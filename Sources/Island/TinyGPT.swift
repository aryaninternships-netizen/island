import Accelerate
import Foundation

/// Bruno's brain: a ~10M-parameter character-level GPT trained in pup/train.py, run here on
/// the CPU with Accelerate. Same forward pass as the MLX model (pre-LN blocks, tanh-GELU,
/// tied embeddings), with a KV cache. A line is ~100 tiny matrix-vector steps: milliseconds.
final class TinyGPT {
    private let nLayer, d, nHead, block, pad: Int
    private let vocab: [Unicode.Scalar]
    private let stoi: [Unicode.Scalar: Int]
    private let w: [Float]
    private var off: [String: Int] = [:]

    init?(json: URL, bin: URL) {
        guard let jd = try? Data(contentsOf: json),
              let meta = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
              let bd = try? Data(contentsOf: bin),
              let nl = meta["n_layer"] as? Int, let ne = meta["n_embd"] as? Int, let nh = meta["n_head"] as? Int,
              let bl = meta["block"] as? Int, let pd = meta["pad"] as? Int,
              let chars = meta["vocab"] as? [String], let order = meta["order"] as? [String],
              let shapes = meta["shapes"] as? [String: [Int]] else { return nil }
        nLayer = nl; d = ne; nHead = nh; block = bl; pad = pd
        vocab = chars.compactMap { $0.unicodeScalars.first }
        var m: [Unicode.Scalar: Int] = [:]
        for (i, c) in vocab.enumerated() { m[c] = i }
        stoi = m
        w = bd.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var o = 0
        for name in order { off[name] = o; o += shapes[name]!.reduce(1, *) }
        guard o == w.count else { return nil }
    }

    /// Generate the line for a conditioning string like "music|Tum Hi Ho".
    func generate(_ prompt: String, temperature: Float = 0.8, topK: Int = 20, maxNew: Int = 100) -> String {
        let space = stoi[" "] ?? 0
        var ids = (prompt + "\t").unicodeScalars.map { stoi[$0] ?? space }
        let end = stoi["\n"] ?? 0
        let hd = d / nHead
        var kCache = [[Float]](repeating: [Float](repeating: 0, count: block * d), count: nLayer)
        var vCache = kCache
        var out = String.UnicodeScalarView()
        var logits = [Float](repeating: 0, count: vocab.count + 1)
        var x = [Float](repeating: 0, count: d), h = x, y = x, qkv = [Float](repeating: 0, count: 3 * d)
        var f = [Float](repeating: 0, count: 4 * d), scores = [Float](repeating: 0, count: block)

        func step(_ id: Int, _ t: Int) {
            w.withUnsafeBufferPointer { W in
                let tok = off["tok.weight"]!, pos = off["pos.weight"]!
                for i in 0..<d { x[i] = W[tok + id * d + i] + W[pos + t * d + i] }
                for l in 0..<nLayer {
                    let p = "blocks.\(l)."
                    layerNorm(x, &h, W, off[p + "ln1.weight"]!, off[p + "ln1.bias"]!)
                    gemv(W, off[p + "qkv.weight"]!, off[p + "qkv.bias"]!, rows: 3 * d, cols: d, h, &qkv)
                    for i in 0..<d { kCache[l][t * d + i] = qkv[d + i]; vCache[l][t * d + i] = qkv[2 * d + i] }
                    let scale = 1 / Float(hd).squareRoot()
                    for hh in 0..<nHead {
                        var mx: Float = -.infinity
                        for j in 0...t {
                            var s: Float = 0
                            for k in 0..<hd { s += qkv[hh * hd + k] * kCache[l][j * d + hh * hd + k] }
                            scores[j] = s * scale; mx = max(mx, scores[j])
                        }
                        var sum: Float = 0
                        for j in 0...t { scores[j] = expf(scores[j] - mx); sum += scores[j] }
                        for k in 0..<hd {
                            var acc: Float = 0
                            for j in 0...t { acc += scores[j] * vCache[l][j * d + hh * hd + k] }
                            y[hh * hd + k] = acc / sum
                        }
                    }
                    gemv(W, off[p + "proj.weight"]!, off[p + "proj.bias"]!, rows: d, cols: d, y, &h)
                    for i in 0..<d { x[i] += h[i] }
                    layerNorm(x, &h, W, off[p + "ln2.weight"]!, off[p + "ln2.bias"]!)
                    gemv(W, off[p + "fc.weight"]!, off[p + "fc.bias"]!, rows: 4 * d, cols: d, h, &f)
                    for i in 0..<4 * d { let v = f[i]; f[i] = 0.5 * v * (1 + tanhf(0.7978845608 * (v + 0.044715 * v * v * v))) }
                    gemv(W, off[p + "out.weight"]!, off[p + "out.bias"]!, rows: d, cols: 4 * d, f, &h)
                    for i in 0..<d { x[i] += h[i] }
                }
                layerNorm(x, &h, W, off["ln_f.weight"]!, off["ln_f.bias"]!)
                // tied head: logits = tok · h
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(vocab.count + 1), Int32(d), 1,
                            W.baseAddress! + tok, Int32(d), h, 1, 0, &logits, 1)
            }
        }

        var t = 0
        for id in ids.dropLast() { if t < block - 1 { step(id, t); t += 1 } }
        var cur = ids.last!
        for _ in 0..<maxNew {
            guard t < block else { break }
            step(cur, t); t += 1
            let next = sample(Array(logits[0..<pad]), temperature, topK)
            if next == end { break }
            out.append(vocab[next]); ids.append(next); cur = next
        }
        return String(out)
    }

    private func gemv(_ W: UnsafeBufferPointer<Float>, _ wOff: Int, _ bOff: Int, rows: Int, cols: Int,
                      _ xin: [Float], _ yout: inout [Float]) {
        for i in 0..<rows { yout[i] = W[bOff + i] }
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(cols), 1, W.baseAddress! + wOff,
                    Int32(cols), xin, 1, 1, &yout, 1)
    }

    private func layerNorm(_ xin: [Float], _ yout: inout [Float], _ W: UnsafeBufferPointer<Float>, _ g: Int, _ b: Int) {
        var mean: Float = 0, v: Float = 0
        for i in 0..<d { mean += xin[i] }
        mean /= Float(d)
        for i in 0..<d { let c = xin[i] - mean; v += c * c }
        let inv = 1 / (v / Float(d) + 1e-5).squareRoot()
        for i in 0..<d { yout[i] = (xin[i] - mean) * inv * W[g + i] + W[b + i] }
    }

    private func sample(_ logits: [Float], _ temp: Float, _ k: Int) -> Int {
        if temp <= 0 { return logits.indices.max { logits[$0] < logits[$1] }! }
        let top = logits.indices.sorted { logits[$0] > logits[$1] }.prefix(k)
        let m = logits[top.first!]
        let ps = top.map { expf((logits[$0] - m) / temp) }
        var r = Float.random(in: 0..<ps.reduce(0, +))
        for (i, p) in zip(top, ps) { r -= p; if r <= 0 { return i } }
        return top.first!
    }
}

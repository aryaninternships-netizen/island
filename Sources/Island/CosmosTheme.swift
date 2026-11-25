import AppKit
import CoreGraphics
import CoreImage

/// Cosmos: a designed deep-space wallpaper. Soft luminous nebula (season palette), a fine star
/// field with a few diffraction-spike stars, and a planet crescent on the right whose phase and
/// light colour follow the time of day. Built as a low-res radiance field (smooth, no detail
/// noise), upsampled, tone-mapped filmically, then stars drawn crisp on top.
enum CosmosTheme {

    // MARK: palette

    private struct V3 { var r: Float, g: Float, b: Float
        init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
        static func * (a: V3, k: Float) -> V3 { V3(a.r * k, a.g * k, a.b * k) }
        static func + (a: V3, b: V3) -> V3 { V3(a.r + b.r, a.g + b.g, a.b + b.b) }
        func mix(_ o: V3, _ t: Float) -> V3 { V3(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
    }
    /// sRGB hex -> linear
    private static func hex(_ v: UInt32) -> V3 {
        func l(_ c: UInt32) -> Float { let s = Float(c) / 255; return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4) }
        return V3(l((v >> 16) & 255), l((v >> 8) & 255), l(v & 255))
    }

    private struct Pal { let gas: V3, core: V3, hot: V3, wash: V3 }

    private static func palette(_ s: Season) -> Pal {
        switch s {
        case .winter:  return Pal(gas: hex(0x2F5BD6), core: hex(0x5FC8F0), hot: hex(0xD8F2FF), wash: hex(0x1A2C6B))
        case .spring:  return Pal(gas: hex(0xB0368F), core: hex(0xF07AB8), hot: hex(0xFFE0EE), wash: hex(0x4A1E5E))
        case .summer:  return Pal(gas: hex(0xE0503C), core: hex(0xFFB547), hot: hex(0xFFF3D6), wash: hex(0x3A1640))
        case .monsoon: return Pal(gas: hex(0x0F7F7A), core: hex(0x3FD6A8), hot: hex(0xD9FFF0), wash: hex(0x0B3A4A))
        case .autumn:  return Pal(gas: hex(0xA8323C), core: hex(0xF08A3A), hot: hex(0xFFE2BC), wash: hex(0x2E1838))
        }
    }

    private struct Time {
        let bgTop: V3, bgLow: V3
        let gain: Float          // nebula brightness
        let warm: V3; let warmK: Float   // tint pulled into gas
        let stars: Int; let bright: Int
        let light: V3            // planet light colour
        let phase: Float         // light direction z (more negative = thinner crescent)
        let lightAng: Float      // 2D angle of light (radians), pi = from left
        var washBg: Float = 1; var washK: Float = 0.3
    }

    private static func time(_ p: DayPart) -> Time {
        switch p {
        case .morning:
            return Time(bgTop: hex(0x0A0F24), bgLow: hex(0x1B1A3A), gain: 0.95, warm: hex(0xFF9E7A), warmK: 0.12,
                        stars: 150, bright: 3, light: hex(0xFFD2B0), phase: -0.70, lightAng: .pi * 1.12, washBg: 0.8, washK: 0.22)
        case .afternoon:
            return Time(bgTop: hex(0x16244A), bgLow: hex(0x2A3A66), gain: 0.85, warm: hex(0xBFD8FF), warmK: 0.18,
                        stars: 70, bright: 2, light: hex(0xF4F8FF), phase: -0.45, lightAng: .pi * 0.92, washBg: 1.0, washK: 0.30)
        case .evening:
            return Time(bgTop: hex(0x120B22), bgLow: hex(0x2E1430), gain: 1.05, warm: hex(0xFF6A4A), warmK: 0.22,
                        stars: 190, bright: 4, light: hex(0xFFA060), phase: -0.80, lightAng: .pi * 0.86, washBg: 0.6, washK: 0.25)
        case .night:
            return Time(bgTop: hex(0x03040C), bgLow: hex(0x0A0B1C), gain: 1.25, warm: hex(0x8090FF), warmK: 0.06,
                        stars: 280, bright: 5, light: hex(0xC8D6FF), phase: -0.90, lightAng: .pi * 1.0, washBg: 0.35, washK: 0.30)
        }
    }

    // MARK: noise

    @inline(__always) private static func hash(_ x: Int32, _ y: Int32, _ s: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6B343 ^ UInt32(bitPattern: y) &* 0xD8163841 ^ s &* 0xCB1AB31F
        h ^= h >> 13; h = h &* 0x5BD1E995; h ^= h >> 15
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }
    @inline(__always) private static func vnoise(_ x: Float, _ y: Float, _ s: UInt32) -> Float {
        let fx = floorf(x), fy = floorf(y)
        let ix = Int32(fx), iy = Int32(fy)
        var tx = x - fx, ty = y - fy
        tx = tx * tx * tx * (tx * (tx * 6 - 15) + 10); ty = ty * ty * ty * (ty * (ty * 6 - 15) + 10)
        let a = hash(ix, iy, s), b = hash(ix + 1, iy, s), c = hash(ix, iy + 1, s), d = hash(ix + 1, iy + 1, s)
        return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
    }
    @inline(__always) private static func fbm(_ x: Float, _ y: Float, _ s: UInt32, _ oct: Int) -> Float {
        var sum: Float = 0, amp: Float = 0.5, f: Float = 1, norm: Float = 0
        var px = x, py = y
        for o in 0..<oct {
            sum += amp * vnoise(px * f, py * f, s &+ UInt32(o) &* 1013)
            norm += amp; amp *= 0.5; f *= 2.03
            let t = px; px = 0.8 * px - 0.6 * py; py = 0.6 * t + 0.8 * py   // rotate per octave
        }
        return sum / norm
    }
    @inline(__always) private static func sstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
    }

    private static func stableHash(_ s: String) -> UInt64 {
        s.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
    }

    // MARK: render

    static func render(size: CGSize, scale: CGFloat, part: DayPart, season: Season) -> CGImage? {
        let W = max(1, Int((size.width * scale).rounded())), H = max(1, Int((size.height * scale).rounded()))
        let pal = palette(season), tm = time(part)
        let seasonSeed = UInt32(truncatingIfNeeded: stableHash("cosmos-" + season.rawValue))
        var rng = SeededRNG(seed: stableHash("cosmos-stars-" + part.rawValue + "-" + season.rawValue))
        let aspect = Float(W) / Float(H)

        // ---- 1. Low-res nebula radiance field (linear RGB) ----
        let ds = 3
        let lw = W / ds + 2, lh = H / ds + 2
        var neb = [Float](repeating: 0, count: lw * lh * 3)
        // Season-specific layout jitter, so each season's cloud has its own shape.
        let ox = Float(seasonSeed % 997) / 97, oy = Float((seasonSeed / 997) % 991) / 89
        // Lobes: where the gas lives (unit coords, y up). Left mass + upper sweep, centre kept quiet.
        let lobes: [(Float, Float, Float, Float)] = [
            (0.10, 0.62, 0.30, 1.00), (0.28, 0.95, 0.26, 0.75), (0.50, 1.10, 0.22, 0.45),
            (0.70, 0.95, 0.20, 0.55), (0.02, 0.15, 0.22, 0.55),
        ]
        var den = [Float](repeating: 0, count: lw * lh), amb = den
        var maxD: Float = 0
        do {
            for j in 0..<lh {
                let v = (Float(j) * Float(ds)) / Float(H)            // 0 top .. 1 bottom (image space)
                let vy = 1 - v
                for i in 0..<lw {
                    let u = (Float(i) * Float(ds)) / Float(W)
                    let px = u * aspect * 0.55 + ox, py = vy * 0.55 + oy
                    // domain warp
                    let w1 = fbm(px * 1.3, py * 1.3, seasonSeed, 3)
                    let w2 = fbm(px * 1.3 + 5.2, py * 1.3 + 1.3, seasonSeed, 3)
                    let n = fbm(px * 1.6 + 1.7 * w1, py * 1.6 + 1.7 * w2, seasonSeed &+ 7, 5)
                    var mask: Float = 0
                    for l in lobes {
                        let dx = (u - l.0) * aspect * 0.42, dy = vy - l.1
                        mask += l.3 * expf(-(dx * dx + dy * dy) / (l.2 * l.2))
                    }
                    mask = min(mask, 1.2)
                    // quiet centre band (text area)
                    let cx = abs(u - 0.5), cy = abs(vy - 0.45)
                    let quiet = 1 - 0.55 * (1 - sstep(0.12, 0.34, cx)) * (1 - sstep(0.18, 0.45, cy))
                    let d = sstep(0.36, 0.78, n) * 1.15 * mask * quiet
                    let dust = sstep(0.52, 0.72, fbm(px * 3.1 - 2.0, py * 3.1 + 4.0, seasonSeed &+ 31, 3))
                    let dd = d * (1 - 0.55 * dust)
                    let k = j * lw + i
                    den[k] = dd; amb[k] = mask * quiet
                }
            }
        }
        // 97th percentile, not max, so one hot spot can't dim the rest.
        do { var srt = den.filter { $0 > 0.001 }; srt.sort(); if !srt.isEmpty { maxD = srt[min(srt.count - 1, Int(Float(srt.count) * 0.97))] } }
        // Normalise per season so every palette gets an equally luminous cloud.
        let norm: Float = 1.0 / max(maxD, 0.05)
        let gas = pal.gas.mix(tm.warm, tm.warmK)
        neb.withUnsafeMutableBufferPointer { nb in
            for k in 0..<(lw * lh) {
                let dd = min(den[k] * norm * 0.85, 1.1)
                var c = gas * (dd * 0.85)
                c = c + pal.core * (dd * dd * 0.75)
                c = c + pal.hot * (dd * dd * dd * dd * 0.26)
                c = c + gas * (amb[k] * 0.07)        // ambient glow around the cloud
                c = c + pal.wash * (amb[k] * 0.25)
                nb[k * 3] = c.r * tm.gain; nb[k * 3 + 1] = c.g * tm.gain; nb[k * 3 + 2] = c.b * tm.gain
            }
        }

        // ---- 2. Full-res composite: background + upsampled nebula + planet + tone map + grain ----
        let bpr = W * 4
        var px = [UInt8](repeating: 0, count: bpr * H)
        // gamma LUT for 0..1 linear -> sRGB byte
        var lut = [UInt8](repeating: 0, count: 4097)
        for i in 0...4096 { let l = Float(i) / 4096
            let s = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
            lut[i] = UInt8(max(0, min(255, s * 255 + 0.5))) }

        // planet geometry (pixels, image space y down)
        let R = Float(H) * 0.95
        let pcx = Float(W) * 0.86 + R, pcy = Float(H) * 0.70
        let la = tm.lightAng
        var Lx = cosf(la), Ly = -sinf(la) * 0.6, Lz = tm.phase   // Ly in image space (down positive)
        let ln = sqrtf(Lx * Lx + Ly * Ly + Lz * Lz); Lx /= ln; Ly /= ln; Lz /= ln
        let l2n = sqrtf(Lx * Lx + Ly * Ly)
        let surfLit = tm.light.mix(pal.core, 0.25)
        let atmo = tm.light.mix(pal.core, 0.45)
        var grainState: UInt32 = UInt32(truncatingIfNeeded: stableHash("grain-" + part.rawValue + season.rawValue)) | 1
        let grainAmp: Float = 0.022

        neb.withUnsafeBufferPointer { nb in
        lut.withUnsafeBufferPointer { lt in
        px.withUnsafeMutableBufferPointer { out in
            let invDs = 1 / Float(ds)
            for y in 0..<H {
                let fy = Float(y) * invDs
                let j0 = min(Int(fy), lh - 2); let ty = fy - Float(j0)
                let v = Float(y) / Float(H - 1)
                let bg = tm.bgTop.mix(tm.bgLow, v * v).mix(pal.wash * tm.washBg, tm.washK)
                for x in 0..<W {
                    let fx = Float(x) * invDs
                    let i0 = min(Int(fx), lw - 2); let tx = fx - Float(i0)
                    let k00 = (j0 * lw + i0) * 3, k10 = k00 + 3, k01 = k00 + lw * 3, k11 = k01 + 3
                    let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty
                    var r = nb[k00] * w00 + nb[k10] * w10 + nb[k01] * w01 + nb[k11] * w11 + bg.r
                    var g = nb[k00+1] * w00 + nb[k10+1] * w10 + nb[k01+1] * w01 + nb[k11+1] * w11 + bg.g
                    var b = nb[k00+2] * w00 + nb[k10+2] * w10 + nb[k01+2] * w01 + nb[k11+2] * w11 + bg.b

                    // planet
                    let dx = (Float(x) - pcx) / R, dy = (Float(y) - pcy) / R
                    let rr = dx * dx + dy * dy
                    if rr < 1.6 {
                        let rd = sqrtf(rr)
                        if rd < 1 {
                            let nz = sqrtf(1 - rr)
                            let ndl = dx * Lx + dy * Ly + nz * Lz
                            let lit = sstep(0.05, 0.6, ndl)
                            // edge AA
                            let edge = sstep(1, 1 - 2.0 / R, rd)
                            let shadow: Float = 0.12
                            let fres = powf(1 - nz, 2.5) * 1.1
                            var sr = r * shadow + pal.wash.r * 0.10 + surfLit.r * lit * 0.42 + atmo.r * fres * lit
                            var sg = g * shadow + pal.wash.g * 0.10 + surfLit.g * lit * 0.42 + atmo.g * fres * lit
                            var sb = b * shadow + pal.wash.b * 0.10 + surfLit.b * lit * 0.42 + atmo.b * fres * lit
                            // faint broad bands (stylised)
                            let band = 0.92 + 0.08 * sinf((dy + 0.15 * dx) * 9)
                            sr *= band; sg *= band; sb *= band
                            r = r + (sr - r) * edge; g = g + (sg - g) * edge; b = b + (sb - b) * edge
                        }
                        // atmosphere halo, strongest on lit side
                        if rd > 0.9 {
                            let face = max(0, (dx * Lx + dy * Ly) / max(rd * l2n, 1e-4))
                            let hal = expf(-max(0, rd - 1) * 30) * sstep(0.9, 1.0, rd) * (0.06 + 0.94 * face * face) * 0.9
                            r += atmo.r * hal; g += atmo.g * hal; b += atmo.b * hal
                        }
                    }

                    // filmic tone map
                    r = 1 - expf(-r * 1.6); g = 1 - expf(-g * 1.6); b = 1 - expf(-b * 1.6)
                    // grain
                    grainState ^= grainState << 13; grainState ^= grainState >> 17; grainState ^= grainState << 5
                    let gn = (Float(grainState & 0xFFFF) / 65535 - 0.5) * grainAmp
                    let o = y * bpr + x * 4
                    out[o] = lt[Int(min(max(r + gn, 0), 1) * 4096)]
                    out[o + 1] = lt[Int(min(max(g + gn, 0), 1) * 4096)]
                    out[o + 2] = lt[Int(min(max(b + gn, 0), 1) * 4096)]
                    out[o + 3] = 255
                }
            }
        }}}

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let base = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: cs,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))

        // ---- 3. Stars (CG space, y up) ----
        let sc = Float(scale)
        func inPlanet(_ x: CGFloat, _ yUp: CGFloat) -> Bool {
            let dx = (Float(x) - pcx) / R, dy = (Float(CGFloat(H) - yUp) - pcy) / R
            return dx * dx + dy * dy < 1.02
        }
        ctx.setBlendMode(.screen)
        let starTint: [CGColor] = [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            CGColor(srgbRed: 0.80, green: 0.88, blue: 1, alpha: 1),
            CGColor(srgbRed: 1, green: 0.92, blue: 0.82, alpha: 1),
        ]
        let nStars = Int(Float(tm.stars) * Float(size.width * size.height) / Float(668 * 214))
        _ = sc
        for _ in 0..<nStars {
            let x = CGFloat.random(in: 0..<CGFloat(W), using: &rng)
            let y = CGFloat.random(in: 0..<CGFloat(H), using: &rng)
            let m = CGFloat.random(in: 0...1, using: &rng)
            let tint = starTint[Int.random(in: 0..<3, using: &rng)]
            if inPlanet(x, y) { continue }
            let rad = (0.35 + 0.75 * m * m * m) * scale
            let a = 0.25 + 0.7 * m
            ctx.setFillColor(tint.copy(alpha: a)!)
            ctx.fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
        }

        // bright diffraction-spike stars, kept out of the centre text band and off the planet
        var placed = 0, tries = 0
        while placed < tm.bright && tries < 60 {
            tries += 1
            let u = CGFloat.random(in: 0.03...0.80, using: &rng)
            let vv = CGFloat.random(in: 0.12...0.92, using: &rng)
            if u > 0.30 && u < 0.68 && vv > 0.22 && vv < 0.78 { continue }
            let x = u * CGFloat(W), y = vv * CGFloat(H)
            if inPlanet(x, y) { continue }
            let big = CGFloat.random(in: 0.55...1.0, using: &rng) * (placed == 0 ? 1.25 : 1)
            spikeStar(ctx, at: CGPoint(x: x, y: y), size: big * 7 * scale,
                      tint: CGColor(srgbRed: CGFloat(pal.hot.r) * 0.2 + 0.8, green: CGFloat(pal.hot.g) * 0.2 + 0.8,
                                    blue: CGFloat(pal.hot.b) * 0.2 + 0.8, alpha: 1))
            placed += 1
        }
        return ctx.makeImage()
    }

    private static func spikeStar(_ g: CGContext, at p: CGPoint, size s: CGFloat, tint: CGColor) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func radial(_ r: CGFloat, _ a: CGFloat) {
            let grad = CGGradient(colorsSpace: cs, colors: [tint.copy(alpha: a)!, tint.copy(alpha: a * 0.25)!, tint.copy(alpha: 0)!] as CFArray,
                                  locations: [0, 0.25, 1])!
            g.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
        }
        g.saveGState(); g.translateBy(x: p.x, y: p.y)
        radial(s * 1.6, 0.35)                  // halo
        for (ang, len, th) in [(CGFloat(0), s * 4.2, 0.045), (.pi / 2, s * 3.4, 0.05)] as [(CGFloat, CGFloat, CGFloat)] {
            g.saveGState(); g.rotate(by: ang); g.scaleBy(x: 1, y: th)
            radial(len, 0.9)
            g.restoreGState()
        }
        let core = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 1), tint.copy(alpha: 0.8)!, tint.copy(alpha: 0)!] as CFArray,
                              locations: [0, 0.3, 1])!
        g.drawRadialGradient(core, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: s * 0.45, options: [])
        g.restoreGState()
    }
}

import CoreImage
import Foundation
import Vision

// Probe Apple's on-device face-identity model (used by Photos' People album).
guard let cls = NSClassFromString("VNCreateFaceprintRequest") as? VNImageBasedRequest.Type else {
    print("VNCreateFaceprintRequest: NOT available"); exit(1)
}
print("VNCreateFaceprintRequest: available")

func faceprint(_ path: String) -> [Float]? {
    guard let ci = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    let det = VNDetectFaceRectanglesRequest()
    let h = VNImageRequestHandler(ciImage: ci, options: [:])
    try? h.perform([det])
    guard let face = det.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { print(path, "no face"); return nil }
    let req = cls.init()
    req.setValue([face], forKey: "inputFaceObservations")
    do { try h.perform([req]) } catch { print("perform error", error); return nil }
    guard let obs = req.results?.first as? NSObject,
          let fp = obs.value(forKey: "faceprint") as? NSObject,
          let data = fp.value(forKey: "descriptorData") as? Data else { print("no faceprint in results"); return nil }
    let n = data.count / 4
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(n)) }
}

func l2(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot() }

let paths = Array(CommandLine.arguments.dropFirst())
var prints: [(String, [Float])] = []
for p in paths { if let f = faceprint(p) { prints.append(((p as NSString).lastPathComponent, f)) } }
if let f = prints.first { print("dim:", f.1.count, " norm:", String(format: "%.3f", l2(f.1, [Float](repeating: 0, count: f.1.count)))) }
for i in 0..<prints.count { for j in (i + 1)..<prints.count {
    print(String(format: "%.3f  %@  <->  %@", l2(prints[i].1, prints[j].1), String(prints[i].0.prefix(26)), String(prints[j].0.prefix(26))))
} }

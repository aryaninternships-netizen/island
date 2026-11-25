// Calibration: distance of every face in the given images to the registered owner profile.
// swiftc -O tools/facecal/main.swift Sources/Island/FaceID.swift -o .build/facecal
import CoreImage
import Foundation
import Vision

struct Store: Codable { var v: Int; var prints: [[Float]]; var threshold: Float }
let s = try JSONDecoder().decode(Store.self, from: Data(contentsOf: FaceID.file))
print(String(format: "profile: %d samples, threshold %.3f", s.prints.count, s.threshold))
for path in CommandLine.arguments.dropFirst() {
    guard let ci = CIImage(contentsOf: URL(fileURLWithPath: path)) else { print(path, "unreadable"); continue }
    let det = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(ciImage: ci, options: [:]).perform([det])
    let faces = det.results ?? []
    if faces.isEmpty { print((path as NSString).lastPathComponent, "no face") }
    for f in faces {
        guard let p = FaceID.printFace(ci, face: f) else { continue }
        let d = s.prints.map { FaceID.distance($0, p) }.min()!
        print(String(format: "%@  dist %.3f  %@", (path as NSString).lastPathComponent, d, d <= s.threshold ? "ACCEPT (would pass as you)" : "reject"))
    }
}

// Backfill Guard events from existing snapshots: crop the largest face, append to events.json.
// usage: importevents "<reason>|<photo file>" ...   (files in ~/Pictures/Island Guard)
import CoreImage
import Foundation
import Vision

struct GuardEvent: Codable { let id: UUID; let date: Date; let reason: String; var photos: [String]; var face: String?; var seen: Bool }
let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Island Guard")
let file = folder.appendingPathComponent("events.json")
var events = (try? JSONDecoder().decode([GuardEvent].self, from: Data(contentsOf: file))) ?? []
let ctx = CIContext()
let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.split(separator: "|", maxSplits: 1).map(String.init)
    let reason = parts[0], name = parts[1]
    let url = folder.appendingPathComponent(name)
    guard let img = CIImage(contentsOf: url) else { print("unreadable", name); continue }
    let stamp = String(name.dropFirst("intruder ".count).dropLast(4))
    let date = df.date(from: stamp) ?? Date()
    var face: String?
    let req = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(ciImage: img, options: [:]).perform([req])
    if let f = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
        let e = img.extent, b = f.boundingBox
        var r = CGRect(x: b.minX * e.width, y: b.minY * e.height, width: b.width * e.width, height: b.height * e.height)
        r = r.insetBy(dx: -r.width * 0.45, dy: -r.height * 0.45).intersection(e)
        if let d = ctx.jpegRepresentation(of: img.cropped(to: r), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
            face = "face \(stamp).jpg"; try? d.write(to: folder.appendingPathComponent(face!))
        }
    }
    events.append(GuardEvent(id: UUID(), date: date, reason: reason, photos: [name], face: face, seen: false))
    print("event:", reason, "@", stamp, "face:", face ?? "none")
}
try JSONEncoder().encode(events).write(to: file)

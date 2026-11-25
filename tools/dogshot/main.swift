import SwiftUI
import AppKit

// Renders every mood at a few moments into one sheet: dogshot <out.png> [scale]
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dogs.png"
let scale = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2])!) : 6
let moods: [(String, DogMood)] = [("walk", .walk), ("sit", .sit), ("dance", .dance), ("curious", .curious), ("bark", .bark), ("alert", .alert),
                                   ("angry", .angry), ("sleep", .sleep), ("hungry", .hungry), ("eat", .eat), ("play", .play), ("happy", .happy)]
let pick = CommandLine.arguments.count > 3 ? Set(CommandLine.arguments[3].split(separator: ",").map(String.init)) : nil
let shown = moods.filter { pick?.contains($0.0) ?? true }
let times: [Double] = [0.0, 0.35, 1.1]

struct Sheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown, id: \.0) { name, m in
                HStack(spacing: 10) {
                    Text(name).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).frame(width: 70, alignment: .leading)
                    ForEach(times, id: \.self) { t in Dog(t: t, mood: m, scale: scale).background(Color(white: 0.04)) }
                }
            }
        }.padding(12).background(Color.black)
    }
}

@MainActor func run() {
    let r = ImageRenderer(content: Sheet())
    r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); exit(1) }
    try! png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
@main struct Main { static func main() { MainActor.assumeIsolated { run() } } }

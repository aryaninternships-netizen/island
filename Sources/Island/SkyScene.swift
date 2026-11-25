import AppKit
import CoreImage

/// Open-island backdrop: the Cosmos theme (nebula + planet crescent), matched to the time of day
/// and the (Delhi) season. Drawn once per (part of day, season, size) and cached; it's a still
/// image, so it costs nothing while shown.
enum DayPart: String, CaseIterable {
    case morning, afternoon, evening, night

    static func at(_ d: Date = Date()) -> DayPart {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        switch h {
        case 5..<11: return .morning
        case 11..<16: return .afternoon
        case 16..<19.5: return .evening
        default: return .night
        }
    }
}

enum Season: String, CaseIterable {
    case winter, spring, summer, monsoon, autumn

    /// Delhi's year: winter Dec-Feb, spring Mar-Apr, summer May-Jun, monsoon Jul-Sep, autumn Oct-Nov.
    static func at(_ d: Date = Date()) -> Season {
        switch Calendar.current.component(.month, from: d) {
        case 12, 1, 2: return .winter
        case 3, 4: return .spring
        case 5, 6: return .summer
        case 7, 8, 9: return .monsoon
        default: return .autumn
        }
    }
}

enum SkyScene {
    private static var cache: [String: CGImage] = [:]
    /// Preview a fixed scene (island://sky?part=night&season=summer; no params = back to live).
    static var override: (DayPart, Season)?

    /// Cached Cosmos backdrop (CosmosTheme) for this moment's time of day and season.
    static func image(size: CGSize, scale: CGFloat, part livePart: DayPart = .at(), season liveSeason: Season = .at()) -> CGImage? {
        let part = override?.0 ?? livePart, season = override?.1 ?? liveSeason
        let key = "\(part.rawValue)-\(season.rawValue)-\(Int(size.width))x\(Int(size.height))@\(scale)"
        if let c = cache[key] { return c }
        guard let raw = CosmosTheme.render(size: size, scale: scale, part: part, season: season) else { return nil }
        let img = readable(raw, scale: scale) ?? raw
        if cache.count > 8 { cache.removeAll() }
        cache[key] = img
        return img
    }
}

extension SkyScene {
    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// Island content spans the whole panel, so no part of the scene may glare behind text:
    /// a tone curve caps highlights (~0.42) while keeping the darks rich, and a light blur softens
    /// hard edges (the planet's rim). Colour and stars survive; white text always stands out.
    static func readable(_ img: CGImage, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: img)
        let curve = CIFilter(name: "CIToneCurve", parameters: [
            kCIInputImageKey: input,
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.25, y: 0.19),
            "inputPoint2": CIVector(x: 0.5, y: 0.31),
            "inputPoint3": CIVector(x: 0.75, y: 0.38),
            "inputPoint4": CIVector(x: 1, y: 0.42),
        ])?.outputImage
        guard let toned = curve,
              let soft = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: toned.clampedToExtent(),
                                                                        kCIInputRadiusKey: 1.2 * scale])?.outputImage?
                .cropped(to: input.extent) else { return nil }
        return ci.createCGImage(soft, from: input.extent)
    }
}

/// Deterministic RNG so a scene looks the same every time it's drawn.
struct SeededRNG: RandomNumberGenerator {
    private var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return s
    }
}

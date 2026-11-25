// Anti-spoof liveness for Island's face unlocks.
//
// Adapted from Glance by Jonathan Zhou (https://github.com/jonnyoo/glance), MIT License,
// Copyright (c) Jonathan Zhou. See THIRD_PARTY_NOTICES.md. Ported: the glare and device-bezel
// deny cues, the nose-parallax and blink confirm cues, and the latched cue evaluator. Not
// ported: Glance's flat-vs-3D landmark plane fit.
//
// Deny cues (evidence of a photo/screen) fail the check outright and override everything.
// Confirm cues (evidence of a real face) pass it; their absence is never a failure.

import CoreGraphics
import CoreImage
import Vision

// MARK: - Frame

/// One frame's liveness measurements, already normalised.
struct LivenessFrame {
    let timestamp: Date
    let yaw: Float?
    let leftEAR: CGFloat?
    let rightEAR: CGFloat?
    /// (nose centroid x - eye midpoint x) / interocular distance: tracks tan(yaw) on a real
    /// 3D face, stays constant on anything flat.
    let noseOffsetRatio: CGFloat?
    let reliable: Bool
    /// Share of the face box inside a detected phone/tablet-shaped rectangle (nil = not run / none).
    let deviceOverlap: CGFloat?
    let glare: GlareSample?
}

struct GlareSample {
    let cropPixelWidth: CGFloat
    /// Near-saturated, low-chroma pixels: direct specular reflection.
    let specularFraction: Float
    /// Densest 8x8 cell's share of them: one blob (glass) vs scattered (skin).
    let specularClusterRatio: Float
}

struct CueReading {
    let level: Float
    let confidence: Float
    static let none = CueReading(level: 0, confidence: 0)
}

enum LivenessCue: String, CaseIterable {
    case glare, device, depthPose, blink
    var deny: Bool { self == .glare || self == .device }
    /// Fire threshold: (level, frames counted across the scan). Glance's real-device defaults.
    var threshold: (level: Float, frames: Int) {
        switch self {
        case .glare: (0.04, 3)
        case .device: (0.15, 3)
        case .depthPose: (0.8, 2)
        case .blink: (0.5, 1)
        }
    }
}

enum LivenessDecision: Equatable {
    case pending
    case confirmed(LivenessCue)
    case denied(LivenessCue)
    var isDenied: Bool { if case .denied = self { return true }; return false }
    var isConfirmed: Bool { if case .confirmed = self { return true }; return false }
}

// MARK: - Analyzer

/// Rolling 2 s window + latched cue counts for one scan (one away session / challenge).
/// Counts accumulate over the whole scan, so a spoof tell can't be waited out.
final class LivenessAnalyzer {
    private var frames: [LivenessFrame] = []
    private var counted: [LivenessCue: Int] = [:]
    private var fired: Set<LivenessCue> = []
    private let lock = NSLock()
    private(set) var decision: LivenessDecision = .pending

    func reset() {
        lock.lock(); frames = []; counted = [:]; fired = []; decision = .pending; lock.unlock()
    }

    @discardableResult
    func observe(_ f: LivenessFrame) -> LivenessDecision {
        lock.lock(); defer { lock.unlock() }
        frames.append(f)
        frames.removeAll { f.timestamp.timeIntervalSince($0.timestamp) > 2 }
        let readings: [LivenessCue: CueReading] = [
            .glare: Self.glare(f.glare),
            .device: f.deviceOverlap.map { CueReading(level: Float(min(max($0, 0), 1)), confidence: 1) } ?? .none,
            .depthPose: Self.depthPose(frames),
            .blink: Self.blink(frames),
        ]
        for (cue, r) in readings where r.confidence > 0 && r.level >= cue.threshold.level {
            counted[cue, default: 0] += 1
            if counted[cue]! >= cue.threshold.frames { fired.insert(cue) }
        }
        if let d = LivenessCue.allCases.first(where: { $0.deny && fired.contains($0) }) { decision = .denied(d) }
        else if let c = LivenessCue.allCases.first(where: { !$0.deny && fired.contains($0) }) { decision = .confirmed(c) }
        else { decision = .pending }
        return decision
    }

    // MARK: cues

    /// Skin: many small scattered highlights. Glass: one big flat blob.
    private static func glare(_ g: GlareSample?) -> CueReading {
        guard let g else { return .none }
        let fraction = ramp(g.specularFraction, 0.01, 0.08)
        let cluster = ramp(g.specularClusterRatio, 0.3, 1.0)
        // Under ~50 px of face there's not enough detail; full trust by ~130 px.
        return CueReading(level: fraction * (0.3 + 0.7 * cluster), confidence: ramp(Float(g.cropPixelWidth), 50, 130))
    }

    /// Nose offset vs tan(yaw) correlation across head movement; abstains under 12 degrees of turn.
    private static func depthPose(_ w: [LivenessFrame]) -> CueReading {
        let pairs = w.compactMap { f -> (CGFloat, CGFloat)? in
            guard let o = f.noseOffsetRatio, let y = f.yaw, f.reliable else { return nil }
            return (o, CGFloat(tan(y)))
        }
        guard pairs.count >= 4, let lo = pairs.map(\.1).min(), let hi = pairs.map(\.1).max() else { return .none }
        let range = abs(atan(hi) - atan(lo)), minRange: CGFloat = 12 * .pi / 180
        guard range > minRange, let r = pearson(pairs.map(\.0), pairs.map(\.1)) else { return .none }
        return CueReading(level: Float(min(max((r + 1) / 2, 0), 1)),
                          confidence: Float(min(max((range - minRange) / (15 * .pi / 180), 0), 1)))
    }

    /// Eye-aspect-ratio dip below 65% of the window's open level, recovering on both sides.
    private static func blink(_ w: [LivenessFrame]) -> CueReading {
        let ears = w.compactMap { f -> CGFloat? in
            guard let l = f.leftEAR, let r = f.rightEAR else { return nil }
            return (l + r) / 2
        }
        guard ears.count >= 4, let base = ears.max(), base > 0, let m = ears.min(), let i = ears.firstIndex(of: m),
              i > 0, i < ears.count - 1 else { return .none }
        let before = ears[..<i].suffix(3).contains { $0 / base > 0.7 }
        let after = ears[(i + 1)...].prefix(3).contains { $0 / base > 0.7 }
        return m / base < 0.65 && before && after ? CueReading(level: 1, confidence: 1) : .none
    }

    private static func pearson(_ xs: [CGFloat], _ ys: [CGFloat]) -> CGFloat? {
        let n = CGFloat(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var c: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 0
        for i in xs.indices {
            let dx = xs[i] - mx, dy = ys[i] - my
            c += dx * dy; vx += dx * dx; vy += dy * dy
        }
        guard vx > 0, vy > 0 else { return nil }
        return c / (vx.squareRoot() * vy.squareRoot())
    }

    private static func ramp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max((v - lo) / max(hi - lo, 0.0001), 0), 1) }
}

// MARK: - Feature extraction

enum LivenessFeatures {
    /// `heavy`: also run the device-rectangle and glare scans (a few ms each); otherwise
    /// only the cheap landmark measurements.
    static func frame(_ face: VNFaceObservation, in image: CIImage, ctx: CIContext, heavy: Bool) -> LivenessFrame {
        let size = image.extent.size
        var leftEAR: CGFloat?, rightEAR: CGFloat?, nose: CGFloat?
        var reliable = false
        if let lm = face.landmarks {
            func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] { r?.pointsInImage(imageSize: size) ?? [] }
            func center(_ p: [CGPoint]) -> CGPoint? {
                p.isEmpty ? nil : CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
            }
            func ear(_ p: [CGPoint]) -> CGFloat? {
                guard p.count >= 4, let x0 = p.map(\.x).min(), let x1 = p.map(\.x).max(),
                      let y0 = p.map(\.y).min(), let y1 = p.map(\.y).max(), x1 > x0 else { return nil }
                return (y1 - y0) / (x1 - x0)
            }
            leftEAR = ear(pts(lm.leftEye)); rightEAR = ear(pts(lm.rightEye))
            let el = center(pts(lm.leftPupil)) ?? center(pts(lm.leftEye))
            let er = center(pts(lm.rightPupil)) ?? center(pts(lm.rightEye))
            if let el, let er, let nc = center(pts(lm.nose)) {
                let io = hypot(er.x - el.x, er.y - el.y)
                if io > 0 { nose = (nc.x - (el.x + er.x) / 2) / io }
            }
            reliable = lm.leftPupil != nil && lm.rightPupil != nil && lm.nose != nil
        }
        return LivenessFrame(timestamp: Date(), yaw: face.yaw?.floatValue, leftEAR: leftEAR, rightEAR: rightEAR,
                             noseOffsetRatio: nose, reliable: reliable,
                             deviceOverlap: heavy ? deviceOverlap(face.boundingBox, image) : nil,
                             glare: heavy ? glare(face.boundingBox, image, ctx) : nil)
    }

    /// A phone/tablet-shaped rectangle overlapping the face (normalised Vision coordinates).
    private static func deviceOverlap(_ faceBox: CGRect, _ image: CIImage) -> CGFloat? {
        let r = VNDetectRectanglesRequest()
        r.minimumConfidence = 0.6
        r.minimumSize = 0.15
        r.maximumObservations = 3
        r.minimumAspectRatio = 0.35
        r.maximumAspectRatio = 1.0
        r.quadratureTolerance = 30
        guard (try? VNImageRequestHandler(ciImage: image).perform([r])) != nil, let rects = r.results, !rects.isEmpty else { return nil }
        let area = faceBox.width * faceBox.height
        guard area > 0 else { return nil }
        // Island change: a phone/tablet showing a face frames it closely and contains it whole.
        // Door frames, cabinets and windows *behind* you also contain your face, but they're far
        // bigger than it, so a candidate must hold the whole face and be at most 3.5x its area.
        var best: CGFloat = 0
        for o in rects {
            let b = o.boundingBox
            let i = b.intersection(faceBox)
            guard !i.isNull else { continue }
            let inside = (i.width * i.height) / area
            let ratio = (b.width * b.height) / area
            if inside >= 0.9, ratio <= 3.5, b.height >= faceBox.height * 1.15 { best = max(best, inside) }
            if inside >= 0.9 { FaceID.debug(String(format: "liveness: rect holds face, %.1fx face area -> %@", ratio, ratio <= 3.5 ? "device" : "background")) }
        }
        return best
    }

    /// Specular highlights in a native-resolution crop of the face.
    private static func glare(_ faceBox: CGRect, _ image: CIImage, _ ctx: CIContext) -> GlareSample? {
        let e = image.extent
        let rect = CGRect(x: e.minX + faceBox.minX * e.width, y: e.minY + faceBox.minY * e.height,
                          width: faceBox.width * e.width, height: faceBox.height * e.height).intersection(e)
        guard rect.width >= 8, rect.height >= 8, let cg = ctx.createCGImage(image, from: rect) else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let c = data.withUnsafeMutableBytes({
            CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let grid = 8
        var cells = [Int](repeating: 0, count: grid * grid), total = 0
        for y in 0..<h {
            let gy = min(grid - 1, y * grid / h)
            for x in 0..<w {
                let o = (y * w + x) * 4
                let r = Float(data[o]), g = Float(data[o + 1]), b = Float(data[o + 2])
                guard 0.299 * r + 0.587 * g + 0.114 * b >= 235 else { continue }
                let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
                let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
                guard abs(cb - 128) <= 10, abs(cr - 128) <= 10 else { continue }
                total += 1
                cells[gy * grid + min(grid - 1, x * grid / w)] += 1
            }
        }
        return GlareSample(cropPixelWidth: CGFloat(w), specularFraction: Float(total) / Float(w * h),
                           specularClusterRatio: total > 0 ? Float(cells.max() ?? 0) / Float(total) : 0)
    }
}

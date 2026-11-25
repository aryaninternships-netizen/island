import SwiftUI

// MARK: - Mood + pose

/// What the pup is feeling. Each mood drives posture, face and timing.
enum DogMood {
    case walk // happy trot, tongue out
    case sit // settles, breathes, blinks, curious head tilts
    case dance // eyes shut in bliss, nods to the beat, paw taps
    case curious // music paused: head cocked, ears up, brows raised
    case bark // "woof!": chin up, mouth snaps open, ears bounce
    case alert // meeting soon: head high, ears perked, tail up
    case angry // intruder: head low, ears pinned, teeth, hackles, tremble
    case sleep // curled up on the floor, slow breathing, eyes shut
    case hungry // sits by the empty bowl, puppy-eyes, ears drooping
    case eat // head down in the bowl, chomping, tail going
    case play // play-bow: chest down, bum up, pouncing at the ball
    case happy // being petted: eyes shut, tongue out, wiggling
}

/// Everything the drawing needs for one frame. Angles in radians.
private struct Pose {
    enum Eyes { case open, wide, blink, bliss }

    var sitting = false
    var lying = false
    var pitch: Double = 0 // torso rotation, negative lifts the front
    var bob: CGFloat = 0
    var squash: CGFloat = 1 // vertical torso scale (breath, stretch)
    var legs: [Double] = [0, 0, 0, 0] // backFar, frontFar, backNear, frontNear (+ = forward)
    var lift: [CGFloat] = [0, 0, 0, 0]
    var pawTap: CGFloat = 0
    var headTilt: Double = 0 // + = chin down
    var headLift: CGFloat = 0 // - = up
    var headForward: CGFloat = 0
    var ear: Double = 0.2 // + = swings back / up
    var tail: Double = 0.7 // 0 = straight back, + = up
    var mouth: CGFloat = 0 // 0 closed ... 1 wide open
    var tongue: CGFloat = 0
    var eyes: Eyes = .open
    var brows: CGFloat = 0 // + angry, - raised
    var teeth = false
    var hackles = false
    var jitter: CGFloat = 0
}

private func blink(_ t: Double, every: Double = 3.7) -> Bool {
    t.truncatingRemainder(dividingBy: every) < 0.13
}

/// 0 -> 1 -> hold -> 0 bump repeating every `period`.
private func pulse(_ t: Double, period: Double, on: Double) -> Double {
    let x = t.truncatingRemainder(dividingBy: period)
    guard x < on else { return 0 }
    let edge = 0.35
    let up = min(x / edge, 1), down = min((on - x) / edge, 1)
    let v = min(up, down)
    return v * v * (3 - 2 * v)
}

private func pose(_ mood: DogMood, _ t: Double) -> Pose {
    var p = Pose()
    switch mood {
    case .walk:
        let f = t * 13
        let a = sin(f), b = sin(f + .pi)
        p.legs = [a * 0.48, b * 0.48, b * 0.48, a * 0.48]
        p.lift = [cos(f), cos(f + .pi), cos(f + .pi), cos(f)].map { CGFloat(max(0, $0)) * 1.4 }
        p.bob = -CGFloat(abs(cos(f))) * 0.75
        p.squash = 1 + 0.035 * CGFloat(sin(2 * f))
        p.pitch = sin(2 * f) * 0.025
        p.headLift = CGFloat(sin(2 * f + 0.8)) * 0.4 // counter-bob
        p.ear = 0.25 + sin(2 * f - 1.1) * 0.24 // lags behind the body
        p.tail = 0.75 + sin(t * 11) * 0.32
        p.mouth = 0.42 + CGFloat(sin(t * 9)) * 0.1
        p.tongue = 0.55
        p.eyes = blink(t) ? .blink : .open

    case .sit:
        p.sitting = true
        p.pitch = -0.5
        p.squash = 1 + 0.022 * CGFloat(sin(t * 2.6)) // breathing
        let tilt = pulse(t + 1, period: 4.6, on: 2.2)
        p.headTilt = -0.28 * tilt
        p.headLift = -CGFloat(tilt) * 0.4
        p.ear = 0.15 + 0.35 * tilt
        p.tail = -0.15 + sin(t * 9) * 0.33 // sweeping the floor
        p.mouth = tilt > 0.3 ? 0 : 0.34 + CGFloat(sin(t * 6)) * 0.08
        p.tongue = tilt > 0.3 ? 0 : 0.45
        p.eyes = blink(t) ? .blink : (tilt > 0.3 ? .wide : .open)
        p.brows = -CGFloat(tilt) * 0.6

    case .dance:
        p.sitting = true
        p.pitch = -0.48
        let beat = t * 3.8
        p.squash = 1 + 0.035 * CGFloat(abs(sin(beat)))
        p.headLift = -CGFloat(abs(sin(beat))) * 1.1 + 0.3
        p.headTilt = sin(beat * 0.5) * 0.2 // sway
        p.ear = 0.25 + sin(beat * 2 - 1) * 0.3
        p.tail = 0.05 + sin(t * 16) * 0.45
        p.pawTap = CGFloat(max(0, sin(beat))) * 1.7
        p.mouth = 0.5
        p.tongue = 0.75
        p.eyes = .bliss

    case .curious:
        p.sitting = true
        p.pitch = -0.52
        p.squash = 1 + 0.02 * CGFloat(sin(t * 2.2))
        p.headTilt = -0.34 + sin(t * 1.3) * 0.04
        p.headLift = -0.6
        p.ear = 0.7 + sin(t * 1.3) * 0.05
        p.tail = -0.1 + sin(t * 3) * 0.15
        p.eyes = blink(t, every: 4.3) ? .blink : .wide
        p.brows = -0.7

    case .bark:
        let k = t * 4.5
        let open = CGFloat(pow(max(0, sin(k)), 0.6))
        p.legs = [-0.18, 0.14, -0.12, 0.2]
        p.mouth = open
        p.tongue = 0.2
        p.headLift = -1.1 * open - 0.4
        p.headTilt = -0.18 * Double(open)
        p.ear = 0.45 + 0.55 * Double(open)
        p.tail = 1.1 + sin(t * 18) * 0.4
        p.squash = 1 - 0.05 * open
        p.pitch = -0.08 * Double(open)
        p.eyes = .wide
        p.brows = -0.4

    case .alert:
        p.legs = [-0.1, 0.08, -0.06, 0.12]
        p.headLift = -1.1
        p.headTilt = -0.12
        p.ear = 0.95 + (pulse(t, period: 2.3, on: 0.4) * 0.12) // twitch
        p.tail = 1.2 + sin(t * 6) * 0.12
        p.eyes = blink(t, every: 3.1) ? .blink : .wide
        p.brows = -0.5

    case .angry:
        p.legs = [-0.25, 0.22, -0.2, 0.28] // braced
        p.pitch = 0.12
        p.headForward = 0.1
        p.headLift = 1.3
        p.headTilt = 0.16
        p.ear = 1.45
        p.tail = 1.35
        p.mouth = 0.34 + CGFloat(sin(t * 30)) * 0.05 // snarl quiver
        p.teeth = true
        p.eyes = .open
        p.brows = 1
        p.hackles = true
        p.jitter = CGFloat(sin(t * 61)) * 0.22

    case .sleep:
        p.lying = true
        p.squash = 1 + 0.035 * CGFloat(sin(t * 1.5)) // slow sleepy breaths
        p.headLift = 3.0 + CGFloat(sin(t * 1.5)) * 0.15
        p.headForward = 1.6
        p.headTilt = 0.12
        p.ear = 0.05
        p.tail = -0.35 + sin(t * 0.7) * 0.05
        p.eyes = .blink

    case .hungry:
        p.sitting = true
        p.pitch = -0.5
        p.squash = 1 + 0.02 * CGFloat(sin(t * 2.4))
        p.headTilt = -0.22 + sin(t * 0.9) * 0.05 // gazing up at you
        p.headLift = -0.3
        p.ear = -0.05 // droopy
        p.tail = -0.25 + sin(t * 2.5) * 0.08 // hopeful, slow
        p.eyes = blink(t, every: 4.1) ? .blink : .wide
        p.brows = -0.85 // puppy eyes

    case .eat:
        let chomp = abs(sin(t * 7))
        p.legs = [-0.08, 0.1, -0.05, 0.14]
        p.pitch = 0.16
        p.headForward = 1.2
        p.headLift = 3.0 + CGFloat(chomp) * 0.5
        p.headTilt = 0.5
        p.mouth = CGFloat(chomp) * 0.45
        p.ear = 0.1 + sin(t * 7) * 0.08
        p.tail = 0.9 + sin(t * 15) * 0.4
        p.eyes = .blink

    case .play:
        let pounce = pulse(t, period: 1.6, on: 0.6)
        p.legs = [-0.12, 0.75, -0.08, 0.8] // front paws stretched out
        p.pitch = 0.32 - pounce * 0.3
        p.bob = -CGFloat(pounce) * 2.5
        p.headLift = 0.6 - CGFloat(pounce) * 0.8
        p.headTilt = -0.15
        p.ear = 0.5 + sin(t * 9) * 0.25
        p.tail = 1.25 + sin(t * 17) * 0.45
        p.mouth = 0.5
        p.tongue = 0.6
        p.eyes = .wide

    case .happy:
        p.sitting = true
        p.pitch = -0.46
        p.squash = 1 + 0.04 * CGFloat(abs(sin(t * 6))) // wiggle
        p.headTilt = sin(t * 2.2) * 0.18 // leaning into the scratch
        p.headLift = -0.2
        p.ear = 0.65 // relaxed back
        p.tail = 0.2 + sin(t * 19) * 0.5
        p.mouth = 0.55
        p.tongue = 0.8
        p.eyes = .bliss
    }
    return p
}

// MARK: - Drawing

/// Chibi dalmatian pup facing right in a 30x22 pt box (ground at y = 21.5): big round head,
/// bean body, tapered legs. Every white part sits on a soft grey under-stroke so overlapping
/// shapes (head on chest, haunch on body) stay readable at any size.
struct Dog: View {
    let t: TimeInterval
    var mood: DogMood = .walk
    /// Drawn larger in the Pet tab; at 2x and up the fine details switch on.
    var scale: CGFloat = 1

    static let size = CGSize(width: 30, height: 22)
    /// The pup's size in the notch (walks, music, reminders): smaller than his original 1x.
    static let small: CGFloat = 0.75
    private var detail: Bool { scale >= 2 }
    /// Outline weight: a touch heavier when tiny so the silhouette survives.
    private var lw: CGFloat { detail ? 0.3 : 0.42 }

    private static let fur = Color(white: 0.99)
    private static let furShade = Color(white: 0.8)
    private static let farFur = Color(white: 0.7)
    private static let farShade = Color(white: 0.52)
    private static let line = Color(white: 0.46)
    private static let farLine = Color(white: 0.3)
    private static let crease = Color(white: 0.78)
    private static let spot = Color(white: 0.1)
    private static let earC = Color(white: 0.1)
    private static let earTop = Color(white: 0.24)
    private static let nose = Color(white: 0.05)
    private static let iris = Color(red: 0.36, green: 0.2, blue: 0.09)
    private static let pupil = Color(red: 0.06, green: 0.03, blue: 0.02)
    private static let tongueC = Color(red: 1, green: 0.47, blue: 0.56)
    private static let tongueDark = Color(red: 0.84, green: 0.28, blue: 0.38)
    private static let mouthC = Color(red: 0.3, green: 0.06, blue: 0.1)
    private static let blush = Color(red: 1, green: 0.48, blue: 0.58)
    private static let collar = Color(red: 0.98, green: 0.36, blue: 0.22)
    private static let collarDark = Color(red: 0.74, green: 0.17, blue: 0.1)
    private static let tag = Color(red: 1, green: 0.8, blue: 0.28)
    private static let tagDark = Color(red: 0.8, green: 0.55, blue: 0.1)

    var body: some View {
        Canvas { c, _ in
            c.scaleBy(x: scale, y: scale)
            draw(&c, pose(mood, t))
        }
        .frame(width: Self.size.width * scale, height: Self.size.height * scale)
    }

    // MARK: helpers

    /// Under-stroke, then fill: the fill hides the inner half, leaving a clean outline.
    private func blob(_ c: inout GraphicsContext, _ p: Path, _ fill: GraphicsContext.Shading, line: Color = Dog.line) {
        c.stroke(p, with: .color(line), style: .init(lineWidth: lw * 2, lineJoin: .round))
        c.fill(p, with: fill)
    }

    private static func union(_ ps: [Path]) -> Path {
        var cg = ps[0].cgPath
        for p in ps.dropFirst() { cg = cg.union(p.cgPath) }
        return Path(cg)
    }

    /// Boolean path ops are the costliest part of a frame: the torso never changes, and the face
    /// only with how far the mouth is open, so both are built once and reused.
    private static let torsoBody = union([Path(ellipseIn: CGRect(x: 4.4, y: 9.4, width: 9.6, height: 8.0)), // rump
                                          Path(ellipseIn: CGRect(x: 11.4, y: 8.8, width: 9.4, height: 8.6)), // chest
                                          Path(roundedRect: CGRect(x: 8, y: 9.7, width: 9, height: 7.2), cornerRadius: 3.2)])
    private static var faces: [Int: Path] = [:]
    private static func face(mouth: CGFloat) -> Path {
        let k = Int((min(max(mouth, 0), 0.6) * 50).rounded()) // 0...30 steps
        if let f = faces[k] { return f }
        let m = CGFloat(k) / 50
        let f = union([Path(ellipseIn: CGRect(x: -4.8, y: -4.5, width: 9.6, height: 8.6)), // skull
                       Path(roundedRect: CGRect(x: 1.2, y: -0.7, width: 6.4, height: 3.9 - m * 1.6), cornerRadius: 1.9), // snout
                       Path(ellipseIn: CGRect(x: -3.4, y: 0.2, width: 7.2, height: 4.0))]) // cheek
        faces[k] = f
        return f
    }

    private func furShading(_ top: CGFloat, _ bottom: CGFloat, far: Bool = false) -> GraphicsContext.Shading {
        let a = far ? Self.farFur : Self.fur, b = far ? Self.farShade : Self.furShade
        return .linearGradient(Gradient(stops: [.init(color: a, location: 0), .init(color: a, location: 0.5), .init(color: b, location: 1)]),
                               startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bottom))
    }

    /// A tapered limb along a quadratic curve a -> b (control m), w0 wide at a, w1 at b.
    private func taper(_ a: CGPoint, _ m: CGPoint, _ b: CGPoint, w0: CGFloat, w1: CGFloat) -> Path {
        var l: [CGPoint] = [], r: [CGPoint] = []
        let n = 12
        for i in 0...n {
            let s = CGFloat(i) / CGFloat(n), u = 1 - s
            let pt = CGPoint(x: u * u * a.x + 2 * u * s * m.x + s * s * b.x, y: u * u * a.y + 2 * u * s * m.y + s * s * b.y)
            let d = CGPoint(x: 2 * u * (m.x - a.x) + 2 * s * (b.x - m.x), y: 2 * u * (m.y - a.y) + 2 * s * (b.y - m.y))
            let len = max(hypot(d.x, d.y), 0.001)
            let w = (w0 + (w1 - w0) * s) / 2
            l.append(CGPoint(x: pt.x - d.y / len * w, y: pt.y + d.x / len * w))
            r.append(CGPoint(x: pt.x + d.y / len * w, y: pt.y - d.x / len * w))
        }
        var p = Path()
        p.move(to: l[0])
        l.dropFirst().forEach { p.addLine(to: $0) }
        // rounded end
        p.addQuadCurve(to: r[n], control: CGPoint(x: b.x + (b.x - m.x) * 0.25 / max(hypot(b.x - m.x, b.y - m.y), 0.001) * w1 * 2,
                                                   y: b.y + (b.y - m.y) * 0.25 / max(hypot(b.x - m.x, b.y - m.y), 0.001) * w1 * 2))
        r.reversed().dropFirst().forEach { p.addLine(to: $0) }
        p.closeSubpath()
        return p
    }

    /// Irregular dalmatian spot: two overlapping ovals.
    private func spot(_ c: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, color: Color = Dog.spot) {
        c.fill(Path(ellipseIn: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)), with: .color(color))
        c.fill(Path(ellipseIn: CGRect(x: x - w * 0.05, y: y - h * 0.62, width: w * 0.55, height: h * 0.6)), with: .color(color))
    }

    private func stroke(_ c: inout GraphicsContext, _ p: Path, _ color: Color, _ w: CGFloat) {
        c.stroke(p, with: .color(color), style: .init(lineWidth: w, lineCap: .round, lineJoin: .round))
    }

    // MARK: body

    private func draw(_ c: inout GraphicsContext, _ p: Pose) {
        let ground: CGFloat = 21.5
        let hipLocal = CGPoint(x: 9, y: 14)
        let hipWorld = p.sitting ? CGPoint(x: 9.6, y: 17.4)
            : p.lying ? CGPoint(x: 9.2, y: 17.6) : CGPoint(x: 9, y: 14 + p.bob)
        c.translateBy(x: p.jitter, y: 0)

        func world(_ l: CGPoint) -> CGPoint {
            let dx = l.x - hipLocal.x, dy = (l.y - hipLocal.y) * p.squash
            let cs = CGFloat(cos(p.pitch)), sn = CGFloat(sin(p.pitch))
            return CGPoint(x: hipWorld.x + cs * dx - sn * dy, y: hipWorld.y + sn * dx + cs * dy)
        }
        func shift(_ q: CGPoint, _ dx: CGFloat, _ dy: CGFloat = 0) -> CGPoint { CGPoint(x: q.x + dx, y: q.y + dy) }

        // soft floor glow
        c.fill(Path(ellipseIn: CGRect(x: 3.5, y: ground - 0.8, width: 23, height: 1.8)), with: .color(.white.opacity(0.07)))

        let shoulder = CGPoint(x: 16.8, y: 14.2), hip = CGPoint(x: 8.4, y: 14.2)

        // legs first, so the body overlaps their tops
        if p.lying {
            foreleg(&c, from: shift(world(shoulder), -1.4, -0.3), ground: ground, far: true)
        } else if p.sitting {
            leg(&c, from: shift(world(shoulder), -1.3), angle: 0.05, ground: ground, lift: 0, far: true, back: false)
            paw(&c, at: CGPoint(x: hipWorld.x + 2.6, y: ground - 1.0), far: true, long: true)
            leg(&c, from: world(shoulder), angle: -0.02, ground: ground, lift: p.pawTap, far: false, back: false)
        } else {
            leg(&c, from: shift(world(hip), -1.2), angle: p.legs[0], ground: ground, lift: p.lift[0], far: true, back: true)
            leg(&c, from: shift(world(shoulder), -1.2), angle: p.legs[1], ground: ground, lift: p.lift[1], far: true, back: false)
            leg(&c, from: world(hip), angle: p.legs[2], ground: ground, lift: p.lift[2], far: false, back: true)
            leg(&c, from: world(shoulder), angle: p.legs[3], ground: ground, lift: p.lift[3], far: false, back: false)
        }

        // torso layer: tail, body, spots, hackles
        c.drawLayer { l in
            l.translateBy(x: hipWorld.x, y: hipWorld.y)
            l.rotate(by: .radians(p.pitch))
            l.scaleBy(x: 1, y: p.squash)
            l.translateBy(x: -hipLocal.x, y: -hipLocal.y)
            drawTail(&l, p)
            drawTorso(&l, p)
        }

        // haunch + near paws over the body
        if p.lying {
            haunch(&c, center: CGPoint(x: hipWorld.x - 0.6, y: ground - 3.3), w: 8.2, h: 6.0)
            paw(&c, at: CGPoint(x: hipWorld.x + 3.4, y: ground - 1.0), far: false, long: true)
            foreleg(&c, from: world(shoulder), ground: ground, far: false)
        } else if p.sitting {
            haunch(&c, center: CGPoint(x: hipWorld.x - 0.5, y: ground - 3.9), w: 8.0, h: 7.4)
            paw(&c, at: CGPoint(x: hipWorld.x + 3.9, y: ground - 1.0), far: false, long: true)
        }

        // collar + swinging tag
        let neck = world(CGPoint(x: 18.6, y: 10.4))
        let band = Path(roundedRect: CGRect(x: -1.25, y: -3.1, width: 2.5, height: 6.2), cornerRadius: 1.25)
            .applying(CGAffineTransform(rotationAngle: CGFloat(p.pitch) - 0.4).concatenating(.init(translationX: neck.x, y: neck.y)))
        blob(&c, band, .linearGradient(Gradient(colors: [Self.collar, Self.collarDark]),
                                        startPoint: CGPoint(x: neck.x - 1, y: neck.y - 2), endPoint: CGPoint(x: neck.x + 1, y: neck.y + 3)),
             line: Self.collarDark)
        if detail {
            c.stroke(band, with: .color(.white.opacity(0.45)), style: .init(lineWidth: 0.14, dash: [0.35, 0.3]))
        }
        let swing = CGFloat(sin(t * 7)) * 0.5 - p.bob * 0.6
        let tagC = CGPoint(x: neck.x + 1.0 + swing * 0.4, y: neck.y + 3.4)
        var ring = Path(); ring.move(to: CGPoint(x: neck.x + 0.7, y: neck.y + 2.2)); ring.addLine(to: CGPoint(x: tagC.x, y: tagC.y - 0.9))
        stroke(&c, ring, Self.tagDark, 0.3)
        let tagP = Path(ellipseIn: CGRect(x: tagC.x - 1.15, y: tagC.y - 1.15, width: 2.3, height: 2.3))
        blob(&c, tagP, .radialGradient(Gradient(colors: [Self.tag, Self.tagDark]), center: CGPoint(x: tagC.x - 0.4, y: tagC.y - 0.4),
                                       startRadius: 0, endRadius: 1.6), line: Self.tagDark)
        c.fill(Path(ellipseIn: CGRect(x: tagC.x - 0.65, y: tagC.y - 0.75, width: 0.6, height: 0.42)), with: .color(.white.opacity(0.9)))
        if detail {
            c.draw(Text("B").font(.system(size: 1.35, weight: .black, design: .rounded)).foregroundColor(Color(red: 0.55, green: 0.36, blue: 0.04)),
                   at: CGPoint(x: tagC.x + 0.05, y: tagC.y + 0.1))
        }

        // head
        let head = CGPoint(x: neck.x + 2.4 + p.headForward + (p.sitting ? 0.2 : 0),
                           y: neck.y - 3.4 + p.headLift + (p.sitting ? 1.7 : 0))
        c.drawLayer { h in
            h.translateBy(x: head.x, y: head.y)
            h.rotate(by: .radians(p.headTilt))
            drawHead(&h, p)
        }
    }

    // MARK: parts

    /// Tapered leg from the body joint down to its paw; `angle` swings it (+ forward), `lift` raises it.
    private func leg(_ c: inout GraphicsContext, from j: CGPoint, angle: Double, ground: CGFloat,
                     lift: CGFloat, far: Bool, back: Bool) {
        let len = ground - 1.0 - j.y
        let foot = CGPoint(x: j.x + CGFloat(sin(angle)) * len, y: j.y + CGFloat(cos(angle)) * len - lift)
        // hind legs bend back at the hock, front legs bend forward when lifted
        let knee = CGPoint(x: (j.x + foot.x) / 2 + (back ? -1.0 : 0.5 * lift), y: (j.y + foot.y) / 2)
        let path = taper(j, knee, foot, w0: back ? 3.8 : 3.1, w1: 1.9)
        blob(&c, path, furShading(j.y, foot.y + 1, far: far), line: far ? Self.farLine : Self.line)
        if !far && !back { spot(&c, (j.x + foot.x) / 2 + 0.2, foot.y - 2.4, 1.1, 0.9) }
        paw(&c, at: CGPoint(x: foot.x + 0.5, y: foot.y), far: far, long: false)
    }

    /// Lying down: foreleg stretched forward along the floor.
    private func foreleg(_ c: inout GraphicsContext, from j: CGPoint, ground: CGFloat, far: Bool) {
        let end = CGPoint(x: j.x + 6.0, y: ground - 1.0)
        let path = taper(j, CGPoint(x: j.x + 2.2, y: ground - 0.9), end, w0: 3.0, w1: 2.0)
        blob(&c, path, furShading(j.y, ground, far: far), line: far ? Self.farLine : Self.line)
        paw(&c, at: CGPoint(x: end.x + 0.6, y: end.y), far: far, long: false)
    }

    /// Round paw with toe creases; `long` is the flat hind foot of a sitting pup.
    private func paw(_ c: inout GraphicsContext, at f: CGPoint, far: Bool, long: Bool) {
        let w: CGFloat = long ? 4.4 : 3.3, h: CGFloat = 2.0
        let r = CGRect(x: f.x - w / 2, y: f.y - h / 2 - 0.05, width: w, height: h)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + 0.5, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - 0.6, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.maxX - 0.4, y: r.minY + 0.2), control: CGPoint(x: r.maxX + 0.4, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.minX + 0.4, y: r.minY + 0.3), control: CGPoint(x: r.midX, y: r.minY - 0.6))
        path.addQuadCurve(to: CGPoint(x: r.minX + 0.5, y: r.maxY), control: CGPoint(x: r.minX - 0.3, y: r.maxY))
        path.closeSubpath()
        blob(&c, path, furShading(r.minY, r.maxY + 0.4, far: far), line: far ? Self.farLine : Self.line)
        guard !far else { return }
        for dx in [-0.65, 0.25] as [CGFloat] {
            var l = Path()
            l.move(to: CGPoint(x: r.maxX - 1.0 + dx, y: r.minY + 0.55))
            l.addLine(to: CGPoint(x: r.maxX - 1.0 + dx, y: r.maxY - 0.15))
            stroke(&c, l, detail ? Self.line : Self.crease, detail ? 0.2 : 0.3)
        }
    }

    private func haunch(_ c: inout GraphicsContext, center h: CGPoint, w: CGFloat, h hh: CGFloat) {
        // egg-shaped thigh, fuller at the bottom where it rests on the floor
        var p = Path()
        p.move(to: CGPoint(x: h.x, y: h.y - hh / 2))
        p.addCurve(to: CGPoint(x: h.x + w / 2, y: h.y + hh * 0.12), control1: CGPoint(x: h.x + w * 0.36, y: h.y - hh / 2),
                   control2: CGPoint(x: h.x + w / 2, y: h.y - hh * 0.2))
        p.addCurve(to: CGPoint(x: h.x, y: h.y + hh / 2), control1: CGPoint(x: h.x + w / 2, y: h.y + hh * 0.42),
                   control2: CGPoint(x: h.x + w * 0.3, y: h.y + hh / 2))
        p.addCurve(to: CGPoint(x: h.x - w / 2, y: h.y + hh * 0.08), control1: CGPoint(x: h.x - w * 0.34, y: h.y + hh / 2),
                   control2: CGPoint(x: h.x - w / 2, y: h.y + hh * 0.36))
        p.addCurve(to: CGPoint(x: h.x, y: h.y - hh / 2), control1: CGPoint(x: h.x - w / 2, y: h.y - hh * 0.26),
                   control2: CGPoint(x: h.x - w * 0.32, y: h.y - hh / 2))
        p.closeSubpath()
        blob(&c, p, furShading(h.y - hh / 2, h.y + hh / 2))
        c.drawLayer { s in
            s.clip(to: p)
            spot(&s, h.x - w * 0.15, h.y - hh * 0.12, 2.3, 1.8)
            spot(&s, h.x + w * 0.28, h.y + hh * 0.22, 1.2, 1.0)
        }
    }

    private func drawTail(_ c: inout GraphicsContext, _ p: Pose) {
        let base = CGPoint(x: 6.2, y: 11.6)
        let a = p.tail
        let tip = CGPoint(x: base.x - CGFloat(cos(a)) * 6.0, y: base.y - CGFloat(sin(a)) * 6.0)
        let ctrl = CGPoint(x: base.x - CGFloat(cos(a - 0.65)) * 3.6, y: base.y - CGFloat(sin(a - 0.65)) * 3.6)
        let path = taper(base, ctrl, tip, w0: 2.4, w1: 1.0)
        blob(&c, path, .color(Self.fur))
        c.drawLayer { s in
            s.clip(to: path)
            spot(&s, (base.x + tip.x) / 2 + (ctrl.x - (base.x + tip.x) / 2) * 0.5, (base.y + tip.y) / 2 + (ctrl.y - (base.y + tip.y) / 2) * 0.5, 1.5, 1.3)
        }
    }

    private func drawTorso(_ c: inout GraphicsContext, _ p: Pose) {
        let body = Self.torsoBody
        if p.hackles {
            for x in stride(from: CGFloat(9.5), through: 16.5, by: 1.4) {
                var h = Path()
                h.move(to: CGPoint(x: x - 0.7, y: 10.2)); h.addLine(to: CGPoint(x: x - 0.4, y: 8.0)); h.addLine(to: CGPoint(x: x + 0.5, y: 10.2))
                h.closeSubpath()
                blob(&c, h, .color(Self.fur))
            }
        }
        blob(&c, body, furShading(9, 17.4))
        c.drawLayer { s in
            s.clip(to: body)
            spot(&s, 9.6, 11.0, 3.4, 2.5)
            spot(&s, 14.8, 12.6, 2.5, 2.0)
            spot(&s, 12.0, 15.6, 1.6, 1.3)
            spot(&s, 6.0, 13.8, 2.0, 1.7)
            spot(&s, 17.8, 10.6, 1.5, 1.2)
            spot(&s, 11.6, 10.0, 1.1, 0.9)
            spot(&s, 16.8, 15.6, 1.2, 1.0)
            // belly shadow + back highlight
            s.fill(Path(ellipseIn: CGRect(x: 8.5, y: 15.4, width: 10, height: 3.4)), with: .color(.black.opacity(0.12)))
            s.fill(Path(ellipseIn: CGRect(x: 8, y: 9.3, width: 9, height: 1.6)), with: .color(.white.opacity(0.6)))
        }
        // thigh and elbow creases give the bean some anatomy
        var thigh = Path(); thigh.move(to: CGPoint(x: 6.0, y: 12.2)); thigh.addQuadCurve(to: CGPoint(x: 10.8, y: 16.9), control: CGPoint(x: 11.4, y: 12.4))
        stroke(&c, thigh, Self.crease.opacity(detail ? 0.6 : 0.8), detail ? 0.22 : 0.32)
        var elbow = Path(); elbow.move(to: CGPoint(x: 17.6, y: 13.4)); elbow.addQuadCurve(to: CGPoint(x: 15.6, y: 16.9), control: CGPoint(x: 15.6, y: 14.2))
        stroke(&c, elbow, Self.crease.opacity(detail ? 0.6 : 0.8), detail ? 0.2 : 0.28)
        if detail {
            // chest fluff and a few fur flicks along the back
            for (x, y) in [(20.4, 12.2), (20.0, 13.4), (19.4, 14.5)] as [(CGFloat, CGFloat)] {
                var f = Path(); f.move(to: CGPoint(x: x, y: y)); f.addQuadCurve(to: CGPoint(x: x + 0.5, y: y + 0.9), control: CGPoint(x: x + 0.6, y: y + 0.3))
                stroke(&c, f, Self.crease, 0.2)
            }
        }
    }

    private func drawHead(_ c: inout GraphicsContext, _ p: Pose) {
        // far ear tucked behind the skull
        ear(&c, anchor: CGPoint(x: -0.4, y: -3.9), angle: p.ear + 0.3, far: true)

        // open jaw sits behind the face
        let drop = p.mouth * 2.6
        if p.mouth > 0.05 {
            // lower jaw hinges open at the back of the mouth
            let hinge = CGPoint(x: 1.6, y: 2.7), ang = Double(p.mouth) * 0.62
            let tip = CGPoint(x: hinge.x + 4.6 * CGFloat(cos(ang)), y: hinge.y + 4.6 * CGFloat(sin(ang)))
            var cavity = Path()
            cavity.move(to: hinge)
            cavity.addLine(to: CGPoint(x: 6.9, y: 2.3))
            cavity.addQuadCurve(to: tip, control: CGPoint(x: tip.x + 1.0, y: (2.3 + tip.y) / 2))
            cavity.closeSubpath()
            c.fill(cavity, with: .color(Self.mouthC))
            let jaw = Path(roundedRect: CGRect(x: 0, y: -0.6, width: 4.9, height: 1.8), cornerRadius: 0.9)
                .applying(CGAffineTransform(rotationAngle: CGFloat(ang)).concatenating(.init(translationX: hinge.x, y: hinge.y)))
            blob(&c, jaw, furShading(hinge.y, tip.y + 1.2))
        }

        // skull + snout + cheek as one silhouette
        let face = Self.face(mouth: p.mouth)
        blob(&c, face, .radialGradient(Gradient(colors: [Self.fur, Self.fur, Color(white: 0.84)]),
                                       center: CGPoint(x: 0.6, y: -1.8), startRadius: 0, endRadius: 7.2))
        c.drawLayer { s in
            s.clip(to: face)
            spot(&s, -1.4, -3.7, 1.9, 1.4)
            spot(&s, -3.9, -0.6, 1.5, 1.4)
            spot(&s, -2.2, 3.2, 1.2, 1.0)
            // snout top highlight
            s.fill(Path(ellipseIn: CGRect(x: 2.6, y: -0.7, width: 3.4, height: 0.9)), with: .color(.white.opacity(0.8)))
        }
        if p.mouth > 0.05 && p.tongue > 0 {
            // tongue lolls out over the lower lip
            let top = 3.2 - min(p.mouth, 0.6) * 1.6 - 0.2
            let tl = 1.2 + p.tongue * 2.0 + drop * 0.3
            let tr = CGRect(x: 3.7, y: top, width: 2.2, height: tl)
            var tongue = Path()
            tongue.move(to: CGPoint(x: tr.minX, y: tr.minY))
            tongue.addLine(to: CGPoint(x: tr.maxX, y: tr.minY))
            tongue.addLine(to: CGPoint(x: tr.maxX, y: tr.maxY - 1.1))
            tongue.addQuadCurve(to: CGPoint(x: tr.minX, y: tr.maxY - 1.1), control: CGPoint(x: tr.midX, y: tr.maxY + 0.9))
            tongue.closeSubpath()
            blob(&c, tongue, .linearGradient(Gradient(colors: [Self.tongueC, Self.tongueDark]),
                                             startPoint: CGPoint(x: tr.minX, y: tr.minY), endPoint: CGPoint(x: tr.maxX, y: tr.maxY)),
                 line: Self.tongueDark)
            var mid = Path(); mid.move(to: CGPoint(x: tr.midX, y: tr.minY + 0.5)); mid.addLine(to: CGPoint(x: tr.midX, y: tr.maxY - 1.0))
            stroke(&c, mid, Self.tongueDark, 0.26)
            if detail { c.fill(Path(ellipseIn: CGRect(x: tr.minX + 0.35, y: tr.maxY - 1.4, width: 0.55, height: 0.38)), with: .color(.white.opacity(0.5))) }
        }

        // freckles where the whiskers grow
        for (x, y) in [(3.9, 1.0), (4.6, 1.3), (4.3, 0.6), (5.1, 0.9)] as [(CGFloat, CGFloat)] {
            c.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.34, height: 0.34)), with: .color(Color(white: 0.4)))
        }
        if detail {
            for i in 0..<3 { // cheek fluff
                let y = 1.4 + CGFloat(i) * 0.7
                var f = Path(); f.move(to: CGPoint(x: -3.0, y: y)); f.addQuadCurve(to: CGPoint(x: -2.0, y: y + 0.6), control: CGPoint(x: -2.9, y: y + 0.6))
                stroke(&c, f, Self.crease, 0.18)
            }
            var tuft = Path(); tuft.move(to: CGPoint(x: -0.6, y: -4.4)); tuft.addQuadCurve(to: CGPoint(x: 0.6, y: -4.9), control: CGPoint(x: -0.1, y: -5.1))
            tuft.addQuadCurve(to: CGPoint(x: 1.2, y: -4.2), control: CGPoint(x: 1.1, y: -4.9))
            stroke(&c, tuft, Self.line, 0.2)
        }

        if p.teeth {
            for x in stride(from: CGFloat(3.0), through: 6.0, by: 1.0) {
                var tooth = Path()
                tooth.move(to: CGPoint(x: x, y: 2.9)); tooth.addLine(to: CGPoint(x: x + 0.45, y: 4.0))
                tooth.addLine(to: CGPoint(x: x + 0.9, y: 2.9)); tooth.closeSubpath()
                blob(&c, tooth, .color(.white))
            }
            for dx in [0.0, 0.7] as [CGFloat] { // snarl wrinkles
                var w = Path(); w.move(to: CGPoint(x: 3.2 + dx, y: -0.2)); w.addQuadCurve(to: CGPoint(x: 4.4 + dx, y: -0.3), control: CGPoint(x: 3.8 + dx, y: 0.4))
                stroke(&c, w, Self.line, 0.32)
            }
        }
        if p.mouth <= 0.05 { // closed: little smile under the nose
            var m = Path()
            m.move(to: CGPoint(x: 6.6, y: 0.9))
            m.addLine(to: CGPoint(x: 6.5, y: 1.9))
            m.addQuadCurve(to: CGPoint(x: 4.0, y: 2.0), control: CGPoint(x: 5.4, y: 3.1))
            stroke(&c, m, Color(white: 0.3), 0.42)
        }

        // nose: soft rounded triangle with a wet highlight
        var n = Path()
        n.move(to: CGPoint(x: 5.8, y: -0.7))
        n.addQuadCurve(to: CGPoint(x: 8.2, y: -0.5), control: CGPoint(x: 7.2, y: -1.4))
        n.addQuadCurve(to: CGPoint(x: 6.8, y: 1.1), control: CGPoint(x: 8.4, y: 0.7))
        n.addQuadCurve(to: CGPoint(x: 5.8, y: -0.7), control: CGPoint(x: 5.6, y: 0.5))
        c.fill(n, with: .linearGradient(Gradient(colors: [Color(white: 0.3), Self.nose]), startPoint: CGPoint(x: 6.6, y: -1.2), endPoint: CGPoint(x: 7.2, y: 1)))
        c.fill(Path(ellipseIn: CGRect(x: 6.4, y: -0.95, width: 0.95, height: 0.5)), with: .color(.white.opacity(0.85)))
        if detail {
            var ns = Path(); ns.move(to: CGPoint(x: 7.5, y: 0.25)); ns.addQuadCurve(to: CGPoint(x: 8.0, y: -0.05), control: CGPoint(x: 7.9, y: 0.3))
            stroke(&c, ns, Color(white: 0.35), 0.16)
        }

        // eye
        let e = CGPoint(x: 1.7, y: -1.1)
        switch p.eyes {
        case .open, .wide:
            let big = p.eyes == .wide
            let w: CGFloat = big ? 2.75 : 2.45, h: CGFloat = big ? 3.15 : 2.85
            let r = CGRect(x: e.x - w / 2, y: e.y - h / 2, width: w, height: h)
            c.fill(Path(ellipseIn: r), with: .radialGradient(Gradient(colors: [Self.iris, Self.pupil]),
                                                             center: CGPoint(x: e.x, y: e.y + h * 0.18), startRadius: 0, endRadius: h * 0.55))
            c.fill(Path(ellipseIn: CGRect(x: e.x - w * 0.28, y: e.y - h * 0.24, width: w * 0.56, height: h * 0.56)), with: .color(Self.pupil.opacity(0.8)))
            let hl: CGFloat = big ? 1.15 : 1.0
            c.fill(Path(ellipseIn: CGRect(x: e.x + w * 0.02, y: e.y - h * 0.4, width: hl, height: hl)), with: .color(.white))
            c.fill(Path(ellipseIn: CGRect(x: e.x - w * 0.36, y: e.y + h * 0.14, width: 0.45, height: 0.45)), with: .color(.white.opacity(0.85)))
            if p.brows < -0.6 { // pleading puppy eyes: extra sparkle
                c.fill(Path(ellipseIn: CGRect(x: e.x + w * 0.2, y: e.y + h * 0.18, width: 0.32, height: 0.32)), with: .color(.white.opacity(0.9)))
            }
            if detail {
                var lid = Path(); lid.move(to: CGPoint(x: r.minX - 0.15, y: e.y - h * 0.15))
                lid.addQuadCurve(to: CGPoint(x: r.maxX + 0.2, y: e.y - h * 0.2), control: CGPoint(x: e.x, y: r.minY - 0.75))
                stroke(&c, lid, Self.pupil, 0.32)
                var lash = Path(); lash.move(to: CGPoint(x: r.maxX + 0.1, y: e.y - h * 0.22)); lash.addLine(to: CGPoint(x: r.maxX + 0.6, y: e.y - h * 0.42))
                stroke(&c, lash, Self.pupil, 0.22)
            }
        case .blink:
            var l = Path(); l.move(to: CGPoint(x: e.x - 1.15, y: e.y + 0.1))
            l.addQuadCurve(to: CGPoint(x: e.x + 1.15, y: e.y + 0.1), control: CGPoint(x: e.x, y: e.y + 1.0))
            stroke(&c, l, Self.pupil, 0.55)
        case .bliss:
            var l = Path(); l.move(to: CGPoint(x: e.x - 1.15, y: e.y + 0.5))
            l.addQuadCurve(to: CGPoint(x: e.x + 1.15, y: e.y + 0.5), control: CGPoint(x: e.x, y: e.y - 1.1))
            stroke(&c, l, Self.pupil, 0.6)
        }
        // cheek blush: always a hint, rosy when blissful
        let rosy = p.eyes == .bliss
        c.fill(Path(ellipseIn: CGRect(x: 0.6, y: 0.9, width: 2.4, height: 1.2)),
               with: .radialGradient(Gradient(colors: [Self.blush.opacity(rosy ? 0.75 : 0.32), Self.blush.opacity(0)]),
                                     center: CGPoint(x: 1.8, y: 1.5), startRadius: 0, endRadius: 1.3))
        if abs(p.brows) > 0.1 {
            var b = Path()
            b.move(to: CGPoint(x: e.x - 0.9, y: -3.4 - 0.3 * p.brows))
            b.addQuadCurve(to: CGPoint(x: e.x + 0.9, y: -3.4 + 0.45 * p.brows), control: CGPoint(x: e.x, y: -3.8 + 0.1 * p.brows))
            stroke(&c, b, Self.pupil, detail ? 0.36 : 0.45)
        }

        // near ear, in front
        ear(&c, anchor: CGPoint(x: -2.2, y: -3.4), angle: p.ear, far: false)
    }

    /// Floppy velvet ear hanging from `anchor`; angle swings it back/up.
    private func ear(_ c: inout GraphicsContext, anchor: CGPoint, angle: Double, far: Bool) {
        var e = Path()
        e.move(to: CGPoint(x: -0.2, y: 0))
        e.addCurve(to: CGPoint(x: -2.1, y: 6.4), control1: CGPoint(x: -2.0, y: 0.9), control2: CGPoint(x: -2.9, y: 4.6))
        e.addQuadCurve(to: CGPoint(x: 1.3, y: 6.3), control: CGPoint(x: -0.4, y: 8.3))
        e.addCurve(to: CGPoint(x: 1.8, y: 0.1), control1: CGPoint(x: 2.3, y: 4.4), control2: CGPoint(x: 2.6, y: 1.3))
        e.closeSubpath()
        let s: CGFloat = far ? 0.88 : 1
        let tr = CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(angle)))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
        let path = e.applying(tr)
        if far {
            c.fill(path, with: .color(Color(white: 0.04)))
            return
        }
        blob(&c, path, .linearGradient(Gradient(colors: [Self.earTop, Self.earC, Self.earC]),
                                       startPoint: CGPoint(x: anchor.x, y: anchor.y), endPoint: CGPoint(x: anchor.x, y: anchor.y + 6)),
             line: Color(white: 0.38))
        var fold = Path()
        fold.move(to: CGPoint(x: 0.3, y: 1.0))
        fold.addQuadCurve(to: CGPoint(x: -0.5, y: 5.4), control: CGPoint(x: -0.9, y: 3.0))
        stroke(&c, fold.applying(tr), Color(white: 0.3), detail ? 0.3 : 0.4)
        if detail {
            var sheen = Path()
            sheen.move(to: CGPoint(x: 0.9, y: 1.2)); sheen.addQuadCurve(to: CGPoint(x: 0.8, y: 4.8), control: CGPoint(x: 1.5, y: 3.0))
            stroke(&c, sheen.applying(tr), Color(white: 0.34), 0.3)
        }
    }
}

// MARK: - Scenes

/// Trots across the closed island, slips behind the notch, pops out the other
/// side, eases to a stop, sits, breathes, tilts its head. Then the island folds.
struct DogWalkView: View {
    let start: Date
    let height: CGFloat
    static let walk: TimeInterval = 3.8
    static let sit: TimeInterval = 2.4
    static var total: TimeInterval { walk + sit }

    @Environment(\.renderPaused) private var paused

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: paused)) { ctx in
            // Paused (Reduce Motion): no walk, he is simply sitting at the end of it.
            let t = paused ? Self.walk + 0.6 : ctx.date.timeIntervalSince(start)
            GeometryReader { g in
                let w = g.size.width, s = Dog.small, dw = Dog.size.width * s
                let p = min(t / Self.walk, 1)
                // cruise, then decelerate into the sit
                let eased = p < 0.75 ? p * 0.88 / 0.75 : 0.88 + (1 - pow(1 - (p - 0.75) / 0.25, 2)) * 0.12
                let x = -dw + (w - 4) * eased
                Dog(t: t, mood: t < Self.walk ? .walk : .sit, scale: s)
                    .position(x: x + dw / 2, y: g.size.height - Dog.size.height * s / 2 - 1)
            }
        }
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Trots in beside the equalizer and vibes to the music; when paused it looks up, puzzled.
struct DancingDog: View {
    let start: Date
    let playing: Bool
    let tint: Color
    @Environment(\.renderPaused) private var paused

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: paused)) { ctx in
            let t = paused ? 1.0 : ctx.date.timeIntervalSince(start) // paused: already in place
            let entering = t < 0.7
            ZStack(alignment: .bottomLeading) {
                Dog(t: t, mood: entering ? .walk : (playing ? .dance : .curious), scale: Dog.small)
                    .offset(x: entering ? CGFloat(1 - t / 0.7) * -30 : 0)
                if !entering {
                    if playing {
                        ForEach(0..<2, id: \.self) { i in
                            let phase = (t * 0.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                            Text(i == 0 ? "♪" : "♫")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(tint)
                                .opacity(1 - phase)
                                .offset(x: 17 + CGFloat(i) * 5 + CGFloat(sin(t * 3 + Double(i))) * 2,
                                        y: -14 - CGFloat(phase) * 9)
                        }
                    } else {
                        Text("?").font(.system(size: 8, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .offset(x: 19, y: -11 + CGFloat(sin(t * 2.5)) * 1)
                    }
                }
            }
            .frame(width: 32, height: 26, alignment: .bottomLeading)
        }
    }
}

/// Banner pup. `.bark` hops and woofs (breaks, nudges), `.alert` perks up (meetings),
/// `.angry` growls and trembles (guard alarm).
struct BarkingDog: View {
    var mood: DogMood = .bark
    @Environment(\.renderPaused) private var paused

    var body: some View {
        if [.sleep, .hungry, .eat, .play, .happy].contains(mood) {
            PupStage(mood: mood, scale: Dog.small).frame(width: 42, height: 32)
        } else {
            barking
        }
    }

    private var barking: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let hop: CGFloat = mood == .bark ? CGFloat(max(0, sin(t * 2.25))) * 4.5 : 0
            ZStack(alignment: .topTrailing) {
                Dog(t: t, mood: mood, scale: Dog.small).offset(y: 7 - hop)
                bubble(t)
            }
            .frame(width: 42, height: 32)
        }
    }

    @ViewBuilder private func bubble(_ t: Double) -> some View {
        switch mood {
        case .bark where sin(t * 4.5) > 0.25:
            label("woof!", .orange)
        case .angry:
            label("grrr", .red).offset(x: CGFloat(sin(t * 61)) * 0.4)
        case .alert where pulse(t, period: 1.6, on: 1.0) > 0.2:
            label("!", .yellow)
        default:
            EmptyView()
        }
    }

    private func label(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 7.5, weight: .heavy, design: .rounded))
            .foregroundStyle(.black).padding(.horizontal, 3).padding(.vertical, 1)
            .background(c, in: Capsule())
            .offset(x: 6, y: -8)
    }
}

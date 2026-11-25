import AppKit
import QuartzCore
import SwiftUI

/// What plays when something activates on the island (a banner arrives).
/// burst = full-screen shock out of the notch + border glow; border = only the notch outline glows.
enum FlairMode: String, CaseIterable { case burst, border, off }

/// One activation flash: the island's border glow watches `seq`.
struct FlairEvent: Equatable {
    let seq: Int
    let tint: Color
}

enum FlairPalette {
    /// Electric colours for activities that don't carry one (plain white/grey tints).
    static let vivid: [NSColor] = [
        NSColor(srgbRed: 0.20, green: 0.85, blue: 1.00, alpha: 1),   // cyan
        NSColor(srgbRed: 1.00, green: 0.25, blue: 0.75, alpha: 1),   // magenta
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.10, alpha: 1),   // orange
        NSColor(srgbRed: 0.55, green: 0.40, blue: 1.00, alpha: 1),   // violet
    ]
    private static var next = 0

    /// The activity's tint when it has real colour, else the next vivid one.
    static func pick(_ c: Color) -> NSColor {
        if let n = NSColor(c).usingColorSpace(.sRGB), n.saturationComponent > 0.25, n.brightnessComponent > 0.3 { return n }
        next = (next + 1) % vivid.count
        return vivid[next]
    }
}

/// The burst's look. IslandModel.flairStyle picks one per kind of event so each kind feels different.
enum BurstStyle: String, CaseIterable {
    case shockwave, lightning, edge, confetti, aurora

    var label: String {
        switch self {
        case .shockwave: "Shockwave"
        case .lightning: "Lightning"
        case .edge: "Edge race"
        case .confetti: "Confetti"
        case .aurora: "Aurora"
        }
    }

    var duration: CFTimeInterval {
        switch self {
        case .shockwave: 1.4
        case .lightning: 1.2
        case .edge: 1.3
        case .confetti: 2.2
        case .aurora: 1.8
        }
    }

    /// Setting value: "auto" (the event's own style), "random", or a style's raw value.
    static func resolve(_ setting: String, auto: BurstStyle) -> BurstStyle {
        switch setting {
        case "random": return allCases.randomElement()!
        case "auto": return auto
        default: return BurstStyle(rawValue: setting) ?? auto
        }
    }
}

/// Full-screen one-shot burst out of the notch, 1-2 s, all Core Animation (GPU, no per-frame Swift).
/// Six looks (BurstStyle). Click-through, never in screen shares (sharingType .none).
final class BurstOverlay {
    static let shared = BurstOverlay()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    /// Debug previews only (island://flair?share=1): let screencapture see the burst.
    var shareable = false

    func fire(style: BurstStyle, tint: NSColor, notch: CGRect, screen: NSScreen) {
        let p = panel ?? makePanel()
        panel = p
        p.setFrame(screen.frame, display: false)
        p.sharingType = shareable || ScreenShare.visible ? .readOnly : .none
        guard let root = p.contentView?.layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let b = CGRect(origin: .zero, size: screen.frame.size)
        // Notch in layer coords (origin bottom-left of this screen).
        let n = CGRect(x: notch.minX - screen.frame.minX, y: notch.minY - screen.frame.minY,
                       width: notch.width, height: notch.height)
        let src = CGPoint(x: n.midX, y: b.maxY)   // top centre: everything pours out of the notch
        let now = CACurrentMediaTime()

        let layers: [CALayer]
        switch style {
        case .shockwave:
            layers = [wash(b, src, tint, now)] + (0..<3).map { ring(b, src, n, tint, $0, now) }
                + [sparks(n, tint, now), sweep(b, tint, now)]
        case .lightning: layers = lightning(b, src, n, tint, now)
        case .edge: layers = edgeRace(b, src, tint, now)
        case .confetti: layers = confetti(n, tint, now)
        case .aurora: layers = aurora(b, src, tint, now)
        }
        layers.forEach { root.addSublayer($0) }

        p.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + style.duration + 0.15, execute: w)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)   // just under the island (+3)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.sharingType = .none
        let v = NSView()
        v.wantsLayer = true
        p.contentView = v
        return p
    }

    // MARK: layers

    /// Radial colour wash that floods down from the notch and fades.
    private func wash(_ b: CGRect, _ src: CGPoint, _ c: NSColor, _ t0: CFTimeInterval) -> CALayer {
        let r = hypot(b.width, b.height) * 1.1
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [c.withAlphaComponent(0.42).cgColor, c.withAlphaComponent(0.14).cgColor, NSColor.clear.cgColor]
        g.locations = [0, 0.35, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        g.position = src
        g.opacity = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.04; scale.toValue = 1
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.9, 0.2, 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0.55, 0]
        fade.keyTimes = [0, 0.1, 0.45, 1]
        return animate(g, [scale, fade], t0, BurstStyle.shockwave.duration)
    }

    /// Glowing elliptical shock ring born at the notch outline, racing past the screen edges.
    private func ring(_ b: CGRect, _ src: CGPoint, _ n: CGRect, _ c: NSColor, _ i: Int, _ t0: CFTimeInterval) -> CALayer {
        let s = CAShapeLayer()
        s.frame = b
        s.fillColor = nil
        s.strokeColor = (i == 0 ? c.blended(withFraction: 0.35, of: .white) ?? c : c).cgColor
        s.lineWidth = [3.0, 2.0, 1.4][i]
        s.shadowColor = c.cgColor
        s.shadowRadius = 14
        s.shadowOpacity = 1
        s.shadowOffset = .zero
        s.opacity = 0
        func ellipse(_ w: CGFloat, _ h: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: src.x - w / 2, y: src.y - h / 2, width: w, height: h), transform: nil)
        }
        let start = ellipse(n.width, n.height * 2)
        let end = ellipse(b.width * 2.3, b.height * 2.4)
        s.path = start
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = start; grow.toValue = end
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0.8, 0]
        fade.keyTimes = [0, 0.06, 0.5, 1]
        return animate(s, [grow, fade], t0 + Double(i) * 0.11, 1.0)
    }

    /// Spark spray out of the notch's lower edge, falling with a little gravity.
    private func sparks(_ n: CGRect, _ c: NSColor, _ t0: CFTimeInterval) -> CALayer {
        let e = CAEmitterLayer()
        e.emitterPosition = CGPoint(x: n.midX, y: n.minY + 2)
        e.emitterShape = .line
        e.emitterSize = CGSize(width: n.width * 0.8, height: 1)
        e.renderMode = .additive
        e.beginTime = t0   // no pre-simulated particles
        let cell = CAEmitterCell()
        cell.contents = Self.dot
        cell.birthRate = 2200
        cell.lifetime = 1.0
        cell.lifetimeRange = 0.35
        cell.velocity = 950
        cell.velocityRange = 520
        cell.emissionLongitude = -.pi / 2   // down (layer y grows upward)
        cell.emissionRange = .pi * 0.42
        cell.yAcceleration = -650
        cell.scale = 0.28
        cell.scaleRange = 0.14
        cell.scaleSpeed = -0.1
        cell.alphaSpeed = -0.95
        cell.color = c.cgColor
        cell.redRange = 0.15; cell.greenRange = 0.15; cell.blueRange = 0.15
        e.emitterCells = [cell]
        // A short puff: ~180 sparks, then let them fly out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { e.birthRate = 0 }
        return e
    }

    /// Thin bright line with a glow sweeping the whole screen top to bottom.
    private func sweep(_ b: CGRect, _ c: NSColor, _ t0: CFTimeInterval) -> CALayer {
        let g = CAGradientLayer()
        g.colors = [NSColor.clear.cgColor, c.withAlphaComponent(0.9).cgColor, NSColor.white.cgColor,
                    c.withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        g.locations = [0, 0.3, 0.5, 0.7, 1]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.bounds = CGRect(x: 0, y: 0, width: b.width, height: 2)
        g.position = CGPoint(x: b.midX, y: b.maxY)
        g.shadowColor = c.cgColor
        g.shadowRadius = 10
        g.shadowOpacity = 1
        g.shadowOffset = .zero
        g.opacity = 0
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = b.maxY; move.toValue = b.minY - 20
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0.7, 0]
        fade.keyTimes = [0, 0.1, 0.7, 1]
        return animate(g, [move, fade], t0 + 0.05, 0.85)
    }

    // MARK: lightning

    /// Jagged branching bolts crackle out of the notch, the screen flickers, then a second strike.
    private func lightning(_ b: CGRect, _ src: CGPoint, _ n: CGRect, _ c: NSColor, _ t0: CFTimeInterval) -> [CALayer] {
        var out: [CALayer] = []
        let f = CALayer()
        f.frame = b
        f.backgroundColor = (c.blended(withFraction: 0.5, of: .white) ?? c).withAlphaComponent(1).cgColor
        f.opacity = 0
        let flick = CAKeyframeAnimation(keyPath: "opacity")
        flick.values = [0, 0.22, 0.02, 0.14, 0, 0.18, 0]
        flick.keyTimes = [0, 0.04, 0.12, 0.2, 0.3, 0.36, 0.55]
        out.append(animate(f, [flick], t0, 1.0))
        let origin = CGPoint(x: src.x, y: b.maxY - n.height)
        for i in 0..<6 {
            let strike2 = i >= 4
            let target = CGPoint(x: CGFloat.random(in: b.width * 0.05...b.width * 0.95),
                                 y: CGFloat.random(in: b.height * 0.05...b.height * 0.55))
            let path = CGMutablePath()
            let main = Self.bolt(origin, target, rough: 0.22)
            path.addLines(between: main)
            for _ in 0..<2 {   // side branches
                let k = Int.random(in: main.count / 4..<max(main.count / 4 + 1, main.count * 3 / 4))
                let from = main[k]
                let ang = atan2(target.y - from.y, target.x - from.x) + Double.random(in: -0.9...0.9)
                let len = hypot(target.x - from.x, target.y - from.y) * CGFloat.random(in: 0.25...0.5)
                path.addLines(between: Self.bolt(from, CGPoint(x: from.x + cos(ang) * len, y: from.y + sin(ang) * len), rough: 0.25))
            }
            for core in [false, true] {
                let s = CAShapeLayer()
                s.path = path
                s.fillColor = nil
                s.lineJoin = .miter
                s.strokeColor = core ? NSColor.white.cgColor : c.cgColor
                s.lineWidth = core ? 1.6 : 6
                if !core { s.shadowColor = c.cgColor; s.shadowRadius = 18; s.shadowOpacity = 1; s.shadowOffset = .zero }
                s.opacity = 0
                let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
                draw.values = [0, 1, 1]; draw.keyTimes = [0, 0.14, 1]
                let blink = CAKeyframeAnimation(keyPath: "opacity")
                blink.values = core ? [1, 1, 0.3, 1, 0.5, 0.9, 0] : [0.9, 0.9, 0.2, 0.8, 0.3, 0.6, 0]
                blink.keyTimes = [0, 0.14, 0.24, 0.34, 0.48, 0.62, 1]
                out.append(animate(s, [draw, blink], t0 + (strike2 ? 0.34 : Double(i) * 0.03), 0.7))
            }
        }
        return out
    }

    /// Midpoint-displacement zig-zag between two points.
    private static func bolt(_ a: CGPoint, _ z: CGPoint, rough: CGFloat) -> [CGPoint] {
        var pts = [a, z]
        var disp = hypot(z.x - a.x, z.y - a.y) * rough
        for _ in 0..<6 {
            var next: [CGPoint] = [pts[0]]
            for i in 1..<pts.count {
                let p = pts[i - 1], q = pts[i]
                let dx = q.x - p.x, dy = q.y - p.y, len = max(hypot(dx, dy), 0.001)
                let off = CGFloat.random(in: -disp...disp)
                next.append(CGPoint(x: (p.x + q.x) / 2 - dy / len * off, y: (p.y + q.y) / 2 + dx / len * off))
                next.append(q)
            }
            pts = next
            disp *= 0.55
        }
        return pts
    }

    // MARK: edge race

    /// Two comets leave the notch and race around the screen edges, meeting at the bottom centre.
    private func edgeRace(_ b: CGRect, _ src: CGPoint, _ c: NSColor, _ t0: CFTimeInterval) -> [CALayer] {
        let i: CGFloat = 2.5, r: CGFloat = 12
        var out: [CALayer] = []
        for side in [-1.0, 1.0] {
            let xEdge = side < 0 ? b.minX + i : b.maxX - i
            let path = CGMutablePath()
            path.move(to: CGPoint(x: src.x, y: b.maxY - i))
            path.addArc(tangent1End: CGPoint(x: xEdge, y: b.maxY - i), tangent2End: CGPoint(x: xEdge, y: b.midY), radius: r)
            path.addArc(tangent1End: CGPoint(x: xEdge, y: b.minY + i), tangent2End: CGPoint(x: b.midX, y: b.minY + i), radius: r)
            path.addLine(to: CGPoint(x: b.midX, y: b.minY + i))
            for core in [false, true] {
                let s = CAShapeLayer()
                s.path = path
                s.fillColor = nil
                s.lineCap = .round
                s.strokeColor = core ? (c.blended(withFraction: 0.55, of: .white) ?? c).cgColor : c.cgColor
                s.lineWidth = core ? 3 : 9
                if !core { s.shadowColor = c.cgColor; s.shadowRadius = 24; s.shadowOpacity = 1; s.shadowOffset = .zero }
                s.strokeEnd = 0
                let ease = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                let end = CAKeyframeAnimation(keyPath: "strokeEnd")
                end.values = [0, 1, 1]; end.keyTimes = [0, 0.62, 1]; end.timingFunctions = [ease, ease]
                let start = CAKeyframeAnimation(keyPath: "strokeStart")
                start.values = [0, 0, 1]; start.keyTimes = [0, 0.28, 1]; start.timingFunctions = [ease, ease]
                out.append(animate(s, [end, start], t0, 1.15))
            }
        }
        // Where they meet: a soft flare at the bottom centre.
        out.append(flash(CGPoint(x: b.midX, y: b.minY), c, t0 + 0.62, radius: 320, peak: 0.8, dur: 0.6))
        out.append(flash(src, c, t0, radius: 200, peak: 0.7, dur: 0.45))
        return out
    }

    // MARK: confetti

    /// Spinning paper bits blast out of the notch and tumble down the screen.
    private func confetti(_ n: CGRect, _ c: NSColor, _ t0: CFTimeInterval) -> [CALayer] {
        let e = CAEmitterLayer()
        e.emitterPosition = CGPoint(x: n.midX, y: n.minY)
        e.emitterShape = .line
        e.emitterSize = CGSize(width: n.width * 0.7, height: 1)
        e.beginTime = t0
        let colors = [c] + FlairPalette.vivid + [NSColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1), .white]
        e.emitterCells = colors.flatMap { col in [Self.paper, Self.dot].compactMap { img -> CAEmitterCell? in
            guard let img else { return nil }
            let cell = CAEmitterCell()
            cell.contents = img
            cell.birthRate = 160
            cell.lifetime = 2.2
            cell.lifetimeRange = 0.4
            cell.velocity = 900
            cell.velocityRange = 450
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi * 0.5
            cell.yAcceleration = -1100
            cell.xAcceleration = CGFloat.random(in: -60...60)
            cell.spin = 4; cell.spinRange = 10
            cell.scale = img === Self.dot ? 0.3 : 0.7
            cell.scaleRange = 0.25
            cell.alphaSpeed = -0.35
            cell.color = col.cgColor
            return cell
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { e.birthRate = 0 }
        return [flash(CGPoint(x: n.midX, y: n.maxY), c, t0, radius: 220, peak: 0.6, dur: 0.4), e]
    }

    // MARK: aurora

    /// Light curtains pour down from the notch region and sway, in hues around the tint.
    private func aurora(_ b: CGRect, _ src: CGPoint, _ c: NSColor, _ t0: CFTimeInterval) -> [CALayer] {
        var out: [CALayer] = []
        let base = c.usingColorSpace(.sRGB) ?? c
        let count = 11
        for k in 0..<count {
            let offset = CGFloat(k - count / 2)
            let hue = (base.hueComponent + offset * 0.025 + 1).truncatingRemainder(dividingBy: 1)
            let col = NSColor(hue: hue, saturation: max(base.saturationComponent, 0.6), brightness: 1, alpha: 1)
            let w = CGFloat.random(in: 70...200)
            let g = CAGradientLayer()
            g.colors = [col.withAlphaComponent(0.7).cgColor, col.withAlphaComponent(0.28).cgColor, NSColor.clear.cgColor]
            g.locations = [0, 0.45, 1]
            g.startPoint = CGPoint(x: 0.5, y: 1); g.endPoint = CGPoint(x: 0.5, y: 0)
            g.bounds = CGRect(x: 0, y: 0, width: w, height: b.height * CGFloat.random(in: 0.7...1.05))
            g.anchorPoint = CGPoint(x: 0.5, y: 1)   // hang from the top edge
            let x = src.x + offset * b.width / CGFloat(count) * 0.9 + CGFloat.random(in: -30...30)
            g.position = CGPoint(x: x, y: b.maxY)
            g.compositingFilter = "screenBlendMode"
            let soft = CAGradientLayer()   // feather the ribbon's sides
            soft.frame = g.bounds
            soft.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
            soft.startPoint = CGPoint(x: 0, y: 0.5); soft.endPoint = CGPoint(x: 1, y: 0.5)
            g.mask = soft
            g.opacity = 0
            let drop = CABasicAnimation(keyPath: "transform.scale.y")
            drop.fromValue = 0.02; drop.toValue = 1
            drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
            let sway = CAKeyframeAnimation(keyPath: "position.x")
            let amp = CGFloat.random(in: 20...55)
            sway.values = [x, x + amp, x - amp * 0.6, x + amp * 0.3]
            sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0.75, 0]; fade.keyTimes = [0, 0.15, 0.6, 1]
            out.append(animate(g, [drop, sway, fade], t0 + abs(Double(offset)) * 0.04, 1.6))
        }
        return out
    }

    /// Short radial glow pulse (used as the "ignition" at the notch and as impact flares).
    private func flash(_ at: CGPoint, _ c: NSColor, _ t0: CFTimeInterval, radius: CGFloat, peak: Float, dur: CFTimeInterval) -> CALayer {
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [(c.blended(withFraction: 0.4, of: .white) ?? c).cgColor, c.withAlphaComponent(0.35).cgColor, NSColor.clear.cgColor]
        g.locations = [0, 0.35, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
        g.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        g.position = at
        g.opacity = 0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, NSNumber(value: peak), 0]; fade.keyTimes = [0, 0.2, 1]
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3; grow.toValue = 1.1
        return animate(g, [fade, grow], t0, dur)
    }

    /// Confetti paper strip, drawn once.
    private static let paper: CGImage? = {
        guard let ctx = CGContext(data: nil, width: 14, height: 7, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 14, height: 7))
        return ctx.makeImage()
    }()

    private func animate(_ l: CALayer, _ anims: [CAAnimation], _ begin: CFTimeInterval, _ dur: CFTimeInterval) -> CALayer {
        let group = CAAnimationGroup()
        group.animations = anims
        group.duration = dur
        group.beginTime = begin
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        anims.forEach { $0.duration = dur }
        l.add(group, forKey: "flair")
        return l
    }

    /// Soft round spark, drawn once.
    private static let dot: CGImage? = {
        let s = 32
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 1]) else { return nil }
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(s / 2), options: [])
        return ctx.makeImage()
    }()
}

/// The island outline lighting up: a rotating gradient stroke with a soft glow, ~1.8 s, then gone.
struct NotchGlow: View {
    let event: FlairEvent
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    @State private var start = Date()
    static let life: Double = 1.8

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            let k = min(max(t / Self.life, 0), 1)
            // Fast in, hold, ease out.
            let env = k < 0.12 ? k / 0.12 : (k < 0.55 ? 1 : max(0, 1 - (k - 0.55) / 0.45))
            let grad = AngularGradient(colors: [event.tint, .white, event.tint.opacity(0.1), event.tint, .white.opacity(0.6), event.tint],
                                       center: .center, angle: .degrees(t * 420))
            let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
            ZStack {
                shape.stroke(grad, lineWidth: 6).blur(radius: 7).opacity(0.9 * env)
                shape.stroke(grad, lineWidth: 1.6).opacity(env)
            }
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }
}

/// Open-island backdrop: black (the closed island must melt into the hardware notch), and when open
/// a soft accent glow rising from the bottom, a faint top sheen and a hairline edge.
struct IslandBackdrop: View {
    let open: Bool
    let accent: Color?
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    /// Cosmos scene for this time of day and season (SkyScene), drawn at one fixed size
    /// and scaled, so the open/close spring never re-renders it.
    var sky: Bool = true
    var skySize = CGSize(width: 668, height: 214)
    /// Extra darkening over the scene: light on Home (artwork + big text), heavier on text-dense tabs.
    var dim: Double = 0.12

    var body: some View {
        ZStack {
            Color.black
            if open {
                if sky, let img = SkyScene.image(size: skySize, scale: NSScreen.main?.backingScaleFactor ?? 2) {
                    Image(decorative: img, scale: NSScreen.main?.backingScaleFactor ?? 2)
                        .resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                        .transition(.opacity)
                    Color.black.opacity(dim)   // highlights are already capped in SkyScene.readable
                    // Soft shade behind the header icon row.
                    LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.24))
                }
                let a = accent ?? Color(red: 0.32, green: 0.30, blue: 1.0)
                RadialGradient(colors: [a.opacity(sky ? (accent == nil ? 0 : 0.22) : 0.30), a.opacity(0.06), .clear],
                               center: UnitPoint(x: 0.5, y: 1.15), startRadius: 0, endRadius: 320)
                RadialGradient(colors: [a.opacity(sky ? 0 : 0.10), .clear],
                               center: UnitPoint(x: 0.12, y: 0.05), startRadius: 0, endRadius: 220)
                LinearGradient(colors: [.white.opacity(0.05), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                    .stroke(LinearGradient(colors: [.white.opacity(0.02), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: accent)
        .animation(.easeInOut(duration: 0.25), value: dim)
    }
}

/// Mean colour of the song artwork, lifted so it reads as a glow. Cached per image.
enum ArtworkTint {
    private static var cache: (ObjectIdentifier, Color?)?
    private static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    static func of(_ img: NSImage?) -> Color? {
        guard let img else { return nil }
        let id = ObjectIdentifier(img)
        if let c = cache, c.0 == id { return c.1 }
        var out: Color?
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let ci = CIImage(cgImage: cg)
            if let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
               let px = f.outputImage {
                var rgba = [UInt8](repeating: 0, count: 4)
                ctx.render(px, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                let n = NSColor(srgbRed: CGFloat(rgba[0]) / 255, green: CGFloat(rgba[1]) / 255, blue: CGFloat(rgba[2]) / 255, alpha: 1)
                // Lift: full brightness, a floor on saturation, so dull covers still glow.
                out = Color(hue: n.hueComponent, saturation: max(n.saturationComponent, 0.45), brightness: 1)
            }
        }
        cache = (id, out)
        return out
    }
}

struct BlurDissolve: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

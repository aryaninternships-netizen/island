import AppKit
import SwiftUI

// Face-unlock animation at the notch, drawn on top of the real lock screen.
//
// Lock-screen visibility uses private SkyLight window-server calls, adapted from Glance
// (https://github.com/jonnyoo/glance, MIT, (c) 2026 Jonathan Zhou), which adapted them from
// Lakr233/SkyLightWindow (MIT). Private API: a macOS update can break it; then `shared` is nil and
// face unlock still works, just without the animation.

/// Live readouts from the scan, for the lab HUD.
struct ScanTelemetry: Equatable {
    var match: Float? // face distance to your profile (lower = closer)
    var threshold: Float = 0.6
    var votes = 0 // of 3
    var life = "—" // BLINK / PARALLAX / —
    var spoof = "CLEAR" // CLEAR / GLARE / DEVICE
    var frames = 0
    var face: CGPoint? // face centre, 0...1
}

/// The scan's visible state.
enum FaceScanPhase: Equatable {
    case hidden
    case scanning
    case matched(String) // name
    case failed(String) // reason
}

final class SkyLightSpace {
    static let shared: SkyLightSpace? = SkyLightSpace()

    private typealias MainConn = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let conn: Int32
    private let space: Int32
    private let add: AddWindows
    private let remove: RemoveWindows

    private init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let a = dlsym(h, "SLSMainConnectionID"), let b = dlsym(h, "SLSSpaceCreate"),
              let c = dlsym(h, "SLSSpaceSetAbsoluteLevel"), let d = dlsym(h, "SLSShowSpaces"),
              let e = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces"), let f = dlsym(h, "SLSRemoveWindowsFromSpaces")
        else { return nil }
        add = unsafeBitCast(e, to: AddWindows.self)
        remove = unsafeBitCast(f, to: RemoveWindows.self)
        conn = unsafeBitCast(a, to: MainConn.self)()
        // Flag 1 matters: other values make Finder draw desktop icons into the space.
        space = unsafeBitCast(b, to: SpaceCreate.self)(conn, 1, 0)
        _ = unsafeBitCast(c, to: SetLevel.self)(conn, space, 400) // Notification Centre's level at the lock screen
        _ = unsafeBitCast(d, to: ShowSpaces.self)(conn, [space] as CFArray)
    }

    /// Only while actually locked.
    func lift(_ w: NSWindow) { _ = add(conn, space, [w.windowNumber] as CFArray, 7) }
    func drop(_ w: NSWindow) { _ = remove(conn, [w.windowNumber] as CFArray, [space] as CFArray) }
}

/// Owns the notch window; shows it (lifted above the lock screen when locked) per phase.
final class LockFaceOverlay: ObservableObject {
    @Published var phase: FaceScanPhase = .hidden
    /// 0...1 how far recognition has got (scanning only), and a nudge for the user.
    @Published private(set) var progress: Double = 0
    @Published private(set) var hint: String?
    @Published private(set) var telemetry = ScanTelemetry()
    private var lastTelemetry = Date.distantPast

    func update(telemetry t: ScanTelemetry) {
        guard Date().timeIntervalSince(lastTelemetry) > 0.12 || t.spoof != telemetry.spoof || t.votes != telemetry.votes else { return }
        lastTelemetry = Date()
        telemetry = t
    }
    private var window: NSPanel?
    private var lifted = false
    private var hideWork: DispatchWorkItem?

    static let size = CGSize(width: 340, height: 120)

    func update(progress p: Double, hint h: String?) {
        guard phase == .scanning else { return }
        if abs(p - progress) > 0.03 { withAnimation(.easeOut(duration: 0.35)) { progress = p } }
        if h != hint { withAnimation(.easeOut(duration: 0.2)) { hint = h } }
    }

    func set(_ p: FaceScanPhase, locked: Bool) {
        hideWork?.cancel()
        if p == .scanning { progress = 0.04; hint = nil; telemetry = ScanTelemetry() }
        if p == .hidden { hide(); return }
        show(locked: locked)
        let was = phase
        withAnimation(A11y.motion(.spring(response: 0.45, dampingFraction: 0.78))) { phase = p }
        if p != was { Self.speak(p) }
        // Results linger briefly, then fold away.
        if case .scanning = p { return }
        let w = DispatchWorkItem { [weak self] in self?.set(.hidden, locked: locked) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
    }

    /// Unlocked, the island renders the scan itself (one seamless shape); the window is only
    /// for the lock screen, where the island can't appear.
    var shownInIsland: Bool { phase != .hidden && !inWindow }
    private var inWindow = false

    private func show(locked: Bool) {
        guard locked else {
            inWindow = false
            if let w = window { if lifted { SkyLightSpace.shared?.drop(w); lifted = false }; w.orderOut(nil) }
            return
        }
        inWindow = true
        let w = window ?? make()
        position(w)
        w.orderFrontRegardless()
        if locked, !lifted, let s = SkyLightSpace.shared { s.lift(w); lifted = true }
    }

    private func hide() {
        withAnimation(.easeIn(duration: 0.2)) { phase = .hidden }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.phase == .hidden, let w = self.window else { return }
            if self.lifted { SkyLightSpace.shared?.drop(w); self.lifted = false }
            w.orderOut(nil)
            self.inWindow = false
        }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.sharingType = .none
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let notch = Self.notchSize()
        p.contentView = NSHostingView(rootView: FaceScanView(o: self, notch: notch))
        window = p
        return p
    }

    private func position(_ w: NSWindow) {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        w.setFrame(CGRect(x: s.frame.midX - Self.size.width / 2, y: s.frame.maxY - Self.size.height,
                          width: Self.size.width, height: Self.size.height), display: true)
    }

    /// VoiceOver hears each phase once; the result also gets a sound, because announcements may
    /// not be spoken over the lock screen. Both are VoiceOver-only.
    private static func speak(_ p: FaceScanPhase) {
        switch p {
        case .scanning: A11y.announce("Face scan")
        case .matched(let name): A11y.announce(name.isEmpty ? "Face recognised" : "Face recognised, \(name)", high: true); A11y.cue("Tink")
        case .failed(let why): A11y.announce("Face not recognised. \(why). Use Touch ID", high: true); A11y.cue("Basso")
        case .hidden: break
        }
    }

    static func notchSize() -> CGSize {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return CGSize(width: 190, height: 32) }
        return CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
    }
}

// MARK: - View

private let phosphor = Color(red: 0.0, green: 1.0, blue: 0.25)
private let alarm = Color(red: 1.0, green: 0.2, blue: 0.25)

/// Matrix lab: green digital rain through the pill; in the portal on the left your head and
/// shoulders lock out of the rain as recognition climbs; terminal readouts of the real scan on
/// the right. Granted: the rain flares white and drains. Denied: red, glitching.
struct FaceScanView: View {
    @ObservedObject var o: LockFaceOverlay
    let notch: CGSize
    /// Inside the island (unlocked): the island draws the pill and morphs; we only draw content.
    var embedded = false
    @State private var since = Date()
    @Environment(\.accessibilityReduceMotion) private var rm
    @Environment(\.accessibilityDifferentiateWithoutColor) private var dwc

    private var open: Bool { o.phase != .hidden }
    private var granted: Bool { if case .matched = o.phase { return true }; return false }
    private var denied: Bool { if case .failed = o.phase { return true }; return false }
    private var ink: Color { denied ? alarm : phosphor }

    var body: some View {
        let w = open ? 232 : notch.width, h = open ? notch.height + 50 : notch.height
        // Reduce Motion: no rain, glitch or scramble; one still frame redrawn only when state changes.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !open || rm)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let age = ctx.date.timeIntervalSince(since)
            let shape = NotchShape(topRadius: 14, bottomRadius: open ? 22 : 10)
            if embedded {
                content(t, age).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                content(t, age)
                    .frame(width: w + 28, height: h)
                    .clipShape(shape)
                    .overlay { if open { shape.stroke(ink.opacity(0.25), lineWidth: 0.6) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(rm ? .easeInOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.82), value: o.phase)
        .onChange(of: o.phase) { since = Date() }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Face unlock")
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        switch o.phase {
        case .scanning: "Scanning, \(Int((o.progress * 100).rounded())) percent" + (o.hint.map { ", " + $0 } ?? "")
        case .matched: "Recognised"
        case .failed(let r): "Not recognised, \(r). Use Touch ID"
        case .hidden: ""
        }
    }

    /// Shape cue beside the colour (Differentiate Without Color or Reduce Motion): open lock or a cross. Never a tick.
    @ViewBuilder private var resultGlyph: some View {
        if granted || denied, dwc || rm {
            Image(systemName: granted ? "lock.open.fill" : "xmark")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(granted ? .white : ink)
        }
    }

    /// Reduce Motion: a plain progress ring in the portal and plain text, nothing moving.
    @ViewBuilder private var still: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().stroke(ink.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: granted ? 1 : (denied ? 0 : o.progress))
                    .stroke(granted ? .white : ink, style: .init(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 34, height: 34)
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    resultGlyph
                    Text(headline).font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1.8)
                        .foregroundStyle(granted ? .white : ink)
                }
                Text(line).font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle((granted ? Color.white : ink).opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
        .padding(.top, notch.height + 5)
    }

    @ViewBuilder private func content(_ t: TimeInterval, _ age: TimeInterval) -> some View {
            ZStack(alignment: .topLeading) {
                Color.black
                if open && rm {
                    still.transition(.opacity)
                } else if open {
                    MatrixRain(t: t, age: age, progress: o.progress, granted: granted, denied: denied,
                               portal: CGRect(x: 22, y: notch.height + 5, width: 38, height: 38))
                    HStack(alignment: .center, spacing: 12) {
                        Color.clear.frame(width: 38, height: 38) // portal lives in the rain layer
                            .overlay(Circle().stroke(ink.opacity(0.35), style: .init(lineWidth: 0.8, dash: [2, 3]))
                                .rotationEffect(.degrees(t * 25)))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                resultGlyph
                                Text(headline).font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1.8)
                                    .foregroundStyle(granted ? .white : ink)
                                    .shadow(color: ink.opacity(0.8), radius: 3)
                            }
                            ScrambleText(value: line, color: (granted ? Color.white : ink).opacity(0.6))
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 22)
                    .padding(.top, notch.height + 5)
                    .modifier(Glitch(on: denied && age < 0.7, t: t))
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
                }
            }
    }

    private var headline: String {
        switch o.phase {
        case .scanning: o.hint.map { $0.uppercased() } ?? (o.progress > 0.66 ? "VERIFYING_" : "SCANNING_")
        case .matched: "GRANTED"
        case .failed(let r): r.lowercased().contains("photo") ? "SPOOF" : "DENIED"
        case .hidden: ""
        }
    }

    /// One readout line: the closest-match distance and the vote count; the spoof cue if one fires.
    private var line: String {
        if o.telemetry.spoof != "CLEAR" { return "SPOOF · " + o.telemetry.spoof }
        if granted { return "MATCH " + match.trimmingCharacters(in: .whitespaces) + " · OK" }
        if denied { return "USE TOUCH ID" }
        return "MATCH \(match.prefix(5)) · \(o.telemetry.votes)/3"
    }

    private var match: String {
        guard let m = o.telemetry.match else { return granted ? "OK" : "----" }
        return String(format: "%.3f", m) + (m <= o.telemetry.threshold ? " <" : "  ")
    }

    private func readout(_ k: String, _ v: String) -> some View {
        HStack(spacing: 0) {
            Text("> " + k.padding(toLength: 6, withPad: " ", startingAt: 0))
                .foregroundStyle(ink.opacity(0.45))
            ScrambleText(value: v, color: granted ? .white : ink)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }
}

/// A value that resolves out of random glyphs whenever it changes.
private struct ScrambleText: View {
    let value: String
    let color: Color
    @State private var changed = Date()
    @State private var settled = false
    private static let pool = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄ0123456789:<>=+*")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: settled)) { ctx in
            let a = ctx.date.timeIntervalSince(changed)
            let shown = String(value.enumerated().map { i, ch in
                a > 0.05 * Double(i) + 0.15 || ch == " " ? ch : Self.pool[(i * 7 + Int(ctx.date.timeIntervalSinceReferenceDate * 40)) % Self.pool.count]
            })
            Text(shown).foregroundStyle(color)
        }
        // Numbers tick in place; only a change of wording scrambles.
        .onChange(of: value.filter { !$0.isNumber && $0 != "." }) { changed = Date(); settleSoon() }
        .onAppear { settleSoon() }
    }
}

extension ScrambleText {
    /// Every glyph has resolved by 0.15 + 0.05 n seconds; after that the timeline can sleep.
    fileprivate func settleSoon() {
        settled = false
        let stamp = changed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + 0.05 * Double(value.count)) {
            if stamp == changed { settled = true }
        }
    }
}

/// Columns of falling glyphs. Inside the portal the cells are finer, and cells within a head-and-
/// shoulders mask brighten with progress, so the face appears out of the rain.
private struct MatrixRain: View {
    let t: TimeInterval
    let age: TimeInterval
    let progress: Double
    let granted: Bool
    let denied: Bool
    let portal: CGRect

    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ012345789Z:・.=*+-<>¦")

    var body: some View {
        Canvas { c, size in
            let ink = denied ? alarm : phosphor
            // Resolve each glyph once per frame in two inks (tails, bright heads).
            var tail: [Character: GraphicsContext.ResolvedText] = [:], head: [Character: GraphicsContext.ResolvedText] = [:]
            func glyph(_ ch: Character, _ bright: Bool, _ size: CGFloat) -> GraphicsContext.ResolvedText {
                let key = ch
                if bright, size > 6, let r = head[key] { return r }
                if !bright, size > 6, let r = tail[key] { return r }
                let r = c.resolve(Text(String(ch)).font(.system(size: size, weight: bright ? .bold : .regular, design: .monospaced))
                    .foregroundColor(bright ? Color(red: 0.85, green: 1, blue: 0.9) : ink))
                if size > 6 { if bright { head[key] = r } else { tail[key] = r } }
                return r
            }
            func hash(_ a: Int, _ b: Int) -> Int { var x = a &* 73856093 ^ b &* 19349663; x ^= x >> 13; return abs(x &* 1274126177) }

            // Background rain over the whole pill (dim), finer + brighter inside the portal.
            let freeze = granted && age < 0.25
            let drain = granted ? max(0, age - 0.25) : 0 // granted: everything falls away fast
            let tt = freeze ? t - age : t
            for zone in 0..<2 {
                let inPortal = zone == 1
                let cell: CGFloat = inPortal ? 4.2 : 7.5
                let area = inPortal ? portal : CGRect(origin: .zero, size: size)
                let cols = Int(area.width / cell), rows = Int(area.height / cell) + 1
                for col in 0..<cols {
                    let seed = hash(col, zone)
                    let speed = 6 + Double(seed % 9) // rows per second
                    let len = 5 + seed % 9
                    let headRow = Int((tt * speed + Double(seed % 97)) .truncatingRemainder(dividingBy: Double(rows + len))) + Int(drain * drain * 60)
                    for row in 0..<rows {
                        let x = area.minX + CGFloat(col) * cell + cell / 2
                        let y = area.minY + CGFloat(row) * cell + cell / 2
                        if inPortal {
                            let dx = (x - portal.midX) / (portal.width / 2), dy = (y - portal.midY) / (portal.height / 2)
                            if dx * dx + dy * dy > 1 { continue }
                        } else if portal.insetBy(dx: -4, dy: -4).contains(CGPoint(x: x, y: y)) { continue }
                        let dist = headRow - row
                        var a: Double = dist >= 0 && dist < len ? 1 - Double(dist) / Double(len) : 0
                        let isHead = dist == 0
                        // The face: head + shoulders mask inside the portal, revealed by progress.
                        var lit = false
                        if inPortal {
                            let u = (x - portal.minX) / portal.width, v = (y - portal.minY) / portal.height
                            let hx = (u - 0.5) / 0.22, hy = (v - 0.4) / 0.27
                            let headIn = hx * hx + hy * hy < 1
                            let sx = (u - 0.5) / 0.46, sy = (v - 1.08) / 0.34
                            let shoulders = sx * sx + sy * sy < 1
                            let eyes = abs(v - 0.37) < 0.035 && (abs(u - 0.41) < 0.04 || abs(u - 0.59) < 0.04)
                            let inMask = (headIn || shoulders) && !eyes
                            let reveal = progress >= (1 - v) * 0.85 || granted // bottom-up as recognition climbs
                            if inMask && reveal { a = max(a, 0.7 + 0.3 * sin(t * 6 + Double(row + col))); lit = true }
                            else if reveal && progress > 0.3 { a *= 0.18 } // rain around the face falls back
                            if eyes && reveal { a = 0 }
                        }
                        if !inPortal { a *= 0.2; if col % 2 == 1 { continue } }
                        if granted && age > 0.12 && age < 0.3 { a = max(a, lit ? 1 : 0.5) } // white flare
                        if drain > 0 { a *= max(0, 1 - drain * 2.2) }
                        guard a > 0.04 else { continue }
                        let ch = Self.glyphs[hash(col * 31 + row, zone + Int(tt * (lit ? 3 : 7))) % Self.glyphs.count]
                        var g = c
                        g.opacity = a
                        let bright = isHead || (granted && age > 0.12 && age < 0.3)
                        g.draw(glyph(ch, bright, inPortal ? 4.6 : 7), at: CGPoint(x: x, y: y))
                    }
                }
            }
            // A scan line through the portal while scanning.
            if !granted && !denied {
                let y = portal.minY + portal.height * CGFloat((sin(t * 2.2) + 1) / 2)
                let half = portal.width / 2 * CGFloat((1 - pow((y - portal.midY) / (portal.height / 2), 2)).squareRoot())
                var p = Path(); p.move(to: CGPoint(x: portal.midX - half, y: y)); p.addLine(to: CGPoint(x: portal.midX + half, y: y))
                c.stroke(p, with: .linearGradient(Gradient(colors: [.clear, phosphor, .white, phosphor, .clear]),
                                                  startPoint: CGPoint(x: portal.midX - half, y: y), endPoint: CGPoint(x: portal.midX + half, y: y)), lineWidth: 1.2)
            }
        }
    }
}

/// Denied: horizontal slices jump sideways for a moment.
private struct Glitch: ViewModifier {
    let on: Bool
    let t: TimeInterval
    func body(content: Content) -> some View {
        if on {
            let k = Int(t * 30)
            content
                .offset(x: CGFloat((k * 37) % 9) - 4)
                .overlay(content.foregroundStyle(alarm).offset(x: CGFloat((k * 13) % 7) - 3).opacity(0.5).blendMode(.screen))
        } else {
            content
        }
    }
}

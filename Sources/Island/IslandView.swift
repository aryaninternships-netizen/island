import SwiftUI

private let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)
/// Glance-style open/close: a little bounce on the way out of the notch, none on the way back.
private let openSpring = Animation.spring(response: 0.45, dampingFraction: 0.7)
private let closeSpring = Animation.spring(response: 0.45, dampingFraction: 1.0)

/// True while the screen is locked or the display sleeps (IslandModel.renderPaused). Continuous
/// animations read it from the environment instead of threading a flag through every view.
private struct RenderPausedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var renderPaused: Bool {
        get { self[RenderPausedKey.self] }
        set { self[RenderPausedKey.self] = newValue }
    }
}

struct IslandView: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var media: MediaController
    @Environment(\.accessibilityReduceMotion) private var rm

    private var open: Bool { m.state == .open }
    /// Reduce Motion: springs become a 0.15 s ease, scale-in becomes a plain fade.
    private var anim: Animation { rm ? .easeInOut(duration: 0.15) : spring }
    private var stateAnim: Animation { rm ? .easeInOut(duration: 0.15) : (open ? openSpring : closeSpring) }
    private var faceTransition: AnyTransition {
        rm ? .opacity.animation(.easeInOut(duration: 0.15))
            : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(spring.delay(0.06)),
                          // Content dissolves (blur + fade) instead of being clipped by the shrinking shape.
                          removal: .opacity.combined(with: .modifier(active: BlurDissolve(radius: 14), identity: BlurDissolve(radius: 0)))
                            .animation(.easeOut(duration: 0.16)))
    }
    private var topRadius: CGFloat { open ? 14 : 7 }
    private var bottomRadius: CGFloat {
        if open { return 30 }
        if m.recPeek { return 18 }
        switch m.closedFace {
        case .scan: return 22
        case .banner, .compact: if m.closedFace.activity?.banner == true { return 22 }
        default: break
        }
        return m.state == .peek ? 13 : 10
    }

    /// View identity for the transition: changes only when what the island shows changes kind or owner.
    private enum Face: Hashable { case open, recPeek, scan, banner(String), compact(String), media, dog, nap, idle, hidden }

    private func face(_ f: ClosedFace) -> Face {
        if open { return .open }
        if m.recPeek { return .recPeek }
        switch f {
        case .scan: return .scan
        case .banner, .compact:
            let a = f.activity!
            return a.banner ? .banner(a.id) : .compact(a.id)
        case .dogWalk: return .dog
        case .media: return .media
        case .nap: return .nap
        case .idle: return .idle
        case .hidden: return .hidden
        }
    }

    var body: some View {
        let s = m.size
        let closed = m.closedFace
        ZStack(alignment: .top) {
            IslandBackdrop(open: open, accent: open && media.live ? ArtworkTint.of(media.artwork) : nil,
                           topRadius: topRadius, bottomRadius: bottomRadius, sky: m.skyBackground,
                           skySize: CGSize(width: m.openSize.width + 28, height: m.openSize.height),
                           dim: m.tab == .home ? 0.12 : 0.30)
            content(closed)
                .padding(.horizontal, topRadius)
                .transition(faceTransition)
                .id(face(closed))
        }
        .frame(width: s.width + topRadius * 2, height: s.height)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        .overlay {
            if let f = m.flair, m.flairRaw != FlairMode.off.rawValue {
                NotchGlow(event: f, topRadius: topRadius, bottomRadius: bottomRadius).id(f.seq)
            }
        }
        .shadow(color: .black.opacity(open ? 0.55 : 0), radius: 16, y: 4)
        .opacity(m.visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(stateAnim, value: m.state)
        .animation(anim, value: m.activitySeq)
        .animation(anim, value: media.live)
        .animation(anim, value: m.dogWalkStart)
        .animation(anim, value: m.dogDanceStart)
        .animation(anim, value: m.lockFace.overlay.phase)
        .animation(anim, value: m.hidden)
        .animation(anim, value: m.recording)
        // Reduce Motion rides the Stage 1 pause plumbing: spinner, equalizer and pup hold a still pose.
        .environment(\.renderPaused, m.renderPaused || rm)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func content(_ closed: ClosedFace) -> some View {
        switch face(closed) {
        case .open:
            ExpandedView(m: m, hub: m.hub, media: media, shelf: m.shelf, battery: m.battery, calendar: m.calendar)
        case .scan:
            FaceScanView(o: m.lockFace.overlay, notch: m.notchSize, embedded: true)
                .padding(.horizontal, -topRadius) // fill the island body edge to edge
        case .banner:
            if let a = closed.activity { BannerView(a: a, notchHeight: m.notchHeight) }
        case .recPeek:
            if let s = m.meeting.session {
                RecPeekView(m: m, rec: s.recorder).padding(.horizontal, -topRadius + 4)
            }
        case .compact:
            if case .compact(let f) = closed, case .rec(let flash) = f.style {
                RecFace(start: f.trailing.clockStart, flash: flash, side: m.recSide, height: m.notchHeight)
            } else if case .compact(let f) = closed, f.style == .offer {
                OfferFace(app: m.meeting.offer?.app ?? "", title: f.title, side: m.offerSide, height: m.notchHeight)
            } else if let a = closed.activity {
                CompactSides(side: m.compactSide, height: m.notchHeight) {
                    Image(systemName: a.symbol).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(a.tint).contentTransition(.symbolEffect(.replace))
                } right: {
                    TrailingView(trailing: a.trailing, tint: a.tint)
                }
            }
        case .nap:
            CompactSides(side: m.compactSide, height: m.notchHeight) {
                PupStage(mood: .sleep, scale: 0.85, start: m.napSince ?? Date(timeIntervalSinceReferenceDate: 0)).offset(y: 1)
            } right: {
                Image(systemName: "moon.zzz.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
        case .media:
            CompactSides(side: m.mediaSide + (m.dogDanceStart != nil ? 32 : 0), height: m.notchHeight) {
                HStack {
                    ArtworkView(image: media.artwork, size: m.notchHeight - 12, radius: 6)
                    Spacer(minLength: 0)
                }.padding(.leading, m.dogDanceStart != nil ? 6 : 0)
            } right: {
                HStack(alignment: .bottom, spacing: 6) {
                    if let start = m.dogDanceStart {
                        DancingDog(start: start, playing: media.playing, tint: media.accent)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    Equalizer(playing: media.playing, tint: media.accent)
                        .frame(width: 18, height: 13)
                        .padding(.bottom, m.dogDanceStart != nil ? 8 : 0)
                }
            }
        case .dog:
            if let start = m.dogWalkStart { DogWalkView(start: start, height: m.notchHeight) }
        case .idle, .hidden:
            Color.clear
        }
    }
}

// MARK: - Meeting faces

extension Activity.Trailing {
    var clockStart: Date? { if case .clock(let d, _) = self { d } else { nil } }
}

/// Recording, closed: a 5 pt dim red dot and a grey elapsed time. Quiet enough to forget.
struct RecFace: View {
    let start: Date?
    let flash: Bool
    let side: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var rm

    var body: some View {
        CompactSides(side: side, height: height) {
            Circle().fill(.red.opacity(flash ? 1 : 0.55)).frame(width: 5, height: 5)
                .scaleEffect(flash && !rm ? 1.8 : 1)
                .animation(.easeOut(duration: 0.18), value: flash)
                .accessibilityLabel("Recording")
        } right: {
            if let start {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(clockText(ctx.date.timeIntervalSince(start)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
        }
    }
}

/// A call took the mic: a hollow red dot and the title. Click opens Home with Record / Not this one.
struct OfferFace: View {
    let app: String
    let title: String
    let side: CGFloat
    let height: CGFloat

    var body: some View {
        CompactSides(side: side, height: height) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Circle().stroke(.red.opacity(0.85), lineWidth: 1.2).frame(width: 6, height: 6)
                Text(app).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .padding(.trailing, 10)
        } right: {
            HStack(spacing: 0) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app) is using the mic. Record \(title)?")
    }
}

/// Hover while recording: the last two transcript lines, Mark and Stop. A click elsewhere opens Home.
struct RecPeekView: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var rec: MeetingRecorder

    private var lines: [String] {
        let live = rec.partial.keys.sorted().compactMap { rec.partial[$0] }.filter { !$0.isEmpty }
        return Array((rec.segments.suffix(2).map(\.text) + live).suffix(2))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(.red.opacity(0.7)).frame(width: 5, height: 5)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(clockText(ctx.date.timeIntervalSince(rec.start)))
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer(minLength: m.notchSize.width + 8)
                Text(rec.marks.isEmpty ? "" : "\(rec.marks.count) mark\(rec.marks.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .frame(height: m.notchHeight)
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text(rec.problem ?? "Listening…").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(size: 10.5)).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.white.opacity(i == lines.count - 1 ? 0.85 : 0.45))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MicroButton(symbol: "bookmark.fill", label: "Mark this moment") { m.meeting.mark() }
                MicroButton(symbol: "stop.fill", label: "Stop recording") { m.meeting.stop() }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { m.requestOpenHome?() }
    }
}

/// 20 pt round icon control for the notch (peek, Live card). Icon only: label and tooltip always.
struct MicroButton: View {
    let symbol: String
    let label: String
    var tint: Color = .red
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(hover ? 0.26 : 0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Closed faces

struct CompactSides<L: View, R: View>: View {
    let side: CGFloat
    let height: CGFloat
    @ViewBuilder var left: L
    @ViewBuilder var right: R

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: side, height: height)
            Spacer(minLength: 0)
            right.frame(width: side, height: height)
        }
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct TrailingView: View {
    let trailing: Activity.Trailing
    let tint: Color

    var body: some View {
        switch trailing {
        case .none: EmptyView()
        case .text(let t):
            Text(t).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint)
        case .meter(let v):
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white).frame(width: max(4, 38 * v))
            }
            .frame(width: 38, height: 5)
        case .progress(let v):
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: v).stroke(tint, style: .init(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
        case .spinner:
            Spinner(tint: tint).frame(width: 15, height: 15)
        case .clock(let d, let up):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(clockText(up ? ctx.date.timeIntervalSince(d) : d.timeIntervalSince(ctx.date)))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tint).contentTransition(.numericText(countsDown: !up))
            }
        case .battery(let level, let charging):
            BatteryGlyph(level: level, charging: charging)
        }
    }
}

/// Small battery outline whose fill tracks the level; green + bolt while charging, red when low.
struct BatteryGlyph: View {
    let level: Int
    let charging: Bool

    @Environment(\.accessibilityDifferentiateWithoutColor) private var dwc

    var body: some View {
        let low = !charging && level <= 20
        HStack(spacing: 4) {
            // Differentiate Without Color: low reads from a glyph, not just red.
            if low && dwc { Image(systemName: "exclamationmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.red) }
            Text("\(level)%").font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(low ? .red : .white)
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(charging ? .green : (low ? .red : .white))
                        .frame(width: max(2, 19 * CGFloat(level) / 100)).padding(2)
                    if charging {
                        Image(systemName: "bolt.fill").font(.system(size: 7, weight: .black)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: 23, height: 11)
                Capsule().fill(.white.opacity(0.45)).frame(width: 1.5, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue("\(level) percent" + (charging ? ", charging" : low ? ", low" : ""))
    }
}

/// Pause/resume a layer tree's animations in place (speed 0 alone would snap back to t = 0).
extension CALayer {
    func freezeAnimations() {
        guard speed != 0 else { return }
        let t = convertTime(CACurrentMediaTime(), from: nil)
        speed = 0
        timeOffset = t
    }

    func thawAnimations() {
        guard speed == 0 else { return }
        let frozen = timeOffset
        speed = 1
        timeOffset = 0
        beginTime = 0
        beginTime = convertTime(CACurrentMediaTime(), from: nil) - frozen
    }

    func setFrozen(_ frozen: Bool) { frozen ? freezeAnimations() : thawAnimations() }
}

/// Indeterminate ring. Core Animation spins it on the render server: no per-frame app work.
struct Spinner: NSViewRepresentable {
    let tint: Color
    @Environment(\.renderPaused) private var paused

    func makeNSView(context: Context) -> SpinnerNSView { SpinnerNSView() }

    func updateNSView(_ v: SpinnerNSView, context: Context) {
        v.setTint(NSColor(tint).cgColor)
        v.setFrozen(paused)
    }

    final class SpinnerNSView: NSView {
        private let root = CALayer()
        private let ring = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            ring.fillColor = nil
            ring.lineWidth = 2.5
            ring.lineCap = .round
            ring.strokeStart = 0
            ring.strokeEnd = 0.72
            root.addSublayer(ring)
            layer?.addSublayer(root)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi // layer space is y-up: negative = clockwise on screen
            spin.duration = 2 * Double.pi / 5 // 5 rad/s, as before
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = bounds
            ring.bounds = bounds
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
            ring.path = CGPath(ellipseIn: bounds, transform: nil)
            CATransaction.commit()
        }

        func setTint(_ c: CGColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.strokeColor = c
            CATransaction.commit()
        }

        func setFrozen(_ f: Bool) { root.setFrozen(f) }
    }
}

struct BannerView: View {
    let a: Activity
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight - 4)
            HStack(spacing: 10) {
                if !a.faces.isEmpty {
                    FaceStack(images: a.faces, size: 30)
                } else if a.dog {
                    BarkingDog(mood: a.dogMood)
                } else if let img = a.image {
                    ArtworkView(image: img, size: 30, radius: 7)
                } else {
                    Image(systemName: a.symbol).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(a.tint)
                        .frame(width: 30, height: 30)
                        .background(a.tint.opacity(0.16), in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(a.wraps ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: a.wraps)
                    if !a.body.isEmpty {
                        Text(a.body).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                TrailingView(trailing: a.trailing, tint: a.tint)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Four calm bars, never in lockstep; flat when paused. Core Animation drives the heights on the
/// render server (bounds.size.height keeps the capsule ends round, a scale would squash them).
struct Equalizer: NSViewRepresentable {
    let playing: Bool
    let tint: Color
    @Environment(\.renderPaused) private var paused

    func makeNSView(context: Context) -> BarsNSView { BarsNSView() }

    func updateNSView(_ v: BarsNSView, context: Context) {
        v.setTint(NSColor(tint).cgColor)
        v.setPlaying(playing)
        v.setFrozen(paused)
    }

    final class BarsNSView: NSView {
        private static let periods: [Double] = [0.42, 0.55, 0.37, 0.61]
        private static let full: CGFloat = 13, barW: CGFloat = 3, gap: CGFloat = 2.5
        private let root = CALayer()
        private var bars: [CALayer] = []
        private var playing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            for _ in Self.periods {
                let b = CALayer()
                b.cornerRadius = Self.barW / 2
                bars.append(b)
                root.addSublayer(b)
            }
            layer?.addSublayer(root)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = bounds
            let total = CGFloat(bars.count) * Self.barW + CGFloat(bars.count - 1) * Self.gap
            let x0 = (bounds.width - total) / 2
            for (i, b) in bars.enumerated() {
                let h = b.bounds.height > 0 ? b.bounds.height : Self.barW
                b.bounds = CGRect(x: 0, y: 0, width: Self.barW, height: h)
                b.position = CGPoint(x: x0 + Self.barW / 2 + CGFloat(i) * (Self.barW + Self.gap), y: bounds.midY)
            }
            CATransaction.commit()
            restRender()
        }

        func setTint(_ c: CGColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bars.forEach { $0.backgroundColor = c }
            CATransaction.commit()
        }

        func setFrozen(_ f: Bool) { root.setFrozen(f) }

        func setPlaying(_ p: Bool) {
            guard p != playing else { return }
            playing = p
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, b) in bars.enumerated() {
                b.removeAnimation(forKey: "h")
                guard p else { b.bounds.size.height = Self.barW; continue }
                let a = CABasicAnimation(keyPath: "bounds.size.height")
                a.fromValue = Self.full * 0.35
                a.toValue = Self.full
                a.duration = Self.periods[i]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.beginTime = b.convertTime(CACurrentMediaTime(), from: nil) - Double(i) * 0.17 // out of phase
                b.bounds.size.height = Self.full
                b.add(a, forKey: "h")
            }
            CATransaction.commit()
        }

        private func restRender() {
            guard !playing else { return }
            for b in bars { b.bounds.size.height = Self.barW }
        }
    }
}

/// Overlapping round face close-ups (who peeked).
struct FaceStack: View {
    let images: [NSImage]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(Circle())
                    .overlay(Circle().stroke(.black, lineWidth: 2))
                    .overlay(Circle().stroke(.orange.opacity(0.9), lineWidth: 1).padding(1))
            }
        }
    }
}

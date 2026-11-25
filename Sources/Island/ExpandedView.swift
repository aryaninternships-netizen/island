import SwiftUI
import UniformTypeIdentifiers

struct ExpandedView: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var hub: FeatureHub
    @ObservedObject var media: MediaController
    @ObservedObject var shelf: Shelf
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var calendar: CalendarModel
    @State private var headerHover = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var dwc

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: m.notchHeight)
            Group {
                switch m.tab {
                case .home: NowView(m: m, hub: hub, media: media, calendar: calendar, weather: m.weather, meeting: m.meeting)
                case .desk: DeskView(m: m, timers: m.timers, clipboard: m.clipboard)
                case .shelf: ShelfView(shelf: shelf, targeted: m.dropTargeted)
                case .watch: WhoPeekedView(log: GuardLog.shared)
                case .pet: PetView(pet: m.pet, brain: m.brain)
                case .tray: TrayView(m: m)
                case .settings: SettingsView(m: m, calendar: calendar, lockFace: m.lockFace)
                case .welcome: OnboardingView(m: m, calendar: calendar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background(alignment: .leading) {
            // Soft artwork glow behind the player.
            if m.tab == .home, media.hasMedia {
                RadialGradient(colors: [media.accent.opacity(0.22), .clear], center: .center,
                               startRadius: 4, endRadius: 190)
                    .frame(width: 380, height: 300).offset(x: -60, y: 20)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $m.dropTargeted) { providers in
            m.tab = .shelf
            return shelf.handle(providers)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            // Home · Desk · [Shelf] · [Tray] · [Pet] · [Watch] · gear. A tab shows only when it has
            // something. Inactive pills are plain dim glyphs; the active one reads at full strength.
            // Up to 7 pills at 26 + 1 pt = 188 pt: clear of the notch from the 24 pt inset.
            HStack(spacing: 1) {
                TabPill(symbol: "house.fill", label: "Now", title: "Now", active: m.tab == .home, lift: lift) { m.tab = .home }
                TabPill(symbol: "square.and.pencil", label: "Desk: timers, note, clipboard", title: "Desk", active: m.tab == .desk, lift: lift) { m.tab = .desk }
                if !shelf.items.isEmpty || m.tab == .shelf {
                    TabPill(symbol: "tray.full.fill", label: "Shelf", title: "Shelf", active: m.tab == .shelf, badge: shelf.items.count, lift: lift) { m.tab = .shelf }
                }
                if m.collapser != nil || m.tab == .tray {
                    TabPill(symbol: "menubar.rectangle", label: "Folded menu bar icons", title: "Menu bar", active: m.tab == .tray, lift: lift) { m.tab = .tray; m.refreshTray() }
                }
                WatchPill(m: m, log: GuardLog.shared, lift: lift)
                TabPill(symbol: "gearshape.fill", label: "Settings", title: "Settings", active: m.tab == .settings, lift: lift) { m.tab = .settings }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Island tabs")
            .onHover { h in withAnimation(.easeOut(duration: 0.18)) { headerHover = h } }
            Spacer(minLength: m.notchSize.width + 24)
            HStack(spacing: 10) {
                // Live features that asked for a header glyph (recording, Guard, Keep Awake, Quiet).
                ForEach(hub.live.filter(\.headerGlyph).prefix(3)) { f in
                    Image(systemName: f.symbol).font(.system(size: 10.5)).foregroundStyle(f.tint)
                        .help(f.title + (f.detail.map { " · " + $0 } ?? ""))
                        .accessibilityLabel(f.title)
                }
                if battery.hasBattery {
                    let low = battery.level <= 20 && !battery.pluggedIn
                    HStack(spacing: 4) {
                        Text("\(battery.level)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        // Differentiate Without Color: low shows an empty cell plus "!", not only red.
                        if low && dwc {
                            Image(systemName: "exclamationmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.red)
                        }
                        Image(systemName: low && dwc ? "battery.0percent" : batterySymbol).font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(low ? .red : .green, .white.opacity(0.5))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Battery")
                    .accessibilityValue("\(battery.level) percent" + (battery.charging || battery.pluggedIn ? ", charging" : low ? ", low" : ""))
                }
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 24)
        .padding(.top, 2)
    }

    /// Hover, ⌃⌥Space or Increase Contrast: inactive tabs lift from 0.35 so they can be found.
    private var lift: Bool { headerHover || m.keyOpen || contrast == .increased }

    private var batterySymbol: String {
        if battery.charging || battery.pluggedIn { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

}

struct TabPill: View {
    let symbol: String
    /// Tooltip and VoiceOver name.
    let label: String
    /// Short name shown beside the glyph while this tab is active, so the bar names where you are.
    var title: String? = nil
    let active: Bool
    var badge = 0
    /// The bar is being reached for (hover, keyboard, contrast): inactive glyphs lift a little.
    var lift = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                if active, let title {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
                .foregroundStyle(.white.opacity(active ? 1 : hover ? 0.85 : Dim.text(contrast, lift ? 0.55 : 0.35)))
                .padding(.horizontal, active && title != nil ? 9 : 0)
                .frame(minWidth: 26, minHeight: 22)
                .background(.white.opacity(active ? 0.14 : 0), in: Capsule())
                .hiContrastStroke(Capsule())
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 8, weight: .bold)).padding(.horizontal, 3.5)
                            .frame(minWidth: 12, minHeight: 12).background(.orange, in: Capsule())
                            .offset(x: 4, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(badge > 0 ? "\(badge) new" : "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Now playing

struct NowPlayingCard: View {
    @ObservedObject var media: MediaController
    @State private var scrub: Double?
    @Environment(\.accessibilityReduceMotion) private var rm

    var body: some View {
        if media.hasMedia {
            HStack(spacing: 14) {
                ArtworkView(image: media.artwork, size: 96, radius: 14)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: media.accent.opacity(0.55), radius: 14, y: 5)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = media.sourceIcon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                                .offset(x: 5, y: 5)
                        }
                    }
                    .scaleEffect(media.playing || rm ? 1 : 0.93)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: media.playing)
                    .onTapGesture { media.openSourceApp() }
                    .help("Open player")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Open player")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { media.openSourceApp() }
                VStack(alignment: .leading, spacing: 5) {
                    Text(media.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(media.artist.isEmpty ? media.album : media.artist)
                        .font(.system(size: 12)).foregroundStyle(media.accent.opacity(0.9)).lineLimit(1)
                    progress.padding(.top, 2)
                    controls
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(.white.opacity(0.3))
                Text("Nothing playing").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let e = scrub ?? media.elapsed(at: ctx.date)
            let d = max(media.duration, 0.01)
            VStack(spacing: 3) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(media.accent).frame(width: max(0, g.size.width * min(e / d, 1)))
                    }
                    .frame(height: scrub == nil ? 4 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in scrub = min(max(v.location.x / g.size.width, 0), 1) * d }
                        .onEnded { _ in
                            if let s = scrub { media.seek(to: s) }
                            scrub = nil
                        })
                    .animation(.easeOut(duration: 0.15), value: scrub == nil)
                }
                .frame(height: 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue(media.duration > 0 ? "\(fmt(e)) of \(fmt(d))" : "")
                if media.duration > 0 {
                    HStack {
                        Text(fmt(e)); Spacer(); Text("-" + fmt(max(d - e, 0)))
                    }
                    .font(T.f(9.5, .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            ControlButton(symbol: "backward.fill", size: 14, label: "Previous track") { media.send(.previous) }
            PlayButton(playing: media.playing) { media.send(.toggle) }
            ControlButton(symbol: "forward.fill", size: 14, label: "Next track") { media.send(.next) }
        }
        .frame(maxWidth: .infinity)
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The one primary control: a solid white circle with a black glyph.
struct PlayButton: View {
    let playing: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var rm

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.black)
                .offset(x: playing ? 0 : 1)
                .frame(width: 34, height: 34)
                .background(.white.opacity(hover ? 1 : 0.92), in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .scaleEffect(pressed && !rm ? 0.88 : (hover && !rm ? 1.05 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(playing ? "Pause" : "Play")
        .accessibilityLabel(playing ? "Pause" : "Play")
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { pressed = false } })
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    var label = ""
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var rm

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 18, height: size + 14)
                .background(.white.opacity(hover ? 0.1 : 0), in: Circle())
                .hiContrastStroke(Circle())
                .scaleEffect(pressed && !rm ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { pressed = false } })
    }
}

// MARK: - Calendar

struct CalendarCard: View {
    @ObservedObject var calendar: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(ctx.date, format: .dateTime.weekday(.wide)).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                    Text(ctx.date, format: .dateTime.day().month(.abbreviated))
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            if !calendar.authorized {
                Button { Deep.open(Deep.calendars) } label: {
                    Text("Allow Calendar access to see events ›").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            } else if calendar.items.isEmpty {
                Text("No more events").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                ForEach(calendar.items) { e in
                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: e.color)).frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Text(when(e)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let link = e.link, e.start.timeIntervalSinceNow < 15 * 60, e.end > Date() {
                            Button { NSWorkspace.shared.open(link) } label: {
                                Text("Join").font(.system(size: 10.5, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.green, in: Capsule()).foregroundStyle(.black)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func when(_ e: CalendarModel.Item) -> String {
        if e.allDay { return "All day" }
        let now = Date()
        if e.start <= now { return "Now · until \(e.end.formatted(date: .omitted, time: .shortened))" }
        let mins = Int(e.start.timeIntervalSince(now) / 60)
        let day = Calendar.current.isDateInToday(e.start) ? "" : "Tomorrow "
        if mins < 60 { return "in \(mins) min" }
        return day + e.start.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Shelf

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    let targeted: Bool

    var body: some View {
        HStack(spacing: 12) {
            if shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                    .foregroundStyle(.white.opacity(targeted ? 0.6 : 0.22))
                    .background(.white.opacity(targeted ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        EmptyState(symbol: targeted ? "tray.and.arrow.down.fill" : "tray", tint: .orange,
                                   text: "Drop files here · drag them out later")
                    }
                    .padding(10)
                    .glass(18)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items) { ShelfTile(item: $0, shelf: shelf) }
                    }
                    .padding(.vertical, 2)
                }
                .padding(10)
                .background(.white.opacity(targeted ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 18))
                .glass(18)
                VStack(spacing: 6) {
                    SideAction(symbol: "airplayaudio", label: "AirDrop") { shelf.airdrop() }
                    SideAction(symbol: "trash", label: "Clear") { shelf.clear() }
                }
                .padding(6)
                .glass(18)
            }
        }
    }
}

struct SideAction: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(label).font(T.f(9.5, .medium))
            }
            .foregroundStyle(.white.opacity(hover ? 1 : 0.85))
            .frame(width: 60, height: 50)
            .background(.white.opacity(hover ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Empty tab: the symbol in a soft tinted tile, one line of guidance under it.
struct EmptyState: View {
    let symbol: String
    var tint: Color = .white
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.72)).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
    }
}

struct ShelfTile: View {
    let item: Shelf.Item
    let shelf: Shelf
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 48, height: 48)
            Text(item.name).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 78, height: 26, alignment: .top)
        }
        .padding(6)
        .background(.white.opacity(hover ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { withAnimation { shelf.remove(item) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                        .symbolRenderingMode(.palette).foregroundStyle(.black, .white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.name)")
            }
        }
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { NSWorkspace.shared.open(item.url) }
        .accessibilityAction(named: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        .accessibilityAction(named: "Remove") { shelf.remove(item) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("AirDrop") { shelf.airdrop([item.url]) }
            Divider()
            Button("Remove") { shelf.remove(item) }
        }
    }
}

// MARK: - Who peeked

/// Tab button with an unseen-incident badge.
struct WatchPill: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var log: GuardLog
    var lift = false

    var body: some View {
        if !log.events.isEmpty || m.tab == .watch {
            TabPill(symbol: "eye.fill", label: "Who looked at or touched your Mac", title: "Watch", active: m.tab == .watch,
                    badge: log.unseen.count, lift: lift) { m.tab = .watch }
        }
    }
}

/// Everyone Guard caught: face close-up, what they did, when. Click a card for the full photo.
struct WhoPeekedView: View {
    @ObservedObject var log: GuardLog

    var body: some View {
        HStack(spacing: 12) {
            if log.events.isEmpty {
                EmptyState(symbol: "eye.slash", tint: .teal, text: "Nobody has peeked. Arm Guard (shield) when you step away.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glass(18)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(log.events.reversed()) { PeekCard(e: $0, log: log) }
                    }
                    .padding(.vertical, 2)
                }
                .padding(10)
                .glass(18)
                VStack(spacing: 6) {
                    SideAction(symbol: "folder", label: "Photos") { NSWorkspace.shared.open(GuardMode.folder) }
                    SideAction(symbol: "trash", label: "Clear") { withAnimation { log.clear() } }
                }
                .padding(6)
                .glass(18)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { log.markAllSeen() } }
    }
}

struct PeekCard: View {
    let e: GuardEvent
    let log: GuardLog
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let img = log.thumbnail(e) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "hand.raised.slash.fill").font(.system(size: 22)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.06))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if !e.seen { Circle().fill(.orange).frame(width: 9, height: 9).offset(x: 3, y: -3) }
            }
            Text(short(e.reason)).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
            Text(e.date, format: .dateTime.hour().minute()).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(width: 78)
        .padding(5)
        .background(.white.opacity(hover ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture { if let u = log.photoURL(e) { NSWorkspace.shared.open(u) } }
        .help(e.reason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(e.reason + ", " + e.date.formatted(date: .omitted, time: .shortened) + (e.seen ? "" : ", new"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let u = log.photoURL(e) { NSWorkspace.shared.open(u) } }
    }

    private func short(_ r: String) -> String {
        let l = r.lowercased()
        if l.contains("looking") || l.contains("peek") { return "Looked at screen" }
        if l.contains("hiding") { return "Touched, hidden" }
        if l.contains("used") || l.contains("touched") { return "Touched Mac" }
        if l.contains("unknown face") { return "Unknown face" }
        return r
    }
}

// MARK: - Menu bar tray

/// Folded menu bar icons as a row you scroll with two fingers (here or up on the menu bar strip).
struct TrayView: View {
    @ObservedObject var m: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.trayItems.isEmpty {
                EmptyState(symbol: "menubar.rectangle", tint: .indigo,
                           text: m.collapser == nil ? "Turn on Fold menu bar in Settings."
                                : "No folded icons. ⌘-drag the │ divider to choose some.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { _ in
                    HStack(spacing: 0) {
                        ForEach(m.trayItems) { TrayIcon(item: $0, m: m) }
                    }
                    .offset(x: -m.trayOffset)
                    .animation(.interactiveSpring(response: 0.25), value: m.trayOffset)
                }
                .frame(height: 76)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                             .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                HStack {
                    Text("\(m.trayItems.count) folded · two-finger scroll · click to open").font(T.f(10)).foregroundStyle(.secondary)
                    Spacer()
                    if !MenuBarExtras.trusted {
                        Button("Allow opening") { MenuBarExtras.askForTrust() }.buttonStyle(.plain)
                            .font(T.f(10, .semibold)).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glass(18)
        .onAppear { m.refreshTray() }
    }
}

struct TrayIcon: View {
    let item: TrayItem
    let m: IslandModel
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: item.icon).resizable().frame(width: 38, height: 38)
                .scaleEffect(hover ? 1.08 : 1)
            Text(item.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1).frame(width: IslandModel.trayItemWidth - 8)
        }
        .frame(width: IslandModel.trayItemWidth, height: 70)
        .background(.white.opacity(hover ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { m.openTrayItem(item) }
        .help("Open \(item.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open \(item.name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { m.openTrayItem(item) }
    }
}

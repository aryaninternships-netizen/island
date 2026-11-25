import SwiftUI

// MARK: - Now (home)

/// One calm screen ranked by what matters this minute: a meeting about to start beats the music,
/// the music beats the clock. The right column is a short glance list that only shows live things.
struct NowView: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var hub: FeatureHub
    @ObservedObject var media: MediaController
    @ObservedObject var calendar: CalendarModel
    @ObservedObject var weather: Weather
    /// Narrow: start/stop, recap, offer. The live card observes the recorder itself.
    @ObservedObject var meeting: MeetingMode
    /// "+N" pressed: the column lists every live feature instead of the top three.
    @State private var showAll = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let soon = upcoming(at: ctx.date)
            let live = meeting.isRecording ? meeting.session : nil
            let recap = live == nil ? meeting.recap.flatMap { $0.fresh ? $0 : nil } : nil
            let showMeeting = live == nil && recap == nil && soon != nil
            HStack(spacing: 12) {
                // LiveMeetingCard > MeetingRecapCard > MeetingHero > media > clock. Keyboard-open (⌃⌥Space):
                // the command bar sits on top and the hero gives way to results while typing.
                Group {
                    if m.keyOpen {
                        CommandPane(m: m, bar: m.bar) { hero(live: live, recap: recap, soon: showMeeting ? soon : nil, now: ctx.date, compact: true) }
                    } else {
                        hero(live: live, recap: recap, soon: showMeeting ? soon : nil, now: ctx.date, compact: false)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .glass(18)
                column(skip: showMeeting ? soon?.id : nil, skipRecording: live != nil, now: ctx.date)
                    .frame(width: 212, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func hero(live: MeetingSession?, recap: MeetingRecap?, soon: CalendarModel.Item?, now: Date, compact: Bool) -> some View {
        if let s = live { LiveMeetingCard(meeting: meeting, s: s, rec: s.recorder) }
        else if let r = recap { MeetingRecapCard(meeting: meeting, r: r) }
        else if let e = soon { MeetingHero(e: e) { meeting.start() } }
        else if media.hasMedia { NowPlayingCard(media: media) }
        else { ClockHero(date: now, name: Pet.owner, compact: compact) }
    }

    /// A timed event starting within 15 min, or happening now.
    private func upcoming(at now: Date) -> CalendarModel.Item? {
        calendar.items.first { !$0.allDay && $0.start.timeIntervalSince(now) < 15 * 60 && $0.end > now }
    }

    /// Top three live features, then the dock. Fewer than three live: quiet glance rows fill in.
    /// 3 x 30 + 26 + 3 x 8 = 140 pt, inside the 154 pt body.
    private func column(skip: String?, skipRecording: Bool, now: Date) -> some View {
        // The meeting hero already carries Join and Record; the live card already carries Mark and Stop.
        let cards = hub.live.filter { !(skip != nil && $0.id == .meeting) && !(skipRecording && $0.id == .recording) }
        let top = Array(cards.prefix(3))
        let extra = cards.count - top.count
        // Nothing live: the dock grows a row of quick starts (Focus · 5m · 15m · Notes).
        let idle = cards.isEmpty
        let rows: [AnyView] = top.map { AnyView(FeatureCard(f: $0, m: m)) }
            + fill(skip: skip, now: now).prefix((idle ? 2 : 3) - top.count)
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if showAll && extra > 0 {
                    ScrollView(.vertical) {
                        VStack(spacing: 0) { ForEach(Array(cards.enumerated()), id: \.element.id) { i, f in
                            FeatureCard(f: f, m: m).overlay(alignment: .top) { if i > 0 { Hairline() } }
                        } }
                    }
                    .scrollIndicators(.never)
                    .frame(height: 3 * 32)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            r.overlay(alignment: .top) { if i > 0 { Hairline() } }
                        }
                    }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .glass(14)
            Spacer(minLength: 0)
            if idle {
                QuickRow(m: m)
            }
            DockRow(controls: hub.dock, extra: extra, showAll: $showAll)
        }
    }

    /// Glance rows for the empty slots: the weather, then what's next on the calendar.
    private func fill(skip: String?, now: Date) -> [AnyView] {
        var rows: [AnyView] = []
        if let t = weather.temp {
            rows.append(AnyView(GlanceRow(symbol: weather.symbol, tint: .yellow, title: "\(t)° \(weather.summary)",
                                          detail: weather.place.isEmpty ? nil : weather.place)))
        }
        if let e = calendar.items.first(where: { $0.id != skip }) {
            rows.append(AnyView(GlanceRow(symbol: "calendar", tint: Color(nsColor: e.color), title: e.title, detail: when(e, now: now))))
        } else if calendar.authorized {
            rows.append(AnyView(GlanceRow(symbol: "calendar", tint: .white.opacity(0.5), title: "Nothing else today")))
        }
        return rows
    }

    private func when(_ e: CalendarModel.Item, now: Date) -> String {
        if e.allDay { return "All day" }
        if e.start <= now { return "Now · until \(e.end.formatted(date: .omitted, time: .shortened))" }
        let mins = Int(e.start.timeIntervalSince(now) / 60)
        if mins < 60 { return "in \(mins) min" }
        return (Calendar.current.isDateInToday(e.start) ? "" : "Tomorrow ") + e.start.formatted(date: .omitted, time: .shortened)
    }
}

/// Quick starts when nothing is live: Focus, the two Desk timers, record notes.
struct QuickRow: View {
    @ObservedObject var m: IslandModel

    var body: some View {
        HStack(spacing: 6) {
            Chip(symbol: "brain.head.profile.fill", tint: .purple) { m.run(.focus) }
                .help("Focus \(Int(LiveTimers.focusMinutes)) min").accessibilityLabel("Focus \(Int(LiveTimers.focusMinutes)) minutes")
            Chip(label: "\(m.chipA)m", tint: .orange) { m.run(.timer(Double(m.chipA))) }
                .help("\(m.chipA) minute timer · scroll to change").accessibilityLabel("\(m.chipA) minute timer")
                .onHover { h in m.hoverScroll(.chipA, h) }
            Chip(label: "\(m.chipB)m", tint: .orange) { m.run(.timer(Double(m.chipB))) }
                .help("\(m.chipB) minute timer · scroll to change").accessibilityLabel("\(m.chipB) minute timer")
                .onHover { h in m.hoverScroll(.chipB, h) }
            Spacer(minLength: 0)
            Chip(symbol: "record.circle", tint: .red) { m.run(.meeting(.start, [:])) }
                .help("Record meeting notes (⌃⌥R)").accessibilityLabel("Record meeting notes")
        }
        .frame(height: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick starts")
    }
}

/// One live feature on Home: symbol, title, a short detail (or its live clock), up to two icon controls.
/// The row is a button (it opens the feature's tab); the timer and Keep Awake rows take scroll.
struct FeatureCard: View {
    let f: FeatureSnapshot
    let m: IslandModel

    private var scrollTarget: IslandModel.ScrollTarget? {
        switch f.id {
        case .timer: f.trailing.clockStart != nil && f.title != "Stopwatch" ? .timer : nil
        case .keepAwake: f.controls.contains { $0.id == "awake.more" } ? .awake : nil
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: f.symbol, tint: f.tint)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(f.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    if f.trailing == .spinner { Spinner(tint: f.tint).frame(width: 9, height: 9) }
                }
                second
            }
            Spacer(minLength: 4)
            ForEach(f.controls.prefix(2)) { CardButton(c: $0) }
        }
        .padding(.leading, 5).padding(.trailing, 4)
        .frame(height: 32)
        .background(.white.opacity(hover && tappable ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: tap)
        .onHover { h in
            hover = h
            if let t = scrollTarget { m.hoverScroll(t, h) }
        }
        .help(scrollTarget == .timer ? "Scroll to add or take a minute" : scrollTarget == .awake ? "Scroll to add or take an hour" : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(f.title + (f.detail.map { ", " + $0 } ?? ""))
        .accessibilityAction(named: "Open", tap)
    }

    @State private var hover = false

    /// Where a click on the row goes: the feature's own tab, or Desk for a timer (its ring and Stop).
    private var destination: IslandModel.Tab? {
        if case .tab(let t) = f.tap { return t }
        return f.id == .timer ? .desk : nil
    }

    private var tappable: Bool { destination != nil }

    private func tap() {
        guard let t = destination else { return }
        if t == .tray { m.refreshTray() }
        m.tab = t
    }

    @ViewBuilder private var second: some View {
        if case .clock(let d, let up) = f.trailing {
            // Ticks only while Home is on screen, like the glance clock it replaces.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(clockText(up ? ctx.date.timeIntervalSince(d) : d.timeIntervalSince(ctx.date)))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(f.tint.opacity(0.9))
            }
        } else if let detail = f.detail {
            Text(detail).font(T.f(10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// Small round icon control on a card. Icon only, so it always carries a label and a tooltip.
struct CardButton: View {
    let c: FeatureControl
    @State private var hover = false

    var body: some View {
        Button(action: c.run) {
            Image(systemName: c.symbol).font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(c.on ? .black : c.tint)
                .frame(width: 22, height: 22)
                .background(c.on ? AnyShapeStyle(c.tint) : AnyShapeStyle(c.tint.opacity(hover ? 0.24 : 0.13)), in: Circle())
                .hiContrastStroke(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(c.a11y)
        .accessibilityLabel(c.a11y)
        .accessibilityValue(c.on ? "On" : "")
    }
}

/// The toggles that used to live on Desk and in the header (Guard, Presence, Keep Awake, Quiet),
/// plus "+N" when more features are live than the three cards show.
struct DockRow: View {
    let controls: [FeatureControl]
    let extra: Int
    @Binding var showAll: Bool
    /// Name of the toggle under the pointer, shown at once above the dock (tooltips are slow
    /// and often never appear in a non-key panel).
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(controls) { c in
                DockToggle(c: c) { h in
                    withAnimation(.easeOut(duration: 0.12)) {
                        if h { hovered = c.a11y } else if hovered == c.a11y { hovered = nil }
                    }
                }
                .frame(maxWidth: .infinity)   // spread evenly across the capsule
            }
            if showAll && extra > 0 {
                DockToggle(c: FeatureControl(id: "dock.less", symbol: "chevron.up", a11y: "Show the top three", tint: .white) {
                    withAnimation(.easeOut(duration: 0.18)) { showAll = false }
                })
            } else if extra > 0 {
                Button { withAnimation(.easeOut(duration: 0.18)) { showAll = true } } label: {
                    Text("+\(extra)").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("\(extra) more live").accessibilityLabel("Show \(extra) more")
            }
        }
        .padding(4)
        .glass(17)
        .overlay(alignment: .top) {
            if let hovered {
                Text(hovered).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 9).frame(height: 20)
                    .background(.black.opacity(0.75), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .offset(y: -24)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick toggles")
    }
}

/// A dock toggle: white glyph when off (reads on any backdrop), filled with its colour when on.
struct DockToggle: View {
    let c: FeatureControl
    var onHover: (Bool) -> Void = { _ in }
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var rm

    var body: some View {
        Button(action: c.run) {
            Image(systemName: c.symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(c.on ? .black : .white.opacity(hover ? 1 : 0.82))
                .frame(width: 36, height: 26)
                .background(c.on ? AnyShapeStyle(c.tint) : AnyShapeStyle(.white.opacity(hover ? 0.14 : 0.0)), in: Capsule())
                .scaleEffect(hover && !rm ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0; onHover($0) }
        .help(c.a11y).accessibilityLabel(c.a11y)
        .accessibilityValue(c.on ? "On" : "Off")
    }
}

/// Feature icon in a tinted rounded tile (iOS Settings style), so every row starts the same way.
struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Panel heading: a small icon tile and a title, used at the top of every glass panel.
struct PanelHeader<T: View>: View {
    let symbol: String
    let title: String
    var tint: Color = .white
    @ViewBuilder var trailing: T

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 4)
            trailing
        }
        .frame(height: 22)
        .accessibilityElement(children: .contain)
    }
}

extension PanelHeader where T == EmptyView {
    init(symbol: String, title: String, tint: Color = .white) {
        self.init(symbol: symbol, title: title, tint: tint) { EmptyView() }
    }
}

/// Sunken input well inside a glass panel (text fields, the note editor).
struct InsetWell: ViewModifier {
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content.background {
            let s = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                s.fill(.black.opacity(0.28))
                s.strokeBorder(LinearGradient(colors: [.black.opacity(0.35), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                               lineWidth: 0.75)
            }
        }
    }
}

/// Row separator inside a glass list, inset past the icon tile.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 35).padding(.trailing, 6)
    }
}

/// Home's frosted panel: dark tint for contrast, a faint top-lit fill, a hairline edge brighter at the
/// top, and a soft shadow, so panels float over the Cosmos backdrop without hiding it.
struct GlassPanel: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            let s = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                s.fill(.black.opacity(0.30))
                s.fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.025)], startPoint: .top, endPoint: .bottom))
                s.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                               lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
    }
}

extension View {
    func glass(_ radius: CGFloat = 16) -> some View { modifier(GlassPanel(radius: radius)) }
}

struct GlanceRow<T: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: T

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) } // 10.5 floor
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 5).padding(.trailing, 4)
        .frame(height: 32)
        .accessibilityElement(children: .combine)
    }
}

extension GlanceRow where T == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail) { EmptyView() }
    }
}

struct LiveClock: View {
    @ObservedObject var timers: LiveTimers
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = timers.end.map { $0.timeIntervalSince(ctx.date) } ?? ctx.date.timeIntervalSince(timers.start)
            Text(clockText(s)).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText(countsDown: timers.end != nil))
        }
    }
}

/// Nothing urgent, nothing playing: the time, big and quiet.
struct ClockHero: View {
    let date: Date
    let name: String
    /// Under the command bar: a smaller clock so the pair fits the 154 pt body.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting + (name.isEmpty ? "" : ", \(name)")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: compact ? 36 : 46, weight: .light, design: .rounded)).monospacedDigit()
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Late night"
        }
    }
}

/// A meeting within 15 minutes takes the stage: countdown and a one-click Join.
struct MeetingHero: View {
    let e: CalendarModel.Item
    var notes: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = e.start.timeIntervalSince(ctx.date)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Circle().fill(Color(nsColor: e.color)).frame(width: 7, height: 7)
                        Text(left > 0 ? "Up next" : "Happening now").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(e.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text(left > 0 ? "starts in " + clockText(left) : "until " + e.end.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(left > 0 && left < 120 ? .orange : .white.opacity(0.75))
                }
                Spacer(minLength: 0)
                Chip(symbol: "record.circle", label: "Record", tint: .red, action: notes)
                    .help("Record this meeting (⌃⌥R)")
                if let link = e.link {
                    Button { NSWorkspace.shared.open(link) } label: {
                        Label("Join", systemImage: "video.fill").font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.green, in: Capsule()).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Meeting cards

/// Recording now: transcript tail, marks, a one-line note that becomes a mark, Mark / Stop / Notes.
struct LiveMeetingCard: View {
    @ObservedObject var meeting: MeetingMode
    @ObservedObject var s: MeetingSession
    @ObservedObject var rec: MeetingRecorder
    @State private var note = ""
    @Environment(\.colorSchemeContrast) private var contrast

    private var lines: [String] {
        let live = rec.partial.keys.sorted().compactMap { rec.partial[$0] }.filter { !$0.isEmpty }
        return Array((rec.segments.suffix(3).map(\.text) + live).suffix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(.red.opacity(0.75)).frame(width: 6, height: 6)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(clockText(ctx.date.timeIntervalSince(rec.start)))
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                }
                Text(s.title.isEmpty ? "Meeting" : s.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if !rec.marks.isEmpty {
                    Text("\(rec.marks.count) mark\(rec.marks.count == 1 ? "" : "s")")
                        .font(T.f(10, .medium)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 2) {
                if lines.isEmpty {
                    Text(rec.problem ?? "Listening… written on this Mac").font(.system(size: 11)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.35)))
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    Text(l).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(.white.opacity(i == lines.count - 1 ? 0.85 : Dim.text(contrast, 0.45)))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live transcript")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottomLeading)
            HStack(spacing: 6) {
                TextField("Note, then Return to mark", text: $note)
                    .textFieldStyle(.plain).font(.system(size: 11.5))
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(.white.opacity(0.06), in: Capsule())
                    .onSubmit { markNow() }
                    .accessibilityLabel("Note, then Return to mark")
                Chip(symbol: "bookmark.fill", label: "Mark", tint: .red) { markNow() }
                    .help("Mark this moment (⌃⌥M)")
                    .accessibilityLabel("Mark this moment")
                Chip(symbol: "stop.fill", tint: .red) { meeting.stop() }
                    .help("Stop and write notes (⌃⌥R)").accessibilityLabel("Stop recording")
                Chip(symbol: "note.text", tint: .white) { meeting.openNotes() }
                    .help("Open the notes window").accessibilityLabel("Open notes")
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func markNow() {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.mark(n.isEmpty ? nil : n)
        note = ""
    }
}

/// A meeting that just ended: three bullets, action items to pick for Reminders, Copy, Finder, Dismiss.
/// The title is editable: Return renames the meeting and its folder.
struct MeetingRecapCard: View {
    @ObservedObject var meeting: MeetingMode
    let r: MeetingRecap
    @State private var title = ""

    private var picked: Int { r.actions.filter { $0.picked && !$0.sent }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().stroke(.white.opacity(0.5), lineWidth: 1).frame(width: 6, height: 6)
                TextField("Meeting", text: $title)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .onSubmit { meeting.rename(title) }
                    .disabled(r.pending)
                    .help("Rename the meeting and its folder")
                    .accessibilityLabel("Meeting title")
                Text(clockText(r.length) + (r.marks > 0 ? " · \(r.marks) mark\(r.marks == 1 ? "" : "s")" : ""))
                    .font(T.f(10, .regular, .monospaced)).foregroundStyle(.secondary).fixedSize()
            }
            if r.pending {
                HStack(spacing: 7) {
                    Spinner(tint: .white.opacity(0.6)).frame(width: 10, height: 10)
                    Text("Writing notes on this Mac…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(r.summary.prefix(3).enumerated()), id: \.offset) { _, b in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(.white.opacity(0.35)).frame(width: 3, height: 3).offset(y: -2)
                                Text(b).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                            }
                        }
                        if !r.actions.isEmpty {
                            Text("Actions").font(T.f(9.5, .semibold)).foregroundStyle(.secondary).padding(.top, 3)
                            ForEach(r.actions) { a in actionRow(a) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                if picked > 0 {
                    Chip(symbol: "list.bullet", label: "Remind \(picked)", tint: .orange) { meeting.sendPicked() }
                        .help("Add the picked action items to Reminders › Island Meetings")
                        .accessibilityLabel("Add \(picked) to Reminders")
                }
                Spacer(minLength: 0)
                Chip(symbol: "doc.on.doc", tint: .white) { meeting.copyRecap() }
                    .help("Copy notes as Markdown").accessibilityLabel("Copy notes as Markdown")
                Chip(symbol: "folder", tint: .white) { meeting.revealRecap() }
                    .help("Show notes and recording in Finder").accessibilityLabel("Show in Finder")
                Chip(symbol: "xmark", tint: .white) { meeting.dismissRecap() }
                    .help("Dismiss this recap").accessibilityLabel("Dismiss recap")
            }
            .disabled(r.pending)
        }
        .frame(maxHeight: .infinity)
        .onAppear { title = r.title }
        .onChange(of: r.title) { _, t in title = t }
    }

    /// Filled dot: picked for Reminders. Hollow: not. Dim filled: already in Reminders.
    private func actionRow(_ a: MeetingRecap.Action) -> some View {
        let state = a.sent ? "Already in Reminders" : a.picked ? "Picked for Reminders" : "Pick for Reminders"
        return Button { meeting.togglePick(a.id) } label: {
            HStack(spacing: 7) {
                ZStack {
                    if a.picked || a.sent { Circle().fill(.orange.opacity(a.sent ? 0.4 : 1)) }
                    else { Circle().stroke(.orange.opacity(0.7), lineWidth: 1.2) }
                }
                .frame(width: 7, height: 7)
                Text(a.text).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(.white.opacity(a.sent ? 0.4 : 0.85))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(a.sent)
        .help(state)
        .accessibilityLabel(a.text + ", " + state)
    }
}

// MARK: - Desk

/// A row of actions (Record, Prompter, timers) over two panels: a quick note and clipboard history.
struct DeskView: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var timers: LiveTimers
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject private var prompter = Prompter.shared
    @AppStorage("quickNote") private var note = ""
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 8) {
            // One even row of actions: meeting tools, then time.
            HStack(spacing: 6) {
                DeskButton(symbol: m.recording ? "stop.fill" : "record.circle", title: m.recording ? "Stop" : "Record",
                           hint: m.recording ? nil : "⌃⌥R", tint: .red, on: m.recording) { m.meeting.toggle() }
                    .help(m.recording ? "Stop recording and write notes (⌃⌥R)" : "Record a meeting from the notch (⌃⌥R)")
                    .accessibilityLabel(m.recording ? "Stop recording" : "Record a meeting")
                    .frame(width: 112)
                DeskButton(symbol: "text.alignleft", title: "Prompter", hint: prompter.on ? nil : "⌃⌥P", tint: .green, on: prompter.on) {
                    m.requestClose?()
                    PrompterScriptWindow.shared.show()
                }
                .help("Paste a script and start the teleprompter (⌃⌥P starts the last one)")
                .accessibilityLabel("Teleprompter")
                .frame(width: 118)
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 20).padding(.horizontal, 2)
                timerArea
            }
            .frame(height: 34)
            HStack(alignment: .top, spacing: 10) {
                noteCard
                ClipList(clipboard: clipboard)
                    .padding(12)
                    .frame(width: 290)
                    .glass(18)
            }
        }
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeader(symbol: "note.text", title: "Quick note", tint: .yellow) {
                // ⌘↩: the note becomes a timestamped line in today's file (or a mark while recording).
                Button(action: logNote) {
                    HStack(spacing: 4) {
                        Text("Save").font(.system(size: 10.5, weight: .semibold))
                        Text("⌘↩").font(.system(size: 10, weight: .medium)).opacity(0.6)
                    }
                    .foregroundStyle(blankNote ? .white.opacity(0.3) : .black)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(blankNote ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(Color.yellow.opacity(0.9)), in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(blankNote)
                .help(m.recording ? "Add to the meeting notes (⌘↩)" : "Append to today's notes in Documents › Island Notes (⌘↩)")
                .accessibilityLabel(m.recording ? "Add to the meeting notes" : "Append to today's notes")
            }
            ZStack(alignment: .topLeading) {
                if note.isEmpty {
                    Text(m.recording ? "Jot something for this meeting…" : "Jot something down…")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.3)))
                        .padding(.horizontal, 5).padding(.top, 1)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $note).font(.system(size: 11.5)).scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .accessibilityLabel("Quick note")
            }
            .padding(6)
            .frame(maxHeight: .infinity)
            .modifier(InsetWell())
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glass(18)
    }

    private var blankNote: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func logNote() {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        m.appendNote(t)
        note = ""
    }

    @ViewBuilder private var timerArea: some View {
        if let k = timers.kind {
            HStack(spacing: 10) {
                ZStack {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        ZStack {
                            Circle().stroke(.white.opacity(0.12), lineWidth: 2.5)
                            Circle().trim(from: 0, to: 1 - (timers.progress(at: ctx.date) ?? 0))
                                .stroke(tint(k), style: .init(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                        }
                    }
                    Image(systemName: symbol(k)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint(k))
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                Text(k == .focus ? "Focus" : k == .rest ? "Break" : k == .stopwatch ? "Stopwatch" : "Timer")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                LiveClock(timers: timers, size: 16)
                Spacer(minLength: 4)
                Chip(symbol: "stop.fill", label: "Stop", tint: .red) { timers.stop() }
                    .accessibilityLabel("Stop timer")
                    .scaleEffect(0.92)
            }
            .padding(.leading, 6).padding(.trailing, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint(k).opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint(k).opacity(0.3), lineWidth: 1))
            .accessibilityElement(children: .contain)
        } else {
            DeskButton(symbol: "timer", title: "\(m.chipA)m", tint: .orange) { timers.timer(minutes: Double(m.chipA)) }
                .help("\(m.chipA) minute timer · scroll to change").onHover { h in m.hoverScroll(.chipA, h) }
                .accessibilityLabel("\(m.chipA) minute timer")
            DeskButton(symbol: "timer", title: "\(m.chipB)m", tint: .orange) { timers.timer(minutes: Double(m.chipB)) }
                .help("\(m.chipB) minute timer · scroll to change").onHover { h in m.hoverScroll(.chipB, h) }
                .accessibilityLabel("\(m.chipB) minute timer")
            DeskButton(symbol: "brain.head.profile.fill", title: "Focus", tint: .purple) { timers.focus() }
                .help("\(Int(LiveTimers.focusMinutes)) min focus, then a \(Int(LiveTimers.restMinutes)) min break")
                .accessibilityLabel("Focus \(Int(LiveTimers.focusMinutes)) minutes")
            DeskButton(symbol: "stopwatch.fill", title: "Stopwatch", tint: .teal) { timers.stopwatch() }
                .accessibilityLabel("Stopwatch")
        }
    }

    private func tint(_ k: LiveTimers.Kind) -> Color { k == .focus ? .purple : k == .rest ? .teal : .orange }
    private func symbol(_ k: LiveTimers.Kind) -> String {
        switch k {
        case .timer: "timer"
        case .stopwatch: "stopwatch.fill"
        case .focus: "brain.head.profile.fill"
        case .rest: "cup.and.heat.waves.fill"
        }
    }
}

/// One even button in the Desk's top row: tinted icon, white title, an optional dim shortcut.
/// Neutral glass at rest so the row reads as one set; `on` washes it in its colour.
struct DeskButton: View {
    let symbol: String
    let title: String
    var hint: String? = nil
    let tint: Color
    var on = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1).fixedSize()
                if let hint {
                    Text(hint).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.35)).fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(on ? AnyShapeStyle(tint.opacity(0.22)) : AnyShapeStyle(.white.opacity(hover ? 0.11 : 0.06)),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(on ? tint.opacity(0.55) : .white.opacity(hover ? 0.14 : 0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Equal-width timer button (the Desk's top row).
struct TimeTile: View {
    var symbol: String? = nil
    var label: String? = nil
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                if let label { Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).fixedSize() }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(tint.opacity(hover ? 0.24 : 0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .hiContrastStroke(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Tall square-ish action: icon in a tinted circle, title, one quiet line under it.
struct ActionTile: View {
    let symbol: String
    let title: String
    let sub: String
    let tint: Color
    var on = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                    .foregroundStyle(on ? .black : tint)
                    .frame(width: 26, height: 26)
                    .background(on ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.2)), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.92))
                    Text(sub).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint.opacity(hover ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(on ? 0.5 : 0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Pill button: tinted wash, label never truncates, `on` fills it (toggles like Quiet).
struct Chip: View {
    var symbol: String? = nil
    var label: String? = nil
    var tint: Color = .white
    var on = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var rm

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                if let label { Text(label).font(.system(size: 11.5, weight: .semibold, design: .rounded)).fixedSize() }
            }
            .foregroundStyle(on ? .black : tint)
            .padding(.horizontal, label == nil ? 0 : 10)
            .frame(minWidth: 28, minHeight: 26)
            .background(on ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(hover ? 0.24 : 0.13)), in: Capsule())
            .hiContrastStroke(Capsule())
            .scaleEffect(hover && !rm ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ClipList: View {
    @ObservedObject var clipboard: ClipboardHistory
    @State private var copied: UUID?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PanelHeader(symbol: "doc.on.clipboard", title: "Clipboard", tint: .cyan)
                if !clipboard.pins.isEmpty {
                    Text("\(clipboard.pins.count) pinned").font(T.f(10)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.35)))
                }
                if !clipboard.clips.isEmpty {
                    Button("Clear") { clipboard.clear() }.buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.45)))
                        .accessibilityLabel("Clear clipboard history")
                }
            }
            if clipboard.all.isEmpty {
                VStack(spacing: 3) {
                    Text(clipboard.enabled ? "Nothing copied yet" : "Clipboard history is off").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(Dim.text(contrast, 0.6)))
                    Text(clipboard.enabled ? "Kept in memory only · passwords skipped" : "Turn it on in Settings › General").font(.system(size: 10))
                        .foregroundStyle(.white.opacity(Dim.text(contrast, 0.35)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 3) {
                        ForEach(clipboard.all) { c in
                            ClipRow(clip: c, copied: copied == c.id, pinned: clipboard.isPinned(c)) {
                                clipboard.copy(c)
                                copied = clipboard.isPinned(c) ? c.id : clipboard.clips.first?.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = nil }
                            } remove: { clipboard.remove(c) } pin: { clipboard.togglePin(c) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ClipRow: View {
    let clip: ClipboardHistory.Clip
    let copied: Bool
    var pinned = false
    let copy: () -> Void
    let remove: () -> Void
    var pin: () -> Void = {}
    @State private var hover = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var preview: String {
        clip.image != nil ? "Image"
            : (clip.text ?? "").split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    @ViewBuilder private var trailing: some View {
        if copied {
            Text("Copied").font(T.f(10, .semibold)).foregroundStyle(.green)
        } else {
            if !hover, !pinned {
                Text(clip.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(T.f(9.5)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.3)))
            }
            // Pin: filled dot pinned, hollow on hover to pin. Text clips only.
            if clip.text != nil, pinned || hover {
                Button(action: pin) { Dot(on: pinned, tint: .orange).padding(3).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(pinned ? "Unpin" : "Pin: keep it across restarts")
                    .accessibilityHidden(true)
            }
            // Delete is always there (dim), so it can be found without hovering.
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(hover ? 0.5 : Dim.text(contrast, 0.35)))
                .help("Delete")
                .accessibilityHidden(true) // the row carries a Delete action instead
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            if let img = clip.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 26, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Text(preview).font(.system(size: 11.5)).lineLimit(1)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(.white.opacity(hover ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    var body: some View {
        let hint: String = clip.app.map { "From \($0). Copies to the clipboard" } ?? "Copies to the clipboard"
        return row
            .onTapGesture(perform: copy)
            .onHover { hover = $0 }
            .help(clip.app.map { "From \($0) · click to copy" } ?? "Click to copy")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(preview)
            .accessibilityHint(hint)
            .accessibilityValue(copied ? "Copied" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, copy)
            .accessibilityAction(named: "Delete", remove)
            .accessibilityAction(named: pinned ? "Unpin" : "Pin", pin)
    }
}

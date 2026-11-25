import AppKit
import Combine
import SwiftUI

// MARK: - Command core
//
// One vocabulary for every way in: island:// URLs (scripts, the Claude hook, `bin/island`), the
// ⌃⌥Space command bar and the status menu. Everything lands in `IslandModel.run(_:)`.

enum MeetingVerb: String { case start, stop, toggle, mark, hide, discard, notes, offer, recover }

enum Command: Equatable {
    case open(IslandModel.Tab?)
    case close
    case timer(Double)
    case focus
    case stopwatch
    case stop
    /// Hours. nil = until switched off, 0 = off.
    case awake(Double?)
    case hush
    case guardNow
    case notes
    case meeting(MeetingVerb, [String: String])
    case note(String)
    case chat(String)
    case clipFilter(String)
    /// `waiting`: the Claude hook's `state=waiting` (a session that needs you).
    case notify(Activity, waiting: Bool)
    case dismiss(String)
    /// island://mb?expand
    case menuBar(expand: Bool)
    /// Every other verb (pup, facescan, nap, lockface, away, sharetest…), handled as before.
    case verb(String, [String: String])

    /// Verbs handled by `IslandModel.runVerb`, kept working for scripts and design previews.
    static let verbs: Set<String> = ["sky", "flair", "dog", "whopeeked", "registerface", "facetest", "shieldtest", "pup", "nap", "dance",
                                     "nudge", "sharetest", "facescan", "lockface", "away", "transcribetest", "prompter", "share"]
    /// Every host the URL side understands (typed ones plus `verbs`).
    static let hosts: Set<String> = verbs.union(["notify", "dismiss", "open", "close", "timer", "focus", "stopwatch",
                                                 "stoptimer", "awake", "hush", "guard", "notes", "meeting", "mb"])

    static func parse(url: URL) -> Command? {
        guard url.scheme == "island" || url.scheme == nil,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var q: [String: String] = [:]
        c.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        let host = (c.host ?? "").lowercased()
        switch host {
        case "dismiss": return .dismiss(q["id"] ?? "notify")
        case "open":
            // island://open?tab=now|home|desk|shelf|watch|pet|tray|settings
            return .open(q["tab"].flatMap { IslandModel.Tab(rawValue: $0 == "now" ? "home" : $0) })
        case "close": return .close
        case "timer": return .timer(Double(q["min"] ?? "") ?? 5)
        case "focus": return .focus
        case "stopwatch": return .stopwatch
        case "stoptimer": return .stop
        case "awake": // hours=3 | hours=0 (off) | hours=-1 (until off)
            let h = Double(q["hours"] ?? "") ?? 3
            return .awake(h < 0 ? nil : h)
        case "hush": return .hush
        case "guard": return .guardNow
        case "notes": return .notes
        case "meeting": return .meeting(MeetingVerb(rawValue: q["do"] ?? "toggle") ?? .toggle, q)
        case "mb": return .menuBar(expand: q.keys.contains("expand") || url.query == "expand")
        case _ where verbs.contains(host): return .verb(host, q)
        default:
            // island://notify?title=..&body=..&icon=sf.symbol&color=hex&id=..&sticky=1&progress=0.4&spinner=1&state=waiting
            // (any unknown host notifies, as it always has)
            let id = q["id"] ?? "notify"
            var a = Activity(id: id, symbol: q["icon"] ?? "bell.fill", tint: Color(hex: q["color"] ?? "") ?? .white,
                             title: q["title"] ?? "", body: q["body"] ?? "")
            if let p = q["progress"], let v = Double(p) {
                a.trailing = .progress(min(max(v, 0), 1))
            } else if q["spinner"] == "1" {
                a.trailing = .spinner
            } else if let t = q["trailing"] {
                a.trailing = .text(t)
            }
            a.banner = !a.body.isEmpty || q["banner"] == "1"
            a.sticky = q["sticky"] == "1"
            a.duration = Double(q["duration"] ?? "") ?? 3.5
            return .notify(a, waiting: q["state"] == "waiting")
        }
    }

    /// The command bar grammar.
    ///   25 · t 25 · t 1h30   timer          f        focus
    ///   a · a 2h · a off     keep awake     q        quiet
    ///   g                    guard now      n        record meeting notes
    ///   > text               append a note  desk, pet, settings…  open that tab
    ///   any island verb with key=value args: `meeting do=mark`, `notify title=Hi`, `island://…`
    ///   anything else filters the clipboard
    static func parse(text raw: String) -> Command? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("island://") { return URL(string: s).flatMap(parse(url:)) }
        // "b hi" / "bruno hi": talk to the pup (his tiny on-device model replies in a banner).
        if let r = s.range(of: #"^(b|bruno)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let t = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : .chat(t)
        }
        if s.hasPrefix(">") {
            let t = s.dropFirst().trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : .note(t)
        }
        let words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        let head = words[0].lowercased()
        let arg = words.count > 1 ? words[1].lowercased() : nil
        if words.count == 1, let m = minutes(head) { return .timer(m) }
        switch head {
        case "t" where arg != nil:
            if let a = arg, let m = minutes(a) { return .timer(m) }
        case "f" where words.count == 1: return .focus
        case "a" where words.count <= 2:
            guard let a = arg else { return .awake(3) }
            if ["off", "0", "stop"].contains(a) { return .awake(0) }
            if ["on", "forever", "inf", "∞"].contains(a) { return .awake(nil) }
            if let m = minutes(a, unit: 60) { return .awake(m / 60) }
        case "q" where words.count == 1: return .hush
        case "g" where words.count == 1: return .guardNow
        case "n" where words.count == 1: return .meeting(.start, [:])
        case "stop" where words.count == 1: return .stop
        case "now" where words.count == 1: return .open(.home)
        default: break
        }
        if words.count == 1, let t = IslandModel.Tab(rawValue: head), t != .welcome { return .open(t) }
        if hosts.contains(head) {
            // `verb k=v k=v`: the URL verbs, typed.
            var c = URLComponents()
            c.scheme = "island"; c.host = head
            let pairs = words.dropFirst().compactMap { w -> URLQueryItem? in
                let kv = w.split(separator: "=", maxSplits: 1).map(String.init)
                return kv.count == 2 ? URLQueryItem(name: kv[0], value: kv[1]) : nil
            }
            if !pairs.isEmpty { c.queryItems = pairs }
            if let u = c.url { return parse(url: u) }
        }
        return .clipFilter(s)
    }

    /// "25", "25m", "1h", "1h30", "1.5h", "90s" as minutes. `unit` is the minutes a bare number means.
    static func minutes(_ s: String, unit: Double = 1) -> Double? {
        let t = s.lowercased()
        if let v = Double(t) { return v > 0 && v <= 24 * 60 ? v * unit : nil }
        var total = 0.0, num = "", any = false
        for ch in t {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard let v = Double(num) else { return nil }
            switch ch {
            case "h": total += v * 60
            case "m": total += v
            case "s": total += v / 60
            default: return nil
            }
            num = ""; any = true
        }
        if !num.isEmpty {
            guard let v = Double(num), any else { return nil }
            total += v // "1h30": trailing minutes
        }
        return any && total > 0 && total <= 24 * 60 ? total : nil
    }

    /// One line the bar shows before Return.
    var preview: (symbol: String, text: String) {
        switch self {
        case .open(let t): ("arrow.up.right", "Open " + (t.map(\.title) ?? "Island"))
        case .close: ("xmark", "Close")
        case .timer(let m): ("timer", "Timer " + Self.span(m))
        case .focus: ("brain.head.profile.fill", "Focus \(Int(LiveTimers.focusMinutes)) min")
        case .stopwatch: ("stopwatch.fill", "Stopwatch")
        case .stop: ("stop.fill", "Stop the timer")
        case .awake(let h):
            switch h {
            case nil: ("cup.and.heat.waves.fill", "Keep awake until off")
            case 0?: ("cup.and.saucer", "Keep Awake off")
            case let h?: ("cup.and.heat.waves.fill", "Keep awake " + Self.span(h * 60))
            }
        case .hush: ("moon.fill", "Toggle Quiet")
        case .guardNow: ("lock.shield.fill", "Guard now")
        case .notes: ("note.text", "Open meeting notes")
        case .meeting(let v, _): ("record.circle", v == .start ? "Record meeting notes" : "Meeting " + v.rawValue)
        case .note(let t): ("text.append", "Note: " + t)
        case .chat(let t): ("pawprint.fill", "Say to the pup: " + t)
        case .clipFilter: ("doc.on.clipboard", "Copy the first match")
        case .notify(let a, _): ("bell", "Notify " + a.title)
        case .dismiss(let id): ("xmark", "Dismiss " + id)
        case .menuBar(let e): ("menubar.rectangle", e ? "Show menu bar icons" : "Fold menu bar icons")
        case .verb(let v, _): ("chevron.right", v)
        }
    }

    static func span(_ minutes: Double) -> String {
        if minutes < 1 { return "\(Int((minutes * 60).rounded())) s" }
        let m = Int(minutes.rounded())
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
    }
}

extension IslandModel.Tab {
    var title: String {
        switch self {
        case .home: "Home"
        case .desk: "Desk"
        case .shelf: "Shelf"
        case .watch: "Watch"
        case .pet: "Pet"
        case .tray: "Tray"
        case .settings: "Settings"
        case .welcome: "Welcome"
        }
    }
}

// MARK: - Dispatcher

extension IslandModel {
    /// The one dispatcher: URLs, the command bar and the menu all end here.
    func run(_ c: Command?) {
        guard let c else { return }
        switch c {
        case .open(let t):
            if paused { pause(hours: nil) } // asking to open ends a pause
            if t == .tray { refreshTray() }
            openTab?(t)
        case .close: requestClose?()
        case .timer(let m): timers.timer(minutes: m)
        case .focus: timers.focus()
        case .stopwatch: timers.stopwatch()
        case .stop: timers.stop()
        case .awake(let h):
            if h == 0 { keepAwake.stop() } else { keepAwake.start(hours: h) }
        case .hush:
            hush.toggle()
            show(Activity(id: "hush", symbol: hush ? "moon.fill" : "moon", tint: .purple,
                          trailing: .text(hush ? "Quiet" : "On"), duration: 1.6))
            if hush { modeOn(.purple) }
        case .guardNow: toggleGuard()
        case .notes: meeting.openNotes()
        case .meeting(let v, let q):
            switch v {
            case .start: meeting.start(title: q["title"])
            case .stop: meeting.stop()
            case .mark: meeting.mark(q["note"])
            case .hide: meeting.presenting.toggle()
            case .discard: meeting.discard()
            case .notes: meeting.openNotes()
            case .offer: meeting.fakeOffer(app: q["app"] ?? "Zoom")
            case .recover: meeting.recover()
            case .toggle: meeting.toggle()
            }
        case .note(let t): appendNote(t)
        case .chat(let t): chatWithPup(t)
        case .clipFilter(let f):
            if let c = clipboard.matches(f).first { clipboard.copy(c) }
        case .notify(let a, let waiting):
            // Claude hook: `state=waiting` marks a session that needs you (attention, not a spinner).
            if a.sticky, ClaudeFeature.owns(a.id) { claude.upsert(a.id, waiting: waiting); return }
            show(a)
        case .dismiss(let id): dismiss(id: id)
        case .menuBar(let e): if e { collapser?.expand() } else { collapser?.collapse() }
        case .verb(let v, let q): runVerb(v, q)
        }
    }

    /// While recording, the line becomes a mark in the meeting notes; otherwise it goes to today's file.
    func appendNote(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if recording { meeting.mark(t); return }
        // Documents can raise a privacy prompt: write off the main thread so Island never freezes.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = QuickLog.append(t)
            DispatchQueue.main.async {
                self?.show(Activity(id: "note", symbol: ok ? "text.append" : "exclamationmark.triangle.fill", tint: ok ? .white : .orange,
                                    trailing: .text(ok ? "Noted" : "Failed"), duration: 1.6))
            }
        }
    }
}

/// `~/Documents/Island Notes/YYYY-MM-DD.md`, one timestamped line per note.
enum QuickLog {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Island Notes", isDirectory: true)
    }

    @discardableResult
    static func append(_ text: String, at date: Date = Date()) -> Bool {
        let fm = FileManager.default
        let day = date.formatted(.iso8601.year().month().day())
        let url = folder.appendingPathComponent(day + ".md")
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let line = "- \(time) " + text.replacingOccurrences(of: "\n", with: " ") + "\n"
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                try ("# " + day + "\n\n").write(to: url, atomically: true, encoding: .utf8)
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(line.utf8))
            return true
        } catch {
            NSLog("Island: note \(error)")
            return false
        }
    }
}

// MARK: - Command bar

/// What's typed in the ⌃⌥Space bar. Its own object, so a keystroke redraws the bar, not the island.
final class CommandBarState: ObservableObject {
    @Published var text = ""
    /// Bumped to pull focus back into the field (Home re-shown while keyboard-open).
    @Published var focusSeq = 0
    var command: Command? { Command.parse(text: text) }
}

/// The field at the top of Home while Island has the keyboard. Return runs the line.
struct CommandField: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var bar: CommandBarState
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(focused ? 0.7 : 0.35))
            TextField("", text: $bar.text, prompt: Text("25 · f · a 2h · q · g · n · > note · or search clips")
                .foregroundStyle(.white.opacity(Dim.text(contrast, 0.3))))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Command")
                .accessibilityHint("Type a command, then Return")
            if let p = bar.command?.preview, !bar.text.isEmpty {
                Text(p.text).font(T.f(10, .medium)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.45)))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            Image(systemName: "return").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(bar.text.isEmpty ? 0.15 : 0.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.white.opacity(focused ? 0.08 : 0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.14 : 0), lineWidth: 0.5))
        .onAppear { pullFocus() }
        .onChange(of: bar.focusSeq) { _, _ in pullFocus() }
    }

    private func pullFocus() {
        // The panel turns key a moment after the view appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
    }

    private func submit() {
        guard let c = bar.command else { return }
        bar.text = ""
        m.run(c)
        // Opening a tab keeps the island; everything else is done, so hand the keyboard back.
        if case .open = c { return }
        if m.state == .open { m.requestClose?() }
    }
}

/// Under the field while typing: clipboard matches, or the command's one-line preview.
struct CommandResults: View {
    @ObservedObject var bar: CommandBarState
    @ObservedObject var clipboard: ClipboardHistory
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let cmd = bar.command
        VStack(alignment: .leading, spacing: 4) {
            if case .clipFilter(let f) = cmd {
                let hits = Array(clipboard.matches(f).prefix(4))
                if hits.isEmpty {
                    Text("No clips match").font(T.f(11)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.4)))
                } else {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: 7) {
                            Circle().fill(.white.opacity(i == 0 ? 0.8 : 0)).overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.8))
                                .frame(width: 5, height: 5)
                            Text(c.text ?? "Image").font(.system(size: 11.5)).lineLimit(1)
                                .foregroundStyle(.white.opacity(i == 0 ? 0.9 : 0.55))
                            Spacer(minLength: 0)
                            if clipboard.isPinned(c) {
                                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
                            }
                        }
                        .frame(height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { clipboard.copy(c); bar.text = "" }
                    }
                    Text("Return copies the first").font(T.f(10)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.3)))
                }
            } else if let p = cmd?.preview {
                HStack(spacing: 8) {
                    Image(systemName: p.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    Text(p.text).font(.system(size: 15, weight: .medium, design: .rounded)).lineLimit(1)
                }
                Text("Return to run · Esc to clear").font(T.f(10)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.3)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }
}

/// Home's left column while keyboard-open: the field on top, the hero (or results) under it.
struct CommandPane<Hero: View>: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var bar: CommandBarState
    @ViewBuilder var hero: Hero

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommandField(m: m, bar: bar)
            if bar.text.isEmpty { hero } else { CommandResults(bar: bar, clipboard: m.clipboard) }
        }
    }
}

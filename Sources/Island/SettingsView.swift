import AVFoundation
import AppKit
import SwiftUI

// MARK: - Away mode

/// What happens when you walk away. Replaces the separate Presence Lock switch; Guard Now (⌃⌥G)
/// stays a one-shot action. Only decides which existing piece runs: the look/lock logic is
/// PresenceLock's and Guard's own, unchanged.
///   off   · nothing watches
///   lock  · Presence: blur when you leave, your face opens it, real lock after the grace time
///   guardMode · Presence, then Guard when you leave: watch, photograph, Touch ID challenge
enum AwayMode: String, CaseIterable {
    case off, lock, guardMode

    static var stored: AwayMode {
        get { UserDefaults.standard.string(forKey: "away.mode").flatMap(AwayMode.init) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "away.mode") }
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .lock: "Lock"
        case .guardMode: "Guard"
        }
    }

    var caption: String {
        switch self {
        case .off: "Nothing watches when you step away. The camera stays off."
        case .lock: "Step away and the screen blurs. Your face opens it; anyone else gets locked out."
        case .guardMode: "Like Lock, and photographs anyone who touches your Mac while you're gone."
        }
    }
}

// MARK: - One-time migration

enum IslandSettings {
    /// Stage 5 settings, run once before anything reads them.
    /// - Existing install (a registered face, a lock-screen password, or any earlier Island default):
    ///   presence.enabled (unset means on) becomes AwayMode .lock or .off, and onboarding is marked done.
    /// - Fresh install: AwayMode .off and presence.enabled false, so no camera runs before onboarding.
    static func migrate(hasFace: Bool) {
        let d = UserDefaults.standard
        guard d.object(forKey: "settings.v5") == nil else { return }
        let existing = hasFace || LockCredential.exists || priorFiles() || priorDefaults(d)
        if d.string(forKey: "away.mode") == nil {
            let presence = d.object(forKey: "presence.enabled") as? Bool ?? true
            let mode: AwayMode = existing && presence ? .lock : .off
            d.set(mode.rawValue, forKey: "away.mode")
            d.set(mode != .off, forKey: "presence.enabled")
            if mode != .off { d.set(mode.rawValue, forKey: "away.last") }
        }
        if existing { d.set(true, forKey: "onboarded") }
        d.set(5, forKey: "settings.v5")
        FaceID.debug("settings: v5 migration, existing=\(existing), away=\(AwayMode.stored.rawValue)")
    }

    /// ~/Library/Application Support/Island holds a face profile, the debug log or anything else from before.
    private static func priorFiles() -> Bool {
        let dir = FaceID.file.deletingLastPathComponent()
        return !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }

    private static func priorDefaults(_ d: UserDefaults) -> Bool {
        let known = ["presence.enabled", "presence.grace", "hoverToOpen", "showVolume", "showBattery", "showTrackToast",
                     "showDog", "sitWatch", "sitMinutes", "hush", "alwaysOn", "mb.enabled", "lockFace.enabled",
                     "lockFace.hours", "pup.name", "pup.greeted", "pup.home", "quickNote", "meeting.detect", "meeting.recap"]
        if known.contains(where: { d.object(forKey: $0) != nil }) { return true }
        // Unknown bundle (a bare `swift run`): never risk showing onboarding over a working setup.
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let keys = (d.persistentDomain(forName: id) ?? [:]).keys
        return keys.contains { !$0.hasPrefix("NS") && !$0.hasPrefix("Apple") && !$0.hasPrefix("com.apple") && $0 != "settings.v5" }
    }
}

// MARK: - Settings tab

/// One section at a time: a rail of five on the left, that section's few rows on the right in
/// two columns. Rows that only matter when another is on (grace, remind after, playful, burst
/// style) appear only then.
enum SettingsSection: String, CaseIterable {
    case general, calendar, look, away, rhythm, keys

    var label: String {
        switch self {
        case .general: "General"
        case .calendar: "Meetings"
        case .look: "Look & alerts"
        case .away: "Away & lock"
        case .rhythm: "Focus & breaks"
        case .keys: "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .calendar: "calendar"
        case .look: "sparkles"
        case .away: "lock.shield"
        case .rhythm: "timer"
        case .keys: "command"
        }
    }

    var tint: Color {
        switch self {
        case .general, .keys: .white
        case .look: .orange
        case .calendar: .red
        case .away: .teal
        case .rhythm: .purple
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var calendar: CalendarModel
    @AppStorage("meeting.lead") private var lead = 10.0
    @AppStorage("meeting.pup") private var leadPup = true
    @AppStorage("whisper.on") private var whisperOn = true
    @ObservedObject private var whisper = WhisperDownload.shared
    @ObservedObject var lockFace: LockScreenUnlock
    @AppStorage("presence.grace") private var grace = 180.0
    @AppStorage("meeting.detect") private var detect = true
    @AppStorage("focusMinutes") private var focus = 25.0
    @AppStorage("restMinutes") private var rest = 5.0
    @AppStorage(ScreenShare.key) private var shareVisible = false
    @AppStorage("settings.section") private var section: SettingsSection = .general
    @State private var fold = false
    @State private var always = AlwaysOn.enabled
    @State private var forgetArmed = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            rail
            Group {
                if section == .keys {
                    ShortcutsCard(hotkeyOK: m.islandHotkeyOK)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if let caption { Text(caption).font(T.f(10.5)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.45))) }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                            rows
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .glass(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { fold = m.collapser != nil; always = AlwaysOn.enabled }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases, id: \.self) { s in
                Button { section = s } label: {
                    HStack(spacing: 7) {
                        Image(systemName: s.symbol).font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(section == s ? s.tint : .white.opacity(0.45)).frame(width: 14)
                        Text(s.label).font(T.f(11.5, section == s ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(section == s ? 0.95 : 0.55))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).frame(height: 23)
                    .background(section == s ? AnyShapeStyle(.white.opacity(0.1)) : AnyShapeStyle(.clear), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == s ? .isSelected : [])
            }
        }
        .frame(width: 132)
    }

    /// One plain sentence on what this section is for, so no row needs its own explanation.
    private var caption: String? {
        switch section {
        case .general: "How Island opens, starts, and shows up in calls."
        case .calendar: calendar.authorized
            ? "Every calendar on this Mac, a heads-up \(Int(lead)) min before, and notes for the calls you record."
            : "Let Island read your calendars to show what's next and remind you before meetings."
        case .look: "What pops out of the notch, and how it looks."
        case .away: m.awayMode.caption + (m.awayMode != .off && m.keepAwake.on ? " Paused while Keep Awake is on." : "")
        case .rhythm: "Focus timer length, and gentle nudges to get up."
        case .keys: nil
        }
    }

    @ViewBuilder private var rows: some View {
        switch section {
        case .general:
            SettingRow("Open on hover") { PillSwitch(on: $m.hoverToOpen) }
            SettingRow("Start at login") {
                PillSwitch(on: Binding(get: { always }, set: { v in always = v; AlwaysOn.setEnabled(v) }))
            }
            SettingRow("Show in screen share") {
                PillSwitch(on: Binding(get: { shareVisible }, set: { ScreenShare.visible = $0; shareVisible = $0 }))
            }
            SettingRow("Tidy menu bar icons") {
                PillSwitch(on: Binding(get: { fold }, set: { v in fold = v; m.setCollapser?(v) }))
            }
            SettingRow("Weather · by IP") {
                PillSwitch(on: Binding(get: { m.weather.enabled }, set: { m.weather.enabled = $0; m.objectWillChange.send() }))
            }
            SettingRow("Clipboard history") {
                PillSwitch(on: Binding(get: { m.clipboard.enabled }, set: { m.clipboard.enabled = $0; m.objectWillChange.send() }))
            }
            SettingRow("Island \(Self.version)") {
                HStack(spacing: 8) {
                    LinkButton("Welcome tour", tint: .white) { m.tab = .welcome }
                    LinkButton("Quit", tint: .orange) { NSApp.terminate(nil) }
                }
            }
        case .calendar:
            if !calendar.authorized {
                SettingRow("Calendar access") {
                    LinkButton("Allow", tint: .red) {
                        calendar.requestAccess { ok in if !ok { Deep.open(Deep.calendars) } }
                    }
                }
            } else {
                SettingRow(calendar.accounts.isEmpty ? "No accounts yet" : calendar.accounts.count == 1 ? calendar.accounts[0] : "\(calendar.accounts.count) accounts") {
                    LinkButton(calendar.hasGoogle ? "Add another" : "Add Google", tint: .red) { CalendarModel.addAccount() }
                }
                SettingRow("Show") {
                    Menu {
                        ForEach(calendar.accounts, id: \.self) { acct in
                            Section(acct) {
                                ForEach(calendar.calendars.filter { $0.account == acct }) { c in
                                    Toggle(c.title, isOn: Binding(
                                        get: { !calendar.hidden.contains(c.id) },
                                        set: { on in if on { calendar.hidden.remove(c.id) } else { calendar.hidden.insert(c.id) } }))
                                }
                            }
                        }
                    } label: {
                        let shown = calendar.calendars.filter { !calendar.hidden.contains($0.id) }.count
                        Text("\(shown) of \(calendar.calendars.count) calendars")
                    }
                    .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
                }
            }
            SettingRow("Remind me") {
                Segments(options: [("5m", 5.0), ("10m", 10.0), ("15m", 15.0)], selection: $lead, tint: .red)
            }
            SettingRow("Bruno brings it") { PillSwitch(on: $leadPup, tint: .red) }
            SettingRow("Offer to take call notes") { PillSwitch(on: $detect, tint: .red) }
            SettingRow(whisper.installed ? "Accurate transcript" : "Accurate transcript · 550 MB") {
                if let p = whisper.progress {
                    HStack(spacing: 8) {
                        Text("\(Int(p * 100))%").font(T.f(10.5, .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                        LinkButton("Cancel", tint: .white) { whisper.cancel() }
                    }
                } else if whisper.installed {
                    PillSwitch(on: $whisperOn, tint: .red)
                } else {
                    LinkButton(whisper.error == nil ? "Download" : "Retry", tint: whisper.error == nil ? .red : .orange) { whisper.start() }
                        .help("Whisper large-v3-turbo from Hugging Face, once. After each recorded meeting it rewrites the transcript on this Mac; audio never leaves it.")
                }
            }
        case .look:
            SettingRow("Sounds") {
                Segments(options: [("Off", "off"), ("Alerts", "alerts"), ("All", "all")], selection: $m.sounds, tint: .orange)
            }
            SettingRow("Volume & brightness") { PillSwitch(on: $m.showVolume, tint: .orange) }
            SettingRow("Battery alerts") { PillSwitch(on: $m.showBattery, tint: .orange) }
            SettingRow("Song banner") { PillSwitch(on: $m.showTrackToast, tint: .orange) }
            SettingRow("Starry background") { PillSwitch(on: $m.skyBackground, tint: .orange) }
            SettingRow("Mode-on effect") {
                Segments(options: [("Burst", FlairMode.burst.rawValue), ("Border", FlairMode.border.rawValue),
                                   ("Off", FlairMode.off.rawValue)], selection: $m.flairRaw)
            }
            if m.flairRaw == FlairMode.burst.rawValue {
                SettingRow("Style") {
                    Picker("", selection: $m.burstStyleRaw) {
                        Text("Auto (per event)").tag("auto")
                        Text("Random").tag("random")
                        Divider()
                        ForEach(BurstStyle.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                }
            }
        case .away:
            SettingRow("When away") {
                Segments(options: AwayMode.allCases.map { ($0.label, $0) }, selection: $m.awayMode, tint: .teal)
            }
            if m.awayMode == .lock {
                SettingRow("Lock after") {
                    HStack(spacing: 6) {
                        ThinSlider(value: $grace, range: 30...600, step: 30, tint: .teal).frame(width: 64)
                        Text(Self.seconds(grace)).font(T.f(10.5, .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7)).frame(width: 34, alignment: .trailing)
                    }
                }
            }
            SettingRow("My face") {
                HStack(spacing: 8) {
                    if m.hasFace {
                        LinkButton("Redo", tint: .teal) { m.registerFace() }
                        LinkButton(forgetArmed ? "Sure?" : "Forget", tint: forgetArmed ? .orange : .white) {
                            if forgetArmed { forgetArmed = false; m.forgetFace() } else {
                                forgetArmed = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { forgetArmed = false }
                            }
                        }
                    } else {
                        LinkButton("Register", tint: .teal) { m.registerFace() }
                    }
                }
            }
            SettingRow("Face unlock") {
                HStack(spacing: 8) {
                    Dot(on: lockFace.ready, tint: .green)
                    LinkButton(lockFace.ready ? "Settings" : "Set up", tint: .teal) { LockFaceWindow.shared.show(lockFace) }
                }
            }
            if cameraDenied {
                SettingRow("Camera blocked") { LinkButton("Allow", tint: .orange) { Deep.open(Deep.camera) } }
            }
        case .rhythm:
            SettingRow("Focus") { ValueStepper(value: $focus, range: 5...120, step: 5, unit: "min") }
            SettingRow("Break") { ValueStepper(value: $rest, range: 1...30, step: 1, unit: "min") }
            SettingRow(m.sitHasPresence ? "Sit reminder" : "Sit reminder · needs Away") { PillSwitch(on: $m.sitWatch, tint: .purple) }
            if m.sitWatch {
                SettingRow("Remind after") {
                    ValueStepper(value: Binding(get: { Double(m.sitMinutes) }, set: { m.sitMinutes = Int($0) }),
                                 range: 15...120, step: 15, unit: "min")
                }
            }
            SettingRow("Pup") { PillSwitch(on: $m.showDog, tint: .purple) }
            if m.showDog { SettingRow("Playful pup") { PillSwitch(on: $m.playful, tint: .purple) } }
        case .keys:
            EmptyView()
        }
    }

    private var cameraDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    static func seconds(_ s: Double) -> String {
        s < 60 ? "\(Int(s)) s" : (Int(s) % 60 == 0 ? "\(Int(s) / 60) m" : String(format: "%.1f m", s / 60))
    }
}

/// The global keys, nothing else. The command bar grammar and island:// verbs live in the README.
struct ShortcutsCard: View {
    let hotkeyOK: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    private let keys: [(String, String)] = [
        ("⌃⌥Space", "open island"), ("⌃⌥P", "teleprompter"), ("⌃⌥O", "roll / pause"),
        ("⌃⌥R", "record"), ("⌃⌥M", "mark"), ("⌃⌥H", "hide"),
        ("⌃⌥T", "hold to peek"), ("⌃⌥G", "Guard now"), ("Esc", "close"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !hotkeyOK {
                Text("⌃⌥Space is taken by another app").font(T.f(10.5, .medium)).foregroundStyle(.orange)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading), count: 3), spacing: 10) {
                ForEach(keys, id: \.0) { k, v in
                    HStack(spacing: 8) {
                        Text(k).font(T.f(11, .semibold, .rounded)).foregroundStyle(.white.opacity(0.9)).fixedSize()
                        Text(v).font(T.f(11)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.5))).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(16)
    }
}

// MARK: - Controls (capsule switches, filled/hollow dots; never check marks)

extension View {
    /// One Settings column as a glass card.
    func settingsCard() -> some View {
        self.padding(.horizontal, 9).padding(.vertical, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glass(16)
    }
}

struct SectionTitle: View {
    let text: String
    var tint: Color = .white
    init(_ text: String, tint: Color = .white) { self.text = text; self.tint = tint }

    var body: some View {
        Text(text.uppercased()).font(T.f(10.5, .semibold)).tracking(0.8)
            .foregroundStyle(tint.opacity(0.55)).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SettingRow<C: View>: View {
    let label: String
    @ViewBuilder var control: C
    init(_ label: String, @ViewBuilder control: () -> C) { self.label = label; self.control = control() }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(T.f(11)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
            Spacer(minLength: 4)
            control
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }
}

/// Capsule switch: the knob slides, the track fills with the tint.
struct PillSwitch: View {
    @Binding var on: Bool
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var rm

    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? AnyShapeStyle(tint.opacity(tint == .white ? 0.85 : 0.75)) : AnyShapeStyle(.white.opacity(0.12)))
                Circle().fill(on ? (tint == .white ? Color.black : .white) : .white.opacity(0.55))
                    .frame(width: 9, height: 9).padding(2)
            }
            .frame(width: 24, height: 13)
            .hiContrastStroke(Capsule())
            .animation(rm ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: on)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Small segmented choice in one capsule.
struct Segments<V: Hashable>: View {
    let options: [(String, V)]
    @Binding var selection: V
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.1) { label, v in
                Button { selection = v } label: {
                    Text(label).font(T.f(10.5, selection == v ? .semibold : .regular))
                        .foregroundStyle(selection == v ? (tint == .white ? .black : .white) : .white.opacity(0.5))
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(selection == v ? AnyShapeStyle(tint.opacity(tint == .white ? 0.85 : 0.6)) : AnyShapeStyle(.clear), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == v ? .isSelected : [])
            }
        }
        .padding(1)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

/// − value + in one line.
struct ValueStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        HStack(spacing: 2) {
            tap("minus") { value = max(range.lowerBound, value - step) }
            Text("\(Int(value)) \(unit)").font(T.f(10.5, .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.8)).frame(minWidth: 40)
            tap("plus") { value = min(range.upperBound, value + step) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(value)) \(unit)")
        .accessibilityAdjustableAction { d in
            value = d == .increment ? min(range.upperBound, value + step) : max(range.lowerBound, value - step)
        }
    }

    private func tap(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                .frame(width: 16, height: 16).background(.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A 3 pt track with a 9 pt knob.
struct ThinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var tint: Color = .white

    var body: some View {
        GeometryReader { g in
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 3)
                Capsule().fill(tint.opacity(0.8)).frame(width: max(3, g.size.width * f), height: 3)
                Circle().fill(.white).frame(width: 9, height: 9).offset(x: (g.size.width - 9) * f)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let x = min(max(v.location.x / g.size.width, 0), 1)
                let raw = range.lowerBound + x * (range.upperBound - range.lowerBound)
                value = (raw / step).rounded() * step
            })
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { d in
            value = d == .increment ? min(range.upperBound, value + step) : max(range.lowerBound, value - step)
        }
    }
}

/// Filled: on/ready. Hollow: off.
struct Dot: View {
    let on: Bool
    var tint: Color = .white

    var body: some View {
        ZStack {
            if on { Circle().fill(tint) } else { Circle().stroke(.white.opacity(0.4), lineWidth: 1) }
        }
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
    }
}

struct LinkButton: View {
    let title: String
    var tint: Color = .white
    let action: () -> Void
    @State private var hover = false
    init(_ title: String, tint: Color = .white, action: @escaping () -> Void) { self.title = title; self.tint = tint; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title).font(T.f(10.5, .semibold)).foregroundStyle(tint.opacity(hover ? 1 : 0.7))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// System Settings deep links, so a denied permission is one click from fixed.
enum Deep {
    static let camera = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    static let calendars = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    static func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}

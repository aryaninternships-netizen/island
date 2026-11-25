import AppKit
import AudioToolbox
import CoreAudio
import EventKit
import IOKit.ps

// MARK: - Volume

/// Watches the default output device's main volume + mute via CoreAudio listeners.
final class VolumeMonitor {
    var onChange: ((Float, Bool) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private let queue = DispatchQueue.main
    private var lastVolume: Float = -1
    private var lastMute = false

    private var volumeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private lazy var changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, queue, deviceChanged)
        attach()
    }

    private func attach() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &volumeAddr, queue, changed)
            AudioObjectRemovePropertyListenerBlock(device, &muteAddr, queue, changed)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &id)
        device = id
        AudioObjectAddPropertyListenerBlock(device, &volumeAddr, queue, changed)
        AudioObjectAddPropertyListenerBlock(device, &muteAddr, queue, changed)
        (lastVolume, lastMute) = read()
    }

    private func read() -> (Float, Bool) {
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &volumeAddr, 0, nil, &size, &v)
        var m: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &size, &m)
        return (v, m != 0)
    }

    /// Step the output volume (two-finger scroll on the island); unmutes on the way up.
    func adjust(by delta: Float) {
        var (v, m) = read()
        v = min(max(v + delta, 0), 1)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(device, &volumeAddr, 0, nil, size, &v)
        if m && delta > 0 {
            var off: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(device, &muteAddr, 0, nil, size, &off)
        }
    }

    private func report() {
        let (v, m) = read()
        guard abs(v - lastVolume) > 0.001 || m != lastMute else { return }
        lastVolume = v; lastMute = m
        onChange?(v, m)
    }
}

// MARK: - Battery

final class BatteryMonitor: ObservableObject {
    @Published private(set) var level = 100
    @Published private(set) var charging = false
    @Published private(set) var pluggedIn = false
    @Published private(set) var hasBattery = false
    /// Minutes until full while charging (nil while macOS is still estimating).
    @Published private(set) var minutesToFull: Int?

    /// (level, pluggedIn) on plug/unplug, and once at 20% / 10% while discharging.
    var onEvent: ((Int, Bool) -> Void)?
    private var source: CFRunLoopSource?
    private var warned: Set<Int> = []

    func start() {
        read(initial: true)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue().read(initial: false)
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func read(initial: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let newLevel = max > 0 ? cur * 100 / max : cur
            let newPlugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let ttf = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            minutesToFull = charging && ttf > 0 ? ttf : nil
            let plugChanged = newPlugged != pluggedIn
            level = newLevel
            pluggedIn = newPlugged
            if initial { return }
            if plugChanged {
                warned.removeAll()
                onEvent?(level, pluggedIn)
            } else if !pluggedIn {
                for t in [20, 10] where level <= t && !warned.contains(t) {
                    warned.insert(t)
                    onEvent?(level, false)
                    break
                }
            }
        }
    }
}

// MARK: - Calendar

final class CalendarModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
        let link: URL?
        var attendees: [String] = []
        var notes: String?
    }

    /// Video-call link from the event URL, location or notes (Meet, Zoom, Teams, Webex).
    static func meetingLink(_ e: EKEvent) -> URL? {
        if let u = e.url, isCall(u) { return u }
        let text = [e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let rx = try! NSRegularExpression(pattern: #"https://[^\s<>"]*(meet\.google\.com|zoom\.us|teams\.microsoft\.com|webex\.com)[^\s<>"]*"#)
        guard let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text), let u = URL(string: String(text[r])), isCall(u) else { return nil }
        return u
    }

    /// https on a real call domain (host suffix, so "evil.example/?zoom.us" does not pass).
    static func isCall(_ u: URL) -> Bool {
        guard u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]
            .contains { h == $0 || h.hasSuffix("." + $0) }
    }

    @Published private(set) var items: [Item] = []
    /// Every timed event in the next 36 h (not only the three shown), so each one gets its heads-up.
    @Published private(set) var timed: [Item] = []
    @Published private(set) var authorized = false
    private var refresh: Timer?

    /// One calendar Island can show, from any account macOS syncs (iCloud, Google, Exchange...).
    struct Cal: Identifiable, Equatable {
        let id: String
        let title: String
        let account: String
        let color: NSColor
    }
    /// Every event calendar on this Mac, grouped by account order. Google accounts added in
    /// System Settings › Internet Accounts land here with no sign-in code in Island.
    @Published private(set) var calendars: [Cal] = []
    /// Calendars the user switched off in Settings › Calendar.
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "cal.hidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "cal.hidden"); reload() }
    }
    /// Account names (e.g. "iCloud", "you@gmail.com"), for the Settings summary.
    var accounts: [String] {
        var seen: [String] = []
        for c in calendars where !seen.contains(c.account) { seen.append(c.account) }
        return seen
    }
    var hasGoogle: Bool { Self.store.sources.contains { $0.sourceType == .calDAV && ($0.title.contains("@gmail") || $0.title.lowercased().contains("google")) } }

    /// Opens System Settings › Internet Accounts, where "Add Account › Google" signs in with Google's
    /// own page and syncs that account's calendars into the Mac's calendar store.
    static func addAccount() {
        for s in ["x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
                  "x-apple.systempreferences:com.apple.preferences.internetaccounts"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
    /// One store for the app: calendar here, Reminders for meeting action items.
    static let store = EKEventStore()
    private var store: EKEventStore { Self.store }

    /// `request` false (fresh install before onboarding): read the current grant only, never prompt.
    func start(request: Bool = true) {
        if request { requestAccess() } else { authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess; reload() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        // Past events fall off and the 36 h window slides even when the island is never opened.
        refresh = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.reload() }
        refresh?.tolerance = 60
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    /// The system Calendar prompt (onboarding card 1, or launch once onboarded).
    func requestAccess(_ done: ((Bool) -> Void)? = nil) {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
                self?.reload()
                done?(granted)
            }
        }
    }

    func reload() {
        guard authorized else { return }
        let allCals = store.calendars(for: .event)
        let cals = allCals.map { Cal(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "On My Mac",
                                 color: $0.color ?? .systemBlue) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        if cals != calendars { calendars = cals }
        let shown = allCals.filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { if !items.isEmpty { items = []; timed = [] }; return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 36, to: now)!
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: shown)
        let all: [Item] = store.events(matching: pred)
            .filter { !$0.isAllDay || Calendar.current.isDateInToday($0.startDate) }
            .sorted { $0.startDate < $1.startDate }
            .map { Item(id: $0.eventIdentifier ?? "\($0.title ?? "Event")-\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Event",
                        start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                        color: $0.calendar.color ?? .systemBlue, link: Self.meetingLink($0),
                        attendees: ($0.attendees ?? []).compactMap(\.name), notes: $0.notes) }
        let new = Array(all.prefix(3))
        if new != items { items = new }
        let t = all.filter { !$0.allDay }
        if t != timed { timed = t }
    }
}

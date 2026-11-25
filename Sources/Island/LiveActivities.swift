import AppKit
import Combine
import CoreGraphics

// MARK: - Timers

/// One live clock at a time: a countdown, a stopwatch, or a focus session that rolls into a break.
final class LiveTimers: ObservableObject {
    enum Kind { case timer, stopwatch, focus, rest }

    @Published private(set) var kind: Kind?
    @Published private(set) var start = Date()
    /// nil for the stopwatch (counts up).
    @Published private(set) var end: Date?
    var onChange: (() -> Void)?
    var onFinish: ((Kind) -> Void)?
    private var tick: Timer?

    /// Settings › Rhythm (25 and 5 until changed).
    static var focusMinutes: Double { max(1, UserDefaults.standard.object(forKey: "focusMinutes") as? Double ?? 25) }
    static var restMinutes: Double { max(1, UserDefaults.standard.object(forKey: "restMinutes") as? Double ?? 5) }

    func timer(minutes: Double) { begin(.timer, minutes) }
    func stopwatch() { begin(.stopwatch, nil) }
    func focus() { begin(.focus, Self.focusMinutes) }

    func stop() {
        tick?.invalidate()
        kind = nil; end = nil
        onChange?()
    }

    /// 0...1 elapsed share of a countdown (stopwatch: nil).
    func progress(at now: Date = Date()) -> Double? {
        guard let end else { return nil }
        return min(max(now.timeIntervalSince(start) / max(end.timeIntervalSince(start), 1), 0), 1)
    }

    /// Push a running countdown's end out (the stopwatch has no end: nothing to do).
    func extend(minutes: Double) {
        guard kind != nil, let e = end else { return }
        end = e.addingTimeInterval(minutes * 60)
        schedule()
        onChange?()
    }

    private func begin(_ k: Kind, _ minutes: Double?) {
        tick?.invalidate()
        kind = k
        start = Date()
        end = minutes.map { start.addingTimeInterval($0 * 60) }
        onChange?()
        schedule()
    }

    private func schedule() {
        tick?.invalidate()
        // One-shot at the end of a countdown; the stopwatch (no end) needs no timer at all.
        guard let end else { tick = nil; return }
        let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            guard let self, let end = self.end, Date() >= end, let k = self.kind else { return }
            if k == .focus { self.begin(.rest, Self.restMinutes) } else { self.stop() }
            self.onFinish?(k)
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }
}

/// "4:05", "1:02:09"
func clockText(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.up)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Downloads

/// Notices files arriving in ~/Downloads: partial files (Chrome, Safari, Firefox, Arc) while they
/// grow, then the finished file. Polls only while a download is in flight.
final class DownloadWatcher: ObservableObject {
    struct Current: Equatable {
        var name: String
        var bytes: Int64
        var url: URL
    }

    /// The download in flight (nil when nothing is arriving). Published on main.
    @Published private(set) var current: Current?
    /// A file just finished landing.
    let done = PassthroughSubject<URL, Never>()

    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var inFlight: Set<String> = []
    private static let partial = ["crdownload", "download", "part", "partial", "opdownload"]

    /// All file work happens here: touching ~/Downloads can raise a privacy prompt, which must
    /// never block the main thread (the whole island would freeze until it is answered).
    private let q = DispatchQueue(label: "island.downloads", qos: .utility)
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        q.async { [self] in
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: q)
            s.setEventHandler { [weak self] in self?.scan() }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
            scan()
        }
    }

    /// On `q`.
    private func scan() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let now = Set(names.filter { Self.partial.contains(($0 as NSString).pathExtension.lowercased()) })
        if let first = now.sorted().first {
            let url = dir.appendingPathComponent(first)
            let c = Current(name: Self.display(first), bytes: Self.size(url), url: url)
            DispatchQueue.main.async { if self.current != c { self.current = c } }
        }
        let finished = inFlight.subtracting(now)
        inFlight = now
        let landed = finished.isEmpty ? nil
            : newest(names.filter { !Self.partial.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") })
        let idle = now.isEmpty
        DispatchQueue.main.async {
            if !finished.isEmpty, idle, self.current != nil { self.current = nil }
            if let landed { self.done.send(landed) }
            if idle { self.poll?.invalidate(); self.poll = nil }
            else if self.poll == nil {
                self.poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.q.async { self?.scan() } }
            }
        }
    }

    /// The file that just landed: newest one modified in the last 15 s.
    private func newest(_ names: [String]) -> URL? {
        names.map { dir.appendingPathComponent($0) }
            .compactMap { u -> (URL, Date)? in
                guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                return (u, d)
            }
            .filter { Date().timeIntervalSince($0.1) < 15 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func display(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.hasPrefix("Unconfirmed") ? "Download" : base
    }

    /// Bytes on disk (Safari's .download is a bundle: add up what's inside).
    static func size(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard isDir.boolValue else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }
}

func byteText(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

// MARK: - Clipboard

/// Last 25 things you copied, in memory only (never written to disk). Password managers mark
/// secrets as concealed/transient; those are skipped. Up to 5 text clips you pin persist.
final class ClipboardHistory: ObservableObject {
    struct Clip: Identifiable, Equatable {
        let id = UUID()
        let text: String?
        let image: NSImage?
        let date: Date
        let app: String?
        static func == (a: Clip, b: Clip) -> Bool { a.id == b.id }
    }

    @Published private(set) var clips: [Clip] = []
    /// Pinned text clips (at most 5), kept across launches. Unpinned history never touches disk.
    @Published private(set) var pins: [Clip] = (UserDefaults.standard.stringArray(forKey: "clip.pins") ?? [])
        .map { Clip(text: $0, image: nil, date: .distantPast, app: nil) }
    static let maxPins = 5
    private var seen = NSPasteboard.general.changeCount
    private var timer: Timer?
    private static let secret: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                              "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]

    func start() {
        resume()
        // Nothing is copied on a locked or sleeping screen: stop polling, and let changeCount catch up on return.
        let dnc = DistributedNotificationCenter.default()
        let wsn = NSWorkspace.shared.notificationCenter
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.suspend() }
        wsn.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.suspend() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.resume() }
        wsn.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.resume() }
    }

    private func suspend() { timer?.invalidate(); timer = nil }

    /// "Pause Island 1 h": no clipboard polling until resumed.
    var paused = false {
        didSet { if paused { suspend() } else { resume() } }
    }

    /// Settings › General › Clipboard history. Off: no polling, history cleared.
    @Published var enabled = UserDefaults.standard.object(forKey: "clip.on") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "clip.on")
            if enabled { resume() } else { suspend(); clips = [] }
        }
    }

    private func resume() {
        guard timer == nil, !paused, enabled else { return }
        check()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != seen else { return }
        seen = pb.changeCount
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.secret) else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clips.removeAll { $0.text == s }
            clips.insert(Clip(text: s, image: nil, date: Date(), app: app), at: 0)
        } else if let img = NSImage(pasteboard: pb) {
            clips.insert(Clip(text: nil, image: img, date: Date(), app: app), at: 0)
        } else { return }
        if clips.count > 25 { clips.removeLast(clips.count - 25) }
    }

    /// Put a clip back on the clipboard (and move it to the top).
    func copy(_ c: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = c.text { pb.setString(t, forType: .string) } else if let i = c.image { pb.writeObjects([i]) }
        seen = pb.changeCount
        clips.removeAll { $0 == c }
        clips.insert(Clip(text: c.text, image: c.image, date: Date(), app: c.app), at: 0)
    }

    func remove(_ c: Clip) {
        clips.removeAll { $0 == c }
        if pins.contains(c) { pins.removeAll { $0 == c }; savePins() }
    }

    /// Clears the history; pins stay.
    func clear() { clips.removeAll() }

    func isPinned(_ c: Clip) -> Bool { c.text.map { t in pins.contains { $0.text == t } } ?? false }

    func togglePin(_ c: Clip) {
        guard let t = c.text else { return }
        if isPinned(c) { pins.removeAll { $0.text == t } } else {
            pins.append(Clip(text: t, image: nil, date: .distantPast, app: c.app))
            if pins.count > Self.maxPins { pins.removeFirst(pins.count - Self.maxPins) }
        }
        savePins()
    }

    /// Pins first, then history, without repeating a pinned text.
    var all: [Clip] {
        let pinned = Set(pins.compactMap(\.text))
        return pins + clips.filter { $0.text.map { !pinned.contains($0) } ?? true }
    }

    /// Case-insensitive text match over pins and history (the command bar).
    func matches(_ f: String) -> [Clip] {
        let q = f.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.text?.localizedCaseInsensitiveContains(q) ?? false }
    }

    private func savePins() { UserDefaults.standard.set(pins.compactMap(\.text), forKey: "clip.pins") }
}

// MARK: - Weather

/// Current conditions for wherever the Mac's IP says it is (wttr.in, no key). Every 30 min.
final class Weather: ObservableObject {
    @Published private(set) var temp: Int?
    @Published private(set) var symbol = "cloud.sun.fill"
    @Published private(set) var summary = ""
    @Published private(set) var place = ""
    private var timer: Timer?

    /// Settings › General › Weather. Asks wttr.in, which places you by IP address.
    @Published var enabled = UserDefaults.standard.object(forKey: "weather.on") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "weather.on")
            if enabled { fetch() } else { temp = nil; place = ""; summary = "" }
        }
    }

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.fetch() }
    }

    private func fetch() {
        guard enabled, let url = URL(string: "https://wttr.in/?format=j1") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("curl/8", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = (j["current_condition"] as? [[String: Any]])?.first else { return }
            let t = Int(cur["temp_C"] as? String ?? "")
            let code = Int(cur["weatherCode"] as? String ?? "") ?? 113
            let desc = ((cur["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let area = ((j["nearest_area"] as? [[String: Any]])?.first?["areaName"] as? [[String: Any]])?.first?["value"] as? String ?? ""
            let hour = Calendar.current.component(.hour, from: Date())
            DispatchQueue.main.async {
                guard self?.enabled == true else { return }
                self?.temp = t
                self?.summary = desc
                self?.place = area
                self?.symbol = Self.symbol(code, night: hour < 6 || hour >= 19)
            }
        }.resume()
    }

    private static func symbol(_ code: Int, night: Bool) -> String {
        switch code {
        case 113: return night ? "moon.stars.fill" : "sun.max.fill"
        case 116: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 119, 122: return "cloud.fill"
        case 143, 248, 260: return "cloud.fog.fill"
        case 200, 386, 389, 392, 395: return "cloud.bolt.rain.fill"
        case 176, 263, 266, 293, 296, 353: return "cloud.drizzle.fill"
        case 299, 302, 305, 308, 356, 359: return "cloud.heavyrain.fill"
        case 179, 227, 230, 323...338, 368, 371: return "cloud.snow.fill"
        default: return "cloud.sun.fill"
        }
    }
}

// MARK: - Brightness

/// Watches the built-in display's brightness (private DisplayServices, read-only) so the island
/// can stand in for the system HUD.
final class BrightnessMonitor {
    var onChange: ((Float) -> Void)?
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private var get: Get?
    private var last: Float = -1
    private var timer: Timer?

    func start() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let sym = dlsym(h, "DisplayServicesGetBrightness") else { return }
        get = unsafeBitCast(sym, to: Get.self)
        last = read() ?? -1
        // Event-driven: a brightness key (or the Control Center slider via the 2 s fallback) wakes a
        // short burst of fast checks; otherwise nothing polls fast.
        NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined, .keyDown]) { [weak self] e in
            let isBrightnessKey: Bool
            if e.type == .systemDefined {
                let code = (e.data1 & 0xFFFF0000) >> 16
                isBrightnessKey = e.subtype.rawValue == 8 && (code == 2 || code == 3) // NX_KEYTYPE_BRIGHTNESS_UP/DOWN
            } else {
                isBrightnessKey = e.keyCode == 144 || e.keyCode == 145 // brightness F-keys
            }
            if isBrightnessKey { self?.burst() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 0.5
    }

    private var burstTimer: Timer?
    private func burst() {
        check()
        burstTimer?.invalidate()
        var n = 0
        burstTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            self?.check(); n += 1
            if n >= 15 { t.invalidate() }
        }
    }

    private func read() -> Float? {
        guard let get else { return nil }
        let id = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID } ?? CGMainDisplayID()
        var v: Float = 0
        return get(id, &v) == 0 ? v : nil
    }

    private func check() {
        guard let v = read() else { return }
        // Ignore tiny drift from auto-brightness; only show real key presses (~1/16 steps).
        guard last >= 0, abs(v - last) > 0.03 else { if last < 0 { last = v }; return }
        last = v
        onChange?(v)
    }
}

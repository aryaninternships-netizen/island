import AppKit
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Keep awake

/// Caffeinate mode: Mac and display stay awake for a set time, Presence stands down (no away
/// blur, no lock). macOS auto-logout watches *input* idle, so while on we also tell macOS the user
/// is active once a minute (skipped while Guard is armed: that would look like a touch).
final class KeepAwake: ObservableObject {
    @Published private(set) var until: Date?
    /// Distant future = until switched off.
    var on: Bool { (until ?? .distantPast) > Date() }
    var guardArmed: () -> Bool = { false }
    var onChange: (() -> Void)?

    private var system: IOPMAssertionID = 0, display: IOPMAssertionID = 0, activity: IOPMAssertionID = 0
    private var held = false
    private var tick: Timer?

    /// hours nil = until switched off.
    func start(hours: Double?) {
        until = hours.map { Date().addingTimeInterval($0 * 3600) } ?? .distantFuture
        hold()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.beat() }
        beat()
        onChange?()
    }

    func stop() {
        until = nil
        tick?.invalidate(); tick = nil
        if activity != 0 { IOPMAssertionRelease(activity); activity = 0 }
        release()
        onChange?()
    }

    private func beat() {
        guard on else { stop(); return }
        if !guardArmed() {
            IOPMAssertionDeclareUserActivity("Island Keep Awake" as CFString, kIOPMUserActiveLocal, &activity)
        }
        objectWillChange.send() // time-left labels
    }

    private func hold() {
        guard !held else { return }
        let why = "Island Keep Awake" as CFString
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), why, &system)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), why, &display)
        held = true
    }

    private func release() {
        guard held else { return }
        IOPMAssertionRelease(system); IOPMAssertionRelease(display)
        held = false
    }

    var leftText: String {
        guard let u = until, on else { return "" }
        if u == .distantFuture { return "until you turn it off" }
        let m = Int(u.timeIntervalSinceNow / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m left" : "\(max(m, 1))m left"
    }
}

// MARK: - Always on

/// Island runs as a LaunchAgent: started at login, relaunched by launchd if it quits or crashes.
/// A copy opened by hand hands over to the launchd one; a second copy never stays.
enum AlwaysOn {
    static let label = Bundle.main.bundleIdentifier ?? "app.island.notch"
    private static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "alwaysOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysOn") }
    }
    /// Started by launchd (it sets XPC_SERVICE_NAME to the job label).
    static var managed: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    /// Call first thing at launch. Returns false if this process should exit right away.
    static func boot() -> Bool {
        if managed {
            // launchd's copy: wait briefly for a hand-opened copy to step aside, then stay.
            for _ in 0..<20 where others() { usleep(100_000) }
            if others() { exit(0) } // someone else already owns the notch; launchd won't respawn on exit 0
            return true
        }
        guard enabled else { return !others() }
        // Run from Downloads or the disk image (often a read-only translocated copy): a login item
        // there would point at a path that is gone after a restart. Ask for Applications first.
        guard inApplications else { return askToMove() }
        install()
        // Hand over: launchd starts its own copy; this one leaves.
        launchctl(["kickstart", "gui/\(getuid())/\(label)"])
        return false
    }

    /// Settings / menu switch. Off never ends this process: the plist goes (no start at login, no
    /// relaunch next session) and launchd's copy keeps running until you quit it (exit 0 is not
    /// relaunched). On from launchd's own copy just writes the plist back: the job is still loaded.
    static func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            try? SMAppService.mainApp.unregister() // launchd starts it now; avoid a second login launch
            if managed { writePlist(bootout: false) } else { install() } // never boot out the running job
        } else if managed {
            try? FileManager.default.removeItem(at: plist)
        } else {
            uninstall() // no launchd copy is running (this one was opened by hand)
        }
    }

    static var inApplications: Bool {
        let p = Bundle.main.bundlePath
        return !p.contains("/AppTranslocation/") && !p.hasPrefix("/Volumes/")
            && (p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/"))
    }

    /// Returns whether this copy should keep running (without the login item).
    private static func askToMove() -> Bool {
        _ = NSApplication.shared
        let a = NSAlert()
        a.messageText = "Move Island to Applications"
        a.informativeText = "Drag Island from the disk image (or Downloads) into your Applications folder, then open it from there. That lets it start at login and update cleanly."
        a.addButton(withTitle: "Open Applications Folder")
        a.addButton(withTitle: "Run Once From Here")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            return false
        }
        return !others()
    }

    static func install() {
        writePlist()
        launchctl(["bootstrap", "gui/\(getuid())", plist.path])
    }

    /// Writes the job plist; when it changed, unloads the stale job first (as install always did).
    @discardableResult
    private static func writePlist(bootout: Bool = true) -> Data? {
        let exe = Bundle.main.executableURL?.path ?? "\(NSHomeDirectory())/Applications/Island.app/Contents/MacOS/Island"
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], // crashes and "Restart" (exit 1) come back
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "ThrottleInterval": 5,
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let old = try? Data(contentsOf: plist)
        if old != data {
            try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data?.write(to: plist)
            if bootout { launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
        }
        return data
    }

    static func uninstall() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    private static func others() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? label)
            .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
    }

    @discardableResult private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
}

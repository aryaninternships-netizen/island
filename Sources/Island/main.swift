import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let island = IslandController()
    private var statusItem: NSStatusItem?
    private var collapser: MenuBarCollapser?

    func applicationWillFinishLaunching(_: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Single instance: a second launch just forwards URLs (via LaunchServices) and quits.
        let mine = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if mine.count > 1 { NSApp.terminate(nil); return }

        _ = URLKey.value   // create the key file for the `island` CLI
        island.start()
        setupStatusItem()
        if UserDefaults.standard.object(forKey: "mb.enabled") as? Bool ?? false { collapser = MenuBarCollapser() }
        island.model.collapser = collapser
    }

    func applicationWillTerminate(_: Notification) { island.model.media.stop() }

    /// Every island:// URL goes through the one dispatcher (Command.swift → IslandModel.run).
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply _: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s) else { return }
        // Any web page or app can open an island:// link. Harmless verbs (notify, open, timers) run as
        // they always have; the ones that change security, record, or show private data need the key
        // only local scripts can read (the `island` CLI adds it).
        guard URLKey.allows(url) else { FaceID.debug("url: refused \(url.host ?? "?") without key"); return }
        DispatchQueue.main.async { self.island.model.run(Command.parse(url: url)) }
    }

    // MARK: menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.tophalf.filled", accessibilityDescription: "Island")
            ?? NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Island")
        let m = buildMenu()
        m.delegate = self
        item.menu = m
        statusItem = item
        // Settings › Fold menu bar.
        island.model.setCollapser = { [weak self] on in self?.setCollapser(on) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = buildMenu().items // refresh labels each open
    }

    /// Six visible items. Everything else lives in Settings (the gear in the island); test and
    /// diagnostic tools hold ⌥.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let m = island.model
        let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]
        menu.addItem(item("Open Island", #selector(openIsland), key: " ", mods: ctrlOpt))
        menu.addItem(item(m.guardOn ? "Guard Off" : "Guard Now", #selector(toggleGuard), key: "g", mods: ctrlOpt))

        let awake = NSMenuItem(title: m.keepAwake.on ? "Keep Awake: \(m.keepAwake.leftText)" : "Keep Awake", action: nil, keyEquivalent: "")
        let am = NSMenu()
        for (title, h) in [("1 hour", 1.0), ("3 hours", 3.0), ("8 hours", 8.0), ("Until I turn it off", -1.0)] {
            let i = item(title, #selector(setAwake(_:)))
            i.representedObject = h
            am.addItem(i)
        }
        if m.keepAwake.on {
            am.addItem(.separator())
            let off = item("Turn Off", #selector(setAwake(_:)))
            off.representedObject = 0.0
            am.addItem(off)
        }
        awake.submenu = am
        menu.addItem(awake)

        menu.addItem(item(Prompter.shared.on ? "End Teleprompter" : "Teleprompter…", #selector(togglePrompter), key: "p", mods: ctrlOpt))
        let share = item("Show Island in Screen Share", #selector(toggleShare))
        share.state = ScreenShare.visible ? .on : .off
        menu.addItem(share)
        menu.addItem(item(m.paused ? "Resume Island" : "Pause Island 1 h", #selector(togglePause)))
        // ⌥: the diagnostics and test tools (also reachable as island:// verbs).
        let diag = item("Diagnostics", nil, mods: .option)
        diag.isAlternate = true
        diag.submenu = diagnosticsMenu()
        menu.addItem(diag)

        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        if AlwaysOn.managed && AlwaysOn.enabled {
            menu.addItem(item("Restart Island", #selector(restart), key: "r"))
        }
        // Always visible: exit 0 is not relaunched by launchd, so Quit really quits.
        menu.addItem(item("Quit Island", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty && mods == [.command] ? [] : mods
        i.target = self
        return i
    }

    /// The old menu's tools, intact: face, Guard snapshots, lock-screen face, pup, meeting mode, tests.
    private func diagnosticsMenu() -> NSMenu {
        let d = NSMenu()
        let m = island.model
        d.addItem(item(m.hasFace ? "Re-register My Face" : "Register My Face", #selector(registerFace)))
        if m.hasFace { d.addItem(item("Test My Face", #selector(testFace))) }
        d.addItem(item(m.lockFace.ready ? "Face Unlock at Lock Screen: Ready…" : "Face Unlock at Lock Screen…", #selector(openLockFace)))
        d.addItem(item("Show Guard Snapshots", #selector(showSnaps)))
        d.addItem(.separator())
        d.addItem(meetingMenu())
        d.addItem(item("Screen Share Test", #selector(shareTest)))
        d.addItem(item("Send Test Notification", #selector(testNotify)))
        d.addItem(item("Walk the Dog", #selector(walkDog)))
        return d
    }

    /// Meeting mode: detection, per-app auto-record (opt-in), hotkeys, share test.
    private func meetingMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Meeting Mode", action: nil, keyEquivalent: "")
        let m = NSMenu()
        let detect = NSMenuItem(title: "Offer to Record When a Call Takes the Mic", action: #selector(flipDetect(_:)), keyEquivalent: "")
        detect.target = self
        detect.state = MeetingMode.detectEnabled ? .on : .off
        m.addItem(detect)
        m.addItem(.separator())
        m.addItem(note("Record automatically in (consent banner still shows):"))
        for (bundle, name) in [("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams"), ("Cisco-Systems.Spark", "Webex"),
                               ("com.apple.FaceTime", "FaceTime"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord")] {
            let i = NSMenuItem(title: name, action: #selector(flipAutoRecord(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = bundle
            i.state = MeetingMode.autoStart(bundle) ? .on : .off
            i.indentationLevel = 1
            m.addItem(i)
        }
        m.addItem(note("Recording laws vary. Always tell people."))
        m.addItem(.separator())
        m.addItem(note("⌃⌥R record · ⌃⌥M mark · ⌃⌥T hold to peek · ⌃⌥H hide"))
        let test = NSMenuItem(title: "Screen Share Test", action: #selector(shareTest), keyEquivalent: "")
        test.target = self
        m.addItem(test)
        item.submenu = m
        return item
    }

    private func note(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func flipDetect(_ sender: NSMenuItem) {
        MeetingMode.detectEnabled.toggle()
        sender.state = MeetingMode.detectEnabled ? .on : .off
    }

    @objc private func flipAutoRecord(_ sender: NSMenuItem) {
        guard let b = sender.representedObject as? String else { return }
        MeetingMode.setAutoStart(b, !MeetingMode.autoStart(b))
        sender.state = MeetingMode.autoStart(b) ? .on : .off
    }

    @objc private func shareTest() { ShareTest.show() }

    @objc private func setAwake(_ sender: NSMenuItem) {
        guard let h = sender.representedObject as? Double else { return }
        if h == 0 { island.model.keepAwake.stop() } else { island.model.keepAwake.start(hours: h < 0 ? nil : h) }
    }

    /// launchd brings it straight back (non-zero exit).
    @objc private func restart() { exit(1) }

    private func setCollapser(_ on: Bool) {
        if on, collapser == nil { collapser = MenuBarCollapser() } else if !on, let c = collapser { c.remove(); collapser = nil }
        island.model.collapser = collapser
        UserDefaults.standard.set(collapser != nil, forKey: "mb.enabled")
    }

    @objc private func openIsland() { island.model.run(.open(nil)) }

    @objc private func openSettings() { island.model.run(.open(.settings)) }

    @objc private func togglePause() { island.model.pause(hours: island.model.paused ? nil : 1) }

    /// Exit 0: launchd (KeepAlive SuccessfulExit false) does not bring it back.
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openLockFace() { LockFaceWindow.shared.show(island.model.lockFace) }

    @objc private func toggleGuard() { island.model.run(.guardNow) }

    @objc private func registerFace() { island.model.registerFace() }

    @objc private func forgetFace() { island.model.forgetFace() }

    @objc private func testFace() { island.model.run(.verb("facetest", [:])) }

    @objc private func showSnaps() {
        try? FileManager.default.createDirectory(at: GuardMode.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(GuardMode.folder)
    }

    @objc private func toggleShare() { ScreenShare.visible.toggle() }

    @objc private func togglePrompter() { Prompter.shared.on ? Prompter.shared.end() : PrompterScriptWindow.shared.show() }

    @objc private func walkDog() { island.model.walkDog(force: true) }

    @objc private func testNotify() {
        island.model.show(Activity(id: "test", symbol: "sparkles", tint: .orange, title: "Island is alive",
                                   body: "Push your own: island notify \"Build done\"", banner: true, duration: 3.5))
    }
}

// Always on: a hand-opened copy hands over to launchd's (which relaunches Island if it quits).
guard AlwaysOn.boot() else { exit(0) }
// Stage 5 settings migration, before anything (the pup's needs, the status item) writes a default.
IslandSettings.migrate(hasFace: FaceID().hasOwner)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()


/// Shared secret for sensitive island:// verbs, in Application Support (mode 0600). Web pages cannot
/// read it; the user's own scripts can.
enum URLKey {
    static let file = FaceID.file.deletingLastPathComponent().appendingPathComponent("url.key")
    /// Verbs anyone may send: the push API, opening tabs, timers.
    static let open: Set<String> = ["notify", "dismiss", "open", "close", "timer", "focus", "stopwatch", "stoptimer",
                                    "awake", "hush", "notes", "mb", "dog", "pup", "nap", "dance", "facescan"]

    static let value: String = {
        if let k = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), k.count >= 16 { return k }
        let k = (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data(k.utf8), attributes: [.posixPermissions: 0o600])
        return k
    }()

    static func allows(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        // Unknown hosts become a notification (the old push API shape): allowed.
        if open.contains(host) || !Command.hosts.contains(host) { return true }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value
        return key == value
    }
}

import AVFoundation
import AppKit
import LocalAuthentication
import Security
import SwiftUI
import Vision

// Face unlock at the real macOS lock screen, the way Glance does it: macOS has no API for a
// third-party app to approve a login, so Island types your stored password into the lock
// screen when it sees *you*, alive. Convenience, not security: a webcam is 2D.
//
// Safeguards:
// - You type the password into Island once (never shown, never logged). It sits in your login
//   keychain, readable only by Island's signature.
// - It is loaded into memory only after you prove it's you (an unlock with your password or
//   Touch ID, or Start session), for 8 h; it expires, and is wiped on any failed attempt.
//   Restart or logout always needs your password.
// - Unlock needs: real lock screen up, exactly one face, your face (stricter than the away
//   blur), no spoof cue (screen glare, phone edges), and proof of life (blink or nose parallax).
// - At most 3 scans per lock; then it stays out of the way until the next lock.

enum LockCredential {
    private static let service = (Bundle.main.bundleIdentifier ?? "app.island.notch") + ".lockscreen"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: NSUserName()]
    }

    static var exists: Bool {
        var q = base; q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult static func save(_ password: String) -> Bool {
        delete()
        var q = base
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "Island lock screen face unlock"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}

final class LockScreenUnlock: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var sessionUntil: Date?
    @Published private(set) var hasPassword = LockCredential.exists
    @Published var enabled = UserDefaults.standard.object(forKey: "lockFace.enabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(enabled, forKey: "lockFace.enabled"); if !enabled { endSession() } }
    }
    @Published var hours = UserDefaults.standard.object(forKey: "lockFace.hours") as? Double ?? 8 {
        didSet { UserDefaults.standard.set(hours, forKey: "lockFace.hours") }
    }
    @Published private(set) var lastResult = ""
    var onUnlocked: (() -> Void)?
    /// The Face ID-style animation at the notch (over the lock screen).
    let overlay = LockFaceOverlay()
    /// The scan display belongs to the lock screen: once unlocked, only hiding gets through
    /// (previews call overlay.set directly).
    private func show(_ p: FaceScanPhase) {
        guard locked || p == .hidden else { return }
        overlay.set(p, locked: locked)
    }

    private let faceID: FaceID
    /// The password, only while a session is armed. Bytes we own, wiped in place.
    private var secret: [UInt8]?
    private let q = DispatchQueue(label: "island.lockface")
    private var session: AVCaptureSession?
    private var scanning = false
    /// Bumped by every scan start and stop: late frames / timers from an old scan are ignored.
    private var scanID = 0
    /// Bumped by every session end: late keychain reads can't revive a session you ended.
    private var sessionEpoch = 0
    private var scansThisLock = 0
    private var lockAt = Date()
    // Capture-queue state (only touched on `q`).
    private var qScanID = 0
    private var scanEnd = Date()
    private var frames = 0
    private var lastDist: Float?
    private var strongHits = 0
    private var scanStart = Date()
    private var firstFaceAt: Date?
    private var timedOut = false
    private let tracker = FaceTracker()
    private let liveness = LivenessAnalyzer()
    private let ctx = CIContext()
    private var locked = false
    private var typedAt: Date?
    private var poll: Timer?

    private static let badKey = "lockFace.badPassword"
    var passwordKnownBad: Bool { UserDefaults.standard.bool(forKey: Self.badKey) }

    init(faceID: FaceID) {
        self.faceID = faceID
        super.init()
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.didLock() }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.didUnlock() }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        // Sleep mid-scan: cancel it cleanly (the 8.5 s timer pauses during sleep) and give the
        // scan back, so the wake scan runs fresh.
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.scanning else { return }
                self.scansThisLock = max(0, self.scansThisLock - 1)
                self.stopScan()
            }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endSession() // fast user switch / logout: drop it
        }
        resumeSession()
    }

    /// Island relaunched (update, crash) mid-session while you're logged in and unlocked: pick the
    /// session back up until its original end. Never across a logout or restart (the end time is
    /// cleared then), never while locked, never with a password that already failed.
    private func resumeSession() {
        guard enabled, !passwordKnownBad, let until = UserDefaults.standard.object(forKey: "lockFace.until") as? Date, until > Date(),
              let boot = Self.bootTime, (UserDefaults.standard.object(forKey: "lockFace.boot") as? Date).map({ abs($0.timeIntervalSince(boot)) < 2 }) == true,
              !GuardMode.isLocked else { return }
        let epoch = sessionEpoch
        loadSecret { [weak self] bytes in
            guard let self, epoch == self.sessionEpoch, until > Date(), !self.locked else { return }
            self.arm(bytes, until: until)
            FaceID.debug("lockface: session resumed until \(until)")
        }
    }

    private static var bootTime: Date? {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// Only on Apple's faceprint model: the generic fallback can't tell lookalikes apart well enough
    /// to type a password.
    var ready: Bool { enabled && secret != nil && (sessionUntil ?? .distantPast) > Date() && faceID.hasOwner && FaceID.strongModel }

    // MARK: secret

    /// Keychain read off the main thread (after an update it can raise an "allow" prompt).
    private func loadSecret(_ done: @escaping ([UInt8]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard var d = LockCredential.load() else { return }
            let bytes = [UInt8](d)
            d.resetBytes(in: 0..<d.count) // the keychain's copy, wiped once ours is taken
            DispatchQueue.main.async { done(bytes) }
        }
    }

    private func arm(_ bytes: [UInt8], until: Date) {
        wipeSecret()
        secret = bytes
        sessionUntil = until
        UserDefaults.standard.set(until, forKey: "lockFace.until")
        UserDefaults.standard.set(Self.bootTime, forKey: "lockFace.boot")
    }

    /// Zero the stored bytes in place (not a copy), then drop them.
    private func wipeSecret() {
        if secret != nil {
            secret!.withUnsafeMutableBytes { p in if let b = p.baseAddress { memset_s(b, p.count, 0, p.count) } }
        }
        secret = nil
    }

    // MARK: setup

    func store(_ password: String) {
        guard !password.isEmpty else { return }
        endSession()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = LockCredential.save(password)
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasPassword = ok
                if ok { UserDefaults.standard.removeObject(forKey: Self.badKey) }
                self.lastResult = ok ? "Password saved. It arms the next time you unlock with Touch ID or your password." : "Couldn't save to the keychain."
            }
        }
    }

    func removePassword() {
        endSession()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            LockCredential.delete()
            DispatchQueue.main.async { self?.hasPassword = false; self?.lastResult = "Password removed." }
        }
    }

    /// Touch ID (or your password) now, then the stored password stays in memory for `hours`.
    func startSession() {
        guard hasPassword, !passwordKnownBad else {
            lastResult = passwordKnownBad ? "The stored password didn't work last time. Re-enter it first." : ""
            return
        }
        let la = LAContext()
        la.localizedFallbackTitle = "Use Password"
        let epoch = sessionEpoch
        la.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "turn on face unlock at the lock screen") { [weak self] ok, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else { self.lastResult = "Session not started."; return }
                self.loadSecret { bytes in
                    guard epoch == self.sessionEpoch else { return }
                    self.arm(bytes, until: Date().addingTimeInterval(self.hours * 3600))
                    self.enabled = true
                    self.lastResult = "Ready until \(self.sessionUntil!.formatted(date: .omitted, time: .shortened))."
                }
            }
        }
    }

    func endSession() {
        sessionEpoch &+= 1
        wipeSecret()
        sessionUntil = nil
        UserDefaults.standard.removeObject(forKey: "lockFace.until")
        stopScan()
    }

    // MARK: lock screen events

    private func didLock() {
        locked = true
        lockAt = Date()
        FaceID.debug("lockface: locked · ready=\(ready) enabled=\(enabled) password=\(hasPassword) session=\(sessionUntil.map { "\($0)" } ?? "none") face=\(faceID.hasOwner)")
        scansThisLock = 0
        typedAt = nil
        if let u = sessionUntil, u < Date() { endSession() }
        // Someone pressing a key / clicking at the lock screen: scan (within the cap). Only input
        // that came after the lock counts, so the ⌃⌘Q that locked it doesn't start a scan.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.locked, !self.scanning else { return }
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            let since = Date().timeIntervalSince(self.lockAt)
            if since > 1.5, idle < 0.8, idle < since - 1.0 { self.scan() }
        }
        poll?.tolerance = 0.2
    }

    private func didUnlock() {
        locked = false
        poll?.invalidate(); poll = nil
        let byFace = typedAt.map { Date().timeIntervalSince($0) < 6 } == true
        stopScan()
        // The scan belongs to the lock screen: unlocked any other way (Touch ID, password, Apple
        // Watch), it goes away now. A face unlock lets "GRANTED" finish on its own.
        if !byFace { overlay.set(.hidden, locked: false) }
        FaceID.debug("lockface: unlocked by \(byFace ? "face" : "Touch ID / password")")
        // A real authentication (not a face unlock) arms / extends the session. A face unlock never
        // renews itself, so the session length really does force your password or Touch ID.
        if !byFace, enabled, hasPassword, !passwordKnownBad {
            let epoch = sessionEpoch
            let keep = secret
            let arm: ([UInt8]) -> Void = { [weak self] bytes in
                guard let self, epoch == self.sessionEpoch, !self.locked else { return }
                self.arm(bytes, until: Date().addingTimeInterval(self.hours * 3600))
                FaceID.debug("lockface: armed by unlock until \(self.sessionUntil!)")
            }
            if let keep { secret = nil; arm(keep) } else { loadSecret(arm) }
        }
        if byFace {
            lastResult = "Unlocked by your face at \(Date().formatted(date: .omitted, time: .shortened))"
            onUnlocked?()
        }
        typedAt = nil
    }

    /// Display woke while locked (lid opened, key pressed): look for you.
    private func wake() { if locked { scan() } }

    // MARK: scan

    private func scan() {
        guard ready, locked, !scanning, scansThisLock < 3, typedAt == nil else { return }
        scansThisLock += 1
        scanID &+= 1
        let id = scanID
        scanning = true
        FaceID.debug("lockface: scan \(scansThisLock)")
        show(.scanning)
        // Hard stop even if the camera never delivers a frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { [weak self] in
            guard let self, self.scanning, self.scanID == id, self.locked else { return }
            FaceID.debug("lockface: scan ended by watchdog")
            self.show(.failed(self.scansThisLock < 3 ? "Tap a key to try again · or use Touch ID" : "Use Touch ID or your password"))
            self.stopScan()
        }
        q.async { [self] in
            qScanID = id
            scanEnd = Date().addingTimeInterval(8)
            frames = 0; lastDist = nil; strongHits = 0; scanStart = Date(); firstFaceAt = nil; timedOut = false
            tracker.reset(); liveness.reset()
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                  let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else {
                DispatchQueue.main.async {
                    guard self.scanID == id, self.locked else { return }
                    FaceID.debug("lockface: camera unavailable")
                    self.scansThisLock = 3 // it won't appear on the next key press either
                    self.show(.failed("Camera unavailable · use Touch ID"))
                    self.stopScan()
                }
                return
            }
            let s = AVCaptureSession()
            s.sessionPreset = s.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
            let out = AVCaptureVideoDataOutput()
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: q)
            if s.canAddInput(input) { s.addInput(input) }
            if s.canAddOutput(out) { s.addOutput(out) }
            s.startRunning()
            session = s
        }
    }

    /// Stop the camera and invalidate the scan; a scan still showing "scanning" is folded away.
    private func stopScan() {
        scanning = false
        scanID &+= 1
        let id = scanID
        if overlay.phase == .scanning { overlay.set(.hidden, locked: locked) }
        q.async { [self] in qScanID = id; session?.stopRunning(); session = nil }
    }

    /// Runs `body` on main only if this frame's scan is still the live one and we're still locked.
    private func onMain(_ id: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.async { guard self.scanning, self.scanID == id, self.locked else { return }; body() }
    }

    func captureOutput(_: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from _: AVCaptureConnection) {
        let id = qScanID
        guard session != nil, !timedOut else { return }
        if Date() > scanEnd {
            timedOut = true
            FaceID.debug("lockface: scan timed out who=\(tracker.who) live=\(liveness.decision)")
            onMain(id) {
                self.show(.failed(self.scansThisLock < 3 ? "Tap a key to try again · or use Touch ID" : "Use Touch ID or your password"))
                self.stopScan()
            }
            return
        }
        frames += 1
        // Every frame after a short warm-up: full frame rate catches blinks and head turns.
        guard frames > 2, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        let ci = CIImage(cvPixelBuffer: px)
        let faces = FaceID.allLandmarks(ci).filter { $0.boundingBox.width > 0.05 }
        // Exactly one face: nobody holding a photo up beside you, no shoulder surfer.
        guard faces.count == 1, let f = faces.first, f.boundingBox.width > 0.09 else {
            report(id, 0.06, faces.count > 1 ? "Only one face, please" : "Move into view")
            return
        }
        tracker.saw(f)
        if firstFaceAt == nil { firstFaceAt = Date() }
        let d = liveness.observe(LivenessFeatures.frame(f, in: ci, ctx: ctx, heavy: frames % 6 == 0))
        telemetry(id, f, d)
        if d.isDenied {
            timedOut = true
            FaceID.debug("lockface: spoof suspected (\(d)), stopping")
            onMain(id) {
                self.scansThisLock = 3
                self.show(.failed("Looks like a photo or a screen · use Touch ID"))
                self.stopScan()
            }
            return
        }
        // Identity every 2nd frame, only on good frames (big enough, facing, level).
        let yaw = abs(f.yaw?.doubleValue ?? 0), roll = abs(f.roll?.doubleValue ?? 0)
        let good = f.boundingBox.width > 0.11 && yaw < 0.5 && roll < 0.45 && (f.faceCaptureQuality ?? 1) > 0.25
        if frames % 2 == 0, good, let p = FaceID.printFace(ci, face: f) {
            let m = faceID.match(p)
            lastDist = m.dist
            if m.dist <= faceID.threshold * 0.55 { strongHits += 1 }
            // Stricter than the away blur: well inside your threshold.
            tracker.vote(owner: m.owner && m.dist <= faceID.threshold * 0.9)
        }
        let alive = tracker.live.blinkedRecently || d.isConfirmed
        let idProgress = min(1, max(Double(min(tracker.ownerVotes, 3)) / 3, Double(strongHits) / 2))
        report(id, 0.22 + 0.48 * idProgress + (alive ? 0.3 : 0), idProgress >= 1 && !alive ? "Blink once" : nil)
        let you = tracker.who == .owner || strongHits >= 2
        guard you, alive else { return }
        timedOut = true // one unlock per scan
        let t0 = scanStart, tf = firstFaceAt
        FaceID.debug(String(format: "lockface: match in %.2fs (face seen at %.2fs) strong=%d votes=%d dist=%.3f",
                            Date().timeIntervalSince(t0), tf.map { $0.timeIntervalSince(t0) } ?? -1, strongHits, tracker.ownerVotes, lastDist ?? -1))
        onMain(id) { self.unlock() }
    }

    private func telemetry(_ id: Int, _ f: VNFaceObservation, _ d: LivenessDecision) {
        var t = ScanTelemetry()
        t.match = lastDist
        t.threshold = faceID.threshold * 0.9
        t.votes = min(tracker.ownerVotes, 3)
        switch d {
        case .confirmed(let c): t.life = c == .blink ? "BLINK" : "PARALLAX"
        case .denied(let c): t.spoof = c == .glare ? "GLARE" : "DEVICE"
        case .pending: t.life = tracker.live.blinkedRecently ? "BLINK" : "—"
        }
        t.frames = frames
        t.face = CGPoint(x: f.boundingBox.midX, y: f.boundingBox.midY)
        onMain(id) { self.overlay.update(telemetry: t) }
    }

    /// Real progress for the ring: face found, identity votes, proof of life.
    private func report(_ id: Int, _ p: Double, _ hint: String?) {
        onMain(id) { self.overlay.update(progress: p, hint: hint) }
    }

    // MARK: unlock

    private func unlock() {
        guard scanning, locked, GuardMode.isLocked, secret != nil, ready else { return }
        guard AXIsProcessTrusted() else {
            scansThisLock = 3
            show(.failed("Turn on Accessibility for Island · use Touch ID"))
            stopScan()
            return
        }
        show(.matched(Pet.owner)) // before stopScan, so the display goes straight to GRANTED
        stopScan()
        FaceID.debug("lockface: typing")
        let typed = secret!.withUnsafeBufferPointer { Self.type($0) }
        guard typed else {
            FaceID.debug("lockface: typing aborted (lock state changed)")
            show(.hidden)
            return
        }
        typedAt = Date()
        // Still locked a few seconds later: the stored password is wrong (changed?). Mark it bad so
        // it isn't re-armed and retyped at every lock; you re-enter it in settings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.locked, self.typedAt != nil, GuardMode.isLocked else { return }
            FaceID.debug("lockface: still locked after typing, password marked bad")
            UserDefaults.standard.set(true, forKey: Self.badKey)
            self.lastResult = "Typing the password didn't unlock the Mac. If you changed it, re-enter it in Face Unlock settings."
            self.typedAt = nil
            self.show(.failed("Stored password didn't work · use Touch ID"))
            self.endSession()
        }
    }

    /// Lock screen genuinely up for this console session, checked live before every key.
    private static var lockScreenUp: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool ?? false) && (d[kCGSessionOnConsoleKey as String] as? Bool ?? false)
    }

    /// Clear the field (⌘→ then deletes, layout-proof), type the password, press Return. Straight from the
    /// stored bytes (UTF-8 → UTF-16, no String copy). Stops the moment the lock screen goes away,
    /// so nothing lands in an app after a Touch ID unlock mid-type. Returns false if it stopped.
    private static func type(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ code: CGKeyCode, cmd: Bool = false, gap: useconds_t = 12_000) -> Bool {
            guard lockScreenUp else { return false }
            if cmd { CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)?.post(tap: .cghidEventTap) }
            let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
            if cmd { d?.flags = .maskCommand; u?.flags = .maskCommand }
            d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
            if cmd { CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)?.post(tap: .cghidEventTap) }
            usleep(gap)
            return true
        }
        // Clear the field: end of line, then plain deletes. Never ⌘⌫ (in Finder that trashes the
        // selection if Touch ID unlocks mid-way); a stray plain delete costs at most one character.
        guard key(0x7C, cmd: true) else { return false }
        for _ in 0..<32 { guard key(0x33, gap: 2_000) else { return false } }
        var ok = true
        _ = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true) { unit in
            guard ok, lockScreenUp else { ok = false; return }
            var c = unit
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            u?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
        guard ok else { return false }
        return key(0x24) // Return, only if still on the lock screen
    }
}

// MARK: - Settings window

final class LockFaceWindow {
    static let shared = LockFaceWindow()
    private var window: NSWindow?

    func show(_ u: LockScreenUnlock) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Face Unlock at the Lock Screen"
        w.contentView = NSHostingView(rootView: LockFaceView(u: u))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct LockFaceView: View {
    @ObservedObject var u: LockScreenUnlock
    @State private var pw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Convenience, not security", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Text("Your webcam is 2D. Island blocks photos and phone screens, but a video of your face could unlock this Mac. Island types your password into the lock screen when it sees you, alive.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if u.hasPassword && !u.passwordKnownBad {
                HStack {
                    Label("Password stored in your keychain", systemImage: "key.fill")
                    Spacer()
                    Button("Remove", role: .destructive) { u.removePassword() }
                }
            } else {
                if u.hasPassword {
                    Label("The saved password didn't unlock the Mac last time. Type it again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    Text("Your Mac login password").font(.subheadline.weight(.semibold))
                }
                HStack {
                    SecureField("Password", text: $pw).textFieldStyle(.roundedBorder).onSubmit(save)
                    Button("Save", action: save).disabled(pw.isEmpty)
                }
            }
            Stepper("Session length: \(Int(u.hours)) h", value: $u.hours, in: 1...24)
            HStack {
                Button { u.startSession() } label: { Label(u.ready ? "Renew session" : "Start session (Touch ID)", systemImage: "touchid") }
                    .disabled(!u.hasPassword || u.passwordKnownBad)
                if u.ready { Button("End session") { u.endSession() } }
            }
            Toggle("Face unlock at the lock screen", isOn: $u.enabled)
            if let until = u.sessionUntil, u.ready {
                Label("Ready until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "faceid").foregroundStyle(.green)
            }
            if !u.lastResult.isEmpty { Text(u.lastResult).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text("Needs your registered face, Camera and Accessibility for Island. After a restart or logout you always type your password.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420, height: 440)
    }

    private func save() { u.store(pw); pw = "" }
}

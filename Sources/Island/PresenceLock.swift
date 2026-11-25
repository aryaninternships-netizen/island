import AVFoundation
import AppKit
import Combine
import IOKit.pwr_mgt
import Vision

/// Presence mode: your Mac stays unlocked while you're at it, and locks the moment you leave.
///
/// - Typing / using the trackpad = you're here. No camera.
/// - No input for 15 s (reading, watching): a quick look (camera on ~1 s at 640x480). Seen → the
///   display is kept awake and the camera goes off; the next look comes 20 s later, backing off
///   to every 90 s while you keep reading. Any key or mouse move resets it.
/// - Not seen in a look → the camera stays on; gone 20 s → "Locking in 8…" banner (look back to
///   cancel) → screen locks. Someone else's face doesn't count as you.
/// Paused while Guard is armed or the screen is locked. The real unlock stays Touch ID / password.
final class PresenceLock: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// What the island shows. Display only: derived on main from the state below, never drives it.
    enum Status: Equatable { case off, idle, watching, warning(Int), paused }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "presence.enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "presence.enabled"); if !newValue { pauseAll() }
            publishStatus()
        }
    }
    /// Published on main only (capture callbacks run on `q`).
    @Published private(set) var status: Status = .idle
    @Published private(set) var isEnabled = UserDefaults.standard.object(forKey: "presence.enabled") as? Bool ?? true
    /// Countdown seconds left (nil = cancelled), for the island banner.
    var onWarn: ((Int?) -> Void)?
    /// You're gone: the model starts the away soft lock (falls back to a real lock).
    var onAway: (() -> Void)?
    /// True while something else owns the situation (Guard armed, island busy with a test…).
    var isPaused: () -> Bool = { false }

    private let faceID: FaceID
    private let q = DispatchQueue(label: "island.presence-lock")
    private var session: AVCaptureSession?
    private var frames = 0
    private var lastLook: CFTimeInterval = 0 // capture queue only
    private var lastMatch: (box: CGRect, at: CFTimeInterval)? // capture queue only
    // Capture queue only: the warm session's parts, and the motion gate.
    private var device: AVCaptureDevice?
    private var watching = false
    private var youRef: [UInt8]?
    private var youRefAt: CFTimeInterval = 0
    private var lastBody: (seen: Bool, at: CFTimeInterval)?
    private var stats = (frames: 0, looks: 0, vision: 0, skips: 0, ms: 0.0, since: CACurrentMediaTime())
    private var camInfo = ""
    private var startedAt: CFTimeInterval = 0
    private var missLog = true
    private var lastGrid: [UInt8]?
    // Main thread: occasional looks while you're idle.
    private var searching = false
    private var lookStart: Date?
    private var nextLook: Date?
    private var lookGap = PresenceLock.firstLookGap
    static let firstLookGap: Double = 20
    static let maxLookGap: Double = 90
    static let lookSeconds: Double = 4
    private var lastYou = Date() {
        // Read-only tap for the sit reminder: a fresh "you're here" (input, or a look that saw you).
        // Backdated resets are skipped. Never feeds back into the lock.
        didSet { if lastYou.timeIntervalSinceNow > -1 { seen.send(lastYou) } }
    }
    /// Presence results, on main. Display/reminder use only; the lock logic never reads it.
    let seen = PassthroughSubject<Date, Never>()
    private var assertion: IOPMAssertionID = 0
    private var holding = false
    private var warning = false
    private var screenLocked = false
    private var timer: Timer?
    private var wasPaused = false
    /// Last time we knew it was you: your face matched, or your hands were on the Mac.
    private var verified = Date.distantPast

    static let idleBeforeCamera: Double = 15
    static let goneBeforeWarning: Double = 20
    static let warningSeconds: Double = 8
    /// After you're confirmed, any face/body at the desk counts as you for this long.
    static let trustWindow: Double = 20 * 60

    init(faceID: FaceID) {
        self.faceID = faceID
        super.init()
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true; self?.pauseAll()
        }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false; self?.lastYou = Date(); self?.verified = Date()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pauseAll()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        defer { publishStatus() }
        // No camera grant: nothing can see you come back, so never blur or lock on idle alone.
        let camOK = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        guard enabled, camOK, !screenLocked, !isPaused() else { pauseAll(); resetLooks(); wasPaused = true; return }
        let now = Date()
        // Coming back from a pause (Guard, away soft lock, lock screen): start fresh.
        if wasPaused { wasPaused = false; lastYou = now }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < Self.idleBeforeCamera {
            // Keyboard or mouse in use: that's you. No camera at all.
            lastYou = now
            verified = now
            resetLooks()
            stopCamera(); release(); cancelWarning()
            return
        }
        if !searching {
            // Hands off, probably reading: a quick look now and then instead of a running camera.
            // Seen → camera off, next look later (backing off while you keep reading). Not seen in
            // a look → camera stays on and the away countdown runs as before.
            if let start = lookStart {
                if lastYou > start {
                    stopCamera()
                    lookStart = nil
                    hold(); cancelWarning()
                    nextLook = now.addingTimeInterval(lookGap)
                    lookGap = min(lookGap * 1.5, Self.maxLookGap)
                    return
                }
                guard now.timeIntervalSince(start) > Self.lookSeconds else { return }
                // Not found in a full look: watch continuously, countdown from a few seconds ago.
                q.async { [self] in
                    let mean = lastGrid.map { Double($0.reduce(0) { $0 + Int($1) }) / Double(max($0.count, 1)) } ?? -1
                    FaceID.debug(String(format: "presence: not seen in a look (brightness %.0f/255, %d looks), watching", mean, stats.looks))
                }
                searching = true
                lookStart = nil
                lastYou = now.addingTimeInterval(-Self.lookSeconds)
            } else {
                if now >= (nextLook ?? now) { lookStart = now; startCamera() }
                return
            }
        }
        startCamera()
        let gone = now.timeIntervalSince(lastYou)
        if gone < 2 {
            // Back in view: return to occasional looks.
            hold(); cancelWarning()
            searching = false
            stopCamera()
            nextLook = now.addingTimeInterval(Self.firstLookGap)
            return
        }
        if gone >= Self.goneBeforeWarning + Self.warningSeconds {
            cancelWarning(); release(); stopCamera()
            lastYou = now
            resetLooks()
            if let onAway { onAway() } else { GuardMode.lockScreen() }
            return
        }
        if gone >= Self.goneBeforeWarning {
            warning = true
            onWarn?(Int((Self.goneBeforeWarning + Self.warningSeconds - gone).rounded(.up)))
        }
    }

    /// Main only. Reads the main-thread state; assigns only on change, so a steady state never publishes.
    private func publishStatus() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.publishStatus() }; return }
        let on = enabled
        let s: Status
        if !on { s = .off }
        else if screenLocked || isPaused() { s = .paused }
        else if warning {
            let gone = Date().timeIntervalSince(lastYou)
            s = .warning(max(1, Int((Self.goneBeforeWarning + Self.warningSeconds - gone).rounded(.up))))
        } else if searching || lookStart != nil || holding { s = .watching }
        else { s = .idle }
        if isEnabled != on { isEnabled = on }
        if status != s { status = s }
    }

    private func resetLooks() {
        searching = false; lookStart = nil; nextLook = nil; lookGap = Self.firstLookGap
    }

    private func pauseAll() { stopCamera(); release(); cancelWarning() }

    private func cancelWarning() {
        guard warning else { return }
        warning = false
        onWarn?(nil)
    }

    // MARK: display awake

    private func hold() {
        guard !holding else { return }
        holding = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                              IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                              "Island presence: you're at the Mac" as CFString, &assertion) == kIOReturnSuccess
    }

    private func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertion)
        holding = false
    }

    // MARK: camera

    /// Recently confirmed at the desk: another camera check (sit-watch) can take this as presence.
    var recentlySeen: Bool { enabled && Date().timeIntervalSince(lastYou) < 30 }

    private func startCamera() {
        q.async { [self] in
            watching = true
            if let s = session {
                if !s.isRunning, let dev = device {
                    s.startRunning()
                    CameraConfig.reapplyCap(dev, fps: 5)
                    frames = 0
                    startedAt = CACurrentMediaTime()
                }
                return
            }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                  let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else { return }
            let s = AVCaptureSession()
            let out = AVCaptureVideoDataOutput()
            out.setSampleBufferDelegate(self, queue: q)
            // Presence needs one look a second: 5 fps, so the camera isn't delivering (and waking us
            // for) frames we'd throw away.
            camInfo = CameraConfig.start(session: s, device: dev, input: input, output: out, fps: 5, preset: .vga640x480, width: 960)
            FaceID.debug("presence: camera \(camInfo)")
            session = s
            device = dev
            frames = 0
            startedAt = CACurrentMediaTime()
        }
    }

    /// Stop the camera (LED off) but keep the session built, so the next start is cheap.
    private func stopCamera() {
        q.async { [self] in
            watching = false
            if session?.isRunning == true { session?.stopRunning() }
            lastMatch = nil; youRef = nil; lastBody = nil
        }
    }

    func captureOutput(_: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from _: AVCaptureConnection) {
        frames += 1
        stats.frames += 1
        flushStats()
        // One look a second, whatever rate the camera actually runs at (it may ignore the cap).
        // The away countdown is 20 s, so a 1 s look costs nothing in reaction time.
        let now = CACurrentMediaTime()
        // Skip the first 0.7 s after a start: auto-exposure is still settling and early frames are
        // too dark for face detection. Then two looks a second (a look is short, so this is cheap).
        guard watching, now - startedAt > 0.7, now - lastLook >= 0.5, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        if missLog { missLog = false; FaceID.debug("presence: look \(CVPixelBufferGetWidth(px))x\(CVPixelBufferGetHeight(px))") }
        lastLook = now
        stats.looks += 1
        // Motion gate: the scene hasn't changed since a look that saw you (< 5 s ago): still you.
        // Anyone swapping into the seat changes the picture far past this threshold.
        let grid = LumaGate.grid(px)
        lastGrid = grid
        if let g = grid, let ref = youRef, now - youRefAt < 5, LumaGate.diff(g, ref) < 6 {
            stats.skips += 1
            DispatchQueue.main.async { self.lastYou = Date() }
            return
        }
        stats.vision += 1
        let t0 = CACurrentMediaTime()
        defer { stats.ms += (CACurrentMediaTime() - t0) * 1000 }
        let ci = CIImage(cvPixelBuffer: px)
        let trusted = Date().timeIntervalSince(verified) < Self.trustWindow
        var you = false
        if let face = FaceID.detectFace(ci), face.boundingBox.width > 0.06 {
            // Same face, same spot as a look that matched you, under 10 s ago: still you, skip the
            // faceprint (the costly part). Swapping seats can't keep the box in place between looks.
            let box = face.boundingBox
            if let lm = lastMatch, now - lm.at < 10, Self.overlap(lm.box, box) > 0.5 {
                you = true
                lastMatch = (box, lm.at) // follow small moves; full print again after 10 s
            } else if !faceID.hasOwner {
                you = true
            } else if let p = FaceID.printFace(ci, face: face) {
                let m = faceID.match(p)
                lastMatch = m.owner ? (box, now) : nil
                if m.owner { you = true; DispatchQueue.main.async { self.verified = Date() } }
                // Bad angle or light: still you if it's close-ish and you were confirmed recently.
                // A stranger's face sits far above this (0.8+), so they never count.
                else if trusted, m.dist < faceID.threshold * 1.3 { you = true }
            } else {
                you = trusted
            }
        } else {
            lastMatch = nil // face gone: the next face gets a full print
            // Looking down at a phone / notebook: no face, but someone is sitting right there.
            // The body check is the costliest request: at most every 3 s.
            if trusted {
                if let b = lastBody, now - b.at < 3 { you = b.seen }
                else { let seen = Self.bodyAtDesk(ci); lastBody = (seen, now); you = seen }
            }
        }
        if you {
            youRef = grid; youRefAt = now
            DispatchQueue.main.async { self.lastYou = Date() }
        } else {
            youRef = nil
        }
    }

    /// Every 30 s: frames, looks, Vision passes, gate skips and Vision time, for the debug log.
    private func flushStats() {
        let now = CACurrentMediaTime(), dt = now - stats.since
        guard dt >= 30 else { return }
        FaceID.debug(String(format: "presence: %.1f fps, %.2f looks/s, %.2f vision/s, %d skips, %.0f ms/s vision",
                            Double(stats.frames) / dt, Double(stats.looks) / dt, Double(stats.vision) / dt, stats.skips, stats.ms / dt))
        stats = (0, 0, 0, 0, 0, now)
    }

    /// Intersection over union of two normalized boxes.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let ia = i.width * i.height
        return ia / (a.width * a.height + b.width * b.height - ia)
    }

    /// An upper body filling a good part of the frame: someone in the seat.
    private static func bodyAtDesk(_ ci: CIImage) -> Bool {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = true
        try? VNImageRequestHandler(ciImage: ci).perform([r])
        return (r.results ?? []).contains { $0.boundingBox.height > 0.35 && $0.confidence > 0.5 }
    }

    /// For the menu: is the display currently held awake because you're here?
    var isHolding: Bool { holding }
}

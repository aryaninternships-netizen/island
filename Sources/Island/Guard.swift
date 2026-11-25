import AppKit
import SwiftUI
import AVFoundation
import LocalAuthentication
import Vision

/// "Watch my Mac": arm it, walk away.
/// - People moving around the room: ignored.
/// - Someone else close to the laptop looking at the screen (or walking up to it): blur + photo +
///   Touch ID / your face to clear it; no answer in 20 s = lock.
/// - Someone else within arm's reach and the keys/trackpad move: blur + photo + lock now.
/// - Keys/trackpad move with no face in view: lock now (or blur + Touch ID if you were seen <15 s ago).
/// - You, recognised and blinking: disarms. Snapshots go to ~/Pictures/Island Guard.
final class GuardMode: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State: Equatable { case off, arming, armed, challenged, alarm }

    /// Messages for the island banner. State for the UI comes from `shown` below.
    var onState: ((State, String) -> Void)?
    private(set) var state: State = .off
    /// `state` and `away` as the UI sees them, published on main only.
    @Published private(set) var shown: State = .off
    @Published private(set) var shownAway = false
    private(set) var snapshots = 0

    private let q = DispatchQueue(label: "island.guard")
    private var session: AVCaptureSession?
    private var latest: CVPixelBuffer?
    private var frames = 0
    // Capture queue only: the empty-seat motion gate.
    private var emptyRef: [UInt8]?
    private var pendingRef: [UInt8]?
    private var lastEmptyLook: CFTimeInterval = 0
    private var poll: Timer?
    private var armWork: DispatchWorkItem?
    private let ci = CIContext()
    let shield = Shield()
    let faceID = FaceID()
    let tracker = FaceTracker()
    /// Glance-derived anti-spoof checks for every face unlock (photo / phone screen = no).
    let liveness = LivenessAnalyzer()
    private var lastSpoofLog = Date.distantPast
    /// Strangers peeking / at the keyboard; rebuilt on each arm so it knows if a profile exists.
    private(set) var attention = Attention(hasProfile: false)
    /// Incident being recorded (photos + face close-up go here).
    private var currentEvent: UUID?
    /// Largest face that isn't you, from the last identity check (normalised box).
    private var otherFace: (box: CGRect, at: Date)?
    private var laContext: LAContext?
    private var faceUnlocked = false
    /// Auto-unlock by face only after the seat was empty once (so it doesn't disarm while you're leaving).
    private var sawEmpty = false
    private var emptySince: Date?
    /// Presence soft lock: you walked away. Blurred, opens for your face, real lock for anything else.
    private(set) var away = false
    private var awayDeadline: DispatchWorkItem?
    private var lastAwayPeek = Date.distantPast
    /// First touch while a face is in view: give recognition + a blink 2 s before locking.
    private var awayTouchAt: Date?
    private var awayStart = Date()
    private var lastAwayLog = Date.distantPast

    static let folder: URL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Island Guard", isDirectory: true)

    func toggle() { state == .off ? arm() : disarm(message: "Guard off") }

    func arm(delay: TimeInterval = 10) {
        guard state == .off else { return }
        // Without the camera Guard can't tell you from anyone else: every keypress would sound the alarm.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            set(.off, "Guard needs the camera · System Settings › Privacy › Camera"); return
        }
        snapshots = 0
        tracker.reset(); liveness.reset(); sawEmpty = false; emptySince = nil
        attention = Attention(hasProfile: faceID.hasOwner)
        set(.arming, "Arming in \(Int(delay))s · walk away")
        startCamera()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .arming else { return }
            self.set(.armed, self.faceID.hasOwner ? "Watching · knows your face" : "Watching your Mac")
            self.poll = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.checkInput() }
        }
        armWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// You just left (Presence saw your seat go empty). Blur now; your face + a blink opens it again
    /// with no password. Keys/trackpad without your face, or `grace` running out: the real lock
    /// screen (display sleep), where Touch ID works.
    func armAway(grace: TimeInterval) {
        guard state == .off else { return }
        away = true
        snapshots = 0
        tracker.reset(); liveness.reset(); sawEmpty = true; emptySince = nil
        attention = Attention(hasProfile: faceID.hasOwner)
        awayTouchAt = nil
        awayStart = Date()
        FaceID.debug("away: armed, grace \(Int(grace))s")
        shield.show(reason: "Away", hint: faceID.hasOwner ? "Look at the camera and blink to open  ·  any key for Touch ID" : "Any key for Touch ID",
                    calm: true)
        startCamera()
        set(.armed, "Away · your face opens it")
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkInput() }
        let w = DispatchWorkItem { [weak self] in self?.awayLock("Locked · Touch ID is ready") }
        awayDeadline = w
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: w)
    }

    /// Hand over to the real lock screen, then stand down (the blur stays until the lock is up).
    private func awayLock(_ msg: String) {
        guard away, state == .armed else { return }
        FaceID.debug("away: lock (\(msg)) who=\(tracker.who) blink=\(tracker.live.blinkedRecently)")
        poll?.invalidate(); poll = nil
        awayDeadline?.cancel()
        Self.lockScreen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.disarm(message: msg) }
    }

    func disarm(message: String) {
        awayDeadline?.cancel(); awayDeadline = nil
        away = false
        armWork?.cancel()
        poll?.invalidate(); poll = nil
        stopCamera()
        shield.hide()
        currentEvent = nil; otherFace = nil
        set(.off, message)
    }

    private func set(_ s: State, _ msg: String) {
        state = s
        DispatchQueue.main.async {
            if self.shown != s { self.shown = s }
            if self.shownAway != self.away { self.shownAway = self.away }
            self.onState?(s, msg)
        }
    }

    // MARK: triggers

    private func checkInput() {
        guard state == .armed || state == .challenged else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 0.5 else { return }
        // You, live, closest to the screen: it's your hands on the keys.
        if liveOwner { faceUnlock(); return }
        // Someone else's face is right at the laptop and the keys/trackpad move: that's them. Lock.
        if attention.strangerAtKeyboard { strangerTouch("Someone else used your Mac"); return }
        // Away mode: you coming back usually touch the trackpad before the camera has finished
        // with you. With a face in view (not a known stranger) wait 2 s for match + blink; keys
        // land on the blur meanwhile. No face, or still unconfirmed after 2 s: real lock.
        if away {
            // Ignore the keypress that started it and anything before the camera is up (~2 s).
            let since = Date().timeIntervalSince(awayStart)
            if since < 2 || idle > since - 0.2 { return }
            if tracker.faceVisible, tracker.who != .stranger {
                if awayTouchAt == nil { awayTouchAt = Date(); FaceID.debug("away: touch with face in view, waiting for match+blink") }
                if Date().timeIntervalSince(awayTouchAt!) < 2 { return }
                awayLock("Touched, face not confirmed"); return
            }
            awayLock("Touched with no face in view"); return
        }
        // While challenged, the input is the owner answering the Touch ID prompt.
        guard state == .armed else { return }
        switch tracker.who {
        case .none where tracker.ownerSeen(within: 15):
            // You were just here: probably your own arm reaching in. Blur + Touch ID, not a lock.
            trigger("Touched out of camera view")
        case .none:
            // Keys moving with no face anywhere: someone is hiding from the camera. Lock now.
            strangerTouch("Touched while hiding from the camera")
        default:
            // A face far off / not yet identified / you without a blink: blur + challenge.
            trigger("Someone touched your Mac")
        }
    }

    /// You, and real: recognised, no spoof cue fired, and alive (our blink, or Glance's blink /
    /// nose parallax).
    private var liveOwner: Bool {
        guard tracker.who == .owner, !liveness.decision.isDenied else { return false }
        return tracker.live.blinkedRecently || liveness.decision.isConfirmed
    }

    /// Your live face is the key: disarms when armed, clears the challenge when challenged.
    private func faceUnlock() {
        DispatchQueue.main.async { [self] in
            switch state {
            case .armed where sawEmpty:
                if away { FaceID.debug("away: opened by face") }
                disarm(message: away ? "Welcome back" : "Welcome back · unlocked by your face")
            case .challenged:
                faceUnlocked = true
                laContext?.invalidate() // callback sees faceUnlocked and disarms
            default: break
            }
        }
    }

    private func trigger(_ why: String) {
        DispatchQueue.main.async { [self] in
            guard state == .armed else { return }
            shield.show(reason: why, hint: faceID.hasOwner ? "Owner? Look at the camera and blink · or use Touch ID" : "Owner? Use Touch ID")
            // blur first, everything else after
            set(.challenged, why)
            currentEvent = GuardLog.shared.begin(why)
            snap(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.snap() }
            NSSound(named: "Sosumi")?.play()
            challenge()
        }
    }

    /// Blur, photograph, lock. No second chances.
    private func strangerTouch(_ why: String) {
        guard state == .armed || state == .challenged else { return }
        laContext?.invalidate() // drop any open Touch ID prompt; its callback sees .alarm and stays quiet
        shield.show(reason: "Hands off")
        set(.alarm, why)
        currentEvent = GuardLog.shared.begin(why)
        snap(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.snap() }
        NSSound(named: "Sosumi")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Self.lockScreen() }
    }

    /// Lock the normal way: display sleep, like closing the lid. With "require password
    /// immediately" that is the standard lock screen, where Touch ID works. (The private
    /// SACLockScreenImmediate lock forces a password prompt, so it's only the fallback for Macs
    /// set to ask for the password later.)
    static func lockScreen() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !isLocked else { return }
            typealias Lock = @convention(c) () -> Void
            if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
               let sym = dlsym(h, "SACLockScreenImmediate") {
                unsafeBitCast(sym, to: Lock.self)()
            }
        }
    }

    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func challenge() {
        let ctx = LAContext()
        laContext = ctx
        faceUnlocked = false
        var timedOut = false
        let timeout = DispatchWorkItem { timedOut = true; ctx.invalidate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        NSApp.activate(ignoringOtherApps: true)
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "disarm Island Guard") { ok, _ in
            DispatchQueue.main.async { [self] in
                timeout.cancel()
                laContext = nil
                if state == .alarm { return } // a stranger already triggered the lock
                if faceUnlocked {
                    let n = snapshots
                    disarm(message: "Unlocked by your face" + (n > 0 ? " · \(n) snapshot\(n == 1 ? "" : "s")" : ""))
                } else if ok, !timedOut {
                    let n = snapshots
                    disarm(message: n > 0 ? "Welcome back · \(n) snapshot\(n == 1 ? "" : "s") saved" : "Welcome back")
                } else {
                    alarm()
                }
            }
        }
    }

    private func alarm() {
        set(.alarm, "Hands off! Photo saved")
        snap()
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { t in
            NSSound(named: "Sosumi")?.play()
            n += 1
            if n >= 8 { t.invalidate() }
        }
        // Lock right away; the owner unlocking with their password disarms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Self.lockScreen() }
    }

    /// Called on screen unlock: whoever unlocked knows the password.
    func ownerUnlocked() {
        guard state != .off else { return }
        let n = snapshots
        disarm(message: n > 0 ? "Guard off · \(n) snapshot\(n == 1 ? "" : "s") of the intruder" : "Guard off")
    }

    // MARK: camera

    private func startCamera() {
        q.async { [self] in
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                  let dev = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: dev) else { return }
            let s = AVCaptureSession()
            let out = AVCaptureVideoDataOutput()
            out.setSampleBufferDelegate(self, queue: q)
            // 15 fps: enough for blinks, half the frames of the camera's default.
            FaceID.debug("guard: camera \(CameraConfig.start(session: s, device: dev, input: input, output: out, fps: 15, preset: .hd1280x720, width: 1280))")
            session = s
        }
    }

    private func stopCamera() {
        q.async { [self] in session?.stopRunning(); session = nil; latest = nil; frames = 0; emptyRef = nil }
    }

    func captureOutput(_: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        latest = px
        frames += 1
        guard state == .armed || state == .challenged else { return }
        // Empty seat for 3 s+: compare against a fixed picture of the empty seat and skip Vision
        // while nothing has changed, with one real look a second regardless. Anyone walking in
        // changes the picture at once and gets the full rate. (Fixed reference, not the previous
        // frame, so a slow approach still trips it.)
        let idleSeat = emptySince.map { Date().timeIntervalSince($0) > 3 } ?? false
        let now = CACurrentMediaTime()
        var forced = false
        pendingRef = nil
        if idleSeat {
            let g = LumaGate.grid(px)
            if let g, let ref = emptyRef, LumaGate.diff(g, ref) < 5 {
                guard now - lastEmptyLook >= 1 else { return }
                forced = true
            }
            if emptyRef == nil { emptyRef = g }
            pendingRef = g
        } else {
            emptyRef = nil
        }
        if forced { lastEmptyLook = now }
        // Landmarks on every frame (15 fps) with a face: blink liveness for the closest one, yaw + size for all.
        let ci = CIImage(cvPixelBuffer: px)
        let faces = FaceID.allLandmarks(ci).filter { $0.boundingBox.width > 0.03 }
        let primary = faces.first.flatMap { $0.boundingBox.width > 0.06 ? $0 : nil }
        tracker.saw(primary)
        if faces.isEmpty {
            if emptySince == nil { emptySince = Date() }
            if let e = emptySince, Date().timeIntervalSince(e) > 2 { sawEmpty = true }
            // A real look confirmed the seat is still empty: this picture is the new reference
            // (so a lighting change can't pin the full rate on).
            if idleSeat, let g = pendingRef { emptyRef = g }
            attention.feed([])
            return
        }
        emptySince = nil

        // Identity + attention ~5x/s (every 3rd frame at 15 fps). Tiny background faces aren't worth a faceprint.
        if frames % 3 == 0 {
            var seen: [Seen] = []
            for f in faces.prefix(3) {
                let w = Double(f.boundingBox.width), yaw = f.yaw?.doubleValue ?? 0
                var owner: Bool?
                if faceID.hasOwner, w >= Attention.nearWidth, let p = FaceID.printFace(ci, face: f) {
                    owner = faceID.match(p).owner
                    if f === primary { tracker.vote(owner: owner!) }
                }
                if owner != true, w >= Attention.nearWidth, otherFace == nil || Date().timeIntervalSince(otherFace!.at) > 0.3
                    || w > Double(otherFace!.box.width) {
                    otherFace = (f.boundingBox, Date())
                }
                seen.append(Seen(width: w, yaw: yaw, owner: owner))
            }
            attention.feed(seen)
        }

        // Liveness on the face that matters: full spoof scan (glare + device) every 3rd pass.
        if let p = primary, away || state == .challenged || tracker.who == .owner {
            let d = liveness.observe(LivenessFeatures.frame(p, in: ci, ctx: self.ci, heavy: frames % 3 == 0))
            if d.isDenied, Date().timeIntervalSince(lastSpoofLog) > 5 {
                lastSpoofLog = Date()
                FaceID.debug("liveness: denied by \(d) (photo or screen?)")
                if away { awayPeek() }
            }
        }
        if liveOwner { faceUnlock() }
        if away, Date().timeIntervalSince(lastAwayLog) > 2 {
            lastAwayLog = Date()
            FaceID.debug("away: who=\(tracker.who) blink=\(tracker.live.blinkedRecently) live=\(liveness.decision) faces=\(faces.count) w=\(String(format: "%.3f", primary.map { Double($0.boundingBox.width) } ?? 0))")
        }
        // Only someone looking at the screen from close up (or walking up to it) blurs it.
        // People moving around the room are ignored.
        if state == .armed, attention.peeking {
            if away { awayPeek() } else { trigger("Someone is looking at your screen") }
        }
    }

    /// Someone looks at the blurred screen while you're away: keep the blur, take their photo.
    private func awayPeek() {
        guard Date().timeIntervalSince(lastAwayPeek) > 30 else { return }
        lastAwayPeek = Date()
        DispatchQueue.main.async { [self] in
            currentEvent = GuardLog.shared.begin("Looked at your screen while you were away")
            snap(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.snap() }
        }
    }

    private func snap() {
        let event = currentEvent
        q.async { [self] in
            guard let px = latest else { return }
            let img = CIImage(cvPixelBuffer: px)
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
            let stamp = f.string(from: Date())
            let name = "intruder \(stamp).jpg"
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let data = ci.jpegRepresentation(of: img, colorSpace: srgb) else { return }
            try? data.write(to: Self.folder.appendingPathComponent(name))
            snapshots += 1
            guard let event else { return }
            GuardLog.shared.addPhoto(name, to: event)
            // Close-up of whoever it was, for the "who peeked" view.
            if !GuardLog.shared.hasFace(event), let o = otherFace, Date().timeIntervalSince(o.at) < 3 {
                let e = img.extent, b = o.box
                var r = CGRect(x: b.minX * e.width, y: b.minY * e.height, width: b.width * e.width, height: b.height * e.height)
                r = r.insetBy(dx: -r.width * 0.45, dy: -r.height * 0.45).intersection(e)
                if r.width > 30, let fd = ci.jpegRepresentation(of: img.cropped(to: r), colorSpace: srgb) {
                    let fname = "face \(stamp).jpg"
                    try? fd.write(to: Self.folder.appendingPathComponent(fname))
                    GuardLog.shared.setFace(fname, for: event)
                }
            }
        }
    }
}

/// Full-screen blur on every display, above everything but the system auth sheet.
/// Swallows clicks so nothing behind it can be used.
final class Shield {
    private var windows: [NSWindow] = []

    func show(reason: String, hint: String = "Owner? Use Touch ID", calm: Bool = false) {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let w = KeyCatcher(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2) // under the island, over apps + menu bar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.sharingType = .none
            let host = NSHostingView(rootView: ShieldFace(reason: reason, hint: hint, calm: calm))
            host.autoresizingMask = [.width, .height]
            host.setAccessibilityLabel(calm ? "Away" : "Guard")
            let base: NSView
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                // Reduce Transparency: opaque black instead of the blur.
                base = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
                base.wantsLayer = true
                base.layer?.backgroundColor = NSColor.black.cgColor
            } else {
                let blur = NSVisualEffectView(frame: CGRect(origin: .zero, size: screen.frame.size))
                blur.material = .fullScreenUI
                blur.blendingMode = .behindWindow
                blur.state = .active
                blur.appearance = NSAppearance(named: .darkAqua)
                base = blur
            }
            host.frame = base.bounds
            base.addSubview(host)
            w.contentView = base
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        // Take keyboard focus so keystrokes land on the blur, not the app underneath.
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        // Alarm and challenge are spoken by the island banner (once); away has no banner, so say it here.
        if calm { A11y.announce(reason + ". " + hint, high: true) }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

/// Borderless windows can't take keys by default; this one does, and swallows them.
private final class KeyCatcher: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {}
}

private struct ShieldFace: View {
    let reason: String
    let hint: String
    var calm = false
    @Environment(\.accessibilityReduceMotion) private var rm

    var body: some View {
        Group { if calm { away } else { alarm } }
            .environment(\.renderPaused, rm) // Reduce Motion: the pup holds still
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(calm ? "Away. \(hint)" : "\(reason). This Mac is guarded. You're on camera. \(hint)")
            .accessibilityAddTraits(.isModal)
    }

    /// Presence soft lock: quiet clock, the pup asleep, how to get back in.
    private var away: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 84, weight: .thin, design: .rounded)).monospacedDigit()
                }
                Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                PupStage(mood: .sleep, scale: 2.6).frame(width: 120, height: 80).padding(.top, 18)
                Label(hint, systemImage: "faceid").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 14).padding(.vertical, 7).background(.white.opacity(0.08), in: Capsule())
            }
            .foregroundStyle(.white)
        }
    }

    private var alarm: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 14) {
                BarkingDog(mood: .angry).scaleEffect(3).frame(width: 130, height: 100)
                Image(systemName: "lock.shield.fill").font(.system(size: 40)).foregroundStyle(.red)
                Text(reason).font(.system(size: 22, weight: .bold))
                Text("This Mac is guarded. You're on camera.").font(.system(size: 14)).foregroundStyle(.secondary)
                Text(hint).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.white.opacity(0.08), in: Capsule())
            }
            .foregroundStyle(.white)
        }
    }
}

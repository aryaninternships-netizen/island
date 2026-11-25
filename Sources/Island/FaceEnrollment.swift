import AVFoundation
import AppKit
import SwiftUI
import Vision

/// Guided face registration: five poses (straight, one side, the other side, up, down), first
/// without glasses, then with them. Head turn is measured from the landmarks (where the nose
/// sits between the eyes, and between eyes and mouth) because Vision's own yaw/pitch come in
/// coarse 45-degree steps. Each pose keeps 4 faceprints; nothing but the numbers is stored.
final class FaceEnrollment: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Pose: String, CaseIterable {
        case straight, sideA, sideB, up, down
        var prompt: String {
            switch self {
            case .straight: "Look straight at the camera"
            case .sideA: "Slowly turn your head to one side"
            case .sideB: "Now turn to the other side"
            case .up: "Tilt your chin up a little"
            case .down: "Tilt your chin down a little"
            }
        }
        var symbol: String {
            switch self {
            case .straight: "face.smiling"
            case .sideA: "arrow.left"
            case .sideB: "arrow.right"
            case .up: "arrow.up"
            case .down: "arrow.down"
            }
        }
    }

    enum Round: Int { case plain, glasses }

    @Published private(set) var round: Round = .plain
    @Published private(set) var pose: Pose = .straight
    @Published private(set) var poseProgress: Double = 0
    @Published private(set) var done = false
    @Published private(set) var message = ""
    @Published private(set) var faceOK = false
    let session = AVCaptureSession()

    private let faceID: FaceID
    private let q = DispatchQueue(label: "island.enroll")
    private var samples: [Round: [[Float]]] = [:]
    private var got = 0
    private var frames = 0
    private var center: (yaw: CGFloat, pitch: CGFloat)?
    private var sideSign: CGFloat = 0
    private var paused = false
    var onFinish: ((Bool, String) -> Void)?

    static let perPose = 4

    init(faceID: FaceID) {
        self.faceID = faceID
        super.init()
    }

    func start() {
        q.async { [self] in
            guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else {
                DispatchQueue.main.async { self.message = "No camera" }
                return
            }
            session.sessionPreset = .high
            let out = AVCaptureVideoDataOutput()
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: q)
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(out) { session.addOutput(out) }
            session.startRunning()
        }
    }

    func stop() { q.async { [self] in session.stopRunning() } }

    /// "I don't wear glasses": finish with round one only.
    func skipGlasses() { q.async { [self] in finish() } }

    /// Between rounds: wait for the user to put glasses on.
    func continueWithGlasses() { q.async { [self] in paused = false; center = nil } ; message = "" }

    // MARK: capture

    func captureOutput(_: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from _: AVCaptureConnection) {
        frames += 1
        guard !done, !paused, frames % 3 == 0, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        let ci = CIImage(cvPixelBuffer: px)
        guard let face = FaceID.landmarks(ci), face.boundingBox.width > 0.12, let g = Self.geometry(face, ci.extent.size) else {
            DispatchQueue.main.async { self.faceOK = false }
            return
        }
        DispatchQueue.main.async { self.faceOK = true }
        guard poseHeld(g) else { return }
        guard let p = FaceID.printFace(ci, face: face) else { return }
        samples[round, default: []].append(p)
        got += 1
        let progress = Double(got) / Double(Self.perPose)
        DispatchQueue.main.async { self.poseProgress = progress }
        if got >= Self.perPose { nextPose() }
    }

    /// Is the head where the current pose wants it? Relative to your own straight-on baseline.
    private func poseHeld(_ g: (yaw: CGFloat, pitch: CGFloat)) -> Bool {
        if pose == .straight {
            // Baseline = running average of the straight frames.
            center = center.map { (($0.yaw * 3 + g.yaw) / 4, ($0.pitch * 3 + g.pitch) / 4) } ?? g
            return abs(g.yaw - center!.yaw) < 0.08
        }
        guard let c = center else { return false }
        let dy = g.yaw - c.yaw, dp = g.pitch - c.pitch
        switch pose {
        case .sideA:
            guard abs(dy) > 0.14 else { return false }
            sideSign = dy > 0 ? 1 : -1
            return true
        case .sideB: return dy * sideSign < -0.14
        case .up: return dp < -0.07 && abs(dy) < 0.15
        case .down: return dp > 0.07 && abs(dy) < 0.15
        case .straight: return false
        }
    }

    private func nextPose() {
        got = 0
        let all = Pose.allCases
        if let i = all.firstIndex(of: pose), i + 1 < all.count {
            let n = all[i + 1]
            DispatchQueue.main.async { self.pose = n; self.poseProgress = 0 }
            pose = n
            return
        }
        if round == .plain {
            paused = true
            round = .glasses; pose = .straight
            DispatchQueue.main.async {
                self.round = .glasses; self.pose = .straight; self.poseProgress = 0
                self.message = "Round 1 done. Now switch: glasses off if you had them on, on if you didn't. Then press Continue."
            }
            NSSound(named: "Pop")?.play()
            return
        }
        finish()
    }

    /// Save every sample; calibrate the threshold from your spread within each round (glasses
    /// vs no glasses is matched by nearest sample, so it never loosens the threshold).
    private func finish() {
        let all = samples.values.flatMap { $0 }
        guard all.count >= Self.perPose * 3 else {
            DispatchQueue.main.async { self.done = true; self.onFinish?(false, "Not enough angles captured, try again") }
            return
        }
        var p95s: [Float] = []
        for (_, s) in samples where s.count >= 4 {
            var ds: [Float] = []
            for i in 0..<s.count { for j in (i + 1)..<s.count { ds.append(FaceID.distance(s[i], s[j])) } }
            ds.sort()
            p95s.append(ds[min(ds.count - 1, Int(Float(ds.count) * 0.95))])
        }
        let n = all.count, glasses = (samples[.glasses]?.count ?? 0) > 0
        faceID.replace(prints: all, spread: p95s.max() ?? 0.35)
        DispatchQueue.main.async {
            self.done = true
            let msg = "Face registered · \(n) angles" + (glasses ? " · with and without glasses" : "")
            self.message = msg
            self.onFinish?(true, msg)
        }
    }

    /// (yaw proxy, pitch proxy) from landmarks, image space.
    private static func geometry(_ f: VNFaceObservation, _ size: CGSize) -> (yaw: CGFloat, pitch: CGFloat)? {
        guard let lm = f.landmarks, let le = lm.leftEye, let re = lm.rightEye, let nose = lm.nose, let lips = lm.outerLips else { return nil }
        func c(_ r: VNFaceLandmarkRegion2D) -> CGPoint {
            let p = r.pointsInImage(imageSize: size)
            return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        let l = c(le), r = c(re), n = c(nose), m = c(lips)
        let eyeMid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
        let io = hypot(r.x - l.x, r.y - l.y)
        let em = eyeMid.y - m.y // image y is up: eyes above mouth
        guard io > 0, em > 0 else { return nil }
        return ((n.x - eyeMid.x) / io, (eyeMid.y - n.y) / em)
    }
}

// MARK: - Window

final class EnrollWindow: NSObject, NSWindowDelegate {
    static let shared = EnrollWindow()
    private var window: NSWindow?
    private var enroll: FaceEnrollment?

    func show(faceID: FaceID, finished: @escaping (Bool, String) -> Void) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let e = FaceEnrollment(faceID: faceID)
        e.onFinish = { [weak self] ok, msg in
            finished(ok, msg)
            if ok { NSSound(named: "Glass")?.play() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self?.window?.close() }
        }
        enroll = e
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 540), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Register Your Face"
        w.contentView = NSHostingView(rootView: EnrollView(e: e).preferredColorScheme(.dark))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        e.start()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        enroll?.stop()
        enroll = nil
        window = nil
    }
}

private struct EnrollView: View {
    @ObservedObject var e: FaceEnrollment
    @Environment(\.accessibilityDifferentiateWithoutColor) private var dwc

    var body: some View {
        VStack(spacing: 14) {
            Text(e.round == .plain ? "Round 1 of 2 · glasses on or off, your choice" : "Round 2 of 2 · the other way")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ZStack {
                CameraPreview(session: e.session)
                    .frame(width: 260, height: 260).clipShape(Circle())
                Circle().stroke(.white.opacity(0.12), lineWidth: 6).frame(width: 276, height: 276)
                Circle().trim(from: 0, to: overall)
                    // Differentiate Without Color: dashed while searching for a face, solid once it's good.
                    .stroke(e.faceOK ? Color.green : Color.orange,
                            style: .init(lineWidth: 6, lineCap: .round, dash: dwc && !e.faceOK ? [2, 10] : []))
                    .rotationEffect(.degrees(-90)).frame(width: 276, height: 276)
                    .animation(.easeOut(duration: 0.25), value: overall)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Face registration progress")
            .accessibilityValue("\(Int((overall * 100).rounded())) percent" + (e.faceOK ? ", face in view" : ", no face yet"))
            if e.message.isEmpty {
                Label(e.pose.prompt, systemImage: e.pose.symbol).font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(e.faceOK ? "Hold it there…" : "Move closer, face the camera")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Text(e.message).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                ForEach(FaceEnrollment.Pose.allCases, id: \.self) { p in
                    poseMark(p)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Poses")
            .accessibilityValue("\(doneCount) of \(FaceEnrollment.Pose.allCases.count) done")
            Spacer(minLength: 0)
            if !e.done {
                HStack {
                    if e.round == .glasses {
                        Button("Skip, I don't wear glasses") { e.skipGlasses() }.keyboardShortcut(.cancelAction)
                        Spacer()
                        if !e.message.isEmpty { Button("Continue") { e.continueWithGlasses() }.keyboardShortcut(.defaultAction) }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 400, height: 540)
        // VoiceOver: each prompt is spoken, and a completed pose ticks with a sound.
        .onChange(of: e.pose) { old, new in
            if new != .straight || old != .straight { A11y.cue("Tink") }
            if e.message.isEmpty { A11y.announce(new.prompt) }
        }
        .onChange(of: e.message) { _, msg in A11y.announce(msg.isEmpty ? e.pose.prompt : msg, high: !msg.isEmpty) }
        .onAppear { A11y.announce(e.pose.prompt) }
    }

    private var doneCount: Int { FaceEnrollment.Pose.allCases.firstIndex(of: e.pose) ?? 0 }

    /// Done, current, still to come. Differentiate Without Color: done is filled, the current one
    /// hollow, the rest a thin dim line, so colour is never the only cue.
    @ViewBuilder private func poseMark(_ p: FaceEnrollment.Pose) -> some View {
        let all = FaceEnrollment.Pose.allCases
        let i = all.firstIndex(of: p)!, cur = all.firstIndex(of: e.pose)!
        if dwc && i == cur {
            Capsule().stroke(.white, lineWidth: 1).frame(width: 28, height: 4)
        } else if dwc && i > cur {
            Capsule().fill(color(p)).frame(width: 28, height: 2)
        } else {
            Capsule().fill(color(p)).frame(width: 28, height: 4)
        }
    }

    private var overall: Double {
        let i = Double(FaceEnrollment.Pose.allCases.firstIndex(of: e.pose) ?? 0)
        return min(1, (i + e.poseProgress) / Double(FaceEnrollment.Pose.allCases.count))
    }

    private func color(_ p: FaceEnrollment.Pose) -> Color {
        let all = FaceEnrollment.Pose.allCases
        let i = all.firstIndex(of: p)!, cur = all.firstIndex(of: e.pose)!
        return i < cur ? .green : i == cur ? .white : .white.opacity(0.2)
    }
}

/// Mirrored live camera preview.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        l.connection?.automaticallyAdjustsVideoMirroring = false
        l.connection?.isVideoMirrored = true
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = l
        return v
    }
    func updateNSView(_: NSView, context: Context) {}
}

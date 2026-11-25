import AppKit
import AVFoundation
import Vision

/// Every few minutes: open the camera for ~2 s, look for a face with Vision, close it.
/// Nothing is saved or sent anywhere; frames live only in memory during the check.
/// Recent keyboard/mouse input also counts as "present" (covers a dark room).
final class PresenceMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onResult: ((Bool) -> Void)?
    private let q = DispatchQueue(label: "island.presence")
    private var session: AVCaptureSession?
    private var frames = 0
    private var found = false
    private var busy = false

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func check() {
        let typing = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                             eventType: CGEventType(rawValue: ~0)!) < 90
        guard Self.authorized else { onResult?(typing); return }
        q.async { [weak self] in self?.capture(typing: typing) }
    }

    private func capture(typing: Bool) {
        guard !busy, let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.onResult?(typing) }
            return
        }
        busy = true; frames = 0; found = false
        let s = AVCaptureSession()
        s.sessionPreset = .low
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: q)
        if s.canAddInput(input) { s.addInput(input) }
        if s.canAddOutput(out) { s.addOutput(out) }
        session = s
        s.startRunning()
        q.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.session?.stopRunning()
            self.session = nil
            self.busy = false
            let present = self.found || typing
            DispatchQueue.main.async { self.onResult?(present) }
        }
    }

    func captureOutput(_: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from _: AVCaptureConnection) {
        frames += 1
        // skip the first frames while auto-exposure settles, then sample every 4th
        guard !found, frames > 8, frames % 4 == 0, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
        if let r = req.results, !r.isEmpty { found = true }
    }
}

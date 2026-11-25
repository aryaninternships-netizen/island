import AVFoundation

/// One place that sets a capture session up so the frame-rate cap actually sticks: preset and
/// outputs first (a preset change resets the device's frame durations), then the cap, held under
/// lockForConfiguration across startRunning.
enum CameraConfig {
    /// Configure and start. Returns a one-line description for the debug log.
    @discardableResult
    static func start(session s: AVCaptureSession, device dev: AVCaptureDevice, input: AVCaptureDeviceInput,
                      output out: AVCaptureVideoDataOutput, fps: Int32, preset: AVCaptureSession.Preset = .medium, width: Int? = nil) -> String {
        s.beginConfiguration()
        // Input first: canSetSessionPreset is judged against the attached device.
        if s.canAddInput(input) { s.addInput(input) }
        if s.canSetSessionPreset(preset) { s.sessionPreset = preset }
        // 420v: luma is plane 0, which the motion gate samples directly.
        var vs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        // Some cameras ignore the preset and send full-size frames: have the output scale them.
        if let w = width {
            let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
            let h = dims.width > 0 ? w * Int(dims.height) / Int(dims.width) : w * 9 / 16
            vs[kCVPixelBufferWidthKey as String] = w
            vs[kCVPixelBufferHeightKey as String] = h & ~1
        }
        out.videoSettings = vs
        out.alwaysDiscardsLateVideoFrames = true
        if s.canAddOutput(out) { s.addOutput(out) }
        s.commitConfiguration()

        let locked = (try? dev.lockForConfiguration()) != nil
        let chosen = cap(dev, fps: fps)
        s.startRunning()
        if locked { dev.unlockForConfiguration() }
        // Fallback for cameras that ignore the device-level cap.
        if let c = out.connection(with: .video), c.isVideoMinFrameDurationSupported {
            c.videoMinFrameDuration = CMTime(value: 1, timescale: fps)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        let ranges = dev.activeFormat.videoSupportedFrameRateRanges.map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) }
        return "\(dims.width)x\(dims.height) ranges=\(ranges.joined(separator: ",")) cap=\(chosen.map { String(format: "%.1f", $0) } ?? "none")"
    }

    /// Re-apply after a stop/start (startRunning can renegotiate the format).
    static func reapplyCap(_ dev: AVCaptureDevice, fps: Int32) {
        guard (try? dev.lockForConfiguration()) != nil else { return }
        _ = cap(dev, fps: fps)
        dev.unlockForConfiguration()
    }

    /// Device must be locked. Picks the slowest supported rate at or above `fps`... or the slowest
    /// the format allows. Returns the chosen fps.
    private static func cap(_ dev: AVCaptureDevice, fps: Int32) -> Double? {
        let want = CMTime(value: 1, timescale: fps)
        let ranges = dev.activeFormat.videoSupportedFrameRateRanges
        guard let slow = ranges.max(by: { $0.maxFrameDuration < $1.maxFrameDuration }) else { return nil }
        // Longest frame duration the format allows, but no longer than 1/fps.
        let d = CMTimeMinimum(slow.maxFrameDuration, want)
        guard ranges.contains(where: { $0.minFrameDuration <= d && d <= $0.maxFrameDuration }) else { return nil }
        dev.activeVideoMinFrameDuration = d
        dev.activeVideoMaxFrameDuration = d
        return 1 / d.seconds
    }
}

/// Cheap "did anything move" check: a coarse luma grid from plane 0 of a 420v buffer.
enum LumaGate {
    static func grid(_ px: CVPixelBuffer, w: Int = 32, h: Int = 24) -> [UInt8]? {
        guard CVPixelBufferGetPlaneCount(px) >= 1, CVPixelBufferLockBaseAddress(px, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(px, 0) else { return nil }
        let pw = CVPixelBufferGetWidthOfPlane(px, 0), ph = CVPixelBufferGetHeightOfPlane(px, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = p + (y * ph / h + ph / (2 * h)) * stride
            for x in 0..<w { out[y * w + x] = row[x * pw / w + pw / (2 * w)] }
        }
        return out
    }

    /// Mean absolute difference, 0...255.
    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var s = 0
        for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }
}

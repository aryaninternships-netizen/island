import AVFoundation
import CoreImage
import Foundation
import Vision

/// On-device owner recognition. Register once: the camera watches for a few seconds
/// while you slowly turn your head, and stores Vision feature prints of your face
/// (number vectors, never a photo) in Application Support. Guard then compares faces
/// it sees to these, votes across frames, and wants a blink before it trusts a match.
/// Everything stays on this Mac.
final class FaceID {
    private struct Store: Codable { var v: Int; var prints: [[Float]]; var threshold: Float }
    /// Bump when the print pipeline changes; old profiles are ignored and must be re-registered.
    static let version = 3

    private(set) var prints: [[Float]] = []
    private(set) var threshold: Float = 0.5
    private let q = DispatchQueue(label: "island.faceid")

    static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Island", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("face.json")
    }()

    var hasOwner: Bool { !prints.isEmpty }

    init() {
        if let d = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(Store.self, from: d),
           s.v == Self.version {
            prints = s.prints; threshold = s.threshold
        }
    }

    static func debug(_ s: String) {
        let line = "\(Date()) \(s)\n"
        let url = file.deletingLastPathComponent().appendingPathComponent("debug.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.data(using: .utf8)?.write(to: url) }
    }

    func forget() {
        prints = []
        try? FileManager.default.removeItem(at: Self.file)
    }

    private func save() {
        let s = Store(v: Self.version, prints: prints, threshold: threshold)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: Self.file) }
    }

    /// Closest distance to any enrolled sample, and whether that is within threshold.
    func match(_ p: [Float]) -> (owner: Bool, dist: Float) {
        let d = prints.map { Self.distance($0, p) }.min() ?? .greatestFiniteMagnitude
        return (d <= threshold, d)
    }

    func setThreshold(_ t: Float) { threshold = t; save() }

    /// New profile from guided enrollment. `spread` = your own p95 sample distance (worst round);
    /// same rule as before: match inside 1.3x your spread, never beyond 0.60 (strangers ~0.76+).
    func replace(prints new: [[Float]], spread: Float) {
        prints = new
        threshold = Self.strongModel ? min(max(spread * 1.3, 0.45), 0.60) : min(spread * 1.2, 0.70)
        save()
        Self.debug(String(format: "enrolled n=%d spread p95=%.3f thr=%.3f", new.count, spread, threshold))
    }

    // MARK: registration

    private var reg: Registration?

    /// Collects face prints for a few seconds. `progress` 0...1, `done` with success.
    func register(progress: @escaping (Double) -> Void, done: @escaping (Bool, String) -> Void) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            done(false, "Allow camera access first"); return
        }
        guard reg == nil else { done(false, "Already busy with the camera…"); return }
        let r = Registration(q: q, target: 10, seconds: 9) { [weak self] samples, diag in
            self?.reg = nil
            guard let self else { return }
            guard samples.count >= 6 else { done(false, diag); return }
            // Calibrate from your own spread: a match must sit inside how much *you* vary.
            var ds: [Float] = []
            for i in 0..<samples.count { for j in (i + 1)..<samples.count { ds.append(Self.distance(samples[i], samples[j])) } }
            ds.sort()
            let p95 = ds[min(ds.count - 1, Int(Float(ds.count) * 0.95))]
            self.prints = samples
            // Faceprint: strangers start ~0.76, so never accept beyond 0.60 whatever your spread.
            self.threshold = Self.strongModel ? min(max(p95 * 1.3, 0.45), 0.60) : min(p95 * 1.2, 0.70)
            self.save()
            Self.debug(String(format: "registered n=%d intra p95=%.3f max=%.3f thr=%.3f", samples.count, p95, ds.last ?? 0, self.threshold))
            done(true, "Face registered · \(samples.count) angles")
        } progress: { p in progress(p) }
        r.collect = { px in
            guard let face = Self.detectFace(CIImage(cvPixelBuffer: px)), face.boundingBox.width > 0.12 else { return nil }
            return Self.printFace(CIImage(cvPixelBuffer: px), face: face)
        }
        reg = r
        r.start()
    }

    /// ~4 s live check: distances to your profile and whether a blink was seen.
    func selfTest(done: @escaping (String) -> Void) {
        guard hasOwner, AVCaptureDevice.authorizationStatus(for: .video) == .authorized, reg == nil else {
            done("Register your face first"); return
        }
        var dists: [Float] = []
        var geo: [(Double, Double)] = [] // (width, yaw) of the closest face
        var blinks = 0
        var seen = Date.distantPast
        let live = Liveness()
        live.trace = []
        let r = Registration(q: q, target: 999, seconds: 7) { [weak self] _, _ in
            self?.reg = nil
            guard let self else { return }
            let verdict: String
            if dists.isEmpty { verdict = "No face seen" }
            else {
                let lo = dists.min()!, avg = dists.reduce(0, +) / Float(dists.count)
                let votes = dists.filter { $0 <= self.threshold }.count
                verdict = String(format: "best %.3f · avg %.3f · thr %.3f · %d/%d frames · blinks %d",
                                 lo, avg, self.threshold, votes, dists.count, blinks)
            }
            Self.debug("selfTest \(verdict)")
            if !geo.isEmpty {
                let w = geo.map(\.0).sorted(), y = geo.map(\.1)
                Self.debug(String(format: "geometry width min %.3f med %.3f max %.3f · yaw min %.2f max %.2f (close>=%.2f facing<=%.2f)",
                                  w.first!, w[w.count / 2], w.last!, y.min()!, y.max()!, Attention.closeWidth, Attention.facingYaw))
            }
            let tr = live.trace ?? []
            Self.debug("eye ratio min=\(String(format: "%.2f", tr.min() ?? 0)) n=\(tr.count) series=" + tr.map { String(format: "%.2f", $0) }.joined(separator: " "))
            done(verdict)
        } progress: { _ in }
        r.every = 2
        var n = 0
        r.collect = { [weak self] px in
            let ci = CIImage(cvPixelBuffer: px)
            guard let self, let face = Self.landmarks(ci) else { return nil }
            live.feed(face)
            geo.append((Double(face.boundingBox.width), face.yaw?.doubleValue ?? 0))
            if live.lastBlink > seen { seen = live.lastBlink; blinks += 1 }
            n += 1
            if n % 3 == 0, let p = Self.printFace(ci, face: face) { dists.append(self.match(p).dist) }
            return nil
        }
        reg = r
        r.start()
    }

    // MARK: pipeline

    static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    /// Largest face (rectangle + roll/yaw), or nil.
    static func detectFace(_ ci: CIImage) -> VNFaceObservation? {
        let det = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: ci, options: [:]).perform([det])
        return det.results?.max { $0.boundingBox.width < $1.boundingBox.width }
    }

    /// Every face in the frame with landmarks + yaw, largest first.
    static func allLandmarks(_ ci: CIImage) -> [VNFaceObservation] {
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(ciImage: ci, options: [:]).perform([req])
        return (req.results ?? []).sorted { $0.boundingBox.width > $1.boundingBox.width }
    }

    /// Largest face with eye/mouth landmarks (for liveness), or nil.
    static func landmarks(_ ci: CIImage) -> VNFaceObservation? {
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(ciImage: ci, options: [:]).perform([req])
        return req.results?.max { $0.boundingBox.width < $1.boundingBox.width }
    }

    /// Apple's on-device face-identity model (Vision's VNCreateFaceprintRequest, the one Photos
    /// uses for People). Private class, looked up at runtime; 128-dim unit vectors where the
    /// same person across years sits ~0.45 apart and different people 0.76+.
    private static let faceprintClass = NSClassFromString("VNCreateFaceprintRequest") as? VNImageBasedRequest.Type
    static var strongModel: Bool { faceprintClass != nil }

    /// Identity vector for a detected face: Apple faceprint when available, else generic print.
    static func printFace(_ ci: CIImage, face: VNFaceObservation) -> [Float]? {
        guard let cls = faceprintClass else { return genericPrint(ci, face: face) }
        let req = cls.init()
        if let acc = req as? VNFaceObservationAccepting { acc.inputFaceObservations = [face] }
        else { req.setValue([face], forKey: "inputFaceObservations") }
        do { try VNImageRequestHandler(ciImage: ci, options: [:]).perform([req]) } catch { return nil }
        guard let obs = req.results?.first as? NSObject, obs.responds(to: Selector(("faceprint"))),
              let fp = obs.value(forKey: "faceprint") as? NSObject, fp.responds(to: Selector(("descriptorData"))),
              let data = fp.value(forKey: "descriptorData") as? Data, data.count >= 64 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Fallback: tight face-only crop, eyes levelled, grayscale, generic image print. Weak
    /// identity signal (strangers land close), only used if the faceprint model is missing.
    static func genericPrint(_ ci: CIImage, face: VNFaceObservation) -> [Float]? {
        let e = ci.extent, b = face.boundingBox
        var rect = CGRect(x: e.minX + b.minX * e.width, y: e.minY + b.minY * e.height,
                          width: b.width * e.width, height: b.height * e.height)
        rect = rect.insetBy(dx: -rect.width * 0.06, dy: -rect.height * 0.06).intersection(e)
        guard rect.width > 40 else { return nil }
        var img = ci
        if let roll = face.roll?.doubleValue, abs(roll) > 0.02 {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            img = img.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(-roll)))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
        }
        img = img.cropped(to: rect)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
        guard let cg = ctx.createCGImage(img, from: rect) else { return nil }
        let fp = VNGenerateImageFeaturePrintRequest()
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([fp]) } catch { return nil }
        guard let obs = fp.results?.first else { return nil }
        let n = obs.elementCount
        var out = [Float](repeating: 0, count: n)
        switch obs.elementType {
        case .float:
            obs.data.withUnsafeBytes { raw in let p = raw.bindMemory(to: Float.self); for i in 0..<n { out[i] = p[i] } }
        case .double:
            obs.data.withUnsafeBytes { raw in let p = raw.bindMemory(to: Double.self); for i in 0..<n { out[i] = Float(p[i]) } }
        default: return nil
        }
        return out
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .greatestFiniteMagnitude }
        var s: Float = 0
        for i in 0..<a.count { let d = a[i] - b[i]; s += d * d }
        return s.squareRoot()
    }
}

// MARK: - Liveness

/// Blink detector from eye landmarks. A printed photo never blinks; people blink every
/// 2-10 s. Vision's eye contour never fully closes, so a blink shows as a short V-dip in
/// eye openness (height/width): >=18% under the recent peak, back up within ~130 ms.
/// Tuned on a real webcam trace (2 blinks found) and simulated still/shaky photos (0 false).
final class Liveness {
    private let lock = NSLock()
    private var hist: [CGFloat] = []
    private var sinceBlink = 99
    private var _lastBlink = Date.distantPast

    var lastBlink: Date { lock.lock(); defer { lock.unlock() }; return _lastBlink }
    var blinkedRecently: Bool { Date().timeIntervalSince(lastBlink) < 8 }
    /// Diagnostics: openness relative to recent peak, per frame (selfTest only).
    var trace: [CGFloat]?

    func reset() { lock.lock(); hist = []; sinceBlink = 99; _lastBlink = .distantPast; lock.unlock() }

    func feed(_ face: VNFaceObservation) {
        guard let l = face.landmarks?.leftEye, let r = face.landmarks?.rightEye else { return }
        let o = (Self.openness(l) + Self.openness(r)) / 2
        guard o > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        hist.append(o); if hist.count > 12 { hist.removeFirst() }
        sinceBlink += 1
        guard hist.count >= 5 else { return }
        let n = hist.count
        let dip = hist[n - 2], after = hist[n - 1], before = hist[(n - 5)..<(n - 2)].max()!
        trace?.append(dip / before)
        if dip < before * 0.82, after > before * 0.86, sinceBlink > 6 {
            sinceBlink = 0
            _lastBlink = Date()
        }
    }

    private static func openness(_ r: VNFaceLandmarkRegion2D) -> CGFloat {
        let p = r.normalizedPoints
        guard p.count >= 4 else { return 0 }
        let xs = p.map(\.x), ys = p.map(\.y)
        let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
        return w > 0 ? h / w : 0
    }
}

// MARK: - Tracker

/// Per-session view of who is in front of the camera: identity votes over the last
/// 5 checks plus blink liveness. Owner = 3 of 5 votes; stranger = 3 of 5 against.
final class FaceTracker {
    enum Who { case none, unsure, owner, stranger }

    let live = Liveness()
    private let lock = NSLock()
    private var votes: [Bool] = []
    private var lastFaceAt = Date.distantPast

    private var lastOwnerAt = Date.distantPast

    func reset() { lock.lock(); votes = []; lastFaceAt = .distantPast; lastOwnerAt = .distantPast; lock.unlock(); live.reset() }

    /// You were recognised (3 of 5 votes) within the last `seconds`.
    func ownerSeen(within seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastOwnerAt) < seconds
    }

    func saw(_ face: VNFaceObservation?) {
        guard let face else { return }
        lock.lock(); lastFaceAt = Date(); lock.unlock()
        live.feed(face)
    }

    func vote(owner: Bool) {
        lock.lock()
        votes.append(owner); if votes.count > 5 { votes.removeFirst() }
        if votes.count >= 3, votes.filter({ $0 }).count >= 3 { lastOwnerAt = Date() }
        lock.unlock()
    }

    /// Owner votes among the last checks (0...5), for progress displays.
    var ownerVotes: Int { lock.lock(); defer { lock.unlock() }; return votes.filter { $0 }.count }

    var faceVisible: Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastFaceAt) < 1.5 }

    var who: Who {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(lastFaceAt) < 1.5 else { return .none }
        guard votes.count >= 3 else { return .unsure }
        let yes = votes.filter { $0 }.count
        if yes >= 3 { return .owner }
        if votes.count - yes >= 3 { return .stranger }
        return .unsure
    }

    /// You, and alive: recognised by vote and blinked within the last 8 s.
    var liveOwner: Bool { who == .owner && live.blinkedRecently }
}

// MARK: - Capture helper

/// Short-lived camera session that hands frames to `collect` and gathers what it returns.
final class Registration: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let q: DispatchQueue
    private let target: Int
    private let seconds: Double
    private let onDone: ([[Float]], String) -> Void
    private let onProgress: (Double) -> Void
    private var session: AVCaptureSession?
    private var samples: [[Float]] = []
    private var frames = 0
    private var looked = 0
    /// Frame handler; return a print to keep it as a sample.
    var collect: ((CVPixelBuffer) -> [Float]?)?
    /// Examine every Nth frame.
    var every = 9

    init(q: DispatchQueue, target: Int, seconds: Double, done: @escaping ([[Float]], String) -> Void,
         progress: @escaping (Double) -> Void) {
        self.q = q; self.target = target; self.seconds = seconds; onDone = done; onProgress = progress
    }

    func start() {
        q.async { [self] in
            guard let dev = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: dev) else {
                DispatchQueue.main.async { self.onDone([], "No camera available.") }; return
            }
            let s = AVCaptureSession()
            s.sessionPreset = .high
            let out = AVCaptureVideoDataOutput()
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: q)
            if s.canAddInput(input) { s.addInput(input) }
            if s.canAddOutput(out) { s.addOutput(out) }
            s.startRunning()
            session = s
        }
        // Hard stop, scheduled off the busy camera queue so it always fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in q.async { self.finish() } }
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        session?.stopRunning(); session = nil
        let diag = looked == 0 ? "Camera gave no frames. Close other apps using it."
            : "Only caught \(samples.count) clear looks. Face the camera in good light, retry."
        FaceID.debug("capture done frames=\(frames) looked=\(looked) samples=\(samples.count)")
        let s = samples
        DispatchQueue.main.async { self.onDone(s, diag) }
    }

    func captureOutput(_: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard !finished, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        frames += 1
        guard frames > 8, frames % every == 0 else { return }
        looked += 1
        guard let p = collect?(px) else { return }
        samples.append(p)
        let pr = Double(samples.count) / Double(target)
        DispatchQueue.main.async { self.onProgress(min(pr, 1)) }
        if samples.count >= target { finish() }
    }
}

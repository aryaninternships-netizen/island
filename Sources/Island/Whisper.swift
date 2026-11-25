import AVFoundation
import Foundation

/// Accurate transcripts after a meeting: whisper.cpp (bundled `whisper-cli`, Metal) with
/// large-v3-turbo, run on the raw Room and Call tracks once the meeting ends. The live transcript
/// (Apple's recognizer, ~40% of the words) shows during the meeting; this replaces it afterwards
/// and the notes are rewritten. On device: only the one-time model download touches the network.
enum Whisper {
    static let modelName = "ggml-large-v3-turbo-q5_0.bin"
    static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
    /// About 574 MB; anything much smaller is a broken download.
    static let modelBytes: Int64 = 574_041_195
    static let pendingName = "whisper.pending"

    static var dir: URL { FaceID.file.deletingLastPathComponent().appendingPathComponent("whisper") }
    static var model: URL { dir.appendingPathComponent(modelName) }

    static var installed: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: model.path)[.size] as? Int64) ?? 0
        return size > 500_000_000
    }

    /// Settings › Meetings › Accurate transcript.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "whisper.on") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "whisper.on") }
    }

    static var cli: URL? {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("whisper-cli"),
              FileManager.default.isExecutableFile(atPath: u.path) else { return nil }
        return u
    }

    static var ready: Bool { enabled && installed && cli != nil }

    static func remove() { try? FileManager.default.removeItem(at: model) }

    // MARK: one track

    /// Transcribe one raw track (room.caf / call.caf). Blocks for minutes: call off main.
    /// nil when it failed (the live transcript then stays).
    static func transcribe(_ track: URL, who: String) -> [MeetingRecorder.Segment]? {
        guard let cli else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("island-whisper-\(UUID().uuidString)")
        let wav = tmp.appendingPathExtension("wav")
        defer {
            for ext in ["wav", "json"] { try? FileManager.default.removeItem(at: tmp.appendingPathExtension(ext)) }
        }
        guard toWav16k(track, wav) else { FaceID.debug("whisper: couldn't convert \(track.lastPathComponent)"); return nil }
        let p = Process()
        p.executableURL = cli
        let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        // A punctuated opening prompt keeps turbo writing sentences (without it: lowercase, no stops).
        p.arguments = ["-m", model.path, "-f", wav.path, "-l", "auto", "--prompt", "Hello, everyone. Thanks for joining. Let's begin.",
                       "-oj", "-of", tmp.path, "-np", "-t", "\(threads)"]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { FaceID.debug("whisper: launch failed \(error)"); return nil }
        // Drain stderr so the pipe never fills and blocks the child.
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp.appendingPathExtension("json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = j["transcription"] as? [[String: Any]] else {
            FaceID.debug("whisper: \(who) failed (\(p.terminationStatus)) " + String(decoding: errData.suffix(300), as: UTF8.self))
            return nil
        }
        var out: [MeetingRecorder.Segment] = []
        for r in rows {
            let text = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ms = ((r["offsets"] as? [String: Any])?["from"] as? NSNumber)?.doubleValue ?? 0
            guard keep(text, after: out.last?.text) else { continue }
            out.append(.init(at: ms / 1000, who: who, text: text))
        }
        return out
    }

    /// Whisper's known junk on silence and its runaway repeats.
    private static let junk: Set<String> = ["thank you.", "thanks for watching!", "thank you for watching.", "you", "bye.",
                                            ".", "so", "[blank_audio]", "(silence)", "[music]", "subtitles by the amara.org community"]

    static func keep(_ t: String, after last: String?) -> Bool {
        let l = t.lowercased()
        if l.isEmpty || junk.contains(l) || (l.hasPrefix("[") && l.hasSuffix("]")) || (l.hasPrefix("(") && l.hasSuffix(")")) { return false }
        return t != last
    }

    /// Any raw track → 16 kHz mono 16-bit WAV, streamed in 10 s blocks (raw tracks can be 1 GB+).
    static func toWav16k(_ src: URL, _ dst: URL) -> Bool {
        guard let inF = try? AVAudioFile(forReading: src),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inF.processingFormat, to: outFmt) else { return false }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let outF = try? AVAudioFile(forWriting: dst, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return false }
        let block = AVAudioFrameCount(inF.processingFormat.sampleRate * 10)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inF.processingFormat, frameCapacity: block),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(16_000 * 10) + 1024) else { return false }
        var ended = false
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { _, status in
                if ended { status.pointee = .endOfStream; return nil }
                inBuf.frameLength = 0
                if (try? inF.read(into: inBuf, frameCount: block)) == nil || inBuf.frameLength == 0 {
                    ended = true; status.pointee = .endOfStream; return nil
                }
                status.pointee = .haveData; return inBuf
            }
            if err != nil || st == .error { return false }
            if outBuf.frameLength > 0 { do { try outF.write(from: outBuf) } catch { return false } }
            if st == .endOfStream || (ended && outBuf.frameLength == 0) { break }
        }
        return true
    }

    // MARK: whole meeting

    /// Both tracks, mic bleed removed (Room lines that repeat what the Call track said at the same
    /// moment), written to the journal as "src":"whisper" with "rebuilt" lines. Returns the
    /// merged transcript, or nil if neither track worked. Blocks: call off main.
    static func meeting(_ dir: URL) -> [MeetingRecorder.Segment]? {
        var tracks: [String: [MeetingRecorder.Segment]] = [:]
        for (who, name) in [("Call", "call.caf"), ("Room", "room.caf")] {
            let u = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            let t0 = Date()
            if let s = transcribe(u, who: who) {
                tracks[who] = s
                FaceID.debug("whisper: \(who) \(s.count) segments in \(Int(Date().timeIntervalSince(t0))) s")
            }
        }
        guard !tracks.isEmpty else { return nil }
        let call = tracks["Call"] ?? []
        var room = tracks["Room"] ?? []
        if !call.isEmpty { room = dropBleed(room, call: call) }
        for (who, segs) in [("Call", call), ("Room", room)] where tracks[who] != nil {
            MeetingRecorder.appendRebuilt(dir, segs: segs, who: who, src: "whisper")
        }
        return (call + room).sorted { $0.at < $1.at }
    }

    /// Room segments the laptop mic picked up from the speakers: same words as a Call segment
    /// within 2 s. Word overlap (Dice) above 0.5 counts as the same line.
    static func dropBleed(_ room: [MeetingRecorder.Segment], call: [MeetingRecorder.Segment]) -> [MeetingRecorder.Segment] {
        func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        func dice(_ a: [String], _ b: [String]) -> Double {
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            var pool = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
            var common = 0
            for w in a where (pool[w] ?? 0) > 0 { common += 1; pool[w]! -= 1 }
            return 2 * Double(common) / Double(a.count + b.count)
        }
        func contained(_ a: [String], in b: [String]) -> Double {
            guard !a.isEmpty else { return 0 }
            var pool = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
            var hit = 0
            for w in a where (pool[w] ?? 0) > 0 { hit += 1; pool[w]! -= 1 }
            return Double(hit) / Double(a.count)
        }
        let cw = call.map { words($0.text) }
        return room.filter { r in
            let rw = words(r.text)
            for (i, c) in call.enumerated() {
                let end = i + 1 < call.count ? call[i + 1].at : c.at + 30
                guard c.at < r.at + 4, end > r.at - 2 else { continue }
                // Whisper's Call lines run ~30 s, so a short Room echo sits inside one: also drop a
                // Room line whose words are mostly contained in the Call line.
                if dice(rw, cw[i]) > 0.5 || contained(rw, in: cw[i]) > 0.7 { return false }
            }
            return true
        }
    }
}

/// The one-time model download (Settings › Meetings). Resumable: a cancelled or failed download
/// starts again from scratch; nothing half-written is ever used (it is moved in only when complete).
final class WhisperDownload: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = WhisperDownload()
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var installed = Whisper.installed
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func start() {
        guard task == nil, !Whisper.installed else { return }
        error = nil
        progress = 0
        task = session.downloadTask(with: Whisper.modelURL)
        task?.resume()
    }

    func cancel() { task?.cancel(); task = nil; progress = nil }

    func remove() { Whisper.remove(); installed = false }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Whisper.modelBytes
        progress = min(1, Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, size > 500_000_000 else {
            error = "Download failed (\(status)). Try again."; return
        }
        try? fm.createDirectory(at: Whisper.dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: Whisper.model)
        do { try fm.moveItem(at: location, to: Whisper.model) } catch { self.error = "Couldn't save the model"; return }
        installed = true
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError e: Error?) {
        task = nil
        progress = nil
        if let e, (e as NSError).code != NSURLErrorCancelled { error = "Download stopped: \(e.localizedDescription)" }
    }
}

extension Notification.Name {
    /// A meeting folder whose raw tracks wait for the Whisper pass (object: URL).
    static let whisperPending = Notification.Name("island.whisperPending")
}

import Accelerate
import AVFoundation
import AppKit
import CoreAudio
import Speech

/// Records a meeting into ~/Documents/Island Meetings/<date title>/:
///
/// - **Room mode** (Mac on a conference table): far-field chain built for voices across a room.
///   High-pass at 90 Hz kills table thumps and HVAC rumble, a gentle cut at 180 Hz removes boom,
///   +4 dB at 3 kHz brings consonants forward, then a leveller (compressor with +14 dB make-up)
///   lifts the quiet people at the far end while a soft gate keeps the hiss down between
///   sentences, and a peak limiter stops the person next to the Mac from clipping.
/// - **Near mode** (just you, or headphones): Apple voice processing (echo cancel, noise
///   suppression) with lighter levelling.
/// - **Call audio**: what the Mac plays (Zoom/Meet/Teams voices) via a Core Audio process tap,
///   recorded as its own track so the transcript can tell Room from Call.
///
/// Both tracks are transcribed live, strictly on device (no on-device model: audio only), then
/// mixed into one recording.m4a when you stop. transcript.jsonl gets one line per segment or mark
/// as it happens, so a crash loses nothing that was already heard.
final class MeetingRecorder: ObservableObject {
    enum Mode: String, CaseIterable { case room = "Room", near = "Near" }
    struct Segment: Identifiable {
        let id = UUID()
        let at: TimeInterval // seconds from start
        let who: String // "Room" / "Call"
        let text: String
    }
    /// A bookmark (⌃⌥M), optionally with a typed note.
    struct Mark: Identifiable, Equatable {
        let id = UUID()
        let at: TimeInterval
        var note: String?
    }

    @Published private(set) var recording = false
    @Published private(set) var start = Date()
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var marks: [Mark] = []
    @Published private(set) var partial: [String: String] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var folder: URL?
    @Published var mode: Mode = .room
    @Published var captureCall = true

    var onChange: (() -> Void)?
    /// Meters publish only while a meter is on screen (the notes window), at most 4 times a second.
    var metersVisible = false {
        didSet { if !metersVisible { micLevel = 0; callLevel = 0 } }
    }
    private var lastMicMeter: CFTimeInterval = 0
    private var lastCallMeter: CFTimeInterval = 0
    private var journal: FileHandle?

    private var engine: AVAudioEngine?
    private var tapNode: AVAudioNode?
    private var micFile: AVAudioFile?
    private var callFile: AVAudioFile?
    private var call: CallTap?
    private var micText: TrackText?
    private var callText: TrackText?
    private let fileQ = DispatchQueue(label: "island.meeting.files")
    /// Device changes (AirPods, USB mic, wake): the chain is rebuilt and keeps writing the same files.
    private var configObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var lastMicBuffer = CACurrentMediaTime()   // audio thread writes, main reads (a Double: fine)
    private var lastRebuild = 0.0
    private var micConv: AVAudioConverter?             // fileQ
    private var callConv: AVAudioConverter?            // fileQ
    private var outputListener: AudioObjectPropertyListenerBlock?

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Island Meetings")
    }

    /// macOS's Voice Isolation mic mode removes everyone but the nearest voice: bad for a room.
    var voiceIsolationOn: Bool { AVCaptureDevice.activeMicrophoneMode == .voiceIsolation }

    // MARK: start / stop

    func begin(title: String) {
        guard !recording else { return }
        problem = nil
        Self.permissions { [weak self] ok, why in
            guard let self else { return }
            guard ok else { self.problem = why; return }
            do { try self.startAll(title: title) } catch {
                self.problem = "Couldn't start: \(error.localizedDescription)"
                self.stopAudio()
            }
        }
    }

    private func startAll(title: String) throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = f.string(from: Date())
        let safe = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let dir = Self.root.appendingPathComponent(stamp.replacingOccurrences(of: "/", with: "-") + (safe.isEmpty ? "" : " " + safe))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folder = dir
        segments = []; partial = [:]; marks = []
        start = Date()
        openJournal(dir, title: title)

        let noSpeech: (String) -> Void = { [weak self] why in if self?.problem == nil { self?.problem = why } }
        micText = TrackText(who: "Room", t0: start, final: { [weak self] who, text, at in self?.add(who, text, at) },
                            partial: { [weak self] who, text in self?.partial[who] = text }, unavailable: noSpeech)
        try startMic(into: dir)
        if captureCall {
            callText = TrackText(who: "Call", t0: start, final: { [weak self] who, text, at in self?.add(who, text, at) },
                                 partial: { [weak self] who, text in self?.partial[who] = text }, unavailable: noSpeech)
            startCall(into: dir)
        }
        recording = true
        lastMicBuffer = CACurrentMediaTime()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkFlow(dir) }
        watchOutput(dir)
        onChange?()
    }

    // MARK: device changes

    /// No mic audio for 4 s while recording: the engine stopped (device gone, sleep). Rebuild, at
    /// most every 10 s, and say so. Recording continues into the same room.caf.
    private func checkFlow(_ dir: URL) {
        guard recording else { return }
        let now = CACurrentMediaTime()
        guard now - lastMicBuffer > 4, now - lastRebuild > 10 else { return }
        rebuildMic(dir, why: "no mic audio for 4 s")
    }

    private func rebuildMic(_ dir: URL, why: String) {
        guard recording else { return }
        lastRebuild = CACurrentMediaTime()
        FaceID.debug("meeting: rebuilding mic chain (\(why))")
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine?.stop()
        tapNode?.removeTap(onBus: 0)
        tapNode = nil; engine = nil
        do {
            try startMic(into: dir)
            lastMicBuffer = CACurrentMediaTime()
            problem = nil
        } catch {
            problem = "Microphone lost: \(error.localizedDescription). Still trying."
            FaceID.debug("meeting: mic rebuild failed \(error)")
        }
    }

    /// The default output changed (headphones in or out): the call tap's aggregate device is tied
    /// to the old one, so build a new tap. call.caf keeps growing.
    private func watchOutput(_ dir: URL) {
        guard captureCall else { return }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.recording else { return }
            FaceID.debug("meeting: output device changed, rebuilding call tap")
            self.call?.stop(); self.call = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.recording else { return }
                self.startCall(into: dir)
            }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
    }

    private func unwatchOutput() {
        guard let block = outputListener else { return }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
        outputListener = nil
    }

    /// A buffer in the file's own format (a new device may run at another sample rate). fileQ only.
    private static func fit(_ b: AVAudioPCMBuffer, to file: AVAudioFile, conv: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        let want = file.processingFormat
        if b.format == want { return b }
        if conv == nil || conv?.inputFormat != b.format { conv = AVAudioConverter(from: b.format, to: want) }
        guard let c = conv else { return nil }
        let cap = AVAudioFrameCount(Double(b.frameLength) * want.sampleRate / b.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: want, frameCapacity: cap) else { return nil }
        var fed = false, err: NSError?
        c.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return b
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }

    /// Stop, finish the transcripts, mix the tracks. `done` gets the folder once recording.m4a exists.
    func finish(done: @escaping (URL?) -> Void) {
        guard recording else { done(folder); return }
        recording = false
        stopAudio()
        onChange?()
        let dir = folder
        // Give the recognisers a moment to deliver their last words.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            for (who, text) in self.partial where !text.isEmpty { self.add(who, text, Date().timeIntervalSince(self.start)) }
            self.partial = [:]
            guard let dir else { done(nil); return }
            let live = self.segments
            let length = Date().timeIntervalSince(self.start)
            self.fileQ.async {
                try? self.journal?.close(); self.journal = nil
                // A live transcriber that died mid-meeting leaves a thin transcript: rebuild those
                // tracks from the raw audio before the mix deletes it.
                let whisper = Whisper.ready
                // Whisper will redo both tracks properly; otherwise rebuild thin ones with Apple's.
                let rebuilt = whisper ? nil : Self.rebuildThin(dir, live: live, length: length)
                if whisper { FileManager.default.createFile(atPath: dir.appendingPathComponent(Whisper.pendingName).path, contents: nil) }
                Self.mix(dir, keepRaw: whisper)
                DispatchQueue.main.async {
                    if let rebuilt { self.segments = rebuilt }
                    done(dir)
                }
            }
        }
    }

    private func stopAudio() {
        watchdog?.invalidate(); watchdog = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        unwatchOutput()
        engine?.stop()
        tapNode?.removeTap(onBus: 0)
        tapNode = nil
        engine = nil
        call?.stop(); call = nil
        // Keep the transcribers alive a few seconds: their final words arrive after endAudio.
        let finishing = [micText, callText].compactMap { $0 }
        finishing.forEach { $0.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { _ = finishing }
        micText = nil; callText = nil
        fileQ.sync { micFile = nil; callFile = nil; micConv = nil; callConv = nil }
        micLevel = 0; callLevel = 0
    }

    private func add(_ who: String, _ text: String, _ at: TimeInterval) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Segments arrive almost in order: insert from the back instead of sorting every time.
        let seg = Segment(at: at, who: who, text: t)
        var i = segments.endIndex
        while i > segments.startIndex, segments[i - 1].at > at { i -= 1 }
        segments.insert(seg, at: i)
        if partial[who] == text { partial[who] = "" }
        log(["t": "seg", "at": at, "who": who, "text": t])
    }

    /// Bookmark this moment. Returns false when not recording.
    @discardableResult func mark(_ note: String? = nil) -> Bool {
        guard recording else { return false }
        let m = Mark(at: Date().timeIntervalSince(start), note: note?.isEmpty == true ? nil : note)
        marks.append(m)
        log(["t": "mark", "at": m.at, "note": m.note ?? ""])
        return true
    }

    // MARK: journal (crash safety)

    static let journalName = "transcript.jsonl"

    private func openJournal(_ dir: URL, title: String) {
        let url = dir.appendingPathComponent(Self.journalName)
        let head: [String: Any] = ["t": "start", "title": title, "start": start.timeIntervalSince1970]
        fileQ.async {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.journal = try? FileHandle(forWritingTo: url)
            Self.write(head, to: self.journal)
        }
    }

    private func log(_ line: [String: Any]) {
        fileQ.async { Self.write(line, to: self.journal) }
    }

    private static func write(_ line: [String: Any], to h: FileHandle?) {
        guard let h, var d = try? JSONSerialization.data(withJSONObject: line) else { return }
        d.append(0x0A)
        try? h.write(contentsOf: d)
    }

    /// What a journal held: for "Recover last meeting" after a crash.
    struct Journal {
        var title = ""
        var start = Date()
        var segments: [Segment] = []
        var marks: [Mark] = []
    }

    static func readJournal(_ dir: URL) -> Journal? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(journalName), encoding: .utf8) else { return nil }
        var j = Journal()
        var rebuilt: [String: String] = [:]          // who -> src of its latest rebuild
        var fromFile: [(String, Segment)] = []       // (src, segment)
        for line in text.split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let at = o["at"] as? Double ?? 0
            switch o["t"] as? String {
            case "start":
                j.title = o["title"] as? String ?? ""
                j.start = Date(timeIntervalSince1970: o["start"] as? Double ?? 0)
            case "seg":
                let seg = Segment(at: at, who: o["who"] as? String ?? "Room", text: o["text"] as? String ?? "")
                if let src = o["src"] as? String { fromFile.append((src, seg)) } else { j.segments.append(seg) }
            case "rebuilt": rebuilt[o["who"] as? String ?? ""] = o["src"] as? String ?? "file"
            case "mark": j.marks.append(Mark(at: at, note: (o["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            default: break
            }
        }
        j.segments = j.segments.filter { rebuilt[$0.who] == nil } + fromFile.filter { rebuilt[$0.1.who] == $0.0 }.map(\.1)
        j.segments.sort { $0.at < $1.at }
        return j
    }

    /// Length of the longest raw track in seconds (0 if none): the real meeting length after a crash.
    static func audioLength(_ dir: URL) -> TimeInterval {
        ["room.caf", "call.caf"].compactMap { try? AVAudioFile(forReading: dir.appendingPathComponent($0)) }
            .map { Double($0.length) / $0.fileFormat.sampleRate }.max() ?? 0
    }

    /// Mix whatever raw tracks a crashed session left. Call off the main thread.
    static func mixLeftovers(_ dir: URL, keepRaw: Bool = false) { mix(dir, keepRaw: keepRaw) }

    // MARK: mic chain

    private func startMic(into dir: URL) throws {
        let e = AVAudioEngine()
        let input = e.inputNode
        if mode == .near {
            try input.setVoiceProcessingEnabled(true)
            // Voice processing ducks every other app by default: keep Zoom at full volume.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { throw NSError(domain: "Island", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone"]) }
        let mono = AVAudioFormat(standardFormatWithSampleRate: inFmt.sampleRate, channels: 1)!

        let down = AVAudioMixerNode() // folds a multi-mic array to mono
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let hp = eq.bands[0]; hp.filterType = .highPass; hp.frequency = 90; hp.bypass = false
        let boom = eq.bands[1]; boom.filterType = .lowShelf; boom.frequency = 180; boom.gain = mode == .room ? -3 : -1; boom.bypass = false
        let presence = eq.bands[2]; presence.filterType = .parametric; presence.frequency = 3000; presence.bandwidth = 1.2
        presence.gain = mode == .room ? 4 : 2; presence.bypass = false
        let dyn = AVAudioUnitEffect(audioComponentDescription: .init(componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        let lim = AVAudioUnitEffect(audioComponentDescription: .init(componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        [down, eq, dyn, lim].forEach { e.attach($0) }
        e.connect(input, to: down, format: inFmt)
        e.connect(down, to: eq, format: mono)
        e.connect(eq, to: dyn, format: mono)
        e.connect(dyn, to: lim, format: mono)
        e.connect(lim, to: e.mainMixerNode, format: mono)
        e.mainMixerNode.outputVolume = 0 // never play the mic back (no feedback)

        // Dynamics processor ids: 0 threshold, 1 headroom, 2 expansion ratio, 3 expansion threshold,
        // 4 attack, 5 release, 6 overall gain.
        let room = mode == .room
        let p: [(AudioUnitParameterID, Float)] = [(0, room ? -32 : -24), (1, room ? 4 : 6), (2, room ? 2.5 : 1.5),
                                                  (3, room ? -56 : -60), (4, 0.004), (5, 0.18), (6, room ? 14 : 6)]
        for (id, v) in p { AudioUnitSetParameter(dyn.audioUnit, id, kAudioUnitScope_Global, 0, v, 0) }
        AudioUnitSetParameter(lim.audioUnit, 2, kAudioUnitScope_Global, 0, 0, 0) // pre-gain 0 dB

        // First start creates room.caf; a rebuild after a device change keeps appending to it.
        let haveFile = fileQ.sync { micFile != nil }
        if !haveFile {
            let file = try AVAudioFile(forWriting: dir.appendingPathComponent("room.caf"), settings: mono.settings)
            fileQ.sync { micFile = file }
        }
        let text = micText
        lim.installTap(onBus: 0, bufferSize: 4096, format: mono) { [weak self] buf, _ in
            guard let self else { return }
            self.lastMicBuffer = CACurrentMediaTime()
            self.fileQ.async {
                guard let f = self.micFile, let b = Self.fit(buf, to: f, conv: &self.micConv) else { return }
                do { try f.write(from: b) } catch { self.writeFailed("room", error) }
            }
            text?.append(buf)
            guard self.metersVisible else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastMicMeter >= 0.25 else { return }
            self.lastMicMeter = now
            let lvl = Self.level(buf)
            DispatchQueue.main.async { self.micLevel = lvl }
        }
        e.prepare()
        try e.start()
        engine = e
        tapNode = lim
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.rebuildMic(dir, why: "audio device changed")
        }
    }

    /// Disk full or folder gone: say so once instead of recording nothing in silence. fileQ.
    private func writeFailed(_ track: String, _ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.problem == nil else { return }
            FaceID.debug("meeting: \(track) write failed \(error)")
            self.problem = "Can't save the \(track) audio: \(error.localizedDescription)"
        }
    }

    // MARK: call audio

    private func startCall(into dir: URL) {
        let t = CallTap()
        let text = callText
        t.onBuffer = { [weak self] buf in
            guard let self else { return }
            self.fileQ.async {
                if self.callFile == nil {
                    self.callFile = try? AVAudioFile(forWriting: dir.appendingPathComponent("call.caf"), settings: buf.format.settings)
                }
                guard let f = self.callFile, let b = Self.fit(buf, to: f, conv: &self.callConv) else { return }
                do { try f.write(from: b) } catch { self.writeFailed("call", error) }
            }
            text?.append(buf)
            guard self.metersVisible else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastCallMeter >= 0.25 else { return }
            self.lastCallMeter = now
            let lvl = Self.level(buf)
            DispatchQueue.main.async { self.callLevel = lvl }
        }
        if let err = t.start() { problem = "Call audio off: \(err)" } else { call = t }
    }

    /// 0...1 loudness for the meters (RMS in dB, -50...0).
    private static func level(_ b: AVAudioPCMBuffer) -> Float {
        guard let d = b.floatChannelData?[0], b.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(d, 1, &rms, vDSP_Length(b.frameLength))
        let db = 20 * log10(max(rms, 1e-5))
        return min(max((db + 50) / 50, 0), 1)
    }

    // MARK: mixdown

    /// room.caf + call.caf -> recording.m4a (AAC mono 48 kHz), then the raw tracks are removed.
    /// Streams 10 s blocks: a 99-minute meeting is ~1.1 GB per raw track, and loading both whole
    /// (the old way) died mid-write and left a broken m4a. Raw tracks go only once the output is
    /// full length.
    private static func mix(_ dir: URL, keepRaw: Bool = false) {
        let rate = 48_000.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let block: AVAudioFrameCount = 480_000
        let outURL = dir.appendingPathComponent("recording.m4a")

        /// One track, resampled to 48 kHz mono on the fly, handed out a block at a time.
        final class Track {
            let file: AVAudioFile
            let conv: AVAudioConverter?
            let inBuf: AVAudioPCMBuffer
            var done = false
            init?(_ u: URL, to fmt: AVAudioFormat, block: AVAudioFrameCount) {
                guard let f = try? AVAudioFile(forReading: u), f.length > 0 else { return nil }
                file = f
                conv = f.processingFormat == fmt ? nil : AVAudioConverter(from: f.processingFormat, to: fmt)
                let cap = AVAudioFrameCount(Double(block) * f.processingFormat.sampleRate / fmt.sampleRate) + 1024
                guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: cap) else { return nil }
                inBuf = b
            }
            var frames: Double { Double(file.length) * 48_000 / file.processingFormat.sampleRate }
            func read(into out: AVAudioPCMBuffer) {
                out.frameLength = 0
                guard !done else { return }
                if conv == nil {
                    do { try file.read(into: out, frameCount: out.frameCapacity) } catch { done = true }
                    if out.frameLength == 0 { done = true }
                    return
                }
                var err: NSError?
                conv!.convert(to: out, error: &err) { [self] _, status in
                    inBuf.frameLength = 0
                    if (try? file.read(into: inBuf, frameCount: inBuf.frameCapacity)) == nil || inBuf.frameLength == 0 {
                        status.pointee = .endOfStream; return nil
                    }
                    status.pointee = .haveData; return inBuf
                }
                if out.frameLength == 0 { done = true }
            }
        }

        let tracks = ["room.caf", "call.caf"].compactMap { Track(dir.appendingPathComponent($0), to: fmt, block: block) }
        guard !tracks.isEmpty else { return }
        let expected = tracks.map(\.frames).max() ?? 0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
        try? FileManager.default.removeItem(at: outURL) // a half-written file from an earlier try
        // Encode in a closure so the output file is released (AAC finalised and closed) before the
        // result is checked; -1 = a write failed.
        let written: Double = {
        guard let out = try? AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let mixBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: block),
              let tmp = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: block) else { return -1 }
        var written = 0.0
        while tracks.contains(where: { !$0.done }) {
            mixBuf.frameLength = 0
            let m = mixBuf.floatChannelData![0]
            for (i, t) in tracks.enumerated() {
                t.read(into: tmp)
                let n = Int(tmp.frameLength)
                guard n > 0 else { continue }
                let src = tmp.floatChannelData![0]
                let gain: Float = i == 0 ? 1 : 0.9
                if Int(mixBuf.frameLength) < n {
                    for k in Int(mixBuf.frameLength)..<n { m[k] = 0 }
                    mixBuf.frameLength = AVAudioFrameCount(n)
                }
                for k in 0..<n { m[k] += src[k] * gain }
            }
            let n = Int(mixBuf.frameLength)
            guard n > 0 else { break }
            for k in 0..<n { m[k] = max(-1, min(1, m[k])) }
            do { try out.write(from: mixBuf) } catch { return -1 } // keep the raw tracks
            written += Double(n)
        }
        return written
        }()
        guard written >= expected * 0.99 else { return }
        // Read the finished file back: only a complete, readable m4a lets the raw tracks go.
        guard let check = try? AVAudioFile(forReading: outURL),
              Double(check.length) * 48_000 / check.fileFormat.sampleRate >= expected * 0.98 else { return }
        guard !keepRaw else { return }   // the Whisper pass still needs them; it deletes them when done
        for name in ["room.caf", "call.caf"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    /// recording.m4a is complete (same check as the mix): the raw tracks may go.
    static func dropRaw(_ dir: URL) {
        let expected = ["room.caf", "call.caf"].compactMap { try? AVAudioFile(forReading: dir.appendingPathComponent($0)) }
            .map { Double($0.length) / $0.fileFormat.sampleRate }.max() ?? 0
        guard let m = try? AVAudioFile(forReading: dir.appendingPathComponent("recording.m4a")),
              Double(m.length) / m.fileFormat.sampleRate >= expected * 0.98 else {
            FaceID.debug("meeting: recording.m4a short or missing, keeping raw tracks in \(dir.lastPathComponent)"); return
        }
        for name in ["room.caf", "call.caf"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    // MARK: permissions

    private static func permissions(_ done: @escaping (Bool, String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { mic in
            guard mic else { DispatchQueue.main.async { done(false, "Allow the microphone for Island in System Settings › Privacy") }; return }
            SFSpeechRecognizer.requestAuthorization { st in
                DispatchQueue.main.async {
                    // Recording still works without speech; the transcript just stays empty.
                    done(true, st == .authorized ? nil : "Speech recognition is off, so no live transcript")
                }
            }
        }
    }
}

// MARK: - Self test

extension MeetingRecorder {
    /// Feed an audio file through the real per-track path (TrackText: analyzer or classic, with the
    /// watchdog), as if it were the mic, at `speed`x. `file` mode runs FileTranscriber instead.
    static func transcribeTest(_ url: URL, mode: String = "live", speed: Double = 1, done: @escaping (String) -> Void) {
        let auth = SFSpeechRecognizer.authorizationStatus()
        guard auth == .authorized else { done("speech permission: \(auth.rawValue) (3 = allowed)"); return }
        if mode == "file" {
            DispatchQueue.global(qos: .utility).async {
                let t = Date()
                let segs = FileTranscriber.run(url, who: "Test")
                let words = segs.reduce(0) { $0 + $1.text.split(separator: " ").count }
                let body = segs.map { "[\(Int($0.at))] \($0.text)" }.joined(separator: "\n")
                DispatchQueue.main.async { done("file: \(segs.count) segs, \(words) words, \(Int(Date().timeIntervalSince(t))) s\n" + body) }
            }
            return
        }
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil else { done("couldn't read \(url.lastPathComponent)"); return }
        var heard: [(Double, String)] = []
        let t0 = Date()
        let t = TrackText(who: "Test", t0: t0, final: { _, text, at in if !text.isEmpty { heard.append((at, text)) } },
                          partial: { _, _ in }, unavailable: { why in heard.append((0, "UNAVAILABLE: " + why)) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let chunk = AVAudioFrameCount(f.processingFormat.sampleRate / 10)
            var pos: AVAudioFrameCount = 0
            func feed() {
                guard pos < buf.frameLength else {
                    t.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        _ = t   // keep it alive: last finals arrive after stop
                        let words = heard.reduce(0) { $0 + $1.1.split(separator: " ").count }
                        done("live: \(heard.count) segs, \(words) words over \(Int(Double(buf.frameLength) / f.processingFormat.sampleRate)) s audio\n"
                             + heard.map { "[\(Int($0.0))] \($0.1)" }.joined(separator: "\n"))
                    }
                    return
                }
                let n = min(chunk, buf.frameLength - pos)
                if let c = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: n) {
                    c.frameLength = n
                    for ch in 0..<Int(buf.format.channelCount) {
                        c.floatChannelData![ch].update(from: buf.floatChannelData![ch] + Int(pos), count: Int(n))
                    }
                    t.append(c)
                }
                pos += n
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 / speed, execute: feed)
            }
            feed()
        }
    }
}

// MARK: - Live transcript

/// On-device speech for one track (the classic recognizer). Tasks rotate every 50 s so an hour-long
/// meeting never hits a per-task limit; each finished task becomes one transcript segment.
/// A task that dies on its own (error before we ended it) is replaced with backoff, and after
/// three failures in a row the recognizer itself is rebuilt. Everything goes to the debug log.
final class LiveTranscriber: TrackTranscriber {
    private let who: String
    private let t0: Date
    private var recognizer: SFSpeechRecognizer?
    private let onFinal: (String, String, TimeInterval) -> Void
    private let onPartial: (String, String) -> Void
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [SFSpeechRecognitionTask] = []
    private var rotate: Timer?
    private let lock = NSLock()
    private var stopped = false
    /// Bumped whenever the current request is replaced: an older task's error is then expected.
    private var gen = 0
    private var failures = 0
    /// False when there is no on-device recognizer (or no permission): nothing is transcribed.
    private(set) var available = false

    init(who: String, t0: Date, final: @escaping (String, String, TimeInterval) -> Void, partial: @escaping (String, String) -> Void) {
        self.who = who; self.t0 = t0; onFinal = final; onPartial = partial
        recognizer = Self.pick()
        available = SFSpeechRecognizer.authorizationStatus() == .authorized && recognizer != nil
        guard available else { return }
        DispatchQueue.main.async { [weak self] in
            self?.next()
            self?.rotate = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in self?.next() }
        }
    }

    /// Privacy gate: on-device only. No local model means no transcript, never Apple's servers.
    private static func pick() -> SFSpeechRecognizer? {
        [Locale.current, Locale(identifier: "en-IN"), Locale(identifier: "en-US")]
            .compactMap { SFSpeechRecognizer(locale: $0) }
            .first { $0.supportsOnDeviceRecognition }
    }

    var engineInfo: String {
        guard let r = recognizer else { return "no on-device recognizer" }
        return "\(r.locale.identifier) on-device"
    }

    func append(_ b: AVAudioPCMBuffer) {
        lock.lock(); request?.append(b); lock.unlock()
    }

    func stop() {
        stopped = true
        rotate?.invalidate()
        lock.lock(); request?.endAudio(); request = nil; gen += 1; lock.unlock()
    }

    /// Audio kept coming but no words did (TrackText's watchdog): start a fresh task now.
    func restart(_ why: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            FaceID.debug("tx \(self.who): restart (\(why))")
            self.next()
        }
    }

    /// Main thread. Starts a new request + task, then ends the old one (it still delivers its final).
    private func next() {
        guard !stopped, let recognizer else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        r.requiresOnDeviceRecognition = true
        var began = Date().timeIntervalSince(t0)
        var latest = "", sent = false
        let who = who
        let t0 = t0
        lock.lock()
        gen += 1
        let mine = gen
        let old = request
        request = r
        lock.unlock()
        if UserDefaults.standard.bool(forKey: "debug.tx") { FaceID.debug("tx \(who): task \(mine) start, recognizer available=\(recognizer.isAvailable)") }
        let task = recognizer.recognitionTask(with: r) { [weak self] res, err in
            if UserDefaults.standard.bool(forKey: "debug.tx") {
                FaceID.debug("tx \(who): task \(mine) cb res=\(res?.bestTranscription.formattedString.prefix(30) ?? "nil") final=\(res?.isFinal ?? false) err=\(err.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "nil")")
            }
            // The on-device recognizer often ends a rotated-out task with an EMPTY final result even
            // though its partials held the words. Never let an empty result wipe what was heard: that
            // dropped every 50 s of speech (the "transcript stops after 50 s" bug, 25 Nov 2026).
            if let res, !res.bestTranscription.formattedString.isEmpty {
                let now = res.bestTranscription.formattedString
                // After a pause the recognizer starts its text over: the old text was a finished
                // utterance. Commit it as its own segment, or only a task's last sentence survives.
                if Self.restarted(from: latest, to: now) {
                    let done = latest, at = began
                    DispatchQueue.main.async { self?.onFinal(who, done, at) }
                    began = Date().timeIntervalSince(t0)
                }
                latest = now
                DispatchQueue.main.async { self?.failures = 0; self?.onPartial(who, now) }
            }
            if (res?.isFinal ?? false) || err != nil, !sent {
                sent = true
                let text = latest
                DispatchQueue.main.async { self?.onFinal(who, text, began) }
            }
            if let err { DispatchQueue.main.async { self?.died(mine, err) } }
        }
        tasks.append(task)
        if tasks.count > 3 { tasks.removeFirst().cancel() }
        old?.endAudio()
    }

    /// True when `new` is a fresh utterance rather than a revision of `old`: clearly shorter and
    /// starting with different words.
    static func restarted(from old: String, to new: String) -> Bool {
        guard !old.isEmpty, new.count < old.count * 6 / 10 else { return false }
        func head(_ s: String) -> [Substring] {
            Array(s.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(2))
        }
        return head(old) != head(new)
    }

    /// A task ended with an error. Expected for one we already rotated out; otherwise the live
    /// request is dead and audio would pour into nothing (the "stops after 50 s" bug): replace it.
    private func died(_ which: Int, _ err: Error) {
        let e = err as NSError
        lock.lock(); let current = which == gen; lock.unlock()
        guard current, !stopped else { return }
        failures += 1
        FaceID.debug("tx \(who): task died \(e.domain) \(e.code) \(e.localizedDescription) at \(Int(Date().timeIntervalSince(t0))) s, failure \(failures)")
        if failures >= 3 {
            recognizer = Self.pick() ?? recognizer
            FaceID.debug("tx \(who): rebuilt recognizer")
        }
        let wait = min(Double(failures), 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.stopped else { return }
            self.lock.lock(); let still = which == self.gen; self.lock.unlock()
            if still { self.next() }
        }
    }
}

// MARK: - Call audio tap

/// Everything the Mac plays (minus Island), via a private process tap in a private aggregate
/// device. Unmuted: you keep hearing the call. Needs "System Audio Recording" permission.
final class CallTap {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let q = DispatchQueue(label: "island.calltap")
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel), ref: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, $0) }
        return st == noErr ? ref?.takeRetainedValue() as String? : nil
    }

    /// nil on success, else a short reason.
    func start() -> String? {
        var a = Self.addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid(), me = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(Self.system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &sz, &me)
        let desc = Self.describe(me: me)
        desc.name = "Island meeting"
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return "no permission for system audio" }

        var out = AudioDeviceID(kAudioObjectUnknown)
        sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        a = Self.addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(Self.system, &a, 0, nil, &sz, &out)
        guard let outUID = Self.string(out, kAudioDevicePropertyDeviceUID) else { stop(); return "no output device" }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Island meeting",
            kAudioAggregateDeviceUIDKey: (Bundle.main.bundleIdentifier ?? "app.island.notch") + ".meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { stop(); return "aggregate failed" }

        var rate: Float64 = 0
        sz = UInt32(MemoryLayout<Float64>.size)
        a = Self.addr(kAudioDevicePropertyNominalSampleRate)
        AudioObjectGetPropertyData(aggID, &a, 0, nil, &sz, &rate)
        guard rate > 0, let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { stop(); return "no sample rate" }
        format = fmt
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) { [weak self] _, input, _, _, _ in
            self?.read(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        }
        guard st == noErr, AudioDeviceStart(aggID, procID) == noErr else { stop(); return "couldn't start" }
        return nil
    }

    /// A native meeting app is running: tap just it (no music, no notification pings). Otherwise
    /// (Meet in a browser) tap everything except Island and music players.
    private static func describe(me: AudioObjectID) -> CATapDescription {
        let apps = NSWorkspace.shared.runningApplications
        let meet = apps.filter { MeetingApps.native[$0.bundleIdentifier ?? ""] != nil }.flatMap { objects(for: $0.processIdentifier) }
        if !meet.isEmpty { return CATapDescription(stereoMixdownOfProcesses: meet) }
        let skip = apps.filter { MeetingApps.music.contains($0.bundleIdentifier ?? "") }.flatMap { objects(for: $0.processIdentifier) }
        return CATapDescription(stereoGlobalTapButExcludeProcesses: (me == kAudioObjectUnknown ? [] : [me]) + skip)
    }

    /// Core Audio process objects for a pid (none if it has never opened audio).
    private static func objects(for pid: pid_t) -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid, obj = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &p, &sz, &obj)
        return obj == kAudioObjectUnknown ? [] : [obj]
    }

    /// The tap is the last input stream; fold it to mono.
    private func read(_ ins: UnsafeMutableAudioBufferListPointer) {
        guard let fmt = format, let last = ins.last, let d = last.mData?.assumingMemoryBound(to: Float.self), last.mNumberChannels > 0 else { return }
        let ch = Int(last.mNumberChannels)
        let n = Int(last.mDataByteSize) / (4 * ch)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let o = buf.floatChannelData![0]
        for i in 0..<n {
            var s: Float = 0
            for c in 0..<ch { s += d[i * ch + c] }
            o[i] = s / Float(ch)
        }
        onBuffer?(buf)
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - Meeting apps

/// Bundle ids that mean "a call is on". Shared by detection (MeetingMode) and the call tap.
enum MeetingApps {
    static let native: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "Cisco-Systems.Spark": "Webex", "com.webex.meetingmanager": "Webex", "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord",
    ]
    /// Browsers count only while a calendar event with a call link is live. Safari's mic lives in WebKit's GPU process.
    static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "com.apple.WebKit.GPU": "Safari",
        "company.thebrowser.Browser": "Arc", "com.microsoft.edgemac": "Edge", "org.mozilla.firefox": "Firefox",
        "com.brave.Browser": "Brave",
    ]
    static let music = ["com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.apple.TV",
                        "com.amazon.music", "com.tidal.desktop", "com.apple.QuickTimePlayerX", "org.videolan.vlc"]

    /// App name for a bundle id or one of its helpers ("com.google.Chrome.helper" is Chrome).
    static func name(_ bundle: String, in table: [String: String]) -> String? {
        if let n = table[bundle] { return n }
        return table.first { bundle.hasPrefix($0.key + ".") }?.value
    }

    /// The canonical key for a bundle (helpers fold into their app), so per-app settings line up.
    static func key(_ bundle: String) -> String {
        for t in [native, browsers] {
            if t[bundle] != nil { return bundle }
            if let k = t.keys.first(where: { bundle.hasPrefix($0 + ".") }) { return k }
        }
        return bundle
    }
}

// MARK: - Transcriber choice

protocol TrackTranscriber: AnyObject {
    func append(_ b: AVAudioPCMBuffer)
    func stop()
}

/// One track's transcript. On macOS 26 with the on-device model installed: SpeechAnalyzer. Otherwise
/// the classic recognizer, on-device only. Neither available: audio only, and `unavailable` says so.
/// Never downloads a model mid-meeting. Buffers that arrive before the engine is ready are dropped.
///
/// Watchdog: if the track is loud (someone is talking) but no words have come for 45 s, the
/// transcriber is restarted; a stalled or failed SpeechAnalyzer falls back to the classic one.
final class TrackText {
    private var inner: TrackTranscriber?
    private let lock = NSLock()
    private var stopped = false
    private let who: String
    private let t0: Date
    private let onFinal: (String, String, TimeInterval) -> Void
    private let onPartial: (String, String) -> Void
    private let unavailable: (String) -> Void
    private var usingAnalyzer = false
    private var lastHeard = Date()            // main
    private var lastLoud = Date.distantPast   // audio thread, under lock
    private var watchdog: Timer?

    init(who: String, t0: Date, final: @escaping (String, String, TimeInterval) -> Void,
         partial: @escaping (String, String) -> Void, unavailable: @escaping (String) -> Void) {
        self.who = who; self.t0 = t0; onFinal = final; onPartial = partial; self.unavailable = unavailable
        if #available(macOS 26, *) {
            Task { [weak self] in await self?.tryAnalyzer() }
        } else {
            legacy()
        }
        DispatchQueue.main.async { [weak self] in
            self?.watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.check() }
        }
    }

    private var finalCB: (String, String, TimeInterval) -> Void {
        { [weak self] w, t, a in self?.lastHeard = Date(); self?.onFinal(w, t, a) }
    }
    private var partialCB: (String, String) -> Void {
        { [weak self] w, t in if !t.isEmpty { self?.lastHeard = Date() }; self?.onPartial(w, t) }
    }

    @available(macOS 26, *)
    private func tryAnalyzer() async {
        let fail: (String) -> Void = { [weak self] why in DispatchQueue.main.async { self?.analyzerFailed(why) } }
        if let a = await AnalyzerTranscriber.make(who: who, t0: t0, final: finalCB, partial: partialCB, failed: fail) {
            FaceID.debug("tx \(who): SpeechAnalyzer")
            DispatchQueue.main.async { [weak self] in self?.usingAnalyzer = true }
            set(a)
        } else {
            FaceID.debug("tx \(who): SpeechAnalyzer model not installed, classic recognizer")
            legacy()
        }
    }

    private func legacy() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let l = LiveTranscriber(who: who, t0: t0, final: finalCB, partial: partialCB)
            if l.available { FaceID.debug("tx \(who): \(l.engineInfo)"); set(l) }
            else { FaceID.debug("tx \(who): no on-device speech"); unavailable("On-device speech not installed: recording audio only") }
        }
    }

    /// Main thread.
    private func analyzerFailed(_ why: String) {
        guard usingAnalyzer, !stopped else { return }
        FaceID.debug("tx \(who): SpeechAnalyzer failed (\(why)), switching to classic")
        usingAnalyzer = false
        lock.lock(); let old = inner; inner = nil; lock.unlock()
        old?.stop()
        legacy()
    }

    /// Main thread, every 10 s.
    private func check() {
        guard !stopped else { watchdog?.invalidate(); return }
        lock.lock(); let loud = lastLoud; let t = inner; lock.unlock()
        let now = Date()
        if ProcessInfo.processInfo.environment["ISLAND_TXDEBUG"] != nil || UserDefaults.standard.bool(forKey: "debug.tx") {
            FaceID.debug("tx \(who): check inner=\(t != nil) loud=\(Int(now.timeIntervalSince(loud)))s ago heard=\(Int(now.timeIntervalSince(lastHeard)))s ago")
        }
        guard t != nil, now.timeIntervalSince(loud) < 5, now.timeIntervalSince(lastHeard) > 45 else { return }
        lastHeard = now
        if usingAnalyzer { analyzerFailed("no words for 45 s of speech") }
        else { (t as? LiveTranscriber)?.restart("no words for 45 s of speech") }
    }

    private func set(_ t: TrackTranscriber) {
        lock.lock()
        if stopped { lock.unlock(); t.stop(); return }
        inner = t
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.lastHeard = Date() }
    }

    func append(_ b: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let d = b.floatChannelData?[0], b.frameLength > 0 { vDSP_rmsqv(d, 1, &rms, vDSP_Length(b.frameLength)) }
        lock.lock()
        if rms > 0.0056 { lastLoud = Date() }   // about -45 dBFS: someone is talking
        let t = inner
        lock.unlock()
        t?.append(b)
    }

    func stop() {
        lock.lock(); stopped = true; let t = inner; lock.unlock()
        t?.stop()
        DispatchQueue.main.async { [weak self] in self?.watchdog?.invalidate() }
    }
}

/// macOS 26: SpeechAnalyzer + SpeechTranscriber fed through an AsyncStream. One continuous
/// session for the whole meeting (no 50 s rotation); segment times come from the audio itself.
/// Any error, or the results ending early, calls `failed` so the track falls back to the classic
/// recognizer instead of going silent for the rest of the meeting.
@available(macOS 26, *)
final class AnalyzerTranscriber: TrackTranscriber {
    private let analyzer: SpeechAnalyzer
    private let target: AVAudioFormat
    private let cont: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    private var stopped = false

    private init(analyzer: SpeechAnalyzer, target: AVAudioFormat, cont: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer; self.target = target; self.cont = cont
    }

    /// The first supported locale whose on-device model is installed (not just the first supported).
    static func installedTranscriber(volatile: Bool = true) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable else { return nil }
        for l in [Locale.current, Locale(identifier: "en-IN"), Locale(identifier: "en-US"), Locale(identifier: "en-GB")] {
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: l) else { continue }
            let tr = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: volatile ? [.volatileResults] : [],
                                       attributeOptions: [.audioTimeRange])
            if await AssetInventory.status(forModules: [tr]) == .installed { return tr }
        }
        return nil
    }

    /// nil unless an on-device model is already installed.
    static func make(who: String, t0: Date, final: @escaping (String, String, TimeInterval) -> Void,
                     partial: @escaping (String, String) -> Void, failed: @escaping (String) -> Void) async -> AnalyzerTranscriber? {
        guard let tr = await installedTranscriber(),
              let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [tr]) else { return nil }
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let an = SpeechAnalyzer(modules: [tr])
        do { try await an.start(inputSequence: stream) } catch {
            FaceID.debug("tx \(who): analyzer start failed \(error)")
            cont.finish(); return nil
        }
        let me = AnalyzerTranscriber(analyzer: an, target: fmt, cont: cont)
        // The analyzer's clock starts at the first buffer it gets: from about now.
        let offset = Date().timeIntervalSince(t0)
        me.results = Task { [weak me] in
            do {
                for try await r in tr.results {
                    let text = String(r.text.characters)
                    if r.isFinal {
                        let at = offset + max(0, r.range.start.seconds.isFinite ? r.range.start.seconds : 0)
                        DispatchQueue.main.async { final(who, text, at); partial(who, "") }
                    } else {
                        DispatchQueue.main.async { partial(who, text) }
                    }
                }
                if me?.isStopped == false { failed("results ended early") }
            } catch {
                let e = error as NSError
                FaceID.debug("tx \(who): analyzer error \(e.domain) \(e.code) \(e.localizedDescription)")
                if me?.isStopped == false { failed("\(e.domain) \(e.code)") }
            }
        }
        return me
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Audio thread: convert to the analyzer's format and queue it.
    func append(_ b: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if converter == nil || converter?.inputFormat != b.format {
            converter = AVAudioConverter(from: b.format, to: target)
        }
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(b.frameLength) * target.sampleRate / b.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return b
        }
        if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        cont.finish()
        let an = analyzer
        Task { try? await an.finalizeAndFinishThroughEndOfInput() }
    }
}


// MARK: - Rebuild a thin transcript from the raw audio

extension MeetingRecorder {
    /// A track is thin when its live transcript has under 20 words per minute of meeting, or stops
    /// before 80% of it. Thin tracks are transcribed again from room.caf / call.caf (on device),
    /// written to the journal with "src":"file" plus a "rebuilt" line, and replace the live text.
    /// Returns the merged segments, or nil when nothing needed rebuilding. Blocks: call off main.
    static func rebuildThin(_ dir: URL, live: [Segment], length: TimeInterval) -> [Segment]? {
        let minutes = max(length / 60, 1)
        var out = live
        var changed = false
        for (who, name) in [("Room", "room.caf"), ("Call", "call.caf")] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let mine = live.filter { $0.who == who }
            let words = mine.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let reach = mine.last?.at ?? 0
            guard Double(words) / minutes < 20 || reach < length * 0.8 else { continue }
            FaceID.debug("meeting: \(who) transcript thin (\(words) words, last at \(Int(reach)) s of \(Int(length))), rebuilding from audio")
            let began = Date()
            let segs = FileTranscriber.run(url, who: who)
            FaceID.debug("meeting: \(who) rebuilt \(segs.count) segments in \(Int(Date().timeIntervalSince(began))) s")
            guard !segs.isEmpty else { continue }
            appendRebuilt(dir, segs: segs, who: who, src: "file")
            out = out.filter { $0.who != who } + segs
            changed = true
        }
        return changed ? out.sorted { $0.at < $1.at } : nil
    }

    /// A track transcribed again (`src` "file" or "whisper"): its segments, then a "rebuilt" line so
    /// readJournal uses them instead of the live ones.
    static func appendRebuilt(_ dir: URL, segs: [Segment], who: String, src: String) {
        guard let h = try? FileHandle(forWritingTo: dir.appendingPathComponent(journalName)) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        var lines: [[String: Any]] = segs.map { ["t": "seg", "at": $0.at, "who": who, "text": $0.text, "src": src] }
        lines.append(["t": "rebuilt", "who": who, "src": src])
        for l in lines { write(l, to: h) }
    }
}

/// Whole-file transcription, on device only. macOS 26 with the model installed: SpeechAnalyzer
/// over the file. Otherwise the classic recognizer, 45 s chunks one at a time. Blocks the caller.
enum FileTranscriber {
    static func run(_ url: URL, who: String) -> [MeetingRecorder.Segment] {
        if #available(macOS 26, *) {
            let sem = DispatchSemaphore(value: 0)
            var result: [MeetingRecorder.Segment]?
            Task.detached {
                result = await analyzer(url, who: who)
                sem.signal()
            }
            sem.wait()
            if let result { return result }
        }
        return classic(url, who: who)
    }

    @available(macOS 26, *)
    private static func analyzer(_ url: URL, who: String) async -> [MeetingRecorder.Segment]? {
        guard let tr = await AnalyzerTranscriber.installedTranscriber(volatile: false),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let an = SpeechAnalyzer(modules: [tr])
        let collect = Task { () -> [MeetingRecorder.Segment] in
            var out: [MeetingRecorder.Segment] = []
            do {
                for try await r in tr.results where r.isFinal {
                    let t = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let at = r.range.start.seconds.isFinite ? r.range.start.seconds : 0
                    if !t.isEmpty { out.append(.init(at: at, who: who, text: t)) }
                }
            } catch { FaceID.debug("tx file \(who): analyzer error \(error)") }
            return out
        }
        do {
            if let last = try await an.analyzeSequence(from: file) {
                try await an.finalizeAndFinish(through: last)
            } else {
                await an.cancelAndFinishNow()
            }
        } catch {
            FaceID.debug("tx file \(who): analyzer failed \(error)")
            collect.cancel()
            return nil
        }
        return await collect.value
    }

    private static func classic(_ url: URL, who: String) -> [MeetingRecorder.Segment] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let rec = [Locale.current, Locale(identifier: "en-IN"), Locale(identifier: "en-US")]
                .compactMap({ SFSpeechRecognizer(locale: $0) }).first(where: { $0.supportsOnDeviceRecognition }),
              let file = try? AVAudioFile(forReading: url) else { return [] }
        let fmt = file.processingFormat
        let chunk = AVAudioFrameCount(fmt.sampleRate * 45)
        var out: [MeetingRecorder.Segment] = []
        var pos: AVAudioFramePosition = 0
        while pos < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
            file.framePosition = pos
            guard (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
            let at = Double(pos) / fmt.sampleRate
            pos += AVAudioFramePosition(buf.frameLength)
            let r = SFSpeechAudioBufferRecognitionRequest()
            r.requiresOnDeviceRecognition = true
            r.addsPunctuation = true
            // Partials on: the recognizer starts its text over after each pause, and only partials
            // show the utterances before the last one (same as the live path).
            r.shouldReportPartialResults = true
            let sem = DispatchSemaphore(value: 0)
            var latest = ""
            var utterances: [String] = []
            var done = false
            let lock = NSLock()
            let task = rec.recognitionTask(with: r) { res, err in
                lock.lock(); defer { lock.unlock() }
                if let res, !res.bestTranscription.formattedString.isEmpty {
                    let now = res.bestTranscription.formattedString
                    if LiveTranscriber.restarted(from: latest, to: now) { utterances.append(latest) }
                    latest = now
                }
                if (res?.isFinal ?? false) || err != nil, !done { done = true; sem.signal() }
            }
            // Feed in 1 s slices: one 45 s append is treated as a single utterance burst.
            let step = AVAudioFrameCount(fmt.sampleRate)
            var off: AVAudioFrameCount = 0
            while off < buf.frameLength {
                let n = min(step, buf.frameLength - off)
                if let c = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) {
                    c.frameLength = n
                    c.floatChannelData![0].update(from: buf.floatChannelData![0] + Int(off), count: Int(n))
                    r.append(c)
                }
                off += n
            }
            r.endAudio()
            if sem.wait(timeout: .now() + 90) == .timedOut { task.cancel() }
            lock.lock(); let t = (utterances + [latest]).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines); lock.unlock()
            if !t.isEmpty { out.append(.init(at: at, who: who, text: t)) }
        }
        return out
    }
}

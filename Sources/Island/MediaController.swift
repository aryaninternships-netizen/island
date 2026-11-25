import AppKit
import CoreImage
import SwiftUI

/// Now Playing for every app (Music, Spotify, Chrome, Safari, ...) through
/// ungive/mediaremote-adapter. MediaRemote is closed to third-party apps since
/// macOS 15.4; the adapter runs inside /usr/bin/perl, which is entitled.
final class MediaController: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var bundleID = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    /// true while playing, and for a short grace period after pausing.
    @Published private(set) var live = false

    private var elapsed: Double = 0
    private var stamp = Date()
    private var rate: Double = 1
    private var state: [String: Any] = [:]
    private var proc: Process?
    private var buffer = Data()
    private var lastArtwork: String?
    private var graceWork: DispatchWorkItem?
    private var stopped = false

    /// Fires on a real track change (title differs), used for the "now playing" toast.
    var onTrackChange: ((MediaController) -> Void)?

    var hasMedia: Bool { !title.isEmpty }

    func elapsed(at date: Date) -> Double {
        guard playing else { return elapsed }
        let e = elapsed + date.timeIntervalSince(stamp) * rate
        return duration > 0 ? min(max(e, 0), duration) : max(e, 0)
    }

    // MARK: adapter process

    private var resources: URL { Bundle.main.resourceURL ?? URL(fileURLWithPath: ".") }
    private var script: String { resources.appendingPathComponent("mediaremote-adapter.pl").path }
    private var framework: String { resources.appendingPathComponent("MediaRemoteAdapter.framework").path }

    func start() {
        stopped = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, "stream", "--debounce=40"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.ingest(d)
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self, !self.stopped else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
        }
        do { try p.run(); proc = p } catch { NSLog("Island: media adapter failed: \(error)") }
    }

    func stop() {
        stopped = true
        proc?.terminate()
    }

    private func ingest(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let diff = obj["diff"] as? Bool ?? false
            DispatchQueue.main.async { self.apply(payload, diff: diff) }
        }
    }

    private func apply(_ payload: [String: Any], diff: Bool) {
        if diff {
            for (k, v) in payload {
                if v is NSNull { state.removeValue(forKey: k) } else { state[k] = v }
            }
        } else {
            state = payload
        }

        let newTitle = state["title"] as? String ?? ""
        let changed = newTitle != title && !newTitle.isEmpty
        let newArtist = state["artist"] as? String ?? ""
        let newAlbum = state["album"] as? String ?? ""
        let newBundle = state["parentApplicationBundleIdentifier"] as? String
            ?? state["bundleIdentifier"] as? String ?? ""
        let newDuration = state["duration"] as? Double ?? 0
        var newRate = state["playbackRate"] as? Double ?? 1
        if newRate == 0 { newRate = 1 }
        let newPlaying = state["playing"] as? Bool ?? false
        // Assign only on change: each @Published write re-renders every observing view.
        if title != newTitle { title = newTitle }
        if artist != newArtist { artist = newArtist }
        if album != newAlbum { album = newAlbum }
        if bundleID != newBundle { bundleID = newBundle }
        if duration != newDuration { duration = newDuration }
        elapsed = state["elapsedTime"] as? Double ?? 0
        rate = newRate
        if let ts = state["timestamp"] as? String,
           let date = Self.iso.date(from: ts) { stamp = date } else { stamp = Date() }
        if playing != newPlaying { playing = newPlaying }

        let art = state["artworkData"] as? String
        if art != lastArtwork {
            lastArtwork = art
            if let art, let data = Data(base64Encoded: art), let img = NSImage(data: data) {
                artwork = img
                accent = Self.accent(of: img)
            } else {
                artwork = nil
                accent = .white
            }
        }

        updateLive()
        if changed { onTrackChange?(self) }
    }

    private func updateLive() {
        graceWork?.cancel()
        if playing, hasMedia {
            if !live { live = true }
        } else if live {
            let w = DispatchWorkItem { [weak self] in
                guard let self, !self.playing else { return }
                self.live = false
            }
            graceWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: w)
        }
    }

    // MARK: controls

    enum Command: Int { case toggle = 2, next = 4, previous = 5, back15 = 12, skip15 = 13 }

    func send(_ c: Command) {
        run(["send", String(c.rawValue)])
        if c == .toggle { // optimistic flip, the stream confirms within ~100 ms
            elapsed = elapsed(at: Date()); stamp = Date(); playing.toggle(); updateLive()
        }
    }

    func seek(to seconds: Double) {
        elapsed = seconds; stamp = Date()
        run(["seek", String(Int(seconds * 1_000_000))])
    }

    private func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func openSourceApp() {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    var sourceIcon: NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: artwork tint

    private static let iso = ISO8601DateFormatter()
    private static let ci = CIContext(options: [.workingColorSpace: NSNull()])

    /// Average artwork colour, pushed bright and saturated so it reads on black.
    static func accent(of image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let input = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIAreaAverage",
                               parameters: [kCIInputImageKey: input,
                                            kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let out = f.outputImage else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        ci.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                  format: .RGBA8, colorSpace: nil)
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                        blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return Color(white: 0.92) }
        return Color(hue: h, saturation: min(1, s * 1.25 + 0.15), brightness: max(b, 0.85))
    }
}

import AVFoundation
import AppKit
import Combine
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Smart notes

/// Summary, decisions and action items from your typed notes + the transcript. Uses Apple's
/// on-device model when Apple Intelligence is on (nothing leaves the Mac); otherwise simple rules.
enum SmartNotes {
    struct Result {
        var summary: [String] = []
        var decisions: [String] = []
        var actions: [String] = []
        var engine = ""
    }

    static func transcriptText(_ segs: [MeetingRecorder.Segment]) -> String {
        segs.map { "[\(clockText($0.at)) \($0.who)] \($0.text)" }.joined(separator: "\n")
    }

    /// Each mark with the transcript ±20 s around it: what you flagged as important.
    static func markText(_ marks: [MeetingRecorder.Mark], _ segs: [MeetingRecorder.Segment]) -> String {
        marks.map { m in
            let near = segs.filter { abs($0.at - m.at) <= 20 }.map(\.text).joined(separator: " ")
            return "[\(clockText(m.at))]" + (m.note.map { " \($0):" } ?? "") + (near.isEmpty ? "" : " \(near)")
        }.joined(separator: "\n")
    }

    static func make(title: String, notes: String, segments: [MeetingRecorder.Segment], marks: [MeetingRecorder.Mark] = [],
                     attendees: [String] = [], done: @escaping (Result) -> Void) {
        let transcript = transcriptText(segments)
        guard !transcript.isEmpty || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !marks.isEmpty else {
            done(Result(summary: ["Nothing was said or typed, so there is nothing to summarize yet."], engine: ""))
            return
        }
        let flagged = markText(marks, segments)
        Task {
            var r: Result?
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                r = try? await apple(title: title, notes: notes, transcript: transcript, marks: flagged, attendees: attendees)
            }
            #endif
            let out = r ?? rules(notes: notes, segments: segments, marks: marks)
            await MainActor.run { done(out) }
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func apple(title: String, notes: String, transcript: String, marks: String, attendees: [String]) async throws -> Result {
        guard case .available = SystemLanguageModel.default.availability else { throw CancellationError() }
        // The on-device model has a small context: boil long transcripts down chunk by chunk first.
        var material = transcript
        if material.count > 7000 {
            var points: [String] = []
            var rest = Substring(material)
            while !rest.isEmpty {
                let chunk = rest.prefix(6000)
                rest = rest.dropFirst(chunk.count)
                let s = LanguageModelSession(instructions: "You condense meeting transcript excerpts into short factual bullet points. Keep names, numbers, dates, decisions and commitments. No preamble.")
                // One refused or failed chunk loses only that chunk, not the whole recap.
                if let r = try? await s.respond(to: "Excerpt:\n\(chunk)\n\nBullet points:") { points.append(r.content) }
            }
            material = points.joined(separator: "\n")
        }
        var prompt = "Meeting: \(title.isEmpty ? "Untitled" : title)"
        if !attendees.isEmpty { prompt += "\nAttendees: " + attendees.joined(separator: ", ") }
        prompt += "\n\nMy notes:\n\(notes.isEmpty ? "(none)" : notes)"
        if !marks.isEmpty { prompt += "\n\nMoments I marked as important (weigh these most):\n\(marks)" }
        prompt += "\n\nTranscript:\n\(material.isEmpty ? "(none)" : material)"
        // Guided generation: the model fills a fixed shape, so there is nothing to parse.
        if let r = try? await guided(prompt) { return r }
        let s = LanguageModelSession(instructions: """
            You write crisp meeting notes. Use only what is in the material. Output exactly three sections:
            SUMMARY: 3-6 bullets
            DECISIONS: bullets, or "- none"
            ACTIONS: bullets as "Owner: task (due date if said)", or "- none"
            Each bullet starts with "- ". No other text.
            """)
        var r = parse(try await s.respond(to: prompt).content)
        r.engine = "Apple Intelligence, on device"
        return r
    }

    /// Notes { summary, decisions, actions: [Action { owner?, task, due? }] } as a runtime schema
    /// (the @Generable macro needs Xcode's plugin; Command Line Tools builds have none).
    @available(macOS 26, *)
    private static func guided(_ prompt: String) async throws -> Result {
        let str = DynamicGenerationSchema(type: String.self)
        let action = DynamicGenerationSchema(name: "Action", description: "One follow-up someone committed to", properties: [
            .init(name: "owner", description: "Who does it, if said", schema: str, isOptional: true),
            .init(name: "task", description: "What to do, short and concrete", schema: str),
            .init(name: "due", description: "When, if said", schema: str, isOptional: true),
        ])
        let notes = DynamicGenerationSchema(name: "Notes", properties: [
            .init(name: "summary", description: "3 to 6 short factual bullets", schema: .init(arrayOf: str, minimumElements: 1, maximumElements: 6)),
            .init(name: "decisions", description: "Decisions made, empty if none", schema: .init(arrayOf: str, maximumElements: 6)),
            .init(name: "actions", description: "Action items, empty if none", schema: .init(arrayOf: .init(referenceTo: "Action"), maximumElements: 10)),
        ])
        let schema = try GenerationSchema(root: notes, dependencies: [action])
        let s = LanguageModelSession(instructions: "You write crisp meeting notes. Use only what is in the material. No preamble.")
        let out = try await s.respond(to: prompt, schema: schema).content
        var r = Result(engine: "Apple Intelligence, on device")
        r.summary = try out.value([String].self, forProperty: "summary")
        r.decisions = (try? out.value([String].self, forProperty: "decisions")) ?? []
        let acts = (try? out.value([GeneratedContent].self, forProperty: "actions")) ?? []
        r.actions = acts.compactMap { a in
            guard let task = try? a.value(String.self, forProperty: "task"), !task.isEmpty else { return nil }
            let owner = (try? a.value(String?.self, forProperty: "owner")) ?? nil
            let due = (try? a.value(String?.self, forProperty: "due")) ?? nil
            return (owner.map { "\($0): " } ?? "") + task + (due.map { " (\($0))" } ?? "")
        }
        return r
    }
    #endif

    private static func parse(_ text: String) -> Result {
        var r = Result()
        var section = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            let up = line.trimmingCharacters(in: CharacterSet(charactersIn: "#:-•* ")).uppercased()
            if up.count <= 16, up.hasPrefix("SUMMARY") { section = 0; continue }
            if up.count <= 16, up.hasPrefix("DECISION") { section = 1; continue }
            if up.count <= 16, up.hasPrefix("ACTION") { section = 2; continue }
            var b = line
            for p in ["- ", "• ", "* "] where b.hasPrefix(p) { b.removeFirst(p.count) }
            b = b.trimmingCharacters(in: .whitespaces)
            let low = b.lowercased()
            guard !b.isEmpty, low != "none", !low.hasPrefix("no decisions"), !low.hasPrefix("no actions"),
                  !low.hasPrefix("no action items") else { continue }
            switch section {
            case 0: r.summary.append(b)
            case 1: r.decisions.append(b)
            default: r.actions.append(b)
            }
        }
        return r
    }

    /// No on-device model: pull out commitments and decisions by phrasing.
    private static func rules(notes: String, segments: [MeetingRecorder.Segment], marks: [MeetingRecorder.Mark]) -> Result {
        var r = Result(engine: "Rules (turn on Apple Intelligence for real summaries)")
        let sentences = segments.flatMap { s in
            s.text.split(whereSeparator: { ".?!".contains($0) }).map { (s.who, $0.trimmingCharacters(in: .whitespaces)) }
        }.filter { $0.1.count > 12 }
        let act = try! NSRegularExpression(pattern: #"\b(i'll|we'll|you'll|will|need to|needs to|action item|follow up|follow-up|to-?do|send|share|by (monday|tuesday|wednesday|thursday|friday|tomorrow|eod|end of))\b"#, options: .caseInsensitive)
        let dec = try! NSRegularExpression(pattern: #"\b(decided|agreed|let's go with|we'll go with|final call|approved)\b"#, options: .caseInsensitive)
        func hit(_ rx: NSRegularExpression, _ s: String) -> Bool { rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        r.actions = Array(sentences.filter { hit(act, $0.1) }.map { $0.1 }.prefix(8))
        r.decisions = Array(sentences.filter { hit(dec, $0.1) }.map { $0.1 }.prefix(5))
        let typed = notes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Marked moments lead: what was said right at each mark, then typed notes, then the longest sentences.
        let marked = marks.compactMap { m in m.note ?? segments.min { abs($0.at - m.at) < abs($1.at - m.at) }?.text }
        r.summary = Array((marked + typed + sentences.sorted { $0.1.count > $1.1.count }.map { $0.1 }).prefix(5))
        return r
    }

    static func markdown(title: String, start: Date, length: TimeInterval, notes: String, result: Result?,
                         segments: [MeetingRecorder.Segment], marks: [MeetingRecorder.Mark] = [], consent: Bool? = false,
                         attendees: [String] = []) -> String {
        var md = "# \(title.isEmpty ? "Meeting" : title)\n\n\(start.formatted(date: .complete, time: .shortened))"
        if length > 0 { md += " · \(clockText(length))" }
        md += "\n\n"
        md += consent.map { $0 ? "consent: shown\n\n" : "consent: not shown (hidden)\n\n" } ?? "consent: unknown (recovered)\n\n"
        if !attendees.isEmpty { md += "Attendees: " + attendees.joined(separator: ", ") + "\n\n" }
        if !notes.isEmpty { md += "## My notes\n\n\(notes)\n\n" }
        if !marks.isEmpty { md += "## Marks\n\n" + markText(marks, segments).split(separator: "\n").map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if let r = result {
            if !r.summary.isEmpty { md += "## Summary\n\n" + r.summary.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !r.decisions.isEmpty { md += "## Decisions\n\n" + r.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !r.actions.isEmpty { md += "## Action items\n\n" + r.actions.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n" }
        }
        if !segments.isEmpty { md += "## Transcript\n\n" + transcriptText(segments) + "\n" }
        return md
    }
}

// MARK: - Session

/// Where a recording came from: the notch, a hotkey, or an app that took the mic.
enum MeetingSource: Equatable {
    case manual
    case detected(app: String, bundle: String)
}

/// One meeting: title, typed notes, recorder, smart result. Owned by MeetingMode; the notes window only shows it.
final class MeetingSession: ObservableObject {
    @Published var title: String
    @Published var notes = ""
    @Published var result: SmartNotes.Result?
    @Published var thinking = false
    @Published var tab = 0 // 0 notes, 1 transcript, 2 summary
    @Published private(set) var length: TimeInterval = 0
    let recorder = MeetingRecorder()
    let source: MeetingSource
    let attendees: [String]
    /// The call app holding the mic when this started: when it lets go, auto-stop may follow.
    let callApp: String?
    /// The consent banner showed at start (always true once recording began; written into notes.md).
    var consentShown = false
    private var began = Date()
    private var draft: AnyCancellable?

    init(title: String, source: MeetingSource = .manual, attendees: [String] = [], callApp: String? = nil) {
        self.title = title
        self.source = source
        self.attendees = attendees
        self.callApp = callApp
        // Crash safety: typed notes land in notes.draft.md two seconds after you stop typing.
        draft = $notes.dropFirst().debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveDraft() }
    }

    func begin() {
        began = Date()
        recorder.begin(title: title)
    }

    /// Stop, then write smart notes and notes.md. `done` runs on main when notes.md exists.
    func stop(done: @escaping () -> Void = {}) {
        guard recorder.recording else { done(); return }
        length = Date().timeIntervalSince(recorder.start)
        thinking = true
        tab = 2
        recorder.finish { [weak self] dir in
            guard let self else { return }
            SmartNotes.make(title: self.title, notes: self.notes, segments: self.recorder.segments,
                            marks: self.recorder.marks, attendees: self.attendees) { r in
                self.result = r
                self.thinking = false
                self.save()
                done()
                if let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent(Whisper.pendingName).path) {
                    NotificationCenter.default.post(name: .whisperPending, object: dir)
                }
            }
        }
    }

    /// Re-run the summary on what's there (typed notes only works too).
    func summarize() {
        thinking = true; tab = 2
        SmartNotes.make(title: title, notes: notes, segments: recorder.segments, marks: recorder.marks,
                        attendees: attendees) { [weak self] r in
            self?.result = r; self?.thinking = false; self?.save()
        }
    }

    var markdown: String {
        SmartNotes.markdown(title: title, start: recorder.folder == nil ? began : recorder.start, length: length,
                            notes: notes, result: result, segments: recorder.segments, marks: recorder.marks,
                            consent: consentShown, attendees: attendees)
    }

    private var dir: URL {
        recorder.folder ?? {
            let d = MeetingRecorder.root.appendingPathComponent(began.formatted(.iso8601.year().month().day()) + " " + (title.isEmpty ? "Notes" : title))
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }()
    }

    @discardableResult func save() -> URL? {
        let d = dir
        let url = d.appendingPathComponent("notes.md")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: d.appendingPathComponent("notes.draft.md"))
        return url
    }

    private func saveDraft() {
        guard recorder.recording, let d = recorder.folder else { return }
        try? notes.write(to: d.appendingPathComponent("notes.draft.md"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Window

/// Small floating notes window: a viewer for MeetingMode's session. Never activates Island or takes
/// focus from the meeting app, never shows in a share, and closing only hides it.
final class MeetingNotesWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MeetingNotesWindow()
    /// Close was pressed while recording: the inline "Stop & close / Keep recording" row shows.
    @Published var confirmClose = false
    private var panel: NSPanel?
    private weak var shown: MeetingSession?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(session s: MeetingSession) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 470),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.minSize = NSSize(width: 320, height: 360)
            p.backgroundColor = .clear
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.sharingType = .none
            p.delegate = self
            if let scr = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: scr.maxX - 400, y: scr.maxY - 490))
            }
            p.isReleasedWhenClosed = false
            panel = p
        }
        if shown !== s {
            shown?.recorder.metersVisible = false
            shown = s
            panel?.contentView = NSHostingView(rootView: MeetingNotesView(s: s, rec: s.recorder, w: self).preferredColorScheme(.dark))
        }
        confirmClose = false
        s.recorder.metersVisible = true
        panel?.orderFrontRegardless() // no NSApp.activate: the meeting app stays frontmost
    }

    func hide() {
        confirmClose = false
        shown?.recorder.metersVisible = false
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let s = shown else { hide(); return false }
        if s.recorder.recording {
            confirmClose = true
        } else {
            if !s.notes.isEmpty || s.result != nil { s.save() }
            hide()
        }
        return false
    }
}

// MARK: - View

struct MeetingNotesView: View {
    @ObservedObject var s: MeetingSession
    @ObservedObject var rec: MeetingRecorder
    @ObservedObject var w: MeetingNotesWindow
    @Environment(\.accessibilityReduceMotion) private var rm
    @Environment(\.accessibilityReduceTransparency) private var rt
    @Environment(\.accessibilityDifferentiateWithoutColor) private var dwc
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Meeting title", text: $s.title)
                .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                .padding(.top, 6)
                .accessibilityLabel("Meeting title")
            recordBar
            if w.confirmClose { confirmRow }
            if let p = rec.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            if rec.voiceIsolationOn && rec.mode == .room {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(.yellow)
                    Text("Voice Isolation hides far voices. Use Standard or Wide Spectrum for a room.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Button("Change") { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.yellow)
                }
            }
            Picker("", selection: $s.tab) {
                Text("Notes").tag(0)
                Text("Transcript").tag(1)
                Text("Smart notes").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("View")
            Group {
                switch s.tab {
                case 0: notesPane
                case 1: transcriptPane
                default: smartPane
                }
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 12)
        // Reduce Transparency: solid black instead of the see-through material.
        .background(rt ? AnyShapeStyle(Color.black) : AnyShapeStyle(.ultraThinMaterial))
        .background(Color.black.opacity(0.55))
    }

    /// Replaces the old modal alert: inline, so nothing pops over the meeting.
    private var confirmRow: some View {
        HStack(spacing: 8) {
            Text("Recording continues in the notch").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Chip(label: "Stop & close", tint: .red) { MeetingMode.shared.stop(); w.hide() }
                .help("Stop recording, write notes, close this window")
            Chip(label: "Keep recording", tint: .white) { w.hide() }
                .help("Hide this window; recording carries on")
        }
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var recordBar: some View {
        HStack(spacing: 12) {
            Button { MeetingMode.shared.toggle(session: s) } label: {
                ZStack {
                    Circle().fill(.red.opacity(rec.recording ? 0.22 : 0.14)).frame(width: 40, height: 40)
                    if rec.recording { RoundedRectangle(cornerRadius: 3).fill(.red).frame(width: 14, height: 14) }
                    else { Circle().fill(.red).frame(width: 18, height: 18) }
                }
            }
            .buttonStyle(.plain)
            .help(rec.recording ? "Stop and write smart notes" : "Record this meeting")
            .accessibilityLabel(rec.recording ? "Stop recording" : "Start recording")
            VStack(alignment: .leading, spacing: 4) {
                if rec.recording {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 6, height: 6)
                                .opacity(rm || Int(ctx.date.timeIntervalSince1970) % 2 == 0 ? 1 : 0.3) // Reduce Motion: solid
                            Text(clockText(ctx.date.timeIntervalSince(rec.start)))
                                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Recording")
                        .accessibilityValue(clockText(ctx.date.timeIntervalSince(rec.start)))
                    }
                    Meter(label: rec.mode == .room ? "Room" : "Mic", level: rec.micLevel, tint: .green)
                    if rec.captureCall { Meter(label: "Call", level: rec.callLevel, tint: .blue) }
                } else {
                    Picker("", selection: $rec.mode) {
                        ForEach(MeetingRecorder.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                    .accessibilityLabel("Microphone mode")
                    .help("Room: Mac on the table, picks up everyone and levels far voices. Near: just you, noise suppressed.")
                    Toggle("Include call audio (Zoom, Meet, Teams)", isOn: $rec.captureCall)
                        .toggleStyle(.checkbox).font(.system(size: 10.5))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var notesPane: some View {
        ZStack(alignment: .topLeading) {
            if s.notes.isEmpty {
                Text("Type notes as you go… Smart notes merges them with the transcript.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.3))).padding(.horizontal, 5).padding(.top, 1)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $s.notes).font(.system(size: 12.5)).scrollContentBackground(.hidden)
                .accessibilityLabel("Notes")
        }
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if rec.segments.isEmpty && rec.partial.values.allSatisfy(\.isEmpty) {
                        Text(rec.recording ? "Listening…" : "Press record: the transcript appears here, written on this Mac.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    ForEach(rec.segments) { seg in line(seg.at, seg.who, seg.text, live: false) }
                    ForEach(rec.partial.keys.sorted(), id: \.self) { who in
                        if let t = rec.partial[who], !t.isEmpty { line(nil, who, t, live: true) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onChange(of: rec.segments.count) { proxy.scrollTo("end") }
            .onChange(of: rec.partial) { proxy.scrollTo("end") }
        }
    }

    private func line(_ at: TimeInterval?, _ who: String, _ text: String, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                // Differentiate Without Color: the speaker word itself carries it, so make it readable.
                Text(who).font(.system(size: dwc ? 11 : 9.5, weight: .bold)).foregroundStyle(who == "Call" ? .blue : .green)
                if let at { Text(clockText(at)).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary) }
            }
            Text(text).font(.system(size: 12)).foregroundStyle(live ? .white.opacity(0.6) : .white).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var smartPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if s.thinking {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Writing smart notes…").font(.system(size: 12)) }
                } else if let r = s.result {
                    section("Summary", "text.alignleft", .white, r.summary)
                    section("Decisions", "signpost.right.fill", .green, r.decisions)
                    section("Action items", "arrow.right.circle.fill", .orange, r.actions)
                    Text(r.engine).font(.system(size: 9.5)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.35)))
                } else {
                    Text("Stop a recording, or tap Summarize, to get a summary, decisions and action items.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func section(_ name: String, _ sym: String, _ tint: Color, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label(name, systemImage: sym).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                ForEach(items, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(i).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Chip(symbol: "sparkles", label: "Summarize", tint: .purple) { s.summarize() }
                .disabled(rec.recording || s.thinking)
            Chip(symbol: "doc.on.doc", label: "Copy", tint: .white) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.markdown, forType: .string)
            }
            Spacer()
            Chip(symbol: "folder", label: nil, tint: .white) {
                if let u = s.save() { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
            .help("Show notes.md and the recording in Finder")
            .accessibilityLabel("Show in Finder")
        }
        .overlay(alignment: .center) {
            if rec.recording {
                Text("Let people know you're recording").font(.system(size: 9.5)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.35)))
                    .offset(y: -22)
            }
        }
    }
}

struct Meter: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(level > 0.92 ? .red : tint).frame(width: g.size.width * CGFloat(level))
                        .animation(.easeOut(duration: 0.1), value: level)
                }
            }
            .frame(width: 120, height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + " level")
        .accessibilityValue("\(Int((min(max(level, 0), 1) * 100).rounded())) percent")
    }
}

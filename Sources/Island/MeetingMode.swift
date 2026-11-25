import AppKit
import Combine
import CoreAudio
import EventKit
import SwiftUI

// MARK: - Meeting mode
//
// Owns the meeting: start, stop, marks, recap, detection. Stealth by design: everything lives in the
// notch (hidden from shares via sharingType), nothing activates Island or steals focus, no sounds.
// Main thread only. Island reads it through narrow removeDuplicates sinks, never objectWillChange.

/// "Zoom took the mic: record?" A hollow dot and the title, silent, gone after 90 s.
struct MeetingOffer: Equatable {
    let bundle: String
    let app: String
    let title: String
    let at: Date
}

/// What a finished meeting left: shown on Home for 3 h, persisted as recap.json in its folder.
struct MeetingRecap: Codable, Equatable {
    struct Action: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        /// Picked on the recap card: these (and only these) go to Reminders.
        var picked = false
        var sent = false
    }

    var title: String
    var folder: String?
    var date: Date
    var length: TimeInterval
    var summary: [String] = []
    var decisions: [String] = []
    var actions: [Action] = []
    var marks = 0
    var engine = ""
    /// Notes are still being written.
    var pending = false
    var dismissed = false

    var fresh: Bool { !dismissed && Date().timeIntervalSince(date) < 3 * 3600 }
    var folderURL: URL? { folder.map { URL(fileURLWithPath: $0) } }
}

final class MeetingMode: ObservableObject {
    static let shared = MeetingMode()

    @Published private(set) var session: MeetingSession?
    /// Mirrors the session recorder's `recording` (the one value most of Island cares about).
    @Published private(set) var isRecording = false
    @Published private(set) var recap: MeetingRecap?
    @Published var offer: MeetingOffer?
    /// Panic-hide (⌃⌥H): the notch draws plain black and the notes window steps away.
    @Published var presenting = false { didSet { if presenting != oldValue { presentingChanged() } } }
    /// The mandatory 4 s "Recording · let people know" banner.
    @Published private(set) var consent = false
    /// Brief dot flash after a mark.
    @Published private(set) var flash = false
    /// "Auto-stopped · Resume" for 2 min after the call app let go of the mic.
    @Published private(set) var autoStopped: String?
    /// A meeting that never finished (Island quit or crashed mid-recording).
    @Published private(set) var recoverable: URL?
    /// Meeting apps (native, or a browser) holding the mic right now, canonical bundle ids.
    @Published private(set) var callsOnMic: Set<String> = []

    weak var calendar: CalendarModel?
    /// Transient banners (problems, Reminders result). Set by IslandModel.
    var banner: ((Activity) -> Void)?

    private let mic = MicWatcher()
    private var sessionBag: Set<AnyCancellable> = []
    private var offerWork: DispatchWorkItem?
    private var consentWork: DispatchWorkItem?
    private var autoStopWork: DispatchWorkItem?
    private var autoStoppedWork: DispatchWorkItem?
    /// Apps whose offer was dismissed or timed out: no new offer until they let go of the mic.
    private var declined: Set<String> = []
    private var notesWereVisible = false
    private let d = UserDefaults.standard

    private init() {
        if let path = d.string(forKey: "meeting.recap"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let r = try? JSONDecoder().decode(MeetingRecap.self, from: data), r.fresh {
            recap = r
        }
    }

    func start(calendar: CalendarModel) {
        self.calendar = calendar
        mic.onChange = { [weak self] apps in self?.micChanged(apps) }
        mic.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkRecovery() }
        NotificationCenter.default.addObserver(forName: .whisperPending, object: nil, queue: .main) { [weak self] n in
            if let dir = n.object as? URL { self?.queueWhisper(dir) }
        }
        // Meetings whose Whisper pass never finished (quit, crash): pick them up quietly.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak self] in self?.resumeWhisper() }
    }

    // MARK: Whisper pass

    /// Folder name being transcribed by Whisper right now (Home shows a quiet spinner card).
    @Published private(set) var whisperBusy: String?
    /// Set when a pass finishes, for the "transcript upgraded" banner.
    @Published private(set) var whisperDone: String?
    private var whisperQueue: [URL] = []

    func queueWhisper(_ dir: URL) {
        guard !whisperQueue.contains(dir) else { return }
        whisperQueue.append(dir)
        runNextWhisper()
    }

    private func runNextWhisper() {
        guard whisperBusy == nil, let dir = whisperQueue.first else { return }
        whisperBusy = dir.lastPathComponent
        FaceID.debug("whisper: start \(dir.lastPathComponent)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ready = Whisper.ready
            let segs = ready ? Whisper.meeting(dir) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                let finish = {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(Whisper.pendingName))
                    DispatchQueue.global(qos: .utility).async { MeetingRecorder.dropRaw(dir) }
                    self.whisperQueue.removeAll { $0 == dir }
                    self.whisperBusy = nil
                    if segs != nil { self.whisperDone = dir.lastPathComponent }
                    self.runNextWhisper()
                }
                if segs != nil { self.rewriteNotes(dir, done: finish) } else { finish() }
            }
        }
    }

    /// notes.md and recap.json again from the (now Whisper) journal. Typed notes, consent line and
    /// the title are kept; the old notes stay as notes.live.md.
    private func rewriteNotes(_ dir: URL, done: @escaping () -> Void) {
        guard let j = MeetingRecorder.readJournal(dir) else { done(); return }
        let notesURL = dir.appendingPathComponent("notes.md")
        let old = (try? String(contentsOf: notesURL, encoding: .utf8)) ?? ""
        let typed = Self.section(old, "My notes")
        let consent: Bool? = old.contains("consent: shown") ? true : old.contains("consent: not shown") ? false : nil
        let recapURL = dir.appendingPathComponent("recap.json")
        let length = max(MeetingRecorder.audioLength(dir), j.segments.last?.at ?? 0)
        var r = (try? JSONDecoder().decode(MeetingRecap.self, from: Data(contentsOf: recapURL)))
            ?? MeetingRecap(title: j.title.isEmpty ? "Meeting" : j.title, folder: dir.path, date: j.start, length: length, marks: j.marks.count)
        SmartNotes.make(title: r.title, notes: typed, segments: j.segments, marks: j.marks) { [weak self] res in
            if !old.isEmpty { try? old.write(to: dir.appendingPathComponent("notes.live.md"), atomically: true, encoding: .utf8) }
            let md = SmartNotes.markdown(title: r.title, start: j.start, length: length, notes: typed, result: res,
                                         segments: j.segments, marks: j.marks, consent: consent)
            try? md.write(to: notesURL, atomically: true, encoding: .utf8)
            r.summary = res.summary; r.decisions = res.decisions; r.engine = res.engine + " · Whisper transcript"
            r.actions = res.actions.map { MeetingRecap.Action(text: $0) }
            r.pending = false
            if let self, self.recap?.folder == r.folder { self.recap = r; self.persist(r) }
            else if let data = try? JSONEncoder().encode(r) { try? data.write(to: recapURL, options: .atomic) }
            done()
        }
    }

    /// Text under "## <name>" up to the next "## " heading.
    static func section(_ md: String, _ name: String) -> String {
        guard let r = md.range(of: "## \(name)\n\n") else { return "" }
        let rest = md[r.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Background queue: folders still marked pending. Whisper gone or off: just finish the cleanup.
    private func resumeWhisper() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: MeetingRecorder.root, includingPropertiesForKeys: nil) else { return }
        let pending = dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent(Whisper.pendingName).path) }
        guard !pending.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for d in pending { self?.queueWhisper(d) }
        }
    }

    // MARK: settings

    static var detectEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "meeting.detect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "meeting.detect") }
    }

    /// Opt-in per app. Auto-start still shows the consent banner.
    static func autoStart(_ bundle: String) -> Bool { UserDefaults.standard.bool(forKey: "meeting.auto." + bundle) }
    static func setAutoStart(_ bundle: String, _ on: Bool) { UserDefaults.standard.set(on, forKey: "meeting.auto." + bundle) }

    // MARK: start / stop

    func toggle(session s: MeetingSession? = nil) {
        if isRecording { stop() } else { start(reuse: s) }
    }

    func start(title: String? = nil, source: MeetingSource = .manual, reuse: MeetingSession? = nil) {
        guard !isRecording else { return }
        clearOffer()
        autoStopped = nil
        let ev = liveEvent()
        let call = callsOnMic.first.map { ($0, appName($0)) }
        let s: MeetingSession
        if let r = reuse, r === session, r.recorder.folder == nil {
            s = r
        } else {
            let t = title ?? ev?.title ?? Self.adHoc(call?.1)
            s = MeetingSession(title: t, source: source, attendees: ev?.attendees ?? [], callApp: call?.0)
            // Room mode whenever call audio is captured (the default); Near is for solo dictation.
            if call != nil { s.recorder.mode = .room }
        }
        session = s
        bind(s)
        // Hidden (⌃⌥H) suppresses the banner; the notes record that honestly.
        s.consentShown = !presenting
        showConsent()
        s.begin()
        if MeetingNotesWindow.shared.isVisible { MeetingNotesWindow.shared.show(session: s) }
    }

    /// Stop and build the recap (Home shows it while notes are written, then filled in).
    func stop() {
        guard let s = session, s.recorder.recording else { return }
        autoStopWork?.cancel(); autoStopWork = nil
        var r = MeetingRecap(title: s.title, folder: s.recorder.folder?.path, date: Date(),
                             length: Date().timeIntervalSince(s.recorder.start), marks: s.recorder.marks.count, pending: true)
        recap = r
        s.stop { [weak self, weak s] in
            guard let self, let s else { return }
            let res = s.result ?? SmartNotes.Result()
            r.title = s.title
            r.summary = res.summary; r.decisions = res.decisions; r.engine = res.engine
            r.actions = res.actions.map { MeetingRecap.Action(text: $0) }
            r.pending = false
            if self.recap?.folder == r.folder || self.recap == nil || self.recap?.pending == true { self.recap = r }
            self.persist(r)
            if self.session === s { self.session = nil }
        }
    }

    /// Bookmark now (⌃⌥M). Haptic tick plus a dot flash, never a sound.
    func mark(_ note: String? = nil) {
        guard let s = session, s.recorder.mark(note) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.flash = false }
    }

    /// Stop without notes and move the folder to the Trash (recoverable from there).
    func discard() {
        guard let s = session else { return }
        autoStopWork?.cancel(); autoStopWork = nil
        let dir = s.recorder.folder
        s.recorder.finish { _ in
            if let dir { try? FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
        }
        session = nil
        MeetingNotesWindow.shared.hide()
    }

    /// Show the notes window for the live session (starting one if nothing is recording).
    func openNotes() {
        if !isRecording { start() }
        if let s = session { MeetingNotesWindow.shared.show(session: s) }
    }

    private func bind(_ s: MeetingSession) {
        sessionBag.removeAll()
        s.recorder.$recording.removeDuplicates().sink { [weak self] on in
            if self?.isRecording != on { self?.isRecording = on }
        }.store(in: &sessionBag)
        s.recorder.$problem.compactMap { $0 }.removeDuplicates().sink { [weak self] p in
            self?.banner?(Activity(id: "meeting-problem", symbol: "exclamationmark.triangle.fill", tint: .orange,
                                   title: p, banner: true, duration: 5))
        }.store(in: &sessionBag)
    }

    private func showConsent() {
        consentWork?.cancel()
        consent = true
        let w = DispatchWorkItem { [weak self] in self?.consent = false }
        consentWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    private func presentingChanged() {
        let w = MeetingNotesWindow.shared
        if presenting {
            notesWereVisible = w.isVisible
            w.hide()
        } else if notesWereVisible, let s = session {
            w.show(session: s)
        }
    }

    // MARK: calendar

    /// A timed event that started (or starts within 5 min) and hasn't ended.
    func liveEvent(now: Date = Date()) -> CalendarModel.Item? {
        calendar?.items.first { !$0.allDay && $0.start.timeIntervalSince(now) < 5 * 60 && $0.end > now }
    }

    static func adHoc(_ app: String?) -> String {
        let t = Date().formatted(date: .omitted, time: .shortened)
        return app.map { "\($0) call \(t)" } ?? "Meeting \(t)"
    }

    private func appName(_ bundle: String) -> String {
        MeetingApps.name(bundle, in: MeetingApps.native) ?? MeetingApps.name(bundle, in: MeetingApps.browsers) ?? "Call"
    }

    // MARK: detection (event-driven: Core Audio listeners, no polling)

    /// Re-run detection without a mic change: a calendar event with a link just went live while
    /// a browser already held the mic. Called from the meeting one-shot timers.
    func recheck() { micChanged(mic.current) }

    private func micChanged(_ apps: Set<String>) {
        let event = liveEvent()
        let calls = apps.filter { b in
            if MeetingApps.native[b] != nil { return true }
            return MeetingApps.browsers[b] != nil && event?.link != nil
        }
        if calls != callsOnMic { callsOnMic = calls }
        declined.formIntersection(calls)

        if let s = session, isRecording, let app = s.callApp {
            if calls.contains(app) {
                autoStopWork?.cancel(); autoStopWork = nil
            } else if autoStopWork == nil {
                // The call app let go of the mic: give it 60 s (rejoins, device switches), then wrap up.
                let w = DispatchWorkItem { [weak self] in
                    guard let self, self.isRecording, self.session === s, !self.callsOnMic.contains(app) else { return }
                    self.autoStopWork = nil
                    let title = s.title
                    self.stop()
                    self.autoStopped = title
                    self.autoStoppedWork?.cancel()
                    let clear = DispatchWorkItem { [weak self] in self?.autoStopped = nil }
                    self.autoStoppedWork = clear
                    DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: clear)
                }
                autoStopWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
            }
        }

        if let o = offer, !calls.contains(o.bundle) { clearOffer() }
        guard !isRecording, Self.detectEnabled, offer == nil,
              let hit = calls.sorted().first(where: { !declined.contains($0) }) else { return }
        let name = appName(hit)
        let title = event?.title ?? Self.adHoc(name)
        if Self.autoStart(hit) {
            start(title: title, source: .detected(app: name, bundle: hit))
        } else {
            offer(MeetingOffer(bundle: hit, app: name, title: title, at: Date()))
        }
    }

    private func offer(_ o: MeetingOffer) {
        offer = o
        offerWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.offer == o else { return }
            self.declined.insert(o.bundle)
            self.offer = nil
        }
        offerWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: w)
    }

    func acceptOffer() {
        guard let o = offer else { return }
        start(title: o.title, source: .detected(app: o.app, bundle: o.bundle))
    }

    func dismissOffer() {
        if let o = offer { declined.insert(o.bundle) }
        clearOffer()
    }

    private func clearOffer() {
        offerWork?.cancel(); offerWork = nil
        if offer != nil { offer = nil }
    }

    /// Pretend an app took the mic (island://meeting?do=offer&app=Zoom). Testing only.
    func fakeOffer(app: String) {
        let b = MeetingApps.native.first { $0.value.lowercased() == app.lowercased() }?.key ?? "us.zoom.xos"
        offer(MeetingOffer(bundle: b, app: appName(b), title: liveEvent()?.title ?? Self.adHoc(appName(b)), at: Date()))
    }

    func resumeAfterAutoStop() {
        let t = autoStopped
        autoStoppedWork?.cancel()
        autoStopped = nil
        start(title: t)
    }

    func dismissAutoStop() { autoStoppedWork?.cancel(); autoStopped = nil }

    // MARK: recap

    private func persist(_ r: MeetingRecap) {
        guard let dir = r.folderURL, let data = try? JSONEncoder().encode(r) else { return }
        let url = dir.appendingPathComponent("recap.json")
        try? data.write(to: url, options: .atomic)
        d.set(url.path, forKey: "meeting.recap")
    }

    private func update(_ f: (inout MeetingRecap) -> Void) {
        guard var r = recap else { return }
        f(&r)
        recap = r
        persist(r)
    }

    func dismissRecap() {
        update { $0.dismissed = true }
        recap = nil
    }

    func togglePick(_ id: UUID) {
        update { r in
            if let i = r.actions.firstIndex(where: { $0.id == id }), !r.actions[i].sent { r.actions[i].picked.toggle() }
        }
    }

    /// Picked, unsent action items into Reminders › Island Meetings.
    func sendPicked() {
        guard let r = recap else { return }
        let items = r.actions.filter { $0.picked && !$0.sent }
        guard !items.isEmpty else { return }
        MeetingReminders.add(items.map(\.text), meeting: r.title) { [weak self] err in
            guard let self else { return }
            if let err {
                self.banner?(Activity(id: "reminders", symbol: "exclamationmark.triangle.fill", tint: .orange,
                                      title: err, banner: true, duration: 5))
                return
            }
            let ids = Set(items.map(\.id))
            self.update { r in for i in r.actions.indices where ids.contains(r.actions[i].id) { r.actions[i].sent = true } }
            self.banner?(Activity(id: "reminders", symbol: "list.bullet", tint: .orange,
                                  title: "\(items.count) in Reminders", body: "Island Meetings list", banner: true, duration: 3))
        }
    }

    var notesURL: URL? { recap?.folderURL?.appendingPathComponent("notes.md") }

    func copyRecap() {
        guard let u = notesURL, let md = try? String(contentsOf: u, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    func revealRecap() {
        if let u = notesURL, FileManager.default.fileExists(atPath: u.path) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else if let dir = recap?.folderURL {
            NSWorkspace.shared.open(dir)
        }
    }

    /// Rename the meeting: its folder (date stamp kept), the notes heading and the recap.
    func rename(_ name: String) {
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !new.isEmpty, var r = recap, !r.pending, new != r.title, let dir = r.folderURL else { return }
        let stamp = String(dir.lastPathComponent.prefix(16)) // "yyyy-MM-dd HH.mm"
        let to = dir.deletingLastPathComponent().appendingPathComponent(stamp + " " + new)
        let fm = FileManager.default
        if !fm.fileExists(atPath: to.path), (try? fm.moveItem(at: dir, to: to)) != nil { r.folder = to.path }
        let notes = (r.folderURL ?? dir).appendingPathComponent("notes.md")
        if var md = try? String(contentsOf: notes, encoding: .utf8), md.hasPrefix("# ") {
            if let nl = md.firstIndex(of: "\n") { md.replaceSubrange(md.startIndex..<nl, with: "# " + new) }
            try? md.write(to: notes, atomically: true, encoding: .utf8)
        }
        r.title = new
        recap = r
        persist(r)
    }

    // MARK: recovery

    /// The newest meeting folder from the last 2 days with a journal but no notes.md.
    private func checkRecovery() {
        guard session == nil else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let dirs = try? fm.contentsOfDirectory(at: MeetingRecorder.root, includingPropertiesForKeys: keys) else { return }
        let skip = d.string(forKey: "meeting.recoverSkip")
        let found = dirs.compactMap { u -> (URL, Date)? in
            guard u.path != skip,
                  fm.fileExists(atPath: u.appendingPathComponent(MeetingRecorder.journalName).path),
                  !fm.fileExists(atPath: u.appendingPathComponent("notes.md").path),
                  let m = try? u.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  Date().timeIntervalSince(m) < 48 * 3600 else { return nil }
            return (u, m)
        }.max { $0.1 < $1.1 }
        recoverable = found?.0
    }

    func skipRecovery() {
        if let u = recoverable { d.set(u.path, forKey: "meeting.recoverSkip") }
        recoverable = nil
    }

    /// Rebuild notes from the journal (every segment and mark heard before the crash) and mix the raw tracks.
    func recover() {
        guard let dir = recoverable, let j = MeetingRecorder.readJournal(dir) else { recoverable = nil; return }
        recoverable = nil
        let draft = (try? String(contentsOf: dir.appendingPathComponent("notes.draft.md"), encoding: .utf8)) ?? ""
        let length = max(j.segments.last?.at ?? 0, j.marks.last?.at ?? 0, MeetingRecorder.audioLength(dir))
        var r = MeetingRecap(title: j.title.isEmpty ? "Recovered meeting" : j.title, folder: dir.path, date: j.start,
                             length: length, marks: j.marks.count, pending: true)
        recap = r
        DispatchQueue.global(qos: .utility).async {
            var j = j
            let whisper = Whisper.ready
            if !whisper, let segs = MeetingRecorder.rebuildThin(dir, live: j.segments, length: length) { j.segments = segs }
            if whisper { FileManager.default.createFile(atPath: dir.appendingPathComponent(Whisper.pendingName).path, contents: nil) }
            MeetingRecorder.mixLeftovers(dir, keepRaw: whisper)
            DispatchQueue.main.async {
                SmartNotes.make(title: r.title, notes: draft, segments: j.segments, marks: j.marks) { [weak self] res in
                    let md = SmartNotes.markdown(title: r.title, start: j.start, length: length, notes: draft, result: res,
                                                 segments: j.segments, marks: j.marks, consent: nil)
                    try? md.write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("notes.draft.md"))
                    r.summary = res.summary; r.decisions = res.decisions; r.engine = res.engine
                    r.actions = res.actions.map { MeetingRecap.Action(text: $0) }
                    r.pending = false
                    r.date = Date() // fresh from now, so it stays on Home a while
                    self?.recap = r
                    self?.persist(r)
                    if whisper { self?.queueWhisper(dir) }
                }
            }
        }
    }
}

// MARK: - Reminders

enum MeetingReminders {
    static let listName = "Island Meetings"

    /// Adds each item to the "Island Meetings" list (created on first use). `done(nil)` on success.
    static func add(_ items: [String], meeting: String, done: @escaping (String?) -> Void) {
        let store = CalendarModel.store
        store.requestFullAccessToReminders { ok, _ in
            guard ok else {
                DispatchQueue.main.async { done("Allow Reminders for Island in System Settings › Privacy") }
                return
            }
            var err: String?
            let list: EKCalendar? = store.calendars(for: .reminder).first { $0.title == listName } ?? {
                let c = EKCalendar(for: .reminder, eventStore: store)
                c.title = listName
                c.source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first { $0.sourceType == .local }
                do { try store.saveCalendar(c, commit: true); return c } catch { return store.defaultCalendarForNewReminders() }
            }()
            if let list {
                do {
                    for t in items {
                        let r = EKReminder(eventStore: store)
                        r.title = t
                        r.notes = "From " + meeting
                        r.calendar = list
                        try store.save(r, commit: false)
                    }
                    try store.commit()
                } catch { err = "Couldn't add to Reminders" }
            } else {
                err = "No Reminders list to add to"
            }
            DispatchQueue.main.async { done(err) }
        }
    }
}

// MARK: - Mic watcher

/// Which apps are using a microphone, from Core Audio property listeners only: the default input's
/// IsRunningSomewhere, the process list, and each process's IsRunningInput. 0 CPU between changes.
final class MicWatcher {
    var onChange: ((Set<String>) -> Void)?
    private let sys = AudioObjectID(kAudioObjectSystemObject)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procs: [AudioObjectID] = []
    private var last: Set<String> = []
    /// Apps using a microphone as of the last change.
    var current: Set<String> { last }
    private var dirty = false
    private let me = getpid()

    private lazy var changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.setNeedsEvaluate() }
    private lazy var defaultChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.bindDevice(); self?.setNeedsEvaluate()
    }
    private lazy var listChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.bindProcesses(); self?.setNeedsEvaluate()
    }

    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        var a = Self.addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(sys, &a, .main, defaultChanged)
        a = Self.addr(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(sys, &a, .main, listChanged)
        bindDevice()
        bindProcesses()
        setNeedsEvaluate()
    }

    private func bindDevice() {
        var a = Self.addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if device != kAudioObjectUnknown { AudioObjectRemovePropertyListenerBlock(device, &a, .main, changed) }
        var dev = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var da = Self.addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectGetPropertyData(sys, &da, 0, nil, &sz, &dev)
        device = dev
        if dev != kAudioObjectUnknown { AudioObjectAddPropertyListenerBlock(dev, &a, .main, changed) }
    }

    private func bindProcesses() {
        var a = Self.addr(kAudioProcessPropertyIsRunningInput)
        let now = processList()
        let old = Set(procs), new = Set(now)
        for p in old.subtracting(new) { AudioObjectRemovePropertyListenerBlock(p, &a, .main, changed) }
        for p in new.subtracting(old) { AudioObjectAddPropertyListenerBlock(p, &a, .main, changed) }
        procs = now
    }

    private func processList() -> [AudioObjectID] {
        var a = Self.addr(kAudioHardwarePropertyProcessObjectList)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids) == noErr else { return [] }
        return ids
    }

    /// A burst of property changes costs one read of the process list.
    private func setNeedsEvaluate() {
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    private func evaluate() {
        dirty = false
        var using: Set<String> = []
        for p in procs {
            guard Self.u32(p, kAudioProcessPropertyIsRunningInput) ?? 0 != 0 else { continue }
            if let pid = Self.pid(p), pid == me { continue }
            if let b = Self.bundle(p), !b.isEmpty { using.insert(MeetingApps.key(b)) }
        }
        guard using != last else { return }
        last = using
        onChange?(using)
    }

    private static func u32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var a = addr(sel), v: UInt32 = 0, sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v) == noErr ? v : nil
    }

    private static func pid(_ o: AudioObjectID) -> pid_t? {
        var a = addr(kAudioProcessPropertyPID), v: pid_t = 0, sz = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &v) == noErr ? v : nil
    }

    private static func bundle(_ o: AudioObjectID) -> String? {
        var a = addr(kAudioProcessPropertyBundleID), ref: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(o, &a, 0, nil, &sz, $0) }
        return st == noErr ? ref?.takeRetainedValue() as String? : nil
    }
}

// MARK: - Share test

/// island://sharetest: a dummy panel with the same protection as the island. Start a real Zoom or Meet
/// share of the whole screen: if the others can see this box, `sharingType` isn't honoured here.
enum ShareTest {
    private static var panel: NSPanel?

    static func show() {
        panel?.orderOut(nil)
        let size = NSSize(width: 360, height: 118)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = .none
        p.contentView = NSHostingView(rootView: ShareTestView { hide() }.preferredColorScheme(.dark))
        if let s = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: s.midX - size.width / 2, y: s.midY - size.height / 2))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if panel === p { hide() } }
    }

    static func hide() { panel?.orderOut(nil); panel = nil }
}

private struct ShareTestView: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(.red.opacity(0.8)).frame(width: 6, height: 6)
                Text("Share test").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                    .help("Close the share test").accessibilityLabel("Close the share test")
            }
            Text("You see this box. People in your screen share should not. If they can, use ⌃⌥H to hide Island while presenting.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 360, height: 118, alignment: .topLeading)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

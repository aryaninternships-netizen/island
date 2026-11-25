import AppKit
import Combine
import SwiftUI

// MARK: - Feature registry
//
// Every live feature (timer, recording, Guard, Claude, a download…) publishes one small snapshot.
// The hub ranks them once per runloop turn and only publishes when the ranked list really changed.
// Home shows the top cards plus a dock of toggles; the closed island shows `closedPick`.
// Adding a feature: one adapter below and one `hub.register` line in IslandModel.start().
// Main thread only: every source publishes on main, and the hub hops to main if one doesn't.

enum FeatureID: String, CaseIterable {
    case recording, guardMode, presence, faceSession, timer, claude,
         meeting, download, battery, keepAwake, quiet, pup, clipboard, tray, generic
}

enum Urgency: Int, Comparable {
    case ambient, info, live, attention, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct FeatureControl: Identifiable, Equatable {
    let id: String
    var symbol: String
    var label: String?
    /// Spoken by VoiceOver and shown as the tooltip.
    var a11y: String
    var tint: Color = .white
    var on = false
    let run: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.symbol == b.symbol && a.label == b.label && a.on == b.on && a.a11y == b.a11y
    }
}

enum FeatureTap: Equatable { case tab(IslandModel.Tab), none }

/// How a snapshot draws when it owns the closed island.
enum ClosedStyle: Equatable {
    case standard
    /// Recording: a 5 pt dim red dot and a grey elapsed time. `flash` brightens the dot after a mark.
    case rec(flash: Bool)
    /// "Record this?": a hollow red dot and the meeting title. Silent.
    case offer
}

/// What one feature shows right now. Never holds per-frame values: clocks tick in the view.
struct FeatureSnapshot: Identifiable, Equatable {
    let id: FeatureID
    var urgency: Urgency
    var since: Date
    var symbol: String
    var tint: Color
    var title: String
    var detail: String?
    var trailing: Activity.Trailing = .none
    var controls: [FeatureControl] = [] // at most 2
    var tap: FeatureTap = .none
    /// May take over the closed island (at `.live` or above).
    var closedEligible = true
    /// Drawn as a banner below the notch when it owns the closed island (presence countdown).
    var closedBanner = false
    var headerGlyph = false
    var style: ClosedStyle = .standard
    /// Beats a passing transient (volume tick) for the closed island: the consent banner.
    var pinned = false

    /// The closed island draws snapshots with the same views as activities.
    var activity: Activity {
        Activity(id: "feature-" + id.rawValue, symbol: symbol, tint: tint, title: title, body: detail ?? "",
                 trailing: trailing, banner: closedBanner)
    }
}

protocol IslandFeature: AnyObject {
    var id: FeatureID { get }
    var snapshot: FeatureSnapshot? { get }
    var dockToggle: FeatureControl? { get }
    /// Narrow publishers only (the few properties the snapshot reads).
    var changed: AnyPublisher<Void, Never> { get }
}

final class FeatureHub: ObservableObject {
    @Published private(set) var live: [FeatureSnapshot] = []
    @Published private(set) var dock: [FeatureControl] = []
    /// How many times `live` was published (debug: one per real state change).
    private(set) var publishes = 0

    private var features: [IslandFeature] = []
    private var bag: Set<AnyCancellable> = []
    private var dirty = false
    private static let order: [FeatureID: Int] =
        Dictionary(uniqueKeysWithValues: FeatureID.allCases.enumerated().map { ($1, $0) })

    func register(_ f: IslandFeature) {
        features.append(f)
        f.changed.sink { [weak self] in self?.setNeedsRecompute() }.store(in: &bag)
        setNeedsRecompute()
    }

    /// Dirty flag plus one hop to the next main runloop turn: a burst of changes costs one recompute.
    func setNeedsRecompute() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.setNeedsRecompute() }; return }
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.async { [weak self] in self?.recompute() }
    }

    private func recompute() {
        dirty = false
        let ranked = features.compactMap(\.snapshot).sorted(by: Self.ranks)
        if ranked != live {
            live = ranked
            publishes += 1
            if UserDefaults.standard.bool(forKey: "hub.debug") {
                FaceID.debug("hub: live #\(publishes) " + ranked.map { "\($0.id.rawValue):\($0.urgency.rawValue)" }.joined(separator: ","))
            }
        }
        let d = features.compactMap(\.dockToggle)
        if d != dock { dock = d }
    }

    /// Urgency, then FeatureID declaration order, then newest.
    static func ranks(_ a: FeatureSnapshot, _ b: FeatureSnapshot) -> Bool {
        if a.urgency != b.urgency { return a.urgency > b.urgency }
        let oa = order[a.id] ?? 0, ob = order[b.id] ?? 0
        if oa != ob { return oa < ob }
        return a.since > b.since
    }

    static func closedPick(_ live: [FeatureSnapshot]) -> FeatureSnapshot? {
        live.first { $0.closedEligible && $0.urgency >= .live }
    }

    var closedPick: FeatureSnapshot? { Self.closedPick(live) }
}

// MARK: - Closed island

/// What the closed island shows. One pure function decides it; size, visibility, the walk/nap
/// guards, the view and tap routing all read the same answer.
enum ClosedFace: Equatable {
    case scan
    /// A transient activity: a banner below the notch, or a compact tick (volume, charger).
    case banner(Activity)
    case compact(FeatureSnapshot)
    case dogWalk(Date)
    case media
    case nap
    case idle
    /// Panic-hide (⌃⌥H): plain notch black, nothing drawn.
    case hidden

    struct Inputs {
        var scan = false
        var hidden = false
        var transient: Activity?
        var pick: FeatureSnapshot?
        var dogWalk: Date?
        var mediaLive = false
        var napping = false
    }

    /// scan > pinned pick > hidden > transient > closedPick > dog walk > media > nap > idle.
    /// The consent banner (pinned) is mandatory, so it shows for its 4 s even under panic-hide.
    static func resolve(_ i: Inputs) -> ClosedFace {
        if i.scan { return .scan }
        // Panic-hide wins over everything pinned, the consent banner included.
        if i.hidden { return .hidden }
        if let p = i.pick, p.pinned { return .compact(p) }
        if let a = i.transient { return .banner(a) }
        if let p = i.pick { return .compact(p) }
        if let d = i.dogWalk { return .dogWalk(d) }
        if i.mediaLive { return .media }
        if i.napping { return .nap }
        return .idle
    }

    /// The activity drawn for this face (transient, or the feature drawn like one).
    var activity: Activity? {
        switch self {
        case .banner(let a): a
        case .compact(let s): s.activity
        default: nil
        }
    }

    /// Something (a transient or a live feature) holds the closed island.
    var busy: Bool { activity != nil }
}

// MARK: - Adapters

/// Turns any publisher into a bare "something changed" ping.
func ping<P: Publisher>(_ p: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
    p.map { _ in () }.eraseToAnyPublisher()
}

/// A feature made of closures over its source. Closures hold their sources weakly.
final class Feature: IslandFeature {
    let id: FeatureID
    let changed: AnyPublisher<Void, Never>
    private let make: () -> FeatureSnapshot?
    private let makeDock: () -> FeatureControl?

    init(_ id: FeatureID, changed: [AnyPublisher<Void, Never>],
         dock: @escaping () -> FeatureControl? = { nil }, snapshot: @escaping () -> FeatureSnapshot?) {
        self.id = id
        self.changed = Publishers.MergeMany(changed).eraseToAnyPublisher()
        make = snapshot
        makeDock = dock
    }

    var snapshot: FeatureSnapshot? { make() }
    var dockToggle: FeatureControl? { makeDock() }
}

/// Claude Code sessions from the hook (`claude-<sid>` ids). A killed session never sends "end",
/// so anything not heard from in 10 min is swept on the companion's minute tick.
final class ClaudeFeature: IslandFeature {
    let id = FeatureID.claude
    private struct Session { var since: Date; var seen: Date; var waiting: Bool }
    private var sessions: [String: Session] = [:]
    private let subject = PassthroughSubject<Void, Never>()
    var changed: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    static let ttl: TimeInterval = 10 * 60

    static func owns(_ id: String) -> Bool { id.hasPrefix("claude-") }

    func upsert(_ id: String, waiting: Bool) {
        let now = Date()
        sessions[id] = Session(since: sessions[id]?.since ?? now, seen: now, waiting: waiting)
        subject.send()
    }

    func remove(_ id: String) { if sessions.removeValue(forKey: id) != nil { subject.send() } }

    func sweep(now: Date = Date()) {
        let before = sessions.count
        sessions = sessions.filter { now.timeIntervalSince($0.value.seen) < Self.ttl }
        if sessions.count != before { subject.send() }
    }

    var count: Int { sessions.count }

    var snapshot: FeatureSnapshot? {
        guard let since = sessions.values.map(\.since).max() else { return nil }
        let waiting = sessions.values.contains { $0.waiting }
        let n = sessions.count
        return FeatureSnapshot(
            id: id, urgency: waiting ? .attention : .live, since: since,
            symbol: waiting ? "hand.raised.fill" : "sparkles", tint: .orange,
            title: waiting ? "Claude needs you" : "Claude is working",
            detail: n > 1 ? "\(n) sessions" : nil,
            trailing: waiting ? .none : .spinner,
            controls: [FeatureControl(id: "claude.dismiss", symbol: "xmark", a11y: "Dismiss Claude status") { [weak self] in
                guard let self, !self.sessions.isEmpty else { return }
                self.sessions.removeAll(); self.subject.send()
            }])
    }

    var dockToggle: FeatureControl? { nil }
}

/// Sticky `island://notify?sticky=1&id=foo` from scripts. Swept after 30 min.
final class GenericFeature: IslandFeature {
    let id = FeatureID.generic
    private var items: [String: (a: Activity, at: Date)] = [:]
    private let subject = PassthroughSubject<Void, Never>()
    var changed: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    static let ttl: TimeInterval = 30 * 60

    func upsert(_ a: Activity) {
        items[a.id] = (a, items[a.id]?.at ?? Date())
        subject.send()
    }

    func remove(_ id: String) { if items.removeValue(forKey: id) != nil { subject.send() } }

    func sweep(now: Date = Date()) {
        let before = items.count
        items = items.filter { now.timeIntervalSince($0.value.at) < Self.ttl }
        if items.count != before { subject.send() }
    }

    var snapshot: FeatureSnapshot? {
        guard let (key, top) = items.max(by: { ($0.value.at, $0.key) < ($1.value.at, $1.key) }) else { return nil }
        let a = top.a
        let more = items.count > 1 ? "+\(items.count - 1) more" : nil
        return FeatureSnapshot(
            id: id, urgency: .live, since: top.at, symbol: a.symbol, tint: a.tint,
            title: a.title.isEmpty ? key : a.title,
            detail: a.body.isEmpty ? more : a.body,
            trailing: a.trailing,
            controls: [FeatureControl(id: "generic.dismiss." + key, symbol: "xmark", a11y: "Dismiss \(a.title.isEmpty ? key : a.title)") { [weak self] in
                self?.remove(key)
            }],
            closedBanner: a.banner)
    }

    var dockToggle: FeatureControl? { nil }
}

extension IslandModel {
    /// Every feature that can show on Home. Order here is the dock order.
    func registerFeatures() {
        let t = timers, k = keepAwake, g = guardMode, b = battery, cal = calendar, p = pet
        let dl = downloads, lf = lockFace

        // Recording: live meeting, or an offer to record, or what's left of one (auto-stopped, crashed).
        let mm = meeting
        hub.register(Feature(.recording, changed: [
            ping(mm.$isRecording.removeDuplicates()), ping(mm.$offer.removeDuplicates()),
            ping(mm.$consent.removeDuplicates()), ping(mm.$flash.removeDuplicates()),
            ping(mm.$autoStopped.removeDuplicates()), ping(mm.$recoverable.removeDuplicates()),
            ping(mm.$session.map { $0.map(ObjectIdentifier.init) }.removeDuplicates()),
        ]) { [weak mm] in
            guard let mm else { return nil }
            if mm.isRecording, let s = mm.session {
                let start = s.recorder.start
                var f = FeatureSnapshot(
                    id: .recording, urgency: .live, since: start, symbol: "record.circle.fill", tint: .red,
                    title: "Recording", detail: s.title.isEmpty ? nil : s.title,
                    trailing: .clock(start, up: true),
                    controls: [
                        FeatureControl(id: "rec.mark", symbol: "bookmark.fill", a11y: "Mark this moment", tint: .red) { [weak mm] in mm?.mark() },
                        FeatureControl(id: "rec.stop", symbol: "stop.fill", a11y: "Stop recording", tint: .red) { [weak mm] in mm?.stop() },
                    ],
                    headerGlyph: true, style: .rec(flash: mm.flash))
                if mm.consent {
                    // Mandatory on every start: a banner nothing else can cover.
                    f.title = "Recording · let people know"
                    f.trailing = .none
                    f.closedBanner = true
                    f.pinned = true
                    f.style = .standard
                }
                return f
            }
            if let o = mm.offer {
                return FeatureSnapshot(
                    id: .recording, urgency: .live, since: o.at, symbol: "circle", tint: .red,
                    title: o.title, detail: "\(o.app) is using the mic · record?",
                    controls: [
                        FeatureControl(id: "offer.rec", symbol: "record.circle", a11y: "Record this meeting", tint: .red) { [weak mm] in mm?.acceptOffer() },
                        FeatureControl(id: "offer.no", symbol: "xmark", a11y: "Not this one") { [weak mm] in mm?.dismissOffer() },
                    ],
                    style: .offer)
            }
            if let t = mm.autoStopped {
                return FeatureSnapshot(
                    id: .recording, urgency: .info, since: .distantPast, symbol: "stop.circle", tint: .red,
                    title: "Auto-stopped", detail: t,
                    controls: [
                        FeatureControl(id: "auto.resume", symbol: "record.circle", a11y: "Resume recording", tint: .red) { [weak mm] in mm?.resumeAfterAutoStop() },
                        FeatureControl(id: "auto.ok", symbol: "xmark", a11y: "Dismiss") { [weak mm] in mm?.dismissAutoStop() },
                    ],
                    closedEligible: false)
            }
            if mm.recoverable != nil {
                return FeatureSnapshot(
                    id: .recording, urgency: .info, since: .distantPast, symbol: "arrow.uturn.backward.circle", tint: .orange,
                    title: "Recover last meeting", detail: "it never finished",
                    controls: [
                        FeatureControl(id: "recover.go", symbol: "arrow.uturn.backward", a11y: "Recover last meeting", tint: .orange) { [weak mm] in mm?.recover() },
                        FeatureControl(id: "recover.no", symbol: "xmark", a11y: "Dismiss") { [weak mm] in mm?.skipRecovery() },
                    ],
                    closedEligible: false)
            }
            return nil
        })

        // Guard.
        hub.register(Feature(.guardMode, changed: [ping(g.$shown), ping(g.$shownAway), ping($guardArmAt)], dock: { [weak self, weak g] in
            guard let g else { return nil }
            let on = g.shown != .off
            return FeatureControl(id: "dock.guard", symbol: on ? "lock.shield.fill" : "shield",
                                  a11y: on ? "Turn Guard off" : "Guard my Mac while I'm away", tint: .red, on: on) { [weak self] in self?.toggleGuard() }
        }) { [weak self, weak g] in
            guard let g, g.shown != .off else { return nil }
            let alert = g.shown == .challenged || g.shown == .alarm
            var s = FeatureSnapshot(id: .guardMode, urgency: alert ? .critical : .live, since: .distantPast,
                                    symbol: "lock.shield.fill", tint: .red, title: alert ? "Guard alert" : "Guard on",
                                    detail: "watching your Mac", trailing: .text("ON"), headerGlyph: true)
            if g.shown == .arming {
                // The walk-away countdown itself, not a spinner.
                s.tint = .yellow; s.title = "Guard arming"; s.detail = "walk away"
                s.trailing = self.map { m in m.guardArmAt.map { .clock($0, up: false) } ?? .spinner } ?? .spinner
            } else if g.shownAway, !alert {
                s.symbol = "figure.walk.departure"; s.tint = .purple; s.trailing = .text("Away")
                s.title = "Away lock"; s.detail = "your face opens it"
            }
            s.controls = [FeatureControl(id: "guard.off", symbol: "shield.slash", a11y: "Turn Guard off", tint: .red) { [weak self] in
                self?.toggleGuard()
            }]
            return s
        })

        // Presence lock: a quiet card while it watches, a compact countdown on the sides when you've gone.
        // The dock chip is Away mode: off, or back to the last mode used (Lock unless Guard was chosen).
        if let pl = presenceLock {
            hub.register(Feature(.presence, changed: [ping(pl.$status), ping(pl.$isEnabled), ping($awayMode)], dock: { [weak self] in
                guard let self else { return nil }
                let on = awayMode != .off
                return FeatureControl(id: "dock.presence", symbol: awayMode == .guardMode ? "figure.walk.departure" : "figure.stand",
                                      a11y: on ? "Locks when you walk away · turn off" : "Lock when I walk away",
                                      tint: .teal, on: on) { [weak self] in
                    guard let self else { return }
                    let last = UserDefaults.standard.string(forKey: "away.last").flatMap(AwayMode.init) ?? .lock
                    self.awayMode = self.awayMode == .off ? (last == .off ? .lock : last) : .off
                }
            }) { [weak pl] in
                guard let pl else { return nil }
                switch pl.status {
                case .warning(let left):
                    return FeatureSnapshot(
                        id: .presence, urgency: .critical, since: .distantPast, symbol: "figure.walk.departure", tint: .orange,
                        title: "Away in \(left)…", detail: "Can't see you · look at the camera or touch a key to stay",
                        trailing: .text("\(left)s"),
                        // Clicking is input: Presence's next tick (under 1 s) sees you and stands down.
                        controls: [FeatureControl(id: "presence.here", symbol: "hand.wave.fill", a11y: "I'm here", tint: .orange) {}])
                case .watching:
                    return FeatureSnapshot(id: .presence, urgency: .ambient, since: .distantPast, symbol: "figure.stand",
                                           tint: .teal, title: "Presence", detail: "locks when you leave")
                default:
                    return nil
                }
            })
        }

        // Face unlock session at the lock screen.
        hub.register(Feature(.faceSession, changed: [ping(lf.$sessionUntil)]) { [weak lf] in
            guard let lf, let u = lf.sessionUntil, u > Date() else { return nil }
            return FeatureSnapshot(
                id: .faceSession, urgency: .live, since: .distantPast, symbol: "faceid", tint: .green,
                title: "Face unlock ready", detail: "until " + (Calendar.current.isDateInToday(u) ? "" : Calendar.current.isDateInTomorrow(u) ? "tomorrow " : u.formatted(.dateTime.weekday(.abbreviated)) + " ") + u.formatted(date: .omitted, time: .shortened),
                controls: [FeatureControl(id: "face.end", symbol: "stop.fill", a11y: "End face unlock session", tint: .green) { [weak lf] in
                    lf?.endSession()
                }],
                closedEligible: false)
        })

        // Timers.
        hub.register(Feature(.timer, changed: [ping(t.$kind), ping(t.$end)]) { [weak t] in
            guard let t, let kind = t.kind else { return nil }
            let (sym, tint, title): (String, Color, String) = switch kind {
            case .timer: ("timer", .orange, "Timer")
            case .stopwatch: ("stopwatch.fill", .orange, "Stopwatch")
            case .focus: ("brain.head.profile.fill", .purple, "Focus")
            case .rest: ("cup.and.heat.waves.fill", .teal, "Break")
            }
            var c = [FeatureControl(id: "timer.stop", symbol: "stop.fill", a11y: "Stop \(title.lowercased())", tint: .red) { [weak t] in t?.stop() }]
            if t.end != nil {
                c.append(FeatureControl(id: "timer.more", symbol: "goforward.5", a11y: "Add 5 minutes", tint: tint) { [weak t] in t?.extend(minutes: 5) })
            }
            return FeatureSnapshot(id: .timer, urgency: .live, since: t.start, symbol: sym, tint: tint, title: title,
                                   trailing: .clock(t.end ?? t.start, up: t.end == nil), controls: c)
        })

        hub.register(claude)

        // Meetings: one-shot timers at -10, -1, start and end nudge the hub (no polling), so the
        // detail is a fixed time, never a countdown that would go stale.
        hub.register(Feature(.meeting, changed: [ping(cal.$items)]) { [weak self, weak cal] in
            guard let cal else { return nil }
            let now = Date()
            guard let e = cal.items.first(where: { !$0.allDay && $0.start.timeIntervalSince(now) <= 10 * 60 && $0.end > now }) else { return nil }
            var c: [FeatureControl] = []
            if let link = e.link {
                c.append(FeatureControl(id: "meeting.join", symbol: "video.fill", a11y: "Join \(e.title)", tint: .green) {
                    NSWorkspace.shared.open(link)
                })
            }
            c.append(FeatureControl(id: "meeting.notes", symbol: "record.circle", a11y: "Record this meeting", tint: .red) { [weak self] in
                self?.meeting.start()
            })
            return FeatureSnapshot(
                id: .meeting, urgency: .attention, since: e.start, symbol: e.link != nil ? "video.fill" : "calendar",
                tint: Color(nsColor: e.color), title: e.title,
                detail: e.start <= now ? "Now · until " + e.end.formatted(date: .omitted, time: .shortened)
                                       : "at " + e.start.formatted(date: .omitted, time: .shortened),
                controls: c, closedEligible: false)
        })

        // Downloads.
        hub.register(Feature(.download, changed: [ping(dl.$current)]) { [weak dl] in
            guard let c = dl?.current else { return nil }
            let url = c.url
            return FeatureSnapshot(
                id: .download, urgency: .live, since: .distantPast, symbol: "arrow.down.circle.fill", tint: .blue,
                title: c.name, detail: byteText(c.bytes), trailing: .text(byteText(c.bytes)),
                controls: [FeatureControl(id: "download.reveal", symbol: "folder", a11y: "Show in Finder", tint: .blue) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }])
        })

        // Battery: charging, or low.
        hub.register(Feature(.battery, changed: [ping(b.$level), ping(b.$charging), ping(b.$pluggedIn),
                                                  ping(b.$hasBattery), ping(b.$minutesToFull)]) { [weak b] in
            guard let b, b.hasBattery else { return nil }
            if b.charging {
                return FeatureSnapshot(id: .battery, urgency: .info, since: .distantPast, symbol: "bolt.fill", tint: .green,
                                       title: "Charging · \(b.level)%",
                                       detail: b.minutesToFull.map { "full in " + IslandModel.duration($0) }, closedEligible: false)
            }
            guard !b.pluggedIn, b.level <= 20 else { return nil }
            return FeatureSnapshot(id: .battery, urgency: .attention, since: .distantPast, symbol: "battery.25percent", tint: .red,
                                   title: "\(b.level)% battery", detail: "plug in soon", closedEligible: false)
        })

        // Keep Awake. Its own minute beat refreshes the time left.
        hub.register(Feature(.keepAwake, changed: [ping(k.objectWillChange), ping($awayMode)], dock: { [weak k] in
            guard let k else { return nil }
            return FeatureControl(id: "dock.awake", symbol: k.on ? "cup.and.heat.waves.fill" : "cup.and.saucer",
                                  a11y: k.on ? "Turn Keep Awake off" : "Keep Awake for 3 hours", tint: .orange, on: k.on) { [weak k] in
                guard let k else { return }
                k.on ? k.stop() : k.start(hours: 3)
            }
        }) { [weak self, weak k] in
            guard let k, k.on, let u = k.until else { return nil }
            // Keep Awake stands Presence down: say so, so a missing lock is never a surprise.
            let paused = (self?.awayMode ?? .off) != .off ? " · lock paused" : ""
            var c: [FeatureControl] = []
            if u != .distantFuture {
                c.append(FeatureControl(id: "awake.more", symbol: "plus", a11y: "One more hour", tint: .orange) { [weak k] in
                    guard let k, let u = k.until else { return }
                    k.start(hours: max(u.timeIntervalSinceNow, 0) / 3600 + 1)
                })
            }
            c.append(FeatureControl(id: "awake.off", symbol: "power", a11y: "Turn Keep Awake off", tint: .orange) { [weak k] in k?.stop() })
            return FeatureSnapshot(id: .keepAwake, urgency: .ambient, since: .distantPast, symbol: "cup.and.heat.waves.fill",
                                   tint: .orange, title: "Keep Awake", detail: k.leftText + paused, controls: c,
                                   closedEligible: false, headerGlyph: true)
        })

        // Quiet.
        hub.register(Feature(.quiet, changed: [ping($hush), ping(t.$kind)], dock: { [weak self] in
            guard let self else { return nil }
            return FeatureControl(id: "dock.quiet", symbol: hush ? "moon.fill" : "moon",
                                  a11y: hush ? "Turn Quiet off" : "Quiet: mute the chatty extras", tint: .purple, on: hush) { [weak self] in
                self?.hush.toggle()
            }
        }) { [weak self] in
            guard let self, quiet else { return nil }
            return FeatureSnapshot(id: .quiet, urgency: .ambient, since: .distantPast, symbol: "moon.fill", tint: .purple,
                                   title: "Quiet", detail: timers.kind == .focus ? "while you focus" : "no pup chatter or song toasts",
                                   closedEligible: false, headerGlyph: true)
        })

        // Pup: only when he needs something. Thresholds, so the minute-by-minute needs don't recompute.
        hub.register(Feature(.pup, changed: [
            ping(p.$food.map { $0 < 0.3 }.removeDuplicates()), ping(p.$fun.map { $0 < 0.35 }.removeDuplicates()), ping(p.$name),
        ]) { [weak p] in
            guard let p, p.food < 0.3 || p.fun < 0.35 else { return nil }
            let hungry = p.food < 0.3
            return FeatureSnapshot(
                id: .pup, urgency: .info, since: .distantPast, symbol: "pawprint.fill", tint: .orange,
                title: hungry ? "\(p.name) is hungry" : "\(p.name) is bored", detail: hungry ? "feed him" : "play a minute",
                controls: [
                    FeatureControl(id: "pup.feed", symbol: "fork.knife", a11y: "Feed \(p.name)", tint: .orange) { [weak p] in p?.feed() },
                    FeatureControl(id: "pup.play", symbol: "tennisball.fill", a11y: "Play with \(p.name)", tint: .orange) { [weak p] in p?.play() },
                ],
                tap: .none, closedEligible: false)
        })

        // Folded menu bar icons (the collapser is attached after start).
        hub.register(Feature(.tray, changed: [
            trayCollapser.map { c in
                c.map { Publishers.Merge(ping($0.$hiddenCount), ping($0.$isCollapsed)).eraseToAnyPublisher() } ?? ping(Just(0))
            }.switchToLatest().eraseToAnyPublisher(),
        ]) { [weak self] in
            guard let c = self?.collapser, c.isCollapsed, c.hiddenCount > 0 else { return nil }
            return FeatureSnapshot(
                id: .tray, urgency: .ambient, since: .distantPast, symbol: "menubar.rectangle", tint: .white.opacity(0.7),
                title: "\(c.hiddenCount) menu bar icon\(c.hiddenCount == 1 ? "" : "s")", detail: "folded away",
                controls: [FeatureControl(id: "tray.expand", symbol: "chevron.left", a11y: "Show folded menu bar icons") { [weak c] in c?.expand() }],
                tap: .tab(.tray), closedEligible: false)
        })

        hub.register(generic)
    }
}

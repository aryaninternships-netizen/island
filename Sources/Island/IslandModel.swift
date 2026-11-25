import AppKit
import Combine
import SwiftUI

/// Something the island shows while closed: a volume tick, a charger plug-in,
/// a track change, a pushed notification, a progress bar from a script.
struct Activity: Identifiable, Equatable {
    /// Quiet mode drops `.chatty` (pup lines, song toasts), never alerts.
    enum EventClass { case alert, chatty, ambient }

    enum Trailing: Equatable {
        case none
        case text(String)
        case meter(Double) // 0...1 bar
        case progress(Double) // 0...1 ring
        case spinner
        case clock(Date, up: Bool) // live mm:ss, counting down to / up from the date
        case battery(Int, charging: Bool)
    }

    var id: String
    var symbol: String
    var tint: Color = .white
    var title: String = ""
    var body: String = ""
    var image: NSImage?
    /// Bruno's lines are whole sentences: give them a second line instead of "…".
    var wraps: Bool { (id == "pup" || id == "dog-nudge") && title.count > 44 }
    var trailing: Trailing = .none
    /// Banner drops below the notch with title/body; otherwise it lives on the two sides.
    var banner = false
    /// Sticky activities stay until replaced or dismissed (progress, "Claude is working").
    var sticky = false
    var duration: TimeInterval = 2.2
    /// Banner shows the barking pup instead of an icon.
    var dog = false
    var dogMood: DogMood = .bark
    /// Face close-ups shown as a stack in the banner (who peeked).
    var faces: [NSImage] = []
    var eventClass: EventClass = .alert
}

final class IslandModel: ObservableObject {
    enum State { case closed, peek, open }
    enum Tab: String { case home, desk, shelf, watch, pet, tray, settings, welcome }

    @Published var state: State = .closed
    @Published var tab: Tab = .home
    /// A passing activity (volume tick, banner). Live features come from `hub` instead.
    @Published private(set) var transient: Activity?
    /// The hub's closed-island pick (published only when it changes).
    @Published private(set) var pick: FeatureSnapshot?
    /// Bumped when the transient or the picked feature changes, so SwiftUI re-animates even when an id repeats.
    @Published private(set) var activitySeq = 0
    /// Every live feature, ranked: Home cards, the dock, header glyphs and the closed island.
    let hub = FeatureHub()
    let claude = ClaudeFeature()
    let generic = GenericFeature()
    @Published var dropTargeted = false
    /// Opened with ⌃⌥Space: the panel is key, held open, and the tab bar reads at full strength.
    @Published var keyOpen = false

    let media = MediaController()
    let shelf = Shelf()
    let battery = BatteryMonitor()
    let calendar = CalendarModel()
    let pet = Pet()
    let timers = LiveTimers()
    let keepAwake = KeepAwake()
    let clipboard = ClipboardHistory()
    let weather = Weather()
    let downloads = DownloadWatcher()
    /// Stealth meeting mode. Read through the narrow sinks below (recording, hidden), never forwarded.
    let meeting = MeetingMode.shared
    @Published private(set) var recording = false
    /// Panic-hide: the closed island draws plain black.
    @Published private(set) var hidden = false
    private let brightness = BrightnessMonitor()
    /// Quiet: no pup chatter, track toasts or walk-ons. On by itself during a focus session.
    @Published var hush = UserDefaults.standard.bool(forKey: "hush") {
        didSet { UserDefaults.standard.set(hush, forKey: "hush") }
    }
    var quiet: Bool { hush || timers.kind == .focus || recording }
    /// Interruption policy: no sounds, compact banners, no chatty extras. Quiet, recording, a call
    /// holding the mic, or a calendar meeting happening right now.
    var busy: Bool {
        if quiet || meeting.session != nil || !meeting.callsOnMic.isEmpty { return true }
        let now = Date()
        return calendar.items.contains { !$0.allDay && $0.start <= now && $0.end > now }
    }
    weak var collapser: MenuBarCollapser? { didSet { trayCollapser.send(collapser) } }
    let trayCollapser = CurrentValueSubject<MenuBarCollapser?, Never>(nil)
    private(set) var presenceLock: PresenceLock?
    /// Folded menu bar icons, shown as a scrollable tray in the island.
    @Published private(set) var trayItems: [TrayItem] = []
    @Published private(set) var trayOffset: CGFloat = 0
    static let trayItemWidth: CGFloat = 68
    let brain = PupBrain()
    /// Pup asleep in the notch while you're away.
    @Published private(set) var napping = false
    private(set) var napSince: Date?
    /// True while the screen is locked or the display sleeps: continuous animations stop.
    @Published private(set) var renderPaused = false
    private var activeSince: Date?
    private var lastHungry = Date.distantPast, lastPlay = Date.distantPast
    private var lastLate = Date.distantPast, lastStretch = Date.distantPast

    @AppStorage("hoverToOpen") var hoverToOpen = true
    @AppStorage("showVolume") var showVolume = true
    @AppStorage("showBattery") var showBattery = true
    /// Duplicates the compact media sides, so off unless asked for.
    @AppStorage("showTrackToast") var showTrackToast = false
    @AppStorage("showDog") var showDog = true
    /// Random walks and dances. Event-driven pup moments (greetings, hunger) stay either way.
    @AppStorage("playful") var playful = false
    /// "off" · "alerts" (timers, meetings, Guard) · "all" (plus the pup's nudge). Busy mutes all.
    @AppStorage("sounds") var sounds = "all"
    /// Activation effect (FlairMode raw value): burst, border or off.
    @AppStorage("flair") var flairRaw = FlairMode.border.rawValue   // full-screen burst is opt-in
    /// Burst look: "auto" (per event kind), "random", or a BurstStyle raw value.
    @AppStorage("flair.style") var burstStyleRaw = "auto"
    /// Open island background: Cosmos (nebula + planet), matched to time of day and season.
    @AppStorage("bg.sky") var skyBackground = true
    /// Current border-glow flash; cleared once it has played.
    @Published private(set) var flair: FlairEvent?
    private var flairSeq = 0
    private var lastFlair = Date.distantPast
    /// Set when nothing was configured before (fresh install) and the three welcome cards are done or skipped.
    @AppStorage("onboarded") var onboarded = false
    /// Desk chips: scroll on them to change, remembered.
    @AppStorage("desk.chipA") var chipA = 5
    @AppStorage("desk.chipB") var chipB = 15

    /// What happens when you walk away. Mirrors into presence.enabled, which PresenceLock reads.
    @Published var awayMode: AwayMode = AwayMode.stored {
        didSet {
            guard awayMode != oldValue else { return }
            AwayMode.stored = awayMode
            if awayMode != .off { UserDefaults.standard.set(awayMode.rawValue, forKey: "away.last") }
            presenceLock?.enabled = awayMode != .off
            // Chosen by hand (Settings, the dock, onboarding): the camera prompt belongs to this moment.
            if awayMode != .off, !PresenceMonitor.authorized { presence.requestAccess { _ in } }
            if awayMode != .off { modeOn(.teal) }
        }
    }
    /// "Pause Island 1 h": panel hidden, presence camera and clipboard stopped, nothing shown.
    @Published private(set) var paused = false
    private var resumeWork: DispatchWorkItem?
    var onPause: ((Bool) -> Void)?
    /// ⌃⌥Space registered (false: another app owns it; Settings says so).
    var islandHotkeyOK = true
    /// Ticket shown on the arming Guard card (10 s countdown, not a spinner).
    @Published private(set) var guardArmAt: Date?
    /// Away mode Guard just armed itself (no walk-away countdown to announce).
    private var awayGuarding = false
    /// The ⌃⌥Space command bar.
    let bar = CommandBarState()
    /// Controller hooks: open held on a tab (nil keeps the tab), and the menu bar folder switch.
    var openTab: ((Tab?) -> Void)?
    var setCollapser: ((Bool) -> Void)?

    /// Set while the pet dog is crossing the island.
    @Published private(set) var dogWalkStart: Date?
    private var dogTimer: DispatchWorkItem?
    /// Set while the pup is visiting the music (dances beside the equalizer).
    @Published private(set) var dogDanceStart: Date?
    private var danceTimer: DispatchWorkItem?

    @AppStorage("sitWatch") var sitWatch = true
    @AppStorage("sitMinutes") var sitMinutes = 45
    private let presence = PresenceMonitor()
    private(set) var sittingSince: Date?
    private var lastSeenAt: Date?
    private var lastNudge: Date?
    private var screenLocked = false
    private var meetingFired: Set<String> = []
    private var meetingTimers: [Timer] = []
    let guardMode = GuardMode()
    private(set) lazy var lockFace = LockScreenUnlock(faceID: guardMode.faceID)
    var guardOn: Bool { guardMode.shown != .off }
    /// Set by the controller so model-side events (meetings) can open the island.
    var requestOpen: (() -> Void)?
    /// Open on Home without holding (a click on the recording peek).
    var requestOpenHome: (() -> Void)?

    private(set) var screenFrame: CGRect = .zero
    private(set) var notchSize = CGSize(width: 190, height: 32)
    private(set) var hasNotch = false

    let openSize = CGSize(width: 640, height: 214)
    var notchHeight: CGFloat { notchSize.height }

    private var dismissWork: DispatchWorkItem?
    private var bag: Set<AnyCancellable> = []

    init() {
        // Child objects publish on their own. IslandView, ExpandedView, NowView and NowPlayingCard
        // each observe `media` directly, so there is no forward.
    }

    func configure(screen: NSScreen) {
        screenFrame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchSize = CGSize(width: screen.frame.width - l.width - r.width, height: top)
        } else {
            hasNotch = false
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 190, height: max(24, min(menuBar, 32)))
        }
    }

    // MARK: geometry

    var compactSide: CGFloat { notchHeight + 28 }
    var mediaSide: CGFloat { notchHeight + 6 }

    /// Size of the black body (excluding the top flares).
    /// What the closed island shows. One pure function (ClosedFace.resolve) over these inputs.
    var closedFace: ClosedFace {
        ClosedFace.resolve(.init(scan: lockFace.overlay.shownInIsland, hidden: hidden, transient: transient, pick: pick,
                                 dogWalk: dogWalkStart, mediaLive: media.live, napping: napping))
    }

    /// A transient or a live feature holds the closed island (what `activity != nil` used to mean).
    var holdsClosed: Bool { transient != nil || pick != nil }

    /// Hovering the notch while recording peeks (last lines, Mark, Stop) instead of opening.
    var recPeek: Bool { state == .peek && recording && !hidden }
    /// Side width of the recording face: just room for "1:02:03".
    var recSide: CGFloat { 46 }
    var offerSide: CGFloat { 112 }

    var size: CGSize {
        if state == .open { return openSize }
        if recPeek { return CGSize(width: 420, height: notchHeight + 46) }
        var s: CGSize
        switch closedFace {
        case .scan:
            // Face unlock takes over the island: as wide as whatever it was showing, never narrower.
            s = CGSize(width: max(notchSize.width + compactSide * 2, 264), height: notchHeight + 50)
        case .banner(let a):
            s = a.banner
                ? CGSize(width: max(notchSize.width + 170, 360), height: notchHeight + 50 + (a.wraps ? 16 : 0))
                : CGSize(width: notchSize.width + compactSide * 2, height: notchHeight)
        case .compact(let f):
            switch f.style {
            case _ where f.closedBanner:
                s = CGSize(width: max(notchSize.width + 170, 360), height: notchHeight + 50)
            case .rec: s = CGSize(width: notchSize.width + recSide * 2, height: notchHeight)
            case .offer: s = CGSize(width: notchSize.width + offerSide * 2, height: notchHeight)
            case .standard: s = CGSize(width: notchSize.width + compactSide * 2, height: notchHeight)
            }
        case .hidden:
            return notchSize
        case .dogWalk:
            s = CGSize(width: notchSize.width + 2 * 64, height: notchHeight)
        case .media:
            let side = mediaSide + (dogDanceStart != nil ? 32 : 0)
            s = CGSize(width: notchSize.width + side * 2, height: notchHeight)
        case .nap:
            s = CGSize(width: notchSize.width + compactSide * 2, height: notchHeight)
        case .idle:
            s = notchSize
        }
        if state == .peek { s.width += 18; s.height += 5 }
        return s
    }

    /// Whether anything is drawn while closed (non-notch screens hide the idle pill).
    var visible: Bool {
        // Panic-hide: on a notched screen the plain black blends into the notch; elsewhere draw nothing.
        if hidden && state == .closed && closedFace == .hidden { return hasNotch }
        return hasNotch || state != .closed || closedFace != .idle
    }

    // MARK: pet dog

    /// Walk now if the island is idle; otherwise skip quietly.
    func walkDog(force: Bool = false) {
        guard dogWalkStart == nil, state == .closed, !holdsClosed, !paused,
              force || (playful && showDog && !media.live && !busy) else { return }
        dogWalkStart = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + DogWalkView.total) { [weak self] in
            self?.dogWalkStart = nil
        }
    }

    /// Pup visits while music plays: shortly after it starts, then every few minutes.
    private func scheduleDance(after t: TimeInterval) {
        danceTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.media.live else { return }
            if self.playful, self.showDog, !self.busy, !self.paused, self.state != .open {
                self.dogDanceStart = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in self?.dogDanceStart = nil }
            }
            self.scheduleDance(after: .random(in: 150...300))
        }
        danceTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    private func startRenderPause() {
        let dnc = DistributedNotificationCenter.default()
        let wsn = NSWorkspace.shared.notificationCenter
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setRenderPaused(true) }
        wsn.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setRenderPaused(true) }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setRenderPaused(false) }
        wsn.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setRenderPaused(false) }
    }

    private func setRenderPaused(_ v: Bool) { if renderPaused != v { renderPaused = v } }

    // MARK: sitting watch

    /// The sit reminder rides on Presence results (you typed, or the presence look saw you). It never
    /// opens the camera itself: with Away off there are no results, and the pup's input-based
    /// stretch line stands in.
    func startSitWatch() {
        let ws = DistributedNotificationCenter.default()
        ws.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true; self?.sittingSince = nil
        }
        ws.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.guardMode.ownerUnlocked()
        }
    }

    /// A presence result: you're at the Mac at `at`. A gap of 5 min (away, asleep, paused) restarts the sitting clock.
    private func presenceSeen(_ at: Date) {
        guard sitWatch, !screenLocked, !guardOn, !paused else { return }
        if let last = lastSeenAt, at.timeIntervalSince(last) > 300 { sittingSince = nil; lastNudge = nil }
        lastSeenAt = at
        guard let since = sittingSince else { sittingSince = at; return }
        let mins = Int(at.timeIntervalSince(since) / 60)
        guard mins >= sitMinutes, lastNudge.map({ at.timeIntervalSince($0) >= 600 }) ?? true else { return }
        lastNudge = at
        nudge(minutes: mins)
    }

    /// The sit reminder has results to work from (Away on and Presence running).
    var sitHasPresence: Bool { awayMode != .off }

    /// The pup's tiny on-device model answers in a banner (the Pet tab is gone; the command bar
    /// `b hi` reaches him).
    func chatWithPup(_ text: String) {
        brain.reply(to: text) { [weak self] l in
            guard let self else { return }
            self.show(Activity(id: "pup", symbol: "pawprint.fill", tint: .orange, title: l,
                               body: "\(self.pet.name)", banner: true, duration: 6, dog: true, dogMood: .happy))
            A11y.announce(l)
        }
    }

    func nudge(minutes: Int) {
        brain.line("stretch", String(max(1, minutes / 60))) { [weak self] l in
            self?.show(Activity(id: "dog-nudge", symbol: "pawprint.fill", tint: .orange, title: l,
                                body: "\(minutes) min in the chair · stand, stretch, water", banner: true, duration: 7, dog: true,
                                eventClass: .chatty))
            self?.play("Pop", alert: false) // never a sound mid-meeting
        }
    }

    // MARK: presence lock

    private func startPresenceLock() {
        let p = PresenceLock(faceID: guardMode.faceID)
        p.isPaused = { [weak self] in (self?.guardOn ?? false) || (self?.keepAwake.on ?? false) || (self?.paused ?? false) }
        // AwayMode decides whether Presence runs at all (presence.enabled). Same key, same lock.
        if p.enabled != (awayMode != .off) { p.enabled = awayMode != .off }
        p.seen.sink { [weak self] at in self?.presenceSeen(at) }.store(in: &bag)
        keepAwake.guardArmed = { [weak self] in self?.guardOn ?? false }
        keepAwake.onChange = { [weak self] in
            guard let self else { return }
            self.show(Activity(id: "awake", symbol: self.keepAwake.on ? "cup.and.heat.waves.fill" : "cup.and.saucer",
                               tint: .orange, trailing: .text(self.keepAwake.on ? "Awake" : "Off"), duration: 1.8))
            if self.keepAwake.on { self.modeOn(.orange) }
        }
        p.onAway = { [weak self] in
            guard let self else { return }
            self.sittingSince = nil; self.lastSeenAt = nil
            switch self.awayMode {
            case .guardMode:
                // Away mode Guard: watch, photograph and challenge, as Guard Now does. No arming walk-away delay.
                if self.guardMode.state == .off { self.awayGuarding = true; self.guardMode.arm(delay: 0) }
            default:
                let grace = UserDefaults.standard.object(forKey: "presence.grace") as? Double ?? 180
                self.guardMode.armAway(grace: grace)
            }
        }
        // The "Away in N…" countdown is the presence feature's snapshot (p.$status), not an activity.
        presenceLock = p
    }

    // MARK: menu bar tray

    func refreshTray() {
        guard let cut = collapser?.dividerCut else { trayItems = []; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = MenuBarExtras.hidden(leftOf: cut)
            DispatchQueue.main.async { [weak self] in
                self?.trayItems = items
                self?.scrollTray(0)
            }
        }
    }

    func scrollTray(_ delta: CGFloat) {
        let viewport = openSize.width - 120
        let maxOff = max(0, CGFloat(trayItems.count) * Self.trayItemWidth - viewport)
        trayOffset = min(max(trayOffset + delta, 0), maxOff)
    }

    /// Show the real icons for a moment and press the chosen one, so its own menu opens.
    func openTrayItem(_ t: TrayItem) {
        requestClose?()
        collapser?.expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            if MenuBarExtras.press(t) { return }
            if !MenuBarExtras.trusted { MenuBarExtras.askForTrust() }
            self?.show(Activity(id: "tray", symbol: "menubar.rectangle", tint: .orange, title: "\(t.name) is in the menu bar now",
                                body: MenuBarExtras.trusted ? "Click it up there" : "Allow Island in Privacy › Accessibility to open it for you",
                                banner: true, duration: 5))
        }
    }

    // MARK: pup companion

    /// The pup says something (his own tiny model) with a pose to match. Click it to open his tab.
    func pupScene(_ mood: DogMood, _ key: String, _ arg: String = "", hint: String) {
        brain.line(key, arg) { [weak self] l in
            guard let self else { return }
            self.show(Activity(id: "pup", symbol: "pawprint.fill", tint: .orange, title: l,
                               body: "\(self.pet.name) · \(hint)", banner: true, duration: 7, dog: true, dogMood: mood,
                               eventClass: .chatty))
        }
    }

    private func startCompanion() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.companionTick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.companionTick() }
    }

    /// Once a minute: update his needs, nap while you're away, and maybe come say something.
    private func companionTick() {
        // Sessions that died without saying goodbye (killed Claude, crashed script).
        claude.sweep(); generic.sweep()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        pet.tick(idle: idle)
        guard showDog, !paused else { if napping { napping = false }; return }
        let now = Date(), cal = Calendar.current
        let h = cal.component(.hour, from: now), m = cal.component(.minute, from: now)
        let weekday = (2...6).contains(cal.component(.weekday, from: now))
        let today = now.formatted(.iso8601.year().month().day())
        let d = UserDefaults.standard

        // Nap while you're away; on your return after a long nap he wakes and says hi.
        let quiet = state == .closed && !holdsClosed && dogWalkStart == nil && !media.live && !guardOn
        // No more napping pup at the notch: the pup only appears for walks, reminders and music.
        _ = quiet
        if napping && (idle < 5 || !quiet) {
            napping = false
            if idle < 5, let s = napSince, now.timeIntervalSince(s) > 20 * 60, quiet { pupScene(.happy, "greet", "back", hint: "missed you") }
            napSince = nil
        }

        if idle > 300 { activeSince = nil } else if activeSince == nil { activeSince = now }
        guard idle < 90, state == .closed, !holdsClosed, !guardOn, !napping else { return }

        if d.string(forKey: "pup.greeted") != today && h >= 5 {
            d.set(today, forKey: "pup.greeted")
            pupScene(.happy, "greet", h < 12 ? "morning" : "afternoon", hint: "good to see you")
        } else if pet.food < 0.3 && now.timeIntervalSince(lastHungry) > 45 * 60 {
            lastHungry = now
            pupScene(.hungry, "hungry", "", hint: "click → Feed")
        } else if (h == 13 || h == 20) && pet.food < 0.6 && now.timeIntervalSince(lastHungry) > 2 * 3600 {
            lastHungry = now
            pupScene(.hungry, "hungry", h == 13 ? "lunch" : "dinner", hint: "click → Feed")
        } else if weekday && ((h == 18 && m >= 30) || h == 19) && d.string(forKey: "pup.home") != today {
            d.set(today, forKey: "pup.home")
            pupScene(.alert, "home", h == 19 ? "late" : "", hint: "workday's done")
        } else if (h >= 23 || h < 4) && now.timeIntervalSince(lastLate) > 3600 {
            lastLate = now
            pupScene(.sleep, "late", h < 4 ? "2am" : "", hint: "time to rest")
        } else if !(sitWatch && sitHasPresence), let a = activeSince, now.timeIntervalSince(a) > 60 * 60, now.timeIntervalSince(lastStretch) > 60 * 60 {
            // Working a long stretch without a break: the pup asks for water and a stand-up.
            lastStretch = now
            pupScene(.bark, "stretch", String(Int(now.timeIntervalSince(a) / 3600) + 1), hint: "water break · stand a minute")
        } else if pet.fun < 0.35 && (10..<20).contains(h) && now.timeIntervalSince(lastPlay) > 2 * 3600 {
            lastPlay = now
            pupScene(.play, "play", "bored", hint: "click → Play")
        }
    }

    // MARK: meetings

    /// Exact one-shot timers at -10 min, -1 min, start and end of each event (5 s tolerance), rebuilt
    /// when the calendar changes and after wake. Nothing ticks in between.
    private func startMeetingWatch() {
        timers.$kind.removeDuplicates().dropFirst().sink { [weak self] k in
            if k == .focus { self?.modeOn(Color(red: 0.36, green: 0.36, blue: 1.0)) }
        }.store(in: &bag)
        calendar.$timed.sink { [weak self] items in self?.armMeetingTimers(items) }.store(in: &bag)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.armMeetingTimers(self.calendar.timed)
        }
    }

    private func armMeetingTimers(_ items: [CalendarModel.Item]) {
        meetingTimers.forEach { $0.invalidate() }
        meetingTimers = []
        let now = Date()
        for e in items where !e.allDay {
            for at in [e.start.addingTimeInterval(-Self.meetingLead * 60), e.start.addingTimeInterval(-60), e.start, e.end] where at > now {
                let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in self?.checkMeetings() }
                t.tolerance = 5
                RunLoop.main.add(t, forMode: .common)
                meetingTimers.append(t)
            }
        }
        hub.setNeedsRecompute()
    }

    /// Minutes before a meeting for the heads-up (Settings › Calendar: 5, 10 or 15).
    static var meetingLead: Double {
        let v = UserDefaults.standard.double(forKey: "meeting.lead")
        return v > 0 ? v : 10
    }
    /// Bruno runs out with the heads-up (Settings › Calendar).
    static var meetingPup: Bool { UserDefaults.standard.object(forKey: "meeting.pup") as? Bool ?? true }

    private func checkMeetings() {
        hub.setNeedsRecompute() // the meeting card comes and goes; publishes only if it changed
        meeting.recheck()
        let now = Date()
        // Already in the call (an app holds the mic): no chime, and never pop the island open.
        let inCall = !meeting.callsOnMic.isEmpty || recording
        if paused { return }
        for e in calendar.timed {
            let mins = e.start.timeIntervalSince(now) / 60
            // Heads-up: fires at the lead time, or late (wake from sleep, a just-added event) while
            // more than 2 min remain, once per event.
            let lead = Self.meetingLead
            if mins <= lead, mins > 2, meetingFired.insert(e.id + "-10").inserted {
                show(Activity(id: "meeting", symbol: "calendar", tint: .orange, title: e.title,
                              body: "in \(Int(mins.rounded())) min" + (e.link != nil ? " · video call" : ""),
                              trailing: .text("\(Int(mins.rounded()))m"), banner: true, duration: 8, dog: Self.meetingPup, dogMood: .alert))
                if !inCall { play("Glass", alert: true) }
            } else if mins <= 1, mins > -1, meetingFired.insert(e.id + "-1").inserted {
                show(Activity(id: "meeting", symbol: "video.fill", tint: .green, title: e.title,
                              body: e.link != nil ? "Starting now · open me to Join" : "Starting now",
                              trailing: .text("now"), banner: true, duration: 8, dog: true, dogMood: .alert))
                if !inCall { play("Glass", alert: true) }
                // T-0: show Join one click away, unheld (it folds once the pointer moves off). Never when
                // the call already holds the mic, while recording or presenting.
                if e.link != nil, !inCall, !meeting.presenting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.2) { [weak self] in
                        guard let self, self.meeting.callsOnMic.isEmpty, !self.recording, !self.meeting.presenting,
                              !self.paused, self.state != .open else { return }
                        self.requestOpenHome?()
                    }
                }
            }
        }
    }

    // MARK: guard

    func toggleGuard() {
        if guardMode.state == .off, !PresenceMonitor.authorized { presence.requestAccess { _ in } }
        guardMode.toggle()
        if guardMode.state != .off { requestClose?() }
    }

    var requestClose: (() -> Void)?

    var hasFace: Bool { guardMode.faceID.hasOwner }

    /// `armAway`: switch Away to Lock once a face is saved (onboarding). Never before: Lock without a
    /// face or camera would blur and lock every time you sit still.
    func registerFace(armAway: Bool = false) {
        guard guardMode.state == .off else {
            show(Activity(id: "face", symbol: "exclamationmark.triangle.fill", tint: .orange,
                          title: "Turn Guard off first", banner: true, duration: 3)); return
        }
        guard PresenceMonitor.authorized else {
            presence.requestAccess { [weak self] ok in
                if ok { self?.registerFace(armAway: armAway) }
                else { self?.show(Activity(id: "face", symbol: "video.slash.fill", tint: .orange,
                                           title: "Camera is off", body: "Enable it in System Settings › Privacy › Camera",
                                           banner: true, duration: 5)) }
            }
            return
        }
        // Guided: five poses without glasses, then five with them.
        EnrollWindow.shared.show(faceID: guardMode.faceID) { [weak self] ok, msg in
            if ok, armAway, self?.awayMode == .off { self?.awayMode = .lock }
            self?.show(Activity(id: "face", symbol: ok ? "faceid" : "exclamationmark.triangle.fill",
                                tint: ok ? .green : .orange, title: msg,
                                body: ok ? "Guard, away blur and lock screen know you now" : "", banner: true, duration: 4))
        }
    }

    func forgetFace() {
        guardMode.faceID.forget()
        show(Activity(id: "face", symbol: "faceid", tint: .white, title: "Face forgotten", banner: true, duration: 3))
    }

    /// "While you were away" banner with one face per distinct person Guard caught. False if nothing new.
    @discardableResult
    func showWhoPeeked() -> Bool {
        let log = GuardLog.shared
        let new = log.unseen
        guard !new.isEmpty else { return false }
        // Same person across incidents (looked, then touched) counts once: cluster by faceprint.
        var people: [(print: [Float], image: NSImage)] = []
        var unidentified: [NSImage] = []
        for e in new where e.face != nil {
            guard let img = log.thumbnail(e) else { continue }
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let face = FaceID.detectFace(CIImage(cgImage: cg)),
               let p = FaceID.printFace(CIImage(cgImage: cg), face: face) {
                if !people.contains(where: { FaceID.distance($0.print, p) <= guardMode.faceID.threshold }) {
                    people.append((p, img))
                }
            } else {
                unidentified.append(img)
            }
        }
        let faces = people.map(\.image) + unidentified
        let n = faces.count
        let title = n > 0 ? "\(n) \(n == 1 ? "person was" : "people were") at your Mac"
                          : "\(new.count) alert\(new.count == 1 ? "" : "s") while you were away"
        let looked = new.contains { $0.reason.lowercased().contains("looking") }
        let touched = new.contains { let r = $0.reason.lowercased(); return r.contains("used") || r.contains("touched") }
        let what = looked && touched ? "Looked, then touched it" : touched ? "Touched your Mac" : "Looked at your screen"
        let body = "\(what) · \(new.last!.date.formatted(date: .omitted, time: .shortened)) · open the 👁 tab"
        show(Activity(id: "guard-msg", symbol: "eye.trianglebadge.exclamationmark", tint: .orange,
                      title: title, body: body, banner: true, duration: 9, faces: Array(faces.prefix(3))))
        play("Funk", alert: true)
        return true
    }

    private func startGuard() {
        guardMode.onState = { [weak self] st, msg in
            guard let self else { return }
            // The live Guard card / closed pill comes from the hub (guardMode.$shown); these are messages.
            switch st {
            case .off:
                if !self.showWhoPeeked() {
                    self.show(Activity(id: "guard-msg", symbol: "shield.slash", tint: .green, title: msg, banner: true, duration: 3.5))
                }
            case .arming:
                self.guardArmAt = Date().addingTimeInterval(10)
                if self.awayGuarding { self.awayGuarding = false; return }
                self.show(Activity(id: "guard-msg", symbol: "lock.shield.fill", tint: .yellow, title: msg, banner: true, duration: 3))
                self.modeOn(.yellow)
            case .armed:
                break
            case .challenged:
                self.show(Activity(id: "guard-msg", symbol: "exclamationmark.shield.fill", tint: .red, title: msg,
                                   body: "Owner? Touch ID to disarm", banner: true, duration: 20, dog: true, dogMood: .angry))
            case .alarm:
                self.show(Activity(id: "guard-msg", symbol: "exclamationmark.shield.fill", tint: .red, title: msg,
                                   body: "Your face is on camera. Screen locked.", banner: true, duration: 6, dog: true, dogMood: .angry))
            }
        }
    }

    /// Wanders by every few minutes.
    private func scheduleDog() {
        dogTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.walkDog()
            self?.scheduleDog()
        }
        dogTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 180...480), execute: w)
    }

    /// Island rect in screen coordinates.
    var frameOnScreen: CGRect {
        let s = size
        return CGRect(x: screenFrame.midX - s.width / 2, y: screenFrame.maxY - s.height,
                      width: s.width, height: s.height)
    }

    var notchRectOnScreen: CGRect {
        CGRect(x: screenFrame.midX - notchSize.width / 2, y: screenFrame.maxY - notchHeight,
               width: notchSize.width, height: notchHeight)
    }

    // MARK: activities

    func show(_ a: Activity) {
        var a = a
        if paused { return }
        // Busy (quiet, recording, a call, a meeting now) drops the chatty extras, never alerts (guard,
        // meetings, timers, Claude), and folds banners into the compact sides. Guard keeps its banner.
        if busy, a.eventClass == .chatty { return }
        let spoken = a.banner
        if busy, a.banner, !a.sticky, !a.id.hasPrefix("guard") {
            a.banner = false
            a.dog = false
            if a.trailing == .none, !a.title.isEmpty, a.title.count <= 8 { a.trailing = .text(a.title) }
        }
        if a.sticky {
            // Sticky things are live features now: Claude sessions, or a script's generic card.
            if ClaudeFeature.owns(a.id) { claude.upsert(a.id, waiting: false) } else { generic.upsert(a) }
            return
        }
        setTransient(a)
        if a.banner, a.eventClass != .chatty, let st = Self.flairStyle(a) { flare(a.tint, auto: st) }
        // VoiceOver hears alert banners once (timer done, low battery, meeting soon, Guard). Never
        // during panic-hide: the call may be sharing system audio.
        if spoken, a.eventClass == .alert, !a.title.isEmpty, !meeting.presenting {
            A11y.announce(a.body.isEmpty ? a.title : a.title + ". " + a.body, high: a.dog && a.dogMood == .angry)
        }
        dismissWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.transient?.id == a.id else { return }
            self.setTransient(nil)
        }
        dismissWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + a.duration, execute: w)
    }

    /// Which burst a banner gets; nil = no effect at all. Task-done news (Claude finished, timer
    /// done, download done) stays quiet; routine Guard messages too (arming flashes as a mode switch).
    static func flairStyle(_ a: Activity) -> BurstStyle? {
        let p = { (x: String) in a.id.hasPrefix(x) }
        if p("claude") || p("timer-done") || p("downloaded") { return nil }
        if a.id == "meeting" {
            if a.symbol == "calendar" { return .shockwave }   // the heads-up before it starts
            return .aurora
        }
        if p("guard") { return a.tint == .red || a.tint == .orange ? .lightning : nil }
        if p("kavach") || p("face") { return .edge }
        if p("battery") || p("meeting-problem") { return .lightning }
        if p("pup") || p("dog") || p("reminders") { return .confetti }
        if p("note") { return .aurora }
        return .shockwave
    }

    /// A mode was switched ON (Away, Quiet, Focus, Guard, Keep Awake): shockwave in its colour.
    /// Runs even though Quiet/Focus make the island busy, since you just asked for it.
    func modeOn(_ tint: Color) { flare(tint, auto: .shockwave, modeSwitch: true) }

    /// Activation flash: the notch outline glows, and in burst mode a 1-2 s effect pours out of the
    /// notch across the whole screen. Never while busy (calls, meetings, Quiet; a mode switch excepted),
    /// presenting, or paused; Reduce Motion keeps only the border glow. At most one per 1.5 s.
    /// `auto` = this event's own style (used when the Burst style setting is Auto); `exact` overrides.
    func flare(_ tint: Color, auto: BurstStyle = .shockwave, exact: BurstStyle? = nil, modeSwitch: Bool = false,
               force: Bool = false, shareable: Bool = false) {
        let mode = FlairMode(rawValue: flairRaw) ?? .border
        guard force || (mode != .off && !paused && !meeting.presenting && (modeSwitch || !busy)) else { return }
        guard Date().timeIntervalSince(lastFlair) > 1.5 || force else { return }
        lastFlair = Date()
        let c = FlairPalette.pick(tint)
        flairSeq &+= 1
        let seq = flairSeq
        flair = FlairEvent(seq: seq, tint: Color(nsColor: c))
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchGlow.life + 0.1) { [weak self] in
            if self?.flair?.seq == seq { self?.flair = nil }
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if (mode == .burst || force), !reduce,
           let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main {
            BurstOverlay.shared.shareable = shareable
            let st = exact ?? BurstStyle.resolve(burstStyleRaw, auto: auto)
            BurstOverlay.shared.fire(style: st, tint: c, notch: notchRectOnScreen, screen: screen)
        }
    }

    func dismiss(id: String) {
        claude.remove(id)
        generic.remove(id)
        if transient?.id == id { setTransient(nil) }
    }

    private func setTransient(_ a: Activity?) {
        transient = a
        activitySeq &+= 1
    }

    /// System sounds through one gate: the Sounds setting, then busy (no sound while recording, on a
    /// call or in a meeting). Logged, so "no sound in an hour of calls" can be counted.
    func play(_ name: String, alert: Bool) {
        let allowed = sounds == "all" || (sounds == "alerts" && alert)
        let ok = allowed && !busy && !paused
        FaceID.debug("sound: \(name) \(ok ? "played" : "muted")\(busy ? " (busy)" : "")")
        if ok { NSSound(named: NSSound.Name(name))?.play() }
    }

    // MARK: scroll to adjust

    /// What the pointer rests on in the open island, for scroll-to-adjust. Plain var: no redraw.
    enum ScrollTarget { case timer, awake, chipA, chipB }
    var scrollTarget: ScrollTarget?

    func hoverScroll(_ t: ScrollTarget, _ inside: Bool) {
        if inside { scrollTarget = t } else if scrollTarget == t { scrollTarget = nil }
    }

    /// One scroll step: timer ±1 min, Keep Awake ±1 h, a Desk chip ±1 min (remembered).
    func adjust(_ t: ScrollTarget, by steps: Int) {
        switch t {
        case .timer:
            guard let end = timers.end, timers.kind != nil else { return }
            // Never scroll a countdown below a minute left.
            let mins = steps < 0 ? -min(Double(-steps), max(0, (end.timeIntervalSinceNow - 60) / 60).rounded(.down)) : Double(steps)
            if mins != 0 { timers.extend(minutes: mins) }
        case .awake:
            guard keepAwake.on, let u = keepAwake.until, u != .distantFuture else { return }
            let h = u.timeIntervalSinceNow / 3600 + Double(steps)
            if h >= 0.25 { keepAwake.start(hours: h) }
        case .chipA: chipA = min(max(chipA + steps, 1), 180)
        case .chipB: chipB = min(max(chipB + steps, 1), 180)
        }
    }

    /// Header order (also the ⌘1 to ⌘7 order): Home, Desk, then the tabs that have something, then the gear.
    var headerTabs: [Tab] {
        var t: [Tab] = [.home, .desk]
        if !shelf.items.isEmpty { t.append(.shelf) }
        if collapser != nil { t.append(.tray) }
        if !GuardLog.shared.events.isEmpty { t.append(.watch) }
        t.append(.settings)
        return t
    }

    // MARK: pause

    /// Pause Island for `hours`: panel hidden, presence camera and clipboard stopped, nothing shown.
    /// Guard, if armed, keeps watching (it is the user's explicit choice). A one-shot timer resumes.
    func pause(hours: Double?) {
        resumeWork?.cancel(); resumeWork = nil
        let on = hours != nil
        guard on != paused else { if on { scheduleResume(hours!) }; return }
        paused = on
        if on {
            requestClose?()
            setTransient(nil)
            napping = false; dogWalkStart = nil; dogDanceStart = nil
            media.stop()
            scheduleResume(hours!)
        } else {
            media.start()
        }
        clipboard.paused = on
        onPause?(on)
    }

    private func scheduleResume(_ hours: Double) {
        let w = DispatchWorkItem { [weak self] in self?.pause(hours: nil) }
        resumeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + hours * 3600, execute: w)
    }

    // MARK: wiring

    func start() {
        IslandSettings.migrate(hasFace: hasFace) // no-op: main.swift ran it before launch
        awayMode = AwayMode.stored
        media.start()
        battery.start()
        calendar.start(request: onboarded)
        startLive()
        scheduleDog()
        startSitWatch()
        startMeetingWatch()
        startCompanion()
        startPresenceLock()
        startGuard()
        meeting.banner = { [weak self] a in self?.show(a) }
        meeting.start(calendar: calendar)
        meeting.$isRecording.removeDuplicates().sink { [weak self] on in
            self?.recording = on
            // ⌃⌥R during a pause: the consent banner must be seen, so Island comes back.
            if on, self?.paused == true { self?.pause(hours: nil) }
        }.store(in: &bag)
        meeting.$presenting.removeDuplicates().sink { [weak self] on in self?.hidden = on }.store(in: &bag)
        meeting.$whisperBusy.removeDuplicates().sink { [weak self] busy in
            guard let self else { return }
            if busy != nil {
                self.show(Activity(id: "whisper", symbol: "waveform", tint: .teal, title: "Improving transcript",
                                   body: "Whisper, on this Mac", trailing: .spinner, sticky: true, eventClass: .ambient))
            } else {
                self.dismiss(id: "whisper")
            }
        }.store(in: &bag)
        meeting.$whisperDone.compactMap { $0 }.sink { [weak self] _ in
            self?.show(Activity(id: "whisper-done", symbol: "text.badge.checkmark", tint: .teal, title: "Meeting notes updated",
                                body: "Full transcript from Whisper", banner: true, duration: 5))
        }.store(in: &bag)
        registerFeatures()
        hub.$live.map(FeatureHub.closedPick).removeDuplicates().sink { [weak self] p in
            guard let self else { return }
            let bump = self.pick?.id != p?.id
            self.pick = p
            if bump { self.activitySeq &+= 1 }
        }.store(in: &bag)
        // $phase fires on willSet, so hop to the next runloop turn and read the settled value.
        lockFace.overlay.$phase
            .receive(on: DispatchQueue.main)
            .map { [weak self] _ in self?.lockFace.overlay.shownInIsland ?? false }
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        startRenderPause()
        lockFace.onUnlocked = { [weak self] in
            self?.show(Activity(id: "guard-msg", symbol: "faceid", tint: .green, title: "Unlocked by your face", banner: true, duration: 3))
        }
        // Fresh install: the welcome cards, once, a moment after launch.
        if !onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, !self.onboarded, self.state != .open else { return }
                self.openTab?(.welcome)
            }
        }
        // Anything caught while Island wasn't on screen (e.g. after a logout): say so on launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.showWhoPeeked() }
        media.$live.removeDuplicates().sink { [weak self] live in
            guard let self else { return }
            if live { self.scheduleDance(after: 3) } else { self.danceTimer?.cancel(); self.dogDanceStart = nil }
        }.store(in: &bag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.walkDog() } // hello on launch (Playful)

        media.onTrackChange = { [weak self] m in
            guard let self, self.showTrackToast, self.state != .open, m.playing else { return }
            self.show(Activity(id: "track", symbol: "music.note", tint: m.accent, title: m.title,
                               body: m.artist, image: m.artwork, trailing: .none, banner: true,
                               duration: 3.2, eventClass: .chatty))
        }

        battery.onEvent = { [weak self] level, plugged in
            guard let self, self.showBattery else { return }
            let low = !plugged && level <= 20
            if plugged {
                // Charging: a short banner with the level and time to full.
                let eta = self.battery.minutesToFull.map { " · full in " + Self.duration($0) } ?? ""
                self.show(Activity(id: "battery", symbol: "bolt.fill", tint: .green, title: "Charging",
                                   body: "\(level)%" + eta, trailing: .battery(level, charging: true), banner: true, duration: 3))
            } else {
                // Unplugging only says something when it matters (20% or less).
                guard low else { return }
                self.show(Activity(id: "battery", symbol: low ? "battery.25percent" : "powerplug",
                                   tint: low ? .red : .white, title: low ? "Low battery" : "",
                                   body: low ? "\(level)% left · plug in soon" : "",
                                   trailing: .battery(level, charging: false), banner: low, duration: low ? 5 : 2.4))
            }
        }

        let volume = VolumeMonitor()
        volume.onChange = { [weak self] v, muted in
            guard let self, self.showVolume, self.state != .open else { return }
            let sym = muted || v == 0 ? "speaker.slash.fill"
                : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            self.show(Activity(id: "volume", symbol: sym, trailing: .meter(muted ? 0 : Double(v)),
                               duration: 1.6))
        }
        volume.start()
        volumeMonitor = volume
    }

    private var volumeMonitor: VolumeMonitor?

    /// Two-finger scroll on the closed island nudges the volume.
    func nudgeVolume(_ delta: Float) { volumeMonitor?.adjust(by: delta) }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    // MARK: live activities

    private func startLive() {
        clipboard.start()
        weather.start()
        timers.onFinish = { [weak self] k in
            guard let self else { return }
            self.play(k == .rest ? "Hero" : "Glass", alert: true)
            let (title, body): (String, String) = switch k {
            case .focus: ("Focus done", "Take \(Int(LiveTimers.restMinutes)) min, stretch with \(pet.name)")
            case .rest: ("Break's over", "Ready for another round?")
            default: ("Time's up", "")
            }
            self.show(Activity(id: "timer-done", symbol: k == .focus ? "sparkles" : "bell.fill",
                               tint: .orange, title: title, body: body, banner: true, duration: 6,
                               dog: k == .focus, dogMood: .happy))
        }
        // Progress is the download feature (downloads.$current); the finished file gets a banner.
        downloads.done.sink { [weak self] url in
            self?.show(Activity(id: "downloaded", symbol: "arrow.down.circle.fill", tint: .blue, title: url.lastPathComponent,
                                body: "Downloaded · \(byteText(DownloadWatcher.size(url)))",
                                image: NSWorkspace.shared.icon(forFile: url.path), banner: true, duration: 4))
        }.store(in: &bag)
        // Not before the welcome tour: touching ~/Downloads may ask for permission, and a prompt
        // with no context on first launch looks wrong.
        if onboarded { downloads.start() }
        else {
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .compactMap { [weak self] _ in self?.onboarded }.filter { $0 }.first()
                .sink { [weak self] _ in self?.downloads.start() }.store(in: &bag)
        }
        brightness.onChange = { [weak self] v in
            guard let self, self.showVolume, self.state != .open else { return }
            self.show(Activity(id: "brightness", symbol: v < 0.5 ? "sun.min.fill" : "sun.max.fill",
                               tint: .yellow, trailing: .meter(Double(v)), duration: 1.6))
        }
        brightness.start()
    }

    /// Start recording from the notch (titled after the meeting that's on). The notes window stays shut.
    func openMeetingNotes() {
        meeting.start()
    }

    /// Every island:// URL goes through the one dispatcher (Command.swift).
    func handle(url: URL) { run(Command.parse(url: url)) }

    /// The verbs that aren't typed commands: Guard/face tools, pup and design previews. Kept in the
    /// release build on purpose (design previews use them); their menu items sit behind ⌥.
    func runVerb(_ verb: String, _ q: [String: String]) {
        switch verb {
        case "dog":
            walkDog(force: true)
        case "share": // island://share?on=1|0  (no param = flip): show the island in screen shares
            ScreenShare.visible = q["on"].map { $0 == "1" } ?? !ScreenShare.visible
        case "prompter": // island://prompter?do=start|end|toggle|roll|paste|edit
            Prompter.shared.run(q)
        case "whopeeked":
            if !showWhoPeeked() { show(Activity(id: "guard-msg", symbol: "eye.slash", title: "Nobody new has peeked", banner: true, duration: 3)) }
        case "registerface":
            registerFace()
        case "sky": // island://sky?part=night&season=summer  (preview a backdrop scene; no params = live)
            if let p = DayPart(rawValue: q["part"] ?? ""), let se = Season(rawValue: q["season"] ?? "") {
                SkyScene.override = (p, se)
            } else { SkyScene.override = nil }
            objectWillChange.send()
        case "flair": // island://flair?style=edge&color=FF9500&share=1  (preview the activation effect)
            flare(Color(hex: q["color"] ?? "") ?? .white, exact: BurstStyle(rawValue: q["style"] ?? ""),
                  force: true, shareable: q["share"] == "1")
        case "facetest":
            guardMode.faceID.selfTest { [weak self] v in
                self?.show(Activity(id: "face", symbol: "faceid", tint: .teal, title: "Face check", body: v, banner: true, duration: 6))
            }
        case "shieldtest":
            guardMode.shield.show(reason: "Shield test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.guardMode.shield.hide() }
        case "pup": // island://pup?key=hungry&arg=&mood=hungry  (testing)
            let moods: [String: DogMood] = ["hungry": .hungry, "happy": .happy, "play": .play, "sleep": .sleep, "eat": .eat,
                                            "alert": .alert, "bark": .bark, "sit": .sit]
            pupScene(moods[q["mood"] ?? ""] ?? .happy, q["key"] ?? "greet", q["arg"] ?? "", hint: q["hint"] ?? "says hi")
        case "nap":
            napping.toggle(); napSince = napping ? Date() : nil
        case "dance":
            dogDanceStart = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in self?.dogDanceStart = nil }
        case "nudge":
            nudge(minutes: Int(q["minutes"] ?? "") ?? sitMinutes)
        case "sharetest":
            ShareTest.show()
        case "facescan": // island://facescan?state=scanning|matched|failed  (preview the lock-screen animation)
            let st: FaceScanPhase = switch q["state"] ?? "scanning" {
            case "matched": .matched(Pet.owner)
            case "failed": .failed("Use Touch ID or your password")
            case "hide": .hidden
            default: .scanning
            }
            lockFace.overlay.set(st, locked: false)
            if st == .scanning { // fake the recognition climbing, for the preview
                for (i, v) in [0.22, 0.38, 0.54, 0.7, 1.0].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(i + 1)) { [weak self] in
                        self?.lockFace.overlay.update(progress: v, hint: i == 3 ? "Blink once" : nil)
                        var tm = ScanTelemetry()
                        tm.match = [0.51, 0.34, 0.27, 0.24, 0.23][i]; tm.votes = min(i, 3); tm.frames = 40 * (i + 1)
                        tm.life = i >= 4 ? "BLINK" : "—"
                        self?.lockFace.overlay.update(telemetry: tm)
                    }
                }
            }
        case "lockface":
            LockFaceWindow.shared.show(lockFace)
        case "away": // island://away?grace=30  (try the presence soft lock now)
            guardMode.armAway(grace: Double(q["grace"] ?? "") ?? 180)
        case "transcribetest": // island://transcribetest?file=/path.aiff
            MeetingRecorder.transcribeTest(URL(fileURLWithPath: q["file"] ?? ""), mode: q["mode"] ?? "live",
                                           speed: Double(q["speed"] ?? "") ?? 1) { [weak self] r in
                try? r.write(to: FaceID.file.deletingLastPathComponent().appendingPathComponent("transcribe-test.txt"), atomically: true, encoding: .utf8)
                self?.show(Activity(id: "face", symbol: "waveform", tint: .teal, title: "Transcribe test",
                                    body: String(r.prefix(80)), banner: true, duration: 8))
            }
        default:
            break
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            let named: [String: Color] = ["orange": .orange, "green": .green, "red": .red, "blue": .blue,
                                          "yellow": .yellow, "purple": .purple, "pink": .pink, "teal": .teal]
            guard let c = named[s.lowercased()] else { return nil }
            self = c
            return
        }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Borderless non-activating panel pinned over the notch. Clicks pass through
/// while closed (ignoresMouseEvents); hover/click/drag are read from global
/// event monitors, which need no Accessibility permission for mouse events.
final class IslandPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        // Never in a screen share or recording (Zoom, Meet, QuickTime). Panic-hide covers capture paths that ignore it.
        // debug.capturable (defaults write): lets screencapture see the island for design checks only.
        sharingType = ScreenShare.type
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Stealth by default: the island never appears in a screen share or recording. Settings ›
/// "Show in screen share" (or the menu bar item) lets others see it. The teleprompter stays hidden
/// either way. debug.capturable (defaults write): same, for design checks.
enum ScreenShare {
    static let key = "share.visible"
    static let changed = Notification.Name("Island.screenShareVisibility")
    static var visible: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key); NotificationCenter.default.post(name: changed, object: nil) }
    }
    static var type: NSWindow.SharingType {
        visible || UserDefaults.standard.bool(forKey: "debug.capturable") ? .readOnly : .none
    }
}

final class IslandController {
    let model = IslandModel()
    private var panel: IslandPanel?
    private var monitors: [Any] = []
    private var bag: Set<AnyCancellable> = []
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    /// Opened from a URL/script: stay open until clicked away, ignore hover-out.
    private var held = false
    /// ⌃⌥T is held: peek stays until the key comes up, wherever the pointer is.
    private var peekHeld = false
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    /// ⌃⌥Space made the panel key: the app to hand focus back to on close.
    private var previousApp: NSRunningApplication?
    /// Held open (URL, meeting, tray) with the pointer elsewhere: let go after 8 s. One-shot.
    private var releaseWork: DispatchWorkItem?
    /// Fine trackpad scroll adds up to one step per 14 pt.
    private var scrollAcc: CGFloat = 0

    private let canvas = CGSize(width: 760, height: 300)

    func start() {
        layout()
        model.requestOpen = { [weak self] in
            guard let self, self.model.state != .open else { return }
            self.model.tab = .home
            self.open(hold: true)
        }
        model.requestClose = { [weak self] in self?.close() }
        model.openTab = { [weak self] t in
            guard let self else { return }
            if let t { self.model.tab = t }
            self.open(hold: true)
        }
        model.onPause = { [weak self] on in
            guard let self, let p = self.panel else { return }
            if on { p.orderOut(nil) } else { p.orderFrontRegardless() }
        }
        model.requestOpenHome = { [weak self] in
            guard let self else { return }
            self.model.tab = .home
            self.open()
        }
        model.start()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &bag)

        model.$state.removeDuplicates().sink { [weak self] s in
            guard let self else { return }
            if s == .peek, !self.model.recording { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            if s == .open { self.model.calendar.reload() }
        }.store(in: &bag)
        // Clickable while open, and while peeking at a recording (Mark / Stop live there).
        model.$state.combineLatest(model.$recording)
            .map { s, rec in !(s == .open || (s == .peek && rec)) }
            .removeDuplicates()
            .sink { [weak self] ignore in self?.panel?.ignoresMouseEvents = ignore }
            .store(in: &bag)
        registerHotkeys()
        // Keys only reach Island while ⌃⌥Space has keyed the panel: Esc closes, 1 to 6 pick a tab.
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.keyDown(e) ?? e
        }) { monitors.append(k) }
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] n in
                guard let self, let p = self.panel, n.object as? NSWindow === p, self.model.keyOpen else { return }
                // Focus went elsewhere (Cmd-Tab, a click on another app): fold, don't steal it back.
                self.previousApp = nil
                if self.model.state == .open { self.close() } else { self.model.keyOpen = false }
            }
            .store(in: &bag)

        // Two-finger scroll on the menu bar strip right of the notch opens + scrolls the icon tray.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in self?.scrolled(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            self?.scrolled(e); return e
        }) { monitors.append(l) }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.handle(e); return e
        }) { monitors.append(l) }
    }

    /// Prefer the built-in (notched) display; fall back to the main screen.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let screen = targetScreen else { return }
        model.configure(screen: screen)
        let f = CGRect(x: screen.frame.midX - canvas.width / 2, y: screen.frame.maxY - canvas.height,
                       width: canvas.width, height: canvas.height)
        if panel == nil {
            let p = IslandPanel(frame: f)
            let host = NSHostingView(rootView: IslandView(m: model, media: model.media))
            host.sizingOptions = []
            p.contentView = host
            p.orderFrontRegardless()
            panel = p
            NotificationCenter.default.addObserver(forName: ScreenShare.changed, object: nil, queue: .main) { [weak p] _ in
                p?.sharingType = ScreenShare.type
            }
        } else {
            panel?.setFrame(f, display: true)
        }
    }

    // MARK: mouse

    private func handle(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        switch e.type {
        case .mouseMoved: moved(p)
        case .leftMouseDown:
            // A click inside the recording peek belongs to its buttons (or its own tap-to-open).
            if model.recPeek, let panel, e.window === panel { return }
            down(p)
        case .leftMouseDragged: dragged(p)
        case .leftMouseUp:
            // Drag finished: remember the pasteboard so stale file types can't re-trigger the shelf.
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            if model.state == .open, !openArea.contains(p), closeWork == nil { scheduleClose(after: 0.4) }
        default: break
        }
    }

    /// Menu bar to the right of the notch, where the folded icons live.
    private var menuStrip: CGRect {
        let n = model.notchRectOnScreen
        return CGRect(x: n.maxX, y: model.screenFrame.maxY - 32, width: model.screenFrame.maxX - n.maxX, height: 32)
    }

    private func scrolled(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        // Closed island under the pointer: two-finger scroll is a volume knob.
        if model.state != .open, hotArea.contains(p) {
            let d = Float(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 400 : e.scrollingDeltaY / 30)
            if abs(d) > 0.001 { model.nudgeVolume(d) }
            return
        }
        // Open, over a timer/Awake card or a Desk chip: scroll changes the amount.
        if model.state == .open, let target = model.scrollTarget, openArea.contains(p) {
            let precise = e.hasPreciseScrollingDeltas
            let dy = e.scrollingDeltaY
            var steps = 0
            if precise {
                scrollAcc += dy
                steps = Int(scrollAcc / 14)
                scrollAcc -= CGFloat(steps) * 14
            } else if dy != 0 { steps = dy > 0 ? 1 : -1 }
            if steps != 0 { model.adjust(target, by: steps) }
            return
        }
        let onStrip = menuStrip.contains(p)
        let inTray = model.state == .open && model.tab == .tray && openArea.contains(p)
        guard onStrip || inTray, model.collapser != nil else { return }
        if onStrip && !(model.state == .open && model.tab == .tray) {
            model.tab = .tray
            model.refreshTray()
            open(hold: true)
        }
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
        model.scrollTray(-(e.scrollingDeltaY + e.scrollingDeltaX) * k)
        closeWork?.cancel(); closeWork = nil
    }

    private var hotArea: CGRect {
        // Generous target around the notch, flush with the top edge.
        model.notchRectOnScreen.union(model.frameOnScreen).insetBy(dx: -8, dy: -6)
            .offsetBy(dx: 0, dy: 3)
    }

    private var openArea: CGRect {
        model.frameOnScreen.insetBy(dx: -24, dy: -22).offsetBy(dx: 0, dy: 11)
    }

    private func moved(_ p: CGPoint) {
        switch model.state {
        case .closed:
            guard !model.hidden, hotArea.contains(p) else { return }
            withAnimation(spring) { model.state = .peek }
            // Recording: hover only peeks; a click opens Home.
            if model.hoverToOpen, !model.recording { scheduleOpen(after: 0.22) }
        case .peek:
            if !peekHeld, !hotArea.contains(p) {
                openWork?.cancel()
                withAnimation(spring) { model.state = .closed }
            }
        case .open:
            if held && model.tab == .tray {
                // Tray opened from the menu bar: stay while the pointer is on the strip or the island.
                if openArea.contains(p) || menuStrip.contains(p) { closeWork?.cancel(); closeWork = nil }
                else if closeWork == nil { scheduleClose(after: 0.6) }
                return
            }
            if held {
                // Pointer back on the island cancels the release; leaving it starts the 8 s again.
                if openArea.contains(p) { releaseWork?.cancel(); releaseWork = nil } else if releaseWork == nil { armRelease() }
                return
            }
            if openArea.contains(p) { closeWork?.cancel(); closeWork = nil } else if closeWork == nil {
                scheduleClose(after: 0.35)
            }
        }
    }

    private func down(_ p: CGPoint) {
        switch model.state {
        case .closed, .peek:
            if hotArea.contains(p) { open() }
        case .open:
            if !openArea.contains(p) { close() }
        }
    }

    private func dragged(_ p: CGPoint) {
        // Only file drags (drag pasteboard changed + carries file URLs) pop the shelf.
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragChangeCount,
              pb.types?.contains(.fileURL) == true else { return }
        let zone = CGRect(x: model.screenFrame.midX - 200, y: model.screenFrame.maxY - 60, width: 400, height: 60)
        if model.state != .open, zone.contains(p) {
            model.tab = .shelf
            open()
        }
        if model.state == .open { closeWork?.cancel(); closeWork = nil }
    }

    /// Spring by default, a short ease under Reduce Motion.
    private var spring: Animation { A11y.motion(.spring(response: 0.42, dampingFraction: 0.78)) }

    private func scheduleOpen(after t: TimeInterval) {
        openWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .peek else { return }
            self.open()
        }
        openWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    private func scheduleClose(after t: TimeInterval) {
        closeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            if self.model.dropTargeted { return }
            let p = NSEvent.mouseLocation
            if self.held && self.model.tab == .tray && self.menuStrip.contains(p) { return }
            if !self.openArea.contains(p) { self.close() }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    // MARK: hotkeys

    /// ⌃⌥R start/stop · ⌃⌥M mark · ⌃⌥T hold to peek · ⌃⌥H panic-hide. Carbon hot keys: no permission,
    /// the keystroke never reaches the meeting app, and Island never activates.
    private func registerHotkeys() {
        let mods = Hotkeys.control | Hotkeys.option
        let mm = model.meeting
        Hotkeys.shared.register(HotkeyID.record, key: Hotkeys.key("r"), mods: mods) { mm.toggle() }
        Hotkeys.shared.register(HotkeyID.mark, key: Hotkeys.key("m"), mods: mods) { mm.mark() }
        Hotkeys.shared.register(HotkeyID.hide, key: Hotkeys.key("h"), mods: mods) { [weak self] in
            mm.presenting.toggle()
            if mm.presenting, let self, self.model.state != .closed { self.close() }
        }
        // ⌃⌥Space: open Home and take the keyboard. The only path that makes the panel key, so hover
        // never steals focus mid-call. Never reveals the island while panic-hide is on.
        model.islandHotkeyOK = Hotkeys.shared.register(HotkeyID.island, key: Hotkeys.key("space"), mods: mods) { [weak self] in
            guard let self else { return }
            if self.model.state == .open, self.model.keyOpen { self.close(); return }
            guard !mm.presenting, !self.model.hidden else { return }
            if self.model.paused { self.model.pause(hours: nil) } // the shortcut also ends a pause
            self.openByKeyboard()
        }
        // ⌃⌥P: teleprompter on/off (its own ⌃⌥O and arrows register only while it's on).
        Hotkeys.shared.register(HotkeyID.prompter, key: Hotkeys.key("p"), mods: mods) { Prompter.shared.toggle() }
        // ⌃⌥G: Guard now (arms with the 10 s walk-away; again turns it off).
        Hotkeys.shared.register(HotkeyID.guardNow, key: Hotkeys.key("g"), mods: mods) { [weak self] in
            self?.model.run(.guardNow)
        }
        Hotkeys.shared.register(HotkeyID.peek, key: Hotkeys.key("t"), mods: mods, down: { [weak self] in
            guard let self, self.model.state == .closed, !self.model.hidden else { return }
            self.peekHeld = true
            self.openWork?.cancel()
            withAnimation(self.spring) { self.model.state = .peek }
        }, up: { [weak self] in
            guard let self, self.peekHeld else { return }
            self.peekHeld = false
            if self.model.state == .peek, !self.hotArea.contains(NSEvent.mouseLocation) {
                withAnimation(self.spring) { self.model.state = .closed }
            }
        })
    }

    func open(hold: Bool = false) {
        guard !model.paused else { return }
        held = hold
        peekHeld = false
        openWork?.cancel()
        if hold { armRelease() }
        // Clicking the pup (talking or napping) opens his tab; a feature may name its own tab.
        let pup = model.transient.map { $0.id == "pup" || $0.id == "dog-nudge" } ?? false
        if !model.onboarded, model.state != .open {
            model.tab = .welcome // first run: the welcome cards until done or skipped
        } else if pup || model.napping {
            model.tab = .home // no pup tab any more: his feed/play controls live on Home
        } else if model.transient == nil, case .tab(let t)? = model.pick?.tap {
            model.tab = t
        }
        withAnimation(spring) { model.state = .open }
    }

    /// Open held on Home, activate Island and key the panel so VoiceOver and the keyboard land in it.
    private func openByKeyboard() {
        guard let panel else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let wasOpen = model.state == .open
        model.keyOpen = true
        open(hold: true)
        if !wasOpen || model.tab != .home { model.tab = .home } // always lands on the command bar
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        model.bar.focusSeq &+= 1
        A11y.announce("Island open. Type a command, then Return. Escape closes, Command 1 to 7 switch tabs.")
    }

    /// Esc closes; 1 to 6 switch tabs (header order) unless a text field is being typed in.
    private func keyDown(_ e: NSEvent) -> NSEvent? {
        guard model.keyOpen, model.state == .open, let panel, e.window === panel else { return e }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if e.keyCode == 53, mods.isEmpty { // Esc: clear the command line first, then close
            if !model.bar.text.isEmpty { model.bar.text = ""; return nil }
            close(); return nil
        }
        let typing = panel.firstResponder is NSText
        // Plain digits pick a tab unless a field has the keyboard (the command bar takes "25"); ⌘digit always does.
        guard mods == [.command] || (mods.isEmpty && !typing) else { return e }
        let order = model.headerTabs
        if let c = e.charactersIgnoringModifiers, let n = Int(c), (1...order.count).contains(n) {
            let t = order[n - 1]
            if t == .tray { model.refreshTray() }
            model.tab = t
            if t == .home { model.bar.focusSeq &+= 1 }
            return nil
        }
        return e
    }

    /// Held open with the pointer away: release after 8 s (never when ⌃⌥Space has the keyboard).
    private func armRelease() {
        releaseWork?.cancel(); releaseWork = nil
        guard held, !model.keyOpen, model.tab != .welcome, !openArea.contains(NSEvent.mouseLocation) else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.releaseWork = nil
            guard self.held, !self.model.keyOpen, self.model.state == .open, self.model.tab != .welcome,
                  !self.model.dropTargeted else { return }
            let p = NSEvent.mouseLocation
            if self.openArea.contains(p) || (self.model.tab == .tray && self.menuStrip.contains(p)) { return }
            self.close()
        }
        releaseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    func close() {
        releaseWork?.cancel(); releaseWork = nil
        model.bar.text = ""
        model.scrollTarget = nil
        held = false
        if model.keyOpen {
            model.keyOpen = false
            // Hand focus back to whatever was in front before ⌃⌥Space.
            if let app = previousApp { app.activate() } else { NSApp.deactivate() }
            previousApp = nil
        }
        closeWork?.cancel(); closeWork = nil
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        withAnimation(spring) {
            model.state = .closed
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.model.state == .closed { self?.model.tab = .home }
        }
    }
}

import AppKit

/// Folds menu bar icons into a "+N" pill (the Hidden Bar technique, no permissions needed).
///
///   [ hidden icons … ] │ [+N] [ always-visible icons … ] clock
///
/// Everything left of the divider is collapsed: the divider grows to 10,000 pt and pushes
/// those icons off-screen. Click the pill to show them; they fold back 15 s later once the
/// pointer leaves the menu bar. ⌘-drag the divider (while expanded) to choose what folds.
final class MenuBarCollapser: NSObject, ObservableObject {
    private let toggle: NSStatusItem
    private let divider: NSStatusItem
    private var hidden = 0
    private var autoCollapse: Timer?
    private let d = UserDefaults.standard

    private(set) var collapsed: Bool {
        get { d.object(forKey: "mb.collapsed") as? Bool ?? true }
        set { d.set(newValue, forKey: "mb.collapsed") }
    }
    /// For the island: icons folded right now (0 while expanded), published only on change.
    @Published private(set) var hiddenCount = 0
    @Published private(set) var isCollapsed = true

    override init() {
        // First run: start the divider just left of the system icons (Wi-Fi … clock), so app icons fold.
        Self.seedPositions()
        toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        divider = NSStatusBar.system.statusItem(withLength: 10)
        super.init()
        toggle.autosaveName = "island.mb.toggle"
        divider.autosaveName = "island.mb.divider"
        if let b = toggle.button {
            b.target = self; b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "Show hidden menu bar icons"
        }
        if let b = divider.button {
            b.image = Self.bar(); b.toolTip = "⌘-drag me: icons to my left fold into the +N pill"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    /// Left edge of the divider: icons left of this are the folded ones.
    var dividerCut: CGFloat? { divider.button?.window?.frame.minX }

    /// Take both items out of the menu bar (when the feature is switched off).
    func remove() {
        autoCollapse?.invalidate()
        NSStatusBar.system.removeStatusItem(toggle)
        NSStatusBar.system.removeStatusItem(divider)
    }

    /// Count once the menu bar is actually visible (a full-screen app hides it), then apply.
    private func refresh() {
        if let n = countLeftOfDivider() { hidden = n; apply() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() } }
    }

    // MARK: actions

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        collapsed ? expand() : collapse()
    }

    func expand() {
        collapsed = false
        apply()
        // Fold back 15 s later, but not while the pointer is up in the menu bar.
        autoCollapse?.invalidate()
        var waited = 0.0
        autoCollapse = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if let n = self.countLeftOfDivider() { self.hidden = n; self.apply() }
            let top = (NSScreen.main?.frame.maxY ?? 0) - NSEvent.mouseLocation.y
            waited = top < 30 ? 0 : waited + 1
            if waited >= 15 && self.d.object(forKey: "mb.autoCollapse") as? Bool ?? true { t.invalidate(); self.collapse() }
        }
        autoCollapse?.tolerance = 0.3
    }

    func collapse() {
        autoCollapse?.invalidate()
        if let n = countLeftOfDivider() { hidden = n } // count while the icons are still on screen
        collapsed = true
        apply()
        if hidden == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() } }
    }

    private func apply() {
        if collapsed && hidden > 0 {
            divider.length = 10_000
            toggle.button?.image = Self.pill("+\(hidden)")
        } else {
            divider.length = collapsed ? 0 : 10 // nothing to fold: keep the bar clean
            toggle.button?.image = collapsed ? Self.pill("+0")
                : NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: "Collapse")
        }
        divider.button?.image = collapsed ? nil : Self.bar()
        if isCollapsed != collapsed { isCollapsed = collapsed }
        if hiddenCount != hidden { hiddenCount = hidden }
    }

    private func showMenu() {
        let m = NSMenu()
        let auto = NSMenuItem(title: "Fold Back Automatically", action: #selector(flipAuto), keyEquivalent: "")
        auto.target = self
        auto.state = (d.object(forKey: "mb.autoCollapse") as? Bool ?? true) ? .on : .off
        m.addItem(auto)
        let how = NSMenuItem(title: "Choose icons: ⌘-drag the │ divider", action: nil, keyEquivalent: "")
        how.isEnabled = false
        m.addItem(how)
        toggle.menu = m
        toggle.button?.performClick(nil)
        toggle.menu = nil
    }

    @objc private func flipAuto() {
        d.set(!(d.object(forKey: "mb.autoCollapse") as? Bool ?? true), forKey: "mb.autoCollapse")
    }

    // MARK: counting

    /// Menu bar icons whose window sits left of the divider (all extras are layer-25 windows).
    /// nil when it can't tell right now (menu bar hidden by a full-screen app, or icons already folded).
    private func countLeftOfDivider() -> Int? {
        guard let dw = divider.button?.window, let tw = toggle.button?.window, !collapsed || dw.frame.width < 100 else {
            return nil
        }
        let cut = dw.frame.minX
        let mine = [dw.frame, tw.frame].map(\.minX)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard list.contains(where: { ($0[kCGWindowLayer as String] as? Int) == 25 }) else { return nil }
        return list.filter { w in
            guard (w[kCGWindowLayer as String] as? Int) == 25, let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let wd = b["Width"], let y = b["Y"], y < 40, wd < 300 else { return false }
            return x + wd <= cut + 1 && !mine.contains { abs($0 - x) < 1 }
        }.count
    }

    // MARK: placement

    /// macOS remembers status item spots as "NSStatusItem Preferred Position <autosaveName>"
    /// (points from the right edge). Seed them once so the divider lands left of the system icons.
    private static func seedPositions() {
        let d = UserDefaults.standard
        guard d.object(forKey: "NSStatusItem Preferred Position island.mb.divider") == nil else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let xs = list.compactMap { w -> CGFloat? in
            guard (w[kCGWindowLayer as String] as? Int) == 25, let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let y = b["Y"], y < 40 else { return nil }
            return b["X"]
        }.sorted(by: >)
        let right = NSScreen.main?.frame.maxX ?? 1470
        // Rightmost five extras are the system ones (clock, Siri, Control Center, Spotlight, Wi-Fi).
        let edge = xs.count >= 5 ? xs[4] : right - 260
        let fromRight = right - edge
        d.set(fromRight + 2, forKey: "NSStatusItem Preferred Position island.mb.toggle")
        d.set(fromRight + 40, forKey: "NSStatusItem Preferred Position island.mb.divider")
    }

    // MARK: drawing

    /// "+N" punched out of a rounded pill, as a template image (follows light/dark menu bar).
    private static func pill(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let ts = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(width: ceil(ts.width) + 12, height: 16)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            (text as NSString).draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2 + 0.5), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func bar() -> NSImage {
        let img = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { r in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

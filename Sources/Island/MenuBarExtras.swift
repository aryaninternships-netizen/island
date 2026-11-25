import AppKit
import ApplicationServices

/// A menu bar icon that's folded away, shown in the island's tray.
struct TrayItem: Identifiable, Equatable {
    let id: String // "<pid>-<index>"
    let pid: pid_t
    let index: Int
    let name: String
    let icon: NSImage

    static func == (a: TrayItem, b: TrayItem) -> Bool { a.id == b.id }
}

/// Reads other apps' menu bar icons through Accessibility ("AXExtrasMenuBar"), which works on
/// macOS 26 where every icon is drawn by Control Centre. Pressing one needs Accessibility trust.
enum MenuBarExtras {
    /// System icons always stay visible, never listed.
    private static let system: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight"]

    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Every app icon whose right edge is left of `cut` (the collapser's divider), left to right.
    static func hidden(leftOf cut: CGFloat) -> [TrayItem] {
        all().filter { $0.frame.maxX <= cut + 1 && $0.frame.width < 200 }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.item)
    }

    /// Open the icon's menu (the icon has to be on screen first, see MenuBarCollapser.expand).
    @discardableResult
    static func press(_ t: TrayItem) -> Bool {
        guard let e = all().first(where: { $0.item.id == t.id })?.element else { return false }
        return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    private static func all() -> [(item: TrayItem, element: AXUIElement, frame: CGRect)] {
        var out: [(TrayItem, AXUIElement, CGRect)] = []
        for app in NSWorkspace.shared.runningApplications {
            if let b = app.bundleIdentifier, system.contains(b) { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.15)
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { continue }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
                  let items = kids as? [AXUIElement] else { continue }
            let mine = app.processIdentifier == getpid()
            for (i, el) in items.enumerated() {
                let f = frame(el)
                var desc: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &desc)
                let label = (desc as? String).flatMap { $0.isEmpty ? nil : $0 }
                // Island's own collapser pieces (divider, pill) aren't icons; keep only its main menu.
                if mine && label != "Island" { continue }
                let friendly = ["TextInputMenuAgent": "Keyboard", "Duo Desktop": "Duo"]
                let name = label ?? app.localizedName.map { friendly[$0] ?? $0 } ?? "App"
                let icon = mine ? Self.islandIcon : (app.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: name)!)
                out.append((TrayItem(id: "\(app.processIdentifier)-\(i)", pid: app.processIdentifier, index: i, name: name, icon: icon), el, f))
            }
        }
        return out
    }

    /// Island has no app icon of its own: a capsule glyph on a dark tile.
    private static let islandIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            NSColor(white: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14).fill()
            let cfg = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold).applying(.init(paletteColors: [.white]))
            if let g = NSImage(systemSymbolName: "capsule.portrait.tophalf.filled", accessibilityDescription: "Island")?.withSymbolConfiguration(cfg) {
                g.draw(in: NSRect(x: (r.width - g.size.width) / 2, y: (r.height - g.size.height) / 2, width: g.size.width, height: g.size.height))
            }
            return true
        }
        img.accessibilityDescription = "Island"
        return img
    }()

    private static func frame(_ el: AXUIElement) -> CGRect {
        var p: CFTypeRef?, s: CFTypeRef?
        var pt = CGPoint.zero, sz = CGSize.zero
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success, let p { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success, let s { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
        return CGRect(origin: pt, size: sz)
    }
}

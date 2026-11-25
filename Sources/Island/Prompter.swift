import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// Teleprompter: the script scrolls in a black pane hanging from the notch, so your eyes sit next
// to the camera while you read. Never in a screen share (sharingType .none), never takes focus.
//   ⌃⌥P start/end · ⌃⌥O pause/roll · ⌃⌥↓ faster · ⌃⌥↑ slower (arrows only while on)
//   click = pause/roll · scroll wheel = move by hand · hover = controls
// Script: ~/Library/Application Support/Island/prompter.txt (re-read on every start), or paste from the
// clipboard (hover button, island://prompter?do=paste).

extension HotkeyID {
    static let prompter: UInt32 = 20 // ⌃⌥P
    static let prompterRoll: UInt32 = 21 // ⌃⌥O
    static let prompterFaster: UInt32 = 22 // ⌃⌥↓
    static let prompterSlower: UInt32 = 23 // ⌃⌥↑
}

final class Prompter: ObservableObject {
    static let shared = Prompter()

    /// Not ~/Documents: reading there blocks the main thread on a TCC prompt.
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Island")
    static let file = folder.appendingPathComponent("prompter.txt")

    @Published private(set) var on = false
    @Published var rolling = false
    @Published var offset: CGFloat = 0
    @Published var text = ""
    /// Points per second.
    @Published var speed: Double = UserDefaults.standard.object(forKey: "prompter.speed") as? Double ?? 32 {
        didSet { UserDefaults.standard.set(speed, forKey: "prompter.speed") }
    }
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "prompter.font") as? Double ?? 19 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "prompter.font") }
    }
    /// Script height minus the visible window, measured by the view.
    var maxOffset: CGFloat = .greatestFiniteMagnitude

    private var panel: NSPanel?
    private var tick: Timer?
    private var last = Date()

    static let size = CGSize(width: 600, height: 170)

    func toggle() { on ? end() : start() }

    func start() {
        load()
        offset = 0
        rolling = false
        on = true
        let p = panel ?? make()
        position(p)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        let mods = Hotkeys.control | Hotkeys.option
        Hotkeys.shared.register(HotkeyID.prompterRoll, key: Hotkeys.key("o"), mods: mods) { [weak self] in self?.roll() }
        Hotkeys.shared.register(HotkeyID.prompterFaster, key: kVK_DownArrow, mods: mods) { [weak self] in self?.nudge(+6) }
        Hotkeys.shared.register(HotkeyID.prompterSlower, key: kVK_UpArrow, mods: mods) { [weak self] in self?.nudge(-6) }
        last = Date()
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
    }

    func end() {
        on = false
        rolling = false
        tick?.invalidate(); tick = nil
        [HotkeyID.prompterRoll, HotkeyID.prompterFaster, HotkeyID.prompterSlower].forEach { Hotkeys.shared.unregister($0) }
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    func roll() {
        if offset >= maxOffset { offset = 0 } // at the end, roll again from the top
        rolling.toggle()
    }

    func nudge(_ d: Double) { speed = min(max(speed + d, 8), 160) }

    func restart() { offset = 0; rolling = false }

    /// Scroll wheel / trackpad: move by hand (positive = further into the script).
    func scroll(by dy: CGFloat) { offset = min(max(offset + dy, 0), max(maxOffset, 0)) }

    func pasteClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? s.write(to: Self.file, atomically: true, encoding: .utf8)
        text = s
        restart()
    }

    func openScript() {
        if !FileManager.default.fileExists(atPath: Self.file.path) { save("") }
        NSWorkspace.shared.open(Self.file)
    }

    /// island://prompter?do=start|end|toggle|roll|paste|edit
    func run(_ q: [String: String]) {
        switch q["do"] ?? "toggle" {
        case "start": if !on { start() }
        case "end", "stop": end()
        case "roll", "pause": if on { roll() }
        case "paste": pasteClipboard(); if !on { start() }
        case "edit": PrompterScriptWindow.shared.show()
        default: toggle()
        }
    }

    private func load() {
        let s = (try? String(contentsOf: Self.file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        text = s.isEmpty ? "No script yet.\n\nCopy your text and press the clipboard button here, or the pencil to edit the script file." : s
    }

    /// From the script window: keep the text, then start (or reload if already on).
    func start(with s: String) {
        save(s.trimmingCharacters(in: .whitespacesAndNewlines))
        if on { load(); restart() } else { start() }
    }

    func savedText() -> String { (try? String(contentsOf: Self.file, encoding: .utf8)) ?? "" }

    private func save(_ s: String) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? s.write(to: Self.file, atomically: true, encoding: .utf8)
    }

    private func step() {
        let now = Date()
        let dt = now.timeIntervalSince(last)
        last = now
        guard rolling else { return }
        offset += CGFloat(speed * dt)
        if offset >= maxOffset { offset = maxOffset; rolling = false }
    }

    private func make() -> NSPanel {
        let p = PrompterPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.isFloatingPanel = true
        // Just under the island (mainMenu + 3), so an opened island still draws on top.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.sharingType = UserDefaults.standard.bool(forKey: "debug.capturable") ? .readOnly : .none
        p.contentView = NSHostingView(rootView: PrompterView(p: self, notch: LockFaceOverlay.notchSize()))
        panel = p
        return p
    }

    /// Top edge flush with the screen top, so the pane reads as the notch grown downward.
    private func position(_ w: NSWindow) {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        w.setFrame(CGRect(x: s.frame.midX - Self.size.width / 2, y: s.frame.maxY - Self.size.height,
                          width: Self.size.width, height: Self.size.height), display: true)
    }
}

/// Never key: clicks and scrolls land without pulling focus from the call.
private final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func scrollWheel(with e: NSEvent) {
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12
        Prompter.shared.scroll(by: -dy)
    }
}

private struct ScriptHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PrompterView: View {
    @ObservedObject var p: Prompter
    let notch: CGSize
    @State private var hover = false

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(.black)
            GeometryReader { g in
                let view = g.size.height
                Text(p.text)
                    .font(.system(size: p.fontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(p.fontSize * 0.35)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: g.size.width, alignment: .leading)
                    .background(GeometryReader { t in Color.clear.preference(key: ScriptHeight.self, value: t.size.height) })
                    .padding(.top, view * 0.18) // first line starts near the camera
                    .padding(.bottom, view * 0.6) // last line can reach the reading line
                    .offset(y: -p.offset)
                    .onPreferenceChange(ScriptHeight.self) { h in p.maxOffset = max(h + view * 0.78 - view, 0) }
            }
            .padding(.horizontal, 30)
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                       .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipped()
            .padding(.top, notch.height) // the status row beside the notch stays clear
            status.frame(height: notch.height)
            if hover { controls.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8).transition(.opacity) }
        }
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { p.roll() }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    /// Either side of the notch: state on the left, speed on the right.
    private var status: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(p.rolling ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(p.rolling ? "Rolling" : "Paused")
            }
            Spacer(minLength: notch.width + 20)
            Text("\(Int(p.speed)) pt/s")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 26)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            button("backward.end.fill", "Back to top") { p.restart() }
            button(p.rolling ? "pause.fill" : "play.fill", p.rolling ? "Pause" : "Roll") { p.roll() }
            button("tortoise.fill", "Slower") { p.nudge(-6) }
            button("hare.fill", "Faster") { p.nudge(+6) }
            button("textformat.size.smaller", "Smaller text") { p.fontSize = max(p.fontSize - 2, 12) }
            button("textformat.size.larger", "Larger text") { p.fontSize = min(p.fontSize + 2, 40) }
            button("doc.on.clipboard", "Use clipboard text") { p.pasteClipboard() }
            button("square.and.pencil", "Edit script") { PrompterScriptWindow.shared.show() }
            button("xmark", "End teleprompter") { p.end() }
        }
        .padding(4)
        .background(.white.opacity(0.12), in: Capsule())
    }

    private func button(_ symbol: String, _ label: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Script window

/// Paste or type the script, then Start. Opened from Desk › Prompter, the menu bar, or the pencil
/// on the pane. Hidden from screen shares like the pane.
final class PrompterScriptWindow: NSObject, NSWindowDelegate {
    static let shared = PrompterScriptWindow()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Teleprompter Script"
        w.sharingType = UserDefaults.standard.bool(forKey: "debug.capturable") ? .readOnly : .none
        w.contentView = NSHostingView(rootView: PrompterScriptView(p: Prompter.shared, close: { [weak w] in w?.close() })
            .preferredColorScheme(.dark))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_: Notification) { window = nil }
}

private struct PrompterScriptView: View {
    @ObservedObject var p: Prompter
    let close: () -> Void
    @State private var draft = Prompter.shared.savedText()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { if let s = NSPasteboard.general.string(forType: .string) { draft = s } } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Replace with the clipboard (⇧⌘V)")
                Button { draft = "" } label: { Label("Clear", systemImage: "trash") }
                Spacer()
                Text("\(draft.split(whereSeparator: \.isWhitespace).count) words · ~\(minutes) min")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if draft.isEmpty {
                    Text("Paste or type what you'll say…").foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 14) {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                Slider(value: $p.speed, in: 8...160).frame(width: 140)
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
                Text("Text").foregroundStyle(.secondary).padding(.leading, 6)
                Stepper("\(Int(p.fontSize)) pt", value: $p.fontSize, in: 12...40, step: 2).fixedSize()
                Spacer()
            }
            .font(.callout)
            HStack {
                Text("⌃⌥O roll/pause · ⌃⌥↑↓ speed · ⌃⌥P end").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if p.on { Button("End") { p.end() } }
                Button(p.on ? "Update" : "Start") {
                    p.start(with: draft)
                    close()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Start the teleprompter under the notch (⌘↩)")
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 360)
    }

    /// Spoken pace ~140 words a minute.
    private var minutes: Int { max(1, Int((Double(draft.split(whereSeparator: \.isWhitespace).count) / 140).rounded())) }
}

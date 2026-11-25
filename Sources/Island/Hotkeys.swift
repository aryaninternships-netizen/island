import Carbon.HIToolbox
import Foundation

/// Ids for every global shortcut Island owns, so stages never collide.
enum HotkeyID {
    static let record: UInt32 = 1 // ⌃⌥R
    static let mark: UInt32 = 2 // ⌃⌥M
    static let peek: UInt32 = 3 // ⌃⌥T (hold)
    static let hide: UInt32 = 4 // ⌃⌥H
    static let island: UInt32 = 5 // ⌃⌥Space: open with the command bar
    static let guardNow: UInt32 = 6 // ⌃⌥G
}

/// Global hot keys via Carbon `RegisterEventHotKey`: no Accessibility permission, nothing runs while
/// idle, and a matched keystroke is consumed (it never reaches the frontmost app). Pressed and
/// released events both arrive, so a key can be held (peek). Main thread.
final class Hotkeys {
    static let shared = Hotkeys()

    static let control = controlKey
    static let option = optionKey
    static let command = cmdKey
    static let shift = shiftKey

    private struct Binding {
        var ref: EventHotKeyRef?
        let down: () -> Void
        let up: (() -> Void)?
    }

    private var bindings: [UInt32: Binding] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4953_4C44 // 'ISLD'

    /// `key` is a virtual key code (kVK_*); `mods` is a Carbon modifier mask (controlKey | optionKey…).
    /// Re-registering an id replaces it. Returns false if the system refused (another app holds it).
    @discardableResult
    func register(_ id: UInt32, key: Int, mods: Int, down: @escaping () -> Void, up: (() -> Void)? = nil) -> Bool {
        installHandler()
        unregister(id)
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: Self.signature, id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let ref else {
            NSLog("Island: hot key \(id) not registered (\(st))")
            return false
        }
        bindings[id] = Binding(ref: ref, down: down, up: up)
        return true
    }

    func unregister(_ id: UInt32) {
        if let r = bindings.removeValue(forKey: id)?.ref { UnregisterEventHotKey(r) }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard st == noErr, hk.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
            Hotkeys.shared.fire(hk.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, types.count, &types, nil, &handler)
    }

    private func fire(_ id: UInt32, pressed: Bool) {
        guard let b = bindings[id] else { return }
        if pressed { b.down() } else { b.up?() }
    }

    /// Virtual key code for a letter, digit or "space" (US layout positions).
    static func key(_ name: String) -> Int {
        let table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "space": kVK_Space,
        ]
        return table[name.lowercased()] ?? kVK_Space
    }
}

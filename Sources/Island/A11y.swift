import AppKit
import SwiftUI

/// Accessibility helpers. Everything here is a no-op under default system settings: announcements
/// and sound cues only fire while VoiceOver runs; the modifiers only change drawing when the
/// matching setting (Reduce Motion, Increase Contrast) is on.
enum A11y {
    static var voiceOver: Bool { NSWorkspace.shared.isVoiceOverEnabled }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Spoken by VoiceOver over whatever has focus. Silent (and free) when VoiceOver is off.
    static func announce(_ s: String, high: Bool = false) {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, voiceOver else { return }
        let post = {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: (high ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
            ])
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// A system sound paired with an announcement, for places VoiceOver may not reach (the lock
    /// screen). VoiceOver users only, so default sound stays exactly as it was.
    static func cue(_ name: String) {
        guard voiceOver else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Spring by default; a short ease under Reduce Motion.
    static func motion(_ spring: Animation) -> Animation { reduceMotion ? .easeInOut(duration: 0.15) : spring }
}

/// Springs and scale for everyone, a plain 0.15 s fade under Reduce Motion.
struct CalmMotion<V: Equatable>: ViewModifier {
    let spring: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var rm

    func body(content: Content) -> some View {
        content.animation(rm ? .easeInOut(duration: 0.15) : spring, value: value)
    }
}

extension View {
    func calmAnimation<V: Equatable>(_ spring: Animation, value: V) -> some View {
        modifier(CalmMotion(spring: spring, value: value))
    }

    /// 1 pt white outline under Increase Contrast; nothing otherwise.
    func hiContrastStroke<S: InsettableShape>(_ shape: S) -> some View {
        modifier(HiContrastStroke(shape: shape))
    }
}

/// Type with a floor for the expanded view (10.5 pt). The closed island never uses it: its height is fixed.
enum T {
    static func f(_ s: CGFloat, _ w: Font.Weight = .regular, _ d: Font.Design = .default, floor: CGFloat = 10.5) -> Font {
        .system(size: max(s, floor), weight: w, design: d)
    }
}

/// Dim text: the designed opacity normally, at least 0.8 under Increase Contrast.
enum Dim {
    static func text(_ c: ColorSchemeContrast, _ base: Double = 0.6) -> Double { c == .increased ? max(base, 0.8) : base }
}

struct HiContrastStroke<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if contrast == .increased { shape.strokeBorder(.white.opacity(0.6), lineWidth: 1) }
        }
    }
}

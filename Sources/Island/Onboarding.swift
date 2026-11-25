import AppKit
import AVFoundation
import EventKit
import SwiftUI

/// First run only (fresh installs; an existing setup is marked onboarded by the migration).
/// Three cards in the island, each with Skip. Nothing asks for a permission before its card:
/// Calendar on card 1, the camera on card 2, Accessibility on card 3.
struct OnboardingView: View {
    @ObservedObject var m: IslandModel
    @ObservedObject var calendar: CalendarModel
    @AppStorage("onboarding.step") private var step = 0
    @State private var calendarDenied = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case 0: helloCard
                case 1: calendarCard
                case 2: faceCard
                default: gesturesCard
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .glass(18)
            .padding(.bottom, 6)
            .transition(.opacity)
            HStack(spacing: 6) {
                ForEach(0..<Self.steps, id: \.self) { i in Dot(on: i <= step, tint: .white) }
                Text("\(min(step, Self.steps - 1) + 1) of \(Self.steps)").font(T.f(10, .medium))
                    .foregroundStyle(.white.opacity(0.45)).padding(.leading, 4)
                Spacer()
                if step > 0 { LinkButton("Back", tint: .white) { step -= 1 } }
                LinkButton(step < Self.steps - 1 ? "Skip" : "Finish", tint: .white) { next() }
            }
            .frame(height: 18)
        }
        .animation(A11y.motion(.easeOut(duration: 0.2)), value: step)
    }

    static let steps = 4

    // MARK: cards

    private var helloCard: some View {
        card(symbol: "sparkles", tint: .yellow, title: "Your notch, now useful",
             body: "Island lives around the camera notch: music, your next meeting, timers, files and quick toggles. Hover the notch any time to open it; move away to close.") {
            primary("Show me around") { next() }
        }
    }

    private var calendarCard: some View {
        card(symbol: "calendar", tint: .red, title: "Meetings in the notch",
             body: "Island shows what's next and puts Join one click away. It reads your calendar on this Mac only.") {
            if calendar.authorized {
                primary("Next") { next() }
            } else if calendarDenied {
                primary("Open Calendar settings") { Deep.open(Deep.calendars) }
            } else {
                primary("Allow Calendar") {
                    calendar.requestAccess { ok in if ok { next() } else { calendarDenied = true } }
                }
            }
        }
    }

    private var faceCard: some View {
        card(symbol: "faceid", tint: .teal, title: "Lock when you walk away",
             body: "Register your face and Island blurs the screen when you leave, opens for you, and locks for anyone else. The camera asks once, here.") {
            if m.hasFace {
                primary("Next") { next() }
            } else if cameraDenied {
                primary("Open Camera settings") { Deep.open(Deep.camera) }
            } else {
                primary("Register my face") {
                    m.registerFace(armAway: true)
                    next()
                }
            }
        }
    }

    private var gesturesCard: some View {
        card(symbol: "hand.point.up.left", tint: .orange, title: "Hover, scroll, type",
             body: "Hover to open, scroll on the notch for volume, drop files on it to keep them for later. ⌃⌥Space opens a command line: type 25 for a timer. Everything else lives in Settings (the gear).") {
            if !MenuBarExtras.trusted {
                secondary("Allow menu bar tray") { MenuBarExtras.askForTrust() }
            }
            primary("Done") { finish() }
        }
    }

    // MARK: pieces

    private func card<B: View>(symbol: String, tint: Color, title: String, body: String, @ViewBuilder actions: () -> B) -> some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Circle().strokeBorder(tint.opacity(0.35), lineWidth: 0.8)
                Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(tint)
            }
            .frame(width: 58, height: 58)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(body).font(T.f(11.5)).foregroundStyle(.white.opacity(Dim.text(contrast, 0.6)))
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                HStack(spacing: 8) { actions() }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 14).frame(height: 26).background(.white.opacity(0.9), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14).frame(height: 26).background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var cameraDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    private func next() {
        if step >= Self.steps - 1 { finish() } else { step += 1 }
    }

    private func finish() {
        m.onboarded = true
        step = 0
        m.tab = .home
        m.requestClose?()
    }
}

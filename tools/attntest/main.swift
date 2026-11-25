// Scenario test for Attention. swiftc tools/attntest/main.swift Sources/Island/Attention.swift
import Foundation

/// Feed `secs` of checks at 5/s; `f(t)` gives the faces at time t. Returns (peekedAt, atKeyboardEnd).
func run(_ secs: Double, profile: Bool = true, _ f: (Double) -> [Seen]) -> (Double?, Bool) {
    let a = Attention(hasProfile: profile)
    let t0 = Date()
    var peekAt: Double?
    var t = 0.0
    while t <= secs {
        a.feed(f(t), at: t0.addingTimeInterval(t))
        if peekAt == nil, a.peeking { peekAt = t }
        t += 0.2
    }
    return (peekAt, a.strangerAtKeyboard(at: t0.addingTimeInterval(secs)))
}

func show(_ name: String, _ expectPeek: Bool, _ expectKbd: Bool?, _ r: (Double?, Bool)) {
    let ok = (r.0 != nil) == expectPeek && (expectKbd == nil || r.1 == expectKbd!)
    print(ok ? "PASS" : "FAIL", name.padding(toLength: 52, withPad: " ", startingAt: 0),
          "peek:", r.0.map { String(format: "%.1fs", $0) } ?? "no", " atKeyboard:", r.1)
}

let S = false // stranger
show("passer-by far away, facing, 3 s", false, false, run(3) { _ in [Seen(width: 0.035, yaw: 0.1, owner: S)] })
show("passer-by close but side-on, crossing 2 s", false, nil, run(2) { _ in [Seen(width: 0.10, yaw: 0.9, owner: S)] })
show("quick glance: close + facing 0.4 s, then gone", false, nil, run(3) { t in t < 0.4 ? [Seen(width: 0.09, yaw: 0.1, owner: S)] : [] })
show("someone walks by mid-room, mostly side-on", false, false, run(4) { t in [Seen(width: 0.05, yaw: t < 2 ? 0.8 : -0.7, owner: S)] })
show("PEEKER: ~1 m behind, facing screen, lingers", true, false, run(3) { _ in [Seen(width: 0.075, yaw: 0.15, owner: S)] })
show("APPROACHER: walks up from ~2 m facing screen", true, nil, run(2.5) { t in [Seen(width: 0.035 + 0.025 * t, yaw: 0.1, owner: S)] })
show("owner close and facing (you)", false, false, run(3) { _ in [Seen(width: 0.13, yaw: 0.05, owner: true)] })
show("owner at desk + stranger peeking over shoulder", true, false, run(3) { _ in [Seen(width: 0.13, yaw: 0.0, owner: true), Seen(width: 0.08, yaw: 0.2, owner: S)] })
show("stranger at keyboard looking down (yaw 0.6)", false, true, run(2) { _ in [Seen(width: 0.12, yaw: 0.6, owner: S)] })
show("stranger sits down at keyboard, facing", true, true, run(2) { _ in [Seen(width: 0.12, yaw: 0.1, owner: S)] })
show("no profile: any close facing face peeks", true, true, run(3, profile: false) { _ in [Seen(width: 0.10, yaw: 0.1, owner: nil)] })

import Foundation

/// One face in one camera check. `width` is the face box width as a fraction of the frame
/// (a proxy for distance), `yaw` in radians (0 = facing the screen), `owner` from the faceprint
/// match: true you, false someone else, nil not checked.
struct Seen {
    var width: Double
    var yaw: Double
    var owner: Bool?
}

/// What strangers are doing in front of the camera. Pure logic (no Vision), fed ~5x/s.
///
/// Not a concern: people walking around (far away, side-on, or only a passing glance).
/// Concern 1 (peeking): someone else close to the laptop, facing the screen, for a sustained
///   moment, or visibly approaching while facing it.
/// Concern 2 (at the keyboard): someone else close enough to be the one using it.
final class Attention {
    // Measured on this MacBook's wide-angle webcam: the owner at the keyboard (~55 cm) is ~0.13.
    // Width scales ~1/distance, so:
    /// Within reading reach of the screen (~1.2 m): looking from here is peeking.
    static let closeWidth = 0.065
    /// Within arm's reach (~0.8 m): close enough to be the one on the keys/trackpad.
    static let keyboardWidth = 0.09
    /// Beyond ~1.6 m is background unless the person is walking towards the screen.
    static let nearWidth = 0.045
    /// Turned less than ~26 degrees away = looking at the screen, not walking past.
    static let facingYaw = 0.45
    /// Sustained looking that counts as peeking (a glance is shorter).
    static let dwell = 0.6
    /// Grew this much within the window while facing = approaching.
    static let approachGrowth = 1.25
    static let window = 1.5

    private let lock = NSLock()
    private let hasProfile: Bool
    private var looks: [Date] = [] // checks where a stranger was attentive
    private var widths: [(Date, Double)] = [] // largest facing-stranger width per check
    private var lastClose = Date.distantPast
    private var approachingNow = false

    init(hasProfile: Bool) { self.hasProfile = hasProfile }

    func reset() {
        lock.lock(); looks = []; widths = []; lastClose = .distantPast; approachingNow = false; lock.unlock()
    }

    func feed(_ faces: [Seen], at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        // With a profile, only faces that failed the owner match count; without one, every face does.
        let others = faces.filter { hasProfile ? $0.owner == false : true }
        if others.contains(where: { $0.width >= Self.keyboardWidth }) { lastClose = now }

        let facing = others.filter { abs($0.yaw) <= Self.facingYaw && $0.width >= Self.nearWidth }
        widths.removeAll { now.timeIntervalSince($0.0) > Self.window }
        looks.removeAll { now.timeIntervalSince($0) > Self.window }
        guard let big = facing.map(\.width).max() else { approachingNow = false; return }

        let smallest = widths.map(\.1).min() ?? big
        approachingNow = widths.count >= 2 && big >= smallest * Self.approachGrowth
        widths.append((now, big))
        if big >= Self.closeWidth || approachingNow { looks.append(now) }
    }

    /// Someone else has been looking at the screen from close up (or walked up to it facing it).
    var peeking: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let first = looks.first, let last = looks.last else { return false }
        if approachingNow && looks.count >= 2 { return true }
        return looks.count >= 3 && last.timeIntervalSince(first) >= Self.dwell
    }

    /// Someone else was within arm's reach in the last 2 s: if keys move, it's them.
    var strangerAtKeyboard: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastClose) < 2
    }

    /// Test hook: same as `strangerAtKeyboard` at a given time.
    func strangerAtKeyboard(at now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now.timeIntervalSince(lastClose) < 2
    }
}

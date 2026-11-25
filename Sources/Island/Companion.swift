import AppKit
import SwiftUI

// MARK: - Needs

/// The pup's needs. Food and fun run down over hours; energy drains while you work and
/// refills while you're away or at night. Persisted, and caught up on launch.
final class Pet: ObservableObject {
    @Published var name: String { didSet { UserDefaults.standard.set(name, forKey: "pup.name") } }
    @Published private(set) var food: Double
    @Published private(set) var fun: Double
    @Published private(set) var energy: Double
    /// Last thing he said (speech bubble in the Pet tab).
    @Published var line = ""

    private var mood: DogMood = .sit
    private var moodUntil = Date.distantPast
    private var last: Date

    static let owner = NSFullUserName().split(separator: " ").first.map(String.init) ?? "you"

    init() {
        let d = UserDefaults.standard
        name = d.string(forKey: "pup.name") ?? "Bruno"
        food = d.object(forKey: "pup.food") as? Double ?? 0.8
        fun = d.object(forKey: "pup.fun") as? Double ?? 0.8
        energy = d.object(forKey: "pup.energy") as? Double ?? 0.9
        last = d.object(forKey: "pup.last") as? Date ?? Date()
        tick(idle: 600) // catch up on the time Island was closed
    }

    /// Advance needs to now. `idle` = seconds since your last keyboard/mouse input.
    func tick(idle: Double) {
        let now = Date()
        let mins = min(now.timeIntervalSince(last) / 60, 12 * 60)
        last = now
        let hour = Calendar.current.component(.hour, from: now)
        let night = hour >= 23 || hour < 6
        food = clamp(food - mins / 300) // empty in ~5 h
        fun = clamp(fun - mins / 360) // bored in ~6 h
        if idle > 300 { energy = clamp(energy + mins / 90) } // naps while you're away
        else { energy = clamp(energy - mins / (night ? 240 : 600)) }
        save()
    }

    func feed() { food = 1; fun = clamp(fun + 0.1); act(.eat, 3.5); save() }
    func play() { fun = clamp(fun + 0.4); energy = clamp(energy - 0.08); food = clamp(food - 0.05); act(.play, 4); save() }
    func pet() { fun = clamp(fun + 0.15); act(.happy, 3); save() }

    func act(_ m: DogMood, _ seconds: TimeInterval) {
        mood = m; moodUntil = Date().addingTimeInterval(seconds)
        objectWillChange.send()
        // displayMood falls back to his resting state when the action ends: publish so views re-read it.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.objectWillChange.send() }
    }

    /// What he's doing right now in the Pet tab: a short action, else his resting state.
    var displayMood: DogMood {
        if Date() < moodUntil { return mood }
        let hour = Calendar.current.component(.hour, from: Date())
        if energy < 0.2 || (hour >= 0 && hour < 6) { return .sleep }
        if food < 0.3 { return .hungry }
        return .sit
    }

    var status: String {
        switch displayMood {
        case .sleep: return "snoozing"
        case .hungry: return "hungry"
        case .eat: return "eating"
        case .play: return "playing"
        case .happy: return "happy"
        default: return fun < 0.35 ? "bored" : energy < 0.4 ? "sleepy" : "content"
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    private func save() {
        let d = UserDefaults.standard
        d.set(food, forKey: "pup.food"); d.set(fun, forKey: "pup.fun"); d.set(energy, forKey: "pup.energy"); d.set(last, forKey: "pup.last")
    }
}

// MARK: - Brain

/// The pup's voice: Bruno's own ~10M-parameter model (pup/train.py, distilled once from a
/// bigger local model), bundled in the app and run on the CPU by TinyGPT. No server, no GPU,
/// a few milliseconds per line. Hand-written lines cover it if the model file is missing.
final class PupBrain {
    private let q = DispatchQueue(label: "island.pup", qos: .utility)
    private var recent: [String] = []
    /// Every word Bruno saw in training: a generated line must be made of these (or the
    /// song/meeting name it was given), otherwise it's babble and he says a written line instead.
    private lazy var known: Set<String> = {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("pup.words.json"),
              let d = try? Data(contentsOf: u), let w = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(w)
    }()

    private func sensible(_ line: String, given arg: String) -> Bool {
        let words = line.lowercased().split { !$0.isLetter && $0 != "'" }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }
        let allowed = Set(arg.lowercased().split { !$0.isLetter }.map(String.init))
        let ok = words.filter { known.contains($0) || allowed.contains($0) }.count
        return Double(ok) / Double(words.count) >= 0.85
    }

    private lazy var gpt: TinyGPT? = {
        guard let r = Bundle.main.resourceURL else { return nil }
        return TinyGPT(json: r.appendingPathComponent("pup.json"), bin: r.appendingPathComponent("pup.bin"))
    }()

    /// One line for a situation, e.g. ("music", "Kesariya"), ("meeting", "Budget review|10"), ("hungry", "").
    func line(_ key: String, _ arg: String = "", done: @escaping (String) -> Void) {
        let x = arg.isEmpty ? key : "\(key)|\(arg)"
        q.async { [self] in
            var out = Self.fallback(key)
            if let g = gpt {
                for _ in 0..<6 { // must read as real words, and not repeat what he just said
                    // The model learned on one person's name; say this Mac's owner instead.
                    let l = Self.personalise(g.generate(x).trimmingCharacters(in: .whitespaces))
                    guard sensible(l, given: arg + " " + Pet.owner) else { continue }
                    out = l
                    if !recent.contains(l) { break }
                }
            }
            recent.append(out); if recent.count > 12 { recent.removeFirst() }
            DispatchQueue.main.async { done(out) }
        }
    }

    /// Free chat from the Pet tab.
    func reply(to text: String, done: @escaping (String) -> Void) {
        line("chat", String(text.prefix(60)).lowercased(), done: done)
    }

    var hasModel: Bool { gpt != nil }

    /// Swaps the training data's name ("Aryan", "boss") for this Mac's owner's first name.
    static func personalise(_ l: String) -> String {
        var out = l
        for name in ["{owner}", "Aryan", "aryan", "ARYAN"] { out = out.replacingOccurrences(of: name, with: Pet.owner) }
        out = out.replacingOccurrences(of: #"\b[Bb]oss\b"#, with: Pet.owner, options: .regularExpression)
        return out
    }

    static func fallback(_ key: String) -> String {
        let lines: [String: [String]] = [
            "greet": ["Morning, \(Pet.owner)! I kept your seat warm. ☀️", "You're back! Tail at maximum wag."],
            "hungry": ["My tummy is growling louder than your fan.", "Bowl's empty… just saying. 🥺"],
            "fed": ["Crunch crunch! Best meal ever! 🦴", "Yum! You're my favourite human."],
            "play": ["Ball! Ball! One quick throw?", "Fetch break? Your inbox can wait. 🎾"],
            "played": ["Got it! Again, again! 🎾"],
            "petted": ["Right behind the ears! Again! 💛", "Hehe, that's the spot!"],
            "home": ["Laptop down, shoes on. Home time!", "Workday's done. Let's go home!"],
            "late": ["Yawn… even the cursor looks sleepy. Bed?", "It's late. Save your work, then sleep."],
            "stretch": ["Paws up! Stretch with me.", "Stand up, shake it out, then back to it."],
            "sleepy": ["Nap time. Wake me if you need me. 🌙"],
            "wake": ["*big stretch* Hi again! 🐾"],
        ]
        return lines[key]?.randomElement() ?? "Woof! 🐾"
    }
}

// MARK: - Props + stage

/// The pup plus whatever the mood needs: a bowl, a ball, hearts, zZz.
/// Three z's rising off a sleeping pup, animated by the render server (no app work per frame).
struct NapZs: NSViewRepresentable {
    var scale: CGFloat
    var paused: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let root = v.layer!
        let period = 1 / 0.35
        for i in 0..<3 {
            let size = (3.5 + CGFloat(i)) * scale
            let z = CATextLayer()
            z.string = "z"
            let base = NSFont.systemFont(ofSize: size, weight: .heavy)
            z.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            z.fontSize = size
            z.foregroundColor = NSColor.white.cgColor
            z.contentsScale = 2
            z.bounds = CGRect(x: 0, y: 0, width: size, height: size * 1.25)
            z.anchorPoint = CGPoint(x: 0, y: 0)
            z.opacity = 0
            // Same path as before: from (24, 9) to (30, 19) in pup units, fading out.
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = CGPoint(x: 24 * scale, y: 9 * scale)
            move.toValue = CGPoint(x: 30 * scale, y: 19 * scale)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.85
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [move, fade]
            g.duration = period
            g.repeatCount = .infinity
            g.timeOffset = period * Double(i) / 3
            z.add(g, forKey: "drift")
            root.addSublayer(z)
        }
        root.setFrozen(paused)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { v.layer?.setFrozen(paused) }
}

struct PupStage: View {
    var mood: DogMood
    var scale: CGFloat = 1
    var start = Date()
    @Environment(\.renderPaused) private var paused

    var body: some View {
        if mood == .sleep {
            // Asleep: the pup is drawn once and the z's drift on Core Animation, so the napping
            // island costs nothing per frame (a SwiftUI timeline here was ~10% CPU even at 8 fps).
            ZStack(alignment: .bottomLeading) {
                Dog(t: 0, mood: mood, scale: scale)
                NapZs(scale: scale, paused: paused)
                    .frame(width: (Dog.size.width + 12) * scale, height: (Dog.size.height + 8) * scale)
                    .allowsHitTesting(false)
            }
            .frame(width: (Dog.size.width + 12) * scale, height: (Dog.size.height + 8) * scale, alignment: .bottomLeading)
        } else {
            animated
        }
    }

    private var animated: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            let s = scale
            ZStack(alignment: .bottomLeading) {
                Dog(t: t, mood: mood, scale: s)
                props(t, s)
            }
            .frame(width: (Dog.size.width + 12) * s, height: (Dog.size.height + 8) * s, alignment: .bottomLeading)
        }
    }

    @ViewBuilder private func props(_ t: Double, _ s: CGFloat) -> some View {
        switch mood {
        case .hungry, .eat:
            Bowl(full: mood == .eat).frame(width: 9 * s, height: 4 * s).offset(x: 29 * s, y: 0)
        case .play:
            let bounce = abs(sin(t * 3.4))
            Circle().fill(Color(red: 0.8, green: 0.95, blue: 0.2))
                .overlay(Circle().trim(from: 0.1, to: 0.4).stroke(.white.opacity(0.8), lineWidth: 0.4 * s))
                .frame(width: 4 * s, height: 4 * s)
                .offset(x: 33 * s, y: -CGFloat(bounce) * 7 * s)
        case .happy:
            ForEach(0..<3, id: \.self) { i in
                let ph = (t * 0.7 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Image(systemName: "heart.fill").font(.system(size: 4 * s)).foregroundStyle(.pink)
                    .opacity(1 - ph).offset(x: (22 + CGFloat(i) * 4) * s + CGFloat(sin(t * 3 + Double(i))) * s, y: (-16 - CGFloat(ph) * 8) * s)
            }
        case .sleep:
            ForEach(0..<3, id: \.self) { i in
                let ph = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z").font(.system(size: (3.5 + CGFloat(i)) * s, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85 * (1 - ph)))
                    .offset(x: (24 + CGFloat(ph) * 6) * s, y: (-9 - CGFloat(ph) * 10) * s)
            }
        default:
            EmptyView()
        }
    }
}

struct Bowl: View {
    var full: Bool
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .bottom) {
                if full {
                    Ellipse().fill(Color(red: 0.62, green: 0.38, blue: 0.18)).frame(width: w * 0.8, height: h * 0.6).offset(y: -h * 0.45)
                }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.85, y: h)); p.addLine(to: CGPoint(x: w * 0.15, y: h)); p.closeSubpath()
                }.fill(Color(red: 0.95, green: 0.35, blue: 0.22))
            }
        }
    }
}

// MARK: - Pet tab

struct PetView: View {
    @ObservedObject var pet: Pet
    let brain: PupBrain
    @State private var text = ""
    @State private var thinking = false
    @State private var pupStart = Date()

    var body: some View {
        HStack(spacing: 18) {
            ZStack(alignment: .top) {
                Ellipse().fill(.white.opacity(0.06)).frame(width: 150, height: 14).frame(maxHeight: .infinity, alignment: .bottom)
                PupStage(mood: pet.displayMood, scale: 3.4, start: pupStart)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { petHim() }
                    .help("Pet \(pet.name)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(pet.name)
                    .accessibilityValue(pet.status)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Pet") { petHim() }
                    .accessibilityAction { petHim() }
                if !pet.line.isEmpty || thinking {
                    Text(thinking ? "…" : pet.line)
                        .font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: 210)
                        .transition(.opacity)
                }
            }
            .frame(width: 220)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pet.name).font(.system(size: 15, weight: .bold))
                    Text(pet.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                NeedBar(label: "Food", value: pet.food, tint: .orange)
                NeedBar(label: "Fun", value: pet.fun, tint: .pink)
                NeedBar(label: "Energy", value: pet.energy, tint: .teal)
                HStack(spacing: 8) {
                    PetButton(symbol: "fork.knife", label: "Feed") { pet.feed(); say("fed") }
                    PetButton(symbol: "tennisball.fill", label: "Play") { pet.play(); say("played") }
                    PetButton(symbol: "hand.raised.fill", label: "Pet") { petHim() }
                }
                TextField("Talk to \(pet.name)…", text: $text)
                    .accessibilityLabel("Talk to \(pet.name)")
                    .textFieldStyle(.plain).font(.system(size: 11.5))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.white.opacity(0.08), in: Capsule())
                    .onSubmit(talk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func petHim() { pet.pet(); say("petted", Bool.random() ? "" : "ears") }

    private func say(_ key: String, _ arg: String = "") {
        thinking = true
        brain.line(key, arg) { l in withAnimation { thinking = false; pet.line = l }; A11y.announce(l) }
    }

    private func talk() {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        text = ""; thinking = true
        brain.reply(to: q) { l in withAnimation { thinking = false; pet.line = l }; A11y.announce(l) }
    }
}

struct NeedBar: View {
    let label: String
    let value: Double
    let tint: Color
    var body: some View {
        HStack(spacing: 7) {
            Text(label).font(T.f(10, .medium)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(tint).frame(width: max(4, 150 * value))
            }
            .frame(width: 150, height: 5)
        }
        .animation(.easeOut(duration: 0.4), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

struct PetButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol).font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.white.opacity(hover ? 0.16 : 0.09), in: Capsule())
                .hiContrastStroke(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { hover = $0 }
    }
}

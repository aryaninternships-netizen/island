import AppKit
import SwiftUI

/// One Guard incident: who (face close-up), what they did, when, and the full photos.
struct GuardEvent: Codable, Identifiable {
    let id: UUID
    let date: Date
    let reason: String
    var photos: [String] = [] // file names in GuardMode.folder
    var face: String? // face close-up file name, if a face was in view
    var seen = false
}

/// Incident log behind "who peeked while I was away". Lives next to the snapshots in
/// ~/Pictures/Island Guard/events.json. Written from the camera queue, published on main.
final class GuardLog: ObservableObject {
    static let shared = GuardLog()

    @Published private(set) var events: [GuardEvent] = []
    private let file = GuardMode.folder.appendingPathComponent("events.json")
    private var cache: [String: NSImage] = [:]

    private init() {
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([GuardEvent].self, from: d) {
            events = e
        }
    }

    var unseen: [GuardEvent] { events.filter { !$0.seen } }

    func begin(_ reason: String) -> UUID {
        let e = GuardEvent(id: UUID(), date: Date(), reason: reason)
        mutate { $0.append(e) }
        return e.id
    }

    func addPhoto(_ name: String, to id: UUID) { mutate { ev in ev.firstIndex { $0.id == id }.map { ev[$0].photos.append(name) } } }

    func setFace(_ name: String, for id: UUID) {
        mutate { ev in
            if let i = ev.firstIndex(where: { $0.id == id }), ev[i].face == nil { ev[i].face = name }
        }
    }

    func hasFace(_ id: UUID) -> Bool { events.first { $0.id == id }?.face != nil }

    func markAllSeen() { if events.contains(where: { !$0.seen }) { mutate { ev in for i in ev.indices { ev[i].seen = true } } } }

    func clear() {
        for e in events {
            for n in e.photos + [e.face].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: GuardMode.folder.appendingPathComponent(n))
            }
        }
        cache = [:]
        mutate { $0.removeAll() }
    }

    /// Face close-up if we have one, else the first photo.
    func thumbnail(_ e: GuardEvent) -> NSImage? {
        guard let name = e.face ?? e.photos.first else { return nil }
        if let i = cache[name] { return i }
        let i = NSImage(contentsOf: GuardMode.folder.appendingPathComponent(name))
        cache[name] = i
        return i
    }

    func photoURL(_ e: GuardEvent) -> URL? {
        (e.photos.first ?? e.face).map { GuardMode.folder.appendingPathComponent($0) }
    }

    private func mutate(_ f: @escaping (inout [GuardEvent]) -> Void) {
        let run = { [self] in
            f(&events)
            if let d = try? JSONEncoder().encode(events) {
                try? FileManager.default.createDirectory(at: GuardMode.folder, withIntermediateDirectories: true)
                try? d.write(to: file)
            }
        }
        Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    }
}

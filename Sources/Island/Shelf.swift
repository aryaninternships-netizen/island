import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File shelf (idea from NotchDrop). Dropped files are copied into
/// ~/Library/Application Support/Island/Shelf so temp files (screenshots,
/// browser drags) survive; the shelf persists across launches.
final class Shelf: ObservableObject {
    struct Item: Identifiable, Codable, Equatable {
        let id: UUID
        let url: URL
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var items: [Item] = [] { didSet { save() } }

    private let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Island/Shelf", isDirectory: true)
    }()

    private let key = "shelf.items"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Item].self, from: d) {
            items = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }

    func add(_ src: URL) {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dst)
            items.append(Item(id: id, url: dst))
        } catch {
            NSLog("Island: shelf copy failed \(error)")
        }
    }

    func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        items.removeAll { $0.id == item.id }
    }

    func clear() { items.forEach(remove) }

    func airdrop(_ urls: [URL]? = nil) {
        let urls = urls ?? items.map(\.url)
        guard !urls.isEmpty, let svc = NSSharingService(named: .sendViaAirDrop) else { return }
        svc.perform(withItems: urls)
    }

    /// Accepts file drops from Finder, screenshots, browsers.
    func handle(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.add(url) }
            }
        }
        return accepted
    }
}

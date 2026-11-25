import Foundation
import Combine

@MainActor
final class RadioHistoryStore: ObservableObject {
    @Published private(set) var items: [RadioHistoryItem] = []

    private struct StoredEntry: Codable {
        var kind: String
        var id: UUID
        var mode: RadioModeID
        var date: Date
        var width: Int?
        var height: Int?
        var complete: Bool?
        var offsetHz: Int?
        var imageFile: String?
        var message: String?
        var frequencyHz: Int?
    }

    private let directory: URL
    private let indexURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let historyDirectory = base.appendingPathComponent("RadioHistory", isDirectory: true)
        directory = historyDirectory
        indexURL = historyDirectory.appendingPathComponent("history.json")
        try? fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let decoded = try? decoder.decode([StoredEntry].self, from: data) {
            items = decoded.compactMap { entry in
                if entry.kind == "picture", let file = entry.imageFile,
                   let rgba = try? Data(contentsOf: historyDirectory.appendingPathComponent(file)) {
                    return .picture(RadioPicture(id: entry.id, mode: entry.mode, startedAt: entry.date,
                                                 width: entry.width ?? 320, height: entry.height ?? 240,
                                                 rgba: rgba, complete: entry.complete ?? false,
                                                 frequencyOffsetHz: entry.offsetHz ?? 0))
                }
                if entry.kind == "text", let message = entry.message {
                    return .text(DecodedText(id: entry.id, mode: entry.mode, receivedAt: entry.date,
                                             text: message, frequencyHz: entry.frequencyHz))
                }
                return nil
            }.sorted { $0.date > $1.date }
        }
    }

    func add(_ item: RadioHistoryItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if case .picture(let picture) = item {
            try? picture.rgba.write(to: pictureURL(for: picture), options: .atomic)
        }
        persist()
    }

    func delete(_ item: RadioHistoryItem) {
        items.removeAll { $0.id == item.id }
        if case .picture(let picture) = item { try? FileManager.default.removeItem(at: pictureURL(for: picture)) }
        persist()
    }

    func pictureURL(for picture: RadioPicture) -> URL {
        directory.appendingPathComponent("\(picture.id.uuidString).rgba")
    }

    private func persist() {
        do {
            let entries = items.map { item -> StoredEntry in
                switch item {
                case .picture(let picture):
                    return StoredEntry(kind: "picture", id: picture.id, mode: picture.mode, date: picture.startedAt,
                                       width: picture.width, height: picture.height, complete: picture.complete,
                                       offsetHz: picture.frequencyOffsetHz, imageFile: "\(picture.id.uuidString).rgba",
                                       message: nil, frequencyHz: nil)
                case .text(let message):
                    return StoredEntry(kind: "text", id: message.id, mode: message.mode, date: message.receivedAt,
                                       width: nil, height: nil, complete: nil, offsetHz: nil, imageFile: nil,
                                       message: message.text, frequencyHz: message.frequencyHz)
                }
            }
            let data = try encoder.encode(entries)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Could not save modem history: %@", error.localizedDescription)
        }
    }
}

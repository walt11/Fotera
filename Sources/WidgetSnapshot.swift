import Foundation
import UIKit

struct WidgetSnapshot: Codable {
    let title: String
    let image: Data
    let date: Date
}
/// Previews shared with the widget through the App Group. The widget never receives session data.
enum WidgetSnapshotStore {
    static let group = "group.net.jwalter.Fotera"
    private static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    private static var pinnedURL: URL? { container?.appendingPathComponent("photo-widget.json") }
    private static var memoriesURL: URL? { container?.appendingPathComponent("memories-widget.json") }
    static var isAvailable: Bool { container != nil }

    /// The photo explicitly chosen with "Show in widget", if any.
    static func read() -> WidgetSnapshot? {
        guard let pinnedURL, let data = try? Data(contentsOf: pinnedURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
    static func save(_ snapshot: WidgetSnapshot) throws {
        guard let pinnedURL else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(snapshot).write(to: pinnedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func readMemories() -> [WidgetSnapshot] {
        guard let memoriesURL, let data = try? Data(contentsOf: memoriesURL) else { return [] }
        return (try? JSONDecoder().decode([WidgetSnapshot].self, from: data)) ?? []
    }
    static func saveMemories(_ snapshots: [WidgetSnapshot]) throws {
        guard let memoriesURL else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(snapshots).write(to: memoriesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func clear() throws {
        if let container { for name in ["feed-album.json", "feed-person.json", "backup-widget.json"] { try? FileManager.default.removeItem(at: container.appendingPathComponent(name)) } }
        for url in [pinnedURL, memoriesURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    static func clearPinned() throws {
        guard let pinnedURL, FileManager.default.fileExists(atPath: pinnedURL.path) else { return }
        try FileManager.default.removeItem(at: pinnedURL)
    }
}

struct BackupWidgetSnapshot: Codable {
    let status: String; let completed: Int; let total: Int; let updated: Date
}
extension WidgetSnapshotStore {
    static func saveFeed(_ snapshots: [WidgetSnapshot], kind: String) throws {
        guard ["album", "person"].contains(kind), let container else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(snapshots).write(to: container.appendingPathComponent("feed-" + kind + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func readFeed(_ kind: String) -> [WidgetSnapshot] {
        guard ["album", "person"].contains(kind), let container, let data = try? Data(contentsOf: container.appendingPathComponent("feed-" + kind + ".json")) else { return [] }
        return (try? JSONDecoder().decode([WidgetSnapshot].self, from: data)) ?? []
    }
    static func saveBackup(_ value: BackupWidgetSnapshot) {
        guard let container, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: container.appendingPathComponent("backup-widget.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func readBackup() -> BackupWidgetSnapshot? {
        guard let container, let data = try? Data(contentsOf: container.appendingPathComponent("backup-widget.json")) else { return nil }
        return try? JSONDecoder().decode(BackupWidgetSnapshot.self, from: data)
    }
}


extension WidgetSnapshot {
    /// Widget extensions have a small memory budget: bound pixels, not screen-scaled points.
    @MainActor static func previewData(_ image: UIImage) -> Data {
        let ratio = min(1, 600 / max(1, max(image.size.width, image.size.height)))
        let size = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    static func needsRefresh(stamp: String, savedStamp: String?, snapshots: [WidgetSnapshot]) -> Bool {
        savedStamp != stamp || snapshots.isEmpty || snapshots.contains { UIImage(data: $0.image) == nil }
    }
}

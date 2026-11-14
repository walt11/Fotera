import Foundation

extension UserDefaults {
    /// Settings shared with the share extension and widget through the App Group.
    static let foteraGroup = UserDefaults(suiteName: WidgetSnapshotStore.group) ?? .standard
}

/// Files shared into Fotera from other apps wait here until the app uploads them.
enum ShareInbox {
    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.group)?
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }
    /// Copies a file into its own folder in the inbox, keeping the original filename.
    static func add(_ file: URL) throws {
        guard let root else { throw CocoaError(.fileWriteNoPermission) }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
    }
    /// Files waiting to be uploaded, oldest first.
    static func pending() -> [URL] {
        guard let root, let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return folders.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.compactMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil))?.first }
    }
    static func remove(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    static var uploadFolder: String { UserDefaults.foteraGroup.string(forKey: "uploadFolderPath") ?? "" }
    static var uploadShared: Bool { UserDefaults.foteraGroup.bool(forKey: "uploadSpaceShared") }
    /// Earlier versions kept the upload folder in the app's own defaults; move it where the extension can read it.
    static func migrateSettings() {
        let group = UserDefaults.foteraGroup
        guard group !== UserDefaults.standard, group.string(forKey: "uploadFolderPath") == nil,
              let folder = UserDefaults.standard.string(forKey: "uploadFolderPath") else { return }
        group.set(folder, forKey: "uploadFolderPath")
        group.set(UserDefaults.standard.bool(forKey: "uploadSpaceShared"), forKey: "uploadSpaceShared")
    }
}

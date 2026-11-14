import Foundation
import CryptoKit

/// Account-scoped metadata and preview cache. Originals and session tokens never enter this cache.
actor LibraryCache {
    static let shared = LibraryCache()
    struct Snapshot: Codable {
        let photos: [RemotePhoto]
        let updated: Date
    }
    static let previewLimit = 300_000_000
    private let root: URL
    private var bytesSinceTrim = 0
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("FoteraLibraryV3", isDirectory: true)
        // Earlier cache layouts are no longer read.
        for legacy in ["FoteraLibrary", "FoteraLibraryV2"] {
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(legacy)
            try? FileManager.default.removeItem(at: url)
        }
    }
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func folder(_ account: String) -> URL { root.appendingPathComponent(Self.hash(account), isDirectory: true) }
    private var previews: URL { root.appendingPathComponent("previews", isDirectory: true) }

    func read(account: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: folder(account).appendingPathComponent("index.json")) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    /// Callers only write when the index actually changed (JSON measured smaller and faster to load than a binary plist here).
    func write(account: String, snapshot: Snapshot) throws {
        let directory = folder(account)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func previewURL(_ key: String) -> URL { previews.appendingPathComponent(Self.hash(key) + ".jpg") }
    func preview(key: String) -> Data? { try? Data(contentsOf: previewURL(key)) }
    func savePreview(key: String, data: Data) {
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try? data.write(to: previewURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        bytesSinceTrim += data.count
        if bytesSinceTrim > 20_000_000 { bytesSinceTrim = 0; trim() }
    }
    /// Evicts the least recently written previews once the cache exceeds its limit.
    func trim() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: previews, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > Self.previewLimit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > Self.previewLimit * 8 / 10 {
            try? FileManager.default.removeItem(at: entry.0); total -= entry.1
        }
    }
    func size() -> Int {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        while let file = enumerator.nextObject() as? URL { total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

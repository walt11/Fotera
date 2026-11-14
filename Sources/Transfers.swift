import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import ImageIO
import AVFoundation

enum TransferState: String, Codable {
    case queued = "Queued", uploading = "Uploading", uploaded = "Uploaded", verifying = "Verifying"
    case verified = "Verified", complete = "Complete", failed = "Needs review"
    var isFinished: Bool { self == .verified || self == .complete }
    var label: String {
        switch self {
        case .queued: return "Waiting"
        case .uploading: return "Uploading"
        case .uploaded, .verifying: return "Verifying"
        case .verified: return "Backed up · verified"
        case .complete: return "Backed up"
        case .failed: return "Needs attention"
        }
    }
}
struct TransferRecord: Codable, Identifiable {
    let id: UUID
    var filename: String
    let folder: String
    let shared: Bool
    var state: TransferState
    var remoteID: Int?
    var message: String?
    let created: Date
    var sourceID: String? = nil
    var digest: String? = nil
    var size: Int64? = nil
    var attempts: Int? = nil
    var updated: Date? = nil
    var verificationRetryAt: Date? = nil
    var verificationAttempts: Int? = nil
    var readyForVerification: Bool { state == .uploaded && (verificationRetryAt ?? .distantPast) <= Date() }
}

/// A durable upload ledger. Uploads run in the background session; this queue submits them,
/// reconciles their receipts, and confirms each one by downloading the NAS copy and comparing digests.
@MainActor final class TransferQueue: ObservableObject {
    @Published private(set) var records: [TransferRecord] = []
    @Published private(set) var running = false
    @Published private(set) var activity: String?
    @Published var failure: String?
    private(set) var completed = Set<String>()
    /// Sources whose NAS copy was byte-verified. Only these count as safe to remove from the iPhone.
    private(set) var verifiedSources = Set<String>()
    private var activeSources = Set<String>()
    private let directory: URL
    private var task: Task<Void, Never>?
    private var events = 0
    private var duplicateCatalog: [Bool: [RemotePhoto]] = [:]
    private var duplicateDigests: [String: Set<String>] = [:]
    private var duplicateIndex: [String: Set<String>] = [:]
    private var duplicateIndexChanges = 0
    private var catalogLoaded: [Bool: Date] = [:]
    private var pendingWrite: Task<Void, Never>?
    /// Supplies the library index the app already holds, so the duplicate check doesn't re-list the NAS.
    static var catalogSource: (@MainActor (Bool) -> [RemotePhoto]?)?
    private var observer: NSObjectProtocol?
    static let historyLimit = 300
    private static var instances: [String: TransferQueue] = [:]

    /// One queue per account and purpose, so screens never fight over the same ledger.
    static func shared(account: String) -> TransferQueue {
        if let queue = instances[account] { return queue }
        let queue = TransferQueue(account: account)
        instances[account] = queue
        return queue
    }
    init(account: String) {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfers/" + LibraryCache.hash(account), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var folder = directory; try folder.setResourceValues(values)
            let index = directory.appendingPathComponent("queue.json")
            if FileManager.default.fileExists(atPath: index.path) {
                records = try JSONDecoder().decode([TransferRecord].self, from: Data(contentsOf: index))
                for i in records.indices where records[i].state == .verifying { records[i].state = .uploaded }
            }
            if let log = try? String(contentsOf: verifiedLog, encoding: .utf8) {
                verifiedSources = Set(log.split(separator: "\n").map(String.init))
            }
            for record in records where record.state == .verified { if let source = record.sourceID { verifiedSources.insert(source) } }
            if let log = try? String(contentsOf: completedLog, encoding: .utf8) {
                completed = Set(log.split(separator: "\n").map(String.init))
            }
            // Earlier versions kept finished records only in the ledger.
            for record in records where record.state.isFinished { if let source = record.sourceID { completed.insert(source) } }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("duplicate-index.json")) {
                duplicateIndex = (try? JSONDecoder().decode([String: Set<String>].self, from: data)) ?? [:]
            }
            rebuildIndex()
        } catch { failure = "Couldn’t restore the upload queue. " + error.localizedDescription }
        observer = NotificationCenter.default.addObserver(forName: .foteraTransferFinished, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.events += 1 }
        }
    }
    private var completedLog: URL { directory.appendingPathComponent("completed.log") }
    private var verifiedLog: URL { directory.appendingPathComponent("verified.log") }
    private static func append(_ line: String, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        }
    }
    /// Coalesces ledger writes (at most one every half second). Writes that must survive a crash pass `immediate`.
    private func persist(immediate: Bool = false) {
        if immediate { pendingWrite?.cancel(); pendingWrite = nil; writeNow(); return }
        guard pendingWrite == nil else { return }
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.pendingWrite = nil
            self.writeNow()
        }
    }
    func flush() { if pendingWrite != nil { persist(immediate: true) } }
    static func flushAll() { for queue in instances.values { queue.flush() } }
    private func writeNow() {
        do { try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("queue.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { failure = "Couldn’t save the upload queue. " + error.localizedDescription }
    }
    private func rebuildIndex() { activeSources = Set(records.filter { !$0.state.isFinished }.compactMap(\.sourceID)) }
    private func source(_ record: TransferRecord) -> URL { directory.appendingPathComponent(record.id.uuidString) }

    var pending: [TransferRecord] { records.filter { !$0.state.isFinished && $0.state != .failed } }
    var attention: [TransferRecord] { records.filter { $0.state == .failed } }
    var history: [TransferRecord] { records.filter(\.state.isFinished) }
    var pendingBytes: Int64 { pending.reduce(0) { $0 + ($1.size ?? 0) } }
    func contains(sourceID: String) -> Bool { activeSources.contains(sourceID) || completed.contains(sourceID) || records.contains { $0.sourceID == sourceID } }
    func pendingSources(withPrefix prefix: String) -> Bool { activeSources.contains { $0.hasPrefix(prefix) } }

    /// Adds a file to the queue. `move` transfers ownership of a staged temporary file instead of copying it.
    func enqueue(_ url: URL, filename: String, folder: String, shared: Bool, sourceID: String? = nil, move: Bool = false,
                 digest precomputed: (String, Int64)? = nil) async throws {
        guard failure == nil else { throw ConnectionError.invalidResponse }
        if let sourceID, contains(sourceID: sourceID) { return }
        let record = TransferRecord(id: UUID(), filename: filename, folder: folder, shared: shared, state: .queued, created: Date(), sourceID: sourceID)
        let target = source(record)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if move { try FileManager.default.moveItem(at: url, to: target) } else { try FileManager.default.copyItem(at: url, to: target) }
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            let (digest, size): (String, Int64)
            if let precomputed { (digest, size) = precomputed }
            else { (digest, size) = try await Task.detached(priority: .utility) { try Self.digest(target) }.value }
            var added = record
            added.digest = digest; added.size = size
            records.append(added)
            if let sourceID { activeSources.insert(sourceID) }
            persist(immediate: true)
        } catch {
            try? FileManager.default.removeItem(at: target); throw error
        }
    }
    func retry(_ record: TransferRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[i].state = records[i].remoteID == nil ? .queued : .uploaded
        records[i].verificationRetryAt = nil; records[i].verificationAttempts = nil
        records[i].attempts = 0; records[i].message = nil; records[i].updated = nil
        persist()
    }
    /// Gives up on a record. Its source is still marked handled so backup doesn't queue it again.
    func dismiss(_ record: TransferRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        let removed = records.remove(at: i)
        try? FileManager.default.removeItem(at: source(removed))
        UploadReceipt.remove(removed.id)
        markCompleted(removed.sourceID)
        rebuildIndex(); persist()
    }
    func clearHistory() {
        records.removeAll(where: \.state.isFinished)
        persist()
    }
    private func markCompleted(_ sourceID: String?) {
        guard let sourceID, completed.insert(sourceID).inserted else { return }
        if let handle = try? FileHandle(forWritingTo: completedLog) {
            handle.seekToEndOfFile(); handle.write(Data((sourceID + "\n").utf8)); try? handle.close()
        } else {
            try? Data((sourceID + "\n").utf8).write(to: completedLog, options: .completeFileProtectionUntilFirstUserAuthentication)
        }
    }
    private func finish(_ index: Int, state: TransferState, message: String) {
        records[index].state = state; records[index].message = message; records[index].updated = Date()
        try? FileManager.default.removeItem(at: source(records[index]))
        UploadReceipt.remove(records[index].id)
        markCompleted(records[index].sourceID)
        if let sourceID = records[index].sourceID {
            activeSources.remove(sourceID)
            if state == .verified, verifiedSources.insert(sourceID).inserted { Self.append(sourceID, to: verifiedLog) }
        }
        let finished = records.indices.filter { records[$0].state.isFinished }
        if finished.count > Self.historyLimit {
            let drop = Set(finished.prefix(finished.count - Self.historyLimit).map { records[$0].id })
            records.removeAll { drop.contains($0.id) }
        }
        persist()
    }

    func start(client: DSMClient, wifiOnly: Bool, verify: Bool = true) {
        guard !running, failure == nil else { return }
        running = true
        task = Task {
            await process(client: client, wifiOnly: wifiOnly, verify: verify)
            running = false; task = nil; activity = nil
        }
    }
    func waitUntilIdle() async { await task?.value }
    /// Stops this app's processing. Uploads already handed to iOS finish on their own and are reconciled later.
    func pause() { task?.cancel() }
    func cancelUploads() async {
        task?.cancel()
        for record in records where record.state == .uploading { await BackgroundUploads.shared.cancel(record.id) }
    }

    /// Submits, reconciles and verifies until there is nothing left, the deadline passes, or the task is cancelled.
    @discardableResult
    func process(client: DSMClient, wifiOnly: Bool, verify: Bool, verifyVideos: Bool = true, deadline: Date? = nil,
                 maxInFlight: Int = 4, verifyAllowed: Bool = true) async -> Bool {
        defer { flush() }
        var networkFailures = 0
        while !Task.isCancelled {
            if let deadline, Date() > deadline { break }
            var progressed = false
            let active = await BackgroundUploads.shared.activeIDs()
            for record in records where record.state == .uploading && !active.contains(record.id) {
                // Videos can skip the full re-download and be checked by size instead.
                let full = verify && (verifyVideos || !Self.isVideoFile(record.filename))
                await reconcile(record.id, client: client, verify: full)
                progressed = true
            }
            let inFlight = records.filter { $0.state == .uploading }.count
            let now = Date()
            let ready = records.filter { record in
                guard record.state == .queued else { return false }
                let wait = min(3600, 15 * pow(2, Double(record.attempts ?? 0)))
                return (record.attempts ?? 0) == 0 || now.timeIntervalSince(record.updated ?? .distantPast) > wait
            }
            for record in ready.prefix(max(0, maxInFlight - inFlight)) where !Task.isCancelled {
                // Wait for an identical in-flight resource to become visible on the NAS.
                if records.contains(where: { $0.state == .uploading && $0.shared == record.shared && $0.digest != nil && $0.digest == record.digest }) { continue }
                if let deadline, Date() >= deadline { break }
                let submitted: Bool
                if let deadline {
                    submitted = (try? await withTimeout(max(0.1, deadline.timeIntervalSinceNow)) {
                        await self.submit(record.id, client: client, wifiOnly: wifiOnly)
                    }) ?? false
                } else { submitted = await submit(record.id, client: client, wifiOnly: wifiOnly) }
                if submitted { progressed = true; networkFailures = 0 } else { networkFailures += 1 }
            }
            if verifyAllowed, let next = records.first(where: { $0.readyForVerification }) {
                if let deadline {
                    _ = try? await withTimeout(max(0.1, deadline.timeIntervalSinceNow)) { await self.verifyRecord(next.id, client: client) }
                } else {
                    _ = await verifyRecord(next.id, client: client)
                }
                // A readback error does not mean uploading is offline. Each item has its own retry delay.
                progressed = true
                continue
            }
            if networkFailures >= 3 && !records.contains(where: { $0.state == .uploading }) { activity = "Uploads will retry…"; break }
            if records.contains(where: { $0.state == .uploading }) {
                let uploading = records.filter { $0.state == .uploading }
                activity = uploading.count == 1 ? "Uploading \(uploading[0].filename)" : "Uploading \(uploading.count) files"
                await waitForEvent(seconds: 15)
                continue
            }
            if !progressed { break }
        }
        activity = nil
        flushDuplicateIndex()
        return networkFailures < 3
    }
    private func waitForEvent(seconds: Int) async {
        let start = events
        for _ in 0..<(seconds * 4) {
            if events != start || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
    /// Searches the selected Photos space, including other folders and differently named files.
    /// Size only narrows candidates; only an exact original-resource SHA-256 match permits a skip.
    func existingOriginal(_ record: TransferRecord, client: DSMClient) async throws -> Int? {
        guard let expected = record.digest else { throw TransferError.missingSource }
        let stale = catalogLoaded[record.shared].map { Date().timeIntervalSince($0) > 600 } ?? true
        if duplicateCatalog[record.shared] == nil || stale, let local = Self.catalogSource?(record.shared), !local.isEmpty {
            duplicateCatalog[record.shared] = local
            catalogLoaded[record.shared] = Date()
        } else if duplicateCatalog[record.shared] == nil || stale {
            var photos: [RemotePhoto] = []; var seen = Set<Int>(); var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await client.items(.all, shared: record.shared, offset: offset)
                photos += page.filter { seen.insert($0.id).inserted }
                offset += page.count
                if page.count < DSMClient.pageSize { break }
            }
            duplicateCatalog[record.shared] = photos
            catalogLoaded[record.shared] = Date()
        }
        // Only an exact size match, or a Live Photo with the same base name (its motion file has a
        // different size than the listed still), can be the same original. Everything else is skipped
        // without downloading, so a large existing library isn't fetched before the first upload.
        let stem = (record.filename as NSString).deletingPathExtension.lowercased()
        let candidates = (duplicateCatalog[record.shared] ?? []).filter { photo in
            if let size = record.size, let remote = photo.filesize, remote == size { return true }
            return photo.isLive && (photo.filename as NSString).deletingPathExtension.lowercased() == stem
        }.sorted { ($0.filename == record.filename ? 0 : 1) < ($1.filename == record.filename ? 0 : 1) }
        let ordered = candidates.sorted {
            let left = duplicateIndex[duplicateKey($0, shared: record.shared)]?.contains(expected) == true
            let right = duplicateIndex[duplicateKey($1, shared: record.shared)]?.contains(expected) == true
            return left && !right
        }
        for photo in ordered {
            try Task.checkCancellation()
            let key = duplicateKey(photo, shared: record.shared)
            // Stored non-matches avoid downloading every Live Photo again. A stored match is ALWAYS re-downloaded.
            if let known = duplicateIndex[key], !known.contains(expected), photo.thumbnailSource != nil { continue }
            if duplicateDigests[key] == nil {
                let file: URL
                do {
                    file = try await photo.isLive ? client.livePackage(photo, shared: record.shared) : client.original(photo, shared: record.shared)
                } catch {
                    // The library may change while scanning. A removed item is not a duplicate.
                    if case ConnectionError.server(let code) = error, code == 117 { continue }
                    throw error
                }
                defer { try? FileManager.default.removeItem(at: file) }
                duplicateDigests[key] = try await Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try await Self.originalDigests(file, live: photo.isLive)
                }.value
            }
            if photo.thumbnailSource != nil, let hashes = duplicateDigests[key], duplicateIndex[key] != hashes {
                duplicateIndex[key] = hashes
                if duplicateIndex.count > 50_000 { duplicateIndex = [key: hashes] }
                duplicateIndexChanges += 1
                if duplicateIndexChanges >= 25 { flushDuplicateIndex() }
            }
            if duplicateDigests[key]?.contains(expected) == true {
                // Confirm cached candidates still exist before marking the local resource complete.
                do { _ = try await client.details(id: photo.id, shared: record.shared) }
                catch {
                    if case ConnectionError.server(let code) = error, code == 117 { duplicateDigests[key] = nil; continue }
                    throw error
                }
                return photo.id
            }
        }
        return nil
    }

    /// Writes the candidate digest index in batches, encoding off the main thread.
    private func flushDuplicateIndex() {
        guard duplicateIndexChanges > 0 else { return }
        duplicateIndexChanges = 0
        let snapshot = duplicateIndex
        let url = directory.appendingPathComponent("duplicate-index.json")
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
    private func duplicateKey(_ photo: RemotePhoto, shared: Bool) -> String {
        "\(shared):\(photo.id):\(photo.thumbnailSource?.cacheKey ?? "unknown"):\(photo.filesize ?? -1):\(photo.time ?? 0):\(photo.type)"
    }
    private func submit(_ id: UUID, client: DSMClient, wifiOnly: Bool) async -> Bool {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return false }
        let record = records[i]
        guard FileManager.default.fileExists(atPath: source(record).path) else {
            records[i].state = .failed; records[i].message = "The local copy of this file is missing. Dismiss it to back it up again."
            persist(); return true
        }
        do {
            activity = "Checking existing photos: \(record.filename)"
            if record.sourceID != nil, let existing = try await existingOriginal(record, client: client) {
                try Task.checkCancellation()
                guard let j = records.firstIndex(where: { $0.id == id }) else { return false }
                records[j].remoteID = existing
                finish(j, state: .verified, message: "Already on the NAS · identical original verified; upload skipped.")
                return true
            }
            try Task.checkCancellation()
            let request = try await client.makeUploadRequest(source: source(record), filename: record.filename, folder: record.folder,
                                                             shared: record.shared, transferID: record.id, wifiOnly: wifiOnly)
            guard let j = records.firstIndex(where: { $0.id == id }) else { return false }
            records[j].state = .uploading; records[j].updated = Date(); records[j].message = nil
            persist(immediate: true)
            BackgroundUploads.shared.submit(request: request, body: BackgroundUploads.bodyURL(id), id: id)
            return true
        } catch {
            guard let j = records.firstIndex(where: { $0.id == id }) else { return false }
            // Suspension and deadline expiry are not failed upload attempts.
            if Task.isCancelled { return false }
            if case ConnectionError.server(let code) = error, code == 621 || code == 642 {
                records[j].state = .failed
            } else {
                records[j].attempts = (records[j].attempts ?? 0) + 1
            }
            records[j].updated = Date(); records[j].message = error.localizedDescription
            persist()
            return false
        }
    }
    private func reconcile(_ id: UUID, client: DSMClient, verify: Bool) async {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[i]
        try? FileManager.default.removeItem(at: BackgroundUploads.bodyURL(id))
        guard let receipt = UploadReceipt.read(id) else {
            // iOS lost the task (for example after a reinstall). Check the NAS before uploading again.
            if let match = try? await client.findItem(named: record.filename, inFolder: record.folder, shared: record.shared),
               let j = records.firstIndex(where: { $0.id == id }) {
                records[j].remoteID = match.id
                records[j].state = .uploaded
                if !verify { finish(j, state: .complete, message: "Found on the NAS.") } else { persist() }
            } else if let j = records.firstIndex(where: { $0.id == id }) {
                records[j].state = .queued; persist()
            }
            return
        }
        UploadReceipt.remove(id)
        switch receipt.outcome {
        case .uploaded(let remote):
            records[i].remoteID = remote
            records[i].state = .uploaded
            records[i].updated = Date()
            persist()
            guard !verify else { return }
            // Without a full download, at least confirm the NAS didn't keep a different file with this name.
            let details = try? await client.details(id: remote, shared: record.shared)
            guard let j = records.firstIndex(where: { $0.id == id }) else { return }
            if let details, details.type != "live", let remoteSize = details.filesize, let size = records[j].size, remoteSize != size {
                records[j].remoteID = nil
                records[j].attempts = (records[j].attempts ?? 0) + 1
                records[j].filename = Self.uniqueName(records[j].filename, id: records[j].id)
                records[j].state = (records[j].attempts ?? 0) >= 3 ? .failed : .queued
                records[j].message = "Another file has this name on the NAS. Uploading as \(records[j].filename)."
                persist()
            } else {
                finish(j, state: .complete, message: "Accepted by the NAS.")
            }
        case .sessionExpired:
            records[i].state = .queued; persist()
            try? await client.renewSession()
        case .cancelled:
            records[i].state = .queued; persist()
        case .server(let code):
            let error = ConnectionError.server(code)
            records[i].message = error.localizedDescription
            records[i].attempts = (records[i].attempts ?? 0) + 1
            records[i].state = code == 620 || (records[i].attempts ?? 0) >= 4 ? .failed : .queued
            records[i].updated = Date(); persist()
        case .failed(let message):
            records[i].message = message
            records[i].attempts = (records[i].attempts ?? 0) + 1
            records[i].state = (records[i].attempts ?? 0) >= 8 ? .failed : .queued
            records[i].updated = Date(); persist()
        }
    }
    /// Live Photo components can be merged after upload, retiring the returned video item ID.
    /// Resolve the current combined item and still verify the exact component bytes in its package.
    func verificationDownload(_ record: TransferRecord, client: DSMClient) async throws -> URL {
        guard let remote = record.remoteID else { throw ConnectionError.invalidResponse }
        let photo = RemotePhoto(id: remote, filename: record.filename, time: nil, type: "photo", additional: nil)
        do { return try await client.original(photo, shared: record.shared) }
        catch {
            guard case ConnectionError.server(let code) = error, code == 117 else { throw error }
            guard let current = try await client.findItem(named: record.filename, inFolder: record.folder, shared: record.shared, includeLiveCompanion: true) else { throw TransferError.remoteMissing }
            let file = try await client.livePackage(current, shared: record.shared)
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].remoteID = current.id; persist() }
            return file
        }
    }
    /// Downloads the NAS copy and compares it to the digest taken when the file was queued.
    /// Returns false when verification couldn't run (for example, the NAS is unreachable).
    private func verifyRecord(_ id: UUID, client: DSMClient) async -> Bool {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].remoteID != nil else { return false }
        records[i].state = .verifying
        activity = "Verifying \(records[i].filename)"
        let record = records[i]
        let local = source(record)
        do {
            var expected = record.digest
            if expected == nil, FileManager.default.fileExists(atPath: local.path) {
                expected = try await Task.detached(priority: .utility) { try Self.digest(local).0 }.value
            }
            guard let expected else { throw TransferError.missingSource }
            let downloaded = try await verificationDownload(record, client: client)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            let matches = try await Task.detached(priority: .utility) {
                if try Self.digest(downloaded).0 == expected { return true }
                guard let package = try? OriginalPackage.unpack(downloaded) else { return false }
                defer { try? FileManager.default.removeItem(at: package.directory) }
                return try package.files.contains { try Self.digest($0).0 == expected }
            }.value
            guard let j = records.firstIndex(where: { $0.id == id }) else { return true }
            if matches {
                finish(j, state: .verified, message: "The NAS copy matches the original.")
            } else {
                // The NAS kept a different file with the same name. Upload this one under a unique name.
                records[j].attempts = (records[j].attempts ?? 0) + 1
                records[j].remoteID = nil
                if (records[j].attempts ?? 0) >= 3 {
                    records[j].state = .failed; records[j].message = TransferError.mismatch.localizedDescription
                } else {
                    records[j].filename = Self.uniqueName(records[j].filename, id: records[j].id)
                    records[j].state = .queued; records[j].message = "Another file has this name on the NAS. Uploading as \(records[j].filename)."
                }
                persist()
            }
            return true
        } catch {
            guard let j = records.firstIndex(where: { $0.id == id }) else { return false }
            records[j].state = .uploaded
            if Task.isCancelled { persist(); return true }
            records[j].verificationAttempts = (records[j].verificationAttempts ?? 0) + 1
            records[j].verificationRetryAt = Date().addingTimeInterval(min(3600, 15 * pow(2, Double(min(records[j].verificationAttempts ?? 1, 8)))))
            records[j].message = "Uploaded; verification will retry. " + error.localizedDescription
            if case TransferError.missingSource = error { records[j].state = .failed }
            if case TransferError.remoteMissing = error, (records[j].verificationAttempts ?? 0) >= 3 {
                records[j].state = .failed
                records[j].remoteID = nil
                records[j].message = "The uploaded file is no longer listed in its destination. The local copy is retained. Check the NAS before choosing Retry."
            }
            persist()
            return isCancelledRequest(error) ? true : false
        }
    }
    static func isVideoFile(_ filename: String) -> Bool {
        ["mov", "mp4", "m4v", "hevc", "avi", "mkv", "3gp"].contains((filename as NSString).pathExtension.lowercased())
    }
    static func uniqueName(_ filename: String, id: UUID) -> String {
        let name = filename as NSString
        let suffix = String(id.uuidString.prefix(6)).lowercased()
        let base = name.deletingPathExtension
        let stem = base.range(of: "_fotera-") .map { String(base[..<$0.lowerBound]) } ?? base
        return name.pathExtension.isEmpty ? "\(stem)_fotera-\(suffix)" : "\(stem)_fotera-\(suffix).\(name.pathExtension)"
    }
    #if DEBUG
    func setDuplicateTestCatalog(_ photos: [RemotePhoto]) { duplicateCatalog[false] = photos; catalogLoaded[false] = Date(); duplicateDigests.removeAll() }
    func simulateInterruptedUpload() {
        guard !records.isEmpty else { return }
        records[0].state = .uploading; persist()
    }
    #endif
    /// Synology may label an item "live" but return only its still original.
    /// Recognize the actual payload; never treat a failed archive parse as proof of a duplicate.
    nonisolated static func originalDigests(_ file: URL, live: Bool) async throws -> Set<String> {
        var hashes: Set<String> = [try digest(file).0]
        guard live else { return hashes }
        if let image = CGImageSourceCreateWithURL(file as CFURL, nil),
           CGImageSourceGetCount(image) > 0, CGImageSourceGetStatus(image) == .statusComplete {
            return hashes
        }
        // A motion component can likewise be returned directly. Validate it as a video
        // before accepting its fingerprint; HTML, error pages and damaged ZIPs still fail.
        let handle = try FileHandle(forReadingFrom: file)
        let header = try handle.read(upToCount: 12) ?? Data(); try handle.close()
        if header.count >= 8, header.subdata(in: 4..<8) == Data("ftyp".utf8) {
            // Downloads requested as packages have a .zip suffix. AVFoundation uses the
            // suffix when choosing its reader, so validate ISO media under a media suffix.
            let media = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: file, to: media)
            defer { try? FileManager.default.removeItem(at: media) }
            let asset = AVURLAsset(url: media)
            if let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty {
                try Task.checkCancellation()
                return hashes
            }
        }
        try Task.checkCancellation()
        let package = try OriginalPackage.unpack(file)
        defer { try? FileManager.default.removeItem(at: package.directory) }
        for part in package.files { hashes.insert(try digest(part).0) }
        return hashes
    }
    nonisolated static func digest(_ url: URL) throws -> (String, Int64) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256(); var size: Int64 = 0
        while let chunk = try file.read(upToCount: 4_194_304), !chunk.isEmpty { hash.update(data: chunk); size += Int64(chunk.count) }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}
enum TransferError: LocalizedError {
    case mismatch, missingSource, remoteMissing
    var errorDescription: String? {
        switch self {
        case .mismatch: return "The NAS copy doesn’t match this file. It wasn’t marked as backed up."
        case .remoteMissing: return "The uploaded item is not currently listed in its destination. Waiting for indexing before retrying."
        case .missingSource: return "The local copy is no longer available to compare."
        }
    }
}

// MARK: - Manual uploads

struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FoteraPicked-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedFile(url: target)
        }
    }
}

struct TransfersView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var queue: TransferQueue
    @AppStorage("uploadSpaceShared", store: .foteraGroup) private var shared = false
    @AppStorage("uploadFolderPath", store: .foteraGroup) private var folderPath = ""
    @State private var choosing = false
    @State private var importing = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var failure: String?
    @State private var adding = false
    var body: some View {
        List {
            Section {
                Picker("Space", selection: $shared) { Text("Personal").tag(false); Text("Shared").tag(true) }
                    .onChange(of: shared) { folderPath = "" }
                Button { choosing = true } label: {
                    LabeledContent("Folder") { Text(folderPath.isEmpty ? "Choose" : folderPath).foregroundStyle(.secondary) }
                }.foregroundStyle(.primary)
            } header: { Text("Destination") }
            Section {
                PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
                Button { importing = true } label: { Label("Choose from Files", systemImage: "folder") }
            }
            .disabled(folderPath.isEmpty || adding)
            if adding { Section { ProgressView("Adding files…") } }
            if let failure = failure ?? queue.failure { Section { Text(failure).foregroundStyle(.red) } }
            TransferListSections(queue: queue)
        }
        .navigationTitle("Upload to NAS")
        .refreshable { if let client = app.client { queue.start(client: client, wifiOnly: false) } }
        .sheet(isPresented: $choosing) {
            if let client = app.client {
                NavigationStack { DestinationPicker(client: client, shared: shared) { folderPath = $0.name; choosing = false } }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): add(urls, move: false)
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .onChange(of: picked) {
            let items = picked
            guard !items.isEmpty else { return }
            picked = []
            Task {
                adding = true
                var urls: [URL] = []
                for item in items {
                    do { if let file = try await item.loadTransferable(type: PickedFile.self) { urls.append(file.url) } }
                    catch { failure = error.localizedDescription }
                }
                adding = false
                add(urls, move: true)
            }
        }
    }
    private func add(_ urls: [URL], move: Bool) {
        guard let client = app.client, !folderPath.isEmpty else { return }
        Task {
            adding = true
            defer { adding = false }
            for url in urls {
                do {
                    try await queue.enqueue(url, filename: url.lastPathComponent, folder: folderPath, shared: shared, move: move)
                    if move { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                } catch { failure = error.localizedDescription }
            }
            queue.start(client: client, wifiOnly: false)
        }
    }
}

/// Pending, needs-attention and recent sections shared by uploads and backup.
struct TransferListSections: View {
    @ObservedObject var queue: TransferQueue
    var body: some View {
        if !queue.attention.isEmpty {
            Section {
                ForEach(queue.attention) { record in
                    TransferRow(record: record)
                        .swipeActions {
                            Button("Dismiss", role: .destructive) { queue.dismiss(record) }
                            Button("Retry") { queue.retry(record) }.tint(.accentColor)
                        }
                }
            } header: { Text("Needs attention") } footer: { Text("Swipe to retry or dismiss.") }
        }
        if !queue.pending.isEmpty {
            Section {
                ForEach(queue.pending.prefix(50)) { TransferRow(record: $0) }
                if queue.pending.count > 50 { Text("and \(queue.pending.count - 50) more").foregroundStyle(.secondary) }
            } header: { Text("In progress") }
        }
        if !queue.history.isEmpty {
            Section {
                ForEach(queue.history.suffix(30).reversed()) { TransferRow(record: $0) }
            } header: {
                HStack { Text("Recent"); Spacer(); Button("Clear") { queue.clearHistory() }.font(.caption) }
            }
        }
    }
}
struct TransferRow: View {
    let record: TransferRecord
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename).lineLimit(1)
                Text(record.message.map { record.state == .failed ? $0 : record.state.label } ?? record.state.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let size = record.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
    private var icon: String {
        switch record.state {
        case .queued: return "clock"
        case .uploading: return "arrow.up.circle"
        case .uploaded, .verifying: return "checkmark.circle.badge.questionmark"
        case .verified: return "checkmark.seal.fill"
        case .complete: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch record.state {
        case .verified, .complete: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

struct DestinationPicker: View {
    let client: DSMClient
    let shared: Bool
    var folder: RemoteFolder? = nil
    let choose: (RemoteFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rootFolder: RemoteFolder?
    @State private var folders: [RemoteFolder] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var creating = false
    @State private var folderName = ""
    var body: some View {
        List {
            if let selected = folder ?? rootFolder {
                Section {
                    Button(folder == nil ? "Use Photos root (/)" : "Use “\(selected.displayName)”") { choose(selected) }.bold()
                } footer: {
                    if folder == nil { Text(shared ? "The base folder of Shared Space." : "The base folder of your Personal Space photos.") }
                }
            }
            Section {
                ForEach(folders) { child in
                    NavigationLink { DestinationPicker(client: client, shared: shared, folder: child, choose: choose) } label: {
                        Label(child.displayName, systemImage: "folder")
                    }
                }
                if loading { ProgressView() }
                if folders.isEmpty && !loading && failure == nil { Text("No subfolders").foregroundStyle(.secondary) }
            } footer: { if let failure { Text(failure).foregroundStyle(.red) } }
        }
        .navigationTitle(folder?.displayName ?? "Choose folder").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folder == nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .primaryAction) { Button("New folder", systemImage: "folder.badge.plus") { folderName = ""; creating = true } }
        }
        .alert("New folder", isPresented: $creating) {
            TextField("Name", text: $folderName).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await create() } }
        }
        .task { if folders.isEmpty { await load() } }
    }
    private func create() async {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            failure = "Enter a folder name without slashes."; return
        }
        do {
            let parentID: Int
            if let folder { parentID = folder.id } else { parentID = try await client.folder(path: "/", shared: shared).id }
            _ = try await client.createFolder(parent: parentID, name: name, shared: shared)
            await load()
        } catch { failure = error.localizedDescription }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            if folder == nil { rootFolder = try await client.folder(path: "/", shared: shared) }
            var result: [RemoteFolder] = []; var offset = 0
            while true {
                let page = try await client.folders(shared: shared, parent: folder?.id ?? 0, offset: offset)
                result += page; offset += page.count
                if page.count < 200 { break }
            }
            folders = result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch { failure = error.localizedDescription }
    }
}

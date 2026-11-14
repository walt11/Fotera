import SwiftUI
import Photos
import CryptoKit
import Network
import Combine

struct BackupPreferences: Codable {
    var showLiveActivity = true
    var enabled = false
    var shared = false
    var destination: RemoteFolder?
    var organizeByMonth = false
    var includeExisting = true
    var wifiOnly = true
    var chargingOnly = false
    var includeVideos = true
    var includeEdited = false
    var verify = true
    /// When off, videos are checked by size instead of being downloaded again (photos are still fully verified).
    var verifyVideos = true
    var enabledAt = Date()
    /// Use the capture date, with Gregorian folder names independent of the device's calendar.
    static func dateFolders(for date: Date?, timeZone: TimeZone = .current) -> [String] {
        guard let date else { return ["Unknown Date"] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: date)
        return [String(format: "%04d", parts.year!), String(format: "%02d", parts.month!)]
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showLiveActivity = try c.decodeIfPresent(Bool.self, forKey: .showLiveActivity) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        shared = try c.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        destination = try c.decodeIfPresent(RemoteFolder.self, forKey: .destination)
        organizeByMonth = try c.decodeIfPresent(Bool.self, forKey: .organizeByMonth) ?? false
        includeExisting = try c.decodeIfPresent(Bool.self, forKey: .includeExisting) ?? true
        wifiOnly = try c.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? true
        chargingOnly = try c.decodeIfPresent(Bool.self, forKey: .chargingOnly) ?? false
        includeVideos = try c.decodeIfPresent(Bool.self, forKey: .includeVideos) ?? true
        includeEdited = try c.decodeIfPresent(Bool.self, forKey: .includeEdited) ?? false
        verify = try c.decodeIfPresent(Bool.self, forKey: .verify) ?? true
        verifyVideos = try c.decodeIfPresent(Bool.self, forKey: .verifyVideos) ?? true
        enabledAt = try c.decodeIfPresent(Date.self, forKey: .enabledAt) ?? Date()
    }
}

/// Automatic PhotoKit backup. Assets are exported in bounded batches, handed to the background
/// upload session, and confirmed against the NAS. Progress survives termination and relaunch.
@MainActor final class BackupController: ObservableObject {
    static let shared = BackupController()
    @Published var preferences = BackupPreferences()
    @Published private(set) var status = "Backup is off." { didSet { publishLiveActivity() } }
    @Published private(set) var running = false { didSet { publishLiveActivity() } }
    @Published private(set) var queue: TransferQueue?
    @Published private(set) var totalAssets = 0
    @Published private(set) var backedUpAssets = 0
    @Published private(set) var lastCompleted: Date?
    @Published private(set) var skippedAssets = 0
    @Published var backgroundNotice: String?
    private(set) var client: DSMClient?
    private var account = ""
    private var stagedAssets = Set<String>()
    /// Staged keys trimmed to "shared|destination|asset", kept in step with `stagedAssets`.
    private var stagedAssetIDs = Set<String>()
    private var stagedPrefix = ""
    private var countTask: Task<Void, Never>?
    private var cachedTotal: (key: String, total: Int, at: Date)?
    private var cachedBaseline: (url: URL, ids: Set<String>)?
    private var runTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var queueObservation: AnyCancellable?
    private var lastWidgetUpdate = Date.distantPast
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var networkWaiters: [CheckedContinuation<Void, Never>] = []

    private var key: String { LibraryCache.hash(account) }
    private var settingsKey: String { "backup." + key }
    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backup/" + key, isDirectory: true)
    }
    private var prefix: String { "\(preferences.shared)|\(preferences.destination?.id ?? 0)" }

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkChanged(path) }
        }
        monitor.start(queue: DispatchQueue(label: "Fotera.Backup.Network"))
    }
    var isAttached: Bool { client != nil }

    func attach(client: DSMClient, account: String) {
        if self.client === client && self.account == account { return }
        pause()
        self.client = client; self.account = account
        preferences = UserDefaults.standard.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(BackupPreferences.self, from: $0) } ?? BackupPreferences()
        lastCompleted = UserDefaults.standard.object(forKey: settingsKey + ".completed") as? Date
        queue = TransferQueue.shared(account: account + "|backup")
        queueObservation = queue?.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleCountUpdate() }
        }
        loadStaged()
        updateCounts()
        status = preferences.enabled ? "Ready" : "Backup is off."
    }
    func detach() {
        pause(); countTask?.cancel(); queueObservation = nil; client = nil; queue = nil; preferences = BackupPreferences(); account = ""
        stagedAssets = []; stagedAssetIDs = []; cachedTotal = nil; cachedBaseline = nil; publishLiveActivity()
    }
    func save() {
        cachedTotal = nil
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: settingsKey) }
        BackupScheduler.schedule(preferences)
        if stagedPrefix != prefix { loadStaged() }
        updateCounts()
    }

    // MARK: Enable

    func enable() async {
        guard preferences.destination != nil else { status = "Choose a destination folder first."; return }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            status = "Allow photo access in iOS Settings to back up."; return
        }
        await BackupNotifier.requestPermission()
        if !preferences.includeExisting {
            var baseline: [String] = []
            PHAsset.fetchAssets(with: nil).enumerateObjects { asset, _, _ in baseline.append(asset.localIdentifier) }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(baseline).write(to: baselineURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        } else {
            try? FileManager.default.removeItem(at: baselineURL)
        }
        cachedBaseline = nil
        preferences.enabled = true; preferences.enabledAt = Date()
        save()
        start(userInitiated: true)
    }
    func disable() {
        pause(); preferences.enabled = false
        save()
        status = "Backup is off."
    }
    private var baselineURL: URL { folder.appendingPathComponent("baseline.json") }

    // MARK: Free up space

    struct Removable {
        let assets: [PHAsset]
        let bytes: Int64
    }
    /// iPhone items whose every backed-up resource was byte-verified on the NAS. Items only
    /// "accepted" (verification off) are never offered for removal.
    func verifiedRemovable(olderThan days: Int, progress: @escaping (Int, Int) -> Void) async -> Removable {
        guard let queue, preferences.destination != nil else { return Removable(assets: [], bytes: 0) }
        let settings = preferences
        let fetch = fetchAssets(settings)
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var result: [PHAsset] = []; var bytes: Int64 = 0
        for index in 0..<fetch.count {
            if index % 200 == 0 { progress(index, fetch.count); await Task.yield() }
            if Task.isCancelled { break }
            let asset = fetch.assets.object(at: index)
            guard (asset.creationDate ?? Date()) < cutoff, stagedAssets.contains(assetKey(asset, settings)) else { continue }
            // Edited photos qualify only if their edited rendering was backed up and verified too.
            let edited: [PHAssetResourceType] = [.fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo]
            let resources = PHAssetResource.assetResources(for: asset).enumerated().filter { _, resource in
                [.photo, .video, .pairedVideo, .alternatePhoto].contains(resource.type) || (asset.hasAdjustments && edited.contains(resource.type))
            }
            guard !resources.isEmpty, !asset.hasAdjustments || settings.includeEdited else { continue }
            let stamp = Int(asset.modificationDate?.timeIntervalSince1970 ?? 0)
            let verified = resources.allSatisfy { index, resource in
                let suffix = edited.contains(resource.type) ? "|e\(stamp)" : ""
                return queue.verifiedSources.contains(prefix + "|" + asset.localIdentifier + "|\(resource.type.rawValue)|\(index)" + suffix)
            }
            guard verified else { continue }
            result.append(asset)
            bytes += resources.reduce(Int64(0)) { $0 + ((($1.1.value(forKey: "fileSize") as? Int64)) ?? 0) }
        }
        progress(fetch.count, fetch.count)
        return Removable(assets: result, bytes: bytes)
    }

    // MARK: Conditions

    private func networkChanged(_ path: NWPath) {
        self.path = path
        if path.status == .satisfied, let client { Task { await client.refreshConnectionRoute() } }
        networkWaiters.forEach { $0.resume() }; networkWaiters.removeAll()
        if !conditionsMet(update: false) { if running { status = blockedReason() ?? status } }
        else if UIApplication.shared.applicationState == .active { start() }
    }
    func waitForNetwork() async {
        if path != nil { return }
        await withCheckedContinuation { networkWaiters.append($0) }
    }
    private func blockedReason() -> String? {
        guard let path, path.status == .satisfied else { return "Waiting for a network connection" }
        if preferences.wifiOnly && (path.isExpensive || !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)) { return "Waiting for Wi‑Fi" }
        let battery = UIDevice.current.batteryState
        let charging = battery == .charging || battery == .full
        if preferences.chargingOnly && !charging { return "Waiting for the iPhone to charge" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled && !charging && UIApplication.shared.applicationState != .active { return "Paused in Low Power Mode" }
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permission == .authorized || permission == .limited else { return "Photo access is off. Review iOS Settings." }
        return nil
    }
    @discardableResult private func conditionsMet(update: Bool = true) -> Bool {
        guard let reason = blockedReason() else { return true }
        if update { status = reason }
        return false
    }

    // MARK: Running

    /// Starts a foreground run if one isn't already going.
    func start(userInitiated: Bool = false) {
        guard preferences.enabled, client != nil else { return }
        if userInitiated { BackupScheduler.requestContinuedBackup() }
        guard !running else { return }
        runTask = Task { await run(deadline: nil, background: false) }
    }
    func pause() {
        BackupScheduler.cancelContinuedBackup()
        retryTask?.cancel(); retryTask = nil
        runTask?.cancel()
        queue?.pause()
    }
    func waitUntilIdle() async { await runTask?.value }
    /// Runs one bounded pass, including verification, so background completions advance the ledger.
    func run(deadline: Date?, background: Bool, trigger: String? = nil) async {
        guard preferences.enabled, !running, let client, let queue, let destination = preferences.destination else { return }
        guard conditionsMet() else { return }
        running = true
        cachedTotal = nil
        let started = Date(), finishedBefore = queue.completed.count, attentionBefore = queue.attention.count
        var staged = 0
        defer {
            running = false; updateCounts()
            let finished = queue.completed.count - finishedBefore
            BackupLog.shared.record(BackupLog.Entry(date: started, trigger: trigger ?? (background ? "background" : "foreground"),
                seconds: Date().timeIntervalSince(started), staged: staged, finished: finished,
                attention: queue.attention.count, status: status))
            BackupNotifier.runFinished(newItems: finished, attention: queue.attention.count, previousAttention: attentionBefore,
                                       upToDate: queue.pending.isEmpty && status == "Up to date")
            if preferences.enabled, !Task.isCancelled, !queue.pending.isEmpty, !background {
                retryTask?.cancel()
                retryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
                    self?.start()
                }
            }
        }
        let settings = preferences
        let fetch = fetchAssets(settings)
        var cursor = 0
        var errors = 0
        do {
            while !Task.isCancelled {
                if let deadline, Date() > deadline { break }
                guard conditionsMet() else { return }
                let batch = try await stage(fetch, cursor: &cursor, destination: destination, settings: settings, queue: queue,
                                             deadline: deadline, budget: background ? (40, 1_500_000_000) : (24, 600_000_000), errors: &errors)
                staged += batch
                updateCounts()
                status = remainingDescription()
                let healthy = await queue.process(client: client, wifiOnly: settings.wifiOnly, verify: settings.verify,
                                                  verifyVideos: settings.verifyVideos, deadline: deadline, maxInFlight: background ? 12 : 4, verifyAllowed: true)
                updateCounts()
                if !healthy { status = "Some uploads couldn’t start. Will retry."; return }
                if batch == 0 && (!queue.pending.isEmpty || cursor >= fetch.count) { break }
            }
            guard !Task.isCancelled else { status = "Paused"; return }
            if queue.pending.isEmpty && cursor >= fetch.count {
                lastCompleted = Date()
                UserDefaults.standard.set(lastCompleted, forKey: settingsKey + ".completed")
                skippedAssets = errors
                status = !queue.attention.isEmpty ? "\(queue.attention.count) files need attention" : (errors > 0 ? "\(errors) items couldn’t be read. They’ll retry next time." : "Up to date")
            } else {
                status = remainingDescription()
            }
        } catch is CancellationError {
            status = "Paused"
        } catch {
            status = "Backup stopped: " + error.localizedDescription
        }
    }
    private func remainingDescription() -> String {
        let remaining = max(0, totalAssets - backedUpAssets)
        if let activity = queue?.activity { return activity }
        let awaiting = queue?.records.filter { $0.state == .uploaded || $0.state == .verifying }.count ?? 0
        if awaiting > 0 { return "\(awaiting) files uploaded; awaiting verification" }
        return remaining == 0 ? "Up to date" : "\(remaining.formatted()) remaining"
    }
    private struct Fetch {
        let assets: PHFetchResult<PHAsset>
        let excluded: Set<String>
        var count: Int { assets.count }
    }
    private func fetchAssets(_ settings: BackupPreferences) -> Fetch {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = settings.includeVideos
            ? NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return Fetch(assets: PHAsset.fetchAssets(with: options), excluded: baseline())
    }
    private func baseline() -> Set<String> {
        if let cachedBaseline, cachedBaseline.url == baselineURL { return cachedBaseline.ids }
        let ids = (try? Data(contentsOf: baselineURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }.map(Set.init) ?? []
        cachedBaseline = (baselineURL, ids)
        return ids
    }
    private static func assetID(_ key: String) -> String { key.split(separator: "|").prefix(3).joined(separator: "|") }
    private func assetKey(_ asset: PHAsset, _ settings: BackupPreferences) -> String {
        var key = prefix + "|" + asset.localIdentifier
        if settings.includeEdited && asset.hasAdjustments { key += "|e\(Int(asset.modificationDate?.timeIntervalSince1970 ?? 0))" }
        return key
    }
    /// Exports resources until the batch budget is reached. Returns how many files were queued.
    private func stage(_ fetch: Fetch, cursor: inout Int, destination: RemoteFolder, settings: BackupPreferences, queue: TransferQueue,
                       deadline: Date?, budget: (count: Int, bytes: Int64), errors: inout Int) async throws -> Int {
        var staged = 0
        while cursor < fetch.count {
            try Task.checkCancellation()
            if let deadline, Date().addingTimeInterval(8) > deadline { break }
            if queue.pending.count >= budget.count || queue.pendingBytes >= budget.bytes { break }
            let asset = fetch.assets.object(at: cursor)
            cursor += 1
            if fetch.excluded.contains(asset.localIdentifier) { continue }
            let key = assetKey(asset, settings)
            if stagedAssets.contains(key) { continue }
            let resources = PHAssetResource.assetResources(for: asset).enumerated().filter { _, resource in
                switch resource.type {
                case .photo, .video, .pairedVideo, .alternatePhoto: return true
                case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo: return settings.includeEdited && asset.hasAdjustments
                default: return false
                }
            }
            // Resolve once for all resources so Live Photo and RAW pairs stay together.
            let uploadFolder: String
            if settings.organizeByMonth, let client {
                uploadFolder = try await client.ensureBackupFolders(base: destination, components: BackupPreferences.dateFolders(for: asset.creationDate), shared: settings.shared).name
            } else {
                uploadFolder = destination.name
            }
            var failed = false
            for (index, resource) in resources {
                try Task.checkCancellation()
                let edited = [PHAssetResourceType.fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo].contains(resource.type)
                let stamp = Int(asset.modificationDate?.timeIntervalSince1970 ?? 0)
                let sourceID = prefix + "|" + asset.localIdentifier + "|\(resource.type.rawValue)|\(index)" + (edited ? "|e\(stamp)" : "")
                if queue.contains(sourceID: sourceID) { continue }
                guard try hasSpace(for: resource) else { throw BackupError.lowStorage }
                let name = resource.originalFilename as NSString
                let filename = edited ? name.deletingPathExtension + "-edited-\(stamp)." + name.pathExtension : resource.originalFilename
                status = "Preparing \(filename)"
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FoteraStage-" + UUID().uuidString)
                do {
                    // Fingerprint while exporting, so the file isn't read a second time before upload.
                    let digest = try await StagedExport.write(resource, to: temporary)
                    if let captured = asset.creationDate { try? FileManager.default.setAttributes([.modificationDate: captured], ofItemAtPath: temporary.path) }
                    try await queue.enqueue(temporary, filename: filename, folder: uploadFolder, shared: settings.shared, sourceID: sourceID, move: true, digest: digest)
                    staged += 1
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    if error is CancellationError { throw error }
                    // iCloud download failures and similar per-asset errors shouldn't stop the whole backup.
                    failed = true
                    errors += 1
                    break
                }
            }
            if !failed { markStaged(key) }
        }
        return staged
    }
    private func hasSpace(for resource: PHAssetResource) throws -> Bool {
        let values = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? .max
        let size = (resource.value(forKey: "fileSize") as? Int64) ?? 50_000_000
        return free > size * 2 + 1_000_000_000
    }

    // MARK: Ledger of staged assets

    private var stagedURL: URL { folder.appendingPathComponent("assets-" + LibraryCache.hash(prefix) + ".log") }
    private func loadStaged() {
        stagedPrefix = prefix
        stagedAssets = (try? String(contentsOf: stagedURL, encoding: .utf8)).map { Set($0.split(separator: "\n").map(String.init)) } ?? []
        stagedAssetIDs = Set(stagedAssets.map(Self.assetID))
    }
    private func markStaged(_ key: String) {
        guard stagedAssets.insert(key).inserted else { return }
        stagedAssetIDs.insert(Self.assetID(key))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: stagedURL) {
            handle.seekToEndOfFile(); handle.write(Data((key + "\n").utf8)); try? handle.close()
        } else {
            try? Data((key + "\n").utf8).write(to: stagedURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        }
    }
    func publishLiveActivity() {
        if Date().timeIntervalSince(lastWidgetUpdate) > 5 {
            lastWidgetUpdate = Date()
            WidgetSnapshotStore.saveBackup(.init(status: status, completed: backedUpAssets, total: totalAssets, updated: Date()))
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fotera-live-activity-test") { return }
        #endif
        let records = queue?.records ?? []
        let awaiting = records.filter { $0.state == .uploaded || $0.state == .verifying }.count
        let phase: BackupActivityAttributes.ContentState.Phase
        if records.contains(where: { $0.state == .uploading }) { phase = .uploading }
        else if records.contains(where: { $0.state == .verifying }) { phase = .verifying }
        else if status == "Paused" { phase = .paused }
        else if !running && !(queue?.attention.isEmpty ?? true) { phase = .attention }
        else if status.hasPrefix("Waiting") || status.hasPrefix("Some uploads") || status.hasPrefix("Backup stopped") { phase = .waiting }
        else if awaiting > 0 { phase = running ? .verifying : .waiting }
        else if !running && totalAssets > 0 && backedUpAssets >= totalAssets { phase = .complete }
        else { phase = .preparing }
        BackupLiveActivity.shared.publish(.init(completed: backedUpAssets, total: totalAssets, awaitingVerification: awaiting, phase: phase),
            enabled: preferences.enabled && preferences.showLiveActivity && (phase == .complete || running || totalAssets > backedUpAssets || !records.filter { !$0.state.isFinished }.isEmpty))
    }
    /// Coalesces the many ledger changes during a backup into at most one recount per second.
    private func scheduleCountUpdate() {
        guard countTask == nil else { return }
        countTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.countTask = nil
            self.updateCounts()
            if self.running { self.status = self.remainingDescription() }
        }
    }
    func updateCounts() {
        defer { publishLiveActivity(); BackupScheduler.updateContinuedProgress() }
        guard preferences.destination != nil else { totalAssets = 0; backedUpAssets = 0; return }
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permission == .authorized || permission == .limited else { return }
        // Counting the library is a PhotoKit query; reuse it for a minute unless settings change.
        let countKey = "\(preferences.includeVideos)|\(baselineURL.path)"
        if let cachedTotal, cachedTotal.key == countKey, Date().timeIntervalSince(cachedTotal.at) < 60 {
            totalAssets = cachedTotal.total
        } else {
            let fetch = fetchAssets(preferences)
            totalAssets = max(0, fetch.count - fetch.excluded.count)
            cachedTotal = (countKey, totalAssets, Date())
        }
        let pendingAssets = Set((queue?.records ?? []).filter { !$0.state.isFinished }.compactMap { $0.sourceID.map(Self.assetID) })
        backedUpAssets = min(totalAssets, max(0, stagedAssetIDs.subtracting(pendingAssets).count))
    }
}
/// Streams a PhotoKit resource to disk and computes its SHA-256 and size in the same pass.
enum StagedExport {
    private final class Sink: @unchecked Sendable {
        let handle: FileHandle
        var hash = SHA256()
        var size: Int64 = 0
        var failure: Error?
        var request: PHAssetResourceDataRequestID?
        init(_ handle: FileHandle) { self.handle = handle }
    }
    static func write(_ resource: PHAssetResource, to url: URL) async throws -> (String, Int64) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let sink = Sink(try FileHandle(forWritingTo: url))
        defer { try? sink.handle.close() }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.request = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                    guard sink.failure == nil else { return }
                    do { try sink.handle.write(contentsOf: chunk); sink.hash.update(data: chunk); sink.size += Int64(chunk.count) }
                    catch { sink.failure = error }
                }, completionHandler: { error in
                    if let error = error ?? sink.failure { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { if let request = sink.request { PHAssetResourceManager.default().cancelDataRequest(request) } }
        try Task.checkCancellation()
        return (sink.hash.finalize().map { String(format: "%02x", $0) }.joined(), sink.size)
    }
}
enum BackupError: LocalizedError {
    case lowStorage
    var errorDescription: String? { "Not enough free space on this iPhone to prepare more files." }
}

// MARK: - UI

struct BackupView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var backup: BackupController
    @State private var choosing = false
    var body: some View {
        List {
            Section { BackupSummaryCard(backup: backup).listRowInsets(EdgeInsets()) }
            Section {
                Toggle("Back up this iPhone", isOn: Binding(get: { backup.preferences.enabled }, set: { value in
                    if value { Task { await backup.enable() } } else { backup.disable() }
                }))
                .disabled(backup.preferences.destination == nil)
                if backup.preferences.enabled {
                    if backup.running {
                        Button("Pause") { backup.pause() }
                        if #available(iOS 26.0, *), !BackupScheduler.hasContinuedBackup {
                            Button("Continue backup in background") { backup.start(userInitiated: true) }
                        }
                    }
                    else { Button("Back up now") { backup.start(userInitiated: true) } }
                }
            } footer: {
                if backup.preferences.destination == nil { Text("Choose where backups go on your NAS.") }
                if let notice = backup.backgroundNotice { Text(notice) }
            }
            Section {
                Picker("Space", selection: $backup.preferences.shared) { Text("Personal").tag(false); Text("Shared").tag(true) }
                    .onChange(of: backup.preferences.shared) { backup.preferences.destination = nil; backup.save() }
                Button { choosing = true } label: {
                    LabeledContent("Folder") { Text(backup.preferences.destination?.name ?? "Choose").foregroundStyle(.secondary) }
                }.foregroundStyle(.primary)
            } header: { Text("Destination") } footer: {
                if backup.preferences.enabled { Text("Turn off backup to change the destination.") }
            }
            .disabled(backup.preferences.enabled)
            Section {
                Toggle("Auto-create year/month folders", isOn: binding(\.organizeByMonth))
                    .disabled(backup.preferences.enabled)
            } header: { Text("Auto-created folders") } footer: {
                Text("New backups go into YYYY/MM folders under your chosen destination, using the date each photo or video was taken. Items without a capture date go into Unknown Date. Previously backed-up items stay where they are. Turn off backup to change this option.")
            }
            Section {
                Toggle("Include existing photos", isOn: binding(\.includeExisting)).disabled(backup.preferences.enabled)
                Toggle("Videos", isOn: binding(\.includeVideos))
                Toggle("Edited versions", isOn: binding(\.includeEdited))
            } header: { Text("What to back up") } footer: {
                Text("Originals are always backed up, including both parts of Live Photos and RAW+JPEG pairs. Edited versions are saved alongside them.")
            }
            Section {
                Toggle("Show in Dynamic Island", isOn: binding(\.showLiveActivity))
                Toggle("Wi‑Fi only", isOn: binding(\.wifiOnly))
                Toggle("Only while charging", isOn: binding(\.chargingOnly))
                Toggle("Verify every upload", isOn: binding(\.verify))
                if backup.preferences.verify {
                    Toggle("Verify videos by downloading", isOn: binding(\.verifyVideos))
                }
            } header: { Text("Options") } footer: {
                Text("Backup progress also appears on the Lock Screen when Live Activities are allowed. Updates may pause while iOS suspends Fotera. Verification downloads each upload from the NAS and compares it byte for byte. Uploads continue while Fotera is in the background; iOS decides when background work runs, so opening Fotera now and then keeps backup current.")
            }
            Section {
                NavigationLink { BackupHistoryView() } label: { Label("Backup history", systemImage: "clock.arrow.circlepath") }
                NavigationLink { FreeUpSpaceView(backup: backup) } label: { Label("Free up space", systemImage: "iphone.and.arrow.forward") }
                Toggle(isOn: Binding(get: { BackupNotifier.enabled }, set: { value in
                    UserDefaults.standard.set(value, forKey: "backupNotifications")
                    if value { Task { await BackupNotifier.requestPermission() } }
                })) { Label("Notifications", systemImage: "bell") }
            } footer: {
                Text("Notifications tell you when a backup finishes in the background, when files need attention, or when backup hasn’t completed for 3 days.")
            }
            if let queue = backup.queue { TransferListSections(queue: queue) }
        }
        .navigationTitle("Backup")
        .refreshable { backup.start() }
        .onAppear { backup.updateCounts() }
        .sheet(isPresented: $choosing) {
            if let client = app.client {
                NavigationStack {
                    DestinationPicker(client: client, shared: backup.preferences.shared) {
                        backup.preferences.destination = $0; backup.save(); choosing = false
                    }
                }
            }
        }
    }
    private func binding(_ keyPath: WritableKeyPath<BackupPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { backup.preferences[keyPath: keyPath] }, set: { backup.preferences[keyPath: keyPath] = $0; backup.save() })
    }
}

struct BackupSummaryCard: View {
    @ObservedObject var backup: BackupController
    @ObservedObject private var uploadProgress = UploadProgress.shared
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                Circle().trim(from: 0, to: fraction).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor)
            }
            .frame(width: 56, height: 56)
            .animation(.easeInOut, value: fraction)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(backup.preferences.enabled ? backup.status : "Backup is off").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if let transfer = uploadProgress.summary(ids: Set(backup.queue?.records.map(\.id) ?? [])) {
                    Text(transfer).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if let queue = backup.queue, backup.preferences.enabled {
                    Text("\(queue.records.filter { $0.state == .uploading }.count) uploading · \(queue.records.filter { $0.state == .uploaded || $0.state == .verifying }.count) verifying · \(queue.attention.count) need attention")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let last = backup.lastCompleted, backup.preferences.enabled {
                    Text("Last completed \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(16)
    }
    private var fraction: CGFloat {
        guard backup.totalAssets > 0 else { return 0 }
        return CGFloat(backup.backedUpAssets) / CGFloat(backup.totalAssets)
    }
    private var title: String {
        guard backup.preferences.destination != nil, backup.totalAssets > 0 else { return "Photo backup" }
        return "\(backup.backedUpAssets.formatted()) of \(backup.totalAssets.formatted()) backed up"
    }
    private var icon: String {
        if !backup.preferences.enabled { return "icloud.slash" }
        if backup.running { return "arrow.up" }
        return backup.backedUpAssets >= backup.totalAssets ? "checkmark" : "icloud"
    }
}

/// The small cloud indicator in the Photos toolbar.
struct BackupBadge: View {
    @ObservedObject var backup: BackupController
    var body: some View {
        Image(systemName: icon)
            .symbolEffect(.pulse, isActive: backup.running)
            .foregroundStyle(color)
            .accessibilityLabel("Backup: " + backup.status)
    }
    private var icon: String {
        if !backup.preferences.enabled { return "icloud.slash" }
        if backup.running { return "arrow.triangle.2.circlepath.icloud" }
        if !(backup.queue?.attention.isEmpty ?? true) { return "exclamationmark.icloud" }
        return backup.backedUpAssets >= backup.totalAssets ? "checkmark.icloud" : "icloud"
    }
    private var color: Color {
        if !(backup.queue?.attention.isEmpty ?? true) { return .orange }
        return backup.preferences.enabled ? .accentColor : .secondary
    }
}

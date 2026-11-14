import SwiftUI
import WidgetKit
import Photos

struct TimelineSection: Identifiable, Sendable {
    let id: Date
    let title: String
    let items: [RemotePhoto]
}
struct Memory: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [RemotePhoto]
    var cover: RemotePhoto? { items.first(where: { !$0.isVideo }) ?? items.first }
}
enum TimelineGrouping: String, CaseIterable, Identifiable, Sendable {
    case day = "Day", month = "Month"
    var id: String { rawValue }
}

/// The timeline index for one space. It keeps the full metadata list on device so the grid,
/// memories, scrubber and offline browsing work without paging through the NAS.
@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var photos: [RemotePhoto] = []
    @Published private(set) var sections: [TimelineSection] = []
    /// `sections` as grid input, built once per change instead of on every redraw.
    @Published private(set) var gridSections: [GridSection] = []
    @Published private(set) var memories: [Memory] = []
    @Published private(set) var videos: [RemotePhoto] = []
    @Published private(set) var located: [RemotePhoto] = []
    @Published private(set) var years: [Int] = []
    @Published private(set) var syncing = false
    @Published private(set) var progress: String?
    @Published private(set) var failure: String?
    @Published private(set) var lastSynced: Date?
    @Published var grouping: TimelineGrouping = .day { didSet { if oldValue != grouping { rebuild() } } }
    private(set) var remotePhotos: [RemotePhoto] = []
    private var phonePhotos: [RemotePhoto] = []
    @Published private(set) var photoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var loadingPhone = false
    private var phoneTask: Task<Void, Never>?
    private var localObserver: NSObjectProtocol?
    private var uploadObserver: NSObjectProtocol?
    private var uploadRefreshTask: Task<Void, Never>?
    private var phoneGeneration = UUID()
    init(remotePhotos: [RemotePhoto] = [], phonePhotos: [RemotePhoto] = []) {
        self.remotePhotos = remotePhotos
        self.phonePhotos = phonePhotos
        localObserver = NotificationCenter.default.addObserver(forName: .foteraLocalLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPhoneLibrary() }
        }
        uploadObserver = NotificationCenter.default.addObserver(forName: .foteraUploadCatalogChanged, object: nil, queue: .main) { [weak self] note in
            let queueAccount = note.userInfo?["account"] as? String
            let space = note.userInfo?["shared"] as? Bool
            Task { @MainActor in
                guard let self, let queueAccount, let space else { return }
                self.uploadsChanged(account: queueAccount, shared: space)
            }
        }
        publishUnified()
    }
    deinit {
        if let localObserver { NotificationCenter.default.removeObserver(localObserver) }
        if let uploadObserver { NotificationCenter.default.removeObserver(uploadObserver) }
        uploadRefreshTask?.cancel()
    }
    private func uploadsChanged(account queueAccount: String, shared space: Bool) {
        guard client != nil, space == shared,
              queueAccount == account || queueAccount == account + "|backup" else { return }
        uploadRefreshTask?.cancel()
        let key = cacheAccount
        uploadRefreshTask = Task {
            // Coalesce adjacent batches; don't lose the update if a refresh is in flight.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await syncTask?.value
            guard !Task.isCancelled, cacheAccount == key else { return }
            publishUnified() // Apply newly confirmed local/NAS links even if the count is unchanged.
            refresh()
            await syncTask?.value
        }
    }
    func requestPhotoAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refreshPhoneLibrary()
    }
    func refreshPhoneLibrary() {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let accessChanged = access != photoAccess
        photoAccess = access
        phoneTask?.cancel()
        let generation = UUID(); phoneGeneration = generation
        guard client != nil, !shared else { phonePhotos = []; publishUnified(); return }
        loadingPhone = LocalAssets.allowed
        phoneTask = Task {
            if accessChanged { await PhoneLibraryIndex.shared.invalidate() }
            let items = await PhoneLibraryIndex.shared.photos()
            guard generation == phoneGeneration, !Task.isCancelled else { return }
            loadingPhone = false
            // Coming back to the app re-checks the phone; only rebuild the timeline when something changed.
            guard items != phonePhotos else { return }
            phonePhotos = items; publishUnified()
        }
    }
    private func publishUnified() {
        let remote = remotePhotos, local = phonePhotos
        let links = account.isEmpty ? [] : TransferQueue.shared(account: account).photoLinks + TransferQueue.shared(account: account + "|backup").photoLinks
        let space = shared
        let generation = UUID(); mergeGeneration = generation
        Task {
            let unified = await Task.detached(priority: .userInitiated) { UnifiedLibrary.merge(remote: remote, local: local, links: links, shared: space) }.value
            guard generation == mergeGeneration else { return }
            photos = unified; rebuild()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--matching-report") {
                let target = "IMG_3288"
                func entry(_ item: RemotePhoto) -> [String: Any] {
                    var value: [String: Any] = ["id": item.id, "filename": item.filename, "type": item.type]
                    value["time"] = item.time; value["localCaptureTime"] = item.localCaptureTime
                    value["localVersion"] = item.localVersion; value["localAssetID"] = item.localAssetID
                    value["resourceNames"] = item.localResourceNames
                    return value
                }
                let selectedRemote = remote.filter { $0.filename.uppercased().contains(target) }
                let selectedLocal = local.filter { ($0.localResourceNames ?? [$0.filename]).contains { $0.uppercased().contains(target) } }
                let report: [String: Any] = ["build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
                    "remoteCount": remote.count, "localCount": local.count, "mergedCount": unified.count,
                    "shared": space, "remote": selectedRemote.map(entry), "local": selectedLocal.map(entry),
                    "merged": unified.filter { $0.filename.uppercased().contains(target) }.map(entry),
                    "scores": selectedRemote.flatMap { nas in selectedLocal.map { phone in
                        ["remote": String(nas.id), "local": String(phone.id), "score": String(UnifiedLibrary.matchScore(remote: nas, local: phone) ?? -1)]
                    } }]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("fotera-match-report.json")
                    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }
            #endif
        }
    }
    private(set) var client: DSMClient?
    private(set) var shared = false
    private var account = ""
    private var widgetTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = UUID()
    private var mergeGeneration = UUID()
    private var buildGeneration = UUID()
    private var builtForDay = ""
    private var positions: [Int: Int] = [:]
    private var lastFullSync: Date? {
        get { UserDefaults.standard.object(forKey: "lastFullSync." + LibraryCache.hash(cacheAccount)) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastFullSync." + LibraryCache.hash(cacheAccount)) }
    }

    var cacheAccount: String { account + "|" + String(shared) }

    func attach(client: DSMClient?, account: String, shared: Bool) async {
        widgetTask?.cancel(); widgetTask = nil
        uploadRefreshTask?.cancel(); uploadRefreshTask = nil
        syncGeneration = UUID()
        syncTask?.cancel(); syncTask = nil; syncing = false
        self.client = client; self.account = account; self.shared = shared
        phonePhotos = []; phoneGeneration = UUID(); phoneTask?.cancel()
        apply([]); refreshPhoneLibrary(); failure = nil; progress = nil; lastSynced = nil
        FavoriteMarks.shared.replace([], loaded: false)
        guard client != nil else { return }
        let key = cacheAccount; let attachment = syncGeneration
        let snapshot = await LibraryCache.shared.read(account: key)
        guard key == cacheAccount, attachment == syncGeneration else { return }
        if let snapshot { apply(snapshot.photos); lastSynced = snapshot.updated }
        refresh()
    }
    /// Re-checks when the index is over 5 minutes old. Day labels ("Today") rebuild only after midnight.
    func refreshIfStale() {
        refreshPhoneLibrary()
        if builtForDay != Self.today() { rebuild() }
        guard let lastSynced else { refresh(); return }
        if Date().timeIntervalSince(lastSynced) > 300 { refresh() }
    }
    /// Ordinary refresh checks the count and newest page, reusing the cached tail when possible.
    /// Explicit rebuilds and six-hour reconciliation catch older edits, imports and deletions.
    func refresh(force: Bool = false) {
        guard let client, !syncing else { return }
        syncing = true; failure = nil
        let key = cacheAccount; let space = shared
        let generation = UUID(); syncGeneration = generation
        let needsFull = force || remotePhotos.isEmpty || lastFullSync.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        let known = remotePhotos
        syncTask = Task {
            defer { if generation == syncGeneration { syncing = false; progress = nil } }
            do {
                if !needsFull {
                    async let count = client.count(shared: space)
                    async let newest = client.items(.all, shared: space, offset: 0, limit: 100, withLocation: true)
                    let (total, page) = try await (count, newest)
                    guard key == cacheAccount, generation == syncGeneration else { return }
                    if let merged = Self.mergeRecent(known: known, page: page, total: total),
                       try await client.count(shared: space) == total {
                        try Task.checkCancellation()
                        guard key == cacheAccount, generation == syncGeneration else { return }
                        let changed = merged != remotePhotos
                        if changed { apply(merged) }
                        lastSynced = Date()
                        if changed { try? await LibraryCache.shared.write(account: key, snapshot: .init(photos: merged, updated: Date())) }
                        await refreshFavorites(client: client, space: space, generation: generation)
                        if !changed { refreshWidgetMemories() }
                        return
                    }
                }
                var indexed: [RemotePhoto] = []; var seen = Set<Int>(); var offset = 0
                while true {
                    try Task.checkCancellation()
                    let page = try await client.items(.all, shared: space, offset: offset, withLocation: true)
                    guard key == cacheAccount, generation == syncGeneration else { return }
                    indexed += page.filter { seen.insert($0.id).inserted }
                    offset += page.count
                    // Show the newest page right away on first launch.
                    if remotePhotos.isEmpty { apply(indexed) }
                    if offset > DSMClient.pageSize { progress = "Indexing \(indexed.count.formatted()) items…" }
                    if page.count < DSMClient.pageSize { break }
                }
                try Task.checkCancellation()
                guard key == cacheAccount, generation == syncGeneration else { return }
                let changed = indexed != remotePhotos
                apply(indexed)
                lastSynced = Date(); lastFullSync = Date()
                if changed { try? await LibraryCache.shared.write(account: key, snapshot: .init(photos: indexed, updated: Date())) }
                await refreshFavorites(client: client, space: space, generation: generation)
                guard generation == syncGeneration, !Task.isCancelled else { return }
                await FeatureWidgets.refresh(client: client, account: account)
            } catch {
                guard key == cacheAccount, generation == syncGeneration, !isCancelledRequest(error) else { return }
                failure = error.localizedDescription
            }
        }
        _ = syncTask
    }
    /// Merge only when the newest page accounts for every added item and overlaps the
    /// cached prefix in order. Older imports, deletions and replacements require reconciliation.
    nonisolated static func mergeRecent(known: [RemotePhoto], page: [RemotePhoto], total: Int) -> [RemotePhoto]? {
        guard !known.isEmpty, !page.isEmpty, total >= known.count else { return nil }
        let knownIDs = Set(known.map(\.id)), pageIDs = Set(page.map(\.id))
        guard knownIDs.count == known.count, pageIDs.count == page.count else { return nil }
        let overlap = page.filter { knownIDs.contains($0.id) }.map(\.id)
        guard !overlap.isEmpty, overlap == Array(known.prefix(overlap.count)).map(\.id),
              pageIDs.subtracting(knownIDs).count == total - known.count else { return nil }
        let result = page + known.filter { !pageIDs.contains($0.id) }
        return result.count == total ? result : nil
    }

    /// The list API doesn't report favorites, so fetch the (usually short) favorites list for tile hearts.
    private func refreshFavorites(client: DSMClient, space: Bool, generation: UUID) async {
        var favorites = Set<Int>(); var offset = 0
        while let page = try? await client.items(.favorites, shared: space, offset: offset) {
            favorites.formUnion(page.map(\.id)); offset += page.count
            if page.count < DSMClient.pageSize { break }
        }
        if generation == syncGeneration { FavoriteMarks.shared.replace(favorites) }
    }
    func refreshAndWait() async {
        // Don't hold the refresh for a route check: a failed read re-checks the route and retries.
        refreshPhoneLibrary()
        refresh()
        await syncTask?.value
        await phoneTask?.value
    }
    /// Removes items locally after a confirmed server deletion so the grid updates immediately.
    func remove(ids: Set<Int>, localAssetIDs: Set<String> = []) {
        guard !ids.isEmpty || !localAssetIDs.isEmpty else { return }
        // A refresh started before the deletion must not restore its old snapshot.
        if !ids.isEmpty {
            syncGeneration = UUID(); syncTask?.cancel(); syncTask = nil
            syncing = false; progress = nil
        }
        if !localAssetIDs.isEmpty {
            phoneGeneration = UUID(); phoneTask?.cancel(); phoneTask = nil
            loadingPhone = false
            phonePhotos.removeAll { item in
                item.localAssetID.map(localAssetIDs.contains) ?? false
            }
        }
        FavoriteMarks.shared.set(Array(ids), false)
        apply(remotePhotos.filter { !ids.contains($0.id) })
        let key = cacheAccount; let snapshot = LibraryCache.Snapshot(photos: remotePhotos, updated: lastSynced ?? Date())
        Task { try? await LibraryCache.shared.write(account: key, snapshot: snapshot) }
    }
    /// Favorites that still exist here, newest first, found by ID lookup rather than scanning the library.
    func favorites(_ ids: Set<Int>) -> [RemotePhoto] {
        ids.compactMap { positions[$0] }.sorted().map { photos[$0] }
    }

    private func apply(_ items: [RemotePhoto]) {
        remotePhotos = items
        publishUnified()
    }
    private static func today() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
    /// Groups the timeline and derived lists off the main thread; the newest build wins.
    private func rebuild() {
        let generation = UUID(); buildGeneration = generation
        let items = photos; let grouping = grouping
        builtForDay = Self.today()
        Task {
            let built = await Task.detached(priority: .userInitiated) { Self.build(items, grouping: grouping) }.value
            guard generation == buildGeneration else { return }
            sections = built.sections; gridSections = built.grid; memories = built.memories
            videos = built.videos; located = built.located; years = built.years; positions = built.positions
            refreshWidgetMemories()
        }
    }
    func refreshWidgetMemories() {
        widgetTask?.cancel()
        guard client != nil, !photos.isEmpty else { return }
        let key = cacheAccount
        widgetTask = Task {
            await WidgetMemories.refresh(memories: memories, photos: photos, shared: shared, account: key)
        }
    }
    private struct Built: Sendable {
        let sections: [TimelineSection]; let grid: [GridSection]; let memories: [Memory]
        let videos: [RemotePhoto]; let located: [RemotePhoto]; let years: [Int]; let positions: [Int: Int]
    }
    nonisolated private static func build(_ photos: [RemotePhoto], grouping: TimelineGrouping) -> Built {
        let calendar = PhotoTime.calendar
        let component: Calendar.Component = grouping == .day ? .day : .month
        var result: [TimelineSection] = []
        var currentStart: Date?
        var bucket: [RemotePhoto] = []
        var videos: [RemotePhoto] = [], located: [RemotePhoto] = []
        var years = Set<Int>(), positions: [Int: Int] = [:]
        positions.reserveCapacity(photos.count)
        func flush() {
            guard let start = currentStart, !bucket.isEmpty else { return }
            let title = start == .distantPast ? "Unknown date" : (grouping == .day ? PhotoTime.dayTitle(start) : PhotoTime.monthTitle(start))
            result.append(TimelineSection(id: start, title: title, items: bucket))
        }
        // Items arrive sorted newest-first, so one linear pass builds every section and list.
        for (index, item) in photos.enumerated() {
            positions[item.id] = index
            if item.isVideo { videos.append(item) }
            if item.additional?.gps != nil { located.append(item) }
            let date = item.date
            if let date { years.insert(calendar.component(.year, from: date)) }
            let start = date.flatMap { calendar.dateInterval(of: component, for: $0)?.start } ?? .distantPast
            if start != currentStart { flush(); currentStart = start; bucket = [] }
            bucket.append(item)
        }
        flush()
        // Undated items are rare but must not split into many sections.
        if result.filter({ $0.id == .distantPast }).count > 1 {
            let undated = result.filter { $0.id == .distantPast }.flatMap(\.items)
            result.removeAll { $0.id == .distantPast }
            result.append(TimelineSection(id: .distantPast, title: "Unknown date", items: undated))
        }
        let grid = result.map { GridSection(id: String($0.id.timeIntervalSince1970), title: $0.title, items: $0.items) }
        return Built(sections: result, grid: grid, memories: memories(from: photos), videos: videos, located: located,
                     years: years.sorted(by: >), positions: positions)
    }
    /// Match the exact capture month/day against the user's local Gregorian date.
    nonisolated static func memories(from photos: [RemotePhoto], now: Date = Date(), timeZone: TimeZone = .current) -> [Memory] {
        let calendar = PhotoTime.calendar
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let today = local.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year else { return [] }
        var byYear: [Int: [RemotePhoto]] = [:]
        for photo in photos {
            guard let date = photo.date else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let photoYear = parts.year, photoYear < year else { continue }
            guard parts.month == today.month, parts.day == today.day else { continue }
            byYear[photoYear, default: []].append(photo)
        }
        return byYear.keys.sorted(by: >).map { photoYear in
            let ago = year - photoYear
            return Memory(id: "otd-\(photoYear)", title: ago == 1 ? "1 year ago" : "\(ago) years ago", items: byYear[photoYear]!.sorted { ($0.time ?? 0) < ($1.time ?? 0) })
        }
    }
}

/// Keeps rotating widget memories fresh. Only small previews are shared with the widget.
enum WidgetMemories {
    /// The stamp whose saved previews were already checked this launch; avoids re-reading them on every rebuild.
    @MainActor private static var checkedStamp: String?
    @MainActor static func refresh(memories: [Memory], photos: [RemotePhoto], shared: Bool, account: String) async {
        // Personal library only: otherwise switching to Shared Space and back replaces the widget each time.
        guard WidgetSnapshotStore.isAvailable, !shared, !Task.isCancelled, UserDefaults.standard.object(forKey: "widgetMemories") as? Bool ?? true else { return }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let today = local.dateComponents([.year, .month, .day], from: Date())
        // Version the stamp so an existing adjacent-day widget selection is replaced.
        let stamp = "preview-v3-\(LibraryCache.hash(account))-\(today.year!)-\(today.month!)-\(today.day!)"
        guard checkedStamp != stamp else { return }
        guard WidgetSnapshot.needsRefresh(stamp: stamp, savedStamp: UserDefaults.standard.string(forKey: "widgetMemoriesStamp"), snapshots: WidgetSnapshotStore.readMemories()) else { checkedStamp = stamp; return }
        var picks: [(String, RemotePhoto)] = memories.flatMap { memory in memory.items.filter { !$0.isVideo }.prefix(2).map { (memory.title, $0) } }
        if picks.isEmpty {
            let stills = photos.filter { !$0.isVideo }
            picks = (0..<min(6, stills.count)).compactMap { _ in stills.randomElement() }.map { photo in
                (photo.date.map { PhotoTime.format($0, .dateTime.month(.abbreviated).day().year()) } ?? "From your library", photo)
            }
        }
        var entries: [WidgetSnapshot] = []
        for (title, photo) in picks.prefix(6) {
            var preview: UIImage?
            if let source = photo.thumbnailSource { preview = await ImagePipeline.shared.image(source, shared: shared, size: .xl) }
            if preview == nil { preview = await ImagePipeline.shared.originalPreview(photo, shared: shared, size: .xl) }
            guard let image = preview else { continue }
            guard !Task.isCancelled else { return }
            let data = WidgetSnapshot.previewData(image)
            entries.append(WidgetSnapshot(title: title, image: data, date: Date()))
        }
        guard !entries.isEmpty, !Task.isCancelled, UserDefaults.standard.object(forKey: "widgetMemories") as? Bool ?? true else { return }
        do {
            try WidgetSnapshotStore.saveMemories(entries)
            UserDefaults.standard.set(stamp, forKey: "widgetMemoriesStamp"); checkedStamp = stamp
            WidgetCenter.shared.reloadAllTimelines()
        } catch {}
    }
}

/// URLSession can report cancellation as URLError even before Task.isCancelled changes.
func isCancelledRequest(_ error: Error) -> Bool {
    if error is CancellationError || Task.isCancelled { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

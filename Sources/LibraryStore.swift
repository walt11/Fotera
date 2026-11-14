import SwiftUI
import WidgetKit

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
    private(set) var client: DSMClient?
    private(set) var shared = false
    private var account = ""
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = UUID()
    private var buildGeneration = UUID()
    private var builtForDay = ""
    private var positions: [Int: Int] = [:]
    private var lastFullSync: Date? {
        get { UserDefaults.standard.object(forKey: "lastFullSync." + LibraryCache.hash(cacheAccount)) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastFullSync." + LibraryCache.hash(cacheAccount)) }
    }

    var cacheAccount: String { account + "|" + String(shared) }

    func attach(client: DSMClient?, account: String, shared: Bool) async {
        syncGeneration = UUID()
        syncTask?.cancel(); syncTask = nil; syncing = false
        self.client = client; self.account = account; self.shared = shared
        apply([]); failure = nil; progress = nil; lastSynced = nil
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
        let needsFull = force || photos.isEmpty || lastFullSync.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        let known = photos
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
                        let changed = merged != photos
                        if changed { apply(merged) }
                        lastSynced = Date()
                        if changed { try? await LibraryCache.shared.write(account: key, snapshot: .init(photos: merged, updated: Date())) }
                        await refreshFavorites(client: client, space: space, generation: generation)
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
                    if photos.isEmpty { apply(indexed) }
                    if offset > DSMClient.pageSize { progress = "Indexing \(indexed.count.formatted()) items…" }
                    if page.count < DSMClient.pageSize { break }
                }
                try Task.checkCancellation()
                guard key == cacheAccount, generation == syncGeneration else { return }
                let changed = indexed != photos
                apply(indexed)
                lastSynced = Date(); lastFullSync = Date()
                if changed { try? await LibraryCache.shared.write(account: key, snapshot: .init(photos: indexed, updated: Date())) }
                await refreshFavorites(client: client, space: space, generation: generation)
                guard generation == syncGeneration, !Task.isCancelled else { return }
                await WidgetMemories.refresh(memories: memories, photos: photos, shared: space)
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
        refresh()
        await syncTask?.value
    }
    /// Removes items locally after a confirmed server deletion so the grid updates immediately.
    func remove(ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        FavoriteMarks.shared.set(Array(ids), false)
        apply(photos.filter { !ids.contains($0.id) })
        let key = cacheAccount; let snapshot = LibraryCache.Snapshot(photos: photos, updated: lastSynced ?? Date())
        Task { try? await LibraryCache.shared.write(account: key, snapshot: snapshot) }
    }
    /// Favorites that still exist here, newest first, found by ID lookup rather than scanning the library.
    func favorites(_ ids: Set<Int>) -> [RemotePhoto] {
        ids.compactMap { positions[$0] }.sorted().map { photos[$0] }
    }

    private func apply(_ items: [RemotePhoto]) {
        photos = items
        rebuild()
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
    @MainActor static func refresh(memories: [Memory], photos: [RemotePhoto], shared: Bool) async {
        guard WidgetSnapshotStore.isAvailable, !shared, UserDefaults.standard.object(forKey: "widgetMemories") as? Bool ?? true else { return }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let today = local.dateComponents([.year, .month, .day], from: Date())
        // Version the stamp so an existing adjacent-day widget selection is replaced.
        let stamp = "exact-day-v2-\(today.year!)-\(today.month!)-\(today.day!)"
        guard UserDefaults.standard.string(forKey: "widgetMemoriesStamp") != stamp else { return }
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
            let scale = min(1, 800 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            entries.append(WidgetSnapshot(title: title, image: data, date: Date()))
        }
        guard !entries.isEmpty else { return }
        do {
            try WidgetSnapshotStore.saveMemories(entries)
            UserDefaults.standard.set(stamp, forKey: "widgetMemoriesStamp")
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

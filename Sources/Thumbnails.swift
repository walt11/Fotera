import Photos
import SwiftUI
import ImageIO

/// A LIFO limiter: the most recently requested thumbnails (what is on screen now) load first.
@MainActor final class RequestLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async throws {
        if running < limit { running += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                MainActor.assumeIsolated {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiting.append((id, continuation)) }
                }
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if let next = waiting.popLast() { next.1.resume() } else { running -= 1 }
    }
}

/// A bounded look-ahead window: evict the oldest request when scrolling reaches new rows.
struct ThumbnailPrefetchWindow {
    let limit: Int
    private(set) var keys: [String] = []
    func contains(_ key: String) -> Bool { keys.contains(key) }
    mutating func insert(_ key: String) -> String? {
        guard !contains(key) else { return nil }
        keys.append(key)
        return keys.count > limit ? keys.removeFirst() : nil
    }
    mutating func remove(_ key: String) { keys.removeAll { $0 == key } }
}

/// Loads, decodes, and caches server previews in memory and on disk. One request per image at a time.
extension Notification.Name {
    /// Posted with the photo ID when a preview is regenerated, so only that photo's tiles reload.
    static let foteraPreviewRegenerated = Notification.Name("FoteraPreviewRegenerated")
}
@MainActor final class ImagePipeline {
    static let shared = ImagePipeline()
    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: (task: Task<UIImage?, Never>, waiters: Int)] = [:]
    private let limiter = RequestLimiter(limit: 6)
    private let groupLimiter = RequestLimiter(limit: 2)
    private let originalLimiter = RequestLimiter(limit: 2)
    /// Prefetches use their own small limiter so they never delay tiles that are on screen.
    private let prefetchLimiter = RequestLimiter(limit: 2)
    private var prefetchWindow = ThumbnailPrefetchWindow(limit: 16)
    private var prefetchTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private(set) var client: DSMClient?
    private var account = ""
    private init() {
        memory.totalCostLimit = 160_000_000
        memory.countLimit = 1500
    }
    func configure(client: DSMClient?, account: String) {
        if account != self.account { memory.removeAllObjects() }
        self.client = client; self.account = account
        for entry in prefetchTasks.values { entry.task.cancel() }
        prefetchTasks = [:]; prefetchWindow = ThumbnailPrefetchWindow(limit: 16)
        for entry in inflight.values { entry.task.cancel() }
        inflight = [:]
    }
    private func key(_ source: ThumbnailSource, _ shared: Bool, _ size: ThumbnailSize) -> String {
        "\(account)|\(shared)|\(size.rawValue)|\(source.kind)|\(source.id)|\(source.cacheKey)"
    }
    func cached(_ source: ThumbnailSource, shared: Bool, size: ThumbnailSize) -> UIImage? {
        memory.object(forKey: key(source, shared, size) as NSString)
    }
    private func localKey(_ photo: RemotePhoto, _ size: ThumbnailSize) -> String? {
        photo.localAssetID.map { "local|\($0)|\(photo.localVersion ?? 0)|\(size.rawValue)" }
    }
    /// A phone copy's tile image already in memory.
    func cachedLocal(_ photo: RemotePhoto?, size: ThumbnailSize) -> UIImage? {
        guard let photo, let key = localKey(photo, size) else { return nil }
        return memory.object(forKey: key as NSString)
    }
    /// Loads a phone copy at tile size (not iCloud) and keeps it with the NAS previews in memory,
    /// so scrolling back doesn't ask Photos again.
    func localImage(_ photo: RemotePhoto, size: ThumbnailSize) async -> UIImage? {
        guard let identifier = photo.localAssetID, let key = localKey(photo, size) else { return nil }
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let pixels: CGFloat = size == .xl ? 2400 : (size == .sm ? 256 : 480)
        guard let image = await LocalCopy.image(asset, maxPixels: pixels) else { return nil }
        memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }
    /// The sharpest preview already in memory, so the viewer can show something immediately.
    func bestCached(_ source: ThumbnailSource, shared: Bool) -> UIImage? {
        for size in [ThumbnailSize.xl, .m, .sm] { if let image = cached(source, shared: shared, size: size) { return image } }
        return nil
    }
    func image(_ source: ThumbnailSource, shared: Bool, size: ThumbnailSize) async -> UIImage? {
        let key = key(source, shared, size)
        if let image = memory.object(forKey: key as NSString) { return image }
        if var entry = inflight[key] {
            entry.waiters += 1; inflight[key] = entry
            return await wait(for: key, entry.task)
        }
        guard let client else { return nil }
        let limiter = limiter
        let maxPixels: CGFloat = size == .xl ? 2400 : (size == .sm ? 256 : 480)
        let task = Task<UIImage?, Never> { [account] in
            if let data = await LibraryCache.shared.preview(key: key), let image = await Self.decode(data, maxPixels: maxPixels) {
                return image
            }
            do {
                try await limiter.acquire()
                defer { limiter.release() }
                try Task.checkCancellation()
                // Synology may finish one preview size before the others.
                let sizes: [ThumbnailSize] = size == .sm ? [.sm, .m] : (size == .m ? [.m, .sm] : [.xl, .m, .sm])
                for candidate in sizes {
                    try Task.checkCancellation()
                    do {
                        let data = try await client.thumbnail(source, shared: shared, size: candidate)
                        guard let image = await Self.decode(data, maxPixels: maxPixels) else { continue }
                        try Task.checkCancellation()
                        // Keep lower-resolution fallbacks out of the requested size's persistent cache.
                        if !account.isEmpty, candidate == size { await LibraryCache.shared.savePreview(key: key, data: data) }
                        return image
                    } catch {
                        if isCancelledRequest(error) || Task.isCancelled { throw CancellationError() }
                    }
                }
                return nil
            } catch { return nil }
        }
        inflight[key] = (task, 1)
        return await wait(for: key, task)
    }
    /// Resolve incomplete/stale collection covers using the same routes as collection browsing.
    func groupPreview(_ fallback: GroupPreviewSource, shared: Bool, size: ThumbnailSize) async -> UIImage? {
        let group = fallback.group
        let key = "group|\(account)|\(shared)|\(size.rawValue)|\(fallback.kind)|\(group.id)|\(group.name)|\(group.additional?.thumbnail?.cache_key ?? "")|\(group.item_count ?? -1)"
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if var entry = inflight[key] {
            entry.waiters += 1; inflight[key] = entry
            return await wait(for: key, entry.task)
        }
        guard let client, ["place", "thing"].contains(fallback.kind) else { return nil }
        let task = Task<UIImage?, Never> {
            do {
                let photos: [RemotePhoto]
                try await self.groupLimiter.acquire()
                do {
                    defer { self.groupLimiter.release() }
                    try Task.checkCancellation()
                    if fallback.kind == "place" {
                        photos = try await client.items(.place(group.id), shared: shared, offset: 0, limit: 6)
                    } else {
                        guard !group.name.isEmpty else { return nil }
                        photos = try await client.search(keyword: group.name, shared: shared, offset: 0, limit: 6)
                    }
                }
                for photo in photos {
                    try Task.checkCancellation()
                    if let source = photo.thumbnailSource,
                       let image = await self.image(source, shared: shared, size: size) { return image }
                }
                // Only try one bounded still original after exhausting small server previews.
                if let photo = photos.first(where: { !$0.isVideo }) {
                    try Task.checkCancellation()
                    return await self.originalPreview(photo, shared: shared, size: size)
                }
            } catch { }
            return nil
        }
        inflight[key] = (task, 1)
        return await wait(for: key, task)
    }
    /// Bounded, cancellable look-ahead. Visible tiles join the same image request instead of
    /// downloading a second copy while a slow remote prefetch is still in flight.
    func prefetch(_ sources: [ThumbnailSource], shared: Bool, size: ThumbnailSize) {
        guard client != nil else { return }
        for source in sources {
            let key = key(source, shared, size)
            guard memory.object(forKey: key as NSString) == nil, inflight[key] == nil,
                  !prefetchWindow.contains(key) else { continue }
            if let evicted = prefetchWindow.insert(key) {
                prefetchTasks.removeValue(forKey: evicted)?.task.cancel()
            }
            let id = UUID()
            let task = Task(priority: .utility) {
                defer {
                    if prefetchTasks[key]?.id == id {
                        prefetchTasks[key] = nil; prefetchWindow.remove(key)
                    }
                }
                do { try await prefetchLimiter.acquire() } catch { return }
                defer { prefetchLimiter.release() }
                guard !Task.isCancelled else { return }
                _ = await image(source, shared: shared, size: size)
            }
            prefetchTasks[key] = (id, task)
        }
    }
    nonisolated static func isHEIC(_ photo: RemotePhoto) -> Bool {
        !photo.isVideo && ["heic", "heif", "hif"].contains((photo.filename as NSString).pathExtension.lowercased())
    }
    /// Some NAS items have no generated previews yet. Build a small local preview from the still original.
    /// Avoid unexpectedly downloading full videos or large RAW files while scrolling.
    func originalPreview(_ photo: RemotePhoto, shared: Bool, size: ThumbnailSize, regenerate: Bool = false) async -> UIImage? {
        if let local = await LocalCopy.asset(photo), let image = await LocalCopy.image(local, maxPixels: size == .xl ? 2400 : 480) { return image }
        guard !photo.isLocalOnly else { return nil }
        // RAW originals are large and slow to decode; leave those as placeholders until the NAS makes a preview.
        let raw: Set<String> = ["dng", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2", "srw", "pef"]
        guard !photo.isVideo, !raw.contains((photo.filename as NSString).pathExtension.lowercased()),
              let client else { return nil }
        let limit: Int64 = Self.isHEIC(photo) ? 50_000_000 : 15_000_000
        if let bytes = photo.filesize, (bytes <= 0 || bytes > limit) { return nil }
        let source = photo.thumbnailSource ?? ThumbnailSource(id: photo.id, cacheKey: "original-\(photo.time ?? 0)-\(photo.filesize ?? -1)", kind: "unit")
        let cacheKey = key(source, shared, size)
        if !regenerate, let image = memory.object(forKey: cacheKey as NSString) { return image }
        let requestKey = cacheKey + (regenerate ? "|regenerate" : "|original")
        if var entry = inflight[requestKey] {
            entry.waiters += 1; inflight[requestKey] = entry
            return await wait(for: requestKey, entry.task)
        }
        let gridKeys = [ThumbnailSize.sm, .m].map { key(source, shared, $0) }
        let limiter = originalLimiter
        let task = Task<UIImage?, Never> {
            if !regenerate, let data = await LibraryCache.shared.preview(key: cacheKey), let image = await Self.decode(data, maxPixels: size == .xl ? 2400 : 480) { return image }
            do {
                try await limiter.acquire(); defer { limiter.release() }
                try Task.checkCancellation()
                if photo.filesize == nil {
                    let details = try await client.details(id: photo.id, shared: shared)
                    guard let bytes = details.filesize, bytes > 0, bytes <= limit else { return nil }
                }
                let file = try await client.original(photo, shared: shared, useOfflineCache: true)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let image = await Self.decode(file: file, maxPixels: size == .xl ? 2400 : 480) else { return nil }
                try Task.checkCancellation()
                if let data = await Self.jpegPreview(image) {
                    await LibraryCache.shared.savePreview(key: cacheKey, data: data)
                    // A manual high-quality preview also replaces placeholder grid previews.
                    if size == .xl, let small = await Self.decode(data, maxPixels: 480), let jpeg = await Self.jpegPreview(small) {
                        for gridKey in gridKeys {
                            await LibraryCache.shared.savePreview(key: gridKey, data: jpeg)
                            self.memory.setObject(small, forKey: gridKey as NSString)
                        }
                    }
                } else { return nil }
                return image
            } catch { return nil }
        }
        inflight[requestKey] = (task, 1)
        let image = await wait(for: requestKey, task)
        if let image { memory.setObject(image, forKey: cacheKey as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
        if regenerate, image != nil, !Task.isCancelled {
            NotificationCenter.default.post(name: .foteraPreviewRegenerated, object: nil, userInfo: ["photo": photo.id, "unit": source.id])
        }
        return image
    }
    private func wait(for key: String, _ task: Task<UIImage?, Never>) async -> UIImage? {
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.drop(key, task: task) }
        }
        if let image, !task.isCancelled {
            memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        if inflight[key]?.task == task { inflight[key] = nil }
        return Task.isCancelled || task.isCancelled ? nil : image
    }
    private func drop(_ key: String, task: Task<UIImage?, Never>) {
        guard var entry = inflight[key], entry.task == task else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 { entry.task.cancel(); inflight[key] = nil } else { inflight[key] = entry }
    }
    /// HDR/high-bit-depth HEIC thumbnails may not support UIImage.jpegData directly.
    /// Render into standard-range RGB first so the persistent JPEG works on every screen.
    nonisolated static func jpegPreview(_ image: UIImage) async -> Data? {
        await Task.detached(priority: .utility) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true; format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            return renderer.jpegData(withCompressionQuality: 0.85) { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }.value
    }
    /// Downsamples off the main thread so large previews never decode at full size.
    nonisolated static func decode(_ data: Data, maxPixels: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
    nonisolated static func decode(file: URL, maxPixels: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}

struct GroupPreviewSource: Hashable {
    let group: RemoteGroup
    let kind: String
}

/// A square, cropped preview that loads lazily and cancels when scrolled away.
struct ThumbnailView: View {
    let source: ThumbnailSource?
    let shared: Bool
    var size: ThumbnailSize = .m
    var contentMode: ContentMode = .fill
    var fallbackPhoto: RemotePhoto? = nil
    var fallbackGroup: GroupPreviewSource? = nil
    var animatesLoading = true
    @State private var image: UIImage?
    @State private var revision = 0
    @Environment(\.scenePhase) private var scenePhase
    private struct RequestID: Hashable {
        let source: ThumbnailSource?
        let shared: Bool
        let size: String
        let active: Bool
        let photoID: Int?
        let localVersion: Double?
        let revision: Int
        let group: GroupPreviewSource?
        var content: [AnyHashable] { [source, shared, size, photoID, localVersion, revision, group] }
    }
    @State private var shownFor: [AnyHashable]?
    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let shown = image ?? source.flatMap({ ImagePipeline.shared.cached($0, shared: shared, size: size) })
                    ?? ImagePipeline.shared.cachedLocal(fallbackPhoto, size: size) {
                    Image(uiImage: shown).resizable().aspectRatio(contentMode: contentMode)
                        .transition(animatesLoading ? .opacity : .identity)
                }
            }
            .clipped()
            .onReceive(NotificationCenter.default.publisher(for: .foteraPreviewRegenerated)) { note in
                let photo = note.userInfo?["photo"] as? Int, unit = note.userInfo?["unit"] as? Int
                guard (photo != nil && photo == fallbackPhoto?.id) || (unit != nil && unit == source?.id) else { return }
                revision += 1
            }
            .task(id: RequestID(source: source, shared: shared, size: size.rawValue, active: scenePhase == .active, photoID: fallbackPhoto?.id, localVersion: fallbackPhoto?.localVersion, revision: revision, group: fallbackGroup)) {
                // Keep the current image across scene changes so the app-switcher snapshot isn't blank.
                let request = RequestID(source: source, shared: shared, size: size.rawValue, active: true, photoID: fallbackPhoto?.id, localVersion: fallbackPhoto?.localVersion, revision: revision, group: fallbackGroup)
                if shownFor != request.content { image = nil; shownFor = request.content }
                #if DEBUG
                if StoreScreenshots.enabled {
                    image = StoreScreenshots.image(source?.id ?? fallbackPhoto?.id)
                    return
                }
                #endif
                guard scenePhase == .active, image == nil else { return }
                if let cached = source.flatMap({ ImagePipeline.shared.cached($0, shared: shared, size: size) })
                    ?? ImagePipeline.shared.cachedLocal(fallbackPhoto, size: size) { image = cached; return }
                // A transient failure or a preview still being generated must not leave a visible tile blank forever.
                for delay in [0, 2, 5, 15, 30, 60] {
                    do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) }; try Task.checkCancellation() }
                    catch { return }
                    var loaded: UIImage?
                    if let fallbackPhoto, fallbackPhoto.localAssetID != nil { loaded = await ImagePipeline.shared.localImage(fallbackPhoto, size: size) }
                    if loaded == nil, let source { loaded = await ImagePipeline.shared.image(source, shared: shared, size: size) }
                    guard !Task.isCancelled else { return }
                    if loaded == nil, let fallbackPhoto {
                        // Let rapidly passing tiles disappear before starting a large original download.
                        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                        loaded = await ImagePipeline.shared.originalPreview(fallbackPhoto, shared: shared, size: size)
                    }
                    guard !Task.isCancelled else { return }
                    if loaded == nil, let fallbackGroup {
                        loaded = await ImagePipeline.shared.groupPreview(fallbackGroup, shared: shared, size: size)
                    }
                    guard !Task.isCancelled else { return }
                    if let loaded {
                        if animatesLoading { withAnimation(.easeOut(duration: 0.15)) { image = loaded } }
                        else { image = loaded }
                        return
                    }
                }
            }
    }
}

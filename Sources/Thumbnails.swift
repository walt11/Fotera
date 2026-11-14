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

/// Loads, decodes, and caches server previews in memory and on disk. One request per image at a time.
@MainActor final class ImagePipeline {
    static let shared = ImagePipeline()
    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: (task: Task<UIImage?, Never>, waiters: Int)] = [:]
    private let limiter = RequestLimiter(limit: 6)
    private let originalLimiter = RequestLimiter(limit: 2)
    /// Prefetches use their own small limiter so they never delay tiles that are on screen.
    private let prefetchLimiter = RequestLimiter(limit: 2)
    private var prefetching = Set<String>()
    private(set) var client: DSMClient?
    private var account = ""
    private init() {
        memory.totalCostLimit = 160_000_000
        memory.countLimit = 1500
    }
    func configure(client: DSMClient?, account: String) {
        if account != self.account { memory.removeAllObjects() }
        self.client = client; self.account = account
        for entry in inflight.values { entry.task.cancel() }
        inflight = [:]
    }
    private func key(_ source: ThumbnailSource, _ shared: Bool, _ size: ThumbnailSize) -> String {
        "\(account)|\(shared)|\(size.rawValue)|\(source.kind)|\(source.id)|\(source.cacheKey)"
    }
    func cached(_ source: ThumbnailSource, shared: Bool, size: ThumbnailSize) -> UIImage? {
        memory.object(forKey: key(source, shared, size) as NSString)
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
        let maxPixels: CGFloat = size == .xl ? 2400 : 480
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
    /// Loads upcoming thumbnails into the memory cache at low priority.
    func prefetch(_ sources: [ThumbnailSource], shared: Bool, size: ThumbnailSize) {
        guard let client else { return }
        let limiter = prefetchLimiter
        for source in sources {
            let key = key(source, shared, size)
            guard memory.object(forKey: key as NSString) == nil, inflight[key] == nil, prefetching.insert(key).inserted else { continue }
            Task(priority: .utility) { [account] in
                defer { prefetching.remove(key) }
                var data = await LibraryCache.shared.preview(key: key)
                if data == nil {
                    guard (try? await limiter.acquire()) != nil else { return }
                    defer { limiter.release() }
                    guard memory.object(forKey: key as NSString) == nil, inflight[key] == nil else { return }
                    data = try? await client.thumbnail(source, shared: shared, size: size)
                    if let data, !account.isEmpty { await LibraryCache.shared.savePreview(key: key, data: data) }
                }
                guard let data, let image = await Self.decode(data, maxPixels: size == .xl ? 2400 : 480) else { return }
                memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
            }
        }
    }
    /// Some NAS items have no generated previews yet. Build a small local preview from the still original.
    /// Avoid unexpectedly downloading full videos or large RAW files while scrolling.
    func originalPreview(_ photo: RemotePhoto, shared: Bool, size: ThumbnailSize) async -> UIImage? {
        // RAW originals are large and slow to decode; leave those as placeholders until the NAS makes a preview.
        let raw: Set<String> = ["dng", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2", "srw", "pef"]
        guard !photo.isVideo, !raw.contains((photo.filename as NSString).pathExtension.lowercased()),
              let bytes = photo.filesize, bytes > 0, bytes <= 15_000_000, let client else { return nil }
        let source = photo.thumbnailSource ?? ThumbnailSource(id: photo.id, cacheKey: "original-\(photo.time ?? 0)-\(bytes)", kind: "unit")
        let cacheKey = key(source, shared, size)
        if let image = memory.object(forKey: cacheKey as NSString) { return image }
        let requestKey = cacheKey + "|original"
        if var entry = inflight[requestKey] {
            entry.waiters += 1; inflight[requestKey] = entry
            return await wait(for: requestKey, entry.task)
        }
        let limiter = originalLimiter
        let task = Task<UIImage?, Never> {
            if let data = await LibraryCache.shared.preview(key: cacheKey), let image = await Self.decode(data, maxPixels: size == .xl ? 2400 : 480) { return image }
            do {
                try await limiter.acquire(); defer { limiter.release() }
                try Task.checkCancellation()
                let file = try await client.original(photo, shared: shared, useOfflineCache: true)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let image = await Self.decode(file: file, maxPixels: size == .xl ? 2400 : 480) else { return nil }
                try Task.checkCancellation()
                if let data = image.jpegData(compressionQuality: 0.85) { await LibraryCache.shared.savePreview(key: cacheKey, data: data) }
                return image
            } catch { return nil }
        }
        inflight[requestKey] = (task, 1)
        let image = await wait(for: requestKey, task)
        if let image { memory.setObject(image, forKey: cacheKey as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
        return image
    }
    private func wait(for key: String, _ task: Task<UIImage?, Never>) async -> UIImage? {
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.drop(key, task: task) }
        }
        if let image {
            memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        if inflight[key]?.task == task { inflight[key] = nil }
        return image
    }
    private func drop(_ key: String, task: Task<UIImage?, Never>) {
        guard var entry = inflight[key], entry.task == task else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 { entry.task.cancel(); inflight[key] = nil } else { inflight[key] = entry }
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

/// A square, cropped preview that loads lazily and cancels when scrolled away.
struct ThumbnailView: View {
    let source: ThumbnailSource?
    let shared: Bool
    var size: ThumbnailSize = .m
    var contentMode: ContentMode = .fill
    var fallbackPhoto: RemotePhoto? = nil
    @State private var image: UIImage?
    @Environment(\.scenePhase) private var scenePhase
    private struct RequestID: Hashable {
        let source: ThumbnailSource?
        let shared: Bool
        let size: String
        let active: Bool
        let photoID: Int?
        var content: [AnyHashable] { [source, shared, size, photoID] }
    }
    @State private var shownFor: [AnyHashable]?
    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let shown = image ?? source.flatMap({ ImagePipeline.shared.cached($0, shared: shared, size: size) }) {
                    Image(uiImage: shown).resizable().aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: RequestID(source: source, shared: shared, size: size.rawValue, active: scenePhase == .active, photoID: fallbackPhoto?.id)) {
                // Keep the current image across scene changes so the app-switcher snapshot isn't blank.
                let request = RequestID(source: source, shared: shared, size: size.rawValue, active: true, photoID: fallbackPhoto?.id)
                if shownFor != request.content { image = nil; shownFor = request.content }
                guard scenePhase == .active, image == nil else { return }
                if let source, let cached = ImagePipeline.shared.cached(source, shared: shared, size: size) { image = cached; return }
                // A transient failure or a preview still being generated must not leave a visible tile blank forever.
                for delay in [0, 2, 5, 15, 30, 60] {
                    do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) }; try Task.checkCancellation() }
                    catch { return }
                    var loaded: UIImage?
                    if let source { loaded = await ImagePipeline.shared.image(source, shared: shared, size: size) }
                    guard !Task.isCancelled else { return }
                    if loaded == nil, let fallbackPhoto {
                        loaded = await ImagePipeline.shared.originalPreview(fallbackPhoto, shared: shared, size: size)
                    }
                    guard !Task.isCancelled else { return }
                    if let loaded {
                        withAnimation(.easeOut(duration: 0.15)) { image = loaded }
                        return
                    }
                }
            }
    }
}

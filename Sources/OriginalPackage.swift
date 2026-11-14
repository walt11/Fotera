import Foundation
import ZIPFoundation
import Photos
import PhotosUI
import SwiftUI

struct OriginalPackage {
    let directory: URL
    let files: [URL]
    static func unpack(_ url: URL) throws -> OriginalPackage {
        let archive = try Archive(url: url, accessMode: .read)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FoteraLive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var files: [URL] = []; var size: UInt64 = 0
            for entry in archive {
                try Task.checkCancellation()
                guard entry.type == .file else { continue }
                let ext = (entry.path as NSString).pathExtension.lowercased()
                guard ["heic", "heif", "jpg", "jpeg", "png", "mov", "mp4", "dng"].contains(ext) else { continue }
                size += entry.uncompressedSize
                guard size <= 500_000_000, files.count < 16 else { throw ConnectionError.invalidResponse }
                // Never use server-supplied paths or extract symlinks.
                let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                _ = try archive.extract(entry, to: target)
                files.append(target)
            }
            guard !files.isEmpty else { throw ConnectionError.invalidResponse }
            return OriginalPackage(directory: directory, files: files)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    @MainActor func livePhoto(placeholder: UIImage?) async throws -> PHLivePhoto {
        let images = files.filter { !["mov", "mp4"].contains($0.pathExtension) }
        let videos = files.filter { ["mov", "mp4"].contains($0.pathExtension) }
        guard images.count == 1, videos.count == 1 else { throw ConnectionError.invalidResponse }
        return try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [images[0], videos[0]], placeholderImage: placeholder,
                                targetSize: .zero, contentMode: .aspectFit) { photo, info in
                if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                if let photo { continuation.resume(returning: photo) }
                else { continuation.resume(throwing: (info[PHLivePhotoInfoErrorKey] as? Error) ?? ConnectionError.invalidResponse) }
            }
        }
    }
}
/// Prepares Live Photos ahead of playback and keeps the last few, so press-and-hold plays at once
/// and replays don't download again. Each entry owns its unpacked files until evicted.
@MainActor final class LivePhotoCache {
    static let shared = LivePhotoCache()
    private struct Entry { let photo: PHLivePhoto; let directory: URL }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var inflight: [String: Task<PHLivePhoto, Error>] = [:]
    private let limit = 8
    nonisolated static func key(_ item: RemotePhoto, client: DSMClient, shared: Bool) -> String {
        "\(ObjectIdentifier(client).hashValue)|\(shared)|\(item.id)|\(item.additional?.thumbnail?.cache_key ?? "")"
    }
    func cached(_ item: RemotePhoto, client: DSMClient, shared: Bool) -> PHLivePhoto? { entries[Self.key(item, client: client, shared: shared)]?.photo }
    func prepare(_ item: RemotePhoto, client: DSMClient, shared: Bool, albumID: Int?, placeholder: UIImage?) async throws -> PHLivePhoto {
        let key = Self.key(item, client: client, shared: shared)
        if let entry = entries[key] { touch(key); return entry.photo }
        if let task = inflight[key] { return try await task.value }
        let task = Task<PHLivePhoto, Error> {
            let archive = try await client.livePackage(item, shared: shared, albumID: albumID, useOfflineCache: true)
            defer { try? FileManager.default.removeItem(at: archive) }
            let package = try await Task.detached(priority: .userInitiated) { try OriginalPackage.unpack(archive) }.value
            do {
                let photo = try await package.livePhoto(placeholder: placeholder)
                store(key, Entry(photo: photo, directory: package.directory))
                return photo
            } catch {
                try? FileManager.default.removeItem(at: package.directory); throw error
            }
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }
    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func store(_ key: String, _ entry: Entry) {
        entries[key] = entry; touch(key)
        while order.count > limit {
            let old = order.removeFirst()
            if let evicted = entries.removeValue(forKey: old) { try? FileManager.default.removeItem(at: evicted.directory) }
        }
    }
    func clear() {
        for entry in entries.values { try? FileManager.default.removeItem(at: entry.directory) }
        entries = [:]; order = []
    }
}
struct LivePhotoPlayer: UIViewRepresentable {
    let photo: PHLivePhoto
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.livePhoto = photo
        view.startPlayback(with: .full)
        return view
    }
    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {}
}

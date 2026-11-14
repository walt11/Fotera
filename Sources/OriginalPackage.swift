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

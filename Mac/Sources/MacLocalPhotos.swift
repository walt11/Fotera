import AppKit
import Photos
import PhotosUI
import SwiftUI
import ZIPFoundation

@MainActor final class MacLocalPhotos: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var photos: [RemotePhoto] = []
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey:"mac.photos.enabled")
    @Published var error: String?
    private var observing = false
    private var generation = UUID()
    func setEnabled(_ value: Bool) async {
        guard !ProcessInfo.processInfo.arguments.contains("--demo") else {return}
        if value {
            let status = await PHPhotoLibrary.requestAuthorization(for:.readWrite)
            guard status == .authorized || status == .limited else { error = "Allow Fotera access to Photos in System Settings → Privacy & Security → Photos."; return }
        }
        enabled = value; UserDefaults.standard.set(value,forKey:"mac.photos.enabled")
        if value { await reload() } else { generation = UUID(); photos = []; if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self); observing = false } }
    }
    func reload() async {
        guard enabled, PHPhotoLibrary.authorizationStatus(for:.readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for:.readWrite) == .limited else { return }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        let token = UUID(); generation = token
        let result = await Task.detached(priority:.utility) {
            let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key:"creationDate",ascending:false)]
            let assets = PHAsset.fetchAssets(with:options); var result: [RemotePhoto] = []
            assets.enumerateObjects { asset,_,_ in
                let resources = PHAssetResource.assetResources(for:asset)
                guard let resource = resources.first(where:{$0.type == (asset.mediaType == .video ? .video : .photo)}) ?? resources.first else { return }
                let wall = asset.creationDate.map{$0.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for:$0))}
                var item = RemotePhoto(id:UnifiedLibrary.localID(asset.localIdentifier),filename:resource.originalFilename,time:wall,type:asset.mediaType == .video ? "video" : asset.mediaSubtypes.contains(.photoLive) ? "live" : "photo")
                item.localAssetID = asset.localIdentifier; item.localVersion = asset.modificationDate?.timeIntervalSince1970; item.localCaptureTime = asset.creationDate?.timeIntervalSince1970
                item.localResourceNames = resources.map(\.originalFilename)
                item.additional = .init(thumbnail:nil,gps:asset.location.map{.init(latitude:$0.coordinate.latitude,longitude:$0.coordinate.longitude)},video_meta:asset.mediaType == .video ? .init(duration:Int(asset.duration*1000)) : nil)
                result.append(item)
            }; return result
        }.value
        guard generation == token else { return }; photos = result
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) { Task { @MainActor [weak self] in await self?.reload() } }
    static func asset(_ photo: RemotePhoto) -> PHAsset? { guard let id = photo.localAssetID else { return nil }; return PHAsset.fetchAssets(withLocalIdentifiers:[id],options:nil).firstObject }
    static func image(_ photo: RemotePhoto, edge: CGFloat) async -> NSImage? {
        guard let asset = asset(photo) else { return nil }
        let options = PHImageRequestOptions(); options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = true; options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for:asset,targetSize:CGSize(width:edge,height:edge),contentMode:.aspectFit,options:options) { image,info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }; continuation.resume(returning:image)
            }
        }
    }
    static func player(_ photo: RemotePhoto) async -> AVPlayer? {
        guard let asset = asset(photo) else { return nil }; let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in PHImageManager.default().requestPlayerItem(forVideo:asset,options:options) { item,_ in continuation.resume(returning:item.map{AVPlayer(playerItem:$0)}) } }
    }
    static func live(_ photo: RemotePhoto) async -> PHLivePhoto? {
        guard let asset = asset(photo) else { return nil }; let options = PHLivePhotoRequestOptions(); options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in PHImageManager.default().requestLivePhoto(for:asset,targetSize:CGSize(width:2000,height:2000),contentMode:.aspectFit,options:options) { live,info in if info?[PHImageResultIsDegradedKey] as? Bool == true { return }; continuation.resume(returning:live) } }
    }
}
struct MacLiveView: NSViewRepresentable {
    let photo: PHLivePhoto
    func makeNSView(context: Context) -> PHLivePhotoView { let view = MacPlayableLivePhotoView(); view.livePhoto = photo; return view }
    func updateNSView(_ view: PHLivePhotoView,context: Context) { view.livePhoto = photo }
}
struct MacLivePackage {
    let directory: URL
    let files: [URL]
    static func unpack(_ file: URL) throws -> Self {
        let archive = try Archive(url:file,accessMode:.read,pathEncoding:nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoteraLive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        do {
            var files: [URL] = []; var bytes: UInt64 = 0
            for entry in archive where entry.type == .file {
                let ext = (entry.path as NSString).pathExtension.lowercased()
                guard ["heic","heif","jpg","jpeg","png","mov","mp4"].contains(ext) else { continue }
                bytes += entry.uncompressedSize; guard bytes <= 500_000_000, files.count < 16 else { throw ConnectionError.invalidResponse }
                let target = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                _ = try archive.extract(entry,to:target); files.append(target)
            }
            return Self(directory:root,files:files)
        } catch { try? FileManager.default.removeItem(at:root); throw error }
    }
    func live() async throws -> PHLivePhoto {
        guard files.count == 2 else { throw ConnectionError.invalidResponse }
        return try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs:files,placeholderImage:nil,targetSize:CGSize(width:2000,height:2000),contentMode:.aspectFit) { live,info in
                if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                if let live { continuation.resume(returning:live) } else { continuation.resume(throwing:ConnectionError.invalidResponse) }
            }
        }
    }
}

final class MacPlayableLivePhotoView: PHLivePhotoView {
    override func mouseDown(with event: NSEvent) { startPlayback(with:.full) }
    override func mouseUp(with event: NSEvent) { stopPlayback() }
}

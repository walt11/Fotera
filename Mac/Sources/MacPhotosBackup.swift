import SwiftUI
import Photos

@MainActor final class MacPhotosBackup: ObservableObject {
    @Published var enabled = false
    @Published var includeVideos = true
    @Published var includeEdited = false
    @Published var onlyNew = false
    @Published private(set) var scanning = false
    @Published var failure:String?
    private weak var model:MacModel?
    private var timer:Task<Void,Never>?
    private var scan:Task<Void,Never>?
    private var key = ""
    private var account = ""
    private var destination = "/"
    private var space = false
    private var from:Date?
    private var dated = true
    private var scanGeneration = UUID()
    init(model:MacModel) {self.model = model}
    func attach() {
        stop(); guard let model else {return}; account = model.account; key = "mac.photosBackup." + LibraryCache.hash(account)
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey:key + ".enabled"); includeEdited = defaults.bool(forKey:key + ".edited"); dated = defaults.object(forKey:key + ".dated") as? Bool ?? true; includeVideos = defaults.object(forKey:key + ".videos") as? Bool ?? true
        from = defaults.object(forKey:key + ".from") as? Date; onlyNew = from != nil
        destination = defaults.string(forKey:key + ".folder") ?? "/"; space = defaults.bool(forKey:key + ".shared")
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanIfEnabled()
                do {try await Task.sleep(for:.seconds(60))} catch {return}
            }
        }
    }
    func stop() {scanGeneration = UUID(); timer?.cancel(); scan?.cancel(); timer = nil; scan = nil; scanning = false; enabled = false}
    func configure(_ value:Bool) async {
        guard let model else {return}
        if value {
            await model.localPhotos.setEnabled(true)
            guard PHPhotoLibrary.authorizationStatus(for:.readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for:.readWrite) == .limited else {failure = "Photos access is required."; return}
            destination = model.targetFolder; space = model.shared; dated = model.backups.yearMonth; from = onlyNew ? Date() : nil
        }
        enabled = value; let defaults = UserDefaults.standard
        defaults.set(value,forKey:key + ".enabled"); defaults.set(includeEdited,forKey:key + ".edited"); defaults.set(dated,forKey:key + ".dated"); defaults.set(includeVideos,forKey:key + ".videos"); defaults.set(from,forKey:key + ".from"); defaults.set(destination,forKey:key + ".folder"); defaults.set(space,forKey:key + ".shared")
        if value {await scanIfEnabled()} else {scan?.cancel(); model.backups.expectedResources = [:]}
    }
    func scanIfEnabled() async {
        guard enabled, !scanning, let model, model.client != nil, account == model.account, !model.backups.paused else {return}
        scanning = true
        let expected = account, token = UUID(); scanGeneration = token
        scan = Task {
            defer {if scanGeneration == token {scanning = false; scan = nil}}
            do {
                let status = PHPhotoLibrary.authorizationStatus(for:.readWrite)
                guard status == .authorized || status == .limited else {throw CocoaError(.fileReadNoPermission)}
                let videos = includeVideos, edited = includeEdited, cutoff = from
                let candidates = await Task.detached(priority:.utility) {
                    let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key:"creationDate",ascending:true)]
                    let results = PHAsset.fetchAssets(with:options); var values:[MacBackupCandidate] = []
                    results.enumerateObjects {asset,_,_ in
                        guard videos || asset.mediaType != .video, cutoff == nil || (asset.creationDate ?? .distantPast) >= cutoff! else {return}
                        let resources = PHAssetResource.assetResources(for:asset).filter {
                            [PHAssetResourceType.photo,.video,.pairedVideo,.alternatePhoto].contains($0.type) ||
                            (edited && asset.hasAdjustments && [PHAssetResourceType.fullSizePhoto,.fullSizeVideo,.fullSizePairedVideo].contains($0.type))
                        }
                        if !resources.isEmpty {values.append(.init(asset:asset,resources:resources))}
                    }; return values
                }.value
                guard scanGeneration == token, model.account == expected else {return}
                model.backups.expectedResources = Dictionary(uniqueKeysWithValues:candidates.map{(MacBackupProgress.key(asset:$0.asset.localIdentifier,shared:space),Set($0.keys))})
                for candidate in candidates {
                    let asset = candidate.asset
                    for resource in candidate.resources {
                        try Task.checkCancellation(); guard enabled, model.account == expected else {return}
                        let identity = candidate.key(resource)
                        if model.backups.records.contains(where:{$0.resourceKey == identity && $0.shared == space}) {continue}
                        let pending = model.backups.records.filter{$0.state != .complete}
                        if pending.count >= 30 || pending.reduce(Int64(0),{$0 + $1.size}) >= 2_000_000_000 {return}
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                        defer {try? FileManager.default.removeItem(at:directory)}
                        let file = directory.appendingPathComponent((resource.originalFilename as NSString).lastPathComponent)
                        try await Self.export(resource,to:file)
                        try Task.checkCancellation(); guard enabled, model.account == expected else {return}
                        let date = asset.creationDate.map{$0.addingTimeInterval(Double(TimeZone.current.secondsFromGMT(for:$0)))}
                        await model.backups.enqueue([file],folder:destination,shared:space,local:.init(assetID:asset.localIdentifier,version:asset.modificationDate?.timeIntervalSince1970,key:identity,captureDate:date),organizeByDate:dated)
                        if let error = model.backups.error {throw FeatureError.message(error)}
                    }
                }
                failure = nil
            } catch {if !isCancelledRequest(error), scanGeneration == token {failure = error.localizedDescription}}
        }
        await scan?.value
    }
    static func export(_ resource:PHAssetResource,to url:URL) async throws {
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in PHAssetResourceManager.default().writeData(for:resource,toFile:url,options:options) {error in if let error {continuation.resume(throwing:error)} else {continuation.resume()}} }
    }
}
struct MacPhotosBackupSettings:View {
    @ObservedObject var controller:MacPhotosBackup
    @State private var confirming = false
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Toggle("Back up Apple Photos automatically",isOn:Binding(get:{controller.enabled},set:{ value in if value {confirming = true} else {Task {await controller.configure(false)}}}))
            if !controller.enabled {Toggle("Include videos",isOn:$controller.includeVideos); Toggle("Also back up edited versions",isOn:$controller.includeEdited); Toggle("Only photos taken from now on",isOn:$controller.onlyNew)}
            if controller.scanning {Text("Preparing original photos…").font(.caption).foregroundStyle(.secondary)}
            if let failure = controller.failure {Text(failure).foregroundStyle(.red); Button("Retry Scan") {Task {await controller.scanIfEnabled()}}}
        }.alert("Enable Apple Photos backup?",isPresented:$confirming) {Button("Cancel",role:.cancel){}; Button("Enable") {Task {await controller.configure(true)}}} message:{Text("Originals will upload to the selected destination while Fotera is running. iCloud originals may download first. Local photos are not deleted.")}
    }
}

struct MacBackupCandidate: @unchecked Sendable {
    let asset:PHAsset
    let resources:[PHAssetResource]
    var keys:[String] {resources.map(key)}
    func key(_ resource:PHAssetResource) -> String {
        let edited = [PHAssetResourceType.fullSizePhoto,.fullSizeVideo,.fullSizePairedVideo].contains(resource.type)
        return "\(asset.localIdentifier)|\(resource.type.rawValue)|\(resource.originalFilename)" + (edited ? "|e\(asset.modificationDate?.timeIntervalSince1970 ?? 0)" : "")
    }
}

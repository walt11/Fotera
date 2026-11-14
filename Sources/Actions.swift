import SwiftUI
import Photos

/// Performs batch operations for a grid or the viewer and owns their progress and result UI.
@MainActor final class ActionRunner: ObservableObject {
    @Published var busy: String?
    @Published var message: String?
    @Published var shareFiles: [URL]?
    @Published var pickingAlbum: [RemotePhoto]?
    @Published var confirmingDelete: [RemotePhoto]?
    /// Checked each time Delete is tapped, so the prompt says whether the delete can be undone.
    /// `nil` means the NAS couldn't confirm it.
    @Published var recycleBinOn: Bool?
    private var temporaryFiles: [URL] = []
    private var deletePlan: PhotoDeletionPlan?
    @Published var deleteWarning = ""
    @Published var deletingPhoneCopies = false

    func run(_ label: String, _ operation: @escaping () async throws -> String?) {
        guard busy == nil else { return }
        busy = label
        Task {
            defer { busy = nil }
            do { if let result = try await operation() { message = result } }
            catch { if !isCancelledRequest(error) { Haptics.warning(); message = error.localizedDescription } }
        }
    }
    func setFavorite(_ items: [RemotePhoto], value: Bool, app: AppModel, completion: (() -> Void)? = nil) {
        guard let client = app.client, !items.isEmpty else { return }
        let shared = app.shared
        run(value ? "Adding to favorites…" : "Removing from favorites…") {
            let remote = items.filter { !$0.isLocalOnly }
            if !remote.isEmpty { try await client.setFavorite(ids: remote.map(\.id), shared: shared, value: value) }
            let local = items.filter(\.isLocalOnly).compactMap(\.localAssetID)
            if !local.isEmpty {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: local, options: nil)
                try await PHPhotoLibrary.shared().performChanges {
                    assets.enumerateObjects { asset, _, _ in PHAssetChangeRequest(for: asset).isFavorite = value }
                }
            }
            FavoriteMarks.shared.set(items.map(\.id), value)
            Haptics.success()
            completion?()
            return nil
        }
    }
    func add(_ items: [RemotePhoto], to album: RemoteAlbum?, newName: String?, app: AppModel, completion: (() -> Void)? = nil) {
        guard let client = app.client, !items.isEmpty else { return }
        guard !items.contains(where: \.isLocalOnly) else { message = "Back up iPhone-only photos before adding them to a NAS album."; return }
        run("Updating album…") {
            if let album {
                try await client.changeAlbumItems(id: album.id, items: items.map(\.id), adding: true)
                completion?()
                return "Added \(items.count) \(items.count == 1 ? "item" : "items") to \(album.name)."
            }
            guard let name = newName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            try await client.createAlbum(name: name, items: items.map(\.id))
            completion?()
            NotificationCenter.default.post(name: .foteraAlbumsChanged, object: nil)
            return "Created album \(name)."
        }
    }
    func removeFromAlbum(_ items: [RemotePhoto], album: RemoteAlbum, app: AppModel, completion: @escaping () -> Void) {
        guard let client = app.client, !items.isEmpty else { return }
        run("Removing from album…") {
            try await client.changeAlbumItems(id: album.id, items: items.map(\.id), adding: false)
            completion()
            return nil
        }
    }
    func share(_ items: [RemotePhoto], app: AppModel, albumID: Int? = nil) {
        guard let client = app.client, !items.isEmpty else { return }
        let shared = app.shared
        cleanup()
        run(items.count == 1 ? "Preparing original…" : "Preparing \(items.count) originals…") {
            var files: [URL] = []
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                if items.count > 1 { self.busy = "Downloading \(index + 1) of \(items.count)…" }
                let file = try await Self.shareOriginal(item, client: client, shared: shared, albumID: albumID)
                // Give shared files their real names instead of temporary identifiers.
                let named = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
                let target = named.appendingPathComponent(item.filename)
                try FileManager.default.moveItem(at: file, to: target)
                files.append(target)
            }
            self.temporaryFiles = files
            self.shareFiles = files
            return nil
        }
    }
    func saveToPhotos(_ items: [RemotePhoto], app: AppModel, albumID: Int? = nil) {
        guard let client = app.client, !items.isEmpty else { return }
        let shared = app.shared
        run("Saving to Photos…") {
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else { return "Allow Fotera to add photos in iOS Settings." }
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                if items.count > 1 { self.busy = "Saving \(index + 1) of \(items.count)…" }
                try await Self.save(item, client: client, shared: shared, albumID: albumID)
            }
            return items.count == 1 ? "Saved to Photos." : "Saved \(items.count) items to Photos."
        }
    }
    private static func shareOriginal(_ item: RemotePhoto, client: DSMClient, shared: Bool, albumID: Int?) async throws -> URL {
        if let identifier = item.localAssetID,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
            let resources = PHAssetResource.assetResources(for: asset)
            let preferred: PHAssetResourceType = item.isVideo ? .fullSizeVideo : .fullSizePhoto
            if let resource = resources.first(where: { $0.type == preferred }) ?? resources.first(where: { $0.type == (item.isVideo ? .video : .photo) }) {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((resource.originalFilename as NSString).pathExtension)
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    return file
                } catch { try? FileManager.default.removeItem(at: file); throw error }
            }
        }
        guard !item.isLocalOnly else { throw MediaFailure.unsupportedPhoto }
        return try await client.original(item, shared: shared, albumID: albumID, useOfflineCache: true)
    }
    /// Saves an original, keeping Live Photos paired with their motion resource.
    static func save(_ item: RemotePhoto, client: DSMClient, shared: Bool, albumID: Int?) async throws {
        if let identifier = item.localAssetID, PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject != nil { return }
        guard !item.isLocalOnly else { throw MediaFailure.unsupportedPhoto }
        var package: OriginalPackage?
        var file: URL?
        defer {
            if let package { try? FileManager.default.removeItem(at: package.directory) }
            if let file { try? FileManager.default.removeItem(at: file) }
        }
        if item.isLive {
            let archive = try await client.livePackage(item, shared: shared, albumID: albumID, useOfflineCache: true)
            defer { try? FileManager.default.removeItem(at: archive) }
            package = try await Task.detached(priority: .userInitiated) { try OriginalPackage.unpack(archive) }.value
        }
        if package == nil || package?.files.count != 2 {
            if let package { try? FileManager.default.removeItem(at: package.directory) }
            package = nil
            file = try await client.original(item, shared: shared, albumID: albumID, useOfflineCache: true)
        }
        let resources = package?.files
        let original = file
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            if let resources {
                for resource in resources {
                    let isVideo = ["mov", "mp4"].contains(resource.pathExtension.lowercased())
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = isVideo ? (item.filename as NSString).deletingPathExtension + "." + resource.pathExtension : item.filename
                    request.addResource(with: isVideo ? .pairedVideo : .photo, fileURL: resource, options: options)
                }
            } else if let original {
                let options = PHAssetResourceCreationOptions(); options.originalFilename = item.filename
                request.addResource(with: item.isVideo ? .video : .photo, fileURL: original, options: options)
            }
        }
    }
    /// Resolve and verify local copies before asking the user to delete anything.
    func requestDelete(_ items: [RemotePhoto], app: AppModel) {
        guard let client = app.client, !items.isEmpty, busy == nil else { return }
        let shared = app.shared, account = app.account
        busy = "Checking recycle bin…"
        deletePlan = nil
        Task {
            defer { busy = nil }
            // Only quick candidate lookups here; the byte comparison runs after "NAS and iPhone" is chosen,
            // so a plain NAS delete never downloads originals. Uses existing Photos access only.
            let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let records = app.manualUploads.records + (BackupController.shared.queue?.records ?? [])
            var candidates: [Int: [PHAsset]] = [:]
            if access == .authorized || access == .limited {
                for item in items {
                    let found = await PhoneDeletionMatch.candidates(for: item, shared: shared, records: records)
                    if !found.isEmpty { candidates[item.id] = found }
                }
            }
            let remoteCount = items.filter { !$0.isLocalOnly }.count
            let enabled = remoteCount > 0 ? try? await client.recycleBinEnabled(shared: shared) : nil
            guard app.client === client, app.account == account, app.shared == shared else { return }
            recycleBinOn = enabled
            let phoneCount = Set(candidates.values.flatMap { $0.map(\.localIdentifier) }).count
            deletePlan = PhotoDeletionPlan(client: client, account: account, shared: shared,
                itemIDs: Set(items.map(\.id)), candidates: candidates)
            deletingPhoneCopies = phoneCount > 0
            deleteWarning = remoteCount == 0 ? "This also removes them from iCloud Photos if it’s on."
                : PhotoDeletionPlan.warning(phoneCount: phoneCount, unmatchedCount: items.count - candidates.count, access: access)
            confirmingDelete = items
        }
    }
    func delete(_ items: [RemotePhoto], includingPhone: Bool, app: AppModel, completion: @escaping () -> Void) {
        guard let plan = deletePlan else { return }
        deletePlan = nil
        guard app.client === plan.client, app.account == plan.account, app.shared == plan.shared,
              Set(items.map(\.id)) == plan.itemIDs else {
            message = "The account or photo space changed. Select the photos again."; return
        }
        run("Deleting…") {
            // Confirm phone copies byte for byte before deleting anything, so a failed check deletes nothing.
            var verified: [PHAsset] = []
            if includingPhone {
                for (index, item) in items.enumerated() {
                    guard let candidates = plan.candidates[item.id] else { continue }
                    if item.isLocalOnly { verified += candidates; continue }
                    self.busy = "Checking iPhone copy \(index + 1) of \(items.count)…"
                    do { verified += try await PhoneDeletionMatch.verified(item, candidates: candidates, shared: plan.shared, client: plan.client) }
                    catch { throw DeletionFailure.unverified(error.localizedDescription) }
                }
                self.busy = "Deleting…"
            }
            let candidateCount = Set(plan.candidates.values.flatMap { $0.map(\.localIdentifier) }).count
            // Do not delete phone copies if the NAS operation fails.
            let remoteIDs = items.filter { !$0.isLocalOnly }.map(\.id)
            if !remoteIDs.isEmpty { try await plan.client.deletePhotos(ids: remoteIDs, shared: plan.shared, permanent: true) }
            guard app.client === plan.client, app.account == plan.account, app.shared == plan.shared else {
                return "Deleted from the NAS. The account or photo space changed, so iPhone copies were left untouched."
            }
            app.library.remove(ids: Set(remoteIDs))
            var result: String?
            if includingPhone && candidateCount > 0 {
                // A photo edited while confirmation was open needs a new match check.
                let fresh = PHAsset.fetchAssets(withLocalIdentifiers: verified.map(\.localIdentifier), options: nil)
                var removable: [PHAsset] = []
                fresh.enumerateObjects { asset, _, _ in
                    if let old = verified.first(where: { $0.localIdentifier == asset.localIdentifier }),
                       old.modificationDate == asset.modificationDate { removable.append(asset) }
                }
                do {
                    if !removable.isEmpty {
                        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(removable as NSArray) }
                    }
                    if removable.count != candidateCount {
                        result = "Deleted from the NAS. iPhone copies that weren’t identical, or changed, were left untouched."
                    }
                    // Apply the confirmed phone deletion directly; do not wait for Photos'
                    // observer or a manual refresh to remove the local timeline copies.
                    if app.client === plan.client, app.account == plan.account, app.shared == plan.shared {
                        app.library.remove(ids: [], localAssetIDs: Set(removable.map(\.localIdentifier)))
                    }
                    await LocalAssets.shared.clear()
                    await PhoneLibraryIndex.shared.invalidate()
                    NotificationCenter.default.post(name: .foteraLocalLibraryChanged, object: nil)
                } catch {
                    result = (remoteIDs.isEmpty ? "The iPhone photos were not deleted. " : "Deleted from the NAS, but the iPhone copies were not deleted. ") + error.localizedDescription
                }
            }
            if result == nil { Haptics.success(); completion() }
            else { Haptics.warning() }
            return result
        }
    }
    func cleanup() {
        for file in temporaryFiles { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        temporaryFiles = []
    }
}

extension Notification.Name {
    static let foteraAlbumsChanged = Notification.Name("FoteraAlbumsChanged")
}

/// Presents the runner's progress, results, share sheet, album picker and delete confirmation.
struct ActionRunnerPresenter: ViewModifier {
    @ObservedObject var runner: ActionRunner
    @EnvironmentObject private var app: AppModel
    var afterChange: () -> Void = {}
    func body(content: Content) -> some View {
        content
            .overlay {
                if let busy = runner.busy {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(busy).font(.subheadline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity)
                }
            }
            .alert("Fotera", isPresented: Binding(get: { runner.message != nil }, set: { if !$0 { runner.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(runner.message ?? "") }
            .sheet(isPresented: Binding(get: { runner.shareFiles != nil }, set: { if !$0 { runner.shareFiles = nil; runner.cleanup() } })) {
                ShareSheet(items: runner.shareFiles ?? []).ignoresSafeArea()
            }
            .sheet(isPresented: Binding(get: { runner.pickingAlbum != nil }, set: { if !$0 { runner.pickingAlbum = nil } })) {
                AlbumPicker { album, name in
                    let items = runner.pickingAlbum ?? []
                    runner.pickingAlbum = nil
                    runner.add(items, to: album, newName: name, app: app, completion: afterChange)
                }
            }
            .alert(deleteTitle, isPresented: Binding(get: { runner.confirmingDelete != nil }, set: { if !$0 { runner.confirmingDelete = nil } })) {
                Button("Cancel", role: .cancel) {}
                if runner.confirmingDelete?.contains(where: { !$0.isLocalOnly }) == true {
                    Button("NAS only", role: .destructive) { confirmDelete(includingPhone: false) }
                }
                if runner.deletingPhoneCopies {
                    Button(runner.confirmingDelete?.allSatisfy(\.isLocalOnly) == true ? "Delete from iPhone" : "NAS and iPhone", role: .destructive) { confirmDelete(includingPhone: true) }
                }
            } message: { Text(runner.deleteWarning) }
    }
    private func confirmDelete(includingPhone: Bool) {
        let items = runner.confirmingDelete ?? []
        runner.confirmingDelete = nil
        runner.delete(items, includingPhone: includingPhone, app: app, completion: afterChange)
    }
    private var deleteTitle: String {
        // Keeps the question you chose earlier: it says plainly where the items go.
        let items = runner.confirmingDelete ?? []
        let target = items.count == 1 ? "this item" : "these \(items.count) items"
        if !items.isEmpty, items.allSatisfy(\.isLocalOnly) { return "Are you sure you want to delete \(target) from your iPhone?" }
        return runner.recycleBinOn == true
            ? "Are you sure you want to move \(target) to the recycle bin?"
            : "Are you sure you want to permanently delete \(target)?"
    }
}
extension View {
    func actionRunner(_ runner: ActionRunner, afterChange: @escaping () -> Void = {}) -> some View {
        modifier(ActionRunnerPresenter(runner: runner, afterChange: afterChange))
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Chooses an existing album or names a new one.
struct AlbumPicker: View {
    let choose: (RemoteAlbum?, String?) -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [RemoteAlbum] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var naming = false
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Button { name = ""; naming = true } label: { Label("New album", systemImage: "plus.rectangle.on.rectangle") }
                Section {
                    ForEach(albums) { album in
                        Button { choose(album, nil) } label: {
                            HStack(spacing: 12) {
                                ThumbnailView(source: album.cover, shared: false, size: .sm)
                                    .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading) {
                                    Text(album.name).foregroundStyle(.primary)
                                    if let count = album.item_count { Text("\(count) items").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                } footer: {
                    if loading { ProgressView() }
                    if let failure { Text(failure) }
                }
            }
            .navigationTitle("Add to album").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New album", isPresented: $naming) {
                TextField("Album name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create") { choose(nil, name) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .task {
                guard let client = app.client else { return }
                do { albums = try await client.allAlbums() } catch { failure = error.localizedDescription }
                loading = false
            }
        }
    }
}


enum DeletionFailure: LocalizedError {
    case unverified(String)
    var errorDescription: String? {
        if case .unverified(let reason) = self { return "Couldn’t check the iPhone copies, so nothing was deleted. " + reason }
        return nil
    }
}
private struct PhotoDeletionPlan {
    let client: DSMClient
    let account: String
    let shared: Bool
    let itemIDs: Set<Int>
    /// Likely phone copies per item; NAS items are byte-checked before any deletion.
    let candidates: [Int: [PHAsset]]

    /// The title already says whether the NAS copy goes to the recycle bin; this only covers the iPhone.
    static func warning(phoneCount: Int, unmatchedCount: Int, access: PHAuthorizationStatus) -> String {
        guard phoneCount > 0 else { return "" }
        var text = "“NAS and iPhone” also removes \(phoneCount) iPhone \(phoneCount == 1 ? "copy" : "copies") after checking \(phoneCount == 1 ? "it’s" : "they’re") identical, including from iCloud Photos if it’s on."
        if unmatchedCount > 0 || access == .limited { text += " Other items stay on the iPhone." }
        return text
    }
}

/// Filename/time lookup is only a candidate search, never authorization for deleting local data.
enum PhoneDeletionMatch {
    static func sourceAssetID(_ source: String) -> String? {
        let parts = source.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 5, ["true", "false"].contains(String(parts[0])),
              Int(parts[1]) != nil, !parts[2].isEmpty, Int(parts[3]) != nil, Int(parts[4]) != nil else { return nil }
        return String(parts[2])
    }
    static func sameContent(remote: Set<String>, local: String) -> Bool {
        !local.isEmpty && remote.contains(local)
    }
    /// Phone assets that are probably this item: upload records first, then filename and capture time.
    @MainActor static func candidates(for item: RemotePhoto, shared: Bool, records: [TransferRecord]) async -> [PHAsset] {
        var identifiers = Set<String>()
        if item.isLocalOnly { if let id = item.localAssetID { identifiers.insert(id) } }
        else {
            identifiers.formUnion(records.filter { $0.shared == shared && $0.remoteID == item.id }.compactMap { $0.sourceID.flatMap(sourceAssetID) })
            if let id = await LocalAssets.shared.identifier(for: item) { identifiers.insert(id) }
        }
        guard !identifiers.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        return (0..<fetched.count).map { fetched.object(at: $0) }
    }
    /// Downloads the NAS original and keeps only phone assets with a byte-identical resource.
    @MainActor static func verified(_ item: RemotePhoto, candidates: [PHAsset], shared: Bool, client: DSMClient) async throws -> [PHAsset] {
        guard !candidates.isEmpty else { return [] }
        let file = try await (item.isLive ? client.livePackage(item, shared: shared) : client.original(item, shared: shared))
        defer { try? FileManager.default.removeItem(at: file) }
        let hashes = try await TransferQueue.originalDigests(file, live: item.isLive)
        var assets: [PHAsset] = []
        for asset in candidates {
            for resource in PHAssetResource.assetResources(for: asset) where
                [.photo, .video, .pairedVideo, .alternatePhoto, .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo].contains(resource.type) {
                try Task.checkCancellation()
                let local = FileManager.default.temporaryDirectory.appendingPathComponent("FoteraDeleteMatch-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: local) }
                let digest = try await StagedExport.write(resource, to: local).0
                if sameContent(remote: hashes, local: digest) { assets.append(asset); break }
            }
        }
        return assets
    }
}


#if DEBUG
/// A confirmation-only preview. It has no deletion plan, client, or Photos mutation.
struct DeleteWarningPreview: View {
    @StateObject private var runner = ActionRunner()
    var body: some View {
        Text("Delete confirmation preview")
            .actionRunner(runner)
            .task {
                runner.deletingPhoneCopies = true
                runner.deleteWarning = PhotoDeletionPlan.warning(phoneCount: 2, unmatchedCount: 0, access: .authorized)
                runner.confirmingDelete = [RemotePhoto(id: -1, filename: "Preview", time: nil, type: "photo", additional: nil)]
            }
    }
}
#endif

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
            try await client.setFavorite(ids: items.map(\.id), shared: shared, value: value)
            FavoriteMarks.shared.set(items.map(\.id), value)
            Haptics.success()
            completion?()
            return nil
        }
    }
    func add(_ items: [RemotePhoto], to album: RemoteAlbum?, newName: String?, app: AppModel, completion: (() -> Void)? = nil) {
        guard let client = app.client, !items.isEmpty else { return }
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
                let file = try await client.original(item, shared: shared, albumID: albumID, useOfflineCache: true)
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
    /// Saves an original, keeping Live Photos paired with their motion resource.
    static func save(_ item: RemotePhoto, client: DSMClient, shared: Bool, albumID: Int?) async throws {
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
        busy = "Checking iPhone copies…"
        deletePlan = nil
        Task {
            defer { busy = nil }
            do {
                var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if access == .notDetermined { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                let records = app.manualUploads.records
                var local: [String: PHAsset] = [:]
                var matchedItems = 0
                if access == .authorized || access == .limited {
                    for (index, item) in items.enumerated() {
                        try Task.checkCancellation()
                        busy = "Checking iPhone copies \(index + 1) of \(items.count)…"
                        let matches = try await PhoneDeletionMatch.assets(for: item, shared: shared, client: client, records: records)
                        if !matches.isEmpty { matchedItems += 1 }
                        for asset in matches { local[asset.localIdentifier] = asset }
                    }
                }
                let enabled = try? await client.recycleBinEnabled(shared: shared)
                guard app.client === client, app.account == account, app.shared == shared else { return }
                recycleBinOn = enabled
                let assets = Array(local.values)
                deletePlan = PhotoDeletionPlan(client: client, account: account, shared: shared,
                    itemIDs: Set(items.map(\.id)), assets: assets)
                deletingPhoneCopies = !assets.isEmpty
                deleteWarning = PhotoDeletionPlan.warning(nasCount: items.count, phoneCount: assets.count,
                    unmatchedCount: items.count - matchedItems, recycleBin: enabled, access: access)
                confirmingDelete = items
            } catch {
                message = "Couldn’t verify the iPhone copies. Nothing was deleted. " + error.localizedDescription
            }
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
            // Do not delete phone copies if the NAS operation fails.
            try await plan.client.deletePhotos(ids: items.map(\.id), shared: plan.shared, permanent: true)
            guard app.client === plan.client, app.account == plan.account, app.shared == plan.shared else {
                return "Deleted from the NAS. The account or photo space changed, so iPhone copies were left untouched."
            }
            app.library.remove(ids: plan.itemIDs)
            var result: String?
            if includingPhone && !plan.assets.isEmpty {
                // A photo edited while confirmation was open needs a new match check.
                let fresh = PHAsset.fetchAssets(withLocalIdentifiers: plan.assets.map(\.localIdentifier), options: nil)
                var removable: [PHAsset] = []
                fresh.enumerateObjects { asset, _, _ in
                    if let old = plan.assets.first(where: { $0.localIdentifier == asset.localIdentifier }),
                       old.modificationDate == asset.modificationDate { removable.append(asset) }
                }
                do {
                    if !removable.isEmpty {
                        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(removable as NSArray) }
                    }
                    if removable.count != plan.assets.count {
                        result = "Deleted from the NAS. Some iPhone copies changed or became unavailable and were left untouched."
                    }
                    await LocalAssets.shared.clear()
                    NotificationCenter.default.post(name: .foteraLocalLibraryChanged, object: nil)
                } catch {
                    result = "Deleted from the NAS, but the iPhone copies were not deleted. The Photos request was cancelled or could not be completed. " + error.localizedDescription
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
                Button("NAS only", role: .destructive) { confirmDelete(includingPhone: false) }
                Button("NAS and iPhone", role: .destructive) { confirmDelete(includingPhone: true) }
                    .disabled(!runner.deletingPhoneCopies)
            } message: { Text(runner.deleteWarning) }
    }
    private func confirmDelete(includingPhone: Bool) {
        let items = runner.confirmingDelete ?? []
        runner.confirmingDelete = nil
        runner.delete(items, includingPhone: includingPhone, app: app, completion: afterChange)
    }
    private var deleteTitle: String {
        let count = runner.confirmingDelete?.count ?? 0
        return count == 1 ? "Delete photo?" : "Delete \(count) items?"
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


private struct PhotoDeletionPlan {
    let client: DSMClient
    let account: String
    let shared: Bool
    let itemIDs: Set<Int>
    let assets: [PHAsset]

    static func warning(nasCount: Int, phoneCount: Int, unmatchedCount: Int, recycleBin: Bool?, access: PHAuthorizationStatus) -> String {
        var text = recycleBin == true ? "NAS copies go to the recycle bin." : "NAS deletion may be permanent."
        if phoneCount > 0 {
            text += " “NAS and iPhone” also removes \(phoneCount) matching iPhone \(phoneCount == 1 ? "copy" : "copies"), including from iCloud Photos if enabled. iOS will ask you to confirm."
            if unmatchedCount > 0 || access == .limited { text += " Other phone copies remain." }
        } else {
            text += access != .authorized && access != .limited
                ? " Allow Photos access to also delete iPhone copies."
                : " No verified iPhone copies found."
        }
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
    @MainActor static func assets(for item: RemotePhoto, shared: Bool, client: DSMClient, records: [TransferRecord]) async throws -> [PHAsset] {
        var candidates = Set(records.filter { $0.shared == shared && $0.remoteID == item.id }
            .compactMap { $0.sourceID.flatMap(sourceAssetID) })
        if let id = await LocalAssets.shared.identifier(for: item) { candidates.insert(id) }
        guard !candidates.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(candidates), options: nil)
        guard fetched.count > 0 else { return [] }
        let file = try await (item.isLive ? client.livePackage(item, shared: shared) : client.original(item, shared: shared))
        defer { try? FileManager.default.removeItem(at: file) }
        let hashes = try await TransferQueue.originalDigests(file, live: item.isLive)
        var assets: [PHAsset] = []
        for index in 0..<fetched.count {
            let asset = fetched.object(at: index)
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
                runner.deleteWarning = PhotoDeletionPlan.warning(nasCount: 2, phoneCount: 2, unmatchedCount: 0, recycleBin: true, access: .authorized)
                runner.confirmingDelete = [RemotePhoto(id: -1, filename: "Preview", time: nil, type: "photo", additional: nil)]
            }
    }
}
#endif

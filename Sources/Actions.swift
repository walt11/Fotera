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

    func run(_ label: String, _ operation: @escaping () async throws -> String?) {
        guard busy == nil else { return }
        busy = label
        Task {
            defer { busy = nil }
            do { if let result = try await operation() { message = result } }
            catch { if !isCancelledRequest(error) { message = error.localizedDescription } }
        }
    }
    func setFavorite(_ items: [RemotePhoto], value: Bool, app: AppModel, completion: (() -> Void)? = nil) {
        guard let client = app.client, !items.isEmpty else { return }
        let shared = app.shared
        run(value ? "Adding to favorites…" : "Removing from favorites…") {
            try await client.setFavorite(ids: items.map(\.id), shared: shared, value: value)
            FavoriteMarks.shared.set(items.map(\.id), value)
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
    /// Checks the NAS recycle bin, then shows the delete prompt with the confirmed result.
    func requestDelete(_ items: [RemotePhoto], app: AppModel) {
        guard let client = app.client, !items.isEmpty, busy == nil else { return }
        let shared = app.shared
        busy = "Checking recycle bin…"
        Task {
            let enabled = try? await client.recycleBinEnabled(shared: shared)
            recycleBinOn = enabled
            busy = nil
            confirmingDelete = items
        }
    }
    /// Deletes after the single confirmation. The NAS still uses its recycle bin when it's on.
    func delete(_ items: [RemotePhoto], app: AppModel, completion: @escaping () -> Void) {
        guard let client = app.client, !items.isEmpty else { return }
        let shared = app.shared
        run("Deleting…") {
            try await client.deletePhotos(ids: items.map(\.id), shared: shared, permanent: true)
            app.library.remove(ids: Set(items.map(\.id)))
            completion()
            return nil
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
                Button("No", role: .cancel) {}
                Button("Yes", role: .destructive) {
                    let items = runner.confirmingDelete ?? []
                    runner.confirmingDelete = nil
                    runner.delete(items, app: app, completion: afterChange)
                }
            }
    }
    /// A plain yes/no question that states where the items go. An unconfirmed recycle bin is treated as permanent.
    private var deleteTitle: String {
        let count = runner.confirmingDelete?.count ?? 0
        let target = count == 1 ? "this item" : "these \(count) items"
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

import SwiftUI
import AVKit
import WidgetKit

actor OfflineVault {
    static let shared = OfflineVault()
    struct Album: Codable, Identifiable {
        var id = UUID(); var title: String; var photos: [RemotePhoto]; var shared: Bool; var completed: Set<Int> = []
    }
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineAlbums", isDirectory: true)
    private func folder(_ account: String) -> URL { root.appendingPathComponent(LibraryCache.hash(account), isDirectory: true) }
    private func media(_ account: String, shared: Bool, id: Int, package: Bool) -> URL { folder(account).appendingPathComponent("\(shared)-\(id)-\(package ? "package.zip" : "original")") }
    func albums(account: String) -> [Album] {
        guard let data = try? Data(contentsOf: folder(account).appendingPathComponent("albums.json")) else { return [] }
        return (try? JSONDecoder().decode([Album].self, from: data)) ?? []
    }
    func save(_ album: Album, account: String) throws {
        var values = albums(account: account); values.removeAll { $0.id == album.id }; values.append(album)
        try FileManager.default.createDirectory(at: folder(account), withIntermediateDirectories: true)
        var url = folder(account); var resource = URLResourceValues(); resource.isExcludedFromBackup = true; try url.setResourceValues(resource)
        try JSONEncoder().encode(values).write(to: folder(account).appendingPathComponent("albums.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func store(_ file: URL, account: String, photo: RemotePhoto, shared: Bool, package: Bool) throws {
        let target = media(account, shared: shared, id: photo.id, package: package)
        try FileManager.default.createDirectory(at: folder(account), withIntermediateDirectories: true)
        let temp = target.appendingPathExtension(UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: temp)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temp.path)
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temp) }
        else { try FileManager.default.moveItem(at: temp, to: target) }
    }
    func originalURL(account: String, shared: Bool, id: Int, package: Bool = false) -> URL? {
        let path = media(account, shared: shared, id: id, package: package)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }
    func copyOriginal(account: String, photo: RemotePhoto, shared: Bool) throws -> URL? {
        guard let file = originalURL(account: account, shared: shared, id: photo.id, package: (photo.filename as NSString).pathExtension.lowercased() == "zip") else { return nil }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((photo.filename as NSString).pathExtension)
        try FileManager.default.copyItem(at: file, to: target); return target
    }
    func remove(_ album: Album, account: String) throws {
        var values = albums(account: account); values.removeAll { $0.id == album.id }
        try JSONEncoder().encode(values).write(to: folder(account).appendingPathComponent("albums.json"), options: .atomic)
        let retained = Set(values.filter { $0.shared == album.shared }.flatMap(\.photos).map(\.id))
        for photo in album.photos where !retained.contains(photo.id) {
            for package in [false, true] { try? FileManager.default.removeItem(at: media(account, shared: album.shared, id: photo.id, package: package)) }
        }
    }
    func clear(account: String) throws {
        let path = folder(account); if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
struct OfflineAlbumsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var albums: [OfflineVault.Album] = []
    @State private var selecting = false
    @State private var failure: String?
    var body: some View {
        List {
            Section { Text("Originals stay on this iPhone until removed here or you sign out. Open an unfinished album to resume downloading.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(albums) { album in
                NavigationLink { OfflineAlbumView(album: album) } label: {
                    VStack(alignment: .leading) { Text(album.title); Text("\(album.completed.count) of \(album.photos.count) downloaded").font(.caption).foregroundStyle(.secondary) }
                }.swipeActions { Button("Remove download", role: .destructive) { Task { do { try await OfflineVault.shared.remove(album, account: app.account); await load() } catch { failure = error.localizedDescription } } } }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }.navigationTitle("Offline albums")
        .toolbar { Button("Add", systemImage: "plus") { selecting = true } }
        .task { await load() }.refreshable { await load() }
        .sheet(isPresented: $selecting) {
            PhotoSelectionSheet(title: "Download album", confirmTitle: "Download", asksForName: true) { ids, name in
                let album = OfflineVault.Album(title: name ?? "Offline album", photos: app.library.photos.filter { ids.contains($0.id) && !$0.isLocalOnly }, shared: app.shared)
                try await OfflineVault.shared.save(album, account: app.account); await load()
            }
        }
    }
    private func load() async { albums = await OfflineVault.shared.albums(account: app.account).filter { $0.shared == app.shared } }
}
struct OfflineAlbumView: View {
    @State var album: OfflineVault.Album
    @EnvironmentObject private var app: AppModel
    @State private var downloading = false
    @State private var failure: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var selection: Set<Int>?
    var body: some View {
        PhotoGrid(sections: album.photos.asSingleSection, shared: album.shared, selection: $selection) {
            VStack(alignment: .leading) {
                Text("\(album.completed.count) of \(album.photos.count) originals downloaded")
                ProgressView(value: Double(album.completed.count), total: Double(max(1, album.photos.count)))
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }.padding()
        }.navigationTitle(album.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { Button(downloading ? "Pause" : "Download") { if downloading { downloadTask?.cancel() } else { start() } }.disabled(!downloading && album.completed.count == album.photos.count) }
        .onDisappear { downloadTask?.cancel() }.task { if album.completed.count < album.photos.count { start() } }
    }
    private func start() {
        guard !downloading, let client = app.client else { return }
        let account = app.account; downloading = true; failure = nil
        downloadTask = Task {
            defer { downloading = false }
            do {
                for photo in album.photos where !album.completed.contains(photo.id) {
                    try Task.checkCancellation()
                    let file = try await client.original(photo, shared: album.shared, useOfflineCache: true)
                    defer { try? FileManager.default.removeItem(at: file) }
                    try await OfflineVault.shared.store(file, account: account, photo: photo, shared: album.shared, package: false)
                    if photo.isLive {
                        let package = try await client.livePackage(photo, shared: album.shared, useOfflineCache: true)
                        defer { try? FileManager.default.removeItem(at: package) }
                        try await OfflineVault.shared.store(package, account: account, photo: photo, shared: album.shared, package: true)
                    }
                    if let source = photo.thumbnailSource { _ = await ImagePipeline.shared.image(source, shared: album.shared, size: .m) }
                    album.completed.insert(photo.id); try await OfflineVault.shared.save(album, account: account)
                }
            } catch { if !isCancelledRequest(error) { failure = error.localizedDescription } }
        }
    }
}
struct SmartAlbumRule: Codable, Identifiable {
    var id = UUID(); var title = ""; var query = ""; var media = "All"; var year = 0; var personID: Int?; var tag = ""; var shared = false
}
struct SmartAlbumsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var rules: [SmartAlbumRule] = []
    @State private var editing: SmartAlbumRule?
    private var key: String { "smartAlbums." + LibraryCache.hash(app.account) }
    var body: some View {
        List {
            Section { Text("Fotera rules stay on this iPhone and update with your library. Person and tag filters need the NAS.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(rules.filter { $0.shared == app.shared }) { rule in
                NavigationLink { SmartAlbumResults(rule: rule, library: app.library) } label: { Label(rule.title, systemImage: "sparkles.rectangle.stack") }
                    .contextMenu { Button("Edit") { editing = rule }; Button("Delete rule", role: .destructive) { rules.removeAll { $0.id == rule.id }; save() } }
            }
        }.navigationTitle("Smart albums")
        .toolbar { Button("New smart album", systemImage: "plus") { editing = SmartAlbumRule(shared: app.shared) } }
        .task { rules = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([SmartAlbumRule].self, from: $0) } ?? [] }
        .sheet(item: $editing) { rule in SmartAlbumEditor(rule: rule) { value in rules.removeAll { $0.id == value.id }; rules.append(value); save() } }
    }
    private func save() { if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: key) } }
}
struct SmartAlbumEditor: View {
    @State var rule: SmartAlbumRule
    let saved: (SmartAlbumRule) -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var people: [RemoteGroup] = []
    var body: some View {
        NavigationStack {
            Form {
                TextField("Album name", text: $rule.title); TextField("Filename or date contains", text: $rule.query)
                Picker("Media", selection: $rule.media) { ForEach(LibraryMediaFilter.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                Picker("Year", selection: $rule.year) { Text("All years").tag(0); ForEach((1900...Calendar.current.component(.year, from: Date())).reversed(), id: \.self) { Text(String($0)).tag($0) } }
                Picker("Person", selection: $rule.personID) { Text("Anyone").tag(Int?.none); ForEach(people) { Text(displayName($0, kind: "person")).tag(Optional($0.id)) } }
                TextField("Tag (optional)", text: $rule.tag)
            }.navigationTitle("Smart album").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { rule.title = rule.title.trimmingCharacters(in: .whitespacesAndNewlines); saved(rule); dismiss() }.disabled(rule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.task { if let client = app.client { people = (try? await client.people(shared: rule.shared)) ?? [] } }
        }
    }
}
struct SmartAlbumResults: View {
    let rule: SmartAlbumRule
    @ObservedObject var library: LibraryStore
    @EnvironmentObject private var app: AppModel
    @State private var remoteIDs: Set<Int>?
    @State private var failure: String?
    @State private var selection: Set<Int>?
    private var matches: [RemotePhoto] {
        LocalLibrarySearch.results(library.photos, query: rule.query, media: LibraryMediaFilter(rawValue: rule.media) ?? .all, year: rule.year == 0 ? nil : rule.year).filter {
            (rule.personID == nil && rule.tag.isEmpty) || remoteIDs?.contains($0.id) == true
        }
    }
    var body: some View {
        PhotoGrid(sections: matches.asSingleSection, shared: rule.shared, selection: $selection) { Text(failure ?? "\(matches.count) matching photos").font(.footnote).foregroundStyle(.secondary).padding() }
            .navigationTitle(rule.title).navigationBarTitleDisplayMode(.inline)
            .task(id: library.lastSynced) { await load() }.refreshable { await library.refreshAndWait(); await load() }
            .toolbar { Button("Select") { selection = [] }.disabled(matches.isEmpty) }.selectionChrome($selection, items: matches)
    }
    private func load() async {
        guard let client = app.client else { return }; failure = nil
        do {
            var ids: Set<Int>?
            if let person = rule.personID {
                var offset = 0; var values = Set<Int>()
                while true { let page = try await client.items(.person(person), shared: rule.shared, offset: offset); values.formUnion(page.map(\.id)); offset += page.count; if page.count < DSMClient.pageSize { break } }
                ids = values
            }
            if !rule.tag.isEmpty {
                var tagged = Set<Int>(); var offset = 0
                while true {
                    let page = try await client.search(keyword: rule.tag, shared: rule.shared, offset: offset)
                    for photo in page where ids == nil || ids!.contains(photo.id) {
                        if try await client.photoTags(id: photo.id, shared: rule.shared).contains(where: { $0.name.localizedCaseInsensitiveCompare(rule.tag) == .orderedSame }) { tagged.insert(photo.id) }
                    }
                    offset += page.count; if page.count < 100 { break }
                }
                ids = tagged
            }
            remoteIDs = ids
        } catch { failure = "Couldn’t refresh rules: " + error.localizedDescription }
    }
}
struct ConnectionSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var lan = ""
    @State private var remoteURL = ""
    @State private var quickConnect = ""
    @State private var enabled = false
    @State private var saving = false
    @State private var message: String?
    var body: some View {
        Form {
            Toggle("Switch connections automatically", isOn: $enabled)
            Section("Local network") {
                TextField("LAN URL, including http:// or https://", text: $lan)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Remote connection") {
                TextField("https://nas.example.com:5001", text: $remoteURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Remote HTTPS URL")
                Text("Include a port if needed.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("QuickConnect ID (optional)", text: $quickConnect)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Text("Uses LAN when available, then your remote address or QuickConnect. All addresses must reach the same NAS. HTTP is unencrypted.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Save connections") { Task { await save() } }.disabled(saving)
                if !app.activeConnection.isEmpty { LabeledContent("Current connection", value: app.activeConnectionLabel) }
                if let message { Text(message).font(.footnote) }
            }
        }.navigationTitle("Connections").task {
            if let data = UserDefaults.standard.data(forKey: "routes." + LibraryCache.hash(app.address)),
               let profile = try? JSONDecoder().decode(RouteProfile.self, from: data) {
                lan = profile.lan; remoteURL = profile.remoteURL ?? ""; quickConnect = profile.quickConnect; enabled = profile.enabled
            }
            if remoteURL.isEmpty, let original = try? DSMClient.normalize(app.address),
               original.scheme == "https", !ConnectionAddress.isLAN(original.host ?? "") { remoteURL = original.absoluteString }
        }
    }
    private func save() async {
        guard let client = app.client else { return }
        saving = true; message = nil; defer { saving = false }
        do {
            try await client.configureRoutes(lan: lan.trimmingCharacters(in: .whitespacesAndNewlines), remoteURL: remoteURL,
                                             quickConnect: quickConnect.trimmingCharacters(in: .whitespacesAndNewlines), enabled: enabled)
            message = "Connections saved."
        } catch { message = error.localizedDescription }
    }
}

struct PhotoMetadataEditor: View {
    let item: RemotePhoto; let shared: Bool
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var descriptionText = ""; @State private var originalDescription = ""
    @State private var tags: [PhotoTag] = []; @State private var newTag = ""
    @State private var busy = false; @State private var loaded = false; @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Description") { TextEditor(text: $descriptionText).frame(minHeight: 120) }
                Section("Tags") {
                    ForEach(tags) { tag in HStack { Text(tag.name); Spacer(); Button("Remove", role: .destructive) { Task { await changeTag(tag) } }.buttonStyle(.borderless) } }
                    TextField("New tag", text: $newTag)
                    Button("Add tag") { Task { await changeTag(nil) } }.disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                Text("Edits are saved to the NAS. Synology may rewrite metadata in the original file.").font(.footnote).foregroundStyle(.secondary)
            }.disabled(busy || !loaded).navigationTitle("Photo details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy || !loaded || descriptionText == originalDescription) }
            }.overlay { if busy || (!loaded && failure == nil) { ProgressView() } }
            .task { await load() }.interactiveDismissDisabled(busy)
        }
    }
    private func load() async {
        guard let client = app.client else { return }
        do { descriptionText = try await client.details(id: item.id, shared: shared).additional?.description ?? ""; originalDescription = descriptionText; tags = try await client.photoTags(id: item.id, shared: shared); loaded = true }
        catch { failure = error.localizedDescription; loaded = false }
    }
    private func save() async {
        guard let client = app.client else { return }; busy = true; failure = nil; defer { busy = false }
        do { try await client.setPhotoDescription(id: item.id, shared: shared, description: descriptionText); originalDescription = descriptionText; app.library.refresh(); dismiss() }
        catch { failure = "Couldn’t confirm the edit. " + error.localizedDescription }
    }
    private func changeTag(_ tag: PhotoTag?) async {
        guard let client = app.client else { return }; busy = true; failure = nil; defer { busy = false }
        do {
            if let tag { try await client.removePhotoTag(id: item.id, shared: shared, tag: tag) }
            else { try await client.addPhotoTag(id: item.id, shared: shared, name: newTag); newTag = "" }
            tags = try await client.photoTags(id: item.id, shared: shared); app.library.refresh()
        } catch { failure = "Couldn’t confirm the tag change. " + error.localizedDescription }
    }
}
struct PeopleManagementView: View {
    let person: RemoteGroup; let shared: Bool
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var people: [RemoteGroup] = []; @State private var selected = Set<Int>()
    @State private var photos: [RemotePhoto] = []; @State private var merging = false
    @State private var busy = false; @State private var failure: String?; @State private var hiding = false
    var body: some View {
        List {
            Section("Visibility") { Button("Hide this person") { hiding = true } }
            Section("Cover photo") {
                ScrollView(.horizontal) { HStack { ForEach(photos) { photo in
                    Button { Task { await perform { client in try await client.personCover(person: person.id, photo: photo.id, shared: shared) } } } label: {
                        ThumbnailView(source: photo.thumbnailSource, shared: shared, fallbackPhoto: photo).frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel("Use \(photo.filename) as cover")
                } } }
            }
            Section("Merge duplicate people into this person") {
                ForEach(people.filter { $0.id != person.id }) { other in
                    Button { if !selected.insert(other.id).inserted { selected.remove(other.id) } } label: {
                        HStack { ThumbnailView(source: other.cover(kind: "person"), shared: shared).frame(width: 40, height: 40).clipShape(Circle()); Text(displayName(other, kind: "person")); Spacer(); if selected.contains(other.id) { Image(systemName: "checkmark") } }
                    }
                }
                Button("Merge selected people") { merging = true }.disabled(selected.isEmpty)
            }
            NavigationLink("Correct face grouping") { FaceCorrectionView(person: person, shared: shared) }
            if let failure { Text(failure).foregroundStyle(.red) }
        }.navigationTitle("Manage person").disabled(busy).overlay { if busy { ProgressView() } }
        .task {
            guard let client = app.client else { return }
            do { people = try await client.allPeople(shared: shared, includeHidden: true); photos = try await client.items(.person(person.id), shared: shared, offset: 0, limit: 100) }
            catch { failure = error.localizedDescription }
        }
        .confirmationDialog("Merge \(selected.count) people into this person? This combines their face groups on the NAS and cannot be undone automatically.", isPresented: $merging, titleVisibility: .visible) {
            Button("Merge people", role: .destructive) { Task { await perform { client in try await client.mergePeople(target: person, sources: Array(selected), shared: shared) } } }
        }
        .confirmationDialog("Hide this person from People? Photos remain in your library. You can unhide them later.", isPresented: $hiding, titleVisibility: .visible) {
            Button("Hide person") { Task { await perform { client in try await client.showPerson(id: person.id, shared: shared, visible: false) } } }
        }
    }
    private func perform(_ operation: (DSMClient) async throws -> Void) async {
        guard let client = app.client else { return }; busy = true; failure = nil; defer { busy = false }
        do { try await operation(client); NotificationCenter.default.post(name: .foteraPeopleChanged, object: nil); dismiss() }
        catch { failure = "Couldn’t confirm the change. " + error.localizedDescription }
    }
}
struct HiddenPeopleView: View {
    @EnvironmentObject private var app: AppModel
    @State private var people: [RemoteGroup] = []; @State private var failure: String?
    var body: some View {
        List {
            ForEach(people) { person in HStack { ThumbnailView(source: person.cover(kind: "person"), shared: app.shared).frame(width: 44, height: 44).clipShape(Circle()); Text(displayName(person, kind: "person")); Spacer(); Button("Unhide") { Task { guard let client = app.client else { return }; do { try await client.showPerson(id: person.id, shared: app.shared, visible: true); await load(); NotificationCenter.default.post(name: .foteraPeopleChanged, object: nil) } catch { failure = error.localizedDescription } } } } }
            if people.isEmpty && failure == nil { Text("No hidden people") }
            if let failure { Text(failure).foregroundStyle(.red) }
        }.navigationTitle("Hidden people").task { await load() }
    }
    private func load() async { guard let client = app.client else { return }; do { let all = try await client.allPeople(shared: app.shared, includeHidden: true); let visible = Set(try await client.allPeople(shared: app.shared).map(\.id)); people = all.filter { !visible.contains($0.id) } } catch { failure = error.localizedDescription } }
}
struct RecycleBinView: View {
    let path: String
    @EnvironmentObject private var app: AppModel
    @State private var files: [RecycleFile] = []; @State private var failure: String?; @State private var loading = false; @State private var restoring: RecycleFile?
    var body: some View {
        List {
            Text("Restore returns a file to its original folder without overwriting an existing file. The original folder must still exist.").font(.footnote).foregroundStyle(.secondary)
            ForEach(files) { file in
                if file.isdir { NavigationLink { RecycleBinView(path: file.path) } label: { Label(file.name, systemImage: "folder") } }
                else { HStack { Label(file.name, systemImage: "photo"); Spacer(); Button("Restore") { restoring = file } } }
            }
            if files.isEmpty && !loading && failure == nil { Text("No deleted files here") }
            if let failure { Text(failure).foregroundStyle(.secondary) }
        }.navigationTitle("Recently Deleted").disabled(loading).overlay { if loading { ProgressView() } }
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("Restore this file to its original folder?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            if let file = restoring { Button("Restore \(file.name)") { Task { await restore(file) } } }
        }
    }
    private func load() async { guard let client = app.client else { return }; loading = true; failure = nil; defer { loading = false }; do { files = try await client.recycleFiles(path: path) } catch ConnectionError.server(408) { failure = "The NAS has no accessible recycle-bin folder here. It may be empty or recycling may be disabled." } catch { failure = error.localizedDescription } }
    private func restore(_ file: RecycleFile) async { guard let client = app.client else { return }; restoring = nil; loading = true; defer { loading = false }; do { try await client.restoreRecycledFile(file); app.library.refresh(); await load() } catch { failure = "Restore could not be confirmed: " + error.localizedDescription } }
}
struct SharedWithMeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var albums: [SharedPhotoAlbum] = []; @State private var failure: String?; @State private var base: URL?
    var body: some View {
        List {
            Text("Albums other people share with you, shown with the owner’s permissions.").font(.footnote).foregroundStyle(.secondary)
            ForEach(albums) { album in
                if let token = album.passphrase, !token.isEmpty {
                    NavigationLink { SharedAlbumView(album: album) } label: {
                        LabeledContent { if let count = album.item_count { Text("\(count)") } } label: { Label(album.name, systemImage: "person.2") }
                    }
                } else { Text(album.name) }
            }
            if albums.isEmpty && failure == nil { Text("No albums shared with you") }
            if let failure { Text(failure).foregroundStyle(.red) }
        }.navigationTitle("Shared with me").task { await load() }.refreshable { await load() }
    }
    private func load() async { guard let client = app.client else { return }; do { albums = try await client.sharedWithMe(); base = await client.base } catch { failure = error.localizedDescription } }
}

struct CollectionWidgetChoice: Codable {
    let kind: String; let id: Int; let title: String; let shared: Bool
}
@MainActor enum FeatureWidgets {
    static func update(_ choice: CollectionWidgetChoice, client: DSMClient) async throws {
        let filter: ItemFilter = choice.kind == "album" ? .album(choice.id) : .person(choice.id)
        let photos = try await client.items(filter, shared: choice.shared, offset: 0, limit: 30)
        var snapshots: [WidgetSnapshot] = []
        for photo in photos where !photo.isVideo {
            try Task.checkCancellation()
            if let source = photo.thumbnailSource, let image = await ImagePipeline.shared.image(source, shared: choice.shared, size: .m), let data = image.jpegData(compressionQuality: 0.85) { snapshots.append(.init(title: choice.title, image: data, date: photo.date ?? Date())) }
            if snapshots.count == 12 { break }
        }
        guard !snapshots.isEmpty else { throw FeatureError.message("No previews are available for this collection yet.") }
        try WidgetSnapshotStore.saveFeed(snapshots, kind: choice.kind); WidgetCenter.shared.reloadAllTimelines()
    }
    static func refresh(client: DSMClient, account: String) async {
        for kind in ["album", "person"] {
            let key = "widgetChoice." + LibraryCache.hash(account) + kind
            if let data = UserDefaults.standard.data(forKey: key), let choice = try? JSONDecoder().decode(CollectionWidgetChoice.self, from: data) { try? await update(choice, client: client) }
        }
    }
}
struct CollectionWidgetSetup: View {
    let source: ItemFilter; let title: String; let shared: Bool
    @EnvironmentObject private var app: AppModel
    @State private var busy = false; @State private var message: String?
    var body: some View {
        Form {
            Text("Rotate photos from \(title) on your Home Screen. Fotera saves up to 12 previews and refreshes them when your library syncs.")
            Button("Use this collection") { Task { await save() } }.disabled(busy)
            if busy { ProgressView() }
            if let message { Text(message) }
        }.navigationTitle("Photo widget")
    }
    private func save() async {
        guard let client = app.client else { return }; busy = true; defer { busy = false }
        let choice: CollectionWidgetChoice
        switch source {
        case .album(let id): choice = .init(kind: "album", id: id, title: title, shared: shared)
        case .person(let id): choice = .init(kind: "person", id: id, title: title, shared: shared)
        default: return
        }
        do {
            try await FeatureWidgets.update(choice, client: client)
            UserDefaults.standard.set(try JSONEncoder().encode(choice), forKey: "widgetChoice." + LibraryCache.hash(app.account) + choice.kind)
            message = "Saved. Add the Fotera \(choice.kind == "album" ? "Album" : "Person") widget on your Home Screen."
        } catch { message = error.localizedDescription }
    }
}

struct FaceCorrectionView: View {
    let person: RemoteGroup; let shared: Bool
    @EnvironmentObject private var app: AppModel
    @State private var faces: [PersonFace] = []; @State private var selected = Set<Int>()
    @State private var confirming = false; @State private var busy = false; @State private var failure: String?
    var body: some View {
        List {
            Text("Select faces that belong to someone else. They will be separated into a new unnamed group; photos are not deleted.").font(.footnote)
            ForEach(faces) { face in
                Button { if !selected.insert(face.id).inserted { selected.remove(face.id) } } label: {
                    HStack {
                        ThumbnailView(source: face.thumbnailSource, shared: shared)
                            .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(face.filename ?? "Face \(face.id)")
                        Spacer(); if selected.contains(face.id) { Image(systemName: "checkmark") }
                    }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }.navigationTitle("Correct faces").disabled(busy)
        .toolbar { Button("Separate") { confirming = true }.disabled(selected.isEmpty || busy) }
        .task { await load() }
        .confirmationDialog("Separate these faces into a new person?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Separate selected faces") { Task { await separate() } }
        }
    }
    private func load() async { guard let client = app.client else { return }; do { faces = try await client.personFaces(person: person.id, shared: shared) } catch { failure = error.localizedDescription } }
    private func separate() async { guard let client = app.client else { return }; busy = true; defer { busy = false }; do { try await client.separateFaces(person: person.id, faces: Array(selected), shared: shared); selected = []; await load(); NotificationCenter.default.post(name: .foteraPeopleChanged, object: nil) } catch { failure = error.localizedDescription } }
}

import SwiftUI
import MapKit

// MARK: - Library tab

struct LibraryTab: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var library: LibraryStore
    @State private var albums: [RemoteAlbum] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var creating = false
    @State private var destination: Destination?
    @State private var sharedCount: Int?
    @ObservedObject private var favorites = FavoriteMarks.shared
    @AppStorage("albumSort") private var sort = "recent"
    enum Destination: String, Identifiable { case recent, duplicates, smart, offline, folders, trash, upload; var id: String { rawValue } }
    var body: some View {
        NavigationStack {
            ScrollView {
                HStack(spacing: Theme.medium) {
                    let favoritePhotos = library.favorites(favorites.ids)
                    coverTile("Favorites", count: favoritePhotos.count, cover: favoritePhotos.first(where: { !$0.isVideo }) ?? favoritePhotos.first) {
                        CollectionScreen(title: "Favorites", source: .filter(.favorites), unfavorite: true)
                    }
                    coverTile("Videos", count: library.videos.count, cover: library.videos.first) {
                        LocalCollectionScreen(title: "Videos", items: library.videos)
                    }
                    coverTile("Shared", count: sharedCount, cover: nil) { SharedWithMeView() }
                }
                .padding(.horizontal, Theme.gutter).padding(.top, 4)
                // Tools that used to hide in the ⋯ menu, reachable in one tap.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        utility("Recently deleted", "trash", .trash)
                        utility("Recently added", "clock", .recent)
                        utility("Duplicates", "square.on.square", .duplicates)
                        utility("Folders", "folder", .folders)
                        utility("Upload to NAS", "square.and.arrow.up", .upload)
                    }
                    .padding(.horizontal, Theme.gutter)
                }
                .padding(.top, Theme.medium)
                HStack {
                    Text("Albums").font(.title3.bold())
                    Spacer()
                    Menu {
                        Button("Recently added", systemImage: "clock") { destination = .recent }
                        Button("Duplicates", systemImage: "square.on.square") { destination = .duplicates }
                        Button("Smart albums", systemImage: "sparkles.rectangle.stack") { destination = .smart }
                        Button("Offline albums", systemImage: "arrow.down.circle") { destination = .offline }
                        Button("Folders", systemImage: "folder") { destination = .folders }
                        Button("Recently deleted", systemImage: "trash") { destination = .trash }
                        Button("Upload to NAS", systemImage: "square.and.arrow.up") { destination = .upload }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More collections").padding(.trailing, 12)
                    Menu {
                        Picker("Sort", selection: $sort) {
                            Text("Recently created").tag("recent")
                            Text("Name").tag("name")
                            Text("Most items").tag("count")
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Sort albums")
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New album").padding(.leading, 12)
                }
                .padding(.horizontal, Theme.gutter).padding(.top, 20)
                if app.shared {
                    Text("Albums belong to your Personal Space.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.medium), GridItem(.flexible(), spacing: Theme.medium)], spacing: Theme.medium) {
                    ForEach(sortedAlbums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: { AlbumCard(album: album) }.buttonStyle(.plain)
                    }
                }
                .padding(Theme.gutter)
                // Placeholders live in their own grid: sharing a lazy grid with album IDs reused their views.
                if loading && albums.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.medium), GridItem(.flexible(), spacing: Theme.medium)], spacing: Theme.medium) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Theme.radius).fill(Color(.secondarySystemFill)).aspectRatio(0.8, contentMode: .fit)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary).padding() }
                if !loading && albums.isEmpty && failure == nil {
                    Text("No albums yet. Select photos and choose Add to album, or tap +.").font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { FoteraBrand(page: "Library") } }
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .recent: CollectionScreen(title: "Recently added", source: .recentlyAdded)
                case .duplicates: DuplicatesView(library: library)
                case .smart: SmartAlbumsView()
                case .offline: OfflineAlbumsView()
                case .folders: FolderView(folder: nil)
                case .trash: RecycleBinView(path: app.shared ? "/photo/#recycle" : "/home/#recycle/Photos")
                case .upload: TransfersView(queue: app.manualUploads)
                }
            }
            .refreshable { await load() }
            .task { if albums.isEmpty { await load() } }
            .task(id: app.shared) { sharedCount = (try? await app.client?.sharedWithMe())?.count }
            .onReceive(NotificationCenter.default.publisher(for: .foteraAlbumsChanged)) { _ in Task { await load() } }
            .sheet(isPresented: $creating) {
                PhotoSelectionSheet(title: "New album", confirmTitle: "Next", asksForName: true) { ids, name in
                    guard let client = app.client, let name else { return }
                    _ = try await client.createAlbum(name: name, items: ids)
                    await load()
                }
            }
        }
    }
    private var sortedAlbums: [RemoteAlbum] {
        switch sort {
        case "name": return albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "count": return albums.sorted { ($0.item_count ?? 0) > ($1.item_count ?? 0) }
        default: return albums
        }
    }
    private func load() async {
        guard let client = app.client, !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do { albums = try await client.allAlbums() }
        catch { if !isCancelledRequest(error) { failure = error.localizedDescription } }
    }
    private func utility(_ title: String, _ icon: String, _ target: Destination) -> some View {
        Button { destination = target } label: {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }
    /// A photo-cover card like an album. Collections without a cover photo use a plain card.
    private func coverTile<Content: View>(_ title: String, count: Int?, cover: RemotePhoto?, @ViewBuilder destination: @escaping () -> Content) -> some View {
        NavigationLink(destination: destination) {
            ZStack(alignment: .bottomLeading) {
                if let cover {
                    ThumbnailView(source: cover.thumbnailSource, shared: app.shared, size: .m, fallbackPhoto: cover)
                } else {
                    Color(.secondarySystemBackground)
                }
                LinearGradient(colors: [.clear, .black.opacity(cover == nil ? 0.15 : 0.6)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let count { Text(count.formatted()).font(.caption2).opacity(0.85) }
                }
                .foregroundStyle(cover == nil ? Color.primary : Color.white)
                .padding(10)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0) items" } ?? title)
    }
}

struct AlbumCard: View {
    let album: RemoteAlbum
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ThumbnailView(source: album.cover, shared: false, size: .m)
            if album.cover == nil {
                Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(.headline).lineLimit(2)
                HStack(spacing: 4) {
                    if let count = album.item_count { Text("\(count) \(count == 1 ? "item" : "items")") }
                    if album.shared == true { Image(systemName: "link") }
                }.font(.caption).opacity(0.85)
            }
            .foregroundStyle(.white).padding(Theme.medium)
        }
        .aspectRatio(0.8, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var album: RemoteAlbum
    @State private var items: [RemotePhoto] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var selection: Set<Int>?
    @State private var sharing = false
    @State private var adding = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var deleting = false
    @StateObject private var runner = ActionRunner()
    var body: some View {
        Group {
            if items.isEmpty && !loading {
                ContentUnavailableView {
                    Label(failure == nil ? "Empty album" : "Couldn’t load album", systemImage: "rectangle.stack")
                } description: { Text(failure ?? "Add photos to this album.") } actions: {
                    Button("Add photos") { adding = true }
                }
            } else {
                PhotoGrid(sections: items.asSingleSection, shared: false, selection: $selection, album: album, onChange: { Task { await load() } }) {
                    if let count = album.item_count {
                        Text("\(count) items").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
            }
        }
        .overlay { if loading && items.isEmpty { SkeletonGrid(showsHeaders: false).background(Color(.systemBackground)) } }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selection == nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Select", systemImage: "checkmark.circle") { selection = [] }
                        Button("Add photos", systemImage: "plus") { adding = true }
                        NavigationLink("Album widget") { CollectionWidgetSetup(source: .album(album.id), title: album.name, shared: false) }
                        Button("Share link", systemImage: "link") { sharing = true }
                        Button("Rename", systemImage: "pencil") { newName = album.name; renaming = true }
                        Button("Delete album", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Album options")
                }
            }
        }
        .selectionChrome($selection, items: items, actions: [.share, .favorite, .save, .removeFromAlbum, .delete], album: album) { Task { await load() } }
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
        .sheet(isPresented: $sharing) { AlbumSharingView(album: album) }
        .sheet(isPresented: $adding) {
            PhotoSelectionSheet(title: "Add to \(album.name)", confirmTitle: "Add", excluded: Set(items.map(\.id))) { ids, _ in
                guard let client = app.client else { return }
                try await client.changeAlbumItems(id: album.id, items: ids, adding: true)
                await load()
            }
        }
        .alert("Rename album", isPresented: $renaming) {
            TextField("Album name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let client = app.client else { return }
                runner.run("Renaming…") {
                    try await client.renameAlbum(id: album.id, name: name)
                    album.name = name
                    NotificationCenter.default.post(name: .foteraAlbumsChanged, object: nil)
                    return nil
                }
            }
        }
        .confirmationDialog("Delete “\(album.name)”? Its photos stay in your library.", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete album", role: .destructive) {
                guard let client = app.client else { return }
                runner.run("Deleting album…") {
                    try await client.deleteAlbum(id: album.id)
                    NotificationCenter.default.post(name: .foteraAlbumsChanged, object: nil)
                    dismiss()
                    return nil
                }
            }
        }
        .actionRunner(runner)
    }
    private func load() async {
        guard let client = app.client, !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            var result: [RemotePhoto] = []; var seen = Set<Int>(); var offset = 0
            while true {
                let page = try await client.items(.album(album.id), shared: false, offset: offset)
                result += page.filter { seen.insert($0.id).inserted }
                offset += page.count
                if page.count < DSMClient.pageSize { break }
            }
            items = result
            album.item_count = result.count
        } catch { if !isCancelledRequest(error) { failure = error.localizedDescription } }
    }
}

/// Picks photos from the timeline, used to create albums and add to them.
struct PhotoSelectionSheet: View {
    let title: String
    let confirmTitle: String
    var asksForName = false
    var excluded: Set<Int> = []
    let confirm: ([Int], String?) async throws -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int>? = []
    @State private var naming = false
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            PhotoGrid(sections: app.library.sections.compactMap { section in
                let items = section.items.filter { !$0.isLocalOnly && !excluded.contains($0.id) }
                return items.isEmpty ? nil : GridSection(id: String(section.id.timeIntervalSince1970), title: section.title, items: items)
            }, shared: app.shared, selection: $selection, showsScrubber: true)
            .overlay { if saving { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    VStack {
                        Text(title).font(.headline)
                        Text("\(selection?.count ?? 0) selected").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { if asksForName { naming = true } else { Task { await save(nil) } } }
                        .disabled((selection ?? []).isEmpty || saving)
                }
            }
            .alert("Album name", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await save(name.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("Couldn’t save", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
            .interactiveDismissDisabled(saving)
        }
    }
    private func save(_ name: String?) async {
        saving = true
        defer { saving = false }
        do { try await confirm(Array(selection ?? []), name); dismiss() }
        catch { failure = error.localizedDescription }
    }
}

// MARK: - Server-backed grids

enum CollectionSource: Hashable {
    case filter(ItemFilter)
    case search(String)
    case recentlyAdded
}

/// A paginated grid for favorites, people, places, folders and searches.
struct CollectionScreen<Header: View>: View {
    let title: String
    let source: CollectionSource
    var unfavorite = false
    @ViewBuilder var header: () -> Header
    @EnvironmentObject private var app: AppModel
    @State private var items: [RemotePhoto] = []
    @State private var more = true
    @State private var loading = false
    @State private var failure: String?
    @State private var selection: Set<Int>?
    var body: some View {
        PhotoGrid(sections: items.asSingleSection, shared: app.shared, selection: $selection,
                  onReachEnd: more ? { Task { await load(reset: false) } } : nil,
                  onChange: { Task { await load(reset: true) } }) {
            header()
            if items.isEmpty && !loading {
                ContentUnavailableView(failure == nil ? "Nothing here" : "Couldn’t load", systemImage: "photo",
                                       description: failure.map(Text.init)).padding(.top, 60)
            }
        }
        .overlay { if loading && items.isEmpty { SkeletonGrid(showsHeaders: false).background(Color(.systemBackground)) } }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { if selection == nil && !items.isEmpty { Button("Select") { selection = [] } } }
        .selectionChrome($selection, items: items, unfavorite: unfavorite) { Task { await load(reset: true) } }
        .refreshable { await load(reset: true) }
        .task { if items.isEmpty { await load(reset: true) } }
    }
    private func load(reset: Bool) async {
        guard let client = app.client, !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        let offset = reset ? 0 : items.count
        do {
            let page: [RemotePhoto]
            switch source {
            case .filter(let filter): page = try await client.items(filter, shared: app.shared, offset: offset)
            case .search(let keyword): page = try await client.search(keyword: keyword, shared: app.shared, offset: offset)
            case .recentlyAdded: page = try await client.recentlyAdded(shared: app.shared, offset: offset)
            }
            var seen = Set(reset ? [] : items.map(\.id))
            let added = page.filter { seen.insert($0.id).inserted }
            items = reset ? added : items + added
            if case .filter = source { more = page.count >= DSMClient.pageSize && !added.isEmpty }
            else { more = page.count >= 100 && !added.isEmpty }
        } catch {
            if !isCancelledRequest(error) { failure = error.localizedDescription; more = false }
        }
    }
}
extension CollectionScreen where Header == EmptyView {
    init(title: String, source: CollectionSource, unfavorite: Bool = false) {
        self.init(title: title, source: source, unfavorite: unfavorite, header: { EmptyView() })
    }
}

/// A grid over items already in the local index, such as Videos.
struct LocalCollectionScreen: View {
    let title: String
    let items: [RemotePhoto]
    @EnvironmentObject private var app: AppModel
    @State private var selection: Set<Int>?
    var body: some View {
        Group {
            if items.isEmpty { ContentUnavailableView("Nothing here", systemImage: "photo") }
            else { PhotoGrid(sections: items.asSingleSection, shared: app.shared, selection: $selection) }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { if selection == nil && !items.isEmpty { Button("Select") { selection = [] } } }
        .selectionChrome($selection, items: items)
    }
}

struct FolderView: View {
    let folder: RemoteFolder?
    /// Shown inside the Photos tab, which supplies its own title.
    var embedded = false
    @EnvironmentObject private var app: AppModel
    @State private var folders: [RemoteFolder] = []
    @State private var failure: String?
    var body: some View {
        Group {
            if let folder {
                CollectionScreen(title: folder.displayName, source: .filter(.folder(folder.id))) { subfolders }
            } else {
                if embedded { ScrollView { subfolders }.refreshable { await reload() } }
                else { ScrollView { subfolders }.navigationTitle("Folders").navigationBarTitleDisplayMode(.inline) }
            }
        }
        .task { if folders.isEmpty { await reload() } }
    }
    private func reload() async {
        guard let client = app.client else { return }
        do {
            folders = try await client.folders(shared: app.shared, parent: folder?.id ?? 0, offset: 0)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            failure = nil
        } catch { failure = error.localizedDescription }
    }
    @ViewBuilder private var subfolders: some View {
        if !folders.isEmpty || failure != nil {
            VStack(spacing: 0) {
                ForEach(folders) { child in
                    NavigationLink { FolderView(folder: child) } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                            Text(child.displayName).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider().padding(.leading, 48)
                }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary).padding() }
            }
        }
    }
}

// MARK: - Album sharing

struct AlbumSharingView: View {
    let album: RemoteAlbum
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var state: AlbumSharingState?
    @State private var role = "view"
    @State private var password = ""
    @State private var expires = false
    @State private var expiration = Date().addingTimeInterval(7 * 86400)
    @State private var confirming = false
    @State private var stopping = false
    @State private var busy = false
    @State private var failure: String?
    private var isShared: Bool { state?.shared == true }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let link = state?.additional?.sharing_info?.sharing_link, let url = URL(string: link), url.scheme == "https", isShared {
                        ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.url = url } label: { Label("Copy link", systemImage: "doc.on.doc") }
                        Text(link).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if state != nil {
                        Text("This album isn’t shared by link.").foregroundStyle(.secondary)
                    } else if failure == nil { ProgressView() }
                } header: { Text("Public link") }
                Section {
                    Picker("Access", selection: $role) { Text("View").tag("view"); Text("View and download").tag("download") }
                    SecureField("Password (optional)", text: $password)
                    Toggle("Expires", isOn: $expires)
                    if expires { DatePicker("Expires on", selection: $expiration, in: Date()..., displayedComponents: [.date]) }
                    Button(isShared ? "Update link" : "Create link") { confirming = true }.disabled(state == nil)
                    if isShared { Button("Stop sharing", role: .destructive) { stopping = true } }
                } footer: { Text("Anyone with the link can see this album. Leaving the password blank removes any existing password.") }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .navigationTitle("Share “\(album.name)”").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task {
                guard let client = app.client else { return }
                do {
                    state = try await client.albumSharing(id: album.id)
                    if state?.additional?.sharing_info?.privacy_type == "public-download" { role = "download" }
                    if let expiry = state?.additional?.sharing_info?.expiration, expiry > 0 { expires = true; expiration = Date(timeIntervalSince1970: expiry) }
                } catch { failure = error.localizedDescription }
            }
            .confirmationDialog("Anyone with the link will be able to access this album.", isPresented: $confirming, titleVisibility: .visible) {
                Button(isShared ? "Update link" : "Create link") { Task { await update(enabled: true) } }
            }
            .confirmationDialog("Stop sharing? Existing links will stop working.", isPresented: $stopping, titleVisibility: .visible) {
                Button("Stop sharing", role: .destructive) { Task { await update(enabled: false) } }
            }
        }
    }
    private func update(enabled: Bool) async {
        guard let client = app.client else { return }
        busy = true; failure = nil
        defer { busy = false }
        do {
            state = try await client.updateAlbumSharing(id: album.id, enabled: enabled, role: role, password: password, expiration: expires ? expiration : nil)
            password = ""
            NotificationCenter.default.post(name: .foteraAlbumsChanged, object: nil)
        } catch {
            failure = "Sharing changes couldn’t be confirmed. Review the current state before retrying. " + error.localizedDescription
            state = try? await client.albumSharing(id: album.id)
        }
    }
}

// MARK: - Search & explore

struct SearchTab: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var library: LibraryStore
    @State private var query = ""
    @State private var submitted = ""
    @State private var people: [RemoteGroup] = []
    @State private var places: [RemoteGroup] = []
    @State private var things: [RemoteGroup] = []
    @State private var loaded = false
    @State private var openedGroup: OpenedGroup?
    @AppStorage("recentSearches") private var recentData = Data()
    struct OpenedGroup: Identifiable, Hashable {
        let group: RemoteGroup
        let kind: String
        var id: String { kind + String(group.id) }
    }
    private var recents: [String] { (try? JSONDecoder().decode([String].self, from: recentData)) ?? [] }
    var body: some View {
        NavigationStack {
            Group {
                if submitted.isEmpty { explore } else { CollectionScreen(title: submitted, source: .search(submitted)).id(submitted) }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { FoteraBrand(page: "Search") } }
            .searchable(text: $query, prompt: "People, places, things, files")
            .searchSuggestions { suggestions }
            .onSubmit(of: .search) { submit(query) }
            .onChange(of: query) { if query.isEmpty { submitted = "" } }
            .navigationDestination(item: $openedGroup) { opened in groupScreen(opened.group, kind: opened.kind) }
            .task(id: app.shared) { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .foteraPeopleChanged)) { _ in Task { await load(force: true) } }
        }
    }
    /// As you type: matching people, places and things, then recent searches, like Immich.
    @ViewBuilder private var suggestions: some View {
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            ForEach(recents, id: \.self) { recent in
                Label(recent, systemImage: "clock.arrow.circlepath").searchCompletion(recent)
            }
        } else {
            let matching: [(RemoteGroup, String, String)] =
                people.filter { !$0.name.isEmpty && $0.name.localizedCaseInsensitiveContains(text) }.prefix(4).map { ($0, "person", "person.crop.circle") } +
                places.filter { $0.name.localizedCaseInsensitiveContains(text) }.prefix(4).map { ($0, "place", "mappin.circle") } +
                things.filter { $0.name.localizedCaseInsensitiveContains(text) }.prefix(4).map { ($0, "thing", "tag.circle") }
            ForEach(matching, id: \.0.id) { group, kind, icon in
                Button { openedGroup = OpenedGroup(group: group, kind: kind) } label: {
                    HStack(spacing: 12) {
                        ThumbnailView(source: group.cover(kind: kind == "person" ? "person" : "unit"), shared: app.shared, size: .sm)
                            .frame(width: 32, height: 32).clipShape(kind == "person" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
                        Label(displayName(group, kind: kind), systemImage: icon).labelStyle(.titleOnly).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: icon).foregroundStyle(.secondary)
                    }
                }
            }
            Label("Search for “\(text)”", systemImage: "magnifyingglass").searchCompletion(text)
        }
    }
    private func submit(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted = value
        guard !value.isEmpty else { return }
        let updated = [value] + recents.filter { $0.caseInsensitiveCompare(value) != .orderedSame }
        recentData = (try? JSONEncoder().encode(Array(updated.prefix(8)))) ?? Data()
    }
    private var explore: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !people.isEmpty {
                    header("People") { GroupListView(title: "People", groups: people, kind: "person") }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: [GridItem(.fixed(104))], spacing: Theme.large) {
                            ForEach(people.prefix(30)) { person in
                                NavigationLink { PersonDetailView(person: person, shared: app.shared) } label: {
                                    VStack(spacing: 6) {
                                        ThumbnailView(source: person.cover(kind: "person"), shared: app.shared, size: .sm)
                                            .frame(width: 80, height: 80).clipShape(Circle())
                                        Text(displayName(person, kind: "person")).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                    }.frame(width: 84)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, Theme.gutter)
                    }
                }
                if !places.isEmpty {
                    header("Places") { GroupListView(title: "Places", groups: places, kind: "place") }
                    cardRow(places.prefix(12), kind: "place")
                }
                if !things.isEmpty {
                    header("Things") { GroupListView(title: "Things", groups: things, kind: "thing") }
                    cardRow(things.prefix(12), kind: "thing")
                }
                VStack(spacing: 0) {
                    if !library.located.isEmpty {
                        browseRow("Map", "map", subtitle: "\(library.located.count.formatted()) photos with locations") { PhotoMapView(photos: library.located) }
                        Divider().padding(.leading, 52)
                    }
                    browseRow("On this iPhone", "iphone", subtitle: "Search the saved library, even offline") { OfflineLibrarySearchView(library: library) }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .padding(.horizontal, Theme.gutter)
                if !loaded {
                    HStack(spacing: Theme.large) {
                        ForEach(0..<4, id: \.self) { _ in Circle().fill(Color(.secondarySystemFill)).frame(width: 80, height: 80) }
                    }.padding(.horizontal, Theme.gutter)
                } else if people.isEmpty && places.isEmpty && things.isEmpty {
                    ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                        description: Text("Search by filename, tag, place or thing. People and places appear once Synology Photos indexes them."))
                }
            }.padding(.vertical, 8)
        }
        .refreshable { await load(force: true) }
    }
    private func header<Destination: View>(_ title: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 4) {
                Text(title).font(.title3.bold()).foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.gutter)
        .accessibilityHint("Shows all \(title.lowercased())")
    }
    private func browseRow<Destination: View>(_ title: String, _ icon: String, subtitle: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.medium).padding(.vertical, Theme.medium).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func cardRow(_ groups: ArraySlice<RemoteGroup>, kind: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(groups) { group in
                    NavigationLink { groupScreen(group, kind: kind) } label: { GroupCard(group: group, kind: kind).frame(width: 140, height: 160) }
                        .buttonStyle(.plain)
                }
            }.padding(.horizontal, Theme.gutter)
        }
    }
    /// People, places and things change rarely; reuse them for 5 minutes per space unless pulled to refresh.
    private static var cache: [Bool: (date: Date, people: [RemoteGroup], places: [RemoteGroup], things: [RemoteGroup])] = [:]
    private func load(force: Bool = false) async {
        guard let client = app.client else { return }
        if !force, let cached = Self.cache[app.shared], Date().timeIntervalSince(cached.date) < 300 {
            people = cached.people; places = cached.places; things = cached.things; loaded = true; return
        }
        async let people = try? client.people(shared: app.shared)
        async let places = try? client.places(shared: app.shared)
        async let things = try? client.concepts(shared: app.shared)
        self.people = (await people ?? []).filter { ($0.item_count ?? 0) > 0 }
        self.places = (await places ?? []).sorted { ($0.item_count ?? 0) > ($1.item_count ?? 0) }
        self.things = (await things ?? []).sorted { ($0.item_count ?? 0) > ($1.item_count ?? 0) }
        loaded = true
        Self.cache[app.shared] = (Date(), self.people, self.places, self.things)
    }
}
func displayName(_ group: RemoteGroup, kind: String) -> String {
    group.name.isEmpty ? (kind == "person" ? "Unnamed" : "Unknown") : group.name
}
@ViewBuilder func groupScreen(_ group: RemoteGroup, kind: String) -> some View {
    switch kind {
    case "person": PersonDetailDestination(person: group)
    case "place": CollectionScreen(title: displayName(group, kind: kind), source: .filter(.place(group.id)))
    default: CollectionScreen(title: displayName(group, kind: kind), source: .search(group.name))
    }
}
struct GroupCard: View {
    let group: RemoteGroup
    let kind: String
    @EnvironmentObject private var app: AppModel
    var body: some View {
        ThumbnailView(source: group.cover(kind: kind == "person" ? "person" : "unit"), shared: app.shared, size: .m)
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if kind == "place" { Image(systemName: "mappin.and.ellipse").font(.caption2.weight(.bold)) }
                        Text(displayName(group, kind: kind)).font(.subheadline.weight(.semibold)).lineLimit(2)
                    }
                    if kind == "place", let country = group.country, !country.isEmpty, country != group.name {
                        Text(country).font(.caption2).opacity(0.85)
                    } else if let count = group.item_count {
                        Text("\(count) \(count == 1 ? "item" : "items")").font(.caption2).opacity(0.85)
                    }
                }
                .foregroundStyle(.white).padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}
struct GroupListView: View {
    let title: String
    let groups: [RemoteGroup]
    let kind: String
    @EnvironmentObject private var app: AppModel
    @State private var updatedGroups: [RemoteGroup]?
    private var shownGroups: [RemoteGroup] { updatedGroups ?? groups }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: kind == "person" ? 90 : 150), spacing: 12)], spacing: 16) {
                ForEach(shownGroups) { group in
                    NavigationLink { groupScreen(group, kind: kind) } label: {
                        if kind == "person" {
                            VStack(spacing: 6) {
                                ThumbnailView(source: group.cover(kind: "person"), shared: app.shared, size: .sm)
                                    .aspectRatio(1, contentMode: .fit).clipShape(Circle())
                                Text(displayName(group, kind: kind)).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                if let count = group.item_count { Text("\(count)").font(.caption2).foregroundStyle(.secondary) }
                            }
                        } else {
                            GroupCard(group: group, kind: kind).aspectRatio(1, contentMode: .fit)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(16)
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if kind == "person" {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { HiddenPeopleView() } label: { Label("Hidden people", systemImage: "eye.slash") }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .foteraPeopleChanged)) { _ in
            guard kind == "person", let client = app.client else { return }
            let space = app.shared
            Task {
                if let refreshed = try? await client.people(shared: space), space == app.shared { updatedGroups = refreshed }
            }
        }
    }
}

/// Plain values can cross to the clustering worker without carrying MapKit UI state.
struct PhotoMapViewport: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let latitudeSpan: Double
    let longitudeSpan: Double
    static let world = PhotoMapViewport(latitude: 0, longitude: 0, latitudeSpan: 180, longitudeSpan: 360)
}
struct PhotoMapCluster: Identifiable, Sendable {
    let id: Int
    let latitude: Double
    let longitude: Double
    let items: [RemotePhoto]
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}
enum PhotoMapClustering {
    /// An 8 x 8 viewport grid caps rendering work at 64 markers, regardless of library size.
    nonisolated static func build(_ photos: [RemotePhoto], viewport: PhotoMapViewport) throws -> [PhotoMapCluster] {
        guard viewport.latitude.isFinite, viewport.longitude.isFinite,
              viewport.latitudeSpan.isFinite, viewport.longitudeSpan.isFinite,
              viewport.latitudeSpan > 0, viewport.longitudeSpan > 0 else { return [] }
        let height = min(180, viewport.latitudeSpan), width = min(360, viewport.longitudeSpan)
        let bottom = viewport.latitude - height / 2
        struct Bucket {
            var items: [RemotePhoto] = []
            var latitude = 0.0
            var longitudeOffset = 0.0
        }
        func wrap(_ longitude: Double) -> Double {
            let value = (longitude + 180).truncatingRemainder(dividingBy: 360)
            return (value < 0 ? value + 360 : value) - 180
        }
        var buckets: [Int: Bucket] = [:]
        for (index, photo) in photos.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard let gps = photo.additional?.gps, gps.latitude.isFinite, gps.longitude.isFinite,
                  (-90...90).contains(gps.latitude), (-180...180).contains(gps.longitude) else { continue }
            let offset = wrap(gps.longitude - viewport.longitude)
            guard gps.latitude >= bottom, gps.latitude <= bottom + height,
                  abs(offset) <= width / 2 else { continue }
            let row = min(7, max(0, Int(((gps.latitude - bottom) / height * 8).rounded(.down))))
            let column = min(7, max(0, Int(((offset + width / 2) / width * 8).rounded(.down))))
            let key = row * 8 + column
            buckets[key, default: Bucket()].items.append(photo)
            buckets[key]!.latitude += gps.latitude
            buckets[key]!.longitudeOffset += offset
        }
        try Task.checkCancellation()
        return buckets.keys.sorted().map { key in
            let bucket = buckets[key]!
            let count = Double(bucket.items.count)
            return PhotoMapCluster(id: key, latitude: bucket.latitude / count,
                                   longitude: wrap(viewport.longitude + bucket.longitudeOffset / count), items: bucket.items)
        }
    }
}

/// Visible photos are clustered off the main thread; camera movement cancels obsolete work.
struct PhotoMapView: View {
    let photos: [RemotePhoto]
    @EnvironmentObject private var app: AppModel
    @State private var clusters: [PhotoMapCluster] = []
    @State private var selected: PhotoMapCluster?
    @State private var viewport = PhotoMapViewport.world
    @State private var loading = true
    var body: some View {
        // A fixed initial region avoids automatic camera fitting reacting to every cluster update.
        Map(initialPosition: .rect(.world)) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate) {
                    Button { selected = cluster } label: {
                        ThumbnailView(source: cluster.items.first?.thumbnailSource, shared: app.shared, size: .sm, fallbackPhoto: cluster.items.first)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
                            .overlay(alignment: .topTrailing) {
                                if cluster.items.count > 1 {
                                    Text("\(cluster.items.count)").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.accentColor, in: Capsule()).offset(x: 8, y: -8)
                                }
                            }
                            .shadow(radius: 2)
                    }.accessibilityLabel("\(cluster.items.count) photos")
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            viewport = PhotoMapViewport(latitude: context.region.center.latitude, longitude: context.region.center.longitude,
                                        latitudeSpan: context.region.span.latitudeDelta, longitudeSpan: context.region.span.longitudeDelta)
        }
        .task(id: viewport) {
            loading = true
            let items = photos, region = viewport
            let worker = Task.detached(priority: .userInitiated) { try PhotoMapClustering.build(items, viewport: region) }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                clusters = result
                loading = false
            } catch {
                if !Task.isCancelled { loading = false }
            }
        }
        .overlay(alignment: .top) {
            if loading { ProgressView("Loading locations…").padding(10).background(.regularMaterial, in: Capsule()).padding() }
        }
        .navigationTitle("Map").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { cluster in
            NavigationStack { LocalCollectionScreen(title: "\(cluster.items.count) photos", items: cluster.items) }
                .presentationDetents([.medium, .large])
        }
    }
}

struct OfflineLibrarySearchView: View {
    @ObservedObject var library: LibraryStore
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var media: LibraryMediaFilter = .all
    @State private var year = 0
    @State private var selection: Set<Int>?
    private var results: [RemotePhoto] { LocalLibrarySearch.results(library.photos, query: query, media: media, year: year == 0 ? nil : year) }
    private var years: [Int] { library.years }
    var body: some View {
        let matches = results
        VStack(spacing: 0) {
            HStack {
                Picker("Media", selection: $media) { ForEach(LibraryMediaFilter.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Year", selection: $year) {
                    Text("All years").tag(0)
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                Spacer()
                Text("\(matches.count) items").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal)
            if matches.isEmpty { ContentUnavailableView.search(text: query) }
            else { PhotoGrid(sections: matches.asSingleSection, shared: app.shared, selection: $selection) }
        }
        .navigationTitle("Saved library").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Filename, month, or YYYY-MM-DD")
        .safeAreaInset(edge: .bottom) {
            if selection == nil { Text("Searches the library index on this iPhone. Uncached photos and changes need a NAS connection.").font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity).background(.bar) }
        }
        .toolbar { if selection == nil && !matches.isEmpty { Button("Select") { selection = [] } } }
        .selectionChrome($selection, items: matches)
        .onChange(of: query) { selection = nil }
        .onChange(of: media) { selection = nil }
        .onChange(of: year) { selection = nil }
        .onChange(of: app.shared) { selection = nil; year = 0 }
    }
}

/// Captures the Photos space when opening a person, so edits target the correct library.
struct PersonDetailDestination: View {
    let person: RemoteGroup
    @EnvironmentObject private var app: AppModel
    var body: some View { PersonDetailView(person: person, shared: app.shared) }
}
struct PersonDetailView: View {
    @State var person: RemoteGroup
    let shared: Bool
    @EnvironmentObject private var app: AppModel
    @State private var editing = false
    var body: some View {
        CollectionScreen(title: displayName(person, kind: "person"), source: .filter(.person(person.id)))
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button(person.name.isEmpty ? "Name person" : "Edit name", systemImage: "pencil") { editing = true }
                    NavigationLink("Manage person") { PeopleManagementView(person: person, shared: shared) }
                    NavigationLink("Use in widget") { CollectionWidgetSetup(source: .person(person.id), title: displayName(person, kind: "person"), shared: shared) }
                }
            }
            .sheet(isPresented: $editing) {
                PersonNameEditor(person: person, shared: shared) { person = $0 }
            }
    }
}
struct PersonNameEditor: View {
    let person: RemoteGroup
    let shared: Bool
    var saved: (RemoteGroup) -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); ThumbnailView(source: person.cover(kind: "person"), shared: shared, size: .m).frame(width: 100, height: 100).clipShape(Circle()); Spacer() }
                    TextField("Name", text: $name).textContentType(.name).textInputAutocapitalization(.words).focused($focused)
                } footer: { Text("This name is saved in Synology Photos and applies to this person’s group of photos.") }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle(person.name.isEmpty ? "Name person" : "Edit name").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || trimmed.isEmpty || trimmed == person.name)
                }
            }
            .disabled(saving).overlay { if saving { ProgressView("Saving name…") } }
            .interactiveDismissDisabled(saving)
            .onAppear { name = person.name; focused = true }
        }
    }
    private func save() async {
        guard let client = app.client, !trimmed.isEmpty else { return }
        saving = true; failure = nil
        defer { saving = false }
        do {
            let updated = try await client.renamePerson(id: person.id, name: trimmed, shared: shared)
            saved(updated)
            NotificationCenter.default.post(name: .foteraPeopleChanged, object: nil)
            dismiss()
        } catch {
            failure = "Couldn’t confirm the name was saved. Your entry is kept here so you can retry. " + error.localizedDescription
        }
    }
}

#if DEBUG
/// Isolated UI stress check: synthetic metadata only; does not restore a NAS session.
struct MapStressPreview: View {
    @State private var photos: [RemotePhoto] = []
    var body: some View {
        NavigationStack {
            VStack {
                if photos.isEmpty { ProgressView("Preparing test library") }
                else { NavigationLink("Open 100,000-photo map") { PhotoMapView(photos: photos) } }
            }.navigationTitle("Map performance check")
        }.task {
            photos = await Task.detached(priority: .userInitiated) {
                (0..<100_000).map { index in
                    var photo = RemotePhoto(id: index, filename: "Test.heic", time: nil, type: "photo", additional: nil)
                    photo.additional = .init(thumbnail: nil, gps: .init(latitude: Double(index % 160) - 80,
                                                                      longitude: Double((index * 17) % 360) - 180), video_meta: nil)
                    return photo
                }
            }.value
        }
    }
}
#endif

import SwiftUI
import MapKit

// MARK: - Library tab

struct LibraryTab: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var library: LibraryStore
    @State private var destination: Destination?
    @State private var sharedCount: Int?
    @State private var discoveryRefresh = 0
    @ObservedObject private var favorites = FavoriteMarks.shared
    enum Destination: String, Identifiable { case recent, duplicates, smart, offline, folders, trash, upload; var id: String { rawValue } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 14) {
                        let favoritePhotos = library.favorites(favorites.ids)
                        coverTile("Favorites", icon: "heart.fill", count: favoritePhotos.count,
                                  cover: favoritePhotos.first(where: { !$0.isVideo }) ?? favoritePhotos.first) {
                            CollectionScreen(title: "Favorites", source: .filter(.favorites), unfavorite: true)
                        }
                        coverTile("Videos", icon: "play.rectangle.fill", count: library.videos.count, cover: library.videos.first) {
                            LocalCollectionScreen(title: "Videos", items: library.videos)
                        }
                    }
                    LibraryDiscoveryView(library: library, refresh: discoveryRefresh)
                        .padding(.horizontal, -Theme.gutter)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Collections").font(.title2.bold())
                        VStack(spacing: 0) {
                            utility("Recently added", "clock", .recent)
                            rowDivider
                            NavigationLink { OfflineLibrarySearchView(library: library) } label: {
                                collectionRow("Search on this iPhone", icon: "iphone")
                            }.buttonStyle(.plain)
                            rowDivider
                            NavigationLink { SharedWithMeView() } label: {
                                collectionRow("Shared with me", icon: "person.2", count: sharedCount)
                            }.buttonStyle(.plain)
                            rowDivider
                            utility("Folders", "folder", .folders)
                            rowDivider
                            utility("Smart albums", "sparkles.rectangle.stack", .smart)
                            rowDivider
                            utility("Offline albums", "arrow.down.circle", .offline)
                        }
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Utilities").font(.title2.bold())
                        VStack(spacing: 0) {
                            utility("Upload to NAS", "square.and.arrow.up", .upload)
                            rowDivider
                            utility("Duplicates", "square.on.square", .duplicates)
                            rowDivider
                            utility("Recently deleted", "trash", .trash)
                        }
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
            }
            .modifier(LibrarySearch(library: library))
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
            .refreshable { discoveryRefresh += 1; await load() }
            .refreshWhileActive(key: app.account + "|" + String(app.shared)) { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .foteraAlbumsChanged)) { _ in Task { await load() } }

        }
    }
    private func load() async {
        guard let client = app.client else { return }
        let count = try? await client.sharedWithMe().count
        guard !Task.isCancelled, app.client === client else { return }
        sharedCount = count
    }
    private var rowDivider: some View { Divider().padding(.leading, 54) }
    private func collectionRow(_ title: String, icon: String, count: Int? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color.accentColor).frame(width: 24)
            Text(title).font(.body).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let count { Text(count.formatted()).font(.subheadline).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .frame(minHeight: 52).contentShape(Rectangle())
    }
    private func utility(_ title: String, _ icon: String, _ target: Destination) -> some View {
        Button { destination = target } label: { collectionRow(title, icon: icon) }.buttonStyle(.plain)
    }
    private func coverTile<Content: View>(_ title: String, icon: String, count: Int?, cover: RemotePhoto?,
                                         @ViewBuilder destination: @escaping () -> Content) -> some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Color(.secondarySystemBackground)
                    if let cover {
                        ThumbnailView(source: cover.thumbnailSource, shared: app.shared, size: .m, fallbackPhoto: cover)
                    } else {
                        Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundStyle(Color.accentColor)
                    }
                }
                .aspectRatio(1.22, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    if let count { Text(count.formatted()).font(.subheadline).foregroundStyle(.secondary) }
                }
            }.foregroundStyle(.primary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0) items" } ?? title)
    }
}

struct AlbumsTab: View {
    @EnvironmentObject private var app: AppModel
    @State private var albums: [RemoteAlbum] = []
    @State private var loading = false
    @State private var reloadRequested = false
    @State private var failure: String?
    @State private var creating = false
    @AppStorage("albumSort") private var sort = "recent"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        NavigationLink { SharedWithMeView() } label: { Label("Shared", systemImage: "person.2") }
                        Spacer()
                        Menu {
                            NavigationLink("Smart albums") { SmartAlbumsView() }
                            NavigationLink("Offline albums") { OfflineAlbumsView() }
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Albums").font(.title2.bold())
                            Spacer()
                            Menu {
                                Picker("Sort albums", selection: $sort) {
                                    Text("Recently created").tag("recent")
                                    Text("Name").tag("name")
                                    Text("Most items").tag("count")
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                            }.accessibilityLabel("Sort albums")
                            Button { creating = true } label: {
                                Image(systemName: "plus").frame(width: 44, height: 44)
                                    .background(Color.accentColor.opacity(0.10), in: Circle())
                            }.accessibilityLabel("New album")
                        }
                        if app.shared {
                            Text("Albums are in Personal Space").font(.footnote).foregroundStyle(.secondary)
                        }
                        if loading && albums.isEmpty {
                            LazyVGrid(columns: albumColumns, spacing: 16) {
                                ForEach(0..<2, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemFill))
                                        .aspectRatio(1, contentMode: .fit)
                                }
                            }
                        } else if !albums.isEmpty {
                            LazyVGrid(columns: albumColumns, alignment: .leading, spacing: 22) {
                                ForEach(sortedAlbums) { album in
                                    NavigationLink { AlbumDetailView(album: album) } label: { AlbumCard(album: album) }
                                        .buttonStyle(.plain)
                                }
                            }
                        } else if failure == nil {
                            Button { creating = true } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 30, weight: .light))
                                    Text("Create your first album").font(.subheadline.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 30)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain)
                        }
                        if let failure {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(failure).font(.footnote).foregroundStyle(.secondary)
                                Button("Try again") { Task { await load() } }
                            }
                        }
                    }

                }.padding(20)
            }
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { FoteraBrand(page: "Albums") } }
            .refreshable { await load() }
            .refreshWhileActive(key: app.account) { await load() }
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
        #if DEBUG
        if StoreScreenshots.enabled { albums = StoreScreenshots.albums; return }
        #endif
        guard let client = app.client else {return}
        guard !loading else {reloadRequested = true; return}
        loading = true; failure = nil
        defer {
            loading = false
            if reloadRequested {reloadRequested = false; Task {await load()}}
        }
        do {
            let fresh = try await client.allAlbums()
            guard !Task.isCancelled, app.client === client else { return }
            albums = fresh

        }
        catch { if !isCancelledRequest(error), app.client === client { failure = error.localizedDescription } }
    }
    private var albumColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)]
    }
}

struct AlbumCard: View {
    let album: RemoteAlbum
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color(.secondarySystemBackground)
                if album.cover != nil {
                    ThumbnailView(source: album.cover, shared: false, size: .m)
                } else {
                    Image(systemName: "rectangle.stack").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(album.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
            HStack(spacing: 6) {
                if let count = album.item_count { Text(count.formatted()) }
                if album.shared == true { Image(systemName: "link").accessibilityLabel("Shared album") }
            }.font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
                        Button("Share album", systemImage: "person.badge.plus") { sharing = true }
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
    @State private var users: [AlbumShareMember] = []
    @State private var memberFailure: String?
    @State private var inviting = false
    @State private var selectedUser: Int?
    @State private var memberRole = AlbumShareRole.view
    @State private var role = "view"
    @State private var password = ""
    @State private var expires = false
    @State private var expiration = Date().addingTimeInterval(7 * 86400)
    @State private var confirming = false
    @State private var stopping = false
    @State private var busy = false
    @State private var sharingRevision = 0
    @State private var failure: String?
    private var publicEnabled: Bool { state?.shared == true && state?.additional?.sharing_info?.privacy_type?.hasPrefix("public-") == true }
    private var permissions: [AlbumSharePermission] {
        guard state?.shared == true else { return [] }
        return state?.additional?.sharing_info?.permission?.filter { $0.member.type == "user" && $0.role != "owner" } ?? []
    }
    private var availableUsers: [AlbumShareMember] {
        users.filter { user in !permissions.contains { $0.member.id == user.id } && user.name != app.username }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(permissions.indices, id: \.self) { index in
                        let permission = permissions[index]
                        let user = users.first { $0.id == permission.member.id }
                        HStack {
                            Label(user?.name ?? permission.member.name ?? "User", systemImage: "person.crop.circle")
                            Spacer()
                            if let user {
                                Menu {
                                    ForEach(AlbumShareRole.allCases) { access in
                                        Button(access.title) { Task { await updateMember(user, role: access) } }
                                    }
                                    Button("Remove access", role: .destructive) { Task { await updateMember(user, role: nil) } }
                                } label: {
                                    Text(AlbumShareRole(rawValue: permission.role)?.title ?? permission.role).font(.subheadline)
                                }
                                .accessibilityLabel("Access for \(user.name)")
                            } else { Text(permission.role).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    Button { selectedUser = availableUsers.first?.id; inviting = true } label: {
                        Label("Add people", systemImage: "person.badge.plus")
                    }.disabled(state == nil || availableUsers.isEmpty)
                    if let memberFailure {
                        Text(memberFailure).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry loading users") { Task { await load() } }
                    } else if state != nil && availableUsers.isEmpty && permissions.isEmpty {
                        Text("No other NAS users available.").foregroundStyle(.secondary)
                    }
                } header: { Text("People with access") } footer: {
                    Text("Invited users can find this album in Shared with me.")
                }
                Section {
                    if let link = state?.additional?.sharing_info?.sharing_link,
                       let url = URL(string: link), ["https", "http"].contains(url.scheme ?? ""), publicEnabled {
                        ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.url = url } label: { Label("Copy link", systemImage: "doc.on.doc") }
                    } else if state != nil {
                        Text("Link sharing is off").foregroundStyle(.secondary)
                    } else if failure == nil { ProgressView() }
                    Picker("Access", selection: $role) { Text("View").tag("view"); Text("View and download").tag("download") }
                    SecureField("Password (optional)", text: $password)
                    Toggle("Expires", isOn: $expires)
                    if expires { DatePicker("Expires on", selection: $expiration, in: Date()..., displayedComponents: [.date]) }
                    Button(publicEnabled ? "Update link" : "Create link") { confirming = true }.disabled(state == nil)
                    if publicEnabled { Button("Turn off link", role: .destructive) { stopping = true } }
                } header: { Text("Share a link") } footer: {
                    Text("Anyone with the link can access the album. A blank password removes existing password protection.")
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .navigationTitle("Share album").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await load() }
            .refreshWhileActive(key: app.account + "|album-sharing|" + String(album.id)) {
                await refreshSharingState()
            }
            .refreshable { await refreshSharingState() }
            .confirmationDialog("Anyone with the link can access this album.", isPresented: $confirming, titleVisibility: .visible) {
                Button(publicEnabled ? "Update link" : "Create link") { Task { await update(enabled: true) } }
            }
            .confirmationDialog("Turn off this link? Invited users keep access.", isPresented: $stopping, titleVisibility: .visible) {
                Button("Turn off link", role: .destructive) { Task { await update(enabled: false) } }
            }
            .sheet(isPresented: $inviting) {
                NavigationStack {
                    Form {
                        Section {
                            Picker("User", selection: $selectedUser) {
                                ForEach(availableUsers) { user in Text(user.name).tag(Optional(user.id)) }
                            }
                            Picker("Access", selection: $memberRole) {
                                ForEach(AlbumShareRole.allCases) { access in Text(access.title).tag(access) }
                            }
                        } footer: { Text("Contributors can add photos to this album.") }
                        if let failure { Text(failure).foregroundStyle(.red) }
                    }
                    .disabled(busy)
                    .navigationTitle("Add people").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { inviting = false }.disabled(busy) }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Share") {
                                guard let user = availableUsers.first(where: { $0.id == selectedUser }) else { return }
                                Task { await updateMember(user, role: memberRole) }
                            }.disabled(busy || selectedUser == nil)
                        }
                    }
                }.presentationDetents([.medium, .large])
            }
        }
    }
    private func load() async {
        guard let client = app.client else { return }
        sharingRevision += 1
        busy = true; failure = nil; memberFailure = nil
        defer { busy = false }
        do {
            state = try await client.albumSharing(id: album.id)
            role = state?.additional?.sharing_info?.privacy_type == "public-download" ? "download" : "view"
            let expiry = state?.additional?.sharing_info?.expiration ?? 0
            expires = expiry > 0
            if expires { expiration = Date(timeIntervalSince1970: expiry) }
        } catch { failure = error.localizedDescription }
        do { users = try await client.albumSharingMembers() }
        catch { memberFailure = "Couldn’t load NAS users. " + error.localizedDescription }
    }
    private func refreshSharingState() async {
        guard let client = app.client, !busy else { return }
        let revision = sharingRevision
        do {
            let fresh = try await client.albumSharing(id: album.id)
            guard !Task.isCancelled, app.client === client, !busy, revision == sharingRevision else { return }
            state = fresh
            // Leave unsaved password, expiry and access choices intact.
            failure = nil
        } catch {
            if !isCancelledRequest(error), app.client === client { failure = error.localizedDescription }
        }
    }
    private func updateMember(_ user: AlbumShareMember, role: AlbumShareRole?) async {
        guard let client = app.client else { return }
        sharingRevision += 1
        busy = true; failure = nil
        defer { busy = false }
        do {
            state = try await client.updateAlbumMember(id: album.id, member: user, role: role)
            inviting = false
            NotificationCenter.default.post(name: .foteraAlbumsChanged, object: nil)
        } catch {
            failure = "Couldn’t confirm access. " + error.localizedDescription
            state = try? await client.albumSharing(id: album.id)
        }
    }
    private func update(enabled: Bool) async {
        guard let client = app.client else { return }
        sharingRevision += 1
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

private struct LibrarySearch: ViewModifier {
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
    func body(content: Content) -> some View {
        Group {
            if submitted.isEmpty { content }
            else { CollectionScreen(title: submitted, source: .search(submitted)).id(submitted) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "People, places, things, files")
        .searchSuggestions { suggestions }
        .onSubmit(of: .search) { submit(query) }
        .onChange(of: query) { if query.isEmpty { submitted = "" } }
        .navigationDestination(item: $openedGroup) { opened in groupScreen(opened.group, kind: opened.kind) }
        .task(id: app.account + "|" + String(app.shared)) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .foteraPeopleChanged)) { _ in Task { await load(force: true) } }
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
            ForEach(matching.map { OpenedGroup(group: $0.0, kind: $0.1) }) { suggestion in
                let group = suggestion.group, kind = suggestion.kind
                let icon = kind == "person" ? "person.crop.circle" : (kind == "place" ? "mappin.circle" : "tag.circle")
                Button { openedGroup = OpenedGroup(group: group, kind: kind) } label: {
                    HStack(spacing: 12) {
                        ThumbnailView(source: group.cover(kind: kind == "person" ? "person" : "unit"), shared: app.shared, size: .sm, fallbackGroup: kind == "person" ? nil : GroupPreviewSource(group: group, kind: kind))
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
    private func load(force: Bool = false) async {
        guard let client = app.client else { return }
        let account = app.account, space = app.shared
        let groups = await DiscoveryCatalog.load(client: client, account: account, shared: space, force: force)
        guard !Task.isCancelled, app.account == account, app.shared == space else { return }
        people = groups.people; places = groups.places; things = groups.things; loaded = true
    }

}
/// Browsing belongs in Library; Search reuses the same metadata for typed suggestions.
private struct LibraryDiscoveryView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var library: LibraryStore
    let refresh: Int
    @State private var people: [RemoteGroup] = []
    @State private var places: [RemoteGroup] = []
    @State private var things: [RemoteGroup] = []
    @State private var loaded = false
    var body: some View {
        Group {
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

                    }

                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .padding(.horizontal, Theme.gutter)
                if !loaded {
                    HStack(spacing: Theme.large) {
                        ForEach(0..<4, id: \.self) { _ in Circle().fill(Color(.secondarySystemFill)).frame(width: 80, height: 80) }
                    }.padding(.horizontal, Theme.gutter)
                } else if people.isEmpty && places.isEmpty && things.isEmpty {
                    Text("People, places and things appear here once Synology Photos indexes them.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Theme.gutter)
                }
            }.padding(.vertical, 8)
        }
        .task(id: app.account + "|" + String(app.shared) + "|" + String(refresh)) { await load(force: refresh > 0) }
        .onReceive(NotificationCenter.default.publisher(for: .foteraPeopleChanged)) { _ in Task { await load(force: true) } }
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
    private func load(force: Bool = false) async {
        #if DEBUG
        if StoreScreenshots.enabled {
            places = StoreScreenshots.groups("places")
            things = StoreScreenshots.groups("things")
            loaded = true
            return
        }
        #endif
        guard let client = app.client else { return }
        let account = app.account, space = app.shared
        let groups = await DiscoveryCatalog.load(client: client, account: account, shared: space, force: force)
        guard !Task.isCancelled, app.account == account, app.shared == space else { return }
        people = groups.people; places = groups.places; things = groups.things; loaded = true
    }
}

@MainActor private enum DiscoveryCatalog {
    struct Groups {
        let date: Date
        let people: [RemoteGroup]
        let places: [RemoteGroup]
        let things: [RemoteGroup]
    }
    private static var cache: [String: Groups] = [:]
    static func load(client: DSMClient, account: String, shared: Bool, force: Bool) async -> Groups {
        let key = account + "|" + String(shared)
        if !force, let cached = cache[key], Date().timeIntervalSince(cached.date) < 300 { return cached }
        async let people = try? client.people(shared: shared)
        async let places = try? client.places(shared: shared)
        async let things = try? client.concepts(shared: shared)
        let (freshPeople, freshPlaces, freshThings) = await (people, places, things)
        let complete = freshPeople != nil && freshPlaces != nil && freshThings != nil
        let previous = cache[key]
        let result = Groups(date: complete ? Date() : .distantPast,
            people: (freshPeople ?? previous?.people ?? []).filter { ($0.item_count ?? 0) > 0 },
            places: (freshPlaces ?? previous?.places ?? []).sorted { ($0.item_count ?? 0) > ($1.item_count ?? 0) },
            things: (freshThings ?? previous?.things ?? []).sorted { ($0.item_count ?? 0) > ($1.item_count ?? 0) })
        // A failed request must not hide a section for the five-minute cache lifetime.
        if !Task.isCancelled { cache[key] = result }
        return result
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
        ThumbnailView(source: group.cover(kind: kind == "person" ? "person" : "unit"), shared: app.shared, size: .m, fallbackGroup: kind == "person" ? nil : GroupPreviewSource(group: group, kind: kind))
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
    @State private var merging = false
    var body: some View {
        CollectionScreen(title: displayName(person, kind: "person"), source: .filter(.person(person.id)))
            .id(person.id)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 12) {
                    Button(person.name.isEmpty ? "Name person" : "Edit name", systemImage: "pencil") { editing = true }
                    Spacer(minLength: 4)
                    Button("Merge with…", systemImage: "person.2") { merging = true }
                        .accessibilityIdentifier("person.merge")
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink("Manage person") { PeopleManagementView(person: person, shared: shared) }
                        NavigationLink("Use in widget") { CollectionWidgetSetup(source: .person(person.id), title: displayName(person, kind: "person"), shared: shared) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Person options")
                }
            }
            .sheet(isPresented: $merging) {
                PersonMergePicker(source: person, shared: shared) { person = $0 }
            }
            .sheet(isPresented: $editing) {
                PersonNameEditor(person: person, shared: shared) { person = $0 }
            }
    }
}
/// The selected destination keeps its identity and name; the source group disappears.
struct PersonMergePicker: View {
    let source: RemoteGroup
    let shared: Bool
    let merged: (RemoteGroup) -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var people: [RemoteGroup] = []
    @State private var query = ""
    @State private var target: RemoteGroup?
    @State private var confirming = false
    @State private var loading = false
    @State private var saving = false
    @State private var failure: String?
    private var candidates: [RemoteGroup] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return people.filter { $0.id != source.id && (text.isEmpty || displayName($0, kind: "person").localizedCaseInsensitiveContains(text)) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    personRow(source)
                } header: { Text("Merge this person") }
                Section {
                    ForEach(candidates) { person in
                        Button { target = person; confirming = true } label: { personRow(person) }
                            .buttonStyle(.plain)
                    }
                    if !loading && candidates.isEmpty && failure == nil {
                        Text(query.isEmpty ? "No other people available." : "No matching people.").foregroundStyle(.secondary)
                    }
                } header: { Text("Choose the person to keep") }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red)
                        Button("Reload people") { Task { await load() } }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a person")
            .navigationTitle("Merge people").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
            .disabled(saving)
            .overlay { if loading || saving { ProgressView(saving ? "Merging…" : "Loading people…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .interactiveDismissDisabled(saving)
            .task { await load() }
            .confirmationDialog("Merge with \(target.map { displayName($0, kind: "person") } ?? "this person")?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Merge people", role: .destructive) { Task { await merge() } }
            } message: {
                Text("Both groups will use this person’s name. This can’t be undone automatically.")
            }
        }
    }
    private func personRow(_ person: RemoteGroup) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(source: person.cover(kind: "person"), shared: shared, size: .sm)
                .frame(width: 52, height: 52).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(person, kind: "person")).foregroundStyle(.primary)
                if let count = person.item_count { Text("\(count.formatted()) photos").font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func load() async {
        guard let client = app.client, !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let fresh = try await client.allPeople(shared: shared)
            guard !Task.isCancelled, app.client === client else { return }
            people = fresh.sorted { displayName($0, kind: "person").localizedStandardCompare(displayName($1, kind: "person")) == .orderedAscending }
        } catch { if !isCancelledRequest(error) { failure = error.localizedDescription } }
    }
    private func merge() async {
        guard let client = app.client, let target, target.id != source.id, !saving else { return }
        saving = true; failure = nil
        defer { saving = false }
        do {
            try await client.mergePeople(target: target, sources: [source.id], shared: shared)
            guard app.client === client else { dismiss(); return }
            merged(target)
            NotificationCenter.default.post(name: .foteraPeopleChanged, object: nil)
            Haptics.success(); dismiss()
        } catch {
            failure = "Couldn’t confirm the merge. Reload people before trying again. " + error.localizedDescription
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
    @State private var recovered = false
    @FocusState private var focused: Bool
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); ThumbnailView(source: person.cover(kind: "person"), shared: shared, size: .m).frame(width: 100, height: 100).clipShape(Circle()); Spacer() }
                    TextField("Name", text: $name).textContentType(.name).textInputAutocapitalization(.words).focused($focused)
                } footer: { Text("This name is saved in Synology Photos and applies to this person’s group of photos.") }
                if recovered { Section { Text("A previous entry was recovered on this device. Save to confirm it on the NAS.").font(.footnote) } }
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
            .task {
                guard let client = app.client, let prior = await client.savedPersonName(id:person.id,shared:shared),
                      !prior.name.isEmpty, (!prior.confirmed || person.name.isEmpty), prior.name != person.name else { return }
                // Never silently reinstate a name removed through the NAS website.
                name = prior.name; recovered = true
            }
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

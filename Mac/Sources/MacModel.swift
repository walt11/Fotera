import SwiftUI
import AppKit
import AVKit
import Combine
import WidgetKit
import Network

enum MacSection: String, CaseIterable, Identifiable {
    case library = "Timeline", folders = "Folders", albums = "Albums", smart = "Smart Albums", people = "People", favorites = "Favorites", memories = "Memories", map = "Map", places = "Places", things = "Things", received = "Shared with Me", recycle = "Recently Deleted", offline = "Offline", backups = "Backups"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .smart: return "sparkles.rectangle.stack"; case .map: return "map"; case .folders: return "folder"; case .received: return "person.2.crop.square.stack"; case .recycle: return "trash"; case .offline: return "arrow.down.circle"; case .library: return "photo.on.rectangle"; case .favorites: return "heart"; case .memories: return "sparkles"; case .albums: return "rectangle.stack"; case .people: return "person.2"; case .places: return "map"; case .things: return "tag"; case .backups: return "externaldrive.badge.icloud" }
    }
}
struct MacPhotoSection: Identifiable {
    let id: String; let photos: [RemotePhoto]
    static func group(_ photos: [RemotePhoto]) -> [Self] {
        let groups = Dictionary(grouping: photos) { $0.date.map(PhotoTime.monthTitle) ?? "Undated" }
        return groups.map { Self(id:$0.key,photos:$0.value.sorted { ($0.time ?? 0) > ($1.time ?? 0) }) }
            .sorted { ($0.photos.first?.time ?? 0) > ($1.photos.first?.time ?? 0) }
    }
}
@MainActor final class MacModel: ObservableObject {
    @Published var section: MacSection = .library
    @Published var photos: [RemotePhoto] = []
    @Published var albums: [RemoteAlbum] = []
    @Published var groups: [RemoteGroup] = []
    @Published var collection: [RemotePhoto]? {didSet {if collection == nil {collectionSpace = nil; collectionFilter = nil}}}
    var collectionSpace: Bool?
    var collectionFilter: ItemFilter?
    var activeSpace: Bool {collectionSpace ?? shared}
    @Published var folderRefresh = UUID()
    @Published var collectionTitle = ""
    @Published var selection = Set<Int>()
    @Published var viewer: RemotePhoto?
    @Published var query = ""
    @Published var media: LibraryMediaFilter = .all
    @Published var locationFilter: MacLocationFilter = .all
    @Published var focusPhotoID: Int?
    @Published var highlightedPhotoID: Int?
    @Published var shared = false
    @Published var loading = false
    @Published var restoring = true
    @Published var client: DSMClient?
    @Published var error: String?
    @Published var notice: String?
    @Published var activeConnection = ""
    @Published var username = ""
    @Published var favorites = Set<Int>()
    @Published var creatingAlbum = false
    @Published var albumAudit:String?
    @Published var showImporter = false
    @Published var targetFolder = "/"
    @Published var tileSize: Double = 150
    let sharing = MacSharing()
    let backups = MacBackupQueue()
    let localPhotos = MacLocalPhotos()
    private var localObserver: AnyCancellable?
    lazy var photosBackup = MacPhotosBackup(model:self)
    private var generation = UUID()
    private var pendingLogin: DSMClient?
    private var pendingAddress = ""
    private var refreshTask: Task<Void,Never>?
    private var pathMonitor:NWPathMonitor?
    private var pathTask:Task<Void,Never>?
    private var routeTask: Task<Void,Never>?
    private var noticeTask: Task<Void,Never>?
    private var routeObserver: NSObjectProtocol?
    var account: String { (client?.address ?? "") + "|" + username }
    var visiblePhotos: [RemotePhoto] {
        var base = collection ?? (shared ? photos : UnifiedLibrary.merge(remote:photos,local:localPhotos.photos,links:backups.links))
        if collection == nil {
            if section == .favorites { base = base.filter { favorites.contains($0.id) } }
            if section == .memories { base = Self.memories(base) }
        }
        return LocalLibrarySearch.results(base,query:query,media:media,year:nil).filter{locationFilter.includes($0)}
    }
    static func memories(_ photos: [RemotePhoto], now: Date = Date(), timeZone: TimeZone = .current) -> [RemotePhoto] {
        var local = Calendar(identifier:.gregorian); local.timeZone = timeZone
        let today = local.dateComponents([.year,.month,.day],from:now)
        return photos.filter { photo in
            guard let date = photo.date else { return false }
            let parts = PhotoTime.calendar.dateComponents([.year,.month,.day],from:date)
            return parts.month == today.month && parts.day == today.day && (parts.year ?? 0) < (today.year ?? 0)
        }
    }
    init() {
        localObserver = localPhotos.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send(); Task { @MainActor [weak self] in await self?.photosBackup.scanIfEnabled() } }
        routeObserver = NotificationCenter.default.addObserver(forName:.foteraRouteChanged,object:nil,queue:.main) { [weak self] note in
            let source = note.object as? DSMClient; let url = note.userInfo?["url"] as? String
            Task { @MainActor in guard let self, self.client === source, let url else { return }; self.activeConnection = url }
        }
        backups.didFinish = { [weak self] in self?.refresh() }
    }
    func restore() async {
        defer { restoring = false }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if ProcessInfo.processInfo.arguments.contains("--demo") { loadDemo(); return }
        guard let saved = try? SessionStore.load() else { return }
        do {
            let connection = try await DSMClient.open(address:saved.address,cachedEndpoint:saved.resolvedAddress,preferCached:true)
            username = saved.username
            do {try await connection.restore(saved,credentials:CredentialStore.load())}
            catch {if let failure = error as? ConnectionError, failure.isSessionExpired {throw error}; toast("Offline — showing saved photos")}
            await activate(connection)
        } catch { self.error = error.localizedDescription }
    }
    func signIn(address: String, username: String, password: String, otp: String, remember: Bool) async {
        loading = true; defer { loading = false }
        do {
            let clean = address.trimmingCharacters(in:.whitespacesAndNewlines)
            if pendingAddress != clean || pendingLogin == nil { pendingLogin = try await DSMClient.open(address:clean); pendingAddress = clean }
            guard let connection = pendingLogin else { return }
            try await connection.signIn(username:username,password:password,otp:otp,remember:remember)
            self.username = username; await activate(connection); pendingLogin = nil
        } catch { self.error = error.localizedDescription }
    }
    private func activate(_ connection: DSMClient) async {
        client = connection; generation = UUID(); activeConnection = await connection.base.absoluteString
        backups.attach(account:account,client:connection)
        await localPhotos.reload()
        photosBackup.attach()
        let key = account + "|\(shared)"
        if let saved = await LibraryCache.shared.read(account:key) { photos = saved.photos }
        refresh()
        routeTask?.cancel()
        pathMonitor?.cancel(); pathTask?.cancel()
        let monitor = NWPathMonitor(); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let lan = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                guard let self, self.client === connection else {return}
                self.pathTask?.cancel()
                self.pathTask = Task {
                    guard available else {return}
                    await connection.refreshConnectionRoute(allowLAN:lan)
                    guard !Task.isCancelled, self.client === connection else {return}
                    self.backups.retryNetworkFailures()
                }
            }
        }
        monitor.start(queue:DispatchQueue(label:"net.jwalter.Fotera.Mac.network"))
        routeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(60)); guard !Task.isCancelled, self?.client === connection else { return }
                await connection.checkRouteIfStale()
            }
        }
    }
    func signOut() async {
        generation = UUID(); refreshTask?.cancel(); routeTask?.cancel(); pathMonitor?.cancel(); pathMonitor = nil; pathTask?.cancel()
        photosBackup.stop(); sharing.cancelPreparation()
        let previous = client; client = nil
        await backups.detach()
        await previous?.disconnect(); photos = []; albums = []; groups = []; collection = nil; viewer = nil; selection = []; favorites = []
        try? WidgetSnapshotStore.clear()
        WidgetKit.WidgetCenter.shared.reloadAllTimelines()
        try? SessionStore.clear(); try? CredentialStore.clear()
        MacImages.shared.clear()
    }
    func refresh(force: Bool = false) {
        guard let connection = client else { return }
        refreshTask?.cancel(); let token = UUID(); generation = token
        let space = shared, key = account + "|\(shared)"
        loading = true
        refreshTask = Task {
            defer { if generation == token { loading = false } }
            do {
                var result: [RemotePhoto]?
                let stampKey = "mac.fullIndex." + LibraryCache.hash(key)
                let lastFull = UserDefaults.standard.object(forKey:stampKey) as? Date
                if !force, !photos.isEmpty, let lastFull, Date().timeIntervalSince(lastFull) < 6*3600 {
                    async let total = connection.count(shared:space)
                    async let page = connection.items(.all,shared:space,offset:0,limit:100,withLocation:true)
                    let (count,newest) = try await (total,page)
                    if let merged = RecentPhotoIndex.merge(known:photos,page:newest,total:count), try await connection.count(shared:space) == count { result = merged }
                }
                var offset = 0
                if result == nil {
                    var all: [RemotePhoto] = []; var seen = Set<Int>()
                    while true {
                        let page = try await connection.items(.all,shared:space,offset:offset,withLocation:true)
                        try Task.checkCancellation()
                        all += page.filter { seen.insert($0.id).inserted }; offset += page.count
                        if page.count < DSMClient.pageSize { break }
                    }
                    result = all; UserDefaults.standard.set(Date(),forKey:stampKey)
                }
                let all = result ?? []
                guard generation == token else { return }
                photos = all; backups.catalog = all; backups.catalogShared = space
                try await LibraryCache.shared.write(account:key,snapshot:.init(photos:all,updated:Date()))
                var marked = Set<Int>(); offset = 0
                while true {
                    let page = try await connection.items(.favorites,shared:space,offset:offset)
                    marked.formUnion(page.map(\.id)); offset += page.count
                    if page.count < DSMClient.pageSize { break }
                }
                guard generation == token else { return }; favorites = marked
                if !space { let result = try await connection.allAlbums(); guard generation == token else { return }; albums = result }
                await loadSection()
                await MacWidgetWriter.refresh(model:self)
            } catch { if generation == token, !isCancelledRequest(error) { self.error = error.localizedDescription } }
        }
    }
    func navigate(_ section: MacSection) {
        generation = UUID(); refreshTask?.cancel(); loading = false
        self.section = section; collection = nil; selection = []; query = ""; groups = []
        Task { await loadSection() }
    }
    func loadSection() async {
        guard let client else { return }
        let expected = section; let space = shared; var loaded: [RemoteGroup] = []; var offset = 0
        do {
            switch expected {
            case .people, .places, .things:
                while true {
                    let page: [RemoteGroup]
                    if expected == .people { page = try await client.people(shared:space,offset:offset) }
                    else if expected == .places { page = try await client.places(shared:space,offset:offset,limit:200) }
                    else { page = try await client.concepts(shared:space,offset:offset,limit:200) }
                    loaded += page; offset += page.count
                    if page.count < 200 { break }
                }
                guard section == expected, shared == space, self.client === client else { return }; groups = loaded
            case .albums: if !space { let result = try await client.allAlbums(); guard self.client === client, shared == space else { return }; albums = result }
            default: break
            }
        } catch { self.error = error.localizedDescription }
    }
    func openCollection(_ filter: ItemFilter, title: String) {
        guard let client else { return }
        let token = UUID(); generation = token; let space = shared
        collectionTitle = title; collection = []; collectionFilter = filter; selection = []; loading = true
        refreshTask?.cancel()
        refreshTask = Task {
            defer { if generation == token { loading = false } }
            do {
                var result: [RemotePhoto] = []; var offset = 0
                while true { let page = try await client.items(filter,shared:space,offset:offset); result += page; offset += page.count; if page.count < DSMClient.pageSize { break } }
                guard generation == token, !Task.isCancelled else { return }; collection = result
            } catch { if generation == token, !isCancelledRequest(error) { self.error = error.localizedDescription } }
        }
    }
    func openThing(_ group: RemoteGroup) {
        guard let client else { return }
        refreshTask?.cancel(); let token = UUID(); generation = token; let space = shared
        collectionTitle = group.name; collection = []; selection = []; loading = true
        refreshTask = Task {
            defer { if generation == token { loading = false } }
            do {
                var result: [RemotePhoto] = []; var offset = 0
                while true {
                    let page = try await client.search(keyword:group.name,shared:space,offset:offset,limit:500)
                    try Task.checkCancellation(); result += page; offset += page.count
                    if page.count < 500 { break }
                }
                guard generation == token else { return }; collection = result
            } catch { if generation == token, !isCancelledRequest(error) { self.error = error.localizedDescription } }
        }
    }
    func toast(_ text: String) {
        noticeTask?.cancel(); notice = text
        noticeTask = Task { try? await Task.sleep(for:.seconds(4)); if !Task.isCancelled { notice = nil } }
    }
    func favorite(_ items: [RemotePhoto], value: Bool) {
        guard let client else { return }; let space = shared
        let ids = items.filter{ !$0.isLocalOnly && $0.passphrase == nil }.map(\.id); guard !ids.isEmpty else { return }
        Task { do { try await client.setFavorite(ids:ids,shared:space,value:value); for item in items { if value { favorites.insert(item.id) } else { favorites.remove(item.id) } } } catch { self.error = error.localizedDescription } }
    }
    func download(_ item: RemotePhoto) {
        guard let client else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.filename
        guard panel.runModal() == .OK, let target = panel.url else { return }; let space = activeSpace
        Task {
            do {
                let file = try await MacExport.original(item,client:client,shared:space)
                defer { try? FileManager.default.removeItem(at:file) }
                let access = target.startAccessingSecurityScopedResource(); defer { if access { target.stopAccessingSecurityScopedResource() } }
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".fotera-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:temporary) }
                try FileManager.default.copyItem(at:file,to:temporary)
                if FileManager.default.fileExists(atPath:target.path) { _ = try FileManager.default.replaceItemAt(target,withItemAt:temporary) }
                else { try FileManager.default.moveItem(at:temporary,to:target) }
                toast("Saved to \(target.lastPathComponent)")
            } catch { self.error = error.localizedDescription }
        }
    }
    func remove(_ items: [RemotePhoto]) {
        guard let client else { return }; let ids = Set(items.filter{ !$0.isLocalOnly && $0.passphrase == nil }.map(\.id)), space = shared
        guard !ids.isEmpty else { return }
        Task { do { try await client.deletePhotos(ids:Array(ids),shared:space); photos.removeAll { ids.contains($0.id) }; collection?.removeAll { ids.contains($0.id) }; selection.subtract(ids); viewer = nil; toast("Moved to NAS recycle bin") } catch { self.error = error.localizedDescription } }
    }
    func showInTimeline(_ photo:RemotePhoto) {
        section = .library; collection = nil; query = ""; media = .all; locationFilter = .all
        focusPhotoID = photo.id; highlightedPhotoID = photo.id; viewer = nil
        Task {try? await Task.sleep(for:.seconds(3)); if highlightedPhotoID == photo.id {highlightedPhotoID = nil}}
    }
    func useCollectionWidget(_ filter:ItemFilter,title:String,kind:String) {
        guard let client else {return}
        guard MacWidgetWriter.photosEnabled else {error = "Enable photo widgets in Settings first."; return}
        let key = account, space = shared
        let id:Int
        switch filter {case .album(let value), .person(let value): id = value; default: return}
        let choice = MacWidgetChoice(id:id,title:title,kind:kind,shared:space)
        do {try choice.save(account:key)} catch {self.error = error.localizedDescription; return}
        Task {do {
            let photos = try await client.items(filter,shared:space,offset:0,limit:6)
            guard account == key else {return}
            try await MacWidgetWriter.collection(photos,title:title,kind:kind,model:self,space:space,expected:choice)
            toast("Widget updated")
        } catch {if !isCancelledRequest(error) {self.error = error.localizedDescription}}}
    }
    func loadDemo() {
        username = "Demo library"; activeConnection = "Local sample images"; restoring = false
        guard let path = Bundle.main.url(forResource:"DemoAssets",withExtension:nil), let data = try? Data(contentsOf:path.appendingPathComponent("photos.json")), let demo = try? JSONDecoder().decode([RemotePhoto].self,from:data) else { return }
        photos = demo
        albums = [.init(id:1,name:"Weekend escapes",item_count:demo.count,additional:nil)]
    }
}

@MainActor final class MacImages {
    static let shared = MacImages()
    private let memory = NSCache<NSString,NSImage>()
    private var tasks: [String:Task<NSImage?,Never>] = [:]
    init() { memory.totalCostLimit = 80_000_000; memory.countLimit = 500 }
    func clear() { tasks.values.forEach { $0.cancel() }; tasks = [:]; memory.removeAllObjects() }
    func image(_ photo: RemotePhoto, model: MacModel, space override:Bool? = nil) async -> NSImage? {
        if ProcessInfo.processInfo.arguments.contains("--demo"), let root = Bundle.main.url(forResource:"DemoAssets",withExtension:nil), let data = try? Data(contentsOf:root.appendingPathComponent("\(abs(photo.id)).png")) { return MacFiles.decode(data,edge:500) }
        if photo.localAssetID != nil, let local = await MacLocalPhotos.image(photo,edge:500) { return local }
        guard let client = model.client else { return nil }
        let source = photo.thumbnailSource
        let space = override ?? model.activeSpace, key = model.account + "|\(space)|\(photo.id)|\(source?.cacheKey ?? "original")"
        if let image = memory.object(forKey:key as NSString) { return image }
        if let pending = tasks[key] { return await pending.value }
        let pending = Task<NSImage?,Never> {
            if let data = await LibraryCache.shared.preview(key:key), let image = MacFiles.decode(data,edge:500) { return image }
            if let source, let data = try? await client.thumbnail(source,shared:space,size:.m), let image = MacFiles.decode(data,edge:500) { await LibraryCache.shared.savePreview(key:key,data:data); return image }
            guard !Task.isCancelled, !photo.isVideo, let size = photo.filesize, size < 50_000_000,
                  let file = try? await client.original(photo,shared:space) else { return nil }
            defer { try? FileManager.default.removeItem(at:file) }
            return await Task.detached(priority:.utility) {
                guard let data = try? Data(contentsOf:file,options:.mappedIfSafe) else { return nil }
                return MacFiles.decode(data,edge:500)
            }.value
        }
        tasks[key] = pending; let image = await pending.value; tasks[key] = nil
        if let image { memory.setObject(image,forKey:key as NSString,cost:Int(image.size.width*image.size.height*4)) }
        return image
    }
}

enum MacLocationFilter:String,CaseIterable,Identifiable {
    case all = "Everywhere", device = "Mac only", cloud = "NAS only", both = "Both"
    var id:String {rawValue}
    func includes(_ photo:RemotePhoto) -> Bool {switch self {case .all:return true; case .device:return photo.isLocalOnly; case .cloud:return !photo.isLocalOnly && photo.localAssetID == nil; case .both:return !photo.isLocalOnly && photo.localAssetID != nil}}
}

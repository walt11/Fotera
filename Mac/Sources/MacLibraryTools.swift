import SwiftUI
import MapKit

struct MacMapView: View {
    @EnvironmentObject var model: MacModel
    @State private var region = MKCoordinateRegion(center:.init(latitude:25,longitude:0),span:.init(latitudeDelta:150,longitudeDelta:350))
    @State private var clusters: [MacMapCluster] = []
    @State private var viewport = MacMapViewport(latitude:25,longitude:0,latitudeSpan:150,longitudeSpan:350)
    var body: some View {
        Map(initialPosition:.region(region)) {
            ForEach(clusters) { cluster in
                Annotation("\(cluster.photos.count) photos",coordinate:cluster.coordinate) {
                    Button { model.collection = cluster.photos; model.collectionTitle = "Photos on map"; model.section = .library } label:{ Text("\(cluster.photos.count)").font(.headline).foregroundStyle(.white).padding(12).background(Color.accentColor,in:Circle()) }.buttonStyle(.plain)
                }
            }
        }
        .onMapCameraChange(frequency:.onEnd) { context in let r = context.region; viewport = .init(latitude:r.center.latitude,longitude:r.center.longitude,latitudeSpan:r.span.latitudeDelta,longitudeSpan:r.span.longitudeDelta) }
        .task(id:viewport) { await rebuild() }
        .onChange(of:model.photos) { _,_ in Task { await rebuild() } }
    }
    private func rebuild() async {
        let photos = model.visiblePhotos, area = viewport
        let task = Task.detached(priority:.utility) { MacMapCluster.make(photos,viewport:area) }
        let result = await withTaskCancellationHandler(operation:{ await task.value },onCancel:{task.cancel()})
        guard !Task.isCancelled, viewport == area else { return }; clusters = result
    }
}
struct MacMapViewport: Hashable, Sendable { let latitude: Double; let longitude: Double; let latitudeSpan: Double; let longitudeSpan: Double }
struct MacMapCluster: Identifiable, Sendable {
    let id: Int; let photos: [RemotePhoto]; let latitude: Double; let longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude:latitude,longitude:longitude) }
    static func make(_ photos: [RemotePhoto], viewport: MacMapViewport) -> [Self] {
        guard viewport.latitudeSpan > 0, viewport.longitudeSpan > 0 else { return [] }
        var bins: [Int:[RemotePhoto]] = [:]
        for (index,photo) in photos.enumerated() {
            if index % 256 == 0 && Task.isCancelled { return [] }
            guard let gps = photo.additional?.gps, gps.latitude.isFinite, gps.longitude.isFinite,
                  abs(gps.latitude) <= 90, abs(gps.longitude) <= 180 else { continue }
            let latitude = gps.latitude - viewport.latitude
            var longitude = (gps.longitude - viewport.longitude).truncatingRemainder(dividingBy:360)
            if longitude > 180 { longitude -= 360 }; if longitude < -180 { longitude += 360 }
            guard abs(latitude) <= viewport.latitudeSpan/2, abs(longitude) <= viewport.longitudeSpan/2 else { continue }
            let row = min(7,max(0,Int((latitude/viewport.latitudeSpan + 0.5)*8)))
            let column = min(7,max(0,Int((longitude/viewport.longitudeSpan + 0.5)*8)))
            bins[row*8+column,default:[]].append(photo)
        }
        return bins.keys.sorted().compactMap { key in guard let items = bins[key], let gps = items.first?.additional?.gps else { return nil }; return Self(id:key,photos:items,latitude:gps.latitude,longitude:gps.longitude) }
    }
}
struct MacRecycleView: View {
    @EnvironmentObject var model: MacModel
    @State private var path = ""
    @State private var files: [RecycleFile] = []
    @State private var busy = false
    @State private var failure: String?
    @State private var restore: RecycleFile?
    private var root: String { model.shared ? "/photo/#recycle" : "/home/#recycle/Photos" }
    var body: some View {
        VStack(alignment:.leading) {
            HStack { if path != root { Button("Back") { path = (path as NSString).deletingLastPathComponent } }; Text(path).font(.caption).textSelection(.enabled); Spacer(); Button("Refresh") { Task { await load() } } }.padding()
            List(files) { file in
                HStack {
                    Image(systemName:file.isdir ? "folder" : "photo")
                    Text(file.name); Spacer()
                    if file.isdir { Button("Open") { path = file.path } }
                    else { Button("Restore…") { restore = file } }
                }.padding(.vertical,4)
            }
            if let failure { Text(failure).foregroundStyle(.red).padding() }
        }.onAppear { path = root }.onChange(of:model.shared) { _,_ in path = root }.task(id:path) { if !path.isEmpty { await load() } }
        .overlay { if busy { ProgressView().padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) } }
        .alert("Restore this file?",isPresented:Binding(get:{restore != nil},set:{if !$0 {restore = nil}})) { Button("Cancel",role:.cancel) {restore = nil}; Button("Restore") { if let file = restore { Task { await restoreFile(file) } }; restore = nil } } message:{Text("It returns to its original NAS folder. Existing files will not be overwritten.")}
    }
    private func load() async { guard let client = model.client else {return}; let requested = path; busy = true; defer {busy = false}; do { let result = try await client.recycleFiles(path:requested); guard path == requested else {return}; files = result; failure = nil } catch {if !isCancelledRequest(error) {failure = error.localizedDescription}} }
    private func restoreFile(_ file: RecycleFile) async { guard let client = model.client else {return}; busy = true; defer {busy = false}; do {try await client.restoreRecycledFile(file); await load(); model.refresh(force:true); model.toast("Restored to NAS") } catch {failure = error.localizedDescription} }
}
struct MacFolderView: View {
    @EnvironmentObject var model: MacModel
    @State private var trail: [RemoteFolder] = []
    @State private var folders: [RemoteFolder] = []
    @State private var failure: String?
    @State private var request = UUID()
    private var demo:Bool {ProcessInfo.processInfo.arguments.contains("--demo")}
    private var loadID:String {"\(model.account)|\(model.shared)|\(trail.last?.id ?? -1)|\(model.folderRefresh)"}
    private var visibleFolders:[RemoteFolder] {
        folders.filter{model.query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(model.query)}
            .sorted{$0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending}
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Button {trail.removeLast(); model.query = ""} label:{Image(systemName:"chevron.left")}
                    .disabled(trail.count < 2).help("Parent folder").accessibilityIdentifier("folder.back")
                ScrollView(.horizontal) {
                    HStack(spacing:8) {
                        ForEach(Array(trail.enumerated()),id:\.element.id) {index,folder in
                            if index > 0 {Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary)}
                            Button(index == 0 ? "Folders" : folder.displayName) {trail = Array(trail.prefix(index + 1)); model.query = ""}
                                .buttonStyle(.plain).fontWeight(index == trail.count - 1 ? .semibold : .regular)
                                .foregroundStyle(index == trail.count - 1 ? .primary : .secondary)
                        }
                    }.fixedSize()
                }.scrollIndicators(.hidden)
                TextField("Search this folder",text:$model.query).textFieldStyle(.roundedBorder).frame(width:210)
                Menu {
                    Button("Use Folder for Backup") {model.targetFolder = trail.last?.name ?? "/"; model.toast("Backup destination selected")}.disabled(trail.isEmpty)
                } label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).frame(width:24).help("Folder options")
            }.padding(.horizontal,20).padding(.vertical,12)
            Divider()
            if let failure {HStack {Text(failure).foregroundStyle(.red); Button("Retry") {model.folderRefresh = UUID()}; Spacer()}.padding()}
            MacTimeline(folderContent:AnyView(folderGrid),folderCount:visibleFolders.count)
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .task(id:loadID) {await load()}
        .onChange(of:model.shared) {_,_ in trail = []}
    }
    private var folderGrid:some View {
        VStack(alignment:.leading,spacing:12) {
            if !visibleFolders.isEmpty {
                HStack {Text("Folders").font(.headline); Text("\(visibleFolders.count)").foregroundStyle(.secondary).font(.subheadline)}
                LazyVGrid(columns:[GridItem(.adaptive(minimum:180,maximum:260),spacing:12)],alignment:.leading,spacing:12) {
                    ForEach(visibleFolders) {folder in
                        Button {trail.append(folder); model.query = ""} label:{
                            HStack(spacing:12) {
                                Image(systemName:"folder.fill").font(.system(size:28)).foregroundStyle(.tint)
                                Text(folder.displayName).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength:0)
                                Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.padding(14).frame(maxWidth:.infinity,minHeight:64,alignment:.leading)
                                .background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:10))
                                .contentShape(RoundedRectangle(cornerRadius:10))
                        }.buttonStyle(.plain).accessibilityIdentifier("folder.\(folder.id)")
                    }
                }
            }
        }
    }
    private func load() async {
        let token = UUID(); request = token
        let account = model.account, space = model.shared
        folders = []; failure = nil; model.media = .all; model.locationFilter = .all; model.collection = []; model.collectionSpace = space; model.selection = []; model.loading = true
        defer {if request == token {model.loading = false}}
        do {
            if trail.isEmpty {
                if demo {trail = [RemoteFolder(id:0,name:"/")]} else if let client = model.client {
                    let root = try await client.folder(path:"/",shared:space)
                    try Task.checkCancellation()
                    guard request == token, model.account == account, model.shared == space else {return}
                    trail = [root]
                }
                return
            }
            guard let folder = trail.last else {return}
            model.collectionTitle = folder.displayName; model.collectionFilter = .folder(folder.id)
            if demo {
                folders = folder.id == 0 ? [RemoteFolder(id:9000,name:"/Sample Photos")] + (1993...2006).map{RemoteFolder(id:$0,name:"/\($0)")} : []
                model.collection = folder.id == 0 ? [] : Array(model.photos.prefix(2)); return
            }
            guard let client = model.client else {return}
            var children:[RemoteFolder] = []; var offset = 0
            while true {
                let page = try await client.folders(shared:space,parent:folder.id,offset:offset)
                try Task.checkCancellation(); children += page; offset += page.count; if page.count < 200 {break}
            }
            guard request == token, model.account == account, model.shared == space else {return}
            folders = children; offset = 0
            while true {
                let page = try await client.items(.folder(folder.id),shared:space,offset:offset)
                try Task.checkCancellation()
                guard request == token, model.account == account, model.shared == space else {return}
                model.collection?.append(contentsOf:page); offset += page.count
                if page.count < DSMClient.pageSize {break}
            }
        } catch {if request == token, !isCancelledRequest(error) {failure = error.localizedDescription}}
    }
}
struct MacSharedAlbumsView: View {
    @EnvironmentObject var model: MacModel
    @State private var albums:[SharedPhotoAlbum] = []
    @State private var failure:String?
    var body: some View {
        List {
            ForEach(albums) { album in Button { open(album) } label:{ HStack {Image(systemName:"person.2.crop.square.stack"); Text(album.name); Spacer(); Text("\(album.item_count ?? 0)").foregroundStyle(.secondary)} }.buttonStyle(.plain).padding(.vertical,8) }
            if let failure {Text(failure).foregroundStyle(.red)}
        }.task {guard let client = model.client else {return}; do {albums = try await client.sharedWithMe()} catch {failure = error.localizedDescription} }
    }
    private func open(_ album:SharedPhotoAlbum) {guard let client = model.client, let token = album.passphrase else {return}; Task {do {let items = try await client.sharedAlbumItems(passphrase:token); model.collectionSpace = false; model.collection = items; model.collectionTitle = album.name} catch {failure = error.localizedDescription}} }
}
struct MacPhotoInfo: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    let photo: RemotePhoto
    @State private var details: ItemDetails?
    @State private var tags: [PhotoTag] = []
    @State private var caption = ""
    @State private var newTag = ""
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        VStack {
            HStack {Text("Photo Info").font(.title2.bold()); Spacer(); Button("Done") {dismiss()}}.padding()
            Form {
                LabeledContent("Filename",value:photo.filename)
                if let date = photo.date {LabeledContent("Taken",value:PhotoTime.format(date,.dateTime.year().month().day().hour().minute()))}
                if let size = details?.filesize ?? photo.filesize {LabeledContent("Size",value:ByteCountFormatter.string(fromByteCount:size,countStyle:.file))}
                if let resolution = details?.additional?.resolution {LabeledContent("Resolution",value:"\(resolution.width) × \(resolution.height)")}
                if let camera = details?.additional?.exif?.camera {LabeledContent("Camera",value:camera)}
                if let lens = details?.additional?.exif?.lens {LabeledContent("Lens",value:lens)}
                if let address = details?.additional?.address?.summary {LabeledContent("Location",value:address)}
                Section("Description") {TextEditor(text:$caption).frame(height:90); Button("Save Description") {run {client in try await client.setPhotoDescription(id:photo.id,shared:model.activeSpace,description:caption)}}.disabled(details == nil || photo.passphrase != nil)}
                Section("Tags") {
                    ForEach(tags) {tag in HStack {Text(tag.name); Spacer(); Button("Remove") {run {client in try await client.removePhotoTag(id:photo.id,shared:model.activeSpace,tag:tag); tags = try await client.photoTags(id:photo.id,shared:model.activeSpace)}}}}
                    HStack {TextField("New tag",text:$newTag); Button("Add") {run {client in try await client.addPhotoTag(id:photo.id,shared:model.activeSpace,name:newTag); tags = try await client.photoTags(id:photo.id,shared:model.activeSpace); newTag = ""}}.disabled(newTag.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                }.disabled(photo.isLocalOnly || photo.passphrase != nil)
                if let failure {Text(failure).foregroundStyle(.red)}
            }.formStyle(.grouped).disabled(busy)
        }.frame(width:530,height:640).task {guard !photo.isLocalOnly, photo.passphrase == nil else {return}; run {client in details = try await client.details(id:photo.id,shared:model.activeSpace); caption = details?.additional?.description ?? ""; tags = try await client.photoTags(id:photo.id,shared:model.activeSpace)}}
    }
    private func run(_ action:@escaping (DSMClient) async throws -> Void) {guard let client = model.client else {return}; busy = true; Task {defer {busy = false}; do {try await action(client); failure = nil} catch {failure = error.localizedDescription}}}
}

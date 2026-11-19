import SwiftUI
import AppKit
import AVKit
import Photos

struct MacThumbnail: View {
    @EnvironmentObject var model: MacModel
    let photo: RemotePhoto
    @State private var image: NSImage?
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image { Image(nsImage:image).resizable().scaledToFill().frame(width:proxy.size.width,height:proxy.size.height).clipped() }
                else { Image(systemName:photo.isVideo ? "video" : "photo").foregroundStyle(.secondary) }
            }
        }.task(id:"\(model.account)|\(model.shared)|\(photo.id)|\(photo.thumbnailSource?.cacheKey ?? "")") { image = await MacImages.shared.image(photo,model:model) }
    }
}
struct MacTimeline: View {
    var folderContent: AnyView? = nil
    var folderCount = 0
    @EnvironmentObject var model: MacModel
    @State private var deleting = false
    var body: some View {
        VStack(spacing:0) {
            if folderContent == nil {
            HStack {
                TextField("Search photos",text:$model.query).textFieldStyle(.roundedBorder).frame(maxWidth:300)
                Picker("Show",selection:$model.media) { ForEach(LibraryMediaFilter.allCases) { Text($0.rawValue).tag($0) } }.frame(width:130)
                Picker("Location",selection:$model.locationFilter) {ForEach(MacLocationFilter.allCases) {Text($0.rawValue).tag($0)}}.labelsHidden().frame(width:125)
                Spacer()
                Text("\(model.visiblePhotos.count) photos").foregroundStyle(.secondary).font(.caption)
                Image(systemName:"square.grid.3x3")
                Slider(value:$model.tileSize,in:100...260).frame(width:100).help("Thumbnail size")
            }.padding(16)
            Divider()
            }
            if model.visiblePhotos.isEmpty && folderCount == 0 {
                ContentUnavailableView(model.loading ? "Loading…" : (folderContent != nil ? (model.query.isEmpty ? "Empty folder" : "No matches") : model.section == .memories ? "No memories for today" : "No photos"),systemImage:model.section.symbol,description:Text(model.query.isEmpty ? (folderContent != nil ? "This folder has no photos or subfolders." : "Your library will appear here.") : "Try a different search."))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:20,pinnedViews:[.sectionHeaders]) {
                        if let folderContent {folderContent}
                        ForEach(MacPhotoSection.group(model.visiblePhotos)) { group in
                            Section {
                                LazyVGrid(columns:[GridItem(.adaptive(minimum:model.tileSize),spacing:4)],spacing:4) {
                                    ForEach(group.photos) { photo in
                                        MacThumbnail(photo:photo).aspectRatio(1,contentMode:.fit)
                                            .id(photo.id)
                                            .accessibilityIdentifier("photo.\(photo.id)")
                                            .accessibilityLabel(photo.filename)
                                            .overlay(alignment:.bottomLeading) { if photo.isVideo || photo.isLive { Label(photo.durationText ?? (photo.isLive ? "LIVE" : ""),systemImage:photo.isLive ? "livephoto" : "play.fill").font(.caption2.bold()).foregroundStyle(.white).shadow(radius:2).padding(8) } }
                                            .overlay { Rectangle().strokeBorder((model.selection.contains(photo.id) || model.highlightedPhotoID == photo.id) ? Color.accentColor : .clear,lineWidth:4) }
                                            .overlay(alignment:.topTrailing) { Image(systemName:photo.isLocalOnly ? "desktopcomputer" : photo.localAssetID != nil ? "checkmark.icloud" : "icloud").font(.caption).foregroundStyle(.white).shadow(radius:2).padding(7) }
                                            .contentShape(Rectangle())
                                            .onTapGesture(count:2) { model.viewer = photo }
                                            .onTapGesture { if NSEvent.modifierFlags.contains(.command) { if model.selection.contains(photo.id) { model.selection.remove(photo.id) } else { model.selection.insert(photo.id) } } else { model.selection = [photo.id] } }
                                            .contextMenu {
                                                Button("Open") { model.viewer = photo }
                                                Button(model.favorites.contains(photo.id) ? "Remove Favorite" : "Favorite") { model.favorite([photo],value:!model.favorites.contains(photo.id)) }.disabled(photo.isLocalOnly || photo.passphrase != nil)
                                                Button("Save Original…") { model.download(photo) }.disabled(photo.passphrase != nil)
                                                Button("Keep Offline") { model.keepOffline(photo) }.disabled(photo.isLocalOnly || photo.passphrase != nil)
                                                Divider()
                                                Button("Delete from NAS…",role:.destructive) { model.selection = [photo.id]; deleting = true }.disabled(photo.isLocalOnly || photo.passphrase != nil)
                                            }
                                    }
                                }
                            } header: { Text(group.id).font(.title3.bold()).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,10).background(.background) }
                        }
                    }.padding(folderContent == nil ? 16 : 20).frame(maxWidth:.infinity,alignment:.topLeading)
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .onAppear { scrollToFocused(proxy) }
                .onChange(of:model.focusPhotoID) { _,_ in scrollToFocused(proxy) }
                }
            }
            if !model.selection.isEmpty {
                Divider()
                HStack {
                    Text("\(model.selection.count) selected")
                    Button("Open") { model.viewer = model.visiblePhotos.first { model.selection.contains($0.id) } }
                    MacShareButton(items:model.visiblePhotos.filter{model.selection.contains($0.id)}).fixedSize()
                    Button("Favorite") { model.favorite(selected,value:true) }.disabled(selected.isEmpty)
                    Menu("Add to Album") {
                        ForEach(model.albums) { album in Button(album.name) {
                            guard let client = model.client else { return }; let ids = selected.map(\.id)
                            Task { do { try await client.changeAlbumItems(id:album.id,items:ids,adding:true); model.toast("Added to album") } catch { model.error = error.localizedDescription } }
                        } }
                        Button("New Album…") { model.creatingAlbum = true }
                    }.disabled(model.shared)
                    if case .album(let id) = model.collectionFilter {
                        Button("Remove from Album") {
                            guard let client = model.client else {return}; let ids = selected.map(\.id)
                            Task {do {try await client.changeAlbumItems(id:id,items:ids,adding:false); model.collection?.removeAll{ids.contains($0.id)}; model.selection = []; model.toast("Removed from album")} catch {model.error = error.localizedDescription}}
                        }.disabled(selected.isEmpty)
                    }
                    Spacer()
                    Button("Delete…",role:.destructive) { deleting = true }.disabled(selected.isEmpty)
                }.padding(12)
            }
        }
        .alert("Delete \(selected.count) photos from NAS?",isPresented:$deleting) { Button("Cancel",role:.cancel){}; Button("Delete",role:.destructive) { model.remove(selected) } } message:{Text("Local originals stay on your Mac.")}
    }
    private func scrollToFocused(_ proxy:ScrollViewProxy) {
        guard let id = model.focusPhotoID, let photo = model.visiblePhotos.first(where:{$0.id == id}) else {return}
        let section = photo.date.map(PhotoTime.monthTitle) ?? "Undated"
        proxy.scrollTo(section,anchor:.top)
        Task {try? await Task.sleep(for:.milliseconds(200)); guard model.focusPhotoID == id else {return}; proxy.scrollTo(id,anchor:.center); model.focusPhotoID = nil}
    }
    private var selected: [RemotePhoto] { model.visiblePhotos.filter { model.selection.contains($0.id) && !$0.isLocalOnly && $0.passphrase == nil } }
}
struct MacCollections: View {
    @EnvironmentObject var model: MacModel
    @State private var editingAlbum: RemoteAlbum?
    @State private var editingPerson: RemoteGroup?
    @State private var showingHidden = false
    var body: some View {
        ScrollView {
            LazyVGrid(columns:[GridItem(.adaptive(minimum:200),spacing:20)],spacing:24) {
                if model.section == .albums {
                    ForEach(model.albums) { album in
                        Button { model.openCollection(.album(album.id),title:album.name) } label:{ card(album.name,count:album.item_count,cover:album.cover) }.buttonStyle(.plain)
                            .contextMenu { Button("Album Settings & Sharing…") { editingAlbum = album }; Button("Keep Album Offline") {model.keepAlbumOffline(album)}; Button("Use in Album Widget") {model.useCollectionWidget(.album(album.id),title:album.name,kind:"album")} }
                    }
                } else {
                    ForEach(model.groups) { group in
                        Button {
                            if model.section == .people { model.openCollection(.person(group.id),title:group.name) }
                            else if model.section == .places { model.openCollection(.place(group.id),title:group.name) }
                            else { model.openThing(group) }
                        } label:{ card(group.name,count:group.item_count,cover:group.cover(kind:model.section == .people ? "person" : "unit")) }.buttonStyle(.plain)
                            .contextMenu { if model.section == .people { Button("Name or Merge…") { editingPerson = group }; Button("Use in Person Widget") {model.useCollectionWidget(.person(group.id),title:group.name,kind:"person")} } }
                    }
                }
            }.padding(24)
            if model.section == .people {Button("Hidden People…") {showingHidden = true}}
            if model.section == .albums { Button("New Album…") { model.creatingAlbum = true }.disabled((model.client == nil && !ProcessInfo.processInfo.arguments.contains("--demo")) || model.shared) }
            if model.section == .albums && model.shared { Text("Albums are available in Personal Space.").foregroundStyle(.secondary) }
        }
        .sheet(isPresented:$showingHidden) {MacHiddenPeople().environmentObject(model)}
        .sheet(item:$editingAlbum) { MacAlbumEditor(album:$0).environmentObject(model) }
        .sheet(item:$editingPerson) { MacPersonEditor(person:$0).environmentObject(model) }
    }
    private func card(_ name: String,count: Int?,cover: ThumbnailSource?) -> some View {
        VStack(alignment:.leading,spacing:8) {
            MacCover(source:cover).aspectRatio(1,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:16))
            Text(name.isEmpty ? "Unnamed" : name).font(.headline).lineLimit(1)
            if let count { Text("\(count) photos").foregroundStyle(.secondary).font(.caption) }
        }
    }
}
struct MacCover: View {
    @EnvironmentObject var model: MacModel
    let source: ThumbnailSource?
    @State private var image: NSImage?
    var body: some View {
        GeometryReader { proxy in ZStack { Rectangle().fill(.quaternary); if let image { Image(nsImage:image).resizable().scaledToFill().frame(width:proxy.size.width,height:proxy.size.height).clipped() } else { Image(systemName:"photo.stack").font(.largeTitle).foregroundStyle(.secondary) } } }
            .task(id:source) { image = nil; guard let source, let client = model.client else { return }; if let data = try? await client.thumbnail(source,shared:model.activeSpace,size:.m) { image = MacFiles.decode(data,edge:500) } }
    }
}
struct MacViewer: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    @State var photo: RemotePhoto
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var file: URL?
    @State private var live: PHLivePhoto?
    @State private var liveDirectory: URL?
    @State private var failure: String?
    @State private var zoom = 1.0
    @State private var showingInfo = false
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Button { dismiss() } label:{Image(systemName:"xmark")}.keyboardShortcut(.escape,modifiers:[])
                VStack(alignment:.leading) { Text(photo.filename).font(.headline); if let date = photo.date { Text(PhotoTime.format(date,.dateTime.year().month().day().hour().minute())).font(.caption).foregroundStyle(.secondary) } }
                Spacer()
                Button { move(-1) } label:{Image(systemName:"chevron.left")}.keyboardShortcut(.leftArrow,modifiers:[])
                Button { move(1) } label:{Image(systemName:"chevron.right")}.keyboardShortcut(.rightArrow,modifiers:[])
                Button { model.favorite([photo],value:!model.favorites.contains(photo.id)) } label:{Image(systemName:model.favorites.contains(photo.id) ? "heart.fill" : "heart")}
                Button { model.download(photo) } label:{Image(systemName:"square.and.arrow.down")}
                MacShareButton(items:[photo]).fixedSize()
                Button {model.showInTimeline(photo); dismiss()} label:{Image(systemName:"square.grid.3x3")}.help("Show in timeline")
                Button { showingInfo = true } label:{Image(systemName:"info.circle")}
                if image != nil { Slider(value:$zoom,in:1...4).frame(width:90) }
            }.padding(16)
            ZStack {
                Color.black
                if let live { MacLiveView(photo:live) }
                else if let player { VideoPlayer(player:player) }
                else if let image { GeometryReader { geometry in ScrollView([.horizontal,.vertical]) { Image(nsImage:image).resizable().scaledToFit().frame(width:geometry.size.width*zoom,height:geometry.size.height*zoom) } } }
                else if let failure { ContentUnavailableView("Unable to open photo",systemImage:"exclamationmark.triangle",description:Text(failure)).foregroundStyle(.white) }
                else { ProgressView().tint(.white) }
            }
        }.frame(minWidth:760,minHeight:540).frame(idealWidth:1000,idealHeight:700)
            .task(id:photo.id) { await load() }
            .onDisappear { cleanup() }
            .sheet(isPresented:$showingInfo) { MacPhotoInfo(photo:photo).environmentObject(model) }
    }
    private func cleanup() { live = nil; if let liveDirectory { try? FileManager.default.removeItem(at:liveDirectory) }; liveDirectory = nil; player?.pause(); player = nil; if let file { try? FileManager.default.removeItem(at:file) }; file = nil }
    private func move(_ delta: Int) { let photos = model.visiblePhotos; if let index = photos.firstIndex(where:{$0.id == photo.id}), photos.indices.contains(index+delta) { photo = photos[index+delta] } }
    private func load() async {
        cleanup(); image = nil; failure = nil; zoom = 1
        if photo.localAssetID != nil && !ProcessInfo.processInfo.arguments.contains("--demo") {
            if photo.isVideo { let value = await MacLocalPhotos.player(photo); if !Task.isCancelled { player = value; if value == nil { failure = "The local video could not be loaded." } }; return }
            if photo.isLive { let value = await MacLocalPhotos.live(photo); if !Task.isCancelled { live = value }; if value != nil { return } }
            let value = await MacLocalPhotos.image(photo,edge:6000); if !Task.isCancelled { image = value }; if value != nil { return }
        }
        guard let client = model.client else { image = await MacImages.shared.image(photo,model:model); return }
        let current = photo
        do {
            if current.isLive {
                let archive = try await client.livePackage(current,shared:model.activeSpace,useOfflineCache:true)
                defer { try? FileManager.default.removeItem(at:archive) }
                let package = try await Task.detached(priority:.userInitiated) { try MacLivePackage.unpack(archive) }.value
                do {
                    let result = try await package.live(); try Task.checkCancellation()
                    liveDirectory = package.directory; live = result
                } catch { try? FileManager.default.removeItem(at:package.directory); throw error }
            } else if current.isVideo {
                if let local = try await OfflineVault.shared.copyOriginal(account:model.account,photo:current,shared:model.activeSpace) {
                    guard !Task.isCancelled else {try? FileManager.default.removeItem(at:local); return}; file = local; player = AVPlayer(url:local)
                } else {let url = try await client.streamingURL(id:current.id,shared:model.activeSpace); try Task.checkCancellation(); player = AVPlayer(url:url)}
            } else {
                let local = try await client.original(current,shared:model.activeSpace,useOfflineCache:true)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at:local); return }
                file = local
                let decoded = await Task.detached(priority:.userInitiated) { (try? Data(contentsOf:local,options:.mappedIfSafe)).flatMap { MacFiles.decode($0,edge:6000) } }.value
                try Task.checkCancellation(); guard let decoded else { throw MediaFailure.unsupportedPhoto }; image = decoded
            }
        } catch { if !isCancelledRequest(error) { failure = error.localizedDescription } }
    }
}
struct MacBackupView: View {
    @EnvironmentObject var model: MacModel
    @ObservedObject var queue: MacBackupQueue
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { VStack(alignment:.leading) { Text("Photo imports").font(.largeTitle.bold()); Text("\(queue.completedPhotos) of \(queue.totalPhotos) photos verified").foregroundStyle(.secondary) }; Spacer(); Button("Choose Photos…") { queue.chooseFiles(folder:model.targetFolder,shared:model.activeSpace) }.buttonStyle(.borderedProminent) }
            MacPhotosBackupSettings(controller:model.photosBackup)
            HStack { TextField("Destination",text:$model.targetFolder); Toggle("Year/month folders",isOn:$queue.yearMonth) }
            Text("Imports continue while Fotera is running. Originals stay on your Mac. Failed uploads remain queued for retry.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(queue.watchedFolder.isEmpty ? "Back Up a Folder…" : "Change Folder…") { queue.chooseWatchFolder(destination:model.targetFolder,shared:model.activeSpace) }
                if !queue.watchedFolder.isEmpty { Toggle("Watch \(queue.watchedFolder)",isOn:$queue.watchEnabled) }
            }
            if queue.paused { Text("Backup paused").foregroundStyle(.secondary) }
            HStack { if queue.running { ProgressView(value:queue.uploadFraction).frame(width:140); Button("Pause") { queue.pause() } } else { Button("Resume / Retry") { queue.retry() }.disabled(queue.records.allSatisfy{$0.state == .complete}) } }
            List(Array(queue.records.filter{$0.state != .complete}.prefix(100)) + Array(queue.records.filter{$0.state == .complete}.suffix(50).reversed())) { record in HStack { Image(systemName:record.state == .complete ? "checkmark.circle.fill" : record.state == .failed ? "exclamationmark.circle" : "arrow.up.circle").foregroundStyle(record.state == .complete ? Color.green : Color.secondary); VStack(alignment:.leading) { Text(record.filename); Text(record.message).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(record.folder).font(.caption).foregroundStyle(.secondary) } }
        }.padding(24)
            .alert("Import failed",isPresented:Binding(get:{queue.error != nil},set:{if !$0 {queue.error = nil}})) { Button("OK") {queue.error = nil} } message:{Text(queue.error ?? "")}
    }
}

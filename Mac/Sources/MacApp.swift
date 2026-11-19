import SwiftUI
import AppKit

@main struct FoteraMacApp: App {
    @StateObject private var model = MacModel()
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var delegate
    var body: some Scene {
        Window("Fotera",id:"main") {
            MacRoot().environmentObject(model).frame(minWidth:850,minHeight:570)
                .task {
                    MacNotifications.shared.register()
                    if model.restoring { await model.restore() }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--album-contract-audit") {await model.auditAlbumContract()}
                    if ProcessInfo.processInfo.arguments.contains("--demo-snapshot") {
                        try? await Task.sleep(for:.seconds(4))
                        if let view = NSApplication.shared.windows.first(where:{$0.isVisible})?.contentView,
                           let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                            view.cacheDisplay(in:view.bounds,to:bitmap)
                            try? bitmap.representation(using:.png,properties:[:])?.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("Fotera-Mac-Library.png"))
                        }
                    }
                    #endif
                }
        }
        .defaultSize(width:1180,height:780)
        .commands {
            CommandGroup(after:.newItem) {
                Button("Import Photos…") { model.backups.chooseFiles(folder:model.targetFolder,shared:model.shared) }.keyboardShortcut("i").disabled(model.client == nil)
                Button("New Album…") { model.creatingAlbum = true }.keyboardShortcut("n",modifiers:[.command,.shift]).disabled((model.client == nil && !ProcessInfo.processInfo.arguments.contains("--demo")) || model.shared)
            }
            CommandMenu("Timeline") {
                Button("Refresh") { if model.section == .folders {model.folderRefresh = UUID()} else {model.refresh()} }.keyboardShortcut("r").disabled(model.client == nil)
                Button("Rebuild NAS Index") { model.refresh(force:true) }.keyboardShortcut("r",modifiers:[.command,.shift]).disabled(model.client == nil)
                Button("Select All") { model.selection = Set(model.visiblePhotos.map(\.id)) }.keyboardShortcut("a")
                Button("Deselect All") { model.selection = [] }.keyboardShortcut("a",modifiers:[.command,.shift])
            }
        }
        Settings { MacSettings().environmentObject(model) }
        MenuBarExtra("Fotera",systemImage:"photo.on.rectangle") { MacStatusMenu(queue:model.backups).environmentObject(model) }
    }
}
struct MacRoot: View {
    @EnvironmentObject var model: MacModel
    var body: some View {
        Group {
            if model.restoring { ProgressView("Opening Fotera…").frame(maxWidth:.infinity,maxHeight:.infinity) }
            else if model.client == nil && !ProcessInfo.processInfo.arguments.contains("--demo") { MacLogin() }
            else {
                NavigationSplitView {
                    VStack(alignment:.leading,spacing:20) {
                        HStack(spacing:10) { Image("Brand").resizable().frame(width:38,height:38).clipShape(RoundedRectangle(cornerRadius:9)); Text("Fotera").font(.title.bold()) }.padding(.horizontal,16).padding(.top,16)
                        List(MacSection.allCases,selection:Binding<MacSection?>(get:{model.section},set:{ if let value = $0 { Task { @MainActor in model.navigate(value) } } })) { section in Label(section.rawValue,systemImage:section.symbol).tag(section).accessibilityIdentifier("sidebar." + section.rawValue.lowercased()) }.listStyle(.sidebar)
                        VStack(alignment:.leading,spacing:6) {
                            Text(model.username).font(.headline)
                            Text(model.activeConnection).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            Picker("Space",selection:$model.shared) { Text("Personal").tag(false); Text("Shared").tag(true) }.labelsHidden()
                                .onChange(of:model.shared) { _,_ in model.collection = nil; model.photos = []; model.albums = []; model.groups = []; model.favorites = []; model.selection = []; model.refresh() }
                            SettingsLink { Label("Settings",systemImage:"gearshape") }.buttonStyle(.plain).padding(.top,6)
                        }.padding(16)
                    }.navigationSplitViewColumnWidth(min:190,ideal:220,max:280)
                } detail: {
                    Group {
                        if model.section == .folders { MacFolderView() }
                        else if model.collection != nil { MacTimeline() }
                        else if model.section == .smart { MacSmartAlbums() }
                        else if model.section == .map { MacMapView() }
                        else if model.section == .received { MacSharedAlbumsView() }
                        else if model.section == .recycle { MacRecycleView() }
                        else if model.section == .offline { MacOfflineView() }
                        else if model.section == .backups { MacBackupView(queue:model.backups) }
                        else if model.collection != nil || ![MacSection.albums,.people,.places,.things].contains(model.section) { MacTimeline() }
                        else { MacCollections() }
                    }
                    .navigationTitle(model.collection == nil ? model.section.rawValue : model.collectionTitle)
                    .toolbar {
                        if model.collection != nil && model.section != .folders { ToolbarItem(placement:.navigation) { Button { model.collection = nil; model.selection = [] } label:{Image(systemName:"chevron.left")}.help("Back") } }
                        ToolbarItemGroup {
                            if model.loading { ProgressView().controlSize(.small) }
                            Button { if model.section == .folders {model.folderRefresh = UUID()} else {model.refresh()} } label:{Image(systemName:"arrow.clockwise")}.help("Refresh")
                            Button { model.backups.chooseFiles(folder:model.targetFolder,shared:model.shared) } label:{Image(systemName:"square.and.arrow.up")}.help("Import photos")
                        }
                    }
                }
            }
        }
        .overlay(alignment:.top) {if let report = model.albumAudit {Text(report).accessibilityIdentifier("album.audit").padding().background(.background)}}
        .overlay(alignment:.bottom) { if let notice = model.notice { Text(notice).padding(.horizontal,18).padding(.vertical,10).background(.regularMaterial,in:Capsule()).padding(20).allowsHitTesting(false) } }
        .alert("Couldn’t complete the request",isPresented:Binding(get:{model.error != nil},set:{if !$0 { model.error = nil }})) { Button("OK") { model.error = nil } } message:{Text(model.error ?? "")}
        .sheet(isPresented:$model.creatingAlbum) {
            MacNewAlbumEditor(items:model.visiblePhotos.filter{model.selection.contains($0.id)}).environmentObject(model)
        }
        .onOpenURL { url in if url.host == "backup" {model.navigate(.backups)} }
        .onReceive(NotificationCenter.default.publisher(for:.macShowBackup)) { _ in model.navigate(.backups) }
        .sheet(item:$model.viewer) { photo in MacViewer(photo:photo).environmentObject(model) }
    }
}
struct MacLogin: View {
    @EnvironmentObject var model: MacModel
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var remember = true
    var body: some View {
        VStack(spacing:20) {
            Image("Brand").resizable().frame(width:90,height:90).clipShape(RoundedRectangle(cornerRadius:20))
            Text("Welcome to Fotera").font(.largeTitle.bold())
            Text("Your photos. Your NAS.").foregroundStyle(.secondary)
            Form {
                TextField("NAS address or QuickConnect ID",text:$address)
                TextField("Username",text:$username)
                SecureField("Password",text:$password)
                TextField("Verification code",text:$otp)
                Toggle("Stay signed in",isOn:$remember)
            }.textFieldStyle(.roundedBorder)
            Button { Task { await model.signIn(address:address,username:username,password:password,otp:otp,remember:remember); if model.client != nil { password = ""; otp = "" } } } label:{ HStack { if model.loading { ProgressView().controlSize(.small) }; Text("Connect").frame(maxWidth:.infinity) } }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.loading || address.isEmpty || username.isEmpty || password.isEmpty)
            Text("Use an HTTPS address, a local HTTP address with port, or your QuickConnect ID.").font(.caption).foregroundStyle(.secondary)
            Text("Independent app. Not affiliated with Synology Inc.").font(.caption2).foregroundStyle(.tertiary)
        }.padding(40).frame(width:490).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
struct MacSettings: View {
    @EnvironmentObject var model: MacModel
    @State private var lan = ""
    @State private var remote = ""
    @State private var quick = ""
    @State private var switching = false
    @State private var saving = false
    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Account",value:model.username)
                LabeledContent("Active connection",value:model.activeConnection)
                Toggle("Automatically switch connections",isOn:$switching)
                TextField("LAN address",text:$lan)
                TextField("Remote HTTPS URL",text:$remote)
                TextField("QuickConnect ID",text:$quick)
                Button(saving ? "Saving…" : "Save connections") {
                    saving = true
                    Task { defer { saving = false }; do { try await model.client?.configureRoutes(lan:lan,remoteURL:remote,quickConnect:quick,enabled:switching); model.toast("Connections saved") } catch { model.error = error.localizedDescription } }
                }.disabled(model.client == nil || saving)
                Button("Sign Out",role:.destructive) { Task { await model.signOut() } }.disabled(model.client == nil)
            }
            Section("Background") {MacBackgroundSettings()}
            Section("Widgets") {MacWidgetSettings()}
            Section("Apple Photos") {
                MacPhotosSetting(library:model.localPhotos)
            }
            Section("Import") {
                TextField("NAS destination",text:$model.targetFolder)
                Text("Path within the selected Photos space, such as /Mac Photos. Year/month folders use the capture date when available.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack { Image("Brand").resizable().frame(width:32,height:32).clipShape(RoundedRectangle(cornerRadius:7)); Text("Fotera for Mac").font(.headline) }
                Text("Fotera is an independent app and is not affiliated with, endorsed by, or sponsored by Synology Inc.")
                Link("Contact support",destination:URL(string:"mailto:Fotera@jwalter.net")!)
                Text("© 2026 John Walter. All rights reserved.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width:530,height:680)
        .task {
            if let address = model.client?.address, let data = UserDefaults.standard.data(forKey:"routes." + LibraryCache.hash(address)), let profile = try? JSONDecoder().decode(RouteProfile.self,from:data) {
                lan = profile.lan; remote = profile.remoteURL ?? ""; quick = profile.quickConnect; switching = profile.enabled
            }
        }
    }
}

struct MacPhotosSetting: View {
    @ObservedObject var library: MacLocalPhotos
    var body: some View {
        VStack(alignment:.leading) {
            Toggle("Show my Mac photo library",isOn:Binding(get:{library.enabled},set:{ value in Task { await library.setEnabled(value) } }))
            Text("Local photos open from Apple Photos. This does not enable automatic backup of your Apple Photos library.").font(.caption).foregroundStyle(.secondary)
            if let error = library.error { Text(error).foregroundStyle(.red) }
        }
    }
}

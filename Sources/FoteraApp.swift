import SwiftUI
import WidgetKit

@main struct FoteraApp: App {
    @UIApplicationDelegateAdaptor(FoteraApplicationDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(app)
        }
    }
}

/// Session, space and library state shared by every screen.
@MainActor final class AppModel: ObservableObject {
    enum Phase { case launching, signedOut, signedIn }
    @Published private(set) var phase: Phase = .launching
    @Published private(set) var client: DSMClient?
    @Published private(set) var shared = false
    @Published var notice: String?
    @Published private(set) var staysSignedIn = false
    let library = LibraryStore()
    @AppStorage("serverAddress") var address = ""
    @AppStorage("accountName") var username = ""
    private var observer: NSObjectProtocol?
    private var backgroundWorker: Task<Void, Never>?

    var account: String { address + "|" + username }
    var manualUploads: TransferQueue { TransferQueue.shared(account: account) }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .foteraSessionExpired, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionExpired() }
        }
    }
    func restore() async {
        guard phase == .launching else { return }
        guard let saved = try? SessionStore.load(), let connection = try? await DSMClient.open(address: saved.address, cachedEndpoint: saved.resolvedAddress) else { phase = .signedOut; return }
        address = connection.address; username = saved.username
        do {
            try await connection.restore(saved, credentials: CredentialStore.load())
            staysSignedIn = await connection.keepsCredentials
            await activate(connection)
            BackupController.shared.start()
        } catch {
            // Offline: keep browsing the cached library and retry on refresh.
            staysSignedIn = await connection.keepsCredentials
            await activate(connection)
            notice = "Couldn’t reach your NAS. Showing saved photos."
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fotera-verify") { await DevelopmentVerification.run(client: connection) }
        #endif
    }
    func signIn(address: String, username: String, password: String, otp: String, remember: Bool) async throws {
        let connection = try await DSMClient.open(address: address)
        try await connection.signIn(username: username, password: password, otp: otp, remember: remember)
        self.address = connection.address; self.username = username
        staysSignedIn = remember
        notice = nil
        await activate(connection)
    }
    private func activate(_ connection: DSMClient) async {
        client = connection
        // Backup's duplicate check reuses the timeline index instead of listing the NAS again.
        TransferQueue.catalogSource = { [weak library] shared in
            guard let library, library.shared == shared, library.lastSynced != nil else { return nil }
            return library.photos
        }
        ImagePipeline.shared.configure(client: connection, account: account)
        BackupController.shared.attach(client: connection, account: account)
        phase = .signedIn
        await library.attach(client: connection, account: account, shared: shared)
    }
    func setShared(_ value: Bool) {
        guard value != shared else { return }
        shared = value
        Task { await library.attach(client: client, account: account, shared: value) }
    }
    func signOut() async {
        let connection = client
        BackupController.shared.detach()
        await manualUploads.cancelUploads()
        await BackgroundUploads.shared.cancelAll()
        try? SessionStore.clear()
        try? CredentialStore.clear()
        try? WidgetSnapshotStore.clear(); WidgetCenter.shared.reloadAllTimelines()
        try? await LibraryCache.shared.clear()
        try? await OfflineVault.shared.clear(account: account)
        ImagePipeline.shared.configure(client: nil, account: "")
        client = nil; shared = false; staysSignedIn = false
        await library.attach(client: nil, account: "", shared: false)
        phase = .signedOut
        await connection?.disconnect()
    }
    func forgetCredentials() async throws {
        if let client { try await client.forgetCredentials() }
        else { try CredentialStore.clear() }
        staysSignedIn = false
    }
    private func sessionExpired() {
        guard phase == .signedIn, !staysSignedIn else { return }
        try? SessionStore.clear()
        BackupController.shared.detach()
        client = nil
        ImagePipeline.shared.configure(client: nil, account: account)
        notice = "Your session expired. Sign in again."
        phase = .signedOut
    }
    func becameActive() {
        guard let client else { return }
        library.refreshIfStale()
        BackupController.shared.start()
        if !manualUploads.pending.isEmpty { manualUploads.start(client: client, wifiOnly: false) }
    }
    /// Before suspension, hand queued uploads to iOS so they continue in the background.
    func enteredBackground() {
        TransferQueue.flushAll()
        guard BackupController.shared.preferences.enabled, client != nil, !BackupScheduler.hasContinuedBackup else { return }
        final class Token { var id = UIBackgroundTaskIdentifier.invalid }
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "Fotera backup") { [weak self] in
            MainActor.assumeIsolated {
                self?.backgroundWorker?.cancel()
                BackupController.shared.pause()
                if token.id != .invalid { UIApplication.shared.endBackgroundTask(token.id); token.id = .invalid }
            }
        }
        backgroundWorker?.cancel()
        backgroundWorker = Task {
            defer { if token.id != .invalid { UIApplication.shared.endBackgroundTask(token.id); token.id = .invalid } }
            let backup = BackupController.shared
            backup.pause()
            await backup.waitUntilIdle()
            guard !Task.isCancelled else { return }
            await backup.run(deadline: Date().addingTimeInterval(25), background: true)
            BackupScheduler.schedule(backup.preferences)
            if token.id != .invalid { UIApplication.shared.endBackgroundTask(token.id); token.id = .invalid }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = AppearanceSetting.dark.rawValue
    @State private var activityBackup = false
    var body: some View {
        Group {
            switch app.phase {
            case .launching: ProgressView().controlSize(.large)
            case .signedOut: LoginView()
            case .signedIn: MainTabs()
            }
        }
        .animation(.default, value: app.phase)
        .preferredColorScheme((AppearanceSetting(rawValue: appearance) ?? .dark).scheme)
        .task {
            await app.restore()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--continued-backup-test") { BackupScheduler.requestContinuedBackup() }
            if ProcessInfo.processInfo.arguments.contains("--fotera-live-activity-test") {
                do {
                    try await BackupLiveActivity.shared.verifyLifecycle()
                    let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("live-activity-test.txt")
                    try "PASS: Live Activity requested and updated to 64 percent".write(to: report, atomically: true, encoding: .utf8)
                } catch {
                    let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("live-activity-test.txt")
                    try? error.localizedDescription.write(to: report, atomically: true, encoding: .utf8)
                }
            }
            #endif
        }
        .onOpenURL { url in
            if url.scheme == "fotera", url.host == "backup", app.client != nil { activityBackup = true }
        }
        .sheet(isPresented: $activityBackup) {
            NavigationStack {
                BackupView(backup: BackupController.shared)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { activityBackup = false } } }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.becameActive() }
            if phase == .background { app.enteredBackground() }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject private var app: AppModel
    @State private var tab = DebugScreen.initialTab
    var body: some View {
        TabView(selection: $tab) {
            PhotosTab(library: app.library, backup: BackupController.shared)
                .tabItem { Label("Photos", systemImage: "photo.on.rectangle.angled") }.tag(0)
            SearchTab(library: app.library)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
            LibraryTab(library: app.library)
                .tabItem { Label("Library", systemImage: "rectangle.stack") }.tag(2)
        }
    }
}

/// DEBUG-only launch argument (`--fotera-screen <name>`) for headless UI screenshots.
enum DebugScreen {
    static var name: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--fotera-screen"), arguments.indices.contains(index + 1) { return arguments[index + 1] }
        #endif
        return nil
    }
    static var initialTab: Int { name == "search" ? 1 : (name == "library" ? 2 : 0) }
}

// MARK: - Sign in

struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var needsOTP = false
    @State private var remember = true
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var focus: Field?
    enum Field { case address, username, password, otp }
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack.fill").font(.system(size: 56)).foregroundStyle(.tint)
                    Text("Fotera").font(.largeTitle.bold())
                    Text("Your Synology Photos library").foregroundStyle(.secondary)
                }.padding(.top, 48)
                VStack(spacing: 12) {
                    field("Server or QuickConnect ID", "https://nas.example.com:5001", text: $address, field: .address)
                        .keyboardType(.URL).textContentType(.URL)
                    field("Username", "DSM username", text: $username, field: .username).textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password).focused($focus, equals: .password).submitLabel(needsOTP ? .next : .go)
                        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    if needsOTP {
                        field("Verification code", "6-digit code", text: $otp, field: .otp)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    }
                    Toggle("Stay signed in", isOn: $remember).padding(.horizontal, 4).padding(.top, 4)
                }
                if let message = failure ?? app.notice {
                    Text(message).font(.footnote).foregroundStyle(failure == nil ? Color.secondary : Color.red).multilineTextAlignment(.center)
                }
                Button { Task { await connect() } } label: {
                    Group { if busy { ProgressView().tint(.white) } else { Text("Sign in").bold() } }
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 12))
                .disabled(busy || address.isEmpty || username.isEmpty || password.isEmpty)
                if address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
                    Label("LAN HTTP is not encrypted. Use it only on a trusted local network; your login and photos travel without encryption.", systemImage: "lock.open")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Enter your NAS address or QuickConnect ID. HTTP is supported for local IP addresses and .local names; QuickConnect uses verified HTTPS. “Stay signed in” keeps your password in this iPhone’s Keychain so backup can renew its session.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onSubmit {
            switch focus {
            case .address: focus = .username
            case .username: focus = .password
            default: Task { await connect() }
            }
        }
        .onAppear {
            address = app.address.isEmpty ? "https://" : app.address
            username = app.username
        }
    }
    private func field(_ label: String, _ prompt: String, text: Binding<String>, field: Field) -> some View {
        TextField(label, text: text, prompt: Text(prompt))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .focused($focus, equals: field)
            .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    private func connect() async {
        guard !busy, !address.isEmpty, !username.isEmpty, !password.isEmpty else { return }
        busy = true; failure = nil; focus = nil
        defer { busy = false }
        do {
            try await app.signIn(address: address, username: username, password: password, otp: otp, remember: remember)
            password = ""; otp = ""
        } catch AuthError.otpRequired {
            withAnimation { needsOTP = true }
            focus = .otp
            failure = AuthError.otpRequired.localizedDescription
        } catch {
            if case AuthError.otpInvalid = error { otp = "" }
            failure = error.localizedDescription
        }
    }
}

// MARK: - Photos

struct PhotosTab: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var backup: BackupController
    @AppStorage("timelineGrouping") private var grouping = TimelineGrouping.day.rawValue
    @State private var selection: Set<Int>?
    @State private var showingSettings = false
    @State private var showingBackup = false
    @State private var memory: Memory?
    var body: some View {
        NavigationStack {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    BackupProgressLine(backup: backup) { showingBackup = true }
                        .animation(.snappy, value: backup.running)
                }
                .toolbar {
                    if selection == nil {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                Picker("Space", selection: Binding(get: { app.shared }, set: { app.setShared($0) })) {
                                    Label("Personal Space", systemImage: "person").tag(false)
                                    Label("Shared Space", systemImage: "person.2").tag(true)
                                }
                                Picker("Group by", selection: $grouping) {
                                    ForEach(TimelineGrouping.allCases) { Text($0.rawValue).tag($0.rawValue) }
                                }
                                Button("Select", systemImage: "checkmark.circle") { selection = [] }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(app.shared ? "Shared" : "Photos").font(.headline)
                                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                                }
                                .foregroundStyle(.primary)
                            }
                            .accessibilityLabel("Space and view options")
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button { showingBackup = true } label: { BackupBadge(backup: backup) }
                            Button { showingSettings = true } label: { Image(systemName: "person.crop.circle") }
                                .accessibilityLabel("Settings")
                        }
                    }
                }
                .selectionChrome($selection, items: library.photos)
                .refreshable { await library.refreshAndWait() }
                .sheet(isPresented: $showingSettings) { SettingsView() }
                .sheet(isPresented: $showingBackup) { NavigationStack { BackupView(backup: backup).toolbar { Button("Done") { showingBackup = false } } } }
                .fullScreenCover(item: $memory) { memory in
                    if memory.id == "debug" {
                        MediaViewer(items: memory.items, startID: memory.items.first?.id ?? 0, shared: app.shared)
                    } else {
                        MemoryStoryView(memory: memory, shared: app.shared)
                    }
                }
                .onAppear {
                    library.grouping = TimelineGrouping(rawValue: grouping) ?? .day
                    if DebugScreen.name == "settings" { showingSettings = true }
                    if DebugScreen.name == "backup" { showingBackup = true }
                    if DebugScreen.name == "select" { selection = Set(library.photos.prefix(3).map(\.id)) }
                }
                .task(id: library.photos.count) {
                    if DebugScreen.name == "viewer" || DebugScreen.name == "info", memory == nil, let first = library.photos.first(where: { $0.isLive }) {
                        memory = Memory(id: "debug", title: "", items: Array(library.photos.prefix(20)).filter { $0.id == first.id } + library.photos.prefix(5))
                    }
                }
                .onChange(of: grouping) { library.grouping = TimelineGrouping(rawValue: grouping) ?? .day }
        }
    }
    @ViewBuilder private var content: some View {
        if library.photos.isEmpty {
            if library.syncing {
                SkeletonGrid().overlay(alignment: .bottom) {
                    if let progress = library.progress { Text(progress).font(.footnote).card(padding: 10).padding(.bottom, 24) }
                }
            } else if let failure = library.failure {
                ContentUnavailableView {
                    Label("Couldn’t load photos", systemImage: "wifi.exclamationmark")
                } description: { Text(failure) } actions: { Button("Try again") { library.refresh() } }
            } else {
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle",
                    description: Text(app.shared ? "Shared Space is empty." : "Turn on backup or upload photos to see them here."))
            }
        } else {
            PhotoGrid(sections: library.gridSections, shared: app.shared, selection: $selection, showsScrubber: true) {
                VStack(alignment: .leading, spacing: 8) {
                    if let notice = app.notice ?? library.failure.map({ "Couldn’t refresh: " + $0 }) {
                        Label(notice, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                    if let progress = library.progress {
                        Label(progress, systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                    if !library.memories.isEmpty && selection == nil { memories }
                }
            }
        }
    }
    private var memories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(library.memories) { memory in
                    Button { self.memory = memory } label: {
                        ThumbnailView(source: memory.items.first(where: { !$0.isVideo })?.thumbnailSource ?? memory.items.first?.thumbnailSource, shared: app.shared, size: .m)
                            .frame(width: 132, height: 176)
                            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom))
                            .overlay(alignment: .bottomLeading) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(memory.title).font(.subheadline.weight(.bold))
                                    Text("\(memory.items.count) \(memory.items.count == 1 ? "item" : "items")").font(.caption2).opacity(0.85)
                                }
                                .foregroundStyle(.white).padding(10)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }.buttonStyle(.plain).accessibilityLabel("Memory, \(memory.title)")
                }
            }.padding(.horizontal, Theme.medium)
        }
        .padding(.vertical, 8)
    }
}

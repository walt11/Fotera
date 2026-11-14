import SwiftUI
import WidgetKit
import Photos

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var backup = BackupController.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("alwaysLoadOriginals") private var alwaysLoadOriginals = false
    @AppStorage("widgetMemories") private var widgetMemories = true
    @AppStorage("appLock") private var appLock = false
    @AppStorage("videoQuality") private var videoQuality = VideoQuality.fast.rawValue
    @AppStorage("appearance") private var appearance = AppearanceSetting.dark.rawValue
    @State private var cacheSize: Int?
    @State private var signingOut = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Text(String(app.username.prefix(1)).uppercased())
                            .font(.title2.bold()).foregroundStyle(.white)
                            .frame(width: 52, height: 52).background(Color.accentColor, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.username).font(.headline)
                            Text(app.activeConnectionLabel).font(.subheadline).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }.padding(.vertical, 4)
                }
                Section("Backup & connection") {
                    NavigationLink { BackupView(backup: backup) } label: {
                        LabeledContent { Text(backup.preferences.enabled ? backup.status : "Off").lineLimit(1) } label: {
                            Label("Photo backup", systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    NavigationLink { ConnectionSettingsView() } label: { Label("Connections", systemImage: "network") }
                    NavigationLink { TransfersView(queue: app.manualUploads) } label: {
                        Label("Manual uploads", systemImage: "square.and.arrow.up")
                    }
                }
                AccountsSection()
                Section("Preferences") {
                    NavigationLink { AppIconSettingsView() } label: { Label("App icon", systemImage: "app") }
                    NavigationLink { Form { viewingSettings }.navigationTitle("Viewing") } label: { Label("Viewing", systemImage: "photo") }
                    NavigationLink { Form { privacySettings }.navigationTitle("Privacy & sign-in") } label: { Label("Privacy & sign-in", systemImage: "lock") }
                    if WidgetSnapshotStore.isAvailable {
                        NavigationLink { Form { widgetSettings }.navigationTitle("Widgets") } label: { Label("Widgets", systemImage: "rectangle.on.rectangle") }
                    }
                    NavigationLink { Form { storageSettings }.navigationTitle("Storage") } label: { Label("Storage", systemImage: "internaldrive") }
                }
                Section {
                    Button("Sign out", role: .destructive) { signingOut = true }
                }
                Section {
                    LabeledContent("Version", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0")
                } footer: {
                    VStack(spacing: 8) {
                        Text("Fotera is an independent app, not affiliated with or endorsed by Synology Inc.")
                        Text("© 2026 John Walter. All rights reserved.")
                    }
                    .font(.footnote).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { FoteraBrand(page: "Settings") }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { cacheSize = await LibraryCache.shared.size() }
            .confirmationDialog("Sign out? Uploads in progress stop, and saved previews and the widget are cleared.", isPresented: $signingOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { dismiss(); await app.signOut() } }
            }
            .alert("Fotera", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }
    private var viewingSettings: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceSetting.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Button("iPhone Photos access") {
                if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                    Task { await app.library.requestPhotoAccess() }
                } else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Toggle("Always load originals", isOn: $alwaysLoadOriginals)
            Picker("Video quality", selection: $videoQuality) {
                ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
        } header: { Text("Viewing") } footer: {
            Text("“Always load originals” downloads full-resolution photos immediately instead of when you zoom, share or save.")
        }
    }
    private var widgetSettings: some View {
            Section {
                Toggle("Memories in widget", isOn: $widgetMemories)
                    .onChange(of: widgetMemories) {
                        UserDefaults.standard.removeObject(forKey: "widgetMemoriesStamp")
                        if !widgetMemories { try? WidgetSnapshotStore.saveMemories([]) }
                        else { app.library.refreshWidgetMemories() }
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                Button("Reset widget photo") {
                    try? WidgetSnapshotStore.clearPinned()
                    app.library.refreshWidgetMemories()
                    WidgetCenter.shared.reloadAllTimelines()
                    message = "The widget will rotate through memories again."
                }
            } header: { Text("Widget") }
    }
    private var storageSettings: some View {
        Section {
            LabeledContent("Cached previews") {
                if let cacheSize { Text(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)) } else { ProgressView() }
            }
            NavigationLink("Repair HEIC previews") { HEICPreviewGenerationView() }
            Button("Clear cache") {
                Task {
                    try? await LibraryCache.shared.clear()
                    cacheSize = await LibraryCache.shared.size()
                    app.library.refresh(force: true)
                }
            }
        } header: { Text("Storage") } footer: { Text("Clear previews to free space on this iPhone. Your NAS photos are kept.") }
    }
    private var privacySettings: some View {
        Section {
            Toggle("Lock with Face ID", isOn: $appLock)
            LabeledContent("Stay signed in", value: app.staysSignedIn ? "On" : "Off")
            if app.staysSignedIn {
                Button("Forget saved password") {
                    Task {
                        do { try await app.forgetCredentials() }
                        catch { message = error.localizedDescription }
                    }
                }
            }
        } header: { Text("Account") } footer: {
            if !app.staysSignedIn { Text("Enable “Stay signed in” at login to keep backup connected.") }
        }
    }
}


struct HEICPreviewGenerationView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var worker: Task<Void, Never>?
    @State private var running = false
    @State private var processed = 0
    @State private var total = 0
    @State private var generated = 0
    @State private var failed = 0
    @State private var status = "Ready"
    var body: some View {
        Form {
            Section {
                Text("Create missing HEIC previews for this space using your iPhone.")
                Text("Keep this screen open on Wi-Fi. Originals are downloaded to create previews; files over 50 MB are skipped.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text(status)
                if total > 0 {
                    ProgressView(value: Double(processed), total: Double(total))
                    Text("\(processed) of \(total) checked · \(generated) generated · \(failed) unavailable").font(.footnote)
                }
                if running { Button("Stop", role: .cancel) { stop() } }
                else { Button("Generate previews") { start() }.disabled(app.client == nil) }
            }
        }
        .navigationTitle("HEIC previews")
        .onDisappear { stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { stop() } }
    }
    private func stop() { worker?.cancel(); if running { status = "Stopping…" } }
    private func start() {
        guard let client = app.client, !running else { return }
        let shared = app.shared
        running = true; processed = 0; generated = 0; failed = 0; total = 0; status = "Finding HEIC photos…"
        worker = Task { @MainActor in
            defer { running = false; worker = nil }
            do {
                var photos: [RemotePhoto] = []; var seen = Set<Int>(); var offset = 0
                while true {
                    try Task.checkCancellation()
                    let page = try await client.items(.all, shared: shared, offset: offset)
                    photos += page.filter { ImagePipeline.isHEIC($0) && seen.insert($0.id).inserted }
                    offset += page.count
                    if page.count < DSMClient.pageSize { break }
                }
                total = photos.count
                for photo in photos {
                    try Task.checkCancellation()
                    guard app.client === client else { throw CancellationError() }
                    status = "Generating previews…"
                    let preview = await ImagePipeline.shared.originalPreview(photo, shared: shared, size: .xl, regenerate: true)
                    try Task.checkCancellation()
                    processed += 1
                    if preview != nil { generated += 1 } else { failed += 1 }
                }
                status = total == 0 ? "No HEIC photos found in this space." : "Finished. Return to the timeline to see your previews."
            } catch {
                status = isCancelledRequest(error) || Task.isCancelled ? "Stopped. Generated previews are saved." : error.localizedDescription
            }
        }
    }
}


private enum FoteraIcon: String, CaseIterable, Identifiable {
    case classic = "Classic", midnight = "Midnight", aurora = "Aurora", sunset = "Sunset", violet = "Violet", monochrome = "Monochrome", black = "Black"
    var id: String { rawValue }
    var assetName: String { self == .classic ? "AppIcon" : "AppIcon" + rawValue }
    var alternateName: String? { self == .classic ? nil : assetName }
    var previewName: String { "IconPreview" + rawValue }
}

struct AppIconSettingsView: View {
    @State private var selected = UIApplication.shared.alternateIconName
    @State private var changing = false
    @State private var failure: String?
    var body: some View {
        List {
            Section {
                ForEach(FoteraIcon.allCases) { icon in
                    Button { change(to: icon) } label: {
                        HStack(spacing: 14) {
                            Image(icon.previewName).resizable().scaledToFit()
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            Text(icon.rawValue).foregroundStyle(.primary)
                            Spacer()
                            if selected == icon.alternateName {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }.padding(.vertical, 3)
                    }
                    .disabled(changing || !UIApplication.shared.supportsAlternateIcons)
                    .accessibilityAddTraits(selected == icon.alternateName ? .isSelected : [])
                }
            } footer: {
                Text("Each icon follows your Home Screen’s light or dark appearance. Midnight and Black stay dark in either mode.")
            }
            if !UIApplication.shared.supportsAlternateIcons {
                Text("Icon changes aren’t available on this device.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("App icon").navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            selected = UIApplication.shared.alternateIconName
        }
        .alert("Couldn’t change icon", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }
    private func change(to icon: FoteraIcon) {
        guard !changing, selected != icon.alternateName else { return }
        changing = true
        UIApplication.shared.setAlternateIconName(icon.alternateName) { error in
            Task { @MainActor in
                changing = false
                selected = UIApplication.shared.alternateIconName
                failure = error?.localizedDescription
            }
        }
    }
}

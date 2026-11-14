import SwiftUI
import WidgetKit

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
                            Text(URL(string: app.address)?.host ?? app.address).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                AccountsSection()
                Section {
                    NavigationLink { BackupView(backup: backup) } label: {
                        LabeledContent { Text(backup.preferences.enabled ? backup.status : "Off").lineLimit(1) } label: {
                            Label("Backup", systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    NavigationLink { ConnectionSettingsView() } label: { Label("Connections", systemImage: "network") }
                    NavigationLink { TransfersView(queue: app.manualUploads) } label: {
                        Label("Upload to NAS", systemImage: "square.and.arrow.up")
                    }
                }
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceSetting.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Toggle("Always load originals", isOn: $alwaysLoadOriginals)
                    Toggle("Lock with Face ID", isOn: $appLock)
                    Picker("Video quality", selection: $videoQuality) {
                        ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } header: { Text("Viewing") } footer: {
                    Text("When off, Fotera shows the NAS’s high-quality preview and downloads the original only when you zoom in, share or save.")
                }
                if WidgetSnapshotStore.isAvailable {
                    Section {
                        Toggle("Memories in widget", isOn: $widgetMemories)
                            .onChange(of: widgetMemories) {
                                UserDefaults.standard.removeObject(forKey: "widgetMemoriesStamp")
                                if !widgetMemories { try? WidgetSnapshotStore.saveMemories([]) }
                                WidgetCenter.shared.reloadAllTimelines()
                            }
                        Button("Reset widget photo") {
                            try? WidgetSnapshotStore.clearPinned(); WidgetCenter.shared.reloadAllTimelines()
                            message = "The widget will rotate through memories again."
                        }
                    } header: { Text("Widget") }
                }
                Section {
                    LabeledContent("Cached previews") {
                        if let cacheSize { Text(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)) } else { ProgressView() }
                    }
                    Button("Clear cache") {
                        Task {
                            try? await LibraryCache.shared.clear()
                            cacheSize = await LibraryCache.shared.size()
                            app.library.refresh(force: true)
                        }
                    }
                } header: { Text("Storage") } footer: { Text("Previews are kept on this iPhone for fast browsing, up to 300 MB. Originals are never cached.") }
                Section {
                    LabeledContent("Stay signed in", value: app.staysSignedIn ? "On" : "Off")
                    if app.staysSignedIn {
                        Button("Forget saved password") {
                            Task {
                                do { try await app.forgetCredentials() }
                                catch { message = error.localizedDescription }
                            }
                        }
                    }
                    Button("Sign out", role: .destructive) { signingOut = true }
                } header: { Text("Account") } footer: {
                    if !app.staysSignedIn { Text("Without a saved password, backup stops when the NAS session expires. Sign in with “Stay signed in” to keep it running.") }
                }
                Section {
                    LabeledContent("Version", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0")
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { cacheSize = await LibraryCache.shared.size() }
            .confirmationDialog("Sign out? Uploads in progress stop, and saved previews and the widget are cleared.", isPresented: $signingOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { dismiss(); await app.signOut() } }
            }
            .alert("Fotera", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }
}

import SwiftUI
import Photos
import UserNotifications

// MARK: - History log

/// A small on-device record of backup runs, for checking how backup behaves over days.
@MainActor final class BackupLog: ObservableObject {
    static let shared = BackupLog()
    struct Entry: Codable, Identifiable {
        var id: Date { date }
        let date: Date
        let trigger: String
        let seconds: Double
        let staged: Int
        let finished: Int
        let attention: Int
        let status: String
    }
    @Published private(set) var entries: [Entry] = []
    static let limit = 500
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backup/history.json")
    }
    private init() {
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
    func record(_ entry: Entry) {
        // Skip empty background wakes that did nothing, so the log stays readable.
        if entry.staged == 0 && entry.finished == 0 && entry.trigger != "foreground", entries.first?.status == entry.status,
           let last = entries.first, entry.date.timeIntervalSince(last.date) < 600 { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }
    func clear() { entries = []; save() }
    private func save() {
        let snapshot = entries, url = url
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    /// A CSV copy for sharing.
    func exportFile() throws -> URL {
        let formatter = ISO8601DateFormatter()
        var lines = ["date,trigger,seconds,prepared,finished,attention,status"]
        for entry in entries {
            let status = entry.status.replacingOccurrences(of: "\"", with: "'")
            lines.append("\(formatter.string(from: entry.date)),\(entry.trigger),\(Int(entry.seconds)),\(entry.staged),\(entry.finished),\(entry.attention),\"\(status)\"")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Fotera backup history.csv")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

struct BackupHistoryView: View {
    @ObservedObject private var log = BackupLog.shared
    @State private var exported: URL?
    var body: some View {
        List {
            if log.entries.isEmpty {
                ContentUnavailableView("No backup runs yet", systemImage: "clock", description: Text("Each foreground and background backup run is recorded here."))
            }
            ForEach(log.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(Self.label(entry.trigger)).font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    Text("\(entry.finished) backed up · \(entry.staged) prepared · \(Int(entry.seconds.rounded())) s")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.status).font(.caption).foregroundStyle(entry.attention > 0 ? .orange : .secondary).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Backup history").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !log.entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let exported { ShareLink("Export CSV", item: exported) }
                        Button("Clear history", role: .destructive) { log.clear() }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("History options")
                }
            }
        }
        .task(id: log.entries.count) { exported = try? log.exportFile() }
    }
    static func label(_ trigger: String) -> String {
        switch trigger {
        case "foreground": return "In app"
        case "suspend": return "Leaving app"
        case "wake": return "Upload finished"
        case "refresh": return "Background refresh"
        case "overnight": return "Overnight"
        case "continued": return "Continued"
        default: return trigger.capitalized
        }
    }
}

// MARK: - Notifications

/// Local notifications so you know backup is working without opening the app.
@MainActor enum BackupNotifier {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "backupNotifications") as? Bool ?? true }
    static func runFinished(newItems: Int, attention: Int, previousAttention: Int, upToDate: Bool) {
        guard enabled, UIApplication.shared.applicationState != .active else { return }
        if attention > previousAttention {
            post("backup.attention", title: "Backup needs attention",
                 body: "\(attention) \(attention == 1 ? "file needs" : "files need") attention. Open Fotera to retry or dismiss them.")
        } else if newItems > 0 && upToDate {
            post("backup.complete", title: "Backup complete",
                 body: "\(newItems) new \(newItems == 1 ? "item was" : "items were") backed up to your NAS.")
        }
    }
    /// Once a day at most: warn when backup is on but hasn't completed for three days.
    static func checkStalled() {
        let backup = BackupController.shared
        guard enabled, backup.preferences.enabled, let last = backup.lastCompleted,
              Date().timeIntervalSince(last) > 3 * 86_400 else { return }
        let key = "backupStalledNotified"
        if let previous = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(previous) < 86_400 { return }
        UserDefaults.standard.set(Date(), forKey: key)
        post("backup.stalled", title: "Backup hasn’t finished in 3 days",
             body: backup.status.isEmpty ? "Open Fotera to let backup catch up." : backup.status + ". Open Fotera to let backup catch up.")
    }
    private static func post(_ id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        content.userInfo = ["url": "fotera://backup"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Opens Backup when a backup notification is tapped.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) else { return }
        await MainActor.run { NotificationCenter.default.post(name: .foteraOpenURL, object: url) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
}
extension Notification.Name {
    static let foteraOpenURL = Notification.Name("FoteraOpenURL")
}

// MARK: - Free up space

/// Like Immich: removes iPhone copies of photos whose NAS copy was byte-verified. iOS asks for
/// confirmation and keeps the items in Recently Deleted for 30 days.
struct FreeUpSpaceView: View {
    @ObservedObject var backup: BackupController
    @AppStorage("freeUpDays") private var days = 30
    @State private var scanning = false
    @State private var progress: (Int, Int) = (0, 0)
    @State private var result: BackupController.Removable?
    @State private var message: String?
    var body: some View {
        List {
            Section {
                Picker("Keep items from the last", selection: $days) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                }
                .onChange(of: days) { result = nil }
            } footer: {
                Text("Only photos and videos whose NAS copy was downloaded back and matched byte for byte are included. Items backed up with verification off are never removed.")
            }
            Section {
                if scanning {
                    HStack {
                        ProgressView()
                        Text(progress.1 > 0 ? "Checking \(progress.0.formatted()) of \(progress.1.formatted())…" : "Checking…").foregroundStyle(.secondary)
                    }
                } else if let result {
                    LabeledContent("Verified on NAS", value: "\(result.assets.count.formatted()) items")
                    LabeledContent("Space to free", value: ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))
                    if result.missing > 0 {
                        Text("\(result.missing.formatted()) backed-up \(result.missing == 1 ? "item stays" : "items stay") on this iPhone: \(result.missing == 1 ? "it isn’t" : "they aren’t") on the NAS anymore, or the iPhone’s original has changed since the backup.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let failure = result.failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                    Button(role: .destructive) { Task { await remove(result.assets) } } label: {
                        Text(result.assets.isEmpty ? "Nothing to remove" : "Remove \(result.assets.count.formatted()) items from iPhone")
                    }
                    .disabled(result.assets.isEmpty)
                } else {
                    Button("Check what can be removed") { Task { await scan() } }
                }
            } footer: {
                Text("iOS asks you to confirm, and removed items stay in the Photos app’s Recently Deleted album for 30 days.")
            }
            if let message { Section { Text(message) } }
        }
        .navigationTitle("Free up space").navigationBarTitleDisplayMode(.inline)
    }
    private func scan() async {
        scanning = true; message = nil
        defer { scanning = false }
        result = await backup.verifiedRemovable(olderThan: days) { done, total in progress = (done, total) }
    }
    private func remove(_ assets: [PHAsset]) async {
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
            message = "Removed \(assets.count.formatted()) items. They’re in Recently Deleted in the Photos app for 30 days."
            result = nil
        } catch {
            // Cancelling the iOS confirmation also lands here.
            message = (error as NSError).code == 3072 ? nil : error.localizedDescription
        }
    }
}

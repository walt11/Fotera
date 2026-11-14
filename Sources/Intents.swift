import AppIntents
import Photos

/// Starts a backup pass without opening Fotera.
struct BackUpNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Back Up Now"
    static let description = IntentDescription("Uploads new photos and videos to your NAS.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await BackupScheduler.ensureAttached() else { return .result(dialog: "Open Fotera and sign in first.") }
        let backup = BackupController.shared
        guard backup.preferences.enabled else { return .result(dialog: "Backup is off. Turn it on in Fotera first.") }
        await backup.waitForNetwork()
        if !backup.running { await backup.run(deadline: Date().addingTimeInterval(25), background: true, trigger: "shortcut") }
        backup.updateCounts()
        return .result(dialog: "\(backup.status). \(backup.backedUpAssets) of \(backup.totalAssets) items are backed up.")
    }
}

/// Uploads the most recent photo or video to the folder chosen in Upload to NAS.
struct UploadLatestPhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Upload Latest Photo"
    static let description = IntentDescription("Uploads your most recent photo or video to your NAS upload folder.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let folder = ShareInbox.uploadFolder
        let shared = ShareInbox.uploadShared
        guard !folder.isEmpty else { return .result(dialog: "Choose an upload folder in Fotera → Upload to NAS first.") }
        guard await BackupScheduler.ensureAttached(), let client = BackupController.shared.client else {
            return .result(dialog: "Open Fotera and sign in first.")
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return .result(dialog: "Allow Fotera to access Photos first.") }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: options).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { [.photo, .video].contains($0.type) }) else {
            return .result(dialog: "No photos found.")
        }
        let account = UserDefaults.standard.string(forKey: "serverAddress").map { $0 + "|" + (UserDefaults.standard.string(forKey: "accountName") ?? "") } ?? ""
        let queue = TransferQueue.shared(account: account)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FoteraShortcut-" + UUID().uuidString)
        let digest = try await StagedExport.write(resource, to: temporary)
        try await queue.enqueue(temporary, filename: resource.originalFilename, folder: folder, shared: shared, move: true, digest: digest)
        await queue.process(client: client, wifiOnly: false, verify: true, deadline: Date().addingTimeInterval(20))
        return .result(dialog: "\(resource.originalFilename) is uploading to \(folder).")
    }
}

/// Opens Fotera on today's memories.
struct ShowMemoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Memories"
    static let description = IntentDescription("Opens Fotera to today’s memories.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .foteraOpenURL, object: URL(string: "fotera://memories"))
        return .result()
    }
}

struct FoteraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BackUpNowIntent(), phrases: ["Back up photos with \(.applicationName)", "\(.applicationName) back up now"],
                    shortTitle: "Back Up Now", systemImageName: "arrow.triangle.2.circlepath.icloud")
        AppShortcut(intent: UploadLatestPhotoIntent(), phrases: ["Upload my latest photo with \(.applicationName)"],
                    shortTitle: "Upload Latest Photo", systemImageName: "square.and.arrow.up")
        AppShortcut(intent: ShowMemoriesIntent(), phrases: ["Show memories in \(.applicationName)"],
                    shortTitle: "Show Memories", systemImageName: "sparkles")
    }
}

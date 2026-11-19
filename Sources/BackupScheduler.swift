import BackgroundTasks
import UIKit

/// Schedules backup work when Fotera isn't open: a short app-refresh task to keep uploads moving,
/// and a longer processing task (usually overnight while charging) that also verifies uploads.
@MainActor enum BackupScheduler {
    nonisolated static var continuedID: String { (Bundle.main.bundleIdentifier ?? "net.jwalter.PhotoHarbor") + ".continued.backup" }
    private static var continuedTask: BGTask?
    private static var continuedRequested = false
    static var hasContinuedBackup: Bool { continuedRequested || continuedTask != nil }
    nonisolated static var processingID: String { (Bundle.main.bundleIdentifier ?? "net.jwalter.PhotoHarbor") + ".backup" }
    nonisolated static var refreshID: String { (Bundle.main.bundleIdentifier ?? "net.jwalter.PhotoHarbor") + ".refresh" }

    nonisolated static func register() {
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedID, using: nil) { task in
                Task { @MainActor in await runContinued(task) }
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            Task { @MainActor in await run(task, deadline: nil) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            Task { @MainActor in await run(task, deadline: Date().addingTimeInterval(25)) }
        }
    }
    static func schedule(_ preferences: BackupPreferences) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
        guard preferences.enabled else { return }
        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = preferences.chargingOnly
        processing.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(processing)
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
    }
    /// Restores the saved session when iOS launches Fotera in the background.
    static func ensureAttached() async -> Bool {
        let backup = BackupController.shared
        if backup.isAttached { return true }
        guard let saved = try? SessionStore.load(), let client = try? await DSMClient.open(address: saved.address, cachedEndpoint: saved.resolvedAddress, preferCached: true) else { return false }
        do { try await client.restore(saved, credentials: CredentialStore.load()) } catch { return false }
        backup.attach(client: client, account: client.address + "|" + saved.username)
        return true
    }
    /// Gives the backup a short window: reconcile finished uploads and hand iOS the next batch.
    static func continueInBackground(seconds: Double) async {
        guard await ensureAttached() else { return }
        let backup = BackupController.shared
        await backup.waitForNetwork()
        if backup.running { backup.updateCounts(); return }
        await backup.run(deadline: Date().addingTimeInterval(seconds), background: true, trigger: "wake")
        BackupNotifier.checkStalled()
    }
    /// Only called from explicit Enable / Back up now / Continue actions while foregrounded.
    static func requestContinuedBackup() {
        guard #available(iOS 26.0, *), !hasContinuedBackup,
              UIApplication.shared.applicationState == .active else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: continuedID, title: "Fotera photo backup", subtitle: "Preparing photos and videos")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request); continuedRequested = true
            BackupController.shared.backgroundNotice = nil
        } catch {
            BackupController.shared.backgroundNotice = "iOS couldn’t grant extended backup time right now. Scheduled background uploads are still enabled; try Back up now again later."
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--continued-backup-test") {
                let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("continued-test.txt")
                try? ("REQUEST FAILED: " + error.localizedDescription).write(to: file, atomically: true, encoding: .utf8)
            }
            #endif
        }
    }
    static func cancelContinuedBackup() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedID)
        let task = continuedTask
        continuedTask = nil; continuedRequested = false
        task?.setTaskCompleted(success: false)
    }
    static func updateContinuedProgress() {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        let backup = BackupController.shared
        task.progress.totalUnitCount = Int64(max(1, backup.totalAssets))
        task.progress.completedUnitCount = Int64(min(backup.backedUpAssets, backup.totalAssets))
        task.updateTitle("Fotera photo backup", subtitle: "\(backup.backedUpAssets.formatted()) of \(backup.totalAssets.formatted()) backed up")
    }
    @available(iOS 26.0, *)
    private static func runContinued(_ task: BGTask) async {
        guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
        continuedTask = task; continuedRequested = false
        let backup = BackupController.shared
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--continued-backup-test"), let client = backup.client {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("continued-test.txt")
            try? "GRANTED: iOS continued processing task".write(to: file, atomically: true, encoding: .utf8)
            task.progress.totalUnitCount = 1
            await DevelopmentVerification.run(client: client)
            task.progress.completedUnitCount = 1
            continuedTask = nil; continuedRequested = false
            task.setTaskCompleted(success: true)
            return
        }
        #endif
        task.expirationHandler = { Task { @MainActor in backup.pause() } }
        guard backup.preferences.enabled, backup.isAttached else { cancelContinuedBackup(); return }
        updateContinuedProgress()
        backup.start()
        await backup.waitUntilIdle()
        guard continuedTask === task else { return }
        let success = backup.totalAssets == backup.backedUpAssets && (backup.queue?.attention.isEmpty ?? true)
        continuedTask = nil; continuedRequested = false
        task.setTaskCompleted(success: success)
        schedule(backup.preferences)
    }

    private static func run(_ task: BGTask, deadline: Date?) async {
        let backup = BackupController.shared
        var finished = false
        let worker = Task { @MainActor () -> Bool in
            guard await ensureAttached(), !Task.isCancelled else { return false }
            await backup.waitForNetwork()
            guard !backup.running else { return true }
            await backup.run(deadline: deadline, background: deadline != nil, trigger: deadline == nil ? "overnight" : "refresh")
            BackupNotifier.checkStalled()
            return !Task.isCancelled && backup.queue != nil && backup.queue?.failure == nil
        }
        task.expirationHandler = {
            Task { @MainActor in
                worker.cancel()
                backup.pause()
                if !finished { finished = true; task.setTaskCompleted(success: false) }
            }
        }
        let success = await worker.value
        schedule(backup.preferences)
        if !finished { finished = true; task.setTaskCompleted(success: success) }
    }
}

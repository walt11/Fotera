import Foundation
import UIKit
import UserNotifications

/// The response of a background upload, persisted so it survives app termination.
struct UploadReceipt: Codable {
    let data: Data
    let status: Int
    let error: String?
    var cancelled: Bool? = nil

    enum Outcome {
        case uploaded(Int), sessionExpired, server(Int), failed(String), cancelled
    }
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TransferReceipts", isDirectory: true)
    }
    static func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    static func read(_ id: UUID) -> UploadReceipt? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
    func save(_ id: UUID) throws {
        let target = Self.url(id)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    var outcome: Outcome {
        if cancelled == true { return .cancelled }
        if let error { return .failed(error) }
        guard status == 200 else { return .failed("The NAS returned HTTP \(status).") }
        struct Result: Decodable { let id: Int?; let unit_id: Int? }
        guard let envelope = try? JSONDecoder().decode(Envelope<Result>.self, from: data) else { return .failed("The NAS returned an unexpected response.") }
        guard envelope.success else {
            let code = envelope.error?.code ?? -1
            return [106, 107, 119].contains(code) ? .sessionExpired : .server(code)
        }
        guard let id = envelope.data?.id ?? envelope.data?.unit_id else { return .failed("The NAS didn’t return an item ID.") }
        return .uploaded(id)
    }
    func remoteID() -> Int? { if case .uploaded(let id) = outcome { return id }; return nil }
}

/// The background session owns file transfers so they continue while Fotera is suspended or terminated.
final class BackgroundUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploads()
    static let identifier = (Bundle.main.bundleIdentifier ?? "PhotoHarbor") + ".uploads"
    private let lock = NSLock()
    private var bytes: [Int: Data] = [:]
    private var samples: [Int: (Date, Int64)] = [:]
    private var session: URLSession!
    private var completion: (() -> Void)?
    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }
    static func bodyURL(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TransferBodies", isDirectory: true).appendingPathComponent(id.uuidString + ".multipart")
    }
    func handleEvents(completion: @escaping () -> Void) {
        lock.lock(); self.completion = completion; lock.unlock()
    }
    /// Hands an upload to the system. Completion is reported through a receipt and `foteraTransferFinished`.
    func submit(request: URLRequest, body: URL, id: UUID) {
        UploadReceipt.remove(id)
        let task = session.uploadTask(with: request, fromFile: body)
        task.taskDescription = id.uuidString
        task.resume()
    }
    func cancel(_ id: UUID) async {
        for task in await session.allTasks where task.taskDescription == id.uuidString { task.cancel() }
    }
    func migrateUploads(from base: URL) async {
        for task in await session.allTasks {
            if let url = task.originalRequest?.url, url.host == base.host, url.port == base.port, url.scheme == base.scheme { task.cancel() }
        }
    }
    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }
    func activeIDs() async -> Set<UUID> {
        let tasks = await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
        return Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let now = Date(); let previous = samples[task.taskIdentifier]
        if let previous, now.timeIntervalSince(previous.0) < 1, totalBytesSent < totalBytesExpectedToSend { return }
        let speed = previous.map { Double(max(0, totalBytesSent - $0.1)) / max(0.01, now.timeIntervalSince($0.0)) } ?? 0
        samples[task.taskIdentifier] = (now, totalBytesSent)
        Task { @MainActor in UploadProgress.shared.values[id] = .init(sent: totalBytesSent, total: totalBytesExpectedToSend, speed: speed) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var accumulated = bytes[dataTask.taskIdentifier] ?? Data()
        guard accumulated.count + data.count <= 1_048_576 else { dataTask.cancel(); return }
        accumulated.append(data); bytes[dataTask.taskIdentifier] = accumulated
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        samples[task.taskIdentifier] = nil
        Task { @MainActor in UploadProgress.shared.values[id] = nil }
        let data = bytes.removeValue(forKey: task.taskIdentifier) ?? Data()
        let cancelled = (error as? URLError)?.code == .cancelled
        let receipt = UploadReceipt(data: data, status: (task.response as? HTTPURLResponse)?.statusCode ?? 0,
                                    error: cancelled ? nil : error?.localizedDescription, cancelled: cancelled)
        try? receipt.save(id)
        try? FileManager.default.removeItem(at: Self.bodyURL(id))
        DispatchQueue.main.async { NotificationCenter.default.post(name: .foteraTransferFinished, object: id) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            // All receipts are durable now. Do not acknowledge the wake before processing them.
            if UIApplication.shared.applicationState != .active {
                await BackupScheduler.continueInBackground(seconds: 20)
            }
            BackupController.shared.publishLiveActivity()
            await BackupLiveActivity.shared.flush()
            finishBackgroundEvents()
        }
    }
    /// Called once the app has processed relaunch events, so iOS can snapshot and suspend it.
    func finishBackgroundEvents() {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        DispatchQueue.main.async { callback?() }
    }
}
extension Notification.Name {
    static let foteraTransferFinished = Notification.Name("FoteraTransferFinished")
    static let foteraBackgroundEventsFinished = Notification.Name("FoteraBackgroundEventsFinished")
}
final class FoteraApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackupScheduler.register()
        _ = BackgroundUploads.shared
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }
    /// iOS relaunches Fotera when background uploads finish. Use the time to reconcile results and
    /// hand the next batch to the system so the backup keeps moving while the app stays suspended.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploads.identifier else { completionHandler(); return }
        BackgroundUploads.shared.handleEvents(completion: completionHandler)
    }
}

@MainActor final class UploadProgress: ObservableObject {
    struct Value { let sent: Int64; let total: Int64; let speed: Double }
    static let shared = UploadProgress()
    @Published var values: [UUID: Value] = [:]
    func summary(ids: Set<UUID>) -> String? {
        let active = values.filter { ids.contains($0.key) }.map(\.value)
        guard !active.isEmpty else { return nil }
        let sent = active.reduce(Int64(0)) { $0 + $1.sent }; let total = active.reduce(Int64(0)) { $0 + max(0, $1.total) }
        let speed = active.reduce(0.0) { $0 + $1.speed }
        let format: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "\(format(sent)) of \(format(total)) · \(format(Int64(speed)))/s"
    }
}

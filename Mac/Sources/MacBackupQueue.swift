import AppKit
import Combine
import UniformTypeIdentifiers
import ImageIO

struct MacTransfer: Codable, Identifiable {
    enum State: String, Codable { case queued, working, complete, failed }
    let id: UUID
    var filename: String
    let digest: String
    let size: Int64
    let folder: String
    let shared: Bool
    var state: State = .queued
    var message: String = "Waiting"
    var remoteID: Int? = nil
    var localAssetID: String? = nil
    var localVersion: Double? = nil
    var resourceKey: String? = nil
    var created: Date? = nil
    var retryable:Bool? = nil
}
@MainActor final class MacBackupQueue: ObservableObject {
    @Published private(set) var records: [MacTransfer] = []
    @Published private(set) var running = false
    @Published private(set) var paused = false
    @Published var error: String?
    @Published var yearMonth = true
    var links: [UploadPhotoLink] { records.compactMap { record in
        guard record.state == .complete, let id = record.remoteID, let asset = record.localAssetID else {return nil}
        return UploadPhotoLink(remoteID:id,localID:asset,shared:record.shared,created:record.created ?? .distantPast)
    } }
    @Published var expectedResources: [String:Set<String>] = [:] {didSet {scheduleCounts()}}
    @Published private(set) var totalPhotos = 0
    @Published private(set) var completedPhotos = 0
    private var countTask:Task<Void,Never>?
    private var countGeneration = UUID()
    private var transferStore:MacTransferStore?
    @Published private(set) var uploadFraction: Double = 0
    var catalog: [RemotePhoto] = []
    var catalogShared = false
    @Published private(set) var watchedFolder = ""
    @Published var watchEnabled = false { didSet { if !account.isEmpty { UserDefaults.standard.set(watchEnabled,forKey:"watch.enabled." + LibraryCache.hash(account)) }; configureWatch() } }
    private var watchTask: Task<Void,Never>?
    private var enqueueing = false
    private var watchedVersions: [String:String] = [:]
    private var watchDestination = "/"
    private var watchShared = false
    private var watchYearMonth = true
    var didFinish: (() -> Void)?
    private var account = ""
    private var client: DSMClient?
    private var worker: Task<Void,Never>?
    private var root: URL { MacFiles.support.appendingPathComponent("Transfers/" + LibraryCache.hash(account)) }
    private func source(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    func attach(account: String, client: DSMClient) {
        self.account = account; self.client = client
        paused = UserDefaults.standard.bool(forKey:"backup.paused." + LibraryCache.hash(account))
        watchedVersions = [:]; expectedResources = [:]
        do {
            let store = try MacTransferStore(directory:root)
            var saved = try store.load()
            if saved.isEmpty, let data = try? Data(contentsOf:root.appendingPathComponent("queue.json")) {
                saved = try JSONDecoder().decode([MacTransfer].self,from:data)
                try store.importLegacy(saved)
            }
            transferStore = store
            records = saved.map {var record = $0; if record.state == .working {record.state = .queued}; return record}
            for record in records where record.state == .queued {try store.save(record)}
            scheduleCounts()
        } catch {self.error = error.localizedDescription; self.client = nil; return}
        let defaults = UserDefaults.standard, key = LibraryCache.hash(account)
        watchedFolder = defaults.string(forKey:"watch.name." + key) ?? ""
        watchDestination = defaults.string(forKey:"watch.destination." + key) ?? "/"
        watchShared = defaults.bool(forKey:"watch.shared." + key)
        yearMonth = defaults.object(forKey:"watch.yearMonth." + key) as? Bool ?? true; watchYearMonth = yearMonth
        watchEnabled = defaults.bool(forKey:"watch.enabled." + key)
        configureWatch()
    }
    func detach() async {
        watchTask?.cancel(); watchTask = nil
        worker?.cancel(); await worker?.value; worker = nil; client = nil; catalog = []; records = []; transferStore = nil; countTask?.cancel(); countGeneration = UUID(); completedPhotos = 0; totalPhotos = 0; account = ""
    }
    private func save(_ record:MacTransfer) throws {
        guard let transferStore else {throw FeatureError.message("Backup history is unavailable.")}
        try transferStore.save(record); scheduleCounts()
    }
    private func scheduleCounts() {
        countTask?.cancel(); let token = UUID(); countGeneration = token
        let records = records, expected = expectedResources
        countTask = Task {
            let result = await Task.detached(priority:.utility) {MacBackupProgress.counts(records:records,expected:expected)}.value
            guard !Task.isCancelled, countGeneration == token else {return}
            completedPhotos = result.complete; totalPhotos = result.total
        }
    }
    func chooseFiles(folder: String, shared: Bool) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.image,.movie]
        guard panel.runModal() == .OK else { return }
        let files = panel.urls
        Task { await enqueue(files,folder:folder,shared:shared) }
    }
    func enqueue(_ files: [URL], folder: String, shared: Bool, local: MacLocalResource? = nil, organizeByDate: Bool? = nil) async {
        let expected = account
        while enqueueing {do {try await Task.sleep(for:.milliseconds(100))} catch {return}}
        guard client != nil, expected == account, !Task.isCancelled else {return}
        enqueueing = true; defer {enqueueing = false}; let dated = organizeByDate ?? yearMonth
        error = nil
        do {
            for file in files {
                let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
                let values = try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.contentModificationDateKey])
                guard values.isRegularFile == true else { continue }
                let digest = try await Task.detached(priority:.utility) { try MacFiles.digest(file) }.value
                guard expected == account else { return }
                if let index = records.firstIndex(where:{$0.digest == digest && $0.shared == shared && (local == nil || $0.localAssetID == local?.assetID)}) {
                    if let local {records[index].localAssetID = local.assetID; records[index].localVersion = local.version; records[index].resourceKey = local.key; records[index].created = Date(); try save(records[index])}
                    continue
                }
                var destination = folder
                if dated {
                    // Prefer the embedded capture date; use modification date only when metadata is absent.
                    let modified = values.contentModificationDate ?? Date()
                    let date = local?.captureDate ?? MacCaptureDate.read(file) ?? modified.addingTimeInterval(Double(TimeZone.current.secondsFromGMT(for:modified)))
                    let parts = PhotoTime.calendar.dateComponents([.year,.month],from:date)
                    destination = (folder == "/" ? "" : folder.trimmingCharacters(in:CharacterSet(charactersIn:"/"))) + String(format:"/%04d/%02d",parts.year!,parts.month!)
                    if !destination.hasPrefix("/") { destination = "/" + destination }
                }
                var record = MacTransfer(id:UUID(),filename:file.lastPathComponent,digest:digest,size:Int64(values.fileSize ?? 0),folder:destination,shared:shared)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                try FileManager.default.copyItem(at:file,to:source(record.id))
                if let local {record.localAssetID = local.assetID; record.localVersion = local.version; record.resourceKey = local.key; record.created = Date()}
                records.append(record); try save(record)
            }
            if !paused { start() }
        } catch { self.error = error.localizedDescription }
    }
    func chooseWatchFolder(destination: String, shared: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            let defaults = UserDefaults.standard, key = LibraryCache.hash(account)
            defaults.set(data,forKey:"watch.bookmark." + key); defaults.set(url.lastPathComponent,forKey:"watch.name." + key)
            defaults.set(destination,forKey:"watch.destination." + key); defaults.set(shared,forKey:"watch.shared." + key); defaults.set(yearMonth,forKey:"watch.yearMonth." + key)
            watchedFolder = url.lastPathComponent; watchDestination = destination; watchShared = shared; watchYearMonth = yearMonth; watchEnabled = true
        } catch { self.error = error.localizedDescription }
    }
    private func configureWatch() {
        watchTask?.cancel(); watchTask = nil
        guard watchEnabled, client != nil else { return }
        let expected = account
        watchTask = Task {
            while !Task.isCancelled, expected == account {
                await scanWatchFolder()
                do { try await Task.sleep(for:.seconds(60)) } catch { return }
            }
        }
    }
    private func scanWatchFolder() async {
        guard !enqueueing, !running, let data = UserDefaults.standard.data(forKey:"watch.bookmark." + LibraryCache.hash(account)) else { return }
        let expected = account
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
            guard !stale, url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            defer { url.stopAccessingSecurityScopedResource() }
            let files = try await Task.detached(priority:.utility) {
                let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey,.contentTypeKey,.contentModificationDateKey]
                guard let enumerator = FileManager.default.enumerator(at:url,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { return [URL]() }
                var result: [URL] = []
                while let file = enumerator.nextObject() as? URL {
                    try Task.checkCancellation()
                    let values = try file.resourceValues(forKeys:Set(keys))
                    guard values.isSymbolicLink != true, values.isRegularFile == true, let type = values.contentType,
                        type.conforms(to:.image) || type.conforms(to:.movie),
                        Date().timeIntervalSince(values.contentModificationDate ?? Date()) > 60 else { continue }
                    result.append(file)
                }
                return result
            }.value
            guard !Task.isCancelled, expected == account else { return }
            var versions: [String:String] = [:]
            let changed = files.filter { file in
                guard let values = try? file.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else { return false }
                let version = "\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                versions[file.path] = version
                return watchedVersions[file.path] != version
            }
            await enqueue(changed,folder:watchDestination,shared:watchShared,organizeByDate:watchYearMonth)
            if error == nil { watchedVersions = versions }
        } catch { if !isCancelledRequest(error) { self.error = "Choose the backup folder again. " + error.localizedDescription; watchEnabled = false } }
    }
    func pause() { paused = true; UserDefaults.standard.set(true,forKey:"backup.paused." + LibraryCache.hash(account)); worker?.cancel() }
    func retry() {
        do {
            for index in records.indices where records[index].state == .failed {
                records[index].state = .queued; records[index].message = "Waiting"; try save(records[index])
            }
            start()
        } catch {self.error = error.localizedDescription}
    }
    func retryNetworkFailures() {
        guard !paused else {return}
        do {
            for index in records.indices where records[index].state == .failed && records[index].retryable == true {
                records[index].state = .queued; records[index].message = "Waiting for connection"; try save(records[index])
            }
            start()
        } catch {self.error = error.localizedDescription}
    }
    func start() {
        guard worker == nil, records.contains(where:{$0.state == .queued}), let client else { return }
        paused = false; UserDefaults.standard.set(false,forKey:"backup.paused." + LibraryCache.hash(account))
        running = true
        MacWidgetWriter.backup(self)
        worker = Task {
            await countTask?.value
            let completedBefore = completedPhotos
            defer {
                running = false; worker = nil; didFinish?(); MacWidgetWriter.backup(self)
                if !Task.isCancelled, completedPhotos == totalPhotos {MacNotifications.shared.completed(completedPhotos - completedBefore)}
            }
            while let index = records.firstIndex(where:{$0.state == .queued}) {
                if Task.isCancelled { break }
                do {
                    records[index].state = .working; records[index].message = "Checking NAS"; try save(records[index])
                    var attempts = 0
                    while true {
                        do {records[index].remoteID = try await transfer(index,client:client); break}
                        catch {
                            guard MacBackupRetry.isTransient(error), attempts < 2 else {throw error}
                            attempts += 1; records[index].message = "Reconnecting…"
                            try await Task.sleep(for:.seconds(attempts == 1 ? 2 : 8))
                            await client.refreshConnectionRoute()
                        }
                    }
                    records[index].retryable = false
                    records[index].state = .complete; records[index].message = "Verified on NAS"; try save(records[index])
                    try? FileManager.default.removeItem(at:source(records[index].id))
                } catch {
                    records[index].retryable = MacBackupRetry.isTransient(error)
                    records[index].state = isCancelledRequest(error) ? .queued : .failed
                    records[index].message = isCancelledRequest(error) ? "Paused" : error.localizedDescription
                    do { try save(records[index]) } catch { self.error = error.localizedDescription; break }
                    if isCancelledRequest(error) { break }
                }
            }
            await countTask?.value
        }
    }
    private func matches(_ photo: RemotePhoto, record: MacTransfer, client: DSMClient) async throws -> Bool {
        let file = photo.isLive ? try await client.livePackage(photo,shared:record.shared) : try await client.original(photo,shared:record.shared)
        defer { try? FileManager.default.removeItem(at:file) }
        return try await Task.detached(priority:.utility) { try MacFiles.originalDigests(file).contains(record.digest) }.value
    }
    private func transfer(_ index: Int, client: DSMClient) async throws -> Int {
        var record = records[index]
        let base = try await client.folder(path:"/",shared:record.shared)
        _ = try await client.ensureBackupFolders(base:base,components:record.folder.split(separator:"/").map(String.init),shared:record.shared)
        // Search both destination and size candidates. Filenames alone never prove a duplicate.
        if let existing = try await client.findItem(named:record.filename,inFolder:record.folder,shared:record.shared), try await matches(existing,record:record,client:client) { return existing.id }
        for candidate in catalog where catalogShared == record.shared && candidate.filesize == record.size {
            try Task.checkCancellation()
            if try await matches(candidate,record:record,client:client) { return candidate.id }
        }
        if let existing = try await client.findItem(named:record.filename,inFolder:record.folder,shared:record.shared) {
            if try await matches(existing,record:record,client:client) { return existing.id }
            let name = record.filename as NSString
            record.filename = name.deletingPathExtension + "-" + record.id.uuidString.prefix(8) + "." + name.pathExtension
            records[index].filename = record.filename; try save(records[index])
        }
        records[index].message = "Uploading"
        let body = BackgroundUploads.bodyURL(record.id)
        defer { try? FileManager.default.removeItem(at:body) }
        let request = try await client.makeUploadRequest(source:source(record.id),filename:record.filename,folder:record.folder,shared:record.shared,transferID:record.id,wifiOnly:false)
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForResource = 3600
        uploadFraction = 0
        let session = URLSession(configuration:configuration,delegate:MacUploadProgress { [weak self] value in Task { @MainActor in self?.uploadFraction = value } },delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (data,response) = try await session.upload(for:request,fromFile:body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ConnectionError.invalidResponse }
        let result = try JSONDecoder().decode(Envelope<EmptyPayload>.self,from:data)
        guard result.success else { throw ConnectionError.server(result.error?.code ?? -1) }
        records[index].message = "Verifying original"
        for attempt in 0..<6 {
            try Task.checkCancellation()
            if let photo = try await client.findItem(named:record.filename,inFolder:record.folder,shared:record.shared,includeLiveCompanion:true), try await matches(photo,record:record,client:client) { return photo.id }
            if attempt < 5 { try await Task.sleep(for:.seconds(3)) }
        }
        throw MacBackupError.verification
    }
}
enum MacBackupError: LocalizedError {
    case verification
    var errorDescription: String? { "The uploaded original could not be verified. Retry to check the NAS before uploading again." }
}
enum MacCaptureDate {
    static func read(_ file: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String:Any], let value = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = PhotoTime.calendar.timeZone; formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from:value)
    }
}

struct MacLocalResource: Sendable {let assetID:String; let version:Double?; let key:String; let captureDate:Date?}
final class MacUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress:@Sendable (Double)->Void
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    init(progress:@escaping @Sendable (Double)->Void) {self.progress = progress}
    func urlSession(_ session:URLSession,task:URLSessionTask,didSendBodyData bytesSent:Int64,totalBytesSent:Int64,totalBytesExpectedToSend:Int64) {guard totalBytesExpectedToSend > 0 else {return}; lock.lock(); let now = Date(); let update = now.timeIntervalSince(lastUpdate) > 0.25 || totalBytesSent == totalBytesExpectedToSend; if update {lastUpdate = now}; lock.unlock(); if update {progress(min(1,Double(totalBytesSent)/Double(totalBytesExpectedToSend)))}}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {completionHandler(nil)}
}


enum MacBackupRetry {
    static func isTransient(_ error:Error) -> Bool {
        guard let error = error as? URLError else {return false}
        return [.timedOut,.cannotFindHost,.cannotConnectToHost,.networkConnectionLost,.dnsLookupFailed,.notConnectedToInternet,.resourceUnavailable].contains(error.code)
    }
}

import Foundation
import Security

struct APIInfo: Codable {
    let path: String
    let minVersion: Int
    let maxVersion: Int
}
struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIError?
}
struct APIError: Decodable { let code: Int }
struct EmptyPayload: Decodable {}

enum ConnectionError: LocalizedError, Equatable {
    case invalidAddress, invalidResponse, server(Int), unavailable, http(Int), quickConnect, signedOut
    var isSessionExpired: Bool {
        if case .server(let code) = self { return [106, 107, 119].contains(code) }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .quickConnect: return "Enter a QuickConnect ID or https://quickconnect.to/your-id."
        case .http(let code): return "The server returned HTTP \(code). Check the DSM address and port."
        case .invalidAddress: return "Enter an HTTPS address, a local HTTP address such as http://192.168.1.20:5000, or a QuickConnect ID."
        case .invalidResponse: return "The NAS returned an unexpected response."
        case .signedOut: return "You’re signed out. Sign in again."
        case .unavailable: return "This NAS doesn’t support that operation."
        case .server(let code):
            switch code {
            case 101, 120: return "The NAS rejected the request parameters (\(code))."
            case 103: return "This Synology Photos version doesn’t support that operation."
            case 105, 160, 803: return "Your account doesn’t have permission for this (\(code))."
            case 106, 107, 119: return "Your NAS session expired. Sign in again."
            case 620: return "Synology Photos doesn’t support this file type."
            case 621, 642: return "The destination folder no longer exists."
            case 801: return "Shared Space is unavailable for this account."
            default: return "The NAS returned error \(code)."
            }
        }
    }
}

enum AuthError: LocalizedError {
    case badCredentials, otpRequired, otpInvalid, disabled, blocked, passwordExpired, enforce2FA, other(Int)
    init(code: Int) {
        switch code {
        case 400: self = .badCredentials
        case 401: self = .disabled
        case 403: self = .otpRequired
        case 404: self = .otpInvalid
        case 406: self = .enforce2FA
        case 407: self = .blocked
        case 408, 409, 410: self = .passwordExpired
        default: self = .other(code)
        }
    }
    var errorDescription: String? {
        switch self {
        case .badCredentials: return "Incorrect username or password."
        case .otpRequired: return "Enter the code from your authenticator app."
        case .otpInvalid: return "That verification code didn’t work. Try the current code."
        case .disabled: return "This DSM account is disabled."
        case .blocked: return "Too many failed attempts. This IP address is temporarily blocked by DSM."
        case .passwordExpired: return "Your DSM password has expired. Change it in DSM, then sign in."
        case .enforce2FA: return "This account must set up 2-step verification in DSM first."
        case .other(let code): return "Sign-in failed (DSM error \(code))."
        }
    }
}

final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ThumbnailSize: String, Sendable { case sm, m, xl }

enum ItemFilter: Hashable, Sendable {
    case all, favorites, folder(Int), album(Int), person(Int), place(Int)
}

extension Notification.Name {
    static let foteraSessionExpired = Notification.Name("FoteraSessionExpired")
    static let foteraPeopleChanged = Notification.Name("FoteraPeopleChanged")
}

actor DSMClient {
    private(set) var base: URL
    /// The HTTPS endpoint the account was opened with. Passwords are only sent here when a LAN HTTP route is active.
    private let secureBase: URL?
    private var routeChecked = Date.distantPast
    private var selectingRoute = false
    nonisolated let address: String
    private let session: URLSession
    private var sid: String?
    private var username = ""
    private var capabilities: [String: APIInfo] = [:]
    private var credentials: Credentials?
    private var reauthTask: Task<Void, Error>?
    private var folderIDs: [String: Int] = [:]
    static let pageSize = 500

    static func normalize(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw ConnectionError.invalidAddress }
        if url.scheme?.lowercased() == "http", !ConnectionAddress.isLAN(host) { throw ConnectionError.invalidAddress }
        if let port = url.port, !(1...65535).contains(port) { throw ConnectionError.invalidAddress }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ConnectionError.invalidAddress }
        components.scheme = url.scheme?.lowercased(); components.path = ""
        guard let normalized = components.url else { throw ConnectionError.invalidAddress }
        return normalized
    }
    /// `preferCached` skips QuickConnect resolution (several network round trips) when a verified endpoint is saved,
    /// which keeps short background wakes within iOS's time limit. Route selection still runs afterwards.
    static func open(address: String, cachedEndpoint: String? = nil, preferCached: Bool = false) async throws -> DSMClient {
        if let id = ConnectionAddress.quickConnectID(address) {
            if preferCached, let cachedEndpoint, let saved = try? Self.normalize(cachedEndpoint), saved.scheme == "https" {
                return try DSMClient(address: "quickconnect://" + id, resolvedBase: saved)
            }
            let endpoint: URL
            do { endpoint = try await QuickConnectResolver.resolve(id) }
            catch {
                if isCancelledRequest(error) { throw error }
                guard let cachedEndpoint, let saved = try? Self.normalize(cachedEndpoint), saved.scheme == "https" else { throw error }
                // This endpoint comes only from the Keychain session, saved after successful verified resolution.
                endpoint = saved
            }
            return try DSMClient(address: "quickconnect://" + id, resolvedBase: endpoint)
        }
        return try DSMClient(address: address)
    }
    init(address: String, resolvedBase: URL? = nil) throws {
        base = try resolvedBase ?? Self.normalize(address)
        secureBase = base.scheme == "https" ? base : nil
        self.address = resolvedBase == nil ? base.absoluteString : address
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }

    func configureRoutes(lan: String, quickConnect: String, enabled: Bool) async throws {
        let local = lan.isEmpty ? nil : try Self.normalize(lan)
        if let local, !ConnectionAddress.isLAN(local.host ?? "") { throw ConnectionError.invalidAddress }
        guard quickConnect.isEmpty || ConnectionAddress.quickConnectID(quickConnect) != nil else { throw ConnectionError.invalidAddress }
        let identity = enabled ? try await Self.nasIdentity(base) : ""
        let profile = RouteProfile(lan: local?.absoluteString ?? "", quickConnect: quickConnect, enabled: enabled, identity: identity)
        UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: "routes." + LibraryCache.hash(address))
        routeChecked = .distantPast
        await selectPreferredRoute()
    }
    static func nasIdentity(_ base: URL) async throws -> String {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 2
        let probe = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        defer { probe.invalidateAndCancel() }
        var url = URLComponents(url: base.appendingPathComponent("webman/pingpong.cgi"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "action", value: "cors"), URLQueryItem(name: "quickconnect", value: "true")]
        let (data, response) = try await probe.data(from: url.url!)
        struct Ping: Decodable { let success: Bool; let ezid: String }
        let result = try JSONDecoder().decode(Ping.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, result.success, !result.ezid.isEmpty else { throw ConnectionError.invalidResponse }
        return result.ezid
    }
    func refreshConnectionRoute() async { routeChecked = .distantPast; await selectPreferredRoute() }
    private func selectPreferredRoute() async {
        guard !selectingRoute, Date().timeIntervalSince(routeChecked) > 30 else { return }
        routeChecked = Date()
        guard let data = UserDefaults.standard.data(forKey: "routes." + LibraryCache.hash(address)),
              let profile = try? JSONDecoder().decode(RouteProfile.self, from: data), profile.enabled else { return }
        selectingRoute = true
        defer { selectingRoute = false }
        if let local = try? Self.normalize(profile.lan), let identity = try? await Self.nasIdentity(local), identity == profile.identity {
            await switchBase(to: local); return
        }
        if let identity = try? await Self.nasIdentity(base), identity == profile.identity { return }
        if let canonical = try? Self.normalize(address), canonical != base,
           let identity = try? await Self.nasIdentity(canonical), identity == profile.identity {
            await switchBase(to: canonical); return
        }
        if let id = ConnectionAddress.quickConnectID(profile.quickConnect), let remote = try? await QuickConnectResolver.resolve(id),
           let identity = try? await Self.nasIdentity(remote), identity == profile.identity { await switchBase(to: remote) }
    }
    /// Uploads already in flight keep their original route unless it was a LAN address we just lost,
    /// so a large video isn't restarted every time the preferred route changes.
    private func switchBase(to new: URL) async {
        guard new != base else { return }
        let previous = base
        base = new
        if ConnectionAddress.isLAN(previous.host ?? ""), !ConnectionAddress.isLAN(new.host ?? "") {
            await BackgroundUploads.shared.migrateUploads(from: previous)
        }
    }
    // MARK: Transport

    private func makeRequest(_ path: String, _ fields: [String: String], via override: URL? = nil) async throws -> URLRequest {
        // Choose a route once before the first request; afterwards re-check in the background so
        // probes of an unreachable LAN address never stall browsing.
        if override == nil {
            if routeChecked == .distantPast { await selectPreferredRoute() }
            else if Date().timeIntervalSince(routeChecked) > 120 { Task { await self.selectPreferredRoute() } }
        }
        guard !path.contains(".."), !path.contains(":"), !path.hasPrefix("/") else { throw ConnectionError.invalidResponse }
        var request = URLRequest(url: (override ?? base).appendingPathComponent("webapi").appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        return request
    }
    private static let formAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    private static func formEncode(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: formAllowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: formAllowed)!)"
        }.joined(separator: "&")
    }
    private func send(_ path: String, _ fields: [String: String], via override: URL? = nil) async throws -> Data {
        let (data, response) = try await session.data(for: makeRequest(path, fields, via: override))
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
        guard http.statusCode == 200 else { throw ConnectionError.http(http.statusCode) }
        return data
    }
    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let result: Envelope<T>
        do { result = try JSONDecoder().decode(Envelope<T>.self, from: data) }
        catch { throw ConnectionError.invalidResponse }
        guard result.success else { throw ConnectionError.server(result.error?.code ?? -1) }
        if let payload = result.data { return payload }
        if let empty = EmptyPayload() as? T { return empty }
        throw ConnectionError.invalidResponse
    }
    func info(_ api: String, _ version: Int) throws -> APIInfo {
        guard let info = capabilities[api], info.minVersion <= version, info.maxVersion >= version else { throw ConnectionError.unavailable }
        return info
    }
    func supports(_ api: String, version: Int = 1) -> Bool {
        guard let info = capabilities[api] else { return false }
        return info.minVersion <= version && info.maxVersion >= version
    }
    private func discover() async throws {
        capabilities = try Self.decode(try await send("query.cgi", ["api": "SYNO.API.Info", "version": "1", "method": "query", "query": "all"]), as: [String: APIInfo].self)
    }

    /// Runs an operation with the current session, re-authenticating once if DSM reports it expired.
    private func authorized<R>(_ operation: (String) async throws -> R) async throws -> R {
        if let reauthTask { try await reauthTask.value }
        guard let current = sid else { throw ConnectionError.signedOut }
        if capabilities.isEmpty { try await discover() }
        do { return try await operation(current) }
        catch let error as ConnectionError where error.isSessionExpired {
            try await reauthenticate(expired: current)
            guard let fresh = sid else { throw ConnectionError.signedOut }
            return try await operation(fresh)
        }
    }
    func call<T: Decodable>(_ api: String, _ version: Int, _ method: String, _ fields: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        try await authorized { sid in
            let info = try self.info(api, version)
            var parameters = fields
            parameters["api"] = api; parameters["version"] = String(version); parameters["method"] = method; parameters["_sid"] = sid
            return try Self.decode(try await self.send(info.path, parameters), as: T.self)
        }
    }
    private func reauthenticate(expired: String) async throws {
        if let reauthTask { return try await reauthTask.value }
        guard sid == expired else { return }
        guard let credentials else {
            await MainActor.run { NotificationCenter.default.post(name: .foteraSessionExpired, object: nil) }
            throw ConnectionError.server(119)
        }
        let task = Task { _ = try await self.login(credentials, otp: "") }
        reauthTask = task
        defer { reauthTask = nil }
        do { try await task.value }
        catch {
            await MainActor.run { NotificationCenter.default.post(name: .foteraSessionExpired, object: nil) }
            throw error
        }
    }
    /// Forces a new session, used when a background upload reports that its session cookie expired.
    func renewSession() async throws {
        guard let sid else { throw ConnectionError.signedOut }
        try await reauthenticate(expired: sid)
    }

    // MARK: Authentication

    private func login(_ account: Credentials, otp: String) async throws -> Credentials {
        if capabilities.isEmpty { try await discover() }
        guard let auth = capabilities["SYNO.API.Auth"], auth.minVersion <= 6, auth.maxVersion >= 6 else { throw ConnectionError.unavailable }
        struct Login: Decodable { let sid: String; let did: String? }
        var fields = ["api": "SYNO.API.Auth", "version": "6", "method": "login", "account": account.username,
                      "passwd": account.password, "session": "PhotoHarbor", "format": "sid"]
        if !otp.isEmpty {
            fields["otp_code"] = otp
            fields["enable_device_token"] = "yes"
            fields["device_name"] = "Fotera iOS"
        } else if let device = account.deviceID, !device.isEmpty {
            fields["device_id"] = device
            fields["device_name"] = "Fotera iOS"
        }
        // Never send the password over an automatically selected HTTP LAN route when an HTTPS endpoint exists.
        let authBase = base.scheme == "http" ? secureBase : nil
        let result: Login
        do { result = try Self.decode(try await send(auth.path, fields, via: authBase), as: Login.self) }
        catch ConnectionError.server(let code) { throw AuthError(code: code) }
        sid = result.sid
        username = account.username
        var updated = account
        if let did = result.did, !did.isEmpty { updated.deviceID = did }
        if credentials != nil {
            credentials = updated
            try? CredentialStore.save(updated, address: address)
        }
        try? SessionStore.save(SavedSession(address: address, username: account.username, sid: result.sid, resolvedAddress: ConnectionAddress.quickConnectID(address) == nil ? nil : base.absoluteString), background: credentials != nil)
        return updated
    }
    func signIn(username: String, password: String, otp: String, remember: Bool) async throws {
        let previousDevice = CredentialStore.load().flatMap { $0.address == address && $0.username == username ? $0.deviceID : nil }
        let account = Credentials(address: address, username: username, password: password, deviceID: previousDevice)
        credentials = remember ? account : nil
        do {
            let updated = try await login(account, otp: otp)
            if remember { try CredentialStore.save(updated, address: address) } else { try? CredentialStore.clear() }
        } catch {
            credentials = nil
            throw error
        }
    }
    func restore(_ saved: SavedSession, credentials stored: Credentials?) async throws {
        guard saved.address == address || (try? Self.normalize(saved.address).absoluteString) == address else { throw ConnectionError.invalidAddress }
        sid = saved.sid
        username = saved.username
        credentials = stored.flatMap { $0.address == address && $0.username == saved.username ? $0 : nil }
        try await discover()
        if ConnectionAddress.quickConnectID(address) != nil {
            try? SessionStore.save(SavedSession(address: address, username: saved.username, sid: saved.sid, resolvedAddress: base.absoluteString), background: credentials != nil)
        }
    }
    var keepsCredentials: Bool { credentials != nil }
    func forgetCredentials() throws {
        try CredentialStore.clear()
        credentials = nil
        reauthTask?.cancel()
        if let saved = try SessionStore.load() { try SessionStore.save(saved, background: false) }
    }
    func disconnect() async {
        defer { sid = nil; credentials = nil; session.invalidateAndCancel() }
        guard let sid, let auth = capabilities["SYNO.API.Auth"] else { return }
        _ = try? await send(auth.path, ["api": "SYNO.API.Auth", "version": "6", "method": "logout", "session": "PhotoHarbor", "_sid": sid])
    }
    func currentSessionID() -> String? { sid }

    // MARK: Browsing

    func space(_ shared: Bool, _ name: String) -> String { (shared ? "SYNO.FotoTeam." : "SYNO.Foto.") + name }

    func items(_ filter: ItemFilter, shared: Bool, offset: Int, limit: Int = DSMClient.pageSize, withLocation: Bool = false) async throws -> [RemotePhoto] {
        struct Page: Decodable { let list: [RemotePhoto] }
        if case .album = filter, shared { throw ConnectionError.unavailable }
        let api = space(shared, "Browse.Item")
        let rich = supports(api, version: 7)
        var fields = ["offset": String(offset), "limit": String(limit)]
        var version = 2
        switch filter {
        case .favorites:
            guard rich else { throw ConnectionError.unavailable }
            version = 7; fields["favorite_only"] = "true"
        case .folder(let id): fields["folder_id"] = String(id)
        case .album(let id): fields["album_id"] = String(id)
        case .person(let id): fields["person_id"] = String(id)
        case .place(let id): fields["geocoding_id"] = String(id)
        case .all: break
        }
        if case .album = filter {} else { fields["sort_by"] = "takentime"; fields["sort_direction"] = "desc" }
        if withLocation && rich { version = 7; fields["additional"] = "[\"thumbnail\",\"gps\",\"video_meta\"]" }
        else { fields["additional"] = "[\"thumbnail\"]" }
        return try await call(api, version, "list", fields, as: Page.self).list
    }
    func count(shared: Bool) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await call(space(shared, "Browse.Item"), 1, "count", as: Count.self).count
    }
    func search(keyword: String, shared: Bool, offset: Int, limit: Int = 100) async throws -> [RemotePhoto] {
        struct Page: Decodable { let list: [RemotePhoto] }
        return try await call(space(shared, "Search.Search"), 1, "list_item", ["keyword": keyword, "offset": String(offset),
            "limit": String(limit), "additional": "[\"thumbnail\"]"], as: Page.self).list
    }
    func albums(offset: Int, limit: Int = 100) async throws -> [RemoteAlbum] {
        struct Page: Decodable { let list: [RemoteAlbum] }
        return try await call("SYNO.Foto.Browse.Album", 1, "list", ["offset": String(offset), "limit": String(limit),
            "additional": "[\"thumbnail\"]"], as: Page.self).list
    }
    func allAlbums() async throws -> [RemoteAlbum] {
        var result: [RemoteAlbum] = []; var seen = Set<Int>(); var offset = 0
        while true {
            let page = try await albums(offset: offset)
            result += page.filter { seen.insert($0.id).inserted }
            offset += page.count
            if page.count < 100 { return result }
        }
    }
    func people(shared: Bool, offset: Int = 0, limit: Int = 200) async throws -> [RemoteGroup] {
        struct Page: Decodable { let list: [RemoteGroup] }
        return try await call(space(shared, "Browse.Person"), 1, "list", ["offset": String(offset), "limit": String(limit),
            "show_more": "true", "show_hidden": "false", "additional": "[\"thumbnail\"]"], as: Page.self).list
    }
    /// Uses Person.set, not Album.set_name. Read back the name before reporting success.
    func renamePerson(id: Int, name: String, shared: Bool) async throws -> RemoteGroup {
        try await mutation(space(shared, "Browse.Person"), method: "set", fields: ["id": String(id), "name": String(decoding: try JSONEncoder().encode(name), as: UTF8.self)])
        var offset = 0
        while true {
            let page = try await people(shared: shared, offset: offset)
            if let person = page.first(where: { $0.id == id }) {
                guard person.name == name else { throw ConnectionError.invalidResponse }
                return person
            }
            if page.count < 200 { throw ConnectionError.invalidResponse }
            offset += page.count
        }
    }
    func places(shared: Bool, offset: Int = 0, limit: Int = 200) async throws -> [RemoteGroup] {
        struct Page: Decodable { let list: [RemoteGroup] }
        return try await call(space(shared, "Browse.Geocoding"), 1, "list", ["offset": String(offset), "limit": String(limit),
            "additional": "[\"thumbnail\"]"], as: Page.self).list
    }
    func concepts(shared: Bool, offset: Int = 0, limit: Int = 100) async throws -> [RemoteGroup] {
        struct Page: Decodable { let list: [RemoteGroup] }
        return try await call(space(shared, "Browse.Concept"), 1, "list", ["offset": String(offset), "limit": String(limit),
            "additional": "[\"thumbnail\"]"], as: Page.self).list
    }
    func details(id: Int, shared: Bool) async throws -> ItemDetails {
        struct Page: Decodable { let list: [ItemDetails] }
        let page = try await call(space(shared, "Browse.Item"), 7, "get", ["id": "[\(id)]",
            "additional": "[\"resolution\",\"exif\",\"address\",\"description\",\"gps\",\"person\",\"favorite\",\"video_meta\",\"video_convert\"]"], as: Page.self)
        guard let item = page.list.first(where: { $0.id == id }) else { throw ConnectionError.invalidResponse }
        return item
    }
    func thumbnail(_ source: ThumbnailSource, shared: Bool, size: ThumbnailSize) async throws -> Data {
        let api = space(shared, "Thumbnail")
        return try await authorized { sid in
            let info = try self.info(api, 1)
            let data = try await self.send(info.path, ["api": api, "version": "1", "method": "get", "_sid": sid,
                "id": String(source.id), "cache_key": source.cacheKey, "type": source.kind, "size": size.rawValue])
            if data.first == UInt8(ascii: "{") {
                let failure = try? JSONDecoder().decode(Envelope<EmptyPayload>.self, from: data)
                throw ConnectionError.server(failure?.error?.code ?? -1)
            }
            return data
        }
    }
    /// A GET URL AVPlayer can stream from. The server transcodes to H.264 ("high" quality).
    func streamingURL(id: Int, shared: Bool) async throws -> URL {
        if let cached = await OfflineVault.shared.originalURL(account: address + "|" + username, shared: shared, id: id) { return cached }
        let api = space(shared, "Streaming")
        return try await authorized { sid in
            let info = try self.info(api, 2)
            var components = URLComponents(url: self.base.appendingPathComponent("webapi").appendingPathComponent(info.path), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "api", value: api), URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "method", value: "streaming"), URLQueryItem(name: "id", value: String(id)),
                URLQueryItem(name: "quality", value: "\"high\""), URLQueryItem(name: "_sid", value: sid)]
            guard let url = components.url else { throw ConnectionError.invalidResponse }
            return url
        }
    }
    func livePackage(_ photo: RemotePhoto, shared: Bool, albumID: Int? = nil, useOfflineCache: Bool = false) async throws -> URL {
        let resource = RemotePhoto(id: photo.id, filename: photo.filename + ".zip", time: photo.time, type: "photo", additional: photo.additional)
        return try await original(resource, shared: shared, albumID: albumID, useOfflineCache: useOfflineCache)
    }
    /// Downloads the original into a private temporary file. Callers own and remove the file.
    func original(_ photo: RemotePhoto, shared: Bool, albumID: Int? = nil, useOfflineCache: Bool = false) async throws -> URL {
        if useOfflineCache, let cached = try await OfflineVault.shared.copyOriginal(account: address + "|" + username, photo: photo, shared: shared) { return cached }
        let api = space(shared, "Download")
        return try await authorized { sid in
            let info = try self.info(api, 1)
            var fields = ["api": api, "version": "1", "method": "download", "_sid": sid, "item_id": "[\(photo.id)]", "force_download": "true"]
            if photo.type == "live" {
                fields.removeValue(forKey: "item_id"); fields.removeValue(forKey: "force_download")
                fields["unit_id"] = "[\(photo.additional?.thumbnail?.unit_id ?? photo.id)]"
            }
            if let albumID { fields["album_id"] = String(albumID) }
            if let key = photo.additional?.thumbnail?.cache_key { fields["cache_key"] = key }
            let (temporary, response) = try await self.session.download(for: self.makeRequest(info.path, fields))
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
            guard http.statusCode == 200 else { throw ConnectionError.http(http.statusCode) }
            if response.mimeType?.contains("json") == true {
                let failure = try? JSONDecoder().decode(Envelope<EmptyPayload>.self, from: Data(contentsOf: temporary))
                throw ConnectionError.server(failure?.error?.code ?? -1)
            }
            try Task.checkCancellation()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FoteraMedia", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = (photo.filename as NSString).pathExtension.filter { $0.isLetter || $0.isNumber }
            let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
    }

    // MARK: Folders

    func folders(shared: Bool, parent: Int, offset: Int) async throws -> [RemoteFolder] {
        struct Page: Decodable { let list: [RemoteFolder] }
        return try await call(space(shared, "Browse.Folder"), 1, "list", ["id": String(parent), "offset": String(offset), "limit": "200"], as: Page.self).list
    }
    func folder(path: String, shared: Bool) async throws -> RemoteFolder {
        struct Result: Decodable { let folder: RemoteFolder }
        let folder = try await call(space(shared, "Browse.Folder"), 2, "get",
            ["name": String(decoding: try JSONEncoder().encode(path), as: UTF8.self)], as: Result.self).folder
        folderIDs["\(shared)|\(path)"] = folder.id
        return folder
    }
    private func folderID(path: String, shared: Bool) async throws -> Int {
        if let id = folderIDs["\(shared)|\(path)"] { return id }
        return try await folder(path: path, shared: shared).id
    }
    func createFolder(parent: Int, name: String, shared: Bool) async throws -> RemoteFolder {
        struct Result: Decodable { let folder: RemoteFolder }
        return try await call(space(shared, "Browse.Folder"), 1, "create", ["target_id": String(parent),
            "name": String(decoding: try JSONEncoder().encode(name), as: UTF8.self)], as: Result.self).folder
    }
    /// Reuses existing folders; verifies each newly created folder through the tested Folder.get API.
    func ensureBackupFolders(base: RemoteFolder, components: [String], shared: Bool) async throws -> RemoteFolder {
        var current = base
        for component in components {
            try Task.checkCancellation()
            guard !component.isEmpty, !component.contains("/"), component != ".", component != ".." else { throw ConnectionError.invalidResponse }
            let path = (current.name == "/" ? "" : current.name) + "/" + component
            if let id = folderIDs["\(shared)|\(path)"] {
                current = RemoteFolder(id: id, name: path)
                continue
            }
            if let existing = try? await folder(path: path, shared: shared) {
                current = existing
            } else {
                try Task.checkCancellation()
                do { _ = try await createFolder(parent: current.id, name: component, shared: shared) }
                catch {
                    // Another client may have created it concurrently; only proceed after readback.
                    if let existing = try? await folder(path: path, shared: shared) { current = existing; continue }
                    throw error
                }
                current = try await folder(path: path, shared: shared)
            }
        }
        return current
    }

    /// Finds an item in a destination folder by filename, used to reconcile uploads whose outcome is unknown.
    func findItem(named filename: String, inFolder path: String, shared: Bool, includeLiveCompanion: Bool = false) async throws -> RemotePhoto? {
        let id = try await folderID(path: path, shared: shared)
        var offset = 0
        for _ in 0..<40 {
            let page = try await items(.folder(id), shared: shared, offset: offset)
            if let match = page.first(where: { $0.filename == filename }) { return match }
            if includeLiveCompanion, (filename as NSString).pathExtension.lowercased() == "mov",
               let match = page.first(where: { $0.isLive && ($0.filename as NSString).deletingPathExtension == (filename as NSString).deletingPathExtension }) { return match }
            if page.count < DSMClient.pageSize { return nil }
            offset += page.count
        }
        return nil
    }

    // MARK: Upload

    /// Writes a multipart body for the background session and returns the request to submit.
    func makeUploadRequest(source: URL, filename: String, folder: String, shared: Bool, transferID: UUID, wifiOnly: Bool) async throws -> URLRequest {
        let api = space(shared, "Upload.Item")
        let info = try info(api, 1)
        let destination = try await folderID(path: folder, shared: shared)
        guard let sid else { throw ConnectionError.signedOut }
        let boundary = "Fotera-" + UUID().uuidString
        let body = BackgroundUploads.bodyURL(transferID)
        try FileManager.default.createDirectory(at: body.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let output = try FileHandle(forWritingTo: body)
        do {
            let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let fields: [(String, String)] = [("api", api), ("version", "1"), ("method", "upload_to_folder"), ("duplicate", "\"ignore\""),
                ("name", String(decoding: try JSONEncoder().encode(filename), as: UTF8.self)),
                ("mtime", String(Int(modified.timeIntervalSince1970))), ("target_folder_id", String(destination))]
            for (key, value) in fields {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            let safeName = filename.map { "\"\r\n".contains($0) ? "_" : String($0) }.joined()
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4_194_304), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close()
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: body.path)
        } catch {
            try? output.close(); try? FileManager.default.removeItem(at: body); throw error
        }
        var components = URLComponents(url: base.appendingPathComponent("webapi").appendingPathComponent(info.path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api", value: api), URLQueryItem(name: "version", value: "1"), URLQueryItem(name: "method", value: "upload_to_folder")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("id=" + sid, forHTTPHeaderField: "Cookie")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.allowsCellularAccess = !wifiOnly
        request.allowsExpensiveNetworkAccess = !wifiOnly
        return request
    }

    // MARK: Mutations

    func mutation(_ api: String, method: String, version: Int = 1, fields: [String: String]) async throws {
        _ = try await call(api, version, method, fields, as: EmptyPayload.self)
    }
    func favorites(ids: [Int], shared: Bool) async throws -> [Int: Bool] {
        struct Item: Decodable {
            let id: Int
            let additional: Extra?
            struct Extra: Decodable { let favorite: Bool? }
        }
        struct Page: Decodable { let list: [Item] }
        let encoded = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        let page = try await call(space(shared, "Browse.Item"), 7, "get", ["id": encoded, "additional": "[\"favorite\"]"], as: Page.self)
        return Dictionary(page.list.map { ($0.id, $0.additional?.favorite ?? false) }, uniquingKeysWith: { a, _ in a })
    }
    func favorite(id: Int, shared: Bool) async throws -> Bool {
        guard let value = try await favorites(ids: [id], shared: shared)[id] else { throw ConnectionError.invalidResponse }
        return value
    }
    func setFavorite(ids: [Int], shared: Bool, value: Bool) async throws {
        let encoded = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        try await mutation(space(shared, "Browse.Item"), method: "set_favorite", version: 7, fields: ["id": encoded, "favorite": value ? "true" : "false"])
        let state = try await favorites(ids: ids, shared: shared)
        guard ids.allSatisfy({ state[$0] == value }) else { throw ConnectionError.invalidResponse }
    }
    func setFavorite(id: Int, shared: Bool, value: Bool) async throws { try await setFavorite(ids: [id], shared: shared, value: value) }
    func albumItemIDs(id: Int) async throws -> Set<Int> {
        var membership = Set<Int>(); var offset = 0
        while true {
            let page = try await items(.album(id), shared: false, offset: offset)
            membership.formUnion(page.map(\.id))
            if page.count < DSMClient.pageSize { return membership }
            offset += page.count
        }
    }
    func changeAlbumItems(id: Int, items: [Int], adding: Bool) async throws {
        let encoded = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        try await mutation("SYNO.Foto.Browse.NormalAlbum", method: adding ? "add_item" : "delete_item", fields: ["id": String(id), "item": encoded])
        let membership = try await albumItemIDs(id: id)
        guard items.allSatisfy({ membership.contains($0) == adding }) else { throw ConnectionError.invalidResponse }
    }
    @discardableResult
    func createAlbum(name: String, items: [Int]) async throws -> Int? {
        struct Created: Decodable { let album: RemoteAlbum? }
        let encodedName = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
        let encodedItems = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        do {
            if let id = try await call("SYNO.Foto.Browse.NormalAlbum", 1, "create", ["name": encodedName, "item": encodedItems], as: Created.self).album?.id { return id }
        } catch ConnectionError.invalidResponse {
            // Some versions return no payload; confirm by reading the album list back below.
        }
        guard let id = try await allAlbums().first(where: { $0.name == name })?.id else { throw ConnectionError.invalidResponse }
        return id
    }
    func renameAlbum(id: Int, name: String) async throws {
        try await mutation("SYNO.Foto.Browse.Album", method: "set_name", fields: ["id": String(id), "name": name])
        guard try await allAlbums().first(where: { $0.id == id })?.name == name else { throw ConnectionError.invalidResponse }
    }
    func deleteAlbum(id: Int) async throws {
        try await mutation("SYNO.Foto.Browse.Album", method: "delete", fields: ["id": "[\(id)]"])
        guard try await !allAlbums().contains(where: { $0.id == id }) else { throw ConnectionError.invalidResponse }
    }
    func albumSharing(id: Int) async throws -> AlbumSharingState {
        struct Page: Decodable { let list: [AlbumSharingState] }
        let result = try await call("SYNO.Foto.Browse.Album", 1, "get", ["id": "[\(id)]", "additional": "[\"sharing_info\"]"], as: Page.self)
        guard let state = result.list.first(where: { $0.id == id }) else { throw ConnectionError.invalidResponse }
        return state
    }
    func updateAlbumSharing(id: Int, enabled: Bool, role: String, password: String, expiration: Date?) async throws -> AlbumSharingState {
        guard ["view", "download"].contains(role) else { throw ConnectionError.invalidResponse }
        try await mutation("SYNO.Foto.Sharing.Passphrase", method: "set_shared", fields: ["policy": "\"album\"", "album_id": String(id), "enabled": enabled ? "true" : "false"])
        if enabled {
            let initial = try await albumSharing(id: id)
            guard let passphrase = initial.additional?.sharing_info?.passphrase ?? initial.passphrase, !passphrase.isEmpty else { throw ConnectionError.invalidResponse }
            let permission: [[String: Any]] = [["action": "update", "role": role, "member": ["type": "public"]]]
            try await mutation("SYNO.Foto.Sharing.Passphrase", method: "update", fields: [
                "passphrase": String(decoding: try JSONEncoder().encode(passphrase), as: UTF8.self),
                "permission": String(decoding: try JSONSerialization.data(withJSONObject: permission), as: UTF8.self),
                "password": String(decoding: try JSONEncoder().encode(password), as: UTF8.self),
                "expiration": String(Int(expiration?.timeIntervalSince1970 ?? 0))])
        }
        let result = try await albumSharing(id: id)
        guard (result.shared ?? false) == enabled else { throw ConnectionError.invalidResponse }
        if enabled {
            guard result.additional?.sharing_info?.privacy_type == "public-" + role,
                  (result.additional?.sharing_info?.enable_password ?? false) == !password.isEmpty else { throw ConnectionError.invalidResponse }
        }
        return result
    }
    func recycleBinEnabled(shared: Bool) async throws -> Bool {
        struct Settings: Decodable { let enable_personal_dsm_recycle_bin: Bool?; let enable_shared_dsm_recycle_bin: Bool? }
        let settings = try await call("SYNO.Foto.Setting.Admin", 1, "get", as: Settings.self)
        return (shared ? settings.enable_shared_dsm_recycle_bin : settings.enable_personal_dsm_recycle_bin) == true
    }
    private func existingIDs(_ ids: [Int], shared: Bool) async throws -> Set<Int> {
        struct Item: Decodable { let id: Int }
        struct Page: Decodable { let list: [Item] }
        let encoded = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        do {
            return Set(try await call(space(shared, "Browse.Item"), 2, "get", ["id": encoded, "additional": "[]"], as: Page.self).list.map(\.id))
        } catch ConnectionError.server(let code) where code == 641 || code == 120 {
            return []  // DSM reports missing items as an error rather than an empty list.
        }
    }
    /// Deletes items only when the NAS confirms its recycle bin is on, then reads back their absence.
    /// Deletes items and reads back their absence. Unless `permanent` is set (the user confirmed
    /// an unrecoverable delete), it refuses when the NAS recycle bin is off.
    func deletePhotos(ids: [Int], shared: Bool, permanent: Bool = false) async throws {
        guard !ids.isEmpty else { return }
        if !permanent {
            guard (try? await recycleBinEnabled(shared: shared)) == true else { throw DeletionError.recycleBinOff }
        }
        let encoded = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        try await mutation(space(shared, "Browse.Item"), method: "delete", fields: ["id": encoded])
        guard try await existingIDs(ids, shared: shared).isEmpty else { throw ConnectionError.invalidResponse }
    }
}

enum DeletionError: LocalizedError {
    case recycleBinOff
    var errorDescription: String? { "Deleting is turned off because the NAS recycle bin isn’t enabled (or this account can’t confirm it). Enable the Synology Photos recycle bin in DSM first." }
}

// MARK: - Keychain

/// The record binds the session to its original server and account.
struct SavedSession: Codable {
    let address: String
    let username: String
    let sid: String
    var resolvedAddress: String? = nil
}
struct Credentials: Codable {
    var address: String
    var username: String
    var password: String
    var deviceID: String?
}
private enum Keychain {
    static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "PhotoHarbor") + service,
         kSecAttrAccount as String: "active"]
    }
    static func save(_ data: Data, service: String, background: Bool) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: background ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(service) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(service).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError(status: status) }
    }
    static func load(service: String) throws -> Data? {
        var lookup = query(service)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageError(status: status) }
        return data
    }
    static func clear(service: String) throws {
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(status: status) }
    }
}
struct StorageError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Secure storage is unavailable (\(status)). Unlock the device and try again." }
}
enum SessionStore {
    static func save(_ session: SavedSession, background: Bool = true) throws {
        try Keychain.save(try JSONEncoder().encode(session), service: ".session", background: background)
    }
    static func load() throws -> SavedSession? {
        try Keychain.load(service: ".session").map { try JSONDecoder().decode(SavedSession.self, from: $0) }
    }
    static func clear() throws { try Keychain.clear(service: ".session") }
}
/// Optional "stay signed in" credentials so the app can renew expired sessions, including during background backup.
enum CredentialStore {
    static func save(_ credentials: Credentials, address: String) throws {
        var stored = credentials; stored.address = address
        try Keychain.save(try JSONEncoder().encode(stored), service: ".credentials", background: true)
    }
    static func load() -> Credentials? {
        guard let data = try? Keychain.load(service: ".credentials") else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    static func clear() throws { try Keychain.clear(service: ".credentials") }
}

struct PhotoTag: Codable, Identifiable, Hashable { let id: Int; let name: String }
extension DSMClient {
    func photoTags(id: Int, shared: Bool) async throws -> [PhotoTag] {
        struct Tags: Decodable { let intersection: [PhotoTag] }
        return try await call(space(shared, "Browse.Item"), 1, "get_tag", ["id": "[\(id)]"], as: Tags.self).intersection
    }
    #if DEBUG
    func featureContract(_ api: String, method: String, version: Int = 1, fields: [String: String] = [:]) async throws -> String {
        try await authorized { sid in
            let apiInfo = try self.info(api, version)
            var values = fields; values["api"] = api; values["version"] = String(version); values["method"] = method; values["_sid"] = sid
            let data = try await self.send(apiInfo.path, values)
            return String(decoding: data, as: UTF8.self)
        }
    }
    func featureAPIs() -> [String] { capabilities.keys.filter { $0.contains("Recycle") || $0.contains("FileStation") || $0.contains("Foto") }.sorted() }
    #endif
}
import Foundation

struct RecycleFile: Decodable, Identifiable {
    var id: String { path }
    let name: String; let path: String; let isdir: Bool
}
struct SharedPhotoAlbum: Decodable, Identifiable {
    let id: Int; let name: String; let passphrase: String?; let item_count: Int?
}
extension DSMClient {
    static func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    func setPhotoDescription(id: Int, shared: Bool, description: String) async throws {
        _ = try await details(id: id, shared: shared)
        let tags = try await photoTags(id: id, shared: shared)
        try await mutation(space(shared, "Browse.Item"), method: "set", version: 7, fields: ["id": "[\(id)]", "description": try Self.json(description)])
        // Some Photos releases clear tags when setting descriptions; preserve them explicitly.
        if !tags.isEmpty { try await mutation(space(shared, "Browse.Item"), method: "add_tag", fields: ["id": "[\(id)]", "tag": try Self.json(tags.map(\.id))]) }
        guard try await details(id: id, shared: shared).additional?.description ?? "" == description,
              Set(try await photoTags(id: id, shared: shared).map(\.id)) == Set(tags.map(\.id)) else { throw ConnectionError.invalidResponse }
    }
    func addPhotoTag(id: Int, shared: Bool, name: String) async throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ConnectionError.invalidResponse }
        _ = try await details(id: id, shared: shared)
        struct TagPage: Decodable { let list: [PhotoTag] }
        var found: PhotoTag?; var offset = 0
        while true {
            let page: TagPage = try await call(space(shared, "Browse.GeneralTag"), 1, "list", ["offset": String(offset), "limit": "200"])
            found = page.list.first { $0.name == clean }; if found != nil || page.list.count < 200 { break }; offset += page.list.count
        }
        let tag: PhotoTag
        if let found { tag = found }
        else {
            struct Created: Decodable { let tag: PhotoTag }
            let created: Created = try await call(space(shared, "Browse.GeneralTag"), 1, "create", ["name": try Self.json(clean)])
            tag = created.tag
        }
        let existing = try await photoTags(id: id, shared: shared)
        let ids = Set(existing.map(\.id)).union([tag.id])
        try await mutation(space(shared, "Browse.Item"), method: "add_tag", fields: ["id": "[\(id)]", "tag": try Self.json(Array(ids))])
        guard Set(try await photoTags(id: id, shared: shared).map(\.id)).isSuperset(of: ids) else { throw ConnectionError.invalidResponse }
    }
    func removePhotoTag(id: Int, shared: Bool, tag: PhotoTag) async throws {
        try await mutation(space(shared, "Browse.Item"), method: "remove_tag", fields: ["id": "[\(id)]", "tag": "[\(tag.id)]"])
        guard try await !photoTags(id: id, shared: shared).contains(where: { $0.id == tag.id }) else { throw ConnectionError.invalidResponse }
    }
    func allPeople(shared: Bool, includeHidden: Bool = false) async throws -> [RemoteGroup] {
        struct Page: Decodable { let list: [RemoteGroup] }
        var result: [RemoteGroup] = []; var offset = 0
        while true {
            let page: Page = try await call(space(shared, "Browse.Person"), 1, "list", ["offset": String(offset), "limit": "200", "show_more": "true", "show_hidden": includeHidden ? "true" : "false", "additional": "[\"thumbnail\"]"])
            result += page.list; offset += page.list.count; if page.list.count < 200 { return result }
        }
    }
    func showPerson(id: Int, shared: Bool, visible: Bool) async throws {
        guard try await allPeople(shared: shared, includeHidden: true).contains(where: { $0.id == id }) else { throw ConnectionError.invalidResponse }
        try await mutation(space(shared, "Browse.Person"), method: "show", fields: ["id": "[\(id)]", "show": visible ? "true" : "false"])
        let list = try await allPeople(shared: shared)
        guard list.contains(where: { $0.id == id }) == visible else { throw ConnectionError.invalidResponse }
    }
    func mergePeople(target: RemoteGroup, sources: [Int], shared: Bool) async throws {
        let ids = Set(sources).subtracting([target.id]); guard !ids.isEmpty else { throw ConnectionError.invalidResponse }
        let before = try await allPeople(shared: shared, includeHidden: true)
        guard Set(before.map(\.id)).isSuperset(of: ids.union([target.id])) else { throw ConnectionError.invalidResponse }
        try await mutation(space(shared, "Browse.Person"), method: "merge", version: 2, fields: ["target_id": String(target.id), "merged_id": try Self.json(Array(ids)), "name": try Self.json(target.name)])
        let after = try await allPeople(shared: shared, includeHidden: true)
        guard after.contains(where: { $0.id == target.id }), Set(after.map(\.id)).isDisjoint(with: ids) else { throw ConnectionError.invalidResponse }
    }
    func personCover(person: Int, photo: Int, shared: Bool) async throws {
        var offset = 0; var belongs = false
        while !belongs { let page = try await items(.person(person), shared: shared, offset: offset); belongs = page.contains { $0.id == photo }; offset += page.count; if page.count < DSMClient.pageSize { break } }
        guard belongs else { throw ConnectionError.invalidResponse }
        try await mutation(space(shared, "Browse.Person"), method: "set_cover", fields: ["id": String(person), "photo_id": String(photo)])
        guard let result = try await allPeople(shared: shared, includeHidden: true).first(where: { $0.id == person }),
              result.cover(kind: "person")?.cacheKey.hasPrefix("\(photo)_") == true else { throw ConnectionError.invalidResponse }
    }
    func sharedWithMe() async throws -> [SharedPhotoAlbum] {
        struct Page: Decodable { let list: [SharedPhotoAlbum] }
        var result: [SharedPhotoAlbum] = []; var offset = 0
        while true {
            let page: Page = try await call("SYNO.Foto.Sharing.Misc", 2, "list_shared_with_me_album", ["offset": String(offset), "limit": "100"])
            result += page.list; offset += page.list.count; if page.list.count < 100 { return result }
        }
    }
    func recycleFiles(path: String) async throws -> [RecycleFile] {
        guard path == "/home/#recycle" || path.hasPrefix("/home/#recycle/") || path == "/photo/#recycle" || path.hasPrefix("/photo/#recycle/"), !path.split(separator: "/").contains("..") else { throw ConnectionError.invalidAddress }
        struct Page: Decodable { let files: [RecycleFile] }
        var result: [RecycleFile] = []; var offset = 0
        while true {
            let page: Page = try await call("SYNO.FileStation.List", 2, "list", ["folder_path": path, "offset": String(offset), "limit": "200", "additional": "[\"size\",\"time\"]"])
            result += page.files; offset += page.files.count; if page.files.count < 200 { return result }
        }
    }
    static func restoredPath(_ path: String) throws -> String {
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }), !path.contains("\0") else { throw ConnectionError.invalidAddress }
        if path.hasPrefix("/home/#recycle/Photos/") { return "/home/Photos/" + path.dropFirst("/home/#recycle/Photos/".count) }
        if path.hasPrefix("/photo/#recycle/") { return "/photo/" + path.dropFirst("/photo/#recycle/".count) }
        throw ConnectionError.invalidAddress
    }
    func restoreRecycledFile(_ file: RecycleFile) async throws {
        guard !file.isdir else { throw ConnectionError.invalidResponse }
        let destination = try Self.restoredPath(file.path)
        struct Existing: Decodable { let files: [RecycleFile] }
        do {
            let existing: Existing = try await call("SYNO.FileStation.List", 2, "getinfo", ["path": try Self.json([destination])])
            if !existing.files.isEmpty { throw FeatureError.message("A file already exists at the original location. Nothing was overwritten.") }
        } catch ConnectionError.server(408) { /* Destination does not exist. */ }
        struct Started: Decodable { let taskid: String }
        let task: Started = try await call("SYNO.FileStation.CopyMove", 3, "start", ["path": try Self.json([file.path]), "dest_folder_path": (destination as NSString).deletingLastPathComponent, "is_move": "true", "overwrite": "false"])
        struct Status: Decodable { let finished: Bool; let errors: [Failure]?; struct Failure: Decodable { let code: Int? } }
        for _ in 0..<120 {
            let status: Status = try await call("SYNO.FileStation.CopyMove", 3, "status", ["taskid": task.taskid])
            if let error = status.errors?.first { throw ConnectionError.server(error.code ?? -1) }
            if status.finished {
                struct Info: Decodable { let files: [RecycleFile] }
                let check: Info = try await call("SYNO.FileStation.List", 2, "getinfo", ["path": try Self.json([destination])])
                guard check.files.contains(where: { $0.path == destination }),
                      try await !recycleFiles(path: (file.path as NSString).deletingLastPathComponent).contains(where: { $0.path == file.path }) else { throw ConnectionError.invalidResponse }; return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw FeatureError.message("The NAS is still restoring this file. Refresh the recycle bin before trying again.")
    }
}
enum FeatureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct PersonFace: Decodable, Identifiable {
    let id: Int; let filename: String?; let item_id: Int?; let photo_id: Int?
    let additional: RemotePhoto.Additional?
    var thumbnailSource: ThumbnailSource? {
        guard let key = additional?.thumbnail?.cache_key else { return nil }
        return ThumbnailSource(id: id, cacheKey: key, kind: "face")
    }
}
extension DSMClient {
    func personFaces(person: Int, shared: Bool) async throws -> [PersonFace] {
        struct Page: Decodable { let list: [PersonFace] }
        var result: [PersonFace] = []; var offset = 0
        while true {
            let photos = try await items(.person(person), shared: shared, offset: offset, limit: 100)
            if photos.isEmpty { break }
            let page: Page = try await call(space(shared, "Browse.Person"), 1, "list_face", ["person_id": String(person), "item_id": try Self.json(photos.map(\.id))])
            result += page.list; offset += photos.count; if photos.count < 100 { break }
        }
        return result
    }
    func separateFaces(person: Int, faces: [Int], shared: Bool) async throws {
        let ids = Set(faces); guard !ids.isEmpty, Set(try await personFaces(person: person, shared: shared).map(\.id)).isSuperset(of: ids) else { throw ConnectionError.invalidResponse }
        try await mutation(space(shared, "Browse.Person"), method: "separate", fields: ["target_id": "0", "name": try Self.json(""), "face_id": try Self.json(Array(ids))])
        guard Set(try await personFaces(person: person, shared: shared).map(\.id)).isDisjoint(with: ids) else { throw ConnectionError.invalidResponse }
    }
}

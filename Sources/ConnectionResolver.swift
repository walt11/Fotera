import Foundation
import CryptoKit
import Darwin

/// Direct HTTP is restricted to explicitly entered local addresses. HTTPS keeps normal TLS validation.
enum ConnectionAddress {
    static func isLAN(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let n = UInt32(bigEndian: ipv4.s_addr)
            return n >> 24 == 10 || n >> 24 == 127 || n >> 20 == 0xac1 || n >> 16 == 0xc0a8 || n >> 16 == 0xa9fe
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in
                (bytes[0] & 0xfe == 0xfc) || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) ||
                (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
            }
        }
        return false
    }
    static func quickConnectID(_ input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = input
        if input.contains("://") {
            guard let url = URL(string: input), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil else { return nil }
            if url.scheme?.lowercased() == "quickconnect", url.path.isEmpty { id = url.host ?? "" }
            else if url.scheme?.lowercased() == "https", ["quickconnect.to", "www.quickconnect.to"].contains(url.host?.lowercased() ?? "") {
                id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else { return nil }
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard (2...64).contains(id.count), id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              id.first != "-", id.last != "-" else { return nil }
        return id.lowercased()
    }
}

enum QuickConnectError: LocalizedError {
    case unavailable, invalidResponse, noSecureRoute
    var errorDescription: String? {
        switch self {
        case .unavailable: return "QuickConnect couldn’t find an online NAS for this ID. Check the ID and DSM’s QuickConnect settings."
        case .invalidResponse: return "QuickConnect returned a response Fotera couldn’t validate. No login details were sent."
        case .noSecureRoute: return "QuickConnect found the NAS, but no verified HTTPS route was available. Check QuickConnect relay permissions, or use your LAN HTTP address."
        }
    }
}

/// Resolver requests contain only the QuickConnect ID; credentials stay in DSMClient.
/// The service protocol is not a public Synology API contract: every route is validated before use.
enum QuickConnectResolver {
    struct Reply: Decodable {
        let errno: Int
        let server: Server?
        let service: Service?
        let env: Environment?
        let smartdns: SmartDNS?
        struct Server: Decodable { let serverID: String; let ddns: String?; let fqdn: String? }
        struct Service: Decodable { let port: Int?; let ext_port: Int?; let relay_dn: String?; let relay_dualstack: String?; let relay_port: Int? }
        struct Environment: Decodable { let control_host: String?; let relay_region: String? }
        struct SmartDNS: Decodable { let host: String?; let lan: [String]?; let lanv6: [String]? }
    }
    static func serviceHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host.hasSuffix(".quickconnect.to") && !host.contains("/") && !host.contains(":") && !host.contains("@")
    }
    static func decode(_ data: Data) throws -> Reply {
        let decoder = JSONDecoder()
        if let rows = try? decoder.decode([Reply].self, from: data), let first = rows.first { return first }
        guard let reply = try? decoder.decode(Reply.self, from: data) else { throw QuickConnectError.invalidResponse }
        return reply
    }
    static func resolve(_ id: String) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func request(_ command: String, host: String) async throws -> Reply {
            guard serviceHost(host), let url = URL(string: "https://" + host + "/Serv.php") else { throw QuickConnectError.invalidResponse }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [["version": 1, "command": command, "id": "dsm_portal_https", "serverID": id, "is_gofile": false]])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw QuickConnectError.unavailable }
            return try decode(data)
        }
        var info = try await request("get_server_info", host: "global.quickconnect.to")
        if info.errno != 0, let control = info.env?.control_host, serviceHost(control), control != "global.quickconnect.to" {
            info = try await request("get_server_info", host: control)
        }
        guard info.errno == 0, let server = info.server, !server.serverID.isEmpty else { throw QuickConnectError.unavailable }
        let expected = Insecure.MD5.hash(data: Data(server.serverID.utf8)).map { String(format: "%02x", $0) }.joined()
        var candidates: [URL] = []
        func append(_ host: String?, port: Int? = nil) {
            guard let host, !host.isEmpty, host != "NULL", !host.contains("/"), !host.contains("@"), !host.contains(":") else { return }
            if let port, !(1...65535).contains(port) { return }
            var components = URLComponents(); components.scheme = "https"; components.host = host; components.port = port
            if let url = components.url, !candidates.contains(url) { candidates.append(url) }
        }
        for host in (info.smartdns?.lan ?? []).prefix(4) { append(host, port: info.service?.port) }
        append(info.smartdns?.host, port: info.service?.port)
        append(server.fqdn, port: info.service?.ext_port.flatMap { $0 > 0 ? $0 : nil } ?? info.service?.port)
        append(server.ddns, port: info.service?.ext_port.flatMap { $0 > 0 ? $0 : nil } ?? info.service?.port)
        func verified(_ urls: [URL]) async -> URL? {
            await withTaskGroup(of: URL?.self) { group in
                for base in urls {
                    group.addTask {
                        do {
                            var components = URLComponents(url: base.appendingPathComponent("webman/pingpong.cgi"), resolvingAgainstBaseURL: false)!
                            components.queryItems = [URLQueryItem(name: "action", value: "cors"), URLQueryItem(name: "quickconnect", value: "true")]
                            var request = URLRequest(url: components.url!); request.timeoutInterval = 5
                            let (data, response) = try await session.data(for: request)
                            struct Ping: Decodable { let success: Bool; let ezid: String }
                            let ping = try JSONDecoder().decode(Ping.self, from: data)
                            guard (response as? HTTPURLResponse)?.statusCode == 200, ping.success, ping.ezid.lowercased() == expected else { return nil }
                            return base
                        } catch { return nil }
                    }
                }
                for await url in group { if let url { group.cancelAll(); return url } }
                return nil
            }
        }
        if let direct = await verified(candidates) { return direct }
        let tunnel = try await request("request_tunnel", host: info.env?.control_host ?? "global.quickconnect.to")
        guard tunnel.errno == 0 else { throw QuickConnectError.noSecureRoute }
        candidates = []
        for region in [tunnel.env?.relay_region, info.env?.relay_region].compactMap({ $0 }) {
            if region.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil { append("\(id).\(region).quickconnect.to") }
        }
        for host in [tunnel.service?.relay_dn, tunnel.service?.relay_dualstack].compactMap({ $0 }) where serviceHost(host) {
            append(host, port: tunnel.service?.relay_port)
            append(host)
        }
        guard let relay = await verified(candidates) else { throw QuickConnectError.noSecureRoute }
        return relay
    }
}

struct RouteProfile: Codable {
    var lan: String = ""
    var quickConnect: String = ""
    // Optional so previously saved profiles decode without losing LAN or QuickConnect settings.
    var remoteURL: String? = nil
    var enabled = false
    var identity = ""
}

extension RouteProfile {
    static func remoteAddress(_ value: String) throws -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = try DSMClient.normalize(trimmed)
        guard url.scheme == "https" else { throw ConnectionError.invalidAddress }
        return url
    }
    func verifiedDirectRoute(current: URL, canonical: String, allowLAN: Bool = true,
                             probe: @Sendable (URL) async throws -> String) async -> URL? {
        for candidate in directCandidates(current: current, canonical: canonical, allowLAN: allowLAN) {
            guard !Task.isCancelled else { return nil }
            if let found = try? await probe(candidate), !identity.isEmpty, found == identity { return candidate }
        }
        return nil
    }
    /// Validated origins, in preference order; probe each at most once per selection.
    func directCandidates(current: URL, canonical: String, allowLAN: Bool = true) -> [URL] {
        var candidates: [URL] = []
        if let local = try? DSMClient.normalize(lan), ConnectionAddress.isLAN(local.host ?? "") { candidates.append(local) }
        if let remote = try? Self.remoteAddress(remoteURL ?? "") { candidates.append(remote) }
        candidates.append(current)
        if let original = try? DSMClient.normalize(canonical) { candidates.append(original) }
        var seen = Set<URL>()
        return candidates.filter { (allowLAN || !ConnectionAddress.isLAN($0.host ?? "")) && seen.insert($0).inserted }
    }
}

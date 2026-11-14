#if DEBUG
import Foundation
import UIKit
import ImageIO

/// Opt-in development checks (launch with `--fotera-verify`). Never reads credentials into a report.
/// Creates/reuses a synthetic JPEG in `/Fotera Validation`; never enables public sharing or deletes photos.
@MainActor enum DevelopmentVerification {
    static func run(client: DSMClient) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report = documents.appendingPathComponent("verification.txt")
        var results: [String] = []
        func record(_ message: String) {
            results.append(message)
            try? results.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        do {
            if ProcessInfo.processInfo.arguments.contains("--login-session-tests") {
                do {
                    try await client.verifyLoginSession("PhotoHarbor")
                    record("PASS: existing session-name login accepted")
                } catch AuthError.permissionDenied {
                    record("REPRODUCED: existing session-name login denied with 402")
                    try await client.verifyLoginSession("SynologyPhotos")
                    record("PASS: Photos session-name login accepted")
                }
                _ = try await client.items(.all, shared: false, offset: 0, limit: 1)
                record("PASS: authenticated photo listing after login")
                record("FINISHED LOGIN SESSION TESTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--backup-download-tests") {
                var photos: [RemotePhoto] = []; var offset = 0
                while true {
                    let page = try await client.items(.all, shared: false, offset: offset)
                    photos += page; offset += page.count
                    if page.count < DSMClient.pageSize { break }
                }
                let targets: [(String, Int64)] = [("IMG_3288.heic", 1146112), ("IMG_2325.heic", 2529967), ("IMG_20260711_164719.heic", 801653), ("IMG_20260613_173856.heic", 2598371), ("IMG_20260613_173819 (2).heic", 2353499), ("IMG_1477.MOV", 3374700), ("IMG_20260613_173819 (1).heic", 2472162), ("IMG_20260613_173819.heic", 2171732), ("IMG_20260613_173732.heic", 2441994), ("IMG_20260613_173730.heic", 2450694), ("IMG_20260606_095526.heic", 2232436), ("IMG_20260606_095526 (1).heic", 5217330), ("IMG_20260606_095526 (2).heic", 1681627), ("IMG_20260606_095526 (3).heic", 2376269), ("IMG_20260606_095526 (4).heic", 1176642), ("IMG_20260606_095527.heic", 1320305), ("IMG_20260606_095527 (1).heic", 949185), ("IMG_20260606_095527 (2).heic", 921771), ("IMG_20260606_095527 (3).heic", 1243754), ("IMG_20260606_095527 (4).heic", 666526), ("IMG_20260606_095527 (5).heic", 2071958), ("IMG_20260606_095527 (6).heic", 911313), ("IMG_20260606_095527 (7).heic", 1744187), ("IMG_20260606_095527 (8).heic", 3272369), ("IMG_20260606_095527 (9).heic", 1670903), ("IMG_20260606_095527 (10).heic", 1829868), ("IMG_20260606_095527 (11).heic", 1305624), ("IMG_20260606_095527 (12).heic", 4150110)]
                let candidates = photos.filter { photo in photo.isLive && targets.contains { name, size in
                    photo.filesize == size || (photo.filename as NSString).deletingPathExtension.lowercased() == (name as NSString).deletingPathExtension.lowercased()
                } }
                record("Checking \(candidates.count) candidates from the phone's failed duplicate checks")
                for photo in candidates {
                    let file = try await client.livePackage(photo, shared: false)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let handle = try FileHandle(forReadingFrom: file)
                    let prefix = try handle.read(upToCount: 16) ?? Data(); try handle.close()
                    let imageType = CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceGetType($0) } as String?
                    record("RESPONSE: \(photo.id), type=\(imageType ?? "unknown"), signature=\(prefix.map { String(format: "%02x", $0) }.joined())")
                    do {
                        let hashes = try await TransferQueue.originalDigests(file, live: true)
                        guard hashes.contains(try TransferQueue.digest(file).0) else { throw TransferError.mismatch }
                        record("PASS: duplicate fingerprint decoded for NAS item \(photo.id)")
                    } catch {
                        let capture = documents.appendingPathComponent("backup-probe-\(photo.id).bin")
                        try? FileManager.default.removeItem(at: capture)
                        try FileManager.default.copyItem(at: file, to: capture)
                        record("FAIL DECODE: \(photo.id), \(error)")
                    }
                    do {
                        let package = try OriginalPackage.unpack(file)
                        record("PACKAGE: \(photo.id), \(package.files.count) resources")
                        try? FileManager.default.removeItem(at: package.directory)
                    } catch {
                        record("NONPACKAGE: \(photo.id), type=\(imageType ?? "unknown"), signature=\(prefix.map { String(format: "%02x", $0) }.joined()), error=\(error)")
                    }
                }
                record("FINISHED BACKUP DOWNLOAD PROBES"); return
            }
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--repair-session"), ProcessInfo.processInfo.arguments.indices.contains(index + 2),
               let sid = await client.currentSessionID() {
                // Development repair: rebinds the simulator's current session to a direct address and account.
                let arguments = ProcessInfo.processInfo.arguments
                try SessionStore.save(SavedSession(address: arguments[index + 1], username: arguments[index + 2], sid: sid), background: false)
                UserDefaults.standard.set(arguments[index + 1], forKey: "serverAddress")
                UserDefaults.standard.set(arguments[index + 2], forKey: "accountName")
                record("REPAIRED"); record("FINISHED"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--similar-probe") {
                let probes: [(String, Int, String, [String: String])] = [
                    ("SYNO.Foto.Browse.Similar", 1, "get", ["id": "1229"]),
                    ("SYNO.Foto.Browse.Similar", 1, "get", ["id": "1229", "additional": "[\"thumbnail\"]"]),
                    ("SYNO.Foto.Browse.SimilarItem", 2, "list", ["offset": "0", "limit": "500"]),
                    ("SYNO.Foto.Browse.Similar", 1, "get", [:]),
                    ("SYNO.Foto.Browse.SimilarItem", 1, "list", ["offset": "0", "limit": "5", "additional": "[\"thumbnail\"]"]),
                    ("SYNO.Foto.Browse.SimilarItem", 2, "list", ["offset": "0", "limit": "5", "additional": "[\"thumbnail\"]"]),
                    ("SYNO.Foto.Browse.SimilarTimeline", 1, "get", [:]),
                    ("SYNO.Foto.Browse.SimilarTimeline", 2, "get", [:]),
                    ("SYNO.Foto.Browse.SimilarTimeline", 2, "list", ["offset": "0", "limit": "5"]),
                    ("SYNO.Foto.Setting.User", 1, "get", [:]),
                    ("SYNO.Foto.Sharing.Misc", 2, "list_shared_with_me_album", ["offset": "0", "limit": "5", "additional": "[\"thumbnail\"]"]),
                ]
                for (api, version, method, fields) in probes {
                    do { record("\(api) v\(version) \(method): " + String((try await client.featureContract(api, method: method, version: version, fields: fields)).prefix(700))) }
                    catch { record("\(api) v\(version) \(method): ERROR \(error)") }
                }
                record("FINISHED"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--recycle-probe") {
                record("ADMIN: " + String((try await client.featureContract("SYNO.Foto.Setting.Admin", method: "get")).prefix(1500)))
                record("FINISHED"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--list-meta-probe") {
                for extra in ["[\"thumbnail\",\"gps\",\"video_meta\"]", "[\"thumbnail\",\"gps\",\"video_meta\",\"favorite\"]"] {
                    let raw = try await client.featureContract("SYNO.Foto.Browse.Item", method: "list", version: 7, fields: ["offset": "0", "limit": "40", "sort_by": "takentime", "sort_direction": "desc", "additional": extra])
                    record("LIST \(extra): " + String(raw.prefix(200)))
                    if let range = raw.range(of: "\"video_meta\"") { record("VIDEO: " + String(raw[range.lowerBound...].prefix(160))) }
                    if let range = raw.range(of: "\"favorite\"") { record("FAV: " + String(raw[range.lowerBound...].prefix(40))) }
                }
                record("FINISHED"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--all-feature-tests") {
                let token = String(UUID().uuidString.prefix(8))
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
                let data = renderer.jpegData(withCompressionQuality: 0.9) { context in UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64)); (token as NSString).draw(at: CGPoint(x: 1, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.white]) }
                let file = documents.appendingPathComponent("Features-\(token).jpg"); try data.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let queue = TransferQueue(account: "features-fixture-" + token)
                try await queue.enqueue(file, filename: file.lastPathComponent, folder: "/Fotera Validation", shared: false)
                _ = await queue.process(client: client, wifiOnly: false, verify: true, deadline: Date().addingTimeInterval(90), maxInFlight: 1)
                guard let uploaded = queue.records.first, uploaded.state == .verified, let id = uploaded.remoteID else { throw ConnectionError.invalidResponse }
                record("PASS: isolated synthetic fixture uploaded and verified")
                let photo = RemotePhoto(id: id, filename: file.lastPathComponent, time: Date().timeIntervalSince1970, type: "photo", additional: nil, filesize: Int64(data.count))
                do {
                    try await client.setPhotoDescription(id: id, shared: false, description: "Fotera validation \"quoted\" & café")
                    record("METADATA STEP: description saved")
                    try await client.addPhotoTag(id: id, shared: false, name: "Fotera-Validation-" + token)
                    record("METADATA STEP: tag added")
                    let tags = try await client.photoTags(id: id, shared: false)
                    guard let tag = tags.first(where: { $0.name == "Fotera-Validation-" + token }) else { throw ConnectionError.invalidResponse }
                    record("METADATA STEP: tag read back")
                    try await client.setPhotoDescription(id: id, shared: false, description: "Updated description")
                    guard try await client.photoTags(id: id, shared: false).contains(tag) else { throw ConnectionError.invalidResponse }
                    try await client.removePhotoTag(id: id, shared: false, tag: tag)
                    try await client.setPhotoDescription(id: id, shared: false, description: "")
                    record("PASS: description Unicode/quotes round-trip, tag create/add/remove, and tag preservation while editing descriptions")
                } catch { record("FAIL METADATA: " + error.localizedDescription) }
                if let saved = try? SessionStore.load() {
                    let account = saved.address + "|" + saved.username
                    let original = try await client.original(photo, shared: false)
                    defer { try? FileManager.default.removeItem(at: original) }
                    let expected = try TransferQueue.digest(original).0
                    let album = OfflineVault.Album(title: "Validation offline album", photos: [photo], shared: false, completed: [id])
                    try await OfflineVault.shared.save(album, account: account)
                    try await OfflineVault.shared.store(original, account: account, photo: photo, shared: false, package: false)
                    let cached = try await client.original(photo, shared: false, useOfflineCache: true)
                    guard try TransferQueue.digest(cached).0 == expected else { throw TransferError.mismatch }; try? FileManager.default.removeItem(at: cached)
                    let damaged = documents.appendingPathComponent("offline-validation-stale"); try Data("deliberately stale cache".utf8).write(to: damaged)
                    try await OfflineVault.shared.store(damaged, account: account, photo: photo, shared: false, package: false); try? FileManager.default.removeItem(at: damaged)
                    let fresh = try await client.original(photo, shared: false)
                    guard try TransferQueue.digest(fresh).0 == expected else { throw TransferError.mismatch }; try? FileManager.default.removeItem(at: fresh)
                    try await OfflineVault.shared.remove(album, account: account)
                    guard await OfflineVault.shared.originalURL(account: account, shared: false, id: id) == nil else { throw ConnectionError.invalidResponse }
                    record("PASS: offline original round-trip, account-scoped cleanup, and backup downloads bypass stale local originals")
                }
                guard try DSMClient.restoredPath("/home/#recycle/Photos/Trip/file.jpg") == "/home/Photos/Trip/file.jpg",
                      try DSMClient.restoredPath("/photo/#recycle/Trip/file.jpg") == "/photo/Trip/file.jpg",
                      (try? DSMClient.restoredPath("/home/#recycle/Photos/../secret")) == nil else { throw ConnectionError.invalidResponse }
                record("PASS: recycle restore paths remain inside the correct Photos space and reject traversal")
                let shared = try await client.sharedWithMe(); record("PASS: shared-with-me listing decoded (\(shared.count) albums)")
                let people = try await client.allPeople(shared: false)
                if let person = people.first {
                    let faces = try await client.personFaces(person: person.id, shared: false)
                    if let source = faces.first?.thumbnailSource {
                        let preview = try await client.thumbnail(source, shared: false, size: .sm)
                        guard UIImage(data: preview) != nil else { throw ConnectionError.invalidResponse }
                        record("PASS: person face listing and actual face preview decoded")
                    }
                    try await client.showPerson(id: person.id, shared: false, visible: true)
                    record("PASS: visibility request read back without changing the visible person")
                    if let key = person.cover(kind: "person")?.cacheKey, let coverID = Int(key.split(separator: "_").first ?? "") {
                        do { try await client.personCover(person: person.id, photo: coverID, shared: false); record("PASS: existing cover photo re-saved and verified") }
                        catch { record("FAIL COVER: " + error.localizedDescription) }
                    }
                }
                let identity = try await DSMClient.nasIdentity(await client.base)
                let quick = try await QuickConnectResolver.resolve("jwaltnas")
                guard try await DSMClient.nasIdentity(quick) == identity else { throw ConnectionError.invalidResponse }
                record("PASS: current and QuickConnect routes identify the same NAS")
                record("FINISHED ALL FEATURE TESTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--feature-contracts") {
                record("APIS: \(await client.featureAPIs().joined(separator: ", "))")
                let photos = try await client.items(.all, shared: false, offset: 0, limit: 1)
                let people = try await client.people(shared: false, limit: 1)
                let personPhoto = try await client.items(.person(people.first!.id), shared: false, offset: 0, limit: 1).first!
                let probes: [(String, String, Int, [String: String])] = [
                    ("SYNO.Foto.Browse.Item", "get_tag", 1, ["id": "[\(photos.first!.id)]"]),
                    ("SYNO.Foto.Browse.Person", "list_face", 1, ["person_id": String(people.first!.id), "item_id": "[\(personPhoto.id)]", "offset": "0", "limit": "2"]),
                    ("SYNO.FileStation.List", "list", 2, ["folder_path": "\"/home/#recycle/Photos\"", "offset": "0", "limit": "5"]),
                    ("SYNO.Foto.Browse.Album", "list", 1, ["offset": "0", "limit": "2", "additional": "[\"sharing_info\"]"]),
                    ("SYNO.Foto.Browse.GeneralTag", "list", 1, ["offset": "0", "limit": "2"]),
                    ("SYNO.Foto.Sharing.Misc", "list_shared_with_me_album", 2, ["offset": "0", "limit": "2"]),
                    ("SYNO.FileStation.List", "list", 2, ["folder_path": "/home/#recycle", "offset": "0", "limit": "3"]),
                    ("SYNO.FileStation.List", "list", 2, ["folder_path": "/photo/#recycle", "offset": "0", "limit": "3"]),
                    ("SYNO.Foto.Browse.Person", "get", 1, ["id": "[\(people.first!.id)]", "additional": "[\"thumbnail\"]"]),
                    ("SYNO.Foto.Browse.Person", "show", 1, ["id": "[\(people.first!.id)]", "show": "true"]),
                    ("SYNO.Foto.Browse.Person", "merge", 2, ["target_id": String(people.first!.id), "merged_id": "[2147483647]", "name": try DSMClient.json(people.first!.name)]),
                    ("SYNO.Foto.Browse.Person", "separate", 1, ["target_id": "0", "name": "\"\"", "face_id": "[2147483647]"]),
                    ("SYNO.FileStation.List", "list", 2, ["folder_path": "/home", "offset": "0", "limit": "3"])
                ]
                for (api, method, version, fields) in probes {
                    do { record("CONTRACT \(api).\(method): " + (try await client.featureContract(api, method: method, version: version, fields: fields))) }
                    catch { record("CONTRACT \(api).\(method): " + error.localizedDescription) }
                }
                record("FINISHED FEATURE CONTRACTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--people-tests") {
                let people = try await client.people(shared: false)
                guard let person = people.first(where: { !$0.name.isEmpty }) ?? people.first else { throw ConnectionError.invalidResponse }
                record("Testing existing name length: \(person.name.count)")
                let before = try await client.items(.person(person.id), shared: false, offset: 0, limit: 20).map(\.id)
                // Re-save the existing name: validates the mutation without assigning anyone an invented identity.
                let result = try await client.renamePerson(id: person.id, name: person.name, shared: false)
                let after = try await client.items(.person(person.id), shared: false, offset: 0, limit: 20).map(\.id)
                guard result.name == person.name, result.id == person.id, before == after else { throw ConnectionError.invalidResponse }
                record("PASS: Person.set accepted on the NAS, name read back correctly, person identity and photo membership unchanged")
                record("FINISHED PEOPLE TESTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--review-tests") {
                let iso = ISO8601DateFormatter()
                let samples = [
                    RemotePhoto(id: 1, filename: "Beach.HEIC", time: iso.date(from: "2025-11-13T23:30:00Z")!.timeIntervalSince1970, type: "live", additional: nil),
                    RemotePhoto(id: 2, filename: "Trip.MOV", time: iso.date(from: "2024-06-01T12:00:00Z")!.timeIntervalSince1970, type: "video", additional: nil),
                    RemotePhoto(id: 3, filename: "Mountain.DNG", time: nil, type: "photo", additional: nil)]
                func matches(_ query: String = "", _ media: LibraryMediaFilter = .all, _ year: Int? = nil) -> [Int] {
                    LocalLibrarySearch.results(samples, query: query, media: media, year: year).map(\.id)
                }
                guard matches("beach 2025-11") == [1], matches("", .live) == [1],
                      matches("", .videos) == [2], matches("", .raw) == [3],
                      matches("", .photos) == [1, 3], matches("", .all, 2024) == [2],
                      matches("2025-11-14").isEmpty, matches("missing").isEmpty else { throw ConnectionError.invalidResponse }
                record("PASS: offline filename/date search, media/year filters, unknown dates, case-insensitive extensions, and capture-day boundary")
                let old = try JSONDecoder().decode(SavedSession.self, from: Data("{\"address\":\"https://example.com\",\"username\":\"fixture\",\"sid\":\"unused\"}".utf8))
                guard old.resolvedAddress == nil else { throw ConnectionError.invalidResponse }
                let modern = SavedSession(address: "quickconnect://fixture", username: "fixture", sid: "unused", resolvedAddress: "https://fixture.us.quickconnect.to")
                guard try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(modern)).resolvedAddress == modern.resolvedAddress else { throw ConnectionError.invalidResponse }
                record("PASS: existing Keychain session format migrates and verified endpoint round-trips")
                let page = try await client.items(.all, shared: false, offset: 0, limit: 10)
                guard let first = page.first else { throw ConnectionError.invalidResponse }
                guard LocalLibrarySearch.results(page, query: first.filename, media: .all, year: nil).contains(where: { $0.id == first.id }) else { throw ConnectionError.invalidResponse }
                record("PASS: search finds an actual NAS photo using only its downloaded metadata")
                record("FINISHED REVIEW TESTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--heic-preview-tests") {
                let photos = try await client.items(.all, shared: false, offset: 0, limit: 100)
                guard var photo = photos.first(where: { ImagePipeline.isHEIC($0) && !$0.isLive }) else { throw ConnectionError.invalidResponse }
                photo.filesize = nil // Exercise imported items lacking size in list metadata.
                guard let preview = await ImagePipeline.shared.originalPreview(photo, shared: false, size: .xl, regenerate: true),
                      max(preview.size.width, preview.size.height) <= 2400 else { throw ConnectionError.invalidResponse }
                record("PASS: real NAS HEIC original generated a bounded local preview with missing list size metadata")
                if let source = photo.thumbnailSource {
                    record("Cached sizes: small=\(ImagePipeline.shared.cached(source, shared: false, size: .sm) != nil), medium=\(ImagePipeline.shared.cached(source, shared: false, size: .m) != nil)")
                    guard ImagePipeline.shared.cached(source, shared: false, size: .sm) != nil,
                          ImagePipeline.shared.cached(source, shared: false, size: .m) != nil else { throw ConnectionError.invalidResponse }
                    record("PASS: generated preview populated both timeline thumbnail sizes")
                    if let saved = try? SessionStore.load() {
                        let key = saved.address + "|" + saved.username + "|false|xl|" + source.kind + "|" + String(source.id) + "|" + source.cacheKey
                        guard let data = await LibraryCache.shared.preview(key: key), await ImagePipeline.decode(data, maxPixels: 480) != nil else { throw ConnectionError.invalidResponse }
                        record("PASS: generated JPEG preview persisted in account-scoped cache")
                    }
                }
                record("FINISHED HEIC PREVIEW TESTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--thumbnail-tests") {
                let photos = try await client.items(.all, shared: false, offset: 0, limit: 100)
                var loaded = 0; var missing = 0; var failed = 0
                for photo in photos {
                    guard let source = photo.thumbnailSource else { missing += 1; continue }
                    do {
                        let data = try await client.thumbnail(source, shared: false, size: .m)
                        if await ImagePipeline.decode(data, maxPixels: 480) != nil { loaded += 1 }
                        else { failed += 1; record("DECODE FAILED: item \(photo.id)") }
                    } catch {
                        failed += 1; record("REQUEST FAILED: item \(photo.id), type \(photo.type), bytes \(photo.filesize ?? -1): \(error.localizedDescription)")
                        for size in [ThumbnailSize.sm, .xl] {
                            do {
                                let data = try await client.thumbnail(source, shared: false, size: size)
                                record("Alternative \(size.rawValue): \(await ImagePipeline.decode(data, maxPixels: 480) != nil)")
                            } catch { record("Alternative \(size.rawValue) failed") }
                        }
                        if !photo.isVideo, let bytes = photo.filesize, bytes < 40_000_000 {
                            let file = try await client.original(photo, shared: false)
                            defer { try? FileManager.default.removeItem(at: file) }
                            record("Original decodes: \(await ImagePipeline.decode(file: file, maxPixels: 480) != nil)")
                            guard await ImagePipeline.shared.originalPreview(photo, shared: false, size: .m) != nil else { throw ConnectionError.invalidResponse }
                            record("PASS: production fallback generated and cached preview for item \(photo.id)")
                        }
                    }
                }
                record("Thumbnail scan: \(loaded) decoded, \(missing) missing metadata, \(failed) failed, out of \(photos.count)")
                record("FINISHED THUMBNAIL TESTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--duplicate-tests") {
                let page = try await client.items(.all, shared: false, offset: 0)
                guard let photo = page.first(where: { !$0.isLive && !$0.isVideo }) else { throw ConnectionError.invalidResponse }
                let original = try await client.original(photo, shared: false)
                defer { try? FileManager.default.removeItem(at: original) }
                let queue = TransferQueue(account: "duplicate-test-" + UUID().uuidString)
                try await queue.enqueue(original, filename: photo.filename, folder: "/Fotera Validation", shared: false, sourceID: "existing-original")
                guard let resource = queue.records.first,
                      try await queue.existingOriginal(resource, client: client) != nil else { throw TransferError.mismatch }
                record("PASS: existing original found in the NAS library")
                let healthy = await queue.process(client: client, wifiOnly: false, verify: true, maxInFlight: 1)
                guard healthy, queue.records.first?.state == .verified,
                      queue.records.first?.message?.contains("upload skipped") == true,
                      queue.completed.contains("existing-original") else { throw ConnectionError.invalidResponse }
                record("PASS: real upload queue skipped the existing file and saved completed backup history")
                var renamed = resource; renamed.filename = "Different-name.jpg"
                guard try await queue.existingOriginal(renamed, client: client) != nil else { throw TransferError.mismatch }
                record("PASS: matching content recognized with a different name and destination folder")
                // Limit the negative fixture to a known candidate so this test does not download the whole library.
                queue.setDuplicateTestCatalog([photo])
                var changed = resource; changed.digest = String(repeating: "0", count: 64)
                guard try await queue.existingOriginal(changed, client: client) == nil else { throw TransferError.mismatch }
                record("PASS: same filename and size with different content is not skipped")
                if let live = page.first(where: \.isLive) {
                    let file = try await client.livePackage(live, shared: false)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let package = try OriginalPackage.unpack(file)
                    defer { try? FileManager.default.removeItem(at: package.directory) }
                    queue.setDuplicateTestCatalog([live])
                    for part in package.files {
                        let digest = try TransferQueue.digest(part)
                        var component = resource; component.digest = digest.0; component.size = digest.1
                        component.filename = (live.filename as NSString).deletingPathExtension + "." + part.pathExtension
                        guard try await queue.existingOriginal(component, client: client) == live.id else { throw TransferError.mismatch }
                    }
                    record("PASS: Live Photo still and motion components (same base name) recognized inside the existing NAS package")
                }
                record("FINISHED DUPLICATE TESTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--connection-tests") {
                for value in ["http://192.168.1.20:5000", "http://10.0.0.2:5000", "http://172.16.0.2", "http://nas.local:5000", "http://[fd00::2]:5000", "https://pics.jwalter.net"] {
                    record("CHECK: \(value)")
                    _ = try DSMClient.normalize(value)
                }
                for value in ["http://8.8.8.8", "http://172.32.0.1", "http://nas.example.com", "https://name:password@example.com", "https://nas.example.com/path", "http://192.168.1.2:99999"] {
                    guard (try? DSMClient.normalize(value)) == nil else { throw ConnectionError.invalidResponse }
                }
                guard ConnectionAddress.quickConnectID("My-NAS") == "my-nas",
                      ConnectionAddress.quickConnectID("https://quickconnect.to/My-NAS") == "my-nas",
                      ConnectionAddress.quickConnectID("quickconnect://my-nas") == "my-nas",
                      ConnectionAddress.quickConnectID("https://quickconnect.to.evil.example/my-nas") == nil,
                      !QuickConnectResolver.serviceHost("quickconnect.to.evil.example"),
                      !QuickConnectResolver.serviceHost("evilquickconnect.to") else { throw ConnectionError.invalidResponse }
                let reply = try QuickConnectResolver.decode(Data("[{\"errno\":0,\"server\":{\"serverID\":\"fixture\"},\"service\":{\"port\":5001},\"env\":{\"relay_region\":\"us\"}}]".utf8))
                guard reply.server?.serverID == "fixture" else { throw ConnectionError.invalidResponse }
                record("PASS: local HTTP addresses accepted, public HTTP and malformed origins rejected; QuickConnect IDs and service hosts validated")
                let probe = try DSMClient(address: "http://127.0.0.1:8766")
                do {
                    try await probe.restore(.init(address: probe.address, username: "test", sid: "unused"), credentials: nil)
                    record("PASS: simulator HTTP API discovery passed with ATS enabled and local-only exceptions")
                } catch let error as URLError where error.code == .cannotConnectToHost {
                    record("SKIP: no local DSM stub on 127.0.0.1:8766")
                }
                let quick = try await DSMClient.open(address: "jwaltnas")
                guard let sid = await client.currentSessionID() else { throw ConnectionError.signedOut }
                // restore() persists QuickConnect sessions; put the real signed-in session back afterwards.
                let originalSession = try SessionStore.load()
                defer { if let originalSession { try? SessionStore.save(originalSession, background: CredentialStore.load() != nil) } }
                try await quick.restore(.init(address: quick.address, username: "connection-test", sid: sid), credentials: nil)
                let items = try await quick.items(.all, shared: false, offset: 0, limit: 1)
                guard let photo = items.first, let source = photo.thumbnailSource else { throw ConnectionError.invalidResponse }
                let preview = try await quick.thumbnail(source, shared: false, size: .m)
                guard await ImagePipeline.decode(preview, maxPixels: 480) != nil else { throw ConnectionError.invalidResponse }
                record("PASS: QuickConnect resolved a verified HTTPS route, restored the existing NAS session, browsed a photo, and decoded its thumbnail")
                record("FINISHED CONNECTION TESTS"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--live-pair-diagnostics") {
                var all: [RemotePhoto] = []; var offset = 0
                while true {
                    let page = try await client.items(.all, shared: false, offset: offset, withLocation: true)
                    all += page; offset += page.count
                    if page.count < DSMClient.pageSize { break }
                }
                try JSONEncoder().encode(all).write(to: documents.appendingPathComponent("live-pair-metadata.json"))
                record("READ: \(all.count) library entries")
                let groups = Dictionary(grouping: all.filter { $0.thumbnailSource != nil }, by: { $0.thumbnailSource!.id })
                record("Shared thumbnail unit groups: \(groups.values.filter { $0.count > 1 }.count)")
                let timed = Dictionary(grouping: all.filter { $0.time != nil }, by: { "\($0.folder_id ?? -1)|\($0.time!)" })
                for group in timed.values.filter({ $0.contains(where: \.isLive) && $0.contains(where: { $0.type == "photo" }) }).prefix(3) {
                    for photo in group {
                        let file = try await client.original(photo, shared: false)
                        defer { try? FileManager.default.removeItem(at: file) }
                        if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                            let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
                            record("METADATA \(photo.id) \(photo.filename) Apple identifiers: \(maker?.filter { ($0.value as? String).flatMap(UUID.init(uuidString:)) != nil } ?? [:])")
                        }
                    }
                }
                record("FINISHED"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--background-backup-test") {
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
                let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
                    UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                }
                let file = documents.appendingPathComponent("Background-Validation.jpg")
                try data.write(to: file)
                let queue = TransferQueue(account: "background-test-" + UUID().uuidString)
                try await queue.enqueue(file, filename: "Background-Validation.jpg", folder: "/Fotera Validation", shared: false)
                record("READY: leave Fotera for the Home Screen to test background upload and verification")
                while UIApplication.shared.applicationState == .active { try await Task.sleep(for: .milliseconds(250)) }
                let token: UIBackgroundTaskIdentifier = ProcessInfo.processInfo.arguments.contains("--continued-backup-test") ? .invalid : UIApplication.shared.beginBackgroundTask(withName: "Backup verification test", expirationHandler: nil)
                defer { if token != .invalid { UIApplication.shared.endBackgroundTask(token) } }
                record("RUNNING: app is backgrounded")
                let healthy = await queue.process(client: client, wifiOnly: false, verify: true, deadline: Date().addingTimeInterval(20), maxInFlight: 1, verifyAllowed: true)
                guard healthy, queue.records.first?.state == .verified,
                      UIApplication.shared.applicationState != .active else { throw ConnectionError.invalidResponse }
                record("PASS: upload completed and downloaded original verified while app remained backgrounded")
                record("FINISHED BACKGROUND TEST"); return
            }
            if ProcessInfo.processInfo.arguments.contains("--backup-diagnostics") {
                let data = try Data(contentsOf: documents.appendingPathComponent("backup-verification-fixtures.json"))
                let fixtures = try JSONDecoder().decode([TransferRecord].self, from: data)
                let queue = TransferQueue(account: "read-only-backup-diagnostics")
                for recordToCheck in fixtures {
                    let download = try await queue.verificationDownload(recordToCheck, client: client)
                    defer { try? FileManager.default.removeItem(at: download) }
                    let expected = recordToCheck.digest
                    var matches = try TransferQueue.digest(download).0 == expected
                    if !matches, let package = try? OriginalPackage.unpack(download) {
                        defer { try? FileManager.default.removeItem(at: package.directory) }
                        matches = try package.files.contains { try TransferQueue.digest($0).0 == expected }
                    }
                    guard matches else { throw TransferError.mismatch }
                    record("PASS: uploaded resource \(recordToCheck.remoteID ?? 0) matches the iPhone's original digest")
                }
                // A retired upload ID must resolve to the current combined Live Photo in the same folder.
                if var companion = fixtures.first(where: { ($0.filename as NSString).pathExtension.lowercased() == "mov" }) {
                    companion.remoteID = Int(Int32.max)
                    let download = try await queue.verificationDownload(companion, client: client)
                    defer { try? FileManager.default.removeItem(at: download) }
                    let package = try OriginalPackage.unpack(download)
                    defer { try? FileManager.default.removeItem(at: package.directory) }
                    guard try package.files.contains(where: { try TransferQueue.digest($0).0 == companion.digest }) else { throw TransferError.mismatch }
                    record("PASS: retired Live Photo component ID resolves to the combined item and matches original video bytes")
                }
                var delayed = fixtures[0]; delayed.state = .uploaded; delayed.verificationRetryAt = Date().addingTimeInterval(60)
                var ready = fixtures[0]; ready.state = .uploaded; ready.verificationRetryAt = nil
                guard !delayed.readyForVerification, ready.readyForVerification,
                      [delayed, ready].filter(\.readyForVerification).count == 1 else { throw ConnectionError.invalidResponse }
                record("PASS: delayed verification does not block the next item")
                record("FINISHED DIAGNOSTICS"); return
            }
            let iso = ISO8601DateFormatter()
            func fixture(_ id: Int, _ value: String) -> RemotePhoto {
                RemotePhoto(id: id, filename: "memory-\(id).jpg", time: iso.date(from: value)!.timeIntervalSince1970, type: "photo", additional: nil)
            }
            let dates = [fixture(1, "2025-11-12T23:59:59Z"), fixture(2, "2025-11-13T00:00:00Z"),
                         fixture(3, "2025-11-13T23:59:59Z"), fixture(4, "2025-11-14T00:00:00Z"),
                         fixture(5, "2026-11-13T12:00:00Z")]
            let central = TimeZone(identifier: "America/Chicago")!
            // UTC is already November 14, but the phone is still on November 13.
            let memories = LibraryStore.memories(from: dates, now: iso.date(from: "2026-11-14T04:00:00Z")!, timeZone: central)
            guard memories.count == 1, memories[0].items.map(\.id) == [2, 3], memories[0].title == "1 year ago" else { throw ConnectionError.invalidResponse }
            let nextDay = LibraryStore.memories(from: dates, now: iso.date(from: "2026-11-14T06:00:00Z")!, timeZone: central)
            guard nextDay.flatMap(\.items).map(\.id) == [4] else { throw ConnectionError.invalidResponse }
            let leap = [fixture(6, "2024-02-29T12:00:00Z")]
            guard LibraryStore.memories(from: leap, now: iso.date(from: "2025-03-01T12:00:00Z")!, timeZone: central).isEmpty else { throw ConnectionError.invalidResponse }
            record("PASS: Memories matches exact local day, excludes adjacent/current-year dates, and handles midnight and leap day")
            let legacy = try JSONDecoder().decode(BackupPreferences.self, from: Data("{}".utf8))
            guard !legacy.organizeByMonth,
                  BackupPreferences.dateFolders(for: Date(timeIntervalSince1970: 1709251200), timeZone: TimeZone(secondsFromGMT: 0)!) == ["2024", "03"],
                  BackupPreferences.dateFolders(for: Date(timeIntervalSince1970: 1709251200), timeZone: TimeZone(secondsFromGMT: -21600)!) == ["2024", "02"],
                  BackupPreferences.dateFolders(for: nil) == ["Unknown Date"] else { throw ConnectionError.invalidResponse }
            record("PASS: backup folder dates handle month boundaries, missing dates, and legacy settings")
            let photosRoot = try await client.folder(path: "/", shared: false)
            guard photosRoot.name == "/" else { throw ConnectionError.invalidResponse }
            record("PASS: Personal Space root resolved from NAS")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let cache = LibraryCache(root: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let item = RemotePhoto(id: 100, filename: "test.jpg", time: 100, type: "photo", additional: nil)
            try await cache.write(account: "A", snapshot: .init(photos: [item], updated: Date()))
            await cache.savePreview(key: "A|preview", data: Data([1, 2, 3]))
            guard await cache.read(account: "A")?.photos.count == 1, await cache.preview(key: "A|preview") == Data([1, 2, 3]),
                  await cache.read(account: "B") == nil else { throw ConnectionError.invalidResponse }
            record("PASS: cache persists metadata and previews; accounts remain isolated")

            // Synology times are wall-clock values encoded as UTC.
            let sample = Date(timeIntervalSince1970: 1_780_739_985)
            guard PhotoTime.format(sample, .dateTime.hour(.twoDigits(amPM: .omitted)).minute()) .contains("59") else { throw ConnectionError.invalidResponse }
            record("PASS: capture times format as wall-clock time")

            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
            let jpeg = renderer.jpegData(withCompressionQuality: 0.9) { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            let file = documents.appendingPathComponent("Fotera-Validation.jpg")
            try jpeg.write(to: file, options: .atomic)
            let account = "verification-" + UUID().uuidString
            let queue = TransferQueue(account: account)
            try await queue.enqueue(file, filename: "Fotera-Validation.jpg", folder: "/Fotera Validation", shared: false, sourceID: "fixture")
            try await queue.enqueue(file, filename: "Fotera-Validation.jpg", folder: "/Fotera Validation", shared: false, sourceID: "fixture")
            guard queue.records.count == 1, queue.records[0].digest != nil else { throw ConnectionError.invalidResponse }
            queue.simulateInterruptedUpload()
            let restored = TransferQueue(account: account)
            guard restored.records.count == 1, restored.contains(sourceID: "fixture"), restored.failure == nil else { throw ConnectionError.invalidResponse }
            record("PASS: queue survives recreation and deduplicates resources")
            if (try? await client.folder(path: "/Fotera Validation", shared: false)) == nil {
                let root = try await client.folder(path: "/", shared: false)
                _ = try await client.createFolder(parent: root.id, name: "Fotera Validation", shared: false)
            }
            let validation = try await client.folder(path: "/Fotera Validation", shared: false)
            let dated = try await client.ensureBackupFolders(base: validation, components: ["2024", "02"], shared: false)
            let reused = try await client.ensureBackupFolders(base: validation, components: ["2024", "02"], shared: false)
            let readback = try await client.folder(path: "/Fotera Validation/2024/02", shared: false)
            guard dated.id == reused.id, dated.id == readback.id else { throw ConnectionError.invalidResponse }
            let dateQueue = TransferQueue(account: account + "-dated")
            try await dateQueue.enqueue(file, filename: "Fotera-Validation.jpg", folder: dated.name, shared: false, sourceID: "dated-fixture")
            await dateQueue.process(client: client, wifiOnly: false, verify: true)
            guard dateQueue.records.first?.state == .verified else { throw ConnectionError.invalidResponse }
            record("PASS: year/month folders created, reused, and uploaded original verified byte for byte")
            record("RUNNING: reconciling interrupted upload and verifying against the NAS")
            await restored.process(client: client, wifiOnly: false, verify: true)
            guard let result = restored.records.first else { throw ConnectionError.invalidResponse }
            record("Upload result: " + result.state.rawValue + " — " + (result.message ?? ""))
            guard result.state == .verified, let id = result.remoteID else { throw ConnectionError.invalidResponse }
            record("PASS: NAS original matches uploaded JPEG byte for byte")

            let favorite = try await client.favorite(id: id, shared: false)
            try await client.setFavorite(ids: [id], shared: false, value: !favorite)
            try await client.setFavorite(ids: [id], shared: false, value: favorite)
            record("PASS: favorite write and restoration read back from NAS")
            if let album = try await client.allAlbums().first(where: { $0.name == "Validation Album" }) {
                try await client.changeAlbumItems(id: album.id, items: [id], adding: true)
                try await client.changeAlbumItems(id: album.id, items: [id], adding: false)
                record("PASS: add/remove album membership read back from NAS; cover present: \(album.cover != nil)")
                _ = try await client.albumSharing(id: album.id)
                record("PASS: album sharing state read without changing access")
            }
            let matches = try await client.search(keyword: "Fotera-Validation", shared: false, offset: 0)
            record("PASS: search decoded; \(matches.count) matches")
            let details = try await client.details(id: id, shared: false)
            record("PASS: details decoded; resolution \(details.additional?.resolution.map { "\($0.width)x\($0.height)" } ?? "none")")
            let people = try await client.people(shared: false)
            let places = try await client.places(shared: false)
            let things = try await client.concepts(shared: false)
            record("PASS: explore decoded; \(people.count) people, \(places.count) places, \(things.count) things")
            if let person = people.first, let cover = person.cover(kind: "person") {
                let face = try await client.thumbnail(cover, shared: false, size: .sm)
                let personItems = try await client.items(.person(person.id), shared: false, offset: 0, limit: 5)
                record("PASS: person thumbnail \(face.count) bytes; \(personItems.count) person items")
            }
            let total = try await client.count(shared: false)
            let indexed = try await client.items(.all, shared: false, offset: 0, withLocation: true)
            record("PASS: count \(total); first page \(indexed.count) items, \(indexed.filter { $0.additional?.gps != nil }.count) with GPS")
            let favorites = try await client.items(.favorites, shared: false, offset: 0)
            record("PASS: favorites list decoded; \(favorites.count) items")
            if let video = indexed.first(where: \.isVideo) {
                let url = try await client.streamingURL(id: video.id, shared: false)
                let (bytes, response) = try await URLSession.shared.data(for: {
                    var request = URLRequest(url: url); request.setValue("bytes=0-1023", forHTTPHeaderField: "Range"); return request
                }())
                let http = response as? HTTPURLResponse
                record("PASS: streaming responded \(http?.statusCode ?? 0), \(bytes.count) bytes, ranges: \(http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "none"), type: \(http?.mimeType ?? "?")")
            }
            _ = try await client.recycleBinEnabled(shared: false)
            record("PASS: recycle-bin capability read without deleting any photos")
        } catch { record("FAIL: " + error.localizedDescription) }
        record("FINISHED")
    }
}
#endif

import XCTest
import UIKit
import ZIPFoundation
@testable import Fotera

/// Unit tests for logic that doesn't need a NAS. NAS round trips stay in the DEBUG `--fotera-verify` harness.
final class FoteraTests: XCTestCase {
    private func photo(_ id: Int, _ name: String = "IMG.HEIC", time: Double? = 1_780_739_985, type: String = "photo",
                       size: Int64? = 1_000, duration: Int? = nil) -> RemotePhoto {
        var item = RemotePhoto(id: id, filename: name, time: time, type: type, additional: nil)
        item.filesize = size
        if let duration { item.additional = .init(thumbnail: nil, gps: nil, video_meta: .init(duration: duration)) }
        return item
    }

    @MainActor
    func testDeletionUpdatesTimelineWithoutRefresh() async throws {
        var local = photo(-1); local.localAssetID = "phone-a"
        let store = LibraryStore(remotePhotos: [photo(42)], phonePhotos: [local])
        store.remove(ids: [42])
        store.remove(ids: [], localAssetIDs: ["phone-a"])
        // Let pending merges and section builds finish: neither may restore old photos.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.photos.isEmpty)
        XCTAssertTrue(store.gridSections.isEmpty)
        XCTAssertTrue(store.remotePhotos.isEmpty)
    }

    @MainActor
    func testNASOnlyDeletionKeepsPhoneCopyAndGroupingDoesNotDropUpdate() async throws {
        var local = photo(-1); local.localAssetID = "phone-a"
        let store = LibraryStore(remotePhotos: [photo(42)], phonePhotos: [local])
        store.remove(ids: [42])
        store.grouping = .month
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.photos.map(\.id), [-1])
        XCTAssertEqual(store.sections.flatMap(\.items).map(\.id), [-1])
        XCTAssertTrue(store.remotePhotos.isEmpty)
    }

    @MainActor
    func testPhoneOnlyDeletionPreservesOtherPhotos() async throws {
        var first = photo(-1); first.localAssetID = "phone-a"
        var second = photo(-2, "OTHER.HEIC"); second.localAssetID = "phone-b"
        let store = LibraryStore(phonePhotos: [first, second])
        store.remove(ids: [], localAssetIDs: ["phone-a"])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.photos.map(\.id), [-2])
        XCTAssertEqual(store.sections.flatMap(\.items).map(\.id), [-2])
    }

    func testUnifiedLibraryMergesOneLocalCopyAndKeepsNASIdentity() {
        var local = photo(UnifiedLibrary.localID("phone-a"), "IMG.HEIC")
        local.localAssetID = "phone-a"; local.localVersion = 100
        let merged = UnifiedLibrary.merge(remote: [photo(42)], local: [local])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, 42)
        XCTAssertEqual(merged.first?.localAssetID, "phone-a")
        XCTAssertFalse(merged.first!.isLocalOnly)
    }
    func testUnifiedLibraryPreservesAmbiguousAndDifferentMedia() {
        var local = photo(-1); local.localAssetID = "phone-a"
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1), photo(2)], local: [local]).count, 3)
        var other = local; other = RemotePhoto(id: -2, filename: other.filename, time: other.time, type: other.type, localAssetID: "phone-b")
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1)], local: [local, other]).count, 3)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1, type: "video")], local: [local]).count, 2)
        var sharedAlbum = photo(1); sharedAlbum.passphrase = "shared-token"
        XCTAssertEqual(UnifiedLibrary.merge(remote: [sharedAlbum], local: [local]).count, 2)
    }
    func testUnifiedLibraryRestoresPhoneOnlyItemAfterNASDeletion() {
        var local = photo(-1); local.localAssetID = "phone-a"
        let merged = UnifiedLibrary.merge(remote: [], local: [local])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isLocalOnly)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1)], local: []).first?.localAssetID, nil)
        XCTAssertLessThan(UnifiedLibrary.localID("phone-a"), 0)
        XCTAssertEqual(UnifiedLibrary.localID("phone-a"), UnifiedLibrary.localID("phone-a"))
        XCTAssertNotEqual(UnifiedLibrary.localID("phone-a"), UnifiedLibrary.localID("phone-b"))
    }
    func testUnifiedLibrarySortsAndDoesNotMergeUnknownDates() {
        var local = photo(-1, time: nil); local.localAssetID = "phone-a"
        let merged = UnifiedLibrary.merge(remote: [photo(2, time: 20), photo(1, time: 10)], local: [local])
        XCTAssertEqual(merged.map(\.id), [2, 1, -1])
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1, time: nil)], local: [local]).count, 2)
    }

    func testUnifiedLibraryMatchesNASLivePhotoToPhoneStill() {
        // Regression from IMG_3288: the phone no longer advertises Live Photo motion.
        var local = photo(-1, "IMG_3288.heic", time: 1792165272.385, type: "photo")
        local.localAssetID = "phone-still"; local.localCaptureTime = 1792183272.385
        let remote = photo(86, "IMG_3288.heic", time: 1792165272, type: "live")
        let result = UnifiedLibrary.merge(remote: [remote], local: [local])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 86)
        XCTAssertEqual(result.first?.localAssetID, "phone-still")
        XCTAssertTrue(result.first?.isLive == true)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(86, "IMG_3288.mov", time: 1792165272, type: "video")], local: [local]).count, 2)
    }

    func testUnifiedLibraryHandlesUTCAndCaptureTimeZoneDifferences() {
        var local = photo(-1, time: 1_700_000_000 - 6 * 3600)
        local.localAssetID = "phone"; local.localCaptureTime = 1_700_000_000
        // NAS imports may use UTC or the camera's original time zone rather than the phone's current zone.
        for offset in [Double(0), 3600, 19800, -25200] {
            let result = UnifiedLibrary.merge(remote: [photo(1, time: 1_700_000_000 + offset + 0.6)], local: [local])
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].localAssetID, "phone")
        }
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1, time: 1_700_000_000 + 86400)], local: [local]).count, 2)
    }
    func testUnifiedLibraryHandlesLiveStillAndResourceNames() {
        var local = photo(-1, "IMG_1234.HEIC", type: "live"); local.localAssetID = "phone"
        local.localResourceNames = ["IMG_1234.HEIC", "FullSizeRender.JPG"]
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1, "IMG_1234.JPG")], local: [local]).count, 1)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1, "FullSizeRender.JPG")], local: [local]).count, 1)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1, "IMG_1234.MOV", type: "video")], local: [local]).count, 2)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1, "IMG_1234-edited-123.JPG")], local: [local]).count, 2)
    }
    func testUnifiedLibraryPrefersExactTimeAndKeepsAmbiguity() {
        var first = photo(-1, time: 1_700_000_000); first.localAssetID = "first"
        var other = photo(-2, time: 1_700_000_000 + 3600); other.localAssetID = "other"
        let result = UnifiedLibrary.merge(remote: [photo(1, time: 1_700_000_000 + 0.9)], local: [first, other])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first(where: { $0.id == 1 })?.localAssetID, "first")
        let ambiguous = UnifiedLibrary.merge(remote: [photo(1, time: 1_700_000_000 + 7200)], local: [first, other])
        XCTAssertEqual(ambiguous.count, 3)
    }
    func testUnifiedLibraryUsesUploadIdentityForRenamedPhotos() {
        var local = photo(-1, "original.heic", time: nil); local.localAssetID = "phone"; local.localVersion = 100
        let link = UploadPhotoLink(remoteID: 42, localID: "phone", shared: false, created: Date(timeIntervalSince1970: 101))
        let remote = photo(42, "renamed.heic", time: nil)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [remote], local: [local], links: [link]).count, 1)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [remote], local: [local], links: [link], shared: true).count, 2)
        local.localVersion = 110
        XCTAssertEqual(UnifiedLibrary.merge(remote: [remote], local: [local], links: [link]).count, 2)
    }
    func testUnifiedLibraryDoesNotGuessConflictingUploadIdentities() {
        var first = photo(-1, "a.heic", time: nil); first.localAssetID = "a"
        var other = photo(-2, "b.heic", time: nil); other.localAssetID = "b"
        let links = ["a", "b"].map { UploadPhotoLink(remoteID: 1, localID: $0, shared: false, created: Date()) }
        XCTAssertEqual(UnifiedLibrary.merge(remote: [photo(1, "renamed.heic", time: nil)], local: [first, other], links: links).count, 3)
    }
    func testUploadIdentityRequiresFinishedTransferAndSurvivesEncoding() throws {
        var record = TransferRecord(id: UUID(), filename: "IMG.HEIC", folder: "/", shared: false, state: .uploaded, remoteID: 42, created: Date(), sourceID: "false|0|asset/L0/001|1|0")
        XCTAssertNil(UploadPhotoLink(record: record))
        record.state = .verified
        let link = try XCTUnwrap(UploadPhotoLink(record: record))
        let decoded = try JSONDecoder().decode(UploadPhotoLink.self, from: JSONEncoder().encode(link))
        XCTAssertEqual(decoded.localID, "asset/L0/001")
        XCTAssertEqual(decoded.remoteID, 42)
        XCTAssertFalse(decoded.shared)
    }
    func testUnifiedLargeLibraryMatchingKeepsAllUniqueItems() {
        let remote = (1...10_000).map { photo($0, "IMG_\($0).HEIC", time: Double($0 * 10)) }
        let local = remote.map { item -> RemotePhoto in
            var result = photo(-item.id, item.filename, time: (item.time ?? 0) + 0.8)
            result.localAssetID = "phone-\(item.id)"; return result
        }
        let merged = UnifiedLibrary.merge(remote: remote, local: local)
        XCTAssertEqual(merged.count, 10_000)
        XCTAssertTrue(merged.allSatisfy { $0.id > 0 && $0.localAssetID != nil })
    }

    func testPhoneDeletionRequiresContentMatchAndValidSourceIdentity() {
        XCTAssertEqual(PhoneDeletionMatch.sourceAssetID("false|12|ABC/L0/001|1|0"), "ABC/L0/001")
        XCTAssertEqual(PhoneDeletionMatch.sourceAssetID("true|12|ABC/L0/001|5|1|e123"), "ABC/L0/001")
        XCTAssertNil(PhoneDeletionMatch.sourceAssetID("IMG_1234.HEIC"))
        XCTAssertNil(PhoneDeletionMatch.sourceAssetID("false|12||1|0"))
        XCTAssertFalse(PhoneDeletionMatch.sameContent(remote: ["nas-hash"], local: "different-phone-hash"))
        XCTAssertFalse(PhoneDeletionMatch.sameContent(remote: [""], local: ""))
        XCTAssertTrue(PhoneDeletionMatch.sameContent(remote: ["still-hash", "motion-hash"], local: "still-hash"))
    }

    @MainActor func testWidgetPreviewHasBoundedPixelDimensions() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let decoded = try XCTUnwrap(UIImage(data: WidgetSnapshot.previewData(image))?.cgImage)
        XCTAssertEqual(decoded.width, 600)
        XCTAssertEqual(decoded.height, 300)
    }
    @MainActor func testWidgetRefreshRepairsMissingOrInvalidSnapshots() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        let valid = WidgetSnapshot(title: "Test", image: WidgetSnapshot.previewData(image), date: Date())
        XCTAssertTrue(WidgetSnapshot.needsRefresh(stamp: "today", savedStamp: "today", snapshots: []))
        XCTAssertTrue(WidgetSnapshot.needsRefresh(stamp: "today", savedStamp: "today", snapshots: [.init(title: "Bad", image: Data(), date: Date())]))
        XCTAssertTrue(WidgetSnapshot.needsRefresh(stamp: "new account", savedStamp: "today", snapshots: [valid]))
        XCTAssertFalse(WidgetSnapshot.needsRefresh(stamp: "today", savedStamp: "today", snapshots: [valid]))
    }

    func testLiveDuplicateCheckAcceptsPlainStillAndRejectsCorruptArchive() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: file) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try image.write(to: file)
        let stillHashes = try await TransferQueue.originalDigests(file, live: true)
        XCTAssertEqual(stillHashes, [try TransferQueue.digest(file).0])
        try Data("not an image or a complete ZIP".utf8).write(to: file)
        do { _ = try await TransferQueue.originalDigests(file, live: true); XCTFail("Corrupt payload must not be accepted") } catch {}
    }
    func testLiveDuplicateCheckHashesEveryArchiveResource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("still.heic"), motion = directory.appendingPathComponent("motion.mov")
        try Data("still content".utf8).write(to: still); try Data("motion content".utf8).write(to: motion)
        let zip = directory.appendingPathComponent("live.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: still.lastPathComponent, relativeTo: directory)
        try archive.addEntry(with: motion.lastPathComponent, relativeTo: directory)
        let hashes = try await TransferQueue.originalDigests(zip, live: true)
        XCTAssertTrue(hashes.contains(try TransferQueue.digest(still).0))
        XCTAssertTrue(hashes.contains(try TransferQueue.digest(motion).0))
        XCTAssertFalse(hashes.contains("different content"))
    }

    func testHEICPreviewEligibility() {
        XCTAssertTrue(ImagePipeline.isHEIC(photo(1, "IMPORTED.HEIC", size: nil)))
        XCTAssertTrue(ImagePipeline.isHEIC(photo(2, "photo.heif")))
        XCTAssertFalse(ImagePipeline.isHEIC(photo(3, "video.heic", type: "video")))
        XCTAssertFalse(ImagePipeline.isHEIC(photo(4, "photo.dng")))
    }

    func testLoginNegotiationUsesOnlySupportedVersions() {
        XCTAssertEqual(DSMClient.loginVersion(APIInfo(path: "entry.cgi", minVersion: 1, maxVersion: 7)), 7)
        XCTAssertEqual(DSMClient.loginVersion(APIInfo(path: "entry.cgi", minVersion: 1, maxVersion: 6)), 6)
        XCTAssertNil(DSMClient.loginVersion(APIInfo(path: "entry.cgi", minVersion: 8, maxVersion: 9)))
        XCTAssertNil(DSMClient.loginVersion(APIInfo(path: "entry.cgi", minVersion: 1, maxVersion: 5)))
    }

    func testLoginChallengeIsScopedAndExpires() {
        let now = Date()
        let challenge = LoginChallenge(username: "first", password: "original", token: "challenge", created: now)
        XCTAssertEqual(challenge.continuation(username: "first", password: "original", otp: "123456", now: now), "challenge")
        XCTAssertNil(challenge.continuation(username: "second", password: "original", otp: "123456", now: now))
        XCTAssertNil(challenge.continuation(username: "first", password: "changed", otp: "123456", now: now))
        XCTAssertNil(challenge.continuation(username: "first", password: "original", otp: "", now: now))
        XCTAssertNil(challenge.continuation(username: "first", password: "original", otp: "123456", now: now.addingTimeInterval(300)))
    }
    func testAuthenticationChallengeDecodingPreservesOtherAPIErrors() throws {
        let challenge = try JSONDecoder().decode(APIError.self, from: Data(#"{"code":403,"errors":{"token":"temporary-challenge","types":[{"type":"otp"}]}}"#.utf8))
        XCTAssertEqual(challenge.errors?.token, "temporary-challenge")
        let other = try JSONDecoder().decode(APIError.self, from: Data(#"{"code":105,"errors":[{"code":1}]}"#.utf8))
        XCTAssertEqual(other.code, 105)
        XCTAssertNil(other.errors)
    }

    func testRecentRefreshMergesNewItemsAndUpdatedMetadata() {
        let known = [photo(3), photo(2), photo(1)]
        let updated = photo(3, "updated.heic")
        let merged = LibraryStore.mergeRecent(known: known, page: [photo(4), updated, photo(2)], total: 4)
        XCTAssertEqual(merged?.map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(merged?[1].filename, "updated.heic")
        XCTAssertEqual(LibraryStore.mergeRecent(known: known, page: [photo(3), photo(2)], total: 3), known)
    }
    func testRecentRefreshRequiresReconciliationForAmbiguousChanges() {
        let known = [photo(3), photo(2), photo(1)]
        XCTAssertNil(LibraryStore.mergeRecent(known: known, page: [photo(3), photo(2)], total: 4)) // older import
        XCTAssertNil(LibraryStore.mergeRecent(known: known, page: [photo(3), photo(2)], total: 2)) // deletion
        XCTAssertNil(LibraryStore.mergeRecent(known: known, page: [photo(4), photo(3)], total: 3)) // replacement
        XCTAssertNil(LibraryStore.mergeRecent(known: known, page: [photo(5), photo(4)], total: 5)) // no overlap
        XCTAssertNil(LibraryStore.mergeRecent(known: known, page: [photo(3), photo(3)], total: 3))
    }
    func testMemoryCoverRetainsStillForOriginalFallback() {
        let still = photo(2, "missing-preview.heic")
        let memory = Memory(id: "test", title: "Test", items: [photo(1, type: "video"), still])
        XCTAssertEqual(memory.cover?.id, still.id)
        XCTAssertNil(memory.cover?.thumbnailSource)
    }

    private func locatedPhoto(_ id: Int, latitude: Double, longitude: Double) -> RemotePhoto {
        var item = photo(id)
        item.additional = .init(thumbnail: nil, gps: .init(latitude: latitude, longitude: longitude), video_meta: nil)
        return item
    }
    func testLargePhotoMapHasBoundedMarkersAndRetainsEveryItem() throws {
        let photos = (0..<100_000).map { locatedPhoto($0, latitude: Double($0 % 160) - 80,
                                                    longitude: Double(($0 * 17) % 360) - 180) }
        let clusters = try PhotoMapClustering.build(photos, viewport: .world)
        XCTAssertLessThanOrEqual(clusters.count, 64)
        XCTAssertEqual(clusters.reduce(0) { $0 + $1.items.count }, photos.count)
        XCTAssertEqual(Set(clusters.flatMap(\.items).map(\.id)).count, photos.count)
    }
    func testMapFiltersViewportAndHandlesDateLineAndInvalidGPS() throws {
        let items = [locatedPhoto(1, latitude: 1, longitude: 179), locatedPhoto(2, latitude: 1, longitude: -179),
                     locatedPhoto(3, latitude: 0, longitude: 0), locatedPhoto(4, latitude: .nan, longitude: 0),
                     locatedPhoto(5, latitude: 91, longitude: 0)]
        let clusters = try PhotoMapClustering.build(items, viewport: .init(latitude: 0, longitude: 180, latitudeSpan: 20, longitudeSpan: 20))
        XCTAssertEqual(Set(clusters.flatMap(\.items).map(\.id)), [1, 2])
        XCTAssertTrue(clusters.allSatisfy { abs($0.longitude) > 170 })
    }
    func testMapClusteringHonorsCancellation() async {
        let task = Task { () throws -> [PhotoMapCluster] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try PhotoMapClustering.build([], viewport: .world)
        }
        do { _ = try await task.value; XCTFail("Cancelled clustering must not publish results") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    // MARK: Time

    func testCaptureTimeIsWallClockNotDeviceTimeZone() {
        // 1780739985 is 2026-06-06 09:59:45 as Synology stores it (wall clock encoded as UTC).
        let date = Date(timeIntervalSince1970: 1_780_739_985)
        XCTAssertEqual(PhotoTime.calendar.component(.hour, from: date), 9)
        XCTAssertEqual(PhotoTime.calendar.component(.minute, from: date), 59)
    }
    func testDayTitleAddsYearOnlyForOtherYears() {
        let lastYear = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        let wallClock = PhotoTime.calendar.date(from: Calendar.current.dateComponents([.year, .month, .day], from: lastYear))!
        XCTAssertTrue(PhotoTime.dayTitle(wallClock).contains(String(Calendar.current.component(.year, from: lastYear))))
        let today = PhotoTime.calendar.date(from: Calendar.current.dateComponents([.year, .month, .day], from: Date()))!
        XCTAssertEqual(PhotoTime.dayTitle(today), "Today")
    }
    func testVideoDurationText() {
        XCTAssertEqual(photo(1, duration: 59_000).durationText, "0:59")
        XCTAssertEqual(photo(1, duration: 3_725_000).durationText, "1:02:05")
        XCTAssertNil(photo(1).durationText)
    }

    // MARK: Memories

    func testMemoriesMatchExactDayInEarlierYearsOnly() {
        let utc = TimeZone(identifier: "UTC")!
        var components = DateComponents(year: 2026, month: 11, day: 13, hour: 12)
        let now = PhotoTime.calendar.date(from: components)!
        components.year = 2024
        let twoYearsAgo = PhotoTime.calendar.date(from: components)!.timeIntervalSince1970
        components.year = 2025; components.day = 12
        let adjacentDay = PhotoTime.calendar.date(from: components)!.timeIntervalSince1970
        let memories = LibraryStore.memories(from: [photo(1, time: twoYearsAgo), photo(2, time: adjacentDay), photo(3, time: now.timeIntervalSince1970)],
                                             now: now, timeZone: utc)
        XCTAssertEqual(memories.map(\.title), ["2 years ago"])
        XCTAssertEqual(memories.first?.items.map(\.id), [1])
    }

    // MARK: Search

    func testLocalSearchMatchesFilenameDateAndFilters() {
        let items = [photo(1, "IMG_0001.HEIC"), photo(2, "clip.MOV", type: "video"), photo(3, "raw.DNG", time: 1_750_000_000)]
        XCTAssertEqual(LocalLibrarySearch.results(items, query: "0001", media: .all, year: nil).map(\.id), [1])
        XCTAssertEqual(LocalLibrarySearch.results(items, query: "2026-06-06", media: .all, year: nil).map(\.id), [1, 2])
        XCTAssertEqual(LocalLibrarySearch.results(items, query: "", media: .videos, year: nil).map(\.id), [2])
        XCTAssertEqual(LocalLibrarySearch.results(items, query: "", media: .raw, year: nil).map(\.id), [3])
        XCTAssertEqual(LocalLibrarySearch.results(items, query: "", media: .all, year: 2025).map(\.id), [3])
    }

    // MARK: Duplicates

    func testDuplicateFinderGroupsExactCopiesAndBursts() {
        let items = [
            photo(1, time: 1000, size: 5_000), photo(2, time: 1000, size: 5_000),          // exact copy
            photo(3, time: 2000, size: 8_000), photo(4, time: 2001, size: 8_040),          // burst (≤2 s, ≤1%)
            photo(5, time: 3000, size: 8_000), photo(6, time: 3010, size: 8_000),          // too far apart
            photo(7, time: 4000, type: "video", size: 8_000), photo(8, time: 4000, type: "video", size: 8_000), // videos ignored
        ]
        let groups = DuplicateFinder.groups(in: items)
        XCTAssertEqual(groups.count, 2)
        let idSets: Set<Set<Int>> = Set(groups.map { Set($0.items.map { $0.id }) })
        XCTAssertEqual(idSets, [[1, 2], [3, 4]])
        XCTAssertEqual(groups.first { $0.items.contains { $0.id == 1 } }?.exact, true)
        XCTAssertEqual(groups.first { $0.items.contains { $0.id == 3 } }?.exact, false)
    }

    func testSimilarGroupsUseTimeWindowAndSkipTakenItems() {
        let items = [photo(1, time: 100), photo(2, time: 130), photo(3, time: 500), photo(4, time: 520), photo(5, time: 900)]
        let groups = DuplicateFinder.similarGroups(items, excluding: [4])
        XCTAssertEqual(groups.map { $0.items.map { $0.id } }, [[1, 2]])
        XCTAssertTrue(groups.allSatisfy { $0.kind == .similar })
    }

    // MARK: Transfers

    @MainActor func testUniqueNameKeepsExtensionAndReplacesPreviousSuffix() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        XCTAssertEqual(TransferQueue.uniqueName("IMG_0001.HEIC", id: id), "IMG_0001_fotera-abcdef.HEIC")
        XCTAssertEqual(TransferQueue.uniqueName("IMG_0001_fotera-123456.HEIC", id: id), "IMG_0001_fotera-abcdef.HEIC")
        XCTAssertEqual(TransferQueue.uniqueName("README", id: id), "README_fotera-abcdef")
    }
    @MainActor func testVideoFileDetection() {
        XCTAssertTrue(TransferQueue.isVideoFile("IMG_0001.MOV"))
        XCTAssertTrue(TransferQueue.isVideoFile("clip.mp4"))
        XCTAssertFalse(TransferQueue.isVideoFile("IMG_0001.HEIC"))
    }
    func testUploadReceiptOutcomes() {
        func receipt(_ json: String, status: Int = 200, error: String? = nil, cancelled: Bool? = nil) -> UploadReceipt {
            UploadReceipt(data: Data(json.utf8), status: status, error: error, cancelled: cancelled)
        }
        if case .uploaded(let id) = receipt(#"{"success":true,"data":{"id":42}}"#).outcome { XCTAssertEqual(id, 42) } else { XCTFail() }
        if case .sessionExpired = receipt(#"{"success":false,"error":{"code":119}}"#).outcome {} else { XCTFail() }
        if case .sessionExpired = receipt(#"{"success":false,"error":{"code":150}}"#).outcome {} else { XCTFail("IP-bound session") }
        XCTAssertTrue(ConnectionError.server(150).isSessionExpired)
        if case .server(620) = receipt(#"{"success":false,"error":{"code":620}}"#).outcome {} else { XCTFail() }
        if case .failed = receipt("", status: 502).outcome {} else { XCTFail() }
        if case .cancelled = receipt("", status: 0, cancelled: true).outcome {} else { XCTFail() }
    }

    // MARK: Backup settings

    func testBackupFoldersUseCaptureYearAndMonth() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(BackupPreferences.dateFolders(for: Date(timeIntervalSince1970: 1_780_739_985), timeZone: utc), ["2026", "06"])
        XCTAssertEqual(BackupPreferences.dateFolders(for: nil), ["Unknown Date"])
    }
    func testLegacyBackupPreferencesDecodeWithDefaults() throws {
        let legacy = #"{"enabled":true,"shared":false,"includeExisting":true,"wifiOnly":true}"#
        let decoded = try JSONDecoder().decode(BackupPreferences.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertTrue(decoded.verify)
        XCTAssertTrue(decoded.verifyVideos)
        XCTAssertFalse(decoded.organizeByMonth)
    }

    func testLegacyConnectionProfileAndRemoteURLValidation() throws {
        let old = try JSONDecoder().decode(RouteProfile.self, from: Data(#"{"lan":"http://192.168.1.2:5000","quickConnect":"testnas","enabled":true,"identity":"test"}"#.utf8))
        XCTAssertNil(old.remoteURL)
        XCTAssertEqual(old.quickConnect, "testnas")
        XCTAssertEqual(try RouteProfile.remoteAddress(" https://nas.example.com:5001/ ")?.absoluteString, "https://nas.example.com:5001")
        XCTAssertThrowsError(try RouteProfile.remoteAddress("http://nas.example.com"))
        XCTAssertThrowsError(try RouteProfile.remoteAddress("https://user:pass@nas.example.com"))
        XCTAssertNil(try RouteProfile.remoteAddress(""))
    }
    func testConnectionPreferenceAndProfileRoundTrip() throws {
        let profile = RouteProfile(lan: "http://192.168.1.2:5000", quickConnect: "testnas", remoteURL: "https://nas.example.com:5001", enabled: true, identity: "test")
        let restored = try JSONDecoder().decode(RouteProfile.self, from: JSONEncoder().encode(profile))
        let current = try DSMClient.normalize(profile.lan)
        XCTAssertEqual(restored.directCandidates(current: current, canonical: "https://nas.example.com:5001").map(\.absoluteString),
                       ["http://192.168.1.2:5000", "https://nas.example.com:5001"])
    }

    func testRouteFailoverAndIdentityProtection() async throws {
        let profile = RouteProfile(lan: "http://192.168.1.2:5000", remoteURL: "https://nas.example.com", enabled: true, identity: "expected-nas")
        let local = try DSMClient.normalize(profile.lan)
        let remote = try XCTUnwrap(RouteProfile.remoteAddress(profile.remoteURL!))
        let home = await profile.verifiedDirectRoute(current: remote, canonical: remote.absoluteString) { _ in "expected-nas" }
        XCTAssertEqual(home, local)
        let away = await profile.verifiedDirectRoute(current: local, canonical: local.absoluteString) { url in
            if url.scheme == "http" { throw URLError(.cannotConnectToHost) }
            return "expected-nas"
        }
        XCTAssertEqual(away, remote)
        let wrong = await profile.verifiedDirectRoute(current: local, canonical: local.absoluteString) { _ in "different-nas" }
        XCTAssertNil(wrong)
    }

    func testRouteFailureDetectionDoesNotRetryCancellationOrTLSFailures() {
        XCTAssertTrue(DSMClient.isRouteFailure(URLError(.networkConnectionLost)))
        XCTAssertTrue(DSMClient.isRouteFailure(URLError(.cannotConnectToHost)))
        XCTAssertFalse(DSMClient.isRouteFailure(URLError(.cancelled)))
        XCTAssertFalse(DSMClient.isRouteFailure(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(DSMClient.isRouteFailure(AuthError.permissionDenied))
    }

    func testCellularSelectionNeverProbesSavedLANOrigins() async throws {
        let profile = RouteProfile(lan: "http://192.168.1.2:5000", remoteURL: "https://nas.example.com", enabled: true, identity: "nas")
        let local = try DSMClient.normalize(profile.lan)
        XCTAssertEqual(profile.directCandidates(current: local, canonical: profile.lan, allowLAN: false).map(\.absoluteString), ["https://nas.example.com"])
        let route = await profile.verifiedDirectRoute(current: local, canonical: profile.lan, allowLAN: false) { url in
            guard url.host == "nas.example.com" else { throw URLError(.timedOut) }
            return "nas"
        }
        XCTAssertEqual(route?.host, "nas.example.com")
    }
    func testRouteChangeComparesPortsAndSchemes() throws {
        XCTAssertTrue(DSMClient.sameOrigin(URL(string: "https://nas.example.com/webapi/entry.cgi")!, URL(string: "https://nas.example.com")!))
        XCTAssertFalse(DSMClient.sameOrigin(URL(string: "http://192.168.1.2:5000")!, URL(string: "https://192.168.1.2:5001")!))
    }

    // MARK: Connections

    func testAddressValidation() throws {
        XCTAssertEqual(try DSMClient.normalize("https://nas.example.com:5001/").absoluteString, "https://nas.example.com:5001")
        XCTAssertNoThrow(try DSMClient.normalize("http://192.168.1.20:5000"))
        XCTAssertThrowsError(try DSMClient.normalize("http://8.8.8.8"))
        XCTAssertThrowsError(try DSMClient.normalize("https://user:pass@nas.example.com"))
        XCTAssertThrowsError(try DSMClient.normalize("https://nas.example.com/photo"))
    }
    func testLANAndQuickConnectParsing() {
        XCTAssertTrue(ConnectionAddress.isLAN("192.168.68.66"))
        XCTAssertTrue(ConnectionAddress.isLAN("nas.local"))
        XCTAssertFalse(ConnectionAddress.isLAN("pics.example.com"))
        XCTAssertEqual(ConnectionAddress.quickConnectID("https://quickconnect.to/My-NAS"), "my-nas")
        XCTAssertNil(ConnectionAddress.quickConnectID("https://quickconnect.to.evil.example/my-nas"))
    }
    func testRecycleRestorePathRejectsTraversal() throws {
        XCTAssertEqual(try DSMClient.restoredPath("/home/#recycle/Photos/2026/a.jpg"), "/home/Photos/2026/a.jpg")
        XCTAssertThrowsError(try DSMClient.restoredPath("/home/#recycle/Photos/../secret"))
    }
}

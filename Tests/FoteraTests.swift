import XCTest
import SwiftUI
import UIKit
import ImageIO
import ZIPFoundation
@testable import Fotera

/// Unit tests for logic that doesn't need a NAS. NAS round trips stay in the DEBUG `--fotera-verify` harness.
final class FoteraTests: XCTestCase {
    func testLiveMotionResourceDoesNotReplaceStillPreview() {
        XCTAssertTrue(TransferQueue.isLiveCompanion("false|0|asset|9|1"))
        XCTAssertTrue(TransferQueue.isLiveCompanion("false|0|asset|10|2|e123"))
        XCTAssertFalse(TransferQueue.isLiveCompanion("false|0|asset|1|0"))
        XCTAssertFalse(TransferQueue.isLiveCompanion("false|0|asset|2|0"))
        XCTAssertFalse(TransferQueue.isLiveCompanion(nil))
    }

    func testUploadPreviewsAreBoundedJPEGsWithAspectRatioPreserved() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 800))
        try renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        }.write(to: file)
        let previews = try await UploadPreviews.generate(source: file, filename: "photo.jpg")
        XCTAssertEqual(previews.map(\.field), ["thumb_sm", "thumb_m", "thumb_xl"])
        for (preview, width) in zip(previews, [240, 320, 1280]) {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, width)
            XCTAssertEqual(image.height, width / 2)
        }
    }

    func testUnsupportedOriginalDoesNotGetFakeUploadPreview() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("unsupported".utf8).write(to: file)
        let previews = try await UploadPreviews.generate(source: file, filename: "unknown.bin")
        XCTAssertTrue(previews.isEmpty)
    }

    func testNotificationTapRoutesAndCompletesOnMainThread() async {
        let routed = expectation(description: "Backup route delivered")
        let completed = expectation(description: "System callback completed")
        completed.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(forName: .foteraOpenURL, object: nil, queue: nil) { note in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(note.object as? URL, URL(string: "fotera://backup"))
            routed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await Task.detached {
            NotificationRouter.shared.handleResponse(link: "fotera://backup") {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
        }.value
        await fulfillment(of: [routed, completed], timeout: 5, enforceOrder: true)
    }

    func testNotificationWithoutRouteStillCompletesOnMainThread() async {
        let completed = expectation(description: "Missing route completes")
        completed.assertForOverFulfill = true
        await Task.detached {
            NotificationRouter.shared.handleResponse(link: nil) {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
        }.value
        await fulfillment(of: [completed], timeout: 5)
    }

    func testPrefetchWindowStaysBoundedDuringFastScrolling() {
        var window = ThumbnailPrefetchWindow(limit: 16)
        for index in 0..<10_000 {
            let key = String(index)
            let evicted = window.insert(key)
            if index >= 16 { XCTAssertEqual(evicted, String(index - 16)) }
            XCTAssertLessThanOrEqual(window.keys.count, 16)
            XCTAssertNil(window.insert(key))
        }
        XCTAssertEqual(window.keys, (9984..<10_000).map(String.init))
        window.remove("9999")
        XCTAssertFalse(window.contains("9999"))
        XCTAssertNil(window.insert("new"))
    }

    func testCopyLocationAlwaysShowsKnownStorage() {
        for location in [PhotoCopyLocation.phone, .nas, .both, .nasUnchecked] {
            XCTAssertNotNil(UIImage(systemName: location.symbol))
        }
        let remote = photo(42)
        XCTAssertEqual(PhotoCopyLocation.resolve(remote, onPhone: nil), .nasUnchecked)
        XCTAssertFalse(PhotoCopyLocation.resolve(remote, onPhone: nil).symbol.isEmpty)
        XCTAssertEqual(PhotoCopyLocation.resolve(remote, onPhone: false), .nas)
        XCTAssertEqual(PhotoCopyLocation.resolve(remote, onPhone: true), .both)
        var merged = remote; merged.localAssetID = "phone-copy"
        XCTAssertEqual(PhotoCopyLocation.resolve(merged, onPhone: nil), .both)
        XCTAssertEqual(PhotoCopyLocation.resolve(merged, onPhone: false), .nas)
        var local = photo(-1); local.localAssetID = "phone-copy"
        XCTAssertEqual(PhotoCopyLocation.resolve(local, onPhone: nil), .phone)
    }

    func testLivePhotoBackupCountsOneItemUntilAllResourcesFinish() {
        let still = TransferRecord(id: UUID(), filename: "IMG_1.HEIC", folder: "/", shared: false,
            state: .uploading, created: Date(), sourceID: "false|1|assetA|1|0")
        var motion = TransferRecord(id: UUID(), filename: "IMG_1.MOV", folder: "/", shared: false,
            state: .uploading, created: Date(), sourceID: "false|1|assetA|9|1")
        XCTAssertEqual(BackupController.backupTransferDescription([still, motion]), "Backing up 1 item")
        motion.state = .verifying
        XCTAssertEqual(BackupController.backupItemCount([still, motion]), 1)
        XCTAssertEqual(BackupController.progressCounts(eligible: ["false|1|assetA"],
            staged: ["false|1|assetA"], pending: ["false|1|assetA"]).completed, 0)
        var verifiedStill = still
        verifiedStill.state = .verified
        XCTAssertEqual(BackupController.backupTransferDescription([verifiedStill, motion]), "Verifying 1 item")
        motion.state = .verified
        XCTAssertNil(BackupController.backupTransferDescription([verifiedStill, motion]))
        XCTAssertEqual(BackupController.progressCounts(eligible: ["false|1|assetA"],
            staged: ["false|1|assetA"], pending: []).completed, 1)
        let other = TransferRecord(id: UUID(), filename: "IMG_1.HEIC", folder: "/", shared: false,
            state: .uploading, created: Date(), sourceID: "false|1|assetB|1|0")
        XCTAssertEqual(BackupController.backupItemCount([still, motion, other]), 2)
        var manual = other; manual.sourceID = nil
        XCTAssertEqual(BackupController.backupItemCount([still, motion, manual]), 2)
    }

    func testTimelineStorageFiltersKeepGroupsAndExcludeEmptySections() {
        var device = photo(-1); device.localAssetID = "device"
        let cloud = photo(2)
        var both = photo(3); both.localAssetID = "both"
        let sections = [GridSection(id: "day", title: "Today", items: [device, cloud, both],
                                    group: "month", groupTitle: "November"),
                        GridSection(id: "empty", title: nil, items: [cloud])]
        XCTAssertEqual(TimelineStorageFilter.all.apply(to: sections).count, 2)
        let deviceResult = TimelineStorageFilter.deviceOnly.apply(to: sections)
        XCTAssertEqual(deviceResult.count, 1)
        XCTAssertEqual(deviceResult.first?.items.map(\.id), [-1])
        XCTAssertEqual(deviceResult.first?.group, "month")
        XCTAssertEqual(deviceResult.first?.groupTitle, "November")
        XCTAssertEqual(TimelineStorageFilter.cloudOnly.apply(to: sections).first?.items.map(\.id), [2])
        XCTAssertEqual(TimelineStorageFilter.both.apply(to: sections).first?.items.map(\.id), [3])
    }

    func testBackupProgressIgnoresRemovedAndExcludedAssets() {
        let counts = BackupController.progressCounts(eligible: ["current", "new", "uploading"],
            staged: ["old-deleted", "excluded-video", "current", "uploading"], pending: ["uploading"])
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.completed, 1)
        let empty = BackupController.progressCounts(eligible: [], staged: ["old-deleted"], pending: [])
        XCTAssertEqual(empty.completed, 0)
    }

    func testFavoriteSnapshotRequiresEveryPage() async throws {
        let first = (1...DSMClient.pageSize).map { photo($0) }
        do {
            _ = try await LibraryStore.favoriteIDs { offset in
                if offset == 0 { return first }
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("An incomplete snapshot must not replace saved favorites")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let complete = try await LibraryStore.favoriteIDs { offset in
            offset == 0 ? first : [self.photo(999)]
        }
        XCTAssertEqual(complete.count, DSMClient.pageSize + 1)
        XCTAssertTrue(complete.contains(999))
    }

    func testTimeoutIsDistinguishedFromUserCancellation() async {
        do {
            let _: Int = try await withTimeout(0.01) {
                try await Task.sleep(for: .seconds(30)); return 1
            }
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let task = Task {
            try await withTimeout(30) { try await Task.sleep(for: .seconds(30)); return 1 }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testFavoriteLookupRemainsConsistentDuringDeletion() async throws {
        let store = LibraryStore(remotePhotos: (1...200).map { photo($0) })
        try await Task.sleep(for: .milliseconds(50))
        for id in stride(from: 200, through: 1, by: -1) {
            store.remove(ids: [id])
            await Task.yield()
            let expected = store.photos.filter { [1, 100, 200].contains($0.id) }.map(\.id)
            XCTAssertEqual(store.favorites([1, 100, 200]).map(\.id), expected)
        }
    }

    func testCompletedBackupScanHasNoLiveActivityWork() {
        typealias State = BackupActivityAttributes.ContentState
        XCTAssertFalse(State(completed: 100, total: 100, awaitingVerification: 0, phase: .preparing).hasPendingWork)
        XCTAssertFalse(State(completed: 0, total: 0, awaitingVerification: 0, phase: .preparing).hasPendingWork)
        XCTAssertTrue(State(completed: 99, total: 100, awaitingVerification: 0, phase: .uploading).hasPendingWork)
        XCTAssertTrue(State(completed: 100, total: 100, awaitingVerification: 1, phase: .verifying).hasPendingWork)
    }

    func testAlbumPermissionsKeepPublicAndNamedUsersSeparate() throws {
        let data = Data(#"{"id":7,"shared":true,"additional":{"sharing_info":{"privacy_type":"private","permission":[{"role":"view","type":"user","id":12,"name":"test-user","db_id":3},{"role":"download","member":{"type":"public"}}]}}}"#.utf8)
        let state = try JSONDecoder().decode(AlbumSharingState.self, from: data)
        let grants = try XCTUnwrap(state.additional?.sharing_info?.permission)
        XCTAssertEqual(grants.count, 2)
        XCTAssertEqual(grants[0].member.id, 12)
        XCTAssertEqual(grants[0].role, "view")
        XCTAssertNil(grants[1].member.id)
        XCTAssertEqual(grants[1].member.type, "public")
    }

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
    func testNASMotionFileMarkedLiveMatchesPhoneVideo() {
        for name in ["IMG_0069+1.mov", "IMG_0067+1.MOV", "IMG_0208.mp4"] {
            let remote = photo(99, name, time: 100, type: "live")
            var local = photo(-1, name, time: 100, type: "video"); local.localAssetID = "phone"
            XCTAssertTrue(remote.isVideo)
            XCTAssertFalse(remote.isLive)
            let link = UploadPhotoLink(remoteID: 99, localID: "phone", shared: false, created: Date())
            let result = UnifiedLibrary.merge(remote: [remote], local: [local], links: [link])
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(PhotoCopyLocation.resolve(result[0], onPhone: nil), .both)
        }
        let still = photo(100, "IMG_0208.heic", type: "live")
        XCTAssertTrue(still.isLive)
        XCTAssertFalse(still.isVideo)
    }

    func testVerifiedEditedRenditionCanMatchPNGWithoutChangingItsFilename() {
        var local = photo(-1, "IMG_0226.PNG", time: 100); local.localAssetID = "phone"
        local.localResourceNames = ["IMG_0226.PNG", "FullSizeRender.jpeg"]
        let remote = photo(42, "IMG_0226.jpg", time: 900000)
        let link = UploadPhotoLink(remoteID: 42, localID: "phone", shared: false, created: Date())
        let merged = UnifiedLibrary.merge(remote: [remote], local: [local], links: [link])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].filename, "IMG_0226.jpg")
        XCTAssertEqual(merged[0].localAssetID, "phone")
        XCTAssertTrue(merged[0].localResourceNames?.contains("IMG_0226.PNG") == true)
    }

    func testRecoveredUploadIdentityMatchesRenamedPhotoWithDifferentDate() {
        var local = photo(-1, "IMG_0117.jpg", time: 1475625600.872)
        local.localAssetID = "phone"; local.localVersion = 100
        let remote = photo(50138, "IMG_0117+1.jpg", time: 1475708863)
        let stale = UploadPhotoLink(remoteID: 25161, localID: "phone", shared: false, created: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(UnifiedLibrary.merge(remote: [remote], local: [local], links: [stale]).filter(\.isLocalOnly).count, 1)
        let recovered = UploadPhotoLink(remoteID: 50138, localID: "phone", shared: false, created: Date(timeIntervalSince1970: 102))
        let links = TransferQueue.replacingLink(recovered, in: [stale])
        let result = UnifiedLibrary.merge(remote: [remote], local: [local], links: links)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.localAssetID, "phone")
        XCTAssertEqual(TransferQueue.replacingLink(recovered, in: links).count, 2)
        XCTAssertEqual(UnifiedLibrary.merge(remote: [], local: [local], links: links).filter(\.isLocalOnly).count, 1)
    }

    func testMultipleProvenNASCopiesDoNotCreateDeviceOnlyDuplicate() {
        var local = photo(-1, "original.jpg", time: nil); local.localAssetID = "phone"
        let remote = [photo(1, "copy-a.jpg", time: nil), photo(2, "copy-b.jpg", time: nil)]
        let links = [1, 2].map { UploadPhotoLink(remoteID: $0, localID: "phone", shared: false, created: Date()) }
        for order in [remote, remote.reversed().map { $0 }] {
            let result = UnifiedLibrary.merge(remote: order, local: [local], links: links)
            XCTAssertEqual(result.count, 2)
            XCTAssertTrue(result.allSatisfy { !$0.isLocalOnly })
            XCTAssertEqual(result.first(where: { $0.localAssetID != nil })?.id, 2)
        }
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

    func testWidgetTimelineChangesDayWithoutAppRefresh() throws {
        let calendar = WidgetMemorySchedule.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "America/Chicago")))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 23, minute: 30)))
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        let schedule = WidgetMemorySchedule(days: [
            "2026-11-15": [.init(title: "Yesterday's memory", image: Data([1]), date: start)],
            "2026-11-16": [.init(title: "Today's memory", image: Data([2]), date: midnight)]], fallback: [])
        let saved = try JSONDecoder().decode(WidgetMemorySchedule.self, from: JSONEncoder().encode(schedule))
        let dates = WidgetMemorySchedule.timelineDates(from: start, calendar: calendar)
        XCTAssertTrue(dates.contains(midnight))
        XCTAssertEqual(saved.snapshot(at: start, calendar: calendar)?.title, "Yesterday's memory")
        XCTAssertEqual(saved.snapshot(at: midnight, calendar: calendar)?.title, "Today's memory")
        XCTAssertEqual(saved.snapshot(at: midnight.addingTimeInterval(3600), calendar: calendar)?.image, Data([2]))
    }

    func testWidgetUsesEvergreenFallbackAfterDatedCacheExpires() throws {
        let calendar = WidgetMemorySchedule.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
        let schedule = WidgetMemorySchedule(days: ["2026-12-31": [.init(title: "1 year ago", image: Data([1]), date: date)]],
            fallback: [.init(title: "From your library", image: Data([2]), date: date)])
        XCTAssertEqual(schedule.snapshot(at: date, calendar: calendar)?.title, "From your library")
        XCTAssertNil(WidgetMemorySchedule(days: [:], fallback: []).snapshot(at: date))
    }

    func testWidgetTimelineIncludesMidnightAcrossDaylightSavingChanges() throws {
        let calendar = WidgetMemorySchedule.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "America/Chicago")))
        for (month, day) in [(3, 8), (11, 1)] {
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let dates = WidgetMemorySchedule.timelineDates(from: start, calendar: calendar)
            XCTAssertEqual(dates.count, 49)
            XCTAssertTrue(dates.contains(tomorrow))
            XCTAssertTrue(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
            XCTAssertEqual(WidgetMemorySchedule.dayKey(tomorrow, calendar: calendar), String(format: "2026-%02d-%02d", month, day + 1))
        }
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

extension FoteraTests {
    func testPeopleNameDraftSurvivesReopeningWithoutLeakingAcrossAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let first = PersonNameHistory(root:root)
        try await first.record(account:"first",id:5,shared:false,name:"Example name",confirmed:false)
        let reopened = PersonNameHistory(root:root)
        let draft = await reopened.entry(account:"first",id:5,shared:false)
        let anotherAccount = await reopened.entry(account:"second",id:5,shared:false)
        let sharedSpace = await reopened.entry(account:"first",id:5,shared:true)
        XCTAssertEqual(draft?.name,"Example name"); XCTAssertEqual(draft?.confirmed,false)
        XCTAssertNil(anotherAccount); XCTAssertNil(sharedSpace)
        try await reopened.record(account:"first",id:5,shared:false,name:"Example name",confirmed:true)
        let confirmed = await first.entry(account:"first",id:5,shared:false)
        XCTAssertEqual(confirmed?.confirmed,true)
    }
}


extension FoteraTests {
    func testAlbumWithoutGeneratedThumbnailStillDecodes() throws {
        let data = Data(#"{"id":42,"name":"Empty album","item_count":0,"additional":{"thumbnail":{}}}"#.utf8)
        let album = try JSONDecoder().decode(RemoteAlbum.self,from:data)
        XCTAssertEqual(album.id,42); XCTAssertEqual(album.name,"Empty album"); XCTAssertNil(album.cover)
        let ready = try JSONDecoder().decode(RemoteAlbum.self,from:Data(#"{"id":43,"name":"Ready","additional":{"thumbnail":{"cache_key":"preview","unit_id":7}}}"#.utf8))
        XCTAssertEqual(ready.cover?.id,7); XCTAssertEqual(ready.cover?.cacheKey,"preview")
    }
}


@MainActor private final class SelectionLayoutState:ObservableObject {
    @Published var selected:Set<Int>?
}
private struct SelectionLayoutHarness:View {
    @ObservedObject var state:SelectionLayoutState
    let app:AppModel
    var body:some View {
        TabView {
            NavigationStack {
                ScrollView {LazyVStack {ForEach(0..<100,id:\.self) {Text("Photo \($0)").frame(height:80)}}}
                    .navigationTitle("Timeline").navigationBarTitleDisplayMode(.inline)
                    .selectionChrome($state.selected,items:[])
            }.tabItem {Label("Timeline",systemImage:"photo")}
        }.environmentObject(app)
    }
}
extension FoteraTests {
    @MainActor func testSelectionBarDoesNotResizeOrMoveScrolledTimeline() async throws {
        let state = SelectionLayoutState(), app = AppModel()
        let controller = UIHostingController(rootView:SelectionLayoutHarness(state:state,app:app))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:0,y:0,width:393,height:852)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {window.isHidden = true; window.rootViewController = nil}
        try await Task.sleep(for:.milliseconds(350)); controller.view.layoutIfNeeded()
        func findScroll(_ view:UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > 1500 {return scroll}
            return view.subviews.lazy.compactMap{findScroll($0)}.first
        }
        let scroll = try XCTUnwrap(findScroll(controller.view))
        scroll.setContentOffset(CGPoint(x:0,y:1200),animated:false)
        try await Task.sleep(for:.milliseconds(100))
        let height = scroll.bounds.height, position = scroll.contentOffset.y, inset = scroll.adjustedContentInset.bottom
        state.selected = [1]
        try await Task.sleep(for:.milliseconds(350)); controller.view.layoutIfNeeded()
        XCTAssertEqual(scroll.bounds.height,height,accuracy:1)
        XCTAssertEqual(scroll.contentOffset.y,position,accuracy:1)
        XCTAssertEqual(scroll.adjustedContentInset.bottom,inset,accuracy:1)
        state.selected = nil
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertEqual(scroll.contentOffset.y,position,accuracy:1)
    }
}


private struct ActualTimelineSelectionHarness:View {
    @ObservedObject var state:SelectionLayoutState
    let app:AppModel
    let library:LibraryStore
    var body:some View {
        TabView {
            PhotosTabContent(library:library,backup:BackupController.shared,selection:$state.selected)
                .tabItem {Label("Timeline",systemImage:"photo")}
        }.environmentObject(app)
    }
}
extension FoteraTests {
    @MainActor func testActualTimelineKeepsMemoriesAndScrollGeometryWhenSelecting() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey:"photosViewMode")
        defaults.set("timeline",forKey:"photosViewMode")
        defer {if let previousMode {defaults.set(previousMode,forKey:"photosViewMode")} else {defaults.removeObject(forKey:"photosViewMode")}}
        var parts = Calendar.current.dateComponents([.year,.month,.day],from:Date())
        parts.year! -= 1; parts.hour = 12
        let date = try XCTUnwrap(PhotoTime.calendar.date(from:parts))
        let photos = (1...160).map{RemotePhoto(id:$0,filename:"test-\($0).jpg",time:date.timeIntervalSince1970 + Double($0),type:"photo")}
        let library = LibraryStore(remotePhotos:photos), app = AppModel(), state = SelectionLayoutState()
        for _ in 0..<40 {if !library.memories.isEmpty {break}; try await Task.sleep(for:.milliseconds(50))}
        XCTAssertFalse(library.memories.isEmpty)
        let controller = UIHostingController(rootView:ActualTimelineSelectionHarness(state:state,app:app,library:library))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:0,y:0,width:393,height:852)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {window.isHidden = true; window.rootViewController = nil}
        try await Task.sleep(for:.milliseconds(500)); controller.view.layoutIfNeeded()
        func findScroll(_ view:UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > 1500, scroll.bounds.height > 300 {return scroll}
            return view.subviews.lazy.compactMap{findScroll($0)}.first
        }
        let scroll = try XCTUnwrap(findScroll(controller.view))
        for position:CGFloat in [0,700] {
            scroll.setContentOffset(CGPoint(x:0,y:position),animated:false)
            try await Task.sleep(for:.milliseconds(300))
            let height = scroll.contentSize.height, offset = scroll.contentOffset.y, viewport = scroll.bounds.height
            func snapshot(_ name:String) {
                let renderer = UIGraphicsImageRenderer(bounds:window.bounds)
                let image = renderer.image {_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
                let attachment = XCTAttachment(image:image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            }
            if position == 0 {snapshot("Timeline before selection")}
            withAnimation(.snappy) {state.selected = [1]}
            try await Task.sleep(for:.milliseconds(500)); controller.view.layoutIfNeeded()
            if position == 0 {snapshot("Timeline after selection")}
            print("TIMELINE geometry \(height) -> \(scroll.contentSize.height); memories \(library.memories.count); selected \(state.selected != nil)")
            XCTAssertEqual(scroll.contentSize.height,height,accuracy:1,"Selecting must not remove timeline content")
            XCTAssertEqual(scroll.contentOffset.y,offset,accuracy:1)
            XCTAssertEqual(scroll.bounds.height,viewport,accuracy:1)
            withAnimation(.snappy) {state.selected = nil}
            try await Task.sleep(for:.milliseconds(400))
            XCTAssertEqual(scroll.contentSize.height,height,accuracy:1)
            XCTAssertEqual(scroll.contentOffset.y,offset,accuracy:1)
        }
    }
}


extension FoteraTests {
    func testSharedAlbumBadgeUsesAccessNotRetainedSharingFlag() throws {
        func state(_ shared:Bool,_ privacy:String,_ permissions:String,_ expiration:Int = 0) throws -> AlbumSharingState {
            try JSONDecoder().decode(AlbumSharingState.self,from:Data("{\"id\":1,\"shared\":\(shared),\"additional\":{\"sharing_info\":{\"privacy_type\":\"\(privacy)\",\"expiration\":\(expiration),\"permission\":\(permissions)}}}".utf8))
        }
        let owner = #"[{"type":"user","id":1,"role":"owner"}]"#
        XCTAssertFalse(try state(true,"private",owner).hasActiveSharing())
        XCTAssertTrue(try state(true,"public-view",owner).hasActiveSharing())
        XCTAssertFalse(try state(false,"public-view",owner).hasActiveSharing())
        XCTAssertTrue(try state(true,"private",#"[{"type":"user","id":2,"role":"view"}]"#).hasActiveSharing())
        XCTAssertTrue(try state(true,"private",#"[{"type":"group","id":3,"role":"download"}]"#).hasActiveSharing())
        XCTAssertFalse(try state(true,"public-view",owner,100).hasActiveSharing(now:Date(timeIntervalSince1970:200)))
    }
}

import XCTest
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

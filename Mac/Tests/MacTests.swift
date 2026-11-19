import XCTest
import ImageIO
import AppKit
#if !MAC_LOGIC_TESTS
@testable import FoteraMac
#endif

final class MacTests: XCTestCase {
    func testDigestMatchesKnownBytes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        try Data("abc".utf8).write(to:file)
        XCTAssertEqual(try MacFiles.digest(file),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    @MainActor func testMemoriesUsesLocalTodayAndNASWallClock() {
        let formatter = ISO8601DateFormatter()
        let today = formatter.date(from:"2026-11-14T03:30:00Z")!
        let correct = RemotePhoto(id:1,filename:"yes.jpg",time:formatter.date(from:"2020-11-13T23:55:00Z")!.timeIntervalSince1970,type:"photo")
        let tomorrow = RemotePhoto(id:2,filename:"no.jpg",time:formatter.date(from:"2020-11-14T00:01:00Z")!.timeIntervalSince1970,type:"photo")
        XCTAssertEqual(MacModel.memories([correct,tomorrow],now:today,timeZone:TimeZone(identifier:"America/Chicago")!).map(\.id),[1])
    }
    func testTransferRoundTripPreservesDestinationAndState() throws {
        let record = MacTransfer(id:UUID(),filename:"test.heic",digest:"digest",size:42,folder:"/Mac/2026/11",shared:true,state:.failed,message:"Retry")
        let decoded = try JSONDecoder().decode(MacTransfer.self,from:JSONEncoder().encode(record))
        XCTAssertEqual(decoded.id,record.id); XCTAssertEqual(decoded.folder,record.folder); XCTAssertEqual(decoded.state,.failed); XCTAssertTrue(decoded.shared)
    }
}

extension MacTests {
    func testJPEGPreviewDimensionsAndFieldNames() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at:file) }
        let context = CGContext(data:nil,width:1800,height:1200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(file as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let previews = try await UploadPreviews.generate(source:file,filename:"image.png")
        XCTAssertEqual(previews.map(\.field),["thumb_sm","thumb_m","thumb_xl"])
        for (preview,edge) in zip(previews,[240,320,1280]) {
            let source = CGImageSourceCreateWithData(preview.data as CFData,nil)!
            let decoded = CGImageSourceCreateImageAtIndex(source,0,nil)!
            XCTAssertEqual(decoded.width,edge); XCTAssertEqual(decoded.height,Int(Double(edge)*1200/1800))
            XCTAssertEqual(CGImageSourceGetType(source) as String?,"public.jpeg")
        }
    }
    func testMonthGroupingPreservesNASCalendarAtMidnight() {
        let date = ISO8601DateFormatter().date(from:"2026-11-01T00:01:00Z")!
        let photo = RemotePhoto(id:1,filename:"test.jpg",time:date.timeIntervalSince1970,type:"photo")
        XCTAssertEqual(MacPhotoSection.group([photo]).first?.id,PhotoTime.monthTitle(date))
        XCTAssertEqual(PhotoTime.calendar.component(.month,from:date),11)
    }
    func testLocalOnlyItemCannotBeMistakenForCloudPhoto() {
        var local = RemotePhoto(id:UnifiedLibrary.localID("local-original"),filename:"IMG_0001.jpg",time:100,type:"photo")
        local.localAssetID = "local-original"
        let unrelated = RemotePhoto(id:20,filename:"IMG_0001.jpg",time:172_800,type:"photo")
        let result = UnifiedLibrary.merge(remote:[unrelated],local:[local])
        XCTAssertEqual(result.count,2); XCTAssertEqual(result.filter(\.isLocalOnly).count,1)
    }
}

extension MacTests {
    func testIncrementalRefreshRejectsMissingAndReorderedPhotos() {
        func photo(_ id:Int) -> RemotePhoto {.init(id:id,filename:"\(id).jpg",time:Double(id),type:"photo")}
        let known = [photo(3),photo(2),photo(1)]
        XCTAssertEqual(RecentPhotoIndex.merge(known:known,page:[photo(4),photo(3)],total:4)?.map(\.id),[4,3,2,1])
        XCTAssertNil(RecentPhotoIndex.merge(known:known,page:[photo(2)],total:2))
        XCTAssertNil(RecentPhotoIndex.merge(known:known,page:[photo(3),photo(1)],total:3))
    }
    func testMapClusteringBoundsLargeLibrariesAndWrapsDateLine() {
        let photos = (0..<100_000).map { id in RemotePhoto(id:id,filename:"test.jpg",time:0,type:"photo",additional:.init(thumbnail:nil,gps:.init(latitude:0,longitude:id % 2 == 0 ? 179 : -179),video_meta:nil)) }
        let clusters = MacMapCluster.make(photos,viewport:.init(latitude:0,longitude:180,latitudeSpan:20,longitudeSpan:20))
        XCTAssertLessThanOrEqual(clusters.count,64); XCTAssertEqual(clusters.reduce(0){$0 + $1.photos.count},100_000)
    }
    func testPeopleNameRecoveryIsScopedToAccountAndSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let history = PersonNameHistory(root:root)
        try await history.record(account:"first",id:42,shared:false,name:"Test name",confirmed:false)
        let pending = await history.entry(account:"first",id:42,shared:false)
        let otherAccount = await history.entry(account:"second",id:42,shared:false)
        let otherSpace = await history.entry(account:"first",id:42,shared:true)
        XCTAssertEqual(pending?.name,"Test name"); XCTAssertEqual(pending?.confirmed,false); XCTAssertNil(otherAccount); XCTAssertNil(otherSpace)
        try await history.record(account:"first",id:42,shared:false,name:"Test name",confirmed:true)
        let saved = await history.entry(account:"first",id:42,shared:false)
        XCTAssertEqual(saved?.confirmed,true)
    }
}


extension MacTests {
    func testBackupHistoryUpdatesOneRowAndSurvivesReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var record = MacTransfer(id:UUID(),filename:"live.heic",digest:"digest",size:10,folder:"/",shared:false)
        do {
            let store = try MacTransferStore(directory:root)
            try store.importLegacy([record])
            record.state = .complete; record.remoteID = 42
            try store.save(record)
        }
        let saved = try MacTransferStore(directory:root).load()
        XCTAssertEqual(saved.count,1); XCTAssertEqual(saved.first?.remoteID,42); XCTAssertEqual(saved.first?.state,.complete)
    }
    func testLivePhotoProgressWaitsForUnstagedCompanionAndSeparatesSpaces() {
        var still = MacTransfer(id:UUID(),filename:"live.heic",digest:"a",size:10,folder:"/",shared:false,state:.complete)
        still.localAssetID = "asset"; still.resourceKey = "still"
        let key = MacBackupProgress.key(asset:"asset",shared:false)
        let expected:[String:Set<String>] = [key:["still","motion"]]
        XCTAssertEqual(MacBackupProgress.counts(records:[still],expected:expected).complete,0)
        var motion = MacTransfer(id:UUID(),filename:"live.mov",digest:"b",size:10,folder:"/",shared:false,state:.complete)
        motion.localAssetID = "asset"; motion.resourceKey = "motion"
        let done = MacBackupProgress.counts(records:[still,motion],expected:expected)
        XCTAssertEqual(done.complete,1); XCTAssertEqual(done.total,1)
        var shared = MacTransfer(id:UUID(),filename:"live.heic",digest:"a",size:10,folder:"/",shared:true,state:.queued)
        shared.localAssetID = "asset"; shared.resourceKey = "still"
        let separate = MacBackupProgress.counts(records:[still,motion,shared],expected:expected)
        XCTAssertEqual(separate.complete,1); XCTAssertEqual(separate.total,2)
        XCTAssertEqual(MacBackupProgress.counts(records:[],expected:expected).total,1)
    }
}


extension MacTests {
    func testBackupRetriesNetworkFailuresButNotLoginOrCancellation() {
        XCTAssertTrue(MacBackupRetry.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(MacBackupRetry.isTransient(URLError(.timedOut)))
        XCTAssertFalse(MacBackupRetry.isTransient(URLError(.cancelled)))
        XCTAssertFalse(MacBackupRetry.isTransient(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(MacBackupRetry.isTransient(ConnectionError.server(402)))
    }
    func testSmartAlbumPersonFilterNeverFallsBackToAllPhotos() {
        let photos = [RemotePhoto(id:1,filename:"a.jpg",time:0,type:"photo"),RemotePhoto(id:2,filename:"b.jpg",time:0,type:"photo")]
        var rule = MacSmartRule(); rule.personID = 42
        XCTAssertTrue(rule.matches(photos,remoteIDs:nil).isEmpty)
        XCTAssertEqual(rule.matches(photos,remoteIDs:[2]).map(\.id),[2])
    }
}


extension MacTests {
    func testAlbumWithoutGeneratedThumbnailStillDecodes() throws {
        let data = Data(#"{"id":42,"name":"Empty album","item_count":0,"additional":{"thumbnail":{}}}"#.utf8)
        let album = try JSONDecoder().decode(RemoteAlbum.self,from:data)
        XCTAssertEqual(album.id,42); XCTAssertEqual(album.name,"Empty album"); XCTAssertNil(album.cover)
        let ready = try JSONDecoder().decode(RemoteAlbum.self,from:Data(#"{"id":43,"name":"Ready","additional":{"thumbnail":{"cache_key":"preview","unit_id":7}}}"#.utf8))
        XCTAssertEqual(ready.cover?.id,7); XCTAssertEqual(ready.cover?.cacheKey,"preview")
    }
}


extension MacTests {
    func testWidgetChoicePersistsSpaceAndDoesNotLeakBetweenAccounts() throws {
        let suite = "FoteraWidgetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let choice = MacWidgetChoice(id:42,title:"Family",kind:"person",shared:true)
        try choice.save(account:"first",defaults:defaults)
        XCTAssertEqual(MacWidgetChoice.read(account:"first",kind:"person",defaults:defaults),choice)
        XCTAssertNil(MacWidgetChoice.read(account:"second",kind:"person",defaults:defaults))
        XCTAssertNil(MacWidgetChoice.read(account:"first",kind:"album",defaults:defaults))
        MacWidgetChoice.remove(account:"first",kind:"person",defaults:defaults)
        XCTAssertNil(MacWidgetChoice.read(account:"first",kind:"person",defaults:defaults))
    }
}


extension MacTests {
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

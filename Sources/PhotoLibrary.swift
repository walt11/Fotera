import Foundation
import Photos
import CryptoKit

/// Synology Photos stores capture times as wall-clock values encoded as if they were UTC.
/// Always format and group them with this calendar, never the device time zone.
enum PhotoTime {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static func format(_ date: Date, _ style: Date.FormatStyle) -> String {
        var style = style
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
    static func dayTitle(_ date: Date) -> String {
        let now = Date()
        // Compare wall-clock components against the device's local "today".
        let local = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let photo = calendar.dateComponents([.year, .month, .day], from: date)
        if local == photo { return "Today" }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now),
           Calendar.current.dateComponents([.year, .month, .day], from: yesterday) == photo { return "Yesterday" }
        if photo.year == local.year { return format(date, .dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        return format(date, .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
    static func monthTitle(_ date: Date) -> String { format(date, .dateTime.month(.wide).year()) }
}

struct RemotePhoto: Codable, Identifiable, Sendable, Hashable {
    let id: Int
    let filename: String
    let time: Double?
    let type: String
    var additional: Additional?
    var filesize: Int64?
    var folder_id: Int?
    /// Share token for items browsed through an album shared with you (not part of the NAS response).
    var passphrase: String?

    /// Present only in the in-memory unified library; never sent to DSM.
    var localAssetID: String? = nil
    var localVersion: Double? = nil
    var localCaptureTime: Double? = nil
    var localResourceNames: [String]? = nil
    var isLocalOnly: Bool { id < 0 && localAssetID != nil }

    struct Additional: Codable, Sendable, Hashable {
        var thumbnail: Thumbnail?
        var gps: GPS?
        var video_meta: VideoInfo?
    }
    struct VideoInfo: Codable, Sendable, Hashable {
        let duration: Int?
    }
    struct Thumbnail: Codable, Sendable, Hashable {
        let cache_key: String
        let unit_id: Int?
    }
    struct GPS: Codable, Sendable, Hashable {
        let latitude: Double
        let longitude: Double
    }
    var date: Date? { time.map(Date.init(timeIntervalSince1970:)) }
    var isVideo: Bool { type == "video" }
    var isLive: Bool { type == "live" }
    /// "0:59" or "1:02:03", from the NAS's video metadata (milliseconds).
    var durationText: String? {
        guard let milliseconds = additional?.video_meta?.duration, milliseconds > 0 else { return nil }
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
                               : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var thumbnailSource: ThumbnailSource? {
        additional?.thumbnail.map { ThumbnailSource(id: $0.unit_id ?? id, cacheKey: $0.cache_key, kind: "unit", passphrase: passphrase) }
    }
    static func == (lhs: RemotePhoto, rhs: RemotePhoto) -> Bool {
        lhs.id == rhs.id && lhs.additional?.thumbnail?.cache_key == rhs.additional?.thumbnail?.cache_key && lhs.localAssetID == rhs.localAssetID && lhs.localVersion == rhs.localVersion && lhs.time == rhs.time && lhs.filename == rhs.filename && lhs.type == rhs.type
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Identifies a server-generated preview. `kind` is "unit" for photos or "person" for faces.
struct ThumbnailSource: Hashable, Sendable {
    let id: Int
    let cacheKey: String
    let kind: String
    /// Set for items in an album someone shared with you; previews are fetched with its share token.
    var passphrase: String? = nil
}

struct CoverThumbnail: Codable, Hashable, Sendable {
    let cache_key: String
    let unit_id: Int?
}
struct CoverAdditional: Codable, Hashable, Sendable {
    let thumbnail: CoverThumbnail?
}

struct RemoteAlbum: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var item_count: Int?
    var shared: Bool?
    var type: String?
    var additional: CoverAdditional?
    var cover: ThumbnailSource? {
        additional?.thumbnail.flatMap { thumb in thumb.unit_id.map { ThumbnailSource(id: $0, cacheKey: thumb.cache_key, kind: "unit") } }
    }
}

/// People, places and things share the same list shape.
struct RemoteGroup: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    var item_count: Int?
    var country: String?
    var additional: CoverAdditional?
    func cover(kind: String) -> ThumbnailSource? {
        guard let thumb = additional?.thumbnail else { return nil }
        if kind == "person" { return ThumbnailSource(id: id, cacheKey: thumb.cache_key, kind: "person") }
        return thumb.unit_id.map { ThumbnailSource(id: $0, cacheKey: thumb.cache_key, kind: "unit") }
    }
}

struct RemoteFolder: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    var displayName: String {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? "Root" : last
    }
}

struct AlbumSharingState: Decodable {
    let passphrase: String?
    let id: Int
    let shared: Bool?
    let additional: Extra?
    struct Extra: Decodable { let sharing_info: Info? }
    struct Info: Decodable {
        let passphrase: String?
        let sharing_link: String?
        let privacy_type: String?
        let enable_password: Bool?
        let expiration: Double?
    }
}

/// Detailed metadata shown in the viewer's info panel.
struct ItemDetails: Decodable {
    let id: Int
    let filename: String
    let filesize: Int64?
    let time: Double?
    let type: String
    let additional: Extra?
    struct Extra: Decodable {
        let description: String?
        let resolution: Resolution?
        let exif: Exif?
        let gps: RemotePhoto.GPS?
        let address: Address?
        let person: [RemoteGroup]?
        let favorite: Bool?
        let video_meta: VideoMeta?
        let video_convert: [VideoConvert]?
    }
    struct Resolution: Decodable { let width: Int; let height: Int }
    struct Exif: Decodable {
        let camera: String?
        let lens: String?
        let aperture: String?
        let exposure_time: String?
        let focal_length: String?
        let iso: String?
    }
    struct Address: Decodable {
        let country: String?
        let state: String?
        let county: String?
        let city: String?
        let town: String?
        let district: String?
        let village: String?
        let route: String?
        let landmark: String?
        var summary: String? {
            let parts = [landmark, route, village ?? district, town ?? city, state, country].compactMap { $0 }.filter { !$0.isEmpty }
            var seen = Set<String>()
            let unique = parts.filter { seen.insert($0).inserted }
            return unique.isEmpty ? nil : unique.joined(separator: ", ")
        }
    }
    struct VideoMeta: Decodable { let duration: Int?; let video_codec: String?; let resolution_x: Int?; let resolution_y: Int? }
    struct VideoConvert: Decodable { let quality: String }
}

/// Local filters only use indexed metadata; they never issue a server request.
enum LibraryMediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos", live = "Live Photos", raw = "RAW"
    var id: String { rawValue }
    func includes(_ photo: RemotePhoto) -> Bool {
        switch self {
        case .all: return true
        case .photos: return !photo.isVideo
        case .videos: return photo.isVideo
        case .live: return photo.isLive
        case .raw: return ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw"].contains((photo.filename as NSString).pathExtension.lowercased())
        }
    }
}
enum LocalLibrarySearch {
    static func results(_ photos: [RemotePhoto], query: String, media: LibraryMediaFilter, year: Int?) -> [RemotePhoto] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return photos.filter { photo in
            guard media.includes(photo) else { return false }
            let parts = photo.date.map { PhotoTime.calendar.dateComponents([.year, .month, .day], from: $0) }
            if let year, parts?.year != year { return false }
            let dateText = parts.map { String(format: "%04d-%02d-%02d", $0.year ?? 0, $0.month ?? 0, $0.day ?? 0) } ?? ""
            let text = photo.filename + " " + dateText + " " + (photo.date.map(PhotoTime.monthTitle) ?? "")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
    }
}


/// One metadata scan per Photos change, off the main thread. No originals are downloaded.
actor PhoneLibraryIndex {
    static let shared = PhoneLibraryIndex()
    private var cached: [RemotePhoto]?
    /// Per-asset results, reused while an asset is unmodified: reading resources is the slow part.
    private var entries: [String: RemotePhoto] = [:]
    func invalidate() { cached = nil }
    func photos() -> [RemotePhoto] {
        guard LocalAssets.allowed else { cached = nil; entries = [:]; return [] }
        if let cached { return cached }
        LocalLibraryObserver.shared.start()
        var items: [RemotePhoto] = []
        var fresh: [String: RemotePhoto] = [:]
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let previous = entries
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            if let known = previous[asset.localIdentifier], known.localVersion == asset.modificationDate?.timeIntervalSince1970 {
                items.append(known); fresh[asset.localIdentifier] = known; return
            }
            guard let item = Self.descriptor(asset, resources: PHAssetResource.assetResources(for: asset)) else { return }
            items.append(item); fresh[asset.localIdentifier] = item
        }
        cached = items; entries = fresh
        return items
    }
    /// Describes a phone asset in the NAS's terms (filename, wall-clock capture time, type) for matching.
    nonisolated static func descriptor(_ asset: PHAsset, resources: [PHAssetResource]) -> RemotePhoto? {
        guard let resource = resources.first(where: { $0.type == (asset.mediaType == .video ? .video : .photo) }) ?? resources.first else { return nil }
        // DSM dates are wall-clock UTC; encode phone dates in the same coordinate system.
        let wall = asset.creationDate.map { $0.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: $0)) }
        var item = RemotePhoto(id: UnifiedLibrary.localID(asset.localIdentifier), filename: resource.originalFilename,
                               time: wall, type: asset.mediaType == .video ? "video" : (asset.mediaSubtypes.contains(.photoLive) ? "live" : "photo"))
        item.localAssetID = asset.localIdentifier
        item.localVersion = asset.modificationDate?.timeIntervalSince1970
        item.localCaptureTime = asset.creationDate?.timeIntervalSince1970
        item.localResourceNames = resources.filter {
            asset.mediaType == .video ? [.video, .fullSizeVideo].contains($0.type) : [.photo, .fullSizePhoto, .alternatePhoto].contains($0.type)
        }.map(\.originalFilename)
        item.additional = .init(thumbnail: nil, gps: asset.location.map { .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                                video_meta: asset.mediaType == .video ? .init(duration: Int(asset.duration * 1000)) : nil)
        return item
    }
}

/// Conservative one-to-one matching for display only. Destructive operations still verify bytes.
enum UnifiedLibrary {
    static func localID(_ identifier: String) -> Int {
        let bytes = SHA256.hash(data: Data(identifier.utf8))
        let value = bytes.prefix(7).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return -Int(value) - 1
    }
    private static func stem(_ name: String) -> String { (name.lowercased() as NSString).deletingPathExtension }
    /// Prefer the displayed wall time, then UTC, then a plausible capture-time-zone offset.
    /// NAS imports can retain UTC or the camera's wall clock; PhotoKit stores absolute time.
    static func matchScore(remote: RemotePhoto, local: RemotePhoto) -> Int? {
        guard remote.passphrase == nil, remote.isVideo == local.isVideo,
              let time = remote.time, let localTime = local.time else { return nil }
        let names = local.localResourceNames ?? [local.filename]
        let exactName = names.contains { $0.caseInsensitiveCompare(remote.filename) == .orderedSame }
        guard exactName || names.contains(where: { stem($0) == stem(remote.filename) }) else { return nil }
        let nameScore = exactName ? 10 : 0
        if abs(time - localTime) <= 2 { return 300 + nameScore }
        let utc = local.localCaptureTime ?? localTime
        if abs(time - utc) <= 2 { return 200 + nameScore }
        let difference = abs(time - utc)
        let remainder = difference.truncatingRemainder(dividingBy: 900)
        guard difference <= 14 * 3600 + 2, min(remainder, 900 - remainder) <= 2 else { return nil }
        return 100 + nameScore
    }
    static func merge(remote: [RemotePhoto], local: [RemotePhoto], links: [UploadPhotoLink] = [], shared: Bool = false) -> [RemotePhoto] {
        var byStem: [String: Set<Int>] = [:], byIdentifier: [String: Int] = [:]
        for (index, item) in local.enumerated() {
            if let id = item.localAssetID { byIdentifier[id] = index }
            for name in item.localResourceNames ?? [item.filename] { byStem[stem(name), default: []].insert(index) }
        }
        var linked: [Int: Set<Int>] = [:]
        for link in links where link.shared == shared {
            guard let index = byIdentifier[link.localID],
                  (local[index].localVersion ?? 0) <= link.created.timeIntervalSince1970 + 2 else { continue }
            linked[link.remoteID, default: []].insert(index)
        }
        // Resolve both directions before merging: iteration order must never choose a photo.
        var proposals: [Int: (local: Int, score: Int)] = [:]
        var reverse: [Int: [(remote: Int, score: Int)]] = [:]
        for (index, item) in remote.enumerated() where item.passphrase == nil {
            var candidates: [(local: Int, score: Int)] = []
            if let known = linked[item.id], known.count == 1, let phone = known.first,
               item.isVideo == local[phone].isVideo {
                candidates = [(phone, 1000)]
            } else {
                for phone in byStem[stem(item.filename)] ?? [] {
                    if let score = matchScore(remote: item, local: local[phone]) { candidates.append((phone, score)) }
                }
            }
            guard let best = candidates.map(\.score).max() else { continue }
            let winners = candidates.filter { $0.score == best }
            guard winners.count == 1, let winner = winners.first else { continue }
            proposals[index] = winner
            reverse[winner.local, default: []].append((index, best))
        }
        var matched = Set<Int>()
        var result = remote.enumerated().map { index, item -> RemotePhoto in
            guard let proposal = proposals[index], let choices = reverse[proposal.local],
                  let best = choices.map(\.score).max(), proposal.score == best,
                  choices.filter({ $0.score == best }).count == 1 else { return item }
            let phone = local[proposal.local]
            var merged = item
            merged.localAssetID = phone.localAssetID; merged.localVersion = phone.localVersion
            merged.localCaptureTime = phone.localCaptureTime; merged.localResourceNames = phone.localResourceNames
            matched.insert(proposal.local)
            return merged
        }
        result += local.enumerated().filter { !matched.contains($0.offset) }.map(\.element)
        return result.sorted { lhs, rhs in
            if lhs.time != rhs.time { return (lhs.time ?? -.infinity) > (rhs.time ?? -.infinity) }
            return lhs.id > rhs.id
        }
    }
}

/// Account-scoped upload identity, retained beyond the short visible transfer history.
struct UploadPhotoLink: Codable, Sendable {
    let remoteID: Int
    let localID: String
    let shared: Bool
    let created: Date
    init?(record: TransferRecord) {
        guard record.state.isFinished, let remote = record.remoteID,
              let source = record.sourceID, let identifier = PhoneDeletionMatch.sourceAssetID(source) else { return nil }
        remoteID = remote; localID = identifier; shared = record.shared; created = record.created
    }
    init(remoteID: Int, localID: String, shared: Bool, created: Date) {
        self.remoteID = remoteID; self.localID = localID; self.shared = shared; self.created = created
    }
}

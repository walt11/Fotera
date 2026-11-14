import Foundation

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
        lhs.id == rhs.id && lhs.additional?.thumbnail?.cache_key == rhs.additional?.thumbnail?.cache_key
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

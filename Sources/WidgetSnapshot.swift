import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
import ImageIO
#endif

struct WidgetSnapshot: Codable {
    let title: String
    let image: Data
    let date: Date
}
/// Previews shared with the widget through the App Group. The widget never receives session data.
enum WidgetSnapshotStore {
    #if os(macOS)
    static let group = "76BJCJ4Q7X.net.jwalter.Fotera.Mac"
    #else
    static let group = "group.net.jwalter.Fotera"
    #endif
    private static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    private static var pinnedURL: URL? { container?.appendingPathComponent("photo-widget.json") }
    private static var memoriesURL: URL? { container?.appendingPathComponent("memories-widget.json") }
    private static var scheduleURL: URL? { container?.appendingPathComponent("memories-schedule.json") }
    static var hasMemorySchedule: Bool { scheduleURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    static var isAvailable: Bool { container != nil }
    static func readMemorySchedule() -> WidgetMemorySchedule? {
        guard let scheduleURL, let data = try? Data(contentsOf: scheduleURL) else { return nil }
        return try? JSONDecoder().decode(WidgetMemorySchedule.self, from: data)
    }
    static func saveMemorySchedule(_ schedule: WidgetMemorySchedule) throws {
        guard let scheduleURL else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(schedule).write(to: scheduleURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The photo explicitly chosen with "Show in widget", if any.
    static func read() -> WidgetSnapshot? {
        guard let pinnedURL, let data = try? Data(contentsOf: pinnedURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
    static func save(_ snapshot: WidgetSnapshot) throws {
        guard let pinnedURL else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(snapshot).write(to: pinnedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func readMemories() -> [WidgetSnapshot] {
        guard let memoriesURL, let data = try? Data(contentsOf: memoriesURL) else { return [] }
        return (try? JSONDecoder().decode([WidgetSnapshot].self, from: data)) ?? []
    }
    static func saveMemories(_ snapshots: [WidgetSnapshot]) throws {
        guard let memoriesURL else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(snapshots).write(to: memoriesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if snapshots.isEmpty, let scheduleURL { try? FileManager.default.removeItem(at: scheduleURL) }
    }
    static func clear() throws {
        if let container { for name in ["feed-album.json", "feed-person.json", "backup-widget.json"] { try? FileManager.default.removeItem(at: container.appendingPathComponent(name)) } }
        for url in [pinnedURL, memoriesURL, scheduleURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    static func clearPinned() throws {
        guard let pinnedURL, FileManager.default.fileExists(atPath: pinnedURL.path) else { return }
        try FileManager.default.removeItem(at: pinnedURL)
    }
}

struct BackupWidgetSnapshot: Codable {
    let status: String; let completed: Int; let total: Int; let updated: Date
}
extension WidgetSnapshotStore {
    static func saveFeed(_ snapshots: [WidgetSnapshot], kind: String) throws {
        guard ["album", "person"].contains(kind), let container else { throw CocoaError(.fileWriteNoPermission) }
        try JSONEncoder().encode(snapshots).write(to: container.appendingPathComponent("feed-" + kind + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func readFeed(_ kind: String) -> [WidgetSnapshot] {
        guard ["album", "person"].contains(kind), let container, let data = try? Data(contentsOf: container.appendingPathComponent("feed-" + kind + ".json")) else { return [] }
        return (try? JSONDecoder().decode([WidgetSnapshot].self, from: data)) ?? []
    }
    static func saveBackup(_ value: BackupWidgetSnapshot) {
        guard let container, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: container.appendingPathComponent("backup-widget.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func readBackup() -> BackupWidgetSnapshot? {
        guard let container, let data = try? Data(contentsOf: container.appendingPathComponent("backup-widget.json")) else { return nil }
        return try? JSONDecoder().decode(BackupWidgetSnapshot.self, from: data)
    }
}


extension WidgetSnapshot {
    /// Widget extensions have a small memory budget: bound pixels, not screen-scaled points.
    #if os(iOS)
    @MainActor static func previewData(_ image: UIImage) -> Data {
        let ratio = min(1, 600 / max(1, max(image.size.width, image.size.height)))
        let size = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    static func needsRefresh(stamp: String, savedStamp: String?, snapshots: [WidgetSnapshot]) -> Bool {
        savedStamp != stamp || snapshots.isEmpty || snapshots.contains { UIImage(data: $0.image) == nil }
    }
    #else
    @MainActor static func previewData(_ image: NSImage) -> Data {
        guard let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else {return Data()}
        let ratio = min(1,600.0/Double(max(cg.width,cg.height)))
        let width = max(1,Int((Double(cg.width)*ratio).rounded())), height = max(1,Int((Double(cg.height)*ratio).rounded()))
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else {return Data()}
        context.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil), let resized = context.makeImage() else {return Data()}
        CGImageDestinationAddImage(output,resized,[kCGImageDestinationLossyCompressionQuality:0.8] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {return Data()}; return data as Data
    }
    static func needsRefresh(stamp:String,savedStamp:String?,snapshots:[WidgetSnapshot]) -> Bool {savedStamp != stamp || snapshots.isEmpty || snapshots.contains{NSImage(data:$0.image) == nil}}
    #endif
}


/// Dated selections plus evergreen library previews. No account credentials or NAS requests.
struct WidgetMemorySchedule: Codable {
    let days: [String: [WidgetSnapshot]]
    let fallback: [WidgetSnapshot]

    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = timeZone; return value
    }
    static func dayKey(_ date: Date, calendar: Calendar = calendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    func snapshot(at date: Date, calendar: Calendar = calendar()) -> WidgetSnapshot? {
        let daily = days[Self.dayKey(date, calendar: calendar)] ?? []
        let pool = daily.isEmpty ? fallback : daily
        guard !pool.isEmpty else { return nil }
        let dayOffset = daily.isEmpty ? (calendar.ordinality(of: .day, in: .era, for: date) ?? 0) : 0
        let index = (dayOffset + calendar.component(.hour, from: date)) % pool.count
        return pool[index]
    }
    /// Schedule actual hour boundaries, including midnight and DST changes, ahead of time.
    static func timelineDates(from now: Date, hours: Int = 48, calendar: Calendar = calendar()) -> [Date] {
        var dates = [now]
        var cursor = now
        for _ in 0..<max(0, hours) {
            guard let next = calendar.dateInterval(of: .hour, for: cursor)?.end, next > cursor else { break }
            dates.append(next); cursor = next
        }
        return dates
    }
}

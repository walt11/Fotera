import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
typealias WidgetPlatformImage = NSImage
#else
typealias WidgetPlatformImage = UIImage
#endif
extension Image {
    init(widgetImage:WidgetPlatformImage) {
        #if os(macOS)
        self.init(nsImage:widgetImage)
        #else
        self.init(uiImage:widgetImage)
        #endif
    }
}

struct PhotoEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}
struct PhotoProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhotoEntry { PhotoEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (PhotoEntry) -> Void) {
        let now = Date()
        completion(PhotoEntry(date: now, snapshot: WidgetSnapshotStore.read() ?? Self.schedule().snapshot(at: now)))
    }
    private static func schedule() -> WidgetMemorySchedule {
        if let saved = WidgetSnapshotStore.readMemorySchedule() { return saved }
        // Migrate an older cache only for its own day; never repeat yesterday's relative titles.
        let calendar = WidgetMemorySchedule.calendar()
        let current = WidgetSnapshotStore.readMemories().filter { calendar.isDate($0.date, inSameDayAs: Date()) }
        return WidgetMemorySchedule(days: [WidgetMemorySchedule.dayKey(Date()): current], fallback: [])
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PhotoEntry>) -> Void) {
        let now = Date()
        if let pinned = WidgetSnapshotStore.read() {
            completion(Timeline(entries: [PhotoEntry(date: now, snapshot: pinned)], policy: .never)); return
        }
        let schedule = Self.schedule()
        let entries = WidgetMemorySchedule.timelineDates(from: now).map {
            PhotoEntry(date: $0, snapshot: schedule.snapshot(at: $0))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}
struct PhotoWidgetView: View {
    let entry: PhotoEntry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let snapshot = entry.snapshot, let image = WidgetPlatformImage(data: snapshot.image) {
                GeometryReader { geometry in
                    Image(widgetImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.privacySensitive()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                Text(snapshot.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).padding(12).privacySensitive()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "photo.stack").font(.title).foregroundStyle(.tint)
                    Text("Fotera").font(.headline)
                    Text("Open Fotera to prepare your memories.").font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
        }.containerBackground(.background, for: .widget)
    }
}
struct FoteraPhotoWidget: Widget {
    let kind = "FoteraPhoto"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PhotoProvider()) { PhotoWidgetView(entry: $0) }
            .configurationDisplayName("Fotera Memories")
            .description("Rotates through memories from your library, or shows a photo you choose. The widget never connects to your NAS.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

@main struct FoteraWidgets: WidgetBundle {
    var body: some Widget {
        FoteraPhotoWidget()
        #if os(iOS)
        BackupActivityWidget()
        #endif
        FoteraCollectionWidget(kind: "album")
        FoteraCollectionWidget(kind: "person")
        FoteraBackupWidget()
    }
}

struct CollectionPhotoProvider: TimelineProvider {
    let kind: String
    func placeholder(in context: Context) -> PhotoEntry { PhotoEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (PhotoEntry) -> Void) { completion(PhotoEntry(date: Date(), snapshot: WidgetSnapshotStore.readFeed(kind).first)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PhotoEntry>) -> Void) {
        let photos = WidgetSnapshotStore.readFeed(kind); let now = Date()
        let entries = (0..<12).map { hour in PhotoEntry(date: now.addingTimeInterval(Double(hour) * 3600), snapshot: photos.isEmpty ? nil : photos[hour % photos.count]) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}
struct FoteraCollectionWidget: Widget {
    let kind: String
    init() { kind = "album" }
    init(kind: String) { self.kind = kind }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FoteraCollection-" + kind, provider: CollectionPhotoProvider(kind: kind)) { PhotoWidgetView(entry: $0) }
            .configurationDisplayName(kind == "album" ? "Fotera Album" : "Fotera Person")
            .description("Choose an album or person inside Fotera. Saved previews rotate hourly without connecting to your NAS.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge]).contentMarginsDisabled()
    }
}
struct BackupWidgetEntry: TimelineEntry { let date: Date; let snapshot: BackupWidgetSnapshot? }
struct BackupWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BackupWidgetEntry { .init(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (BackupWidgetEntry) -> Void) { completion(.init(date: Date(), snapshot: WidgetSnapshotStore.readBackup())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BackupWidgetEntry>) -> Void) { completion(Timeline(entries: [.init(date: Date(), snapshot: WidgetSnapshotStore.readBackup())], policy: .after(Date().addingTimeInterval(15 * 60)))) }
}
struct FoteraBackupWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FoteraBackup", provider: BackupWidgetProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                Label("Fotera backup", systemImage: "icloud.and.arrow.up").font(.headline)
                if let value = entry.snapshot {
                    Text("\(value.completed) of \(value.total)").font(.title2.bold()).minimumScaleFactor(0.6)
                    ProgressView(value: Double(min(value.completed, value.total)), total: Double(max(1, value.total)))
                    Text(value.status).font(.caption).lineLimit(2)
                    Text(value.updated, style: .relative).font(.caption2).foregroundStyle(.secondary)
                } else { Text("Open Fotera to enable backup.").font(.caption) }
            }.containerBackground(.background, for: .widget).widgetURL(URL(string: {
                #if os(macOS)
                return "fotera-mac://backup"
                #else
                return "fotera://backup"
                #endif
            }()))
        }.configurationDisplayName("Fotera Backup").description("Last reported backup progress. Open backup for current progress; the system controls widget refresh timing.").supportedFamilies([.systemSmall, .systemMedium])
    }
}

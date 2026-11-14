import SwiftUI
import WidgetKit

struct PhotoEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}
struct PhotoProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhotoEntry { PhotoEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (PhotoEntry) -> Void) {
        completion(PhotoEntry(date: Date(), snapshot: WidgetSnapshotStore.read() ?? WidgetSnapshotStore.readMemories().first))
    }
    /// A pinned photo stays put. Otherwise the widget rotates through today's memories every hour.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PhotoEntry>) -> Void) {
        if let pinned = WidgetSnapshotStore.read() {
            completion(Timeline(entries: [PhotoEntry(date: Date(), snapshot: pinned)], policy: .never)); return
        }
        let memories = WidgetSnapshotStore.readMemories()
        guard !memories.isEmpty else {
            completion(Timeline(entries: [PhotoEntry(date: Date(), snapshot: nil)], policy: .after(Date().addingTimeInterval(6 * 3600)))); return
        }
        let start = Date()
        let entries = (0..<12).map { hour in
            PhotoEntry(date: start.addingTimeInterval(Double(hour) * 3600), snapshot: memories[hour % memories.count])
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}
struct PhotoWidgetView: View {
    let entry: PhotoEntry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let snapshot = entry.snapshot, let image = UIImage(data: snapshot.image) {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.privacySensitive()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                Text(snapshot.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).padding(12).privacySensitive()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "photo.stack").font(.title).foregroundStyle(.tint)
                    Text("Fotera").font(.headline)
                    Text("Memories from your NAS appear here.").font(.caption).foregroundStyle(.secondary)
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
        BackupActivityWidget()
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
            }.containerBackground(.background, for: .widget).widgetURL(URL(string: "fotera://backup"))
        }.configurationDisplayName("Fotera Backup").description("Last reported backup progress. Tap to open backup; iOS controls widget refresh timing.").supportedFamilies([.systemSmall, .systemMedium])
    }
}

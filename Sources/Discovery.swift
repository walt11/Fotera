import SwiftUI
import Network

// MARK: - Duplicates

/// Finds likely duplicates in the synced index: exact copies (same size and capture time) and bursts
/// (same size within 1% and taken within 2 seconds). Like Immich, it pre-selects all but one per group.
struct DuplicateGroup: Identifiable {
    enum Kind { case exact, burst, similar }
    let id: Int
    let items: [RemotePhoto]
    let kind: Kind
    var exact: Bool { kind == .exact }
}
enum DuplicateFinder {
    static func groups(in photos: [RemotePhoto]) -> [DuplicateGroup] {
        let candidates = photos.filter { !$0.isVideo && $0.time != nil && ($0.filesize ?? 0) > 0 }
            .sorted { ($0.time ?? 0) < ($1.time ?? 0) }
        var groups: [DuplicateGroup] = []
        var current: [RemotePhoto] = []
        func close() {
            if current.count > 1 {
                let sizes = Set(current.compactMap(\.filesize)), times = Set(current.compactMap(\.time))
                groups.append(DuplicateGroup(id: current[0].id, items: current, kind: sizes.count == 1 && times.count == 1 ? .exact : .burst))
            }
            current = []
        }
        for photo in candidates {
            if let last = current.last, let time = photo.time, let lastTime = last.time, let size = photo.filesize, let lastSize = last.filesize,
               time - lastTime <= 2, abs(Double(size - lastSize)) <= Double(max(size, lastSize)) * 0.01 {
                current.append(photo)
            } else {
                close(); current = [photo]
            }
        }
        close()
        return groups.sorted { ($0.items.first?.time ?? 0) > ($1.items.first?.time ?? 0) }
    }
    /// Groups the NAS's similar photos taken within a minute of each other, skipping photos already
    /// in an exact/burst group.
    static func similarGroups(_ similar: [RemotePhoto], excluding taken: Set<Int>) -> [DuplicateGroup] {
        let items = similar.filter { !taken.contains($0.id) && $0.time != nil }.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
        var groups: [DuplicateGroup] = []; var current: [RemotePhoto] = []
        func close() { if current.count > 1 { groups.append(DuplicateGroup(id: current[0].id, items: current, kind: .similar)) }; current = [] }
        for item in items {
            if let last = current.last, let time = item.time, let lastTime = last.time, time - lastTime <= 60 { current.append(item) }
            else { close(); current = [item] }
        }
        close()
        return groups
    }
}

struct DuplicatesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var library: LibraryStore
    @State private var groups: [DuplicateGroup] = []
    @State private var selected = Set<Int>()
    @State private var scanned = false
    @StateObject private var runner = ActionRunner()
    var body: some View {
        List {
            if !scanned {
                HStack { ProgressView(); Text("Looking for duplicates…").foregroundStyle(.secondary) }
            } else if groups.isEmpty {
                ContentUnavailableView("No duplicates found", systemImage: "checkmark.circle",
                    description: Text("No exact copies or burst shots in \(app.shared ? "Shared Space" : "your library")."))
            } else {
                Section {
                    Text("\(groups.count) groups · \(selected.count) selected to delete. In copies and bursts the first photo is kept; similar photos start unselected. Tap photos to change.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(group.items) { item in
                                    let marked = selected.contains(item.id)
                                    ThumbnailView(source: item.thumbnailSource, shared: app.shared, size: .m)
                                        .frame(width: 110, height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.small))
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: marked ? "trash.circle.fill" : "checkmark.circle.fill")
                                                .font(.title3).symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, marked ? Color.red : Color.green).padding(4)
                                        }
                                        .overlay(alignment: .bottomLeading) {
                                            Text(ByteCountFormatter.string(fromByteCount: item.filesize ?? 0, countStyle: .file))
                                                .font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(4)
                                                .shadow(radius: 2)
                                        }
                                        .opacity(marked ? 0.6 : 1)
                                        .onTapGesture { if marked { selected.remove(item.id) } else { selected.insert(item.id) } }
                                        .accessibilityLabel("\(item.filename), \(marked ? "will be deleted" : "kept")")
                                        .accessibilityAddTraits(.isButton)
                                }
                            }
                        }
                    } header: {
                        Text(label(group.kind) + (group.items.first?.date.map { PhotoTime.format($0, .dateTime.month(.abbreviated).day().year().hour().minute()) } ?? ""))
                    }
                }
            }
        }
        .navigationTitle("Duplicates").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !selected.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete \(selected.count)", role: .destructive) {
                        runner.requestDelete(library.photos.filter { selected.contains($0.id) }, app: app)
                    }
                }
            }
        }
        .actionRunner(runner) { scan() }
        .task(id: library.photos.count) { scan() }
    }
    private func label(_ kind: DuplicateGroup.Kind) -> String {
        switch kind {
        case .exact: return "Exact copies · "
        case .burst: return "Burst · "
        case .similar: return "Similar · "
        }
    }
    private func scan() {
        let photos = library.photos
        let client = app.client, shared = app.shared
        Task {
            var found = await Task.detached(priority: .userInitiated) { DuplicateFinder.groups(in: photos) }.value
            // Add look-alikes from Synology Photos' Similar photos feature, when the NAS has it on.
            if let client, let similar = try? await client.similarItems(shared: shared) {
                let taken = Set(found.flatMap { $0.items.map(\.id) })
                found += DuplicateFinder.similarGroups(similar, excluding: taken)
                found.sort { ($0.items.first?.time ?? 0) > ($1.items.first?.time ?? 0) }
            }
            groups = found
            // Similar photos aren't copies, so nothing in those groups is pre-selected.
            selected = Set(found.filter { $0.kind != .similar }.flatMap { $0.items.dropFirst().map(\.id) })
            scanned = true
        }
    }
}

// MARK: - Albums shared with you

/// Browses an album someone shared with you inside Fotera, using the album's share token.
/// Falls back to Synology's web viewer when the NAS doesn't allow token browsing.
struct SharedAlbumView: View {
    let album: SharedPhotoAlbum
    @EnvironmentObject private var app: AppModel
    @State private var items: [RemotePhoto] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var webURL: URL?
    @State private var viewer: ViewerRequest?
    var body: some View {
        Group {
            if loading && items.isEmpty {
                SkeletonGrid(showsHeaders: false)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Can’t show this album here", systemImage: "person.2")
                } description: { Text(failure ?? "This album is empty.") } actions: {
                    if let webURL { Link("Open in Synology Photos", destination: webURL) }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(items) { item in
                            ThumbnailView(source: item.thumbnailSource, shared: false, size: .m)
                                .aspectRatio(1, contentMode: .fit)
                                .onTapGesture { viewer = ViewerRequest(id: item.id, items: items) }
                                .accessibilityLabel(item.filename).accessibilityAddTraits(.isButton)
                        }
                    }
                }
            }
        }
        .navigationTitle(album.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { if let webURL { Link(destination: webURL) { Image(systemName: "safari") }.accessibilityLabel("Open in browser") } }
        .fullScreenCover(item: $viewer) { request in SharedAlbumViewer(items: request.items, startID: request.id) }
        .task {
            guard let client = app.client, let token = album.passphrase, !token.isEmpty else { loading = false; return }
            webURL = await client.base.appendingPathComponent("mo/sharing").appendingPathComponent(token)
            do { items = try await client.sharedAlbumItems(passphrase: token) }
            catch { failure = error.localizedDescription }
            loading = false
        }
    }
}
/// A simple preview pager for shared-album items (their originals stay with the owner).
struct SharedAlbumViewer: View {
    let items: [RemotePhoto]
    let startID: Int
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ThumbnailView(source: item.thumbnailSource, shared: false, size: .xl, contentMode: .fit)
                        .background(Color.black).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44) }
                .accessibilityLabel("Close").padding(.leading, 8)
        }
        .preferredColorScheme(.dark)
        .onAppear { selection = items.firstIndex(where: { $0.id == startID }) ?? 0 }
    }
}

// MARK: - Video quality

enum VideoQuality: String, CaseIterable, Identifiable {
    case fast = "Fast start", originalOnWiFi = "Original on Wi‑Fi", original = "Always original"
    var id: String { rawValue }
    static var current: VideoQuality { VideoQuality(rawValue: UserDefaults.standard.string(forKey: "videoQuality") ?? "") ?? .fast }
    var detail: String {
        switch self {
        case .fast: return "Streams the NAS’s smaller H.264 version so playback starts quickly."
        case .originalOnWiFi: return "Plays the full-quality original on Wi‑Fi and streams the smaller version on cellular."
        case .original: return "Always streams the full-quality original. Uses more data."
        }
    }
    /// Whether to stream the NAS's converted version rather than download the original.
    var prefersStream: Bool {
        switch self {
        case .fast: return true
        case .originalOnWiFi: return NetworkStatus.shared.isExpensive
        case .original: return false
        }
    }
}
/// Tracks whether the current network is cellular or otherwise metered.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock(); self?.expensive = path.isExpensive || path.isConstrained; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "Fotera.NetworkStatus"))
    }
    var isExpensive: Bool { lock.lock(); defer { lock.unlock() }; return expensive }
}

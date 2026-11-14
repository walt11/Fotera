import SwiftUI
import Combine
import AVKit
import PhotosUI
import MapKit
import WidgetKit

@MainActor final class ViewerState: ObservableObject {
    @Published var index: Int
    @Published var chromeVisible = true
    @Published var zoomed = false
    @Published var dismissOffset: CGFloat = 0
    @Published var liveRequest = 0
    @Published var favorites: [Int: Bool] = [:]
    /// The visible item, so pages can pause or activate themselves.
    @Published var currentID: Int?
    init(index: Int, currentID: Int?) { self.index = index; self.currentID = currentID }
}

/// Full-screen media viewer. Pages are hosted in a UIPageViewController so only nearby items exist.
struct MediaViewer: View {
    let startID: Int
    let shared: Bool
    var album: RemoteAlbum?
    var onChange: () -> Void
    @State private var items: [RemotePhoto]
    @StateObject private var state: ViewerState
    @StateObject private var runner = ActionRunner()
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingInfo = false
    @State private var slideshow = false
    @State private var removing = false
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    init(items: [RemotePhoto], startID: Int, shared: Bool, album: RemoteAlbum? = nil, onChange: @escaping () -> Void = {}) {
        self.startID = startID; self.shared = shared; self.album = album; self.onChange = onChange
        _items = State(initialValue: items)
        let index = items.firstIndex(where: { $0.id == startID }) ?? 0
        _state = StateObject(wrappedValue: ViewerState(index: index, currentID: items.indices.contains(index) ? items[index].id : nil))
    }
    private var current: RemotePhoto? { items.indices.contains(state.index) ? items[state.index] : nil }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.8, state.dismissOffset / 400)).ignoresSafeArea()
            if let client = app.client {
                PagerView(count: items.count, state: state, dismiss: { dismiss() }, showInfo: { showingInfo = true }) { index in
                    MediaPage(item: items[index], client: client, shared: shared, albumID: album?.id, state: state)
                }
                .ignoresSafeArea()
            }
            if state.chromeVisible && state.dismissOffset == 0, let current { chrome(current) }
        }
        .statusBarHidden(!state.chromeVisible)
        .persistentSystemOverlays(state.chromeVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingInfo) {
            if let current { ItemInfoView(item: current, shared: shared).presentationDetents([.medium, .large]) }
        }
        .actionRunner(runner) { removeCurrent() }
        .confirmationDialog("Remove from this album? The original stays in your library.", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove from album", role: .destructive) {
                guard let current, let album else { return }
                runner.removeFromAlbum([current], album: album, app: app) { removeCurrent() }
            }
        }
        .onReceive(timer) { _ in
            guard slideshow else { return }
            if state.index + 1 < items.count { withAnimation { state.index += 1 } } else { slideshow = false; state.chromeVisible = true }
        }
        .onChange(of: state.index) { state.currentID = current?.id; loadFavorite(); preloadNeighbors() }
        .task {
            loadFavorite()
            if DebugScreen.name == "info" { try? await Task.sleep(for: .seconds(1)); showingInfo = true }
        }
    }
    /// Loads the high-quality previews either side of the current item, so swiping is instant.
    private func preloadNeighbors() {
        let range = max(0, state.index - 2)...min(items.count - 1, state.index + 2)
        let sources = range.filter { $0 != state.index }.compactMap { items[$0].thumbnailSource }
        ImagePipeline.shared.prefetch(sources, shared: shared, size: .xl)
        let nearby = range.filter { $0 != state.index }.map { items[$0] }
        Task.detached(priority: .utility) { for item in nearby { _ = await LocalAssets.shared.identifier(for: item) } }
    }
    private func loadFavorite() {
        guard let current, state.favorites[current.id] == nil, let client = app.client else { return }
        let id = current.id
        if current.isLocalOnly {
            Task { if let local = await LocalCopy.asset(current) { state.favorites[id] = local.isFavorite } }
            return
        }
        // The synced favorites list already knows this; only ask the NAS when it hasn't loaded.
        if shared == app.shared, FavoriteMarks.shared.loaded {
            state.favorites[id] = FavoriteMarks.shared.ids.contains(id); return
        }
        Task { if let value = try? await client.favorite(id: id, shared: shared) { state.favorites[id] = value } }
    }
    private func removeCurrent() {
        guard let current else { return }
        items.removeAll { $0.id == current.id }
        onChange()
        if items.isEmpty { dismiss() } else { state.index = min(state.index, items.count - 1); state.currentID = items[state.index].id }
    }
    private func chrome(_ item: RemotePhoto) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36) }
                    .accessibilityLabel("Close")
                Spacer()
                VStack(spacing: 2) {
                    if let date = item.date {
                        Text(PhotoTime.format(date, .dateTime.month(.abbreviated).day().year())).font(.subheadline.weight(.semibold))
                        Text(PhotoTime.format(date, .dateTime.hour().minute())).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                if item.isLive {
                    Button { state.liveRequest += 1 } label: {
                        Label("LIVE", systemImage: "livephoto").font(.caption.weight(.bold)).padding(.horizontal, 10).frame(height: 30)
                            .background(.white.opacity(0.18), in: Capsule())
                    }.accessibilityLabel("Play Live Photo")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, Theme.medium).padding(.vertical, 6)
            .background(Color.black.opacity(0.35).ignoresSafeArea(edges: .top))
            Spacer()
            VStack(spacing: 6) {
                if items.count > 1 { Filmstrip(items: items, shared: shared, state: state) }
                HStack {
                    bottomButton("Share", "square.and.arrow.up") { runner.share([item], app: app, albumID: album?.id) }
                    let favorite = state.favorites[item.id]
                    bottomButton(favorite == true ? "Unfavorite" : "Favorite", favorite == true ? "heart.fill" : "heart") {
                        guard let favorite else { return }
                        runner.setFavorite([item], value: !favorite, app: app) { state.favorites[item.id] = !favorite }
                    }.disabled(favorite == nil)
                    bottomButton("Delete", "trash") { runner.requestDelete([item], app: app) }
                    moreMenu(item).frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8).padding(.bottom, 2)
            .background(Color.black.opacity(0.35).ignoresSafeArea(edges: .bottom))
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }
    private func moreMenu(_ item: RemotePhoto) -> some View {
        Menu {
            Button("Details", systemImage: "info.circle") { showingInfo = true }
            Button("Add to album", systemImage: "rectangle.stack.badge.plus") { runner.pickingAlbum = [item] }.disabled(item.isLocalOnly)
            Button("Save to Photos", systemImage: "square.and.arrow.down") { runner.saveToPhotos([item], app: app, albumID: album?.id) }.disabled(item.localAssetID != nil)
            Button(slideshow ? "Stop slideshow" : "Slideshow", systemImage: slideshow ? "pause" : "play.rectangle") {
                slideshow.toggle(); state.chromeVisible = !slideshow
            }
            if !item.isVideo, WidgetSnapshotStore.isAvailable {
                Button("Show in widget", systemImage: "square.grid.2x2") { pinToWidget(item) }
            }
            if album != nil {
                Button("Remove from album", systemImage: "rectangle.stack.badge.minus", role: .destructive) { removing = true }
            }
        } label: { Image(systemName: "ellipsis").font(.title3).frame(maxWidth: .infinity, minHeight: 48) }
            .accessibilityLabel("More")
    }
    private func bottomButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title3).frame(maxWidth: .infinity, minHeight: 48) }
            .accessibilityLabel(title)
    }
    private func pinToWidget(_ item: RemotePhoto) {
        guard let source = item.thumbnailSource else { return }
        runner.run("Updating widget…") {
            guard let image = await ImagePipeline.shared.image(source, shared: shared, size: .xl) else { throw ConnectionError.invalidResponse }
            let data = WidgetSnapshot.previewData(image)
            let title = item.date.map { PhotoTime.format($0, .dateTime.month(.abbreviated).day().year()) } ?? "From your library"
            try WidgetSnapshotStore.save(.init(title: title, image: data, date: Date()))
            WidgetCenter.shared.reloadAllTimelines()
            return "The Fotera widget now shows this photo. Clear it in Settings to return to rotating memories."
        }
    }
}

/// UIPageViewController wrapper with a swipe-down-to-dismiss gesture.
struct PagerView<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @ObservedObject var state: ViewerState
    let dismiss: () -> Void
    var showInfo: () -> Void = {}
    @ViewBuilder let page: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
        controller.view.backgroundColor = .clear
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        if count > 0 { controller.setViewControllers([context.coordinator.host(state.index)], direction: .forward, animated: false) }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        controller.view.addGestureRecognizer(pan)
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard count > 0 else { return }
        let shown = (controller.viewControllers?.first as? IndexedHost)?.index
        if shown != state.index || context.coordinator.lastCount != count {
            let forward = (shown ?? 0) <= state.index
            controller.setViewControllers([context.coordinator.host(state.index)], direction: forward ? .forward : .reverse,
                                          animated: shown != nil && context.coordinator.lastCount == count)
        }
        context.coordinator.lastCount = count
    }
    final class IndexedHost: UIHostingController<AnyView> {
        var index = 0
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PagerView
        var lastCount = 0
        init(_ parent: PagerView) { self.parent = parent; lastCount = parent.count }
        func host(_ index: Int) -> UIViewController {
            let host = IndexedHost(rootView: AnyView(parent.page(index).id(index)))
            host.index = index
            host.view.backgroundColor = .clear
            return host
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let index = (viewController as? IndexedHost)?.index, index > 0 else { return nil }
            return host(index - 1)
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let index = (viewController as? IndexedHost)?.index, index + 1 < parent.count else { return nil }
            return host(index + 1)
        }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let index = (controller.viewControllers?.first as? IndexedHost)?.index else { return }
            MainActor.assumeIsolated {
                parent.state.index = index
                parent.state.zoomed = false
            }
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            // Down dismisses, up opens details (like Immich and Ente); both only when not zoomed in.
            return MainActor.assumeIsolated { !parent.state.zoomed } && abs(velocity.y) > abs(velocity.x) * 1.5
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            MainActor.assumeIsolated {
                switch recognizer.state {
                case .changed:
                    if translation.y < 0 {
                        // Rubber-band upward as a hint that details are coming.
                        view.transform = CGAffineTransform(translationX: 0, y: translation.y * 0.25)
                        return
                    }
                    let offset = translation.y
                    view.transform = CGAffineTransform(translationX: translation.x * 0.3, y: offset).scaledBy(x: 1 - min(0.25, offset / 1600), y: 1 - min(0.25, offset / 1600))
                    parent.state.dismissOffset = offset
                case .ended, .cancelled:
                    if translation.y < -60 || recognizer.velocity(in: view).y < -700 {
                        UIView.animate(withDuration: 0.25) { view.transform = .identity }
                        parent.state.dismissOffset = 0
                        if recognizer.state == .ended { parent.showInfo() }
                    } else if translation.y > 120 || recognizer.velocity(in: view).y > 900 {
                        parent.dismiss()
                    } else {
                        UIView.animate(withDuration: 0.25) { view.transform = .identity }
                        parent.state.dismissOffset = 0
                    }
                default: break
                }
            }
        }
    }
}

/// One page: a fast preview first, then the original only when zoomed in or played.
// MARK: - Copies already on this iPhone

/// Finds the iPhone's own copy of a NAS item, like Immich does, so the viewer can show it without a
/// download. A match needs the same media type, the same filename and the same capture time (the NAS
/// stores wall-clock time, so it may differ from the phone's by a whole time-zone offset).
/// Only used when Photos access was already granted; Fotera never asks for it here.
actor LocalAssets {
    static let shared = LocalAssets()
    private var matches: [String: String?] = [:]
    /// Capture times (whole seconds) of every photo on the phone, to rule out most NAS-only items cheaply.
    private var times: Set<Int>?
    nonisolated static var allowed: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }
    func identifier(for item: RemotePhoto) -> String? {
        if Self.allowed, let local = item.localAssetID { return local }
        guard Self.allowed, item.passphrase == nil, let time = item.time else { return nil }
        let key = "\(item.id)|\(item.additional?.thumbnail?.cache_key ?? "")"
        if let known = matches[key] { return known }
        // A grid cell that scrolled away no longer needs an answer.
        guard !Task.isCancelled else { return nil }
        guard mayBeLocal(time) else { matches[key] = .some(nil); return nil }
        let found = Self.find(item, time: time)
        matches[key] = .some(found)
        return found
    }
    func clear() { matches = [:]; times = nil }
    private func mayBeLocal(_ time: Double) -> Bool {
        let set = localTimes(), base = Int(time.rounded())
        for zone in -56...56 {
            let t = base - zone * 900
            if set.contains(t) || set.contains(t - 1) || set.contains(t + 1) { return true }
        }
        return false
    }
    private func localTimes() -> Set<Int> {
        if let times { return times }
        LocalLibraryObserver.shared.start()
        var set = Set<Int>()
        PHAsset.fetchAssets(with: nil).enumerateObjects { asset, _, _ in
            if let date = asset.creationDate { set.insert(Int(date.timeIntervalSince1970.rounded())) }
        }
        times = set
        return set
    }
    private static func find(_ item: RemotePhoto, time: Double) -> String? {
        let wall = Date(timeIntervalSince1970: time)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                        wall.addingTimeInterval(-14 * 3600 - 2) as NSDate, wall.addingTimeInterval(14 * 3600 + 2) as NSDate)
        let assets = PHAsset.fetchAssets(with: item.isVideo ? .video : .image, options: options)
        let name = item.filename.lowercased(), stem = (name as NSString).deletingPathExtension
        var result: String?
        assets.enumerateObjects { asset, _, stop in
            guard let created = asset.creationDate else { return }
            // Time zones are whole quarter hours apart; allow 2 seconds for rounding.
            let remainder = abs((time - created.timeIntervalSince1970).truncatingRemainder(dividingBy: 900))
            guard remainder < 2 || remainder > 898 else { return }
            if item.isLive && !asset.mediaSubtypes.contains(.photoLive) { return }
            let names = PHAssetResource.assetResources(for: asset).map { $0.originalFilename.lowercased() }
            if names.contains(where: { $0 == name || ($0 as NSString).deletingPathExtension == stem }) {
                result = asset.localIdentifier; stop.pointee = true
            }
        }
        return result
    }
}
/// Forgets matches when photos are added to or removed from the phone, and refreshes the badges.
/// One observer for the app. Photos often sends bursts of changes (iCloud sync, edits), so they're
/// coalesced into a single refresh.
final class LocalLibraryObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    static let shared = LocalLibraryObserver()
    private let lock = NSLock()
    private var started = false
    private var pending: Task<Void, Never>?
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        PHPhotoLibrary.shared().register(self)
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock(); defer { lock.unlock() }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await LocalAssets.shared.clear()
            await PhoneLibraryIndex.shared.invalidate()
            await MainActor.run { NotificationCenter.default.post(name: .foteraLocalLibraryChanged, object: nil) }
        }
    }
}
extension Notification.Name { static let foteraLocalLibraryChanged = Notification.Name("FoteraLocalLibraryChanged") }

/// Immich-style marker on a grid tile: a cloud when the item is only on the NAS. Items also on this
/// iPhone stay unmarked. Shows nothing without Photos access, since it can't tell.
struct LocalAvailabilityBadge: View {
    let item: RemotePhoto
    let compact: Bool
    @State private var onPhone: Bool?
    @State private var revision = 0
    var body: some View {
        Group {
            if item.isLocalOnly {
                Image(systemName: "iphone").font(.system(size: compact ? 8 : 10, weight: .semibold))
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2).padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .accessibilityLabel("iPhone only")
            } else if onPhone == false {
                Image(systemName: "cloud.fill").font(.system(size: compact ? 8 : 10, weight: .semibold))
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .accessibilityLabel("Only on NAS")
            }
        }
        .task(id: "\(item.id)|\(revision)") {
            guard LocalAssets.allowed, item.passphrase == nil else { onPhone = nil; return }
            let found = await LocalAssets.shared.identifier(for: item) != nil
            if !Task.isCancelled { onPhone = found }
        }
        .onReceive(NotificationCenter.default.publisher(for: .foteraLocalLibraryChanged)) { _ in revision += 1 }
    }
}

/// Loads a local copy without touching iCloud; anything not fully on the phone falls back to the NAS.
@MainActor enum LocalCopy {
    static func asset(_ item: RemotePhoto) async -> PHAsset? {
        guard let id = await LocalAssets.shared.identifier(for: item) else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }
    static func image(_ asset: PHAsset, maxPixels: CGFloat, network: Bool = false) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat; options.resizeMode = .fast; options.isNetworkAccessAllowed = network
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: maxPixels, height: maxPixels), contentMode: .aspectFit, options: options) { image, info in
                guard !resumed, (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                resumed = true; continuation.resume(returning: image)
            }
        }
    }
    static func livePhoto(_ asset: PHAsset, network: Bool = false) async -> PHLivePhoto? {
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = network
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestLivePhoto(for: asset, targetSize: CGSize(width: 2400, height: 2400), contentMode: .aspectFit, options: options) { photo, info in
                guard !resumed, (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                resumed = true; continuation.resume(returning: photo)
            }
        }
    }
    static func video(_ asset: PHAsset, network: Bool = false) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = network; options.version = .current
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in continuation.resume(returning: video) }
        }
    }
}

struct MediaPage: View {
    let item: RemotePhoto
    let client: DSMClient
    let shared: Bool
    let albumID: Int?
    @ObservedObject var state: ViewerState
    @AppStorage("alwaysLoadOriginals") private var alwaysLoadOriginals = false
    @State private var preview: UIImage?
    @State private var full: UIImage?
    @State private var loadingFull = false
    @State private var player: AVPlayer?
    @State private var live: PHLivePhoto?
    @State private var livePlaying = false
    @State private var liveTask: Task<Void, Never>?
    @State private var temporary: URL?
    @State private var failure: String?
    @State private var working = false

    var body: some View {
        ZStack {
            if item.isVideo {
                if let player {
                    VideoPlayer(player: player).onTapGesture { withAnimation { state.chromeVisible.toggle() } }
                } else {
                    poster
                    if working { ProgressView().tint(.white).controlSize(.large) }
                }
            } else {
                ZoomableImage(image: full ?? preview, onZoom: { zoomed in
                    state.zoomed = zoomed
                    if zoomed { loadOriginal() }
                }, onTap: { withAnimation(.easeInOut(duration: 0.2)) { state.chromeVisible.toggle() } },
                onHold: item.isLive ? { pressed in
                    livePlaying = pressed
                    if pressed { requestLivePlayback() }
                } : nil)
                if let live, livePlaying {
                    LivePhotoPlayer(photo: live).allowsHitTesting(false).transition(.opacity)
                }
                if working && livePlaying { ProgressView("Loading Live Photo…").tint(.white).foregroundStyle(.white).allowsHitTesting(false) }
                if preview == nil && full == nil && failure == nil { ProgressView().tint(.white) }
            }
            if let failure {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(failure).multilineTextAlignment(.center).font(.subheadline)
                    Button("Retry") { self.failure = nil; Task { await activate() } }.buttonStyle(.bordered)
                }.foregroundStyle(.white).padding(32)
            }
        }
        .task {
            // Show the grid thumbnail already in memory right away, then upgrade to the sharp preview.
            if let source = item.thumbnailSource, preview == nil { preview = ImagePipeline.shared.bestCached(source, shared: shared) }
            // The copy on this iPhone, when there is one, needs no download at all.
            if let local = await LocalCopy.asset(item), let image = await LocalCopy.image(local, maxPixels: 2400, network: item.isLocalOnly) {
                preview = image; return
            }
            if item.isLocalOnly { if !item.isVideo { failure = "This photo is unavailable. Check Photos access or your iCloud connection." }; return }
            if let source = item.thumbnailSource, let sharp = await ImagePipeline.shared.image(source, shared: shared, size: .xl) { preview = sharp }
            if preview == nil && !item.isVideo { loadOriginal() }
        }
        .task(id: state.currentID) {
            if isPageCurrent() {
                // A short pause so swiping quickly past items doesn't start downloads for each.
                try? await Task.sleep(for: .milliseconds(item.isVideo ? 80 : 300))
                guard !Task.isCancelled else { return }
                await activate()
            } else {
                player?.pause()
                livePlaying = false
            }
        }
        .onChange(of: state.liveRequest) { if isPageCurrent() { livePlaying.toggle(); if livePlaying { requestLivePlayback() } } }
        .onDisappear { teardown() }
    }
    private func isPageCurrent() -> Bool { state.currentID == item.id }
    private var poster: some View {
        Group {
            if let preview { Image(uiImage: preview).resizable().scaledToFit() } else { Color.clear }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { state.chromeVisible.toggle() } }
    }
    private func activate() async {
        if item.isVideo { await startVideo() }
        else {
            if item.isLive { requestLivePlayback() }   // Prepare the motion so press-and-hold plays at once.
            if alwaysLoadOriginals { loadOriginal() }
        }
    }
    private func loadOriginal() {
        guard full == nil, !loadingFull, !item.isVideo else { return }
        loadingFull = true
        Task {
            defer { loadingFull = false }
            do {
                if let local = await LocalCopy.asset(item), let image = await LocalCopy.image(local, maxPixels: 6000, network: item.isLocalOnly) { full = image; return }
                guard !item.isLocalOnly else { throw MediaFailure.unsupportedPhoto }
                let file = try await client.original(item, shared: shared, albumID: albumID, useOfflineCache: true)
                defer { try? FileManager.default.removeItem(at: file) }
                guard let image = await ImagePipeline.decode(file: file, maxPixels: 6000) else { throw MediaFailure.unsupportedPhoto }
                full = image
            } catch {
                if preview == nil && !isCancelledRequest(error) { failure = error.localizedDescription }
            }
        }
    }
    /// Streams the NAS's converted version or the original (the NAS serves byte ranges, so playback
    /// starts without the whole file), and downloads the original only if neither can play.
    private func startVideo() async {
        if let player { player.play(); return }
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            var asset: AVAsset?
            // The copy on this iPhone plays immediately.
            if let local = await LocalCopy.asset(item) { asset = await LocalCopy.video(local, network: item.isLocalOnly) }
            if item.isLocalOnly && asset == nil { throw MediaFailure.unsupportedVideo }
            // Settings → Video quality decides between the NAS's smaller stream and the original.
            if asset == nil, VideoQuality.current.prefersStream, let url = try? await client.streamingURL(id: item.id, shared: shared) {
                let candidate = AVURLAsset(url: url)
                if (try? await withTimeout(8) { try await candidate.load(.isPlayable) }) == true { asset = candidate }
            }
            // Original quality, or no converted version: stream the original before downloading all of it.
            if asset == nil, let url = try? await client.originalStreamURL(item, shared: shared, albumID: albumID) {
                let candidate = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: Self.mimeType(item.filename)])
                if (try? await withTimeout(6) { try await candidate.load(.isPlayable) }) == true { asset = candidate }
            }
            if asset == nil {
                let file = try await client.original(item, shared: shared, albumID: albumID, useOfflineCache: true)
                temporary = file
                let local = AVURLAsset(url: file)
                guard try await local.load(.isPlayable) else { throw MediaFailure.unsupportedVideo }
                asset = local
            }
            guard let asset, !Task.isCancelled, isPageCurrent() else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            player.play()
        } catch {
            if !isCancelledRequest(error) { failure = error.localizedDescription }
        }
    }
    private static func mimeType(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "mov", "qt": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        default: return "video/mp4"
        }
    }
    private func requestLivePlayback() {
        guard item.isLive, live == nil, liveTask == nil else { return }
        liveTask = Task { await playLive(); liveTask = nil }
    }
    /// Prepared Live Photos are cached, so playing again (or coming back) needs no download.
    private func playLive() async {
        guard item.isLive, live == nil else { return }
        if let ready = LivePhotoCache.shared.cached(item, client: client, shared: shared) { live = ready; return }
        if let local = await LocalCopy.asset(item), let photo = await LocalCopy.livePhoto(local, network: item.isLocalOnly) {
            guard !Task.isCancelled else { return }
            live = photo; return
        }
        guard !item.isLocalOnly else { failure = "Live Photo motion is unavailable on this iPhone."; return }
        working = true
        defer { working = false }
        do {
            let photo = try await LivePhotoCache.shared.prepare(item, client: client, shared: shared, albumID: albumID, placeholder: full ?? preview)
            try Task.checkCancellation()
            withAnimation { live = photo }
        } catch {
            // Only report failures the user asked for by pressing; background preparation stays quiet.
            if livePlaying && !isCancelledRequest(error) { failure = "Live Photo motion couldn’t be loaded. " + error.localizedDescription }
        }
    }
    private func teardown() {
        liveTask?.cancel(); liveTask = nil; livePlaying = false
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        live = nil; full = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary); self.temporary = nil }
    }
}

func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw CancellationError() }
        guard let result = try await group.next() else { throw CancellationError() }
        group.cancelAll()
        return result
    }
}

enum MediaFailure: LocalizedError {
    case unsupportedVideo, unsupportedPhoto
    var errorDescription: String? {
        switch self {
        case .unsupportedVideo: return "This video can’t be played on this device."
        case .unsupportedPhoto: return "This original couldn’t be opened as an image."
        }
    }
}

// MARK: - Zoom

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    let onZoom: (Bool) -> Void
    let onTap: () -> Void
    var onHold: ((Bool) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.delegate = context.coordinator
        view.setImage(image)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        if onHold != nil {
            let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
            hold.minimumPressDuration = 0.3
            hold.allowableMovement = 15
            tap.require(toFail: hold)
            view.addGestureRecognizer(hold)
        }
        return view
    }
    func updateUIView(_ view: PhotoScrollView, context: Context) {
        context.coordinator.parent = self
        if view.imageView.image !== image { view.setImage(image) }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        private var zoomed = false
        init(parent: ZoomableImage) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PhotoScrollView)?.centerImage()
            let value = scrollView.zoomScale > 1.05
            if value != zoomed { zoomed = value; parent.onZoom(value) }
        }
        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began: parent.onHold?(true)
            case .ended, .cancelled, .failed: parent.onHold?(false)
            default: break
            }
        }
        @objc func tap() { parent.onTap() }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PhotoScrollView else { return }
            if view.zoomScale > 1.05 {
                view.setZoomScale(1, animated: true)
            } else {
                let scale: CGFloat = 2.5
                let point = recognizer.location(in: view.imageView)
                let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
/// Lays the image out aspect-fit at zoom 1, so swapping a preview for the original keeps the same geometry.
final class PhotoScrollView: UIScrollView {
    let imageView = UIImageView()
    private var laidOutSize = CGSize.zero
    private var aspect: CGFloat = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
        imageView.contentMode = .scaleAspectFit
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = 8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setImage(_ image: UIImage?) {
        imageView.image = image
        let newAspect = image.map { $0.size.width / max(1, $0.size.height) } ?? 0
        if abs(newAspect - aspect) > 0.01 { aspect = newAspect; laidOutSize = .zero; setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if laidOutSize != bounds.size {
            laidOutSize = bounds.size
            zoomScale = 1
            var size = bounds.size
            if aspect > 0 {
                if bounds.width / bounds.height > aspect { size.width = bounds.height * aspect } else { size.height = bounds.width / aspect }
            }
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
        }
        centerImage()
    }
    func centerImage() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2),
                                    left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }
}

// MARK: - Info

struct ItemInfoView: View {
    let item: RemotePhoto
    let shared: Bool
    @EnvironmentObject private var app: AppModel
    @State private var details: ItemDetails?
    @State private var failure: String?
    @State private var editingMetadata = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let date = item.date {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PhotoTime.format(date, .dateTime.weekday(.wide).month(.wide).day().year())).font(.headline)
                            Text(PhotoTime.format(date, .dateTime.hour().minute())).foregroundStyle(.secondary)
                        }
                    }
                    if let description = details?.additional?.description, !description.isEmpty { Text(description) }
                }
                Section {
                    row("doc", item.filename, subtitle: fileSubtitle)
                    if let exif = details?.additional?.exif, exif.camera != nil {
                        row("camera", exif.camera ?? "", subtitle: [exif.aperture, exif.exposure_time, exif.focal_length, exif.iso.map { "ISO \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        if let lens = exif.lens { Text(lens).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let video = details?.additional?.video_meta {
                        row("film", [video.video_codec?.uppercased(), video.duration.map { Duration.milliseconds($0).formatted(.time(pattern: .minuteSecond)) }].compactMap { $0 }.joined(separator: " · "), subtitle: nil)
                    }
                }
                if let gps = details?.additional?.gps {
                    Section("Location") {
                        let coordinate = CLLocationCoordinate2D(latitude: gps.latitude, longitude: gps.longitude)
                        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000))) {
                            Marker("", coordinate: coordinate)
                        }
                        .frame(height: 180).listRowInsets(EdgeInsets())
                        if let address = details?.additional?.address?.summary { Text(address).font(.subheadline) }
                    }
                }
                if let people = details?.additional?.person, !people.isEmpty {
                    Section("People") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(people) { person in
                                    VStack {
                                        ThumbnailView(source: person.cover(kind: "person"), shared: shared, size: .sm)
                                            .frame(width: 56, height: 56).clipShape(Circle())
                                        Text(person.name.isEmpty ? "Unnamed" : person.name).font(.caption).lineLimit(1)
                                    }.frame(width: 64)
                                }
                            }
                        }
                    }
                }
                if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { if !item.isLocalOnly { Button("Edit") { editingMetadata = true } } }
            .sheet(isPresented: $editingMetadata, onDismiss: { Task { if let client = app.client { details = try? await client.details(id: item.id, shared: shared) } } }) { PhotoMetadataEditor(item: item, shared: shared) }
            .task {
                guard !item.isLocalOnly, let client = app.client else { return }
                do { details = try await client.details(id: item.id, shared: shared) }
                catch { failure = error.localizedDescription }
            }
        }
    }
    private var fileSubtitle: String {
        var parts: [String] = []
        if let resolution = details?.additional?.resolution {
            let megapixels = Double(resolution.width * resolution.height) / 1_000_000
            parts.append("\(resolution.width) × \(resolution.height)")
            if megapixels >= 1 { parts.append(String(format: "%.0f MP", megapixels)) }
        }
        if let size = details?.filesize ?? item.filesize { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        parts.append(item.isLocalOnly ? "iPhone" : (item.localAssetID != nil ? "iPhone and NAS" : (shared ? "Shared Space" : "NAS")))
        return parts.joined(separator: " · ")
    }
    private func row(_ icon: String, _ title: String, subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

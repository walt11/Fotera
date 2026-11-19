import SwiftUI
import Combine

/// One set of shape and spacing values so every card, tile and row looks related.
enum Theme {
    static let radius: CGFloat = 12
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let gutter: CGFloat = 16
}
extension View {
    /// The standard secondary-background card.
    func card(padding: CGFloat = Theme.medium) -> some View {
        self.padding(padding)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case dark = "Dark", system = "System", light = "Light"
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// Favorite IDs for the current space, used for the small heart on grid tiles.
@MainActor final class FavoriteMarks: ObservableObject {
    static let shared = FavoriteMarks()
    @Published private(set) var ids = Set<Int>()
    /// True once a sync has loaded favorites for the current space.
    private(set) var loaded = false
    func replace(_ ids: Set<Int>, loaded: Bool = true) { self.loaded = loaded; if ids != self.ids { self.ids = ids } }
    func set(_ items: [Int], _ value: Bool) {
        var updated = ids
        if value { updated.formUnion(items) } else { updated.subtract(items) }
        ids = updated
    }
}

// MARK: - Zoom transition

extension View {
    /// Marks a grid tile as the origin of the viewer's zoom transition (iOS 18+).
    @ViewBuilder func zoomSource(id: Int, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
    /// Opens the viewer by zooming out of its grid tile, like Immich and Ente (iOS 18+).
    @ViewBuilder func zoomTransition(sourceID: Int, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: sourceID, in: namespace)) } else { self }
    }
    /// A sidebar on iPad and a tab bar on iPhone (iOS 18+).
    @ViewBuilder func adaptiveTabs() -> some View {
        if #available(iOS 18.0, *) { tabViewStyle(.sidebarAdaptable) } else { self }
    }
}

enum Haptics {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Skeleton placeholders

/// Pulsing placeholder tiles shown while a grid loads, instead of a spinner.
struct SkeletonGrid: View {
    var columns = 4
    var rows = 8
    var showsHeaders = true
    @State private var pulse = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<3, id: \.self) { block in
                    if showsHeaders {
                        RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill))
                            .frame(width: block == 0 ? 140 : 96, height: block == 0 ? 20 : 12)
                            .padding(.horizontal, Theme.medium).padding(.top, block == 0 ? 12 : 18).padding(.bottom, 8)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                        ForEach(0..<(columns * (block == 0 ? 3 : rows / 2)), id: \.self) { _ in
                            Rectangle().fill(Color(.secondarySystemFill)).aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
        }
        .scrollDisabled(true)
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityLabel("Loading photos")
    }
}

// MARK: - Scroll tracking

/// Reports how far a scroll view has scrolled and whether it is moving (iOS 18 and later).
struct ScrollTracking: ViewModifier {
    @Binding var fraction: CGFloat
    @Binding var active: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    let range = geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                    guard range > 0 else { return 0 }
                    return min(1, max(0, (geometry.contentOffset.y + geometry.contentInsets.top) / range))
                } action: { _, value in fraction = value }
                .onScrollPhaseChange { _, phase in active = phase != .idle }
        } else {
            content
        }
    }
}

// MARK: - Grid badges

/// Duration for videos, a Live Photo mark, and a heart for favorites, drawn over a tile.
struct TileBadges: View {
    let item: RemotePhoto
    let favorite: Bool
    let compact: Bool
    var body: some View {
        ZStack {
            if item.isVideo {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: compact ? 7 : 9, weight: .bold))
                    if let duration = item.durationText, !compact { Text(duration).font(.caption2.weight(.semibold)).monospacedDigit() }
                }
                .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2)
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if item.isLive && !compact {
                Image(systemName: "livephoto").font(.caption2.weight(.semibold))
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            LocalAvailabilityBadge(item: item, compact: compact)
            if favorite {
                Image(systemName: "heart.fill").font(.system(size: compact ? 8 : 10, weight: .bold))
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Transient timeline status

/// Lives above the grid, never in its layout. Progress counts do not extend the
/// dismissal deadline or bring a dismissed popup back during the same operation.
struct TimelineStatusPopup: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var backup: BackupController
    let notice: String?
    @State private var message: String?
    @State private var symbol = "info.circle"
    @State private var category = ""
    @State private var presentation = UUID()
    private var backingUp: Bool { backup.running && backup.preferences.enabled }

    var body: some View {
        Group {
            if let message {
                Label(message, systemImage: symbol)
                    .font(.footnote)
                    .lineLimit(3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .frame(maxWidth: 340)
                    .transition(.opacity)
                    .accessibilityLabel(message)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: message != nil)
        .onAppear {
            if let notice { show(notice, category: "notice") }
            else if let failure = library.failure { show("Couldn’t refresh: " + failure, category: "failure") }
            else if let progress = library.progress { show(progress, category: "indexing") }
            else if backingUp { show(backup.status, category: "backup") }
        }
        .onChange(of: notice) { _, value in
            if let value { show(value, category: "notice") }
            else { clear("notice") }
        }
        .onChange(of: library.failure) { _, value in
            if let value { show("Couldn’t refresh: " + value, category: "failure") }
            else { clear("failure") }
        }
        .onChange(of: library.progress) { old, value in
            if let value {
                if old == nil { show(value, category: "indexing") }
                else if category == "indexing", message != nil { message = value }
            } else { clear("indexing") }
        }
        .onChange(of: backingUp) { _, active in
            if active { show(backup.status, category: "backup") }
            else { clear("backup") }
        }
        .onChange(of: backup.status) { _, value in
            if category == "backup", message != nil { message = value }
        }
        .task(id: presentation) {
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            message = nil
        }
    }

    private func show(_ text: String, category: String) {
        guard !text.isEmpty else { return }
        // An ongoing operation must not immediately replace an actionable notice.
        if message != nil, ["notice", "failure"].contains(self.category),
           ["indexing", "backup"].contains(category) { return }
        self.category = category
        symbol = category == "failure" ? "exclamationmark.triangle" :
            category == "backup" ? "icloud.and.arrow.up" :
            category == "indexing" ? "arrow.triangle.2.circlepath" : "info.circle"
        message = text
        presentation = UUID()
    }

    private func clear(_ category: String) {
        if self.category == category { message = nil }
    }
}

// MARK: - Memory stories

/// Full-screen memory. Photos change only when the user taps previous or next.
struct MemoryStoryView: View {
    let memory: Memory
    let shared: Bool
    var showInTimeline: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var viewer: ViewerRequest?
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private var items: [RemotePhoto] { memory.items }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.indices.contains(index) {
                if items[index].isVideo, let client = app.client {
                    MemoryVideoPage(item: items[index], client: client, shared: shared,
                                    active: viewer == nil && scenePhase == .active)
                        .id(items[index].id)
                        .padding(.top, 70)
                        .padding(.bottom, 120)
                } else {
                    ThumbnailView(source: items[index].thumbnailSource, shared: shared, size: .xl, contentMode: .fit, fallbackPhoto: items[index], animatesLoading: false)
                        .background(Color.black)
                        .id(items[index].id)
                        .ignoresSafeArea()
                }
            }
            if items[safe: index]?.isVideo != true {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
                }
                .accessibilityElement()
                .accessibilityLabel("\(memory.title), item \(index + 1) of \(items.count)")
                .accessibilityAction(named: "Next") { step(1) }
                .accessibilityAction(named: "Previous") { step(-1) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(items.indices, id: \.self) { position in
                        GeometryReader { geometry in
                            Capsule().fill(.white.opacity(0.3))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white).frame(width: geometry.size.width * fill(position))
                                }
                        }.frame(height: 3)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memory.title).font(.headline)
                        if let date = items[safe: index]?.date {
                            Text(PhotoTime.format(date, .dateTime.month(.wide).day().year())).font(.caption).opacity(0.8)
                        }
                    }
                    Spacer()
                    Button { viewer = ViewerRequest(id: items[safe: index]?.id ?? 0, items: items) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 36, height: 36)
                    }.accessibilityLabel("Open in viewer")
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36) }
                        .accessibilityLabel("Close")
                }
                Spacer()
                if items[safe: index]?.isVideo == true {
                    HStack(spacing: 40) {
                        Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .disabled(index == 0).accessibilityLabel("Previous")
                        Text("\(index + 1) of \(items.count)").font(.caption.monospacedDigit())
                        Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                            .accessibilityLabel(index + 1 == items.count ? "Finish memory" : "Next")
                    }.frame(maxWidth: .infinity)
                }
                Button {
                    guard let photo = items[safe: index] else { return }
                    showInTimeline(photo.id)
                    dismiss()
                } label: {
                    Label("Show in timeline", systemImage: "square.grid.3x3")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .frame(maxWidth: .infinity).padding(.bottom, 24)
                .disabled(items.isEmpty)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .padding(.horizontal, Theme.medium).padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .fullScreenCover(item: $viewer) { request in MediaViewer(items: request.items, startID: request.id, shared: shared) }
    }
    private func fill(_ position: Int) -> CGFloat { position <= index ? 1 : 0 }
    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0 else { return }
        guard next < items.count else { dismiss(); return }
        index = next
    }
}


/// Reuses the viewer's local-first playback, NAS streaming, retry, and cleanup.
struct MemoryVideoPage: View {
    let item: RemotePhoto
    let client: DSMClient
    let shared: Bool
    let active: Bool
    @StateObject private var state: ViewerState

    init(item: RemotePhoto, client: DSMClient, shared: Bool, active: Bool) {
        self.item = item; self.client = client; self.shared = shared; self.active = active
        _state = StateObject(wrappedValue: ViewerState(index: 0, currentID: active ? item.id : nil))
    }

    var body: some View {
        MediaPage(item: item, client: client, shared: shared, albumID: nil, state: state)
            .onChange(of: active) { state.currentID = active ? item.id : nil }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Viewer filmstrip

/// Small thumbnails along the bottom of the viewer for quick jumps.
struct Filmstrip: View {
    let items: [RemotePhoto]
    let shared: Bool
    @ObservedObject var state: ViewerState
    private var window: Range<Int> {
        let lower = max(0, state.index - 40), upper = min(items.count, state.index + 41)
        return lower..<upper
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(window, id: \.self) { position in
                        let current = position == state.index
                        ThumbnailView(source: items[position].thumbnailSource, shared: shared, size: .sm, fallbackPhoto: items[position])
                            .frame(width: current ? 44 : 30, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: current ? 2 : 0))
                            .padding(.horizontal, current ? 4 : 0)
                            .id(position)
                            .onTapGesture { state.index = position }
                            .accessibilityLabel("Item \(position + 1) of \(items.count)")
                    }
                }
                .padding(.horizontal, 160)
                .animation(.snappy(duration: 0.2), value: state.index)
            }
            .frame(height: 48)
            .onAppear { proxy.scrollTo(state.index, anchor: .center) }
            .onChange(of: state.index) { withAnimation(.snappy) { proxy.scrollTo(state.index, anchor: .center) } }
        }
    }
}

#if DEBUG
struct MemoryNavigationPreview: View {
    private let photos = (0..<3000).map { RemotePhoto(id: $0, filename: "Photo \($0)", time: Double(1_780_739_985 - $0 * 86400), type: "photo", additional: nil) }
    @State private var selection: Set<Int>?
    @State private var memory: Memory?
    @State private var pending: Int?
    @State private var jump: TimelineJump?
    var body: some View {
        NavigationStack {
            PhotoGrid(sections: (0..<3).map { month in GridSection(id: "month-\(month)", title: "Month \(month)", items: Array(photos[(month * 1000)..<((month + 1) * 1000)])) }, shared: false,
                      selection: $selection, timelineJump: jump) {
                Button("Open test memory") { memory = Memory(id: "test", title: "Test memory", items: Array(photos[1790...1792])) }
                    .padding()
            }.navigationTitle("Memory navigation")
        }
        .fullScreenCover(item: $memory, onDismiss: {
            if let pending { jump = TimelineJump(photoID: pending); self.pending = nil }
        }) { memory in
            MemoryStoryView(memory: memory, shared: false) { pending = $0 }
        }
    }
}
#endif


/// Compact branding for the app's main pages.
struct FoteraBrand: View {
    var page: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image("FoteraMark").resizable().scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Fotera").font(.headline)
                if let page { Text(page).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

/// Keep server-owned metadata current after edits made in the web app or another client.
@MainActor private struct ActiveMetadataRefresh: ViewModifier {
    @Environment(\.scenePhase) private var phase
    let key: String
    let action: @MainActor () async -> Void
    func body(content: Content) -> some View {
        content.task(id: key + "|" + String(describing: phase)) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await action()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
}
extension View {
    @MainActor func refreshWhileActive(key: String, action: @escaping @MainActor () async -> Void) -> some View {
        modifier(ActiveMetadataRefresh(key: key, action: action))
    }
}

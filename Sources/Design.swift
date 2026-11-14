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

// MARK: - Backup progress line

/// A slim progress line under the top bar while backup runs. Tap to open Backup.
struct BackupProgressLine: View {
    @ObservedObject var backup: BackupController
    let open: () -> Void
    var body: some View {
        if backup.running && backup.preferences.enabled {
            Button(action: open) {
                VStack(spacing: 4) {
                    ProgressView(value: Double(backup.backedUpAssets), total: Double(max(1, backup.totalAssets)))
                        .progressViewStyle(.linear).tint(.accentColor)
                    Text(backup.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Theme.medium).padding(.vertical, 6)
                .background(.bar)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("Backup in progress. \(backup.status)")
        }
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
    private var items: [RemotePhoto] { memory.items }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.indices.contains(index) {
                ThumbnailView(source: items[index].thumbnailSource, shared: shared, size: .xl, contentMode: .fit, fallbackPhoto: items[index], animatesLoading: false)
                    .background(Color.black)
                    .id(items[index].id)
                    .ignoresSafeArea()
            }
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
            }
            .accessibilityElement()
            .accessibilityLabel("\(memory.title), item \(index + 1) of \(items.count)")
            .accessibilityAction(named: "Next") { step(1) }
            .accessibilityAction(named: "Previous") { step(-1) }
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
                        ThumbnailView(source: items[position].thumbnailSource, shared: shared, size: .sm)
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

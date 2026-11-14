import SwiftUI

struct GridSection: Identifiable, Sendable {
    let id: String
    let title: String?
    let items: [RemotePhoto]
    /// Sections sharing a group (for example a month) appear under one sticky header.
    var group: String? = nil
    var groupTitle: String? = nil
}
struct GridGroup: Identifiable {
    let id: String
    let title: String?
    let sections: [GridSection]
}
extension Array where Element == RemotePhoto {
    var asSingleSection: [GridSection] { isEmpty ? [] : [GridSection(id: "all", title: nil, items: self)] }
}
struct ViewerRequest: Identifiable {
    let id: Int
    let items: [RemotePhoto]
}

/// The shared photo grid: pinch to change density, long-press to select, drag the right edge to scrub.
struct PhotoGrid<Header: View>: View {
    let sections: [GridSection]
    let shared: Bool
    @Binding var selection: Set<Int>?
    var album: RemoteAlbum? = nil
    var showsScrubber = false
    var onReachEnd: (() -> Void)? = nil
    var onChange: () -> Void = {}
    @ViewBuilder var header: () -> Header
    @AppStorage("gridColumns") private var columns = 4
    @ObservedObject private var favorites = FavoriteMarks.shared
    @State private var viewer: ViewerRequest?
    @State private var scrollFraction: CGFloat = 0
    @State private var scrolling = false

    private var groups: [GridGroup] {
        var result: [GridGroup] = []
        for section in sections {
            let key = section.group ?? "section-" + section.id
            if let last = result.last, last.id == key {
                result[result.count - 1] = GridGroup(id: key, title: last.title, sections: last.sections + [section])
            } else {
                result.append(GridGroup(id: key, title: section.groupTitle, sections: [section]))
            }
        }
        return result
    }
    var body: some View {
        let grouped = sections.contains { $0.group != nil }
        ScrollViewReader { proxy in
            ScrollView {
                header()
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: grouped ? [.sectionHeaders] : []) {
                    if grouped {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.sections) { section in sectionView(section, minor: true) }
                            } header: {
                                if let title = group.title { monthHeader(title) }
                            }
                        }
                    } else {
                        // Most grids have no month groups; skip building them on every redraw.
                        ForEach(sections) { section in sectionView(section, minor: false) }
                    }
                    if let onReachEnd { Color.clear.frame(height: 1).onAppear(perform: onReachEnd) }
                }
                .padding(.bottom, 12)
                .animation(.default, value: columns)
            }
            .modifier(ScrollTracking(fraction: $scrollFraction, active: $scrolling))
            .overlay(alignment: .trailing) {
                if showsScrubber && sections.count > 6 {
                    TimelineScrubber(sections: sections, proxy: proxy, fraction: scrollFraction, scrolling: scrolling)
                }
            }
        }
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            if value.magnification > 1.25 { columns = max(2, columns - 1) }
            else if value.magnification < 0.8 { columns = min(7, columns + 1) }
        })
        .fullScreenCover(item: $viewer) { request in
            MediaViewer(items: request.items, startID: request.id, shared: shared, album: album, onChange: onChange)
        }
    }
    private func sectionView(_ section: GridSection, minor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = section.title { sectionHeader(title, section, minor: minor) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    tile(item, in: section)
                        .onAppear { prefetch(after: index, in: section) }
                }
            }
        }.id(section.id)
    }
    /// Warms the next two rows so fast scrolling shows fewer empty tiles.
    private func prefetch(after index: Int, in section: GridSection) {
        let start = index + 1, end = min(section.items.count, index + 1 + columns * 2)
        guard start < end else { return }
        let size: ThumbnailSize = columns <= 3 ? .m : .sm
        ImagePipeline.shared.prefetch(section.items[start..<end].compactMap(\.thumbnailSource), shared: shared, size: size)
    }
    private func monthHeader(_ title: String) -> some View {
        Text(title).font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.medium).padding(.vertical, 10)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
    }
    private func sectionHeader(_ title: String, _ section: GridSection, minor: Bool) -> some View {
        HStack {
            Text(title).font(minor ? .footnote.weight(.medium) : .subheadline.weight(.semibold))
                .foregroundStyle(minor ? .secondary : .primary)
            Spacer()
            if let selection {
                let all = section.items.allSatisfy { selection.contains($0.id) }
                Button {
                    var updated = selection
                    if all { section.items.forEach { updated.remove($0.id) } } else { section.items.forEach { updated.insert($0.id) } }
                    self.selection = updated
                } label: {
                    Image(systemName: all ? "checkmark.circle.fill" : "circle").font(.title3)
                }.accessibilityLabel(all ? "Deselect \(title)" : "Select \(title)")
            }
        }
        .padding(.horizontal, Theme.medium).padding(.top, minor ? 10 : 16).padding(.bottom, 6)
    }
    private func tile(_ item: RemotePhoto, in section: GridSection) -> some View {
        let selected = selection?.contains(item.id) == true
        return ThumbnailView(source: item.thumbnailSource, shared: shared, size: columns <= 3 ? .m : .sm, fallbackPhoto: item)
            .aspectRatio(1, contentMode: .fit)
            .overlay { TileBadges(item: item, favorite: favorites.ids.contains(item.id), compact: columns >= 6) }
            .scaleEffect(selected ? 0.86 : 1)
            .overlay(alignment: .topLeading) {
                if selection != nil {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.accentColor : .black.opacity(0.2))
                        .font(.title3).shadow(radius: 1).padding(5)
                }
            }
            .background(selected ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if var current = selection {
                    if !current.insert(item.id).inserted { current.remove(item.id) }
                    selection = current
                } else {
                    viewer = ViewerRequest(id: item.id, items: sections.flatMap(\.items))
                }
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                var current = selection ?? []
                current.insert(item.id)
                withAnimation(.snappy) { selection = current }
            }
            .animation(.snappy(duration: 0.2), value: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(item, selected: selected))
            .accessibilityAddTraits(.isButton)
    }
    private func accessibilityLabel(_ item: RemotePhoto, selected: Bool) -> String {
        let kind = item.isVideo ? "Video" : (item.isLive ? "Live Photo" : "Photo")
        let date = item.date.map { PhotoTime.format($0, .dateTime.month().day().year()) } ?? ""
        return [kind, item.durationText, date, favorites.ids.contains(item.id) ? "Favorite" : nil, selected ? "Selected" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
extension PhotoGrid where Header == EmptyView {
    init(sections: [GridSection], shared: Bool, selection: Binding<Set<Int>?>, album: RemoteAlbum? = nil,
         showsScrubber: Bool = false, onReachEnd: (() -> Void)? = nil, onChange: @escaping () -> Void = {}) {
        self.init(sections: sections, shared: shared, selection: selection, album: album, showsScrubber: showsScrubber,
                  onReachEnd: onReachEnd, onChange: onChange, header: { EmptyView() })
    }
}

/// The right-edge scrubber. A thumb follows scrolling (iOS 18+), year markers appear while dragging,
/// and dragging jumps through the timeline with a date bubble, like Immich.
struct TimelineScrubber: View {
    let sections: [GridSection]
    let proxy: ScrollViewProxy
    var fraction: CGFloat = 0
    var scrolling = false
    @State private var position: CGFloat?
    @State private var label = ""
    @State private var lastIndex = -1
    @State private var visible = false
    private var years: [(year: Int, fraction: CGFloat)] {
        var result: [(Int, CGFloat)] = []
        var last: Int?
        for (index, section) in sections.enumerated() {
            guard let date = section.items.first?.date else { continue }
            let year = PhotoTime.calendar.component(.year, from: date)
            if year != last { result.append((year, CGFloat(index) / CGFloat(max(1, sections.count)))); last = year }
        }
        return result
    }
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .topTrailing) {
                Color.clear.contentShape(Rectangle())
                if position != nil {
                    // Year markers, skipping any that would overlap the previous one.
                    let markers = years.reduce(into: [(Int, CGFloat)]()) { result, entry in
                        let y = entry.fraction * height
                        if let previous = result.last, y - previous.1 < 22 { return }
                        result.append((entry.year, y))
                    }
                    ForEach(markers, id: \.0) { year, y in
                        Text(String(year)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                            .offset(x: -14, y: min(max(0, y - 8), max(0, height - 16)))
                            .allowsHitTesting(false)
                    }
                }
                if position != nil || visible {
                    let y = position ?? fraction * height
                    Capsule().fill(position == nil ? Color.secondary.opacity(0.8) : Color.accentColor)
                        .frame(width: 5, height: 36)
                        .overlay(alignment: .trailing) {
                            if position != nil {
                                Text(label).font(.footnote.weight(.semibold))
                                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(.regularMaterial, in: Capsule())
                                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                                    .offset(x: -54)
                                    .allowsHitTesting(false)
                            }
                        }
                        .offset(y: min(max(0, y - 18), max(0, height - 36)))
                        .padding(.trailing, 4)
                        .transition(.opacity)
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !sections.isEmpty else { return }
                let fraction = min(max(0, value.location.y / max(1, height)), 0.999)
                let index = Int(fraction * CGFloat(sections.count))
                position = value.location.y
                if index != lastIndex {
                    lastIndex = index
                    let section = sections[index]
                    label = section.items.first?.date.map { PhotoTime.format($0, .dateTime.month(.abbreviated).year()) } ?? (section.title ?? "")
                    proxy.scrollTo(section.id, anchor: .top)
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }.onEnded { _ in withAnimation(.easeOut.delay(0.4)) { position = nil }; lastIndex = -1 })
        }
        .frame(width: 44)
        .padding(.vertical, 8)
        .onChange(of: scrolling) {
            if scrolling { withAnimation(.easeIn(duration: 0.15)) { visible = true } }
        }
        .task(id: scrolling) {
            guard !scrolling else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { visible = false }
        }
        .accessibilityHidden(true)
    }
}

struct SelectionActions: OptionSet {
    let rawValue: Int
    static let share = SelectionActions(rawValue: 1)
    static let favorite = SelectionActions(rawValue: 2)
    static let album = SelectionActions(rawValue: 4)
    static let save = SelectionActions(rawValue: 8)
    static let delete = SelectionActions(rawValue: 16)
    static let removeFromAlbum = SelectionActions(rawValue: 32)
    static let standard: SelectionActions = [.share, .favorite, .album, .save, .delete]
}

/// Adds the "N selected" toolbar and bottom action bar shown while selecting.
struct SelectionChrome: ViewModifier {
    @Binding var selection: Set<Int>?
    let items: [RemotePhoto]
    let actions: SelectionActions
    var album: RemoteAlbum? = nil
    var unfavorite = false
    var onChange: () -> Void = {}
    @EnvironmentObject private var app: AppModel
    @StateObject private var runner = ActionRunner()
    private var chosen: [RemotePhoto] {
        guard let selection else { return [] }
        return items.filter { selection.contains($0.id) }
    }
    func body(content: Content) -> some View {
        content
            .toolbar {
                if let selection {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { withAnimation(.snappy) { self.selection = nil } }
                    }
                    ToolbarItem(placement: .principal) {
                        Text(selection.isEmpty ? "Select items" : "\(selection.count) selected").font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selection.count == items.count ? "Deselect All" : "Select All") {
                            self.selection = selection.count == items.count ? [] : Set(items.map(\.id))
                        }
                    }
                }
            }
            .toolbar(selection != nil ? .hidden : .automatic, for: .tabBar)
            .navigationBarBackButtonHidden(selection != nil)
            .safeAreaInset(edge: .bottom) {
                if selection != nil { bar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .actionRunner(runner) { finish() }
    }
    private func finish() {
        withAnimation(.snappy) { selection = nil }
        onChange()
    }
    private var bar: some View {
        let disabled = chosen.isEmpty || runner.busy != nil
        return HStack {
            if actions.contains(.share) { barButton("Share", "square.and.arrow.up") { runner.share(chosen, app: app, albumID: album?.id) } }
            if actions.contains(.favorite) {
                barButton(unfavorite ? "Unfavorite" : "Favorite", unfavorite ? "heart.slash" : "heart") {
                    runner.setFavorite(chosen, value: !unfavorite, app: app) { finish() }
                }
            }
            if actions.contains(.album) { barButton("Add to", "rectangle.stack.badge.plus") { runner.pickingAlbum = chosen } }
            if actions.contains(.save) { barButton("Save", "square.and.arrow.down") { runner.saveToPhotos(chosen, app: app, albumID: album?.id) } }
            if actions.contains(.removeFromAlbum), let album {
                barButton("Remove", "rectangle.stack.badge.minus") { runner.removeFromAlbum(chosen, album: album, app: app) { finish() } }
            }
            if actions.contains(.delete) { barButton("Delete", "trash", role: .destructive) { runner.requestDelete(chosen, app: app) } }
        }
        .disabled(disabled)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
    private func barButton(_ title: String, _ icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }.frame(maxWidth: .infinity)
        }
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}
extension View {
    func selectionChrome(_ selection: Binding<Set<Int>?>, items: [RemotePhoto], actions: SelectionActions = .standard,
                         album: RemoteAlbum? = nil, unfavorite: Bool = false, onChange: @escaping () -> Void = {}) -> some View {
        modifier(SelectionChrome(selection: selection, items: items, actions: actions, album: album, unfavorite: unfavorite, onChange: onChange))
    }
}

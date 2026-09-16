//
//  CollectionFolderBrowseView.swift
//  NuvioTV
//
//  Created for NuvioTVOS modularization.
//

import SwiftUI
import Foundation

/// One catalog strip inside Rows view mode (Android `RowsContent`).
struct CollectionFolderCatalogRow: Identifiable {
    let id: String
    let title: String
    let source: NuvioCollectionSource
    var items: [NuvioMeta]
    var nextSkip: Int
    var hasMore: Bool
    var isLoadingMore: Bool = false
}

private struct CollectionFolderSourceLoad {
    let index: Int
    let source: NuvioCollectionSource
    let page: CatalogPage?
    let errorMessage: String?
}

#if os(macOS)
/// Band ids for the collection browser's keyboard model. Rows mode stacks one
/// band per catalog strip; Tabs mode is the tab bar above a single grid band.
enum CollectionFolderFocusBand {
    static let tabs = "collection.tabs"
    static let grid = "collection.grid"

    static func row(_ id: String) -> String { "collection.row.\(id)" }
}
#endif

/// Drags the viewport along with the caret.
///
/// The highlight is a plain value, so on macOS it lands on rows and cards
/// below the fold that the scroll view never follows by itself. On tvOS the
/// focus engine already does this and the target stays nil.
private struct MacCaretScroll: ViewModifier {
    let target: String?
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content.onChange(of: target) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

/// Full-screen folder browser. Honors collection `viewMode`:
/// - **Tabs** (`TABBED_GRID`): poster grid (optional source tabs + All).
/// - **Rows** / **Follow layout**: Home-style horizontal catalog rows per source.
struct CollectionFolderBrowseView: View {
    let folder: TVCollectionFolderItem
    let collectionTitle: String
    let repository: CatalogRepository
    let onSelect: (NuvioMeta) -> Void
    let onLongPress: (NuvioMeta) -> Void
    let onBack: () -> Void

    @State private var items: [NuvioMeta] = []
    @State private var catalogRows: [CollectionFolderCatalogRow] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTabIndex = 0
    @FocusState private var focusedItemID: String?
    @FocusState private var isLoadingFocusActive: Bool
    @State private var lastFocusedItemID: String?
    @State private var focusRestoreGeneration = 0
    @State private var watchedTitleKeys: Set<String> = []
    @State private var cachedCollectionMetadata: [String: NuvioMeta] = [:]
    @State private var collectionEnrichmentTask: Task<Void, Never>?
    #if os(macOS)
    /// macOS has no focus engine, so the screen carries its own caret. Without
    /// one nothing here was reachable from the keyboard at all.
    @StateObject private var macFocus = MacScreenFocus("collections")
    @ObservedObject private var macKeyRouter = MacKeyRouter.shared
    #endif
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

    private let pageSize = 40

    private var usesRows: Bool {
        folder.viewMode.usesCatalogRows(homeLayout: homeLayout)
    }
    private var usesCinematicPresentation: Bool {
        guard usesRows else { return false }
        return ["STREAMING_SERVICE", "STUDIO_FRANCHISE"].contains(
            folder.presentationStyle?.uppercased() ?? ""
        )
    }
    /// A folder opened in Rows mode should retain Home-row behavior even when
    /// the top-level Home preference is Grid View. Compact remains compact;
    /// every other layout uses the normal portrait-to-landscape Home row.
    private var collectionRowLayoutMode: String {
        homeLayout == "Compact" ? "Compact" : "Modern"
    }

    private var heading: String {
        if collectionTitle.caseInsensitiveCompare(folder.title) == .orderedSame {
            return collectionTitle
        }
        return "\(collectionTitle) • \(folder.title)"
    }

    /// Tab labels for Tabs mode: optional "All" + one tab per source.
    private var tabLabels: [String] {
        guard !usesRows, folder.sources.count > 1 else { return [] }
        var labels: [String] = []
        if folder.showAllTab {
            labels.append("All")
        }
        for source in folder.sources {
            labels.append(Self.sourceLabel(source))
        }
        return labels
    }

    private var displayedGridItems: [NuvioMeta] {
        guard !usesRows else { return items }
        guard !tabLabels.isEmpty else { return items }
        if folder.showAllTab, selectedTabIndex == 0 {
            return items
        }
        let sourceIndex = folder.showAllTab ? selectedTabIndex - 1 : selectedTabIndex
        guard folder.sources.indices.contains(sourceIndex) else { return items }
        let source = folder.sources[sourceIndex]
        // Items were loaded per-source into catalogRows when multi-source.
        if let row = catalogRows.first(where: { $0.id == Self.sourceKey(source) }) {
            return row.items
        }
        return []
    }

    /// Sports and live-TV folders declare LANDSCAPE, and their artwork is
    /// fixture/channel imagery that a portrait crop ruins.
    private var tileShape: CollectionTileShape { folder.tileShape }

    private var tileSize: (width: CGFloat, height: CGFloat) {
        CollectionFolderGridMetrics.tileSize(for: tileShape)
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: tileSize.width, maximum: tileSize.width),
            spacing: CollectionFolderGridMetrics.posterGap,
            alignment: .top
        )]
    }

    var body: some View {
        Group {
            if usesCinematicPresentation {
                cinematicRowsBrowser
            } else {
                gridBrowser
            }
        }
        .onExitCommand(perform: onBack)
        .onAppear {
            requestLoadingFocusIfNeeded()
            #if os(macOS)
            // Presented over Home rather than as a tab, so it takes the front
            // of the key router for as long as it is up.
            macFocus.update(macBands)
            macFocus.syncClaim(isCurrent: true)
            #endif
        }
        .onDisappear {
            collectionEnrichmentTask?.cancel()
            collectionEnrichmentTask = nil
            #if os(macOS)
            macFocus.release()
            #endif
        }
        #if os(macOS)
        .onChange(of: macBandSignature, initial: true) { _, _ in
            macFocus.update(macBands)
        }
        .onChange(of: macKeyRouter.latest) { _, press in
            guard let press else { return }
            macFocus.handle(press.key, activate: macActivate)
        }
        #endif
        .task {
            refreshWatchedTitles()
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refreshWatchedTitles()
        }
        .onChange(of: focusedItemID) { _, newValue in
            if let newValue { lastFocusedItemID = newValue }
        }
        .onChange(of: isLoading) { _, loading in
            if loading {
                requestLoadingFocusIfNeeded()
            } else {
                isLoadingFocusActive = false
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                focusRestoreGeneration &+= 1
                if let focusedItemID { lastFocusedItemID = focusedItemID }
            } else if let target = lastFocusedItemID {
                let generation = focusRestoreGeneration
                DispatchQueue.main.async {
                    guard focusRestoreGeneration == generation else { return }
                    focusedItemID = target
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard focusRestoreGeneration == generation else { return }
                    focusedItemID = target
                }
            }
        }
    }

    private var gridBrowser: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                header

                if !tabLabels.isEmpty {
                    tabBar
                }

                if isLoading {
                    Spacer()
                    BrandLoadingView(wordmarkWidth: 360)
                        .frame(maxWidth: .infinity)
                        .overlay { loadingFocusAnchor }
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if usesRows {
                    rowsContent
                } else if displayedGridItems.isEmpty {
                    Spacer()
                    Text("No titles found in this folder")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    gridContent
                }
            }
        }
    }

    /// Rows-mode collections share the same cinematic identity treatment as
    /// network/company pages: full-bleed artwork, a large logo hero, then rails.
    private var cinematicRowsBrowser: some View {
        ZStack(alignment: .top) {
            cinematicBackdrop

            ScrollViewReader { macHeroScroll in
              ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    cinematicHero

                    if isLoading {
                        BrandLoadingView(wordmarkWidth: 360)
                            .frame(maxWidth: .infinity, minHeight: 260)
                            .overlay { loadingFocusAnchor }
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if catalogRows.isEmpty {
                        Text("No titles found in this folder")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(catalogRows) { row in
                            CollectionFolderHomeStyleRow(
                                id: row.id,
                                title: row.title,
                                items: row.items,
                                isLoadingMore: row.isLoadingMore,
                                layoutMode: collectionRowLayoutMode,
                                showPosterLabels: posterLabels,
                                externalFocus: $focusedItemID,
                                macFocusedCardKey: macCaretItemID,
                                watchedTitleKeys: watchedTitleKeys,
                                onFocus: enrichCollectionItemIfNeeded,
                                onApproachEnd: { item in
                                    loadMoreRowIfNeeded(rowId: row.id, currentItem: item)
                                },
                                onLongPress: onLongPress,
                                onSelect: onSelect
                            )
                            .id("collection.row.\(row.id)")
                        }
                    }
                }
                .padding(.bottom, 70)
              }
              .focusSection()
              .defaultFocusIfAvailable($focusedItemID, firstFocusID)
              .modifier(MacCaretScroll(target: macCaretRowAnchor, proxy: macHeroScroll))
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    private var cinematicBackdrop: some View {
        let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        return ZStack {
            if let url = cinematicBackdropURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                backdropColor
            }

            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: backdropColor.opacity(0.96), location: 0),
                        .init(color: backdropColor.opacity(0.86), location: 0.25),
                        .init(color: backdropColor.opacity(0.64), location: 0.50),
                        .init(color: backdropColor.opacity(0.34), location: 0.70),
                        .init(color: backdropColor.opacity(0.10), location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.76)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            LinearGradient(
                colors: [.clear, backdropColor.opacity(0.74), backdropColor],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Keep focus inside the full-screen collection while its network request
    /// is pending, so Menu reaches this view's `onExitCommand` instead of the
    /// Apple TV shell.
    private var loadingFocusAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable(true)
            .focused($isLoadingFocusActive)
    }

    private func requestLoadingFocusIfNeeded() {
        guard isLoading else { return }
        DispatchQueue.main.async {
            guard isLoading else { return }
            isLoadingFocusActive = true
        }
    }

    private var cinematicBackdropURL: URL? {
        let firstItem = catalogRows.lazy.flatMap { $0.items }.first
        for candidate in [folder.heroBackdropUrl, firstItem?.backgroundUrl, firstItem?.posterUrl] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, let url = URL(string: value) { return url }
        }
        return nil
    }

    private var cinematicHero: some View {
        HStack(alignment: .bottom, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                Text(cinematicCategoryLabel)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))

                Text(folder.title)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                Text("Movies and series • \(folder.sources.count) catalogs")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white.opacity(0.68))
            }

            Spacer(minLength: 20)

            if let logo = folder.preferredTitleLogoURLString ?? folder.coverImageUrl,
               let url = URL(string: logo) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text(folder.title)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 520, height: 190)
            }
        }
        .padding(.horizontal, TVLayout.rowLeading)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .bottom)
    }

    private var cinematicCategoryLabel: String {
        folder.presentationStyle?.uppercased() == "STUDIO_FRANCHISE"
            ? "Studio & Franchise"
            : "Streaming Service"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(heading)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitleLine)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 60)
        // Start below the collapsed menu rather than behind it: the title was
        // drawn straight over the hamburger in the window's top-left corner.
        #if os(macOS)
        .padding(.top, MacMenuMetrics.headerTopInset)
        #else
        .padding(.top, 48)
        #endif
    }

    private var subtitleLine: String {
        let count = folder.sources.count
        let catalogs = count == 1 ? "1 catalog" : "\(count) catalogs"
        if usesRows {
            return "\(catalogs) · Rows"
        }
        return catalogs
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(tabLabels.enumerated()), id: \.offset) { index, label in
                    CollectionFolderTabButton(
                        label: label,
                        isSelected: selectedTabIndex == index,
                        macIsFocused: macCaretIsOnTab(index)
                    ) {
                        selectedTabIndex = index
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 8)
        }
        .scrollClipDisabledIfAvailable()
        .focusSection()
    }

    /// Home-style vertical list of horizontal catalog strips.
    private var rowsContent: some View {
        Group {
            if catalogRows.isEmpty {
                Spacer()
                Text("No titles found in this folder")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { macRowScroll in
                  ScrollView {
                    VStack(alignment: .leading, spacing: TVHomeLayout.sectionSpacing) {
                        ForEach(catalogRows) { row in
                            CollectionFolderHomeStyleRow(
                                id: row.id,
                                title: row.title,
                                items: row.items,
                                isLoadingMore: row.isLoadingMore,
                                layoutMode: collectionRowLayoutMode,
                                showPosterLabels: posterLabels,
                                externalFocus: $focusedItemID,
                                macFocusedCardKey: macCaretItemID,
                                watchedTitleKeys: watchedTitleKeys,
                                onFocus: enrichCollectionItemIfNeeded,
                                onApproachEnd: { item in
                                    loadMoreRowIfNeeded(rowId: row.id, currentItem: item)
                                },
                                onLongPress: onLongPress,
                                onSelect: onSelect
                            )
                            .id("collection.row.\(row.id)")
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 60)
                  }
                  .focusSection()
                  .defaultFocusIfAvailable($focusedItemID, firstFocusID)
                  .modifier(MacCaretScroll(target: macCaretRowAnchor, proxy: macRowScroll))
                }
            }
        }
    }

    private var gridContent: some View {
      ScrollViewReader { macGridScroll in
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: CollectionFolderGridMetrics.posterGap) {
                ForEach(displayedGridItems) { item in
                    CollectionFolderResultCard(
                        meta: item,
                        tileShape: tileShape,
                        externalFocus: $focusedItemID,
                        isWatched: isTitleWatched(item),
                        macIsFocused: macCaretIsOnGridItem(item.id),
                        onLongPress: { onLongPress(item) }
                    ) {
                        onSelect(item)
                    }
                    .id(item.id)
                    .onAppear {
                        loadMoreGridIfNeeded(currentItem: item)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 60)

            if isGridLoadingMore {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            }

            Color.clear.frame(height: 60)
        }
        .focusSection()
        .defaultFocusIfAvailable($focusedItemID, firstFocusID)
        .id(selectedTabIndex)
        .modifier(MacCaretScroll(target: macCaretGridAnchor, proxy: macGridScroll))
      }
    }

    private var firstFocusID: String? {
        if usesRows {
            guard let row = catalogRows.first(where: { !$0.items.isEmpty }),
                  let item = row.items.first else {
                return nil
            }
            return "\(row.id)\u{1}\(item.id)"
        }
        return displayedGridItems.first?.id
    }

    /// The caret's card key. The card views are shared with tvOS, where the
    /// focus engine owns the highlight and this stays nil.
    private var macCaretItemID: String? {
        #if os(macOS)
        return macFocus.itemID
        #else
        return nil
        #endif
    }

    /// The strip the caret is in, as a scroll id, so a Down onto an off-screen
    /// row brings it into view. Nil on tvOS, where the focus engine scrolls.
    private var macCaretRowAnchor: String? {
        #if os(macOS)
        guard let band = macFocus.bandID, band.hasPrefix("collection.row.") else { return nil }
        return band
        #else
        return nil
        #endif
    }

    private var macCaretGridAnchor: String? {
        #if os(macOS)
        guard macFocus.bandID == CollectionFolderFocusBand.grid else { return nil }
        return macFocus.itemID
        #else
        return nil
        #endif
    }

    private func macCaretIsOnTab(_ index: Int) -> Bool {
        #if os(macOS)
        return macFocus.isFocused(CollectionFolderFocusBand.tabs, String(index))
        #else
        return false
        #endif
    }

    private func macCaretIsOnGridItem(_ id: String) -> Bool {
        #if os(macOS)
        return macFocus.isFocused(CollectionFolderFocusBand.grid, id)
        #else
        return false
        #endif
    }

    #if os(macOS)
    // MARK: - macOS keyboard focus

    /// The screen as a vertical stack of bands. Rows mode is one band per
    /// catalog strip, each `items.count` wide so Left/Right walks the strip;
    /// Tabs mode is the tab bar over a single grid band that knows its own
    /// column count.
    private var macBands: [MacFocusBand] {
        guard !isLoading else { return [] }

        if usesRows {
            return catalogRows.compactMap { row in
                guard !row.items.isEmpty else { return nil }
                return MacFocusBand(
                    id: CollectionFolderFocusBand.row(row.id),
                    items: row.items.map { "\(row.id)\u{1}\($0.id)" }
                )
            }
        }

        var bands: [MacFocusBand] = []
        if !tabLabels.isEmpty {
            bands.append(MacFocusBand(
                id: CollectionFolderFocusBand.tabs,
                items: tabLabels.indices.map(String.init)
            ))
        }
        let items = displayedGridItems
        if !items.isEmpty {
            bands.append(MacFocusBand(
                id: CollectionFolderFocusBand.grid,
                items: items.map(\.id),
                columns: macGridColumns
            ))
        }
        return bands
    }

    /// The grid is `.adaptive`, so the column count follows the width the
    /// canvas actually gives it rather than a constant.
    private var macGridColumns: Int {
        // `MacTVCanvas` is generic over its content, so the static needs a
        // concrete parameter to name the canvas the app actually renders on.
        let available = MacTVCanvas<EmptyView>.canvasSize.width - 120
        let step = tileSize.width + CollectionFolderGridMetrics.posterGap
        return max(Int((available + CollectionFolderGridMetrics.posterGap) / step), 1)
    }

    /// Cheap stand-in for the bands themselves, which are not `Equatable`.
    /// The caret only has to be rebuilt when the shape of the screen changes —
    /// a row gaining a page, a tab switching, the load finishing.
    private var macBandSignature: String {
        if usesRows {
            let rows = catalogRows.map { "\($0.id):\($0.items.count)" }.joined(separator: ",")
            return "rows:\(isLoading):\(rows)"
        }
        return "grid:\(isLoading):\(selectedTabIndex):\(displayedGridItems.count)"
    }

    private func macIsFocused(_ band: String, _ item: String) -> Bool {
        macFocus.isFocused(band, item)
    }

    private func macActivate(band: String, item: String) {
        if band == CollectionFolderFocusBand.tabs {
            guard let index = Int(item), tabLabels.indices.contains(index) else { return }
            selectedTabIndex = index
            return
        }

        if band == CollectionFolderFocusBand.grid {
            guard let match = displayedGridItems.first(where: { $0.id == item }) else { return }
            onSelect(match)
            return
        }

        // A row's key is "rowId\u{1}itemId"; the meta id is the tail, and it
        // can itself contain the separator's neighbours, so split once only.
        guard let separator = item.firstIndex(of: "\u{1}") else { return }
        let rowId = String(item[item.startIndex..<separator])
        let metaId = String(item[item.index(after: separator)...])
        guard let row = catalogRows.first(where: { $0.id == rowId }),
              let match = row.items.first(where: { $0.id == metaId })
        else { return }
        onSelect(match)
    }
    #endif

    private func refreshWatchedTitles() {
        watchedTitleKeys = WatchedStore.visibleWholeTitleIdentityKeys()
    }

    private func isTitleWatched(_ meta: NuvioMeta) -> Bool? {
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: meta)
        )
        guard !["series", "tv", "show", "tvshow"].contains(meta.type.lowercased()) else {
            return titleWatched ? true : nil
        }
        return titleWatched
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        selectedTabIndex = 0

        let sources = folder.sources
        if sources.isEmpty {
            items = []
            catalogRows = []
            errorMessage = "This folder has no sources."
            isLoading = false
            return
        }

        // Always load per-source so Rows mode (and Tabs without All) can split.
        var rows: [CollectionFolderCatalogRow] = []
        var all: [NuvioMeta] = []
        var seen = Set<String>()
        var firstFailureMessage: String?
        let loadedSources = await withTaskGroup(
            of: CollectionFolderSourceLoad.self,
            returning: [CollectionFolderSourceLoad].self
        ) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { @MainActor [repository] in
                    do {
                        let page = try await CollectionSourceResolver(repository: repository)
                            .browse(source)
                        return CollectionFolderSourceLoad(
                            index: index,
                            source: source,
                            page: page,
                            errorMessage: nil
                        )
                    } catch {
                        return CollectionFolderSourceLoad(
                            index: index,
                            source: source,
                            page: nil,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }

            var results: [CollectionFolderSourceLoad] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }

        for result in loadedSources {
            let source = result.source
            guard let page = result.page else {
                if firstFailureMessage == nil {
                    firstFailureMessage = result.errorMessage
                }
                continue
            }
            let batch = pageItems(page, source: source)
            var sourceIds = Set<String>()
            let resolved = batch.filter { sourceIds.insert($0.id).inserted }
            rows.append(
                CollectionFolderCatalogRow(
                    id: Self.sourceKey(source),
                    title: Self.sourceLabel(source),
                    source: source,
                    items: resolved,
                    nextSkip: nextCursor(
                        page,
                        source: source,
                        requestedCursor: 0,
                        receivedCount: batch.count
                    ),
                    hasMore: page.hasMore && !batch.isEmpty
                )
            )
            for meta in resolved where seen.insert(meta.id).inserted {
                all.append(meta)
            }
        }
        // Tabs must retain their source-to-row mapping even when one source is
        // empty. Rows mode can omit empty strips.
        catalogRows = usesRows ? rows.filter { !$0.items.isEmpty } : rows
        items = all
        if items.isEmpty, let firstFailureMessage {
            errorMessage = firstFailureMessage
        }
        isLoading = false

        // The first card does not exist during the loading render, so the
        // default-focus modifier cannot select it by itself. Re-arm focus once
        // the catalog has been inserted into the view hierarchy.
        await Task.yield()
        focusedItemID = firstFocusID
    }

    private var isGridLoadingMore: Bool {
        if folder.showAllTab, !tabLabels.isEmpty, selectedTabIndex == 0 {
            return catalogRows.contains(where: \.isLoadingMore)
        }
        guard let rowId = selectedGridRowId else { return false }
        return catalogRows.first(where: { $0.id == rowId })?.isLoadingMore == true
    }

    private var selectedGridRowId: String? {
        guard !usesRows, !tabLabels.isEmpty else { return catalogRows.first?.id }
        if folder.showAllTab, selectedTabIndex == 0 { return nil }
        let sourceIndex = folder.showAllTab ? selectedTabIndex - 1 : selectedTabIndex
        guard folder.sources.indices.contains(sourceIndex) else { return nil }
        return Self.sourceKey(folder.sources[sourceIndex])
    }

    private func loadMoreGridIfNeeded(currentItem: NuvioMeta) {
        guard displayedGridItems.suffix(8).contains(where: { $0.id == currentItem.id }) else { return }

        if folder.showAllTab, !tabLabels.isEmpty, selectedTabIndex == 0 {
            for row in catalogRows where row.hasMore && !row.isLoadingMore {
                loadMoreSource(rowId: row.id)
            }
        } else if let rowId = selectedGridRowId {
            loadMoreSource(rowId: rowId)
        }
    }

    private func loadMoreRowIfNeeded(rowId: String, currentItem: NuvioMeta) {
        guard let row = catalogRows.first(where: { $0.id == rowId }),
              row.items.suffix(8).contains(where: { $0.id == currentItem.id }) else { return }
        loadMoreSource(rowId: rowId)
    }

    private func loadMoreSource(rowId: String) {
        guard let rowIndex = catalogRows.firstIndex(where: { $0.id == rowId }),
              catalogRows[rowIndex].hasMore,
              !catalogRows[rowIndex].isLoadingMore else { return }

        let source = catalogRows[rowIndex].source
        let requestedSkip = catalogRows[rowIndex].nextSkip
        catalogRows[rowIndex].isLoadingMore = true

        Task { @MainActor in
            do {
                let page = try await CollectionSourceResolver(repository: repository)
                    .browse(source, cursor: requestedSkip)
                guard let latestIndex = catalogRows.firstIndex(where: { $0.id == rowId }) else { return }

                let batch = pageItems(page, source: source)
                var existingRowIds = Set(catalogRows[latestIndex].items.map(\.id))
                let newItems = batch.filter { existingRowIds.insert($0.id).inserted }
                catalogRows[latestIndex].items.append(contentsOf: newItems)
                catalogRows[latestIndex].nextSkip = nextCursor(
                    page,
                    source: source,
                    requestedCursor: requestedSkip,
                    receivedCount: batch.count
                )
                catalogRows[latestIndex].hasMore = page.hasMore && !newItems.isEmpty
                catalogRows[latestIndex].isLoadingMore = false

                var existingAllIds = Set(items.map(\.id))
                items.append(contentsOf: newItems.filter { existingAllIds.insert($0.id).inserted })
            } catch {
                guard let latestIndex = catalogRows.firstIndex(where: { $0.id == rowId }) else { return }
                catalogRows[latestIndex].isLoadingMore = false
            }
        }
    }

    /// Collections use the same focus-driven catalog enrichment as Home. This
    /// intentionally goes through the repository rather than TMDB, so a
    /// source-provided `/meta` logo still appears when TMDB is disabled.
    private func enrichCollectionItemIfNeeded(_ item: NuvioMeta) {
        guard item.needsHeroMetadataEnrichment else { return }
        let key = "\(item.type.lowercased())\u{1f}\(item.id)"

        if let fullMeta = cachedCollectionMetadata[key] {
            applyCollectionMetadata(fullMeta, to: item.id)
            return
        }

        // Focus moves quickly while the user browses with the remote. Do not
        // start one metadata request per card passed over; wait for focus to
        // settle and cancel the previous pending request.
        collectionEnrichmentTask?.cancel()
        collectionEnrichmentTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let fullMeta = try? await repository.refreshMetadata(
                id: item.id,
                type: item.type
            ), !Task.isCancelled else {
                return
            }
            cachedCollectionMetadata[key] = fullMeta
            applyCollectionMetadata(fullMeta, to: item.id)
        }
    }

    private func applyCollectionMetadata(_ fullMeta: NuvioMeta, to itemID: String) {
        for rowIndex in catalogRows.indices {
            guard let itemIndex = catalogRows[rowIndex].items.firstIndex(where: { $0.id == itemID }) else {
                continue
            }
            let compact = catalogRows[rowIndex].items[itemIndex]
            catalogRows[rowIndex].items[itemIndex] = compact.fillingMissingHeroMetadata(from: fullMeta)
        }
        if let itemIndex = items.firstIndex(where: { $0.id == itemID }) {
            items[itemIndex] = items[itemIndex].fillingMissingHeroMetadata(from: fullMeta)
        }
    }

    private func pageItems(
        _ page: CatalogPage,
        source: NuvioCollectionSource
    ) -> [NuvioMeta] {
        source.normalizedProvider == "addon"
            ? Array(page.items.prefix(pageSize))
            : page.items
    }

    private func nextCursor(
        _ page: CatalogPage,
        source: NuvioCollectionSource,
        requestedCursor: Int,
        receivedCount: Int
    ) -> Int {
        if source.normalizedProvider == "addon" {
            return requestedCursor + receivedCount
        }
        return page.nextSkip ?? requestedCursor
    }

    private static func sourceKey(_ source: NuvioCollectionSource) -> String {
        source.routeKey
    }

    private static func sourceLabel(_ source: NuvioCollectionSource) -> String {
        CollectionSourceResolver.label(for: source)
    }
}

/// One Home-like catalog strip inside Rows mode.
/// Uses the same focus-driven strip offset + spring as `TVCatalogRow` (not
/// a native ScrollView), so left/right focus slides cards under the title.
private struct CollectionFolderHomeStyleRow: View {
    let id: String
    let title: String
    let items: [NuvioMeta]
    var isLoadingMore: Bool = false
    var layoutMode: String = "Modern"
    var showPosterLabels: Bool = false
    var externalFocus: FocusState<String?>.Binding? = nil
    /// The screen's caret, as a plain value so the cards actually redraw as it
    /// passes. `.focused` bindings are not render dependencies.
    var macFocusedCardKey: String? = nil
    let watchedTitleKeys: Set<String>
    let onFocus: (NuvioMeta) -> Void
    let onApproachEnd: (NuvioMeta) -> Void
    let onLongPress: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void

    /// Stable row id so composite card keys stay unique across strips.
    private var rowId: String { id }

    @State private var scrollIndex: Int = 0
    @State private var landscapeFocusedId: String?
    @State private var pendingLandscapeFocusedId: String?
    @State private var landscapeFocusTask: Task<Void, Never>?
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.focusedPosterBackdropEnabled) private var focusedPosterBackdropEnabled = true
    @AppStorage(SettingsKey.focusedPosterBackdropDelay) private var focusedPosterBackdropDelay = 3

    private var posterWidth: CGFloat {
        layoutMode == "Compact" ? 170 : 210
    }

    private var rowSpacing: CGFloat {
        layoutMode == "Compact" ? 22 : 28
    }

    private var step: CGFloat { posterWidth + rowSpacing }

    private var stripHeight: CGFloat {
        let imageHeight: CGFloat = layoutMode == "Compact" ? 255 : 315
        return imageHeight + (showPosterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(1)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onDisappear {
            landscapeFocusTask?.cancel()
            landscapeFocusTask = nil
            pendingLandscapeFocusedId = nil
        }
        .onChange(of: focusedPosterBackdropEnabled) { _, enabled in
            guard !enabled else { return }
            pendingLandscapeFocusedId = nil
            landscapeFocusTask?.cancel()
            landscapeFocusTask = nil
            landscapeFocusedId = nil
        }
    }

    /// Same clipping-window + manual offset pattern as `TVCatalogRow.cardStrip`.
    private var cardStrip: some View {
        GeometryReader { geo in
            let edgeInset = max(0, geo.frame(in: .global).minX)
            let stripWidth = geo.size.width + edgeInset * 2
            let rowHomeLayout = layoutMode
            let rowPosterLabels = showPosterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowStep = (rowHomeLayout == "Compact" ? 170.0 : 210.0)
                + (rowHomeLayout == "Compact" ? 22.0 : 28.0)

            HStack(alignment: .bottom, spacing: rowHomeLayout == "Compact" ? 22 : 28) {
                ForEach(items) { item in
                    let cardKey = "\(rowId)\u{1}\(item.id)"
                    PosterCard(
                        meta: item,
                        isLandscape: rowHomeLayout == "Modern" && landscapeFocusedId == cardKey,
                        onFocus: { focused in
                            if let index = items.firstIndex(where: { $0.id == focused.id }) {
                                if scrollIndex != index {
                                    scrollIndex = index
                                }
                            }
                            onFocus(focused)
                            scheduleLandscapeFocus(cardKey: cardKey)
                            onApproachEnd(focused)
                        },
                        onBlur: { blurred in
                            let key = "\(rowId)\u{1}\(blurred.id)"
                            clearLandscapeFocus(cardKey: key)
                        },
                        macFocusedCardKey: macFocusedCardKey,
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey,
                        onLongPress: onLongPress,
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowSmoothFocus,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        isWatched: isTitleWatched(item)
                    ) {
                        onSelect(item)
                    }
                }

                if isLoadingMore {
                    ProgressView()
                        .tint(.white)
                        .frame(width: posterWidth, height: rowHomeLayout == "Compact" ? 255 : 315)
                }
            }
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            // Pin the focused card under the title (Home BringIntoViewSpec).
            .offset(x: edgeInset + TVLayout.rowLeading - CGFloat(scrollIndex) * rowStep)
            .frame(
                width: stripWidth,
                height: (rowHomeLayout == "Compact" ? 255 : 315)
                    + (rowPosterLabels ? 48 : 0)
                    + TVHomeLayout.stripVerticalPadding * 2,
                alignment: .leading
            )
            .clipped()
            .offset(x: -edgeInset)
            .animation(rowSmoothFocus ? TVHomeLayout.scrollAnimation : nil, value: scrollIndex)
            .animation(rowSmoothFocus ? TVHomeLayout.scrollAnimation : nil, value: landscapeFocusedId)
        }
        .frame(height: stripHeight)
    }

    private func isTitleWatched(_ meta: NuvioMeta) -> Bool? {
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: meta)
        )
        guard !["series", "tv", "show", "tvshow"].contains(meta.type.lowercased()) else {
            return titleWatched ? true : nil
        }
        return titleWatched
    }

    /// Wait for the configured backdrop delay before expanding the settled
    /// portrait card, and cancel when focus moves away.
    private func scheduleLandscapeFocus(cardKey: String) {
        guard layoutMode == "Modern", focusedPosterBackdropEnabled else {
            pendingLandscapeFocusedId = nil
            landscapeFocusedId = nil
            landscapeFocusTask?.cancel()
            return
        }
        if pendingLandscapeFocusedId == cardKey && landscapeFocusedId == nil { return }
        if landscapeFocusedId == cardKey { return }

        pendingLandscapeFocusedId = cardKey
        landscapeFocusedId = nil
        landscapeFocusTask?.cancel()

        let targetKey = cardKey
        let delaySeconds = max(0, focusedPosterBackdropDelay)
        landscapeFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled,
                  pendingLandscapeFocusedId == targetKey else { return }
            landscapeFocusedId = targetKey
        }
    }

    private func clearLandscapeFocus(cardKey: String) {
        if pendingLandscapeFocusedId == cardKey {
            pendingLandscapeFocusedId = nil
            landscapeFocusTask?.cancel()
        }
        if landscapeFocusedId == cardKey {
            landscapeFocusedId = nil
        }
    }
}

/// Pill tab button for CollectionFolderBrowseView (Grid view mode).
/// Displays a clear focus outline (theme accent color) when navigated to,
/// and highlights selected tabs.
private struct CollectionFolderTabButton: View {
    let label: String
    let isSelected: Bool
    /// Driven by `MacScreenFocus`; macOS has no focus engine to set `focused`.
    var macIsFocused = false
    let action: () -> Void

    @FocusState private var focused: Bool
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    /// tvOS reads the focus engine; macOS has none, so the caret decides.
    private var isFocused: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return focused
        #endif
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .background(
                    backgroundColor,
                    in: Capsule(style: .continuous)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isFocused ? AppFocusOutline.color : .clear,
                            lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                        )
                )
                .shadow(
                    color: .black.opacity(isFocused ? 0.45 : 0.0),
                    radius: isFocused ? 12 : 0
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : .easeOut(duration: 0.12), value: isFocused)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var textColor: Color {
        if isFocused {
            return .black
        }
        return isSelected ? .black : .white.opacity(0.85)
    }

    private var backgroundColor: Color {
        if isFocused {
            return .white
        }
        return isSelected ? Color.white : Color.white.opacity(0.12)
    }
}

/// Poster card chrome matching Search / Library grids (Tabs view mode).
struct CollectionFolderResultCard: View {
    let meta: NuvioMeta
    var tileShape: CollectionTileShape = .poster
    var externalFocus: FocusState<String?>.Binding? = nil
    var isWatched: Bool? = nil
    /// Driven by `MacScreenFocus`: macOS has no focus engine to set `focused`,
    /// and a focus binding is not a render dependency, so the card would never
    /// redraw as the caret passed over it.
    var macIsFocused = false
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    private var tileSize: (width: CGFloat, height: CGFloat) {
        CollectionFolderGridMetrics.tileSize(for: tileShape)
    }

    /// tvOS reads the focus engine; macOS has none, so the caret decides.
    private var focused: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return isFocused
        #endif
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                CachedPosterArtwork(
                    // A landscape tile wants wide art: the fixture/channel
                    // backdrop first, with the poster only as a last resort.
                    urlString: tileShape == .landscape
                        ? (meta.backgroundUrl ?? meta.posterUrl)
                        : meta.posterUrl,
                    width: tileSize.width,
                    height: tileSize.height,
                    maximumWidth: tileSize.width
                ) {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.07))
                        Image(systemName: meta.type == "series" ? "tv" : "film")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .frame(width: tileSize.width, height: tileSize.height)
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: focused,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(alignment: .topTrailing) {
                    if let isWatched {
                        if isWatched { WatchedCheckmarkIcon() }
                    } else {
                        WatchedCheckmarkBadge(meta: meta)
                    }
                }
                .overlay(
                    shape.stroke(
                        focused ? AppFocusOutline.color : .clear,
                        lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                    )
                )
                .shadow(
                    color: .black.opacity(focused ? 0.5 : 0.2),
                    radius: focused ? 16 : 6
                )

                if posterLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(focused ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: tileSize.width, alignment: .leading)
                }
            }
            .scaleEffect(focused ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: meta.id))
        .focusEffectDisabledIfAvailable()
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: action
        )
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: focused)
        .zIndex(focused ? 1 : 0)
    }

    private var subtitle: String {
        var parts: [String] = [meta.type == "series" ? "Series" : "Movie"]
        if let year = meta.year { parts.append(String(year)) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: "  ·  ")
    }
}

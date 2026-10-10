#if os(iOS)
import SwiftUI

/// Loads Home for the phone: the same add-on catalogs, row order and Continue
/// Watching sources as tvOS `TVHomeView`, without its focus bookkeeping.
///
/// Deliberately simpler than tvOS for now: no skeleton rows, SMB/Jellyfin
/// rows or partial-load retry. Rows arrive as each add-on answers.
@MainActor
final class PhoneHomeLoader: ObservableObject {
    @Published private(set) var sections: [TVHomeSection] = []
    @Published private(set) var continueWatching: [ContinueWatchingItem] = []
    /// The synced collections, one row of folder cards each, as on the TV.
    @Published private(set) var collectionRows: [TVHomeSection] = TVHomeSection.collectionRows()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: CatalogRepository = CinemetaCatalogRepository()
    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [ContinueWatchingStore.changedNotification, ContinueWatchingDismissStore.changedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshContinueWatching() }
            })
        }
        // A sync pull or a Settings edit replaces the collections.
        observers.append(center.addObserver(forName: CollectionsStore.changedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.collectionRows = TVHomeSection.collectionRows() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// `key` identifies the profile + catalog revision; a new key reloads.
    func load(key: String, force: Bool = false) {
        guard force || key != loadedKey else { return }
        loadedKey = key
        refreshContinueWatching()
        collectionRows = TVHomeSection.collectionRows()
        loadTask?.cancel()
        loadTask = Task { await loadCatalogs() }
    }

    func reload() {
        guard let loadedKey else { return }
        load(key: loadedKey, force: true)
    }

    private func loadCatalogs() async {
        isLoading = true
        errorMessage = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            for try await catalogs in repository.homeCatalogsProgressively() {
                try Task.checkCancellation()
                let built = await makeSections(from: catalogs)
                try Task.checkCancellation()
                var seen = Set<String>()
                sections = TVHomeCatalogOrder.apply(to: built)
                    .filter { !$0.items.isEmpty && seen.insert($0.id).inserted }
            }
        } catch is CancellationError {
        } catch {
            if sections.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func makeSections(from catalogs: [NuvioCatalog]) async -> [TVHomeSection] {
        var result: [TVHomeSection] = []
        for catalog in catalogs {
            guard let items = catalog.items else { continue }
            let head = await TmdbDetailsService.localizedMetadata(for: Array(items.prefix(18)))
            let all = head + items.dropFirst(18)
            // Kids profiles: only child-friendly titles, in rows and hero.
            let visible = await KidsContentFilter.filterIfNeeded(all.filter(isVisible))
            result.append(TVHomeSection(
                id: catalog.id,
                title: catalog.name,
                items: visible,
                contentType: catalog.contentType,
                catalogId: catalog.catalogId,
                addonId: catalog.addonId,
                addonName: catalog.addonName,
                catalogGenre: catalog.catalogGenre,
                nextSkip: items.count,
                hasMore: catalog.contentType != nil && catalog.catalogId != nil
            ))
        }
        return result
    }

    /// Next page for a row once its last few posters come on screen.
    func loadMoreIfNeeded(sectionId: String, current meta: NuvioMeta) {
        guard let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let section = sections[index]
        guard section.hasMore, !section.isLoadingMore,
              let contentType = section.contentType, let catalogId = section.catalogId,
              let position = section.items.firstIndex(where: { $0.id == meta.id }),
              position >= section.items.count - 6 else { return }
        sections[index].isLoadingMore = true
        let skip = section.nextSkip ?? section.items.count
        Task {
            let page = try? await repository.browseCatalog(
                addonId: section.addonId,
                contentType: contentType,
                catalogId: catalogId,
                skip: skip,
                genre: section.catalogGenre
            )
            guard let page else {
                if let latest = sections.firstIndex(where: { $0.id == sectionId }) {
                    sections[latest].isLoadingMore = false
                }
                return
            }
            let existingBefore = Set(sections.first { $0.id == sectionId }?.items.map(\.id) ?? [])
            let unseen = page.items.filter { !existingBefore.contains($0.id) }
            // Kids profiles: later pages go through the same filter as the
            // first, or scrolling a row brought adult titles in.
            let allowed = await KidsContentFilter.filterIfNeeded(unseen.filter(isVisible))
            guard let latest = sections.firstIndex(where: { $0.id == sectionId }) else { return }
            sections[latest].isLoadingMore = false
            let existing = Set(sections[latest].items.map(\.id))
            let fresh = allowed.filter { !existing.contains($0.id) }
            sections[latest].items.append(contentsOf: fresh)
            sections[latest].nextSkip = page.nextSkip ?? (skip + page.items.count)
            // More pages may still hold allowed titles even when this one
            // had none, so keep going while the catalog has new items.
            sections[latest].hasMore = page.hasMore && !unseen.isEmpty
        }
    }

    // MARK: Continue Watching

    func refreshContinueWatching() {
        if RemoteTrackingState.isProgressSourceAuthenticated {
            progressTask?.cancel()
            progressTask = Task {
                let items = await TraktProgressService.fetchContinueWatching(
                    repository: repository,
                    source: TraktSettingsStore.watchProgressSource
                )
                guard !Task.isCancelled, let items else { return }
                var seen = Set<String>()
                let visible = items.filter { shouldDisplay($0) && seen.insert($0.meta.id).inserted }
                // Same order the TV and Mac show: the profile's Continue
                // Watching sort, not the provider's raw order.
                let sort = ProfileSettings.current.string(forKey: SettingsKey.continueWatchingSort) ?? "Default"
                continueWatching = ContinueWatchingSortPolicy.sorted(visible, preference: sort)
            }
            return
        }
        var byId: [String: ContinueWatchingItem] = [:]
        for item in ContinueWatchingBuilder.pagedItems { byId[item.meta.id] = item }
        for item in ContinueWatchingStore.items() { byId[item.meta.id] = item }
        let visible = byId.values
            .sorted { $0.recencySortDate > $1.recencySortDate }
            .filter(shouldDisplay)
        let sort = ProfileSettings.current.string(forKey: SettingsKey.continueWatchingSort) ?? "Default"
        continueWatching = ContinueWatchingSortPolicy.sorted(visible, preference: sort)
    }

    private func shouldDisplay(_ item: ContinueWatchingItem) -> Bool {
        let showUnaired = (ProfileSettings.current.object(forKey: SettingsKey.showUnairedNextUp) as? Bool) ?? true
        return (!item.isUpNextEntry || ContinueWatchingFeatureFlags.nextUpCardsEnabled)
            && isVisible(item.meta)
            && (showUnaired || !item.isUpNextEntry || item.hasAired || item.isAiringToday)
            && !ContinueWatchingDismissStore.isDismissed(item)
    }

    private func isVisible(_ meta: NuvioMeta) -> Bool {
        let hideUnreleased = (ProfileSettings.current.object(forKey: SettingsKey.hideUnreleased) as? Bool) ?? false
        return !hideUnreleased || !ContentReleasePolicy.isUnreleased(meta)
    }
}

/// Phone metrics for the three Home layouts the TV offers (Settings → Layout).
private struct PhoneHomeStyle {
    let posterWidth: CGFloat
    let cardSpacing: CGFloat
    let sectionSpacing: CGFloat
    /// Share of the screen height the hero takes.
    let heroHeightFraction: CGFloat
    let isGrid: Bool

    init(layout: String) {
        switch layout {
        case "Compact":
            self.init(posterWidth: 100, cardSpacing: 8, sectionSpacing: 18, heroHeightFraction: 0.56, isGrid: false)
        case "Grid View":
            self.init(posterWidth: 0, cardSpacing: 10, sectionSpacing: 30, heroHeightFraction: 0.62, isGrid: true)
        default: // Modern (and the retired Classic)
            self.init(posterWidth: 128, cardSpacing: 12, sectionSpacing: 28, heroHeightFraction: 0.72, isGrid: false)
        }
    }

    private init(posterWidth: CGFloat, cardSpacing: CGFloat, sectionSpacing: CGFloat, heroHeightFraction: CGFloat, isGrid: Bool) {
        self.posterWidth = posterWidth
        self.cardSpacing = cardSpacing
        self.sectionSpacing = sectionSpacing
        self.heroHeightFraction = heroHeightFraction
        self.isGrid = isGrid
    }
}

/// One page of the hero carousel: either a title from the hero catalogs or,
/// with Featured Carousel on, something to pick up from Continue Watching.
private enum PhoneHeroSlide: Identifiable {
    case title(NuvioMeta)
    case resume(ContinueWatchingItem)

    var id: String {
        switch self {
        case .title(let meta): return "t:\(meta.type):\(meta.id)"
        case .resume(let item): return "r:\(item.meta.id)"
        }
    }

    var meta: NuvioMeta {
        switch self {
        case .title(let meta): return meta
        case .resume(let item): return item.meta
        }
    }

    /// Wide art (backdrop, or an episode still for resume entries). Many
    /// Continue Watching entries carry only a poster, so an IMDb title
    /// falls back to Cinemeta's backdrop for it.
    private var wideURL: String? {
        switch self {
        case .title(let meta):
            return meta.backgroundUrl ?? Self.cinemetaBackdrop(for: meta)
        case .resume(let item):
            return item.meta.backgroundUrl ?? Self.cinemetaBackdrop(for: item.meta) ?? item.episodeThumbnailOverride
        }
    }

    private static func cinemetaBackdrop(for meta: NuvioMeta) -> String? {
        guard let imdb = meta.imdbId ?? NuvioMeta.canonicalImdbID(from: meta.id), imdb.hasPrefix("tt") else { return nil }
        return "https://images.metahub.space/background/large/\(imdb)/img"
    }

    /// The hero's art for the phone's orientation: the 2:3 poster suits a
    /// portrait hero, the wide backdrop a landscape one. Each falls back to
    /// the other when the title lacks it.
    func artURL(portrait: Bool) -> String? {
        portrait ? (meta.posterUrl ?? wideURL) : (wideURL ?? meta.posterUrl)
    }

    /// The other of the two, shown blurred behind in case the main art fails.
    func fallbackArtURL(portrait: Bool) -> String? {
        portrait ? wideURL : meta.posterUrl
    }
}

struct PhoneHomeView: View {
    @ObservedObject var loader: PhoneHomeLoader
    let onOpenDetails: (NuvioMeta) -> Void
    let onResume: (ContinueWatchingItem) -> Void
    let onStartOver: (ContinueWatchingItem) -> Void
    let onRemoveContinueWatching: (ContinueWatchingItem) -> Void

    // The same Layout settings the TV Home reads, from the profile's suite.
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = SettingsDefault.homeLayout
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.heroAutoScroll) private var heroAutoScroll = false
    @AppStorage(SettingsKey.homeFeature) private var homeFeature = true
    @AppStorage(SettingsKey.heroCatalogs) private var heroCatalogsData = Data()
    @AppStorage(SettingsKey.fullscreenHeroBackdrop) private var fullscreenHeroBackdrop = true
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.catalogAddonNames) private var catalogAddonNames = true

    /// Compact height means landscape on a phone.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Page in the padded carousel: a copy of the last slide sits at page 0
    /// and a copy of the first at `count + 1`, so swiping past either end
    /// carries on round instead of rewinding. Landing on a copy hops,
    /// unanimated, to the real page it shows.
    @State private var heroPage = 1
    /// The carousel's exact swipe position, for the art's parallax. Kept in
    /// an observable object only the art reads, so a frame of swiping
    /// redraws the art and not the whole page.
    @State private var heroParallax = PhoneHeroParallax()

    /// The real slide index behind `heroPage`.
    private var heroIndex: Int {
        let count = heroSlides.count
        guard count > 1 else { return 0 }
        return ((heroPage - 1) % count + count) % count
    }
    /// Side safe-area inset (the Dynamic Island in landscape), zero upright.
    @State private var sideInset = PhoneSideInsets()
    @State private var pageHeight: CGFloat = 0
    @State private var pageWidth: CGFloat = 402
    @State private var browsingSection: TVHomeSection?
    @State private var browsingFolder: PhoneFolderRoute?

    private var style: PhoneHomeStyle { PhoneHomeStyle(layout: homeLayout) }

    /// Continue Watching takes the hero whenever there is something in it.
    /// Unlike the TV this includes Grid View: on a phone the carousel is the
    /// one place resume is a single tap, whatever the layout below it.
    private var featureHeroActive: Bool {
        homeFeature && !loader.continueWatching.isEmpty
    }

    /// Mirrors the TV's `gridHeroItems`: one title from each selected hero
    /// catalog first for variety, then the rest in catalog order, seven in all.
    /// No selection, or a selection whose catalogs are gone, means every row.
    private var heroCatalogTitles: [NuvioMeta] {
        let selected = Set((try? JSONDecoder().decode([String].self, from: heroCatalogsData)) ?? [])
        let chosen = loader.sections.filter { selected.contains($0.id) }
        let sources = selected.isEmpty || chosen.isEmpty ? loader.sections : chosen
        var seen = Set<String>()
        var result: [NuvioMeta] = []
        func add(_ meta: NuvioMeta) {
            guard result.count < TVHomeGridLayout.heroPageLimit,
                  seen.insert("\(meta.type)\u{1f}\(meta.id)").inserted else { return }
            result.append(meta)
        }
        sources.compactMap(\.items.first).forEach(add)
        sources.flatMap(\.items).forEach(add)
        return result
    }

    private var heroSlides: [PhoneHeroSlide] {
        guard heroEnabled else { return [] }
        if featureHeroActive {
            return loader.continueWatching.prefix(20).map(PhoneHeroSlide.resume)
        }
        return heroCatalogTitles.map(PhoneHeroSlide.title)
    }

    private var currentSlide: PhoneHeroSlide? {
        let slides = heroSlides
        guard !slides.isEmpty else { return nil }
        return slides[min(heroIndex, slides.count - 1)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: style.sectionSpacing) {
                let slides = heroSlides
                if !slides.isEmpty {
                    heroCarousel(slides)
                } else {
                    Color.clear.frame(height: 56)
                }

                Group {
                    // The featured carousel already shows these; the TV hides
                    // the row too rather than repeat the titles beneath it.
                    if !featureHeroActive && !loader.continueWatching.isEmpty {
                        continueWatchingRow
                    }

                    // Pinned collections lead, the rest follow the catalogs,
                    // as on the TV.
                    ForEach(loader.collectionRows.filter(\.isPinnedCollection)) { collectionRow($0) }

                    ForEach(loader.sections) { section in
                        if style.isGrid {
                            gridSection(section)
                        } else {
                            catalogRow(section)
                        }
                    }

                    ForEach(loader.collectionRows.filter { !$0.isPinnedCollection }) { collectionRow($0) }

                    if loader.sections.isEmpty && loader.collectionRows.isEmpty {
                        emptyState
                    }
                }
                // Rows keep clear of the Dynamic Island in landscape; their
                // horizontal scrollers still run to the screen edge.
                .safeAreaPadding(sideInset)
            }
            .padding(.bottom, 24)
        }
        // Edge to edge in every orientation: the hero art reaches the sides
        // in landscape too, and the side insets are added back where text is.
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onGeometryChange(for: PhoneSideInsets.self) { proxy in
            PhoneSideInsets(proxy.safeAreaInsets)
        } action: { sideInset = $0 }
        // The whole screen, safe areas included: the iPhone Duo keeps a
        // column down one side out of the safe area, and the art and the
        // poster-or-wide choice go by the screen, not that narrower area.
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(
                width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            )
        } action: {
            pageHeight = $0.height
            pageWidth = $0.width
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // Into the observable only the backdrop reads: a @State here
            // rebuilt all of Home on every scroll frame, and the Duo's larger
            // landscape page dropped frames doing it.
            heroParallax.scroll = offset
        }
        .background(alignment: .topLeading) {
            pageBackdrop
                .ignoresSafeArea()
        }
        .onChange(of: heroSlides.map(\.id), initial: true) { _, _ in
            PhoneImageLoader.prefetch(heroSlides.map { $0.artURL(portrait: !isLandscape) }, kind: .backdrop)
        }
        .refreshable { loader.reload() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $browsingSection) { section in
            PhoneSectionGridView(sectionID: section.id, loader: loader, onOpenDetails: onOpenDetails)
        }
        .navigationDestination(item: $browsingFolder) { route in
            PhoneCollectionFolderView(folder: route.folder, onOpenDetails: onOpenDetails)
        }
        .onChange(of: heroSlides.map(\.id)) { old, ids in
            // The list changes as Home loads (Continue Watching, catalogs).
            // Stay on the title being shown if it's still there; the
            // carousel is rebuilt for the new list (see heroCarousel).
            let oldIndex = old.isEmpty ? 0 : ((heroPage - 1) % old.count + old.count) % old.count
            let newIndex = old.indices.contains(oldIndex) ? ids.firstIndex(of: old[oldIndex]) ?? 0 : 0
            heroPage = ids.count > 1 ? newIndex + 1 : 0
        }
        .onChange(of: heroPage, initial: true) { _, page in
            heroParallax.page = page
            let count = heroSlides.count
            guard count > 1, page == 0 || page == count + 1 else { return }
            // Let the slide onto the copy finish, then swap in the real page.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                // Swiped on again before the hop: that swipe wins.
                guard heroPage == page else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    heroPage = page == 0 ? count : 1
                }
            }
        }
        // Auto-advance, restarted whenever the page changes by hand too. Only
        // with Auto-Scroll Carousel on.
        .task(id: "\(heroIndex)|\(heroSlides.count)|\(heroAutoScroll)") {
            guard heroAutoScroll, heroSlides.count > 1 else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                heroPage = heroIndex + 2
            }
        }
    }

    /// The wide hero layout and art: in landscape, and also whenever the
    /// screen is too wide for the 2:3 poster to fit its height (the iPhone
    /// Duo's near-square screen).
    private var isLandscape: Bool {
        guard pageWidth > 0, pageHeight > 0 else { return verticalSizeClass == .compact }
        return pageWidth * 1.5 > pageHeight
    }

    /// Scroll distance over which the hero art fades out.
    private var heroFadeDistance: CGFloat { max(pageHeight * 0.8, 1) }

    /// In both orientations the hero's art is the whole background — edge to
    /// edge and top to bottom, fixed behind the rows — and fades out as the
    /// page scrolls up. The carousel pages above it draw only their text and
    /// buttons. Portrait uses the poster, landscape the wide backdrop.
    @ViewBuilder
    private var pageBackdrop: some View {
        if !style.isGrid || isLandscape, let url = currentSlide?.artURL(portrait: !isLandscape) {
            ZStack {
                blurredBackdrop(url: url)
                if isLandscape {
                    PhoneHeroParallaxArt(
                        parallax: heroParallax,
                        urls: heroPages(heroSlides).map { $0.slide.artURL(portrait: false) },
                        fallbackURL: url,
                        portraitWidth: nil,
                        size: CGSize(width: pageWidth, height: pageHeight)
                    )
                    // Drifts up behind the rows as the page scrolls.
                    .modifier(PhoneHeroScrollEffect(parallax: heroParallax, fadeDistance: heroFadeDistance))
                } else {
                    // The poster at the screen's width, pinned to the top, as
                    // the hero drew it — filling the full height instead crops
                    // a 2:3 poster's sides, title included. It dissolves into
                    // the frosted backdrop below.
                    PhoneHeroParallaxArt(
                        parallax: heroParallax,
                        urls: heroPages(heroSlides).map { $0.slide.artURL(portrait: true) },
                        fallbackURL: url,
                        portraitWidth: pageWidth,
                        size: CGSize(width: pageWidth, height: pageHeight)
                    )
                    .modifier(PhoneHeroScrollEffect(parallax: heroParallax, fadeDistance: heroFadeDistance))
                }
                if isLandscape {
                    // Legibility for the hero's text on the left, and a floor
                    // for the rows along the bottom.
                    LinearGradient(
                        colors: [.black.opacity(0.75), .black.opacity(0.25), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.45),
                            .init(color: .black.opacity(0.9), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    // The status bar at the top; then darkening towards the
                    // hero's text, which sits around 70% down, and the rows.
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.4), location: 0),
                            .init(color: .clear, location: 0.18),
                            .init(color: .clear, location: 0.38),
                            .init(color: .black.opacity(0.75), location: 0.68),
                            .init(color: .black.opacity(0.92), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            // Exactly the screen, from its top-left corner: centred in the
            // background instead, the fixed-size art sat 21pt off the left
            // edge on the iPhone Duo and left a dark strip down the right.
            .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
        } else {
            portraitBackdrop
        }
    }

    /// Under the landscape art: the frosted backdrop when that setting is on,
    /// so rows scrolled past the hero keep its colour; plain black when off.
    @ViewBuilder
    private func blurredBackdrop(url: String) -> some View {
        ZStack {
            Color.black
            if fullscreenHeroBackdrop {
                // Sized by the screen, not the image: a fill image left to its
                // own size widened the whole background past the screen edge.
                Color.clear
                    .overlay { PhoneArtwork(url: url, kind: .backdrop) }
                    .clipped()
                    .blur(radius: 40)
                    .opacity(0.55)
            }
        }
    }

    /// Fullscreen Hero Backdrop: the current hero's art fills the whole page,
    /// dimmed and frosted behind the rows, as on the TV. Off, or in Grid View
    /// (which has no backdrop on the TV either), the page is plain black.
    @ViewBuilder
    private var portraitBackdrop: some View {
        if fullscreenHeroBackdrop, !style.isGrid, let url = currentSlide?.artURL(portrait: true) {
            ZStack {
                Color.black
                PhoneArtwork(url: url, kind: .backdrop)
                    .blur(radius: 40)
                    .opacity(0.55)
                    .animation(.easeInOut(duration: 0.6), value: url)
                LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    // MARK: Hero

    /// With more than one slide: last copy, the slides, first copy.
    private func heroPages(_ slides: [PhoneHeroSlide]) -> [(id: String, slide: PhoneHeroSlide)] {
        slides.count > 1
            ? [("wrap-head", slides[slides.count - 1])]
                + slides.map { ($0.id, $0) }
                + [("wrap-tail", slides[0])]
            : slides.map { ($0.id, $0) }
    }

    private func heroCarousel(_ slides: [PhoneHeroSlide]) -> some View {
        let pages = heroPages(slides)
        let parallax = heroParallax
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { page, entry in
                PhoneHeroSlideView(
                    slide: entry.slide,
                    sideInset: sideInset,
                    // The page backdrop draws the art, fixed, in both orientations.
                    drawsArt: false,
                    isPortrait: !isLandscape,
                    onOpenDetails: { onOpenDetails(entry.slide.meta) },
                    onResume: onResume
                )
                // Long-press a Continue Watching slide for its options, as on
                // the Continue Watching row.
                .contextMenu {
                    if case .resume(let item) = entry.slide {
                        continueWatchingMenu(item)
                    }
                }
                // The measured screen width, not containerRelativeFrame: on
                // the iPhone Duo that flipped between the full width and the
                // width less its 84pt side column, so the pages shifted under
                // the carousel — it flickered by 84pt, settled on the wrong
                // page, and the art behind followed the wrong title.
                .frame(width: pageWidth)
                .id(page)
            }
            }
            .scrollTargetLayout()
        }
        // A paging scroll view rather than a page TabView: it reports where
        // the swipe is between pages, which the art's parallax follows.
        .scrollTargetBehavior(.paging)
        // A new slide list builds a new carousel: an existing one kept
        // showing the slide it had while its page number now named another,
        // so the art behind belonged to a different title.
        .id(slides.map(\.id))
        .scrollIndicators(.hidden)
        .scrollPosition(id: Binding(get: { Optional(heroPage) }, set: { if let page = $0 { heroPage = page } }))
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.width > 0 ? geometry.contentOffset.x / geometry.containerSize.width : 0
        } action: { _, position in
            // Only while the carousel is actually moving. At rest its offset
            // isn't trustworthy: on the iPhone Duo it flicked by the width of
            // the side safe area (84pt) as Home scrolled under the camera
            // column, and a re-created carousel reports page 0 first. Either
            // slid the art sideways mid-scroll, which looked like a zoom.
            guard parallax.isPaging else { return }
            parallax.position = position
        }
        .onScrollPhaseChange { _, phase in
            parallax.isPaging = phase != .idle
        }
        // These dots count real slides, not the two wrap-around copies.
        .overlay(alignment: .bottom) {
            if slides.count > 1 {
                HStack(spacing: 8) {
                    ForEach(0..<slides.count, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == heroIndex ? 1 : 0.4))
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.bottom, 10)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: heroIndex)
            }
        }
        // Landscape: nearly the whole screen, so the title sits low over the
        // art and only a sliver of the first row shows beneath it.
        .containerRelativeFrame(.vertical) { height, _ in
            height * (isLandscape ? 0.85 : style.heroHeightFraction)
        }
    }

    // MARK: Rows

    private var continueWatchingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhoneSectionHeader(title: L10n.string("continue_watching", fallback: "Continue Watching"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: style.cardSpacing) {
                    ForEach(loader.continueWatching, id: \.meta.id) { item in
                        Button {
                            // Unaired Up Next has nothing to play yet: open it.
                            if item.isUpNextEntry && !item.hasAired && !item.isAiringToday {
                                onOpenDetails(item.meta)
                            } else {
                                onResume(item)
                            }
                        } label: { PhoneContinueCard(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu { continueWatchingMenu(item) }
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)
            }
        }
    }

    @ViewBuilder
    private func continueWatchingMenu(_ item: ContinueWatchingItem) -> some View {
        Button { onResume(item) } label: { Label("Resume", systemImage: "play.fill") }
        Button { onStartOver(item) } label: { Label("Start Over", systemImage: "gobackward") }
        Button { onOpenDetails(item.meta) } label: { Label("Details", systemImage: "info.circle") }
        Button(role: .destructive) { onRemoveContinueWatching(item) } label: {
            Label("Remove", systemImage: "xmark")
        }
    }

    private func sectionHeader(_ section: TVHomeSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(style.posterWidth < 110 && !style.isGrid ? .headline : .title3.weight(.bold))
                .lineLimit(1)
            if catalogAddonNames, let addon = section.addonName, !addon.isEmpty {
                Text(addon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PhoneLayout.gutter)
    }

    /// A collection: its folders as cards, each opening the folder's catalogs.
    private func collectionRow(_ section: TVHomeSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: style.cardSpacing) {
                    ForEach(section.collectionFolders) { folder in
                        Button { browsingFolder = PhoneFolderRoute(folder: folder) } label: {
                            PhoneCollectionFolderCard(folder: folder, posterWidth: style.posterWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)
            }
        }
    }

    private func catalogRow(_ section: TVHomeSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: style.cardSpacing) {
                    ForEach(section.items, id: \.id) { meta in
                        Button { onOpenDetails(meta) } label: {
                            PhonePosterCard(meta: meta, width: style.posterWidth, showsLabel: posterLabels)
                        }
                        .buttonStyle(.plain)
                        .onAppear { loader.loadMoreIfNeeded(sectionId: section.id, current: meta) }
                    }
                    if section.isLoadingMore {
                        ProgressView().frame(width: 60, height: style.posterWidth * PhoneLayout.posterAspect)
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)
            }
        }
    }

    /// Grid View: each catalog as a three-column block with a See All tile,
    /// like the TV's 7x3 grid sections.
    private func gridSection(_ section: TVHomeSection) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: style.cardSpacing, alignment: .top), count: 3)
        let preview = Array(section.items.prefix(8))
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section)
            LazyVGrid(columns: columns, spacing: style.cardSpacing) {
                ForEach(preview, id: \.id) { meta in
                    Button { onOpenDetails(meta) } label: {
                        PhoneGridPoster(meta: meta, showsLabel: posterLabels)
                    }
                    .buttonStyle(.plain)
                }
                if section.items.count > preview.count || section.hasMore {
                    Button { browsingSection = section } label: {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .aspectRatio(1 / PhoneLayout.posterAspect, contentMode: .fit)
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "square.grid.3x3.fill").font(.title3)
                                    Text("See All").font(.subheadline.weight(.semibold))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, PhoneLayout.gutter)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if loader.isLoading {
                ProgressView()
            } else if let error = loader.errorMessage {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { loader.reload() }
            } else {
                Image(systemName: "puzzlepiece.extension").font(.largeTitle)
                Text("No catalogs yet. Add-ons installed on your account will appear here.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }
}

extension TVHomeSection: Hashable {
    static func == (lhs: TVHomeSection, rhs: TVHomeSection) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A poster sized by its grid column rather than a fixed width.
private struct PhoneGridPoster: View {
    let meta: NuvioMeta
    let showsLabel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1 / PhoneLayout.posterAspect, contentMode: .fit)
                .overlay { PhoneArtwork(url: meta.posterUrl ?? meta.backgroundUrl) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if showsLabel {
                Text(meta.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Everything in one catalog, paging in more as the end comes into view.
private struct PhoneSectionGridView: View {
    let sectionID: String
    @ObservedObject var loader: PhoneHomeLoader
    let onOpenDetails: (NuvioMeta) -> Void

    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

    var body: some View {
        let section = loader.sections.first { $0.id == sectionID }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(section?.items ?? [], id: \.id) { meta in
                    Button { onOpenDetails(meta) } label: { PhoneGridPoster(meta: meta, showsLabel: posterLabels) }
                        .buttonStyle(.plain)
                        .onAppear { loader.loadMoreIfNeeded(sectionId: sectionID, current: meta) }
                }
            }
            .padding(.horizontal, PhoneLayout.gutter)
            if section?.isLoadingMore == true {
                ProgressView().padding()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(section?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// A full-bleed hero page: backdrop edge to edge and under the status bar,
/// the title's logo, and what to do next.
private struct PhoneHeroSlideView: View {
    let slide: PhoneHeroSlide
    var sideInset = PhoneSideInsets()
    /// False in landscape, where the page draws this art full screen behind.
    var drawsArt: Bool = true
    /// The page's layout (poster) rather than the size class, which stays
    /// regular on large screens.
    var isPortrait = true
    let onOpenDetails: () -> Void
    let onResume: (ContinueWatchingItem) -> Void


    /// A poster usually carries the title in its own artwork, so the logo
    /// on top of it would say the same thing twice.
    private var showsLogo: Bool {
        !(isPortrait && slide.meta.posterUrl != nil)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Each image fills the hero frame on its own: stacked together,
            // the taller poster set the size and pushed the backdrop down.
            // The alternate art, blurred, shows through wherever the main
            // art is missing or fails; synced progress often records none.
            Color.clear
                .overlay {
                    if drawsArt {
                        PhoneArtwork(url: slide.fallbackArtURL(portrait: isPortrait), kind: .backdrop).blur(radius: 30)
                    }
                }
                .overlay {
                    if drawsArt {
                        PhoneArtwork(url: slide.artURL(portrait: isPortrait), kind: .backdrop)
                    }
                }
                .overlay {
                    if drawsArt {
                        // Darkens behind the text, then eases off again so
                        // nothing here ends in a band of its own.
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.45), location: 0),
                                .init(color: .clear, location: 0.22),
                                .init(color: .clear, location: 0.4),
                                .init(color: .black.opacity(0.6), location: 0.78),
                                .init(color: .black.opacity(0.35), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .clipped()
                // The art fades to fully transparent over its last third,
                // dissolving into the page backdrop beneath instead of
                // ending at a hard edge above the first row.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.66),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenDetails)

            VStack(alignment: .leading, spacing: 10) {
                if showsLogo {
                    PhoneTitleLogo(meta: slide.meta)
                }
                details
                actions
            }
            .padding(sideInset, plus: PhoneLayout.gutter)
            .padding(.bottom, drawsArt ? 40 : 34)
            .shadow(color: .black.opacity(0.45), radius: 8)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var details: some View {
        switch slide {
        case .resume(let item):
            VStack(alignment: .leading, spacing: 6) {
                if let line = item.episodeDisplayLine {
                    Text(line).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text(item.isUpNextEntry ? item.upNextBadgeText : item.remainingText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if item.progress > 0 {
                    ProgressView(value: min(max(item.progress, 0), 1))
                        .tint(.white)
                        .frame(maxWidth: 220)
                }
            }
        case .title(let meta):
            VStack(alignment: .leading, spacing: 6) {
                Text([meta.year.map(String.init), meta.genres?.prefix(2).joined(separator: " · ")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                if let description = meta.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                if case .resume(let item) = slide, !isUnaired { onResume(item) } else { onOpenDetails() }
            } label: {
                Label(playTitle, systemImage: playIcon)
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            Button(action: onOpenDetails) {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Details")
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    /// An Up Next episode that has not aired yet: nothing to play, so the
    /// button opens the title instead.
    private var isUnaired: Bool {
        guard case .resume(let item) = slide else { return false }
        return item.isUpNextEntry && !item.hasAired && !item.isAiringToday
    }

    private var playTitle: String {
        if isUnaired { return "Details" }
        if case .resume = slide { return "Resume" }
        return "Play"
    }

    private var playIcon: String {
        isUnaired ? "info.circle" : "play.fill"
    }
}
/// The hero carousel's swipe position, in pages (1.5 is halfway from page
/// one to two).
@Observable
final class PhoneHeroParallax {
    var position: CGFloat = 1
    /// The carousel is being swiped or is animating between slides.
    var isPaging = false
    /// The carousel's current page (wrap-around copies included).
    var page = 1
    /// How far Home has scrolled.
    var scroll: CGFloat = 0
}

/// The hero art's drift and fade as Home scrolls. Reads the scroll here,
/// so a scroll frame redraws the art and nothing else.
private struct PhoneHeroScrollEffect: ViewModifier {
    let parallax: PhoneHeroParallax
    let fadeDistance: CGFloat

    func body(content: Content) -> some View {
        let offset = parallax.scroll
        content
            .modifier(PhoneParallaxScroll(offset: offset))
            // Unanimated, like the drift (see PhoneParallaxScroll).
            .transaction { $0.animation = nil } body: { content in
                content.opacity(Double(min(max(1 - offset / fadeDistance, 0), 1)))
            }
    }
}

/// The hero art behind the carousel, sliding with it at half speed: each
/// slide's art sits in a window that moves with its page, while the picture
/// inside moves only half as far — the parallax. Only the two slides on
/// either side of the swipe are drawn.
private struct PhoneHeroParallaxArt: View {
    let parallax: PhoneHeroParallax
    let urls: [String?]
    let fallbackURL: String
    /// Portrait: the poster at this width, pinned to the top and faded out
    /// at the bottom. Landscape (nil): the wide art over the whole screen.
    let portraitWidth: CGFloat?
    /// The whole screen, measured by the page. Not measured here: inside
    /// the scroll drift, ignoring the safe area made the art grow by the
    /// drift into the bottom inset (up to 34pt) and snap back past it,
    /// which zoomed the full-height wide art in and out as Home scrolled.
    let size: CGSize

    private static let depth: CGFloat = 0.5

    var body: some View {
        let width = size.width
        // The swipe's own position while the carousel moves; at rest,
        // the current page itself.
        let position = urls.count > 1 ? (parallax.isPaging ? parallax.position : CGFloat(parallax.page)) : 0
        let base = Int(floor(position))
        ZStack(alignment: .topLeading) {
            ForEach([base, base + 1].filter { urls.indices.contains($0) }, id: \.self) { index in
                let distance = CGFloat(index) - position
                if abs(distance) < 1 {
                    art(urls[index] ?? fallbackURL, size: size)
                        // Picture moves at half speed inside its window…
                        .offset(x: -distance * width * Self.depth)
                        .frame(width: width, height: size.height, alignment: .top)
                        .clipped()
                        // …and the window moves with the page.
                        .offset(x: distance * width)
                }
            }
            if urls.isEmpty {
                art(fallbackURL, size: size)
            }
        }
        .frame(width: width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func art(_ url: String, size: CGSize) -> some View {
        if let portraitWidth {
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: portraitWidth, height: portraitWidth * 1.5)
                    .overlay { PhoneArtwork(url: url, kind: .backdrop) }
                    .clipped()
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.7),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        } else {
            Color.clear
                .frame(width: size.width, height: size.height)
                .overlay { PhoneArtwork(url: url, kind: .backdrop) }
                .clipped()
        }
    }
}
// MARK: - Collections

/// A folder opened from a collection row.
struct PhoneFolderRoute: Hashable {
    let folder: TVCollectionFolderItem
}

/// A collection folder's card: its cover art, or its emoji, in the folder's
/// own shape, with the title beneath unless the folder hides it.
struct PhoneCollectionFolderCard: View {
    let folder: TVCollectionFolderItem
    let posterWidth: CGFloat

    private var size: CGSize {
        switch folder.tileShape {
        case .poster: return CGSize(width: posterWidth, height: posterWidth * PhoneLayout.posterAspect)
        case .landscape: return CGSize(width: posterWidth * 1.7, height: posterWidth * 1.7 * 9 / 16)
        case .square: return CGSize(width: posterWidth * 1.1, height: posterWidth * 1.1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
                if let cover = folder.coverImageUrl, !cover.isEmpty {
                    PhoneArtwork(url: cover, kind: folder.tileShape == .poster ? .poster : .backdrop)
                } else if let emoji = folder.coverEmoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: size.height * 0.4))
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: size.height * 0.3))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !folder.hideTitle {
                Text(folder.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: size.width, alignment: .leading)
            }
        }
    }
}

/// A collection folder on the phone: a tab per source (and All, when the
/// collection offers it) over a poster grid. Loads through the same
/// `CollectionSourceResolver` as the TV's folder screen.
struct PhoneCollectionFolderView: View {
    let folder: TVCollectionFolderItem
    let onOpenDetails: (NuvioMeta) -> Void

    private struct SourceRow {
        let label: String
        let items: [NuvioMeta]
    }

    @State private var rows: [SourceRow] = []
    @State private var tab = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    private let repository: CatalogRepository = CinemetaCatalogRepository()
    private static let pageSize = 40

    private var showsAll: Bool { folder.showAllTab && rows.count > 1 }

    private var tabs: [String] {
        (showsAll ? [L10n.string("library_type_all", fallback: "All")] : []) + rows.map(\.label)
    }

    private var shownItems: [NuvioMeta] {
        if showsAll, tab == 0 {
            var seen = Set<String>()
            return rows.flatMap(\.items).filter { seen.insert($0.id).inserted }
        }
        let index = tab - (showsAll ? 1 : 0)
        return rows.indices.contains(index) ? rows[index].items : []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if tabs.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                                Button { tab = index } label: {
                                    Text(title)
                                        .font(.subheadline.weight(tab == index ? .semibold : .regular))
                                        .lineLimit(1)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule().fill(tab == index ? Color.white : Color.white.opacity(0.12))
                                        )
                                        .foregroundStyle(tab == index ? Color.black : Color.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, PhoneLayout.gutter)
                    }
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if shownItems.isEmpty {
                    Text(errorMessage ?? "Nothing in this folder yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    PhonePosterGrid(items: shownItems, onSelect: onOpenDetails)
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(folder.title)
        .navigationBarTitleDisplayMode(.large)
        .task(id: folder.id) { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        let sources = folder.sources
        guard !sources.isEmpty else {
            rows = []
            errorMessage = "This folder has no sources."
            isLoading = false
            return
        }
        let repository = self.repository
        let loaded = await withTaskGroup(of: (Int, SourceRow?, String?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { @MainActor in
                    do {
                        let page = try await CollectionSourceResolver(repository: repository).browse(source)
                        let items = source.normalizedProvider == "addon"
                            ? Array(page.items.prefix(Self.pageSize))
                            : page.items
                        var seen = Set<String>()
                        return (index, SourceRow(
                            label: CollectionSourceResolver.label(for: source),
                            items: items.filter { seen.insert($0.id).inserted }
                        ), nil)
                    } catch {
                        return (index, nil, error.localizedDescription)
                    }
                }
            }
            var results: [(Int, SourceRow?, String?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled else { return }
        rows = loaded.compactMap(\.1)
        if rows.allSatisfy({ $0.items.isEmpty }) {
            errorMessage = loaded.compactMap(\.2).first
        }
        tab = 0
        isLoading = false
    }
}
#endif

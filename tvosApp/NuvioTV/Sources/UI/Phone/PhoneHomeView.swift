#if os(iOS)
import SwiftUI

/// Loads Home for the phone: the same add-on catalogs, row order and Continue
/// Watching sources as tvOS `TVHomeView`, without its focus bookkeeping.
///
/// Deliberately simpler than tvOS for now: no skeleton rows, collections,
/// SMB/Jellyfin rows or partial-load retry. Rows arrive as each add-on answers.
@MainActor
final class PhoneHomeLoader: ObservableObject {
    @Published private(set) var sections: [TVHomeSection] = []
    @Published private(set) var continueWatching: [ContinueWatchingItem] = []
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
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// `key` identifies the profile + catalog revision; a new key reloads.
    func load(key: String, force: Bool = false) {
        guard force || key != loadedKey else { return }
        loadedKey = key
        refreshContinueWatching()
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
            result.append(TVHomeSection(
                id: catalog.id,
                title: catalog.name,
                items: all.filter(isVisible),
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
            guard let latest = sections.firstIndex(where: { $0.id == sectionId }) else { return }
            sections[latest].isLoadingMore = false
            guard let page else { return }
            let existing = Set(sections[latest].items.map(\.id))
            let fresh = page.items.filter { !existing.contains($0.id) && isVisible($0) }
            sections[latest].items.append(contentsOf: fresh)
            sections[latest].nextSkip = page.nextSkip ?? (skip + page.items.count)
            sections[latest].hasMore = page.hasMore && !fresh.isEmpty
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

    /// Wide art (backdrop, or an episode still for resume entries).
    private var wideURL: String? {
        switch self {
        case .title(let meta): return meta.backgroundUrl
        case .resume(let item): return item.meta.backgroundUrl ?? item.episodeThumbnailOverride
        }
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
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
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

    /// The real slide index behind `heroPage`.
    private var heroIndex: Int {
        let count = heroSlides.count
        guard count > 1 else { return 0 }
        return ((heroPage - 1) % count + count) % count
    }
    /// Side safe-area inset (the Dynamic Island in landscape), zero upright.
    @State private var sideInset: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var pageHeight: CGFloat = 0
    @State private var browsingSection: TVHomeSection?

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

                    ForEach(loader.sections) { section in
                        if style.isGrid {
                            gridSection(section)
                        } else {
                            catalogRow(section)
                        }
                    }

                    if loader.sections.isEmpty {
                        emptyState
                    }
                }
                // Rows keep clear of the Dynamic Island in landscape; their
                // horizontal scrollers still run to the screen edge.
                .safeAreaPadding(.horizontal, sideInset)
            }
            .padding(.bottom, 24)
        }
        // Edge to edge in every orientation: the hero art reaches the sides
        // in landscape too, and the side insets are added back where text is.
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing)
        } action: { sideInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in scrollOffset = offset }
        .background { pageBackdrop }
        .onChange(of: heroSlides.map(\.id), initial: true) { _, _ in
            PhoneImageLoader.prefetch(heroSlides.map { $0.artURL(portrait: !isLandscape) }, kind: .backdrop)
        }
        .refreshable { loader.reload() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $browsingSection) { section in
            PhoneSectionGridView(sectionID: section.id, loader: loader, onOpenDetails: onOpenDetails)
        }
        .onChange(of: heroSlides.map(\.id)) { _, ids in
            if heroIndex >= ids.count || ids.count <= 1 { heroPage = ids.count > 1 ? 1 : 0 }
        }
        .onChange(of: heroPage) { _, page in
            let count = heroSlides.count
            guard count > 1, page == 0 || page == count + 1 else { return }
            // Let the slide onto the copy finish, then swap in the real page.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
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

    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// Landscape: 1 with the hero in view, fading to 0 as it scrolls away.
    private var heroFade: Double {
        let distance = max(pageHeight * 0.8, 1)
        return Double(min(max(1 - scrollOffset / distance, 0), 1))
    }

    /// Landscape: the hero's art is the whole background — edge to edge and
    /// top to bottom, behind the rows too — and fades out as the page scrolls
    /// up. The carousel pages above it draw only their text and buttons.
    @ViewBuilder
    private var pageBackdrop: some View {
        if isLandscape, let url = currentSlide?.artURL(portrait: false) {
            ZStack {
                blurredBackdrop(url: url)
                PhoneArtwork(url: url, kind: .backdrop)
                    .opacity(heroFade)
                    .animation(.easeInOut(duration: 0.6), value: url)
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
            }
            .ignoresSafeArea()
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
                PhoneArtwork(url: url, kind: .backdrop)
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

    private func heroCarousel(_ slides: [PhoneHeroSlide]) -> some View {
        // With more than one slide: last copy, the slides, first copy.
        let pages: [(id: String, slide: PhoneHeroSlide)] = slides.count > 1
            ? [("wrap-head", slides[slides.count - 1])]
                + slides.map { ($0.id, $0) }
                + [("wrap-tail", slides[0])]
            : slides.map { ($0.id, $0) }
        return TabView(selection: $heroPage) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { page, entry in
                PhoneHeroSlideView(
                    slide: entry.slide,
                    sideInset: sideInset,
                    drawsArt: !isLandscape,
                    onOpenDetails: { onOpenDetails(entry.slide.meta) },
                    onResume: onResume
                )
                .tag(page)
            }
        }
        // The system dots would count the two copies; these count real slides.
        .tabViewStyle(.page(indexDisplayMode: .never))
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
                        Button { onResume(item) } label: { PhoneContinueCard(item: item) }
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
    var sideInset: CGFloat = 0
    /// False in landscape, where the page draws this art full screen behind.
    var drawsArt: Bool = true
    let onOpenDetails: () -> Void
    let onResume: (ContinueWatchingItem) -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isPortrait: Bool { verticalSizeClass != .compact }

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
            .padding(.horizontal, PhoneLayout.gutter + sideInset)
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
                if case .resume(let item) = slide { onResume(item) } else { onOpenDetails() }
            } label: {
                Label(playTitle, systemImage: "play.fill")
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

    private var playTitle: String {
        if case .resume = slide { return "Resume" }
        return "Play"
    }
}
#endif

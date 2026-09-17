import SwiftUI

/// Full catalog of titles from a production company or network.
#if os(macOS)
/// Band ids for the company and person browse screens. A company page is one
/// band per rail; a person page is a single grid band.
enum BrowseFocusBand {
    static let grid = "browse.grid"

    static func rail(_ id: String) -> String { "browse.rail.\(id)" }
}
#endif

struct ProductionBrowseView: View {
    let company: MetaCompany
    let onSelect: (RelatedTitle) -> Void
    let onBack: () -> Void

    @State private var titles: [RelatedTitle] = []
    @State private var networkBrowse: TmdbNetworkBrowseData?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                .ignoresSafeArea()

            CompanyBrowseContent(
                company: company,
                data: networkBrowse,
                providedRails: company.kind == .network ? (networkBrowse?.rails ?? []) : productionRails,
                fallbackTitles: titles,
                isLoading: isLoading,
                errorMessage: errorMessage,
                onSelect: onSelect,
                onBack: onBack
            )

        }
        .onExitCommand(perform: onBack)
        .task(id: company.id) {
            await load()
        }
    }

    private var productionRails: [TmdbNetworkBrowseRail] {
        let series = titles.filter { $0.type == "series" }
        let movies = titles.filter { $0.type == "movie" }
        var rails: [TmdbNetworkBrowseRail] = []
        if !series.isEmpty {
            rails.append(TmdbNetworkBrowseRail(id: "series", title: L10n.string("details_series_popular", fallback: "Series • Popular"), items: series))
        }
        if !movies.isEmpty {
            rails.append(TmdbNetworkBrowseRail(id: "movies", title: L10n.string("details_movies_popular", fallback: "Movies • Popular"), items: movies))
        }
        if rails.isEmpty && !titles.isEmpty {
            rails.append(TmdbNetworkBrowseRail(id: "titles", title: L10n.string("details_titles_popular", fallback: "Titles • Popular"), items: titles))
        }
        return rails
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        networkBrowse = nil
        let results: [RelatedTitle]
        if company.kind == .network {
            let browse = await TmdbDetailsService.fetchNetworkBrowse(company: company)
            networkBrowse = browse
            if let browse, !browse.rails.isEmpty {
                results = browse.rails.flatMap(\.items)
            } else {
                results = await TmdbDetailsService.discoverTitles(company: company)
            }
        } else {
            results = await TmdbDetailsService.discoverTitles(company: company)
        }
        titles = results
        isLoading = false
    }
}

/// Company catalog presentation matching the Android TV layout: a cinematic
/// identity hero followed by horizontally scrolling title rails.
private struct CompanyBrowseContent: View {
    let company: MetaCompany
    let data: TmdbNetworkBrowseData?
    let providedRails: [TmdbNetworkBrowseRail]
    let fallbackTitles: [RelatedTitle]
    let isLoading: Bool
    let errorMessage: String?
    let onSelect: (RelatedTitle) -> Void
    /// Escape is routed to this screen rather than reaching `onExitCommand`,
    /// which needs SwiftUI focus the caret-driven page never holds.
    let onBack: () -> Void

    @FocusState private var placeholderFocused: Bool
    @State private var scrollOffset: CGFloat = 0
    #if os(macOS)
    /// macOS has no focus engine, so this page carries its own caret — without
    /// one nothing on it was reachable from the keyboard.
    @StateObject private var macFocus = MacScreenFocus("companyBrowse")
    @ObservedObject private var macKeyRouter = MacKeyRouter.shared
    @State private var macScrollProxy: ScrollViewProxy?
    #endif
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    private var displayName: String { data?.name ?? company.name }
    private var logoURL: String? { data?.logoURL ?? company.logoURL }
    private var usesWhiteLogo: Bool {
        company.kind == .network && displayName.localizedCaseInsensitiveContains("apple")
    }

    private var rails: [TmdbNetworkBrowseRail] {
        if !providedRails.isEmpty { return providedRails }
        guard !fallbackTitles.isEmpty else { return [] }
        return [TmdbNetworkBrowseRail(
            id: "popular",
            title: company.kind == .network
                ? L10n.string("details_series_popular", fallback: "Series • Popular")
                : L10n.string("details_titles_popular", fallback: "Titles • Popular"),
            items: fallbackTitles
        )]
    }

    private var backdropURL: URL? {
        guard let item = rails.first?.items.first,
              let string = item.backdropURL ?? item.posterURL else { return nil }
        return URL(string: string)
    }

    private var scrollShadowProgress: CGFloat {
        min(max(scrollOffset / 120, 0), 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            Color.black
                .opacity(0.78 * scrollShadowProgress)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollViewReader { macScroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: CompanyBrowseScrollOffsetKey.self,
                                value: geometry.frame(in: .named("company-browse-scroll")).minY
                            )
                    }
                    .frame(height: 0)

                    hero

                    if isLoading {
                        BrandLoadingView(wordmarkWidth: 360)
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if rails.isEmpty {
                        Text(L10n.format("details_no_titles_found_for", fallback: "No titles found for %@", displayName))
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(rails) { rail in
                            // The anchor is a marker above the rail rather
                            // than the rail itself: a rail wraps its own
                            // horizontal ScrollView, and `scrollTo` aimed at
                            // that container was accepted and then ignored —
                            // the proxy was live and the call was made, the
                            // viewport just never moved. The person grid,
                            // whose ids sit on plain cards, always worked.
                            Color.clear
                                .frame(height: 0)
                                .id("browse.rail.\(rail.id)")
                            NetworkBrowseRail(
                                rail: rail,
                                macFocusedID: macCaretItemID,
                                onSelect: onSelect
                            )
                        }
                    }
                }
                .padding(.bottom, 70)
            }
            .focusSection()
            .coordinateSpace(name: "company-browse-scroll")
            .modifier(CompanyBrowseScrollTracker(offset: $scrollOffset))
            #if os(macOS)
            .onAppear { macScrollProxy = macScroll }
            #endif
            }

            CompanyBrowseScrollTransitionShadow(progress: scrollShadowProgress)

            if isLoading || rails.isEmpty {
                placeholderFocusAnchor
            }
        }
        .ignoresSafeArea(edges: .top)
        #if os(macOS)
        .onAppear {
            macFocus.update(macBands)
            macFocus.syncClaim(isCurrent: true)
        }
        .onDisappear { macFocus.release() }
        .onChange(of: macBandSignature, initial: true) { _, _ in
            macFocus.update(macBands)
        }
        .onChange(of: macKeyRouter.latest) { _, press in
            guard let press else { return }
            // `onExitCommand` needs SwiftUI focus, which a screen driving its
            // own caret never has, so Escape arrives here instead.
            guard press.key != .back else { onBack(); return }
            let previousBand = macFocus.bandID
            macFocus.handle(press.key, activate: macActivate)
            macScrollCaretIntoView(previousBand: previousBand)
        }
        #endif
    }

    /// The caret's card key, as a plain value so the cards redraw as it passes.
    /// Nil on tvOS, where the focus engine owns the highlight.
    private var macCaretItemID: String? {
        #if os(macOS)
        return macFocus.itemID
        #else
        return nil
        #endif
    }

    #if os(macOS)
    /// One band per rail, each as wide as its own row.
    private var macBands: [MacFocusBand] {
        rails.compactMap { rail in
            guard !rail.items.isEmpty else { return nil }
            return MacFocusBand(
                id: BrowseFocusBand.rail(rail.id),
                items: rail.items.map { "\(rail.id)\u{1}\($0.id)" }
            )
        }
    }

    private var macBandSignature: String {
        rails.map { "\($0.id):\($0.items.count)" }.joined(separator: ",")
    }

    private func macActivate(band: String, item: String) {
        guard let separator = item.firstIndex(of: "\u{1}") else { return }
        let railId = String(item[item.startIndex..<separator])
        let titleId = String(item[item.index(after: separator)...])
        guard let rail = rails.first(where: { $0.id == railId }),
              let match = rail.items.first(where: { $0.id == titleId })
        else { return }
        onSelect(match)
    }

    /// Brings the caret's rail into view. Within a rail the strip scrolls
    /// itself, so only a change of rail moves the page.
    private func macScrollCaretIntoView(previousBand: String?) {
        guard let band = macFocus.bandID, band != previousBand,
              band.hasPrefix("browse.rail."),
              let proxy = macScrollProxy else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(band, anchor: .top)
        }
    }
    #endif

    private var backdrop: some View {
        let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        return ZStack {
            if let backdropURL {
                AsyncImage(url: backdropURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
                // Match TvDetailsBackdrop: the artwork fills the entire
                // screen layer, so its crop starts at the same vertical point
                // instead of being constrained to the hero's shorter frame.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                backdropColor
            }

            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: backdropColor.opacity(0.95), location: 0),
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
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                Text(company.kind == .network ? "Network" : "Production")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))

                Text(displayName)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                let location = [data?.headquarters, data?.originCountry]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                if !location.isEmpty {
                    Text(location)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 20)

            if let logoURL, let url = URL(string: logoURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        if usesWhiteLogo {
                            image
                                .renderingMode(.template)
                                .resizable()
                                .foregroundColor(.white)
                                .scaledToFit()
                        } else {
                            image
                                .resizable()
                                .scaledToFit()
                        }
                    } else {
                        Text(displayName)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 520, height: 190)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .bottom)
    }

    private var placeholderFocusAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable(true)
            .focused($placeholderFocused)
            .focusEffectDisabledIfAvailable()
            .onAppear {
                DispatchQueue.main.async { placeholderFocused = true }
            }
    }
}

private struct CompanyBrowseScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CompanyBrowseScrollTracker: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(tvOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newOffset in
                offset = max(0, newOffset)
            }
        } else {
            content.onPreferenceChange(CompanyBrowseScrollOffsetKey.self) { minY in
                offset = max(0, -minY)
            }
        }
    }
}

private struct CompanyBrowseScrollTransitionShadow: View {
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    .black.opacity(0.34 * progress),
                    .black.opacity(0.12 * progress),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 72)

            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct NetworkBrowseRail: View {
    let rail: TmdbNetworkBrowseRail
    /// The page's caret, as a plain value: a `.focused` binding is not a render
    /// dependency, so the cards would never redraw as it moved.
    var macFocusedID: String? = nil
    let onSelect: (RelatedTitle) -> Void

    /// Unique per card: the same title can appear in more than one rail.
    private func cardKey(_ title: RelatedTitle) -> String {
        "\(rail.id)\u{1}\(title.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(rail.title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 80)

            ScrollViewReader { strip in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: TmdbBrowseGridMetrics.posterGap) {
                        ForEach(rail.items) { title in
                            ProductionBrowseCard(
                                title: title,
                                macIsFocused: macFocusedID == cardKey(title)
                            ) {
                                onSelect(title)
                            }
                            .id(cardKey(title))
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 12)
                }
                .scrollClipDisabledIfAvailable()
                #if os(macOS)
                // The caret walks the strip as a plain value, so the strip has
                // to be told to follow it. tvOS gets this from the focus
                // engine; here the highlight simply moved off-screen and the
                // rest of the row stayed unreachable.
                .onChange(of: macFocusedID) { _, id in
                    guard let id, id.hasPrefix("\(rail.id)\u{1}") else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        strip.scrollTo(id, anchor: .center)
                    }
                }
                #endif
            }
        }
    }
}

/// Movies and series associated with a TMDB actor, director, or creator.
struct PersonBrowseView: View {
    let person: TmdbPersonMetadata
    let onSelect: (RelatedTitle) -> Void
    let onBack: () -> Void

    @State private var titles: [RelatedTitle] = []
    @State private var isLoading = true
    @FocusState private var focusedId: String?
    @FocusState private var placeholderFocused: Bool
    #if os(macOS)
    /// macOS has no focus engine, so the grid keeps its own caret.
    @StateObject private var macFocus = MacScreenFocus("personBrowse")
    @ObservedObject private var macKeyRouter = MacKeyRouter.shared
    @State private var macScrollProxy: ScrollViewProxy?
    #endif
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    private var columns: [GridItem] { TmdbBrowseGridMetrics.columns }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 28) {
                    if let profileURL = person.profileURL,
                       let url = URL(string: profileURL) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 96, height: 96)
                                    .clipShape(Circle())
                            } else {
                                personFallback
                            }
                        }
                    } else {
                        personFallback
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(person.name)
                            .font(.system(size: 42, weight: .bold))
                            .foregroundColor(.white)
                        if let role = person.role {
                            Text(role)
                                .font(.system(size: 26, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        if !isLoading {
                            Text(L10n.format("details_titles_count", fallback: "%d titles", titles.count))
                                .font(.system(size: 24, weight: .regular))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 60)

                if isLoading {
                    Spacer()
                    BrandLoadingView(wordmarkWidth: 360)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if titles.isEmpty {
                    Spacer()
                    Text(L10n.format("details_no_titles_found_for_person", fallback: "No movies or series found for %@", person.name))
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollViewReader { macScroll in
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: TmdbBrowseGridMetrics.posterGap) {
                            ForEach(titles) { title in
                                ProductionBrowseCard(
                                    title: title,
                                    macIsFocused: macCaretIsOn(title.id)
                                ) {
                                    onSelect(title)
                                }
                                .nuvioFocusable()
                                .focused($focusedId, equals: title.id)
                                .id(title.id)
                            }
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 60)
                        .padding(.bottom, 60)
                    }
                    .focusSection()
                    .defaultFocusIfAvailable($focusedId, titles.first?.id)
                    #if os(macOS)
                    .onAppear { macScrollProxy = macScroll }
                    #endif
                    }
                }
            }
            .padding(.top, 48)

            if titles.isEmpty {
                placeholderFocusAnchor
            }
        }
        .onExitCommand(perform: onBack)
        .task(id: person.id) {
            isLoading = true
            titles = await TmdbDetailsService.discoverTitles(person: person)
            isLoading = false
            focusedId = titles.first?.id
        }
        #if os(macOS)
        .onAppear {
            macFocus.update(macBands)
            macFocus.syncClaim(isCurrent: true)
        }
        .onDisappear { macFocus.release() }
        .onChange(of: titles.map(\.id), initial: true) { _, _ in
            macFocus.update(macBands)
        }
        .onChange(of: macKeyRouter.latest) { _, press in
            guard let press else { return }
            guard press.key != .back else { onBack(); return }
            let previous = macFocus.itemID
            macFocus.handle(press.key, activate: macActivate)
            guard let id = macFocus.itemID, id != previous else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                macScrollProxy?.scrollTo(id, anchor: .center)
            }
        }
        #endif
    }

    private func macCaretIsOn(_ id: String) -> Bool {
        #if os(macOS)
        return macFocus.isFocused(BrowseFocusBand.grid, id)
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// One grid band, which knows its own column count so Up and Down move a
    /// whole row rather than one card.
    private var macBands: [MacFocusBand] {
        guard !titles.isEmpty else { return [] }
        return [MacFocusBand(
            id: BrowseFocusBand.grid,
            items: titles.map(\.id),
            columns: macGridColumns
        )]
    }

    /// The grid is `.adaptive`, so `columns` is one entry however many cards a
    /// row actually holds — the count has to come from the canvas width.
    private var macGridColumns: Int {
        // `MacTVCanvas` is generic over its content, so the static needs a
        // concrete parameter to name the canvas the app actually renders on.
        let available = MacTVCanvas<EmptyView>.canvasSize.width - 120
        let step = TmdbBrowseGridMetrics.posterWidth + TmdbBrowseGridMetrics.posterGap
        return max(Int((available + TmdbBrowseGridMetrics.posterGap) / step), 1)
    }

    private func macActivate(band: String, item: String) {
        guard let match = titles.first(where: { $0.id == item }) else { return }
        onSelect(match)
    }
    #endif

    private var personFallback: some View {
        Text(person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
            .font(.system(size: 30, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 96, height: 96)
            .background(Color.white.opacity(0.16))
            .clipShape(Circle())
    }

    private var placeholderFocusAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable(true)
            .focused($placeholderFocused)
            .focusEffectDisabledIfAvailable()
            .onAppear {
                DispatchQueue.main.async { placeholderFocused = true }
            }
    }
}

private enum TmdbBrowseGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28

    static var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: posterWidth, maximum: posterWidth),
            spacing: posterGap,
            alignment: .top
        )]
    }
}

private struct ProductionBrowseCard: View {
    let title: RelatedTitle
    let alwaysShowLabels: Bool
    /// Driven by `MacScreenFocus`; macOS has no focus engine to set `focused`.
    let macIsFocused: Bool
    let onSelect: () -> Void

    @FocusState private var focused: Bool

    /// tvOS reads the focus engine; macOS has none, so the caret decides.
    private var isFocused: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return focused
        #endif
    }
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

    init(
        title: RelatedTitle,
        alwaysShowLabels: Bool = false,
        macIsFocused: Bool = false,
        onSelect: @escaping () -> Void
    ) {
        self.title = title
        self.alwaysShowLabels = alwaysShowLabels
        self.macIsFocused = macIsFocused
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    shape
                        .fill(Color.white.opacity(0.08))
                    if let poster = title.posterURL, let url = URL(string: poster) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(width: TmdbBrowseGridMetrics.posterWidth, height: TmdbBrowseGridMetrics.posterHeight)
                        .clipped()
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .frame(width: TmdbBrowseGridMetrics.posterWidth, height: TmdbBrowseGridMetrics.posterHeight)
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: isFocused,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(
                    shape.stroke(
                        isFocused ? AppFocusOutline.color : .clear,
                        lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
                    )
                )
                .shadow(
                    color: .black.opacity(isFocused ? 0.5 : 0.2),
                    radius: isFocused ? 16 : 6
                )

                if posterLabels || alwaysShowLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(isFocused ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: TmdbBrowseGridMetrics.posterWidth, alignment: .leading)
                }
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .titleActionsContextMenu(
            meta: title.asMeta,
            onOpenDetails: onSelect
        )
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: isFocused)
        .zIndex(isFocused ? 1 : 0)
    }

    private var subtitle: String {
        var parts = [title.type == "series" ? "Series" : "Movie"]
        if let year = title.year { parts.append(year) }
        if let rating = title.rating, rating > 0 {
            parts.append(String(format: "★ %.1f", rating))
        }
        return parts.joined(separator: "  ·  ")
    }
}

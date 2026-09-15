import SwiftUI

/// Band identifiers for the macOS keyboard model, and the filters the host can
/// open from it. Declared unfenced because the filter bar and grid that use
/// them are shared with tvOS.
enum DiscoverFocusBand {
    static let filters = "discover.filters"
    static let grid = "discover.grid"
    /// The grid is the same 210pt posters at the same 28pt gap as Search's
    /// results, inside the same page inset, so it is the same seven wide.
    static let gridColumns = 7

    enum Filter { case type, catalog, genre }
}

private enum DiscoverGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
}

/// Embeddable Discover section — a filterable poster grid (type / sort / genre)
/// backed by Cinemeta. Hosted inside the Search tab below the search bar.
/// The host provides the outer title, padding and background.
struct DiscoverSection: View {
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    /// Lets an embedded host react to moving into a card or out of the
    /// Discover controls entirely (the Netflix Search host uses this to
    /// collapse/restore its keyboard).
    var onCardFocus: (() -> Void)? = nil
    var onFilterFocus: (() -> Void)? = nil
    var onFocusExit: (() -> Void)? = nil
    @StateObject private var viewModel = DiscoverViewModel()
    @FocusState private var focusedCardID: String?
    @State private var focusedElementID: String?
    /// Cards can briefly blur while a rapid remote swipe realizes the next
    /// grid cell. Only treat it as leaving Discover if it remains unfocused.
    @State private var focusChangeGeneration = 0
    /// Last card focused in the grid, kept so returning from details (which
    /// steals focus and nils `focusedCardID`) restores that card instead of
    /// snapping back to the top of the grid.
    @State private var lastFocusedCardID: String?
    @State private var shouldRestoreFocus = false
    /// Debounced arming of the restore flag: a rapid vertical move blips
    /// `focusedCardID` to nil while the next lazy cell materializes, and
    /// arming instantly on that blip bounces focus back to the previous card.
    @State private var restoreArmTask: Task<Void, Never>?
    /// Card to actively re-focus once the Details overlay dismisses; captured
    /// when the tab view gets disabled (overlay up), consumed on re-enable.
    @State private var overlayRestoreCardID: String?
    @State private var overlayRestoreGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @Binding private var parentTransitionActive: Bool
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false
    #if os(macOS)
    /// Discover is always embedded, so it publishes its rows into the host
    /// screen's keyboard model and reads the caret back out of it rather than
    /// claiming the key router itself. See `MacFocusContribution`.
    private var macFocus: MacScreenFocus?
    private var macContribute: ((MacFocusContribution) -> Void)?
    @State private var macOpenType = false
    @State private var macOpenCatalog = false
    @State private var macOpenGenre = false
    #endif

    init(
        onContentClick: @escaping (String, String) -> Void,
        onLongPress: ((NuvioMeta) -> Void)? = nil,
        onCardFocus: (() -> Void)? = nil,
        onFilterFocus: (() -> Void)? = nil,
        onFocusExit: (() -> Void)? = nil,
        parentTransitionActive: Binding<Bool>
    ) {
        self.onContentClick = onContentClick
        self.onLongPress = onLongPress
        self.onCardFocus = onCardFocus
        self.onFilterFocus = onFilterFocus
        self.onFocusExit = onFocusExit
        _parentTransitionActive = parentTransitionActive
    }

    #if os(macOS)
    /// Attaches the host screen's keyboard model: the caret this section draws
    /// its highlights from, and where to hand its own rows up to. Set after
    /// init rather than through it, because these types do not exist on tvOS
    /// and a shared initialiser could not name them.
    func macFocusModel(
        _ focus: MacScreenFocus,
        contribute: @escaping (MacFocusContribution) -> Void
    ) -> DiscoverSection {
        var copy = self
        copy.macFocus = focus
        copy.macContribute = contribute
        return copy
    }
    #endif

    #if os(macOS)
    private var macFilterItems: [String] {
        var items = ["type"]
        if !viewModel.catalogs.isEmpty { items.append("catalog") }
        items.append("genre")
        return items
    }

    /// Republished whenever the filter set or the grid changes.
    private func macPublish() {
        guard let macContribute else { return }
        var bands = [MacFocusBand(id: DiscoverFocusBand.filters, items: macFilterItems)]
        if !visibleItems.isEmpty {
            bands.append(MacFocusBand(
                id: DiscoverFocusBand.grid,
                items: visibleItems.map(\.id),
                columns: DiscoverFocusBand.gridColumns
            ))
        }
        macContribute(MacFocusContribution(bands: bands, activate: macActivate))
    }

    private func macActivate(band: String, item: String) {
        if band == DiscoverFocusBand.filters {
            switch item {
            case "type": macOpenType = true
            case "catalog": macOpenCatalog = true
            default: macOpenGenre = true
            }
            return
        }
        guard let meta = visibleItems.first(where: { $0.id == item }) else { return }
        parentTransitionActive = true
        overlayRestoreCardID = meta.id
        lastFocusedCardID = meta.id
        onContentClick(meta.id, meta.type)
    }
    #endif

    /// True when the host's caret is on this control. Always false on tvOS,
    /// where the focus engine drives the appearance instead.
    private func macIsFocused(_ band: String, _ item: String) -> Bool {
        #if os(macOS)
        return macFocus?.isFocused(band, item) == true
        #else
        return false
        #endif
    }

    /// Lets the host open a filter menu from the keyboard. Nil on tvOS, where
    /// the focus engine and Select already do it.
    private func macOpen(_ filter: DiscoverFocusBand.Filter) -> Binding<Bool>? {
        #if os(macOS)
        switch filter {
        case .type: return $macOpenType
        case .catalog: return $macOpenCatalog
        case .genre: return $macOpenGenre
        }
        #else
        return nil
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            filterBar
                .disabled(overlayRestoreCardID != nil)
                .zIndex(1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .zIndex(0)
        }
        .onChange(of: focusedCardID) { _, newValue in
            if let newValue {
                restoreArmTask?.cancel()
                lastFocusedCardID = newValue
                shouldRestoreFocus = false
                // Restoration complete -- lift the focus restriction.
                if isEnabled, newValue == overlayRestoreCardID {
                    overlayRestoreCardID = nil
                    parentTransitionActive = false
                }
            } else if lastFocusedCardID != nil {
                scheduleRestoreArm()
            }
        }
        .onChange(of: focusedElementID) { oldValue, newValue in
            if newValue?.hasPrefix("card:") == true {
                onCardFocus?()
            } else if newValue?.hasPrefix("filter:") == true {
                onFilterFocus?()
            } else if oldValue?.hasPrefix("filter:") == true, newValue == nil {
                // Lazy grid cells can briefly disappear from the focus tree
                // during a rapid scroll. A card blur is therefore not proof
                // that focus left Discover; only the fixed filter bar can
                // reliably hand focus back to the host keyboard.
                onFocusExit?()
            }
        }
        // Overlay dismissal re-places focus geometrically without consulting
        // `defaultFocus`. While `overlayRestoreCardID` is set every other card
        // is unfocusable, so the engine can only land back on the saved card
        // -- no scroll-to-top flash. See TVHomeView for the full story.
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = focusedCardID ?? lastFocusedCardID
            } else if let target = overlayRestoreCardID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
        #if os(macOS)
        .onAppear { macPublish() }
        .onChange(of: visibleItems.map(\.id)) { _, _ in macPublish() }
        .onChange(of: viewModel.catalogs.count) { _, _ in macPublish() }
        #endif
    }

    /// Arms the restore flag only after focus has stayed off the cards long
    /// enough that the nil is a real departure (menu/tab) instead of the
    /// one-frame blip of a rapid vertical move between lazy cells.
    private func scheduleRestoreArm() {
        guard lastFocusedCardID != nil, focusedCardID == nil else { return }
        restoreArmTask?.cancel()
        restoreArmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, focusedCardID == nil else { return }
            shouldRestoreFocus = true
        }
    }

    private func restoreOverlayFocus(to target: String, generation: Int) {
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                    focusedCardID = target
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                overlayRestoreCardID = nil
                parentTransitionActive = false
            }
        }
    }

    // MARK: - Filters (dropdown menus)

    private var filterBar: some View {
        HStack(spacing: 16) {
            FilterMenu(
                label: viewModel.type.title,
                options: viewModel.availableTypes.map { type in
                    FilterOption(type.title, isSelected: viewModel.type == type) {
                        viewModel.setType(type)
                    }
                },
                onFocusChange: { updateDiscoverFocus("filter:type", isFocused: $0) },
                macIsFocused: macIsFocused(DiscoverFocusBand.filters, "type"),
                macOpen: macOpen(.type)
            )

            // Catalogs come from the installed add-ons, so this list changes
            // with the selected type (and is empty until manifests load).
            if !viewModel.catalogs.isEmpty {
                FilterMenu(
                    label: viewModel.catalog?.name ?? L10n.string("tvos_discover_popular", fallback: "Popular"),
                    options: viewModel.catalogs.map { catalog in
                        FilterOption(catalog.title, isSelected: viewModel.catalog == catalog) {
                            viewModel.setCatalog(catalog)
                        }
                    },
                    onFocusChange: { updateDiscoverFocus("filter:sort", isFocused: $0) },
                    macIsFocused: macIsFocused(DiscoverFocusBand.filters, "catalog"),
                    macOpen: macOpen(.catalog)
                )
            }

            FilterMenu(
                label: viewModel.genre ?? L10n.string("tvos_discover_all_genres", fallback: "All Genres"),
                options: genreOptions,
                onFocusChange: { updateDiscoverFocus("filter:genre", isFocused: $0) },
                macIsFocused: macIsFocused(DiscoverFocusBand.filters, "genre"),
                macOpen: macOpen(.genre)
            )
        }
    }

    private var genreOptions: [FilterOption] {
        let all = FilterOption(
            L10n.string("tvos_discover_all_genres", fallback: "All Genres"),
            isSelected: viewModel.genre == nil
        ) {
            viewModel.setGenre(nil)
        }
        return [all] + viewModel.genres.map { genre in
            FilterOption(genre, isSelected: viewModel.genre == genre) {
                viewModel.setGenre(genre)
            }
        }
    }

    // MARK: - Content

    private var visibleItems: [NuvioMeta] {
        guard hideUnreleased else { return viewModel.items }
        return viewModel.items.filter { !ContentReleasePolicy.isUnreleased($0) }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            centered { BrandLoadingView(wordmarkWidth: 360) }
        } else if let error = viewModel.error, visibleItems.isEmpty {
            centered {
                message(icon: "wifi.exclamationmark", title: error)
            }
        } else if visibleItems.isEmpty {
            centered {
                message(
                    icon: "rectangle.on.rectangle.slash",
                    title: L10n.string("tvos_discover_empty_title", fallback: "Nothing here"),
                    subtitle: L10n.string(
                        "tvos_discover_empty_subtitle",
                        fallback: "Try a different genre or category."
                    )
                )
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        #if os(macOS)
        // The caret is a plain value, so nothing pulls a row below the fold
        // into view on its own.
        ScrollViewReader { proxy in
            gridScrollView
                .onChange(of: macFocus?.itemID) { _, id in
                    guard let id, macFocus?.bandID == DiscoverFocusBand.grid else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
        }
        #else
        gridScrollView
        #endif
    }

    private var gridScrollView: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: DiscoverGridMetrics.posterGap) {
                ForEach(visibleItems) { item in
                    DiscoverCard(
                        meta: item,
                        externalFocus: $focusedCardID,
                        onFocusChange: { updateDiscoverFocus("card:\(item.id)", isFocused: $0) },
                        retainFocusAppearance: overlayRestoreCardID == item.id,
                        macIsFocused: macIsFocused(DiscoverFocusBand.grid, item.id),
                        onLongPress: onLongPress.map { cb in { cb(item) } }
                    ) {
                        parentTransitionActive = true
                        overlayRestoreCardID = item.id
                        lastFocusedCardID = item.id
                        onContentClick(item.id, item.type)
                    }
                    .disabled(overlayRestoreCardID != nil && overlayRestoreCardID != item.id)
                    .id(item.id)
                    .onAppear { viewModel.loadMoreIfNeeded(currentItem: item) }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 12)

            if viewModel.isLoadingMore {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 28)
            }

            Color.clear.frame(height: 60)
        }
        // This is a vertical grid beneath fixed controls. Its focused cards
        // must remain inside the viewport instead of spilling upward over the
        // Movies / Popular / All Genres menus.
        .scrollClipDisabled(false)
        .focusSection()
        .defaultFocusIfAvailable($focusedCardID, shouldRestoreFocus ? lastFocusedCardID : nil)
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: DiscoverGridMetrics.posterWidth, maximum: DiscoverGridMetrics.posterWidth),
            spacing: DiscoverGridMetrics.posterGap,
            alignment: .top
        )]
    }

    /// Adjacent controls report blur/focus separately. Defer a blur by one
    /// focus pass so a card-to-filter move remains inside Discover rather than
    /// briefly looking like focus left the section altogether.
    private func updateDiscoverFocus(_ id: String, isFocused: Bool) {
        if isFocused {
            focusChangeGeneration &+= 1
            focusedElementID = id
        } else if focusedElementID == id {
            let generation = focusChangeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                if focusChangeGeneration == generation, focusedElementID == id {
                    focusedElementID = nil
                }
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 40)
            content()
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func message(icon: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 700)
    }
}

// MARK: - Filter dropdown

/// One option in a dropdown, as data rather than as a view.
///
/// `FilterMenu` used to take its options as a `@ViewBuilder` of `Button`s.
/// A ViewBuilder cannot be enumerated, so macOS had no way to draw the list
/// itself and fell back to `confirmationDialog` — an `NSAlert`, which shows at
/// most three buttons and drops the rest with no indication. Passing data
/// instead lets each platform present the same options its own way: the system
/// dialog on tvOS, an in-canvas panel on macOS.
struct FilterOption: Identifiable {
    let id: String
    let label: String
    let isSelected: Bool
    let apply: () -> Void

    init(_ label: String, isSelected: Bool, apply: @escaping () -> Void) {
        self.id = label
        self.label = label
        self.isSelected = isSelected
        self.apply = apply
    }
}

/// A glass chip that opens a dropdown menu of options. Falls back to a static
/// chip on tvOS < 17 (where `Menu` is unavailable). Shared by Discover & Library.
struct FilterMenu: View {
    let label: String
    /// The options, as data — see `FilterOption` for why this is not a
    /// `@ViewBuilder` of buttons any more.
    let options: [FilterOption]
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Driven by `MacScreenFocus`; macOS has no focus engine to set `focused`.
    var macIsFocused = false
    /// Set by the owning screen to open this menu from the keyboard. Consumed
    /// immediately, so the screen only has to raise it.
    var macOpen: Binding<Bool>? = nil
    @State private var showOptions = false
    @FocusState private var focused: Bool

    private var showsFocus: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return focused
        #endif
    }

    var body: some View {
        Button(action: open) { chipLabel }
            .buttonStyle(PosterCardButtonStyle())
            .nuvioFocusable()
            .focused($focused)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(showsFocus ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.14), value: showsFocus)
            #if !os(macOS)
            // tvOS presents the system dialog, which has no button limit and
            // is what the focus engine expects. Only AppKit's NSAlert caps it.
            .confirmationDialog(label, isPresented: $showOptions, titleVisibility: .visible) {
                ForEach(options) { option in
                    Button { option.apply() } label: {
                        Text(option.isSelected ? "✓  \(option.label)" : option.label)
                    }
                }
            }
            #endif
            .onChange(of: focused) { _, isFocused in onFocusChange?(isFocused) }
            .onChange(of: macOpen?.wrappedValue ?? false) { _, wantsOpen in
                guard wantsOpen else { return }
                open()
                macOpen?.wrappedValue = false
            }
    }

    private func open() {
        #if os(macOS)
        MacOptionPanel.shared.present(title: label, options: options)
        #else
        showOptions = true
        #endif
    }

    private var chipLabel: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
        }
        .foregroundColor(.white.opacity(showsFocus ? 1.0 : 0.9))
        .padding(.horizontal, 28)
        .frame(height: 60)
        .modifier(GlassChipBackground(filled: false))
        .overlay(
            Capsule()
                .strokeBorder(showsFocus ? AppFocusOutline.color : .clear, lineWidth: showsFocus ? AppFocusOutline.width : 0)
        )
    }
}

// MARK: - Card

private struct DiscoverCard: View {
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    var retainFocusAppearance = false
    /// Driven by `MacScreenFocus`; macOS has no focus engine to set `focused`.
    var macIsFocused = false
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
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

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottom) {
                    CachedPosterArtwork(
                        urlString: meta.posterUrl,
                        width: DiscoverGridMetrics.posterWidth,
                        height: DiscoverGridMetrics.posterHeight,
                        maximumWidth: DiscoverGridMetrics.posterWidth
                    ) {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.07))
                            Image(systemName: meta.type == "series" ? "tv" : "film")
                                .font(.system(size: 40))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }
                    .frame(width: DiscoverGridMetrics.posterWidth, height: DiscoverGridMetrics.posterHeight)

                    if metaLine != nil {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.85)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 120)
                        .frame(maxWidth: .infinity, alignment: .bottom)

                        if let metaLine {
                            Text(metaLine)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(width: DiscoverGridMetrics.posterWidth, height: DiscoverGridMetrics.posterHeight)
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: showsFocusedAppearance,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(meta: meta)
                }
                .overlay(
                    shape.stroke(showsFocusedAppearance ? focusBorderColor : .clear, lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width)
                )
                .shadow(color: .black.opacity(showsFocusedAppearance ? 0.5 : 0.2), radius: showsFocusedAppearance ? 16 : 6)

                if posterLabels {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(showsFocusedAppearance ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        if let year = meta.year {
                            Text(String(year))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(width: DiscoverGridMetrics.posterWidth, alignment: .leading)
                }
            }
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: meta.id))
        .focusEffectDisabledIfAvailable()
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: action
        )
        .onChange(of: focused) { _, isFocused in onFocusChange?(isFocused) }
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: showsFocusedAppearance)
    }

    /// "Genre · ★ Rating" overlay, omitting whichever piece is missing.
    private var metaLine: String? {
        var parts: [String] = []
        if let genre = meta.genres?.first, !genre.isEmpty { parts.append(genre) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var focusBorderColor: Color {
        AppFocusOutline.color
    }

    private var showsFocusedAppearance: Bool {
        macIsFocused || focused || retainFocusAppearance
    }
}

import SwiftUI

private enum CalendarMetrics {
    /// 16:9 still, sized so five cards sit comfortably across a 1080p-safe row.
    static let cardWidth: CGFloat = 320
    static let cardImageHeight: CGFloat = 180
    static let cardGap: CGFloat = 28
    /// Matches LibraryGridMetrics.pageInset so headings line up across tabs.
    static let pageInset: CGFloat = 36
    /// Hero block height, mirroring TVHeroView's compact proportions.
    static let heroHeight: CGFloat = 360
    /// Month grid cell.
    static let dayCellWidth: CGFloat = 224
    static let dayCellHeight: CGFloat = 150
    static let dayCellGap: CGFloat = 12
}

/// Upcoming (and recent) releases for the titles the user follows.
///
/// Two presentations, chosen in Settings → Layout → Calendar View:
/// `.list` groups by day; `.month` is a browsable month grid. Both honour the
/// shared `heroEnabled` / `fullscreenHeroBackdrop` layout settings so the tab
/// matches Home rather than carrying its own toggle.
struct CalendarView: View {
    let onContentClick: (String, String) -> Void

    @StateObject private var viewModel = CalendarViewModel()
    #if os(macOS)
    /// macOS has no focus engine: each day is a band of entries. See
    /// `MacScreenFocus`.
    @StateObject private var macFocus = MacScreenFocus("calendar")
    @ObservedObject private var keyRouter = MacKeyRouter.shared
    @ObservedObject private var macTabState = MacTabState.shared
    /// Day the caret goes back to when the slide-out panel closes, so backing
    /// out of a day does not reseed the grid to the filters.
    @State private var macReturnDayKey: String?
    #endif
    @FocusState private var focusedEntryID: String?
    @FocusState private var focusedDayKey: String?
    @State private var focusedEntry: CalendarEntry?
    @State private var monthAnchor = Date()
    /// One-shot: place focus on today when the month grid first has data.
    @State private var didPlaceInitialFocus = false

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.fullscreenHeroBackdrop) private var fullscreenHeroBackdrop = true
    @AppStorage(SettingsKey.calendarViewMode) private var calendarViewModeRaw = CalendarViewMode.list.rawValue
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue

    /// Day whose episodes are shown in the slide-out panel.
    @State private var panelDayKey: String?
    @FocusState private var focusedPanelEntryID: String?
    /// Sports competition menu (Search-style dropdown).
    @State private var showSportMenu = false

    private var mode: CalendarViewMode { CalendarViewMode.from(calendarViewModeRaw) }
    private var backgroundColor: Color { Color.nuvioBackground(amoled: amoled, body: bodyColor) }
    /// Appearance → accent, so Calendar focus matches the rest of the app.
    private var accentColor: Color { SettingsAccent.color(for: theme) }

    var body: some View {
        ZStack(alignment: .top) {
            backgroundColor.ignoresSafeArea()

            if heroEnabled {
                backdropLayer
            }

            VStack(alignment: .leading, spacing: 0) {
                if heroEnabled, mode == .list, let focusedEntry {
                    CalendarHeroView(entry: focusedEntry)
                        .frame(height: CalendarMetrics.heroHeight, alignment: .bottomLeading)
                        .transition(.opacity)
                } else {
                    // No page heading: the tab bar chip already reads "Calendar",
                    // and the reclaimed height lets the month grid sit higher.
                    Color.clear.frame(height: 34)
                }

                filterChips
                    .padding(.horizontal, CalendarMetrics.pageInset)
                    .padding(.bottom, 14)

                content
                    // Rows scrolled up behind the hero would otherwise be cut
                    // mid-card, showing a caption with no artwork above it.
                    .mask(heroEnabled && mode == .list ? AnyView(topFade) : AnyView(Rectangle()))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .disabled(panelDayKey != nil)

            if let panelDayKey {
                DayEntriesPanel(
                    dayKey: panelDayKey,
                    entries: viewModel.entries(on: panelDayKey),
                    accentColor: accentColor,
                    macFocusedEntryID: macPanelEntryID,
                    focusedEntryID: $focusedPanelEntryID,
                    onSelect: { entry in
                        self.panelDayKey = nil
                        onContentClick(entry.metaId, entry.type)
                    }
                )
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }
        }
        // Menu backs out of whatever is on top rather than leaving the tab.
        .onExitCommand(perform: exitCommand)
        .onChange(of: focusedPanelEntryID) { _, id in
            guard let id, let key = panelDayKey,
                  let match = viewModel.entries(on: key).first(where: { $0.id == id }) else { return }
            withAnimation(.easeOut(duration: 0.25)) { focusedEntry = match }
        }
        .task {
            // Cheap to repeat: the repository caches metadata, so re-entering
            // the tab picks up newly added titles without refetching the rest.
            await viewModel.load()
        }
        // `defaultFocus` loses to the month chevrons, which appear earlier in the
        // hierarchy, so place focus explicitly — once, so it never steals focus
        // back from the user afterwards.
        .task(id: viewModel.hasLoaded) {
            guard mode == .month, viewModel.hasLoaded, !didPlaceInitialFocus else { return }
            let today = CalendarDayKey.dayKey(offsetFromToday: 0)
            // A single assignment is silently dropped while the cells are still
            // being realized, so retry briefly until the engine accepts it.
            for _ in 0..<12 {
                if focusedDayKey == today { break }
                focusedDayKey = today
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled { return }
            }
            didPlaceInitialFocus = true
        }
        .onChange(of: focusedEntryID) { _, id in
            guard let id, let match = viewModel.entriesByDay.values.flatMap({ $0 }).first(where: { $0.id == id })
            else { return }
            withAnimation(.easeOut(duration: 0.25)) { focusedEntry = match }
        }
        .onChange(of: focusedDayKey) { _, key in
            guard let key else { return }
            if let first = viewModel.entries(on: key).first {
                withAnimation(.easeOut(duration: 0.25)) { focusedEntry = first }
            }
        }
        #if os(macOS)
        .onAppear {
            macFocus.update(macBands)
            macFocus.syncClaim(isCurrent: macTabState.current == .calendar)
        }
        .onDisappear { macFocus.release() }
        .onChange(of: macTabState.current, initial: true) { _, tab in
            macFocus.update(macBands)
            macFocus.syncClaim(isCurrent: tab == .calendar)
        }
        .onChange(of: viewModel.days.map(\.id)) { _, _ in macFocus.update(macBands) }
        .onChange(of: mode) { _, _ in macFocus.update(macBands) }
        .onChange(of: monthAnchor) { _, _ in macFocus.update(macBands) }
        .onChange(of: viewModel.entriesByDay.count) { _, _ in macFocus.update(macBands) }
        // Opening or closing the day panel changes who owns the keyboard.
        .onChange(of: panelDayKey) { _, key in
            macFocus.update(macBands)
            guard key == nil, let day = macReturnDayKey,
                  let week = macMonthBands.first(where: { $0.items.contains(day) })
            else { return }
            macFocus.focus(band: week.id, item: day)
            macReturnDayKey = nil
        }
        .onChange(of: keyRouter.latest) { _, press in
            guard let press else { return }
            macFocus.handle(press.key, activate: macActivate)
            macSkipBlankDay()
        }
        // The hero above the list follows the highlight, the way the focus
        // engine drives it on tvOS.
        .onChange(of: macFocus.itemID) { _, id in
            guard let id,
                  let match = viewModel.entriesByDay.values.flatMap({ $0 }).first(where: { $0.id == id })
            else { return }
            withAnimation(.easeOut(duration: 0.25)) { focusedEntry = match }
        }
        #endif
    }

    private var filterChips: some View {
        HStack(spacing: 14) {
            #if os(macOS)
            // Clear of the collapsed menu icon in the top-left corner.
            Color.clear.frame(width: MacMenuMetrics.headerInset, height: 1)
            #endif
            ForEach(CalendarFilter.allCases) { option in
                CalendarFilterChip(
                    title: chipTitle(for: option),
                    isSelected: viewModel.filters.contains(option),
                    macIsFocused: macIsFocused(CalendarFocusBand.filters, option.rawValue),
                    showsMenuAffordance: option == .sports && sportMenuAvailable,
                    accentColor: accentColor,
                    action: {
                        withAnimation(.easeOut(duration: 0.18)) { viewModel.toggle(option) }
                    },
                    longPressAction: option == .sports && sportMenuAvailable
                        ? { showSportMenu = true }
                        : nil
                )
            }

            if (viewModel.filters.contains(.sports) && viewModel.isLoadingSports)
                || (viewModel.filters.contains(.movies) && viewModel.isLoadingMovies) {
                ProgressView().padding(.leading, 8)
            }
            Spacer(minLength: 0)
        }
        // Same dialog Search and Discover use for their filters. On macOS that
        // is an NSAlert, which shows three buttons and drops the rest — which
        // is why this chip read as all-or-nothing there.
        #if !os(macOS)
        .confirmationDialog(
            L10n.string("calendar_sports_picker_title", fallback: "Sports"),
            isPresented: $showSportMenu,
            titleVisibility: .visible
        ) {
            ForEach(sportOptions) { option in
                Button { option.apply() } label: {
                    menuItem(option.label, selected: option.isSelected)
                }
            }
        }
        #endif
        .onChange(of: showSportMenu) { _, wantsOpen in
            #if os(macOS)
            guard wantsOpen else { return }
            showSportMenu = false
            MacOptionPanel.shared.present(
                title: L10n.string("calendar_sports_picker_title", fallback: "Sports"),
                options: sportOptions
            )
            #endif
        }
    }

    /// Competitions, with "All Sports" ahead of them.
    private var sportOptions: [FilterOption] {
        let all = FilterOption(
            L10n.string("calendar_sports_all", fallback: "All Sports"),
            isSelected: viewModel.selectedSportGenre == nil
        ) {
            viewModel.selectedSportGenre = nil
        }
        return [all] + viewModel.availableSportGenres.map { genre in
            FilterOption(genre, isSelected: viewModel.selectedSportGenre == genre) {
                viewModel.selectedSportGenre = genre
            }
        }
    }

    /// The competition menu is only worth offering once Sports is on and
    /// fixtures have loaded — the list comes from the fixtures themselves.
    private var sportMenuAvailable: Bool {
        viewModel.filters.contains(.sports) && !viewModel.availableSportGenres.isEmpty
    }

    /// The Sports chip reads the chosen competition, so the current narrowing is
    /// visible without opening anything.
    private func chipTitle(for option: CalendarFilter) -> String {
        guard option == .sports,
              viewModel.filters.contains(.sports),
              let genre = viewModel.selectedSportGenre
        else { return option.title }
        return genre
    }

    /// Matches Discover's menu rows.
    private func menuItem(_ title: String, selected: Bool) -> some View {
        Text(selected ? "✓  \(title)" : title)
    }



    /// Back closes the topmost layer, and only leaves the tab when nothing is
    /// open. Returning nil hands Menu back to the tab bar — without that the
    /// app would quit from here.
    private var exitCommand: (() -> Void)? {
        if let openDay = panelDayKey {
            return {
                withAnimation(.easeOut(duration: 0.22)) { panelDayKey = nil }
                restoreFocus(toDay: openDay)
            }
        }
        return nil
    }

    /// Puts focus back on the day whose panel was just closed, instead of
    /// letting the grid reset to the top as though the tab had been re-entered.
    /// Retried briefly for the same reason the initial placement is: a single
    /// assignment is dropped while the cells are still being realized.
    private func restoreFocus(toDay key: String) {
        Task { @MainActor in
            for _ in 0..<10 {
                if focusedDayKey == key { return }
                focusedDayKey = key
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    /// Short dissolve at the very top of the scrolling content.
    private var topFade: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// The same crossfading backdrop Home uses, so switching tabs feels
    /// continuous rather than like a different app.
    private var backdropLayer: some View {
        GeometryReader { proxy in
            if fullscreenHeroBackdrop {
                CrossfadingBackdrop(url: focusedEntry?.backdropUrl, placeholder: backgroundColor)
                    .equatable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay(
                        // The month grid sits over the whole screen, so it needs a
                        // far heavier scrim than the list hero to stay readable.
                        mode == .month
                            ? AnyView(backgroundColor.opacity(0.88))
                            : AnyView(
                                LinearGradient(
                                    stops: [
                                        .init(color: backgroundColor.opacity(0.30), location: 0),
                                        .init(color: backgroundColor.opacity(0.80), location: 0.45),
                                        .init(color: backgroundColor, location: 0.85),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
            } else {
                ZStack(alignment: .topTrailing) {
                    backgroundColor
                    CrossfadingBackdrop(
                        url: focusedEntry?.backdropUrl,
                        placeholder: backgroundColor,
                        alignment: .topTrailing
                    )
                    .equatable()
                    .frame(width: proxy.size.width * 0.65, height: 460, alignment: .topTrailing)
                    .mask(
                        LinearGradient(
                            colors: [.black, .black.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.entriesByDay.isEmpty {
            if viewModel.isLoading || !viewModel.hasLoaded { loadingState } else { emptyState }
        } else {
            switch mode {
            case .list:  listMode
            case .month: monthMode
            }
        }
    }

    /// The panel row the caret sits on, or nil when the panel is not up.
    private var macPanelEntryID: String? {
        #if os(macOS)
        return macFocus.bandID == CalendarFocusBand.panel ? macFocus.itemID : nil
        #else
        return nil
        #endif
    }

    /// The day cell the caret sits on, or nil when it is elsewhere.
    private var macFocusedMonthDay: String? {
        #if os(macOS)
        guard let band = macFocus.bandID, band.hasPrefix(CalendarFocusBand.weekPrefix) else { return nil }
        return macFocus.itemID
        #else
        return nil
        #endif
    }

    /// True when the macOS highlight is on this entry; always false on tvOS,
    /// where the focus engine drives the same appearance.
    private func macIsFocused(_ day: String, _ entry: String) -> Bool {
        #if os(macOS)
        return macFocus.isFocused(day, entry)
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// List mode is one band per day; month mode is the header controls above
    /// a seven-wide matrix, one band per week row.
    private var macBands: [MacFocusBand] {
        // The panel covers the grid and disables it, so it owns the keyboard
        // outright rather than sitting on top of a still-navigable screen.
        if let panelDayKey {
            let entries = viewModel.entries(on: panelDayKey)
            if !entries.isEmpty {
                return [MacFocusBand(
                    id: CalendarFocusBand.panel,
                    items: entries.map(\.id),
                    columns: 1
                )]
            }
        }
        var bands = [MacFocusBand(
            id: CalendarFocusBand.filters,
            items: CalendarFilter.allCases.map(\.rawValue)
        )]
        guard mode == .list else { return bands + macMonthBands }
        bands += viewModel.days.map { day in
            MacFocusBand(id: day.id, items: day.entries.map(\.id))
        }
        return bands
    }

    private var macMonthBands: [MacFocusBand] {
        var header = ["prev", "next"]
        if !CalendarDateFormatting.isSameMonth(monthAnchor, Date()) { header.append("today") }
        var bands = [MacFocusBand(id: CalendarFocusBand.monthHeader, items: header)]

        let layout = CalendarDateFormatting.monthLayout(for: monthAnchor)
        for (week, days) in layout.weeks.enumerated() {
            let items = days.enumerated().map { column, day -> String in
                guard let day else { return "\(CalendarFocusBand.blankPrefix)\(week).\(column)" }
                return CalendarDayKey.dayKey(year: layout.year, month: layout.month, day: day)
            }
            bands.append(MacFocusBand(
                id: "\(CalendarFocusBand.weekPrefix)\(week)",
                items: items,
                columns: 7,
                // The weeks are rows of one grid: moving between them holds the
                // weekday, rather than returning to whichever day that week was
                // last left on.
                carriesColumn: true
            ))
        }
        return bands
    }

    /// Days outside the month hold the matrix square but draw nothing, so the
    /// caret never rests on one — it carries on to the nearest real day in the
    /// same week, which is always toward the middle of the month.
    private func macSkipBlankDay() {
        guard let band = macFocus.bandID, let item = macFocus.itemID,
              CalendarFocusBand.isBlank(item),
              let week = macMonthBands.first(where: { $0.id == band }),
              let index = week.items.firstIndex(of: item)
        else { return }
        let real = week.items.enumerated()
            .filter { !CalendarFocusBand.isBlank($0.element) }
            .min(by: { abs($0.offset - index) < abs($1.offset - index) })
        guard let real else { return }
        macFocus.focus(band: band, item: real.element)
    }

    private func macActivate(day: String, entry: String) {
        if day == CalendarFocusBand.filters {
            guard let option = CalendarFilter(rawValue: entry) else { return }
            withAnimation(.easeOut(duration: 0.18)) { viewModel.toggle(option) }
            return
        }
        if day == CalendarFocusBand.panel {
            guard let key = panelDayKey,
                  let match = viewModel.entries(on: key).first(where: { $0.id == entry })
            else { return }
            panelDayKey = nil
            onContentClick(match.metaId, match.type)
            return
        }
        if day == CalendarFocusBand.monthHeader {
            switch entry {
            case "prev": step(by: -1)
            case "next": step(by: 1)
            default: withAnimation(.easeOut(duration: 0.2)) { monthAnchor = Date() }
            }
            return
        }
        if day.hasPrefix(CalendarFocusBand.weekPrefix) {
            guard !CalendarFocusBand.isBlank(entry),
                  !viewModel.entries(on: entry).isEmpty else { return }
            focusedPanelEntryID = viewModel.entries(on: entry).first?.id
            macReturnDayKey = entry
            withAnimation(.easeOut(duration: 0.22)) { panelDayKey = entry }
            return
        }
        guard let match = viewModel.days.first(where: { $0.id == day })?
            .entries.first(where: { $0.id == entry })
        else { return }
        onContentClick(match.metaId, match.type)
    }
    #endif

    // MARK: - List mode

    private var listMode: some View {
        #if os(macOS)
        // The highlight is a plain value, so it lands on days below the fold
        // that the viewport never follows.
        ScrollViewReader { proxy in
            listScrollView
                .onChange(of: macFocus.bandID) { _, day in
                    guard let day else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(day, anchor: .center)
                    }
                }
        }
        #else
        listScrollView
        #endif
    }

    private var listScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                ForEach(viewModel.days) { day in
                    daySection(day)
                        .id(day.id)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func daySection(_ day: CalendarDay) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            dayHeading(day.id)
                .padding(.horizontal, CalendarMetrics.pageInset)

            #if os(macOS)
            // Each day scrolls on its own, so the caret walks straight off the
            // right-hand edge unless this row follows it.
            ScrollViewReader { rowProxy in
                dayEntries(day)
                    .onChange(of: macFocus.itemID) { _, id in
                        guard let id, macFocus.bandID == day.id else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            rowProxy.scrollTo(id, anchor: .center)
                        }
                    }
            }
            #else
            dayEntries(day)
            #endif
        }
    }

    @ViewBuilder
    private func dayEntries(_ day: CalendarDay) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CalendarMetrics.cardGap) {
                ForEach(day.entries) { entry in
                    CalendarEntryCard(
                        entry: entry,
                        accentColor: accentColor,
                        macIsFocused: macIsFocused(day.id, entry.id)
                    ) {
                        onContentClick(entry.metaId, entry.type)
                    }
                    .nuvioFocusable()
                    .focused($focusedEntryID, equals: entry.id)
                    .id(entry.id)
                }
            }
            // Room for the focused card's scale so it cannot clip.
            .padding(.horizontal, CalendarMetrics.pageInset)
            .padding(.vertical, 12)
        }
    }

    private func dayHeading(_ dayKey: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(CalendarDateFormatting.heading(for: dayKey))
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.white)

            if let relative = CalendarDateFormatting.relativeSuffix(for: dayKey) {
                Text(relative)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    // MARK: - Month mode

    private var monthMode: some View {
        VStack(alignment: .leading, spacing: 18) {
            monthHeader
                .padding(.horizontal, CalendarMetrics.pageInset)

            MonthGrid(
                anchor: monthAnchor,
                viewModel: viewModel,
                accentColor: accentColor,
                macFocusedDayKey: macFocusedMonthDay,
                focusedDayKey: $focusedDayKey,
                onOpenDay: { key in
                    guard !viewModel.entries(on: key).isEmpty else { return }
                    focusedPanelEntryID = viewModel.entries(on: key).first?.id
                    withAnimation(.easeOut(duration: 0.22)) { panelDayKey = key }
                }
            )
            .padding(.horizontal, CalendarMetrics.pageInset)

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var monthHeader: some View {
        HStack(spacing: 22) {
            MonthStepButton(
                systemImage: "chevron.left",
                accentColor: accentColor,
                macIsFocused: macIsFocused(CalendarFocusBand.monthHeader, "prev")
            ) { step(by: -1) }

            Text(CalendarDateFormatting.monthTitle(for: monthAnchor))
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize()
                // Centred in a fixed slot so it sits balanced between the chevrons.
                .frame(width: 400, alignment: .center)
                .multilineTextAlignment(.center)

            MonthStepButton(
                systemImage: "chevron.right",
                accentColor: accentColor,
                macIsFocused: macIsFocused(CalendarFocusBand.monthHeader, "next")
            ) { step(by: 1) }

            Spacer()

            if !CalendarDateFormatting.isSameMonth(monthAnchor, Date()) {
                MonthTodayButton(
                    accentColor: accentColor,
                    macIsFocused: macIsFocused(CalendarFocusBand.monthHeader, "today")
                ) { withAnimation(.easeOut(duration: 0.2)) { monthAnchor = Date() } }
            }
        }
    }

    private func step(by months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: monthAnchor) else { return }
        withAnimation(.easeOut(duration: 0.2)) { monthAnchor = next }
    }

    // MARK: - Placeholder states

    private var emptyBody: String {
        // Everything switched off is a deliberate choice, not an empty result —
        // say what to do rather than implying nothing was found.
        if viewModel.filters.isEmpty {
            return L10n.string(
                "calendar_empty_no_filters",
                fallback: "All filters are off. Turn on Shows, Movies or Sports above to see releases."
            )
        }
        // Only one filter on: say something specific. Several on: stay generic
        // rather than guessing which one the user expected to fill.
        if viewModel.filters == [.shows] {
            return L10n.string(
                "calendar_empty_body",
                fallback: "Add shows to your Library and any upcoming episodes will appear here."
            )
        }
        if viewModel.filters == [.movies] {
            return L10n.string(
                "calendar_empty_movies",
                fallback: "Upcoming movies come from installed add-ons with a releases catalog."
            )
        }
        if viewModel.filters == [.sports] {
            return L10n.string(
                "calendar_empty_sports",
                fallback: "No fixtures found. Sports need an installed add-on that publishes sport catalogs."
            )
        }
        return L10n.string(
            "calendar_empty_generic",
            fallback: "Nothing scheduled for the selected filters."
        )
    }

    private var loadingState: some View {
        HStack(spacing: 16) {
            ProgressView()
            Text(L10n.string("calendar_loading", fallback: "Checking your shows for upcoming episodes…"))
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "calendar")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.white.opacity(0.35))

            Text(L10n.string("calendar_empty_title", fallback: "Nothing scheduled"))
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.white)

            Text(emptyBody)
            .font(.system(size: 24))
            .foregroundColor(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}


/// Filter pill. Uses the Appearance accent when selected, matching the focus
/// language used everywhere else on this screen.
private struct CalendarFilterChip: View {
    let title: String
    let isSelected: Bool
    /// Driven by `MacScreenFocus`; macOS has no focus engine to set the
    /// environment value.
    var macIsFocused = false
    /// Draws the chevron hinting that a long press opens a menu.
    var showsMenuAffordance: Bool = false
    let accentColor: Color
    let action: () -> Void
    /// Long press opens the chip's menu, leaving the plain press as the on/off
    /// toggle it is on every other chip.
    var longPressAction: (() -> Void)? = nil

    /// A reference type on purpose: a `@State` Bool is captured by the Button's
    /// action closure, so the closure can still see the pre-gesture value and
    /// toggle the filter anyway. Through a box the flag is read live, and
    /// setting it does not re-render.
    private final class PressGate {
        var swallowNextPress = false
    }
    @State private var pressGate = PressGate()

    var body: some View {
        Button {
            // The hold also releases as a press; swallow that one so opening the
            // menu does not toggle the filter as a side effect.
            guard !pressGate.swallowNextPress else {
                pressGate.swallowNextPress = false
                return
            }
            action()
        } label: {
            ChipBody(
                title: title,
                isSelected: isSelected,
                showsMenuAffordance: showsMenuAffordance,
                accentColor: accentColor,
                macIsFocused: macIsFocused
            )
        }
        .buttonStyle(ChromeButtonStyle())
        .fixedSize()
        // `.onLongPressGesture` never fires here: the Button consumes the press.
        // A simultaneous gesture runs alongside it — the pattern Details uses.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                guard longPressAction != nil else { return }
                pressGate.swallowNextPress = true
                longPressAction?()
                // Safety net: if the hold is never followed by a press (focus
                // moved away instead), do not swallow a genuine press later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    pressGate.swallowNextPress = false
                }
            }
        )
    }

    /// Matches Search / Discover chips: glass pill, white when selected, accent
    /// outline on focus. Calendar previously rolled its own look.
    private struct ChipBody: View {
        @Environment(\.isFocused) private var environmentFocused
        let title: String
        let isSelected: Bool
        let showsMenuAffordance: Bool
        let accentColor: Color
        /// Passed down from the chip: macOS has no focus engine to set the
        /// environment value.
        var macIsFocused = false

        private var isFocused: Bool {
            #if os(macOS)
            return macIsFocused
            #else
            return environmentFocused
            #endif
        }

        var body: some View {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                if showsMenuAffordance {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                }
            }
            .foregroundColor(isSelected ? .black : .white.opacity(isFocused ? 1 : 0.9))
            .padding(.horizontal, 28)
            .frame(height: 60)
            .modifier(GlassChipBackground(filled: isSelected))
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? accentColor : .clear,
                    lineWidth: isFocused ? AppFocusOutline.width : 0
                )
            )
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
        }
    }
}

// MARK: - Hero

/// Calendar's hero text block. Deliberately lighter than `TVHeroView`: it
/// describes one dated episode rather than a title's whole continue-watching
/// state, so it leads with the date.
private struct CalendarHeroView: View {
    let entry: CalendarEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)

            Text(CalendarDateFormatting.heroDateLine(for: entry.dayKey))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .textCase(.uppercase)

            Text(entry.title)
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            if let overview = entry.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(3)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .padding(.horizontal, CalendarMetrics.pageInset)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if entry.isMovie { return L10n.string("calendar_badge_movie", fallback: "Movie") }
        let code = entry.episodeCode ?? ""
        let title = entry.episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !code.isEmpty && !title.isEmpty { return "\(code) · \(title)" }
        return code.isEmpty ? title : code
    }
}

// MARK: - Month grid

/// Accent focus ring.
///
/// Must be placed **inside** a Button's label: tvOS publishes `\.isFocused`
/// into the label's environment, so a view that merely *contains* the button
/// always reads `false` — which is why these rings never appeared.
/// Band identifiers for the macOS keyboard model.
enum CalendarFocusBand {
    static let filters = "filters"
    /// Month mode: the chevrons and Today, then one band per week row.
    static let monthHeader = "month.header"
    static let weekPrefix = "month.week."
    /// Cells for days outside the month. They keep every week band exactly
    /// seven wide so Up/Down holds its weekday column; the caret is nudged off
    /// them because they draw nothing.
    static let blankPrefix = "month.blank."
    /// The slide-out day panel, which owns the keyboard while it is up.
    static let panel = "month.panel"

    static func isBlank(_ item: String) -> Bool { item.hasPrefix(blankPrefix) }
}

private struct FocusRing<Content: View>: View {
    @Environment(\.isFocused) private var environmentFocused
    /// Driven by `MacScreenFocus`; macOS has no focus engine to set the
    /// environment value.
    var macIsFocused = false
    let accentColor: Color
    var cornerRadius: CGFloat = 12
    var lineWidth: CGFloat = 6
    var scale: CGFloat = 1.04
    var fillOnFocus: Color? = nil
    @ViewBuilder let content: Content

    private var isFocused: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return environmentFocused
        #endif
    }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isFocused ? (fillOnFocus ?? .clear) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(accentColor, lineWidth: isFocused ? lineWidth : 0)
            )
            .shadow(color: accentColor.opacity(isFocused ? 0.5 : 0), radius: 14)
            .scaleEffect(isFocused ? scale : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private struct MonthGrid: View {
    let anchor: Date
    @ObservedObject var viewModel: CalendarViewModel
    let accentColor: Color
    /// The macOS caret. There is no focus engine there, so the cells cannot
    /// read `\.isFocused` and the screen hands the position down instead.
    var macFocusedDayKey: String? = nil
    @FocusState.Binding var focusedDayKey: String?
    let onOpenDay: (String) -> Void

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        let layout = CalendarDateFormatting.monthLayout(for: anchor)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: CalendarMetrics.dayCellGap) {
                ForEach(CalendarDateFormatting.weekdaySymbols(), id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: CalendarMetrics.dayCellWidth, alignment: .leading)
                }
            }

            ForEach(Array(layout.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: CalendarMetrics.dayCellGap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            let key = CalendarDayKey.dayKey(year: layout.year, month: layout.month, day: day)
                            DayCell(
                                day: day,
                                entries: viewModel.entries(on: key),
                                isToday: key == CalendarDayKey.dayKey(offsetFromToday: 0),
                                accentColor: accentColor,
                                macIsFocused: macFocusedDayKey == key,
                                action: { onOpenDay(key) }
                            )
                            .nuvioFocusable()
                            .focused($focusedDayKey, equals: key)
                            // AppKit draws its own ring outside the cell's
                            // bounds, which read as a focus box larger than the
                            // day it belongs to. The cell draws its own.
                            .focusEffectDisabledIfAvailable()
                        } else {
                            Color.clear
                                .frame(width: CalendarMetrics.dayCellWidth, height: CalendarMetrics.dayCellHeight)
                        }
                    }
                }
            }
        }
        .focusSection()
        // Land on today (or the month's first populated day) instead of the back
        // chevron, so the grid is immediately navigable.
        .defaultFocusIfAvailable($focusedDayKey, defaultFocusKey(layout))
    }

    /// Today when it is in view, else the first day holding episodes, else the 1st.
    private func defaultFocusKey(_ layout: CalendarDateFormatting.MonthLayout) -> String? {
        let today = CalendarDayKey.dayKey(offsetFromToday: 0)
        let keys = layout.weeks.flatMap { $0 }.compactMap { $0 }
            .map { CalendarDayKey.dayKey(year: layout.year, month: layout.month, day: $0) }
        if keys.contains(today) { return today }
        return keys.first { !viewModel.entries(on: $0).isEmpty } ?? keys.first
    }
}

private struct DayCell: View {
    let day: Int
    let entries: [CalendarEntry]
    let isToday: Bool
    let accentColor: Color
    var macIsFocused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FocusRing(
                macIsFocused: macIsFocused,
                accentColor: accentColor,
                cornerRadius: 10,
                fillOnFocus: .white.opacity(0.16)
            ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // Today reads as a filled chip — light plate, dark numeral —
                    // so it is distinct from the accent ring, which means focus.
                    Text("\(day)")
                        .font(.system(size: 22, weight: isToday ? .bold : .medium))
                        .foregroundColor(isToday ? .black : .white.opacity(0.85))
                        .padding(.horizontal, isToday ? 10 : 0)
                        .frame(height: isToday ? 34 : nil)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isToday ? Color.white : Color.clear)
                        )
                    Spacer(minLength: 0)
                    if entries.count > 1 {
                        Text("\(entries.count)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

                // Up to three posters, sized to fill the height freed by
                // dropping the title row.
                HStack(spacing: 5) {
                    ForEach(entries.prefix(3)) { entry in
                        DayThumb(url: entry.posterUrl ?? entry.imageUrl)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(width: CalendarMetrics.dayCellWidth, height: CalendarMetrics.dayCellHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(entries.isEmpty ? 0.03 : 0.09))
            )
            }
        }
        .buttonStyle(ChromeButtonStyle())
    }
}

private struct DayThumb: View {
    let url: String?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: 62, height: 92)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Chrome background that brightens on focus. tvOS paints an opaque white
/// focus effect over `.plain` buttons, which swamps small controls — these
/// disable it and render their own state instead.
/// No decoration of its own. Built-in tvOS styles (`.plain`, `.card`) draw a
/// focus fill sized to the button rather than the label, which swamped these
/// small controls; focus visuals are handled by the label instead.
private struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct ChromeBackground<Content: View>: View {
    @Environment(\.isFocused) private var environmentFocused
    /// Driven by `MacScreenFocus`; macOS has no focus engine to set the
    /// environment value.
    var macIsFocused = false
    var accentColor: Color = .white
    /// Sized explicitly: inside an HStack the label would otherwise stretch and
    /// paint its focus fill across the neighbouring month title.
    var width: CGFloat? = nil
    var height: CGFloat = 52
    @ViewBuilder let content: Content

    private var isFocused: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return environmentFocused
        #endif
    }

    var body: some View {
        content
            .foregroundColor(isFocused ? .black : .white)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFocused ? accentColor : Color.white.opacity(0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(isFocused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private struct MonthStepButton: View {
    let systemImage: String
    var accentColor: Color = .white
    var macIsFocused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChromeBackground(macIsFocused: macIsFocused, accentColor: accentColor, width: 66) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
            }
        }
        .buttonStyle(ChromeButtonStyle())
        .fixedSize()
    }
}

private struct MonthTodayButton: View {
    var accentColor: Color = .white
    var macIsFocused = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChromeBackground(macIsFocused: macIsFocused, accentColor: accentColor) {
                Text(L10n.string("calendar_today", fallback: "Today"))
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 22)
            }
        }
        .buttonStyle(ChromeButtonStyle())
        .fixedSize()
    }
}


// MARK: - Day panel

/// Slides in from the right with every episode on the selected day.
///
/// A day can hold nine or more episodes, which will not fit inside a grid cell,
/// so selecting a day opens this instead of trying to make each poster in the
/// cell its own focus target. Selecting a row goes straight to that title's
/// details, where a stream can be picked.
private struct DayEntriesPanel: View {
    let dayKey: String
    let entries: [CalendarEntry]
    let accentColor: Color
    /// The macOS caret, handed down for the same reason `MonthGrid` takes one.
    var macFocusedEntryID: String? = nil
    @FocusState.Binding var focusedEntryID: String?
    let onSelect: (CalendarEntry) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Transparent: a second full-screen scrim on top of the panel's own
            // background read as two layers of dark during the slide-in.
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CalendarDateFormatting.heading(for: dayKey))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                    Text(entryCountLabel)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 34)
                .padding(.top, 52)
                .padding(.bottom, 20)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(entries) { entry in
                                DayPanelRow(
                                    entry: entry,
                                    accentColor: accentColor,
                                    macIsFocused: macFocusedEntryID == entry.id
                                ) {
                                    onSelect(entry)
                                }
                                .id(entry.id)
                                .nuvioFocusable()
                                .focused($focusedEntryID, equals: entry.id)
                                .focusEffectDisabledIfAvailable()
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.bottom, 40)
                    }
                    #if os(macOS)
                    // tvOS scrolls the focused row into view by itself. macOS
                    // has no focus engine to do it, so the caret walked off the
                    // bottom of the panel and the rows below it stayed
                    // unreachable however far Down was held.
                    .onChange(of: macFocusedEntryID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    #endif
                }
            }
            .frame(width: 760)
            // tvOS has no `glassEffect` (only Glass *button* styles), so the
            // closest available treatment is a blur material plus a bright
            // leading edge to catch the light.
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.45))
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.04), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 1)
            }
            .ignoresSafeArea()
            .defaultFocusIfAvailable($focusedEntryID, entries.first?.id)
            .task(id: dayKey) {
                // tvOS needs a beat after the panel mounts before focus will
                // take; without this the first row can render unfocused.
                try? await Task.sleep(nanoseconds: 80_000_000)
                if focusedEntryID == nil { focusedEntryID = entries.first?.id }
            }
        }
    }

    private var entryCountLabel: String {
        entries.count == 1
            ? L10n.string("calendar_panel_one", fallback: "1 episode")
            : String(
                format: L10n.string("calendar_panel_many", fallback: "%d episodes"),
                entries.count
            )
    }
}

/// Episode artwork with a fallback chain.
///
/// Cinemeta *constructs* `episodes.metahub.space/<imdb>/<season>/<episode>/w780.jpg`
/// for every episode without checking it exists, so individual episodes 404
/// (verified: The Gentlemen S02E01, Ted Lasso S00E09) while their siblings
/// return real JPEGs. Falling back to the show's backdrop, then its poster,
/// avoids the empty tile those 404s would otherwise leave.
private struct EntryArtwork: View {
    let entry: CalendarEntry
    @State private var attempt = 0

    private var candidates: [String] {
        var out: [String] = []
        for value in [entry.imageUrl, entry.backdropUrl, entry.posterUrl] {
            guard let value, !value.isEmpty, !out.contains(value) else { continue }
            out.append(value)
        }
        return out
    }

    var body: some View {
        ZStack {
            Color.white.opacity(0.07)

            if attempt < candidates.count, let url = URL(string: candidates[attempt]) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        // Advance to the next candidate rather than showing a hole.
                        Color.clear.onAppear { attempt += 1 }
                    default:
                        Color.clear
                    }
                }
                .id(attempt)
            } else {
                Image(systemName: entry.isMovie ? "film" : "tv")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

private struct DayPanelRow: View {
    let entry: CalendarEntry
    let accentColor: Color
    var macIsFocused = false
    let action: () -> Void

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    private var rowCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    var body: some View {
        Button(action: action) {
            FocusRing(
                macIsFocused: macIsFocused,
                accentColor: accentColor,
                cornerRadius: rowCornerRadius,
                scale: 1.02,
                fillOnFocus: .white.opacity(0.14)
            ) {
            HStack(spacing: 18) {
                EntryArtwork(entry: entry)
                .frame(width: 178, height: 100)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: max(rowCornerRadius - 4, 4), style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            }
        }
        .buttonStyle(ChromeButtonStyle())
    }

    private var subtitle: String {
        if entry.isMovie { return L10n.string("calendar_badge_movie", fallback: "Movie") }
        let code = entry.episodeCode ?? ""
        let title = entry.episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !code.isEmpty && !title.isEmpty { return "\(code) · \(title)" }
        return code.isEmpty ? title : code
    }
}

// MARK: - Cards

/// One episode/movie card. tvOS gives `.card` buttons their own focus scale and
/// shadow, so the card only supplies the artwork and caption.
private struct CalendarEntryCard: View {
    let entry: CalendarEntry
    var accentColor: Color = .white
    var macIsFocused = false
    let action: () -> Void

    /// Same radius every other card in the app uses. Hardcoding 12 here made
    /// the accent ring disagree with the artwork corners, which read as broken.
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    var body: some View {
        // Artwork-only card with the label beneath it, matching Home, Search and
        // Library. Previously the caption lived *inside* the button, so `.card`
        // painted its own background behind the text and the tile read as two
        // mismatched blocks.
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                FocusRing(
                    macIsFocused: macIsFocused,
                    accentColor: accentColor,
                    cornerRadius: cardCornerRadius,
                    scale: 1.0
                ) {
                    artwork
                }
            }
            #if os(macOS)
            .buttonStyle(PosterCardButtonStyle())
            #else
            .buttonStyle(.card)
            #endif

            caption
        }
        .frame(width: CalendarMetrics.cardWidth, alignment: .leading)
    }

    private var artwork: some View {
        EntryArtwork(entry: entry)
        .frame(width: CalendarMetrics.cardWidth, height: CalendarMetrics.cardImageHeight)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            if let code = entry.episodeCode {
                badge(code)
            } else if entry.isMovie {
                badge(L10n.string("calendar_badge_movie", fallback: "Movie"))
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.65), in: Capsule())
            .padding(10)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 19))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(width: CalendarMetrics.cardWidth, alignment: .leading)
    }

    private var subtitle: String {
        if entry.isMovie {
            return L10n.string("calendar_movie_release", fallback: "Release date")
        }
        let episodeTitle = entry.episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let episodeTitle, !episodeTitle.isEmpty { return episodeTitle }
        return entry.episodeCode ?? ""
    }
}

// MARK: - Formatting

/// Day-heading strings and month layout. Kept separate so the date maths stays
/// testable and out of the view bodies.
enum CalendarDateFormatting {
    private static let headingFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter
    }()

    /// "Today" / "Tomorrow" / "Yesterday" where it reads better, otherwise a
    /// localized weekday-and-date heading.
    static func heading(for dayKey: String) -> String {
        if let offset = dayOffset(for: dayKey) {
            switch offset {
            case 0: return L10n.string("calendar_today", fallback: "Today")
            case 1: return L10n.string("calendar_tomorrow", fallback: "Tomorrow")
            case -1: return L10n.string("calendar_yesterday", fallback: "Yesterday")
            default: break
            }
        }
        guard let date = CalendarDayKey.date(fromDayKey: dayKey) else { return dayKey }
        return headingFormatter.string(from: date)
    }

    /// The plain date alongside a relative heading, so "Today" still says which
    /// day it is. Nil when the heading already carries the date.
    static func relativeSuffix(for dayKey: String) -> String? {
        guard let offset = dayOffset(for: dayKey), (-1...1).contains(offset) else { return nil }
        guard let date = CalendarDayKey.date(fromDayKey: dayKey) else { return nil }
        return headingFormatter.string(from: date)
    }

    /// Hero eyebrow: the relative word and the date together.
    static func heroDateLine(for dayKey: String) -> String {
        let head = heading(for: dayKey)
        if let suffix = relativeSuffix(for: dayKey) { return "\(head) · \(suffix)" }
        return head
    }

    static func monthTitle(for date: Date) -> String {
        monthFormatter.string(from: date)
    }

    static func isSameMonth(_ a: Date, _ b: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.component(.year, from: a) == calendar.component(.year, from: b)
            && calendar.component(.month, from: a) == calendar.component(.month, from: b)
    }

    /// Localized short weekday names, rotated to the locale's first weekday.
    static func weekdaySymbols() -> [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    struct MonthLayout {
        let year: Int
        let month: Int
        /// Rows of seven; nil marks a padding cell outside this month.
        let weeks: [[Int?]]
    }

    /// Splits a month into week rows honouring the locale's first weekday.
    static func monthLayout(for date: Date) -> MonthLayout {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)

        var components = DateComponents()
        components.year = year; components.month = month; components.day = 1
        guard let firstOfMonth = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return MonthLayout(year: year, month: month, weeks: [])
        }

        // Offset of the 1st from the locale's first weekday.
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7

        var cells: [Int?] = Array(repeating: nil, count: leading)
        cells.append(contentsOf: range.map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }

        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
        return MonthLayout(year: year, month: month, weeks: weeks)
    }

    /// Whole days from today, in the viewer's calendar.
    static func dayOffset(for dayKey: String) -> Int? {
        guard let target = CalendarDayKey.date(fromDayKey: dayKey) else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: target)
        ).day
    }
}

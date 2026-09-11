import Foundation
import Combine

/// How the Calendar tab presents its data. Persisted as the raw value under
/// `SettingsKey.calendarViewMode`.
enum CalendarViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case month = "Month"

    var id: String { rawValue }

    static func from(_ rawValue: String?) -> CalendarViewMode {
        guard let rawValue, let mode = CalendarViewMode(rawValue: rawValue) else { return .list }
        return mode
    }
}

/// What a calendar entry represents. Sports are a genuinely different shape —
/// live fixtures rather than a followed title's episode guide — so they are
/// fetched and filtered separately.
enum CalendarKind: String, Hashable {
    case series, movie, sport
}

/// Calendar tab filter. Shows is the default because the tab began as an
/// episode guide for followed series.
enum CalendarFilter: String, CaseIterable, Identifiable {
    case shows, movies, sports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shows:  return L10n.string("calendar_filter_shows", fallback: "Shows")
        case .movies: return L10n.string("calendar_filter_movies", fallback: "Movies")
        case .sports: return L10n.string("calendar_filter_sports", fallback: "Sports")
        }
    }

    var kind: CalendarKind {
        switch self {
        case .shows:  return .series
        case .movies: return .movie
        case .sports: return .sport
        }
    }
}

/// A single dated row entry: an episode of a followed series, or a movie
/// release. Built from add-on metadata the app already fetches, so the Calendar
/// needs no extra account or API key.
struct CalendarEntry: Identifiable, Hashable {
    let id: String
    let metaId: String
    /// Type to hand back to details routing (`series` / `movie`).
    let type: String
    let title: String
    let posterUrl: String?
    /// Episode still when the add-on supplies one; falls back to the show's
    /// backdrop, then its poster.
    let imageUrl: String?
    /// Show backdrop, used by the hero behind the Calendar.
    let backdropUrl: String?
    let logoUrl: String?
    let overview: String?
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    /// `yyyy-MM-dd` in the release's own calendar day. Grouping key.
    let dayKey: String
    let kind: CalendarKind
    /// Sport fixtures carry their competition ("Football", "Fight") for grouping.
    var sportGenre: String? = nil
    /// True for a fixture the add-on reports as in progress right now.
    var isLiveNow: Bool = false

    var isMovie: Bool { kind == .movie }

    /// `S01E05`, or nil for movies and for episodes missing numbering.
    var episodeCode: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }
}

/// One day's worth of entries.
struct CalendarDay: Identifiable, Hashable {
    /// `yyyy-MM-dd`.
    let id: String
    let entries: [CalendarEntry]
}

/// Builds an upcoming-releases calendar from the titles the user actually
/// follows: everything in the Library plus anything in Continue Watching.
///
/// Deliberately local-first — it reuses `CatalogRepository.getMetadata`, so it
/// works against whatever add-ons are installed and needs no Trakt/Simkl/TMDB
/// credentials. Titles the user has not saved never appear.
@MainActor
final class CalendarViewModel: ObservableObject {
    /// Every entry kept in memory, keyed by day. Month browsing reads straight
    /// from this, so paging back and forward costs no extra network work.
    @Published private(set) var entriesByDay: [String: [CalendarEntry]] = [:]

    /// Kept apart by source. `load()` replaces the Library-derived set on every
    /// Calendar appearance, and merging everything into one store meant that
    /// pass silently wiped the sports fixtures and upcoming movies.
    private var libraryDays: [String: [CalendarEntry]] = [:]
    private var sportsDays: [String: [CalendarEntry]] = [:]
    private var upcomingMovieDays: [String: [CalendarEntry]] = [:]

    /// Recombines the three sources. Library entries win on a duplicate title:
    /// they carry the user's own artwork and metadata.
    private func rebuildEntries() {
        var merged = libraryDays
        for source in [sportsDays, upcomingMovieDays] {
            for (day, entries) in source {
                var existing = merged[day] ?? []
                let knownIds = Set(existing.map(\.id))
                let knownMovieMetaIds = Set(
                    existing.filter { $0.kind == .movie }.map(\.metaId)
                )
                existing.append(contentsOf: entries.filter { entry in
                    guard !knownIds.contains(entry.id) else { return false }
                    if entry.kind == .movie, knownMovieMetaIds.contains(entry.metaId) { return false }
                    return true
                })
                merged[day] = existing
            }
        }
        entriesByDay = merged
    }
    /// Independently toggleable, so any combination is possible. Persisted per
    /// profile so the choice survives relaunches.
    @Published var filters: Set<CalendarFilter> = CalendarViewModel.loadFilters() {
        didSet {
            guard oldValue != filters else { return }
            Self.saveFilters(filters)
            fetchForSelectedFilters()
        }
    }

    /// Kinds currently on screen.
    var activeKinds: Set<CalendarKind> { Set(filters.map(\.kind)) }

    /// Toggle. Every filter may be switched off: an empty calendar is a valid
    /// thing to ask for, and the page says so rather than looking broken.
    func toggle(_ option: CalendarFilter) {
        var updated = filters
        if updated.contains(option) {
            updated.remove(option)
        } else {
            updated.insert(option)
        }
        filters = updated
    }

    /// Competition narrowing the Sports filter, or nil for all of them.
    /// Persisted per profile so the choice survives relaunches.
    @Published var selectedSportGenre: String? = CalendarViewModel.loadSelectedSportGenre() {
        didSet {
            guard oldValue != selectedSportGenre else { return }
            Self.saveSelectedSportGenre(selectedSportGenre)
        }
    }

    /// Every competition present in the loaded fixtures. Comes from the fixtures
    /// themselves rather than a fixed list, so it follows whatever the installed
    /// add-ons publish.
    var availableSportGenres: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entries in sportsDays.values {
            for entry in entries {
                guard let genre = entry.sportGenre, !genre.isEmpty else { continue }
                if seen.insert(genre).inserted { result.append(genre) }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Kind filter plus, for fixtures, the chosen competition.
    private func matches(_ entry: CalendarEntry) -> Bool {
        guard activeKinds.contains(entry.kind) else { return false }
        guard entry.kind == .sport, let wanted = selectedSportGenre else { return true }
        return entry.sportGenre == wanted
    }

    private static let selectedSportGenreKey =
        "nuvio.tv.settings.layout.calendarSportGenre"

    private static func loadSelectedSportGenre() -> String? {
        guard let raw = ProfileSettings.current.string(forKey: selectedSportGenreKey),
              !raw.isEmpty else { return nil }
        return raw
    }

    private static func saveSelectedSportGenre(_ genre: String?) {
        ProfileSettings.current.set(genre ?? "", forKey: selectedSportGenreKey)
    }

    private func fetchForSelectedFilters() {
        if filters.contains(.sports), !hasLoadedSports {
            Task { await loadSports() }
        }
        if filters.contains(.movies), !hasLoadedUpcomingMovies {
            Task { await loadUpcomingMovies() }
        }
    }

    private static let filtersKey = "nuvio.tv.settings.layout.calendarFilters"

    private static func loadFilters() -> Set<CalendarFilter> {
        // No stored value at all is first run, which defaults to Shows. A stored
        // *empty* value is the user having switched everything off, and has to
        // survive a relaunch rather than snapping back to the default.
        guard let raw = ProfileSettings.current.string(forKey: filtersKey) else { return [.shows] }
        if raw.isEmpty { return [] }
        return Set(raw.split(separator: ",").compactMap { CalendarFilter(rawValue: String($0)) })
    }

    private static func saveFilters(_ filters: Set<CalendarFilter>) {
        let raw = filters.map(\.rawValue).sorted().joined(separator: ",")
        ProfileSettings.current.set(raw, forKey: filtersKey)
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingSports = false
    @Published private(set) var isLoadingMovies = false
    private var hasLoadedSports = false
    private var hasLoadedUpcomingMovies = false
    /// True once a load has finished, so the view can tell "still loading"
    /// apart from "genuinely nothing scheduled".
    @Published private(set) var hasLoaded = false

    /// How far back recently-aired episodes stay visible in **list** mode.
    static let pastWindowDays = 7
    /// How far ahead list mode looks.
    static let futureWindowDays = 90
    /// How much either side is retained for **month** browsing. A series'
    /// episode guide arrives whole, so keeping a wider span costs only memory
    /// and lets the user page through months without refetching.
    static let archiveWindowDays = 420
    /// Metadata fetches in flight at once. Each is one add-on HTTP request and
    /// a cold Library can hold dozens of titles.
    private static let maxConcurrentFetches = 6

    private let repository: CatalogRepository
    private var libraryObserver: NSObjectProtocol?
    private var loadGeneration = 0

    init(repository: CatalogRepository = CinemetaCatalogRepository()) {
        self.repository = repository
        fetchForSelectedFilters()
        libraryObserver = NotificationCenter.default.addObserver(
            forName: LibraryStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.load() }
        }
    }

    deinit {
        if let libraryObserver {
            NotificationCenter.default.removeObserver(libraryObserver)
        }
    }

    // MARK: - Projections

    /// Day-grouped entries for list mode: recent past through the near future.
    var days: [CalendarDay] {
        let lower = CalendarDayKey.dayKey(offsetFromToday: -Self.pastWindowDays)
        let upper = CalendarDayKey.dayKey(offsetFromToday: Self.futureWindowDays)
        return entriesByDay
            .filter { $0.key >= lower && $0.key <= upper }
            .compactMap { key, value -> CalendarDay? in
                let matching = value.filter { matches($0) }
                return matching.isEmpty ? nil : CalendarDay(id: key, entries: matching)
            }
            .sorted { $0.id < $1.id }
    }

    /// Entries on one calendar day, for the month grid.
    func entries(on dayKey: String) -> [CalendarEntry] {
        (entriesByDay[dayKey] ?? []).filter { matches($0) }
    }

    /// Whether anything at all is scheduled in the given month, so the grid can
    /// hint that paging further is worthwhile.
    func hasEntries(inMonthPrefix prefix: String) -> Bool {
        entriesByDay.contains { key, value in
            key.hasPrefix(prefix) && value.contains { matches($0) }
        }
    }

    /// The titles worth asking about: Library first (explicit intent), then any
    /// Continue Watching entry not already covered.
    private func followedTitles() -> [(id: String, type: String, meta: NuvioMeta)] {
        var seen: Set<String> = []
        var result: [(id: String, type: String, meta: NuvioMeta)] = []

        func append(_ meta: NuvioMeta) {
            let key = "\(meta.id)|\(meta.type)"
            guard seen.insert(key).inserted else { return }
            result.append((id: meta.id, type: meta.type, meta: meta))
        }

        for item in LibraryStore.items() { append(item.meta) }
        for item in ContinueWatchingStore.items() { append(item.meta) }
        return result
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true

        let titles = followedTitles()
        guard !titles.isEmpty else {
            libraryDays = [:]
            rebuildEntries()
            isLoading = false
            hasLoaded = true
            return
        }

        let lowerBound = CalendarDayKey.dayKey(offsetFromToday: -Self.archiveWindowDays)
        let upperBound = CalendarDayKey.dayKey(offsetFromToday: Self.archiveWindowDays)
        let repository = self.repository

        let collected: [CalendarEntry] = await withTaskGroup(
            of: [CalendarEntry].self
        ) { group in
            var index = 0
            var entries: [CalendarEntry] = []

            func addTask(for title: (id: String, type: String, meta: NuvioMeta)) {
                group.addTask {
                    await Self.entries(
                        for: title.meta,
                        id: title.id,
                        type: title.type,
                        repository: repository,
                        lowerBound: lowerBound,
                        upperBound: upperBound
                    )
                }
            }

            while index < min(Self.maxConcurrentFetches, titles.count) {
                addTask(for: titles[index])
                index += 1
            }

            for await produced in group {
                entries.append(contentsOf: produced)
                if index < titles.count {
                    addTask(for: titles[index])
                    index += 1
                }
            }
            return entries
        }

        // A newer load started while this one was in flight.
        guard generation == loadGeneration else { return }

        libraryDays = Self.group(collected)
        rebuildEntries()
        isLoading = false
        hasLoaded = true
    }



    // MARK: - Upcoming movies

    /// Catalog ids/names that mean "not out yet, or only just out".
    private static let upcomingCatalogHints = [
        "upcoming", "coming soon", "comingsoon", "in theaters", "in theatres",
        "now playing", "now_playing", "latest release", "new release"
    ]

    /// Builds a "coming soon" movie schedule from installed add-on catalogs.
    ///
    /// Library movies alone are far too thin — a movie has to already be saved
    /// *and* unreleased to appear. Add-ons that aggregate release calendars
    /// (verified: an "Upcoming" catalog returning 50 titles with full
    /// `released` timestamps) give a real schedule without needing a Rotten
    /// Tomatoes or IMDb key of our own. Titles route to the normal details
    /// page, so a stream attaches automatically once one exists.
    func loadUpcomingMovies() async {
        guard !isLoadingMovies else { return }
        isLoadingMovies = true
        defer { isLoadingMovies = false }

        let catalogs = await repository.availableAddonCatalogs().filter { option in
            guard option.type.lowercased() == "movie" else { return false }
            let haystack = "\(option.catalogId) \(option.catalogName)".lowercased()
            return Self.upcomingCatalogHints.contains { haystack.contains($0) }
        }
        guard !catalogs.isEmpty else { hasLoadedUpcomingMovies = true; return }

        let repository = self.repository
        let lower = CalendarDayKey.dayKey(offsetFromToday: -Self.archiveWindowDays)
        let upper = CalendarDayKey.dayKey(offsetFromToday: Self.archiveWindowDays)

        let collected: [CalendarEntry] = await withTaskGroup(of: [CalendarEntry].self) { group in
            var index = 0
            var out: [CalendarEntry] = []

            func addTask(_ option: AddonCatalogOption) {
                group.addTask {
                    guard let page = try? await repository.browseCatalog(
                        addonId: option.addonId,
                        contentType: option.type,
                        catalogId: option.catalogId,
                        skip: 0,
                        genre: nil
                    ) else { return [] }
                    return page.items.compactMap { meta in
                        guard let day = CalendarDayKey.dayKey(from: meta.released),
                              day >= lower, day <= upper else { return nil }
                        return CalendarEntry(
                            id: "upcoming|\(meta.id)",
                            metaId: meta.id,
                            type: meta.type,
                            title: meta.name,
                            posterUrl: meta.posterUrl,
                            imageUrl: meta.backgroundUrl ?? meta.posterUrl,
                            backdropUrl: meta.backgroundUrl,
                            logoUrl: meta.logoUrl,
                            overview: meta.description,
                            season: nil,
                            episode: nil,
                            episodeTitle: nil,
                            dayKey: day,
                            kind: .movie
                        )
                    }
                }
            }

            while index < min(Self.maxConcurrentFetches, catalogs.count) {
                addTask(catalogs[index]); index += 1
            }
            for await produced in group {
                out.append(contentsOf: produced)
                if index < catalogs.count { addTask(catalogs[index]); index += 1 }
            }
            return out
        }

        upcomingMovieDays = Self.group(collected)
        rebuildEntries()
        hasLoadedUpcomingMovies = true
    }

    // MARK: - Sports fixtures

    /// Loads dated fixtures from every installed add-on that publishes `sport`
    /// catalogs (football, fight, basketball, rugby, cricket, motor sports …).
    ///
    /// Unlike shows and movies these are not tied to the user's Library — they
    /// are a live schedule — so they load on demand the first time Sports is
    /// selected rather than on every Calendar visit.
    func loadSports() async {
        guard !isLoadingSports else { return }
        isLoadingSports = true
        defer { isLoadingSports = false }

        let catalogs = await repository.availableAddonCatalogs()
            .filter { $0.type.lowercased() == "sport" || $0.type.lowercased() == "sports" }
        guard !catalogs.isEmpty else { hasLoadedSports = true; return }

        let repository = self.repository
        let collected: [CalendarEntry] = await withTaskGroup(of: [CalendarEntry].self) { group in
            var index = 0
            var out: [CalendarEntry] = []

            func addTask(_ option: AddonCatalogOption) {
                group.addTask {
                    guard let page = try? await repository.browseCatalog(
                        addonId: option.addonId,
                        contentType: option.type,
                        catalogId: option.catalogId,
                        skip: 0,
                        genre: nil
                    ) else { return [] }
                    return page.items.compactMap { Self.sportEntry(from: $0, catalog: option) }
                }
            }

            while index < min(Self.maxConcurrentFetches, catalogs.count) {
                addTask(catalogs[index]); index += 1
            }
            for await produced in group {
                out.append(contentsOf: produced)
                if index < catalogs.count { addTask(catalogs[index]); index += 1 }
            }
            return out
        }

        sportsDays = Self.group(collected)
        rebuildEntries()
        hasLoadedSports = true
    }

    /// Maps one fixture to a dated entry.
    ///
    /// Sports add-ons put the kick-off in `releaseInfo` as `07 Sep 2026 · 00:00
    /// UTC`, or the literal `LIVE` for something already in progress — there is
    /// no `released` field to read, so this is the only date source.
    nonisolated private static func sportEntry(
        from meta: NuvioMeta,
        catalog: AddonCatalogOption
    ) -> CalendarEntry? {
        let info = meta.releaseInfo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isLive = info.uppercased() == "LIVE"
        guard let day = isLive
            ? CalendarDayKey.dayKey(offsetFromToday: 0)
            : CalendarDayKey.dayKey(fromFixtureInfo: info)
        else { return nil }

        // The first genre is the competition; the second is usually a channel slug.
        let sport = meta.genres?.first(where: { !$0.contains("-") })

        return CalendarEntry(
            id: "sport|\(catalog.addonId)|\(meta.id)",
            metaId: meta.id,
            type: meta.type,
            title: meta.name,
            posterUrl: meta.posterUrl,
            imageUrl: meta.backgroundUrl ?? meta.posterUrl,
            backdropUrl: meta.backgroundUrl,
            logoUrl: meta.logoUrl,
            overview: meta.description,
            season: nil,
            episode: nil,
            episodeTitle: nil,
            dayKey: day,
            kind: .sport,
            sportGenre: sport ?? catalog.catalogName,
            isLiveNow: isLive
        )
    }

    /// Episodes (or the release date, for a movie) that fall inside the window.
    private static func entries(
        for cachedMeta: NuvioMeta,
        id: String,
        type: String,
        repository: CatalogRepository,
        lowerBound: String,
        upperBound: String
    ) async -> [CalendarEntry] {
        // A movie needs no episode guide — the cached release date is enough.
        if !cachedMeta.isSeries {
            guard let day = CalendarDayKey.dayKey(from: cachedMeta.released),
                  day >= lowerBound, day <= upperBound else { return [] }
            return [
                CalendarEntry(
                    id: "\(id)|movie",
                    metaId: id,
                    type: type,
                    title: cachedMeta.name,
                    posterUrl: cachedMeta.posterUrl,
                    imageUrl: cachedMeta.backgroundUrl ?? cachedMeta.posterUrl,
                    backdropUrl: cachedMeta.backgroundUrl,
                    logoUrl: cachedMeta.logoUrl,
                    overview: cachedMeta.description,
                    season: nil,
                    episode: nil,
                    episodeTitle: nil,
                    dayKey: day,
                    kind: .movie
                )
            ]
        }

        // Library snapshots store a compact meta without `videos`, so the
        // episode guide has to be fetched (the repository caches it).
        let meta: NuvioMeta
        if let videos = cachedMeta.videos, !videos.isEmpty {
            meta = cachedMeta
        } else if let fetched = try? await repository.getMetadata(id: id, type: type) {
            meta = fetched
        } else {
            return []
        }

        guard let videos = meta.videos else { return [] }

        return videos.compactMap { video -> CalendarEntry? in
            guard let day = CalendarDayKey.dayKey(from: video.released),
                  day >= lowerBound,
                  day <= upperBound else { return nil }
            return CalendarEntry(
                id: "\(id)|\(video.id)",
                metaId: id,
                type: type,
                title: meta.name,
                posterUrl: meta.posterUrl,
                imageUrl: video.thumbnail ?? meta.backgroundUrl ?? meta.posterUrl,
                backdropUrl: meta.backgroundUrl,
                logoUrl: meta.logoUrl,
                overview: video.overview ?? meta.description,
                season: video.season,
                episode: video.episode,
                episodeTitle: video.title,
                dayKey: day,
                kind: .series
            )
        }
    }

    /// Groups by day, sorted within a day so a multi-episode drop reads in order.
    private static func group(_ entries: [CalendarEntry]) -> [String: [CalendarEntry]] {
        // A series can legitimately appear twice for the same slot across
        // Library and Continue Watching; entry ids make that collapse.
        var unique: [String: CalendarEntry] = [:]
        for entry in entries { unique[entry.id] = entry }

        return Dictionary(grouping: unique.values, by: \.dayKey)
            .mapValues { items in
                items.sorted {
                    if $0.title != $1.title { return $0.title < $1.title }
                    if ($0.season ?? 0) != ($1.season ?? 0) {
                        return ($0.season ?? 0) < ($1.season ?? 0)
                    }
                    return ($0.episode ?? 0) < ($1.episode ?? 0)
                }
            }
    }
}

/// Day-key maths, kept out of `CalendarViewModel` so it stays nonisolated: the
/// view formats headings synchronously and would otherwise be calling
/// main-actor-isolated members from a nonisolated context.
enum CalendarDayKey {

    /// Calendar-day key for a release string.
    ///
    /// A date-only value like `2026-08-13` is a statement about a calendar day,
    /// not an instant, so it is taken verbatim rather than pushed through a time
    /// zone — the same reasoning as `EpisodeReleasePolicy.hasAired`. Only a full
    /// timestamp gets converted, and then into the viewer's local day.
    static func dayKey(from released: String?) -> String? {
        guard let raw = released?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if raw.count >= 10 {
            let candidate = String(raw.prefix(10))
            if isDayKey(candidate) {
                // Date-only: keep the stated day.
                if raw.count == 10 { return candidate }
                // Full timestamp: convert to the viewer's local day.
                if let date = EpisodeReleasePolicy.releaseDate(for: raw) {
                    return dayKey(from: date)
                }
                return candidate
            }
        }

        guard let date = EpisodeReleasePolicy.releaseDate(for: raw) else { return nil }
        return dayKey(from: date)
    }

    private static func isDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(from date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    static func dayKey(offsetFromToday days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return dayKey(from: date)
    }

    /// Parses a sports add-on's `releaseInfo`, e.g. `07 Sep 2026 · 00:00 UTC`.
    /// Converted into the viewer's local day, since a UTC kick-off can land on
    /// the neighbouring date locally.
    static func dayKey(fromFixtureInfo info: String) -> String? {
        let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in fixtureFormatters {
            if let date = formatter.date(from: trimmed) { return dayKey(from: date) }
        }
        return nil
    }

    private static let fixtureFormatters: [DateFormatter] = {
        ["dd MMM yyyy · HH:mm 'UTC'", "dd MMM yyyy · HH:mm", "dd MMM yyyy"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            return formatter
        }
    }()

    /// `yyyy-MM` prefix, for "does this month hold anything" checks.
    static func monthPrefix(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    static func dayKey(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Parses a day key back to local noon — noon, not midnight, so DST shifts
    /// cannot tip the value into the neighbouring day when it is formatted.
    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return Calendar.current.date(from: components)
    }
}

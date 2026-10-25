import Foundation
import Combine

/// Content-type filter for the search screen.
enum SearchContentType: String, CaseIterable, Identifiable {
    case all, movie, series, live, adult
    var id: String { rawValue }

    /// The filters on offer: Adult only while Search's 18+ toggle is on.
    @MainActor
    static var visibleCases: [SearchContentType] {
        NSFWVisibility.shared.showsInSearch ? allCases : allCases.filter { $0 != .adult }
    }

    /// Where a search starts: within the Discover type the viewer chose, so
    /// picking Tube and typing searches Tube's kind of thing. Types with no
    /// filter of their own (Anime, Other) and no choice at all start on All.
    @MainActor
    static func scope(forDiscoverType raw: String?) -> SearchContentType {
        guard let raw = raw?.lowercased() else { return .all }
        switch raw {
        case "movie": return .movie
        case "series": return .series
        default:
            if isLiveFilterType(raw) { return .live }
            if AdultContent.shared.isAdult(id: "", type: raw) {
                return NSFWVisibility.shared.showsInSearch ? .adult : .all
            }
            return .all
        }
    }

    /// Live TV: channels (IPTV and add-on TV) and sports add-ons' matches.
    static func isLiveFilterType(_ type: String) -> Bool {
        let lowered = type.lowercased()
        return CinemetaCatalogRepository.isLiveSearchType(lowered) || lowered == "sport" || lowered == "sports"
    }

    /// Whether a result belongs under this filter. 18+ results sit under
    /// Adult only, not also under Movies (Porn Tube's scenes are "movie").
    @MainActor
    func includes(_ meta: NuvioMeta) -> Bool {
        let adult = AdultContent.shared.isAdult(meta)
        switch self {
        case .all: return true
        case .movie: return !adult && meta.type == "movie"
        case .series: return !adult && meta.type == "series"
        case .live: return !adult && Self.isLiveFilterType(meta.type)
        case .adult: return adult
        }
    }

    var title: String {
        switch self {
        case .all:
            return L10n.string("library_type_all", fallback: "All")
        case .movie:
            return L10n.string("type_movies", fallback: L10n.string("type_movie", fallback: "Movies"))
        case .series:
            return L10n.string("type_series_plural", fallback: L10n.string("type_series", fallback: "Series"))
        case .live:
            return L10n.string("search_type_live_tv", fallback: "Live TV")
        case .adult:
            return L10n.string("search_type_adult", fallback: "Adult")
        }
    }
}

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [NuvioMeta] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedType: SearchContentType = .all
    @Published var recentSearches: [String] = []
    /// Last focused result card, kept here (outside the view, like
    /// `TVHomeStore.lastFocusedCardID`) so it survives the details push and
    /// returning restores that card instead of snapping to the first result.
    var lastFocusedResultID: String?

    private let repository: CatalogRepository
    private var allResults: [NuvioMeta] = []
    private var cancellables = Set<AnyCancellable>()
    private var hadQuery = false
    private var searchTask: Task<Void, Never>?
    /// Runs after the raw search grid is visible: refreshes the top results'
    /// full `/meta` records so artwork and watched state match Discovery.
    /// Cancelled on every new query so stale enrichment can never be applied.
    private var enrichmentTask: Task<Void, Never>?
    /// Small in-memory cache makes repeated queries (including backspacing)
    /// instantaneous without keeping stale search data on disk. Stores the
    /// enriched results once the background enrichment finishes.
    private var cachedResults: [String: [NuvioMeta]] = [:]
    private var cacheOrder: [String] = []
    private let recentKey = "nuvio.search.recent"

    init(repository: CatalogRepository = CinemetaCatalogRepository()) {
        self.repository = repository
        recentSearches = UserDefaults.standard.stringArray(forKey: recentKey) ?? []

        $searchText
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] text in
                self?.handleQueryChange(text)
            }
            .store(in: &cancellables)

        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performSearch(query: text)
            }
            .store(in: &cancellables)

        NSFWVisibility.shared.$showsInSearch
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shown in
                guard let self else { return }
                if !shown, self.selectedType == .adult { self.selectedType = .all }
                self.applyFilter()
            }
            .store(in: &cancellables)
    }

    var hasQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleQueryChange(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A new search starts within the Discover type the viewer chose.
        if !trimmed.isEmpty, !hadQuery {
            selectedType = SearchContentType.scope(forDiscoverType: DiscoverViewModel.chosenType)
        }
        hadQuery = !trimmed.isEmpty
        guard !trimmed.isEmpty else {
            searchTask?.cancel()
            enrichmentTask?.cancel()
            allResults = []
            results = []
            error = nil
            isLoading = false
            return
        }

        let cacheKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let cached = cachedResults[cacheKey] {
            allResults = cached
            applyFilter()
            error = nil
            isLoading = false
            return
        }

        // Cancel pending tasks and immediately enter loading state while debouncing
        // so the UI does not flash "No Results" before the search runs.
        searchTask?.cancel()
        enrichmentTask?.cancel()
        isLoading = true
        error = nil
    }

    func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        searchTask?.cancel()
        enrichmentTask?.cancel()

        guard !trimmed.isEmpty else {
            allResults = []
            results = []
            error = nil
            isLoading = false
            return
        }

        if let cached = cachedResults[cacheKey] {
            allResults = cached
            applyFilter()
            error = nil
            isLoading = false
            if SearchResultEnrichment.hasIncompleteLeadingResults(cached) {
                enrich(cached, cacheKey: cacheKey)
            }
            return
        }

        isLoading = true
        error = nil

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.repository.search(query: trimmed)
                if Task.isCancelled { return }
                self.allResults = found
                self.cache(found, for: cacheKey)
                self.applyFilter()
                if !found.isEmpty { self.commitRecentSearch(trimmed) }
                self.isLoading = false
                if SearchResultEnrichment.hasIncompleteLeadingResults(found) {
                    self.enrich(found, cacheKey: cacheKey)
                }
            } catch {
                if Task.isCancelled { return }
                self.error = "Couldn’t complete search. Check your connection and try again."
                self.isLoading = false
            }
        }
    }

    /// Refreshes the top raw results with their full `/meta` records without
    /// blocking the grid already on screen, then swaps them into `allResults`
    /// (and the filter) and the query cache. Cancelled whenever the query
    /// changes; the query-key guard is a second line of defense against a
    /// stale enrichment landing on a newer result list.
    @MainActor
    private func enrich(_ found: [NuvioMeta], cacheKey: String) {
        enrichmentTask?.cancel()
        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            let enriched = await SearchResultEnrichment.enrich(
                found,
                repository: self.repository
            )
            guard !Task.isCancelled,
                  self.normalizedQuery() == cacheKey else { return }
            self.allResults = enriched
            self.cache(enriched, for: cacheKey)
            self.applyFilter()
        }
    }

    private func normalizedQuery() -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func setType(_ type: SearchContentType) {
        selectedType = type
        applyFilter()
    }

    private func applyFilter() {
        // 18+ titles only while Search's NSFW toggle is on (this session).
        let allowed = NSFWVisibility.shared.searchFiltered(allResults)
        let filter = selectedType
        results = allowed.filter { filter.includes($0) }
    }

    /// Past searches containing what is typed so far, best first: this
    /// device's recent searches, then the other queries searched this
    /// session (their results are still in memory). All of the recent ones
    /// while nothing is typed.
    var matchingRecentSearches: [String] {
        func folded(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let typed = folded(searchText)
        guard !typed.isEmpty else { return recentSearches }
        var seen = Set<String>([typed])
        return (recentSearches + cacheOrder.reversed())
            .filter { folded($0).contains(typed) && seen.insert(folded($0)).inserted }
            .prefix(6)
            .map { $0 }
    }

    func applyRecent(_ term: String) {
        searchText = term
    }

    func clearRecent() {
        recentSearches = []
        saveRecent()
    }

    /// Re-reads the shared recent-search list. `NetflixSearchViewModel` writes
    /// the same key, so whichever search style isn't on screen goes stale until
    /// its view reappears.
    func reloadRecent() {
        recentSearches = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    func clear() {
        searchText = ""
    }

    private func commitRecentSearch(_ term: String) {
        var list = recentSearches.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        recentSearches = Array(list.prefix(8))
        saveRecent()
    }

    private func saveRecent() {
        UserDefaults.standard.set(recentSearches, forKey: recentKey)
    }

    private func cache(_ results: [NuvioMeta], for key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        cachedResults[key] = results

        while cacheOrder.count > 12 {
            cachedResults.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

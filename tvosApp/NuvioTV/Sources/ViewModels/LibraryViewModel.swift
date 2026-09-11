import Foundation
import Combine

@MainActor
public class LibraryViewModel: ObservableObject {
    @Published public var items: [StremioMeta] = []
    @Published public var sortOption: SortOption = .dateAdded
    @Published public var groupOption: GroupOption = .none
    @Published public var contentTypeFilter: String?
    @Published public var genreFilter: String?
    @Published public var watchedFilter: WatchedFilter = .all
    /// Last focused card, kept here (outside the view, like
    /// `TVHomeStore.lastFocusedCardID`) so it survives the details push and
    /// returning restores that card instead of snapping to the top.
    public var lastFocusedItemID: String?
    private var libraryObserver: NSObjectProtocol?
    private var traktAuthObserver: NSObjectProtocol?
    private var simklAuthObserver: NSObjectProtocol?
    private var traktSettingsObserver: NSObjectProtocol?
    private var traktMutationObserver: NSObjectProtocol?
    private var displayedSource: TraktLibrarySourceMode?
    private var refreshGeneration = 0
    private let repository: CatalogRepository = CinemetaCatalogRepository()
    
    public enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded = "Date Added"
        case lastWatched = "Last Watched"
        case mostWatched = "Most Watched"
        case title = "Title"
        case titleDescending = "Title Descending"
        case year = "Year"
        
        public var id: String { self.rawValue }

        /// Localized label for menus; `rawValue` stays English for identity/storage.
        public var localizedTitle: String {
            switch self {
            case .dateAdded:
                return L10n.string("library_sort_added_desc", fallback: "Date Added")
            case .lastWatched:
                return L10n.string("library_sort_last_watched", fallback: "Last Watched")
            case .mostWatched:
                return L10n.string("library_sort_most_watched", fallback: "Most Watched")
            case .title:
                return L10n.string("library_sort_title_asc", fallback: "A-Z")
            case .titleDescending:
                return L10n.string("library_sort_title_desc", fallback: "Z-A")
            case .year:
                return L10n.string("library_filter_year", fallback: "Year")
            }
        }
    }

    /// Watched-state filter, mirroring the Watched / Not Watched tabs.
    public enum WatchedFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case watched = "Watched"
        case notWatched = "Not Watched"

        public var id: String { self.rawValue }

        public var localizedTitle: String {
            switch self {
            case .all:
                return L10n.string("library_type_all", fallback: "All")
            case .watched:
                return L10n.string("library_filter_watched", fallback: "Watched")
            case .notWatched:
                return L10n.string("library_filter_not_watched", fallback: "Not Watched")
            }
        }
    }
    
    public enum GroupOption: String, CaseIterable, Identifiable {
        case none = "None"
        case type = "Type"
        
        public var id: String { self.rawValue }

        public var localizedTitle: String {
            switch self {
            case .none:
                return L10n.string("action_none", fallback: "None")
            case .type:
                return L10n.string("library_filter_type", fallback: "Type")
            }
        }
    }
    
    public init() {
        loadLibrary()
        libraryObserver = NotificationCenter.default.addObserver(
            forName: LibraryStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.loadLibrary()
            }
        }
        traktAuthObserver = NotificationCenter.default.addObserver(
            forName: TraktAuthStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSelectedLibrary()
            }
        }
        simklAuthObserver = NotificationCenter.default.addObserver(
            forName: SimklAuthStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSelectedLibrary()
            }
        }
        traktSettingsObserver = NotificationCenter.default.addObserver(
            forName: TraktSettingsStore.libraryChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSelectedLibrary()
            }
        }
        traktMutationObserver = NotificationCenter.default.addObserver(
            forName: TraktLibraryService.mutationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mutation = notification.object as? TraktLibraryMutation else { return }
            Task { @MainActor in
                self?.applyTraktMutation(mutation)
            }
        }
    }

    deinit {
        for observer in [
            libraryObserver, traktAuthObserver, simklAuthObserver,
            traktSettingsObserver, traktMutationObserver
        ].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    public func loadLibrary() {
        guard !usesRemoteLibrary else {
            if displayedSource != TraktSettingsStore.librarySourceMode {
                displayedSource = TraktSettingsStore.librarySourceMode
                items = []
                validateFilters()
            }
            return
        }

        displayedSource = .local
        items = LibraryStore.items().map(\.stremioMeta)
        validateFilters()
    }

    public func refreshSelectedLibrary() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let profileID = LibraryStore.activeProfileId

        guard usesRemoteLibrary else {
            loadLibrary()
            return
        }

        if displayedSource != TraktSettingsStore.librarySourceMode {
            displayedSource = TraktSettingsStore.librarySourceMode
            items = []
            validateFilters()
        }

        guard let remoteItems = await SelectedLibraryService.fetchLibrary(repository: repository),
              !Task.isCancelled,
              generation == refreshGeneration,
              profileID == LibraryStore.activeProfileId,
              usesRemoteLibrary else {
            return
        }

        displayedSource = TraktSettingsStore.librarySourceMode
        items = remoteItems.map(\.stremioMeta)
        validateFilters()
    }

    private var usesRemoteLibrary: Bool {
        SelectedLibraryService.isSelectedAndAuthenticated
    }

    /// The Android TV library updates its Trakt snapshot immediately after a
    /// validated watchlist mutation. Do the same here so navigation into
    /// Library never waits on a second network pull to reveal the title.
    private func applyTraktMutation(_ mutation: TraktLibraryMutation) {
        guard usesRemoteLibrary else { return }
        let item = LibraryStoreItem(meta: mutation.meta, addedAt: Date()).stremioMeta
        if mutation.isInWatchlist {
            items = [item] + items.filter {
                !($0.id == item.id && $0.contentType.caseInsensitiveCompare(item.contentType) == .orderedSame)
            }
        } else {
            items.removeAll {
                $0.id == item.id && $0.contentType.caseInsensitiveCompare(item.contentType) == .orderedSame
            }
        }
        displayedSource = TraktSettingsStore.librarySourceMode
        validateFilters()
    }

    private func validateFilters() {
        if let contentTypeFilter, !availableContentTypes.contains(contentTypeFilter) {
            self.contentTypeFilter = nil
        }
        if let genreFilter, !availableGenres.contains(genreFilter) {
            self.genreFilter = nil
        }
    }

    public var availableContentTypes: [String] {
        Array(Set(items.map(\.contentType)))
            .filter { !$0.isEmpty }
            .sorted { typeLabel($0) < typeLabel($1) }
    }

    public var availableGenres: [String] {
        Array(Set(items.flatMap { $0.genres ?? [] }))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "movie":
            return L10n.string("type_movies", fallback: L10n.string("type_movie", fallback: "Movies"))
        case "series", "tv":
            return L10n.string("type_series_plural", fallback: L10n.string("type_series", fallback: "Series"))
        default:
            return type.capitalized
        }
    }
    
    /// Latest watch timestamp per meta id. An episode mark counts for its show,
    /// so a series reads as watched from any episode.
    private static func latestWatchedDates() -> [String: Date] {
        var result: [String: Date] = [:]
        for entry in WatchedStore.items() {
            let id = entry.meta.id
            if let existing = result[id], existing >= entry.watchedAt { continue }
            result[id] = entry.watchedAt
        }
        return result
    }

    public var sortedAndGroupedItems: [String: [StremioMeta]] {
        var result: [String: [StremioMeta]] = [:]
        
        // Most recent watch per title, for the Last Watched sort and the
        // watched filter. Built once per pass rather than per comparison.
        let watchedAtByMetaId = Self.latestWatchedDates()

        let filtered = items.filter { item in
            let matchesType = contentTypeFilter == nil || item.contentType == contentTypeFilter
            let matchesGenre = genreFilter == nil || item.genres?.contains(where: {
                $0.caseInsensitiveCompare(genreFilter ?? "") == .orderedSame
            }) == true
            let isWatched = watchedAtByMetaId[item.id] != nil
            let matchesWatched: Bool
            switch watchedFilter {
            case .all:        matchesWatched = true
            case .watched:    matchesWatched = isWatched
            case .notWatched: matchesWatched = !isWatched
            }
            return matchesType && matchesGenre && matchesWatched
        }

        let sorted: [StremioMeta]
        switch sortOption {
        case .dateAdded:
            sorted = filtered
        case .lastWatched:
            // Never-watched titles sort last rather than jumbling in at epoch.
            sorted = filtered.sorted {
                let lhs = watchedAtByMetaId[$0.id] ?? .distantPast
                let rhs = watchedAtByMetaId[$1.id] ?? .distantPast
                if lhs == rhs { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return lhs > rhs
            }
        case .mostWatched:
            // Counting began when this shipped, so untouched titles tie at zero
            // and fall back to alphabetical rather than arbitrary order.
            let counts = PlayCountStore.counts()
            sorted = filtered.sorted {
                let lhs = counts[$0.id] ?? 0
                let rhs = counts[$1.id] ?? 0
                if lhs == rhs { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return lhs > rhs
            }
        case .title:
            sorted = filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .titleDescending:
            sorted = filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .year:
            sorted = filtered.sorted { ($0.releaseInfo ?? "") > ($1.releaseInfo ?? "") }
        }
        
        switch groupOption {
        case .none:
            result["All"] = sorted
        case .type:
            result = Dictionary(grouping: sorted, by: { $0.contentType })
        }
        
        return result
    }
}

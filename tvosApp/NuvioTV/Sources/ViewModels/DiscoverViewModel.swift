import Foundation
import Combine

/// A content type offered by the installed add-ons.
///
/// Deliberately *not* a fixed enum: which types exist depends entirely on what
/// the user has installed. A stock setup yields movie/series, while a populated
/// one adds sport, anime, tv and so on.
struct DiscoverType: Identifiable, Hashable {
    let rawValue: String
    var id: String { rawValue }

    /// Localized plural label, falling back to a capitalized raw type so an
    /// add-on can introduce a type this app has never heard of.
    var title: String {
        switch rawValue {
        case "movie":
            return L10n.string("type_movies", fallback: L10n.string("type_movie", fallback: "Movies"))
        case "series":
            return L10n.string("type_series_plural", fallback: L10n.string("type_series", fallback: "Series"))
        case "sport", "sports":
            return L10n.string("type_sports", fallback: "Sports")
        case "anime":
            return L10n.string("type_anime", fallback: "Anime")
        case "tv", "channel":
            return L10n.string("type_tv", fallback: "TV")
        case "other":
            return L10n.string("type_other", fallback: "Other")
        default:
            return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    static let movie = DiscoverType(rawValue: "movie")
    static let series = DiscoverType(rawValue: "series")

    /// Familiar types first, then whatever else the add-ons declare.
    static func ordered(_ types: [String]) -> [DiscoverType] {
        let preferred = ["movie", "series", "sport", "sports", "anime", "tv", "channel"]
        let unique = Array(Set(types))
        return unique
            .sorted {
                let l = preferred.firstIndex(of: $0) ?? preferred.count
                let r = preferred.firstIndex(of: $1) ?? preferred.count
                return l == r ? $0 < $1 : l < r
            }
            .map { DiscoverType(rawValue: $0) }
    }
}

/// One selectable catalog within the chosen type. Replaces the old hardcoded
/// Popular / Top Rated pair, which only existed because Discover was wired
/// directly to Cinemeta's own catalog ids.
struct DiscoverCatalog: Identifiable, Hashable {
    let addonId: String?
    let addonName: String
    let type: String
    let catalogId: String
    let name: String
    /// The catalog's own genres, from its add-on's manifest.
    var genreOptions: [String] = []
    /// It answers only with one of them chosen, so there is no "All".
    var genreRequired = false

    /// Cinemeta's own rows, whose genres are Cinemeta's list.
    var isCinemeta: Bool {
        addonId == nil || addonId == CinemetaCatalogRepository.cinemetaAddonId
    }

    var id: String { "\(addonId ?? "cinemeta")_\(type)_\(catalogId)" }

    /// Qualified with the add-on so two "Popular" catalogs stay distinguishable.
    var title: String { "\(name) · \(addonName)" }
}

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var items: [NuvioMeta] = []
    @Published private(set) var genres: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var error: String?

    @Published private(set) var type: DiscoverType = .movie
    @Published private(set) var genre: String? = nil   // nil == All Genres
    /// Types the installed add-ons actually offer.
    @Published private(set) var availableTypes: [DiscoverType] = [.movie, .series]
    /// Catalogs available for the selected type.
    @Published private(set) var catalogs: [DiscoverCatalog] = []
    @Published private(set) var catalog: DiscoverCatalog?

    private let repository: CatalogRepository
    private var page = 1
    /// Where the next page starts in the selected catalog. Add-ons page by
    /// their own size (twenty is common); assuming a hundred skipped most of
    /// a large catalog.
    private var nextSkip = 0
    private var hasMore = true
    private var loadTask: Task<Void, Never>?

    /// Every catalog across every installed add-on, loaded once.
    private var allCatalogs: [AddonCatalogOption] = []

    private var nsfwObserver: AnyCancellable?

    init(repository: CatalogRepository = CinemetaCatalogRepository()) {
        self.repository = repository
        loadGenres()
        reload()
        Task { await discoverAvailableTypes() }
        // Search's NSFW toggle covers the Discover section inside it too.
        nsfwObserver = NSFWVisibility.shared.$showsInSearch
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyCatalogs() }
    }

    /// Builds the type and catalog lists from the installed add-ons' manifests.
    private func discoverAvailableTypes() async {
        let options = await repository.availableAddonCatalogs()
        guard !options.isEmpty else { return }
        allCatalogs = options
        applyCatalogs()
    }

    /// The catalogs on offer: without 18+ add-ons' and catalogs while
    /// Search's NSFW toggle is off.
    private var visibleCatalogs: [AddonCatalogOption] {
        guard !NSFWVisibility.shared.showsInSearch else { return allCatalogs }
        return allCatalogs.filter {
            !AdultContent.shared.isAdultCatalog(addonId: $0.addonId, type: $0.type, catalogId: $0.catalogId)
        }
    }

    private func applyCatalogs() {
        guard !allCatalogs.isEmpty else { return }
        availableTypes = DiscoverType.ordered(visibleCatalogs.map(\.type))
        if !availableTypes.contains(type), let first = availableTypes.first {
            type = first
            genre = nil
            catalog = nil
            loadGenres()
            refreshCatalogsForType(reloadItems: true)
            return
        }
        refreshCatalogsForType(reloadItems: catalog == nil)
    }

    private func refreshCatalogsForType(reloadItems: Bool) {
        catalogs = visibleCatalogs
            .filter { $0.type == type.rawValue }
            .map {
                DiscoverCatalog(
                    addonId: $0.addonId,
                    addonName: $0.addonName,
                    type: $0.type,
                    catalogId: $0.catalogId,
                    name: $0.catalogName,
                    genreOptions: $0.genreOptions,
                    genreRequired: $0.genreRequired
                )
            }
        if let current = catalog, catalogs.contains(current) { return }
        catalog = catalogs.first
        loadGenres()
        if reloadItems, catalog != nil { reload() }
    }

    /// The type last picked by hand, which a search then starts within.
    /// Nil until one is: the default Movies must not narrow every search.
    static var chosenType: String?

    func setType(_ newType: DiscoverType) {
        Self.chosenType = newType.rawValue
        guard type != newType else { return }
        type = newType
        genre = nil
        catalog = nil
        loadGenres()
        refreshCatalogsForType(reloadItems: false)
        reload()
    }

    func setCatalog(_ newCatalog: DiscoverCatalog) {
        guard catalog != newCatalog else { return }
        catalog = newCatalog
        genre = nil
        loadGenres()
        reload()
    }

    /// "All Genres" is offered unless the catalog needs one chosen.
    var allowsAllGenres: Bool { !(catalog?.genreRequired ?? false) }

    /// A catalog's name, with its add-on's only when another catalog of the
    /// type has the same name: "Theme", not "Theme · TPB 4K Porn - TorBox…".
    func title(of catalog: DiscoverCatalog) -> String {
        let shared = catalogs.filter { $0.name == catalog.name }.count > 1
        return shared ? catalog.title : catalog.name
    }

    func setGenre(_ newGenre: String?) {
        guard newGenre != nil || allowsAllGenres else { return }
        guard genre != newGenre else { return }
        genre = newGenre
        reload()
    }

    func reload() {
        loadTask?.cancel()
        page = 1
        nextSkip = 0
        hasMore = true
        isLoading = true
        isLoadingMore = false
        error = nil
        loadTask = Task { await load(reset: true) }
    }

    /// Loads the next page when the grid scrolls near its end.
    func loadMoreIfNeeded(currentItem: NuvioMeta) {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        guard items.suffix(8).contains(where: { $0.id == currentItem.id }) else { return }
        isLoadingMore = true
        Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        do {
            let result: CatalogPage
            if let catalog {
                // Route to the add-on that owns this catalog; a nil addonId
                // falls through to the built-in Cinemeta base URL.
                result = try await repository.browseCatalog(
                    addonId: catalog.addonId,
                    contentType: catalog.type,
                    catalogId: catalog.catalogId,
                    skip: reset ? 0 : nextSkip,
                    genre: genre
                )
            } else {
                result = try await repository.browseCatalog(
                    contentType: type.rawValue,
                    catalogId: "top",
                    page: page,
                    genre: genre,
                    year: nil,
                    sort: nil
                )
            }
            if Task.isCancelled { return }
            if reset {
                items = result.items
            } else {
                let existing = Set(items.map(\.id))
                items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            }
            hasMore = result.hasMore
            page = result.page + 1
            let start = reset ? 0 : nextSkip
            nextSkip = result.nextSkip ?? (start + result.items.count)
            isLoading = false
            isLoadingMore = false
        } catch {
            if Task.isCancelled { return }
            self.error = "Couldn’t load Discover. Check your connection and try again."
            isLoading = false
            isLoadingMore = false
        }
    }

    /// The selected catalog's own genres when its add-on declares them (an
    /// adult add-on's categories, a sports add-on's leagues); otherwise the
    /// general list for the type.
    /// The genres follow the catalog: its own, from its add-on's manifest;
    /// Cinemeta's list only for Cinemeta's catalogs; otherwise none, and the
    /// Genre filter goes. Film genres used to show for Porn, Tube and Live
    /// catalogs, where they matched nothing. A catalog that needs a genre
    /// starts on its first.
    private func loadGenres() {
        if let declared = catalog?.genreOptions, !declared.isEmpty {
            genres = declared
            if catalog?.genreRequired == true, genre == nil || !declared.contains(genre!) {
                genre = declared.first
            }
            return
        }
        guard catalog?.isCinemeta ?? true else {
            genres = []
            return
        }
        let forType = type
        let forCatalog = catalog
        Task {
            let loaded = (try? await repository.getGenres(contentType: forType.rawValue)) ?? []
            // Only if the selection is still the one asked about: switching
            // to an add-on's catalog meanwhile must not get Cinemeta's list.
            guard !Task.isCancelled, type == forType, catalog == forCatalog else { return }
            genres = loaded
        }
    }
}

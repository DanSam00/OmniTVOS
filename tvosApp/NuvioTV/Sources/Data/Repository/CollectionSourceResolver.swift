import Foundation

enum CollectionSourceError: LocalizedError {
    case invalidAddonSource
    case missingTmdbAPIKey
    case tmdbKeyRejected
    case missingTmdbID(String)
    case missingTraktClientID
    case missingTraktListID
    case missingMdbListKey
    case unsupportedProvider(String)
    case requestFailed(String, Int)
    case invalidResponse(String)
    /// The folder names an add-on this profile does not have installed.
    case addonNotInstalled(addonId: String, catalogId: String? = nil)

    var errorDescription: String? {
        switch self {
        case .invalidAddonSource:
            return "This add-on catalog source is incomplete."
        case .missingTmdbAPIKey:
            return "Enter a TMDB API key in Settings to load this folder."
        case .tmdbKeyRejected:
            return "TMDB rejected the API key. Enter a current key in Settings → Integrations."
        case .missingTmdbID(let sourceType):
            return "This TMDB \(sourceType.lowercased()) source has no ID."
        case .missingTraktClientID:
            return "Enter a Trakt Client ID in Settings to load this folder."
        case .missingTraktListID:
            return "This Trakt source has no public list ID."
        case .missingMdbListKey:
            return "This folder is an MDBList list. Enter an MDBList API key in Settings → Integrations to load it."
        case .unsupportedProvider(let provider):
            return "The collection source provider “\(provider)” is not supported."
        case .requestFailed(let provider, let status):
            return ServiceErrorText.describe(status: status, service: provider)
        case .invalidResponse(let provider):
            return "\(provider) returned data the app could not read."
        case .addonNotInstalled(let addonId, let catalogId):
            #if !OMNI_X
            // Omni's add-ons are fixed; there is nothing for the viewer to install.
            _ = (addonId, catalogId)
            return "This row isn't available in Omni."
            #else
            if let name = Self.knownAddonName(addonId) {
                let catalog = catalogId.map { " It needs the catalog “\($0)” in that add-on's configuration, as the collection's author set it up." } ?? ""
                return "This row comes from \(name), which isn't installed on this profile.\(catalog) Install and configure \(name) in Settings → Integrations → Add-ons."
            }
            return "This row comes from the add-on “\(addonId)”, which isn't installed on this profile. Install it in Settings → Integrations → Add-ons to see it."
            #endif
        }
    }
}

extension CollectionSourceError {
    /// A button that fixes this in Settings, for errors that are a missing or
    /// rejected key or a missing add-on; nil for anything else.
    var settingsFixTitle: String? {
        switch self {
        case .missingTmdbAPIKey: return "Add a TMDB Key"
        case .tmdbKeyRejected: return "Update the TMDB Key"
        case .missingTraktClientID: return "Set Up Trakt"
        case .missingMdbListKey: return "Add an MDBList Key"
        case .addonNotInstalled(let addonId, _):
            #if !OMNI_X
            _ = addonId
            return nil
            #else
            return Self.knownAddonName(addonId).map { "Set Up \($0)" } ?? "Install the Add-on"
            #endif
        default: return nil
        }
    }

    /// The add-on's own name, for the ids collections refer to it by.
    static func knownAddonName(_ addonId: String) -> String? {
        let id = addonId.lowercased()
        if id.contains("aio-metadata") || id.contains("aiometadata") || id.contains("aio.metadata") { return "AIOMetadata" }
        if id.contains("aiostreams") { return "AIOStreams" }
        if id.contains("mdblist") { return "MDBList" }
        if id.contains("trakt") { return "Trakt" }
        return nil
    }

    /// Where in Settings → Integrations that fix is.
    var settingsAnchor: SettingsDeepLink.Anchor? {
        switch self {
        case .missingTmdbAPIKey, .tmdbKeyRejected: return .tmdb
        case .missingTraktClientID: return .trakt
        case .missingMdbListKey: return .mdblist
        case .addonNotInstalled: return .addons
        default: return nil
        }
    }
}

/// Opens a Settings page from elsewhere in the app (iPhone): the Settings tab,
/// pushed to that category. Kept until Settings is there to take it, since
/// it is built the first time its tab is shown.
@MainActor
enum SettingsDeepLink {
    /// A place on the Integrations page to land on.
    enum Anchor: String {
        case addons, simkl, trakt, aiSubtitles, tmdb, mdblist, debrid

        var id: String { "settings.anchor.\(rawValue)" }
    }

    static let notification = Notification.Name("omni.settings.deepLink")
    /// Posted once the page has scrolled to an anchor, with it as the
    /// object, so that section can open its own setup (TMDB's key sheet).
    static let revealNotification = Notification.Name("omni.settings.deepLink.reveal")
    /// A `SettingsCategory` raw value.
    static var pendingCategory: String?
    static var pendingAnchor: Anchor?

    static func openIntegrations(at anchor: Anchor? = nil) {
        pendingCategory = "Integrations"
        pendingAnchor = anchor
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

/// Resolves the heterogeneous collection source format shared with the Compose
/// client. Its cursor is a Stremio item offset for add-ons and a page number for
/// TMDB/Trakt; callers store the opaque value from `CatalogPage.nextSkip`.
struct CollectionSourceResolver {
    let repository: CatalogRepository
    /// The folder's title ("1980s"), a hint for catalogs whose id says less
    /// than it should (`AIOMetadataFallback`).
    var folderTitle: String? = nil
    var session: URLSession = .shared
    var settings: UserDefaults = ProfileSettings.current
    /// The TMDB key the last request used, so a rejected one is not retried.
    private let lastTmdbKey = Box()
    private final class Box: @unchecked Sendable { var value: String? }

    func browse(_ source: NuvioCollectionSource, cursor: Int = 0) async throws -> CatalogPage {
        do {
            return try await browseSource(source, cursor: cursor)
        } catch {
            // Without this a failing source only shows as an empty row.
            // Never log the request URL: it carries the API key.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                Self.log(
                    "collection.source failed provider=\(source.normalizedProvider) "
                        + "type=\(source.tmdbSourceType ?? source.catalogId ?? "-") "
                        + "title=\(source.title ?? "-") error=\(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func browseSource(_ source: NuvioCollectionSource, cursor: Int) async throws -> CatalogPage {
        switch source.normalizedProvider {
        case "addon":
            guard let type = nonEmpty(source.type),
                  let catalogId = nonEmpty(source.catalogId) else {
                throw CollectionSourceError.invalidAddonSource
            }
            // A catalog AIOMetadata builds from TMDB, Trakt or MDBList, without
            // that add-on (or with it, unconfigured): straight from the
            // service, with this profile's key. The cursor is then a page number.
            let fallback = AIOMetadataFallback.source(for: source, folderTitle: folderTitle)
            do {
                if fallback != nil, cursor > 0 { throw CollectionSourceError.addonNotInstalled(addonId: source.addonId ?? "", catalogId: source.catalogId) }
                return try await repository.browseCatalog(
                    addonId: nonEmpty(source.addonId),
                    contentType: type,
                    catalogId: catalogId,
                    skip: max(cursor, 0),
                    genre: nonEmpty(source.genre)
                )
            } catch {
                guard let fallback, !(error is CancellationError) else { throw error }
                let page = try await browseSource(fallback, cursor: max(cursor, 1))
                return AIOMetadataFallback.filtered(page, for: source)
            }
        case "tmdb":
            do {
                return try await browseTmdb(source, page: max(cursor, 1))
            } catch CollectionSourceError.tmdbKeyRejected {
                // That key is now known bad; another profile's may work.
                let next = TmdbAccountKey.key(in: settings)
                guard next != nil, next != lastTmdbKey.value else { throw CollectionSourceError.tmdbKeyRejected }
                return try await browseTmdb(source, page: max(cursor, 1))
            }
        case "trakt":
            return try await browseTrakt(source, page: max(cursor, 1))
        case "mdblist":
            return try await browseMdbList(source, page: max(cursor, 1))
        default:
            throw CollectionSourceError.unsupportedProvider(source.provider)
        }
    }

    static func label(for source: NuvioCollectionSource) -> String {
        if let title = nonEmpty(source.title) { return title }
        switch source.normalizedProvider {
        case "tmdb":
            return (nonEmpty(source.tmdbSourceType) ?? "TMDB").capitalized
        case "trakt":
            return "Trakt List"
        default:
            if let readable = AIOMetadataFallback.readableName(for: source) { return readable }
            let name = (nonEmpty(source.catalogId) ?? "Catalog")
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            let type = nonEmpty(source.type)?.capitalized
            let base = type.map { "\(name) (\($0))" } ?? name
            if let genre = nonEmpty(source.genre) {
                return "\(base) · \(genre)"
            }
            return base
        }
    }

    // MARK: - TMDB

    private func browseTmdb(_ source: NuvioCollectionSource, page: Int) async throws -> CatalogPage {
        guard let apiKey = TmdbAccountKey.key(in: settings) else {
            throw CollectionSourceError.missingTmdbAPIKey
        }
        lastTmdbKey.value = apiKey

        let sourceType = (nonEmpty(source.tmdbSourceType) ?? "DISCOVER").uppercased()
        let language = TmdbDetailsService.preferredLanguage
        switch sourceType {
        case "LIST":
            let id = try requiredTmdbID(source, sourceType: sourceType)
            let response: TmdbCollectionListResponse = try await tmdbRequest(
                path: "list/\(id)",
                apiKey: apiKey,
                query: [
                    URLQueryItem(name: "language", value: language),
                    URLQueryItem(name: "page", value: String(page))
                ]
            )
            let items = sortedTmdbItems(
                response.items.compactMap { tmdbMeta(from: $0, fallbackMediaType: source.mediaType) },
                sortBy: source.sortBy
            )
            let hasMore = page < (response.totalPages ?? page) && !items.isEmpty
            return CatalogPage(
                items: items,
                hasMore: hasMore,
                page: page,
                nextSkip: hasMore ? page + 1 : nil
            )

        case "COLLECTION":
            let id = try requiredTmdbID(source, sourceType: sourceType)
            let response: TmdbCollectionResponse = try await tmdbRequest(
                path: "collection/\(id)",
                apiKey: apiKey,
                query: [URLQueryItem(name: "language", value: language)]
            )
            let items = sortedTmdbItems(
                response.parts.compactMap { tmdbMeta(from: $0, fallbackMediaType: "movie") },
                sortBy: source.sortBy
            )
            return CatalogPage(items: items, hasMore: false, page: 1, nextSkip: nil)

        case "PERSON", "DIRECTOR":
            let id = try requiredTmdbID(source, sourceType: sourceType)
            let response: TmdbCollectionCreditsResponse = try await tmdbRequest(
                path: "person/\(id)/combined_credits",
                apiKey: apiKey,
                query: [URLQueryItem(name: "language", value: language)]
            )
            let rawItems = sourceType == "DIRECTOR"
                ? response.crew.filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
                : response.cast
            let items = sortedTmdbItems(
                rawItems.compactMap { tmdbMeta(from: $0, fallbackMediaType: source.mediaType) },
                sortBy: source.sortBy
            )
            return CatalogPage(items: items, hasMore: false, page: 1, nextSkip: nil)

        case "COMPANY", "NETWORK", "DISCOVER":
            let mediaType = sourceType == "NETWORK" ? "tv" : normalizedTmdbMediaType(source.mediaType)
            var query = tmdbDiscoverQuery(source, mediaType: mediaType, page: page, language: language)
            if sourceType == "COMPANY" {
                query.append(
                    URLQueryItem(
                        name: "with_companies",
                        value: String(try requiredTmdbID(source, sourceType: sourceType))
                    )
                )
            } else if sourceType == "NETWORK" {
                query.append(
                    URLQueryItem(
                        name: "with_networks",
                        value: String(try requiredTmdbID(source, sourceType: sourceType))
                    )
                )
            }
            let response: TmdbCollectionPageResponse = try await tmdbRequest(
                path: "discover/\(mediaType)",
                apiKey: apiKey,
                query: query
            )
            let items = response.results.compactMap {
                tmdbMeta(from: $0, fallbackMediaType: mediaType)
            }
            let hasMore = page < (response.totalPages ?? page) && !items.isEmpty
            return CatalogPage(
                items: items,
                hasMore: hasMore,
                page: page,
                nextSkip: hasMore ? page + 1 : nil
            )

        default:
            throw CollectionSourceError.unsupportedProvider("TMDB \(sourceType)")
        }
    }

    private func requiredTmdbID(
        _ source: NuvioCollectionSource,
        sourceType: String
    ) throws -> Int {
        guard let id = source.tmdbId, id > 0 else {
            throw CollectionSourceError.missingTmdbID(sourceType)
        }
        return id
    }

    private func tmdbDiscoverQuery(
        _ source: NuvioCollectionSource,
        mediaType: String,
        page: Int,
        language: String
    ) -> [URLQueryItem] {
        let filters = source.filters
        let sort = normalizedTmdbSort(source.sortBy, mediaType: mediaType)
        let releaseDateLte = nonEmpty(filters?.releaseDateLte)
            ?? (isRecentReleaseSource(source, sort: sort) ? currentLocalDateString() : nil)
        let voteCountGte = filters?.voteCountGte.map { String($0) }
        let voteAverageGte = filters?.voteAverageGte.map { String($0) }
        let voteAverageLte = filters?.voteAverageLte.map { String($0) }
        // A kids profile browsing a channel or service with no genre of its
        // own gets its children's titles (Animation, Family, Kids) rather
        // than a page of mostly adult ones the kids filter then hides.
        let isKids = settings.bool(forKey: SettingsKey.kidsProfile)
        let kidsGenres = isKids && nonEmpty(filters?.withGenres) == nil
            ? (mediaType == "tv" ? "10762|10751|16" : "10751|16")
            : nil
        var values: [(String, String?)] = [
            ("language", language),
            ("page", String(page)),
            ("sort_by", sort),
            ("with_companies", filters?.withCompanies),
            ("with_networks", filters?.withNetworks),
            ("with_genres", filters?.withGenres ?? kidsGenres),
            ("without_genres", isKids ? "27,53,80,10752,10764,10749" : nil),
            ("vote_count.gte", voteCountGte),
            ("vote_average.gte", voteAverageGte),
            ("vote_average.lte", voteAverageLte),
            ("with_original_language", filters?.withOriginalLanguage),
            ("with_origin_country", filters?.withOriginCountry),
            ("with_keywords", filters?.withKeywords),
        ]
        if let providers = nonEmpty(filters?.withWatchProviders) {
            values.append(("with_watch_providers", providers))
            values.append(("watch_region", nonEmpty(filters?.watchRegion) ?? "US"))
            values.append(("with_watch_monetization_types", "flatrate|free|ads|rent|buy"))
        }
        if let year = filters?.year {
            values.append((mediaType == "tv" ? "first_air_date_year" : "year", String(year)))
        }
        values.append((
            mediaType == "tv" ? "first_air_date.gte" : "primary_release_date.gte",
            filters?.releaseDateGte
        ))
        values.append((
            mediaType == "tv" ? "first_air_date.lte" : "primary_release_date.lte",
            releaseDateLte
        ))
        return values.compactMap { name, value in
            nonEmpty(value).map { URLQueryItem(name: name, value: $0) }
        }
    }

    /// The built-in Recent rows sort by release date, but TMDB includes announced
    /// future titles unless the discover request also supplies an upper bound.
    private func isRecentReleaseSource(_ source: NuvioCollectionSource, sort: String) -> Bool {
        guard let title = nonEmpty(source.title)?.lowercased(), title.hasPrefix("recent ") else {
            return false
        }
        return sort == "primary_release_date.desc" || sort == "first_air_date.desc"
    }

    private func currentLocalDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func normalizedTmdbSort(_ value: String?, mediaType: String) -> String {
        let sort = nonEmpty(value) ?? "popularity.desc"
        if mediaType == "tv" {
            switch sort {
            case "primary_release_date.desc", "release_date.desc":
                return "first_air_date.desc"
            default:
                return sort
            }
        }
        if sort == "first_air_date.desc" { return "primary_release_date.desc" }
        return sort
    }

    private func normalizedTmdbMediaType(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tv", "series", "show":
            return "tv"
        default:
            return "movie"
        }
    }

    private func tmdbRequest<T: Decodable>(
        path: String,
        apiKey: String,
        query: [URLQueryItem]
    ) async throws -> T {
        var components = URLComponents(
            url: URL(string: "https://api.themoviedb.org/3")!.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + query
        guard let url = components.url else {
            throw CollectionSourceError.invalidResponse("TMDB")
        }
        return try await request(url, provider: "TMDB", headers: [:])
    }

    private func tmdbMeta(
        from item: TmdbCollectionItem,
        fallbackMediaType: String?
    ) -> NuvioMeta? {
        guard item.id > 0 else { return nil }
        let mediaType = normalizedTmdbMediaType(item.mediaType ?? fallbackMediaType)
        let name = nonEmpty(item.title) ?? nonEmpty(item.name)
        guard let name else { return nil }
        let releaseDate = nonEmpty(item.releaseDate) ?? nonEmpty(item.firstAirDate)
        return NuvioMeta(
            id: "tmdb:\(item.id)",
            name: name,
            description: nonEmpty(item.overview),
            posterUrl: tmdbImage(item.posterPath, size: "w500")
                ?? tmdbImage(item.backdropPath, size: "w780"),
            backgroundUrl: tmdbImage(item.backdropPath, size: "w1280"),
            logoUrl: nil,
            imdbId: nil,
            tmdbId: item.id,
            type: mediaType == "tv" ? "series" : "movie",
            year: releaseDate.flatMap { Int($0.prefix(4)) },
            genres: nil,
            rating: item.voteAverage.flatMap { $0 > 0 ? $0 : nil },
            releaseInfo: releaseDate.map { String($0.prefix(4)) },
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: releaseDate
        )
    }

    private func sortedTmdbItems(_ items: [NuvioMeta], sortBy: String?) -> [NuvioMeta] {
        switch sortBy {
        case "vote_average.desc":
            return items.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        case "release_date.desc", "primary_release_date.desc", "first_air_date.desc":
            return items.sorted { ($0.released ?? "") > ($1.released ?? "") }
        default:
            return items
        }
    }

    private func tmdbImage(_ path: String?, size: String) -> String? {
        guard let path = nonEmpty(path) else { return nil }
        if path.lowercased().hasPrefix("http") { return path }
        return "https://image.tmdb.org/t/p/\(size)\(path.hasPrefix("/") ? path : "/\(path)")"
    }

    // MARK: - Trakt

    private func browseTrakt(_ source: NuvioCollectionSource, page: Int) async throws -> CatalogPage {
        let clientID = TraktConfig.clientID(in: settings)
        guard !clientID.isEmpty else {
            throw CollectionSourceError.missingTraktClientID
        }
        guard let listID = source.traktListId, listID > 0 else {
            throw CollectionSourceError.missingTraktListID
        }

        let isSeries = normalizedTmdbMediaType(source.mediaType) == "tv"
        let itemType = isSeries ? "show" : "movie"
        let limit = 50
        var components = URLComponents(
            string: "\(TraktConfig.apiBaseURL)/lists/\(listID)/items/\(itemType)"
        )!
        components.queryItems = [
            URLQueryItem(name: "extended", value: "full,images"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: normalizedTraktSort(source.sortBy)),
            URLQueryItem(name: "sort_how", value: normalizedTraktDirection(source.sortHow))
        ]
        guard let url = components.url else {
            throw CollectionSourceError.invalidResponse("Trakt")
        }

        let response: (value: [TraktCollectionListItem], http: HTTPURLResponse) = try await requestWithResponse(
            url,
            provider: "Trakt",
            headers: [
                "Accept": "application/json",
                "trakt-api-version": "2",
                "trakt-api-key": clientID
            ]
        )
        var seen = Set<String>()
        let items = response.value.compactMap { entry in
            traktMeta(
                from: isSeries ? entry.show : entry.movie,
                type: isSeries ? "series" : "movie"
            )
        }.filter { seen.insert("\($0.type):\($0.id)").inserted }

        let pageCount = response.http.value(forHTTPHeaderField: "x-pagination-page-count")
            .flatMap(Int.init)
        let hasMore = pageCount.map { page < $0 } ?? (items.count == limit)
        return CatalogPage(
            items: items,
            hasMore: hasMore && !items.isEmpty,
            page: page,
            nextSkip: hasMore && !items.isEmpty ? page + 1 : nil
        )
    }

    private func normalizedTraktSort(_ value: String?) -> String {
        let allowed = ["rank", "added", "title", "released", "runtime", "popularity", "percentage", "votes"]
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return allowed.contains(value) ? value : "rank"
    }

    private func normalizedTraktDirection(_ value: String?) -> String {
        value?.caseInsensitiveCompare("desc") == .orderedSame ? "desc" : "asc"
    }

    private func traktMeta(from item: TraktCollectionMedia?, type: String) -> NuvioMeta? {
        guard let item, let name = nonEmpty(item.title) else { return nil }
        let id: String
        if let imdb = nonEmpty(item.ids?.imdb) {
            id = imdb
        } else if let tmdb = item.ids?.tmdb {
            id = "tmdb:\(tmdb)"
        } else if let trakt = item.ids?.trakt {
            id = "trakt:\(trakt)"
        } else {
            return nil
        }
        let releaseDate = type == "series" ? item.firstAired : item.released
        return NuvioMeta(
            id: id,
            name: name,
            description: nonEmpty(item.overview),
            posterUrl: traktImage(item.images?.poster) ?? traktImage(item.images?.fanart),
            backgroundUrl: traktImage(item.images?.fanart)
                ?? traktImage(item.images?.banner)
                ?? traktImage(item.images?.thumb),
            logoUrl: traktImage(item.images?.logo) ?? traktImage(item.images?.clearart),
            imdbId: nonEmpty(item.ids?.imdb),
            tmdbId: item.ids?.tmdb,
            type: type,
            year: item.year,
            genres: item.genres,
            rating: item.rating.flatMap { $0 > 0 ? $0 : nil },
            releaseInfo: item.year.map(String.init) ?? releaseDate.map { String($0.prefix(4)) },
            runtime: item.runtime.map { "\($0) min" },
            cast: nil,
            director: nil,
            writer: nil,
            certification: item.certification,
            country: item.country,
            released: releaseDate
        )
    }

    private func traktImage(_ values: [String]?) -> String? {
        guard var value = values?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if value.hasPrefix("//") {
            value = "https:\(value)"
        } else if value.lowercased().hasPrefix("http://") {
            value = "https://" + String(value.dropFirst("http://".count))
        } else if !value.lowercased().hasPrefix("https://"),
                  value.lowercased().contains("trakt.tv/") {
            value = "https://\(value)"
        }
        return value
    }

    // MARK: - MDBList

    /// An MDBList list, with this profile's MDBList key; its titles' art and
    /// overviews from TMDB when there is a TMDB key, else MetaHub's posters.
    private func browseMdbList(_ source: NuvioCollectionSource, page: Int) async throws -> CatalogPage {
        guard let apiKey = nonEmpty(settings.string(forKey: SettingsKey.mdbListApiKey)) else {
            throw CollectionSourceError.missingMdbListKey
        }
        guard let listID = nonEmpty(source.catalogId) else {
            throw CollectionSourceError.invalidAddonSource
        }
        let limit = 40
        var components = URLComponents(string: "https://api.mdblist.com/lists/\(listID)/items")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String((page - 1) * limit)),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        guard let url = components.url else { throw CollectionSourceError.invalidResponse("MDBList") }
        // MDBList's firewall turns away requests without an app's user agent.
        let response: MdbListItemsResponse = try await request(url, provider: "MDBList", headers: ["User-Agent": "Omni"])
        let entries = ((response.movies ?? []) + (response.shows ?? [])).sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }

        let tmdbKey = TmdbAccountKey.key(in: settings)
        let language = TmdbDetailsService.preferredLanguage
        var details = [Int: TmdbCollectionItem]()
        if let tmdbKey {
            await withTaskGroup(of: (Int, TmdbCollectionItem?).self) { group in
                var next = 0
                func addNext() {
                    guard next < entries.count else { return }
                    let index = next
                    next += 1
                    let entry = entries[index]
                    guard let tmdb = entry.ids?.tmdb else { group.addTask { (index, nil) }; return }
                    let path = entry.isShow ? "tv/\(tmdb)" : "movie/\(tmdb)"
                    group.addTask {
                        let item: TmdbCollectionItem? = try? await tmdbRequest(
                            path: path, apiKey: tmdbKey, query: [URLQueryItem(name: "language", value: language)]
                        )
                        return (index, item)
                    }
                }
                for _ in 0..<8 { addNext() }
                while let (index, item) = await group.next() {
                    details[index] = item
                    addNext()
                }
            }
        }
        let items = entries.indices.compactMap { mdbListMeta(entries[$0], details: details[$0]) }
        let hasMore = response.pagination?.hasMore ?? (entries.count >= limit)
        return CatalogPage(items: items, hasMore: hasMore, page: page, nextSkip: hasMore ? page + 1 : nil)
    }

    private func mdbListMeta(_ entry: MdbListEntry, details: TmdbCollectionItem?) -> NuvioMeta? {
        guard let name = nonEmpty(details?.title) ?? nonEmpty(details?.name) ?? nonEmpty(entry.title) else { return nil }
        let imdb = nonEmpty(entry.ids?.imdb) ?? nonEmpty(entry.imdbId)
        let tmdb = entry.ids?.tmdb
        guard let id = imdb ?? tmdb.map({ "tmdb:\($0)" }) else { return nil }
        let releaseDate = nonEmpty(details?.releaseDate) ?? nonEmpty(details?.firstAirDate) ?? nonEmpty(entry.releaseDate)
        let metahub: (String) -> String? = { kind in imdb.map { "https://images.metahub.space/\(kind)/medium/\($0)/img" } }
        return NuvioMeta(
            id: id,
            name: name,
            description: nonEmpty(details?.overview),
            posterUrl: tmdbImage(details?.posterPath, size: "w500") ?? metahub("poster"),
            backgroundUrl: tmdbImage(details?.backdropPath, size: "w1280") ?? metahub("background"),
            logoUrl: nil,
            imdbId: imdb,
            tmdbId: tmdb,
            type: entry.isShow ? "series" : "movie",
            year: entry.releaseYear ?? releaseDate.flatMap { Int($0.prefix(4)) },
            genres: nil,
            rating: details?.voteAverage.flatMap { $0 > 0 ? $0 : nil },
            releaseInfo: (entry.releaseYear.map(String.init)) ?? releaseDate.map { String($0.prefix(4)) },
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: releaseDate
        )
    }

    // MARK: - Networking

    private func request<T: Decodable>(
        _ url: URL,
        provider: String,
        headers: [String: String]
    ) async throws -> T {
        let result: (value: T, http: HTTPURLResponse) = try await requestWithResponse(
            url,
            provider: provider,
            headers: headers
        )
        return result.value
    }

    private func requestWithResponse<T: Decodable>(
        _ url: URL,
        provider: String,
        headers: [String: String]
    ) async throws -> (value: T, http: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CollectionSourceError.invalidResponse(provider)
        }
        guard 200..<300 ~= http.statusCode else {
            if provider == "TMDB", http.statusCode == 401 {
                if let key = TmdbAccountKey.key(in: url) { TmdbAccountKey.markRejected(key) }
                throw CollectionSourceError.tmdbKeyRejected
            }
            throw CollectionSourceError.requestFailed(provider, http.statusCode)
        }
        do {
            return (try JSONDecoder().decode(T.self, from: data), http)
        } catch {
            throw CollectionSourceError.invalidResponse(provider)
        }
    }

    private static func log(_ message: String) {
        #if os(macOS)
        MacDiagnostics.log(message)
        #elseif os(iOS)
        AetherPlaybackController.PhoneLogFile.log(message)
        #else
        print(message)
        #endif
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func nonEmpty(_ value: String?) -> String? {
        Self.nonEmpty(value)
    }
}

/// Constructs Stremio path-style extras once. `URL.appendingPathComponent`
/// re-encodes an already escaped `%20` as `%2520`, so the endpoint is assembled
/// from an escaped string instead.
enum StremioCatalogURLBuilder {
    static func url(
        baseURL: URL,
        type: String,
        catalogId: String,
        skip: Int? = nil,
        search: String? = nil,
        genre: String? = nil
    ) throws -> URL {
        var extras: [String] = []
        if let search, let encoded = encodedExtra(name: "search", value: search) {
            extras.append(encoded)
        }
        if let genre, let encoded = encodedExtra(name: "genre", value: genre) {
            extras.append(encoded)
        }
        if let skip {
            extras.append("skip=\(max(skip, 0))")
        }

        var path = "catalog/\(encodedPathComponent(type))/\(encodedPathComponent(catalogId))"
        if !extras.isEmpty {
            path += "/" + extras.joined(separator: "&")
        }
        path += ".json"

        // Configured add-ons commonly keep a token in the manifest URL's
        // query. Concatenating onto `absoluteString` puts the catalog path
        // after `?token=…`, where the server reads it as part of the token
        // instead of the request path. Work with URLComponents so that path,
        // query, and fragment retain their proper roles.
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.hasSuffix("manifest.json") {
            basePath = (basePath as NSString).deletingLastPathComponent
            if basePath == "/" || basePath == "." { basePath = "" }
            basePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.percentEncodedPath = "/" + ([basePath, path]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private static let unreserved: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func encodedPathComponent(_ value: String) -> String {
        let clean = value.removingPercentEncoding ?? value
        return clean.addingPercentEncoding(withAllowedCharacters: unreserved) ?? clean
    }

    private static func encodedExtra(name: String, value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return "\(encodedPathComponent(name))=\(encodedPathComponent(value))"
    }
}

private struct TmdbCollectionPageResponse: Decodable {
    let page: Int?
    let totalPages: Int?
    let results: [TmdbCollectionItem]

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
    }
}

private struct TmdbCollectionListResponse: Decodable {
    let page: Int?
    let totalPages: Int?
    let items: [TmdbCollectionItem]

    enum CodingKeys: String, CodingKey {
        case page, items
        case totalPages = "total_pages"
    }
}

private struct TmdbCollectionResponse: Decodable {
    let parts: [TmdbCollectionItem]
}

private struct TmdbCollectionCreditsResponse: Decodable {
    let cast: [TmdbCollectionItem]
    let crew: [TmdbCollectionItem]
}

private struct TmdbCollectionItem: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let mediaType: String?
    let job: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, job
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case mediaType = "media_type"
    }
}

private struct MdbListItemsResponse: Decodable {
    let movies: [MdbListEntry]?
    let shows: [MdbListEntry]?
    let pagination: Pagination?

    struct Pagination: Decodable {
        let hasMore: Bool?
        enum CodingKeys: String, CodingKey { case hasMore = "has_more" }
    }
}

private struct MdbListEntry: Decodable {
    let title: String?
    let mediatype: String?
    let imdbId: String?
    let releaseYear: Int?
    let releaseDate: String?
    let rank: Int?
    let ids: IDs?

    var isShow: Bool { (mediatype ?? "").lowercased() == "show" }

    struct IDs: Decodable {
        let imdb: String?
        let tmdb: Int?
    }

    enum CodingKeys: String, CodingKey {
        case title, mediatype, rank, ids
        case imdbId = "imdb_id"
        case releaseYear = "release_year"
        case releaseDate = "release_date"
    }
}

private struct TraktCollectionListItem: Decodable {
    let movie: TraktCollectionMedia?
    let show: TraktCollectionMedia?
}

private struct TraktCollectionMedia: Decodable {
    let title: String?
    let year: Int?
    let ids: TraktCollectionIDs?
    let overview: String?
    let released: String?
    let firstAired: String?
    let rating: Double?
    let genres: [String]?
    let runtime: Int?
    let certification: String?
    let country: String?
    let images: TraktCollectionImages?

    enum CodingKeys: String, CodingKey {
        case title, year, ids, overview, released, rating, genres, runtime
        case certification, country, images
        case firstAired = "first_aired"
    }
}

private struct TraktCollectionIDs: Decodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
}

private struct TraktCollectionImages: Decodable {
    let fanart: [String]?
    let poster: [String]?
    let logo: [String]?
    let clearart: [String]?
    let banner: [String]?
    let thumb: [String]?
}

/// AIOMetadata's catalogs, read without AIOMetadata.
///
/// Community collections built with AIOMetadata name its catalogs
/// (`tmdb.list.8661472.series`, `tmdb.discover.movie.decades.1980s`,
/// `trakt.list.22899376`), which only that add-on, configured as its author's
/// was, can serve. Most say enough in the id to ask TMDB or Trakt directly:
/// - `tmdb.list.<id>[.movies|.series]`: the TMDB list, of that type.
/// - `tmdb.collection.<id>`: the TMDB collection.
/// - `tmdb.discover.<type>.<words>.<suffix>`: a TMDB discover search built
///   from the words: a streaming service ("netflix", "amazon_prime"), a
///   decade ("1980s"; the folder's own title wins, since copied catalogs keep
///   their old name), a year, genres, and "new"/"top" for the order; plus the
///   folder's genre. Ids with none of these are left to the add-on.
/// - `tmdb.top`, `tmdb.trending`, `tmdb.popular`, `tmdb.top_rated`,
///   `tmdb.year`, `tmdb.airing_today`: the matching TMDB order.
/// - `trakt.list.<id>`: the public Trakt list.
enum AIOMetadataFallback {
    static func source(for source: NuvioCollectionSource, folderTitle: String?) -> NuvioCollectionSource? {
        guard let catalogId = source.catalogId?.trimmingCharacters(in: .whitespaces).lowercased(),
              !catalogId.isEmpty else { return nil }
        let parts = catalogId.split(separator: ".").map(String.init)
        let isSeries = (source.type ?? "").lowercased() == "series"
        let mediaType = isSeries ? "tv" : "movie"
        let genreName = source.genre

        if parts.count >= 3, parts[0] == "trakt", parts[1] == "list", let id = Int64(parts[2]) {
            return NuvioCollectionSource(provider: "trakt", title: source.title, traktListId: id, mediaType: mediaType)
        }
        if parts.count >= 2, parts[0] == "mdblist", Int(parts[1]) != nil {
            return NuvioCollectionSource(provider: "mdblist", catalogId: parts[1], title: source.title, mediaType: mediaType)
        }
        guard parts.first == "tmdb", parts.count >= 2 else { return nil }

        switch parts[1] {
        case "list":
            guard parts.count >= 3, let id = Int(parts[2]) else { return nil }
            return NuvioCollectionSource(provider: "tmdb", tmdbSourceType: "LIST", title: source.title, tmdbId: id, mediaType: mediaType)
        case "collection":
            guard parts.count >= 3, let id = Int(parts[2]) else { return nil }
            return NuvioCollectionSource(provider: "tmdb", tmdbSourceType: "COLLECTION", title: source.title, tmdbId: id, mediaType: "movie")
        case "discover":
            let words = parts.dropFirst(3).joined(separator: ".")
            return discover(words: words, mediaType: mediaType, genreName: genreName, folderTitle: folderTitle, title: source.title)
        case "top", "popular", "trending":
            return discoverSource(filters: genreFilters(genreName, mediaType: mediaType), sort: "popularity.desc", mediaType: mediaType, title: source.title)
        case "top_rated":
            var filters = genreFilters(genreName, mediaType: mediaType)
            filters.voteCountGte = 300
            return discoverSource(filters: filters, sort: "vote_average.desc", mediaType: mediaType, title: source.title)
        case "year":
            var filters = NuvioTmdbCollectionFilters()
            filters.year = genreName.flatMap { Int($0) } ?? Calendar.current.component(.year, from: Date())
            return discoverSource(filters: filters, sort: "popularity.desc", mediaType: mediaType, title: source.title)
        case "airing_today":
            var filters = NuvioTmdbCollectionFilters()
            let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            filters.releaseDateGte = today
            filters.releaseDateLte = today
            return discoverSource(filters: filters, sort: "popularity.desc", mediaType: "tv", title: source.title)
        default:
            return nil
        }
    }

    /// "Netflix Series", "1980s Movies", "Movies · Trakt": an AIOMetadata
    /// catalog's id as a tab name, without its random suffix; a list says
    /// whose, so a folder's TMDB and Trakt lists aren't both "Movies".
    static func readableName(for source: NuvioCollectionSource) -> String? {
        guard let catalogId = source.catalogId?.lowercased(),
              catalogId.hasPrefix("tmdb.") || catalogId.hasPrefix("trakt.") || catalogId.hasPrefix("mdblist.") else { return nil }
        let parts = catalogId.split(separator: ".").map(String.init)
        let kind = (source.type ?? "").lowercased() == "series" ? "Series" : "Movies"
        guard parts.count > 2, parts[1] == "discover" else {
            if parts.count > 1, parts[1] == "collection" { return "Collection" }
            let service = ["tmdb": "TMDB", "trakt": "Trakt", "mdblist": "MDBList"][parts[0]] ?? parts[0]
            return "\(kind) · \(service)"
        }
        let isSuffix: (String) -> Bool = { word in
            word.count >= 6 && word.contains(where: \.isNumber) && word.contains(where: \.isLetter)
                && word.range(of: #"^(19|20)\d0s$"#, options: .regularExpression) == nil
        }
        let words = parts.dropFirst(3)
            .flatMap { $0.split(separator: "_").map(String.init) }
            .filter { !isSuffix($0) && !["copy", "decades", "decade", "movie", "movies", "series", "tv"].contains($0) }
        guard !words.isEmpty else { return kind }
        let names = ["hbo": "HBO", "appletv": "Apple TV", "amazon": "Amazon", "max": "Max"]
        let title = words.map { names[$0] ?? ($0.prefix(1).uppercased() + $0.dropFirst()) }.joined(separator: " ")
        return "\(title) \(kind)"
    }

    /// A list mixes films and shows; a catalog of one type keeps its own.
    static func filtered(_ page: CatalogPage, for source: NuvioCollectionSource) -> CatalogPage {
        guard let type = source.type?.lowercased(), type == "movie" || type == "series" else { return page }
        let kept = page.items.filter { $0.type.lowercased() == type }
        return CatalogPage(items: kept, hasMore: page.hasMore, page: page.page, nextSkip: page.nextSkip)
    }

    // MARK: Discover

    private static func discover(
        words: String,
        mediaType: String,
        genreName: String?,
        folderTitle: String?,
        title: String?
    ) -> NuvioCollectionSource? {
        let tokens = words.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "copy" }
        let joined = tokens.joined(separator: " ")
        var filters = genreFilters(genreName, mediaType: mediaType)
        var understood = filters.withGenres != nil

        // A streaming service.
        for (names, providers) in services where names.contains(where: { name in
            (" " + joined + " ").contains(" " + name + " ")
        }) {
            filters.withWatchProviders = providers
            filters.watchRegion = Locale.current.region?.identifier ?? "US"
            understood = true
            break
        }
        // Genres named in the id, beside the folder's.
        let named = tokens.compactMap { genreIDs(mediaType)[$0] }
        if !named.isEmpty {
            filters.withGenres = ([filters.withGenres].compactMap { $0 } + named).joined(separator: ",")
            understood = true
        }
        // A decade: the folder's title first, since a copied catalog keeps the
        // name it was copied from ("1990s_copy" in the 1980s folder).
        if let decade = decade(in: folderTitle ?? "") ?? decade(in: joined) {
            filters.releaseDateGte = "\(decade)-01-01"
            filters.releaseDateLte = "\(decade + 9)-12-31"
            understood = true
        } else if let year = tokens.compactMap({ Int($0) }).first(where: { (1900...2100).contains($0) }) {
            filters.year = year
            understood = true
        }
        guard understood else { return nil }

        var sort = "popularity.desc"
        if tokens.contains(where: { ["new", "latest", "recent", "newest"].contains($0) }) {
            sort = mediaType == "tv" ? "first_air_date.desc" : "primary_release_date.desc"
            if filters.releaseDateLte == nil {
                filters.releaseDateLte = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            }
        } else if tokens.contains(where: { ["top", "best", "rated", "acclaimed"].contains($0) }) {
            sort = "vote_average.desc"
            filters.voteCountGte = 300
        }
        return discoverSource(filters: filters, sort: sort, mediaType: mediaType, title: title)
    }

    private static func discoverSource(
        filters: NuvioTmdbCollectionFilters,
        sort: String,
        mediaType: String,
        title: String?
    ) -> NuvioCollectionSource {
        NuvioCollectionSource(
            provider: "tmdb",
            tmdbSourceType: "DISCOVER",
            title: title,
            mediaType: mediaType,
            sortBy: sort,
            filters: filters
        )
    }

    private static func decade(in text: String) -> Int? {
        let lowered = text.lowercased()
        guard let match = lowered.range(of: #"(19|20)\d0s"#, options: .regularExpression) else {
            // "80s", "90s".
            guard let short = lowered.range(of: #"\b[0-9]0s\b"#, options: .regularExpression),
                  let digit = Int(lowered[short].prefix(1)) else { return nil }
            return digit >= 3 ? 1900 + digit * 10 : 2000 + digit * 10
        }
        return Int(lowered[match].prefix(4))
    }

    private static func genreFilters(_ name: String?, mediaType: String) -> NuvioTmdbCollectionFilters {
        var filters = NuvioTmdbCollectionFilters()
        if let name, let id = genreIDs(mediaType)[name.lowercased()] { filters.withGenres = id }
        return filters
    }

    /// TMDB watch providers: Netflix, Prime Video, Disney+, Apple TV+, Max,
    /// Paramount+, Hulu, Peacock, Crunchyroll, Starz, Showtime, Stan, Binge.
    private static let services: [([String], String)] = [
        (["netflix"], "8"),
        (["amazon", "prime", "primevideo"], "9|119"),
        (["disney", "disneyplus"], "337"),
        (["appletv", "apple"], "350"),
        (["hbo", "max", "hbomax"], "1899|384"),
        (["paramount"], "531"),
        (["hulu"], "15"),
        (["peacock"], "386|387"),
        (["crunchyroll"], "283"),
        (["starz"], "43"),
        (["showtime"], "37"),
        (["stan"], "21"),
        (["binge"], "385"),
    ]

    private static func genreIDs(_ mediaType: String) -> [String: String] {
        mediaType == "tv" ? tvGenres : movieGenres
    }

    private static let movieGenres: [String: String] = [
        "action": "28", "adventure": "12", "animation": "16", "animated": "16", "comedy": "35",
        "crime": "80", "documentary": "99", "drama": "18", "family": "10751", "kids": "10751",
        "fantasy": "14", "history": "36", "horror": "27", "music": "10402", "musical": "10402",
        "mystery": "9648", "romance": "10749", "science fiction": "878", "scifi": "878", "sci": "878",
        "thriller": "53", "war": "10752", "western": "37",
    ]

    private static let tvGenres: [String: String] = [
        "action": "10759", "adventure": "10759", "action & adventure": "10759", "animation": "16",
        "animated": "16", "comedy": "35", "crime": "80", "documentary": "99", "drama": "18",
        "family": "10751", "kids": "10762", "mystery": "9648", "news": "10763", "reality": "10764",
        "sci-fi & fantasy": "10765", "scifi": "10765", "sci": "10765", "fantasy": "10765",
        "soap": "10766", "talk": "10767", "war": "10768", "war & politics": "10768", "western": "37",
    ]
}


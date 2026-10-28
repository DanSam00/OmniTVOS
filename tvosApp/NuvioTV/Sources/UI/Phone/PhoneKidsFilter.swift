#if os(iOS)
import SwiftUI

/// Kids profiles: only titles rated for children are listed.
///
/// A title's official US age rating decides it — up to PG for films and up
/// to TV-G for shows — looked up through TMDB and remembered. Where TMDB
/// has no rating (or "NR") its genres decide: Family or Kids, or older
/// Western animation (the classic shorts and cartoons were never rated);
/// nothing that is also Horror, Thriller, Crime, War, Romance or Reality.
/// Without a TMDB key a genre rule decides instead: family or kids titles
/// only. Either way nothing tagged horror, thriller, crime, war, mystery or
/// adult gets through.
enum PhoneKidsMode {
    static var isActive: Bool {
        #if OMNI_DEBUG_TOOLS
        // `-OmniDebugKids YES`: try Kids filtering on the current profile
        // without changing it (launch arguments aren't saved).
        if UserDefaults.standard.bool(forKey: "OmniDebugKids") { return true }
        #endif
        return ProfileSettings.current.bool(forKey: SettingsKey.kidsProfile)
    }
}

enum KidsContentFilter {
    private static let allowedMovieRatings: Set<String> = ["G", "PG"]
    private static let allowedTVRatings: Set<String> = ["TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G"]
    private static let blockedRatings: Set<String> = ["PG-13", "R", "NC-17", "NR", "TV-PG", "TV-14", "TV-MA"]
    /// For titles without a rating. Animation alone isn't enough: plenty
    /// of anime and adult animation is untagged by rating.
    private static let kidGenres = ["family", "kids", "children"]
    private static let adultGenres = ["horror", "thriller", "crime", "war", "adult", "erotic", "mystery"]

    /// `metas` unchanged outside a Kids profile; otherwise only the allowed
    /// ones, in order.
    static func filterIfNeeded(_ metas: [NuvioMeta]) async -> [NuvioMeta] {
        guard PhoneKidsMode.isActive, !metas.isEmpty else { return metas }
        var allowed = [Bool](repeating: false, count: metas.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            // A handful at a time: a Home load asks about a few hundred titles.
            for _ in 0..<min(8, metas.count) {
                let index = next
                group.addTask { (index, await isAllowed(metas[index])) }
                next += 1
            }
            while let (index, ok) = await group.next() {
                allowed[index] = ok
                if next < metas.count {
                    let index = next
                    group.addTask { (index, await isAllowed(metas[index])) }
                    next += 1
                }
            }
        }
        return metas.indices.filter { allowed[$0] }.map { metas[$0] }
    }

    static func isAllowed(_ meta: NuvioMeta) async -> Bool {
        // Genre first: a PG rating doesn't make a horror or crime title
        // suitable, so these are out whatever the rating says.
        if hasAdultGenre(meta) { return false }
        let rating = await KidsRatingCache.shared.rating(for: meta)
        if rating == KidsRatingCache.unratedForKids { return true }
        if let rating, !rating.isEmpty {
            let normalized = rating.uppercased()
            if allowedMovieRatings.contains(normalized) || allowedTVRatings.contains(normalized) { return true }
            if blockedRatings.contains(normalized) { return false }
        }
        return genreRuleAllows(meta)
    }

    private static func hasAdultGenre(_ meta: NuvioMeta) -> Bool {
        (meta.genres ?? []).contains { genre in
            let genre = genre.lowercased()
            return adultGenres.contains { genre.contains($0) }
        }
    }

    private static func genreRuleAllows(_ meta: NuvioMeta) -> Bool {
        let genres = (meta.genres ?? []).map { $0.lowercased() }
        let isKid = genres.contains { genre in kidGenres.contains { genre.contains($0) } }
        let isAdult = genres.contains { genre in adultGenres.contains { genre.contains($0) } }
        return isKid && !isAdult
    }
}

/// US age ratings from TMDB, kept across launches. An empty string records
/// "looked up, none found" so a title isn't asked about again.
actor KidsRatingCache {
    static let shared = KidsRatingCache()

    /// Stored for a title with no US rating that TMDB's genres say is for
    /// children.
    static let unratedForKids = "~unrated-kids"
    /// v2 judges unrated titles by genre; v1 kept them as "none".
    private static let storageKey = "omni.kids.ratings.v2"
    private var ratings: [String: String]
    private var inFlight: [String: Task<String?, Never>] = [:]

    private init() {
        ratings = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        UserDefaults.standard.removeObject(forKey: "omni.kids.ratings.v1")
    }

    func rating(for meta: NuvioMeta) async -> String? {
        if let certification = meta.certification?.trimmingCharacters(in: .whitespaces), !certification.isEmpty,
           certification.uppercased() != "NR" {
            return certification
        }
        if let known = ratings[meta.id] { return known }
        if let task = inFlight[meta.id] { return await task.value }
        let task = Task { await Self.fetchRating(for: meta) }
        inFlight[meta.id] = task
        let value = await task.value
        inFlight[meta.id] = nil
        // Only remember real answers (a rating, or a definite "none"); a
        // failed request is retried next time.
        if let value {
            ratings[meta.id] = value
            UserDefaults.standard.set(ratings, forKey: Self.storageKey)
        }
        return value
    }

    /// The US certification; `unratedForKids` or "" for a title without
    /// one, by its genres; nil when TMDB couldn't be asked (no key, offline).
    private static func fetchRating(for meta: NuvioMeta) async -> String? {
        let key = TmdbAccountKey.key() ?? ""
        guard !key.isEmpty, let resolved = await TmdbDetailsService.resolveTmdbId(for: meta) else { return nil }
        let isTV = resolved.mediaType == "tv"
        let path = isTV
            ? "tv/\(resolved.id)?append_to_response=content_ratings"
            : "movie/\(resolved.id)?append_to_response=release_dates"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(path)&api_key=\(key)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let results = (json[isTV ? "content_ratings" : "release_dates"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        let us = results.first { ($0["iso_3166_1"] as? String) == "US" }
        let rating: String
        if isTV {
            rating = (us?["rating"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        } else {
            rating = (us?["release_dates"] as? [[String: Any]] ?? [])
                .compactMap { ($0["certification"] as? String)?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
        }
        if !rating.isEmpty, rating.uppercased() != "NR" { return rating }
        let genres = Set((json["genres"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int })
        let language = json["original_language"] as? String ?? ""
        let date = (json["release_date"] as? String) ?? (json["first_air_date"] as? String) ?? ""
        let year = Int(date.prefix(4)) ?? .max
        return unratedIsForKids(genres: genres, language: language, year: year) ? unratedForKids : ""
    }

    /// Family or Kids; or Animation from before 1990 and not Japanese (the
    /// Looney Tunes and Hanna-Barbera era, never rated). Never alongside
    /// Horror, Thriller, Crime, War, Romance or Reality.
    private static func unratedIsForKids(genres: Set<Int>, language: String, year: Int) -> Bool {
        guard genres.isDisjoint(with: [27, 53, 80, 10752, 10749, 10764]) else { return false }
        if !genres.isDisjoint(with: [10751, 10762]) { return true }
        return genres.contains(16) && language != "ja" && year < 1990
    }
}

extension RelatedTitle {
    /// Enough of a title for the Kids check: its ids and type.
    var kidsCheckMeta: NuvioMeta {
        let imdb = id.hasPrefix("tt") ? String(id.split(separator: ":").first ?? "") : nil
        let tmdb = id.hasPrefix("tmdb:") ? Int(id.dropFirst(5)) : nil
        return NuvioMeta(
            id: id, name: name, description: overview, posterUrl: posterURL, backgroundUrl: backdropURL,
            logoUrl: nil, imdbId: imdb, tmdbId: tmdb, type: type, year: nil, genres: nil, rating: rating,
            releaseInfo: year, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil,
            country: nil, released: nil
        )
    }
}

/// Kids profiles: collection folders with nothing a child may watch (every
/// title rated above PG, or nothing loading at all), found by loading each
/// folder's first page in the background, so Home hides them rather than
/// showing a folder that opens empty. Each answer is kept for a day.
@MainActor
final class PhoneKidsFolderAudit: ObservableObject {
    static let shared = PhoneKidsFolderAudit()
    /// Folder ids (`TVCollectionFolderItem.id`) to hide on this profile.
    @Published private(set) var hidden: Set<String> = []

    private static let storageKey = "omni.kids.folderAudit.v1"
    private static let lifetime: TimeInterval = 24 * 3600
    private var profile: String?
    /// Folder id -> [checked at, 1 if empty].
    private var results: [String: [Double]] = [:]
    private var queue: [TVCollectionFolderItem] = []
    private var running = 0
    private let repository: CatalogRepository = CinemetaCatalogRepository()

    func check(_ folders: [TVCollectionFolderItem]) {
        guard PhoneKidsMode.isActive else {
            if !hidden.isEmpty { hidden = [] }
            return
        }
        loadIfProfileChanged()
        let now = Date().timeIntervalSince1970
        let pending = Set(queue.map(\.id))
        for folder in folders where !pending.contains(folder.id) {
            if let result = results[folder.id], now - result[0] < Self.lifetime { continue }
            queue.append(folder)
        }
        pump()
    }

    private func loadIfProfileChanged() {
        let scope = ProfileSettings.activeProfileScope
        guard scope != profile else { return }
        profile = scope
        queue = []
        results = ProfileSettings.current.dictionary(forKey: Self.storageKey) as? [String: [Double]] ?? [:]
        hidden = Set(results.filter { $0.value.count > 1 && $0.value[1] == 1 }.keys)
    }

    private func pump() {
        while running < 3, !queue.isEmpty {
            let folder = queue.removeFirst()
            running += 1
            let scope = profile
            Task {
                let empty = await Self.isEmptyForKids(folder, repository: repository)
                running -= 1
                if let empty, scope == profile {
                    results[folder.id] = [Date().timeIntervalSince1970, empty ? 1 : 0]
                    ProfileSettings.current.set(results, forKey: Self.storageKey)
                    if empty { hidden.insert(folder.id) } else { hidden.remove(folder.id) }
                }
                pump()
            }
        }
    }

    /// True when the first page of up to three of its catalogs holds nothing
    /// a child may watch; nil when it couldn't be asked (offline), so it is
    /// asked again rather than hidden.
    private static func isEmptyForKids(_ folder: TVCollectionFolderItem, repository: CatalogRepository) async -> Bool? {
        var answered = false
        for source in folder.sources.prefix(3) {
            do {
                let page = try await CollectionSourceResolver(repository: repository, folderTitle: folder.title).browse(source)
                answered = true
                if await !KidsContentFilter.filterIfNeeded(page.items).isEmpty { return false }
            } catch let error as URLError where [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cancelled].contains(error.code) {
                continue
            } catch {
                // A source that cannot load (a missing add-on, a key it needs)
                // gives a child nothing either.
                answered = true
            }
        }
        return answered ? true : nil
    }
}

/// Hands `content` the list a Kids profile may see (the list itself
/// otherwise), filtering in the background as the list changes. While a
/// longer list (another page) is checked, the titles already allowed stay.
struct PhoneKidsFiltered<Content: View>: View {
    let items: [NuvioMeta]
    /// The allowed titles, and whether some are still being checked.
    let content: ([NuvioMeta], Bool) -> Content

    @State private var filtered: [NuvioMeta]?
    @State private var filteredIDs: [String] = []

    init(items: [NuvioMeta], @ViewBuilder content: @escaping ([NuvioMeta]) -> Content) {
        self.items = items
        self.content = { visible, _ in content(visible) }
    }

    init(items: [NuvioMeta], @ViewBuilder checking content: @escaping ([NuvioMeta], Bool) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        let ids = items.map(\.id)
        let isKids = PhoneKidsMode.isActive
        let isDone = filteredIDs == ids
        let kept: [NuvioMeta] = {
            guard !isDone else { return filtered ?? [] }
            let current = Set(ids)
            return (filtered ?? []).filter { current.contains($0.id) }
        }()
        content(isKids ? kept : items, isKids && !isDone)
            .task(id: isKids ? ids : []) {
                guard isKids else { return }
                let result = await KidsContentFilter.filterIfNeeded(items)
                guard !Task.isCancelled else { return }
                filtered = result
                filteredIDs = ids
            }
    }
}
#endif

#if os(iOS)
import SwiftUI

/// Kids profiles: only titles rated for children are listed.
///
/// A title's official US age rating decides it — up to PG for films and up
/// to TV-PG for shows — looked up through TMDB and remembered. Where there
/// is no rating (no TMDB key, or TMDB has none) a genre rule decides
/// instead: family, animation or kids titles, and nothing tagged horror,
/// thriller, crime, war or adult.
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
    private static let allowedTVRatings: Set<String> = ["TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "TV-PG"]
    private static let blockedRatings: Set<String> = ["PG-13", "R", "NC-17", "NR", "TV-14", "TV-MA"]
    private static let kidGenres = ["family", "animation", "kids", "children"]
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

    private static let storageKey = "omni.kids.ratings.v1"
    private var ratings: [String: String]
    private var inFlight: [String: Task<String?, Never>] = [:]

    private init() {
        ratings = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func rating(for meta: NuvioMeta) async -> String? {
        if let certification = meta.certification?.trimmingCharacters(in: .whitespaces), !certification.isEmpty {
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

    /// The US certification, "" when TMDB has none, nil when it couldn't be
    /// asked (no key, offline).
    private static func fetchRating(for meta: NuvioMeta) async -> String? {
        let key = ProfileSettings.current.string(forKey: SettingsKey.tmdbApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, let resolved = await TmdbDetailsService.resolveTmdbId(for: meta) else { return nil }
        let isTV = resolved.mediaType == "tv"
        let path = isTV ? "tv/\(resolved.id)/content_ratings" : "movie/\(resolved.id)/release_dates"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(path)?api_key=\(key)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        guard let us = results.first(where: { ($0["iso_3166_1"] as? String) == "US" }) else { return "" }
        if isTV {
            return (us["rating"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let releases = us["release_dates"] as? [[String: Any]] ?? []
        return releases
            .compactMap { ($0["certification"] as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
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

/// Hands `content` the list a Kids profile may see (the list itself
/// otherwise), filtering in the background as the list changes.
struct PhoneKidsFiltered<Content: View>: View {
    let items: [NuvioMeta]
    @ViewBuilder let content: ([NuvioMeta]) -> Content

    @State private var filtered: [NuvioMeta]?
    @State private var filteredIDs: [String] = []

    var body: some View {
        let ids = items.map(\.id)
        let isKids = PhoneKidsMode.isActive
        content(isKids ? (filteredIDs == ids ? filtered ?? [] : []) : items)
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

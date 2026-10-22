import Foundation

/// Finds the previously watched shows that have had a new episode out since
/// the viewer last watched them.
///
/// Continue Watching is built newest-watch first and capped, so a show
/// finished a year ago sits far down a long history and its new season never
/// reaches the row — exactly the card most worth showing. This answers the
/// question for the whole history up front, so those shows can be lifted to
/// the front of the build.
///
/// It uses Cinemeta's batched calendar endpoint, which returns the latest
/// episodes of many series in one request, rather than one full episode guide
/// per show. Answers are kept for three hours.
@MainActor
enum FreshEpisodeScanner {
    private struct Latest {
        let released: Date?
        let fetchedAt: Date
    }

    private static var latestById: [String: Latest] = [:]
    private static let lifetime: TimeInterval = 3 * 3600
    private static let batchSize = 40
    private static let endpoint = "https://v3-cinemeta.strem.io/catalog/series/calendar-videos/calendarVideosIds="

    /// The ids among `shows` with an episode released after the given watch
    /// date and inside the new-episode window.
    static func freshShowIds(_ shows: [(id: String, watchedAt: Date)]) async -> Set<String> {
        let ids = Array(Set(shows.map(\.id).filter { $0.hasPrefix("tt") }))
        let now = Date()
        let stale = ids.filter { id in
            guard let latest = latestById[id] else { return true }
            return now.timeIntervalSince(latest.fetchedAt) > lifetime
        }
        for start in stride(from: 0, to: stale.count, by: batchSize) {
            let batch = Array(stale[start..<min(start + batchSize, stale.count)])
            guard let found = await fetchLatest(batch) else { continue }
            for id in batch {
                latestById[id] = Latest(released: found[id], fetchedAt: now)
            }
        }

        let window = Double(EpisodeReleasePolicy.newEpisodeWindowDays) * 24 * 3600
        var fresh = Set<String>()
        for show in shows {
            guard let released = latestById[show.id]?.released,
                  released > show.watchedAt,
                  now.timeIntervalSince(released) < window else { continue }
            fresh.insert(show.id)
        }
        return fresh
    }

    private struct Response: Decodable {
        struct Meta: Decodable {
            struct Video: Decodable {
                let season: Int?
                let released: String?
            }
            let id: String
            let videos: [Video]?
        }
        let metasDetailed: [Meta]?
    }

    /// Latest aired episode date per id; nil when the request failed.
    private static func fetchLatest(_ ids: [String]) async -> [String: Date]? {
        guard let url = URL(string: endpoint + ids.joined(separator: ",") + ".json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let now = Date()
        var result: [String: Date] = [:]
        for meta in decoded.metasDetailed ?? [] {
            let aired = (meta.videos ?? [])
                .filter { ($0.season ?? 0) > 0 }
                .compactMap { EpisodeReleasePolicy.releaseDate(for: $0.released) }
                .filter { $0 <= now }
            if let latest = aired.max() { result[meta.id] = latest }
        }
        return result
    }
}

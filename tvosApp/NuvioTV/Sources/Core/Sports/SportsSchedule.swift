import Foundation

/// Upcoming fixtures for the Calendar's Sports filter, from TheSportsDB, and
/// the viewer's own IPTV channels that could be showing them.
///
/// Omni lists *when* a match is on; it never supplies the stream. A fixture's
/// page offers the live channels in the viewer's IPTV playlists whose names
/// match its teams or competition.
///
/// TheSportsDB's free test key ("123"; the older "3" is switched off and
/// answers 403) gives only the next match of each competition and about 30
/// requests a minute. Set `TheSportsDBKey` in Info.plist to the project's own
/// key before shipping.
enum SportsSchedule {
    struct League: Hashable {
        let id: String
        let name: String
        /// Words that tell a channel is likely to carry this competition.
        let channelWords: [String]
    }

    /// Competitions shown on the Calendar. Ids are TheSportsDB league ids.
    static let leagues: [League] = [
        League(id: "4328", name: "English Premier League", channelWords: ["premier league", "epl", "sky sports", "tnt sports", "nbc sports", "usa network"]),
        League(id: "4480", name: "UEFA Champions League", channelWords: ["champions league", "ucl", "tnt sports", "cbs sports", "paramount"]),
        League(id: "4335", name: "Spanish La Liga", channelWords: ["la liga", "laliga", "movistar", "espn"]),
        League(id: "4332", name: "Italian Serie A", channelWords: ["serie a", "dazn", "cbs sports"]),
        League(id: "4331", name: "German Bundesliga", channelWords: ["bundesliga", "sky sport", "espn"]),
        League(id: "4334", name: "French Ligue 1", channelWords: ["ligue 1", "bein"]),
        League(id: "4356", name: "Australian A-League Men", channelWords: ["a-league", "a league", "paramount", "network 10", "kayo"]),
        League(id: "4387", name: "NBA", channelWords: ["nba", "espn", "tnt", "abc"]),
        League(id: "4391", name: "NFL", channelWords: ["nfl", "espn", "fox", "cbs", "nbc"]),
        League(id: "4424", name: "MLB", channelWords: ["mlb", "espn", "fox"]),
        League(id: "4380", name: "NHL", channelWords: ["nhl", "espn", "tnt"]),
        League(id: "4370", name: "Formula 1", channelWords: ["formula 1", "f1", "sky sports f1", "espn"]),
        League(id: "4443", name: "UFC", channelWords: ["ufc", "espn", "tnt", "fight"]),
    ]

    private static let apiKey: String = {
        (Bundle.main.object(forInfoDictionaryKey: "TheSportsDBKey") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "123"
    }()

    private static let lock = NSLock()
    private static var metasByID: [String: NuvioMeta] = [:]
    /// Each competition's last answer, kept on disk: the free key allows
    /// about 30 requests a minute, so a launch reuses fresh ones and a
    /// refused request (429) falls back to the last good list instead of
    /// leaving the Calendar empty.
    private static var stored: [String: StoredLeague]?
    /// One fetch at a time: the Calendar and Continue Watching both ask at
    /// launch, and two rounds would spend the minute's requests twice.
    private static var inFlight: Task<[NuvioMeta], Never>?

    private static let freshFor: TimeInterval = 30 * 60

    private struct StoredLeague: Codable {
        let fetchedAt: Date
        let events: [Event]
    }

    private static var storeURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SportsSchedule.json")
    }

    static let idPrefix = "omnisport:"

    static func isFixtureID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// A fixture's page, from the schedule fetched for the Calendar.
    static func meta(forContentID id: String) -> NuvioMeta? {
        lock.lock(); defer { lock.unlock() }
        return metasByID[id]
    }

    /// The next fixtures of each competition, each refreshed when 30 minutes old.
    static func fixtures() async -> [(meta: NuvioMeta, league: League)] {
        let task: Task<[NuvioMeta], Never> = {
            lock.lock(); defer { lock.unlock() }
            if let inFlight { return inFlight }
            let task = Task { await load() }
            inFlight = task
            return task
        }()
        let metas = await task.value
        lock.lock()
        if inFlight == task { inFlight = nil }
        lock.unlock()
        return pair(metas)
    }

    private static func load() async -> [NuvioMeta] {
        var leagueEvents: [String: StoredLeague] = {
            lock.lock(); defer { lock.unlock() }
            if stored == nil {
                stored = storeURL
                    .flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? JSONDecoder().decode([String: StoredLeague].self, from: $0) } ?? [:]
            }
            return stored ?? [:]
        }()
        let due = leagues.filter { league in
            guard let held = leagueEvents[league.id] else { return true }
            return Date().timeIntervalSince(held.fetchedAt) >= freshFor
        }
        if !due.isEmpty {
            let answers: [(String, [Event])] = await withTaskGroup(of: (String, [Event]?).self) { group in
                var index = 0
                var out: [(String, [Event])] = []
                func add(_ league: League) {
                    group.addTask { (league.id, await events(in: league)) }
                }
                while index < min(2, due.count) { add(due[index]); index += 1 }
                for await (id, events) in group {
                    if let events { out.append((id, events)) }
                    if index < due.count { add(due[index]); index += 1 }
                }
                return out
            }
            for (id, events) in answers {
                leagueEvents[id] = StoredLeague(fetchedAt: Date(), events: events)
            }
            if !answers.isEmpty {
                lock.lock(); stored = leagueEvents; lock.unlock()
                if let url = storeURL, let data = try? JSONEncoder().encode(leagueEvents) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        let metas = leagues.flatMap { league in
            (leagueEvents[league.id]?.events ?? []).compactMap { meta(from: $0, league: league) }
        }
        lock.lock()
        for meta in metas { metasByID[meta.id] = meta }
        lock.unlock()
        return metas
    }

    private static func pair(_ metas: [NuvioMeta]) -> [(meta: NuvioMeta, league: League)] {
        metas.compactMap { meta in
            guard let name = meta.genres?.first, let league = leagues.first(where: { $0.name == name }) else { return nil }
            return (meta, league)
        }
    }

    // MARK: TheSportsDB

    private struct Response: Decodable {
        let events: [Event]?
    }

    private struct Event: Codable {
        let idEvent: String
        let strHomeTeam: String?
        let strAwayTeam: String?
        let strEvent: String?
        let strLeague: String?
        let strSport: String?
        let strTimestamp: String?
        let dateEvent: String?
        let strTime: String?
        let strThumb: String?
        let strPoster: String?
    }

    /// The competition's next fixtures, or nil when the request failed (so
    /// the last good answer is kept).
    private static func events(in league: League) async -> [Event]? {
        guard let url = URL(string: "https://www.thesportsdb.com/api/v1/json/\(apiKey)/eventsnextleague.php?id=\(league.id)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return decoded.events ?? []
    }

    private static let releaseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "dd MMM yyyy · HH:mm"
        return formatter
    }()

    /// The kick-off in the viewer's own time zone, for the description;
    /// `releaseInfo` keeps the UTC form other code reads back.
    private static let localKickOffFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM jmm")
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static func meta(from event: Event, league: League) -> NuvioMeta? {
        let title: String
        if let home = event.strHomeTeam, let away = event.strAwayTeam, !home.isEmpty, !away.isEmpty {
            title = "\(home) vs. \(away)"
        } else if let name = event.strEvent, !name.isEmpty {
            title = name
        } else {
            return nil
        }
        let start: Date? = {
            if let stamp = event.strTimestamp, let date = timestampFormatter.date(from: String(stamp.prefix(19))) { return date }
            if let day = event.dateEvent {
                return timestampFormatter.date(from: day + "T" + (event.strTime.map { String($0.prefix(8)) } ?? "00:00:00"))
            }
            return nil
        }()
        guard let start, start > Date().addingTimeInterval(-3 * 3600) else { return nil }
        let when = releaseFormatter.string(from: start) + " UTC"
        let art = event.strThumb ?? event.strPoster
        return NuvioMeta(
            id: idPrefix + event.idEvent,
            name: title,
            // The Calendar already names the competition beside it.
            description: localKickOffFormatter.string(from: start),
            posterUrl: art,
            backgroundUrl: art,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: "sport",
            year: nil,
            genres: [league.name],
            rating: nil,
            releaseInfo: when,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    // MARK: Matching the viewer's IPTV channels

    /// Live channels in the viewer's playlists that could carry this
    /// fixture: those named for both teams (event channels), then for either
    /// team, then sports channels of the competition. Best first, at most 12.
    static func liveStreams(forContentID id: String) async -> [NuvioStream] {
        if meta(forContentID: id) == nil { _ = await fixtures() }
        guard let meta = meta(forContentID: id) else { return [] }
        let channels = await IPTVLibrary.shared.allChannels()
        guard !channels.isEmpty else { return [] }

        let league = leagues.first { $0.name == meta.genres?.first }
        let teams = meta.name
            .components(separatedBy: " vs. ")
            .map(fold)
            .filter { $0.count >= 3 }
        let teamWords = teams.map { $0.split(separator: " ").map(String.init).filter { $0.count >= 4 }.last ?? $0 }
        let words = (league?.channelWords ?? []).map(fold)
        let names = Dictionary(IPTVSourceStore.sources().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        var scored: [(channel: IPTVChannel, score: Int)] = []
        for channel in channels {
            let name = fold(channel.name)
            let group = fold(channel.group)
            var score = 0
            let teamHits = zip(teams, teamWords).filter { name.contains($0.0) || name.contains($0.1) }.count
            score += teamHits * 10
            if teamHits < 2, words.contains(where: { name.contains($0) }) { score += 5 }
            if score > 0, group.contains("sport") { score += 2 }
            if score >= 5 { scored.append((channel, score)) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : IPTVNaming.qualityRank($0.channel.name) > IPTVNaming.qualityRank($1.channel.name) }
            .prefix(12)
            .map { item in
                NuvioStream(
                    url: item.channel.streamURL,
                    name: names[item.channel.sourceID] ?? "IPTV",
                    description: "\(item.channel.name) · \(item.channel.group)",
                    addonName: "IPTV"
                )
            }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 +]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}

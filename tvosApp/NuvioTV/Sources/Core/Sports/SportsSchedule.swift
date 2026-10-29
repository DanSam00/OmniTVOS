import Foundation

/// Upcoming fixtures for the Calendar's Sports filter and favourite teams,
/// from ESPN's public scoreboards, and the viewer's own IPTV channels that
/// could be showing them.
///
/// Omni lists *when* a match is on; it never supplies the stream. A fixture's
/// page offers the live channels in the viewer's IPTV playlists whose names
/// match its teams or competition.
///
/// ESPN needs no key and lists every game (TheSportsDB's free key gave three
/// a day per competition, so most of an NBA night was missing). It takes one
/// day or one month per request, not a range: competitions with games most
/// days are read a day at a time, the rest a month at a time.
enum SportsSchedule {
    struct League: Hashable {
        /// ESPN's league slug ("nba", "eng.1").
        let id: String
        let name: String
        /// Words that tell a channel is likely to carry this competition.
        let channelWords: [String]
        /// ESPN's sport path ("basketball"); empty for a competition only
        /// known from a stored fixture.
        var sport: String = ""
        /// The sport's name as the match art reads it.
        var sportName: String = ""
        /// Games most days: read a day at a time.
        var daily = false
    }

    /// Competitions shown on the Calendar.
    static let leagues: [League] = [
        League(id: "eng.1", name: "English Premier League", channelWords: ["premier league", "epl", "sky sports", "tnt sports", "nbc sports", "usa network"], sport: "soccer", sportName: "Soccer"),
        League(id: "uefa.champions", name: "UEFA Champions League", channelWords: ["champions league", "ucl", "tnt sports", "cbs sports", "paramount"], sport: "soccer", sportName: "Soccer"),
        League(id: "uefa.europa", name: "UEFA Europa League", channelWords: ["europa league", "uel", "tnt sports", "cbs sports", "paramount"], sport: "soccer", sportName: "Soccer"),
        League(id: "eng.fa", name: "English FA Cup", channelWords: ["fa cup", "bbc", "itv", "tnt sports", "espn"], sport: "soccer", sportName: "Soccer"),
        League(id: "eng.league_cup", name: "English Carabao Cup", channelWords: ["carabao", "league cup", "efl", "sky sports", "espn"], sport: "soccer", sportName: "Soccer"),
        League(id: "esp.1", name: "Spanish La Liga", channelWords: ["la liga", "laliga", "movistar", "espn"], sport: "soccer", sportName: "Soccer"),
        League(id: "ita.1", name: "Italian Serie A", channelWords: ["serie a", "dazn", "cbs sports"], sport: "soccer", sportName: "Soccer"),
        League(id: "ger.1", name: "German Bundesliga", channelWords: ["bundesliga", "sky sport", "espn"], sport: "soccer", sportName: "Soccer"),
        League(id: "fra.1", name: "French Ligue 1", channelWords: ["ligue 1", "bein"], sport: "soccer", sportName: "Soccer"),
        League(id: "usa.1", name: "MLS", channelWords: ["mls", "apple tv", "fox"], sport: "soccer", sportName: "Soccer"),
        League(id: "aus.1", name: "Australian A-League Men", channelWords: ["a-league", "a league", "paramount", "network 10", "kayo"], sport: "soccer", sportName: "Soccer"),
        League(id: "nba", name: "NBA", channelWords: ["nba", "espn", "tnt", "abc"], sport: "basketball", sportName: "Basketball", daily: true),
        League(id: "nfl", name: "NFL", channelWords: ["nfl", "espn", "fox", "cbs", "nbc"], sport: "football", sportName: "American Football"),
        League(id: "mlb", name: "MLB", channelWords: ["mlb", "espn", "fox"], sport: "baseball", sportName: "Baseball", daily: true),
        League(id: "nhl", name: "NHL", channelWords: ["nhl", "espn", "tnt"], sport: "hockey", sportName: "Ice Hockey", daily: true),
        League(id: "f1", name: "Formula 1", channelWords: ["formula 1", "f1", "sky sports f1", "espn"], sport: "racing", sportName: "Motorsport"),
        League(id: "ufc", name: "UFC", channelWords: ["ufc", "espn", "tnt", "fight"], sport: "mma", sportName: "MMA"),
    ]

    /// How far ahead daily competitions are read.
    private static let daysAhead = 6

    private static let lock = NSLock()
    private static var metasByID: [String: NuvioMeta] = [:]
    /// Every answer so far, kept on disk: a launch reuses fresh ones, and a
    /// failed request falls back to the last good list instead of leaving
    /// the Calendar empty.
    private static var stored: [String: StoredList]?
    /// One fetch at a time: the Calendar and Continue Watching both ask at
    /// launch.
    private static var inFlight: Task<[(meta: NuvioMeta, league: League)], Never>?

    private struct StoredList: Codable {
        let fetchedAt: Date
        let fixtures: [Fixture]
    }

    /// One game, as much of ESPN's answer as is kept.
    private struct Fixture: Codable {
        let id: String
        let title: String
        let start: Date
        /// ESPN's "pre", "in" or "post".
        let state: String
    }

    private static var storeURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SportsSchedule.espn.json")
    }

    static let idPrefix = "omnisport:"

    static func isFixtureID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// A fixture's page, from the schedule fetched for the Calendar.
    static func meta(forContentID id: String) -> NuvioMeta? {
        lock.lock(); defer { lock.unlock() }
        return metasByID[id]
    }

    /// Every competition's games from yesterday to a week ahead, the ones
    /// under way included.
    static func fixtures() async -> [(meta: NuvioMeta, league: League)] {
        let task: Task<[(meta: NuvioMeta, league: League)], Never> = {
            lock.lock(); defer { lock.unlock() }
            if let inFlight { return inFlight }
            let task = Task { await load() }
            inFlight = task
            return task
        }()
        let fixtures = await task.value
        lock.lock()
        if inFlight == task { inFlight = nil }
        lock.unlock()
        return fixtures
    }

    /// One scoreboard and how long its answer stays good.
    private struct Request {
        let key: String
        let league: League
        /// ESPN's `dates`: a day (`20261029`) or a month (`202610`).
        let dates: String
        let freshFor: TimeInterval
    }

    private static func requests() -> [Request] {
        let now = Date()
        let today = dayFormatter.string(from: now)
        let thisMonth = monthFormatter.string(from: now)
        var out: [Request] = []
        for league in leagues {
            if league.daily {
                for offset in -1...daysAhead {
                    let day = dayFormatter.string(from: now.addingTimeInterval(Double(offset) * 86_400))
                    // Today's and yesterday's (tonight's games in ESPN's US
                    // dates) change as they are played; later ones rarely.
                    let current = day <= today
                    out.append(Request(key: "\(league.id):\(day)", league: league, dates: day, freshFor: current ? 15 * 60 : 6 * 3600))
                }
            } else {
                let months = Set([-86_400.0, 0, Double(daysAhead + 7) * 86_400].map {
                    monthFormatter.string(from: now.addingTimeInterval($0))
                }).sorted()
                for month in months {
                    out.append(Request(key: "\(league.id):\(month)", league: league, dates: month, freshFor: month == thisMonth ? 15 * 60 : 6 * 3600))
                }
            }
        }
        return out
    }

    private static func load() async -> [(meta: NuvioMeta, league: League)] {
        var lists: [String: StoredList] = {
            lock.lock(); defer { lock.unlock() }
            if stored == nil {
                stored = storeURL
                    .flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? JSONDecoder().decode([String: StoredList].self, from: $0) } ?? [:]
            }
            return stored ?? [:]
        }()
        let all = requests()
        var queue = all.filter { request in
            guard let held = lists[request.key] else { return true }
            return Date().timeIntervalSince(held.fetchedAt) >= request.freshFor
        }
        var changed = false
        while !queue.isEmpty {
            let batch = Array(queue.prefix(6))
            queue.removeFirst(batch.count)
            let answers = await withTaskGroup(of: (String, [Fixture]?).self) { group in
                for request in batch {
                    group.addTask { (request.key, await scoreboard(request)) }
                }
                var out: [(String, [Fixture]?)] = []
                for await answer in group { out.append(answer) }
                return out
            }
            for case let (key, fixtures?) in answers {
                lists[key] = StoredList(fetchedAt: Date(), fixtures: fixtures)
                changed = true
            }
        }
        if changed {
            // Days and months no longer asked for.
            let wanted = Set(all.map(\.key))
            lists = lists.filter { wanted.contains($0.key) }
            lock.lock(); stored = lists; lock.unlock()
            if let url = storeURL, let data = try? JSONEncoder().encode(lists) {
                try? data.write(to: url, options: .atomic)
            }
        }

        var seen = Set<String>()
        var fixtures: [(meta: NuvioMeta, league: League)] = []
        for request in all {
            for fixture in lists[request.key]?.fixtures ?? [] where seen.insert(fixture.id).inserted {
                if let meta = meta(from: fixture, league: request.league) { fixtures.append((meta, request.league)) }
            }
        }
        lock.lock()
        for fixture in fixtures { metasByID[fixture.meta.id] = fixture.meta }
        lock.unlock()
        return fixtures
    }

    // MARK: ESPN

    private struct Scoreboard: Decodable {
        struct Event: Decodable {
            struct Competition: Decodable {
                struct Competitor: Decodable {
                    struct Team: Decodable { let displayName: String? }
                    let homeAway: String?
                    let team: Team?
                }
                let competitors: [Competitor]?
            }
            struct Status: Decodable {
                struct Kind: Decodable { let state: String? }
                let type: Kind?
            }
            let id: String
            let date: String
            let name: String?
            let competitions: [Competition]?
            let status: Status?
        }
        let events: [Event]?
    }

    /// One day's or month's games, or nil when the request failed (so the
    /// last good answer is kept).
    private static func scoreboard(_ request: Request) async -> [Fixture]? {
        let path = "https://site.api.espn.com/apis/site/v2/sports/\(request.league.sport)/\(request.league.id)/scoreboard?dates=\(request.dates)&limit=300"
        guard let url = URL(string: path) else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: urlRequest),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let board = try? JSONDecoder().decode(Scoreboard.self, from: data) else { return nil }
        return (board.events ?? []).compactMap { event in
            guard let start = espnDate(event.date) else { return nil }
            let sides = event.competitions?.first?.competitors ?? []
            let home = sides.first { $0.homeAway == "home" }?.team?.displayName
            let away = sides.first { $0.homeAway == "away" }?.team?.displayName
            let title: String
            if let home, let away, !home.isEmpty, !away.isEmpty {
                title = "\(home) vs. \(away)"
            } else if let name = event.name, !name.isEmpty {
                title = name
            } else {
                return nil
            }
            return Fixture(id: event.id, title: title, start: start, state: event.status?.type?.state ?? "pre")
        }
    }

    /// ESPN writes "2026-10-28T23:00Z", usually without seconds.
    private static func espnDate(_ text: String) -> Date? {
        espnMinuteFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static let espnMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmX"
        return formatter
    }()

    /// ESPN's days are the US East Coast's.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyyMM"
        return formatter
    }()

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

    private static func meta(from fixture: Fixture, league: League) -> NuvioMeta? {
        // Finished games go; one ESPN still shows as not started hours after
        // its time has likely been played or called off.
        guard fixture.state != "post", fixture.start > Date().addingTimeInterval(-4 * 3600) else { return nil }
        let isLive = fixture.state == "in"
        // Live games say so: Continue Watching and the Calendar read "LIVE"
        // as under way now.
        let when = isLive ? "LIVE" : releaseFormatter.string(from: fixture.start) + " UTC"
        return NuvioMeta(
            id: idPrefix + fixture.id,
            name: fixture.title,
            // The Calendar already names the competition beside it.
            description: localKickOffFormatter.string(from: fixture.start),
            // The app draws the match's art from the teams' crests.
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: "sport",
            year: nil,
            // The competition, then the sport the match art reads.
            genres: [league.name, league.sportName].filter { !$0.isEmpty },
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
            ?? meta.genres?.first.map { League(id: $0, name: $0, channelWords: [$0]) }
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

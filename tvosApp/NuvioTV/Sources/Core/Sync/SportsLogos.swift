import Foundation

/// Team crests, colours and league badges from ESPN's public site API.
///
/// ESPN lists a whole league's teams, logos and colours in one request and
/// does not hold callers to TheSportsDB's 30 requests a minute, so most
/// matches are drawn from this; TheSportsDB covers the rest (cricket, rugby,
/// smaller leagues). Each sport's leagues are fetched once and kept on disk
/// for a week.
@MainActor
enum SportsLogos {
    struct Team: Codable {
        let names: [String]
        let logo: String?
        let colour: String?
        let secondColour: String?
    }

    struct League: Codable {
        let slug: String
        let name: String
        let logo: String?
        let teams: [Team]
    }

    struct Match {
        let home: Team?
        let away: Team?
        /// The league both play in, when there is one.
        let league: League?
    }

    /// ESPN's leagues for each of TheSportsDB's sport names.
    private static let leaguesBySport: [String: (path: String, leagues: [String])] = [
        "Basketball": ("basketball", ["nba", "wnba", "nbl", "euroleague", "mens-college-basketball"]),
        "Soccer": ("soccer", [
            "uefa.champions", "uefa.europa", "uefa.europa.conf", "eng.1", "eng.2", "esp.1", "ita.1", "ger.1",
            "fra.1", "ned.1", "por.1", "sco.1", "bel.1", "tur.1", "usa.1", "mex.1", "bra.1", "arg.1", "aus.1",
            "ksa.1", "conmebol.libertadores",
        ]),
        "American Football": ("football", ["nfl", "college-football"]),
        "Ice Hockey": ("hockey", ["nhl"]),
        "Baseball": ("baseball", ["mlb"]),
        "Australian Football": ("australian-football", ["afl"]),
    ]

    private static var bySport: [String: [League]] = [:]
    private static var loading: [String: Task<[League]?, Never>] = [:]
    private static let lifetime: TimeInterval = 7 * 24 * 3600

    /// Both teams, and their shared league, for a sport ESPN covers. Nil when
    /// the sport is not one, or its leagues could not be fetched.
    static func match(home: String, away: String, sport: String?) async -> Match? {
        guard let sport, leaguesBySport[sport] != nil, let leagues = await leagues(for: sport) else { return nil }
        let homeHits = candidates(for: home, in: leagues)
        let awayHits = candidates(for: away, in: leagues)
        // The league both sides play in decides between namesakes ("Liberty"
        // is a college side and, as New York Liberty, a WNBA one).
        var best: (score: Int, league: League, home: Team, away: Team)?
        for h in homeHits {
            for a in awayHits where a.league.slug == h.league.slug {
                let score = h.score + a.score
                if best == nil || score > best!.score { best = (score, h.league, h.team, a.team) }
            }
        }
        if let best { return Match(home: best.home, away: best.away, league: best.league) }
        return Match(home: homeHits.max { $0.score < $1.score }?.team, away: awayHits.max { $0.score < $1.score }?.team, league: nil)
    }

    // MARK: Matching

    private static func candidates(for name: String, in leagues: [League]) -> [(score: Int, league: League, team: Team)] {
        let wanted = normalised(name)
        guard !wanted.isEmpty else { return [] }
        let wantedWords = Set(wanted.split(separator: " "))
        var hits: [(Int, League, Team)] = []
        for league in leagues {
            for team in league.teams {
                let names = team.names.map(normalised)
                var score = 0
                if names.first == wanted {
                    score = 3   // the full name
                } else if names.contains(wanted) {
                    score = 2   // its short name, nickname or town
                } else if let full = names.first, !full.isEmpty {
                    let fullWords = Set(full.split(separator: " "))
                    // "Zalgiris" for "Zalgiris Kaunas"; "Olympiacos BC" trimmed.
                    if wantedWords.isSubset(of: fullWords) || fullWords.isSubset(of: wantedWords) { score = 1 }
                }
                if score > 0 { hits.append((score, league, team)) }
            }
        }
        return hits
    }

    private static let clubWords: Set<Substring> = ["fc", "cf", "afc", "sc", "bc", "fk", "sk", "ac", "as", "cd", "club", "the"]

    static func normalised(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .filter { !clubWords.contains(Substring($0)) }
            .joined(separator: " ")
    }

    // MARK: Fetching

    private struct Stored: Codable {
        let leagues: [League]
        let savedAt: Date
    }

    private static func leagues(for sport: String) async -> [League]? {
        if let known = bySport[sport] { return known }
        if let stored = load(sport), Date().timeIntervalSince(stored.savedAt) < lifetime {
            bySport[sport] = stored.leagues
            return stored.leagues
        }
        if let pending = loading[sport] { return await pending.value }
        guard let spec = leaguesBySport[sport] else { return nil }
        let task = Task<[League]?, Never> {
            var fetched: [League] = []
            await withTaskGroup(of: League?.self) { group in
                for slug in spec.leagues {
                    group.addTask { await fetchLeague(path: spec.path, slug: slug) }
                }
                for await league in group { if let league { fetched.append(league) } }
            }
            // Keep the configured order: competitions before domestic leagues.
            return spec.leagues.compactMap { slug in fetched.first { $0.slug == slug } }
        }
        loading[sport] = task
        let leagues = await task.value
        loading[sport] = nil
        guard let leagues, !leagues.isEmpty else { return nil }
        bySport[sport] = leagues
        save(sport, Stored(leagues: leagues, savedAt: Date()))
        return leagues
    }

    private struct TeamsResponse: Decodable {
        struct Sport: Decodable { let leagues: [LeagueDTO]? }
        struct LeagueDTO: Decodable {
            let name: String?
            let teams: [Entry]?
        }
        struct Entry: Decodable { let team: TeamDTO }
        struct TeamDTO: Decodable {
            let displayName: String?
            let shortDisplayName: String?
            let name: String?
            let nickname: String?
            let location: String?
            let color: String?
            let alternateColor: String?
            let logos: [Logo]?
        }
        struct Logo: Decodable {
            let href: String?
            let rel: [String]?
        }
        let sports: [Sport]?
    }

    private struct ScoreboardResponse: Decodable {
        struct LeagueDTO: Decodable { let logos: [TeamsResponse.Logo]? }
        let leagues: [LeagueDTO]?
    }

    nonisolated private static func fetchLeague(path: String, slug: String) async -> League? {
        let base = "https://site.api.espn.com/apis/site/v2/sports/\(path)/\(slug)"
        guard let teamsURL = URL(string: base + "/teams?limit=1000"),
              let (data, response) = try? await URLSession.shared.data(from: teamsURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TeamsResponse.self, from: data),
              let league = decoded.sports?.first?.leagues?.first else { return nil }
        let teams: [Team] = (league.teams ?? []).map { entry in
            let team = entry.team
            // The plain logo; the "dark" one is drawn for dark grounds but
            // some teams have only that.
            let logo = team.logos?.first(where: { !($0.rel ?? []).contains("dark") })?.href ?? team.logos?.first?.href
            return Team(
                names: [team.displayName, team.shortDisplayName, team.name, team.nickname, team.location]
                    .compactMap { $0 }.filter { !$0.isEmpty },
                logo: logo,
                colour: team.color,
                secondColour: team.alternateColor
            )
        }
        var leagueLogo: String?
        if let boardURL = URL(string: base + "/scoreboard"),
           let (board, _) = try? await URLSession.shared.data(from: boardURL),
           let logos = (try? JSONDecoder().decode(ScoreboardResponse.self, from: board))?.leagues?.first?.logos {
            // The version made for a dark ground, which the art is.
            leagueLogo = logos.first(where: { ($0.rel ?? []).contains("dark") })?.href ?? logos.first?.href
        }
        return League(slug: slug, name: league.name ?? slug, logo: leagueLogo, teams: teams)
    }

    private static func file(_ sport: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("espn-teams-\(sport.lowercased().replacingOccurrences(of: " ", with: "-")).json")
    }

    private static func load(_ sport: String) -> Stored? {
        guard let file = file(sport), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func save(_ sport: String, _ stored: Stored) {
        guard let file = file(sport), let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Art for a match, drawn by the app: "Team A v Team B" as a broadcaster
/// would draw it — each team's colours on its side of a diagonal, its crest
/// large on that side, the competition's badge between them.
///
/// Sports add-ons give a fixture one small 16:9 picture with both crests baked
/// in, which a portrait hero crops and a large one blows up into blocks. Every
/// sports listing whose name reads as two teams ("Juventus vs. Stade Rennais",
/// "New Zealand vs India - 1st T20I") gets this instead, on tiles, heroes, its
/// page and the widgets.
///
/// Drawn on demand: a match's art addresses use the `omni-fixture` scheme,
/// which `FixtureArtURLProtocol` answers by drawing the picture the first time
/// something shows it and keeping it on disk. A catalog of two hundred
/// fixtures costs nothing until one is on screen.
///
/// Crests, colours and league badges come from TheSportsDB's free tier (no
/// account). A team it does not know gets a monogram in a colour from its name.
enum FixtureArtwork {
    static let scheme = "omni-fixture"

    enum Shape: String {
        case portrait = "p"
        /// Wide, the match centred: tiles, and the iPhone's pages, which crop
        /// the sides.
        case landscape = "l"
        /// Wide, the match on the right: Apple TV and Mac heroes and pages put
        /// the title and buttons over the left.
        case backdrop = "b"

        var size: CGSize {
            self == .portrait ? CGSize(width: 1000, height: 1500) : CGSize(width: 1600, height: 900)
        }
    }

    /// The wide shape this platform uses for a listing's background.
    static var wideShape: Shape {
        #if os(iOS)
        .landscape
        #else
        .backdrop
        #endif
    }

    // MARK: Addresses

    /// Posted (debounced) when newly drawn pictures are ready, so screens
    /// showing a match's add-on image can swap in the art.
    static let artDrawnNotification = Notification.Name("omni.fixtureArt.drawn")

    /// The listing with the app's art when it is a match whose art is drawn.
    ///
    /// Until then it keeps the add-on's own image — on a slow connection the
    /// first drawing takes a while, and a blank tile is worse than a rough
    /// one — and the match joins the queue to be drawn in the background.
    /// `artDrawnNotification` tells screens to call this again.
    static func decorated(_ meta: NuvioMeta) -> NuvioMeta {
        guard isMatchCached(meta) else { return meta }
        let genres = meta.genres ?? []
        guard isDrawn(title: meta.name, genres: genres),
              let poster = artURL(for: meta, shape: .portrait),
              let background = artURL(for: meta, shape: wideShape) else {
            enqueue(title: meta.name, genres: genres)
            return meta
        }
        // The add-on's logo (its own badge) does not belong over the match.
        return meta.withArtwork(poster: poster, background: background, dropsLogo: true)
    }

    /// The address to hand SwiftUI's `AsyncImage`, which does not go through
    /// `FixtureArtURLProtocol`: match art as its saved file, anything else
    /// unchanged. Art addresses are only given out once the file is saved.
    static func displayURL(_ url: URL?) -> URL? {
        guard let url, url.scheme == scheme,
              let shape = Shape(rawValue: String(url.path.dropFirst())),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let title = query.first(where: { $0.name == "t" })?.value else { return url }
        let genres = (query.first(where: { $0.name == "g" })?.value ?? "")
            .split(separator: "|").map(String.init).filter { !$0.isEmpty }
        guard let file = drawnFile(title: title, genres: genres, shape: shape),
              FileManager.default.fileExists(atPath: file.path) else { return url }
        return file
    }

    /// Draws a match's art now, for the few cards that should never show the
    /// add-on's image (your teams' matches). True when it is ready.
    @MainActor
    static func ensureDrawn(_ meta: NuvioMeta) async -> Bool {
        guard isMatch(meta) else { return false }
        let genres = meta.genres ?? []
        if isDrawn(title: meta.name, genres: genres) { return true }
        await draw(title: meta.name, genres: genres)
        return isDrawn(title: meta.name, genres: genres)
    }

    // MARK: Background drawing

    @MainActor private static var queue: [(title: String, genres: [String])] = []
    @MainActor private static var queuedKeys: Set<String> = []
    /// When each match was last tried, so one that cannot be drawn yet (its
    /// lookups failing) is not retried on every refresh.
    @MainActor private static var lastTried: [String: Date] = [:]
    @MainActor private static var isDrawing = false
    @MainActor private static var announceTask: Task<Void, Never>?

    /// Puts a match on screen at the front of the queue. Home reads several
    /// sports catalogs at once, a few hundred matches, and TheSportsDB allows
    /// one request every two seconds: in listing order, the tiles being
    /// looked at could wait many minutes.
    static func prioritise(_ meta: NuvioMeta) {
        guard isMatchCached(meta), !isDrawn(title: meta.name, genres: meta.genres ?? []) else { return }
        enqueue(title: meta.name, genres: meta.genres ?? [], atFront: true)
    }

    private static func enqueue(title: String, genres: [String], atFront: Bool = false) {
        Task { @MainActor in
            let key = artKey(title: title, genres: genres)
            if atFront {
                // Moved up even when already waiting; a recent failure still
                // holds it back.
                guard lastTried[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
                queue.removeAll { artKey(title: $0.title, genres: $0.genres) == key }
                queuedKeys.insert(key)
                queue.insert((title, genres), at: 0)
            } else {
                guard !queuedKeys.contains(key),
                      lastTried[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
                queuedKeys.insert(key)
                queue.append((title, genres))
            }
            guard !isDrawing else { return }
            isDrawing = true
            while !queue.isEmpty {
                let next = queue.removeFirst()
                let nextKey = artKey(title: next.title, genres: next.genres)
                lastTried[nextKey] = Date()
                await draw(title: next.title, genres: next.genres)
                queuedKeys.remove(nextKey)
                if isDrawn(title: next.title, genres: next.genres) { announce() }
            }
            isDrawing = false
        }
    }

    @MainActor
    private static func draw(title: String, genres: [String]) async {
        for shape in [Shape.portrait, wideShape] {
            guard let url = artURL(title: title, genres: genres, shape: shape).flatMap(URL.init(string:)) else { continue }
            _ = await imageData(for: url)
        }
    }

    /// Batches notices: a row of matches finishing together refreshes once.
    @MainActor
    private static func announce() {
        guard announceTask == nil else { return }
        announceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            announceTask = nil
            NotificationCenter.default.post(name: artDrawnNotification, object: nil)
        }
    }

    private static let matchLock = NSLock()
    nonisolated(unsafe) private static var matchMemo: [String: Bool] = [:]

    /// `isMatch`, remembered: screens ask on every redraw.
    private static func isMatchCached(_ meta: NuvioMeta) -> Bool {
        let key = meta.type + "|" + meta.id + "|" + meta.name + "|" + (meta.genres ?? []).joined(separator: "|")
        matchLock.lock()
        if let known = matchMemo[key] { matchLock.unlock(); return known }
        matchLock.unlock()
        let answer = isMatch(meta)
        matchLock.lock()
        if matchMemo.count > 4000 { matchMemo.removeAll() }
        matchMemo[key] = answer
        matchLock.unlock()
        return answer
    }

    /// A sports listing naming two teams: a "sport" item, or a live one
    /// from a sports add-on ("tv", `nuvio_sport_…`). Never a film or a show,
    /// whatever its name ("Coyote vs. Acme").
    static func isMatch(_ meta: NuvioMeta) -> Bool {
        let type = meta.type.lowercased()
        let genres = (meta.genres ?? []).map { $0.lowercased() }
        // Some add-ons list matches as films ("Real Madrid vs RB Leipzig",
        // genres Soccer, La Liga): a sports genre says what they are.
        let sportsGenre = genres.contains { genre in sportWords.contains { genre.contains($0) } }
        if ["movie", "series"].contains(type), !sportsGenre { return false }
        let isSports = type.contains("sport") || meta.id.lowercased().contains("sport") || sportsGenre
        return isSports && teams(in: meta.name) != nil
    }

    private static let sportWords = [
        "soccer", "football", "basketball", "cricket", "rugby", "tennis", "hockey", "baseball", "volleyball",
        "handball", "nfl", "nba", "nhl", "mlb", "afl", "nrl", "mma", "ufc", "boxing", "motorsport", "formula",
        "golf", "la liga", "laliga", "premier league", "serie a", "bundesliga", "ligue 1", "champions league",
        "europa league", "uefa", "mls", "eredivisie",
    ]

    static func artURL(for meta: NuvioMeta, shape: Shape) -> String? {
        artURL(title: meta.name, genres: meta.genres ?? [], shape: shape)
    }

    static func artURL(title: String, genres: [String], shape: Shape) -> String? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "art"
        components.path = "/" + shape.rawValue
        components.queryItems = [
            URLQueryItem(name: "t", value: title),
            URLQueryItem(name: "g", value: genres.joined(separator: "|")),
            URLQueryItem(name: "v", value: String(designVersion)),
        ]
        return components.url?.absoluteString
    }

    // MARK: Reading the fixture

    /// "Juventus vs. Stade Rennais", "New Zealand vs India - 1st T20I",
    /// "Arsenal v Chelsea", "Lakers @ Celtics", "🔴 LIVE: WTA - Singles:
    /// Katie Boulter vs Viktorija Golubic" → the two teams, and the match's
    /// label from before or after them.
    static func teams(in title: String) -> (home: String, away: String, suffix: String?)? {
        let versus = #"\s(vs\.?|v|@)\s"#
        // A live marker in front ("🔴 LIVE: ") is not part of the match.
        var text = title.replacingOccurrences(
            of: #"^[^\p{L}\p{N}]*(live\s*[:\-–]\s*)?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        var prefix: String?
        // "WTA - Singles: A vs B": the competition before a colon.
        if let colon = text.range(of: ": "),
           text[colon.upperBound...].range(of: versus, options: [.regularExpression, .caseInsensitive]) != nil,
           text[..<colon.lowerBound].range(of: versus, options: [.regularExpression, .caseInsensitive]) == nil {
            prefix = text[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            text = String(text[colon.upperBound...])
        }
        var suffix: String?
        for separator in [" - ", " – ", " — ", " | "] {
            if let range = text.range(of: separator) {
                let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let head = String(text[..<range.lowerBound])
                // Only a tail after the teams, not a hyphen inside one name.
                if head.range(of: versus, options: [.regularExpression, .caseInsensitive]) != nil {
                    text = head
                    suffix = tail.isEmpty ? nil : tail
                    break
                }
            }
        }
        guard let range = text.range(of: versus, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let home = cleanTeamName(String(text[..<range.lowerBound]))
        let away = cleanTeamName(String(text[range.upperBound...]))
        guard !home.isEmpty, !away.isEmpty else { return nil }
        let label = [prefix, suffix].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return (home, away, label.isEmpty ? nil : label)
    }

    /// A team's name without what listings tack on after it: "RB Leipzig UEFA
    /// Champions League Football download free at Real Madrid" → "RB Leipzig",
    /// "Arsenal (H)" → "Arsenal".
    static func cleanTeamName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: #"\s*[\(\[].*$"#, with: "", options: .regularExpression)
        let noise = #"(?i)\s(uefa|champions league|europa league|conference league|premier league|la ?liga|serie a|bundesliga|ligue 1|eredivisie|mls|football|soccer|download|highlights|full match|replay|live stream|stream|free|hd|fhd|4k)\b.*$"#
        name = name.replacingOccurrences(of: noise, with: "", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// TheSportsDB's sport for the listing, to pick India's cricket side for a
    /// T20 rather than its football team.
    private static func sportHint(title: String, genres: [String]) -> String? {
        let text = ([title] + genres).joined(separator: " ").lowercased()
        let hints: [(String, String)] = [
            ("cricket", "Cricket"), ("t20", "Cricket"), ("odi", "Cricket"), ("test day", "Cricket"),
            ("nfl", "American Football"), ("american football", "American Football"),
            ("nba", "Basketball"), ("basketball", "Basketball"), ("nhl", "Ice Hockey"), ("hockey", "Ice Hockey"),
            ("mlb", "Baseball"), ("baseball", "Baseball"), ("nrl", "Rugby"), ("rugby", "Rugby"),
            ("afl", "Australian Football"),
            ("football", "Soccer"), ("soccer", "Soccer"), ("premier league", "Soccer"), ("uefa", "Soccer"),
        ]
        return hints.first(where: { text.contains($0.0) })?.1
    }

    // MARK: Drawing

    /// The design's version. Part of every art address, so a new design is a
    /// new address and no image cache keeps showing the old one.
    static let designVersion = 15
    private static var folderName: String { "fixture-art-v\(designVersion)" }

    /// The picture behind an `omni-fixture` address, drawn once and kept.
    @MainActor
    static func imageData(for url: URL) async -> Data? {
        guard url.scheme == scheme,
              let shape = Shape(rawValue: String(url.path.dropFirst())),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let title = query.first(where: { $0.name == "t" })?.value,
              let names = teams(in: title) else { return nil }
        let genres = (query.first(where: { $0.name == "g" })?.value ?? "")
            .split(separator: "|").map(String.init).filter { !$0.isEmpty }

        let file = drawnFile(title: title, genres: genres, shape: shape)
        if let file, let data = try? Data(contentsOf: file) { return data }

        let sport = sportHint(title: title, genres: genres)
        // ESPN first (a whole league per request, no tight limit), then
        // TheSportsDB for a side it does not know.
        let espn = await SportsLogos.match(home: names.home, away: names.away, sport: sport)
        var (home, homeAnswered) = await espnTeam(espn?.home, named: names.home)
        if home == nil { (home, homeAnswered) = await team(named: names.home, sport: sport) }
        var (away, awayAnswered) = await espnTeam(espn?.away, named: names.away)
        if away == nil { (away, awayAnswered) = await team(named: names.away, sport: sport) }
        let homeSide = home!, awaySide = away!
        let badge: CGImage?
        let badgeAnswered: Bool
        if let league = espn?.league {
            badge = await image(at: league.logo)
            badgeAnswered = league.logo == nil || badge != nil
        } else {
            (badge, badgeAnswered) = await leagueBadge(
                home: homeSide, away: awaySide, listing: ([title] + genres).joined(separator: " ")
            )
        }
        // Kept only when every lookup was answered: a picture drawn while
        // TheSportsDB was busy is shown now and drawn again next time.
        let complete = homeAnswered && awayAnswered && badgeAnswered
        // The badge stands for the competition; without one, the sport is
        // written instead. A match label ("1st T20I") is kept either way.
        let sportName = genres.first(where: { !$0.contains("-") })
        let label = badge == nil ? [sportName, names.suffix].compactMap { $0 }.joined(separator: " · ") : names.suffix

        let renderer = ImageRenderer(
            content: FixtureArtView(home: homeSide, away: awaySide, badge: badge, label: label?.nilIfEmpty, shape: shape)
                .frame(width: shape.size.width, height: shape.size.height)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = jpeg(image) else { return nil }
        if complete, let file { try? data.write(to: file, options: .atomic) }
        return data
    }

    // MARK: Teams

    private struct Team {
        let name: String
        let crest: CGImage?
        /// The crest is a country's flag.
        var isFlag = false
        let colour: Color
        let secondColour: Color
        /// The competitions it plays in, as (id, name), main league first.
        let leagues: [(id: String, name: String)]
    }

    /// What TheSportsDB said about a team. Saved, so each team is asked once.
    private struct TeamRecord: Codable {
        struct League: Codable {
            let id: String
            let name: String
        }
        let crest: String?
        let colour: String?
        let secondColour: String?
        let leagues: [League]
        let savedAt: Date
    }

    private struct LookupStore: Codable {
        var teams: [String: TeamRecord] = [:]
        /// League id → badge address ("" when it has none).
        var leagueBadges: [String: String] = [:]
    }

    @MainActor private static var store: LookupStore = loadStore()
    /// When the next TheSportsDB request may go: its free tier allows about
    /// 30 a minute, and a row of matches asks for far more at once. Going
    /// over failed whole rows into monograms.
    @MainActor private static var nextRequestSlot = Date.distantPast

    private struct SearchResponse: Decodable {
        struct Team: Decodable {
            let strSport: String?
            let strBadge: String?
            let strColour1: String?
            let strColour2: String?
            let strLeague: String?, idLeague: String?
            let strLeague2: String?, idLeague2: String?
            let strLeague3: String?, idLeague3: String?
            let strLeague4: String?, idLeague4: String?
            let strLeague5: String?, idLeague5: String?
            let strLeague6: String?, idLeague6: String?
            let strLeague7: String?, idLeague7: String?

            var leagues: [TeamRecord.League] {
                [(idLeague, strLeague), (idLeague2, strLeague2), (idLeague3, strLeague3), (idLeague4, strLeague4),
                 (idLeague5, strLeague5), (idLeague6, strLeague6), (idLeague7, strLeague7)]
                    .compactMap { id, name in
                        guard let id, !id.isEmpty, let name, !name.isEmpty else { return nil }
                        return TeamRecord.League(id: id, name: name)
                    }
            }
        }
        let teams: [Team]?
    }

    /// While TheSportsDB is turning requests away, it is not asked at all.
    @MainActor private static var sportsDBBusyUntil = Date.distantPast

    /// One TheSportsDB request, spaced from the last. Nil when it could not
    /// be answered (not when it found nothing).
    ///
    /// A busy answer is not waited out: that held the whole drawing queue
    /// for minutes behind one team, while matches ESPN could draw at once sat
    /// waiting. The match is drawn later instead, keeping the add-on's image
    /// meanwhile.
    @MainActor
    private static func sportsDB(_ url: URL) async -> Data? {
        guard Date() >= sportsDBBusyUntil else { return nil }
        let wait = nextRequestSlot.timeIntervalSinceNow
        nextRequestSlot = max(nextRequestSlot, Date()).addingTimeInterval(2.2)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            return data
        case 429:
            sportsDBBusyUntil = Date().addingTimeInterval(60)
            return nil
        default:
            return nil
        }
    }

    /// The forms a name is searched under, in turn: as written, without club
    /// initials ("F.C. København" → "København"), and without accents.
    static func searchNames(for name: String) -> [String] {
        var names = [name]
        let bare = name.replacingOccurrences(
            of: #"(?i)(^|\s)(f\.?c\.?|c\.?f\.?|a\.?f\.?c\.?|s\.?c\.?|fk|sk|ac|as|cd|cf|sc)(?=\s|$)"#,
            with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        if !bare.isEmpty, bare != name { names.append(bare) }
        let folded = bare.folding(options: .diacriticInsensitive, locale: nil)
        if folded != bare { names.append(folded) }
        return names
    }

    /// A side from ESPN's lists, with its crest downloaded; nil when ESPN did
    /// not know it.
    @MainActor
    private static func espnTeam(_ entry: SportsLogos.Team?, named name: String) async -> (Team?, Bool) {
        // ESPN lists some leagues without crests (EuroLeague): TheSportsDB then.
        guard let entry, entry.logo != nil else { return (nil, true) }
        let crest = await image(at: entry.logo)
        return (
            Team(
                name: name,
                crest: crest,
                colour: colour(hex: entry.colour) ?? colour(seed: name),
                secondColour: colour(hex: entry.secondColour) ?? .white,
                leagues: []
            ),
            entry.logo == nil || crest != nil
        )
    }

    /// The team, and whether it could be looked up (a busy or unreachable
    /// TheSportsDB is not the same as a team it does not know).
    @MainActor
    private static func team(named name: String, sport: String?) async -> (team: Team, answered: Bool) {
        let key = name.lowercased() + "|" + (sport ?? "")
        var answered = true
        if store.teams[key] == nil {
            var found: TeamRecord?
            for candidate in searchNames(for: name) {
                var components = URLComponents(string: "https://www.thesportsdb.com/api/v1/json/123/searchteams.php")
                components?.queryItems = [URLQueryItem(name: "t", value: candidate)]
                guard let url = components?.url else { continue }
                guard let data = await sportsDB(url) else { answered = false; break }
                let teams = (try? JSONDecoder().decode(SearchResponse.self, from: data))?.teams ?? []
                let pick = teams.first { team in
                    guard let sport, let teamSport = team.strSport else { return false }
                    return teamSport.caseInsensitiveCompare(sport) == .orderedSame
                } ?? (sport == nil ? teams.first : nil)
                if let pick {
                    found = TeamRecord(
                        crest: pick.strBadge, colour: pick.strColour1, secondColour: pick.strColour2,
                        leagues: pick.leagues, savedAt: Date()
                    )
                    break
                }
            }
            if answered {
                store.teams[key] = found
                    ?? TeamRecord(crest: nil, colour: nil, secondColour: nil, leagues: [], savedAt: Date())
                saveStore()
            }
        }
        let entry = store.teams[key]
        var crest = await image(at: entry?.crest)
        if entry?.crest != nil, crest == nil { answered = false }
        // A national side TheSportsDB does not know (Jersey's cricketers,
        // say): its country's flag.
        if crest == nil, entry?.crest == nil, let code = countryCode(for: name) {
            crest = await image(at: "https://flagcdn.com/w640/\(code).png")
        }
        let isFlag = entry?.crest == nil && crest != nil
        return (
            Team(
                name: name,
                crest: crest,
                isFlag: isFlag,
                colour: colour(hex: entry?.colour) ?? colour(seed: name),
                secondColour: colour(hex: entry?.secondColour) ?? .white,
                leagues: (entry?.leagues ?? []).map { ($0.id, $0.name) }
            ),
            answered
        )
    }

    private struct LeagueResponse: Decodable {
        struct League: Decodable { let strBadge: String? }
        let leagues: [League]?
    }

    /// The competition's badge: the league both teams play in (NBA for
    /// Lakers v Warriors, the Europa League for Juventus v Rennes), the one
    /// the listing names when it names one, never a friendly.
    @MainActor
    private static func leagueBadge(home: Team, away: Team, listing: String) async -> (badge: CGImage?, answered: Bool) {
        let awayIds = Set(away.leagues.map(\.id))
        var shared = home.leagues.filter { awayIds.contains($0.id) && !$0.name.lowercased().contains("friendl") }
        if shared.isEmpty, away.crest == nil {
            // Only one side known (a national side, say): its main league.
            shared = Array(home.leagues.prefix(1))
        }
        let lower = listing.lowercased()
        guard let league = shared.first(where: { lower.contains($0.name.lowercased()) }) ?? shared.first else {
            return (nil, true)
        }
        if store.leagueBadges[league.id] == nil {
            guard let url = URL(string: "https://www.thesportsdb.com/api/v1/json/123/lookupleague.php?id=\(league.id)"),
                  let data = await sportsDB(url) else { return (nil, false) }
            store.leagueBadges[league.id] =
                (try? JSONDecoder().decode(LeagueResponse.self, from: data))?.leagues?.first?.strBadge ?? ""
            saveStore()
        }
        let address = store.leagueBadges[league.id] ?? ""
        guard !address.isEmpty else { return (nil, true) }
        let badge = await image(at: address)
        return (badge, badge != nil)
    }

    /// The ISO region code of a country named exactly, in English.
    static func countryCode(for name: String) -> String? {
        let wanted = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let english = Locale(identifier: "en_US")
        for code in Locale.Region.isoRegions.map(\.identifier) where code.count == 2 {
            guard let country = english.localizedString(forRegionCode: code) else { continue }
            if country.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == wanted {
                return code.lowercased()
            }
        }
        return nil
    }

    private static func image(at address: String?) async -> CGImage? {
        guard let address, let url = URL(string: address),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static var storeFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sportsdb-lookups.json")
    }

    private static func loadStore() -> LookupStore {
        guard let file = storeFile, let data = try? Data(contentsOf: file),
              var store = try? JSONDecoder().decode(LookupStore.self, from: data) else { return LookupStore() }
        // A month on, a team may have a new crest; ask again.
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        store.teams = store.teams.filter { $0.value.savedAt > cutoff }
        return store
    }

    @MainActor
    private static func saveStore() {
        guard let file = storeFile, let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static func colour(hex: String?) -> Color? {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private static func colour(seed: String) -> Color {
        Color(hue: Double(stableHash(seed) % 360) / 360, saturation: 0.6, brightness: 0.55)
    }

    // MARK: Storage

    private static func artKey(title: String, genres: [String]) -> String {
        String(stableHash(title + "|" + genres.joined(separator: "|")), radix: 16)
    }

    private static func drawnFile(title: String, genres: [String], shape: Shape) -> URL? {
        folder?.appendingPathComponent(artKey(title: title, genres: genres) + "-" + shape.rawValue + ".jpg")
    }

    /// Both shapes are on disk.
    private static func isDrawn(title: String, genres: [String]) -> Bool {
        [Shape.portrait, wideShape].allSatisfy { shape in
            drawnFile(title: title, genres: genres, shape: shape).map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
        }
    }

    private static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    // MARK: The picture

    /// Two halves split on a slant, each in its team's colour with a band of
    /// its second colour; the crests large on their sides; the competition's
    /// badge between them, smaller than the crests.
    private struct FixtureArtView: View {
        let home: Team
        let away: Team
        let badge: CGImage?
        let label: String?
        let shape: Shape

        private var isPortrait: Bool { shape == .portrait }

        var body: some View {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    half(home, size: size, isFirst: true)
                    half(away, size: size, isFirst: false)
                    seam(size: size)
                    // Light from above, shade below.
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear, .black.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    if isPortrait {
                        // Stacked: home above the seam, away below, the
                        // badge on the seam. All above the lower third, which
                        // a portrait hero covers with its text.
                        let crest = size.width * 0.38
                        crestView(home, size: crest).position(x: size.width / 2, y: size.height * 0.15)
                        centre(badgeSize: crest * 0.46).position(x: size.width / 2, y: size.height * 0.365)
                        crestView(away, size: crest).position(x: size.width / 2, y: size.height * 0.575)
                    } else if shape == .backdrop {
                        // The match in the right two-fifths: the left is where
                        // an Apple TV or Mac hero and page put their title
                        // (which can run past half the width) and buttons.
                        let crest = size.height * 0.4
                        let row = size.height * 0.42
                        crestView(home, size: crest).position(x: size.width * 0.59, y: row)
                        centre(badgeSize: crest * 0.48).position(x: size.width * 0.745, y: row)
                        crestView(away, size: crest).position(x: size.width * 0.875, y: row)
                    } else {
                        // Side by side, the badge on the seam between them —
                        // close enough in that a narrower header cropping
                        // the sides keeps both crests whole.
                        // A little above the middle: a page's title sits
                        // over the art's lower part.
                        let crest = size.height * 0.48
                        let row = size.height * 0.4
                        crestView(home, size: crest).position(x: size.width * 0.3, y: row)
                        centre(badgeSize: crest * 0.5).position(x: size.width / 2, y: row)
                        crestView(away, size: crest).position(x: size.width * 0.7, y: row)
                    }
                }
            }
            .background(Color.black)
        }

        /// The seam's two ends. Landscape: a slant from top to bottom, home on
        /// the left. Portrait: a slant from side to side, home on top.
        private func seamEnds(_ size: CGSize) -> (CGPoint, CGPoint) {
            switch shape {
            case .portrait:
                return (CGPoint(x: 0, y: size.height * 0.43), CGPoint(x: size.width, y: size.height * 0.30))
            case .landscape:
                return (CGPoint(x: size.width * 0.57, y: 0), CGPoint(x: size.width * 0.43, y: size.height))
            case .backdrop:
                // Through the badge, between the two crests on the right.
                return (CGPoint(x: size.width * 0.8, y: 0), CGPoint(x: size.width * 0.67, y: size.height))
            }
        }

        private func halfPath(size: CGSize, isFirst: Bool) -> Path {
            Path { path in
                let (start, end) = seamEnds(size)
                let corners: [CGPoint]
                if isPortrait {
                    corners = isFirst
                        ? [.zero, CGPoint(x: size.width, y: 0), end, start]
                        : [start, end, CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
                } else {
                    corners = isFirst
                        ? [.zero, start, end, CGPoint(x: 0, y: size.height)]
                        : [start, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), end]
                }
                path.addLines(corners)
                path.closeSubpath()
            }
        }

        private func half(_ team: Team, size: CGSize, isFirst: Bool) -> some View {
            ZStack {
                team.colour
                // A band of the second colour across the side, running with
                // the seam.
                Rectangle()
                    .fill(team.secondColour.opacity(0.85))
                    .frame(width: max(size.width, size.height) * 1.8, height: min(size.width, size.height) * 0.13)
                    .rotationEffect(.degrees(isPortrait ? -7.5 : -58))
                    .offset(
                        x: isPortrait ? 0 : (isFirst ? -size.width * 0.30 : size.width * 0.30),
                        y: isPortrait ? (isFirst ? -size.height * 0.30 : size.height * 0.36) : 0
                    )
                // Depth: darker towards the outside edge.
                LinearGradient(
                    colors: [.black.opacity(0.35), .clear],
                    startPoint: isPortrait ? (isFirst ? .top : .bottom) : (isFirst ? .leading : .trailing),
                    endPoint: isPortrait ? (isFirst ? .bottom : .top) : (isFirst ? .trailing : .leading)
                )
            }
            .frame(width: size.width, height: size.height)
            .clipShape(halfPath(size: size, isFirst: isFirst))
        }

        private func seam(size: CGSize) -> some View {
            Path { path in
                let (start, end) = seamEnds(size)
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(Color.black.opacity(0.55), lineWidth: isPortrait ? 14 : 16)
            .shadow(color: .black.opacity(0.6), radius: 18)
        }

        private func crestView(_ team: Team, size: CGFloat) -> some View {
            Group {
                if let crest = team.crest {
                    VStack(spacing: size * 0.06) {
                        Image(decorative: crest, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .modifier(FlagFrame(isFlag: team.isFlag, size: size))
                        // A flag says less than a crest: name the side.
                        if team.isFlag {
                            Text(team.name)
                                .font(.system(size: size * 0.12, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                } else {
                    VStack(spacing: size * 0.06) {
                        Circle()
                            .fill(team.colour)
                            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: size * 0.03))
                            .overlay(
                                Text(Self.monogram(team.name))
                                    .font(.system(size: size * 0.3, weight: .heavy))
                                    .foregroundStyle(.white)
                            )
                            .frame(width: size * 0.78, height: size * 0.78)
                        // No crest to recognise it by: name it.
                        Text(team.name)
                            .font(.system(size: size * 0.11, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.55), radius: size * 0.06, y: size * 0.03)
        }

        /// The competition's badge on a dark plate, or "VS" without one; a
        /// match label under it when there is one.
        private func centre(badgeSize: CGFloat) -> some View {
            VStack(spacing: badgeSize * 0.12) {
                ZStack {
                    RoundedRectangle(cornerRadius: badgeSize * 0.22, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: badgeSize * 0.22, style: .continuous)
                                .stroke(.white.opacity(0.35), lineWidth: 3)
                        )
                    if let badge {
                        Image(decorative: badge, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(badgeSize * 0.14)
                    } else {
                        Text("VS")
                            .font(.system(size: badgeSize * 0.34, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: badgeSize, height: badgeSize)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                if let label {
                    Text(label.uppercased())
                        .font(.system(size: badgeSize * 0.13, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .frame(width: badgeSize * 1.8)
                }
            }
        }

        /// A flag gets rounded corners and a thin edge, as a badge would.
        struct FlagFrame: ViewModifier {
            let isFlag: Bool
            let size: CGFloat

            func body(content: Content) -> some View {
                if isFlag {
                    content
                        .frame(width: size * 0.82)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.06, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                                .stroke(.white.opacity(0.7), lineWidth: size * 0.015)
                        )
                } else {
                    content
                }
            }
        }

        /// "Stade Rennais" → "SR", "Juventus" → "JUV".
        private static func monogram(_ name: String) -> String {
            let words = name.split(separator: " ").filter { !$0.isEmpty }
            if words.count >= 2 { return words.prefix(3).compactMap(\.first).map(String.init).joined().uppercased() }
            return String(name.prefix(3)).uppercased()
        }
    }
}

/// Answers `omni-fixture` addresses with `FixtureArtwork`'s picture, so the
/// image loaders that use the shared session (and the poster cache, which is
/// given it too) treat match art like any other.
final class FixtureArtURLProtocol: URLProtocol, @unchecked Sendable {
    private var drawing: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == FixtureArtwork.scheme
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        drawing = Task { [weak self] in
            let data = await FixtureArtwork.imageData(for: url)
            guard let self, !Task.isCancelled else { return }
            if let data,
               let response = HTTPURLResponse(
                   url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                   headerFields: ["Content-Type": "image/jpeg", "Content-Length": String(data.count)]
               ) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData))
            }
        }
    }

    override func stopLoading() {
        drawing?.cancel()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

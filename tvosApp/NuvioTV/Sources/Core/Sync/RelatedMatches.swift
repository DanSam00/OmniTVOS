import Foundation

/// The other matches in a match's competition, for under its page and under
/// the iPhone's portrait player.
///
/// A match page does not know which catalog it was opened from, so the sports
/// add-ons' catalogs of the same type are read (first page each, and further
/// pages of the catalog for its sport, kept ten minutes). Matches of the same
/// competition ("More Premier League") come first; with none, the catalog
/// listing this match supplies the rest, else matches of the same sport.
@MainActor
enum RelatedMatches {
    /// Posted with a `NuvioMeta` to play it in place of what is playing.
    static let playNotification = Notification.Name("omni.relatedMatches.play")

    private static var pages: [String: (items: [NuvioMeta], at: Date)] = [:]
    private static let lifetime: TimeInterval = 10 * 60
    private static let repository = CinemetaCatalogRepository()
    /// A sport's catalog runs to hundreds of matches, twenty a page, in date
    /// order: a competition's next round is rarely all on the first page.
    private static let sportCatalogPages = 8

    /// A sports listing: a match, or anything a sports add-on lists.
    static func applies(to meta: NuvioMeta) -> Bool {
        FixtureArtwork.isMatch(meta) || meta.type.lowercased().contains("sport")
    }

    /// The sport and competition a match is filed under, from its genres. The
    /// sports add-ons give them as ["Football", "Premier League"], Omni's own
    /// schedule as ["English Premier League", "Soccer"]; channel codes some
    /// listings add ("NOW-34334") are neither.
    static func filing(of meta: NuvioMeta) -> (sport: String?, competition: String?) {
        let names = (meta.genres ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isChannelCode($0) }
        let sport = names.first { sportNames.contains($0.lowercased()) } ?? names.first
        let competition = names.first { $0 != sport }
        return (sport, competition)
    }

    /// The row's title: "More Premier League" when the row is that
    /// competition's, else "More Football", else "More Matches".
    static func rowTitle(for meta: NuvioMeta, matches: [NuvioMeta]) -> String {
        let filing = filing(of: meta)
        if let competition = filing.competition, !matches.isEmpty,
           matches.allSatisfy({ isSameCompetition($0, competition) }) {
            return L10n.format("details_more_sport", fallback: "More %@", competition)
        }
        if let sport = filing.sport {
            return L10n.format("details_more_sport", fallback: "More %@", sport)
        }
        return L10n.string("details_more_matches", fallback: "More Matches")
    }

    static func matches(for meta: NuvioMeta, limit: Int = 30) async -> [NuvioMeta] {
        guard applies(to: meta) else { return [] }
        let type = meta.type.lowercased()
        let filing = filing(of: meta)
        let catalogs = await repository.availableAddonCatalogs().filter { $0.type.lowercased() == type }
        var lists: [[NuvioMeta]] = []
        await withTaskGroup(of: [NuvioMeta]?.self) { group in
            for catalog in catalogs {
                let isSportCatalog = filing.sport.map {
                    catalog.catalogName.caseInsensitiveCompare($0) == .orderedSame
                } ?? false
                let pageCount = isSportCatalog ? sportCatalogPages : 1
                let key = catalog.addonId + "|" + catalog.type + "|" + catalog.catalogId + "|\(pageCount)"
                if let cached = pages[key], Date().timeIntervalSince(cached.at) < lifetime {
                    lists.append(cached.items)
                    continue
                }
                group.addTask { [repository] in
                    var items: [NuvioMeta] = []
                    var skip = 0
                    for _ in 0..<pageCount {
                        guard let page = try? await repository.browseCatalog(
                            addonId: catalog.addonId,
                            contentType: catalog.type,
                            catalogId: catalog.catalogId,
                            skip: skip,
                            genre: nil
                        ) else { break }
                        let fresh = page.items.filter { item in !items.contains { $0.id == item.id } }
                        items += fresh
                        guard page.hasMore, !fresh.isEmpty else { break }
                        skip = page.nextSkip ?? (skip + page.items.count)
                    }
                    guard !items.isEmpty else { return nil }
                    await MainActor.run { pages[key] = (items, Date()) }
                    return items
                }
            }
            for await list in group { if let list { lists.append(list) } }
        }
        // Omni has no sports add-ons: its matches come from the schedule.
        if AppEdition.isPublic { lists.append(await SportsSchedule.fixtures().map(\.meta)) }

        var seen: Set<String> = [meta.id]
        if let competition = filing.competition {
            let sameCompetition = lists.joined()
                .filter { FixtureArtwork.isMatch($0) && isSameCompetition($0, competition) }
                .filter { seen.insert($0.id).inserted }
            if !sameCompetition.isEmpty { return Array(sameCompetition.prefix(limit)) }
        }

        // The category it came from: of the catalogs listing it, the one with
        // the most matches of its sport ("Basketball", not a "Live now" list
        // mixing in channels). Else that sport's matches from any catalog.
        let sport = filing.sport?.lowercased()
        func sameSportMatches(_ list: [NuvioMeta]) -> [NuvioMeta] {
            list.filter { candidate in
                guard FixtureArtwork.isMatch(candidate) else { return false }
                guard let sport else { return true }
                return (candidate.genres ?? []).contains { $0.lowercased() == sport }
            }
        }
        let homes = lists.filter { list in list.contains { $0.id == meta.id } }
        let others: [NuvioMeta]
        if let home = homes.max(by: { sameSportMatches($0).count < sameSportMatches($1).count }) {
            // Its matches; a category of other things keeps them all.
            let matches = home.filter(FixtureArtwork.isMatch)
            others = matches.count > 1 ? matches : home
        } else {
            others = lists.flatMap(sameSportMatches)
        }
        return Array(others.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    // MARK: The same match in other add-ons

    /// A listing of the same match by another add-on (or another catalog of
    /// the same one), with the add-on that serves it.
    struct Twin {
        let meta: NuvioMeta
        /// The add-on's manifest id.
        let addonId: String
    }

    /// Every other listing of this match. Films and episodes share an IMDb id
    /// that every add-on answers to; a match does not — each sports add-on
    /// files it under its own id ("nuvio_sport_…", "streamed:…") and serves
    /// streams only for that. So the sports catalogs of every type are read
    /// (first page, kept ten minutes) for the same two teams on the same day.
    static func twins(of meta: NuvioMeta) async -> [Twin] {
        guard let teams = FixtureArtwork.teams(in: meta.name) else { return [] }
        let catalogs = await repository.availableAddonCatalogs().filter { catalog in
            guard !catalog.genreRequired else { return false }
            let type = catalog.type.lowercased()
            let name = catalog.catalogName.lowercased()
            // Where matches are listed: sports, TV and event catalogs, or any
            // catalog named for a sport. Not every add-on's films and clips.
            let namedForSport = name.contains("sport") || sportNames.contains { name.contains($0) }
            return namedForSport || ["sport", "tv", "channel", "event", "live"].contains { type.contains($0) }
        }
        var found: [Twin] = []
        await withTaskGroup(of: (String, [NuvioMeta])?.self) { group in
            for catalog in catalogs {
                let key = catalog.addonId + "|" + catalog.type + "|" + catalog.catalogId + "|1"
                if let cached = pages[key], Date().timeIntervalSince(cached.at) < lifetime {
                    found += cached.items.filter { isSameMatch($0, teams: teams, as: meta) }
                        .map { Twin(meta: $0, addonId: catalog.addonId) }
                    continue
                }
                group.addTask { [repository] in
                    guard let page = try? await repository.browseCatalog(
                        addonId: catalog.addonId,
                        contentType: catalog.type,
                        catalogId: catalog.catalogId,
                        skip: 0,
                        genre: nil
                    ), !page.items.isEmpty else { return nil }
                    await MainActor.run { pages[key] = (page.items, Date()) }
                    return (catalog.addonId, page.items)
                }
            }
            for await result in group {
                guard let (addonId, items) = result else { continue }
                found += items.filter { isSameMatch($0, teams: teams, as: meta) }
                    .map { Twin(meta: $0, addonId: addonId) }
            }
        }
        var seen: Set<String> = [meta.id]
        return found.filter { seen.insert($0.meta.id).inserted }
    }

    /// Both teams, either way round ("76ers" is "Philadelphia 76ers"), and,
    /// when both listings carry a date, within a day of each other.
    static func isSameMatch(_ candidate: NuvioMeta, teams: (home: String, away: String, suffix: String?), as meta: NuvioMeta) -> Bool {
        guard candidate.id != meta.id, let other = FixtureArtwork.teams(in: candidate.name) else { return false }
        let mine = [teamKey(teams.home), teamKey(teams.away)]
        let theirs = [teamKey(other.home), teamKey(other.away)]
        let straight = sameTeam(mine[0], theirs[0]) && sameTeam(mine[1], theirs[1])
        let swapped = sameTeam(mine[0], theirs[1]) && sameTeam(mine[1], theirs[0])
        guard straight || swapped else { return false }
        if let a = date(of: meta), let b = date(of: candidate), abs(a.timeIntervalSince(b)) > 30 * 3600 { return false }
        return true
    }

    private static func teamKey(_ name: String) -> [String] {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { !["fc", "afc", "cf", "sc", "the", "de", "club"].contains($0) }
    }

    /// One name inside the other ("Pistons" / "Detroit Pistons"), or the
    /// same distinctive last word.
    private static func sameTeam(_ a: [String], _ b: [String]) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let x = a.joined(separator: " "), y = b.joined(separator: " ")
        if x == y || " \(x) ".contains(" \(y) ") || " \(y) ".contains(" \(x) ") { return true }
        guard let lastA = a.last, let lastB = b.last, lastA.count >= 4 else { return false }
        return lastA == lastB
    }

    private static func date(of meta: NuvioMeta) -> Date? {
        guard let raw = meta.released, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func isSameCompetition(_ candidate: NuvioMeta, _ competition: String) -> Bool {
        filing(of: candidate).competition?.caseInsensitiveCompare(competition) == .orderedSame
    }

    /// A broadcaster's code ("NOW-34334", "NZ-SKYTRTRTR"), not a competition.
    /// Matched by shape, not by a dash alone: "A-League Men" is a competition.
    private static func isChannelCode(_ genre: String) -> Bool {
        genre.range(of: "^[A-Z]{2,}(-[A-Z0-9]+)+$", options: .regularExpression) != nil
    }

    /// The sports the add-ons' catalogs and Omni's schedule are named after.
    private static let sportNames: Set<String> = [
        "football", "soccer", "basketball", "american football", "baseball", "hockey", "ice hockey",
        "rugby", "rugby league", "rugby union", "cricket", "tennis", "golf", "fight", "mma", "boxing",
        "motor sports", "motorsport", "afl", "darts", "billiards", "snooker", "volleyball", "handball",
        "cycling", "other",
    ]
}

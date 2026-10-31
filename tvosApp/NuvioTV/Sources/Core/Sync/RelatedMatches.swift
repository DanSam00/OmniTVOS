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

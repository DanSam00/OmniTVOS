import Foundation

/// The other matches in a match's category, for under its page and under the
/// iPhone's portrait player.
///
/// A match page does not know which catalog it was opened from, so the sports
/// add-ons' catalogs of the same type are read (first page each, kept ten
/// minutes) and the one listing this match supplies the rest. When none lists
/// it, matches of the same sport stand in.
@MainActor
enum RelatedMatches {
    /// Posted with a `NuvioMeta` to play it in place of what is playing.
    static let playNotification = Notification.Name("omni.relatedMatches.play")

    private static var pages: [String: (items: [NuvioMeta], at: Date)] = [:]
    private static let lifetime: TimeInterval = 10 * 60
    private static let repository = CinemetaCatalogRepository()

    /// A sports listing: a match, or anything a sports add-on lists.
    static func applies(to meta: NuvioMeta) -> Bool {
        FixtureArtwork.isMatch(meta) || meta.type.lowercased().contains("sport")
    }

    static func matches(for meta: NuvioMeta, limit: Int = 30) async -> [NuvioMeta] {
        guard applies(to: meta) else { return [] }
        let type = meta.type.lowercased()
        let catalogs = await repository.availableAddonCatalogs().filter { $0.type.lowercased() == type }
        var lists: [[NuvioMeta]] = []
        await withTaskGroup(of: [NuvioMeta]?.self) { group in
            for catalog in catalogs {
                let key = catalog.addonId + "|" + catalog.type + "|" + catalog.catalogId
                if let cached = pages[key], Date().timeIntervalSince(cached.at) < lifetime {
                    lists.append(cached.items)
                    continue
                }
                group.addTask { [repository] in
                    guard let page = try? await repository.browseCatalog(
                        addonId: catalog.addonId,
                        contentType: catalog.type,
                        catalogId: catalog.catalogId,
                        skip: 0,
                        genre: nil
                    ) else { return nil }
                    await MainActor.run { pages[key] = (page.items, Date()) }
                    return page.items
                }
            }
            for await list in group { if let list { lists.append(list) } }
        }

        // The category it came from: of the catalogs listing it, the one with
        // the most matches of its sport ("Basketball", not a "Live now" list
        // mixing in channels). Else that sport's matches from any catalog.
        let sport = (meta.genres ?? []).first(where: { !$0.contains("-") })?.lowercased()
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
        var seen: Set<String> = [meta.id]
        return Array(others.filter { seen.insert($0.id).inserted }.prefix(limit))
    }
}

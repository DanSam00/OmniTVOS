import Foundation

/// Background enrichment for compact Cinemeta search records.
///
/// `CatalogRepository.search(query:)` intentionally returns fast, compact
/// records: Cinemeta search results carry an id (usually IMDb), name, type and
/// a poster, but omit the aliases (IMDb/TMDB ids), backdrop, and logo that
/// Discovery/collection cards have. That leaves Search artwork behind and can
/// hide watched-state checkmarks when the watch history only knows the title
/// by its TMDB id.
///
/// This helper refreshes the leading results with their full `/meta` records
/// *after* the raw grid is already on screen, merging the missing fields while
/// preserving each result's original id (so focus identity and navigation are
/// unchanged). Requests run in small waves so a long result list never fans
/// out into one request per card, and the caller cancels the task when the
/// query changes so a stale enrichment can never be applied.
@MainActor
enum SearchResultEnrichment {
    /// Upper bound on how many leading results get a full `/meta` refresh.
    /// Covers the visible grid plus a row or two of scroll; anything further
    /// down is refreshed if the user keeps scrolling and re-searches.
    static let maxResultsToEnrich = 24

    /// Refresh requests run in waves of this size (about four at a time).
    static let maxConcurrentRequests = 4

    static func hasIncompleteLeadingResults(_ results: [NuvioMeta]) -> Bool {
        results
            .prefix(maxResultsToEnrich)
            .contains { $0.needsSearchMetadataEnrichment }
    }

    /// Returns `results` with the leading entries merged with their refreshed
    /// `/meta` records. Order, ids, and names are untouched; refreshed artwork
    /// wins over stale compact search artwork, while aliases and other missing
    /// metadata are filled. Skipping a record that is already complete keeps
    /// repeated queries from re-fetching what the cache already enriched.
    static func enrich(
        _ results: [NuvioMeta],
        repository: CatalogRepository
    ) async -> [NuvioMeta] {
        guard !results.isEmpty else { return results }

        let candidateIndices = Array(results.indices.prefix(maxResultsToEnrich))
            // Live channels come from their add-on whole; there is no `/meta`
            // to refresh them from.
            .filter { results[$0].needsSearchMetadataEnrichment
                && !CinemetaCatalogRepository.isLiveSearchType(results[$0].type) }
        guard !candidateIndices.isEmpty else { return results }

        var enriched = results
        var cursor = 0
        while cursor < candidateIndices.count {
            guard !Task.isCancelled else { break }
            let end = min(cursor + maxConcurrentRequests, candidateIndices.count)
            let slice = Array(candidateIndices[cursor..<end])

            // Child tasks inherit cancellation, so in-flight refreshes abort
            // when the caller cancels (query changed) instead of completing.
            let refreshed: [(index: Int, full: NuvioMeta?)] = await withTaskGroup(
                of: (Int, NuvioMeta?).self
            ) { group in
                for index in slice {
                    group.addTask {
                        let meta = results[index]
                        let full = try? await repository.refreshMetadata(
                            id: meta.id,
                            type: meta.type
                        )
                        return (index, full)
                    }
                }
                var collected: [(Int, NuvioMeta?)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }

            for (index, full) in refreshed {
                guard let full, !Task.isCancelled else { continue }
                enriched[index] = results[index].mergingSearchMetadata(from: full)
            }
            cursor = end
        }
        return enriched
    }
}

/// Orders search results by how closely each title matches what was typed.
///
/// The repository fetches movies, then series, then live channels, and showed
/// them in that order, so "house of the dragon" listed eighteen films before
/// the series of that name. Each title now lands in a tier: the exact title,
/// then titles that start with the phrase, contain it, contain every word, and
/// last by how many of the words they share (little words like "of" and "the"
/// do not count there). Within a tier the shorter title is the closer one, and
/// past that the source's own order stands.
enum SearchRanking {
    private static let minorWords: Set<String> = ["a", "an", "the", "of", "and", "in", "on", "to", "for", "at", "by", "with", "&"]

    /// `peopleTitleIDs`: titles found through the people matching the query
    /// (TMDB). They follow every title that holds all the words typed, ahead
    /// of the loose partial matches, and keep their own (popularity) order.
    static func rank(_ results: [NuvioMeta], query: String, peopleTitleIDs: Set<String> = []) -> [NuvioMeta] {
        let phrase = normalized(query)
        guard !phrase.isEmpty else { return results }
        let words = phrase.split(separator: " ").map(String.init)
        let significant = Set(words.filter { !minorWords.contains($0) })
        return results.enumerated()
            .map { offset, meta -> (meta: NuvioMeta, tier: Int, share: Double, length: Int, offset: Int) in
                let title = normalized(meta.name)
                let titleWords = Set(title.split(separator: " ").map(String.init))
                // Tiers in steps of two, so a person's titles slot in at 7.
                let tier: Int
                if title == phrase {
                    tier = 0
                } else if title.hasPrefix(phrase + " ") {
                    tier = 2
                } else if (" " + title + " ").contains(" " + phrase + " ") {
                    tier = 4
                } else if Set(words).isSubset(of: titleWords) {
                    tier = 6
                } else if peopleTitleIDs.contains(meta.id) {
                    tier = 7
                } else {
                    tier = 8
                }
                let share = significant.isEmpty
                    ? 0
                    : Double(significant.intersection(titleWords).count) / Double(significant.count)
                return (meta, tier, share, title.count, offset)
            }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                if lhs.tier == 8, lhs.share != rhs.share { return lhs.share > rhs.share }
                if lhs.tier > 0, lhs.tier != 7, lhs.length != rhs.length { return lhs.length < rhs.length }
                return lhs.offset < rhs.offset
            }
            .map(\.meta)
    }

    /// Lowercased, accents folded, punctuation and emoji gone, single spaces.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}

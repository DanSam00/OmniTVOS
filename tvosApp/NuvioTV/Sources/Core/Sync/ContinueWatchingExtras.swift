import Foundation

/// The favourite teams whose next match joins Continue Watching. Kept per
/// profile, on this device.
enum FavouriteTeamsStore {
    static let changedNotification = Notification.Name("omni.favouriteTeams.changed")

    static func teams() -> [String] {
        (ProfileSettings.current.array(forKey: SettingsKey.favouriteTeams) as? [String]) ?? []
    }

    static func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = teams()
        guard !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        list.append(trimmed)
        save(list)
    }

    static func remove(_ name: String) {
        save(teams().filter { $0 != name })
    }

    private static func save(_ list: [String]) {
        ProfileSettings.current.set(list, forKey: SettingsKey.favouriteTeams)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// True when `title` ("Arsenal vs Chelsea") names `team` as whole words.
    static func title(_ title: String, names team: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let teamWords = words(team)
        let titleWords = words(title)
        guard !teamWords.isEmpty, titleWords.count >= teamWords.count else { return false }
        for start in 0...(titleWords.count - teamWords.count)
            where Array(titleWords[start..<start + teamWords.count]) == teamWords {
            return true
        }
        return false
    }
}

/// What Home's Continue Watching shows beyond watch progress, and the rule for
/// which progress cards may show at all.
///
/// Every platform's Home passes its row through `compose` and then
/// `ContinueWatchingSortPolicy.sorted`, so the row reads the same everywhere:
/// - an aired next episode only appears once a real source for it exists
///   (`StreamAvailability`);
/// - a favourite team's next match appears from the day before until it is
///   expected to have finished;
/// - a few recommendations, each with a real source, close the row.
///
/// Nothing here is stored as progress or synced to an account.
@MainActor
final class ContinueWatchingExtras {
    static let shared = ContinueWatchingExtras()

    /// Posted when the fixtures or recommendations change.
    static let changedNotification = Notification.Name("omni.continueWatchingExtras.changed")

    private(set) var recommendations: [ContinueWatchingItem] = []
    private(set) var fixtures: [ContinueWatchingItem] = []

    private var recommendationsLoadedAt: Date?
    private var recommendationsProfile: String?
    private var fixturesLoadedAt: Date?
    private var fixturesKey: String?
    private var recommendationTask: Task<Void, Never>?
    private var fixtureTask: Task<Void, Never>?
    private let repository = CinemetaCatalogRepository()

    private static let recommendationLifetime: TimeInterval = 6 * 3600
    private static let fixtureLifetime: TimeInterval = 20 * 60
    /// Built, and shown: more are built than shown, since some will have no
    /// source yet.
    private static let recommendationCandidates = 10
    private static let recommendationCount = 6

    private init() {
        NotificationCenter.default.addObserver(
            forName: FavouriteTeamsStore.changedNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                ContinueWatchingExtras.shared.fixturesLoadedAt = nil
                // Home composes again, which loads the new team's matches.
                NotificationCenter.default.post(name: ContinueWatchingExtras.changedNotification, object: nil)
            }
        }
    }

    // MARK: Composition

    /// The progress cards that may show, plus fixtures and recommendations.
    /// Starts any source checks and refreshes this needs; their answers come
    /// back through `StreamAvailability.changedNotification` and
    /// `changedNotification`, on which the caller composes again.
    func compose(_ items: [ContinueWatchingItem]) -> [ContinueWatchingItem] {
        refreshIfNeeded(basedOn: items)

        var requests: [StreamAvailability.Request] = []
        let gated = items.filter { Self.needsSource($0) }
            .sorted { ContinueWatchingSortPolicy.tier($0) < ContinueWatchingSortPolicy.tier($1) }
        requests += gated.compactMap(StreamAvailability.request(for:))

        let shown = items.filter { item in
            guard Self.needsSource(item), let request = StreamAvailability.request(for: item) else { return true }
            return StreamAvailability.shared.isAvailable(request)
        }

        let present = Set(shown.map(\.meta.id))
        let liveFixtures = fixtures.filter { Self.fixtureIsCurrent($0) && !present.contains($0.meta.id) }
        let extraRecommendations = recommendations.filter { item in
            guard !present.contains(item.meta.id), let request = StreamAvailability.request(for: item) else {
                return false
            }
            requests.append(request)
            return StreamAvailability.shared.isAvailable(request)
        }.prefix(Self.recommendationCount)
        StreamAvailability.shared.ensureChecked(requests)

        return (shown + liveFixtures + extraRecommendations)
            .filter { !ContinueWatchingDismissStore.isDismissed($0) }
    }

    /// An aired next episode, which only shows once it has a real source.
    /// Progress already under way is left alone: it played before.
    private static func needsSource(_ item: ContinueWatchingItem) -> Bool {
        item.cardKind == nil && item.isUpNextEntry && (item.hasAired || item.isAiringToday)
    }

    // MARK: Refresh

    private func refreshIfNeeded(basedOn items: [ContinueWatchingItem]) {
        let profile = ProfileSettings.activeProfileScope
        let now = Date()
        if recommendationsProfile != profile {
            recommendations = []
            recommendationsLoadedAt = nil
        }
        let seeds = items.filter { $0.cardKind == nil }.prefix(3).map(\.meta)
        // Without the viewer's own titles to go on there is nothing to suggest
        // from, unless Trakt has recommendations of its own.
        if recommendationTask == nil, !seeds.isEmpty || TraktAuthStore.state.isAuthenticated,
           recommendationsLoadedAt.map({ now.timeIntervalSince($0) > Self.recommendationLifetime }) ?? true {
            recommendationTask = Task {
                let found = await loadRecommendations(seeds: Array(seeds), excluding: Set(items.map(\.meta.id)))
                recommendationTask = nil
                recommendationsProfile = profile
                // Nothing found (a source not answering) is asked again sooner.
                recommendationsLoadedAt = found.isEmpty
                    ? Date().addingTimeInterval(600 - Self.recommendationLifetime)
                    : Date()
                if found.map(\.meta.id) != recommendations.map(\.meta.id) {
                    recommendations = found
                    NotificationCenter.default.post(name: Self.changedNotification, object: nil)
                }
            }
        }

        let teams = FavouriteTeamsStore.teams()
        let key = profile + "|" + teams.joined(separator: "|")
        if fixturesKey != key {
            fixturesLoadedAt = nil
            if teams.isEmpty, !fixtures.isEmpty {
                fixtures = []
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
            }
        }
        guard !teams.isEmpty, fixtureTask == nil,
              fixturesLoadedAt.map({ now.timeIntervalSince($0) > Self.fixtureLifetime }) ?? true else { return }
        fixtureTask = Task {
            let found = await loadFixtures(teams: teams)
            fixtureTask = nil
            fixturesKey = key
            fixturesLoadedAt = Date()
            if found.map(\.id) != fixtures.map(\.id) || found.map(\.kickoff) != fixtures.map(\.kickoff) {
                fixtures = found
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
            }
        }
    }

    // MARK: Recommendations

    /// The account's recommendations when Trakt is connected; otherwise titles
    /// like the ones being watched, from the details page's source.
    private func loadRecommendations(seeds: [NuvioMeta], excluding: Set<String>) async -> [ContinueWatchingItem] {
        var candidates = await TraktDetailsService.fetchRecommendations(limit: 10)
        if candidates.isEmpty {
            // Taken in turn from each title, so one film does not supply them all.
            var lists: [[RelatedTitle]] = []
            for seed in seeds {
                var related = TraktSettingsStore.moreLikeThisSource == .trakt && TraktAuthStore.state.isAuthenticated
                    ? await TraktDetailsService.fetchRelated(for: seed, limit: 8)
                    : await TmdbDetailsService.fetchMoreLikeThis(for: seed, limit: 8)
                // Neither connected (or TMDB refusing its key): Trakt's public list.
                if related.isEmpty {
                    related = await TraktDetailsService.fetchPublicRelated(for: seed, limit: 8)
                }
                lists.append(related)
            }
            for index in 0..<(lists.map(\.count).max() ?? 0) {
                candidates += lists.compactMap { index < $0.count ? $0[index] : nil }
            }
        }

        let watched = Set(WatchedStore.visibleItems().map(\.meta.id))
        var seen = excluding.union(watched)
        var result: [ContinueWatchingItem] = []
        // TMDB's come as `tmdb:` ids; the catalog maps them to IMDb on lookup.
        for candidate in candidates where candidate.id.hasPrefix("tt") || candidate.id.hasPrefix("tmdb:") {
            guard result.count < Self.recommendationCandidates, seen.insert(candidate.id).inserted else { continue }
            let type = candidate.type == "movie" ? "movie" : "series"
            guard let meta = try? await repository.getMetadata(id: candidate.id, type: type),
                  meta.id.hasPrefix("tt"), seen.insert(meta.id).inserted || meta.id == candidate.id,
                  !ContentReleasePolicy.isUnreleased(meta) else { continue }
            if meta.isSeries {
                let first = (meta.videos ?? [])
                    .filter { $0.season > 0 && EpisodeReleasePolicy.hasAired($0.released) }
                    .min { ($0.season, $0.episode) < ($1.season, $1.episode) }
                guard let first else { continue }
                result.append(ContinueWatchingItem(
                    meta: meta, streamUrl: "", position: 0, duration: 1, lastWatchedAt: .distantPast,
                    season: first.season, episode: first.episode, released: first.released,
                    isUpNext: true, cardKind: ContinueWatchingItem.recommendationKind
                ))
            } else {
                result.append(ContinueWatchingItem(
                    meta: meta, streamUrl: "", position: 0, duration: 1, lastWatchedAt: .distantPast,
                    released: meta.released, isUpNext: true, cardKind: ContinueWatchingItem.recommendationKind
                ))
            }
        }
        return result
    }

    // MARK: Fixtures

    /// Each team's next match from the installed sports add-ons.
    private func loadFixtures(teams: [String]) async -> [ContinueWatchingItem] {
        let catalogs = await repository.availableAddonCatalogs()
            .filter { ["sport", "sports"].contains($0.type.lowercased()) }
        var listed: [NuvioMeta] = []
        await withTaskGroup(of: [NuvioMeta].self) { group in
            for catalog in catalogs {
                group.addTask { [repository] in
                    (try? await repository.browseCatalog(
                        addonId: catalog.addonId,
                        contentType: catalog.type,
                        catalogId: catalog.catalogId,
                        skip: 0,
                        genre: nil
                    ))?.items ?? []
                }
            }
            for await items in group { listed += items }
        }

        var result: [ContinueWatchingItem] = []
        var used = Set<String>()
        for team in teams {
            let matches = listed
                .filter { FavouriteTeamsStore.title($0.name, names: team) }
                .compactMap { meta -> ContinueWatchingItem? in
                    let info = meta.releaseInfo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Live with no time given: under way as of now, which the
                    // next refresh moves on while the add-on still lists it.
                    let kickoff = info.uppercased() == "LIVE"
                        ? Date().addingTimeInterval(-60)
                        : Self.kickoff(fromFixtureInfo: info)
                    // A date with no time: shown on the day and the day before.
                    let day = kickoff == nil ? CalendarDayKey.dayKey(fromFixtureInfo: info) : nil
                    guard kickoff != nil || day != nil else { return nil }
                    return ContinueWatchingItem(
                        meta: meta, streamUrl: "", position: 0, duration: 1,
                        lastWatchedAt: kickoff ?? Date(),
                        released: day,
                        isUpNext: true,
                        cardKind: ContinueWatchingItem.fixtureKind,
                        kickoff: kickoff
                    )
                }
                .filter(Self.fixtureIsCurrent)
                .sorted { ($0.kickoff ?? .distantPast) < ($1.kickoff ?? .distantPast) }
            // The next one only: a live match, else the soonest.
            if let next = matches.first, used.insert(next.meta.id).inserted {
                result.append(next)
            }
        }
        return result
    }

    /// From the start of the day before kick-off until the match should be
    /// over; with only a date, that day and the one before.
    static func fixtureIsCurrent(_ item: ContinueWatchingItem) -> Bool {
        guard let kickoff = item.kickoff else {
            guard item.isFixture, let day = item.released else { return false }
            return [CalendarDayKey.dayKey(offsetFromToday: 0), CalendarDayKey.dayKey(offsetFromToday: 1)].contains(day)
        }
        let calendar = Calendar.current
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: kickoff)) ?? kickoff
        let end = kickoff.addingTimeInterval(expectedLength(of: item.meta))
        let now = Date()
        return now >= dayBefore && now <= end
    }

    /// How long a match runs, kick-off to final whistle with a margin, by sport.
    private static func expectedLength(of meta: NuvioMeta) -> TimeInterval {
        let text = ([meta.name] + (meta.genres ?? [])).joined(separator: " ").lowercased()
        let hours: Double
        if text.contains("cricket") {
            hours = 8
        } else if text.contains("nfl") || text.contains("american football") || text.contains("baseball")
                    || text.contains("mlb") {
            hours = 4
        } else if text.contains("ufc") || text.contains("mma") || text.contains("boxing") || text.contains("fight")
                    || text.contains("wwe") {
            hours = 5
        } else if text.contains("tennis") || text.contains("golf") {
            hours = 5
        } else if text.contains("basketball") || text.contains("nba") || text.contains("hockey")
                    || text.contains("nhl") {
            hours = 3
        } else if text.contains("formula") || text.contains("f1") || text.contains("motogp") || text.contains("race") {
            hours = 2.5
        } else {
            // Football, rugby and most others: two halves, a break, stoppage.
            hours = 2.5
        }
        return hours * 3600
    }

    private static let kickoffFormatters: [DateFormatter] = {
        ["dd MMM yyyy · HH:mm 'UTC'", "dd MMM yyyy · HH:mm"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            return formatter
        }
    }()

    /// A sports add-on's `07 Sep 2026 · 00:00 UTC`, as a moment.
    static func kickoff(fromFixtureInfo info: String) -> Date? {
        for formatter in kickoffFormatters {
            if let date = formatter.date(from: info) { return date }
        }
        return nil
    }
}

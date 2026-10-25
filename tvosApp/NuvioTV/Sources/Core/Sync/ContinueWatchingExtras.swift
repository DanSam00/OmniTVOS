import Foundation
#if os(iOS) || os(macOS)
import WidgetKit
#endif

/// The favourite teams whose next match joins Continue Watching. Kept per
/// profile and synced with the account like the other profile settings, so
/// one entry reaches every device. Stored as one name per line: the account
/// sync carries strings, not lists.
enum FavouriteTeamsStore {
    static let changedNotification = Notification.Name("omni.favouriteTeams.changed")

    static func teams() -> [String] {
        let store = ProfileSettings.current
        if let text = store.string(forKey: SettingsKey.favouriteTeams) {
            return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        // 4.1.3 stored a list on this device only; rewritten as text, which
        // the account sync then carries.
        guard let list = store.array(forKey: SettingsKey.favouriteTeams) as? [String] else { return [] }
        store.set(list.joined(separator: "\n"), forKey: SettingsKey.favouriteTeams)
        return list
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
        ProfileSettings.current.set(list.joined(separator: "\n"), forKey: SettingsKey.favouriteTeams)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Club initials a listing usually leaves out: "Liverpool FC" is listed
    /// as "Liverpool vs Brighton".
    private static let clubWords: Set<String> = ["fc", "afc", "cf", "sc", "ac", "bc", "fk", "sk", "cd", "club"]

    /// True when `title` ("Arsenal vs Chelsea") names `team` as whole words.
    static func title(_ title: String, names team: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        var teamWords = words(team)
        let bare = teamWords.filter { !clubWords.contains($0) }
        if !bare.isEmpty { teamWords = bare }
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
            #if os(iOS) || os(macOS)
            if teams.isEmpty { publishToWidget([]) }
            #endif
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
                    // A page is about twenty matches and a busy sport lists
                    // far more, so read on: on the first page alone Liverpool
                    // v Brighton was never seen. Six pages at most.
                    var items: [NuvioMeta] = []
                    var skip = 0
                    for _ in 0..<6 {
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
                    return items
                }
            }
            for await items in group { listed += items }
        }
        #if os(macOS)
        MacDiagnostics.log("fixtures.load catalogs=\(catalogs.count) listed=\(listed.count)")
        #endif

        var nextMatches: [ContinueWatchingItem] = []
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
                .filter(Self.fixtureIsNotOver)
                // By when each is on: a listing with only a date counts as
                // that day, not as the earliest of all. Sorted first, a cup
                // match next week hid the league match tomorrow.
                .sorted { Self.whenOn($0) < Self.whenOn($1) }
            // The next one only: a live match, else the soonest.
            if let next = matches.first, used.insert(next.meta.id).inserted {
                nextMatches.append(next)
            }
            #if os(macOS)
            MacDiagnostics.log("fixtures.team \(team) listed=\(matches.count) next=\(matches.first?.meta.name ?? "-")")
            #endif
        }
        // Your teams' cards (and the widget) always get the app's art: there
        // are few of them, so it is drawn now rather than queued.
        for index in nextMatches.indices {
            let item = nextMatches[index]
            guard await FixtureArtwork.ensureDrawn(item.meta) else { continue }
            nextMatches[index] = ContinueWatchingItem(
                meta: FixtureArtwork.decorated(item.meta),
                streamUrl: "", position: 0, duration: 1,
                lastWatchedAt: item.lastWatchedAt,
                released: item.released,
                isUpNext: true,
                cardKind: ContinueWatchingItem.fixtureKind,
                kickoff: item.kickoff
            )
        }
        #if os(iOS) || os(macOS)
        publishToWidget(nextMatches)
        #endif
        // Continue Watching shows each from the day before.
        return nextMatches.filter(Self.fixtureIsCurrent)
    }

    /// When a fixture is on: its kick-off, or the start of its listed day.
    private static func whenOn(_ item: ContinueWatchingItem) -> Date {
        if let kickoff = item.kickoff { return kickoff }
        if let day = item.released, let date = CalendarDayKey.date(fromDayKey: day) {
            return Calendar.current.startOfDay(for: date)
        }
        return .distantFuture
    }

    /// Not yet finished: before the expected final whistle, or (with only a
    /// date) that day or later.
    static func fixtureIsNotOver(_ item: ContinueWatchingItem) -> Bool {
        if let kickoff = item.kickoff {
            return Date() <= kickoff.addingTimeInterval(expectedLength(of: item.meta))
        }
        guard let day = item.released else { return false }
        return day >= CalendarDayKey.dayKey(offsetFromToday: 0)
    }

    #if os(iOS) || os(macOS)
    /// The teams' next matches for the Coming Up widget, beside the episodes.
    private func publishToWidget(_ matches: [ContinueWatchingItem]) {
        let feed = matches.compactMap { item -> UpcomingEpisodeEntry? in
            let day = item.kickoff ?? item.released.flatMap(CalendarDayKey.date(fromDayKey:))
            guard let day else { return nil }
            return UpcomingEpisodeEntry(
                id: "match|" + item.meta.id,
                metaId: item.meta.id,
                type: item.meta.type,
                title: item.meta.name,
                episodeCode: nil,
                episodeTitle: nil,
                airDate: Calendar.current.startOfDay(for: day),
                posterURL: item.meta.posterUrl,
                imageURL: item.meta.backgroundUrl,
                kickoff: item.kickoff,
                matchLength: Self.expectedLength(of: item.meta)
            )
        }
        guard UpcomingEpisodeFeedStore.readMatches() != feed else { return }
        UpcomingEpisodeFeedStore.writeMatches(feed)
        WidgetCenter.shared.reloadTimelines(ofKind: OmniWidgetKind.upcoming)
        let sources = feed.flatMap { [$0.posterURL, $0.imageURL].compactMap { $0 } }
        Task {
            if await WidgetArtworkCache.fill(sources) {
                WidgetCenter.shared.reloadTimelines(ofKind: OmniWidgetKind.upcoming)
            }
            WidgetArtworkCache.pruneToFeeds()
        }
    }
    #endif

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
    static func expectedLength(of meta: NuvioMeta) -> TimeInterval {
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

    /// A time marked UTC is UTC; one with no zone is the viewer's own, which
    /// is how the sports add-ons write it ("25 Oct 2026 · 13:00", or on the
    /// next request "25 Oct 2026 · 1:00 PM", for a 1 pm tip-off in Sydney).
    /// Decided by whether the text says UTC: the formatter's literal does not
    /// decide it, since DateFormatter accepted "13:00" for "HH:mm 'UTC'" and
    /// read every unmarked time as UTC, a game an hour away as tomorrow.
    static func kickoff(fromFixtureInfo info: String) -> Date? {
        FixtureTime.parse(info)
    }
}

import SwiftUI
import WidgetKit

// MARK: - Upcoming episodes
//
// New episodes of the shows you follow, from the Calendar's data, and your
// favourite teams' next matches. The app refreshes the episodes when the
// Calendar loads and, while this widget is on the Home Screen or desktop,
// every few hours on opening Omni; the matches whenever Home loads them.

struct UpcomingEpisodesEntry: TimelineEntry {
    let date: Date
    let episodes: [UpcomingEpisodeEntry]
    let hasFeed: Bool
}

struct UpcomingEpisodesProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingEpisodesEntry {
        UpcomingEpisodesEntry(date: Date(), episodes: Self.samples, hasFeed: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingEpisodesEntry) -> Void) {
        let entry = Self.entry(at: Date())
        completion(entry.episodes.isEmpty && context.isPreview
            ? UpcomingEpisodesEntry(date: Date(), episodes: Self.samples, hasFeed: true)
            : entry)
    }

    /// One entry now, one at each of the next midnights (so "Tomorrow" turns
    /// into "Today" and aired episodes drop off without the app), and one at
    /// each match's kick-off and expected end, for LIVE.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingEpisodesEntry>) -> Void) {
        let calendar = Calendar.current
        let now = Date()
        let horizon = now.addingTimeInterval(7 * 24 * 3600)
        var dates = [now]
        var day = calendar.startOfDay(for: now)
        for _ in 0..<7 {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            dates.append(day)
        }
        for match in UpcomingEpisodeFeedStore.readMatches() {
            guard let kickoff = match.kickoff else { continue }
            dates += [kickoff, kickoff.addingTimeInterval(match.matchLength ?? 3 * 3600)]
                .filter { $0 > now && $0 < horizon }
        }
        completion(Timeline(entries: Set(dates).sorted().map(Self.entry(at:)), policy: .atEnd))
    }

    private static func entry(at date: Date) -> UpcomingEpisodesEntry {
        let feed = UpcomingEpisodeFeedStore.read()
        let matches = UpcomingEpisodeFeedStore.readMatches()
        // A match under way first, then everything by when it is on.
        let episodes = ((feed?.entries ?? []) + matches)
            .filter { $0.isCurrent(at: date) }
            .sorted { lhs, rhs in
                if lhs.isLive(at: date) != rhs.isLive(at: date) { return lhs.isLive(at: date) }
                return (lhs.kickoff ?? lhs.airDate) < (rhs.kickoff ?? rhs.airDate)
            }
        return UpcomingEpisodesEntry(date: date, episodes: episodes, hasFeed: feed != nil || !matches.isEmpty)
    }

    private static let samples: [UpcomingEpisodeEntry] = (0..<6).map { index in
        UpcomingEpisodeEntry(
            id: "sample\(index)", metaId: "sample\(index)", type: "series",
            title: ["A show you follow", "Another favourite", "Season finale", "New season", "Back again", "One more"][index],
            episodeCode: String(format: "S01E%02d", index + 4), episodeTitle: nil,
            airDate: Calendar.current.date(byAdding: .day, value: index, to: Calendar.current.startOfDay(for: Date()))!,
            posterURL: nil, imageURL: nil
        )
    }
}

struct UpcomingEpisodesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OmniWidgetKind.upcoming, provider: UpcomingEpisodesProvider()) { entry in
            UpcomingEpisodesWidgetView(entry: entry)
        }
        .configurationDisplayName("Coming Up")
        .description("New episodes of the shows you follow, and your teams' next matches.")
        .supportedFamilies(OmniWidgetLayout.families)
        .contentMarginsDisabled()
    }
}

struct UpcomingEpisodesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpcomingEpisodesEntry

    private var layout: OmniWidgetLayout { OmniWidgetLayout(family) }
    private var episodes: [UpcomingEpisodeEntry] { entry.episodes }

    var body: some View {
        Group {
            if episodes.isEmpty {
                WidgetEmptyState(
                    symbol: "calendar",
                    message: entry.hasFeed ? "No new episodes in the next month" : "Open Omni to load your shows"
                )
                .padding(14)
            } else {
                switch layout {
                case .small: hero(episodes[0], titleSize: 16).widgetURL(episodes[0].deepLinkURL)
                case .medium: medium
                case .large: stacked(heroShare: 0.5, rows: 2)
                case .extraLargePortrait: stacked(heroShare: 0.36, rows: 5)
                case .extraLarge: wide
                case .rectangular: rectangular
                }
            }
        }
        .foregroundStyle(.white)
        .omniWidgetBackground(layout)
    }

    // MARK: Layouts

    private var medium: some View {
        HStack(spacing: 0) {
            heroLink(episodes[0], titleSize: 15)
                .frame(maxWidth: .infinity)
            rows(Array(episodes.dropFirst().prefix(2)))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .environment(\.widgetRowCompact, true)
        }
    }

    private func stacked(heroShare: CGFloat, rows count: Int) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                heroLink(episodes[0], titleSize: 19)
                    .frame(height: proxy.size.height * heroShare)
                rows(Array(episodes.dropFirst().prefix(count)), slots: count)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
    }

    private var wide: some View {
        HStack(spacing: 0) {
            heroLink(episodes[0], titleSize: 24)
                .frame(maxWidth: .infinity)
            rows(Array(episodes.dropFirst().prefix(4)), slots: 4)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        let next = episodes[0]
        return VStack(alignment: .leading, spacing: 1) {
            Label(
                next.isLive(at: entry.date) ? "LIVE" : dayLabel(next.kickoff ?? next.airDate),
                systemImage: next.isMatch ? "sportscourt" : "calendar"
            )
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
            Text(next.title).font(.headline).lineLimit(1)
            Text(detail(next)).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(next.deepLinkURL)
    }

    // MARK: Parts

    private func hero(_ episode: UpcomingEpisodeEntry, titleSize: CGFloat) -> some View {
        WidgetHero(
            title: episode.title,
            meta: meta(episode),
            metaHighlighted: isToday(episode.airDate),
            isLive: episode.isLive(at: entry.date),
            art: episode.imageURL,
            fallback: episode.posterURL,
            titleSize: titleSize
        )
    }

    private func heroLink(_ episode: UpcomingEpisodeEntry, titleSize: CGFloat) -> some View {
        Link(destination: episode.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
            hero(episode, titleSize: titleSize)
        }
    }

    private func rows(_ list: [UpcomingEpisodeEntry], slots: Int? = nil) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, episode in
                WidgetRow(
                    title: episode.title,
                    meta: meta(episode),
                    metaHighlighted: isToday(episode.airDate),
                    isLive: episode.isLive(at: entry.date),
                    art: episode.imageURL,
                    fallback: episode.posterURL,
                    isLast: index == list.count - 1,
                    url: episode.deepLinkURL
                )
            }
            if let slots, list.count < slots {
                ForEach(list.count..<slots, id: \.self) { _ in
                    Color.clear.frame(maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: Text

    /// "TOMORROW · S1, E6", in the Apple TV app's manner; for a match
    /// "TODAY · 7:30 PM", then "LIVE".
    private func meta(_ episode: UpcomingEpisodeEntry) -> String {
        if let kickoff = episode.kickoff {
            if episode.isLive(at: entry.date) { return "LIVE" }
            return [dayLabel(kickoff), kickoff.formatted(date: .omitted, time: .shortened)].joined(separator: " · ")
        }
        return [dayLabel(episode.airDate), episodeCode(episode)].compactMap { $0 }.joined(separator: " · ")
    }

    private func episodeCode(_ episode: UpcomingEpisodeEntry) -> String? {
        guard let code = episode.episodeCode, code.hasPrefix("S") else { return episode.episodeCode }
        let parts = code.dropFirst().split(separator: "E")
        guard parts.count == 2, let season = Int(parts[0]), let number = Int(parts[1]) else { return code }
        return "S\(season), E\(number)"
    }

    private func detail(_ episode: UpcomingEpisodeEntry) -> String {
        if let kickoff = episode.kickoff, !episode.isLive(at: entry.date) {
            return kickoff.formatted(date: .omitted, time: .shortened)
        }
        return [episode.episodeCode, episode.episodeTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDate(date, inSameDayAs: entry.date)
    }

    /// Today, Tomorrow, a weekday within the week, else a short date.
    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: entry.date), to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Tomorrow"
        case 2..<7: return date.formatted(.dateTime.weekday(.wide))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

import SwiftUI
import WidgetKit

// MARK: - Upcoming episodes
//
// New episodes of the shows you follow, from the Calendar's data. The app
// refreshes the feed when the Calendar loads and, while this widget is on the
// Home Screen or desktop, every few hours on opening Omni.

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

    /// One entry now and one at each of the next midnights, so "Tomorrow"
    /// turns into "Today" and aired episodes drop off without the app.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingEpisodesEntry>) -> Void) {
        let calendar = Calendar.current
        let now = Date()
        var dates = [now]
        var day = calendar.startOfDay(for: now)
        for _ in 0..<7 {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            dates.append(day)
        }
        completion(Timeline(entries: dates.map(Self.entry(at:)), policy: .atEnd))
    }

    private static func entry(at date: Date) -> UpcomingEpisodesEntry {
        let feed = UpcomingEpisodeFeedStore.read()
        let today = Calendar.current.startOfDay(for: date)
        let episodes = (feed?.entries ?? []).filter { $0.airDate >= today }
        return UpcomingEpisodesEntry(date: date, episodes: episodes, hasFeed: feed != nil)
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
        .description("New episodes of the shows you follow.")
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
                VStack(spacing: 0) {
                    if layout != .small && layout != .rectangular {
                        header
                    }
                    WidgetEmptyState(
                        symbol: "calendar",
                        message: entry.hasFeed ? "No new episodes in the next month" : "Open Omni to load your shows"
                    )
                }
                .padding(14)
            } else {
                switch layout {
                case .small: small
                case .medium: medium
                case .large: stacked(rows: 4)
                case .extraLarge: wide
                case .extraLargePortrait: stacked(rows: 8)
                case .rectangular: rectangular
                }
            }
        }
        .foregroundStyle(.white)
        .omniWidgetBackground(layout)
    }

    private var header: some View {
        WidgetHeader(symbol: "calendar", title: "Coming Up", chip: weekChip)
    }

    /// "3 this week", or the count overall when none are this week.
    private var weekChip: String {
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: entry.date)) ?? entry.date
        let thisWeek = episodes.filter { $0.airDate < weekEnd }.count
        return thisWeek > 0 ? "\(thisWeek) this week" : "\(episodes.count) coming"
    }

    // MARK: Small: the next release, full bleed

    private var small: some View {
        let next = episodes[0]
        return ZStack(alignment: .bottomLeading) {
            WidgetArtwork(source: next.imageURL, fallback: next.posterURL)
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                WidgetPill(text: dayLabel(next.airDate), highlighted: isToday(next.airDate))
                Spacer(minLength: 0)
                Text(next.title)
                    .font(.system(size: 16, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let code = next.episodeCode {
                    Text(code)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(OmniWidgetStyle.secondary)
                }
            }
            .padding(12)
        }
        .widgetURL(next.deepLinkURL)
    }

    // MARK: Medium: the next three

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(spacing: 4) {
                ForEach(episodes.prefix(3)) { row($0, height: 34) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(14)
    }

    // MARK: Large and Extra Large Portrait: what is next, then the rest

    private func stacked(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            highlight(episodes[0])
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            if episodes.count > 1 {
                WidgetPanel(padding: 8) {
                    VStack(spacing: 4) {
                        ForEach(episodes.dropFirst().prefix(rows)) { row($0, height: 36) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    // MARK: Extra Large (Mac): what is next beside the rest

    private var wide: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 12) {
                highlight(episodes[0])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if episodes.count > 1 {
                    WidgetPanel(padding: 8) {
                        VStack(spacing: 4) {
                            ForEach(episodes.dropFirst().prefix(5)) { row($0, height: 36) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(16)
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        let next = episodes[0]
        return VStack(alignment: .leading, spacing: 1) {
            Label(dayLabel(next.airDate), systemImage: "calendar")
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
            Text(next.title).font(.headline).lineLimit(1)
            Text(detail(next)).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(next.deepLinkURL)
    }

    // MARK: Parts

    /// The next release as a lit panel: its art, the day in large capitals,
    /// the show and the episode.
    private func highlight(_ episode: UpcomingEpisodeEntry) -> some View {
        Link(destination: episode.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
            ZStack(alignment: .bottomLeading) {
                WidgetArtwork(source: episode.imageURL, fallback: episode.posterURL)
                LinearGradient(colors: [.clear, .black.opacity(0.3), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Spacer(minLength: 0)
                    Text(dayLabel(episode.airDate).uppercased())
                        .font(.system(size: 22, weight: .black))
                        .tracking(0.5)
                        .foregroundStyle(isToday(episode.airDate) ? OmniWidgetStyle.accent : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(episode.title)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text(detail(episode).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(OmniWidgetStyle.secondary)
                        .lineLimit(1)
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func row(_ episode: UpcomingEpisodeEntry, height: CGFloat) -> some View {
        Link(destination: episode.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
            HStack(spacing: 10) {
                WidgetArtwork(source: episode.posterURL, fallback: episode.imageURL)
                    .frame(width: height * 2 / 3, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(episode.title)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Text(detail(episode))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OmniWidgetStyle.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                WidgetPill(text: dayLabel(episode.airDate), highlighted: isToday(episode.airDate))
            }
            .frame(height: height)
        }
    }

    // MARK: Text

    private func detail(_ episode: UpcomingEpisodeEntry) -> String {
        [episode.episodeCode, episode.episodeTitle].compactMap { $0 }.joined(separator: " · ")
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
        case 2..<7: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

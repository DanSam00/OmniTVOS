import SwiftUI
import WidgetKit

// MARK: - Upcoming episodes
//
// New episodes of the shows you follow, from the Calendar's data. The app
// refreshes the feed when the Calendar loads and, while this widget is on the
// Home Screen, every few hours on opening Omni.

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

    private static let samples: [UpcomingEpisodeEntry] = (0..<4).map { index in
        UpcomingEpisodeEntry(
            id: "sample\(index)", metaId: "sample\(index)", type: "series",
            title: ["A show you follow", "Another favourite", "Season finale", "New season"][index],
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct UpcomingEpisodesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpcomingEpisodesEntry

    var body: some View {
        Group {
            if entry.episodes.isEmpty {
                WidgetEmptyState(
                    symbol: "calendar",
                    message: entry.hasFeed ? "No new episodes in the next month" : "Open Omni to load your shows"
                )
                .padding()
            } else {
                switch family {
                case .systemSmall: small
                case .systemMedium: list(count: 3)
                case .systemLarge: list(count: 6)
                case .accessoryRectangular: rectangular
                default: small
                }
            }
        }
        .containerBackground(for: .widget) {
            family == .accessoryRectangular ? AnyView(AccessoryWidgetBackground()) : AnyView(OmniWidgetStyle.background)
        }
    }

    // MARK: Small: the next release, full bleed

    private var small: some View {
        let next = entry.episodes[0]
        return ZStack(alignment: .bottomLeading) {
            WidgetArtwork(source: next.imageURL, fallback: next.posterURL)
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel(next.airDate).uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(OmniWidgetStyle.accent)
                Text(next.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                if let code = next.episodeCode {
                    Text(code).font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .widgetURL(next.deepLinkURL)
    }

    // MARK: Medium and large: a dated list

    private func list(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Coming Up").font(.caption.weight(.bold))
                Spacer()
                Image(systemName: "calendar").font(.caption).foregroundStyle(OmniWidgetStyle.accent)
            }
            ForEach(entry.episodes.prefix(count)) { episode in
                Link(destination: episode.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
                    HStack(spacing: 10) {
                        WidgetArtwork(source: episode.posterURL, fallback: episode.imageURL)
                            .frame(width: 26, height: 39)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(detail(episode)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(dayLabel(episode.airDate))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isToday(episode.airDate) ? OmniWidgetStyle.accent : .secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        let next = entry.episodes[0]
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
        case 2..<7: return date.formatted(.dateTime.weekday(.wide))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

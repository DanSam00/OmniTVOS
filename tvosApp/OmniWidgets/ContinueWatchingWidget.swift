import SwiftUI
import WidgetKit

// MARK: - Continue Watching
//
// The same row as Home's Continue Watching, written by the app into the App
// Group. Tapping a title resumes it, as the Apple TV Top Shelf does.

struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let items: [TopShelfEntry]
}

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: Date(), items: Self.samples)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        let items = TopShelfFeedStore.read()?.entries ?? []
        completion(ContinueWatchingEntry(date: Date(), items: items.isEmpty && context.isPreview ? Self.samples : items))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        let entry = ContinueWatchingEntry(date: Date(), items: TopShelfFeedStore.read()?.entries ?? [])
        // The app reloads this whenever the row changes; the hourly check is
        // only a safety net.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
    }

    private static let samples = [
        TopShelfEntry(contentId: "sample1", contentType: "series", title: "Your next episode",
                      subtitle: "S1 · E3  ·  32m left", imageURL: nil, progress: 0.4),
        TopShelfEntry(contentId: "sample2", contentType: "movie", title: "A film you started",
                      subtitle: "1h 10m left", imageURL: nil, progress: 0.25),
        TopShelfEntry(contentId: "sample3", contentType: "series", title: "A show you follow",
                      subtitle: "S2 · E1", imageURL: nil, progress: nil),
    ]
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OmniWidgetKind.continueWatching, provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies(OmniWidgetLayout.families)
        .contentMarginsDisabled()
    }
}

struct ContinueWatchingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueWatchingEntry

    private var layout: OmniWidgetLayout { OmniWidgetLayout(family) }
    private var items: [TopShelfEntry] { entry.items }

    var body: some View {
        Group {
            if items.isEmpty {
                WidgetEmptyState(symbol: "play.circle", message: "Start watching something in Omni")
                    .padding(14)
            } else {
                switch layout {
                case .small: hero(items[0], titleSize: 16).widgetURL(items[0].deepLinkURL)
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

    /// Medium: the latest beside the next two.
    private var medium: some View {
        HStack(spacing: 0) {
            heroLink(items[0], titleSize: 15)
                .frame(maxWidth: .infinity)
            rows(Array(items.dropFirst().prefix(2)))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .environment(\.widgetRowCompact, true)
        }
    }

    /// Large and Extra Large Portrait: the latest across the top, the rest
    /// listed under it.
    private func stacked(heroShare: CGFloat, rows count: Int) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                heroLink(items[0], titleSize: 19)
                    .frame(height: proxy.size.height * heroShare)
                rows(Array(items.dropFirst().prefix(count)), slots: count)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
    }

    /// Extra Large (Mac): the latest filling the left half, top to bottom; the
    /// next four evenly down the right.
    private var wide: some View {
        HStack(spacing: 0) {
            heroLink(items[0], titleSize: 24)
                .frame(maxWidth: .infinity)
            rows(Array(items.dropFirst().prefix(4)), slots: 4)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        let item = items[0]
        return VStack(alignment: .leading, spacing: 1) {
            Label("Continue", systemImage: "play.fill")
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
            Text(item.title).font(.headline).lineLimit(1)
            if let progress = item.progress {
                ProgressView(value: progress)
            } else if let subtitle = item.subtitle {
                Text(subtitle).font(.caption).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(item.deepLinkURL)
    }

    // MARK: Parts

    private func hero(_ item: TopShelfEntry, titleSize: CGFloat) -> some View {
        WidgetHero(
            title: item.title,
            meta: Self.meta(item),
            progress: item.progress,
            art: item.backdropURL,
            fallback: item.imageURL,
            titleSize: titleSize
        )
    }

    private func heroLink(_ item: TopShelfEntry, titleSize: CGFloat) -> some View {
        Link(destination: item.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
            hero(item, titleSize: titleSize)
        }
    }

    /// The list. With `slots`, rows keep the height of a full list even when
    /// there are fewer titles, so a short list sits at the top rather than
    /// stretching.
    private func rows(_ list: [TopShelfEntry], slots: Int? = nil) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.contentId) { index, item in
                WidgetRow(
                    title: item.title,
                    meta: Self.meta(item),
                    progress: item.progress,
                    art: item.backdropURL,
                    fallback: item.imageURL,
                    isLast: index == list.count - 1,
                    url: item.deepLinkURL
                )
            }
            if let slots, list.count < slots {
                ForEach(list.count..<slots, id: \.self) { _ in
                    Color.clear.frame(maxHeight: .infinity)
                }
            }
        }
    }

    /// The capitals line, as the Apple TV app writes it: "NEXT · S2, E1" for
    /// an episode not yet started, else where you are and what is left.
    private static func meta(_ item: TopShelfEntry) -> String? {
        guard let subtitle = item.subtitle else { return item.progress == nil ? "Next" : nil }
        let parts = subtitle.components(separatedBy: "  ·  ")
        let episode = parts.first.map { $0.replacingOccurrences(of: " · ", with: ", ") }
        if item.progress == nil {
            return ["Next", episode].compactMap { $0 }.joined(separator: " · ")
        }
        return ([episode] + parts.dropFirst().map { Optional($0) }).compactMap { $0 }.joined(separator: " · ")
    }
}

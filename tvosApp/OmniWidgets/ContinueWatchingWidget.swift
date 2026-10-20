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
                VStack(spacing: 0) {
                    if layout != .small && layout != .rectangular {
                        header
                    }
                    WidgetEmptyState(symbol: "play.circle", message: "Start watching something in Omni")
                }
                .padding(14)
            } else {
                switch layout {
                case .small: small
                case .medium: medium
                case .large: stacked(rows: 3)
                case .extraLarge: wide
                case .extraLargePortrait: stacked(rows: 6)
                case .rectangular: rectangular
                }
            }
        }
        .foregroundStyle(.white)
        .omniWidgetBackground(layout)
    }

    private var header: some View {
        WidgetHeader(
            symbol: "play.fill",
            title: "Continue Watching",
            chip: items.count == 1 ? "1 title" : "\(items.count) titles"
        )
    }

    // MARK: Small: the latest, full bleed

    private var small: some View {
        let item = items[0]
        return ZStack(alignment: .bottomLeading) {
            WidgetArtwork(source: item.backdropURL, fallback: item.imageURL)
            LinearGradient(
                colors: [.black.opacity(0.35), .clear, .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 4) {
                WidgetPill(text: "Continue", highlighted: true)
                Spacer(minLength: 0)
                Text(item.title)
                    .font(.system(size: 16, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let meta = Self.meta(item) {
                    Text(meta)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(OmniWidgetStyle.secondary)
                        .lineLimit(1)
                }
                if let progress = item.progress {
                    WidgetProgressBar(value: progress).padding(.top, 2)
                }
            }
            .padding(12)
        }
        .widgetURL(item.deepLinkURL)
    }

    // MARK: Medium: a shelf of posters

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 8) {
                ForEach(items.prefix(4), id: \.contentId) { item in
                    Link(destination: item.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
                        VStack(spacing: 5) {
                            WidgetArtwork(source: item.imageURL, fallback: item.backdropURL)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                                )
                            WidgetProgressBar(value: item.progress ?? 0)
                                .opacity(item.progress == nil ? 0 : 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                ForEach(0..<max(0, 4 - items.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(14)
    }

    // MARK: Large and Extra Large Portrait: the latest up top, the rest below

    private func stacked(rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            hero(items[0])
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            if items.count > 1 {
                list(Array(items.dropFirst().prefix(rows)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    // MARK: Extra Large (Mac): the latest beside the rest

    private var wide: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 12) {
                hero(items[0])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if items.count > 1 {
                    list(Array(items.dropFirst().prefix(5)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(16)
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

    /// The latest title as a lit panel: artwork, title, where you are, and
    /// a resume pill.
    private func hero(_ item: TopShelfEntry) -> some View {
        Link(destination: item.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
            ZStack(alignment: .bottomLeading) {
                WidgetArtwork(source: item.backdropURL, fallback: item.imageURL)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.25), .black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        WidgetPill(text: item.progress == nil ? "Up next" : "Resume", highlighted: true)
                        Spacer()
                    }
                    Spacer(minLength: 0)
                    Text(item.title)
                        .font(.system(size: 20, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let meta = Self.meta(item) {
                        Text(meta)
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(OmniWidgetStyle.secondary)
                            .lineLimit(1)
                    }
                    if let progress = item.progress {
                        WidgetProgressBar(value: progress, height: 4).padding(.top, 3)
                    }
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

    /// The rest, as rows inside a panel.
    private func list(_ rows: [TopShelfEntry]) -> some View {
        WidgetPanel(padding: 8) {
            VStack(spacing: 6) {
                ForEach(rows, id: \.contentId) { item in
                    Link(destination: item.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
                        HStack(spacing: 10) {
                            WidgetArtwork(source: item.backdropURL, fallback: item.imageURL)
                                .frame(width: 64, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    if let meta = Self.meta(item) {
                                        Text(meta)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(OmniWidgetStyle.tertiary)
                                            .lineLimit(1)
                                    }
                                    if let progress = item.progress {
                                        WidgetProgressBar(value: progress, height: 2.5)
                                            .frame(maxWidth: 70)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 38)
                    }
                }
            }
        }
    }

    /// "S2 · E3 · 22M LEFT", in the card's caps.
    private static func meta(_ item: TopShelfEntry) -> String? {
        item.subtitle?
            .replacingOccurrences(of: "  ·  ", with: " · ")
            .uppercased()
    }
}

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
    ]
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OmniWidgetKind.continueWatching, provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct ContinueWatchingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueWatchingEntry

    var body: some View {
        Group {
            if entry.items.isEmpty {
                WidgetEmptyState(symbol: "play.circle", message: "Start watching something in Omni")
                    .padding()
            } else {
                switch family {
                case .systemSmall: small
                case .systemMedium: medium
                case .systemLarge: large
                case .accessoryRectangular: rectangular
                default: small
                }
            }
        }
        .containerBackground(for: .widget) {
            family == .accessoryRectangular ? AnyView(AccessoryWidgetBackground()) : AnyView(OmniWidgetStyle.background)
        }
    }

    // MARK: Small: the most recent title, full bleed

    private var small: some View {
        let item = entry.items[0]
        return ZStack(alignment: .bottomLeading) {
            WidgetArtwork(source: item.backdropURL, fallback: item.imageURL)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                if let progress = item.progress {
                    WidgetProgressBar(value: progress).padding(.top, 3)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .widgetURL(item.deepLinkURL)
    }

    // MARK: Medium: a row of posters

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 8) {
                ForEach(entry.items.prefix(4), id: \.contentId) { item in
                    Link(destination: item.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
                        VStack(spacing: 4) {
                            WidgetArtwork(source: item.imageURL, fallback: item.backdropURL)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(2 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            WidgetProgressBar(value: item.progress ?? 0)
                                .opacity(item.progress == nil ? 0 : 1)
                        }
                    }
                }
                ForEach(0..<max(0, 4 - entry.items.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
    }

    // MARK: Large: the latest up top, then the rest

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            let first = entry.items[0]
            Link(destination: first.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
                ZStack(alignment: .bottomLeading) {
                    WidgetArtwork(source: first.backdropURL, fallback: first.imageURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(first.title).font(.headline).lineLimit(1)
                        if let subtitle = first.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                        if let progress = first.progress {
                            WidgetProgressBar(value: progress).padding(.top, 2)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            ForEach(entry.items.dropFirst().prefix(3), id: \.contentId) { item in
                Link(destination: item.deepLinkURL ?? URL(string: "nuvio-tv://")!) {
                    HStack(spacing: 10) {
                        WidgetArtwork(source: item.backdropURL, fallback: item.imageURL)
                            .frame(width: 84, height: 47)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let subtitle = item.subtitle {
                                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let progress = item.progress {
                                WidgetProgressBar(value: progress, height: 2.5)
                            }
                        }
                        Spacer(minLength: 0)
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
        let item = entry.items[0]
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

    private var header: some View {
        HStack {
            Text("Continue Watching")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.caption)
                .foregroundStyle(OmniWidgetStyle.accent)
        }
    }
}

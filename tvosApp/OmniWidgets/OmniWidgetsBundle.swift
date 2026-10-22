import ImageIO
import SwiftUI
import WidgetKit

@main
struct OmniWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        UpcomingEpisodesWidget()
        #if os(iOS)
        DownloadsLiveActivity()
        #endif
    }
}

// MARK: - Sizes

/// The widget sizes, folded into one switchable set: the newest
/// (Extra Large Portrait) is only on iOS and macOS 27.
enum OmniWidgetLayout {
    case small, medium, large, extraLarge, extraLargePortrait, rectangular

    init(_ family: WidgetFamily) {
        if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait {
            self = .extraLargePortrait
            return
        }
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        case .systemExtraLarge: self = .extraLarge
        case .accessoryRectangular: self = .rectangular
        default: self = .small
        }
    }

    /// What each Omni widget offers: Extra Large is a Mac (and iPad) size,
    /// the Lock Screen one an iPhone size.
    static var families: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        #if os(iOS)
        families.append(.accessoryRectangular)
        #else
        families.append(.systemExtraLarge)
        #endif
        if #available(iOS 27.0, macOS 27.0, *) {
            families.append(.systemExtraLargePortrait)
        }
        return families
    }
}

// MARK: - Look

/// Omni's widget look, after the Apple TV app's: the artwork full bleed at the
/// top with the wordmark in its corner, the title and a small capitals line
/// over its foot, and a plain list beneath on a near-black card.
enum OmniWidgetStyle {
    /// The theme colour chosen in the app's Settings, else white. Used
    /// sparingly: progress, and what is on today.
    static var accent: Color {
        let rgb = WidgetTheme.accentComponents
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static let card = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let secondary = Color.white.opacity(0.6)
    static let separator = Color.white.opacity(0.12)

    static var background: some View { card }

    /// The white Omni wordmark, shipped inside the extension.
    static let wordmark: Image? = {
        guard let url = Bundle.main.url(forResource: "OmniWordmark", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Image(decorative: image, scale: 2)
    }()
}

/// The wordmark for a hero's corner.
struct WidgetWordmark: View {
    var height: CGFloat = 14

    var body: some View {
        if let wordmark = OmniWidgetStyle.wordmark {
            wordmark
                .resizable()
                .scaledToFit()
                .frame(height: height)
                .shadow(color: .black.opacity(0.5), radius: 4)
        }
    }
}

/// The lead title: artwork edge to edge, the wordmark in the top corner, the
/// title and its capitals line over a dark foot.
struct WidgetHero: View {
    let title: String
    let meta: String?
    var metaHighlighted = false
    var isLive = false
    var progress: Double? = nil
    let art: String?
    var fallback: String? = nil
    var titleSize: CGFloat = 18
    var showsWordmark = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WidgetArtwork(source: art, fallback: fallback)
            LinearGradient(
                colors: [.black.opacity(0.25), .clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 3) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let meta {
                    WidgetMeta(text: meta, highlighted: metaHighlighted, isLive: isLive)
                }
                if let progress {
                    WidgetProgressBar(value: progress, height: 3)
                        .frame(maxWidth: 160)
                        .padding(.top, 3)
                }
            }
            .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            if showsWordmark {
                WidgetWordmark().padding(12)
            }
        }
        .foregroundStyle(.white)
    }
}

/// The small capitals line: NEXT · S2, E1. Live content gets a red dot.
struct WidgetMeta: View {
    let text: String
    var highlighted = false
    var isLive = false
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 5) {
            if isLive {
                Circle()
                    .fill(Color.red)
                    .frame(width: size * 0.7, height: size * 0.7)
                    .shadow(color: .red.opacity(0.8), radius: 3)
            }
            Text(text.uppercased())
                .font(.system(size: size, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(isLive ? .white : (highlighted ? OmniWidgetStyle.accent : OmniWidgetStyle.secondary))
                .lineLimit(1)
        }
    }
}

extension EnvironmentValues {
    /// Medium widgets: rows half a widget wide, so a smaller thumbnail.
    @Entry var widgetRowCompact = false
}

/// One row of the list: a 16:9 thumbnail, the title and its capitals line,
/// and a hairline under the text unless it is the last.
struct WidgetRow: View {
    let title: String
    let meta: String?
    var metaHighlighted = false
    var isLive = false
    var progress: Double? = nil
    let art: String?
    var fallback: String? = nil
    var isLast = false
    var url: URL?
    @Environment(\.widgetRowCompact) private var compact

    var body: some View {
        Link(destination: url ?? URL(string: "nuvio-tv://")!) {
            HStack(spacing: compact ? 10 : 14) {
                // Capped so the title keeps most of a narrow list's width.
                WidgetArtwork(source: art, fallback: fallback)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: compact ? 56 : 108)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(.system(size: compact ? 13 : 15, weight: .semibold))
                        .lineLimit(1)
                    if let meta {
                        WidgetMeta(text: meta, highlighted: metaHighlighted, isLive: isLive, size: 10)
                    }
                    if let progress {
                        WidgetProgressBar(value: progress, height: 2.5)
                            .frame(maxWidth: 90)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if !isLast {
                        Rectangle().fill(OmniWidgetStyle.separator).frame(height: 0.5)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
    }
}

/// Artwork from the App Group cache, or a quiet placeholder until the app has
/// stored it. Fills whatever space it is given and crops to it.
struct WidgetArtwork: View {
    let source: String?
    var fallback: String? = nil

    var body: some View {
        Color.clear
            .overlay { content }
            .clipped()
    }

    @ViewBuilder
    private var content: some View {
        if let image = Self.image(for: source) ?? Self.image(for: fallback) {
            image
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                Image(systemName: "play.rectangle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.3))
            )
        }
    }

    /// Decoded with ImageIO, which both iOS and macOS have.
    static func image(for source: String?) -> Image? {
        guard let file = WidgetArtworkCache.cachedFile(for: source),
              let imageSource = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}

/// A slim progress bar in the theme colour.
struct WidgetProgressBar: View {
    let value: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(OmniWidgetStyle.accent)
                    .frame(width: max(height, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Shown when a feed is empty: the app has not written one yet.
struct WidgetEmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(OmniWidgetStyle.accent)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(OmniWidgetStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// The card background for system sizes; the system's own on the Lock
    /// Screen.
    @ViewBuilder
    func omniWidgetBackground(_ layout: OmniWidgetLayout) -> some View {
        if layout == .rectangular {
            containerBackground(for: .widget) { AccessoryWidgetBackground() }
        } else {
            containerBackground(for: .widget) { OmniWidgetStyle.background }
        }
    }
}

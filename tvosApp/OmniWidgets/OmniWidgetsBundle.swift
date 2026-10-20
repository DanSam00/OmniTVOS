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

/// Omni's widget look: a deep navy card lit by the theme colour, a clear
/// header, inset panels and large type for what matters.
enum OmniWidgetStyle {
    /// The theme colour chosen in the app's Settings, else white.
    static var accent: Color {
        let rgb = WidgetTheme.accentComponents
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static let ink = Color(red: 0.07, green: 0.08, blue: 0.13)
    static let navy = Color(red: 0.11, green: 0.13, blue: 0.21)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.42)

    /// The card itself: navy, darker at the foot, with a soft glow of the
    /// theme colour from the top corner.
    static var background: some View {
        ZStack {
            LinearGradient(colors: [navy, ink], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [accent.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 260
            )
        }
    }
}

/// The header every Omni widget opens with: an icon tile, the title in
/// tracked capitals, and a chip on the right.
struct WidgetHeader: View {
    let symbol: String
    let title: String
    var chip: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OmniWidgetStyle.accent)
                .frame(width: 22, height: 22)
                .background(OmniWidgetStyle.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let chip {
                Text(chip)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(OmniWidgetStyle.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
            }
        }
        .frame(height: 22)
    }
}

/// An inset panel: a slightly lighter, finely edged block inside the card.
struct WidgetPanel<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            )
    }
}

/// A small capsule label: TODAY, TOMORROW, RESUME.
struct WidgetPill: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(highlighted ? OmniWidgetStyle.ink : .white.opacity(0.8))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(highlighted ? AnyShapeStyle(OmniWidgetStyle.accent) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
            .lineLimit(1)
            .fixedSize()
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
                colors: [OmniWidgetStyle.accent.opacity(0.25), OmniWidgetStyle.navy],
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

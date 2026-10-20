import SwiftUI
import WidgetKit

@main
struct OmniWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        UpcomingEpisodesWidget()
        DownloadsLiveActivity()
    }
}

// MARK: - Shared look

enum OmniWidgetStyle {
    /// The theme colour chosen in the app's Settings, else white.
    static var accent: Color {
        let rgb = WidgetTheme.accentComponents
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    static let background = Color(red: 0.06, green: 0.06, blue: 0.08)
}

/// Artwork from the App Group cache, or a quiet placeholder until the app has
/// stored it.
struct WidgetArtwork: View {
    let source: String?
    var fallback: String? = nil

    /// Fills whatever space it is given and crops to it. A bare
    /// `scaledToFill` image sizes itself to the picture instead, which pushed
    /// the text around it out of the widget.
    var body: some View {
        Color.clear
            .overlay { content }
            .clipped()
    }

    @ViewBuilder
    private var content: some View {
        if let image = Self.image(for: source) ?? Self.image(for: fallback) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [OmniWidgetStyle.accent.opacity(0.35), OmniWidgetStyle.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.35))
            )
        }
    }

    static func image(for source: String?) -> UIImage? {
        guard let file = WidgetArtworkCache.cachedFile(for: source) else { return nil }
        return UIImage(contentsOfFile: file.path)
    }
}

/// Thin progress bar for a resume point.
struct WidgetProgressBar: View {
    let value: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
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
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(OmniWidgetStyle.accent)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

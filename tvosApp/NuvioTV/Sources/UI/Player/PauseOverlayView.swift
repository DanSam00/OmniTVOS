import SwiftUI
import Combine

/// Metadata sheet shown while paused — logo/title, episode line, synopsis,
/// cast chips, and a wall-clock in the corner. Video stays visible underneath.
struct PauseOverlayView: View {
    /// Sizes for the screen: the TV's 1080p canvas (Apple TV, Mac), or a
    /// phone held sideways.
    private enum M {
        #if os(iOS)
        static let labelSize: CGFloat = 12, logoWidth: CGFloat = 220, logoHeight: CGFloat = 56
        static let titleSize: CGFloat = 28, episodeSize: CGFloat = 16, bodySize: CGFloat = 14
        static let bodyWidth: CGFloat = 460, castLabelSize: CGFloat = 11, castSize: CGFloat = 12
        static let castCount = 4, spacing: CGFloat = 8, sidePadding: CGFloat = 28, bottomPadding: CGFloat = 28
        static let clockSize: CGFloat = 20, clockTop: CGFloat = 20, metaSize: CGFloat = 14
        #else
        static let labelSize: CGFloat = 22, logoWidth: CGFloat = 440, logoHeight: CGFloat = 120
        static let titleSize: CGFloat = 52, episodeSize: CGFloat = 28, bodySize: CGFloat = 24
        static let bodyWidth: CGFloat = 950, castLabelSize: CGFloat = 18, castSize: CGFloat = 20
        static let castCount = 6, spacing: CGFloat = 14, sidePadding: CGFloat = 60, bottomPadding: CGFloat = 100
        static let clockSize: CGFloat = 40, clockTop: CGFloat = 50, metaSize: CGFloat = 24
        #endif
    }

    let title: String
    let episodeLine: String?
    let year: Int?
    let description: String?
    let cast: [String]
    let logoURL: URL?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            gradients

            PauseClock(size: M.clockSize)
                .padding(.top, M.clockTop)
                .padding(.trailing, M.sidePadding)

            VStack(alignment: .leading, spacing: M.spacing) {
                Spacer()

                Text(L10n.string("player_pause_youre_watching", fallback: "YOU'RE WATCHING"))
                    .font(.system(size: M.labelSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .kerning(2)

                if let logoURL {
                    AsyncImage(url: FixtureArtwork.displayURL(logoURL)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: M.logoWidth, maxHeight: M.logoHeight, alignment: .bottomLeading)
                        default:
                            titleText
                        }
                    }
                } else {
                    titleText
                }

                metaLine

                if let episodeLine, !episodeLine.isEmpty {
                    Text(episodeLine)
                        .font(.system(size: M.episodeSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: M.bodySize))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                        .frame(maxWidth: M.bodyWidth, alignment: .leading)
                        .padding(.top, 4)
                }

                if !cast.isEmpty {
                    Text(L10n.string("details_cast", fallback: "Cast").uppercased())
                        .font(.system(size: M.castLabelSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .kerning(2)
                        .padding(.top, M.spacing)

                    HStack(spacing: M.spacing) {
                        ForEach(cast.prefix(M.castCount), id: \.self) { member in
                            Text(member)
                                .font(.system(size: M.castSize, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, M.castSize * 0.9)
                                .padding(.vertical, M.castSize * 0.5)
                                .background(
                                    Color.white.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                    }
                }
            }
            .padding(.horizontal, M.sidePadding)
            .padding(.bottom, M.bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: M.titleSize, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(2)
    }

    @ViewBuilder
    private var metaLine: some View {
        let parts = [year.map(String.init), episodeCode].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(parts.joined(separator: "  •  "))
                .font(.system(size: M.metaSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// "S1 · E3 · Title" → "S1E3" for the year line when possible.
    private var episodeCode: String? {
        guard let episodeLine, !episodeLine.isEmpty else { return nil }
        // Prefer S/E from a "S1 · E2 · Name" subtitle; otherwise omit here
        // (full episode line is shown below).
        if let numbers = EpisodeTagResolver.episodeNumbers(in: episodeLine) {
            return "S\(numbers.season)E\(numbers.episode)"
        }
        return nil
    }

    private var gradients: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.88), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            Color.black.opacity(0.32)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.35), location: 0.35),
                    .init(color: .black.opacity(0.15), location: 0.65),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct PauseClock: View {
    var size: CGFloat = 40
    @State private var now = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(now, style: .time)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(.white.opacity(0.95))
            .onReceive(timer) { now = $0 }
    }
}

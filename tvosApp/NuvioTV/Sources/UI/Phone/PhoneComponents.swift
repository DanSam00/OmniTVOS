// Building blocks shared by the iPhone screens.
//
// The tvOS views are laid out in fixed 1080p points around the focus engine;
// none of that carries to a touch screen that is 400pt wide. The phone UI is a
// separate, adaptive view layer over the same models, stores and view models.
#if os(iOS)
import SwiftUI

enum PhoneLayout {
    static let gutter: CGFloat = 16
    static let posterWidth: CGFloat = 112
    static let posterAspect: CGFloat = 1.5
    static let landscapeWidth: CGFloat = 240
}

/// Remote artwork with a quiet placeholder. `AsyncImage` goes through
/// `URLCache.shared`, which the app sizes at launch.
struct PhoneArtwork: View {
    let url: String?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:)), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            default:
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
    }
}

struct PhonePosterCard: View {
    let meta: NuvioMeta
    var width: CGFloat = PhoneLayout.posterWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PhoneArtwork(url: meta.posterUrl ?? meta.backgroundUrl)
                .frame(width: width, height: width * PhoneLayout.posterAspect)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if meta.posterUrl == nil {
                        Text(meta.name)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(8)
                    }
                }
            Text(meta.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// Continue Watching card: the landscape still with a progress bar.
struct PhoneContinueCard: View {
    let item: ContinueWatchingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                PhoneArtwork(url: item.episodeThumbnailOverride ?? item.meta.backgroundUrl ?? item.meta.posterUrl)
                    .frame(width: PhoneLayout.landscapeWidth, height: PhoneLayout.landscapeWidth * 9 / 16)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                if item.progress > 0 {
                    GeometryReader { proxy in
                        Capsule().fill(Color.white.opacity(0.25))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.white)
                                    .frame(width: proxy.size.width * min(max(item.progress, 0), 1))
                            }
                    }
                    .frame(height: 3)
                    .padding(8)
                }
            }
            .frame(width: PhoneLayout.landscapeWidth, height: PhoneLayout.landscapeWidth * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(item.meta.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(item.episodeDisplayLine ?? item.remainingText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: PhoneLayout.landscapeWidth, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct PhoneSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .padding(.horizontal, PhoneLayout.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A two-to-four column poster grid for search and library results.
struct PhonePosterGrid: View {
    let items: [NuvioMeta]
    let onSelect: (NuvioMeta) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items, id: \.id) { meta in
                Button { onSelect(meta) } label: {
                    GeometryReader { proxy in
                        PhonePosterCard(meta: meta, width: proxy.size.width)
                    }
                    .aspectRatio(1 / (PhoneLayout.posterAspect + 0.18), contentMode: .fit)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PhoneLayout.gutter)
    }
}
#endif

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

/// Which shared decoded-image cache a picture goes through. Both downsample
/// once and keep the result in memory, so a card scrolled back into view or
/// a carousel page swiped back to draws at once instead of fetching and
/// decoding the full-size original again, as `AsyncImage` did.
enum PhoneArtKind {
    /// Posters, logos and stills, decoded at card size.
    case poster
    /// Hero and page backdrops, decoded at screen size.
    case backdrop
}

enum PhoneImageLoader {
    static func image(for urlString: String?, kind: PhoneArtKind) async -> UIImage? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        switch kind {
        case .poster:
            return await PosterArtworkCache.shared.image(for: url, maxPixelSize: 600)
        case .backdrop:
            return await BackdropImageCache.shared.image(for: url)
        }
    }

    /// Warms the caches, so the next carousel page is ready before it slides in.
    static func prefetch(_ urls: [String?], kind: PhoneArtKind) {
        for url in urls.compactMap({ $0 }) {
            Task.detached(priority: .utility) { _ = await image(for: url, kind: kind) }
        }
    }
}

/// Remote artwork with a quiet placeholder.
struct PhoneArtwork: View {
    let url: String?
    var contentMode: ContentMode = .fill
    var kind: PhoneArtKind = .poster

    @State private var image: UIImage?
    @State private var loadedURL: String?

    var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .task(id: url) {
            let loaded = await PhoneImageLoader.image(for: url, kind: kind)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                loadedURL = url
            }
        }
    }
}

/// A title's logo art, or its name in type when there is no logo or the image
/// fails — never an empty grey box where the title should be.
struct PhoneTitleLogo: View {
    let meta: NuvioMeta
    var maxWidth: CGFloat = 240
    var maxHeight: CGFloat = 90

    private enum State { case loading, loaded(UIImage), failed }
    @SwiftUI.State private var state: State = .loading

    var body: some View {
        Group {
            switch state {
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
            case .failed:
                name
            case .loading:
                Color.clear.frame(width: maxWidth, height: maxHeight * 0.6)
            }
        }
        .task(id: meta.logoUrl) {
            guard meta.logoUrl != nil else { state = .failed; return }
            let image = await PhoneImageLoader.image(for: meta.logoUrl, kind: .poster)
            guard !Task.isCancelled else { return }
            state = image.map(State.loaded) ?? .failed
        }
    }

    private var name: some View {
        Text(meta.name)
            .font(.largeTitle.weight(.bold))
            .lineLimit(2)
            .minimumScaleFactor(0.7)
    }
}

struct PhonePosterCard: View {
    let meta: NuvioMeta
    var width: CGFloat = PhoneLayout.posterWidth
    /// Titles under posters: Settings → Layout → Poster Labels, off by default
    /// as on the TV. Search and Library pass true, where the name is the point.
    var showsLabel: Bool = true

    @AppStorage(SettingsKey.cardCornerRadius) private var cornerRadiusRaw = CardCornerRadiusOption.subtle.rawValue

    /// The TV radii are for a 210pt card; scaled to this one's width.
    private var cornerRadius: CGFloat {
        CardCornerRadiusOption.from(rawValue: cornerRadiusRaw).radius * width / 210
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PhoneArtwork(url: meta.posterUrl ?? meta.backgroundUrl)
                .frame(width: width, height: width * PhoneLayout.posterAspect)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    if meta.posterUrl == nil {
                        Text(meta.name)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(8)
                    }
                }
            if showsLabel {
                Text(meta.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
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

extension Array where Element == NuvioMeta {
    /// First occurrence of each id. Search merges several add-ons' answers and
    /// a catalog page can repeat a title; a repeated id inside one `ForEach`
    /// breaks SwiftUI's diffing and can stall the grid.
    func uniquedByID() -> [NuvioMeta] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

/// A two-to-four column poster grid for search and library results.
struct PhonePosterGrid: View {
    let items: [NuvioMeta]
    let onSelect: (NuvioMeta) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items.uniquedByID(), id: \.id) { meta in
                Button { onSelect(meta) } label: {
                    PhoneFlexiblePoster(meta: meta)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PhoneLayout.gutter)
    }
}

/// A poster that takes its grid column's width. Sized by aspect ratio alone:
/// measuring each cell with a GeometryReader inside a lazy grid re-runs layout
/// whenever the container resizes — the keyboard appearing over Search did
/// exactly that and froze the page.
struct PhoneFlexiblePoster: View {
    let meta: NuvioMeta
    var showsLabel = true

    @AppStorage(SettingsKey.cardCornerRadius) private var cornerRadiusRaw = CardCornerRadiusOption.subtle.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1 / PhoneLayout.posterAspect, contentMode: .fit)
                .overlay { PhoneArtwork(url: meta.posterUrl ?? meta.backgroundUrl) }
                .clipShape(RoundedRectangle(
                    cornerRadius: CardCornerRadiusOption.from(rawValue: cornerRadiusRaw).radius / 2,
                    style: .continuous
                ))
            if showsLabel {
                Text(meta.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif

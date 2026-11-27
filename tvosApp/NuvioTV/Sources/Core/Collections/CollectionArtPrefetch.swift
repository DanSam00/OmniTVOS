import Foundation

/// Fetches the covers of Home's collection rows (Directors, Franchises,
/// Streaming Services…) ahead of the rows being drawn.
///
/// Each folder's cover is a separate download that can take seconds, and
/// they were only started when a tile came on screen, then decoded at screen
/// size into a memory-only cache. Now they start as soon as the profile is
/// in, a few at a time, into `PosterArtworkCache` (on disk across launches),
/// and again whenever the collections change.
enum CollectionArtPrefetch {
    /// Pixels a folder cover is decoded at: enough for a tile on a 4K TV.
    static let coverPixels = 900

    @MainActor private static var observer: NSObjectProtocol?
    @MainActor private static var pending: Task<Void, Never>?

    @MainActor
    static func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: CollectionsStore.changedNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in schedule(after: 1) }
            }
        }
        schedule(after: 0)
    }

    @MainActor
    private static func schedule(after seconds: Double) {
        pending?.cancel()
        pending = Task(priority: .utility) {
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            let urls = await MainActor.run { coverURLs() }
            await PosterArtworkCache.shared.prefetch(urls, maxPixelSize: coverPixels)
        }
    }

    /// Covers and wordmarks in Home's order, so the first rows come first.
    @MainActor
    private static func coverURLs() -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for section in TVHomeSection.collectionRows() {
            for folder in section.collectionFolders {
                for raw in [folder.coverImageUrl, folder.titleLogoUrl] {
                    guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                          text.hasPrefix("http"), let url = URL(string: text),
                          seen.insert(text).inserted else { continue }
                    urls.append(url)
                }
            }
        }
        return urls
    }
}

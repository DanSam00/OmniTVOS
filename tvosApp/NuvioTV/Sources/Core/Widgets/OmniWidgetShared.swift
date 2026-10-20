#if os(iOS) || os(macOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - Widgets: what the app and the widget extension share
//
// Compiled into the Omni iOS and Mac apps and their widget extensions, so it
// uses no app model types. The app writes small feeds and pre-sized artwork into the
// App Group; the widgets only read them, and never touch the network.
//
// Continue Watching reuses the Top Shelf feed (`TopShelfFeedStore`), which the
// iPhone app writes from exactly the row Home shows.

enum OmniWidgetKind {
    static let continueWatching = "OmniContinueWatching"
    static let upcoming = "OmniUpcoming"
}

// MARK: Theme

/// The profile's accent colour (Settings → Appearance → Theme), copied here by
/// the app so the widgets and the Live Activity match it. White until the app
/// has written one, which is also the app's own default.
enum WidgetTheme {
    private static let accentKey = "omni.widgets.accent"

    static var accentComponents: (red: Double, green: Double, blue: Double) {
        guard let values = UserDefaults(suiteName: topShelfAppGroupID)?.array(forKey: accentKey) as? [Double],
              values.count == 3 else { return (1, 1, 1) }
        return (values[0], values[1], values[2])
    }

    /// True when the colour changed, so the widgets need redrawing.
    @discardableResult
    static func store(red: Double, green: Double, blue: Double) -> Bool {
        guard let defaults = UserDefaults(suiteName: topShelfAppGroupID) else { return false }
        let values = [red, green, blue].map { ($0 * 1000).rounded() / 1000 }
        guard defaults.array(forKey: accentKey) as? [Double] != values else { return false }
        defaults.set(values, forKey: accentKey)
        return true
    }
}

// MARK: Upcoming episodes

/// One upcoming episode of a show the user follows, from the Calendar's data.
struct UpcomingEpisodeEntry: Codable, Equatable, Identifiable {
    let id: String
    let metaId: String
    let type: String
    let title: String
    /// `S01E05`, when numbered.
    let episodeCode: String?
    let episodeTitle: String?
    /// Midnight of the release day, local time.
    let airDate: Date
    let posterURL: String?
    /// Episode still, else the show's backdrop.
    let imageURL: String?

    var deepLinkURL: URL? {
        var components = URLComponents()
        components.scheme = "nuvio-tv"
        components.host = "details"
        components.queryItems = [
            URLQueryItem(name: "id", value: metaId),
            URLQueryItem(name: "type", value: type),
        ]
        return components.url
    }
}

struct UpcomingEpisodeFeed: Codable, Equatable {
    let entries: [UpcomingEpisodeEntry]
    let updatedAt: Date
}

enum UpcomingEpisodeFeedStore {
    private static let feedKey = "omni.widgets.upcoming"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: topShelfAppGroupID)
    }

    static func write(_ entries: [UpcomingEpisodeEntry]) {
        guard let defaults = sharedDefaults,
              let data = try? JSONEncoder().encode(UpcomingEpisodeFeed(entries: entries, updatedAt: Date()))
        else { return }
        defaults.set(data, forKey: feedKey)
    }

    static func read() -> UpcomingEpisodeFeed? {
        guard let data = sharedDefaults?.data(forKey: feedKey) else { return nil }
        return try? JSONDecoder().decode(UpcomingEpisodeFeed.self, from: data)
    }
}

// MARK: Artwork

/// Pre-sized artwork in the App Group, keyed by its source URL. The app fills
/// it; widgets read it. Widget extensions have a small memory budget, so images
/// are stored already scaled down.
enum WidgetArtworkCache {
    private static let folderName = "WidgetArtwork"

    static var directory: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: topShelfAppGroupID
        ) else { return nil }
        let folder = container.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func fileURL(for source: String) -> URL? {
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return directory?.appendingPathComponent("\(String(hash, radix: 16)).jpg")
    }

    /// The cached file for this source, when the app has stored one.
    static func cachedFile(for source: String?) -> URL? {
        guard let source, !source.isEmpty, let url = fileURL(for: source),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Downloads and stores each missing source, scaled to fit `maxPixel`.
    /// Returns true when anything new was stored.
    @discardableResult
    static func fill(_ sources: [String], maxPixel: Int = 640) async -> Bool {
        var storedAny = false
        for source in Set(sources) where !source.isEmpty {
            guard let destination = fileURL(for: source),
                  !FileManager.default.fileExists(atPath: destination.path),
                  let url = URL(string: source),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let scaled = downsampled(data, maxPixel: maxPixel) else { continue }
            if (try? scaled.write(to: destination, options: .atomic)) != nil { storedAny = true }
        }
        return storedAny
    }

    /// Removes artwork neither widget feed refers to any more.
    static func pruneToFeeds() {
        let watching = TopShelfFeedStore.read()?.entries
            .flatMap { [$0.imageURL, $0.backdropURL].compactMap { $0 } } ?? []
        let upcoming = UpcomingEpisodeFeedStore.read()?.entries
            .flatMap { [$0.posterURL, $0.imageURL].compactMap { $0 } } ?? []
        prune(keeping: watching + upcoming)
    }

    /// Removes files no longer referenced by any feed.
    static func prune(keeping sources: [String]) {
        guard let directory else { return }
        let keep = Set(sources.compactMap { fileURL(for: $0)?.lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !keep.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private static func downsampled(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: Downloads Live Activity

#if os(iOS) && canImport(ActivityKit)
/// The Lock Screen and Dynamic Island card while downloads run.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The download in front: "Severance" / "S2 · E3 · Hello, Ms. Cobel".
        var title: String
        var subtitle: String?
        /// 0...1 for the download in front.
        var progress: Double
        /// Downloads finished since this card appeared, and the total.
        var completed: Int
        var total: Int
        var isWaitingForWiFi: Bool
        var isFinished: Bool
    }
}
#endif
#endif

import Foundation
import CryptoKit

// MARK: - Sources

/// An IPTV provider the viewer added in Settings ▸ Integrations: an M3U
/// playlist URL, or an Xtream Codes server with its login.
struct IPTVSource: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable {
        case m3u
        case xtream
    }

    var id: String = UUID().uuidString
    var name: String
    var kind: Kind
    /// The playlist URL (M3U) or the server address (Xtream).
    var url: String
    var username: String?
    var password: String?
    var enabled: Bool = true

    /// What Settings shows under the name, without the password.
    var summary: String {
        switch kind {
        case .m3u:
            return URL(string: url)?.host ?? url
        case .xtream:
            let host = URL(string: IPTVSource.normalizedServer(url))?.host ?? url
            return "\(username ?? "") @ \(host)"
        }
    }

    /// `http(s)://host[:port]` with no trailing slash, adding `http://` when
    /// the viewer typed a bare host, which Xtream panels usually hand out.
    static func normalizedServer(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        // A pasted player_api.php or get.php link: keep only the server.
        if let range = value.range(of: "/player_api.php") ?? value.range(of: "/get.php") {
            value = String(value[..<range.lowerBound])
        }
        return value
    }
}

/// Whether the active profile has any IPTV source, so the Live TV tab can
/// stay out of the menus until there is something to show in it.
@MainActor
final class IPTVAvailability: ObservableObject {
    static let shared = IPTVAvailability()

    @Published private(set) var hasSources = !IPTVSourceStore.sources().isEmpty

    private var observers: [NSObjectProtocol] = []

    private init() {
        // A profile switch moves `ProfileSettings.current` to another suite,
        // which arrives as a defaults change rather than a sources change.
        let names = [
            IPTVSourceStore.changedNotification,
            ProfileSettings.settingsChangedNotification,
            UserDefaults.didChangeNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh() {
        let has = !IPTVSourceStore.sources().isEmpty
        if has != hasSources { hasSources = has }
    }
}

/// The profile's IPTV sources. Kept on this device in the profile's settings
/// and left out of account sync: an Xtream login is a password.
enum IPTVSourceStore {
    static let changedNotification = Notification.Name("omni.iptv.sources.changed")

    static func sources(in defaults: UserDefaults = ProfileSettings.current) -> [IPTVSource] {
        guard let json = defaults.string(forKey: SettingsKey.iptvSources),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([IPTVSource].self, from: data) else { return [] }
        return decoded
    }

    static func save(_ sources: [IPTVSource], in defaults: UserDefaults = ProfileSettings.current) {
        guard let data = try? JSONEncoder().encode(sources),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: SettingsKey.iptvSources)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func add(_ source: IPTVSource) {
        save(sources() + [source])
    }

    static func remove(id: String) {
        save(sources().filter { $0.id != id })
        IPTVLibrary.shared.forget(sourceID: id)
    }
}

// MARK: - Channels

struct IPTVChannel: Codable, Equatable, Hashable {
    /// Stable within its source: the Xtream stream id, or a hash of the M3U
    /// stream URL, so a reordered playlist keeps the same ids.
    let key: String
    let sourceID: String
    let name: String
    let logo: String?
    let group: String
    /// XMLTV channel id, for the guide later.
    let tvgID: String?
    let streamURL: String

    var contentID: String { "iptv:\(sourceID):\(key)" }

    func meta(sourceName: String) -> NuvioMeta {
        NuvioMeta(
            id: contentID,
            name: name,
            description: "Live · \(group) · \(sourceName)",
            posterUrl: logo,
            backgroundUrl: nil,
            logoUrl: logo,
            imdbId: nil,
            tmdbId: nil,
            type: "tv",
            year: nil,
            genres: [group],
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }
}

/// One channel as the viewer sees it: every variant of it the sources list
/// (HD, FHD, 4K, backup, another group) merged under one page, each variant a
/// source on that page.
struct IPTVChannelGroup: Equatable {
    let id: String
    let name: String
    let logo: String?
    let category: String
    /// Languages the channel's tags point to; empty when it has none.
    let languages: Set<String>
    let variants: [IPTVChannel]

    func meta(description: String? = nil) -> NuvioMeta {
        let sources = variants.count == 1 ? "1 source" : "\(variants.count) sources"
        return NuvioMeta(
            id: id,
            name: name,
            description: description ?? "Live · \(category) · \(sources)",
            posterUrl: logo,
            backgroundUrl: nil,
            logoUrl: logo,
            imdbId: nil,
            tmdbId: nil,
            type: "tv",
            year: nil,
            genres: [category],
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }
}

/// A source's channels, as fetched, with the guide address the playlist
/// declared (`url-tvg` / Xtream's `xmltv.php`), kept for the EPG step.
struct IPTVPlaylist: Codable {
    var channels: [IPTVChannel]
    var guideURL: String?
    var fetchedAt: Date
}

/// What a playlist load is doing, for the bar under Save.
struct IPTVLoadProgress: Equatable {
    var stage: String
    /// 0...1 when the size is known; nil shows an indeterminate bar.
    var fraction: Double?
}

typealias IPTVProgressHandler = @Sendable (IPTVLoadProgress) -> Void

enum IPTVError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - Library

/// Every enabled source's channels, fetched and parsed, held in memory for
/// the synchronous lookups the stream picker makes, and on disk so Home has
/// them at launch without refetching a playlist that can run to megabytes.
final class IPTVLibrary: @unchecked Sendable {
    static let shared = IPTVLibrary()

    /// Refetch a playlist after this long.
    private static let maxAge: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private var playlists: [String: IPTVPlaylist] = [:]
    private var channelsByContentID: [String: IPTVChannel] = [:]
    /// Channels merged by name across variants and sources (`iptvch:` ids).
    private var groupsByID: [String: IPTVChannelGroup] = [:]
    private var groupOrder: [String] = []

    // MARK: Lookups (synchronous)

    func channel(forContentID id: String) -> IPTVChannel? {
        lock.lock(); defer { lock.unlock() }
        return channelsByContentID[id]
    }

    func group(forContentID id: String) -> IPTVChannelGroup? {
        lock.lock(); defer { lock.unlock() }
        return groupsByID[id]
    }

    func meta(forContentID id: String) -> NuvioMeta? {
        if let group = group(forContentID: id) { return group.meta() }
        // A single variant's id, as an older build saved it.
        guard let channel = channel(forContentID: id) else { return nil }
        let name = IPTVSourceStore.sources().first { $0.id == channel.sourceID }?.name ?? "IPTV"
        return channel.meta(sourceName: name)
    }

    /// The streams to offer for a channel: one per variant, best first.
    func streams(forContentID id: String) -> [NuvioStream] {
        let names = Dictionary(IPTVSourceStore.sources().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let variants = group(forContentID: id)?.variants ?? channel(forContentID: id).map { [$0] } ?? []
        return variants
            .sorted { IPTVNaming.qualityRank($0.name) > IPTVNaming.qualityRank($1.name) }
            .map { channel in
                NuvioStream(
                    url: channel.streamURL,
                    name: names[channel.sourceID] ?? "IPTV",
                    description: "\(channel.name) · \(channel.group)",
                    addonName: "IPTV"
                )
            }
    }

    /// Channels in the viewer's languages, merged, in playlist order.
    func visibleGroups() -> [IPTVChannelGroup] {
        let preferred = IPTVNaming.preferredLanguages()
        lock.lock(); defer { lock.unlock() }
        return groupOrder.compactMap { groupsByID[$0] }.filter { IPTVNaming.matches($0.languages, preferred: preferred) }
    }

    func cachedChannels(sourceID: String) -> [IPTVChannel] {
        lock.lock(); defer { lock.unlock() }
        return playlists[sourceID]?.channels ?? []
    }

    func forget(sourceID: String) {
        lock.lock()
        playlists[sourceID] = nil
        channelsByContentID = channelsByContentID.filter { !$0.key.hasPrefix("iptv:\(sourceID):") }
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.cacheURL(sourceID: sourceID))
    }

    // MARK: Loading

    /// The source's playlist: from memory, else disk, else the network, and
    /// refetched once it is older than `maxAge` or when `force` is set.
    @discardableResult
    func playlist(
        for source: IPTVSource,
        force: Bool = false,
        progress: IPTVProgressHandler? = nil
    ) async throws -> IPTVPlaylist {
        if !force {
            lock.lock()
            let held = playlists[source.id]
            lock.unlock()
            if let held, Date().timeIntervalSince(held.fetchedAt) < Self.maxAge { return held }
            if let stored = Self.readCache(sourceID: source.id),
               Date().timeIntervalSince(stored.fetchedAt) < Self.maxAge {
                install(stored, sourceID: source.id)
                return stored
            }
        }
        do {
            let fetched = try await Self.fetch(source, progress: progress ?? { _ in })
            install(fetched, sourceID: source.id)
            Self.writeCache(fetched, sourceID: source.id)
            return fetched
        } catch {
            // Offline or the provider is down: an old list still plays.
            if let stored = Self.readCache(sourceID: source.id) {
                install(stored, sourceID: source.id)
                return stored
            }
            throw error
        }
    }

    /// Channels of every enabled source, loading what is not held yet.
    func allChannels() async -> [IPTVChannel] {
        var all: [IPTVChannel] = []
        for source in IPTVSourceStore.sources() where source.enabled {
            if let playlist = try? await playlist(for: source) {
                all += playlist.channels
            }
        }
        return all
    }

    private func install(_ playlist: IPTVPlaylist, sourceID: String) {
        lock.lock(); defer { lock.unlock() }
        playlists[sourceID] = playlist
        channelsByContentID = channelsByContentID.filter { !$0.key.hasPrefix("iptv:\(sourceID):") }
        for channel in playlist.channels { channelsByContentID[channel.contentID] = channel }
        rebuildGroups()
    }

    /// Merges every held playlist's channels by cleaned name and language.
    /// Runs under `lock`.
    private func rebuildGroups() {
        var variants: [String: [IPTVChannel]] = [:]
        var languages: [String: Set<String>] = [:]
        var order: [String] = []
        for sourceID in playlists.keys.sorted() {
            for channel in playlists[sourceID]?.channels ?? [] where !IPTVNaming.isPlaceholder(channel.name) {
                let cleaned = IPTVNaming.clean(channel.name)
                guard !cleaned.key.isEmpty else { continue }
                let langs = IPTVNaming.languages(group: channel.group, nameTags: cleaned.tags)
                let id = "iptvch:" + (langs.isEmpty ? "any" : langs.sorted().joined(separator: "+").lowercased())
                    + ":" + cleaned.key.replacingOccurrences(of: " ", with: "-")
                if variants[id] == nil { order.append(id) }
                variants[id, default: []].append(channel)
                languages[id] = langs
            }
        }
        // An untagged copy ("CNN") joins the one tagged channel of the same
        // name ("US: CNN") instead of standing apart as a second page.
        let anyPrefix = "iptvch:any:"
        var byName: [String: [String]] = [:]
        for id in order where !id.hasPrefix(anyPrefix) {
            byName[String(id.split(separator: ":", maxSplits: 2).last ?? ""), default: []].append(id)
        }
        for id in order where id.hasPrefix(anyPrefix) {
            let name = String(id.dropFirst(anyPrefix.count))
            guard let tagged = byName[name], tagged.count == 1, let target = tagged.first else { continue }
            variants[target, default: []].append(contentsOf: variants[id] ?? [])
            variants[id] = nil
        }
        order.removeAll { variants[$0] == nil }

        var groups: [String: IPTVChannelGroup] = [:]
        for id in order {
            let list = variants[id] ?? []
            guard let first = list.first else { continue }
            groups[id] = IPTVChannelGroup(
                id: id,
                name: IPTVNaming.clean(first.name).display,
                logo: list.lazy.compactMap(\.logo).first,
                category: first.group,
                languages: languages[id] ?? [],
                variants: list
            )
        }
        groupsByID = groups
        groupOrder = order
    }

    /// Channels whose name holds `needle` (already folded), for Search: one
    /// result per channel, in the viewer's languages.
    func search(_ needle: String) async -> [NuvioMeta] {
        guard !needle.isEmpty else { return [] }
        _ = await allChannels()
        return visibleGroups()
            .filter {
                $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(needle)
            }
            .prefix(60)
            .map { $0.meta() }
    }

    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let slug = String(kept).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "channels" : slug
    }

    // MARK: Fetching

    static func fetch(_ source: IPTVSource, progress: @escaping IPTVProgressHandler) async throws -> IPTVPlaylist {
        switch source.kind {
        case .xtream:
            return try await fetchXtream(source, progress: progress)
        case .m3u:
            // A panel's `get.php?username=…&password=…` playlist lists every
            // film and episode too, tens of megabytes. The same panel's API
            // returns just the live channels, so try that first.
            if let login = xtreamLogin(fromPlaylistURL: source.url) {
                var asXtream = source
                asXtream.kind = .xtream
                asXtream.url = login.server
                asXtream.username = login.username
                asXtream.password = login.password
                if let playlist = try? await fetchXtream(asXtream, progress: progress) {
                    return playlist
                }
            }
            return try await fetchM3U(source, progress: progress)
        }
    }

    /// The server and login inside an Xtream panel's playlist link.
    static func xtreamLogin(fromPlaylistURL raw: String) -> (server: String, username: String, password: String)? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.path.lowercased().hasSuffix("/get.php"),
              let user = components.queryItems?.first(where: { $0.name == "username" })?.value, !user.isEmpty,
              let pass = components.queryItems?.first(where: { $0.name == "password" })?.value, !pass.isEmpty,
              let scheme = components.scheme, let host = components.host else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return ("\(scheme)://\(host)\(port)", user, pass)
    }

    /// A session that only gives up when the server goes quiet for a minute,
    /// and allows a quarter of an hour in all: a provider's full playlist can
    /// take minutes on a slow panel, and the default single deadline cut it off.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Omni/\(SimklConfig.appVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw IPTVError.message("No response from the provider.") }
        guard (200..<300).contains(http.statusCode) else {
            throw IPTVError.message(http.statusCode == 401 || http.statusCode == 403
                ? "The provider refused the login (\(http.statusCode))."
                : "The provider answered \(http.statusCode).")
        }
    }

    private static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(url))
        try check(response)
        return data
    }

    /// A download that reports how far it has got, receiving the data in
    /// the network's own chunks: reading a 50 MB playlist byte by byte took
    /// longer than downloading it.
    private static func download(
        _ url: URL,
        stage: String,
        progress: @escaping IPTVProgressHandler
    ) async throws -> Data {
        let loader = IPTVChunkedDownload(stage: stage, progress: progress)
        return try await loader.run(request(url))
    }

    private static func fetchM3U(_ source: IPTVSource, progress: @escaping IPTVProgressHandler) async throws -> IPTVPlaylist {
        guard let url = URL(string: source.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw IPTVError.message("That playlist address is not a valid URL.")
        }
        progress(IPTVLoadProgress(stage: "Connecting to the provider…", fraction: nil))
        let data = try await download(url, stage: "Downloading playlist", progress: progress)
        progress(IPTVLoadProgress(stage: "Reading channels, films and shows…", fraction: nil))
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw IPTVError.message("The playlist could not be read.")
        }
        let parsed = M3UParser.parse(text, sourceID: source.id)
        progress(IPTVLoadProgress(
            stage: "Found \(parsed.channels.count) channels, \(parsed.movieCount) films and \(parsed.seriesCount) shows",
            fraction: 1
        ))
        guard !parsed.channels.isEmpty else {
            throw IPTVError.message(parsed.movieCount + parsed.seriesCount > 0
                ? "The playlist has films and shows but no live channels."
                : "The playlist has no channels in it.")
        }
        return IPTVPlaylist(channels: parsed.channels, guideURL: parsed.guideURL, fetchedAt: Date())
    }

    private struct XtreamCategory: Decodable {
        let categoryID: String
        let categoryName: String?
        enum CodingKeys: String, CodingKey {
            case categoryID = "category_id"
            case categoryName = "category_name"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            categoryID = (try? c.decode(String.self, forKey: .categoryID))
                ?? (try? c.decode(Int.self, forKey: .categoryID)).map(String.init) ?? ""
            categoryName = try? c.decode(String.self, forKey: .categoryName)
        }
    }

    private struct XtreamStream: Decodable {
        let streamID: String
        let name: String?
        let icon: String?
        let epgChannelID: String?
        let categoryID: String?
        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id"
            case name
            case icon = "stream_icon"
            case epgChannelID = "epg_channel_id"
            case categoryID = "category_id"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Panels disagree on whether ids are numbers or strings.
            streamID = (try? c.decode(String.self, forKey: .streamID))
                ?? (try? c.decode(Int.self, forKey: .streamID)).map(String.init) ?? ""
            name = try? c.decode(String.self, forKey: .name)
            icon = try? c.decode(String.self, forKey: .icon)
            epgChannelID = try? c.decode(String.self, forKey: .epgChannelID)
            categoryID = (try? c.decode(String.self, forKey: .categoryID))
                ?? (try? c.decode(Int.self, forKey: .categoryID)).map(String.init)
        }
    }

    private static func xtreamURL(_ server: String, _ user: String, _ pass: String, action: String) -> URL? {
        var components = URLComponents(string: "\(server)/player_api.php")
        components?.queryItems = [
            URLQueryItem(name: "username", value: user),
            URLQueryItem(name: "password", value: pass),
            URLQueryItem(name: "action", value: action),
        ]
        return components?.url
    }

    private static func fetchXtream(_ source: IPTVSource, progress: @escaping IPTVProgressHandler) async throws -> IPTVPlaylist {
        let server = IPTVSource.normalizedServer(source.url)
        let user = source.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pass = source.password ?? ""
        guard !user.isEmpty, !pass.isEmpty,
              let categoriesURL = xtreamURL(server, user, pass, action: "get_live_categories"),
              let streamsURL = xtreamURL(server, user, pass, action: "get_live_streams") else {
            throw IPTVError.message("Enter the server, username and password.")
        }
        // A wrong login answers 200 with `{"user_info":{"auth":0}}` instead of
        // a list, so a decode failure is reported as the login.
        progress(IPTVLoadProgress(stage: "Signing in and loading channel groups…", fraction: 0.05))
        let categories = (try? JSONDecoder().decode([XtreamCategory].self, from: try await get(categoriesURL))) ?? []
        progress(IPTVLoadProgress(stage: "Loading live channels…", fraction: 0.15))
        let streamsData = try await download(streamsURL, stage: "Loading live channels", progress: { update in
            // The API's own download fills the bar's remaining 15–90%.
            progress(IPTVLoadProgress(stage: update.stage, fraction: update.fraction.map { 0.15 + $0 * 0.75 }))
        })
        progress(IPTVLoadProgress(stage: "Sorting channels into groups…", fraction: 0.95))
        guard let streams = try? JSONDecoder().decode([XtreamStream].self, from: streamsData) else {
            throw IPTVError.message("The server did not accept that username and password.")
        }
        let groupNames = Dictionary(categories.map { ($0.categoryID, $0.categoryName ?? "") }, uniquingKeysWith: { a, _ in a })
        let order = categories.map(\.categoryID)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let channels: [IPTVChannel] = streams
            .filter { !$0.streamID.isEmpty }
            .sorted { (rank[$0.categoryID ?? ""] ?? Int.max) < (rank[$1.categoryID ?? ""] ?? Int.max) }
            .map { stream in
                let group = groupNames[stream.categoryID ?? ""].flatMap { $0.isEmpty ? nil : $0 } ?? "Live TV"
                let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
                let encodedPass = pass.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pass
                return IPTVChannel(
                    key: stream.streamID,
                    sourceID: source.id,
                    name: stream.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Channel \(stream.streamID)",
                    logo: stream.icon?.nilIfBlank,
                    group: group,
                    tvgID: stream.epgChannelID?.nilIfBlank,
                    // HLS output, which both Apple's player and mpv play.
                    streamURL: "\(server)/live/\(encodedUser)/\(encodedPass)/\(stream.streamID).m3u8"
                )
            }
        guard !channels.isEmpty else {
            throw IPTVError.message("The server returned no live channels for this login.")
        }
        var guide = URLComponents(string: "\(server)/xmltv.php")
        guide?.queryItems = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass)]
        return IPTVPlaylist(channels: channels, guideURL: guide?.url?.absoluteString, fetchedAt: Date())
    }

    // MARK: Disk cache

    private static func cacheURL(sourceID: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sourceID).json")
    }

    private static func readCache(sourceID: String) -> IPTVPlaylist? {
        guard let data = try? Data(contentsOf: cacheURL(sourceID: sourceID)) else { return nil }
        return try? JSONDecoder().decode(IPTVPlaylist.self, from: data)
    }

    private static func writeCache(_ playlist: IPTVPlaylist, sourceID: String) {
        guard let data = try? JSONEncoder().encode(playlist) else { return }
        try? data.write(to: cacheURL(sourceID: sourceID), options: .atomic)
    }
}

// MARK: - Naming and language

/// Reads a provider's channel names: the region or language tags in front
/// ("US: ", "AM | ", "AR | "), the quality and backup marks providers append
/// ("FHD", "4K", "(Backup)", "ᴴᴰ"), and the languages the tags point to.
enum IPTVNaming {
    struct Cleaned {
        /// The name to show, tags and marks removed, case kept.
        let display: String
        /// Lowercased, accent-free form two variants of a channel share.
        let key: String
        /// The tags that were in front of the name.
        let tags: [String]
    }

    private static let qualityWords: Set<String> = [
        "hd", "fhd", "uhd", "sd", "4k", "8k", "hevc", "h265", "h264", "hdr", "hq", "lq", "raw",
        "vip", "backup", "bk", "multi", "720p", "1080p", "2160p", "1080i", "50fps", "60fps", "25fps",
        "fps",
    ]

    /// Entries a panel lists that are not channels: section headers drawn in
    /// symbols ("✦●✦ FIFA REPLAYS ✦●✦", "##### USA #####") and the
    /// subscription notice some providers put first.
    static func isPlaceholder(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        if lowered.contains("account info") || lowered.hasPrefix("expire") || lowered.contains("####") { return true }
        let leading = trimmed.unicodeScalars.prefix(2)
        return leading.count == 2 && leading.allSatisfy {
            !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespaces.contains($0)
        }
    }

    static func clean(_ raw: String) -> Cleaned {
        // Superscript and decorative characters some panels use.
        var text = raw.applyingTransform(.toLatin, reverse: false) ?? raw
        text = text.replacingOccurrences(of: "ᴴᴰ", with: " HD").replacingOccurrences(of: "ᵁᴴᴰ", with: " UHD")
        text = String(text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || " +&'|:!.-".unicodeScalars.contains(scalar)
                ? Character(scalar) : " "
        })
        // Bracketed asides: "(Backup)", "[FHD]", "(1080p)".
        text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)

        // Tags in front: "AM | USA: ESPN" → tags [AM, USA], name "ESPN".
        var tags: [String] = []
        // Tags may be hyphenated: "LATIN-MX| ESPN" → [LATIN, MX].
        while let range = text.range(of: #"^\s*([A-Za-z0-9/ \-]{1,16}?)\s*[|:]\s*"#, options: .regularExpression) {
            let tag = text[range].trimmingCharacters(in: CharacterSet(charactersIn: " |:"))
            guard !tag.isEmpty else { break }
            tags += tag.split(whereSeparator: { $0 == " " || $0 == "-" }).map { String($0).uppercased() }
            text.removeSubrange(range)
        }
        text = text.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: ":", with: " ")

        let words = text.split(separator: " ").map(String.init).filter {
            !qualityWords.contains($0.lowercased()) && $0 != "-" && $0 != "."
        }
        let display = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        let folded = display.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let kept: [Character] = folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "+" ? Character($0) : " "
        }
        let key = String(kept).split(separator: " ").map(String.init).joined(separator: " ")
        return Cleaned(display: display.isEmpty ? raw : display, key: key, tags: tags)
    }

    /// Higher for the better copy of a channel, to list it first.
    static func qualityRank(_ name: String) -> Int {
        let upper = name.uppercased()
        if upper.contains("8K") { return 6 }
        if upper.contains("4K") || upper.contains("UHD") || upper.contains("2160") { return 5 }
        if upper.contains("FHD") || upper.contains("1080") { return 4 }
        if upper.contains("HD") || upper.contains("720") { return 3 }
        if upper.contains("BACKUP") { return 1 }
        if upper.contains("SD") { return 2 }
        return 2
    }

    /// Codes allowed only as a tag in front of a name ("AR | …"): as loose
    /// words they would match too much.
    private static let tagCodes: [String: [String]] = [
        "US": ["English"], "UK": ["English"], "GB": ["English"], "EN": ["English"], "ENG": ["English"],
        "AU": ["English"], "AUS": ["English"], "NZ": ["English"], "IE": ["English"], "IRL": ["English"],
        "CA": ["English", "French"], "ES": ["Spanish"], "ESP": ["Spanish"], "MX": ["Spanish"], "LAT": ["Spanish"],
        "CO": ["Spanish"], "CL": ["Spanish"], "PE": ["Spanish"], "VE": ["Spanish"], "EC": ["Spanish"],
        "AR": ["Arabic"], "SA": ["Arabic"], "KSA": ["Arabic"], "AE": ["Arabic"], "EG": ["Arabic"], "MA": ["Arabic"],
        "FR": ["French"], "QC": ["French"], "BE": ["French", "Dutch"], "DE": ["German"], "AT": ["German"],
        "CH": ["German", "French", "Italian"], "IT": ["Italian"], "PT": ["Portuguese"], "BR": ["Portuguese"],
        "IN": ["Hindi"], "TR": ["Turkish"], "PL": ["Polish"], "NL": ["Dutch"], "RU": ["Russian"], "GR": ["Greek"],
        "RO": ["Romanian"], "HU": ["Hungarian"], "CZ": ["Czech"], "SE": ["Swedish"], "NO": ["Norwegian"],
        "DK": ["Danish"], "FI": ["Finnish"], "UA": ["Ukrainian"], "BG": ["Bulgarian"], "HR": ["Croatian"],
        "IL": ["Hebrew"], "TH": ["Thai"], "VN": ["Vietnamese"], "KR": ["Korean"], "JP": ["Japanese"],
        "CN": ["Chinese"], "HK": ["Chinese"], "TW": ["Chinese"], "ID": ["Indonesian"],
        "PK": ["Urdu"], "IR": ["Persian"], "AF": ["Persian"], "AL": ["Albanian"], "RS": ["Serbian"],
        "BD": ["Bengali"], "PH": ["Filipino"], "MY": ["Malay"],
    ]

    /// Whole words that name a country or language wherever they appear.
    private static let words: [String: [String]] = [
        "USA": ["English"], "AMERICA": ["English"], "AMERICAN": ["English"], "ENGLISH": ["English"],
        "BRITISH": ["English"], "AUSTRALIA": ["English"], "IRELAND": ["English"], "CANADA": ["English", "French"],
        "CANADIAN": ["English", "French"],
        "SPAIN": ["Spanish"], "ESPANA": ["Spanish"], "SPANISH": ["Spanish"], "ESPANOL": ["Spanish"],
        "LATINO": ["Spanish"], "LATINA": ["Spanish"], "LATAM": ["Spanish"], "LATIN": ["Spanish"], "MEXICO": ["Spanish"],
        "ARGENTINA": ["Spanish"], "COLOMBIA": ["Spanish"], "CHILE": ["Spanish"], "PERU": ["Spanish"],
        "ARAB": ["Arabic"], "ARABIC": ["Arabic"], "ARABE": ["Arabic"], "ARABIA": ["Arabic"], "EGYPT": ["Arabic"],
        "FRANCE": ["French"], "FRENCH": ["French"], "FRANCAIS": ["French"], "QUEBEC": ["French"],
        "GERMANY": ["German"], "GERMAN": ["German"], "DEUTSCH": ["German"], "DEUTSCHLAND": ["German"],
        "ITALY": ["Italian"], "ITALIA": ["Italian"], "ITALIAN": ["Italian"],
        "PORTUGAL": ["Portuguese"], "PORTUGUESE": ["Portuguese"], "BRAZIL": ["Portuguese"], "BRASIL": ["Portuguese"],
        "INDIA": ["Hindi"], "HINDI": ["Hindi"], "INDIAN": ["Hindi"],
        "TAMIL": ["Tamil"], "TELUGU": ["Telugu"], "PUNJABI": ["Punjabi"], "MALAYALAM": ["Malayalam"],
        "KANNADA": ["Kannada"], "MARATHI": ["Marathi"], "BANGLA": ["Bengali"], "BENGALI": ["Bengali"],
        "URDU": ["Urdu"], "PAKISTAN": ["Urdu"], "PERSIAN": ["Persian"], "IRAN": ["Persian"], "AFGHAN": ["Persian"],
        "TURKEY": ["Turkish"], "TURKISH": ["Turkish"], "TURKIYE": ["Turkish"],
        "POLAND": ["Polish"], "POLSKA": ["Polish"], "NETHERLANDS": ["Dutch"], "DUTCH": ["Dutch"],
        "RUSSIA": ["Russian"], "RUSSIAN": ["Russian"], "GREECE": ["Greek"], "GREEK": ["Greek"],
        "ROMANIA": ["Romanian"], "HUNGARY": ["Hungarian"], "CZECH": ["Czech"], "SWEDEN": ["Swedish"],
        "NORWAY": ["Norwegian"], "DENMARK": ["Danish"], "FINLAND": ["Finnish"], "UKRAINE": ["Ukrainian"],
        "BULGARIA": ["Bulgarian"], "CROATIA": ["Croatian"], "ISRAEL": ["Hebrew"], "THAILAND": ["Thai"],
        "VIETNAM": ["Vietnamese"], "KOREA": ["Korean"], "KOREAN": ["Korean"], "JAPAN": ["Japanese"],
        "CHINA": ["Chinese"], "CHINESE": ["Chinese"], "INDONESIA": ["Indonesian"], "ALBANIA": ["Albanian"],
        "EXYU": ["Serbian"], "SERBIA": ["Serbian"], "AFRICA": ["English"], "PHILIPPINES": ["Filipino"],
    ]

    /// The languages a channel's tags and group point to; empty when none do.
    static func languages(group: String, nameTags: [String]) -> Set<String> {
        let groupCleaned = clean(group)
        var found = Set<String>()
        for tag in nameTags + groupCleaned.tags {
            found.formUnion(tagCodes[tag] ?? words[tag] ?? [])
        }
        let groupWords = (groupCleaned.tags + groupCleaned.display.uppercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .split(whereSeparator: { !$0.isLetter }).map(String.init))
        for word in groupWords { found.formUnion(words[word] ?? []) }
        return found
    }

    /// The viewer's languages: audio, then the subtitle choices, as named in
    /// Settings ("English"). Empty when every one is left on System.
    static func preferredLanguages(in defaults: UserDefaults = ProfileSettings.current) -> Set<String> {
        let keys = [
            SettingsKey.audioLanguage, SettingsKey.subtitleLanguage,
            SettingsKey.subtitleLanguageSecondary, SettingsKey.subtitleLanguageTertiary,
        ]
        let chosen = keys.compactMap { defaults.string(forKey: $0) }
            .filter { !$0.isEmpty && !SubtitleLanguagePreferences.disabledValues.contains($0) }
        if !chosen.isEmpty { return Set(chosen) }
        // Nothing chosen: the device's own language.
        if let code = Locale.current.language.languageCode?.identifier,
           let name = Locale(identifier: "en").localizedString(forLanguageCode: code) {
            return [name]
        }
        return []
    }

    /// A channel shows when its languages include one of the viewer's, or
    /// when its tags name no language at all.
    static func matches(_ languages: Set<String>, preferred: Set<String>) -> Bool {
        languages.isEmpty || preferred.isEmpty || !languages.isDisjoint(with: preferred)
    }
}

// MARK: - Guide (now and next)

struct IPTVProgramme: Equatable {
    let title: String
    let start: Date
    let end: Date
}

/// Now and next for a channel, from the provider's Xtream API (`get_short_epg`),
/// asked for one channel at a time when its page opens and kept five minutes.
/// The full guide grid will read the XMLTV file instead.
actor IPTVGuide {
    static let shared = IPTVGuide()
    private var cache: [String: (fetched: Date, programmes: [IPTVProgramme])] = [:]

    func nowAndNext(for group: IPTVChannelGroup) async -> (now: IPTVProgramme?, next: IPTVProgramme?) {
        let now = Date()
        let upcoming = await programmes(for: group, limit: 4).filter { $0.end > now }
        return (upcoming.first { $0.start <= now }, upcoming.first { $0.start > now })
    }

    /// A channel's programmes from now on, in order: the first variant whose
    /// provider has guide data for it answers. For the guide's rows.
    func programmes(for group: IPTVChannelGroup, limit: Int = 16) async -> [IPTVProgramme] {
        let sources = IPTVSourceStore.sources()
        for channel in group.variants {
            guard let source = sources.first(where: { $0.id == channel.sourceID }),
                  let login = Self.xtreamLogin(for: source),
                  let streamID = Self.streamID(of: channel) else { continue }
            let found = await shortEPG(login: login, streamID: streamID, limit: limit)
                .filter { $0.end > Date() }
                .sorted { $0.start < $1.start }
            if !found.isEmpty { return found }
        }
        return []
    }

    private func shortEPG(
        login: (server: String, username: String, password: String),
        streamID: String,
        limit: Int
    ) async -> [IPTVProgramme] {
        let key = "\(login.server)|\(streamID)|\(limit)"
        if let held = cache[key], Date().timeIntervalSince(held.fetched) < 300 { return held.programmes }
        var components = URLComponents(string: "\(login.server)/player_api.php")
        components?.queryItems = [
            URLQueryItem(name: "username", value: login.username),
            URLQueryItem(name: "password", value: login.password),
            URLQueryItem(name: "action", value: "get_short_epg"),
            URLQueryItem(name: "stream_id", value: streamID),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listings = object["epg_listings"] as? [[String: Any]] else { return [] }
        let programmes = listings.compactMap { entry -> IPTVProgramme? in
            // Xtream sends titles base64-encoded and times as Unix seconds.
            let rawTitle = entry["title"] as? String ?? ""
            let title = Data(base64Encoded: rawTitle).flatMap { String(data: $0, encoding: .utf8) } ?? rawTitle
            guard let start = Self.seconds(entry["start_timestamp"]),
                  let end = Self.seconds(entry["stop_timestamp"]) ?? Self.seconds(entry["end_timestamp"]),
                  !title.isEmpty else { return nil }
            return IPTVProgramme(title: title, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
        }
        cache[key] = (Date(), programmes)
        return programmes
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func xtreamLogin(for source: IPTVSource) -> (server: String, username: String, password: String)? {
        switch source.kind {
        case .xtream:
            guard let user = source.username, !user.isEmpty, let pass = source.password, !pass.isEmpty else { return nil }
            return (IPTVSource.normalizedServer(source.url), user, pass)
        case .m3u:
            return IPTVLibrary.xtreamLogin(fromPlaylistURL: source.url)
        }
    }

    /// The panel's stream id: the key itself when the channel came from the
    /// API, else the number at the end of its stream URL.
    static func streamID(of channel: IPTVChannel) -> String? {
        if !channel.key.isEmpty, channel.key.allSatisfy(\.isNumber) { return channel.key }
        let last = URL(string: channel.streamURL)?.deletingPathExtension().lastPathComponent ?? ""
        return !last.isEmpty && last.allSatisfy(\.isNumber) ? last : nil
    }
}

// MARK: - Chunked download

/// One download through its own session delegate, so progress can be
/// reported as data arrives. The session is invalidated when it finishes.
private final class IPTVChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let stage: String
    private let progress: IPTVProgressHandler
    private var data = Data()
    private var expected: Int64 = -1
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<Data, Error>?
    private var failure: Error?

    init(stage: String, progress: @escaping IPTVProgressHandler) {
        self.stage = stage
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.default
        // Only a minute of silence ends it; a slow panel may need minutes.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = IPTVError.message(http.statusCode == 401 || http.statusCode == 403
                ? "The provider refused the login (\(http.statusCode))."
                : "The provider answered \(http.statusCode).")
            completionHandler(.cancel)
            return
        }
        expected = response.expectedContentLength
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        data.append(chunk)
        guard Date().timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = Date()
        let got = Double(data.count) / 1_048_576
        if expected > 0 {
            progress(IPTVLoadProgress(
                stage: String(format: "%@ — %.1f of %.1f MB", stage, got, Double(expected) / 1_048_576),
                fraction: min(Double(data.count) / Double(expected), 1)
            ))
        } else {
            progress(IPTVLoadProgress(stage: String(format: "%@ — %.1f MB", stage, got), fraction: nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            let timedOut = (error as? URLError)?.code == .timedOut
            continuation?.resume(throwing: timedOut
                ? IPTVError.message("The provider stopped sending for a minute. Try again, or use the Xtream login instead.")
                : error)
        } else {
            continuation?.resume(returning: data)
        }
        continuation = nil
    }
}

// MARK: - M3U

/// Reads an extended M3U playlist: `#EXTINF` lines carry the attributes
/// (`tvg-id`, `tvg-name`, `tvg-logo`, `group-title`) and the display name after
/// the last comma outside quotes; the next non-comment line is the stream URL.
/// `#EXTGRP` sets a group for playlists without `group-title`.
enum M3UParser {
    struct Result {
        var channels: [IPTVChannel]
        var guideURL: String?
        /// A panel's `m3u_plus` playlist lists films and episodes too; they
        /// are counted here and kept out of Live TV.
        var movieCount = 0
        var seriesCount = 0
    }

    static func parse(_ text: String, sourceID: String) -> Result {
        var channels: [IPTVChannel] = []
        var guideURL: String?
        var pendingInfo: (attributes: [String: String], name: String)?
        var pendingGroup: String?
        var seenKeys = Set<String>()
        var movieCount = 0
        var seriesCount = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTM3U") {
                let header = attributes(in: line)
                guideURL = header["url-tvg"] ?? header["x-tvg-url"]
                guideURL = guideURL?.split(separator: ",").first.map(String.init)
            } else if line.hasPrefix("#EXTINF") {
                pendingInfo = (attributes(in: line), displayName(in: line))
            } else if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                continue
            } else {
                guard let info = pendingInfo else { continue }
                let url = line
                // Xtream panels serve films under /movie/ and episodes under /series/.
                let lowered = url.lowercased()
                if lowered.contains("/movie/") {
                    movieCount += 1; pendingInfo = nil; pendingGroup = nil; continue
                }
                if lowered.contains("/series/") {
                    seriesCount += 1; pendingInfo = nil; pendingGroup = nil; continue
                }
                let attrs = info.attributes
                let name = info.name.nilIfBlank ?? attrs["tvg-name"]?.nilIfBlank ?? "Channel"
                let group = attrs["group-title"]?.nilIfBlank ?? pendingGroup?.nilIfBlank ?? "Live TV"
                var key = shortHash(url)
                // The same stream listed twice: keep both, with distinct ids.
                if !seenKeys.insert(key).inserted { key += "-\(channels.count)" ; seenKeys.insert(key) }
                channels.append(IPTVChannel(
                    key: key,
                    sourceID: sourceID,
                    name: name,
                    logo: attrs["tvg-logo"]?.nilIfBlank,
                    group: group,
                    tvgID: attrs["tvg-id"]?.nilIfBlank,
                    streamURL: url
                ))
                pendingInfo = nil
                pendingGroup = nil
            }
        }
        return Result(channels: channels, guideURL: guideURL, movieCount: movieCount, seriesCount: seriesCount)
    }

    /// `key="value"` pairs on an `#EXTINF` / `#EXTM3U` line.
    static func attributes(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([A-Za-z0-9_-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(line.startIndex..., in: line)
        for match in regex.matches(in: line, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            result[line[keyRange].lowercased()] = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// The display name: everything after the first comma that follows the
    /// attributes. Names themselves can hold commas ("US: ESPN, HD"), so the
    /// last comma is the wrong one.
    static func displayName(in line: String) -> String {
        var inQuotes = false
        for index in line.indices {
            let character = line[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

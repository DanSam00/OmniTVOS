import Foundation

/// An IPTV provider's own films and shows, browsed by its categories (the
/// Library's Folders), each opening a page of its own that plays from the
/// provider. `IPTVVODLibrary` reads the same Xtream "VOD" lists, but only to
/// offer a catalog title's copies; this is the provider's list as it is.
///
/// Ids: `iptvvod-m-<stream_id>-<source id>` for a film and
/// `iptvvod-s-<series_id>-<source id>` for a show, whose episodes are
/// `<show id>:<season>:<episode>`. Nothing inside an id is a colon, so the
/// `id:season:episode` reading elsewhere holds.
actor IPTVVODBrowser {
    static let shared = IPTVVODBrowser()
    static let idPrefix = "iptvvod-"

    enum Kind: String, CaseIterable {
        case movies = "m"
        case series = "s"

        var title: String {
            self == .movies ? L10n.string("iptv_browse_movies", fallback: "Movies")
                : L10n.string("iptv_browse_series", fallback: "Series")
        }
    }

    struct Category: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Entry: Identifiable, Hashable {
        let contentID: String
        let name: String
        let poster: String?
        let year: Int?
        let type: String
        var id: String { contentID }
    }

    private struct EpisodeFile {
        let id: String
        let ext: String?
    }

    private var categories: [String: [Category]] = [:]
    private var entries: [String: [Entry]] = [:]
    private var metas: [String: NuvioMeta] = [:]
    private var movieExts: [String: String] = [:]
    private var episodeFiles: [String: [String: EpisodeFile]] = [:]

    static func isBrowserID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The enabled providers whose films and shows can be listed: an Xtream
    /// login, or a playlist link from an Xtream panel.
    nonisolated static func sources() -> [IPTVSource] {
        IPTVSourceStore.sources().filter { $0.enabled && IPTVGuide.xtreamLogin(for: $0) != nil }
    }

    // MARK: Listing

    /// The provider's categories of this kind in the viewer's languages
    /// (all of them when none is tagged with one), in the provider's order.
    func categories(source: IPTVSource, kind: Kind) async -> [Category] {
        let cacheKey = "\(source.id)|\(kind.rawValue)"
        if let held = categories[cacheKey] { return held }
        guard let login = IPTVGuide.xtreamLogin(for: source),
              let list = await IPTVVODLibrary.json(
                login: login, action: kind == .movies ? "get_vod_categories" : "get_series_categories"
              ) as? [[String: Any]] else { return [] }
        let all = list.compactMap { entry -> Category? in
            guard let id = IPTVVODLibrary.stringValue(entry["category_id"]),
                  let name = (entry["category_name"] as? String)?.vodNonBlank else { return nil }
            return Category(id: id, name: name)
        }
        let preferred = IPTVNaming.preferredLanguages()
        let mine = all.filter { IPTVNaming.matches(IPTVVODLibrary.categoryLanguages($0.name), preferred: preferred) }
        let result = mine.isEmpty ? all : mine
        if !result.isEmpty { categories[cacheKey] = result }
        return result
    }

    /// One category's films or shows, by name.
    func entries(source: IPTVSource, kind: Kind, categoryID: String) async -> [Entry] {
        let cacheKey = "\(source.id)|\(kind.rawValue)|\(categoryID)"
        if let held = entries[cacheKey] { return held }
        guard let login = IPTVGuide.xtreamLogin(for: source),
              let list = await IPTVVODLibrary.json(
                login: login, action: kind == .movies ? "get_vod_streams" : "get_series",
                extra: ["category_id": categoryID]
              ) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        let result = list.compactMap { entry -> Entry? in
            guard let itemID = IPTVVODLibrary.stringValue(entry[kind == .movies ? "stream_id" : "series_id"]),
                  let raw = (entry["name"] as? String)?.vodNonBlank else { return nil }
            let contentID = Self.contentID(kind: kind, itemID: itemID, sourceID: source.id)
            guard seen.insert(contentID).inserted else { return nil }
            if kind == .movies, let ext = (entry["container_extension"] as? String)?.vodNonBlank {
                movieExts[contentID] = ext
            }
            let (title, nameYear) = IPTVVODLibrary.splitYear(raw)
            let released = (entry["releaseDate"] as? String) ?? (entry["year"] as? String)
            return Entry(
                contentID: contentID,
                name: Self.displayName(title) ?? raw,
                poster: ((entry[kind == .movies ? "stream_icon" : "cover"] as? String)?.vodNonBlank).flatMap(Self.webURL),
                year: nameYear ?? released.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil },
                type: kind == .movies ? "movie" : "series"
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !result.isEmpty { entries[cacheKey] = result }
        return result
    }

    // MARK: A title's page

    /// The page for a film or show, from the provider's own details. Built
    /// from the id alone, so a title in Continue Watching opens after a
    /// relaunch as well.
    func meta(forContentID id: String) async -> NuvioMeta? {
        if let held = metas[id] { return held }
        guard let parsed = Self.parse(id),
              let source = IPTVSourceStore.sources().first(where: { $0.id == parsed.sourceID }),
              let login = IPTVGuide.xtreamLogin(for: source) else { return nil }
        let meta: NuvioMeta?
        switch parsed.kind {
        case .movies:
            meta = await movieMeta(id: id, itemID: parsed.itemID, login: login)
        case .series:
            meta = await seriesMeta(id: id, itemID: parsed.itemID, login: login)
        }
        if let meta { metas[id] = meta }
        return meta
    }

    private func movieMeta(
        id: String, itemID: String, login: (server: String, username: String, password: String)
    ) async -> NuvioMeta? {
        guard let answer = await IPTVVODLibrary.json(login: login, action: "get_vod_info", extra: ["vod_id": itemID]) as? [String: Any] else {
            return nil
        }
        let info = answer["info"] as? [String: Any] ?? [:]
        let data = answer["movie_data"] as? [String: Any] ?? [:]
        if let ext = (data["container_extension"] as? String)?.vodNonBlank { movieExts[id] = ext }
        let raw = (info["name"] as? String)?.vodNonBlank ?? (data["name"] as? String)?.vodNonBlank ?? ""
        guard !raw.isEmpty else { return nil }
        return Self.meta(id: id, type: "movie", rawName: raw, info: info, videos: nil)
    }

    private func seriesMeta(
        id: String, itemID: String, login: (server: String, username: String, password: String)
    ) async -> NuvioMeta? {
        guard let answer = await IPTVVODLibrary.json(login: login, action: "get_series_info", extra: ["series_id": itemID]) as? [String: Any] else {
            return nil
        }
        let info = answer["info"] as? [String: Any] ?? [:]
        guard let raw = (info["name"] as? String)?.vodNonBlank else { return nil }
        // Panels send the seasons as an object keyed by number, or a list.
        let seasons: [Any] = (answer["episodes"] as? [String: Any]).map { Array($0.values) }
            ?? (answer["episodes"] as? [Any]) ?? []
        var files: [String: EpisodeFile] = [:]
        var videos: [NuvioVideo] = []
        for list in seasons {
            for case let entry as [String: Any] in (list as? [Any]) ?? [] {
                guard let fileID = IPTVVODLibrary.stringValue(entry["id"]),
                      let season = IPTVVODLibrary.stringValue(entry["season"]).flatMap({ Int($0) }),
                      let number = IPTVVODLibrary.stringValue(entry["episode_num"]).flatMap({ Int($0) }),
                      files["\(season):\(number)"] == nil else { continue }
                files["\(season):\(number)"] = EpisodeFile(id: fileID, ext: (entry["container_extension"] as? String)?.vodNonBlank)
                let details = entry["info"] as? [String: Any] ?? [:]
                videos.append(NuvioVideo(
                    id: "\(id):\(season):\(number)",
                    title: Self.episodeTitle(entry["title"] as? String, show: raw) ?? "Episode \(number)",
                    season: season,
                    episode: number,
                    thumbnail: ((details["movie_image"] as? String)?.vodNonBlank).flatMap(Self.webURL),
                    overview: (details["plot"] as? String)?.vodNonBlank,
                    released: (details["releasedate"] as? String)?.vodNonBlank ?? (details["air_date"] as? String)?.vodNonBlank,
                    rating: nil
                ))
            }
        }
        episodeFiles[id] = files
        return Self.meta(
            id: id, type: "series", rawName: raw, info: info,
            videos: videos.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        )
    }

    private static func meta(id: String, type: String, rawName: String, info: [String: Any], videos: [NuvioVideo]?) -> NuvioMeta {
        let (title, nameYear) = IPTVVODLibrary.splitYear(rawName)
        let released = (info["releasedate"] as? String)?.vodNonBlank ?? (info["releaseDate"] as? String)?.vodNonBlank
        let year = nameYear ?? released.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }
        let poster = ((info["movie_image"] as? String)?.vodNonBlank ?? (info["cover_big"] as? String)?.vodNonBlank
            ?? (info["cover"] as? String)?.vodNonBlank).flatMap(webURL)
        let backdrop = ((info["backdrop_path"] as? [String])?.first?.vodNonBlank
            ?? (info["backdrop_path"] as? String)?.vodNonBlank).flatMap(webURL)
        func names(_ key: String) -> [String]? {
            let list = ((info[key] as? String) ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return list.isEmpty ? nil : list
        }
        let rating = IPTVVODLibrary.stringValue(info["rating"]).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        let minutes = IPTVVODLibrary.stringValue(info["episode_run_time"]).flatMap(Int.init)
            ?? IPTVVODLibrary.stringValue(info["duration_secs"]).flatMap(Int.init).map { $0 / 60 }
        return NuvioMeta(
            id: id,
            name: displayName(title) ?? rawName,
            description: (info["plot"] as? String)?.vodNonBlank ?? (info["description"] as? String)?.vodNonBlank,
            posterUrl: poster,
            backgroundUrl: backdrop ?? poster,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: type,
            year: year,
            genres: names("genre"),
            rating: rating,
            releaseInfo: year.map(String.init),
            runtime: minutes.flatMap { $0 > 0 ? "\($0) min" : nil },
            cast: names("cast"),
            director: names("director"),
            writer: nil,
            certification: nil,
            country: (info["country"] as? String)?.vodNonBlank,
            released: released,
            videos: videos
        )
    }

    // MARK: Playing

    /// The film, or the episode `videoID` names, from its provider.
    func streams(videoID: String) async -> [NuvioStream] {
        let base = String(videoID.split(separator: ":").first ?? Substring(videoID))
        guard let parsed = Self.parse(base),
              let source = IPTVSourceStore.sources().first(where: { $0.id == parsed.sourceID }),
              let login = IPTVGuide.xtreamLogin(for: source),
              let meta = await meta(forContentID: base) else { return [] }
        switch parsed.kind {
        case .movies:
            return [IPTVVODLibrary.stream(
                source: source, login: login, kind: "movie", id: parsed.itemID, ext: movieExts[base], label: meta.name
            )]
        case .series:
            let episode = StreamsRepository.seasonEpisode(fromVideoId: videoID)
            guard let season = episode.season, let number = episode.episode,
                  let file = episodeFiles[base]?["\(season):\(number)"] else { return [] }
            return [IPTVVODLibrary.stream(
                source: source, login: login, kind: "series", id: file.id, ext: file.ext,
                label: String(format: "%@ · S%02dE%02d", meta.name, season, number)
            )]
        }
    }

    // MARK: Ids

    static func contentID(kind: Kind, itemID: String, sourceID: String) -> String {
        "\(idPrefix)\(kind.rawValue)-\(itemID)-\(sourceID)"
    }

    private static func parse(_ id: String) -> (kind: Kind, itemID: String, sourceID: String)? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let rest = id.dropFirst(idPrefix.count)
        let parts = rest.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[0])), !parts[1].isEmpty, !parts[2].isEmpty else {
            return nil
        }
        return (kind, String(parts[1]), String(parts[2]))
    }

    /// A provider's name without its language tags in front or the release
    /// marks after it: "EN| 28 Years Later MULTI-SUB" → "28 Years Later".
    /// Only those: a channel's cleaning also reads "X: " as a tag, which
    /// cut "Hope Valley: 1874" down to "1874".
    static func displayName(_ raw: String) -> String? {
        var name = raw
        let tags = [#"^\s*[A-Za-z]{2,5}(-[A-Za-z]{2,5})?\s*\|\s*"#, #"^\s*\[[^\]]{1,16}\]\s*"#]
        while let range = tags.lazy.compactMap({ name.range(of: $0, options: .regularExpression) }).first {
            name.removeSubrange(range)
        }
        // "… MULTI-SUB", "… - 4K", or the same in brackets: "… [MULTI-SUB-AUDIO]".
        let marks = #"(?i)([\s\-|]+(multi[\s-]?(sub|subs|audio|lang)|vostfr|dual[\s-]?audio|4k|uhd|fhd|hd|hevc|h265|x265)|\s*[\[(](multi[^\])]*|vostfr|dual[\s-]?audio|4k|uhd|fhd|hd|hevc|h265|x265)[\])])\s*$"#
        while let range = name.range(of: marks, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name.trimmingCharacters(in: .whitespaces).vodNonBlank
    }

    /// An episode's own name, without the show's name and "S01E01" panels
    /// put around it; nil when that leaves nothing ("S01E01" alone).
    private static func episodeTitle(_ raw: String?, show: String) -> String? {
        guard var name = raw.flatMap(displayName) else { return nil }
        if let showName = displayName(show), name.lowercased().hasPrefix(showName.lowercased()) {
            name.removeFirst(showName.count)
        }
        name = name.replacingOccurrences(of: #"(?i)\bS\d{1,2}\s?E\d{1,3}\b"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -–|:."))
        return name.vodNonBlank
    }

    /// Panels sometimes send a bare host or a path with spaces.
    private static func webURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("http") else { return nil }
        if URL(string: trimmed) != nil { return trimmed }
        return trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
    }
}

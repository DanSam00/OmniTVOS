import Foundation

/// Films and shows from an IPTV provider's library (the Xtream API's "VOD"),
/// offered as sources on a title's page next to the add-ons'.
///
/// Panels list no TMDB or IMDb ids ("EN| Bluey", "FR| Arco - 2025"), so a
/// title is matched on its name and year. The lists are large — one panel
/// sent 158,000 films and 63,000 shows, 150 MB — so only the categories in
/// the viewer's languages are fetched ("[EN] NETFLIX", plus the multi-
/// language ones, which are then filtered title by title), kept as a compact
/// index on disk and refreshed every few days. A page never waits for that:
/// until a provider's index is ready it simply offers nothing.
actor IPTVVODLibrary {
    static let shared = IPTVVODLibrary()

    struct Item: Codable, Hashable {
        /// `stream_id` for a film, `series_id` for a show.
        let id: String
        /// `titleKey` of the name.
        let key: String
        let year: Int?
        let ext: String?
        /// The provider's own name for it, shown on the source row.
        let label: String
    }

    struct Index: Codable {
        var movies: [Item]
        var series: [Item]
        /// The languages it was built for; a change in Settings rebuilds it.
        var languages: [String]
        var fetchedAt: Date
        /// The matching rules it was built with; older indexes are rebuilt.
        var version: Int? = nil
    }

    private static let indexVersion = 2

    struct Episode: Codable {
        let id: String
        let season: Int
        let episode: Int
        let ext: String?
    }

    private static let maxAge: TimeInterval = 3 * 24 * 3600
    private static let episodesMaxAge: TimeInterval = 6 * 3600

    private var indexes: [String: Index] = [:]
    private var building: Set<String> = []
    private var episodeLists: [String: (fetched: Date, episodes: [Episode])] = [:]

    // MARK: Sources for a title

    /// This film's or episode's copies on every enabled provider whose index
    /// is ready. One without an index starts building it, for next time.
    func streams(meta: NuvioMeta, season: Int?, episode: Int?) async -> [NuvioStream] {
        let key = Self.titleKey(meta.name)
        guard !key.isEmpty else { return [] }
        let year = meta.year ?? meta.releaseInfo.flatMap { Int($0.prefix(4)) }
        let languages = IPTVNaming.preferredLanguages().sorted()
        var result: [NuvioStream] = []
        for source in IPTVSourceStore.sources() where source.enabled {
            guard let login = IPTVGuide.xtreamLogin(for: source),
                  let index = readyIndex(for: source, login: login, languages: languages) else { continue }
            func sameTitle(_ item: Item) -> Bool {
                guard item.key == key else { return false }
                guard let year, let itemYear = item.year else { return true }
                return abs(itemYear - year) <= 1
            }
            if meta.isSeries {
                guard let season, let episode else { continue }
                for show in index.series.filter(sameTitle).prefix(4) {
                    let episodes = await episodes(source: source, login: login, seriesID: show.id)
                    for match in episodes where match.season == season && match.episode == episode {
                        result.append(Self.stream(
                            source: source, login: login, kind: "series", id: match.id, ext: match.ext,
                            label: String(format: "%@ · S%02dE%02d", show.label, season, episode)
                        ))
                    }
                }
            } else {
                for film in index.movies.filter(sameTitle).prefix(8) {
                    result.append(Self.stream(
                        source: source, login: login, kind: "movie", id: film.id, ext: film.ext, label: film.label
                    ))
                }
            }
        }
        if !result.isEmpty { Self.log("iptv.vod matches=\(result.count) \(meta.isSeries ? "series" : "movie")") }
        return result
    }

    private static func stream(
        source: IPTVSource,
        login: (server: String, username: String, password: String),
        kind: String,
        id: String,
        ext: String?,
        label: String
    ) -> NuvioStream {
        let user = login.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login.username
        let pass = login.password.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login.password
        let fileExt = ext?.vodNonBlank ?? "mp4"
        return NuvioStream(
            url: "\(login.server)/\(kind)/\(user)/\(pass)/\(id).\(fileExt)",
            name: "IPTV\n\(fileExt.uppercased())",
            description: label,
            addonName: source.name.vodNonBlank ?? "IPTV",
            filename: "\(label).\(fileExt)"
        )
    }

    // MARK: Index

    /// The index if there is one for these languages; a stale one is used
    /// while a fresh one builds.
    private func readyIndex(
        for source: IPTVSource,
        login: (server: String, username: String, password: String),
        languages: [String]
    ) -> Index? {
        if indexes[source.id] == nil, let saved = Self.readCache(sourceID: source.id) {
            indexes[source.id] = saved
        }
        let current = indexes[source.id].flatMap {
            $0.languages == languages && $0.version == Self.indexVersion ? $0 : nil
        }
        if current.map({ Date().timeIntervalSince($0.fetchedAt) > Self.maxAge }) ?? true {
            startBuilding(source: source, login: login, languages: languages)
        }
        return current
    }

    private func startBuilding(
        source: IPTVSource,
        login: (server: String, username: String, password: String),
        languages: [String]
    ) {
        guard building.insert(source.id).inserted else { return }
        Task.detached(priority: .utility) {
            let started = Date()
            let index = await Self.build(login: login, languages: languages)
            await self.finishBuilding(sourceID: source.id, index: index, started: started)
        }
    }

    private func finishBuilding(sourceID: String, index: Index?, started: Date) {
        building.remove(sourceID)
        guard let index else {
            Self.log("iptv.vod index failed ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return
        }
        indexes[sourceID] = index
        Self.writeCache(index, sourceID: sourceID)
        Self.log("iptv.vod index films=\(index.movies.count) shows=\(index.series.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }

    private static func build(
        login: (server: String, username: String, password: String),
        languages: [String]
    ) async -> Index? {
        let preferred = Set(languages)
        async let movies = items(
            login: login, categoriesAction: "get_vod_categories", listAction: "get_vod_streams",
            idField: "stream_id", preferred: preferred
        )
        async let series = items(
            login: login, categoriesAction: "get_series_categories", listAction: "get_series",
            idField: "series_id", preferred: preferred
        )
        let (films, shows) = await (movies, series)
        guard films != nil || shows != nil else { return nil }
        return Index(
            movies: films ?? [], series: shows ?? [], languages: languages, fetchedAt: Date(), version: indexVersion
        )
    }

    /// One kind's titles in the viewer's languages: the categories tagged
    /// with one of them, and those tagged with none ("MULTI-LANG"), whose
    /// titles are then kept or dropped by their own tag ("FR| …").
    private static func items(
        login: (server: String, username: String, password: String),
        categoriesAction: String,
        listAction: String,
        idField: String,
        preferred: Set<String>
    ) async -> [Item]? {
        var categoryIDs: [String?] = [nil]
        if let categories = await json(login: login, action: categoriesAction) as? [[String: Any]], !categories.isEmpty {
            categoryIDs = categories.compactMap { category -> String? in
                guard let id = stringValue(category["category_id"]) else { return nil }
                let name = (category["category_name"] as? String) ?? ""
                return IPTVNaming.matches(categoryLanguages(name), preferred: preferred) ? id : nil
            }
        }
        var items: [Item] = []
        var seen = Set<String>()
        var anyAnswered = false
        // A few categories at a time: a panel serves one list per request.
        for chunk in stride(from: 0, to: categoryIDs.count, by: 4).map({ Array(categoryIDs[$0..<min($0 + 4, categoryIDs.count)]) }) {
            let lists = await withTaskGroup(of: [[String: Any]]?.self) { group -> [[[String: Any]]?] in
                for id in chunk {
                    group.addTask {
                        await json(login: login, action: listAction, extra: id.map { ["category_id": $0] } ?? [:]) as? [[String: Any]]
                    }
                }
                var collected: [[[String: Any]]?] = []
                for await list in group { collected.append(list) }
                return collected
            }
            for list in lists {
                guard let list else { continue }
                anyAnswered = true
                for entry in list {
                    guard let id = stringValue(entry[idField]), seen.insert(id).inserted,
                          let name = (entry["name"] as? String)?.vodNonBlank,
                          let item = item(id: id, name: name, ext: entry["container_extension"] as? String,
                                          released: entry["releaseDate"] as? String, preferred: preferred)
                    else { continue }
                    items.append(item)
                }
            }
        }
        return anyAnswered ? items : nil
    }

    private static func item(id: String, name: String, ext: String?, released: String?, preferred: Set<String>) -> Item? {
        let tags = IPTVNaming.clean(name).tags
        let languages = IPTVNaming.languages(group: "", nameTags: tags)
        // A short tag the naming rules don't know ("SW| ", "ALB| ", "KU| ")
        // is still a language, just not one of the viewer's.
        if languages.isEmpty, !preferred.isEmpty, let tag = tags.first,
           (2...3).contains(tag.count), tag.allSatisfy(\.isLetter) { return nil }
        guard IPTVNaming.matches(languages, preferred: preferred) else { return nil }
        let (title, nameYear) = splitYear(name)
        let key = titleKey(title, stripTags: true)
        guard !key.isEmpty else { return nil }
        let releasedYear = released.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }
        return Item(id: id, key: key, year: nameYear ?? releasedYear, ext: ext?.vodNonBlank, label: name)
    }

    /// "[EN] NETFLIX" → English. Untagged and "[MULTI-LANG]" → none.
    private static func categoryLanguages(_ name: String) -> Set<String> {
        guard let range = name.range(of: #"^\s*\[([^\]]{1,16})\]"#, options: .regularExpression) else {
            return IPTVNaming.languages(group: name, nameTags: [])
        }
        let tag = name[range].trimmingCharacters(in: CharacterSet(charactersIn: " []"))
        // As a "TAG|" prefix, the form the naming rules read tags in.
        return IPTVNaming.languages(group: "\(tag)| x", nameTags: [])
    }

    // MARK: Episodes

    private func episodes(
        source: IPTVSource,
        login: (server: String, username: String, password: String),
        seriesID: String
    ) async -> [Episode] {
        let cacheKey = "\(source.id)|\(seriesID)"
        if let cached = episodeLists[cacheKey], Date().timeIntervalSince(cached.fetched) < Self.episodesMaxAge {
            return cached.episodes
        }
        guard let info = await Self.json(login: login, action: "get_series_info", extra: ["series_id": seriesID]) as? [String: Any] else {
            return []
        }
        var episodes: [Episode] = []
        let bySeason: [Any] = (info["episodes"] as? [String: Any]).map { Array($0.values) }
            ?? (info["episodes"] as? [Any]) ?? []
        for list in bySeason {
            for case let entry as [String: Any] in (list as? [Any]) ?? [] {
                guard let id = Self.stringValue(entry["id"]),
                      let season = Self.stringValue(entry["season"]).flatMap({ Int($0) }),
                      let number = Self.stringValue(entry["episode_num"]).flatMap({ Int($0) }) else { continue }
                episodes.append(Episode(id: id, season: season, episode: number, ext: entry["container_extension"] as? String))
            }
        }
        episodeLists[cacheKey] = (Date(), episodes)
        return episodes
    }

    // MARK: Names

    /// A name reduced to what two listings of the same title share:
    /// lowercase, accents and punctuation gone, "&" as "and", without the
    /// year, bracketed asides, quality marks — and, for a provider's name,
    /// the language tags in front ("EN| ", "FR - ").
    static func titleKey(_ raw: String, stripTags: Bool = false) -> String {
        var text = raw
        if stripTags {
            while let range = text.range(of: #"^\s*[A-Za-z]{2,5}(-[A-Za-z]{2,5})?\s*\|\s*"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
        }
        text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&", with: " and ")
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
            .split(separator: " ")
            .map(String.init)
            .filter { !qualityMarks.contains($0) }
        return words.joined(separator: " ")
    }

    private static let qualityMarks: Set<String> = [
        "4k", "uhd", "fhd", "hd", "sd", "hdr", "1080p", "720p", "2160p", "hevc", "multi", "vostfr", "vf",
    ]

    /// "Arco - 2025" → ("Arco", 2025); "Bluey (2018)" → ("Bluey", 2018).
    static func splitYear(_ name: String) -> (String, Int?) {
        let pattern = #"\s*[-–(\[]?\s*((?:19|20)\d{2})\s*[)\]]?\s*$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return (name, nil) }
        let digits = name[range].filter(\.isNumber)
        let title = String(name[..<range.lowerBound])
        // A title that is only a year ("1917") keeps it.
        guard !titleKey(title, stripTags: true).isEmpty else { return (name, nil) }
        return (title, Int(digits))
    }

    // MARK: Network

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static func json(
        login: (server: String, username: String, password: String),
        action: String,
        extra: [String: String] = [:]
    ) async -> Any? {
        var components = URLComponents(string: "\(login.server)/player_api.php")
        components?.queryItems = [
            URLQueryItem(name: "username", value: login.username),
            URLQueryItem(name: "password", value: login.password),
            URLQueryItem(name: "action", value: action),
        ] + extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Omni/\(SimklConfig.appVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Panels disagree on whether ids and numbers are numbers or strings.
    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text.vodNonBlank }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: Disk cache

    private static func cacheURL(sourceID: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sourceID)-vod.json")
    }

    private static func readCache(sourceID: String) -> Index? {
        guard let data = try? Data(contentsOf: cacheURL(sourceID: sourceID)) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    private static func writeCache(_ index: Index, sourceID: String) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: cacheURL(sourceID: sourceID), options: .atomic)
    }

    /// Counts only: stream addresses carry the provider login.
    private static func log(_ message: String) {
        #if os(macOS)
        MacDiagnostics.log(message)
        #elseif os(iOS)
        AetherPlaybackController.PhoneLogFile.log(message)
        #else
        print(message)
        #endif
    }
}

private extension String {
    var vodNonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

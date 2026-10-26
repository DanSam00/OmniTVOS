import Foundation

/// Collections people have shared on nuvio.tv (nuvio.tv/community-collections),
/// read through the site's own API with the viewer's Nuvio sign-in.
///
/// An entry's `envelope` holds either one collection (`collection`) or a pack
/// of them (`collections`), each in the same JSON as Omni's collections
/// import, so adding one goes through the same merge. The site counts
/// installs with a POST of its own, which this makes too.
enum CommunityCollections {
    static let baseURL = URL(string: "https://nuvio.tv/api/community-collections")!

    /// The signed-in Nuvio account's access token; set by the app at launch.
    @MainActor static var tokenProvider: (() async -> String?)?

    struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let description: String
        let tags: [String]
        let imageURL: URL?
        let likes: Int
        let installs: Int
        let isPack: Bool

        /// Categorised for children: kids, child or family in its tags or
        /// title, or plainly said in its description; never one marked for
        /// adults. Kids profiles are shown only these.
        var isKidFriendly: Bool {
            let everything = ([title, description] + tags).joined(separator: " ")
            guard !CommunityCollections.mentions(CommunityCollections.adultWords, in: everything) else { return false }
            let categorised = ([title] + tags).joined(separator: " ")
            return CommunityCollections.mentions(CommunityCollections.kidWords, in: categorised)
                || CommunityCollections.mentions(CommunityCollections.strongKidWords, in: description)
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case popular, recent
        var id: String { rawValue }
        var label: String { self == .popular ? "Popular" : "Recent" }
    }

    struct Page {
        let items: [Item]
        let hasNextPage: Bool
    }

    enum Failure: LocalizedError {
        case signedOut
        case server(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .signedOut: return "Sign in to your Nuvio account (Settings → Account) to browse community collections."
            case .server(let status): return ServiceErrorText.describe(status: status, service: "nuvio.tv")
            case .unreadable: return "nuvio.tv sent something Omni couldn't read."
            }
        }
    }

    static func list(sort: Sort, search: String = "", page: Int = 1, limit: Int = 24) async throws -> Page {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "view", value: "summary"),
        ]
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { query.append(URLQueryItem(name: "search", value: trimmed)) }
        components.queryItems = query
        let json = try await request(components.url!)
        guard let rows = json["items"] as? [[String: Any]] else { throw Failure.unreadable }
        let pagination = json["pagination"] as? [String: Any]
        return Page(
            items: rows.compactMap(item(from:)),
            hasNextPage: pagination?["hasNextPage"] as? Bool ?? false
        )
    }

    /// The collections an entry adds, in Omni's import JSON.
    static func collections(for item: Item) async throws -> [[String: Any]] {
        let json = try await request(baseURL.appendingPathComponent(item.id))
        let envelope = (json["envelope"] as? [String: Any])
            ?? ((json["item"] as? [String: Any])?["envelope"] as? [String: Any])
        guard let envelope else { throw Failure.unreadable }
        if let pack = envelope["collections"] as? [[String: Any]] { return pack }
        if let single = envelope["collection"] as? [String: Any] { return [single] }
        throw Failure.unreadable
    }

    /// Tells nuvio.tv it was installed, as the site does; best effort.
    static func recordInstall(_ item: Item) async {
        _ = try? await request(baseURL.appendingPathComponent(item.id).appendingPathComponent("install"), method: "POST")
    }

    private static func request(_ url: URL, method: String = "GET") async throws -> [String: Any] {
        guard let token = await tokenProvider?(), !token.isEmpty else { throw Failure.signedOut }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 401 ? Failure.signedOut : Failure.server(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if method == "POST" { return [:] }
            throw Failure.unreadable
        }
        return json
    }

    private static func item(from row: [String: Any]) -> Item? {
        guard let id = row["public_id"] as? String ?? row["id"] as? String else { return nil }
        let envelope = row["envelope"] as? [String: Any]
        let image = [row["thumbnail_url"] as? String, row["image_url"] as? String]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? coverImage(in: envelope)
        return Item(
            id: id,
            title: row["title"] as? String ?? "Untitled",
            description: plainText(row["description"] as? String ?? ""),
            tags: row["tags"] as? [String] ?? [],
            imageURL: image.flatMap { URL(string: $0, relativeTo: URL(string: "https://nuvio.tv")) }?.absoluteURL,
            likes: row["likes_count"] as? Int ?? 0,
            installs: row["installs_count"] as? Int ?? 0,
            isPack: (envelope?["type"] as? String) == "collection_pack"
        )
    }

    /// Descriptions are written in Markdown for the site; shown here as plain
    /// text (headings, emphasis and link syntax removed, links keep their words).
    private static func plainText(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*\*|__|`|~~"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The site's own choice of cover: the envelope's cover image, else the
    /// first collection backdrop or folder art it holds.
    private static func coverImage(in envelope: [String: Any]?) -> String? {
        guard let envelope else { return nil }
        if let cover = (envelope["community"] as? [String: Any])?["coverImageUrl"] as? String, !cover.isEmpty {
            return cover
        }
        let collections = (envelope["collections"] as? [[String: Any]])
            ?? (envelope["collection"] as? [String: Any]).map { [$0] } ?? []
        for collection in collections {
            var candidates = [collection["backdropImageUrl"] as? String]
            for folder in collection["folders"] as? [[String: Any]] ?? [] {
                candidates += ["heroBackdropUrl", "coverImageUrl", "titleLogoUrl", "focusGifUrl"].map { folder[$0] as? String }
            }
            if let found = candidates.compactMap({ $0 }).first(where: { $0.hasPrefix("http") }) { return found }
        }
        return nil
    }

    /// Kids profiles see only the child-friendly ones; others everything, in
    /// the site's order.
    static func ordered(_ items: [Item], forKids: Bool) -> [Item] {
        forKids ? items.filter(\.isKidFriendly) : items
    }

    // MARK: Kids filtering

    static let kidWords = ["kid", "kids", "child", "children", "childrens", "family", "families",
                           "toddler", "toddlers", "preschool", "cartoon", "cartoons", "junior", "nick jr"]
    /// Said in a description, only these mean made for children: "family"
    /// there is as often "something for the whole family" in a general one.
    static let strongKidWords = ["kids", "children", "childrens", "toddler", "toddlers", "preschool", "for kids"]
    static let adultWords = ["horror", "adult", "18", "nsfw", "gore", "erotic", "mature", "xxx", "porn", "slasher"]
    /// TMDB genres: Animation, Family, and TV's Kids.
    private static let kidGenreIDs: Set<String> = ["16", "10751", "10762"]
    /// Children's channels and studios, whose folders say nothing else about
    /// who they are for.
    static let kidBrands = ["nickelodeon", "nicktoons", "nick jr", "disney", "disney channel", "disney junior",
                            "disney xd", "cartoon network", "boomerang", "cartoonito", "pbs kids", "cbeebies",
                            "cbbc", "pixar", "dreamworks", "toon", "toons", "looney tunes", "hanna barbera"]
    /// TMDB networks: Nickelodeon, Nick Jr., Nicktoons, Disney Channel,
    /// Disney Junior, Disney XD, Cartoon Network, Boomerang.
    private static let kidNetworkIDs: Set<String> = ["13", "35", "224", "54", "281", "44", "56", "523"]
    /// A row or folder named for any of these is never a children's one,
    /// whatever else it matches ("Child's Play" is a Chucky film). Anime,
    /// awards and grown-up moods are general libraries, not children's.
    static let kidBlockedWords = adultWords + [
        "reality", "dating", "chucky", "child s play", "thriller", "thrillers", "crime", "killer", "killers",
        "murder", "murders", "war", "zombie", "zombies", "romance", "romantic", "drama", "dramas",
        "tearjerkers", "noir", "gangster", "gangsters", "mafia",
        "anime", "shonen", "seinen", "isekai", "award", "awards", "oscar", "oscars", "golden globes",
        "feel good",
    ]
    /// TMDB genres no children's folder is built from: Horror, Thriller,
    /// Crime, War, Reality, Romance, Talk, War & Politics.
    private static let kidBlockedGenreIDs: Set<String> = ["27", "53", "80", "10752", "10764", "10749", "10767", "10768"]

    /// Whole words or phrases, so "kid" is not found in "kidnap".
    static func mentions(_ words: [String], in text: String) -> Bool {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let joined = " " + tokens.joined(separator: " ") + " "
        return words.contains { joined.contains(" " + $0 + " ") }
    }

    /// One catalog of a folder, as far as the kids rules care: its words,
    /// TMDB genres and network.
    struct KidsSourceTraits {
        var text: String
        var genres: Set<String>
        var networks: Set<String>
    }

    private static func ids(_ value: String?) -> Set<String> {
        Set((value ?? "").components(separatedBy: CharacterSet(charactersIn: ",|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    static func traits(ofRawSource source: [String: Any]) -> KidsSourceTraits {
        let text = ["genre", "catalogId", "catalog_id", "title"].compactMap { source[$0] as? String }.joined(separator: " ")
        let filters = source["filters"] as? [String: Any]
        return KidsSourceTraits(
            text: text,
            genres: ids((filters?["withGenres"] as? String) ?? (filters?["with_genres"] as? String)),
            networks: ids((filters?["withNetworks"] as? String) ?? (filters?["with_networks"] as? String))
        )
    }

    static func traits(of source: NuvioCollectionSource) -> KidsSourceTraits {
        KidsSourceTraits(
            text: [source.genre, source.catalogId, source.title].compactMap { $0 }.joined(separator: " "),
            genres: ids(source.filters?.withGenres),
            networks: ids(source.filters?.withNetworks)
        )
    }

    /// Never for a kids profile: named for something adult, violent or
    /// romantic, or built mostly from genres like Horror, Crime or Reality.
    static func folderIsBlockedForKids(title: String, sources: [KidsSourceTraits]) -> Bool {
        if mentions(kidBlockedWords, in: title) { return true }
        let withGenres = sources.filter { !$0.genres.isEmpty }
        let blocked = withGenres.filter { !$0.genres.isDisjoint(with: kidBlockedGenreIDs) }
        return !withGenres.isEmpty && blocked.count * 2 >= withGenres.count
    }

    /// A folder made for children: named for them or for a children's
    /// channel or studio, or built mostly from children's genres or channels.
    static func folderIsKidFriendly(title: String, sources: [KidsSourceTraits]) -> Bool {
        guard !folderIsBlockedForKids(title: title, sources: sources) else { return false }
        if mentions(kidWords + kidBrands + ["animation", "animated"], in: title) { return true }
        let forKids = sources.filter { source in
            (!source.genres.isDisjoint(with: kidGenreIDs) && source.genres.isDisjoint(with: kidBlockedGenreIDs))
                || !source.networks.isDisjoint(with: kidNetworkIDs)
                || mentions(kidWords + kidBrands, in: source.text)
        }
        return !sources.isEmpty && forKids.count * 2 >= sources.count
    }

    private static func rawSources(_ folder: [String: Any]) -> [KidsSourceTraits] {
        ((folder["sources"] as? [[String: Any]] ?? []) + (folder["catalogSources"] as? [[String: Any]] ?? [])
            + (folder["catalog_sources"] as? [[String: Any]] ?? [])).map(traits(ofRawSource:))
    }

    static func folderIsKidFriendly(_ folder: [String: Any]) -> Bool {
        folderIsKidFriendly(title: folder["title"] as? String ?? "", sources: rawSources(folder))
    }

    /// Made for children by its own name or tags, not just mentioning them in
    /// a description ("Includes … Kids").
    static func entryIsMadeForKids(title: String, tags: [String] = []) -> Bool {
        let text = ([title] + tags).joined(separator: " ")
        return mentions(kidWords, in: text) && !mentions(adultWords, in: text)
    }

    /// What a kids profile gets of these collections: everything of an entry
    /// or row made for children, less any folder that is never for them; of
    /// a general library, only its children's folders. A collection left
    /// empty is dropped.
    static func forKids(_ collections: [[String: Any]], madeForKids entryForKids: Bool = false) -> [[String: Any]] {
        collections.compactMap { collection in
            let folders = collection["folders"] as? [[String: Any]] ?? []
            let name = [collection["title"] as? String, collection["name"] as? String].compactMap { $0 }.joined(separator: " ")
            guard !mentions(kidBlockedWords, in: name) else { return nil }
            let madeForKids = entryForKids || (mentions(kidWords, in: name) && !mentions(adultWords, in: name))
            let kept = madeForKids
                ? folders.filter { !folderIsBlockedForKids(title: $0["title"] as? String ?? "", sources: rawSources($0)) }
                : folders.filter(folderIsKidFriendly)
            guard !kept.isEmpty else { return nil }
            var trimmed = collection
            trimmed["folders"] = kept
            return trimmed
        }
    }

    /// What a kids profile shows of collections it already has: anything
    /// added before these rules, less the folders never for children.
    static func forKidsDisplay(_ collections: [NuvioCollection]) -> [NuvioCollection] {
        collections.compactMap { collection in
            guard !mentions(kidBlockedWords, in: collection.title) else { return nil }
            var trimmed = collection
            trimmed.folders = collection.folders.filter {
                !folderIsBlockedForKids(title: $0.title, sources: $0.sources.map(traits(of:)))
            }
            return trimmed.folders.isEmpty ? nil : trimmed
        }
    }

    /// Adds an entry's collections to the current profile (only the
    /// children's part on a kids profile) and counts the install on the
    /// site. Returns how many collections were added.
    @MainActor
    @discardableResult
    static func install(_ item: Item, forKids: Bool) async throws -> Int {
        var rows = try await collections(for: item)
        if forKids { rows = Self.forKids(rows, madeForKids: entryIsMadeForKids(title: item.title, tags: item.tags)) }
        guard !rows.isEmpty else { return 0 }
        // Adding an entry again brings its rows up to date in place, rather
        // than keeping copies saved before.
        var current = CollectionsStore.rawCollections()
        var fresh: [[String: Any]] = []
        for row in rows {
            if let id = row["id"] as? String, let index = current.firstIndex(where: { ($0["id"] as? String) == id }) {
                current[index] = row
            } else {
                fresh.append(row)
            }
        }
        current += fresh
        CollectionsStore.saveLocalEdit(current)
        await recordInstall(item)
        return rows.count
    }

    // MARK: Chosen at profile creation

    /// Collections picked in Add Profile (id → title), added the first time
    /// the profile is in use, so they go through that profile's own sync.
    static let pendingInstallKey = "omni.collections.pendingInstall"

    static func setPendingInstall(_ picks: [String: String], in store: UserDefaults) {
        guard let data = try? JSONSerialization.data(withJSONObject: picks) else { return }
        store.set(data, forKey: pendingInstallKey)
    }

    /// Adds the current profile's pending picks, once. Returns how many
    /// collections were added.
    @MainActor
    @discardableResult
    static func installPendingIfNeeded() async -> Int {
        let store = ProfileSettings.current
        guard let data = store.data(forKey: pendingInstallKey),
              let picks = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return 0 }
        store.removeObject(forKey: pendingInstallKey)
        let kids = store.bool(forKey: SettingsKey.kidsProfile)
        var added = 0
        for (id, title) in picks {
            let item = Item(id: id, title: title, description: "", tags: [], imageURL: nil, likes: 0, installs: 0, isPack: false)
            added += (try? await install(item, forKids: kids)) ?? 0
        }
        return added
    }

    /// Kids and family collections: the site searched for each of those
    /// words, merged, kept only if child-friendly, most installed first.
    static func kidsAndFamily() async throws -> [Item] {
        var seen = Set<String>()
        var found: [Item] = []
        var lastError: Error?
        for query in ["kids", "family", "children", "child"] {
            do {
                let page = try await list(sort: .popular, search: query, limit: 24)
                for item in page.items where item.isKidFriendly && seen.insert(item.id).inserted {
                    found.append(item)
                }
            } catch {
                lastError = error
            }
        }
        if found.isEmpty, let lastError { throw lastError }
        return found.sorted { $0.installs > $1.installs }
    }

    // MARK: Kids profiles

    /// Set on a kids profile when it is created; the first time it is in use
    /// it gets the kids starter collections, then this is cleared.
    static let kidsSeedPendingKey = "omni.collections.kidsSeedPending"

    /// A new kids profile's Home, in this order: films, cartoons, kids'
    /// streaming and decades; kids and family discovery; studios and
    /// universes; and the children's part of the Mega library (its
    /// channels, genres, film collections and anime).
    static let kidsStarter: [(id: String, title: String)] = [
        ("simple-kids-profile", "Simple Kids Profile"),
        ("kaptain-s-kids-and-family-collection-easy-install-no-addons", "Kaptain's Kids and Family Collection"),
        ("kids", "Kids"),
        ("kaptain-s-mega-collection-v0-4", "Kaptain's Mega Collection"),
    ]

    /// Adds the kids starter collections to the current profile, once, if it
    /// is a new kids profile; the two most popular child-friendly entries if
    /// none of those can be had. Returns how many it added.
    @MainActor
    @discardableResult
    static func seedKidsProfileIfNeeded() async -> Int {
        let store = ProfileSettings.current
        guard store.bool(forKey: kidsSeedPendingKey) else { return 0 }
        var added: [[String: Any]] = []
        var picks = kidsStarter.map {
            Item(id: $0.id, title: $0.title, description: "", tags: [], imageURL: nil, likes: 0, installs: 0, isPack: false)
        }
        var usedStarter = true
        while true {
            for item in picks {
                if let rows = try? await collections(for: item) {
                    added += forKids(rows, madeForKids: entryIsMadeForKids(title: item.title, tags: item.tags))
                    await recordInstall(item)
                }
            }
            guard added.isEmpty, usedStarter, let page = try? await list(sort: .popular, limit: 48) else { break }
            picks = Array(page.items.filter(\.isKidFriendly).prefix(2))
            usedStarter = false
        }
        // Cleared even when nothing suitable was found, so it does not retry forever.
        store.set(false, forKey: kidsSeedPendingKey)
        guard !added.isEmpty else { return 0 }
        var current = CollectionsStore.rawCollections()
        // Entries can share a row id; the first one's row is kept, as two
        // rows with one id break Home.
        var seen = Set(current.compactMap { $0["id"] as? String })
        let fresh = added.filter { ($0["id"] as? String).map { seen.insert($0).inserted } ?? true }
        current += fresh
        CollectionsStore.saveLocalEdit(current)
        return fresh.count
    }
}

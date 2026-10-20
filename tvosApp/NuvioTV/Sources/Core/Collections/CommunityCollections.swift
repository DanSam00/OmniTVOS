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

        /// Looks made for children, from its words alone (kids profiles list
        /// these first).
        var isKidFriendly: Bool {
            let titleText = title.lowercased()
            let text = ([title, description] + tags).joined(separator: " ").lowercased()
            // Made for children, wherever it is said.
            let strong = ["kids", "kid-friendly", "kid friendly", "children", "childrens", "toddler",
                          "preschool", "cartoon", "disney junior", "nick jr", "for kids"]
            // Words a general collection uses for one of its folders ("Family",
            // "Animation"): they only count in the title.
            let titleOnly = ["family", "animated", "animation", "pixar", "disney"]
            let adult = ["horror", "adult", "18+", "nsfw", "thriller", "gore", "erotic", "mature", "anime"]
            guard !adult.contains(where: { text.contains($0) }) else { return false }
            return strong.contains { text.contains($0) } || titleOnly.contains { titleText.contains($0) }
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

    /// Kids profiles see the child-friendly ones first, otherwise in the
    /// site's order.
    static func ordered(_ items: [Item], forKids: Bool) -> [Item] {
        guard forKids else { return items }
        return items.filter(\.isKidFriendly) + items.filter { !$0.isKidFriendly }
    }

    // MARK: Kids profiles

    /// Set on a kids profile when it is created; the first time it is in use
    /// it gets a couple of child-friendly collections, then this is cleared.
    static let kidsSeedPendingKey = "omni.collections.kidsSeedPending"

    /// Adds the two most popular child-friendly collections to the current
    /// profile, once, if it is a new kids profile. Returns how many it added.
    @MainActor
    @discardableResult
    static func seedKidsProfileIfNeeded() async -> Int {
        let store = ProfileSettings.current
        guard store.bool(forKey: kidsSeedPendingKey) else { return 0 }
        guard let page = try? await list(sort: .popular, limit: 48) else { return 0 }
        let picks = page.items.filter(\.isKidFriendly).prefix(2)
        var added: [[String: Any]] = []
        for item in picks {
            if let rows = try? await collections(for: item) {
                added += rows
                await recordInstall(item)
            }
        }
        // Cleared even when nothing suitable was found, so it does not retry forever.
        store.set(false, forKey: kidsSeedPendingKey)
        guard !added.isEmpty else { return 0 }
        var current = CollectionsStore.rawCollections()
        let existing = Set(current.compactMap { $0["id"] as? String })
        current += added.filter { ($0["id"] as? String).map { !existing.contains($0) } ?? true }
        CollectionsStore.saveLocalEdit(current)
        return added.count
    }
}

import Foundation
import SwiftUI

/// What a title's rating and content advisory say: the certificate ("R",
/// "TV-MA") and a line per kind of content that is present, shown over the
/// picture for a few seconds when playback starts.
struct ContentGuide: Codable, Equatable {
    struct Line: Codable, Equatable, Identifiable {
        let category: String
        let severity: String
        var id: String { category }
    }

    var rating: String?
    var lines: [Line]
    /// Where the lines came from: "ddd" (Does the Dog Die) or nil (IMDb).
    /// Its terms ask for "Powered by DoesTheDogDie.com" beside the lines; the
    /// owner chose to leave that off while the app is only for their own use.
    var linesSource: String? = nil

    var isEmpty: Bool { (rating ?? "").isEmpty && lines.isEmpty }
}

enum ContentGuideService {
    private static let storeKey = "omni.contentGuide.v1"
    private static let ttl: TimeInterval = 60 * 24 * 3600
    /// A title with no warnings is asked about again after a week.
    private static let emptyTTL: TimeInterval = 7 * 24 * 3600
    private static let lock = NSLock()
    private static var memory: [String: ContentGuide] = [:]

    private struct Stored: Codable {
        var guide: ContentGuide
        var fetchedAt: Date
    }

    /// The guide for what is about to play: its certificate from the
    /// metadata, and (Omni X) the advisory lines for its IMDb id, kept for
    /// two months.
    static func guide(for meta: NuvioMeta) async -> ContentGuide? {
        var rating = meta.certification?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // Most add-ons (Cinemeta among them) send no certificate: ask TMDB.
        if rating == nil || rating?.uppercased() == "NR" {
            rating = await tmdbRating(for: meta)
        }
        var guide = ContentGuide(rating: rating, lines: [])
        let imdb = imdbID(of: meta)
        let cacheKey = imdb ?? meta.tmdbId.map { "tmdb:\($0)" }
        if let cacheKey, let held = cached(cacheKey) {
            guide.lines = held.lines
            guide.linesSource = held.linesSource
        } else if DoesTheDogDie.apiKey != nil {
            // The viewer's own key: community warnings, kept for two months
            // (a week when there were none, so new votes are picked up).
            if let lines = await DoesTheDogDie.lines(imdb: imdb, tmdb: meta.tmdbId, isSeries: meta.isSeries) {
                guide.lines = lines
                guide.linesSource = "ddd"
                if let cacheKey {
                    remember(ContentGuide(rating: nil, lines: lines, linesSource: "ddd"), for: cacheKey)
                }
            }
        } else if let imdb, let lines = await fetchLines(imdb: imdb) {
            guide.lines = lines
            remember(ContentGuide(rating: nil, lines: lines), for: imdb)
        }
        return guide.isEmpty ? nil : guide
    }

    private static func imdbID(of meta: NuvioMeta) -> String? {
        if let id = meta.imdbId, id.hasPrefix("tt") { return id }
        let first = meta.id.split(separator: ":").first.map(String.init) ?? meta.id
        return first.hasPrefix("tt") ? first : nil
    }

    // MARK: Certificate from TMDB

    nonisolated(unsafe) private static var tmdbRatings: [String: String] = [:]
    private static let englishBoards = ["US", "GB", "AU", "CA", "NZ", "IE"]

    /// The title's certificate from TMDB: the US one, else the viewer's
    /// region's, else another English-language board's. Nil without TMDB
    /// (switched off, no key) or when no board has rated it.
    private static func tmdbRating(for meta: NuvioMeta) async -> String? {
        lock.lock()
        let known = tmdbRatings[meta.id]
        lock.unlock()
        if let known { return known.nilIfEmpty }
        guard let key = TmdbAccountKey.key(),
              let resolved = await TmdbDetailsService.resolveTmdbId(for: meta) else { return nil }
        let isTV = resolved.mediaType == "tv"
        let path = isTV ? "tv/\(resolved.id)/content_ratings" : "movie/\(resolved.id)/release_dates"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(path)?api_key=\(key)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        var byBoard: [String: String] = [:]
        for entry in results {
            guard let country = entry["iso_3166_1"] as? String, byBoard[country] == nil else { continue }
            let candidates: [String] = isTV
                ? [entry["rating"] as? String ?? ""]
                : (entry["release_dates"] as? [[String: Any]] ?? []).map { $0["certification"] as? String ?? "" }
            if let rating = candidates
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty && $0.uppercased() != "NR" }) {
                byBoard[country] = rating
            }
        }
        let order = ["US"] + [Locale.current.region?.identifier].compactMap { $0 } + englishBoards
        let rating = order.lazy.compactMap { byBoard[$0] }.first ?? ""
        lock.lock()
        tmdbRatings[meta.id] = rating
        lock.unlock()
        return rating.nilIfEmpty
    }

    // MARK: Cache

    private static func cached(_ imdb: String) -> ContentGuide? {
        lock.lock(); defer { lock.unlock() }
        if let held = memory[imdb] { return held }
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let map = try? JSONDecoder().decode([String: Stored].self, from: data),
              let stored = map[imdb], Date().timeIntervalSince(stored.fetchedAt) < ttl,
              !stored.guide.lines.isEmpty || Date().timeIntervalSince(stored.fetchedAt) < emptyTTL else { return nil }
        memory[imdb] = stored.guide
        return stored.guide
    }

    private static func remember(_ guide: ContentGuide, for imdb: String) {
        lock.lock(); defer { lock.unlock() }
        memory[imdb] = guide
        var map = UserDefaults.standard.data(forKey: storeKey)
            .flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        map = map.filter { Date().timeIntervalSince($0.value.fetchedAt) < ttl }
        map[imdb] = Stored(guide: guide, fetchedAt: Date())
        if let data = try? JSONEncoder().encode(map) { UserDefaults.standard.set(data, forKey: storeKey) }
    }

    // MARK: Advisory lines

    /// Omni (the public app) takes no advisory text from a site that offers
    /// no API for it: it shows the certificate only. Omni X reads IMDb's
    /// parents' guide page, as best it can; a change to that page just means
    /// no lines are shown.
    private static func fetchLines(imdb: String) async -> [ContentGuide.Line]? {
        #if OMNI_X
        guard let url = URL(string: "https://www.imdb.com/title/\(imdb)/parentalguide/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return parse(html: html)
        #else
        return nil
        #endif
    }

    /// The page embeds its data as JSON in `__NEXT_DATA__`; each advisory is
    /// an object with a `category` and a `severity` (or its votes).
    static func parse(html: String) -> [ContentGuide.Line]? {
        guard let start = html.range(of: "id=\"__NEXT_DATA__\""),
              let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)) else {
            return nil
        }
        var found: [String: String] = [:]
        walk(json) { object in
            guard let category = object["category"] as? [String: Any],
                  let id = (category["id"] as? String) ?? (category["text"] as? String),
                  let severity = severityText(object) else { return }
            found[id.uppercased()] = severity
        }
        let order: [(key: String, label: String)] = [
            ("SEX", "Sex & Nudity"), ("VIOLENCE", "Violence & Gore"), ("PROFANITY", "Profanity"),
            ("ALCOHOL", "Alcohol, Drugs & Smoking"), ("FRIGHTENING", "Frightening & Intense Scenes"),
        ]
        let lines = order.compactMap { item -> ContentGuide.Line? in
            guard let severity = found.first(where: { $0.key.contains(item.key) })?.value,
                  severity.lowercased() != "none" else { return nil }
            return ContentGuide.Line(category: item.label, severity: severity.capitalized)
        }
        return lines.isEmpty ? nil : lines
    }

    private static func severityText(_ object: [String: Any]) -> String? {
        if let severity = object["severity"] as? [String: Any],
           let text = (severity["text"] as? String) ?? (severity["id"] as? String) { return text }
        if let votes = object["severityVotes"] as? [[String: Any]] {
            let best = votes.max { ($0["voteCount"] as? Int ?? 0) < ($1["voteCount"] as? Int ?? 0) }
            return (best?["voteType"] as? String) ?? (best?["text"] as? String)
        }
        return nil
    }

    private static func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let object = node as? [String: Any] {
            visit(object)
            for value in object.values { walk(value, visit) }
        } else if let array = node as? [Any] {
            for value in array { walk(value, visit) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The rating card that writes itself in over the first seconds of
/// playback: the certificate, then one line at a time for each kind of
/// content, then it fades away. Once per start, always.
struct ContentGuideOverlay: View {
    let meta: NuvioMeta
    /// True once the picture is up.
    let playbackStarted: Bool
    var isSuppressed = false

    @State private var guide: ContentGuide?
    @State private var showsCard = false
    @State private var revealed = 0
    @State private var didRun = false

    #if os(iOS)
    private let titleSize: CGFloat = 17, lineSize: CGFloat = 14, pad: CGFloat = 14, gap: CGFloat = 6
    private let outer: CGFloat = 16
    #else
    private let titleSize: CGFloat = 30, lineSize: CGFloat = 24, pad: CGFloat = 26, gap: CGFloat = 10
    private let outer: CGFloat = 70
    #endif

    private var hasRating: Bool { !(guide?.rating ?? "").isEmpty }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if showsCard, let guide, !isSuppressed {
                VStack(alignment: .leading, spacing: gap) {
                    if revealed >= 1, let rating = guide.rating, !rating.isEmpty {
                        Text("Rated \(rating)")
                            .font(.system(size: titleSize, weight: .bold))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    ForEach(Array(guide.lines.enumerated()), id: \.element.id) { index, line in
                        if revealed >= (hasRating ? 1 : 0) + index + 1 {
                            HStack(spacing: 10) {
                                Circle().fill(color(for: line.severity)).frame(width: lineSize * 0.45, height: lineSize * 0.45)
                                Text("\(line.category)").font(.system(size: lineSize, weight: .medium))
                                Text(line.severity).font(.system(size: lineSize, weight: .bold))
                                    .foregroundColor(color(for: line.severity))
                            }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                }
                .foregroundColor(.white)
                .padding(pad)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(outer)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.35), value: revealed)
        .animation(.easeInOut(duration: 0.5), value: showsCard)
        .task(id: meta.id) {
            guard !meta.isLiveContent else { guide = nil; return }
            guide = await ContentGuideService.guide(for: meta)
        }
        .task(id: playbackStarted) {
            guard playbackStarted, !didRun, !meta.isLiveContent else { return }
            // The advisory has had the time the picture took to start; give
            // it a moment more before giving up on it.
            for _ in 0..<8 where guide == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard let guide, !guide.isEmpty else { return }
            didRun = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            showsCard = true
            let total = (hasRating ? 1 : 0) + guide.lines.count
            for step in 1...max(total, 1) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                revealed = step
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            showsCard = false
        }
    }

    private func color(for severity: String) -> Color {
        switch severity.lowercased() {
        case "mild": return Color(red: 0.98, green: 0.84, blue: 0.35)
        case "moderate": return Color(red: 1.0, green: 0.62, blue: 0.2)
        case "severe": return Color(red: 1.0, green: 0.33, blue: 0.3)
        default: return .white.opacity(0.7)
        }
    }
}


// MARK: - Does the Dog Die

/// Community content warnings from DoesTheDogDie.com's API.
///
/// The key is built in: the build scripts fill `OmniContentWarningsKey` in
/// the app's Info.plist from a file kept on the developer's Mac, never in
/// the repo. A build without it (a cloud build) shows the rating only.
///
/// Two requests a title — find it by IMDb (else TMDB) id, then its topic
/// votes — against a free tier of 30 a minute and 5,000 a month shared by
/// every device, so the guide's cache keeps each answer for weeks. A topic
/// counts when at least three people said yes and more said yes than no.
/// Series list each topic many times over (4,877 entries for Breaking Bad);
/// the best-voted copy of each is kept.
enum DoesTheDogDie {
    private static let base = "https://www.doesthedogdie.com/api/v3"
    private static let maxLines = 6
    private static let minimumYes = 3

    static let apiKey: String? = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "OmniContentWarningsKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty || raw.hasPrefix("$(") ? nil : raw
    }()

    /// The title's warning lines; [] when it has none or is not listed; nil
    /// when the API could not be asked (no key, offline, limit reached).
    static func lines(imdb: String?, tmdb: Int?, isSeries: Bool) async -> [ContentGuide.Line]? {
        guard let key = apiKey else { return nil }
        var search = URLComponents(string: "\(base)/items")
        if let imdb {
            search?.queryItems = [URLQueryItem(name: "imdb", value: imdb)]
        } else if let tmdb {
            search?.queryItems = [URLQueryItem(name: "tmdb", value: String(tmdb))]
        } else {
            return nil
        }
        guard let searchURL = search?.url,
              let found = await json(searchURL, key: key) as? [[String: Any]] else { return nil }
        // "Movie" or "TV Show".
        let item = found.first { item in
            let type = ((item["itemTypeName"] as? String) ?? "").lowercased()
            return isSeries ? type.contains("tv") : type.contains("movie")
        } ?? found.first
        guard let item else { return [] }
        guard let id = (item["id"] as? Int) ?? (item["id"] as? String).flatMap(Int.init),
              let detailURL = URL(string: "\(base)/items/\(id)"),
              let detail = await json(detailURL, key: key) as? [String: Any] else { return nil }
        return lines(from: detail["topicItemStats"] as? [[String: Any]] ?? [])
    }

    private static func json(_ url: URL, key: String) async -> Any? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(key, forHTTPHeaderField: "X-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The topics a rating would speak to, by their exact names on the site,
    /// most serious first: the order the lines are shown in.
    private static let topics: [(name: String, label: String)] = [
        ("someone is sexually assaulted", "Sexual assault"),
        ("there is sexual content", "Sexual content"),
        ("there are nude scenes", "Nudity"),
        ("someone uses drugs", "Drug use"),
        ("alcohol abuse", "Alcohol"),
        ("there's blood/gore", "Gore"),
        ("there's gun violence", "Gun violence"),
        ("there's torture", "Torture"),
        ("there's suicide", "Suicide"),
        ("someone self harms", "Self-harm"),
        ("there's domestic violence", "Domestic violence"),
        ("there's child abuse", "Child abuse"),
        ("there is obscene language/gestures", "Strong language"),
        ("there are jump scares", "Jump scares"),
        ("someone smokes or vapes", "Smoking"),
    ]

    static func lines(from stats: [[String: Any]]) -> [ContentGuide.Line] {
        let rankByName = Dictionary(
            topics.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // The best-voted copy of each topic.
        var best: [Int: (yes: Int, no: Int, severity: [String: Any]?)] = [:]
        for stat in stats {
            let name = ((stat["topicName"] as? String) ?? "").lowercased()
            guard let rank = rankByName[name] else { continue }
            let yes = (stat["yesSum"] as? Int) ?? 0
            let no = (stat["noSum"] as? Int) ?? 0
            if let held = best[rank], held.yes >= yes { continue }
            best[rank] = (yes, no, stat["severity"] as? [String: Any])
        }
        return best
            .filter { $0.value.yes >= minimumYes && $0.value.yes > $0.value.no }
            .sorted { $0.key < $1.key }
            .prefix(maxLines)
            .map { ContentGuide.Line(category: topics[$0.key].label, severity: severityText($0.value.severity)) }
    }

    /// The level most voters chose (the reviewer's, when there is one), in
    /// the guide's three words. Each topic has its own scale — drug use runs
    /// Implied, Used, Harmful; suicide talked about, attempted, completed —
    /// so the words are read rather than the position.
    private static func severityText(_ severity: [String: Any]?) -> String {
        guard let severity, let levels = severity["levels"] as? [String], !levels.isEmpty else { return "" }
        let counts = (severity["counts"] as? [Int]) ?? []
        var index: Int?
        if let verified = severity["verified"] as? Int, verified >= 1, verified <= levels.count {
            index = verified - 1
        } else if let top = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[top] > 0 {
            index = top
        }
        guard let index, levels.indices.contains(index) else { return "" }
        switch levels[index].lowercased() {
        case "implied", "mentioned", "talked about", "minor", "threatened", "mild", "incidental",
             "partial", "casual", "verbal":
            return "Mild"
        case "depicted", "used", "groping", "drunk", "crude", "psychological", "attempted",
             "startling", "covered":
            return "Moderate"
        case "harmful", "explicit", "excessive", "brutal", "severe", "completed", "addiction",
             "jarring", "intentional", "abusive", "violent":
            return "Severe"
        default:
            // An unknown word: placed by where it sits on the topic's scale.
            guard levels.count > 1 else { return "" }
            let position = Double(index) / Double(levels.count - 1)
            return position <= 0.34 ? "Mild" : (position >= 0.67 ? "Severe" : "Moderate")
        }
    }
}

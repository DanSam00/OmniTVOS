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

    var isEmpty: Bool { (rating ?? "").isEmpty && lines.isEmpty }
}

enum ContentGuideService {
    private static let storeKey = "omni.contentGuide.v1"
    private static let ttl: TimeInterval = 60 * 24 * 3600
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
        if let imdb = imdbID(of: meta) {
            if let held = cached(imdb) {
                guide.lines = held.lines
            } else if let lines = await fetchLines(imdb: imdb) {
                guide.lines = lines
                remember(ContentGuide(rating: nil, lines: lines), for: imdb)
            }
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
              let stored = map[imdb], Date().timeIntervalSince(stored.fetchedAt) < ttl else { return nil }
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
/// content, then it fades away. Once per start; off in Settings → Playback.
struct ContentGuideOverlay: View {
    let meta: NuvioMeta
    /// True once the picture is up.
    let playbackStarted: Bool
    var isSuppressed = false

    @AppStorage(SettingsKey.contentGuideOnStart) private var enabled = true
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
            guard enabled, !meta.isLiveContent else { guide = nil; return }
            guide = await ContentGuideService.guide(for: meta)
        }
        .task(id: playbackStarted) {
            guard playbackStarted, enabled, !didRun, !meta.isLiveContent else { return }
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

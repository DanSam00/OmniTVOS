import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Art for a match, drawn by the app: "Team A v Team B" as a broadcaster
/// would draw it — each team's colours on its side of a diagonal, its crest
/// large on that side, the competition's badge between them.
///
/// Sports add-ons give a fixture one small 16:9 picture with both crests baked
/// in, which a portrait hero crops and a large one blows up into blocks. Every
/// sports listing whose name reads as two teams ("Juventus vs. Stade Rennais",
/// "New Zealand vs India - 1st T20I") gets this instead, on tiles, heroes, its
/// page and the widgets.
///
/// Drawn on demand: a match's art addresses use the `omni-fixture` scheme,
/// which `FixtureArtURLProtocol` answers by drawing the picture the first time
/// something shows it and keeping it on disk. A catalog of two hundred
/// fixtures costs nothing until one is on screen.
///
/// Crests, colours and league badges come from TheSportsDB's free tier (no
/// account). A team it does not know gets a monogram in a colour from its name.
enum FixtureArtwork {
    static let scheme = "omni-fixture"

    enum Shape: String {
        case portrait = "p"
        case landscape = "l"

        var size: CGSize {
            self == .portrait ? CGSize(width: 1000, height: 1500) : CGSize(width: 1600, height: 900)
        }
    }

    // MARK: Addresses

    /// The listing with the app's art, when it is a match; otherwise as is.
    static func decorated(_ meta: NuvioMeta) -> NuvioMeta {
        guard isMatch(meta),
              let poster = artURL(for: meta, shape: .portrait),
              let background = artURL(for: meta, shape: .landscape) else { return meta }
        // The add-on's logo (its own badge) does not belong over the match.
        return meta.withArtwork(poster: poster, background: background, dropsLogo: true)
    }

    /// A sports listing naming two teams: a "sport" item, or a live one
    /// from a sports add-on ("tv", `nuvio_sport_…`). Never a film or a show,
    /// whatever its name ("Coyote vs. Acme").
    static func isMatch(_ meta: NuvioMeta) -> Bool {
        let type = meta.type.lowercased()
        guard !["movie", "series"].contains(type) else { return false }
        let isSports = type.contains("sport") || meta.id.lowercased().contains("sport")
        return isSports && teams(in: meta.name) != nil
    }

    static func artURL(for meta: NuvioMeta, shape: Shape) -> String? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "art"
        components.path = "/" + shape.rawValue
        components.queryItems = [
            URLQueryItem(name: "t", value: meta.name),
            URLQueryItem(name: "g", value: (meta.genres ?? []).joined(separator: "|")),
            URLQueryItem(name: "v", value: String(designVersion)),
        ]
        return components.url?.absoluteString
    }

    // MARK: Reading the fixture

    /// "Juventus vs. Stade Rennais", "New Zealand vs India - 1st T20I",
    /// "Arsenal v Chelsea", "Lakers @ Celtics", "🔴 LIVE: WTA - Singles:
    /// Katie Boulter vs Viktorija Golubic" → the two teams, and the match's
    /// label from before or after them.
    static func teams(in title: String) -> (home: String, away: String, suffix: String?)? {
        let versus = #"\s(vs\.?|v|@)\s"#
        // A live marker in front ("🔴 LIVE: ") is not part of the match.
        var text = title.replacingOccurrences(
            of: #"^[^\p{L}\p{N}]*(live\s*[:\-–]\s*)?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        var prefix: String?
        // "WTA - Singles: A vs B": the competition before a colon.
        if let colon = text.range(of: ": "),
           text[colon.upperBound...].range(of: versus, options: [.regularExpression, .caseInsensitive]) != nil,
           text[..<colon.lowerBound].range(of: versus, options: [.regularExpression, .caseInsensitive]) == nil {
            prefix = text[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            text = String(text[colon.upperBound...])
        }
        var suffix: String?
        for separator in [" - ", " – ", " — ", " | "] {
            if let range = text.range(of: separator) {
                let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let head = String(text[..<range.lowerBound])
                // Only a tail after the teams, not a hyphen inside one name.
                if head.range(of: versus, options: [.regularExpression, .caseInsensitive]) != nil {
                    text = head
                    suffix = tail.isEmpty ? nil : tail
                    break
                }
            }
        }
        guard let range = text.range(of: versus, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let home = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let away = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !home.isEmpty, !away.isEmpty else { return nil }
        let label = [prefix, suffix].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return (home, away, label.isEmpty ? nil : label)
    }

    /// TheSportsDB's sport for the listing, to pick India's cricket side for a
    /// T20 rather than its football team.
    private static func sportHint(title: String, genres: [String]) -> String? {
        let text = ([title] + genres).joined(separator: " ").lowercased()
        let hints: [(String, String)] = [
            ("cricket", "Cricket"), ("t20", "Cricket"), ("odi", "Cricket"), ("test day", "Cricket"),
            ("nfl", "American Football"), ("american football", "American Football"),
            ("nba", "Basketball"), ("basketball", "Basketball"), ("nhl", "Ice Hockey"), ("hockey", "Ice Hockey"),
            ("mlb", "Baseball"), ("baseball", "Baseball"), ("nrl", "Rugby"), ("rugby", "Rugby"),
            ("afl", "Australian Football"),
            ("football", "Soccer"), ("soccer", "Soccer"), ("premier league", "Soccer"), ("uefa", "Soccer"),
        ]
        return hints.first(where: { text.contains($0.0) })?.1
    }

    // MARK: Drawing

    /// The design's version. Part of every art address, so a new design is a
    /// new address and no image cache keeps showing the old one.
    static let designVersion = 9
    private static var folderName: String { "fixture-art-v\(designVersion)" }

    /// The picture behind an `omni-fixture` address, drawn once and kept.
    @MainActor
    static func imageData(for url: URL) async -> Data? {
        guard url.scheme == scheme,
              let shape = Shape(rawValue: String(url.path.dropFirst())),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let title = query.first(where: { $0.name == "t" })?.value,
              let names = teams(in: title) else { return nil }
        let genres = (query.first(where: { $0.name == "g" })?.value ?? "")
            .split(separator: "|").map(String.init).filter { !$0.isEmpty }

        let file = folder?.appendingPathComponent(
            String(stableHash(title + "|" + genres.joined(separator: "|")), radix: 16) + "-" + shape.rawValue + ".jpg"
        )
        if let file, let data = try? Data(contentsOf: file) { return data }

        let sport = sportHint(title: title, genres: genres)
        async let homeTeam = team(named: names.home, sport: sport)
        async let awayTeam = team(named: names.away, sport: sport)
        let (home, away) = await (homeTeam, awayTeam)
        let badge = await leagueBadge(home: home, away: away, listing: ([title] + genres).joined(separator: " "))
        // The badge stands for the competition; without one, the sport is
        // written instead. A match label ("1st T20I") is kept either way.
        let sportName = genres.first(where: { !$0.contains("-") })
        let label = badge == nil ? [sportName, names.suffix].compactMap { $0 }.joined(separator: " · ") : names.suffix

        let renderer = ImageRenderer(
            content: FixtureArtView(home: home, away: away, badge: badge, label: label?.nilIfEmpty, shape: shape)
                .frame(width: shape.size.width, height: shape.size.height)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = jpeg(image) else { return nil }
        if let file { try? data.write(to: file, options: .atomic) }
        return data
    }

    // MARK: Teams

    private struct Team {
        let name: String
        let crest: CGImage?
        let colour: Color
        let secondColour: Color
        /// The competitions it plays in, as (id, name), main league first.
        let leagues: [(id: String, name: String)]
    }

    private struct TeamRecord {
        let crest: String?
        let colour: String?
        let secondColour: String?
        let leagues: [(id: String, name: String)]
    }

    @MainActor private static var teamCache: [String: TeamRecord] = [:]
    @MainActor private static var leagueBadgeCache: [String: String?] = [:]

    private struct SearchResponse: Decodable {
        struct Team: Decodable {
            let strSport: String?
            let strBadge: String?
            let strColour1: String?
            let strColour2: String?
            let strLeague: String?, idLeague: String?
            let strLeague2: String?, idLeague2: String?
            let strLeague3: String?, idLeague3: String?
            let strLeague4: String?, idLeague4: String?
            let strLeague5: String?, idLeague5: String?
            let strLeague6: String?, idLeague6: String?
            let strLeague7: String?, idLeague7: String?

            var leagues: [(id: String, name: String)] {
                [(idLeague, strLeague), (idLeague2, strLeague2), (idLeague3, strLeague3), (idLeague4, strLeague4),
                 (idLeague5, strLeague5), (idLeague6, strLeague6), (idLeague7, strLeague7)]
                    .compactMap { id, name in
                        guard let id, !id.isEmpty, let name, !name.isEmpty else { return nil }
                        return (id, name)
                    }
            }
        }
        let teams: [Team]?
    }

    @MainActor
    private static func team(named name: String, sport: String?) async -> Team {
        let key = name.lowercased() + "|" + (sport ?? "")
        if teamCache[key] == nil {
            var found = TeamRecord(crest: nil, colour: nil, secondColour: nil, leagues: [])
            var components = URLComponents(string: "https://www.thesportsdb.com/api/v1/json/123/searchteams.php")
            components?.queryItems = [URLQueryItem(name: "t", value: name)]
            if let url = components?.url,
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let teams = (try? JSONDecoder().decode(SearchResponse.self, from: data))?.teams, !teams.isEmpty {
                let pick = teams.first { team in
                    guard let sport, let teamSport = team.strSport else { return false }
                    return teamSport.caseInsensitiveCompare(sport) == .orderedSame
                } ?? (sport == nil ? teams.first : nil)
                found = TeamRecord(
                    crest: pick?.strBadge, colour: pick?.strColour1, secondColour: pick?.strColour2,
                    leagues: pick?.leagues ?? []
                )
            }
            teamCache[key] = found
        }
        let entry = teamCache[key] ?? TeamRecord(crest: nil, colour: nil, secondColour: nil, leagues: [])
        let mainColour = colour(hex: entry.colour) ?? colour(seed: name)
        return Team(
            name: name,
            crest: await image(at: entry.crest),
            colour: mainColour,
            secondColour: colour(hex: entry.secondColour) ?? .white,
            leagues: entry.leagues
        )
    }

    private struct LeagueResponse: Decodable {
        struct League: Decodable { let strBadge: String? }
        let leagues: [League]?
    }

    /// The competition's badge: the league both teams play in (NBA for
    /// Lakers v Warriors, the Europa League for Juventus v Rennes), the one
    /// the listing names when it names one, never a friendly.
    @MainActor
    private static func leagueBadge(home: Team, away: Team, listing: String) async -> CGImage? {
        let awayIds = Set(away.leagues.map(\.id))
        var shared = home.leagues.filter { awayIds.contains($0.id) && !$0.name.lowercased().contains("friendl") }
        if shared.isEmpty, away.crest == nil {
            // Only one side known (a national side, say): its main league.
            shared = Array(home.leagues.prefix(1))
        }
        let lower = listing.lowercased()
        guard let league = shared.first(where: { lower.contains($0.name.lowercased()) }) ?? shared.first else {
            return nil
        }
        if leagueBadgeCache[league.id] == nil {
            var badge: String?
            if let url = URL(string: "https://www.thesportsdb.com/api/v1/json/123/lookupleague.php?id=\(league.id)"),
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                badge = (try? JSONDecoder().decode(LeagueResponse.self, from: data))?.leagues?.first?.strBadge
            }
            leagueBadgeCache[league.id] = badge
        }
        return await image(at: leagueBadgeCache[league.id] ?? nil)
    }

    private static func image(at address: String?) async -> CGImage? {
        guard let address, let url = URL(string: address),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func colour(hex: String?) -> Color? {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private static func colour(seed: String) -> Color {
        Color(hue: Double(stableHash(seed) % 360) / 360, saturation: 0.6, brightness: 0.55)
    }

    // MARK: Storage

    private static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    // MARK: The picture

    /// Two halves split on a slant, each in its team's colour with a band of
    /// its second colour; the crests large on their sides; the competition's
    /// badge between them, smaller than the crests.
    private struct FixtureArtView: View {
        let home: Team
        let away: Team
        let badge: CGImage?
        let label: String?
        let shape: Shape

        private var isPortrait: Bool { shape == .portrait }

        var body: some View {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    half(home, size: size, isFirst: true)
                    half(away, size: size, isFirst: false)
                    seam(size: size)
                    // Light from above, shade below.
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear, .black.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    if isPortrait {
                        // Stacked: home above the seam, away below, the
                        // badge on the seam. All above the lower third, which
                        // a portrait hero covers with its text.
                        let crest = size.width * 0.38
                        crestView(home, size: crest).position(x: size.width / 2, y: size.height * 0.15)
                        centre(badgeSize: crest * 0.46).position(x: size.width / 2, y: size.height * 0.365)
                        crestView(away, size: crest).position(x: size.width / 2, y: size.height * 0.575)
                    } else {
                        // Side by side, the badge on the seam between them —
                        // close enough in that a narrower header cropping
                        // the sides keeps both crests whole.
                        // A little above the middle: a page's title sits
                        // over the art's lower part.
                        let crest = size.height * 0.48
                        let row = size.height * 0.4
                        crestView(home, size: crest).position(x: size.width * 0.3, y: row)
                        centre(badgeSize: crest * 0.5).position(x: size.width / 2, y: row)
                        crestView(away, size: crest).position(x: size.width * 0.7, y: row)
                    }
                }
            }
            .background(Color.black)
        }

        /// The seam's two ends. Landscape: a slant from top to bottom, home on
        /// the left. Portrait: a slant from side to side, home on top.
        private func seamEnds(_ size: CGSize) -> (CGPoint, CGPoint) {
            isPortrait
                ? (CGPoint(x: 0, y: size.height * 0.43), CGPoint(x: size.width, y: size.height * 0.30))
                : (CGPoint(x: size.width * 0.57, y: 0), CGPoint(x: size.width * 0.43, y: size.height))
        }

        private func halfPath(size: CGSize, isFirst: Bool) -> Path {
            Path { path in
                let (start, end) = seamEnds(size)
                let corners: [CGPoint]
                if isPortrait {
                    corners = isFirst
                        ? [.zero, CGPoint(x: size.width, y: 0), end, start]
                        : [start, end, CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
                } else {
                    corners = isFirst
                        ? [.zero, start, end, CGPoint(x: 0, y: size.height)]
                        : [start, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), end]
                }
                path.addLines(corners)
                path.closeSubpath()
            }
        }

        private func half(_ team: Team, size: CGSize, isFirst: Bool) -> some View {
            ZStack {
                team.colour
                // A band of the second colour across the side, running with
                // the seam.
                Rectangle()
                    .fill(team.secondColour.opacity(0.85))
                    .frame(width: max(size.width, size.height) * 1.8, height: min(size.width, size.height) * 0.13)
                    .rotationEffect(.degrees(isPortrait ? -7.5 : -58))
                    .offset(
                        x: isPortrait ? 0 : (isFirst ? -size.width * 0.30 : size.width * 0.30),
                        y: isPortrait ? (isFirst ? -size.height * 0.30 : size.height * 0.36) : 0
                    )
                // Depth: darker towards the outside edge.
                LinearGradient(
                    colors: [.black.opacity(0.35), .clear],
                    startPoint: isPortrait ? (isFirst ? .top : .bottom) : (isFirst ? .leading : .trailing),
                    endPoint: isPortrait ? (isFirst ? .bottom : .top) : (isFirst ? .trailing : .leading)
                )
            }
            .frame(width: size.width, height: size.height)
            .clipShape(halfPath(size: size, isFirst: isFirst))
        }

        private func seam(size: CGSize) -> some View {
            Path { path in
                let (start, end) = seamEnds(size)
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(Color.black.opacity(0.55), lineWidth: isPortrait ? 14 : 16)
            .shadow(color: .black.opacity(0.6), radius: 18)
        }

        private func crestView(_ team: Team, size: CGFloat) -> some View {
            Group {
                if let crest = team.crest {
                    Image(decorative: crest, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: size * 0.06) {
                        Circle()
                            .fill(team.colour)
                            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: size * 0.03))
                            .overlay(
                                Text(Self.monogram(team.name))
                                    .font(.system(size: size * 0.3, weight: .heavy))
                                    .foregroundStyle(.white)
                            )
                            .frame(width: size * 0.78, height: size * 0.78)
                        // No crest to recognise it by: name it.
                        Text(team.name)
                            .font(.system(size: size * 0.11, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.55), radius: size * 0.06, y: size * 0.03)
        }

        /// The competition's badge on a dark plate, or "VS" without one; a
        /// match label under it when there is one.
        private func centre(badgeSize: CGFloat) -> some View {
            VStack(spacing: badgeSize * 0.12) {
                ZStack {
                    RoundedRectangle(cornerRadius: badgeSize * 0.22, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: badgeSize * 0.22, style: .continuous)
                                .stroke(.white.opacity(0.35), lineWidth: 3)
                        )
                    if let badge {
                        Image(decorative: badge, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(badgeSize * 0.14)
                    } else {
                        Text("VS")
                            .font(.system(size: badgeSize * 0.34, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: badgeSize, height: badgeSize)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                if let label {
                    Text(label.uppercased())
                        .font(.system(size: badgeSize * 0.13, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .frame(width: badgeSize * 1.8)
                }
            }
        }

        /// "Stade Rennais" → "SR", "Juventus" → "JUV".
        private static func monogram(_ name: String) -> String {
            let words = name.split(separator: " ").filter { !$0.isEmpty }
            if words.count >= 2 { return words.prefix(3).compactMap(\.first).map(String.init).joined().uppercased() }
            return String(name.prefix(3)).uppercased()
        }
    }
}

/// Answers `omni-fixture` addresses with `FixtureArtwork`'s picture, so the
/// image loaders that use the shared session (and the poster cache, which is
/// given it too) treat match art like any other.
final class FixtureArtURLProtocol: URLProtocol, @unchecked Sendable {
    private var drawing: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == FixtureArtwork.scheme
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        drawing = Task { [weak self] in
            let data = await FixtureArtwork.imageData(for: url)
            guard let self, !Task.isCancelled else { return }
            if let data,
               let response = HTTPURLResponse(
                   url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                   headerFields: ["Content-Type": "image/jpeg", "Content-Length": String(data.count)]
               ) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData))
            }
        }
    }

    override func stopLoading() {
        drawing?.cancel()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import Foundation

/// Whether a title has a real source yet, so a card or a Play button is only
/// offered for something that will actually play.
///
/// "Real" is stricter than what the stream picker lists: the stream has to be
/// playable here, name the title, be the right episode, carry no year outside
/// the title's own, have seeders when it is a torrent that reports them, and
/// not be a cinema copy, a promotion or a paywall placeholder. A new episode
/// that has aired but has no such stream yet stays hidden until one appears.
///
/// Two guards against a namesake — Dark Matter (2024) was "available" a day
/// before its episode aired, through the 2015 series' S02E09:
/// - nothing counts before the release time; a copy of an episode that is not
///   out yet is always some other show's;
/// - when another title shares the name, the release must also name this
///   one's year or the episode's own title (`TitleAmbiguity`).
///
/// Results are kept per profile (each profile has its own add-ons) and saved,
/// so a cold start already knows what was found last time. A found source is
/// trusted for six hours; a missing one is asked again after half an hour,
/// which is how a new episode shows up soon after its first release does.
@MainActor
final class StreamAvailability: ObservableObject {
    static let shared = StreamAvailability()

    /// Posted when any title's answer changes, so rows filtered by it rebuild.
    static let changedNotification = Notification.Name("omni.streamAvailability.changed")

    enum Status { case unknown, checking, available, unavailable, notYetReleased }

    struct Request: Hashable {
        /// `movie` or `series`.
        let type: String
        /// The title id, or `id:season:episode` for an episode.
        let videoId: String
        let title: String
        let year: Int?
        let season: Int?
        let episode: Int?
        /// A series' first year, which a release naming a year must fit.
        var startYear: Int? = nil
        /// The episode's own title, which tells namesakes apart.
        var episodeTitle: String? = nil
        /// When the episode or film comes out; nothing counts before then.
        var releaseDate: Date? = nil

        var key: String { "\(type)|\(videoId)" }

        var isReleased: Bool { releaseDate.map { $0 <= Date() } ?? true }

        /// Out within the last two months, or when unknown.
        var isRecent: Bool { releaseDate.map { Date().timeIntervalSince($0) < 60 * 24 * 3600 } ?? true }

        var baseId: String { String(videoId.split(separator: ":").first ?? "") }

        /// For a Play button before release: "Airs Tomorrow", "Airs 7:00 pm".
        var releaseLabel: String {
            guard let releaseDate, season != nil else {
                return L10n.string("details_no_source_yet", fallback: "Not Available Yet")
            }
            let calendar = Calendar.current
            let when: String
            if calendar.isDateInToday(releaseDate) {
                when = releaseDate.formatted(date: .omitted, time: .shortened)
            } else if calendar.isDateInTomorrow(releaseDate) {
                when = L10n.string("date_tomorrow", fallback: "Tomorrow")
            } else {
                when = releaseDate.formatted(.dateTime.day().month(.abbreviated))
            }
            return L10n.format("details_airs_date", fallback: "Airs %@", when)
        }
    }

    /// Bumped on every change, for views that observe this object.
    @Published private(set) var revision = 0

    private struct Entry: Codable {
        let available: Bool
        let checkedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private var queue: [Request] = []
    private var running = 0
    /// The last set a row asked about, re-checked on a timer while the app runs.
    private var watched: [Request] = []
    private var recheckTask: Task<Void, Never>?

    private static let maxConcurrent = 2
    private static let availableLifetime: TimeInterval = 6 * 3600
    private static let unavailableLifetime: TimeInterval = 30 * 60
    private static let recheckInterval: UInt64 = 10 * 60 * 1_000_000_000

    private init() {
        entries = Self.load()
    }

    // MARK: Requests

    /// The request for a Continue Watching card, or nil when the card is not
    /// one this applies to (live channels, sport, IPTV).
    static func request(for item: ContinueWatchingItem) -> Request? {
        let numbers = item.meta.isSeries ? item.episodeNumbers : nil
        guard var request = request(meta: item.meta, season: numbers?.season, episode: numbers?.episode) else {
            return nil
        }
        // A provider's row may carry no episode guide; its own fields then.
        if request.season != nil {
            request.episodeTitle = request.episodeTitle ?? item.episodeDisplayTitle
            request.releaseDate = request.releaseDate
                ?? EpisodeReleasePolicy.releaseDate(for: item.episodeVideo?.released ?? item.released)
        }
        return request
    }

    nonisolated static func request(meta: NuvioMeta, season: Int?, episode: Int?) -> Request? {
        let type = meta.type.lowercased()
        guard ["movie", "series"].contains(type), !meta.id.hasPrefix("iptv") else { return nil }
        let year = meta.year
            ?? meta.releaseInfo.flatMap { Int($0.prefix(4)) }
            ?? meta.released.flatMap { Int($0.prefix(4)) }
        if type == "series" {
            guard let season, let episode else { return nil }
            let video = meta.videos?.first { $0.season == season && $0.episode == episode }
            let title = video?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isPlaceholder = title.isEmpty || title.caseInsensitiveCompare("TBA") == .orderedSame
                || title.lowercased().hasPrefix("episode ")
            return Request(
                type: "series",
                videoId: "\(meta.id):\(season):\(episode)",
                title: meta.name,
                year: nil,
                season: season,
                episode: episode,
                startYear: year,
                episodeTitle: isPlaceholder ? nil : title,
                releaseDate: EpisodeReleasePolicy.releaseDate(for: video?.released)
            )
        }
        return Request(
            type: "movie", videoId: meta.id, title: meta.name, year: year, season: nil, episode: nil,
            releaseDate: EpisodeReleasePolicy.releaseDate(for: meta.released)
        )
    }

    // MARK: Answers

    func status(_ request: Request) -> Status {
        guard request.isReleased else { return .notYetReleased }
        let key = scopedKey(request)
        if let entry = entries[key] { return entry.available ? .available : .unavailable }
        return inFlight.contains(key) ? .checking : .unknown
    }

    /// Only a source actually found counts; not yet asked is not available.
    func isAvailable(_ request: Request) -> Bool {
        status(request) == .available
    }

    /// Asks about every request without a current answer. Answers arrive
    /// through `changedNotification`.
    func ensureChecked(_ requests: [Request]) {
        watched = requests
        for request in requests where needsCheck(request) {
            enqueue(request)
        }
        pump()
        scheduleRecheck()
    }

    /// Asks now (or waits for the check already running) and returns the
    /// answer. For a Play button, which has one title to decide.
    func check(_ request: Request) async -> Bool {
        if !needsCheck(request) { return isAvailable(request) }
        let key = scopedKey(request)
        if !inFlight.contains(key) {
            queue.removeAll { scopedKey($0) == key }
            await run(request)
        }
        while inFlight.contains(key), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return isAvailable(request)
    }

    // MARK: Checking

    private func needsCheck(_ request: Request) -> Bool {
        guard request.isReleased else { return false }
        let key = scopedKey(request)
        guard !inFlight.contains(key) else { return false }
        guard let entry = entries[key] else { return true }
        let lifetime = entry.available ? Self.availableLifetime : Self.unavailableLifetime
        return Date().timeIntervalSince(entry.checkedAt) > lifetime
    }

    private func enqueue(_ request: Request) {
        let key = scopedKey(request)
        guard !queue.contains(where: { scopedKey($0) == key }) else { return }
        queue.append(request)
    }

    private func pump() {
        while running < Self.maxConcurrent, !queue.isEmpty {
            let request = queue.removeFirst()
            guard needsCheck(request) else { continue }
            running += 1
            Task {
                await run(request)
                running -= 1
                pump()
            }
        }
    }

    private func run(_ request: Request) async {
        let key = scopedKey(request)
        inFlight.insert(key)
        revision &+= 1
        let store = ProfileSettings.current
        let includeDebrid = DebridResolver(store: store).isEnabled
        let cachedOnly = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        let ambiguous = await TitleAmbiguity.answer(for: request).shared
        let found = await StreamsRepository.downloads.hasSource(type: request.type, videoId: request.videoId) {
            Self.isRealSource(
                $0, for: request, includeDebrid: includeDebrid, cachedOnly: cachedOnly, nameIsShared: ambiguous
            )
        }
        inFlight.remove(key)
        let previous = entries[key]?.available
        entries[key] = Entry(available: found, checkedAt: Date())
        save()
        revision &+= 1
        if previous != found {
            NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        }
    }

    private func scheduleRecheck() {
        guard recheckTask == nil else { return }
        recheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.recheckInterval)
                guard let self else { return }
                self.ensureChecked(self.watched)
            }
        }
    }

    private func scopedKey(_ request: Request) -> String {
        "\(ProfileSettings.activeProfileScope)|\(request.key)"
    }

    // MARK: The rule

    /// True when `stream` is a real copy of the requested title.
    /// `nameIsShared`: another title has this name, so the release must also
    /// say which one it is.
    static func isRealSource(
        _ stream: NuvioStream,
        for request: Request,
        includeDebrid: Bool,
        cachedOnly: Bool,
        nameIsShared: Bool = false
    ) -> Bool {
        guard request.isReleased else { return false }
        // Media itself, over HTTP, or a torrent a debrid service will fetch. A
        // link out to another app or page (an add-on's `externalUrl`) is not.
        guard stream.isExternalLink != true else { return false }
        let url = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isMedia = url.hasPrefix("http://") || url.hasPrefix("https://")
        guard isMedia || (includeDebrid && stream.isDebridResolvable) else { return false }
        guard SmartPlaybackSelector.isPlatformPlaybackCompatible(stream),
              !SmartPlaybackSelector.isPromotionalStream(stream),
              !SmartPlaybackSelector.isPaywallPlaceholderStream(stream),
              !SmartPlaybackSelector.isCinemaCopy(stream) else { return false }
        if cachedOnly, !stream.isLikelyCached { return false }

        let text = "\(stream.name ?? "") \(stream.description ?? "") \(stream.filename ?? "")"
        // A torrent nobody is sharing never starts.
        if let seeders = StreamQualityTags.seeders(in: text), seeders == 0 { return false }

        // The right title. Skipped for a title in another script, which the
        // release names transliterate.
        let words = SmartPlaybackSelector.titleWords(request.title)
        if words.allSatisfy({ $0.unicodeScalars.allSatisfy(\.isASCII) }),
           !SmartPlaybackSelector.namesTitle(stream, words: words) {
            return false
        }

        let namesake = nameIsShared ? TitleAmbiguity.cached(for: request) : nil
        let verdict = identity(of: stream, for: request, serviceTags: namesake?.serviceTags ?? [])
        if verdict.contradicts { return false }
        // Another title with this name: the release must say it is this one.
        // Only for something out in the last two months, where a namesake's
        // old copy passes for a new release; long-out titles have their own.
        if nameIsShared, request.isRecent, !verdict.confirms { return false }
        return true
    }

    /// What a release's name says about which title it is.
    struct Identity {
        /// Names another episode, another season's pack, a year outside this
        /// title's, or (for a shared name) another service's tag.
        let contradicts: Bool
        /// Names this title's year, the episode's own title, or the service
        /// it streams on ("ATVP" for an Apple TV+ show).
        let confirms: Bool
    }

    nonisolated static func identity(
        of stream: NuvioStream,
        for request: Request,
        serviceTags: Set<String> = []
    ) -> Identity {
        let text = "\(stream.name ?? "") \(stream.description ?? "") \(stream.filename ?? "")"

        // The right episode: a release naming another one, or another
        // season's pack, is not this episode.
        if let season = request.season, let episode = request.episode {
            if let found = EpisodeTagResolver.episodeNumbers(in: text) {
                if found.season != season || found.episode != episode {
                    return Identity(contradicts: true, confirms: false)
                }
            } else if let pack = seasonPackNumber(in: text), pack != season {
                return Identity(contradicts: true, confirms: false)
            }
        }

        // The right year. A year in the release name (not one in the title
        // itself) has to be the film's, a year either side for festival and
        // regional dates, or inside the show's run: "Dark.Matter.2015" is not
        // the series that began in 2024.
        let titleYears = Set(years(in: request.title))
        let named = years(in: text).filter { !titleYears.contains($0) }
        let knownYear = request.startYear ?? request.year
        let fits: (Int) -> Bool
        if request.season != nil {
            let thisYear = Calendar.current.component(.year, from: Date())
            fits = { year in knownYear.map { ($0 - 1)...(thisYear + 1) ~= year } ?? true }
        } else {
            fits = { year in knownYear.map { abs(year - $0) <= 1 } ?? true }
        }
        if !named.isEmpty, !named.contains(where: fits) {
            return Identity(contradicts: true, confirms: false)
        }

        // The service: another one's tag is another show's release.
        let tokens = Set(text.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        let namedServices = tokens.intersection(TitleAmbiguity.allServiceTags)
        if !serviceTags.isEmpty, !namedServices.isEmpty, namedServices.isDisjoint(with: serviceTags) {
            return Identity(contradicts: true, confirms: false)
        }

        var namesEpisode = false
        if let episodeTitle = request.episodeTitle {
            let words = SmartPlaybackSelector.titleWords(episodeTitle)
            namesEpisode = !words.isEmpty && SmartPlaybackSelector.namesTitle(stream, words: words)
        }
        let namesYear = knownYear != nil && named.contains(where: fits)
        let namesService = !namedServices.isDisjoint(with: serviceTags)
        return Identity(contradicts: false, confirms: namesYear || namesEpisode || namesService)
    }

    nonisolated private static func years(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    /// The season of a whole-season release ("S02", "Season 2"), when named.
    nonisolated private static func seasonPackNumber(in text: String) -> Int? {
        let patterns = [
            #"(?i)(?:^|[^A-Za-z0-9])S(\d{1,2})(?:[^A-Za-z0-9E]|$)"#,
            #"(?i)season[\s._-]*(\d{1,2})(?:[^0-9]|$)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let captured = Range(match.range(at: 1), in: text),
               let season = Int(text[captured]) {
                return season
            }
        }
        return nil
    }

    // MARK: Storage

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            // v2: answers from before the namesake and release-time rules.
            .appendingPathComponent("stream-availability-v2.json")
    }

    private static func load() -> [String: Entry] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        // Anything older than a few days says nothing about now.
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        return decoded.filter { $0.value.checkedAt > cutoff }
    }

    private func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Whether another title of the same type shares this one's name (Cinemeta's
/// search), and, when one does, the service this one streams on (Trakt's
/// public show record, read with the app's client id) — the 2024 Dark Matter
/// is Apple TV+'s, so its releases say "ATVP"; the 2015 one's are Syfy's.
///
/// Answers are kept for a day. A failed lookup counts as not shared, so an
/// outage never hides everything. Read from the stream ranking, which runs
/// off the main actor, hence the lock rather than actor isolation.
enum TitleAmbiguity {
    struct Answer {
        let shared: Bool
        /// Release tags of this title's service; empty when unknown.
        let serviceTags: Set<String>
    }

    nonisolated(unsafe) private static var answers: [String: (answer: Answer, at: Date)] = [:]
    private static let lock = NSLock()
    private static let lifetime: TimeInterval = 24 * 3600

    /// Scene tags for the services, by words in Trakt's network name.
    private static let servicesByNetwork: [(match: String, tags: Set<String>)] = [
        ("apple", ["ATVP"]), ("netflix", ["NF"]), ("amazon", ["AMZN"]), ("prime video", ["AMZN"]),
        ("disney", ["DSNP"]), ("hbo", ["HMAX", "MAX"]), ("max", ["HMAX", "MAX"]), ("hulu", ["HULU"]),
        ("peacock", ["PCOK"]), ("paramount", ["PMTP"]), ("syfy", ["SYFY"]), ("stan", ["STAN"]),
    ]
    static let allServiceTags: Set<String> = servicesByNetwork.reduce(into: []) { $0.formUnion($1.tags) }

    private static func key(_ request: StreamAvailability.Request) -> String {
        request.type + "|" + request.baseId
    }

    /// The answer when already known, without asking.
    static func cached(for request: StreamAvailability.Request) -> Answer? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = answers[key(request)], Date().timeIntervalSince(entry.at) < lifetime else { return nil }
        return entry.answer
    }

    /// Asks in the background, so a later `cached` has it.
    static func prefetch(for request: StreamAvailability.Request) {
        guard cached(for: request) == nil else { return }
        Task { _ = await answer(for: request) }
    }

    private struct SearchResponse: Decodable {
        struct Meta: Decodable {
            let id: String
            let name: String
        }
        let metas: [Meta]?
    }

    private struct ShowRecord: Decodable {
        let network: String?
    }

    static func answer(for request: StreamAvailability.Request) async -> Answer {
        if let known = cached(for: request) { return known }
        let words = SmartPlaybackSelector.titleWords(request.title)

        var components = URLComponents()
        components.scheme = "https"
        components.host = "v3-cinemeta.strem.io"
        components.path = "/catalog/\(request.type)/top/search=\(request.title).json"
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            // Kept ten minutes, so a caller waiting on an answer has one.
            let unknown = Answer(shared: false, serviceTags: [])
            lock.lock()
            answers[key(request)] = (unknown, Date().addingTimeInterval(600 - lifetime))
            lock.unlock()
            return unknown
        }
        let shared = (decoded.metas ?? []).contains { meta in
            meta.id != request.baseId && SmartPlaybackSelector.titleWords(meta.name) == words
        }
        var tags: Set<String> = []
        if shared, request.type == "series", request.baseId.hasPrefix("tt"),
           let network = await network(imdb: request.baseId)?.lowercased() {
            for entry in servicesByNetwork where network.contains(entry.match) {
                tags.formUnion(entry.tags)
            }
        }
        let answer = Answer(shared: shared, serviceTags: tags)
        lock.lock()
        answers[key(request)] = (answer, Date())
        lock.unlock()
        return answer
    }

    private static func network(imdb: String) async -> String? {
        guard let url = URL(string: "\(TraktConfig.apiBaseURL)/shows/\(imdb)?extended=full") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktConfig.builtInClientID, forHTTPHeaderField: "trakt-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(ShowRecord.self, from: data))?.network
    }
}

import Foundation
#if os(iOS) || os(macOS)
import UserNotifications
#endif

/// What Omni last learned about one IPTV subscription: how much it lists,
/// when that was read, and when it runs out (Xtream panels report this).
struct IPTVSourceInfo: Codable, Equatable {
    var channels: Int
    var movies: Int?
    var series: Int?
    var syncedAt: Date
    /// When the subscription ends; nil when the panel gave none (an M3U
    /// link, or an unlimited account).
    var expiresAt: Date?
    var isTrial: Bool?
    /// The panel was asked about the account and answered.
    var accountChecked = false

    /// Whole days until it expires, rounded up so "expires today" is 0 and
    /// something past is negative.
    func daysLeft(now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        let seconds = expiresAt.timeIntervalSince(now)
        return Int((seconds / 86_400).rounded(.up))
    }
}

enum IPTVSourceInfoStore {
    static let changedNotification = Notification.Name("omni.iptv.info.changed")
    private static let key = "omni.iptv.sourceInfo.v1"
    private static let lock = NSLock()

    static func all() -> [String: IPTVSourceInfo] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    static func info(for sourceID: String) -> IPTVSourceInfo? { all()[sourceID] }

    static func update(_ sourceID: String, create: @autoclosure () -> IPTVSourceInfo, _ change: (inout IPTVSourceInfo) -> Void) {
        lock.lock()
        var map = read()
        var value = map[sourceID] ?? create()
        change(&value)
        map[sourceID] = value
        write(map)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func forget(id: String) {
        lock.lock()
        var map = read()
        map[id] = nil
        write(map)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
        Task { await IPTVSourceInfoService.scheduleExpiryReminders() }
    }

    private static func read() -> [String: IPTVSourceInfo] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: IPTVSourceInfo].self, from: data) else { return [:] }
        return map
    }

    private static func write(_ map: [String: IPTVSourceInfo]) {
        if let data = try? JSONEncoder().encode(map) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Keeps `IPTVSourceInfo` current and reminds the viewer before a
/// subscription ends.
enum IPTVSourceInfoService {
    /// How many days ahead the viewer is told, and again the day before.
    static let reminderDays = [3, 1]
    private static let reminderPrefix = "omni.iptv.expiry."

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 20 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: Recording

    /// A playlist was just fetched: note its size, then ask the panel about
    /// the account.
    static func recordPlaylist(_ playlist: IPTVPlaylist, for source: IPTVSource) {
        IPTVSourceInfoStore.update(
            source.id,
            create: IPTVSourceInfo(channels: playlist.channels.count, syncedAt: playlist.fetchedAt)
        ) { info in
            info.channels = playlist.channels.count
            info.syncedAt = playlist.fetchedAt
            if let movies = playlist.movieCount { info.movies = movies }
            if let series = playlist.seriesCount { info.series = series }
        }
        Task {
            await refreshAccount(for: source)
            #if os(macOS)
            // Counting films and shows downloads the panel's whole list, so
            // only the Mac does it on its own, and not more than every few days.
            if let info = IPTVSourceInfoStore.info(for: source.id),
               info.movies == nil || Date().timeIntervalSince(info.syncedAt) > 3 * 86_400 {
                await countCatalog(for: source)
            }
            #endif
        }
    }

    /// Launch: refresh each subscription's end date (one small request each)
    /// and keep the reminders in step.
    static func refreshAll() async {
        for source in IPTVSourceStore.sources() where source.enabled {
            if IPTVSourceInfoStore.info(for: source.id) == nil {
                let cached = IPTVLibrary.shared.cachedChannels(sourceID: source.id)
                if !cached.isEmpty {
                    IPTVSourceInfoStore.update(
                        source.id,
                        create: IPTVSourceInfo(channels: cached.count, syncedAt: Date())
                    ) { _ in }
                }
            }
            await refreshAccount(for: source)
        }
        await scheduleExpiryReminders()
    }

    /// Asks an Xtream panel about the account: end date and trial flag.
    static func refreshAccount(for source: IPTVSource) async {
        guard let login = IPTVGuide.xtreamLogin(for: source),
              var components = URLComponents(string: "\(login.server)/player_api.php") else { return }
        components.queryItems = [
            URLQueryItem(name: "username", value: login.username),
            URLQueryItem(name: "password", value: login.password),
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = json["user_info"] as? [String: Any] else { return }
        let expiry = timestamp(user["exp_date"])
        let trial = (user["is_trial"] as? String).map { $0 == "1" } ?? (user["is_trial"] as? Int).map { $0 == 1 }
        IPTVSourceInfoStore.update(
            source.id,
            create: IPTVSourceInfo(
                channels: IPTVLibrary.shared.cachedChannels(sourceID: source.id).count,
                syncedAt: Date()
            )
        ) { info in
            info.expiresAt = expiry
            info.isTrial = trial
            info.accountChecked = true
        }
        await scheduleExpiryReminders(askPermission: true)
    }

    /// Panels send `exp_date` as a Unix time, as a string or a number; null
    /// or 0 means no end.
    private static func timestamp(_ value: Any?) -> Date? {
        let seconds: Double?
        if let text = value as? String { seconds = Double(text) }
        else if let number = value as? NSNumber { seconds = number.doubleValue }
        else { seconds = nil }
        guard let seconds, seconds > 86_400 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Counts the panel's films and shows by downloading each list to a file
    /// and counting entries, without decoding them (one panel's lists run to
    /// 150 MB). Slow, so it runs on request, and on its own only on the Mac.
    static func countCatalog(for source: IPTVSource) async {
        guard let login = IPTVGuide.xtreamLogin(for: source) else { return }
        async let movies = count(login, action: "get_vod_streams", marker: "\"stream_id\"")
        async let series = count(login, action: "get_series", marker: "\"series_id\"")
        let (movieCount, seriesCount) = await (movies, series)
        guard movieCount != nil || seriesCount != nil else { return }
        IPTVSourceInfoStore.update(
            source.id,
            create: IPTVSourceInfo(
                channels: IPTVLibrary.shared.cachedChannels(sourceID: source.id).count,
                syncedAt: Date()
            )
        ) { info in
            if let movieCount { info.movies = movieCount }
            if let seriesCount { info.series = seriesCount }
            info.syncedAt = Date()
        }
    }

    private static func count(
        _ login: (server: String, username: String, password: String),
        action: String,
        marker: String
    ) async -> Int? {
        guard var components = URLComponents(string: "\(login.server)/player_api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "username", value: login.username),
            URLQueryItem(name: "password", value: login.password),
            URLQueryItem(name: "action", value: action),
        ]
        guard let url = components.url,
              let (file, response) = try? await session.download(from: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        let needle = Data(marker.utf8)
        var total = 0
        var cursor = data.startIndex
        while let hit = data.range(of: needle, in: cursor..<data.endIndex) {
            total += 1
            cursor = hit.upperBound
        }
        return total
    }

    // MARK: Reminders

    /// Replaces the notifications that warn of an ending subscription: one
    /// three days before and one the day before, at 10:00. A subscription
    /// found already inside that window is warned of once, soon.
    static func scheduleExpiryReminders(askPermission: Bool = false) async {
        #if os(iOS) || os(macOS)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(reminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        let names = Dictionary(IPTVSourceStore.sources().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let upcoming = IPTVSourceInfoStore.all().compactMap { id, info -> (String, String, Date)? in
            guard let name = names[id], let end = info.expiresAt, end > Date() else { return nil }
            return (id, name, end)
        }
        guard !upcoming.isEmpty else { return }

        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, askPermission {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let now = Date()
        for (id, name, end) in upcoming {
            var fired = false
            for days in reminderDays {
                guard let day = calendar.date(byAdding: .day, value: -days, to: end),
                      let tenAM = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day),
                      tenAM > now else { continue }
                fired = true
                await add(id: "\(reminderPrefix)\(id).\(days)", name: name, end: end, days: days, fireAt: tenAM, formatter: formatter, center: center)
            }
            // Already inside the last window and nothing left ahead: once, soon.
            if !fired, end.timeIntervalSince(now) > 3600 {
                let days = max(1, Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
                await add(id: "\(reminderPrefix)\(id).now", name: name, end: end, days: days, fireAt: now.addingTimeInterval(60), formatter: formatter, center: center)
            }
        }
        #endif
    }

    #if os(iOS) || os(macOS)
    private static func add(
        id: String, name: String, end: Date, days: Int, fireAt: Date,
        formatter: DateFormatter, center: UNUserNotificationCenter
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "\(name) is about to expire"
        let when = days <= 1 ? "tomorrow" : "in \(days) days"
        content.body = "Your IPTV subscription ends \(when) (\(formatter.string(from: end))). Renew it with your provider to keep watching."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(5, fireAt.timeIntervalSinceNow), repeats: false)
        )
        try? await center.add(request)
    }
    #endif
}

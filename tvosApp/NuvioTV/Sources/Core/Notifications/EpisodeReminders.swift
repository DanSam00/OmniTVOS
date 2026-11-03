#if os(iOS) || os(macOS)
import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import WidgetKit

/// A notification on the morning a followed show's new episode comes out,
/// built from the same release data as the Calendar tab. Opt-in, per device
/// (Settings → Layout → New Episode Alerts). Apple TV has no alerts to show,
/// so it is left out.
///
/// Each alert comes when the episode is out rather than at a fixed hour: at
/// its air time where TVmaze lists one (`EpisodeAirTimes`), else at the time
/// its add-on gives for the release, and only failing both at 9:00 local time
/// that day. If Omni finds a playable source before then, the alert comes
/// at once (`sourceFound`). iOS keeps at most 64 pending notifications per
/// app; the soonest 60 are scheduled and the rest follow on a later refresh.
@MainActor
enum EpisodeReminders {
    private static let idPrefix = "omni.episode."
    private static let maxScheduled = 60
    private static let lookAheadDays = 30
    private static let alertHour = 9
    /// A full refresh fetches every followed show's episode guide; not more
    /// often than this unless the Calendar has just done that work anyway.
    private static let refreshInterval: TimeInterval = 6 * 3600
    private static let lastRefreshKey = "omni.episodeReminders.lastRefresh"
    /// Alerts already given early, so a later schedule does not give them again.
    private static let deliveredKey = "omni.episodeReminders.delivered"

    static var isEnabled: Bool {
        ProfileSettings.current.bool(forKey: SettingsKey.episodeReminders)
    }

    /// Asks for permission when switched on. False when the system refused,
    /// so the setting can switch itself back off.
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { await refresh(force: true) }
        return granted
    }

    static func disable() {
        Task { await removePending(keeping: []) }
    }

    /// At launch and on returning to the app. Loads the followed shows'
    /// guides itself, at most every few hours.
    /// Also keeps the iPhone's Upcoming widget filled when one is on the
    /// Home Screen, alerts or not.
    static func refresh(force: Bool = false) async {
        let feedsWidget = await upcomingWidgetIsInstalled()
        guard isEnabled || feedsWidget else { return }
        // A widget just added has nothing to show yet: fill it now.
        let force = force || (feedsWidget && UpcomingEpisodeFeedStore.read() == nil)
        let defaults = UserDefaults.standard
        if !force, let last = defaults.object(forKey: lastRefreshKey) as? Date,
           Date().timeIntervalSince(last) < refreshInterval {
            return
        }
        defaults.set(Date(), forKey: lastRefreshKey)
        let calendar = CalendarViewModel()
        await calendar.load()
        let entries = calendar.upcomingEpisodes(days: lookAheadDays)
        publishToWidget(entries)
        if isEnabled { await schedule(entries) }
    }

    /// The releases the alerts were last set from, set again as air times arrive.
    private static var scheduledEntries: [CalendarEntry] = []

    /// The Calendar tab has just loaded the same data: use it.
    static func calendarDidLoad(_ calendar: CalendarViewModel) {
        let entries = calendar.upcomingEpisodes(days: lookAheadDays)
        publishToWidget(entries)
        guard isEnabled else { return }
        UserDefaults.standard.set(Date(), forKey: lastRefreshKey)
        Task { await schedule(entries) }
    }

    private static func upcomingWidgetIsInstalled() async -> Bool {
        let configurations = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        return configurations.contains { $0.kind == OmniWidgetKind.upcoming }
    }

    /// The last releases handed to the widget, published again when their
    /// air times arrive.
    private static var widgetEntries: [CalendarEntry] = []
    private static var airTimesObserver: NSObjectProtocol?

    /// Hands the next releases to the Upcoming widget, with their artwork and,
    /// where TVmaze lists one, the exact air time (`EpisodeAirTimes`).
    private static func publishToWidget(_ entries: [CalendarEntry]) {
        let entries = Array(entries.prefix(24))
        widgetEntries = entries
        let airTimes = EpisodeAirTimes.shared
        airTimes.ensureLoaded(imdbIds: entries.filter { !$0.isMovie }.map(\.metaId))
        if airTimesObserver == nil {
            airTimesObserver = NotificationCenter.default.addObserver(
                forName: EpisodeAirTimes.changedNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    publishToWidget(widgetEntries)
                    // An alert set for the day can now be set for the hour.
                    if isEnabled, !scheduledEntries.isEmpty { await schedule(scheduledEntries) }
                }
            }
        }
        let feed = entries.compactMap { entry -> UpcomingEpisodeEntry? in
            guard let day = CalendarDayKey.date(fromDayKey: entry.dayKey) else { return nil }
            var item = UpcomingEpisodeEntry(
                id: entry.id,
                metaId: entry.metaId,
                type: entry.type,
                title: entry.title,
                episodeCode: entry.episodeCode,
                episodeTitle: entry.episodeTitle,
                airDate: Calendar.current.startOfDay(for: day),
                posterURL: entry.posterUrl,
                imageURL: entry.imageUrl ?? entry.backdropUrl
            )
            if !entry.isMovie, let season = entry.season, let episode = entry.episode {
                item.airTime = airTimes.airTime(
                    imdbId: entry.metaId, season: season, episode: episode, listed: day
                )
            }
            return item
        }
        guard UpcomingEpisodeFeedStore.read()?.entries != feed else { return }
        UpcomingEpisodeFeedStore.write(feed)
        WidgetCenter.shared.reloadTimelines(ofKind: OmniWidgetKind.upcoming)
        let sources = feed.flatMap { [$0.posterURL, $0.imageURL].compactMap { $0 } }
        Task {
            if await WidgetArtworkCache.fill(sources) {
                WidgetCenter.shared.reloadTimelines(ofKind: OmniWidgetKind.upcoming)
            }
            WidgetArtworkCache.pruneToFeeds()
        }
    }

    /// When an episode is out: its air time, else the release time its
    /// add-on gives, else nil (the day is all that is known).
    static func releaseTime(of entry: CalendarEntry, airTimes: EpisodeAirTimes) -> Date? {
        let day = CalendarDayKey.date(fromDayKey: entry.dayKey)
        if let season = entry.season, let episode = entry.episode,
           let time = airTimes.airTime(imdbId: entry.metaId, season: season, episode: episode, listed: day) {
            return time
        }
        // A bare date, or midnight UTC (how a date alone is often written),
        // says nothing about the hour.
        guard let raw = entry.released, raw.contains("T"), !raw.contains("T00:00:00"),
              let time = EpisodeReleasePolicy.releaseDate(for: raw),
              let day, Calendar.current.isDate(time, inSameDayAs: day)
                || abs(time.timeIntervalSince(day)) < 36 * 3600 else { return nil }
        return time
    }

    private static func schedule(_ entries: [CalendarEntry]) async {
        scheduledEntries = entries
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let airTimes = EpisodeAirTimes.shared
        airTimes.ensureLoaded(imdbIds: Array(Set(entries.map(\.metaId))))
        let delivered = deliveredIdentifiers()
        let now = Date()
        var requests: [UNNotificationRequest] = []
        for entry in entries {
            guard let day = CalendarDayKey.date(fromDayKey: entry.dayKey),
                  !delivered.contains(idPrefix + entry.id) else { continue }
            let time = releaseTime(of: entry, airTimes: airTimes)
            let fire: Date
            if let time {
                fire = time
            } else {
                var parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
                parts.hour = alertHour
                guard let morning = Calendar.current.date(from: parts) else { continue }
                fire = morning
            }
            guard fire > now else { continue }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            requests.append(UNNotificationRequest(
                identifier: idPrefix + entry.id,
                content: content(for: entry, out: time != nil ? "is out now" : "is out today"),
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            ))
            if requests.count == maxScheduled { break }
        }
        await removePending(keeping: Set(requests.map(\.identifier)))
        for request in requests {
            try? await center.add(request)
        }
    }

    private static func content(for entry: CalendarEntry, out: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = entry.title
        var body = "New episode " + out.replacingOccurrences(of: "is ", with: "")
        if let code = entry.episodeCode {
            body = "\(code)" + (entry.episodeTitle.map { " · \($0)" } ?? "") + " " + out
        }
        content.body = body
        content.sound = .default
        content.threadIdentifier = entry.metaId
        content.userInfo = [
            "id": entry.metaId, "type": entry.type,
            "season": entry.season ?? -1, "episode": entry.episode ?? -1,
        ]
        return content
    }

    /// Omni found a playable source for an episode before its alert was due:
    /// the alert comes now. Only while the app is running, which on the Mac
    /// is often and on the iPhone whenever it is open.
    static func sourceFound(metaId: String, season: Int, episode: Int) {
        guard isEnabled, reportedSources.insert("\(metaId):\(season):\(episode)").inserted else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests().first { request in
                let info = request.content.userInfo
                return request.identifier.hasPrefix(idPrefix)
                    && info["id"] as? String == metaId
                    && info["season"] as? Int == season
                    && info["episode"] as? Int == episode
            }
            guard let pending,
                  let fire = (pending.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                  fire > Date().addingTimeInterval(60) else { return }
            center.removePendingNotificationRequests(withIdentifiers: [pending.identifier])
            markDelivered(pending.identifier)
            guard let content = pending.content.mutableCopy() as? UNMutableNotificationContent else { return }
            content.body = content.body
                .replacingOccurrences(of: " is out today", with: " is out now")
                .replacingOccurrences(of: "out today", with: "out now")
            try? await center.add(UNNotificationRequest(identifier: pending.identifier, content: content, trigger: nil))
        }
    }

    /// Episodes already looked at this launch: the row composes often.
    private static var reportedSources: Set<String> = []

    private static func deliveredIdentifiers() -> Set<String> {
        Set((UserDefaults.standard.dictionary(forKey: deliveredKey) as? [String: Date] ?? [:]).keys)
    }

    private static func markDelivered(_ identifier: String) {
        let cutoff = Date().addingTimeInterval(-Double(lookAheadDays) * 86_400)
        var delivered = (UserDefaults.standard.dictionary(forKey: deliveredKey) as? [String: Date] ?? [:])
            .filter { $0.value > cutoff }
        delivered[identifier] = Date()
        UserDefaults.standard.set(delivered, forKey: deliveredKey)
    }

    private static func removePending(keeping: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(idPrefix) && !keeping.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
    }

    /// Opens the show when its alert is tapped, and lets an alert show while
    /// Omni is in front.
    static func installDelegate() {
        UNUserNotificationCenter.current().delegate = TapHandler.shared
    }

    private final class TapHandler: NSObject, UNUserNotificationCenterDelegate {
        static let shared = TapHandler()

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            let info = response.notification.request.content.userInfo
            guard let id = info["id"] as? String else { return }
            var components = URLComponents()
            components.scheme = "nuvio-tv"
            components.host = "details"
            components.queryItems = [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "type", value: info["type"] as? String ?? "series"),
            ]
            guard let url = components.url else { return }
            await MainActor.run {
                #if os(iOS)
                UIApplication.shared.open(url)
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
        }
    }
}
#endif

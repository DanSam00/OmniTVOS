#if os(iOS) || os(macOS)
import Foundation
import UserNotifications
#if os(iOS)
import UIKit
import WidgetKit
#else
import AppKit
#endif

/// A notification on the morning a followed show's new episode comes out,
/// built from the same release data as the Calendar tab. Opt-in, per device
/// (Settings → Layout → New Episode Alerts). Apple TV has no alerts to show,
/// so it is left out.
///
/// The Calendar knows the release day but not the hour, so each alert is set
/// for 9:00 local time that day. iOS keeps at most 64 pending notifications
/// per app; the soonest 60 are scheduled and the rest follow on a later
/// refresh.
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
        #if os(iOS)
        let feedsWidget = await upcomingWidgetIsInstalled()
        #else
        let feedsWidget = false
        #endif
        guard isEnabled || feedsWidget else { return }
        #if os(iOS)
        // A widget just added has nothing to show yet: fill it now.
        let force = force || (feedsWidget && UpcomingEpisodeFeedStore.read() == nil)
        #endif
        let defaults = UserDefaults.standard
        if !force, let last = defaults.object(forKey: lastRefreshKey) as? Date,
           Date().timeIntervalSince(last) < refreshInterval {
            return
        }
        defaults.set(Date(), forKey: lastRefreshKey)
        let calendar = CalendarViewModel()
        await calendar.load()
        let entries = calendar.upcomingEpisodes(days: lookAheadDays)
        #if os(iOS)
        publishToWidget(entries)
        #endif
        if isEnabled { await schedule(entries) }
    }

    /// The Calendar tab has just loaded the same data: use it.
    static func calendarDidLoad(_ calendar: CalendarViewModel) {
        let entries = calendar.upcomingEpisodes(days: lookAheadDays)
        #if os(iOS)
        publishToWidget(entries)
        #endif
        guard isEnabled else { return }
        UserDefaults.standard.set(Date(), forKey: lastRefreshKey)
        Task { await schedule(entries) }
    }

    #if os(iOS)
    private static func upcomingWidgetIsInstalled() async -> Bool {
        let configurations = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        return configurations.contains { $0.kind == OmniWidgetKind.upcoming }
    }

    /// Hands the next releases to the Upcoming widget, with their artwork.
    private static func publishToWidget(_ entries: [CalendarEntry]) {
        let feed = entries.prefix(24).compactMap { entry -> UpcomingEpisodeEntry? in
            guard let day = CalendarDayKey.date(fromDayKey: entry.dayKey) else { return nil }
            return UpcomingEpisodeEntry(
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
    #endif

    private static func schedule(_ entries: [CalendarEntry]) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let now = Date()
        var requests: [UNNotificationRequest] = []
        for entry in entries {
            guard let day = CalendarDayKey.date(fromDayKey: entry.dayKey) else { continue }
            var parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            parts.hour = alertHour
            guard let fire = Calendar.current.date(from: parts), fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = entry.title
            var body = "New episode out today"
            if let code = entry.episodeCode {
                body = "\(code)" + (entry.episodeTitle.map { " · \($0)" } ?? "") + " is out today"
            }
            content.body = body
            content.sound = .default
            content.threadIdentifier = entry.metaId
            content.userInfo = ["id": entry.metaId, "type": entry.type]
            requests.append(UNNotificationRequest(
                identifier: idPrefix + entry.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            ))
            if requests.count == maxScheduled { break }
        }
        await removePending(keeping: Set(requests.map(\.identifier)))
        for request in requests {
            try? await center.add(request)
        }
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

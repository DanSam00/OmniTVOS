import Foundation
import Combine
#if os(iOS) || os(macOS)
import UserNotifications
#endif

/// "Remind me" on an upcoming match: a notification five minutes before it
/// starts.
///
/// The reminders are a synced setting (`SettingsKey.matchReminders`), so one
/// set on the Apple TV, which has no notifications to show, alerts on the
/// iPhone and Mac signed into the same account. Each of those schedules its
/// own notifications from the list (`sync`) at launch, on returning to the
/// app, and whenever the list changes, including from another device.
@MainActor
final class MatchReminders: ObservableObject {
    struct Reminder: Codable, Equatable {
        let id: String
        let type: String
        let title: String
        let start: Date
    }

    static let shared = MatchReminders()
    static let lead: TimeInterval = 5 * 60
    private static let idPrefix = "omni.match."

    @Published private(set) var reminders: [Reminder] = []
    private var stored = ""
    private var observer: NSObjectProtocol?

    private init() {
        reload()
        // A list pulled from the account, or changed in another window.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in MatchReminders.shared.reloadIfChanged() }
        }
    }

    // MARK: Pages

    /// A live channel or a match: no download or watched state, and an
    /// upcoming one can have a reminder.
    static func isLivePage(_ meta: NuvioMeta) -> Bool {
        let type = meta.type.lowercased()
        return ["tv", "channel", "live", "sport", "sports"].contains(type)
            || meta.id.hasPrefix("iptv:") || meta.id.hasPrefix("iptvch:")
            || meta.isLiveContent
            || FixtureArtwork.isMatch(meta)
    }

    /// When a listing starts, if that is still ahead: its kick-off from
    /// `releaseInfo`. Nil for something already on, or a channel.
    static func upcomingStart(of meta: NuvioMeta) -> Date? {
        guard let info = meta.releaseInfo, let start = FixtureTime.parse(info), start > Date() else { return nil }
        return start
    }

    func isSet(_ id: String) -> Bool { reminders.contains { $0.id == id } }

    /// `start` when the caller knows it already: a Continue Watching match
    /// carries its kick-off.
    func toggle(_ meta: NuvioMeta, start known: Date? = nil) {
        if isSet(meta.id) {
            reminders.removeAll { $0.id == meta.id }
        } else {
            guard let start = known.flatMap({ $0 > Date() ? $0 : nil }) ?? Self.upcomingStart(of: meta) else { return }
            reminders.append(Reminder(id: meta.id, type: meta.type, title: meta.name, start: start))
        }
        save()
        Task { await sync(askPermission: true) }
    }

    // MARK: Storage

    private func reloadIfChanged() {
        let text = ProfileSettings.current.string(forKey: SettingsKey.matchReminders) ?? ""
        guard text != stored else { return }
        reload()
        Task { await sync(askPermission: false) }
    }

    private func reload() {
        stored = ProfileSettings.current.string(forKey: SettingsKey.matchReminders) ?? ""
        let decoded = (try? JSONDecoder().decode([Reminder].self, from: Data(stored.utf8))) ?? []
        // Matches that have been and gone drop off.
        let kept = decoded.filter { $0.start > Date().addingTimeInterval(-6 * 3600) }
        if kept != reminders { reminders = kept }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(reminders), let text = String(data: data, encoding: .utf8) else { return }
        stored = text
        ProfileSettings.current.set(text, forKey: SettingsKey.matchReminders)
    }

    // MARK: Notifications

    /// Schedules this device's notifications from the list, and drops any
    /// for reminders since removed.
    func sync(askPermission: Bool = false) async {
        #if os(iOS) || os(macOS)
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, askPermission, !reminders.isEmpty {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        var wanted: [UNNotificationRequest] = []
        if status == .authorized || status == .provisional {
            let now = Date()
            for reminder in reminders where reminder.start > now {
                // Set inside the last five minutes: right away instead.
                let fire = max(reminder.start.addingTimeInterval(-Self.lead), now.addingTimeInterval(5))
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                let minutes = max(1, Int((reminder.start.timeIntervalSince(fire) / 60).rounded()))
                content.body = minutes == 1 ? "Starts in a minute" : "Starts in \(minutes) minutes"
                content.sound = .default
                content.userInfo = ["id": reminder.id, "type": reminder.type]
                wanted.append(UNNotificationRequest(
                    identifier: Self.idPrefix + reminder.id,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSince(now), repeats: false)
                ))
            }
        }
        // Replaced wholesale: a changed kick-off or a removed reminder is
        // simplest to get right that way.
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for request in wanted {
            try? await center.add(request)
        }
        #endif
    }
}

#if os(iOS) || os(macOS)
import Foundation

/// Handoff between the iPhone and the Mac: while something plays, Omni
/// advertises it, and the other device's Handoff icon opens it there. The
/// receiving side goes through the `continue-watching` deep link, which
/// resumes from Continue Watching (the position arrives by Nuvio Sync) or,
/// before that has caught up, opens the title. Apple TV has no Handoff.
@MainActor
enum WatchingHandoff {
    static let activityType = "com.saminaden.omni.watching"

    private static var activity: NSUserActivity?
    private static var advertisedID: String?

    /// Advertises the title playing, replacing whatever was before.
    static func advertise(meta: NuvioMeta, title: String, subtitle: String) {
        guard advertisedID != meta.id else { return }
        activity?.invalidate()
        let activity = NSUserActivity(activityType: activityType)
        activity.title = subtitle.isEmpty ? title : "\(title) · \(subtitle)"
        activity.userInfo = ["id": meta.id, "type": meta.type]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.becomeCurrent()
        self.activity = activity
        advertisedID = meta.id
    }

    /// Playback ended here: nothing left to hand off.
    static func stop() {
        activity?.invalidate()
        activity = nil
        advertisedID = nil
    }

    /// The deep link for an activity handed over from the other device.
    static func deepLink(for activity: NSUserActivity) -> URL? {
        guard activity.activityType == activityType,
              let id = activity.userInfo?["id"] as? String else { return nil }
        var components = URLComponents()
        components.scheme = "nuvio-tv"
        components.host = "continue-watching"
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "type", value: activity.userInfo?["type"] as? String ?? "movie"),
        ]
        return components.url
    }
}
#endif

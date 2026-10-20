#if os(iOS)
import ActivityKit
import Combine
import Foundation

/// Shows running downloads on the Lock Screen and in the Dynamic Island.
///
/// The card appears when a download starts, follows the one in front, counts
/// the batch ("2 of 5"), and ends a few minutes after the last one finishes.
/// iOS only lets an app start a Live Activity while it is in front, which is
/// when downloads are started anyway. While Omni is suspended the background
/// session carries on without it, so the card catches up whenever iOS wakes
/// Omni or it is opened again.
@MainActor
final class DownloadLiveActivity {
    static let shared = DownloadLiveActivity()

    private typealias State = DownloadActivityAttributes.ContentState
    private static let runningStates: Set<DownloadRecord.State> = [
        .findingSource, .resolving, .queued, .downloading,
    ]
    /// Progress alone updates the card at most this often: Live Activity
    /// updates are budgeted.
    private static let progressInterval: TimeInterval = 3

    private var activity: Activity<DownloadActivityAttributes>?
    private var observer: AnyCancellable?
    /// Every download seen running since the card appeared: the batch count.
    private var batch: Set<String> = []
    private var lastState: State?
    private var lastUpdate = Date.distantPast

    private init() {}

    /// Idempotent: called each time Omni comes to the front.
    func start() {
        guard observer == nil else { return }
        // A card left over from an earlier run: adopt the newest, end the rest.
        let existing = Activity<DownloadActivityAttributes>.activities
        activity = existing.last
        for stale in existing.dropLast() {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        observer = DownloadManager.shared.$records
            .receive(on: RunLoop.main)
            .sink { [weak self] records in self?.recordsChanged(records) }
    }

    private func recordsChanged(_ records: [String: DownloadRecord]) {
        let running = records.values.filter { Self.runningStates.contains($0.state) }
        guard let front = running.max(by: Self.isBehind) else {
            finish(records)
            return
        }
        batch.formUnion(running.map(\.id))
        batch = batch.filter { records[$0] != nil }
        let state = State(
            title: front.meta.name,
            subtitle: Self.subtitle(for: front),
            progress: (front.progress * 100).rounded() / 100,
            completed: batch.filter { records[$0]?.state == .completed }.count,
            total: batch.count,
            isWaitingForWiFi: DownloadManager.shared.isWaitingForWiFi(front),
            isFinished: false
        )
        push(state)
    }

    /// The download shown in front: one actually transferring, then the
    /// furthest along, then the oldest.
    private static func isBehind(_ a: DownloadRecord, _ b: DownloadRecord) -> Bool {
        let aActive = a.state == .downloading, bActive = b.state == .downloading
        if aActive != bActive { return !aActive }
        if a.progress != b.progress { return a.progress < b.progress }
        return a.createdAt > b.createdAt
    }

    private static func subtitle(for record: DownloadRecord) -> String? {
        guard let season = record.season, let episode = record.episode else { return nil }
        let code = "S\(season) · E\(episode)"
        guard let title = record.episodeTitle, !title.isEmpty else { return code }
        return "\(code) · \(title)"
    }

    private func push(_ state: State) {
        guard state != lastState else { return }
        let now = Date()
        if let last = lastState, activity != nil,
           Self.onlyProgressChanged(last, state),
           now.timeIntervalSince(lastUpdate) < Self.progressInterval {
            return
        }
        lastState = state
        lastUpdate = now
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: DownloadActivityAttributes(),
            content: content,
            pushType: nil
        )
    }

    private static func onlyProgressChanged(_ a: State, _ b: State) -> Bool {
        var a = a
        a.progress = b.progress
        return a == b
    }

    /// Nothing running: say how the batch went, then clear the card.
    private func finish(_ records: [String: DownloadRecord]) {
        defer {
            batch = []
            lastState = nil
        }
        guard let activity else { return }
        self.activity = nil
        let done = batch.filter { records[$0]?.state == .completed }.count
        guard done > 0, var final = lastState else {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        final.progress = 1
        final.completed = done
        final.isWaitingForWiFi = false
        final.isFinished = true
        Task {
            await activity.end(
                ActivityContent(state: final, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(10 * 60))
            )
        }
    }
}
#endif

import Foundation
import Network

/// Watch progress and watched marks that could not reach Trakt or Simkl —
/// a downloaded episode watched on a flight, say — kept per profile and sent
/// once the connection is back. Nuvio Sync needs no queue of its own: its
/// ledger keeps unsent rows flagged until the server takes them, so it only
/// needs a push started (`NuvioSyncManager.connectionRestored`).
///
/// Kept in a file rather than UserDefaults: every UserDefaults write starts a
/// Nuvio settings push.
enum OfflinePlaybackSync {
    struct Entry: Codable, Equatable {
        enum Kind: String, Codable { case progress, watched }

        let kind: Kind
        /// `TraktWatchProgressSource` raw value the update was meant for.
        let source: String
        let meta: NuvioMeta
        let season: Int?
        let episode: Int?
        var position: Double
        var duration: Double
        var recordedAt: Date
        var attempts: Int

        var key: String { "\(kind.rawValue)|\(source)|\(meta.id)|\(season ?? -1)|\(episode ?? -1)" }
    }

    /// An update that still fails after this many sends, or this old, is dropped.
    private static let maxAttempts = 5
    private static let maxAge: TimeInterval = 30 * 24 * 3600

    private static let lock = NSLock()

    // MARK: Recording

    /// A progress report that didn't get through. Replaces any earlier one for
    /// the same episode: only the latest position matters.
    static func recordProgress(
        meta: NuvioMeta,
        season: Int?,
        episode: Int?,
        position: Double,
        duration: Double,
        source: TraktWatchProgressSource
    ) {
        guard source != .nuvioSync, position.isFinite, duration.isFinite, duration > 0 else { return }
        upsert(Entry(
            kind: .progress, source: source.rawValue, meta: meta.persistenceSnapshot,
            season: season, episode: episode, position: position, duration: duration,
            recordedAt: Date(), attempts: 0
        ))
    }

    /// A progress report got through: nothing older needs sending.
    static func clearProgress(meta: NuvioMeta, season: Int?, episode: Int?, source: TraktWatchProgressSource) {
        let key = Entry(
            kind: .progress, source: source.rawValue, meta: meta, season: season, episode: episode,
            position: 0, duration: 0, recordedAt: Date(), attempts: 0
        ).key
        mutate { $0.removeAll { $0.key == key } }
    }

    /// A watched mark that didn't get through.
    static func recordWatched(meta: NuvioMeta, season: Int?, episode: Int?, source: TraktWatchProgressSource) {
        guard source != .nuvioSync else { return }
        upsert(Entry(
            kind: .watched, source: source.rawValue, meta: meta.persistenceSnapshot,
            season: season, episode: episode, position: 0, duration: 0,
            recordedAt: Date(), attempts: 0
        ))
    }

    // MARK: Sending

    @MainActor private static var isFlushing = false

    /// Sends what is waiting. Watched marks go first, so a finished episode
    /// is never sent as resume progress after its mark.
    @MainActor
    static func flush() async {
        guard !isFlushing else { return }
        let pending = entries()
        guard !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        let store = ProfileSettings.current
        var sent = 0
        for entry in pending.sorted(by: { ($0.kind == .watched ? 0 : 1, $0.recordedAt) < ($1.kind == .watched ? 0 : 1, $1.recordedAt) }) {
            guard let source = TraktWatchProgressSource(rawValue: entry.source) else {
                remove(entry)
                continue
            }
            let delivered: Bool?
            switch entry.kind {
            case .watched:
                delivered = await sendWatched(entry, source: source, store: store)
            case .progress:
                delivered = await sendProgress(entry, source: source, store: store)
            }
            switch delivered {
            case true?:
                sent += 1
                remove(entry)
            case nil:
                // No longer wanted: the source changed or the title is watched.
                remove(entry)
            case false?:
                mutate { list in
                    guard let index = list.firstIndex(where: { $0.key == entry.key }) else { return }
                    list[index].attempts += 1
                }
            }
        }
        mutate { list in
            list.removeAll { $0.attempts >= maxAttempts || Date().timeIntervalSince($0.recordedAt) > maxAge }
        }
        log("offline.sync sent=\(sent) of \(pending.count) waiting=\(entries().count)")
    }

    /// nil when the update no longer applies.
    @MainActor
    private static func sendWatched(_ entry: Entry, source: TraktWatchProgressSource, store: UserDefaults) async -> Bool? {
        guard RemoteTrackingState.shouldSyncWatchedHistory(to: source, in: store) else { return nil }
        switch source {
        case .trakt:
            return await TraktHistoryService.setWatched(
                entry.meta, season: entry.season, episode: entry.episode, isWatched: true, store: store
            )
        case .simkl:
            return await SimklHistoryService.setWatched(
                entry.meta, season: entry.season, episode: entry.episode, isWatched: true, store: store
            )
        case .nuvioSync:
            return nil
        }
    }

    @MainActor
    private static func sendProgress(_ entry: Entry, source: TraktWatchProgressSource, store: UserDefaults) async -> Bool? {
        guard TraktSettingsStore.watchProgressSource(in: store) == source else { return nil }
        // Finished since: the watched mark covers it, and a resume point at
        // the credits would only put it back in Continue Watching.
        let watched = entry.season.flatMap { season in
            entry.episode.map { WatchedStore.containsEpisode(meta: entry.meta, season: season, episode: $0) }
        } ?? WatchedStore.contains(meta: entry.meta)
        if watched || entry.position / entry.duration >= 0.9 { return nil }
        return await TraktProgressService.reportPlayback(
            meta: entry.meta,
            position: entry.position,
            duration: entry.duration,
            season: entry.season,
            episode: entry.episode,
            action: .pause,
            store: store
        )
    }

    // MARK: Storage

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflinePlaybackSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let profile = ProfileSettings.activeProfileScope
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
        return base.appendingPathComponent("\(profile).json")
    }

    static func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    private static func read() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func mutate(_ change: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var list = read()
        let before = list
        change(&list)
        guard list != before else { return }
        if list.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func upsert(_ entry: Entry) {
        mutate { list in
            list.removeAll { $0.key == entry.key }
            // A watched mark makes waiting progress for the same episode moot.
            if entry.kind == .watched {
                list.removeAll {
                    $0.kind == .progress && $0.meta.id == entry.meta.id
                        && $0.season == entry.season && $0.episode == entry.episode
                }
            }
            list.append(entry)
        }
    }

    private static func remove(_ entry: Entry) {
        mutate { $0.removeAll { $0.key == entry.key } }
    }

    private static func log(_ message: String) {
        #if os(macOS)
        MacDiagnostics.log(message)
        #elseif os(iOS)
        AetherPlaybackController.PhoneLogFile.log(message)
        #else
        print(message)
        #endif
    }
}

/// Posts `restoredNotification` when the device gets a connection back after
/// being without one.
final class ConnectivityMonitor: @unchecked Sendable {
    static let shared = ConnectivityMonitor()
    static let restoredNotification = Notification.Name("omni.connectivity.restored")

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "omni.connectivity")
    private var isStarted = false
    private var wasOffline = false

    func start() {
        queue.async { [self] in
            guard !isStarted else { return }
            isStarted = true
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let offline = path.status != .satisfied
                if self.wasOffline, !offline {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Self.restoredNotification, object: nil)
                    }
                }
                self.wasOffline = offline
            }
            monitor.start(queue: queue)
        }
    }
}

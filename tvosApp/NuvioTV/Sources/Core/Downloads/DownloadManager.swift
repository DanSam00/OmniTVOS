#if os(iOS) || os(macOS)
import Foundation
import Network
import Combine

// Offline viewing, phase 1: one movie at a time, iPhone and Mac. Not on
// Apple TV, which keeps no storage an app can count on — anything saved there
// sits in a cache the system clears when it likes.

// MARK: - Settings

/// The download preferences: the most a movie or an episode may take, and
/// whether mobile data may be used. Kept on this device, out of sync.
enum DownloadSettings {
    /// The sizes the Settings slider steps through, smallest to largest. The
    /// last step is "No limit".
    static let steps: [Int64] = [
        250, 500, 750, 1_024, 1_536, 2_048, 3_072, 4_096, 5_120, 6_144, 8_192,
        10_240, 12_288, 15_360, 20_480, 25_600, 30_720, 40_960, 51_200,
    ].map { Int64($0) * 1_048_576 }

    static let defaultMovieBytes: Int64 = 4_096 * 1_048_576
    static let defaultEpisodeBytes: Int64 = 1_536 * 1_048_576

    /// nil is no limit.
    static func maxMovieBytes(in store: UserDefaults = ProfileSettings.current) -> Int64? {
        limit(store.object(forKey: SettingsKey.downloadMaxMovieBytes), fallback: defaultMovieBytes)
    }

    static func maxEpisodeBytes(in store: UserDefaults = ProfileSettings.current) -> Int64? {
        limit(store.object(forKey: SettingsKey.downloadMaxEpisodeBytes), fallback: defaultEpisodeBytes)
    }

    static func allowsCellular(in store: UserDefaults = ProfileSettings.current) -> Bool {
        #if os(iOS)
        store.bool(forKey: SettingsKey.downloadAllowCellular)
        #else
        true
        #endif
    }

    /// Stored as bytes; 0 is no limit.
    private static func limit(_ stored: Any?, fallback: Int64) -> Int64? {
        let value = (stored as? NSNumber)?.int64Value ?? fallback
        return value > 0 ? value : nil
    }

    static func label(for bytes: Int64?) -> String {
        guard let bytes else { return "No limit" }
        let mb = Double(bytes) / 1_048_576
        if mb < 1_024 { return "\(Int(mb.rounded())) MB" }
        let gb = mb / 1_024
        return gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
    }
}

// MARK: - Choosing a stream

/// Picks what to download from a title's streams. With a limit set, the
/// largest stream at or under it — the closest to the limit; with no limit,
/// the best stream. When the sizes cannot tell (none known, or all over the
/// limit) the user picks.
enum DownloadStreamChooser {
    enum Choice {
        case auto(NuvioStream)
        case ask
    }

    /// A direct file link, or a torrent the debrid provider can turn into
    /// one. Not live streams, nor HLS playlists, which need Apple's separate
    /// downloader.
    static func isDownloadable(_ stream: NuvioStream, debridEnabled: Bool) -> Bool {
        if let raw = stream.url, let url = URL(string: raw) {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
            let path = url.path.lowercased()
            if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") || path.contains("/live/") { return false }
            return true
        }
        return debridEnabled && stream.isDebridResolvable && stream.isCached != false
    }

    /// `streams` in the order the source list shows them, best first.
    static func choose(from streams: [NuvioStream], maxBytes: Int64?, debridEnabled: Bool) -> Choice {
        let candidates = streams.filter { isDownloadable($0, debridEnabled: debridEnabled) }
        guard !candidates.isEmpty else { return .ask }
        let sized = candidates.compactMap { stream in
            StreamBadgeSizing.fileSizeBytes(for: stream).map { (stream, $0) }
        }
        guard let maxBytes else {
            return .auto(candidates[0])
        }
        let fitting = sized.filter { $0.1 <= maxBytes }
        // Closest to the limit; the earlier (better-ranked) one on a tie.
        guard let best = fitting.max(by: { $0.1 < $1.1 }) else { return .ask }
        return .auto(best.0)
    }
}

// MARK: - Records

struct DownloadRecord: Codable, Identifiable {
    enum State: String, Codable {
        case resolving, queued, downloading, paused, completed, failed
    }

    /// "<profile>|<content id>": the content id is the movie's id, or the
    /// episode's video id.
    let id: String
    let contentId: String
    let profileId: String
    let meta: NuvioMeta
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    let stream: NuvioStream
    var sourceURL: String?
    var headers: [String: String]
    var expectedBytes: Int64
    var receivedBytes: Int64
    var state: State
    var errorMessage: String?
    var fileName: String?
    let createdAt: Date

    var progress: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }
}

// MARK: - Manager

/// Downloads to the device through a background URL session, so a download
/// carries on with Omni closed or the phone locked, and keeps the list of
/// downloads in a JSON index beside the files.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    nonisolated static let sessionIdentifier = "com.saminaden.omni.downloads"
    private static let maxConcurrent = 2

    @Published private(set) var records: [String: DownloadRecord] = [:]
    /// The device is on mobile data (or another expensive network) only.
    @Published private(set) var isOnCellularOnly = false

    /// Handed over by the app when iOS wakes it for finished background
    /// work; called once the session has delivered its events.
    var backgroundEventsCompletion: (() -> Void)?

    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Tasks cancelled to pause, so their error is not taken as a failure.
    private var pausing: Set<String> = []
    private let pathMonitor = NWPathMonitor()
    private var lastProgressPublish: [String: Date] = [:]

    private override init() {
        super.init()
        records = Self.loadIndex()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        #if os(iOS)
        config.sessionSendsLaunchEvents = true
        #endif
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        reattachTasks()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let cellularOnly = path.status == .satisfied
                && (path.usesInterfaceType(.cellular) || path.isExpensive)
                && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in self?.isOnCellularOnly = cellularOnly }
        }
        pathMonitor.start(queue: DispatchQueue(label: "omni.downloads.path"))
    }

    // MARK: Queries

    static func key(profileId: String, contentId: String) -> String { "\(profileId)|\(contentId)" }

    private var profileId: String { ProfileSettings.activeProfileScope }

    func record(for contentId: String) -> DownloadRecord? {
        records[Self.key(profileId: profileId, contentId: contentId)]
    }

    /// Downloading but held back: mobile data only, and not allowed.
    func isWaitingForWiFi(_ record: DownloadRecord) -> Bool {
        (record.state == .downloading || record.state == .queued)
            && isOnCellularOnly && !DownloadSettings.allowsCellular()
    }

    func localFileURL(for record: DownloadRecord) -> URL? {
        guard record.state == .completed, let fileName = record.fileName else { return nil }
        let url = Self.directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Bytes the finished downloads take on disk.
    var storageUsed: Int64 {
        records.values.reduce(0) { total, record in
            guard record.state == .completed else { return total }
            return total + record.receivedBytes
        }
    }

    // MARK: Actions

    func start(
        meta: NuvioMeta,
        stream: NuvioStream,
        contentId: String,
        season: Int? = nil,
        episode: Int? = nil,
        episodeTitle: String? = nil
    ) {
        let key = Self.key(profileId: profileId, contentId: contentId)
        if let existing = records[key], existing.state != .failed { return }
        let record = DownloadRecord(
            id: key,
            contentId: contentId,
            profileId: profileId,
            meta: meta,
            season: season,
            episode: episode,
            episodeTitle: episodeTitle,
            stream: stream,
            sourceURL: nil,
            headers: stream.httpHeaders ?? [:],
            expectedBytes: StreamBadgeSizing.fileSizeBytes(for: stream) ?? 0,
            receivedBytes: 0,
            state: .resolving,
            errorMessage: nil,
            fileName: nil,
            createdAt: Date()
        )
        records[key] = record
        saveIndex()
        Task { await resolveAndQueue(key) }
    }

    func pause(_ contentId: String) {
        let key = Self.key(profileId: profileId, contentId: contentId)
        guard let task = tasks[key] else { return }
        pausing.insert(key)
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { Self.writeResumeData(data, for: key) }
                self.tasks[key] = nil
                self.update(key) { $0.state = .paused }
                self.pump()
            }
        }
    }

    func resume(_ contentId: String) {
        let key = Self.key(profileId: profileId, contentId: contentId)
        guard let record = records[key], record.state == .paused || record.state == .failed else { return }
        update(key) {
            $0.state = .queued
            $0.errorMessage = nil
        }
        // A debrid link may have run out while it waited: get a fresh one.
        if record.sourceURL == nil || (record.state == .failed && Self.readResumeData(for: key) == nil) {
            update(key) { $0.state = .resolving }
            Task { await resolveAndQueue(key) }
        } else {
            pump()
        }
    }

    func delete(_ contentId: String) {
        deleteRecord(Self.key(profileId: profileId, contentId: contentId))
    }

    func deleteAll() {
        for key in Array(records.keys) { deleteRecord(key) }
    }

    private func deleteRecord(_ key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
        pausing.remove(key)
        if let fileName = records[key]?.fileName {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(fileName))
        }
        Self.removeResumeData(for: key)
        records[key] = nil
        saveIndex()
        pump()
    }

    // MARK: Engine

    private func resolveAndQueue(_ key: String) async {
        guard let record = records[key] else { return }
        let url: URL?
        if let raw = record.stream.url, let direct = URL(string: raw) {
            url = direct
        } else {
            let result = await DebridResolver(store: ProfileSettings.current).resolvedURL(
                for: record.stream,
                season: record.season,
                episode: record.episode
            )
            if case let .success(resolved, _, _)? = result { url = resolved } else { url = nil }
        }
        guard records[key] != nil else { return }
        guard let url else {
            fail(key, "Couldn't get a download link for this source.")
            return
        }
        update(key) {
            $0.sourceURL = url.absoluteString
            $0.state = .queued
        }
        Self.removeResumeData(for: key)
        pump()
    }

    /// Starts queued downloads up to the limit, oldest first.
    private func pump() {
        let running = tasks.count
        guard running < Self.maxConcurrent else { return }
        let queued = records.values
            .filter { $0.state == .queued && tasks[$0.id] == nil }
            .sorted { $0.createdAt < $1.createdAt }
        for record in queued.prefix(Self.maxConcurrent - running) {
            begin(record)
        }
    }

    private func begin(_ record: DownloadRecord) {
        let key = record.id
        let task: URLSessionDownloadTask
        if let data = Self.readResumeData(for: key) {
            task = session.downloadTask(withResumeData: data)
            Self.removeResumeData(for: key)
        } else {
            guard let raw = record.sourceURL, let url = URL(string: raw) else {
                fail(key, "The download link is missing.")
                return
            }
            if record.expectedBytes > 0, let free = Self.freeSpace(), free < record.expectedBytes {
                fail(key, "Not enough storage for this download.")
                return
            }
            var request = URLRequest(url: url)
            for (field, value) in record.headers { request.setValue(value, forHTTPHeaderField: field) }
            // Held until Wi-Fi when mobile data is not allowed.
            request.allowsCellularAccess = DownloadSettings.allowsCellular()
            request.allowsExpensiveNetworkAccess = DownloadSettings.allowsCellular()
            task = session.downloadTask(with: request)
        }
        task.taskDescription = key
        tasks[key] = task
        update(key) { $0.state = .downloading }
        task.resume()
    }

    private func fail(_ key: String, _ message: String) {
        tasks[key] = nil
        update(key) {
            $0.state = .failed
            $0.errorMessage = message
        }
        pump()
    }

    private func update(_ key: String, save: Bool = true, _ change: (inout DownloadRecord) -> Void) {
        guard var record = records[key] else { return }
        let before = record.state
        change(&record)
        records[key] = record
        if record.state != before {
            Self.log(
                "download.state \(record.contentId) \(before.rawValue)->\(record.state.rawValue)"
                    + " bytes=\(record.receivedBytes)/\(record.expectedBytes)"
                    + (record.errorMessage.map { " error=\($0)" } ?? "")
            )
        }
        if save { saveIndex() }
    }

    nonisolated static func log(_ line: String) {
        #if os(macOS)
        MacDiagnostics.log(line)
        #else
        AetherPlaybackController.PhoneLogFile.log(line)
        #endif
    }

    /// After a relaunch: picks the session's surviving tasks back up, and
    /// re-queues downloads whose task did not survive.
    private func reattachTasks() {
        session.getAllTasks { [weak self] all in
            let pairs = all.compactMap { task -> (String, URLSessionDownloadTask)? in
                guard let download = task as? URLSessionDownloadTask,
                      let key = download.taskDescription else { return nil }
                return (key, download)
            }
            Task { @MainActor in
                guard let self else { return }
                for (key, task) in pairs {
                    if self.records[key] == nil { task.cancel() } else { self.tasks[key] = task }
                }
                for (key, record) in self.records where self.tasks[key] == nil {
                    switch record.state {
                    case .downloading: self.update(key) { $0.state = .queued }
                    case .resolving: Task { await self.resolveAndQueue(key) }
                    default: break
                    }
                }
                self.pump()
            }
        }
    }

    // MARK: Delegate results (main actor)

    fileprivate func progress(_ key: String, written: Int64, expected: Int64) {
        guard records[key] != nil else { return }
        let now = Date()
        // A few updates a second are plenty for a progress ring.
        if let last = lastProgressPublish[key], now.timeIntervalSince(last) < 0.25 { return }
        lastProgressPublish[key] = now
        update(key, save: false) {
            $0.receivedBytes = written
            if expected > 0 { $0.expectedBytes = expected }
            if $0.state != .downloading { $0.state = .downloading }
        }
    }

    fileprivate func finished(_ key: String, fileName: String?, bytes: Int64, error: String?) {
        tasks[key] = nil
        lastProgressPublish[key] = nil
        if let error {
            fail(key, error)
            return
        }
        update(key) {
            $0.state = .completed
            $0.fileName = fileName
            $0.receivedBytes = bytes
            $0.expectedBytes = max($0.expectedBytes, bytes)
        }
        pump()
    }

    fileprivate func ended(_ key: String, error: Error?) {
        guard let error else { return }
        if pausing.remove(key) != nil { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            Self.writeResumeData(data, for: key)
        }
        if nsError.code == NSURLErrorCancelled, records[key] == nil { return }
        fail(key, error.localizedDescription)
    }

    // MARK: Storage

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Omni Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Large and replaceable: kept out of device backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    private static func loadIndex() -> [String: DownloadRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func saveIndex() {
        let list = Array(records.values)
        let url = Self.indexURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func safeName(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.reduce("") { $0 + String($1) }
    }

    private static func resumeURL(for key: String) -> URL {
        directory.appendingPathComponent(safeName(key) + ".resume")
    }

    private static func writeResumeData(_ data: Data, for key: String) {
        try? data.write(to: resumeURL(for: key), options: .atomic)
    }

    private static func readResumeData(for key: String) -> Data? {
        try? Data(contentsOf: resumeURL(for: key))
    }

    private static func removeResumeData(for key: String) {
        try? FileManager.default.removeItem(at: resumeURL(for: key))
    }

    private static func freeSpace() -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - URLSession delegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor in
            self.progress(key, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    /// The file has to be moved before this returns: the system deletes it
    /// straight after.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let key = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // An error page, not the film.
            Task { @MainActor in
                self.finished(key, fileName: nil, bytes: 0, error: "The source refused the download (HTTP \(http.statusCode)).")
            }
            return
        }
        let suggested = downloadTask.response?.suggestedFilename ?? downloadTask.originalRequest?.url?.lastPathComponent ?? ""
        let ext = (suggested as NSString).pathExtension.lowercased()
        let fileName = Self.safeName(key) + "." + (ext.isEmpty ? "mkv" : ext)
        let destination = Self.directory.appendingPathComponent(fileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { @MainActor in self.finished(key, fileName: fileName, bytes: bytes, error: nil) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in self.finished(key, fileName: nil, bytes: 0, error: message) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        Task { @MainActor in self.ended(key, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundEventsCompletion?()
            self.backgroundEventsCompletion = nil
        }
    }
}
#endif

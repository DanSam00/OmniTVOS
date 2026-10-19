import Foundation
import Darwin
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Network buffer sizing

/// libmpv network-cache sizes, driven by Settings → Playback → Network Cache.
/// `forwardBuffer` is how far ahead mpv prefetches ("preload"); `backBuffer`
/// keeps already-played data resident for instant backward seeks. Values are
/// libmpv bytesize strings (e.g. `"128MiB"`).
///
/// Caps are intentionally modest on tvOS. Apple TV often has only 2–4 GB RAM
/// total; demuxer cache + decode surfaces + Metal/Vulkan can jetsam the app
/// (bug type 298 / `per-process-limit`) once a process approaches ~2 GB.
/// Older defaults (Auto ≈ 512 MiB–1 GiB forward alone) filled aggressively on
/// debrid/4K hosts and caused frequent foreground kills during long watches.
/// Readahead window, in seconds, chosen separately for on-demand and live.
///
/// Distinct from `PlaybackCacheSettings`, which caps *bytes*. Seconds express
/// intent ("hold two minutes ahead"); the byte cap still bounds RAM, so a
/// high-bitrate stream simply reaches the cap before the time target.
enum PlaybackBufferSettings {
    /// Offered in Settings. Live tops out lower on purpose: every buffered
    /// second on a live stream is a second further behind the broadcast.
    static let vodChoices = [15, 30, 60, 120, 240]
    static let liveChoices = [5, 10, 20, 30, 60]

    static let vodDefault = 120
    static let liveDefault = 20

    /// Stored value meaning "let the app decide".
    static let autoValue = -1

    /// Rolling count of recent playbacks that stalled waiting for data. Auto
    /// reads it to lengthen the buffer on a connection that has been struggling
    /// and shorten it on one that has not.
    private static let stallScoreKey = "nuvio.tv.playback.bufferAutoStallScore"
    private static let maximumStallScore = 6

    static func seconds(isLive: Bool) -> Int {
        let key = isLive ? SettingsKey.bufferSecondsLive : SettingsKey.bufferSecondsVOD
        let fallback = isLive ? liveDefault : vodDefault
        let stored = ProfileSettings.current.integer(forKey: key)
        if stored == autoValue { return automatic(isLive: isLive) }
        // `integer(forKey:)` returns 0 for an unset key, which is the state a
        // profile starts in — Auto is the default there too.
        guard stored > 0 else { return automatic(isLive: isLive) }
        let allowed = isLive ? liveChoices : vodChoices
        // A value from an older build (or another device) is clamped into the
        // offered range rather than trusted blindly.
        return allowed.contains(stored) ? stored : fallback
    }

    /// Picks a window from what the device can actually observe.
    ///
    /// Two signals, because neither is enough alone. The interface type is
    /// known before playback starts but says nothing about the *source* — a
    /// gigabit Ethernet link to a slow debrid host still stalls. Recent stall
    /// history reflects real throughput but only exists after playing
    /// something. Together: start from the link, then correct for what actually
    /// happened.
    static func automatic(isLive: Bool) -> Int {
        let choices = isLive ? liveChoices : vodChoices
        // Middle of the range for a wired link, one step up for wireless, since
        // Wi-Fi is the more variable of the two.
        var index = PlaybackLinkQuality.isWired ? (choices.count / 2) - 1 : choices.count / 2
        // Each recent stall moves one step longer; a clean run eases back down.
        index += stallScore()
        return choices[min(max(index, 0), choices.count - 1)]
    }

    static func stallScore() -> Int {
        min(max(ProfileSettings.current.integer(forKey: stallScoreKey), 0), maximumStallScore)
    }

    /// Called when playback stalls waiting for the network.
    static func recordStall() {
        ProfileSettings.current.set(min(stallScore() + 1, maximumStallScore), forKey: stallScoreKey)
    }

    /// Called when a playback runs to a reasonable length without stalling, so
    /// a one-off bad night does not lengthen the buffer forever.
    static func recordCleanPlayback() {
        ProfileSettings.current.set(max(stallScore() - 1, 0), forKey: stallScoreKey)
    }
}

/// What kind of link this Apple TV is on. Wired is treated as the steadier of
/// the two; no bandwidth estimate is attempted, since the OS does not offer one
/// and guessing would be worse than the stall history Auto already uses.
enum PlaybackLinkQuality {
    static var isWired: Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let name = String(cString: current.pointee.ifa_name)
            let isUp = (flags & IFF_UP) == IFF_UP && (flags & IFF_LOOPBACK) == 0
            // en0 is Wi-Fi on Apple TV; a wired link appears as a second
            // ethernet interface.
            if isUp, name.hasPrefix("en"), name != "en0" { return true }
            pointer = current.pointee.ifa_next
        }
        return false
    }
}

struct PlaybackCacheSettings {
    let forwardBuffer: String
    let backBuffer: String

    static var current: PlaybackCacheSettings {
        switch ProfileSettings.current.string(forKey: SettingsKey.networkCache) ?? "Auto" {
        case "Small", "Conservative":
            // Minimal readahead — prefer stability over seek/buffer comfort.
            return PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        case "Medium":
            return PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        case "Large":
            // Still well under previous 1 GiB default; enough for bursty hosts.
            return PlaybackCacheSettings(forwardBuffer: "256MiB", backBuffer: "64MiB")
        case "Max":
            // High-RAM Apple TV only. Still capped to limit jetsam risk.
            return PlaybackCacheSettings(forwardBuffer: "512MiB", backBuffer: "96MiB")
        default:
            return auto
        }
    }

    /// Ceiling scaled to total device RAM (`physicalMemory` is bytes).
    /// Prefer staying far below jetsam: demuxer is only one slice of peak RSS.
    /// > 3.5 GB (newer 4K) → 192/48, ~3 GB (common 4K) → 128/32, ≤ 2.5 GB (HD) → 64/16.
    private static var auto: PlaybackCacheSettings {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gib > 3.5 {
            return PlaybackCacheSettings(forwardBuffer: "192MiB", backBuffer: "48MiB")
        } else if gib > 2.5 {
            return PlaybackCacheSettings(forwardBuffer: "128MiB", backBuffer: "32MiB")
        } else {
            return PlaybackCacheSettings(forwardBuffer: "64MiB", backBuffer: "16MiB")
        }
    }
}



// MARK: - Connection speed

/// How fast this device can download on its current connection, for picking
/// a source the connection can actually sustain.
///
/// Estimated per connection type — Wi-Fi, wired, cellular — since each has
/// its own speed. A short test download runs at launch and when the type
/// changes (at most every 30 minutes per type), capped at 5 MB on cellular.
/// Real playback refines it: what the player measured while filling its
/// buffer is folded in when playback ends.
final class ConnectionSpeed: @unchecked Sendable {
    static let shared = ConnectionSpeed()

    enum Kind: String { case wifi, wired, cellular, other }

    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "omni.connection-speed")
    private var currentKind: Kind = .other
    private var started = false
    private var testing = false

    /// The connection type right now.
    var kind: Kind { lock.withLock { currentKind } }

    /// Starts watching the connection; safe to call repeatedly.
    func start() {
        let shouldStart: Bool = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let kind = Self.kind(of: path)
            let changed: Bool = self.lock.withLock {
                defer { self.currentKind = kind }
                return self.currentKind != kind
            }
            if changed || self.isStale(kind) {
                Task.detached(priority: .utility) { await self.test(kind) }
            }
        }
        monitor.start(queue: queue)
    }

    /// Estimated sustainable download speed on the current connection, in
    /// megabits per second; nil before anything has been measured.
    var estimatedMbps: Double? {
        let value = UserDefaults.standard.double(forKey: Self.speedKey(kind))
        return value > 0 ? value : nil
    }

    /// What a stream may use: most of the estimate, leaving headroom for the
    /// connection's dips. Without a measurement, a cautious guess per type.
    var budgetMbps: Double {
        if let measured = estimatedMbps { return measured * 0.7 }
        switch kind {
        case .wired: return 25
        case .wifi: return 15
        case .cellular: return 6
        case .other: return 10
        }
    }

    /// For Settings: the connection and its measured speed.
    var summary: String {
        let name: String
        switch kind {
        case .wifi: name = "Wi-Fi"
        case .wired: name = "Ethernet"
        case .cellular: name = "Cellular (up to 1080p)"
        case .other: name = "this connection"
        }
        guard let mbps = estimatedMbps else { return "\(name), not measured yet" }
        return "\(name), about \(Int(mbps.rounded())) Mbps"
    }

    /// Folds in a speed the player saw while filling its buffer. Players can
    /// only fill as fast as the source serves, so a slow sample may be the
    /// server's fault: it lowers the estimate gently, a fast one raises it.
    func recordPlayback(mbps: Double) {
        guard mbps > 0.5 else { return }
        let key = Self.speedKey(kind)
        let old = UserDefaults.standard.double(forKey: key)
        let blended: Double
        if old <= 0 {
            blended = mbps
        } else if mbps > old {
            blended = old * 0.6 + mbps * 0.4
        } else {
            blended = old * 0.85 + mbps * 0.15
        }
        UserDefaults.standard.set(blended, forKey: key)
    }

    // MARK: Test download

    private static let testURL = "https://speed.cloudflare.com/__down?bytes="
    private static let retestInterval: TimeInterval = 30 * 60

    private func isStale(_ kind: Kind) -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.testedKey(kind))
        return Date().timeIntervalSince1970 - last > Self.retestInterval
    }

    private func test(_ kind: Kind) async {
        let proceed: Bool = lock.withLock {
            guard !testing else { return false }
            testing = true
            return true
        }
        guard proceed else { return }
        defer { lock.withLock { testing = false } }
        // Let the new connection settle before judging it.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard self.kind == kind else { return }
        let cap = kind == .cellular ? 5_000_000 : 25_000_000
        guard let url = URL(string: Self.testURL + String(cap)),
              let mbps = await SpeedProbe.measure(url: url, maxSeconds: 4) else { return }
        let key = Self.speedKey(kind)
        let old = UserDefaults.standard.double(forKey: key)
        UserDefaults.standard.set(old > 0 ? old * 0.5 + mbps * 0.5 : mbps, forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.testedKey(kind))
    }

    private static func kind(of path: NWPath) -> Kind {
        guard path.status == .satisfied else { return .other }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }

    private static func speedKey(_ kind: Kind) -> String { "omni.connectionSpeed.mbps.\(kind.rawValue)" }
    private static func testedKey(_ kind: Kind) -> String { "omni.connectionSpeed.tested.\(kind.rawValue)" }
}

/// Times one capped download: bytes received over the time from the first
/// byte to the last, so connection setup isn't counted as slowness.
private final class SpeedProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var bytes = 0
    private var firstByte: Date?
    private var lastByte: Date?
    private var continuation: CheckedContinuation<Double?, Never>?
    private let lock = NSLock()

    static func measure(url: URL, maxSeconds: TimeInterval) async -> Double? {
        let probe = SpeedProbe()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        return await withCheckedContinuation { continuation in
            probe.lock.withLock { probe.continuation = continuation }
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + maxSeconds) {
                task.cancel()
                probe.finish()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            let now = Date()
            if firstByte == nil { firstByte = now }
            lastByte = now
            bytes += data.count
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish() {
        let (continuation, result): (CheckedContinuation<Double?, Never>?, Double?) = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            guard let first = firstByte, let last = lastByte, bytes > 200_000 else { return (pending, nil) }
            let seconds = max(last.timeIntervalSince(first), 0.05)
            return (pending, Double(bytes) * 8 / seconds / 1_000_000)
        }
        continuation?.resume(returning: result)
    }
}

/// The "Auto" stream quality: the best resolution whose stream this
/// connection can sustain. A stream's bitrate comes from its file size and the
/// title's runtime; without both, a typical bitrate for its resolution.
enum AutoStreamQuality {
    static let preference = "Auto"

    struct Plan {
        /// Highest resolution worth playing, and whether to favour small files.
        let maxResolution: Int
        let budgetMbps: Double
        let preferSmaller: Bool
    }

    static func plan() -> Plan {
        let speed = ConnectionSpeed.shared
        let cellular = speed.kind == .cellular
        // Cellular stops at 1080p however fast it is, and leans to the
        // smaller file of equal quality, to go easy on data.
        return Plan(
            maxResolution: min(cellular ? 1080 : 4320, deviceMaxResolution),
            budgetMbps: speed.budgetMbps,
            preferSmaller: cellular
        )
    }

    /// The most this device can show. A phone screen gains nothing from 4K
    /// over 1080p but the data and the decoding; the simulator decodes in
    /// software and stutters on 4K; an Apple TV goes to 4K only on a 4K
    /// display.
    static var deviceMaxResolution: Int {
        #if targetEnvironment(simulator)
        return 1080
        #elseif os(iOS)
        return 1080
        #elseif os(tvOS)
        let screen = UIScreen.main.nativeBounds.size
        let display = max(screen.width, screen.height) >= 3840 ? 2160 : 1080
        return min(display, AppleTVCapability.current.maxResolution)
        #else
        return 2160
        #endif
    }

    static func bitrateMbps(sizeBytes: Int64, resolution: Int, runtimeMinutes: Int?) -> Double {
        if sizeBytes > 0, let minutes = runtimeMinutes, minutes > 0 {
            return Double(sizeBytes) * 8 / Double(minutes * 60) / 1_000_000
        }
        switch resolution {
        case 2160...: return 20
        case 1440..<2160: return 12
        case 1080..<1440: return 8
        case 720..<1080: return 4
        default: return 2.5
        }
    }

    /// Minutes from a runtime like "120 min", "1h 45m" or "45".
    static func runtimeMinutes(_ text: String?) -> Int? {
        guard let text = text?.lowercased(), !text.isEmpty else { return nil }
        let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        guard let first = numbers.first else { return nil }
        if text.contains("h"), numbers.count >= 2 { return first * 60 + numbers[1] }
        if text.contains("h") { return first * 60 }
        return first
    }
}

/// Smart play becomes the default: Play starts the best source for the
/// connection, with the full list a long-press away. Applied once per
/// profile, since the old defaults (off, "Highest") were stored and synced.
enum SmartPlayDefaults {
    private static let flag = "omni.smartPlay.autoDefault.v1"

    static func applyIfNeeded(store: UserDefaults = ProfileSettings.current) {
        guard !store.bool(forKey: flag) else { return }
        store.set(true, forKey: flag)
        store.set(true, forKey: SettingsKey.smartStreamSelection)
        store.set(AutoStreamQuality.preference, forKey: SettingsKey.smartStreamQuality)
    }
}

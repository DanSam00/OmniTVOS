import Foundation
import Darwin

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


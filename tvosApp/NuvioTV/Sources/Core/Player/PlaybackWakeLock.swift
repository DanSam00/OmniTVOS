import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// `AVAudioSession` category and activation changes can block while the system
/// reconfigures audio routes. Keep them off the main actor so a preview or
/// player start never stalls SwiftUI focus and animation work.
enum PlaybackAudioSession {
    private static let queue = DispatchQueue(label: "tv.nuvio.audio-session")

    static func activateMoviePlayback() {
        // macOS has no AVAudioSession: routing, category and activation are all
        // handled by the system, so there is nothing to configure here.
        #if os(macOS)
        return
        #else
        queue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                #if os(tvOS)
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
                #else
                try session.setCategory(.playback, mode: .moviePlayback)
                #endif
                try session.setActive(true)
            } catch {
                print("[PlaybackAudioSession] activate failed: \(error.localizedDescription)")
            }
        }
        #endif
    }
}

/// Keeps Apple TV awake for the full player session.
///
/// Custom MPV Metal rendering is not treated as "system video playback" the way
/// a system video controller is, so tvOS can still honor Settings → General →
/// Sleep After (often 15–30 minutes) unless the app explicitly disables the
/// idle timer. Status-based toggling was too fragile: brief non-playing states
/// re-enabled sleep while video continued.
///
/// Hold this for the entire `PlayerView` lifetime (including pause/buffering),
/// and reassert periodically in case the system or another UI path clears it.
@MainActor
enum PlaybackWakeLock {
    private static var holdCount = 0
    private static var reassertTimer: Timer?

    /// Begin preventing sleep. Nested acquires are reference-counted.
    static func acquire() {
        holdCount += 1
        apply(disabled: true)
        activateAudioSession()
        startReassertTimerIfNeeded()
    }

    /// End preventing sleep when the last holder releases.
    static func release() {
        holdCount = max(0, holdCount - 1)
        if holdCount == 0 {
            reassertTimer?.invalidate()
            reassertTimer = nil
            apply(disabled: false)
        }
    }

    /// Force the idle timer off while a hold is active (safe to call often).
    static func reassert() {
        guard holdCount > 0 else { return }
        apply(disabled: true)
    }

    private static func apply(disabled: Bool) {
        #if os(macOS)
        // No idle timer on macOS — display sleep is held off with an IOKit
        // power assertion instead. See `MacIdleSleep`.
        MacIdleSleep.setPrevented(disabled)
        #else
        if UIApplication.shared.isIdleTimerDisabled != disabled {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
        #endif
    }

    private static func startReassertTimerIfNeeded() {
        guard reassertTimer == nil else { return }
        // Sleep After is typically 15+ minutes; reassert well before that so a
        // cleared flag cannot accumulate idle time toward system sleep.
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                reassert()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reassertTimer = timer
    }

    private static func activateAudioSession() {
        PlaybackAudioSession.activateMoviePlayback()
    }
}

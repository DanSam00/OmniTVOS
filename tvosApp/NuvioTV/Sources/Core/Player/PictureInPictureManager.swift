import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import AVKit
import AVFoundation
import Combine
import AetherEngine

/// Context required to restore the full-screen player UI from a floating PiP window.
struct ActivePlaybackContext: Equatable {
    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let httpHeaders: [String: String]
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    let episodes: [NuvioVideo]
    let currentEpisode: NuvioVideo?
    let autoPlayNextEnabled: Bool
    let autoPlayNextCountdownSeconds: Int
    let playbackOrigin: PlaybackOrigin

    init(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String] = [:],
        externalSubtitles: [NuvioSubtitle] = [],
        resumeFrom: Double? = nil,
        episodes: [NuvioVideo] = [],
        currentEpisode: NuvioVideo? = nil,
        autoPlayNextEnabled: Bool = true,
        autoPlayNextCountdownSeconds: Int = 10,
        playbackOrigin: PlaybackOrigin = .main
    ) {
        self.url = url
        self.meta = meta
        self.subtitle = subtitle
        self.httpHeaders = httpHeaders
        self.externalSubtitles = externalSubtitles
        self.resumeFrom = resumeFrom
        self.episodes = episodes
        self.currentEpisode = currentEpisode
        self.autoPlayNextEnabled = autoPlayNextEnabled
        self.autoPlayNextCountdownSeconds = autoPlayNextCountdownSeconds
        self.playbackOrigin = playbackOrigin
    }
}

/// AVKit's own account of what Picture in Picture did.
///
/// On macOS it joins the app log beside the player traces, which is where the
/// rest of a PiP problem is visible; on tvOS it stays on the console, as it was.
private func pipLog(_ line: String) {
    #if os(macOS)
    MacDiagnostics.log("pip.avkit " + line)
    #else
    print("[PictureInPicture] " + line)
    #endif
}

/// Central Picture-in-Picture manager for tvOS.
/// Bridges `AVPictureInPictureController` with `AetherEngine` (native AVPlayerLayer & sample-buffer paths).
@MainActor
final class PictureInPictureManager: NSObject, ObservableObject {
    static let shared = PictureInPictureManager()

    @Published private(set) var isPictureInPictureActive: Bool = false
    @Published private(set) var isPictureInPicturePossible: Bool = false

    var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    private(set) var pipController: AVPictureInPictureController?
    private(set) var activeCoordinator: PlaybackSessionCoordinator?
    private(set) var activeAetherController: AetherPlaybackController?
    private(set) var activeContext: ActivePlaybackContext?

    private var possibleObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var isRestoringUI = false
    private var pendingRestoreCompletion: ((Bool) -> Void)?
    private var pendingRestoreResult: Bool?
    private var restoreSurfaceReady = false
    private weak var configuredSoftwareDisplayLayer: CALayer?

    var isRestoringUIInProgress: Bool { isRestoringUI }

    /// Invoked when PiP begins so the active full-screen PlayerView can dismiss to the background.
    var onDidStartPiP: (() -> Void)?

    #if os(macOS)
    /// True while the mini player was opened by the app losing focus, so a PiP
    /// the viewer opened by hand is not closed out from under them on return.
    private var startedAutomatically = false
    private var focusObserver: NSObjectProtocol?

    /// Open the mini player because the app lost focus, and arm the return.
    ///
    /// Owned here rather than by `PlayerViewModel` because starting PiP
    /// unmounts the full-screen player, which takes that view model with it:
    /// its `didBecomeActive` observer then held a nil `self` and the film
    /// stayed in the mini player forever. This object is a singleton and
    /// outlives the transition, which is the whole requirement.
    func startAutomatically() {
        guard !isPictureInPictureActive else { return }
        startedAutomatically = true
        observeReturnToForeground()
        startPictureInPicture()
        // AVKit starts asynchronously and may refuse. Do not leave the flag
        // set if it never began — it would swallow the next real restore.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.startedAutomatically, !self.isPictureInPictureActive else { return }
            pipLog("auto start never became active")
            self.startedAutomatically = false
        }
    }

    /// The viewer opened or closed PiP themselves; the app no longer owns it.
    func forgetAutomaticStart() {
        startedAutomatically = false
    }

    private func observeReturnToForeground() {
        guard focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                pipLog("focus returned auto=\(self.startedAutomatically) active=\(self.isPictureInPictureActive)")
                guard self.startedAutomatically else { return }
                self.startedAutomatically = false
                self.stopPictureInPicture()
            }
        }
    }
    #endif

    /// Invoked when PiP is closed by the user (via X button) without restoring full-screen UI.
    var onDidStopPiPWithoutRestoring: (() -> Void)?

    /// Invoked when the user clicks the expand / restore button on the system PiP window.
    var onRestoreUI: ((ActivePlaybackContext, @escaping (Bool) -> Void) -> Void)?

    override private init() {
        super.init()
    }

    // MARK: - Session Registration

    /// Registers the currently active playback session with the PiP manager.
    func registerSession(
        coordinator: PlaybackSessionCoordinator,
        context: ActivePlaybackContext
    ) {
        self.activeCoordinator = coordinator
        self.activeContext = context

        setupPipController(for: coordinator.aetherController)
    }

    /// Sets up or reconfigures the `AVPictureInPictureController` for the given Aether controller.
    func setupPipController(for aetherController: AetherPlaybackController) {
        let controllerChanged = activeAetherController !== aetherController
        self.activeAetherController = aetherController
        if controllerChanged {
            configuredSoftwareDisplayLayer = nil
        }
        guard isPictureInPictureSupported else { return }

        cancellables.removeAll()

        // Observe software PiP source changes (for software decode path)
        aetherController.engine.$softwarePiPSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildPipControllerIfNeeded()
            }
            .store(in: &cancellables)

        // Observe playback phase changes to rebuild when layer is mounted
        aetherController.engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildPipControllerIfNeeded()
            }
            .store(in: &cancellables)

        rebuildPipControllerIfNeeded()
    }

    private func rebuildPipControllerIfNeeded() {
        guard isPictureInPictureSupported, let controller = activeAetherController else { return }
        guard !isPictureInPictureActive else { return } // Don't disrupt active PiP window

        let engine = controller.engine

        if let nativeLayer = engine.nativePlayerLayer {
            configuredSoftwareDisplayLayer = nil
            if let existing = pipController, existing.playerLayer === nativeLayer {
                return
            }
            possibleObservation?.invalidate()
            let pip = AVPictureInPictureController(playerLayer: nativeLayer)
            pip?.delegate = self
            self.pipController = pip
            bindPossibleObservation(pip)
        } else if #available(tvOS 15.0, macOS 12.0, *), let swSource = engine.softwarePiPSource {
            if configuredSoftwareDisplayLayer === swSource.layer, pipController != nil {
                return
            }
            possibleObservation?.invalidate()
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: swSource.layer,
                playbackDelegate: self
            )
            let pip = AVPictureInPictureController(contentSource: contentSource)
            pip.delegate = self
            self.pipController = pip
            configuredSoftwareDisplayLayer = swSource.layer
            bindPossibleObservation(pip)
        }
    }

    private func bindPossibleObservation(_ pip: AVPictureInPictureController?) {
        guard let pip else {
            isPictureInPicturePossible = false
            return
        }
        isPictureInPicturePossible = pip.isPictureInPicturePossible
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            Task { @MainActor [weak self] in
                guard let self, self.pipController === controller else { return }
                self.isPictureInPicturePossible = controller.isPictureInPicturePossible
            }
        }
    }

    // MARK: - Actions

    func startPictureInPicture() {
        guard isPictureInPictureSupported else { return }
        rebuildPipControllerIfNeeded()

        guard let pip = pipController else {
            pipLog("Cannot start: no AVPictureInPictureController instance")
            return
        }

        pipLog("Requesting startPictureInPicture (isPossible=\(pip.isPictureInPicturePossible))")
        pip.startPictureInPicture()
    }

    func stopPictureInPicture() {
        guard isPictureInPictureActive else { return }
        pipController?.stopPictureInPicture()
    }

    func togglePictureInPicture() {
        if isPictureInPictureActive {
            stopPictureInPicture()
        } else {
            startPictureInPicture()
        }
    }

    /// Stops playback and clears the active session state.
    func invalidateSession() {
        let retainedCoordinator = activeCoordinator
        let oldPipController = pipController
        let restoreCompletion = pendingRestoreCompletion
        // Clear the identity before stopping AVKit. A stop callback can be
        // delivered synchronously, and callbacks from this old controller
        // must not mutate a subsequently registered session.
        pipController = nil
        oldPipController?.delegate = nil
        possibleObservation?.invalidate()
        possibleObservation = nil
        cancellables.removeAll()
        if isPictureInPictureActive {
            oldPipController?.stopPictureInPicture()
        }
        retainedCoordinator?.aetherController.engine.pictureInPictureActive = false
        retainedCoordinator?.stopAll()
        activeCoordinator = nil
        activeAetherController = nil
        activeContext = nil
        isPictureInPictureActive = false
        isPictureInPicturePossible = false
        isRestoringUI = false
        pendingRestoreCompletion = nil
        pendingRestoreResult = nil
        restoreSurfaceReady = false
        configuredSoftwareDisplayLayer = nil
        restoreCompletion?(false)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PictureInPictureManager: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        pipLog("willStartPictureInPicture")
        activeAetherController?.engine.pictureInPictureActive = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        pipLog("didStartPictureInPicture")
        isPictureInPictureActive = true
        activeAetherController?.engine.pictureInPictureActive = true
        onDidStartPiP?()
        #if os(macOS)
        // Temporary: the PiP window shows one magnified corner of the picture
        // over black, and reading the code has not settled who sizes the layer
        // once AVKit has it. This states the geometry outright, a second in.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let layer = self?.activeAetherController?.engine.softwarePiPSource?.layer else {
                MacDiagnostics.log("pip.geom no software layer (native path)")
                return
            }
            let superlayer = layer.superlayer
            MacDiagnostics.log(String(
                format: "pip.geom layer.frame=%.0fx%.0f@%.0f,%.0f bounds=%.0fx%.0f gravity=%@ "
                    + "mask=%lu super=%@ super.bounds=%.0fx%.0f",
                layer.frame.width, layer.frame.height, layer.frame.origin.x, layer.frame.origin.y,
                layer.bounds.width, layer.bounds.height,
                layer.videoGravity.rawValue,
                UInt(layer.autoresizingMask.rawValue),
                superlayer.map { String(describing: type(of: $0)) } ?? "none",
                superlayer?.bounds.width ?? 0, superlayer?.bounds.height ?? 0))
        }
        #endif
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard pipController === pictureInPictureController else { return }
        pipLog("failedToStartPictureInPictureWithError: \(error.localizedDescription)")
        isPictureInPictureActive = false
        activeAetherController?.engine.pictureInPictureActive = false
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        pipLog("willStopPictureInPicture (isRestoringUI=\(isRestoringUI))")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        pipLog("didStopPictureInPicture (isRestoringUI=\(isRestoringUI))")
        isPictureInPictureActive = false
        activeAetherController?.engine.pictureInPictureActive = false
        activeAetherController?.rebindSurface()

        if !isRestoringUI {
            onDidStopPiPWithoutRestoring?()
            invalidateSession()
        }
        isRestoringUI = false
    }

    /// Called by the mounted full-screen Aether surface. AVKit's restore
    /// completion must wait until this rebind has happened; acknowledging it
    /// as soon as `activeScreen` changes can let AVKit tear down PiP while the
    /// new SwiftUI hierarchy still owns an empty surface.
    func fullscreenSurfaceDidRebind() {
        guard isRestoringUI else { return }
        restoreSurfaceReady = true
        activeAetherController?.rebindSurface()
        finishRestoreIfReady()
    }

    private func finishRestoreIfReady() {
        guard let result = pendingRestoreResult,
              let completion = pendingRestoreCompletion,
              !result || restoreSurfaceReady else { return }
        pendingRestoreResult = nil
        pendingRestoreCompletion = nil
        completion(result)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard pipController === pictureInPictureController else {
            completionHandler(false)
            return
        }
        pipLog("restoreUserInterfaceForPictureInPictureStop")
        isRestoringUI = true
        pendingRestoreCompletion = completionHandler
        pendingRestoreResult = nil
        restoreSurfaceReady = false

        guard let context = activeContext else {
            pendingRestoreResult = false
            fullscreenSurfaceDidRebind()
            return
        }

        if let onRestoreUI {
            onRestoreUI(context) { [weak self] success in
                self?.pendingRestoreResult = success
                self?.finishRestoreIfReady()
            }
        } else {
            pendingRestoreResult = false
            finishRestoreIfReady()
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(tvOS 15.0, *)
extension PictureInPictureManager: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        activeAetherController?.engine.softwarePiPSource?.setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        activeAetherController?.engine.softwarePiPSource?.timeRange()
            ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        activeAetherController?.engine.softwarePiPSource?.isPaused ?? true
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // Render size update
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        activeAetherController?.engine.softwarePiPSource?.skip(by: skipInterval.seconds)
        completionHandler()
    }
}

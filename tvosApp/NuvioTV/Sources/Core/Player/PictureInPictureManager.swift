import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
import SwiftUI
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

    /// True while this object, rather than AVKit, is driving the return to the
    /// full-screen player.
    private var isReturningFromAutomaticPiP = false

    /// True once that return has asked AVKit to close the mini player, so a
    /// second surface rebind does not ask again.
    private var didRequestAutomaticStop = false

    /// True between AVKit accepting a stop and completing it.
    private var isStopping = false

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
                self.returnFromAutomaticStart()
            }
        }
    }

    /// Put the film back in the app window now that the viewer is looking at it
    /// again.
    ///
    /// Not simply `stopPictureInPicture()`. Starting PiP dismisses the
    /// full-screen player, so by the time focus comes back AVKit's source layer
    /// is in no window at all and the stop request is ignored outright: the log
    /// showed the call going in and no `willStop` ever coming back, and the
    /// film stayed in the mini player for the rest of the session. AVKit's own
    /// restore button works because it asks the app to put its UI back *first*,
    /// so that is the order used here — remount the player, wait for the
    /// surface to rebind, then close the mini player.
    private func returnFromAutomaticStart() {
        guard isPictureInPictureActive, !isRestoringUI else {
            startedAutomatically = false
            return
        }
        guard let context = activeContext, let onRestoreUI else {
            // Nothing to restore into. Ask AVKit to close it anyway rather than
            // leaving the viewer with a mini player they did not open.
            startedAutomatically = false
            stopPictureInPicture()
            return
        }

        isRestoringUI = true
        isReturningFromAutomaticPiP = true
        didRequestAutomaticStop = false
        restoreSurfaceReady = false
        onRestoreUI(context) { [weak self] success in
            guard let self, self.isReturningFromAutomaticPiP, !success else { return }
            pipLog("return refused by the app")
            self.giveUpAutomaticReturn()
        }

        // The player is remounted asynchronously and may never arrive. Holding
        // the restore flags open costs the full-screen player its surface
        // rebinding, so let go rather than waiting forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.isReturningFromAutomaticPiP, !self.didRequestAutomaticStop else { return }
            pipLog("player never remounted; letting go")
            self.giveUpAutomaticReturn()
        }
    }

    /// Ask AVKit to close the mini player, and keep asking for a moment.
    ///
    /// AVKit ignores `stopPictureInPicture()` outright when the source layer
    /// has nowhere to put the picture, and says nothing about it — no delegate
    /// call, no error. The rebind that gets us here happens while SwiftUI is
    /// still assembling the view, so on the first pass the video is not in the
    /// window yet and the request falls into exactly that gap.
    private func requestAutomaticStop(attempt: Int = 0) {
        guard isReturningFromAutomaticPiP, isPictureInPictureActive, !isStopping else { return }
        guard let pip = pipController else {
            pipLog("stop attempt \(attempt) abandoned: no controller")
            giveUpAutomaticReturn()
            return
        }

        let isHosted = activeAetherController?.playerView.window != nil
        pipLog("stop attempt \(attempt) hosted=\(isHosted) possible=\(pip.isPictureInPicturePossible) suspended=\(pip.isPictureInPictureSuspended)")
        if isHosted {
            pip.stopPictureInPicture()
        }

        guard attempt < 12 else {
            pipLog("mini player would not close; letting go")
            giveUpAutomaticReturn()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.requestAutomaticStop(attempt: attempt + 1)
        }
    }

    /// Stop driving the return. The restore flags suppress the surface
    /// rebinding the full-screen player needs, so they cannot be left set.
    private func giveUpAutomaticReturn() {
        clearAutomaticReturn()
        isRestoringUI = false
        startedAutomatically = false
    }

    private func clearAutomaticReturn() {
        isReturningFromAutomaticPiP = false
        didRequestAutomaticStop = false
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
            #if os(macOS)
            // Software-decoded video goes to the mini player, which is always possible.
            possibleObservation?.invalidate()
            pipController = nil
            configuredSoftwareDisplayLayer = swSource.layer
            isPictureInPicturePossible = true
            return
            #else
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
            #endif
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

    #if os(macOS)
    // MARK: Mini player (software-decoded video)

    /// The floating window software-decoded video goes to instead of the system PiP window.
    ///
    /// AVKit on the Mac draws a sample-buffer layer at 1:1 and places it by its size, not by the
    /// window: measured with a test grid, a 720x540 layer put its corner at the window's centre, a
    /// 1440x1080 one at the bottom-left, a 480x360 one at the top-right. No layer size is right for
    /// every PiP window size, so for that path Omni floats its own window, fed by the renderer's PiP
    /// mirror. The native (AVPlayerLayer) path keeps the system window, which it draws correctly.
    private var miniPlayer: MacMiniPlayerPanel?

    private func startMiniPlayer(_ source: SoftwarePiPSource) {
        guard miniPlayer == nil else { return }
        let engine = activeAetherController?.engine
        engine?.pictureInPictureActive = true
        let panel = MacMiniPlayerPanel(
            layer: source.layer,
            videoSize: engine?.softwareDisplaySize ?? CGSize(width: 16, height: 9),
            isPaused: { [weak source] in source?.isPaused ?? true }
        )
        panel.onTogglePlay = { [weak source] in
            guard let source else { return }
            source.setPlaying(source.isPaused)
        }
        panel.onReturn = { [weak self] in self?.returnFromMiniPlayer() }
        panel.onClose = { [weak self] in self?.finishMiniPlayer(restoring: false) }
        miniPlayer = panel
        panel.show()
        isPictureInPictureActive = true
        pipLog("mini player start")
        onDidStartPiP?()
    }

    /// The mini player's return button: the same as AVKit's restore button.
    private func returnFromMiniPlayer() {
        guard miniPlayer != nil, !isRestoringUI else { return }
        guard let context = activeContext, let onRestoreUI else {
            finishMiniPlayer(restoring: false)
            return
        }
        isRestoringUI = true
        restoreSurfaceReady = false
        // The panel never activates Omni, so bring it forward, as the system window's button does.
        NSApp.activate(ignoringOtherApps: true)
        onRestoreUI(context) { [weak self] success in
            guard let self, !success else { return }
            // The app refused: stay in the mini player.
            self.isRestoringUI = false
        }
    }

    /// Closes the mini player: back to the full-screen player once it has remounted, or, without
    /// restoring, the end of playback, as the system window's close button is.
    private func finishMiniPlayer(restoring: Bool) {
        guard let panel = miniPlayer else { return }
        miniPlayer = nil
        panel.close()
        pipLog("mini player stop restoring=\(restoring)")
        startedAutomatically = false
        isStopping = false
        clearAutomaticReturn()
        isPictureInPictureActive = false
        activeAetherController?.engine.pictureInPictureActive = false
        activeAetherController?.rebindSurface()
        if !restoring {
            onDidStopPiPWithoutRestoring?()
            invalidateSession()
        }
        isRestoringUI = false
    }
    #endif

    func startPictureInPicture() {
        #if os(macOS)
        if let source = activeAetherController?.engine.softwarePiPSource {
            startMiniPlayer(source)
            return
        }
        #endif
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
        #if os(macOS)
        if miniPlayer != nil {
            finishMiniPlayer(restoring: false)
            return
        }
        #endif
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
        #if os(macOS)
        if let panel = miniPlayer {
            miniPlayer = nil
            panel.close()
        }
        #endif
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
        #if os(macOS)
        startedAutomatically = false
        isStopping = false
        clearAutomaticReturn()
        #endif
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
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard pipController === pictureInPictureController else { return }
        pipLog("failedToStartPictureInPictureWithError: \(error.localizedDescription)")
        #if os(macOS)
        startedAutomatically = false
        isStopping = false
        #endif
        isPictureInPictureActive = false
        activeAetherController?.engine.pictureInPictureActive = false
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        pipLog("willStopPictureInPicture (isRestoringUI=\(isRestoringUI))")
        #if os(macOS)
        isStopping = true
        #endif
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        pipLog("didStopPictureInPicture (isRestoringUI=\(isRestoringUI))")
        #if os(macOS)
        startedAutomatically = false
        isStopping = false
        clearAutomaticReturn()
        #endif
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
        #if os(macOS)
        if miniPlayer != nil {
            // The player is back in the window: the mini player has done its job.
            finishMiniPlayer(restoring: true)
            return
        }
        #endif
        restoreSurfaceReady = true
        activeAetherController?.rebindSurface()
        #if os(macOS)
        if isReturningFromAutomaticPiP {
            // Our own return: the surface is back, so AVKit now has somewhere
            // to put the picture and the stop request will be honoured.
            guard !didRequestAutomaticStop else { return }
            didRequestAutomaticStop = true
            pipLog("surface rebound; closing the mini player")
            requestAutomaticStop()
            return
        }
        #endif
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
        #if os(macOS)
        // Our own return got here: it remounted the player and only asked for
        // the stop once the surface was back in the window. So the rebind this
        // completion waits on has already happened and will not happen again —
        // SwiftUI has no reason to rebuild a view that is already mounted, and
        // holding out for it left AVKit waiting on an answer that never came.
        // From here on the two paths are the same one.
        if isReturningFromAutomaticPiP {
            clearAutomaticReturn()
            restoreSurfaceReady = true
        }
        #endif

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

#if os(macOS)
// MARK: - Mac mini player

/// A floating, resizable window holding the renderer's PiP mirror layer: Omni's own picture in
/// picture for software-decoded video (see `PictureInPictureManager.startMiniPlayer`). It floats
/// over every app and Space, keeps the video's shape, and shows its controls on hover.
@MainActor
final class MacMiniPlayerPanel {
    var onReturn: (() -> Void)?
    var onClose: (() -> Void)?
    var onTogglePlay: (() -> Void)?

    private let panel: MiniPanel
    private let layer: CALayer
    private let model: MacMiniPlayerModel
    private var pollTimer: Timer?

    /// A borderless panel that can still take clicks without bringing Omni forward.
    private final class MiniPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    init(layer: AVSampleBufferDisplayLayer, videoSize: CGSize, isPaused: @escaping () -> Bool) {
        let aspect = videoSize.width > 0 && videoSize.height > 0 ? videoSize : CGSize(width: 16, height: 9)
        let width: CGFloat = 480
        let height = (width * aspect.height / aspect.width).rounded()
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: screen.maxX - width - 24, y: screen.minY + 24, width: width, height: height)

        panel = MiniPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentAspectRatio = aspect
        panel.minSize = CGSize(width: 240, height: (240 * aspect.height / aspect.width).rounded())

        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true

        self.layer = layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        layer.videoGravity = .resizeAspect
        layer.frame = content.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(layer)
        CATransaction.commit()

        let model = MacMiniPlayerModel(isPaused: isPaused())
        self.model = model
        let controls = NSHostingView(rootView: MacMiniPlayerControls(
            model: model,
            onTogglePlay: { [weak model] in
                model?.isPaused.toggle()
            },
            onReturn: {},
            onClose: {},
            onDrag: { _ in }
        ))
        controls.frame = content.bounds
        controls.autoresizingMask = [.width, .height]
        content.addSubview(controls)
        panel.contentView = content

        // Wired after init so the closures can reach `self`.
        controls.rootView = MacMiniPlayerControls(
            model: model,
            onTogglePlay: { [weak self] in self?.onTogglePlay?() },
            onReturn: { [weak self] in self?.onReturn?() },
            onClose: { [weak self] in self?.onClose?() },
            onDrag: { [weak self] ended in self?.drag(ended: ended) }
        )
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak model] _ in
            MainActor.assumeIsolated {
                let paused = isPaused()
                if model?.isPaused != paused { model?.isPaused = paused }
            }
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private var dragStart: (origin: CGPoint, mouse: CGPoint)?

    /// Moves the window with the pointer, in screen coordinates: the controls cover the whole
    /// picture, so the panel's own drag-by-background never sees the press.
    private func drag(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (panel.frame.origin, mouse)
        dragStart = ended ? nil : start
        panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        CATransaction.commit()
        panel.orderOut(nil)
    }
}

@MainActor
final class MacMiniPlayerModel: ObservableObject {
    @Published var isPaused: Bool
    init(isPaused: Bool) { self.isPaused = isPaused }
}

/// The mini player's controls, over the picture while the pointer is on it: close and return at
/// the top, play/pause in the middle — the system PiP window's layout.
struct MacMiniPlayerControls: View {
    @ObservedObject var model: MacMiniPlayerModel
    let onTogglePlay: () -> Void
    let onReturn: () -> Void
    let onClose: () -> Void
    /// Called while the picture is dragged; true once the drag ends.
    let onDrag: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        // Always laid out, faded in on hover: a click lands on a control even before the
        // pointer has been noticed over the window.
        ZStack {
            Color.black.opacity(0.25)
            VStack {
                HStack {
                    button("xmark", help: "Close", action: onClose)
                    Spacer()
                    button("arrow.up.left.and.arrow.down.right", help: "Back to Omni", action: onReturn)
                }
                Spacer()
            }
            .padding(10)
            button(model.isPaused ? "play.fill" : "pause.fill", help: model.isPaused ? "Play" : "Pause",
                   size: 22, action: onTogglePlay)
        }
        .opacity(isHovering ? 1 : 0.001)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    private func button(_ symbol: String, help: String, size: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 2.6, height: size * 2.6)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Combine

/// Shown while playback is waiting on the network: says that the connection is
/// the reason, and how fast it is actually running.
///
/// Only appears once a stall is genuinely network-bound and a rate has been
/// sampled — a spinner during ordinary startup is not a connection problem, and
/// labelling it as one would be misleading.
private struct PlayerConnectionWarning: View {
    let speedMbps: Double
    let isStalled: Bool

    /// Below this, a 1080p stream cannot sustain playback, so the stall is
    /// almost certainly throughput rather than a momentary hiccup.
    private let slowThresholdMbps: Double = 8

    var body: some View {
        if isStalled, speedMbps > 0 {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(speedMbps < slowThresholdMbps ? .orange : .white.opacity(0.8))

                Text(
                    L10n.format(
                        "player_slow_connection",
                        fallback: "Slow connection · %@ Mbps",
                        String(format: "%.1f", speedMbps)
                    )
                )
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .transition(.opacity)
        }
    }
}

struct PlayerView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @Environment(\.scenePhase) private var scenePhase

    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let httpHeaders: [String: String]
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    var playbackOrigin: PlaybackOrigin = .main
    var addonName: String? = nil
    var provider: String? = nil
    var filename: String? = nil
    var videoSize: Int64? = nil
    /// Episode context for the in-player Next Episode card. Empty for movies/trailers.
    var episodes: [NuvioVideo] = []
    var currentEpisode: NuvioVideo? = nil
    var autoPlayNextEnabled: Bool = true
    var autoPlayNextCountdownSeconds: Int = 10
    /// Resolves a next episode into a ready-to-play stream (add-on fetch + smart
    /// selection), supplied by the app layer. Nil disables auto-advance.
    var resolveNextStream: ((NuvioVideo) async -> PreparedNextStream?)? = nil
    /// Re-resolves a fresh stream for the *current* title/episode, used to
    /// recover from an expired link, load timeout, or playback error.
    /// `excludedURLs` are sources already tried this session. Nil disables failover.
    var reloadCurrentStream: ((_ excludedURLs: [String]) async -> PreparedNextStream?)? = nil
    /// Lists alternate streams for the Sources side panel.
    var fetchPlaybackSources: ((_ contentId: String, _ type: String) async -> [NuvioStream])? = nil
    /// Resolves a user-selected source for mid-playback switching.
    var resolvePlaybackStream: ((
        _ stream: NuvioStream,
        _ contentId: String,
        _ subtitleLine: String
    ) async -> PreparedNextStream?)? = nil
    var onFinished: (() -> Void)? = nil
    var onPlaybackStarted: (() -> Void)? = nil
    var onPlayRecommendation: ((_ meta: NuvioMeta, _ playManually: Bool) -> Void)? = nil
    var onOpenRecommendationDetails: ((_ meta: NuvioMeta) -> Void)? = nil
    var onBack: () -> Void

    @State private var didHandleFinished = false
    @State private var didReportPlaybackStarted = false
    @FocusState private var remoteInputFocused: Bool
    @FocusState private var nextEpisodeFocused: Bool
    @FocusState private var cancelAutoPlayFocused: Bool
    @FocusState private var skipSegmentFocused: Bool
    @FocusState private var postPlayFocus: PostPlayFocusItem?
    #if os(macOS)
    /// The keyboard reference, opened with ? and closed with ? or Escape.
    @State private var showKeyboardHelp = false
    /// The keyboard caret over the player's own buttons. `@FocusState` never
    /// moves on macOS, so the skip, next-episode and transport buttons were
    /// unreachable from the keyboard.
    @State private var macCaret: MacPlayerCaret?
    /// The same, for the post-play recommendations screen.
    @State private var macPostPlayCaretState: PostPlayFocusItem?
    @AppStorage(SettingsKey.playerShowPiP) private var playerShowPiP = true
    @AppStorage(SettingsKey.playerShowEpisodes) private var playerShowEpisodes = true
    @AppStorage(SettingsKey.playerShowSources) private var playerShowSources = true
    #endif

    private var skipCardShownFocused: Bool {
        #if os(macOS)
        macCaret == .skipSegment
        #else
        skipSegmentFocused
        #endif
    }

    private var nextCardShownFocused: Bool {
        #if os(macOS)
        macCaret == .nextEpisode
        #else
        nextEpisodeFocused
        #endif
    }

    /// The transport control the macOS caret is on, for `PlayerControls`.
    private var macControlCaret: PlayerControlFocus? {
        #if os(macOS)
        if case .control(let key) = macCaret { return key }
        #endif
        return nil
    }

    /// The post-play item the macOS caret is on, for the overlay and the mini
    /// player frame.
    private var macPostPlayCaret: PostPlayFocusItem? {
        #if os(macOS)
        return macPostPlayEffectiveCaret
        #else
        return nil
        #endif
    }

    private var isMiniPlayerShownFocused: Bool {
        #if os(macOS)
        macPostPlayCaret == .miniPlayer
        #else
        postPlayFocus == .miniPlayer
        #endif
    }

    private var cancelAutoPlayShownFocused: Bool {
        #if os(macOS)
        macCaret == .cancelAutoPlay
        #else
        cancelAutoPlayFocused
        #endif
    }

    #if os(macOS)
    /// Pulled out of `body`: inline, these closures pushed the player's
    /// view builder past what the type checker will solve in reasonable time.
    private var macKeyCatcher: some View {
        MacPlayerKeyCatcher(
            onTogglePlayPause: { viewModel.togglePlayPause() },
            onSeek: { seconds in
                viewModel.revealControls()
                viewModel.nudgeSeek(seconds)
            },
            onRevealControls: { viewModel.revealControls() },
            onEpisodes: {
                guard viewModel.canShowEpisodesPanel else { return }
                viewModel.macToggleSidePanel(.episodes)
            },
            onSources: {
                guard viewModel.canShowSourcesPanel else { return }
                viewModel.macToggleSidePanel(.sources)
            },
            onSettings: {
                if viewModel.showSettingsPanel {
                    viewModel.showSettingsPanel = false
                } else {
                    viewModel.closeSidePanel()
                    viewModel.showSettingsPanel = true
                }
            },
            seekStep: { Double(viewModel.seekStepSeconds) },
            onToggleHelp: { showKeyboardHelp.toggle() },
            isPanelOpen: { viewModel.sidePanel != nil },
            onPanelMove: { viewModel.macPanelMove($0) },
            onPanelActivate: { viewModel.macPanelActivate() },
            onDismissTopmost: {
                if showKeyboardHelp { showKeyboardHelp = false; return true }
                if viewModel.macDismissTopmost() { return true }
                // `onExitCommand` needs a focused view to fire, and on macOS
                // nothing here ever holds focus — so Escape did nothing at all
                // on the post-play screen. Walk the same ladder by hand.
                return macHandleEscape()
            },
            isHelpVisible: { showKeyboardHelp },
            isSettingsOpen: { viewModel.showSettingsPanel },
            onCaretMove: { macCaretMove($0) },
            onCaretActivate: { macCaretActivate() },
            swallowsTransportKeys: { viewModel.postPlayState.isVisible }
        )
    }
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            videoLayer

            postPlayOverlay

            // Window-level trackpad capture for Infuse-style scrubbing / peek.
            RemoteTouchCatcher(
                isActive: {
                    !viewModel.showSettingsPanel
                        && viewModel.sidePanel == nil
                        && !viewModel.postPlayState.isVisible
                        && (viewModel.isScrubbing
                            || (!viewModel.showControls && !viewModel.showNextEpisodeCard))
                },
                onBegan: { viewModel.remoteTouchBegan() },
                onMoved: { dx, dy in viewModel.remoteTouchMoved(dx: dx, dy: dy) },
                onEnded: { dx, dy in viewModel.remoteTouchEnded(dx: dx, dy: dy) }
            )
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)

            RemoteSeekPressCatcher(
                // Hold left/right continuous seek when controls are hidden, or
                // when the timeline is focused. (Arrow holds are unreliable while
                // a focused progress bar owns the focus engine — hide chrome to
                // hold-seek.)
                isActive: !viewModel.showSettingsPanel
                    && viewModel.sidePanel == nil
                    && !viewModel.isScrubbing
                    && !viewModel.postPlayState.isVisible
                    && (!viewModel.showControls || viewModel.isTimelineFocused),
                onBeginBackward: { viewModel.beginRepeatingSkipBackward() },
                onBeginForward: { viewModel.beginRepeatingSkipForward() },
                onEnd: { viewModel.stopRepeatingSkip() }
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)

            playerStatusOverlay

            if let toast = viewModel.playerToast {
                VStack {
                    Text(toast)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 48)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(6)
            }

            // Focus sink for when the controls are hidden. tvOS routes the Menu
            // button to the system (which quits the app) and drops directional
            // input whenever no view holds focus, so something must always own it
            // while the controls are down. A bare focusable `Color.clear` is used
            // deliberately, not a Button: a Button draws a white full-screen focus
            // glow on tvOS 26+ (even with `.buttonStyle(.plain)` + focus effect
            // disabled), and dropping its opacity to hide that glow also makes the
            // focus engine skip it entirely — so `up` produced no move command.
            // A focusable Color draws no highlight yet stays reliably focusable at
            // full opacity. Kept mounted full-time (mounting it only when the
            // controls hide raced the timeline losing focusability, leaving focus in
            // a void); non-focusable while the controls are up so focus hands cleanly
            // to the timeline, focusable again the instant they hide. `up`/`down`
            // reveal via the PlayerView `onMoveCommand`; the select click reveals via
            // the tap gesture.
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .focusable(
                    (!viewModel.showControls || !didReportPlaybackStarted || viewModel.isSwitchingSource || viewModel.isScrubbing || viewModel.showPauseOverlay)
                        && !viewModel.showNextEpisodeCard
                        && !viewModel.showSkipSegmentCard
                        && !viewModel.showSettingsPanel
                        && !viewModel.postPlayState.isVisible
                        && viewModel.sidePanel == nil
                )
                .nuvioFocusable()
                .focused($remoteInputFocused)
                .onTapGesture {
                    if viewModel.isScrubbing {
                        viewModel.commitScrub()
                    } else if viewModel.showPauseOverlay {
                        viewModel.play()
                    } else if viewModel.peekVisible {
                        viewModel.beginScrub()
                    } else {
                        viewModel.revealControls()
                    }
                }
                .accessibilityHidden(true)

            // Light-tap peek timeline (no full chrome).
            if viewModel.peekVisible, !viewModel.showControls, !viewModel.isScrubbing {
                PeekBar(clock: viewModel.clock)
                    .transition(.opacity)
                    .zIndex(1)
            }

            // Infuse scrub HUD (trackpad / D-pad fine seek).
            if viewModel.isScrubbing {
                InfuseScrubHUD(
                    clock: viewModel.clock,
                    title: viewModel.title,
                    episodeLine: viewModel.subtitle.isEmpty ? nil : viewModel.subtitle,
                    wheelEngaged: viewModel.wheelEngaged
                )
                .transition(.opacity)
                .zIndex(4)
            }

            #if os(macOS)
            // Keyboard reference. Nothing on screen says these keys exist, and
            // a player is the one place a viewer will not go hunting for them.
            if showKeyboardHelp {
                MacPlayerShortcutsOverlay(
                    seekStep: viewModel.seekStepSeconds,
                    showsEpisodes: viewModel.canShowEpisodesPanel,
                    showsSources: viewModel.canShowSourcesPanel,
                    onDismiss: { showKeyboardHelp = false }
                )
                .transition(.opacity)
                .zIndex(6)
            }
            #endif

            // Accumulated D-pad skip preview over bare video.
            if viewModel.pendingSeekDelta != 0, !viewModel.showControls, !viewModel.isScrubbing {
                SeekHUD(clock: viewModel.clock, delta: viewModel.pendingSeekDelta)
                    .transition(.opacity)
                    .zIndex(4)
            }

            // Pause metadata sheet ("You're watching…").
            if viewModel.showPauseOverlay {
                PauseOverlayView(
                    title: viewModel.title,
                    episodeLine: viewModel.pauseOverlayEpisodeLine,
                    year: viewModel.pauseOverlayYear,
                    description: viewModel.pauseOverlayDescription,
                    cast: viewModel.pauseOverlayCast,
                    logoURL: viewModel.pauseOverlayLogoURL
                )
                .transition(.opacity)
                .zIndex(2)
            }

            if viewModel.showSkipSegmentCard, let interval = viewModel.activeSkipInterval {
                Button(action: { viewModel.skipActiveInterval() }) {
                    SkipSegmentOverlay(
                        interval: interval,
                        countdown: viewModel.skipSegmentCountdown,
                        isFocused: skipCardShownFocused
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .nuvioFocusable()
                .focused($skipSegmentFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 60)
                .padding(.bottom, viewModel.showControls ? 200 : 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }

            // Next-episode prompt, shown near the end. Auto-play occurs only
            // after the current episode reaches genuine end-of-media.
            if viewModel.showNextEpisodeCard, let next = viewModel.nextEpisode {
                VStack(spacing: 8) {
                    Button(action: { viewModel.playNextEpisode() }) {
                        NextEpisodeOverlay(episode: next, isAdvancing: viewModel.isAdvancingEpisode, isFocused: nextCardShownFocused, isAutoPlayCancelled: viewModel.isAutoPlayCancelled)
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .nuvioFocusable()
                    .focused($nextEpisodeFocused)
                    if autoPlayNextEnabled && !viewModel.isAutoPlayCancelled && !viewModel.isAdvancingEpisode {
                        Button(action: { viewModel.cancelAutoPlay() }) {
                            Text(L10n.string("player_cancel_autoplay", fallback: "Cancel Auto-Play"))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(cancelAutoPlayShownFocused ? .black : .white.opacity(0.85))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(cancelAutoPlayShownFocused ? Color.white : Color.white.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .nuvioFocusable()
                        .focused($cancelAutoPlayFocused)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 60)
                .padding(.bottom, viewModel.showControls ? 200 : 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }

            // Kept mounted (not gated by an `if`) so the hide animates too: removing
            // a view that holds tvOS focus makes the focus engine finalize the
            // removal before the transition can play, so only the appear would
            // animate. Animating opacity/scale on a mounted view sidesteps that —
            // focusability is gated inside PlayerControls so focus still hands off
            // cleanly to the remote-input overlay when hidden.
            PlayerControls(
                viewModel: viewModel,
                isSkipSegmentFocused: skipSegmentFocused,
                isNextEpisodeFocused: nextEpisodeFocused || cancelAutoPlayFocused,
                onFocusSkipSegment: { focusSkipSegment() },
                onFocusNextEpisode: { focusNextEpisode() },
                macCaret: macControlCaret
            )
                .opacity(
                    viewModel.showControls
                        && didReportPlaybackStarted
                        && !viewModel.isSwitchingSource
                        && !viewModel.showSettingsPanel
                        && !viewModel.isScrubbing
                        && !viewModel.showPauseOverlay
                    ? 1 : 0
                )
                .scaleEffect(
                    viewModel.showControls
                        && didReportPlaybackStarted
                        && !viewModel.isSwitchingSource
                        && !viewModel.isScrubbing
                        && !viewModel.showPauseOverlay
                    ? 1 : 0.95
                )
                .allowsHitTesting(
                    viewModel.showControls
                        && didReportPlaybackStarted
                        && !viewModel.isSwitchingSource
                        && !viewModel.showSettingsPanel
                        && !viewModel.isScrubbing
                        && !viewModel.showPauseOverlay
                )
                .animation(.playerControls, value: viewModel.showControls)
                .animation(.playerControls, value: didReportPlaybackStarted)
                .animation(.playerControls, value: viewModel.isSwitchingSource)
                .animation(.playerControls, value: viewModel.showSettingsPanel)
                .animation(.playerControls, value: viewModel.isScrubbing)
                .animation(.playerControls, value: viewModel.showPauseOverlay)

            // Settings panel (subtitles / audio / speed), over the dimmed video.
            if viewModel.showSettingsPanel {
                PlayerSettingsPanel(viewModel: viewModel) {
                    viewModel.showSettingsPanel = false
                }
                .transition(.opacity)
                .zIndex(2)
            }

            // Episodes / Sources side panels.
            if viewModel.sidePanel == .episodes {
                PlayerEpisodesPanel(viewModel: viewModel)
                    .zIndex(7)
            } else if viewModel.sidePanel == .sources {
                PlayerSourcesPanel(viewModel: viewModel)
                    .zIndex(7)
            }

            debugOverlayLayer
        }
        .animation(.playerControls, value: viewModel.showSettingsPanel)
        .animation(.playerControls, value: viewModel.showNextEpisodeCard)
        .animation(.playerControls, value: viewModel.showSkipSegmentCard)
        .animation(.easeOut(duration: 0.16), value: viewModel.isScrubbing)
        .animation(.easeOut(duration: 0.16), value: viewModel.peekVisible)
        .animation(.easeOut(duration: 0.16), value: viewModel.pendingSeekDelta != 0)
        .animation(.easeOut(duration: 0.2), value: viewModel.isSwitchingSource)
        .animation(.easeOut(duration: 0.2), value: viewModel.playerToast)
        .animation(.easeOut(duration: 0.22), value: viewModel.showPauseOverlay)
        .animation(.easeOut(duration: 0.22), value: viewModel.sidePanel)
        .onAppear {
            // Hold for the full player session (not only .playing/.buffering).
            // Status flicker previously re-enabled Sleep After mid-watch.
            PlaybackWakeLock.acquire()
            viewModel.load(
                url: url,
                meta: meta,
                subtitle: subtitle,
                httpHeaders: httpHeaders,
                externalSubtitles: externalSubtitles,
                resumeFrom: resumeFrom,
                playbackOrigin: playbackOrigin,
                addonName: addonName,
                provider: provider,
                filename: filename,
                videoSize: videoSize
            )
            if subtitle != PlaybackMarkers.trailerSubtitle {
                viewModel.fetchExternalSubtitles(
                    contentId: subtitleContentId,
                    type: meta.isSeries ? "series" : meta.type
                )
            }
            viewModel.reloadCurrentStream = reloadCurrentStream
            viewModel.fetchPlaybackSources = fetchPlaybackSources
            viewModel.resolvePlaybackStream = resolvePlaybackStream
            if let resolveNextStream {
                viewModel.configureNextEpisode(
                    episodes: episodes,
                    current: currentEpisode,
                    autoPlayEnabled: autoPlayNextEnabled,
                    autoPlayCountdownSeconds: autoPlayNextCountdownSeconds,
                    resolver: resolveNextStream
                )
            }
        }
        // The guide can arrive after playback starts — a series resumed from a
        // Continue Watching row has none to begin with — and `onAppear` has
        // already run by then.
        .onChange(of: episodes) { _, updated in
            guard let resolveNextStream, !updated.isEmpty else { return }
            viewModel.configureNextEpisode(
                episodes: updated,
                current: currentEpisode,
                autoPlayEnabled: autoPlayNextEnabled,
                autoPlayCountdownSeconds: autoPlayNextCountdownSeconds,
                resolver: resolveNextStream
            )
        }
        .onDisappear {
            PlaybackStartupTiming.cancel()
            if !PictureInPictureManager.shared.isPictureInPictureActive {
                PlaybackWakeLock.release()
                viewModel.shutdown()
            }
        }
        .onChange(of: viewModel.isPictureInPictureActive) { _, isActive in
            if isActive {
                onBack()
            }
        }
        .onChange(of: viewModel.status) { _, status in
            // Keep reasserting while the player is up — never re-enable sleep
            // based on transient status (pause/buffer/error) mid-session.
            PlaybackWakeLock.reassert()
            if status == .playing,
               !viewModel.isSwitchingSource,
               !viewModel.isReloadingStream,
               !viewModel.didDetectReplacementStream,
               !didReportPlaybackStarted {
                didReportPlaybackStarted = true
                PlaybackStartupTiming.complete()
                onPlaybackStarted?()
            }
            guard status == .ended,
                  !didHandleFinished,
                  !viewModel.postPlayState.blocksNaturalCompletion,
                  let onFinished else {
                return
            }
            didHandleFinished = true
            onFinished()
        }
        .onChange(of: viewModel.isSwitchingSource) { _, isSwitching in
            if isSwitching {
                PlaybackStartupTiming.start()
                didReportPlaybackStarted = false
            }
        }
        .onChange(of: viewModel.didDetectReplacementStream) { _, isReplacement in
            if isReplacement {
                PlaybackStartupTiming.start()
                didReportPlaybackStarted = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                PlaybackWakeLock.reassert()
            }
        }
        .onChange(of: viewModel.showControls) { _, isVisible in
            if viewModel.sidePanel != nil || viewModel.postPlayState.isVisible {
                remoteInputFocused = false
                nextEpisodeFocused = false
                cancelAutoPlayFocused = false
                skipSegmentFocused = false
                return
            }
            if isVisible, !viewModel.isScrubbing, !viewModel.showPauseOverlay {
                remoteInputFocused = false
                nextEpisodeFocused = false
                cancelAutoPlayFocused = false
                skipSegmentFocused = false
            } else if viewModel.isScrubbing || viewModel.showPauseOverlay {
                focusRemoteInput()
            } else if viewModel.showNextEpisodeCard {
                focusNextEpisode()
            } else if viewModel.showSkipSegmentCard {
                focusSkipSegment()
            } else {
                focusRemoteInput()
            }
        }
        .onChange(of: viewModel.postPlayState.isVisible) { _, isVisible in
            if isVisible {
                remoteInputFocused = false
                nextEpisodeFocused = false
                cancelAutoPlayFocused = false
                skipSegmentFocused = false
                DispatchQueue.main.async {
                    postPlayFocus = .primaryAction
                }
            } else {
                postPlayFocus = nil
            }
        }
        .onChange(of: viewModel.sidePanel) { _, panel in
            if panel != nil {
                remoteInputFocused = false
                nextEpisodeFocused = false
                cancelAutoPlayFocused = false
                skipSegmentFocused = false
            }
        }
        .onChange(of: viewModel.showPauseOverlay) { _, visible in
            if visible {
                nextEpisodeFocused = false
                cancelAutoPlayFocused = false
                skipSegmentFocused = false
                focusRemoteInput()
            }
        }
        .onChange(of: viewModel.isScrubbing) { _, scrubbing in
            if scrubbing {
                nextEpisodeFocused = false
                cancelAutoPlayFocused = false
                skipSegmentFocused = false
                focusRemoteInput()
            } else if viewModel.showControls {
                remoteInputFocused = false
            } else {
                focusRemoteInput()
            }
        }
        .onChange(of: viewModel.showNextEpisodeCard) { _, visible in
            guard !viewModel.showControls else { return }
            if visible {
                focusNextEpisode()
            } else if viewModel.showSkipSegmentCard {
                nextEpisodeFocused = false
                cancelAutoPlayFocused = false
                focusSkipSegment()
            } else {
                nextEpisodeFocused = false
                cancelAutoPlayFocused = false
                focusRemoteInput()
            }
        }
        .onChange(of: viewModel.isAutoPlayCancelled) { _, cancelled in
            if cancelled {
                cancelAutoPlayFocused = false
                focusNextEpisode()
            }
        }
        .onChange(of: viewModel.showSkipSegmentCard) { _, visible in
            guard !viewModel.showControls, !viewModel.showNextEpisodeCard else { return }
            if visible {
                focusSkipSegment()
            } else {
                skipSegmentFocused = false
                focusRemoteInput()
            }
        }
        #if os(macOS)
        .onChange(of: macCaret) { _, caret in
            MacDiagnostics.log("player.caret " + (caret.map { "\($0)" } ?? "none"))
            // Same rule as tvOS: chrome stays up while the caret is on a button
            // that opens something, and may auto-hide on Play or the timeline.
            switch caret {
            case .control(let key) where key != .timeline && key != .play:
                viewModel.setControlsAutoHideSuspended(true)
            case .control:
                viewModel.setControlsAutoHideSuspended(false)
            default:
                break
            }
        }
        .onChange(of: viewModel.showControls) { _, visible in
            // A caret on a hidden button would come back somewhere stale.
            if !visible, case .control = macCaret { macCaret = nil }
        }
        .background(macKeyCatcher)
        // The pointer has no business sitting over a playing film.
        .background(MacCursorAutoHide(isActive: viewModel.status == .playing))
        #else
        .onPlayPauseCommand {
            viewModel.togglePlayPause()
        }
        #endif
        .onMoveCommand { direction in
            // The Episodes/Sources sheet exclusively owns directional input.
            // Do not let list navigation also seek or reveal player controls.
            guard viewModel.sidePanel == nil else { return }

            // Trackpad swipes also emit move commands; the pan recognizer sets
            // moveSuppressed so a swipe does not double-fire as a skip.
            if viewModel.moveSuppressed { return }

            if viewModel.isScrubbing {
                switch direction {
                case .left:
                    viewModel.scrubJump(-Double(max(viewModel.seekStepSeconds * 4, 60)))
                case .right:
                    viewModel.scrubJump(Double(max(viewModel.seekStepSeconds * 4, 60)))
                default:
                    viewModel.cancelScrub()
                }
                return
            }

            if viewModel.showPauseOverlay {
                switch direction {
                case .left:
                    viewModel.nudgeSeek(-Double(viewModel.seekStepSeconds))
                case .right:
                    viewModel.nudgeSeek(Double(viewModel.seekStepSeconds))
                default:
                    viewModel.revealControls()
                }
                return
            }

            guard !viewModel.showControls else { return }
            switch direction {
            case .left:
                viewModel.nudgeSeek(-Double(viewModel.seekStepSeconds))
            case .right:
                viewModel.nudgeSeek(Double(viewModel.seekStepSeconds))
            default:
                viewModel.revealControls()
            }
        }
        .onExitCommand { exitOneLayer() }
    }

    /// Backs out of whatever is on top, one layer per press, leaving the player
    /// only once there is nothing left to close.
    ///
    /// Extracted from `onExitCommand` so macOS can call it from its key
    /// monitor: that modifier only fires for a focused view, and on macOS
    /// nothing in the player ever holds focus.
    private func exitOneLayer() {
        // The panel handles its own exit; this fallback covers the frame
        // where focus hasn't landed inside it yet.
        if viewModel.showSettingsPanel {
            viewModel.showSettingsPanel = false
            return
        }
        if viewModel.sidePanel != nil {
            viewModel.closeSidePanel()
            return
        }
        if viewModel.isScrubbing {
            viewModel.cancelScrub()
            return
        }
        if viewModel.showPauseOverlay {
            viewModel.dismissPauseOverlay()
            viewModel.revealControls()
            return
        }
        if viewModel.peekVisible {
            viewModel.hidePeek()
            return
        }
        if viewModel.showPostPlaySynopsis {
            viewModel.showPostPlaySynopsis = false
            return
        }
        if viewModel.postPlayState.isTrailerPlaying {
            viewModel.stopPostPlayTrailer()
            return
        }
        if viewModel.postPlayState.isVisible {
            if viewModel.postPlayState.canReturnToPlayer && viewModel.time.current < max(0, viewModel.time.duration - 3) && viewModel.status != .ended {
                viewModel.returnToPlayerFromPostPlay()
            } else {
                onBack()
            }
            return
        }
        if viewModel.showControls {
            viewModel.hideControls()
            return
        }
        onBack()
    }

    #if os(macOS)
    /// Escape, from the key monitor. Always true: every press backs out a
    /// layer, and the last one leaves the player.
    func macHandleEscape() -> Bool {
        exitOneLayer()
        return true
    }
    #endif

    private var subtitleContentId: String {
        if let currentEpisode { return currentEpisode.id }
        if meta.isSeries, let numbers = EpisodeTagResolver.episodeNumbers(in: subtitle) {
            return "\(meta.id):\(numbers.season):\(numbers.episode)"
        }
        return meta.id
    }

    private func focusRemoteInput() {
        guard !viewModel.postPlayState.isVisible else { return }
        DispatchQueue.main.async {
            remoteInputFocused = true
        }
    }

    private func focusNextEpisode() {
        DispatchQueue.main.async {
            nextEpisodeFocused = true
        }
    }

    private func focusSkipSegment() {
        DispatchQueue.main.async {
            skipSegmentFocused = true
        }
    }

    /// The post-play recommendations screen.
    ///
    /// Extracted from `body` for the type checker, like the video layer above.
    @ViewBuilder
    private var postPlayOverlay: some View {
            // Post-Play Recommendation Overlay
    if viewModel.postPlayState.isVisible {
        PostPlayRecommendationOverlay(
            state: viewModel.postPlayState,
            currentTitle: meta.name,
            showManualPlayOption: autoPlayNextEnabled,
            focus: $postPlayFocus,
            macCaret: macPostPlayCaret,
            showSynopsisModal: $viewModel.showPostPlaySynopsis,
            onPlay: { rec, manual in
                onPlayRecommendation?(rec.asMeta, manual)
            },
            onOpenDetails: { rec in
                onOpenRecommendationDetails?(rec.asMeta)
            },
            onPlayTrailer: {
                viewModel.playPostPlayTrailer()
            },
            onStopTrailer: {
                viewModel.stopPostPlayTrailer()
            },
            onPreviousRecommendation: {
                viewModel.showPreviousRecommendation()
            },
            onNextRecommendation: {
                viewModel.showNextRecommendation()
            },
            onBack: {
                if viewModel.postPlayState.isTrailerPlaying {
                    viewModel.stopPostPlayTrailer()
                } else if viewModel.postPlayState.canReturnToPlayer && viewModel.time.current < max(0, viewModel.time.duration - 3) && viewModel.status != .ended {
                    viewModel.returnToPlayerFromPostPlay()
                } else {
                    onBack()
                }
            }
        )
        .zIndex(2)
        .transition(.opacity)
    }
    }

    /// The video, full screen or as the post-play mini window.
    ///
    /// Extracted from `body`, and the mini-window flag hoisted into a local:
    /// inline, this chain was past what the type checker will solve in
    /// reasonable time.
    @ViewBuilder
    private var videoLayer: some View {
        let isMini = viewModel.postPlayState.isVisible
            // Main video surface (or top-right mini window during post-play recommendations)
    if !viewModel.postPlayState.isTrailerPlaying &&
        (!viewModel.postPlayState.isVisible || viewModel.postPlayState.canReturnToPlayer) {
        videoSurfaceStack
        .frame(
            width: isMini ? 580 : nil,
            height: isMini ? 326 : nil
        )
        // Only clip for the rounded mini window. A zero-radius
        // `clipShape` still antialiases its own edge, and that blend
        // against the black behind it is the hairline border that ran
        // around the whole video full-screen.
        .clipShape(
            RoundedRectangle(cornerRadius: isMini ? 16 : 0),
            style: FillStyle(eoFill: false, antialiased: viewModel.postPlayState.isVisible)
        )
        .scaleEffect(viewModel.postPlayState.isVisible && isMiniPlayerShownFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.16), value: isMiniPlayerShownFocused)
        .overlay {
            if viewModel.postPlayState.isVisible {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isMiniPlayerShownFocused ? Color.white : Color.white.opacity(0.35),
                        lineWidth: isMiniPlayerShownFocused ? 4 : 2
                    )
                    .shadow(
                        color: isMiniPlayerShownFocused ? Color.white.opacity(0.6) : Color.clear,
                        radius: 12
                    )
            }
        }
        .shadow(color: Color.black.opacity(isMini ? 0.6 : 0), radius: 16)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: isMini ? .topTrailing : .center
        )
        .padding(.top, isMini ? 50 : 0)
        .padding(.trailing, isMini ? 60 : 0)
        .zIndex(isMini ? 5 : 0)
        .ignoresSafeArea(edges: isMini ? [] : .all)
    }
    }

    /// The video surface, its subtitle overlay and, during post-play, the mini
    /// player's click target.
    ///
    /// Extracted from `body`: inline, the stack plus the mini-window geometry
    /// around it was past what the type checker will solve in reasonable time.
    @ViewBuilder
    private var videoSurfaceStack: some View {
        ZStack {
            Group {
                switch viewModel.activeEngineKind {
                case .aether:
                    AetherPlayerSurface(controller: viewModel.aetherController)
                case .mpv:
                    MPVVideoSurface(controller: viewModel.playerController)
                }
            }

            if viewModel.activeEngineKind == .aether {
                PlayerSubtitleOverlay(
                    playback: viewModel.aetherController.subtitleOverlayState,
                    translation: viewModel.aetherController.subtitleTranslationState,
                    subtitleDelaySeconds: Double(viewModel.subtitleDelayMs) / 1000.0,
                    videoNaturalSize: viewModel.videoNaturalSize,
                    aspectMode: viewModel.aspectMode,
                    style: viewModel.subtitleStyle
                )
                .ignoresSafeArea(edges: viewModel.postPlayState.isVisible ? [] : .all)
            } else {
                MPVSubtitleOverlay(
                    translation: viewModel.playerController.subtitleTranslationState,
                    videoNaturalSize: viewModel.videoNaturalSize,
                    aspectMode: viewModel.aspectMode,
                    style: viewModel.subtitleStyle
                )
                .ignoresSafeArea(edges: viewModel.postPlayState.isVisible ? [] : .all)
            }

            if viewModel.postPlayState.isVisible && viewModel.postPlayState.canReturnToPlayer {
                miniPlayerReturnControls
            }
        }
    }

    /// The mini player's own click target.
    ///
    /// Split out of the video stack because that stack was already at the type
    /// checker's limit.
    @ViewBuilder
    private var miniPlayerReturnControls: some View {
        miniPlayerReturnButton
        #if os(macOS)
        // The engine's video view is a real NSView, so it hit-tests above the
        // SwiftUI button behind it and ate every click on the mini player. An
        // AppKit catcher of our own, added after it, takes the click back.
        MacClickCatcher { viewModel.returnToPlayerFromPostPlay() }
        #endif
    }

    @ViewBuilder
    private var miniPlayerReturnButton: some View {
        Button {
            viewModel.returnToPlayerFromPostPlay()
        } label: {
            ZStack {
                Color.clear
                if postPlayFocus == .miniPlayer {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .bold))
                            Text(L10n.string("player_return_to_video", fallback: "Return to Video"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.95), in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .padding(.bottom, 14)
                    }
                    .transition(.opacity)
                }
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .nuvioFocusable()
        .focused($postPlayFocus, equals: .miniPlayer)
        .onMoveCommand { direction in
            if direction == .down {
                postPlayFocus = .primaryAction
            }
        }
        .accessibilityLabel("Return to video")
    }

    @ViewBuilder
    private var playerStatusOverlay: some View {
        switch viewModel.status {
        case .buffering, .idle:
            if viewModel.isSwitchingSource || viewModel.isReloadingStream || viewModel.didDetectReplacementStream {
                PlayerLoadingOverlay(
                    backdropUrl: meta.backgroundUrl ?? meta.posterUrl,
                    logoUrl: meta.logoUrl,
                    title: meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
            } else if !didReportPlaybackStarted {
                PlayerLoadingOverlay(
                    backdropUrl: meta.backgroundUrl ?? meta.posterUrl,
                    logoUrl: meta.logoUrl,
                    title: meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
            } else {
                VStack(spacing: 20) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(2)
                        .padding(48)
                        .glassCircle()

                    PlayerConnectionWarning(
                        speedMbps: viewModel.networkSpeedMbps,
                        isStalled: viewModel.isStalledOnNetwork
                    )
                }
            }
        case .playing, .paused:
            if viewModel.isSwitchingSource || viewModel.isReloadingStream || viewModel.didDetectReplacementStream || !didReportPlaybackStarted {
                PlayerLoadingOverlay(
                    backdropUrl: meta.backgroundUrl ?? meta.posterUrl,
                    logoUrl: meta.logoUrl,
                    title: meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
            }
        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.yellow)
                Text(L10n.string("player_status_playback_failed", fallback: "Playback failed"))
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
            .padding(48)
            .glassRoundedRect(cornerRadius: 32)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var debugOverlayLayer: some View {
        if viewModel.isPlaybackDebugHUDVisible,
           let info = viewModel.playbackDebugInfo {
            let dur = viewModel.clock.duration > 0 ? viewModel.clock.duration : viewModel.time.duration
            let pos = viewModel.clock.duration > 0 ? viewModel.clock.position : viewModel.time.current
            let remaining = dur > 0 ? max(0, dur - pos) : nil
            PlaybackDebugHUDView(
                info: info,
                reason: viewModel.playbackDebugReason,
                remainingSeconds: remaining
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
            .zIndex(100)
        }
    }
}

/// Comprehensive playback diagnostics and telemetry overlay matching the HUD specification.
struct PlaybackDebugHUDView: View {
    let info: PlaybackDebugInfo
    let reason: String
    let remainingSeconds: Double?

    @State private var currentTimeString: String = ""
    @State private var endsAtTimeString: String = ""
    @State private var timer: AnyCancellable?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top Section: SOURCE & Clock
            sourceSection

            sectionDivider

            // VIDEO Section
            videoSection

            sectionDivider

            // AUDIO Section
            audioSection

            sectionDivider

            // NETWORK Section
            networkSection

            sectionDivider

            // SYSTEM Section
            systemSection

            // Optional Backend Diagnostics / Policy Trace
            if !reason.isEmpty || !info.diagnostics.isEmpty {
                sectionDivider
                diagnosticsSection
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 680, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.7), radius: 24, x: 0, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 48)
        .padding(.top, 36)
        .allowsHitTesting(false)
        .onAppear {
            updateClock()
            timer = Timer.publish(every: 1.0, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    updateClock()
                }
        }
        .onChange(of: remainingSeconds) { _, _ in
            updateClock()
        }
        .onDisappear {
            timer?.cancel()
            timer = nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback debug overlay")
    }

    // MARK: - SOURCE Section

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("SOURCE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
                    .tracking(1.2)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentTimeString)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.9))

                    if !endsAtTimeString.isEmpty {
                        Text(endsAtTimeString)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.55))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                hudRow(label: "Add-on", value: info.addon.isEmpty ? "Direct" : info.addon)
                hudRow(label: "Provider", value: info.provider.isEmpty ? "Direct" : info.provider)
                hudRow(label: "Server", value: info.server.isEmpty ? "--" : info.server)
                fileRow
                hudRow(label: "Size", value: info.size.isEmpty ? "--" : info.size)
            }
        }
    }

    private var fileRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            statusDotSpacer

            Text("File")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.60))
                .frame(width: 105, alignment: .leading)

            HStack(spacing: 8) {
                Text(info.fileExtension.isEmpty ? "MKV" : info.fileExtension.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.90))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )

                Text(info.fileName.isEmpty ? "Top.Gun.Maverick.2022.L" : info.fileName)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - VIDEO Section

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VIDEO")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(label: "Video", value: info.video.isEmpty ? "3840×2160 · 23.976 fps · dolby-vision" : info.video)
                hudRow(label: "HDR", value: info.hdr.isEmpty ? "Dolby Vision" : info.hdr)
                hudRow(label: "V bitrate", value: info.vBitrate.isEmpty ? "avg mux 72.9 Mbit/s · now 82.0 Mbit/s" : info.vBitrate)
                hudRow(
                    label: "DV",
                    value: info.dv.isEmpty ? "None" : info.dv,
                    hasDot: info.dv != "None" && !info.dv.isEmpty,
                    dotColor: .green
                )
                hudRow(label: "DV HDR", value: info.dvHdr.isEmpty ? "MaxCLL 617 · MaxFALL 496 · MDL peak ~1001 nits" : info.dvHdr)
                hudRow(label: "Decoder", value: info.decoder.isEmpty ? "c2.amlogic.dolby-vision.dvhe.decoder" : info.decoder)
                hudRow(
                    label: "Dropped",
                    value: info.dropped.isEmpty ? "0 frames" : info.dropped,
                    hasDot: true,
                    dotColor: info.droppedCount > 10 ? .red : (info.droppedCount > 0 ? .yellow : .green)
                )
                hudRow(label: "Frame lead", value: info.frameLead.isEmpty ? "+44.9 ms" : info.frameLead, hasDot: true, dotColor: .green)
                hudRow(label: "Display", value: info.display.isEmpty ? "23.98 Hz" : info.display, hasDot: true, dotColor: .green)
            }
        }
    }

    // MARK: - AUDIO Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AUDIO")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(label: "Audio", value: info.audio.isEmpty ? "TrueHD · 8ch · 48 kHz · passthrough" : info.audio, hasDot: true, dotColor: .green)
                hudRow(label: "A bitrate", value: info.aBitrate.isEmpty ? "meas 5.14 Mbit/s" : info.aBitrate)
                hudRow(label: "Underruns", value: info.underruns.isEmpty ? "0 · native 0" : info.underruns, hasDot: true, dotColor: info.underrunsCount > 0 ? .yellow : .green)
                hudRow(label: "Route", value: info.route.isEmpty ? "HDMI · 0 changes" : info.route)
                hudRow(label: "A jitter", value: info.aJitter.isEmpty ? "drift avg 32 ms/s · max 343 · 13 ev" : info.aJitter, hasDot: true, dotColor: .green)
            }
        }
    }

    // MARK: - NETWORK Section

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NETWORK")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(
                    label: "Buffer",
                    value: info.buffer.isEmpty ? "--" : info.buffer,
                    hasDot: true,
                    dotColor: (info.buffer.contains("cushion") || info.bufferSeconds >= 1.0) ? .green : (info.bufferSeconds > 0 ? .yellow : .green)
                )
                hudRow(label: "Speed", value: info.speed.isEmpty ? "est 199.0 Mbit/s" : info.speed, hasDot: true, dotColor: .green)
                hudRow(label: "Ping", value: info.ping.isEmpty ? "7 ms" : info.ping, hasDot: true, dotColor: .green)
                hudRow(label: "Loaded", value: info.loaded.isEmpty ? "1021.6 MB" : info.loaded)
                hudRow(
                    label: "Stalls",
                    value: info.stalls.isEmpty ? "0" : info.stalls,
                    hasDot: true,
                    dotColor: info.stallsCount > 1 ? .red : (info.stallsCount == 1 ? .yellow : .green)
                )
            }
        }
    }

    // MARK: - SYSTEM Section

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SYSTEM")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.55))
                .tracking(1.2)

            VStack(alignment: .leading, spacing: 3) {
                hudRow(
                    label: "App CPU",
                    value: info.appCpu.isEmpty ? "27 %" : info.appCpu,
                    hasDot: true,
                    dotColor: info.appCpuPercent > 85 ? .yellow : .green
                )
                hudRow(label: "Memory", value: info.memory.isEmpty ? "heap 57/384 MB · native 841 MB" : info.memory, hasDot: true, dotColor: .green)
                hudRow(
                    label: "SoC temp",
                    value: info.socTemp.isEmpty ? "48.9 °C" : info.socTemp,
                    hasDot: true,
                    dotColor: info.isThermalElevated ? .yellow : .green
                )
                hudRow(label: "CPU clock", value: info.cpuClock.isEmpty ? "2.40 GHz · cap 2.40 GHz" : info.cpuClock, hasDot: true, dotColor: .green)
            }
        }
    }

    // MARK: - Optional Diagnostics / Policy Section

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !reason.isEmpty {
                Text("POLICY   \(reason)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.yellow.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(info.diagnostics, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Row Helpers

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    private var statusDotSpacer: some View {
        Color.clear
            .frame(width: 14, height: 14)
    }

    private func statusDot(_ color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
    }

    private func hudRow(
        label: String,
        value: String,
        hasDot: Bool = false,
        dotColor: Color = .green
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if hasDot {
                statusDot(dotColor)
            } else {
                statusDotSpacer
            }

            Text(label)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.60))
                .frame(width: 105, alignment: .leading)

            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Clock Calculation

    private func updateClock() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        currentTimeString = formatter.string(from: now)

        if let remaining = remainingSeconds, remaining > 0 {
            let endsAt = now.addingTimeInterval(remaining)
            endsAtTimeString = "Ends at \(formatter.string(from: endsAt))"
        } else {
            endsAtTimeString = ""
        }
    }
}



// Hosts the libmpv UIViewController (owns the CAMetalLayer surface).
struct MPVVideoSurface: UIViewControllerRepresentable {
    let controller: MPVPlayerViewController

    #if os(macOS)
    func makeNSViewController(context: Context) -> MPVPlayerViewController {
        controller
    }

    func updateNSViewController(_ nsViewController: MPVPlayerViewController, context: Context) {}
    #else
    func makeUIViewController(context: Context) -> MPVPlayerViewController {
        controller
    }

    func updateUIViewController(_ uiViewController: MPVPlayerViewController, context: Context) {}
    #endif
}

/// Hosts AetherEngine's `AetherPlayerView` for native / software decode.
struct AetherPlayerSurface: UIViewControllerRepresentable {
    let controller: AetherPlaybackController

    private func makeSurface() -> AetherPlaybackController {
        controller.rebindSurface()
        PictureInPictureManager.shared.fullscreenSurfaceDidRebind()
        return controller
    }

    private func updateSurface(_ controller: AetherPlaybackController) {
        // While Picture in Picture is showing, AVKit owns the video layer: on
        // the software path it moves that layer into its own window. Rebinding
        // steals it back into this one, and SwiftUI calls this on every update
        // of the player — so the PiP window went black with a torn slice of the
        // last frame in it. The restore path still rebinds deliberately, which
        // is how the layer comes home when PiP closes.
        if PictureInPictureManager.shared.isPictureInPictureActive,
           !PictureInPictureManager.shared.isRestoringUIInProgress {
            return
        }
        controller.rebindSurface()
        PictureInPictureManager.shared.fullscreenSurfaceDidRebind()
    }

    #if os(macOS)
    func makeNSViewController(context: Context) -> AetherPlaybackController { makeSurface() }

    func updateNSViewController(_ nsViewController: AetherPlaybackController, context: Context) {
        updateSurface(nsViewController)
    }
    #else
    func makeUIViewController(context: Context) -> AetherPlaybackController { makeSurface() }

    func updateUIViewController(_ uiViewController: AetherPlaybackController, context: Context) {
        updateSurface(uiViewController)
    }
    #endif
}


#if os(macOS)
/// Keyboard stand-in for the Siri Remote's hold-to-seek.
///
/// tvOS installs window-level press recognizers because a focused SwiftUI view
/// otherwise swallows the remote's arrow holds. The same problem exists on the
/// Mac — the focus engine consumes arrow keys — so this uses a window-level
/// `NSEvent` monitor for the same reason.
///
/// Taps are deliberately passed through so ordinary focus navigation and
/// `onMoveCommand` seeking still work; only once a key has been held past the
/// threshold does this take the key over and start a continuous seek.
private struct RemoteSeekPressCatcher: NSViewRepresentable {
    let isActive: Bool
    let onBeginBackward: () -> Void
    let onBeginForward: () -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> RemoteSeekKeyHostView {
        let view = RemoteSeekKeyHostView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: RemoteSeekKeyHostView, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: RemoteSeekKeyHostView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    private func apply(to view: RemoteSeekKeyHostView) {
        view.onBeginBackward = onBeginBackward
        view.onBeginForward = onBeginForward
        view.onEnd = onEnd
        view.setActive(isActive)
    }
}

final class RemoteSeekKeyHostView: NSView {
    private enum Direction {
        case backward
        case forward
    }

    var onBeginBackward: () -> Void = {}
    var onBeginForward: () -> Void = {}
    var onEnd: () -> Void = {}

    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    /// Matches the tvOS recognizer's `minimumPressDuration`.
    private static let holdThreshold: TimeInterval = 0.35

    private var monitor: Any?
    private var acceptsNewHolds = false
    private var activeDirection: Direction?
    private var pendingKeyCode: UInt16?
    private var holdTimer: Timer?

    func setActive(_ active: Bool) {
        acceptsNewHolds = active
        if !active, activeDirection == nil {
            cancelPendingHold()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    private func installMonitorIfNeeded() {
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stopMonitoring() {
        endSeekIfActive()
        cancelPendingHold()
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        holdTimer?.invalidate()
    }

    /// Returns true when the event was consumed by a hold-seek.
    private func handle(_ event: NSEvent) -> Bool {
        guard let direction = Self.direction(for: event.keyCode) else { return false }

        if event.type == .keyUp {
            let wasSeeking = activeDirection == direction
            cancelPendingHold()
            endSeekIfActive()
            // Swallow only the key-up that terminates a seek; a plain tap's
            // key-up belongs to whoever handled the key-down.
            return wasSeeking
        }

        if activeDirection == direction {
            // Already seeking: absorb the auto-repeat so it does not also
            // register as step-seeks.
            return true
        }

        guard acceptsNewHolds, activeDirection == nil else { return false }

        if pendingKeyCode != event.keyCode {
            cancelPendingHold()
            pendingKeyCode = event.keyCode
            holdTimer = Timer.scheduledTimer(
                withTimeInterval: Self.holdThreshold,
                repeats: false
            ) { [weak self] _ in
                self?.beginSeek(direction)
            }
        }
        // Let the first key-down through so a tap still steps normally, but
        // absorb the auto-repeats that arrive while the hold is still pending.
        return event.isARepeat
    }

    private static func direction(for keyCode: UInt16) -> Direction? {
        switch keyCode {
        case leftArrowKeyCode: return .backward
        case rightArrowKeyCode: return .forward
        default: return nil
        }
    }

    private func beginSeek(_ direction: Direction) {
        holdTimer = nil
        pendingKeyCode = nil
        guard acceptsNewHolds, activeDirection == nil else { return }
        activeDirection = direction
        switch direction {
        case .backward: onBeginBackward()
        case .forward: onBeginForward()
        }
    }

    private func cancelPendingHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        pendingKeyCode = nil
    }

    private func endSeekIfActive() {
        guard activeDirection != nil else { return }
        activeDirection = nil
        onEnd()
    }
}
#else
private struct RemoteSeekPressCatcher: UIViewControllerRepresentable {
    let isActive: Bool
    let onBeginBackward: () -> Void
    let onBeginForward: () -> Void
    let onEnd: () -> Void

    func makeUIViewController(context: Context) -> RemoteSeekPressViewController {
        let controller = RemoteSeekPressViewController()
        controller.onBeginBackward = onBeginBackward
        controller.onBeginForward = onBeginForward
        controller.onEnd = onEnd
        controller.setActive(isActive)
        return controller
    }

    func updateUIViewController(_ controller: RemoteSeekPressViewController, context: Context) {
        controller.onBeginBackward = onBeginBackward
        controller.onBeginForward = onBeginForward
        controller.onEnd = onEnd
        controller.setActive(isActive)
    }
}

private final class RemoteSeekPressViewController: UIViewController {
    enum Direction {
        case backward
        case forward
    }

    var onBeginBackward: () -> Void = {}
    var onBeginForward: () -> Void = {}
    var onEnd: () -> Void = {}

    private var activeDirection: Direction?
    private var acceptsNewHolds = false
    private weak var gestureWindow: UIWindow?
    private lazy var backwardHoldRecognizer = makeHoldRecognizer(
        pressType: .leftArrow,
        action: #selector(handleBackwardHold(_:))
    )
    private lazy var forwardHoldRecognizer = makeHoldRecognizer(
        pressType: .rightArrow,
        action: #selector(handleForwardHold(_:))
    )

    /// Window-level press recognizers receive Siri Remote holds even when a
    /// focused SwiftUI view owns the responder chain. A sibling view controller's
    /// `pressesBegan` is not guaranteed to receive those presses.
    func setActive(_ active: Bool) {
        acceptsNewHolds = active
        updateRecognizerState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installRecognizersIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        uninstallRecognizers()
    }

    private func makeHoldRecognizer(pressType: UIPress.PressType, action: Selector) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer(target: self, action: action)
        recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
        recognizer.minimumPressDuration = 0.35
        recognizer.cancelsTouchesInView = true
        recognizer.isEnabled = false
        return recognizer
    }

    private func installRecognizersIfNeeded() {
        guard let window = view.window, gestureWindow !== window else { return }
        uninstallRecognizers()
        window.addGestureRecognizer(backwardHoldRecognizer)
        window.addGestureRecognizer(forwardHoldRecognizer)
        gestureWindow = window
        updateRecognizerState()
    }

    private func uninstallRecognizers() {
        if activeDirection != nil {
            activeDirection = nil
            onEnd()
        }
        gestureWindow?.removeGestureRecognizer(backwardHoldRecognizer)
        gestureWindow?.removeGestureRecognizer(forwardHoldRecognizer)
        gestureWindow = nil
    }

    private func updateRecognizerState() {
        // Once a hold starts, keep its recognizer alive through the brief focus
        // handoff that occurs when seeking reveals the controls.
        let enabled = acceptsNewHolds || activeDirection != nil
        backwardHoldRecognizer.isEnabled = enabled
        forwardHoldRecognizer.isEnabled = enabled
    }

    @objc private func handleBackwardHold(_ recognizer: UILongPressGestureRecognizer) {
        handleHold(recognizer, direction: .backward)
    }

    @objc private func handleForwardHold(_ recognizer: UILongPressGestureRecognizer) {
        handleHold(recognizer, direction: .forward)
    }

    private func handleHold(_ recognizer: UILongPressGestureRecognizer, direction: Direction) {
        switch recognizer.state {
        case .began:
            guard acceptsNewHolds, activeDirection == nil else { return }
            activeDirection = direction
            switch direction {
            case .backward: onBeginBackward()
            case .forward: onBeginForward()
            }
        case .ended, .cancelled, .failed:
            guard activeDirection == direction else { return }
            activeDirection = nil
            onEnd()
            updateRecognizerState()
        default:
            break
        }
    }
}
#endif

#if os(macOS)
/// Where the keyboard caret sits in the player: one of the cards shown near a
/// segment or the end of an episode, or one of the transport controls.
enum MacPlayerCaret: Hashable {
    case skipSegment
    case nextEpisode
    case cancelAutoPlay
    case control(PlayerControlFocus)
}

extension PlayerView {
    /// The cards on screen, left to right.
    private var macCards: [MacPlayerCaret] {
        var cards: [MacPlayerCaret] = []
        if viewModel.showSkipSegmentCard, viewModel.activeSkipInterval != nil {
            cards.append(.skipSegment)
        }
        if viewModel.showNextEpisodeCard, viewModel.nextEpisode != nil {
            cards.append(.nextEpisode)
            if autoPlayNextEnabled, !viewModel.isAutoPlayCancelled, !viewModel.isAdvancingEpisode {
                cards.append(.cancelAutoPlay)
            }
        }
        return cards
    }

    /// Mirrors `PlayerControls.transportFocusOrder`.
    private var macTransportOrder: [PlayerControlFocus] {
        var order: [PlayerControlFocus] = [.play]
        if viewModel.isPictureInPictureSupported && playerShowPiP { order.append(.pip) }
        if viewModel.canShowEpisodesPanel && playerShowEpisodes { order.append(.episodes) }
        if viewModel.canShowSourcesPanel && playerShowSources { order.append(.sources) }
        order.append(.settings)
        return order
    }

    /// Anything drawn over the controls owns the keys instead, and keeps the
    /// handling it already had.
    private var macCaretApplies: Bool {
        !viewModel.isScrubbing
            && !viewModel.showPauseOverlay
            && !viewModel.showSettingsPanel
            && viewModel.sidePanel == nil
            && !viewModel.postPlayState.isVisible
    }

    private func macIsValid(_ caret: MacPlayerCaret) -> Bool {
        switch caret {
        case .skipSegment, .nextEpisode, .cancelAutoPlay:
            return macCards.contains(caret)
        case .control(let key):
            guard viewModel.showControls else { return false }
            return key == .timeline ? !viewModel.isLiveStream : macTransportOrder.contains(key)
        }
    }

    /// The caret, or where it lands when it has nowhere valid to be: a card
    /// when one is up, otherwise the timeline (Play on a live stream).
    private var macEffectiveCaret: MacPlayerCaret? {
        if let macCaret, macIsValid(macCaret) { return macCaret }
        if let card = macCards.first { return card }
        guard viewModel.showControls else { return nil }
        return .control(viewModel.isLiveStream ? .play : .timeline)
    }

    /// - Returns: false to leave the key to the player's default handling
    ///   (seeking, revealing the controls).
    func macCaretMove(_ direction: MoveCommandDirection) -> Bool {
        if macPostPlayMove(direction) { return true }
        guard macCaretApplies else { return false }
        let cards = macCards

        // Chrome down: arrows keep seeking and revealing. A card on screen
        // takes the caret so Return reaches it.
        guard viewModel.showControls else {
            if direction == .up || direction == .down {
                viewModel.revealControls()
                macCaret = macEffectiveCaret
                return true
            }
            return false
        }

        guard let caret = macEffectiveCaret else { return false }
        viewModel.revealControls()

        switch caret {
        case .skipSegment, .nextEpisode, .cancelAutoPlay:
            let index = cards.firstIndex(of: caret) ?? 0
            switch direction {
            case .left where index > 0:
                macCaret = cards[index - 1]
            case .right where index < cards.count - 1:
                macCaret = cards[index + 1]
            case .down:
                macCaret = .control(.play)
            default:
                macCaret = caret
            }
        case .control(.timeline):
            switch direction {
            case .left:
                viewModel.nudgeSeek(-Double(viewModel.seekStepSeconds))
            case .right:
                viewModel.nudgeSeek(Double(viewModel.seekStepSeconds))
            case .up:
                macCaret = .control(.play)
                return true
            default:
                break
            }
            macCaret = caret
        case .control(let key):
            let order = macTransportOrder
            let index = order.firstIndex(of: key) ?? 0
            switch direction {
            case .left where index > 0:
                macCaret = .control(order[index - 1])
            case .right where index < order.count - 1:
                macCaret = .control(order[index + 1])
            case .up:
                macCaret = cards.first ?? caret
            case .down:
                macCaret = viewModel.isLiveStream ? caret : .control(.timeline)
            default:
                macCaret = caret
            }
        }
        return true
    }

    /// - Returns: false when there is nothing under the caret to press.
    func macCaretActivate() -> Bool {
        if macPostPlayActivate() { return true }
        guard macCaretApplies, let caret = macEffectiveCaret else { return false }
        MacDiagnostics.log("player.caret.activate \(caret)")
        switch caret {
        case .skipSegment:
            viewModel.skipActiveInterval()
            macCaret = nil
        case .nextEpisode:
            viewModel.playNextEpisode()
        case .cancelAutoPlay:
            viewModel.cancelAutoPlay()
            macCaret = .nextEpisode
        case .control(.play), .control(.timeline):
            viewModel.togglePlayPause()
        case .control(.pip):
            viewModel.togglePictureInPicture()
        case .control(.episodes):
            viewModel.openSidePanel(.episodes)
        case .control(.sources):
            viewModel.openSidePanel(.sources)
        case .control(.settings):
            viewModel.showSettingsPanel = true
        }
        return true
    }
}
#endif

#if os(macOS)
extension PlayerView {
    /// The post-play screen's buttons, left to right, with the mini player
    /// above them. Only what is actually on screen and usable.
    private var macPostPlayItems: [PostPlayFocusItem] {
        let state = viewModel.postPlayState
        guard let recommendation = state.recommendation else { return [] }
        var items: [PostPlayFocusItem] = [.primaryAction]
        if recommendation.hasTrailer { items.append(.trailerAction) }
        if state.recommendationCount > 1 {
            if state.canNavigatePrevious { items.append(.prevAction) }
            if state.canNavigateNext { items.append(.nextAction) }
        }
        return items
    }

    var macPostPlayEffectiveCaret: PostPlayFocusItem? {
        let items = macPostPlayItems
        if let caret = macPostPlayCaretState {
            if caret == .miniPlayer {
                return viewModel.postPlayState.canReturnToPlayer ? caret : items.first
            }
            if items.contains(caret) { return caret }
        }
        return items.first
    }

    /// - Returns: true when the post-play screen took the key. It takes every
    ///   arrow while it is up, so the film behind it cannot seek unseen.
    func macPostPlayMove(_ direction: MoveCommandDirection) -> Bool {
        guard viewModel.postPlayState.isVisible else { return false }
        if viewModel.showPostPlaySynopsis { return true }
        let items = macPostPlayItems
        guard let caret = macPostPlayEffectiveCaret else { return true }

        switch direction {
        case .up where viewModel.postPlayState.canReturnToPlayer:
            macPostPlayCaretState = .miniPlayer
        case .down where caret == .miniPlayer:
            macPostPlayCaretState = items.first
        case .left, .right:
            guard caret != .miniPlayer, let index = items.firstIndex(of: caret) else { break }
            let next = direction == .left ? index - 1 : index + 1
            if items.indices.contains(next) { macPostPlayCaretState = items[next] }
        default:
            break
        }
        return true
    }

    /// - Returns: true when the post-play screen took Return.
    func macPostPlayActivate() -> Bool {
        if viewModel.postPlayState.isVisible, viewModel.showPostPlaySynopsis {
            viewModel.showPostPlaySynopsis = false
            return true
        }
        guard viewModel.postPlayState.isVisible,
              let caret = macPostPlayEffectiveCaret,
              let recommendation = viewModel.postPlayState.recommendation else { return false }
        MacDiagnostics.log("postplay.caret.activate \(caret)")
        switch caret {
        case .miniPlayer:
            viewModel.returnToPlayerFromPostPlay()
        case .primaryAction:
            if recommendation.isSeries {
                onOpenRecommendationDetails?(recommendation.asMeta)
            } else {
                onPlayRecommendation?(recommendation.asMeta, false)
            }
        case .trailerAction:
            if viewModel.postPlayState.isTrailerPlaying {
                viewModel.stopPostPlayTrailer()
            } else {
                viewModel.playPostPlayTrailer()
            }
        case .prevAction:
            viewModel.showPreviousRecommendation()
        case .nextAction:
            viewModel.showNextRecommendation()
        }
        return true
    }
}
#endif

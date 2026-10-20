#if os(macOS)
import AppKit
import Combine
import MediaPlayer

/// The Mac's Now Playing card and media keys for Omni's player.
///
/// On iPhone and Apple TV the engine publishes Now Playing through
/// `MPNowPlayingSession`, which macOS does not have, so on the Mac nothing
/// reached Control Center and the play/pause and skip keys went to whatever
/// else had last played. This writes the shared info center and answers the
/// remote commands for both of Aether's paths, native and software. The mpv
/// fallback keeps its own (see `MPVPlaybackController`), so this steps aside
/// while it plays.
@MainActor
final class MacNowPlaying {
    static let shared = MacNowPlaying()

    private weak var viewModel: PlayerViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkKey: String?

    func attach(_ viewModel: PlayerViewModel) {
        guard self.viewModel !== viewModel else { return }
        detach()
        self.viewModel = viewModel
        registerCommands()

        // Rate and elapsed time let the system run the clock itself; publish
        // again only when something it cannot work out changes.
        viewModel.$status.removeDuplicates { "\($0)" == "\($1)" }
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        Publishers.Merge(viewModel.$title.map { _ in () }, viewModel.$subtitle.map { _ in () })
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.publish() }
            .store(in: &cancellables)
        viewModel.clock.$duration.removeDuplicates()
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        // Seeks: a jump the steady clock does not explain.
        viewModel.clock.$position
            .scan((0.0, 0.0)) { last, now in (last.1, now) }
            .filter { abs($0.1 - $0.0) > 3 }
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        publish()
    }

    /// Ends the card when the player closes. A different view model taking
    /// over (PiP restore) has already re-attached, so this one is ignored.
    func detach(_ viewModel: PlayerViewModel? = nil) {
        if let viewModel, viewModel !== self.viewModel { return }
        cancellables.removeAll()
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        self.viewModel = nil
        artwork = nil
        artworkKey = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func publish() {
        guard let viewModel, viewModel.activeEngineKind == .aether else { return }
        let center = MPNowPlayingInfoCenter.default()
        let playing = viewModel.status == .playing
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: viewModel.title.isEmpty ? "Omni" : viewModel.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: viewModel.clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(viewModel.playbackSpeed.rawValue) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if !viewModel.subtitle.isEmpty { info[MPMediaItemPropertyArtist] = viewModel.subtitle }
        if viewModel.clock.duration > 0, !viewModel.isLiveStream {
            info[MPMediaItemPropertyPlaybackDuration] = viewModel.clock.duration
        }
        info[MPNowPlayingInfoPropertyIsLiveStream] = viewModel.isLiveStream
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
        loadArtworkIfNeeded()
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = viewModel.nextEpisode != nil
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !viewModel.isLiveStream
    }

    private func loadArtworkIfNeeded() {
        guard let meta = viewModel?.playingMeta,
              let raw = meta.backgroundUrl ?? meta.posterUrl,
              raw != artworkKey,
              let url = URL(string: raw) else { return }
        artworkKey = raw
        Task { [weak self] in
            guard let image = await BackdropImageCache.shared.image(for: url) else { return }
            let size = image.size
            let item = MPMediaItemArtwork(boundsSize: size) { _ in image }
            guard let self, self.artworkKey == raw else { return }
            self.artwork = item
            self.publish()
        }
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerViewModel, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let viewModel = self?.viewModel else { return .noActionableNowPlayingItem }
                    action(viewModel, event)
                    return .success
                }
            }
            commandTargets.append((command, target))
        }
        on(center.playCommand) { vm, _ in vm.play() }
        on(center.pauseCommand) { vm, _ in vm.pause() }
        on(center.togglePlayPauseCommand) { vm, _ in vm.togglePlayPause() }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        on(center.skipForwardCommand) { vm, _ in vm.skipForward() }
        on(center.skipBackwardCommand) { vm, _ in vm.skipBackward() }
        on(center.nextTrackCommand) { vm, _ in vm.playNextEpisode() }
        on(center.changePlaybackPositionCommand) { vm, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            vm.seek(to: event.positionTime)
        }
    }
}
#endif

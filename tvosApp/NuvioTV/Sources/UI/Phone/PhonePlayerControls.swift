#if os(iOS)
import AVKit
import CoreMotion
import SwiftUI

/// Touch controls over the shared player: tap to show/hide, double-tap either
/// side to skip, a draggable scrubber, and option panels for episodes,
/// sources, subtitles, audio and speed. Stands in for tvOS `PlayerControls`,
/// its Siri Remote catchers and the TV-sized overlays (skip HUD, pause sheet,
/// settings panel, side panels), which `PlayerView` leaves out on iOS.
struct PhonePlayerControls: View {
    @ObservedObject var viewModel: PlayerViewModel
    let isReady: Bool
    var autoPlayNextEnabled: Bool = true
    let onClose: () -> Void

    @State private var isVisible = true
    @State private var scrubValue: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: PhonePlayerPanel?
    @ObservedObject private var cast = PhoneCastController.shared
    /// This player's stream is on the Cast device and the phone is its remote.
    @State private var isCasting = false
    @AppStorage(PhoneScreenMode.storageKey) private var screenModeRaw = PhoneScreenMode.fit.rawValue
    @ObservedObject private var mini = PhoneMiniPlayerState.shared
    /// The phone is upright: video in a box at the top, the controls deck and
    /// the title's details beneath it, Netflix style.
    @State private var isPortrait = false
    /// The season the portrait episode list shows; nil follows the playing one.
    @State private var portraitSeason: Int?

    private var isPlaying: Bool { viewModel.status == .playing }

    var body: some View {
        Group {
            if isCasting {
                PhoneCastingView(
                    cast: cast,
                    title: viewModel.title,
                    subtitle: viewModel.subtitle,
                    backdropURL: viewModel.castableMedia?.backdropURL?.absoluteString,
                    seekStep: viewModel.seekStepSeconds,
                    onStop: { endCasting(at: cast.stopCasting()) },
                    onClose: onClose
                )
                .transition(.opacity)
            } else {
                localControls
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isCasting)
        // Shrunk to the mini bar: only the picture shows; the bar has the controls.
        .opacity(mini.isMini ? 0 : 1)
        .allowsHitTesting(!mini.isMini)
        .onAppear {
            mini.viewModel = viewModel
            applyScreenMode()
            cast.startDiscovery()
            if cast.isConnected { startCastingWhenReady() }
        }
        .onChange(of: screenModeRaw) { _, _ in applyScreenMode() }
        .onChange(of: viewModel.activeEngineKind) { _, _ in applyScreenMode() }
        .onChange(of: cast.isConnected) { _, connected in
            if connected {
                startCastingWhenReady()
            } else if isCasting {
                endCasting(at: cast.position)
            }
        }
        .onChange(of: isReady) { _, ready in
            if ready { applyScreenMode() }
            if ready, cast.isConnected, !isCasting { startCastingWhenReady() }
        }
        .onChange(of: cast.hasMedia) { _, hasMedia in
            // Finished, or stopped from the TV's own remote.
            if !hasMedia, isCasting { endCasting(at: cast.position) }
        }
        .onReceive(viewModel.aetherController.engine.airPlayReceiverRefused) { _ in
            viewModel.showCastMessage("That TV couldn't play this video's format over AirPlay, so it's back on your iPhone")
        }
        .onChange(of: cast.lastError) { _, error in
            guard let error else { return }
            viewModel.showCastMessage(error)
            if isCasting { endCasting(at: cast.position, resume: false) }
        }
    }

    private var localControls: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            ZStack {
                if portrait {
                    portraitLayout(size: proxy.size, bottomInset: proxy.safeAreaInsets.bottom)
                } else {
                    landscapeLayout
                }

                if let panel {
                    PhonePlayerPanelContainer(onDismiss: closePanel) {
                        panelContent(panel)
                    }
                    .transition(.opacity)
                }
            }
            .onAppear { updateLayout(portrait: portrait, topInset: proxy.safeAreaInsets.top) }
            .onChange(of: portrait) { _, now in updateLayout(portrait: now, topInset: proxy.safeAreaInsets.top) }
            .onChange(of: proxy.safeAreaInsets.top) { _, top in updateLayout(portrait: portrait, topInset: top) }
        }
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .animation(.easeInOut(duration: 0.2), value: panel)
        .animation(.easeOut(duration: 0.16), value: viewModel.pendingSeekDelta != 0)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showSkipSegmentCard)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showNextEpisodeCard)
        .onAppear {
            scheduleHide()
            PhoneOrientation.matchHeldOrientation()
            PhonePlayerPresence.shared.isVisible = true
            #if OMNI_DEBUG_TOOLS
            // `-OmniDebugPlayerPortrait YES`: turn upright once the player is
            // up, since the simulator cannot be rotated from the command line.
            if UserDefaults.standard.bool(forKey: "OmniDebugPlayerPortrait") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { PhoneOrientation.request(.portrait) }
            }
            #endif
        }
        .onDisappear {
            PhoneOrientation.request(.portrait)
            PhonePlayerPresence.shared.isVisible = false
            PhonePlayerLayout.shared.isPortrait = false
            if #unavailable(iOS 26.0), isPortrait { PhoneDeckSheen.shared.stop() }
        }
        .onChange(of: viewModel.status) { _, status in
            if status == .playing { scheduleHide() } else { hideTask?.cancel() }
        }
        .onChange(of: viewModel.isSwitchingSource) { _, switching in
            if switching { panel = nil }
        }
        // Upright, the status bar stays, as it does over Netflix's.
        .statusBarHidden(mini.isMini ? false : (isPortrait ? panel != nil : (!isVisible || panel != nil)))
        .persistentSystemOverlays(mini.isMini ? .automatic : .hidden)
    }

    private func updateLayout(portrait: Bool, topInset: CGFloat) {
        // Before iOS 26 the tiles light themselves from the tilt; Liquid
        // Glass does that on its own.
        if #unavailable(iOS 26.0), portrait != isPortrait {
            if portrait { PhoneDeckSheen.shared.start() } else { PhoneDeckSheen.shared.stop() }
        }
        isPortrait = portrait
        PhonePlayerLayout.shared.isPortrait = portrait
        PhonePlayerLayout.shared.topInset = topInset
        if portrait { hideTask?.cancel() } else { reveal() }
    }

    private var landscapeLayout: some View {
        ZStack {
            // Full-screen tap target; also the double-tap-to-skip zones.
            HStack(spacing: 0) {
                tapZone { viewModel.skipBackward() }
                tapZone { viewModel.skipForward() }
            }

            if isVisible, panel == nil {
                chrome
                    .transition(.opacity)
            }

            if viewModel.pendingSeekDelta != 0 {
                PhoneSeekIndicator(clock: viewModel.clock, delta: viewModel.pendingSeekDelta)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if panel == nil, isReady {
                promptCards(bottomPadding: isVisible ? 110 : 24)
            }
        }
    }


    private func tapZone(onDoubleTap: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard isReady else { return }
                onDoubleTap()
            }
            .onTapGesture {
                isVisible.toggle()
                if isVisible { scheduleHide() }
            }
    }

    // MARK: Portrait

    /// Upright: the picture in a 16:9 box under the status bar (placed there
    /// by `PlayerView`, at the top of this safe area), the controls deck below
    /// it on a frosted reflection of the picture, then the title's details.
    private func portraitLayout(size: CGSize, bottomInset: CGFloat) -> some View {
        let videoHeight = size.width * 9 / 16
        return ZStack(alignment: .top) {
            // The picture mirrored at its own size directly beneath it.
            PhonePlayerReflection(
                player: viewModel.aetherController.engine.currentAVPlayer,
                mirrorLayer: viewModel.aetherController.engine.softwareMirrorLayer,
                fallbackURL: viewModel.castableMedia?.backdropURL?.absoluteString
                    ?? viewModel.playingMeta?.backgroundUrl
            )
            .frame(width: size.width, height: videoHeight)
            .clipped()
            .padding(.top, videoHeight)
            .frame(width: size.width, height: size.height, alignment: .top)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 0) {
                        tapZone { viewModel.skipBackward() }
                        tapZone { viewModel.skipForward() }
                    }
                    if viewModel.pendingSeekDelta != 0 {
                        PhoneSeekIndicator(clock: viewModel.clock, delta: viewModel.pendingSeekDelta)
                            .scaleEffect(0.8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    if panel == nil, isReady {
                        promptCards(bottomPadding: 10)
                    }
                }
                .frame(height: videoHeight)
                // Pull the picture down to shrink the player into the mini bar
                // and keep browsing; the X closes it.
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            if value.translation.height > 90,
                               abs(value.translation.width) < value.translation.height {
                                if let minimize = PhoneMiniPlayerState.shared.minimize {
                                    minimize()
                                } else {
                                    onClose()
                                }
                            }
                        }
                )

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        portraitDeck
                        portraitDetails
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                    .frame(width: size.width)
                }
            }
            .frame(width: size.width)
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(.white)
    }

    private var portraitDeck: some View {
        PhoneGlassGroup { portraitDeckTiles }
    }

    private var portraitDeckTiles: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PhoneDuoTile(action: onClose) {
                    Image(systemName: "xmark").font(.headline)
                }
                .frame(width: 52)
                .accessibilityLabel("Close player")

                PhoneDuoTile(action: {
                    if viewModel.canShowEpisodesPanel { open(.episodes) }
                }) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !viewModel.subtitle.isEmpty {
                                Text(viewModel.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if viewModel.canShowEpisodesPanel {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .accessibilityLabel(viewModel.canShowEpisodesPanel ? "Episodes" : viewModel.title)

                if isReady {
                    PhoneDuoTileBackground {
                        PhoneRoutePicker(
                            prioritizesVideo: viewModel.activeEngineKind == .aether,
                            player: { viewModel.aetherController.engine.currentAVPlayer },
                            onSoundOnly: {
                                viewModel.showCastMessage(
                                    "This stream plays in Omni's own player, so AirPlay can send its sound but not the picture"
                                )
                            }
                        )
                    }
                    .frame(width: 52)
                    .accessibilityLabel("AirPlay")

                    PhoneDuoTileBackground {
                        PhoneCastButton().frame(width: 26, height: 26)
                    }
                    .frame(width: 52)
                    .accessibilityLabel("Cast")
                }
            }
            .frame(height: 52)

            if isReady {
                HStack(spacing: 8) {
                    PhoneDuoTile(action: { viewModel.skipBackward() }) {
                        Image(systemName: "gobackward.\(viewModel.seekStepSeconds)").font(.title2)
                    }
                    .disabled(viewModel.isLiveStream)
                    .accessibilityLabel("Back \(viewModel.seekStepSeconds) seconds")

                    PhoneDuoTile(prominent: true, action: { viewModel.togglePlayPause() }) {
                        Group {
                            if viewModel.status == .buffering {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 34))
                            }
                        }
                    }
                    .layoutPriority(1)
                    .frame(minWidth: 140)
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")

                    PhoneDuoTile(action: { viewModel.skipForward() }) {
                        Image(systemName: "goforward.\(viewModel.seekStepSeconds)").font(.title2)
                    }
                    .disabled(viewModel.isLiveStream)
                    .accessibilityLabel("Forward \(viewModel.seekStepSeconds) seconds")
                }
                .frame(height: 88)

                PhoneDuoTileBackground {
                    timeline.padding(.horizontal, 14).padding(.vertical, 8)
                }

                HStack(spacing: 8) {
                    PhoneDuoTile(action: { open(.speed) }) {
                        portraitOption(
                            viewModel.playbackSpeed == .normal ? "Speed" : viewModel.playbackSpeed.label,
                            icon: "gauge.with.dots.needle.67percent"
                        )
                    }
                    PhoneDuoTile(action: { open(.subtitles) }) {
                        portraitOption("Subtitles", icon: subtitlesOn ? "captions.bubble.fill" : "captions.bubble")
                    }
                    PhoneDuoTile(action: { open(.audio) }) {
                        portraitOption("Audio", icon: "speaker.wave.2")
                    }
                    if viewModel.canShowSourcesPanel {
                        PhoneDuoTile(action: { open(.sources) }) {
                            portraitOption("Sources", icon: "arrow.triangle.branch")
                        }
                    }
                    if viewModel.isPictureInPictureSupported, viewModel.isPictureInPicturePossible {
                        PhoneDuoTile(action: { viewModel.togglePictureInPicture() }) {
                            portraitOption("PiP", icon: viewModel.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        }
                    }
                    PhoneDuoTile(action: { PhoneOrientation.request(.landscape) }) {
                        portraitOption("Full Screen", icon: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .frame(height: 54)
            }
        }
    }

    private func portraitOption(_ title: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
            Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    /// What is playing, beneath the deck: the title's official logo, then for
    /// a show its episodes by season (tap one to play it), for a film its
    /// synopsis, cast and director.
    @ViewBuilder
    private var portraitDetails: some View {
        let meta = viewModel.playingMeta
        VStack(alignment: .leading, spacing: 14) {
            if let meta, meta.logoUrl != nil {
                PhoneTitleLogo(meta: meta, maxWidth: 220, maxHeight: 70)
            } else if !viewModel.title.isEmpty {
                // No logo to show: the name stands in.
                Text(viewModel.title).font(.title2.weight(.bold))
            }

            let facts = [meta?.year.map(String.init), meta?.genres?.prefix(2).joined(separator: ", "), meta?.runtime]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  "))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }

            if viewModel.canShowEpisodesPanel {
                portraitEpisodes
            } else if let meta {
                portraitMovieInfo(meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var portraitSeasons: [Int] {
        Array(Set(viewModel.panelEpisodes.map(\.season))).sorted { a, b in
            // Specials (season 0) after the numbered seasons.
            (a == 0 ? Int.max : a) < (b == 0 ? Int.max : b)
        }
    }

    private var shownSeason: Int? {
        portraitSeason ?? viewModel.playingEpisode?.season ?? portraitSeasons.first
    }

    @ViewBuilder
    private var portraitEpisodes: some View {
        let seasons = portraitSeasons
        if seasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons, id: \.self) { season in
                        let selected = season == shownSeason
                        Button { portraitSeason = season } label: {
                            Text(season == 0 ? "Specials" : "Season \(season)")
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
                                .foregroundStyle(selected ? Color.black : Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        LazyVStack(spacing: 8) {
            ForEach(viewModel.panelEpisodes.filter { $0.season == shownSeason }) { episode in
                portraitEpisodeRow(episode)
            }
        }
    }

    private func portraitEpisodeRow(_ episode: NuvioVideo) -> some View {
        let isCurrent = episode.id == viewModel.panelCurrentEpisodeId
        return Button { viewModel.selectEpisode(episode) } label: {
            HStack(alignment: .top, spacing: 12) {
                PhoneArtwork(
                    url: episode.thumbnail ?? viewModel.playingMeta?.backgroundUrl,
                    kind: .backdrop,
                    fallbacks: [viewModel.playingMeta?.backgroundUrl, viewModel.playingMeta?.posterUrl]
                )
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if isCurrent {
                        Text("Playing")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.white, in: Capsule())
                            .padding(5)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(episode.episode). \(episode.title)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isCurrent ? Color.white.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func portraitMovieInfo(_ meta: NuvioMeta) -> some View {
        if let synopsis = meta.description, !synopsis.isEmpty {
            Text(synopsis)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let cast = meta.cast, !cast.isEmpty {
            portraitCredit("Cast", cast.prefix(8).joined(separator: ", "))
        }
        if let director = meta.director, !director.isEmpty {
            portraitCredit(director.count == 1 ? "Director" : "Directors", director.joined(separator: ", "))
        }
    }

    private func portraitCredit(_ label: String, _ names: String) -> some View {
        (Text(label + "  ").foregroundStyle(.white.opacity(0.5)) + Text(names).foregroundStyle(.white.opacity(0.85)))
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Chrome

    private var chrome: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 8)
                if isReady { transport }
                Spacer(minLength: 8)
                if isReady {
                    timeline
                    optionsRow
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close player")

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.title).font(.headline).lineLimit(1)
                if !viewModel.subtitle.isEmpty {
                    Text(viewModel.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isReady {
                // AirPlay. AetherEngine moves its loopback stream onto the LAN
                // while a receiver is active, so the video itself goes across;
                // under MPV only the audio can be routed.
                PhoneRoutePicker(
                    prioritizesVideo: viewModel.activeEngineKind == .aether,
                    player: { viewModel.aetherController.engine.currentAVPlayer },
                    onSoundOnly: {
                        viewModel.showCastMessage(
                            "This stream plays in Omni's own player, so AirPlay can send its sound but not the picture"
                        )
                    }
                )
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("AirPlay")
            }

            if isReady {
                PhoneCastButton()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Cast")
            }

            if isReady, viewModel.isPictureInPictureSupported, viewModel.isPictureInPicturePossible {
                Button { viewModel.togglePictureInPicture() } label: {
                    Image(systemName: viewModel.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Picture in Picture")
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 56) {
            Button { viewModel.skipBackward(); reveal() } label: {
                Image(systemName: "gobackward.\(viewModel.seekStepSeconds)")
                    .font(.title)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .disabled(viewModel.isLiveStream)
            Button { viewModel.togglePlayPause(); reveal() } label: {
                Group {
                    if viewModel.status == .buffering {
                        // The shared player draws the buffering spinner in
                        // the centre; a second one here stacked on top of it.
                        Color.clear
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .font(.largeTitle)
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
            }
            Button { viewModel.skipForward(); reveal() } label: {
                Image(systemName: "goforward.\(viewModel.seekStepSeconds)")
                    .font(.title)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .disabled(viewModel.isLiveStream)
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if viewModel.isLiveStream {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("LIVE").font(.caption.weight(.bold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            PhonePlayerTimeline(
                clock: viewModel.clock,
                scrubValue: $scrubValue,
                onBeginScrub: { hideTask?.cancel() },
                onCommit: { target in
                    viewModel.seek(to: target)
                    scheduleHide()
                }
            )
        }
    }

    /// The option buttons under the scrubber. Labels when they fit (landscape),
    /// icons alone when they don't (portrait).
    private var optionsRow: some View {
        ViewThatFits(in: .horizontal) {
            optionButtons(showLabels: true)
            optionButtons(showLabels: false)
        }
    }

    private func optionButtons(showLabels: Bool) -> some View {
        HStack(spacing: showLabels ? 8 : 4) {
            if viewModel.canShowEpisodesPanel {
                optionButton("Episodes", icon: "rectangle.stack", showLabel: showLabels) { open(.episodes) }
            }
            if viewModel.canShowSourcesPanel {
                optionButton("Sources", icon: "arrow.triangle.branch", showLabel: showLabels) { open(.sources) }
            }
            optionButton("Subtitles", icon: subtitlesOn ? "captions.bubble.fill" : "captions.bubble", showLabel: showLabels) { open(.subtitles) }
            optionButton("Audio", icon: "speaker.wave.2", showLabel: showLabels) { open(.audio) }
            optionButton("Screen", icon: "aspectratio", showLabel: showLabels) { open(.screen) }
            optionButton(viewModel.playbackSpeed == .normal ? "Speed" : viewModel.playbackSpeed.label,
                         icon: "gauge.with.dots.needle.67percent", showLabel: showLabels) { open(.speed) }
            Spacer(minLength: 0)
            if let next = viewModel.nextEpisode, EpisodeReleasePolicy.hasAired(next.released) {
                optionButton("Next Episode", icon: "forward.end", showLabel: showLabels) {
                    viewModel.playNextEpisode()
                }
            }
        }
    }

    private func optionButton(_ title: String, icon: String, showLabel: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                if showLabel { Text(title).lineLimit(1) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, showLabel ? 12 : 10)
            .frame(minWidth: 44, minHeight: 36)
            .background(.white.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
            .fixedSize()
        }
        .accessibilityLabel(title)
    }

    private var subtitlesOn: Bool {
        viewModel.subtitles.contains { $0.isSelected && $0.id != "off" }
    }

    // MARK: Skip intro / next episode

    private func promptCards(bottomPadding: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            if viewModel.showSkipSegmentCard, let interval = viewModel.activeSkipInterval {
                Button { viewModel.skipActiveInterval() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "forward.end.fill")
                        Text(interval.label)
                        if let countdown = viewModel.skipSegmentCountdown {
                            Text("\(countdown)")
                                .foregroundStyle(.black.opacity(0.5))
                                .contentTransition(.numericText())
                        }
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.white, in: Capsule())
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if viewModel.showNextEpisodeCard, let next = viewModel.nextEpisode {
                PhoneNextEpisodeCard(
                    episode: next,
                    isAdvancing: viewModel.isAdvancingEpisode,
                    isAutoPlayCancelled: viewModel.isAutoPlayCancelled,
                    showsCancel: autoPlayNextEnabled && !viewModel.isAutoPlayCancelled && !viewModel.isAdvancingEpisode,
                    onPlay: { viewModel.playNextEpisode() },
                    onCancel: { viewModel.cancelAutoPlay() }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, isPortrait ? 12 : 20)
        // Clear the scrubber and option row while the chrome is up.
        .padding(.bottom, bottomPadding)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
    }

    // MARK: Panels

    private func open(_ panel: PhonePlayerPanel) {
        hideTask?.cancel()
        if panel == .sources { viewModel.loadSourcesIfNeeded() }
        self.panel = panel
    }

    private func closePanel() {
        panel = nil
        reveal()
    }

    @ViewBuilder
    private func panelContent(_ panel: PhonePlayerPanel) -> some View {
        switch panel {
        case .subtitles:
            PhoneSubtitlesPanel(viewModel: viewModel, onClose: closePanel)
        case .audio:
            PhoneAudioPanel(viewModel: viewModel, onClose: closePanel)
        case .speed:
            PhoneSpeedPanel(viewModel: viewModel, onClose: closePanel)
        case .episodes:
            PhoneEpisodesPanel(viewModel: viewModel, onClose: closePanel)
        case .sources:
            PhoneSourcesPanel(viewModel: viewModel, onClose: closePanel)
        case .screen:
            PhoneScreenPanel(onClose: closePanel)
        }
    }

    private func applyScreenMode() {
        viewModel.setAspectMode((PhoneScreenMode(rawValue: screenModeRaw) ?? .fit).engineMode)
    }

    // MARK: Cast

    private func startCastingWhenReady() {
        guard isReady, !isCasting, let media = viewModel.castableMedia else { return }
        if let reason = cast.load(media) {
            viewModel.showCastMessage(reason)
            return
        }
        viewModel.pause()
        panel = nil
        isCasting = true
    }

    /// Back to the phone, at the point the Cast device reached.
    private func endCasting(at position: Double, resume: Bool = true) {
        isCasting = false
        if position > 1, !viewModel.isLiveStream { viewModel.seek(to: position) }
        if resume { viewModel.play() }
        reveal()
    }

    private func reveal() {
        isVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // Upright the deck stays: it sits below the picture, not over it.
        guard isPlaying, panel == nil, !isPortrait else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, scrubValue == nil, panel == nil else { return }
            isVisible = false
        }
    }
}

private enum PhonePlayerPanel: Hashable {
    case subtitles, audio, speed, episodes, sources, screen
}

/// How the picture fills the phone screen. Applied by `PlayerView` as a scale
/// on the video surface, worked out from the video's own size, so it behaves
/// the same under either engine.
enum PhoneScreenMode: String, CaseIterable, Identifiable {
    case fit, zoom, stretch, ratio16x9, ratio4x3, ratio21x9, ratio185

    static let storageKey = "phone.player.screenMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "Fit to Screen"
        case .zoom: return "Zoom"
        case .stretch: return "Stretch"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        case .ratio21x9: return "21:9"
        case .ratio185: return "1.85:1"
        }
    }

    var detail: String {
        switch self {
        case .fit: return "The whole picture, with black bars"
        case .zoom: return "Fill the screen, cropping the edges"
        case .stretch: return "Fill the screen, distorting the picture"
        case .ratio16x9: return "Widescreen TV"
        case .ratio4x3: return "Classic TV"
        case .ratio21x9: return "Ultrawide cinema"
        case .ratio185: return "Flat cinema"
        }
    }

    /// The shape of the box the video is drawn in, for the fixed ratios.
    var forcedRatio: CGFloat? {
        switch self {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio21x9: return 21.0 / 9.0
        case .ratio185: return 1.85
        default: return nil
        }
    }

    /// What the engine does inside that box.
    var engineMode: PlayerAspectMode {
        switch self {
        case .fit: return .fit
        case .zoom: return .fill
        default: return .stretch
        }
    }
}

extension View {
    /// Confines the video surface to `ratio`, centred, when one is set.
    ///
    /// Always wraps in the same layout: switching between a plain view and a
    /// ratio-framed one would change the surface's identity, and rebuilding
    /// the video surface mid-playback leaves it black.
    func phoneScreenFrame(ratio: CGFloat?) -> some View {
        PhoneRatioLayout(ratio: ratio) { self }
    }
}

/// Lays out one child at the full proposal, or at `ratio` fitted inside it.
private struct PhoneRatioLayout: Layout {
    var ratio: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        var size = bounds.size
        if let ratio, size.width > 0, size.height > 0 {
            size = size.width / size.height > ratio
                ? CGSize(width: size.height * ratio, height: size.height)
                : CGSize(width: size.width, height: size.width / ratio)
        }
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
    }
}

// MARK: - Seek indicator

/// Double-tap skip feedback: the running offset on the side being tapped and
/// the time it will land on. Replaces the TV's SeekHUD bar, which drew a
/// second scrubber over the phone's own.
private struct PhoneSeekIndicator: View {
    @ObservedObject var clock: PlaybackClock
    let delta: Double

    var body: some View {
        HStack {
            if delta > 0 { Spacer() }
            bubble
            if delta < 0 { Spacer() }
        }
        .padding(.horizontal, 60)
    }

    private var bubble: some View {
        VStack(spacing: 4) {
            Image(systemName: delta > 0 ? "goforward" : "gobackward")
                .font(.title2.weight(.semibold))
            Text((delta > 0 ? "+" : "−") + "\(Int(abs(delta).rounded()))s")
                .font(.headline.monospacedDigit())
            Text(PhonePlayerTimeline.format(min(max(clock.position + delta, 0), max(clock.duration, 0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .frame(width: 96, height: 96)
        .background(.black.opacity(0.45), in: Circle())
    }
}

// MARK: - Next episode card

private struct PhoneNextEpisodeCard: View {
    let episode: NuvioVideo
    let isAdvancing: Bool
    let isAutoPlayCancelled: Bool
    let showsCancel: Bool
    let onPlay: () -> Void
    let onCancel: () -> Void

    private var hasAired: Bool { EpisodeReleasePolicy.hasAired(episode.released) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    PhoneArtwork(url: episode.thumbnail)
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next Episode")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("S\(episode.season) E\(episode.episode) · \(episode.title)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if !hasAired {
                            Text(EpisodeReleasePolicy.airDateText(for: episode.released).map { "Airs \($0)" } ?? "Upcoming")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        } else if isAutoPlayCancelled {
                            Text("Auto-Play cancelled")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if hasAired {
                        Group {
                            if isAdvancing {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "play.fill").font(.headline)
                            }
                        }
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(.white, in: Circle())
                    }
                }
                .padding(10)
                .frame(width: 320)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .environment(\.colorScheme, .dark)
            }
            .buttonStyle(.plain)
            .disabled(!hasAired || isAdvancing)

            if showsCancel, hasAired {
                Button("Cancel Auto-Play", action: onCancel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.14), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

// MARK: - Panel container

/// Option panels slide over the video: a side sheet in landscape, a bottom
/// sheet in portrait. Tapping the dimmed video closes them.
private struct PhonePlayerPanelContainer<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            ZStack(alignment: landscape ? .trailing : .bottom) {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                content
                    .frame(
                        width: landscape ? min(400, proxy.size.width * 0.55) : proxy.size.width,
                        height: landscape ? proxy.size.height : proxy.size.height * 0.62
                    )
                    .background {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 20,
                            bottomLeadingRadius: landscape ? 20 : 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: landscape ? 0 : 20,
                            style: .continuous
                        )
                        .fill(Color(white: 0.09).opacity(0.97))
                        .ignoresSafeArea(edges: landscape ? [.vertical, .trailing] : [.bottom, .horizontal])
                    }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

/// Title row and scrolling body shared by every panel.
private struct PhonePanelScaffold<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    content
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct PhonePanelRow: View {
    let title: String
    var subtitle: String? = nil
    var badge: String? = nil
    var trailing: String? = nil
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if let badge, !badge.isEmpty {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.12), in: Capsule())
                                .lineLimit(1)
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 6)
                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PhonePanelSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

/// "Delay  [−] +0.2s [+]" and the like. Tapping the value resets it.
private struct PhonePanelStepper: View {
    let title: String
    let value: String
    let onMinus: () -> Void
    let onPlus: () -> Void
    var onReset: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline)
            Spacer()
            stepButton("minus", action: onMinus)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 64)
                .onTapGesture { onReset?() }
            stepButton("plus", action: onPlus)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct PhonePanelToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

private func formatDelay(_ ms: Int) -> String {
    if ms == 0 { return "0.0s" }
    return (ms > 0 ? "+" : "−") + String(format: "%.1fs", abs(Double(ms)) / 1000)
}

// MARK: - Subtitles

private struct PhoneSubtitlesPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onClose: () -> Void
    @State private var style = SubtitleStyle.current

    private struct Option: Identifiable {
        enum Kind { case track(SubtitleTrack), external(NuvioSubtitle) }
        let id: String
        let kind: Kind
        let title: String
        let badge: String
        let detail: String?
        let language: String
        let isSelected: Bool
    }

    private static let palette = ["#FFFFFF", "#C7C7C7", "#F2C94C", "#56CCF2", "#EB5757", "#6FCF97"]

    var body: some View {
        PhonePanelScaffold(title: "Subtitles", onClose: onClose) {
            PhonePanelRow(title: "Off", isSelected: isOff) {
                if let off = viewModel.subtitles.first(where: { $0.id == "off" }) {
                    viewModel.selectSubtitle(off)
                }
            }

            ForEach(groups, id: \.language) { group in
                PhonePanelSectionHeader(title: group.language)
                ForEach(group.options) { option in
                    PhonePanelRow(
                        title: option.title,
                        subtitle: option.detail,
                        badge: option.badge,
                        isSelected: option.isSelected
                    ) {
                        switch option.kind {
                        case .track(let track): viewModel.selectSubtitle(track)
                        case .external(let subtitle): viewModel.selectExternalSubtitle(subtitle)
                        }
                    }
                }
            }

            PhonePanelSectionHeader(title: "Timing")
            PhonePanelStepper(
                title: "Delay",
                value: formatDelay(viewModel.subtitleDelayMs),
                onMinus: { viewModel.setSubtitleDelayMs(viewModel.subtitleDelayMs - 100) },
                onPlus: { viewModel.setSubtitleDelayMs(viewModel.subtitleDelayMs + 100) },
                onReset: { viewModel.setSubtitleDelayMs(0) }
            )
            if viewModel.canManuallyToggleAISubtitleTranslation {
                PhonePanelToggle(title: "AI Translation", isOn: viewModel.isAISubtitleTranslationManuallyEnabled) {
                    viewModel.setAISubtitleTranslationManuallyEnabled(!viewModel.isAISubtitleTranslationManuallyEnabled)
                }
            }

            PhonePanelSectionHeader(title: "Style")
            PhonePanelStepper(
                title: "Size",
                value: "\(style.textSize)%",
                onMinus: { updateStyle { $0.textSize = max($0.textSize - 10, 60) } },
                onPlus: { updateStyle { $0.textSize = min($0.textSize + 10, 220) } }
            )
            PhonePanelToggle(title: "Bold", isOn: style.bold) { updateStyle { $0.bold.toggle() } }
            HStack(spacing: 12) {
                Text("Colour").font(.subheadline)
                Spacer()
                ForEach(Self.palette, id: \.self) { hex in
                    let selected = style.textColorHex.caseInsensitiveCompare(hex) == .orderedSame
                    Button { updateStyle { $0.textColorHex = hex } } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            PhonePanelToggle(title: "Outline", isOn: style.outlineEnabled) { updateStyle { $0.outlineEnabled.toggle() } }
            PhonePanelToggle(title: "Background", isOn: style.backgroundEnabled) { updateStyle { $0.backgroundEnabled.toggle() } }
        }
    }

    private var isOff: Bool {
        !viewModel.subtitles.contains { $0.isSelected && $0.id != "off" }
    }

    private var options: [Option] {
        let externalURLs = Set(viewModel.availableExternalSubtitles.map(\.url))
        var options: [Option] = []
        for track in viewModel.subtitles where track.id != "off" {
            // Loaded add-on subtitles are listed from the add-on list below.
            if !track.externalFilename.isEmpty, externalURLs.contains(track.externalFilename) { continue }
            let language = Self.languageName(track.language.isEmpty ? track.name : track.language)
            options.append(Option(
                id: "track-\(track.id)",
                kind: .track(track),
                title: track.name.isEmpty ? language : track.name,
                badge: track.externalFilename.isEmpty ? "Built in" : "External",
                detail: nil,
                language: language,
                isSelected: track.isSelected
            ))
        }
        for subtitle in viewModel.availableExternalSubtitles {
            let language = Self.languageName(subtitle.language)
            let loaded = viewModel.subtitles.first { $0.externalFilename == subtitle.url }
            let detail = subtitle.label.flatMap { $0.caseInsensitiveCompare(language) == .orderedSame ? nil : $0 }
            options.append(Option(
                id: "ext-\(subtitle.url)",
                kind: .external(subtitle),
                title: language,
                badge: subtitle.source ?? "Add-on",
                detail: detail,
                language: language,
                isSelected: loaded?.isSelected ?? false
            ))
        }
        return options
    }

    /// Preferred subtitle languages first, then the rest alphabetically.
    private var groups: [(language: String, options: [Option])] {
        var order: [String] = []
        var byLanguage: [String: [Option]] = [:]
        for option in options {
            if byLanguage[option.language] == nil { order.append(option.language) }
            byLanguage[option.language, default: []].append(option)
        }
        let preferred = SubtitleLanguagePreferences.orderedFromDefaults()
        func rank(_ language: String) -> Int? {
            preferred.firstIndex { SubtitleLanguagePreferences.matches(language, target: $0) }
        }
        return order
            .sorted { lhs, rhs in
                switch (rank(lhs), rank(rhs)) {
                case let (l?, r?) where l != r: return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
            }
            .map { (language: $0, options: byLanguage[$0] ?? []) }
    }

    private static func languageName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        let code = trimmed.lowercased().components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? ""
        if code.count <= 3, code.allSatisfy(\.isLetter),
           let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private func updateStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        mutate(&style)
        let defaults = ProfileSettings.current
        defaults.set(style.textSize, forKey: SubtitleStyleKey.textSize)
        defaults.set(style.bold, forKey: SubtitleStyleKey.bold)
        defaults.set(style.textColorHex, forKey: SubtitleStyleKey.textColor)
        defaults.set(style.textOpacity, forKey: SubtitleStyleKey.textOpacity)
        defaults.set(style.outlineEnabled, forKey: SubtitleStyleKey.outlineEnabled)
        defaults.set(style.outlineColorHex, forKey: SubtitleStyleKey.outlineColor)
        defaults.set(style.backgroundEnabled, forKey: SubtitleStyleKey.backgroundEnabled)
        defaults.set(style.backgroundColorHex, forKey: SubtitleStyleKey.backgroundColor)
        defaults.set(style.backgroundOpacity, forKey: SubtitleStyleKey.backgroundOpacity)
        viewModel.applySubtitleStyle()
    }
}

// MARK: - Audio

private struct PhoneAudioPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onClose: () -> Void

    var body: some View {
        PhonePanelScaffold(title: "Audio", onClose: onClose) {
            if viewModel.audioTracks.isEmpty {
                Text("No audio tracks")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(12)
            }
            ForEach(viewModel.audioTracks) { track in
                PhonePanelRow(
                    title: title(for: track),
                    subtitle: [track.name.isEmpty ? "" : track.languageName, track.detail]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    isSelected: track.isSelected
                ) {
                    viewModel.selectAudio(track)
                }
            }

            // Delay and boost are applied by mpv; AetherEngine ignores them.
            if viewModel.activeEngineKind == .mpv {
                PhonePanelSectionHeader(title: "Adjust")
                PhonePanelStepper(
                    title: "Delay",
                    value: formatDelay(viewModel.audioDelayMs),
                    onMinus: { viewModel.setAudioDelayMs(viewModel.audioDelayMs - 50) },
                    onPlus: { viewModel.setAudioDelayMs(viewModel.audioDelayMs + 50) },
                    onReset: { viewModel.setAudioDelayMs(0) }
                )
                PhonePanelStepper(
                    title: "Boost",
                    value: "\(viewModel.audioAmplificationDb) dB",
                    onMinus: { viewModel.setAudioAmplificationDb(viewModel.audioAmplificationDb - 1) },
                    onPlus: { viewModel.setAudioAmplificationDb(viewModel.audioAmplificationDb + 1) },
                    onReset: { viewModel.setAudioAmplificationDb(0) }
                )
            }
        }
    }

    private func title(for track: AudioTrack) -> String {
        if !track.name.isEmpty { return track.name }
        if !track.languageName.isEmpty { return track.languageName }
        return track.language.isEmpty ? "Track \(track.id)" : track.language
    }
}

// MARK: - Speed

private struct PhoneSpeedPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onClose: () -> Void

    var body: some View {
        PhonePanelScaffold(title: "Playback", onClose: onClose) {
            PhonePanelSectionHeader(title: "Speed")
            ForEach(PlaybackSpeed.allCases) { speed in
                PhonePanelRow(title: speed.label, isSelected: viewModel.playbackSpeed == speed) {
                    viewModel.setSpeed(speed)
                }
            }
            PhonePanelSectionHeader(title: "Skip interval")
            HStack(spacing: 6) {
                ForEach(PlayerSeekSettings.validSteps, id: \.self) { step in
                    let selected = viewModel.seekStepSeconds == step
                    Button { viewModel.setSeekStepSeconds(step) } label: {
                        Text("\(step)s")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(selected ? Color.white : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Screen

private struct PhoneScreenPanel: View {
    let onClose: () -> Void
    @AppStorage(PhoneScreenMode.storageKey) private var modeRaw = PhoneScreenMode.fit.rawValue

    var body: some View {
        PhonePanelScaffold(title: "Screen", onClose: onClose) {
            ForEach(PhoneScreenMode.allCases) { mode in
                PhonePanelRow(title: mode.label, subtitle: mode.detail, isSelected: modeRaw == mode.rawValue) {
                    modeRaw = mode.rawValue
                }
            }
        }
    }
}

// MARK: - Episodes

private struct PhoneEpisodesPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onClose: () -> Void

    var body: some View {
        PhonePanelScaffold(title: "Episodes", onClose: onClose) {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.panelEpisodes) { episode in
                        row(episode)
                            .id(episode.id)
                    }
                }
                .onAppear {
                    if let current = viewModel.panelCurrentEpisodeId {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(_ episode: NuvioVideo) -> some View {
        let isCurrent = episode.id == viewModel.panelCurrentEpisodeId
        return Button { viewModel.selectEpisode(episode) } label: {
            HStack(spacing: 10) {
                PhoneArtwork(url: episode.thumbnail)
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if isCurrent {
                            Text("Playing")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white, in: Capsule())
                                .padding(4)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("S\(episode.season) E\(episode.episode)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isCurrent ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sources

private struct PhoneSourcesPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onClose: () -> Void

    var body: some View {
        PhonePanelScaffold(title: "Sources", onClose: onClose) {
            if viewModel.isLoadingSources, viewModel.availableSources.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Finding sources…").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if viewModel.availableSources.isEmpty {
                VStack(spacing: 10) {
                    Text("No other sources found")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                    Button("Search again") { viewModel.loadSourcesIfNeeded(force: true) }
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                PhoneSourceFilterBar(
                    providers: viewModel.macSourceProviders.map { .init(id: $0, name: $0) },
                    selectedProvider: viewModel.macSourceProvider,
                    onSelectProvider: { viewModel.macSourceProvider = $0 },
                    resolution: Binding(get: { viewModel.macSourceResolution }, set: { viewModel.macSourceResolution = $0 }),
                    sort: Binding(get: { viewModel.macSourceSort }, set: { viewModel.macSourceSort = $0 }),
                    cachedOnly: Binding(get: { viewModel.macSourceCachedOnly }, set: { viewModel.macSourceCachedOnly = $0 }),
                    showsCachedOnly: viewModel.macSourceIncludesDebrid,
                    onDarkBackground: true,
                    horizontalInset: 0
                )
                let shown = viewModel.macDisplayedSources
                if shown.isEmpty {
                    Text("No sources match these filters.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                ForEach(shown, id: \.id) { stream in
                    PhonePanelRow(
                        title: stream.panelTitle,
                        subtitle: stream.panelSubtitle,
                        trailing: stream.panelResolutionLabel,
                        isSelected: viewModel.isCurrentSource(stream)
                    ) {
                        viewModel.selectSource(stream)
                    }
                }
            }
        }
        .onAppear { viewModel.loadSourcesIfNeeded() }
    }
}

// MARK: - Timeline

/// Position and scrubber. Observes `PlaybackClock` directly: the clock ticks
/// many times a second and is kept off `PlayerViewModel` so those ticks
/// re-render only this.
struct PhonePlayerTimeline: View {
    @ObservedObject var clock: PlaybackClock
    @Binding var scrubValue: Double?
    let onBeginScrub: () -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        let duration = max(clock.duration, 1)
        let shown = min(scrubValue ?? clock.position, duration)
        VStack(spacing: 4) {
            PhoneScrubBar(
                fraction: shown / duration,
                isScrubbing: scrubValue != nil,
                onChanged: { fraction in
                    if scrubValue == nil { onBeginScrub() }
                    scrubValue = fraction * duration
                },
                onEnded: {
                    if let target = scrubValue {
                        scrubValue = nil
                        onCommit(target)
                    }
                }
            )
            HStack {
                Text(Self.format(shown))
                Spacer()
                Text("-" + Self.format(max(duration - shown, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A thin track that thickens while dragged, with a knob. The system Slider
/// has an unfilled track that vanishes over bright video and an oversized
/// glass thumb on iOS 26. The whole 32pt-tall strip takes the drag.
struct PhoneScrubBar: View {
    let fraction: Double
    let isScrubbing: Bool
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let clamped = min(max(fraction, 0), 1)
            let trackHeight: CGFloat = isScrubbing ? 8 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                    .frame(height: trackHeight)
                Capsule().fill(.white)
                    .frame(width: width * clamped, height: trackHeight)
                Circle().fill(.white)
                    .frame(width: isScrubbing ? 20 : 14, height: isScrubbing ? 20 : 14)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .offset(x: width * clamped - (isScrubbing ? 10 : 7))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onChanged(min(max(value.location.x / width, 0), 1)) }
                    .onEnded { _ in onEnded() }
            )
            .animation(.easeOut(duration: 0.15), value: isScrubbing)
        }
        .frame(height: 32)
    }
}

/// The system AirPlay button, styled for the player chrome.
private struct PhoneRoutePicker: UIViewRepresentable {
    let prioritizesVideo: Bool
    /// Apple's player, when that is what plays the stream; nil when mpv does.
    var player: () -> AVPlayer? = { nil }
    /// Called as the list opens on a stream only its sound can follow.
    var onSoundOnly: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.backgroundColor = .clear
        picker.prioritizesVideoDevices = prioritizesVideo
        picker.delegate = context.coordinator
        context.coordinator.parent = self
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.prioritizesVideoDevices = prioritizesVideo
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVRoutePickerViewDelegate {
        var parent: PhoneRoutePicker?

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            guard let parent else { return }
            guard let player = parent.player() else {
                // AirPlay video goes through Apple's player only; mpv's sound
                // still follows the system route.
                parent.onSoundOnly()
                return
            }
            // Off if a TV refused the last stream; the viewer is choosing again.
            player.allowsExternalPlayback = true
        }
    }
}

/// Whether the full-screen player is up. Pages underneath it stay mounted,
/// so anything they play themselves (the details page trailer) pauses on it.
@MainActor
final class PhonePlayerPresence: ObservableObject {
    static let shared = PhonePlayerPresence()
    @Published var isVisible = false
}

/// Sets the player's starting orientation and turns back to portrait
/// afterwards. The user can still rotate freely; this only sets the start.
enum PhoneOrientation {
    /// Video opens the way the phone is held: on its side, in landscape;
    /// upright, flat or unknown, it stays in portrait with the portrait player.
    static func matchHeldOrientation() {
        let device = UIDevice.current
        if !device.isGeneratingDeviceOrientationNotifications {
            device.beginGeneratingDeviceOrientationNotifications()
        }
        if device.orientation.isLandscape {
            request(.landscape)
        }
    }

    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif

#if os(iOS)
/// How the phone is tilted, for the sheen on the portrait deck's tiles: light
/// sliding across glass as it would if the tiles were real. Netflix's Duo
/// player drives the same thing from the hinge angle and the light sensor;
/// an ordinary iPhone has neither to offer an app, so the tilt alone does it.
/// Runs only while the portrait deck is on screen.
@MainActor
@Observable
final class PhoneDeckSheen {
    static let shared = PhoneDeckSheen()
    /// -1...1, left to right and top to bottom.
    private(set) var x: Double = 0
    private(set) var y: Double = 0

    private let motion = CMMotionManager()
    private var users = 0

    func start() {
        users += 1
        guard users == 1, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            // Gravity rather than attitude: no drift, and flat on a table is still.
            let nx = max(-1, min(1, gravity.x * 1.6))
            let ny = max(-1, min(1, (gravity.y + 0.55) * 1.6))
            // Ease toward the reading so the light glides rather than jitters.
            self.x += (nx - self.x) * 0.25
            self.y += (ny - self.y) * 0.25
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        motion.stopDeviceMotionUpdates()
        x = 0
        y = 0
    }
}

/// The player shrunk into a bar while the viewer browses (swipe the portrait
/// picture down). The player itself stays mounted in its slot in
/// `ContentView`, only smaller, so playback, progress saving and the video
/// surface carry on untouched; this holds what the bar needs to show and do.
@MainActor
final class PhoneMiniPlayerState: ObservableObject {
    static let shared = PhoneMiniPlayerState()
    @Published var isMini = false
    /// The player's view model, for the bar's title and play/pause.
    weak var viewModel: PlayerViewModel?
    /// Set by `ContentView`, which owns the player's slot.
    var minimize: (() -> Void)?
    var expand: (() -> Void)?
    var close: (() -> Void)?

    /// Bar size; the video sits at its leading end.
    static let videoSize = CGSize(width: 112, height: 63)
    static let barHeight: CGFloat = 75
}

/// The mini player's bar: the title and episode, play/pause and close. The
/// video itself is the real player, laid over the bar's leading end by
/// `ContentView`.
struct PhoneMiniPlayerBar: View {
    @ObservedObject var state = PhoneMiniPlayerState.shared

    var body: some View {
        let viewModel = state.viewModel
        HStack(spacing: 12) {
            Color.clear.frame(width: PhoneMiniPlayerState.videoSize.width)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = viewModel?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { state.expand?() }

            if let viewModel {
                PhoneMiniPlayButton(viewModel: viewModel)
            }
            Button { state.close?() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
        }
        .padding(6)
        .padding(.trailing, 6)
        .frame(height: PhoneMiniPlayerState.barHeight)
        .foregroundStyle(.white)
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -40 { state.expand?() }
            }
        )
    }
}

/// Play/pause for the mini bar, watching the player's own status.
private struct PhoneMiniPlayButton: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        Button { viewModel.togglePlayPause() } label: {
            Image(systemName: viewModel.status == .playing ? "pause.fill" : "play.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.status == .playing ? "Pause" : "Play")
    }
}

/// Where the portrait player draws the video, shared with `PlayerView`, which
/// places the video surface itself.
@MainActor
final class PhonePlayerLayout: ObservableObject {
    static let shared = PhonePlayerLayout()
    @Published var isPortrait = false
    /// The status bar's height: the video box starts below it.
    @Published var topInset: CGFloat = 0
}

extension View {
    /// Upright, the video in a 16:9 box under the status bar; otherwise the
    /// whole screen. One layout either way: swapping the view for another on
    /// rotation rebuilt the video surface, which left the picture black.
    func phonePortraitVideoBox(_ portrait: Bool, topInset: CGFloat) -> some View {
        PhonePortraitBoxLayout(portrait: portrait, topInset: topInset) { self }
    }
}

private struct PhonePortraitBoxLayout: Layout {
    var portrait: Bool
    var topInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        guard portrait else {
            child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
            return
        }
        let size = CGSize(width: bounds.width, height: bounds.width * 9 / 16)
        child.place(at: CGPoint(x: bounds.minX, y: bounds.minY + topInset), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// A Netflix-Duo-style tile: a rounded slab of frosted glass with a faint
/// lit edge, its content centred.
private struct PhoneDuoTile<Content: View>: View {
    var prominent = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            PhoneDuoTileBackground(prominent: prominent) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(PhoneDuoPressStyle())
    }
}

private struct PhoneDuoTileBackground<Content: View>: View {
    var prominent = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(iOS 26.0, *) {
            // The system's Liquid Glass: it follows the Clear / Tinted choice
            // in Settings and Reduce Transparency by itself, and its
            // highlights already move as the phone tilts.
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(
                    prominent ? .regular.tint(.white.opacity(0.10)).interactive() : .regular.interactive(),
                    in: shape
                )
        } else {
            handmadeGlass(shape)
        }
    }

    private func handmadeGlass(_ shape: RoundedRectangle) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(prominent ? 0.14 : 0.08), in: shape)
            .background(PhoneDeckSheenLayer(shape: shape))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
    }
}

/// One glass container for the deck on iOS 26, so neighbouring tiles share
/// the same light rather than each sampling the picture on its own.
private struct PhoneGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }
}

/// The tilt-driven highlight inside a tile (see `PhoneDeckSheen`).
private struct PhoneDeckSheenLayer: View {
    let shape: RoundedRectangle
    private var sheen: PhoneDeckSheen { .shared }

    var body: some View {
        let center = UnitPoint(x: 0.5 - sheen.x * 0.6, y: 0.2 - sheen.y * 0.5)
        shape
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.16), .white.opacity(0)],
                    center: center,
                    startRadius: 0,
                    endRadius: 120
                )
            )
            .allowsHitTesting(false)
    }
}

private struct PhoneDuoPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The "reflection" under the portrait video, as on Netflix's Duo player: the
/// picture mirrored below itself and frosted, so the deck glows with what is
/// playing. Always live, and never a second download or decode: through
/// AVPlayer it is a second layer on the same player; on the software path it
/// is the engine's mirror layer, which is handed the same decoded frames.
/// The title's backdrop stands in only before either exists.
private struct PhonePlayerReflection: View {
    let player: AVPlayer?
    let mirrorLayer: AVSampleBufferDisplayLayer?
    let fallbackURL: String?

    var body: some View {
        ZStack {
            if let player {
                PhoneMirroredPlayerLayer(player: player)
            } else if let mirrorLayer {
                PhoneMirroredSampleLayer(layer: mirrorLayer)
            } else if let fallbackURL {
                PhoneArtwork(url: fallbackURL, kind: .backdrop)
                    .scaleEffect(x: 1, y: -1)
            }
            // Frosted, but less than the full material: the picture should
            // read through it.
            Rectangle().fill(.ultraThinMaterial).opacity(0.7)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.15), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.55),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }
}

private struct PhoneMirroredPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    final class MirrorView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> MirrorView {
        let view = MirrorView()
        view.isUserInteractionEnabled = false
        // Drawn as the picture is, so the reflection matches it 1:1.
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        // Upside down, so the bottom of the picture meets the top of its
        // reflection.
        view.transform = CGAffineTransform(scaleX: 1, y: -1)
        return view
    }

    func updateUIView(_ view: MirrorView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: MirrorView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

/// Hosts the engine's mirror display layer, upside down. The layer belongs to
/// this view alone on iOS, so it can be moved in and kept sized here.
private struct PhoneMirroredSampleLayer: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    final class HostView: UIView {
        var hosted: AVSampleBufferDisplayLayer? {
            didSet {
                guard hosted !== oldValue else { return }
                if oldValue?.superlayer === layer { oldValue?.removeFromSuperlayer() }
                if let hosted {
                    hosted.videoGravity = .resizeAspect
                    layer.addSublayer(hosted)
                    setNeedsLayout()
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.transform = CGAffineTransform(scaleX: 1, y: -1)
        view.hosted = layer
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.hosted = layer
    }

    static func dismantleUIView(_ view: HostView, coordinator: ()) {
        view.hosted = nil
    }
}
#endif

#if os(iOS)
import SwiftUI

/// Title page for the phone. Same `DetailsViewModel` and stream discovery as
/// tvOS `DetailsScreen`; hands the chosen stream to `ContentView` through the
/// same `onPlayClick` signature, so playback, resume and next-episode logic
/// are shared.
struct PhoneDetailsView: View {
    let id: String
    let type: String
    let onPlayClick: (String, [String: String], NuvioMeta, String, [NuvioSubtitle], NuvioVideo?, [NuvioVideo], ExternalPlayer?) -> Void
    let onBack: () -> Void
    let onOpenTitle: (String, String) -> Void

    @StateObject private var viewModel = DetailsViewModel(repository: CinemetaCatalogRepository())
    @State private var selectedSeason: Int?
    @State private var pickerEpisode: NuvioVideo?
    @State private var isSourcesPresented = false
    @State private var isResolvingDebrid = false
    /// "season:episode" keys of watched episodes, for the eye markers.
    @State private var watchedEpisodeKeys: Set<String> = []
    /// Side safe-area inset (the Dynamic Island in landscape), zero upright.
    @State private var sideInset: CGFloat = 0
    /// How far the page has scrolled, for fading the fixed art.
    @State private var scrollOffset: CGFloat = 0
    @State private var pageHeight: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var playerPresence = PhonePlayerPresence.shared
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    /// The trailer is resolved and buffered (paused) once the page settles,
    /// then shown when the Trailer Delay runs out — as Home does on the TV.
    @State private var trailerPreparedID: String?
    @State private var trailerShownID: String?
    /// Set when the trailer reaches its end, to fade back to the art.
    @State private var trailerFinishedID: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let meta = viewModel.uiState.meta {
                content(meta)
            } else if let error = viewModel.uiState.error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { viewModel.loadDetails(id: id, type: type) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            backButton
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            // Opened from Search, the keyboard would otherwise stay up over
            // this page (it is an overlay, not a pushed view, so nothing ends
            // the search field's editing).
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            viewModel.loadDetails(id: id, type: type)
        }
        .onDisappear { viewModel.cancelAllTasks() }
        .onChange(of: viewModel.uiState.meta?.id, initial: true) { _, _ in refreshWatchedEpisodes() }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refreshWatchedEpisodes()
        }
        .sheet(isPresented: $isSourcesPresented) {
            if let meta = viewModel.uiState.meta {
                PhoneSourcesSheet(
                    title: pickerEpisode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? meta.name,
                    state: viewModel.uiState,
                    isResolving: isResolvingDebrid,
                    onRefresh: { prepareStreams(meta: meta, episode: pickerEpisode, force: true) },
                    onSelect: { stream in play(stream, meta: meta) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        // The left-edge back swipe is added where ContentView presents this
        // page (`phoneEdgeSwipeBack`), alongside the other overlay pages.
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.headline.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.leading, PhoneLayout.gutter)
        .padding(.top, 8)
        .accessibilityLabel("Back")
    }

    // MARK: Content

    private func content(_ meta: NuvioMeta) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(meta)

                Group {
                VStack(alignment: .leading, spacing: 14) {
                    actions(meta)

                    if let description = meta.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    if let cast = meta.cast, !cast.isEmpty {
                        Text("Cast: " + cast.prefix(6).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)

                if meta.isSeries {
                    episodes(meta)
                }

                if !viewModel.uiState.moreLikeThis.isEmpty {
                    moreLikeThis
                }
                }
                // Everything below the art keeps clear of the Dynamic Island
                // in landscape; the art itself runs to the screen edges.
                .safeAreaPadding(.horizontal, sideInset)
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing)
        } action: { sideInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in scrollOffset = offset }
        .background { pageBackdrop(meta) }
    }

    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// 1 at the top, fading to 0 as the page scrolls, leaving the blur.
    private var artFade: Double {
        let distance = max((isLandscape ? pageHeight : 320) * 0.8, 1)
        return Double(min(max(1 - scrollOffset / distance, 0), 1))
    }

    /// The art stays put behind the page, as on Home: sharp at the top, and
    /// dissolving into a frosted copy of itself as the content scrolls over.
    private func pageBackdrop(_ meta: NuvioMeta) -> some View {
        let url = meta.backgroundUrl ?? meta.posterUrl
        return ZStack {
            Color.black
            // Sized by the screen, not the image, so a fill image can't widen
            // the page past the screen edge.
            Color.clear
                .overlay { PhoneArtwork(url: url, kind: .backdrop) }
                .clipped()
                .blur(radius: 40)
                .opacity(0.55)
            if isLandscape {
                Color.clear
                    .overlay { artWithTrailer(meta, url: url) }
                    .clipped()
                    .opacity(artFade)
                LinearGradient(
                    colors: [.black.opacity(0.7), .black.opacity(0.2), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.85), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 380)
                        .overlay { artWithTrailer(meta, url: url) }
                        .clipped()
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.6),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    Spacer(minLength: 0)
                }
                .opacity(artFade)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .clear, location: 0.15),
                        .init(color: .black.opacity(0.55), location: 0.45),
                        .init(color: .black.opacity(0.8), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    /// The page art, with the title's trailer over it once it is playing.
    /// Titles without a trailer just keep the art.
    private func artWithTrailer(_ meta: NuvioMeta, url: String?) -> some View {
        ZStack {
            PhoneArtwork(url: url, kind: .backdrop)
            if trailerPreparedID == meta.id {
                TrailerPreviewPlayer(
                    meta: meta,
                    isActive: trailerShownID == meta.id
                        && artFade > 0.05
                        && !playerPresence.isVisible
                        && !isSourcesPresented
                        && scenePhase == .active,
                    onPlaybackFinished: { trailerFinishedID = meta.id },
                    logLabel: "phone-details"
                )
                .id(meta.id)
                // The player keeps itself hidden until its first frame is up
                // and it is active. Its ready callback can't be used to reveal
                // it: the surface holds the callback from when it was made, so
                // a trailer that resolves after the delay never fires it, and
                // only the sound came through.
                .opacity(trailerFinishedID == meta.id ? 0 : 1)
                .animation(.easeInOut(duration: 0.6), value: trailerFinishedID)
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(meta.id)|\(trailersEnabled)|\(trailerDelay)") {
            trailerPreparedID = nil
            trailerShownID = nil
            trailerFinishedID = nil
            guard trailersEnabled else { return }
            let delay = Double(max(0, trailerDelay))
            let settle = min(delay, 1.5)
            try? await Task.sleep(for: .seconds(settle))
            guard !Task.isCancelled else { return }
            trailerPreparedID = meta.id
            try? await Task.sleep(for: .seconds(delay - settle))
            guard !Task.isCancelled else { return }
            trailerShownID = meta.id
        }
    }

    private func header(_ meta: NuvioMeta) -> some View {
        ZStack(alignment: .bottomLeading) {
            // The art itself is the fixed page backdrop; this only reserves
            // its space and holds the title.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: isLandscape ? max(pageHeight * 0.7, 240) : 320)
            VStack(alignment: .leading, spacing: 8) {
                PhoneTitleLogo(meta: meta, maxHeight: 80)
                Text(metaLine(meta))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(PhoneLayout.gutter)
            .padding(.horizontal, sideInset)
        }
    }

    private func metaLine(_ meta: NuvioMeta) -> String {
        var parts: [String] = []
        if let year = meta.releaseInfo ?? meta.year.map(String.init) { parts.append(year) }
        if let runtime = meta.runtime { parts.append(runtime) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        if let genres = meta.genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func actions(_ meta: NuvioMeta) -> some View {
        HStack(spacing: 12) {
            Button {
                if meta.isSeries {
                    let next = nextEpisode(meta)
                    openSources(meta: meta, episode: next)
                } else {
                    openSources(meta: meta, episode: nil)
                }
            } label: {
                Label(playLabel(meta), systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.black)
            }

            Button { viewModel.toggleWatchlist() } label: {
                Image(systemName: viewModel.uiState.isInWatchlist ? "checkmark" : "plus")
                    .font(.headline)
                    .frame(width: 48, height: 46)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityLabel(viewModel.uiState.isInWatchlist ? "Remove from Library" : "Add to Library")

            Button { viewModel.toggleWatched() } label: {
                // Light when watched, dark when not: an outline-vs-filled eye
                // on the same dark button was too close to tell apart.
                let watched = viewModel.uiState.isWatched
                Image(systemName: watched ? "eye.fill" : "eye")
                    .font(.headline)
                    .foregroundStyle(watched ? Color.black : Color.white)
                    .frame(width: 48, height: 46)
                    .background(watched ? Color.white : Color.white.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .animation(.easeOut(duration: 0.15), value: watched)
            }
            .accessibilityLabel(viewModel.uiState.isWatched ? "Mark Unwatched" : "Mark Watched")
        }
    }

    private func playLabel(_ meta: NuvioMeta) -> String {
        guard meta.isSeries, let episode = nextEpisode(meta) else { return "Play" }
        return "Play S\(episode.season) E\(episode.episode)"
    }

    // MARK: Episodes

    private func orderedEpisodes(_ meta: NuvioMeta) -> [NuvioVideo] {
        (meta.videos ?? []).sorted {
            (seasonKey($0.season), $0.episode) < (seasonKey($1.season), $1.episode)
        }
    }

    private func seasonKey(_ season: Int) -> Int { season <= 0 ? Int.max : season }

    private func seasons(_ meta: NuvioMeta) -> [Int] {
        Array(Set((meta.videos ?? []).map(\.season))).sorted { seasonKey($0) < seasonKey($1) }
    }

    /// What Play should start: the episode being resumed in Continue Watching,
    /// else the one after the furthest episode marked watched, else the first.
    private func nextEpisode(_ meta: NuvioMeta) -> NuvioVideo? {
        let episodes = orderedEpisodes(meta).filter { $0.season > 0 }
        if let item = ContinueWatchingStore.items().first(where: { $0.meta.id == meta.id }),
           let season = item.season, let number = item.episode,
           let match = episodes.first(where: { $0.season == season && $0.episode == number }) {
            return match
        }
        if let lastWatched = episodes.lastIndex(where: {
            watchedEpisodeKeys.contains("\($0.season):\($0.episode)")
        }) {
            // Everything watched: offer the last episode again rather than none.
            return episodes.indices.contains(lastWatched + 1) ? episodes[lastWatched + 1] : episodes[lastWatched]
        }
        return episodes.first ?? orderedEpisodes(meta).first
    }

    private func episodes(_ meta: NuvioMeta) -> some View {
        let allSeasons = seasons(meta)
        let season = selectedSeason ?? nextEpisode(meta)?.season ?? allSeasons.first ?? 1
        let list = orderedEpisodes(meta).filter { $0.season == season }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes").font(.title3.weight(.bold))
                Spacer()
                if allSeasons.count > 1 {
                    Menu {
                        ForEach(allSeasons, id: \.self) { value in
                            Button(value == 0 ? "Specials" : "Season \(value)") { selectedSeason = value }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(season == 0 ? "Specials" : "Season \(season)")
                            Image(systemName: "chevron.down").font(.caption)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, PhoneLayout.gutter)

            LazyVStack(spacing: 14) {
                ForEach(list, id: \.id) { episode in
                    let isWatched = watchedEpisodeKeys.contains("\(episode.season):\(episode.episode)")
                    PhoneSwipeActionRow(
                        isWatched: isWatched,
                        onTap: { openSources(meta: meta, episode: episode) },
                        onToggleWatched: { toggleEpisodeWatched(episode, meta: meta) },
                        onMarkThroughHere: { markWatchedThrough(episode, meta: meta) }
                    ) {
                        PhoneEpisodeRow(episode: episode, fallbackArt: meta.backgroundUrl, isWatched: isWatched)
                    }
                }
            }
            .padding(.horizontal, PhoneLayout.gutter)
        }
    }

    // MARK: Watched episodes

    private func refreshWatchedEpisodes() {
        guard let meta = viewModel.uiState.meta, meta.isSeries else { return }
        watchedEpisodeKeys = WatchedStore.watchedEpisodeKeys(meta: meta)
    }

    private func toggleEpisodeWatched(_ episode: NuvioVideo, meta: NuvioMeta) {
        _ = WatchedStore.toggleEpisode(meta: meta, season: episode.season, episode: episode.episode)
        refreshWatchedEpisodes()
    }

    /// Marks this episode and every earlier one (all earlier seasons too,
    /// specials aside) watched — the TV's "catch up" action.
    private func markWatchedThrough(_ episode: NuvioVideo, meta: NuvioMeta) {
        let upTo = orderedEpisodes(meta).filter { candidate in
            guard candidate.season > 0 else { return false }
            return candidate.season < episode.season
                || (candidate.season == episode.season && candidate.episode <= episode.episode)
        }
        for (season, videos) in Dictionary(grouping: upTo, by: \.season) {
            WatchedStore.setSeasonWatched(meta: meta, season: season, episodes: videos.map(\.episode), isWatched: true)
        }
        refreshWatchedEpisodes()
    }

    private var moreLikeThis: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhoneSectionHeader(title: "More Like This")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(viewModel.uiState.moreLikeThis, id: \.id) { title in
                        Button { onOpenTitle(title.id, title.type) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PhoneArtwork(url: title.posterURL)
                                    .frame(width: PhoneLayout.posterWidth, height: PhoneLayout.posterWidth * PhoneLayout.posterAspect)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(title.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: PhoneLayout.posterWidth, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)
            }
        }
    }

    // MARK: Streams

    private func openSources(meta: NuvioMeta, episode: NuvioVideo?) {
        let changed = pickerEpisode?.id != episode?.id
        pickerEpisode = episode
        if changed || viewModel.uiState.streamGroups.isEmpty {
            prepareStreams(meta: meta, episode: episode, force: false)
        }
        isSourcesPresented = true
    }

    private func prepareStreams(meta: NuvioMeta, episode: NuvioVideo?, force: Bool) {
        if let episode {
            viewModel.prepareStreams(forId: episode.id, type: "series", forceRefresh: force)
        } else {
            viewModel.prepareStreams(forId: meta.streamId, type: meta.type, forceRefresh: force)
        }
    }

    /// Direct links play at once; torrent-only streams go through the
    /// configured debrid provider first, as on tvOS.
    private func play(_ stream: NuvioStream, meta: NuvioMeta) {
        let episode = pickerEpisode
        let subtitleLine = episode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? ""
        let episodes = meta.isSeries ? orderedEpisodes(meta) : []
        LastStreamQualityStore.save(metaId: meta.id, stream: stream)

        if let url = stream.url, !url.isEmpty {
            isSourcesPresented = false
            onPlayClick(url, stream.httpHeaders ?? [:], meta, subtitleLine, stream.subtitles, episode, episodes, nil)
            return
        }
        guard stream.isDebridResolvable, !isResolvingDebrid else { return }
        isResolvingDebrid = true
        Task {
            let result = await DebridResolver(store: ProfileSettings.current)
                .resolvedURL(for: stream, season: episode?.season, episode: episode?.episode)
            isResolvingDebrid = false
            if case let .success(url, _, _)? = result {
                isSourcesPresented = false
                onPlayClick(url.absoluteString, stream.httpHeaders ?? [:], meta, subtitleLine, stream.subtitles, episode, episodes, nil)
            }
        }
    }
}

private struct PhoneEpisodeRow: View {
    let episode: NuvioVideo
    let fallbackArt: String?
    var isWatched = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PhoneArtwork(url: episode.thumbnail ?? fallbackArt)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isWatched ? 0.55 : 1)
                .overlay(alignment: .topTrailing) {
                    if isWatched {
                        Image(systemName: "eye.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(5)
                            .background(Color.white, in: Circle())
                            .padding(5)
                            .accessibilityLabel("Watched")
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episode). \(episode.title)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        // A Liquid Glass card over the page's art, lightly darkened so the
        // text holds up on bright backdrops.
        .padding(8)
        .frame(minHeight: 88)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .rect(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
    }
}

/// A row that swipes left like Mail's. Let go past 80% of the width and it
/// toggles watched at once; let go part-way and it stays open on two
/// buttons — toggle watched, or mark everything up to here watched. Tap the
/// open row (or swipe back) to close it.
/// A horizontal-only pan. `gestureRecognizerShouldBegin` refuses any touch
/// that starts out more vertical than horizontal, so the enclosing scroll
/// view gets those immediately and never waits on this.
private struct PhoneHorizontalPan: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onChanged(dx)
        case .ended, .cancelled, .failed:
            onEnded(dx, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.2
        }
    }
}

private struct PhoneSwipeActionRow<Content: View>: View {
    let isWatched: Bool
    let onTap: () -> Void
    let onToggleWatched: () -> Void
    let onMarkThroughHere: () -> Void
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var rowWidth: CGFloat = 360
    @State private var isOpen = false

    private let buttonWidth: CGFloat = 92
    private var openOffset: CGFloat { -buttonWidth * 2 }
    private var fullSwipe: CGFloat { -rowWidth * 0.8 }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                actionButton(
                    title: "Up to here",
                    systemImage: "checkmark.circle",
                    color: Color(white: 0.3),
                    action: onMarkThroughHere
                )
                actionButton(
                    title: isWatched ? "Unwatched" : "Watched",
                    systemImage: isWatched ? "eye.slash" : "eye",
                    // Grows to fill the gap as a full swipe gets close.
                    color: .blue,
                    width: max(buttonWidth, -offset - buttonWidth),
                    action: onToggleWatched
                )
            }
            .opacity(offset < 0 ? 1 : 0)

            content
                .offset(x: offset)
                .onTapGesture {
                    if isOpen { close() } else { onTap() }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = max($0, 1) }
        // A UIKit pan that only begins on a sideways movement: a SwiftUI drag
        // on every row competed with the scroll view for each touch, and
        // made scrolling the episode list stick.
        .gesture(PhoneHorizontalPan(
            onChanged: { dx in
                let start = isOpen ? openOffset : 0
                offset = min(0, start + dx)
            },
            onEnded: { dx, velocity in
                let start = isOpen ? openOffset : 0
                let end = start + dx + velocity * 0.15
                if offset <= fullSwipe || end <= fullSwipe * 1.15 {
                    withAnimation(.easeOut(duration: 0.18)) { offset = -rowWidth }
                    onToggleWatched()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { close() }
                } else if offset < openOffset / 2 {
                    withAnimation(.spring(duration: 0.3)) { offset = openOffset }
                    isOpen = true
                } else {
                    close()
                }
            }
        ))
    }

    private func actionButton(
        title: String,
        systemImage: String,
        color: Color,
        width: CGFloat? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            close()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.headline)
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: width ?? buttonWidth)
            .frame(maxHeight: .infinity)
            .background(color)
        }
        .buttonStyle(.plain)
    }

    private func close() {
        withAnimation(.spring(duration: 0.3)) { offset = 0 }
        isOpen = false
    }
}

/// Every stream the add-ons returned, grouped by quality order the same way
/// the tvOS picker sorts them.
private struct PhoneSourcesSheet: View {
    let title: String
    let state: DetailsUiState
    let isResolving: Bool
    let onRefresh: () -> Void
    let onSelect: (NuvioStream) -> Void

    private var streams: [NuvioStream] {
        let store = ProfileSettings.current
        let sort = store.string(forKey: SettingsKey.streamSortOption)
            .flatMap(StreamSortOption.init(rawValueOrSync:)) ?? .quality
        let cachedOnly = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        return StreamPickerListBuilder.displayedStreams(
            streams: state.streams,
            groups: state.streamGroups,
            selectedAddonId: nil,
            sortOption: sort,
            includeDebrid: DebridResolver(store: store).isEnabled,
            cachedOnly: cachedOnly
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if state.isLoadingStreams || isResolving {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isResolving ? "Resolving link…" : "Searching add-ons…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(streams, id: \.id) { stream in
                    Button { onSelect(stream) } label: { PhoneStreamRow(stream: stream) }
                        .disabled(isResolving)
                }
                if !state.isLoadingStreams && streams.isEmpty {
                    Text("No sources found. Check your add-ons in Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh sources")
                }
            }
        }
    }
}

private struct PhoneStreamRow: View {
    let stream: NuvioStream

    var body: some View {
        let tags = StreamQualityTags.parse(stream: stream)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if tags.resolution > 0 { badge(tags.resolution >= 2160 ? "4K" : "\(tags.resolution)p") }
                if tags.isDolbyVision { badge("DV") } else if tags.isHDR { badge("HDR") }
                if tags.isAtmos { badge("Atmos") }
                if tags.isCached { badge("Cached") }
                Spacer(minLength: 0)
                Text(stream.addonName ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            Text(stream.name ?? "Stream")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if let description = stream.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.12), in: Capsule())
    }
}
#endif

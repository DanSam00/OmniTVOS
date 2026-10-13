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
    @State private var sideInset = PhoneSideInsets()
    /// How far the page has scrolled, for fading the fixed art.
    @State private var scrollOffset: CGFloat = 0
    @State private var pageHeight: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var playerPresence = PhonePlayerPresence.shared
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    /// The trailer is resolved and buffered (paused) once the page settles,
    /// then shown when the Trailer Delay runs out — as Home does on the TV.
    @State private var trailerPreparedID: String?
    @State private var trailerShownID: String?
    @ObservedObject private var downloads = DownloadManager.shared
    /// The movie or episode whose streams are loading, to choose one to download.
    @State private var preparingDownloadId: String?
    /// The episode being downloaded (nil for the movie itself).
    @State private var downloadEpisode: NuvioVideo?
    /// The sources sheet is open to pick a download, not to play.
    @State private var isPickingDownload = false
    /// The download whose options are showing.
    @State private var downloadMenuId: String?

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
        }
        // No back button: the left-edge swipe goes back (added where
        // ContentView presents this page, `phoneEdgeSwipeBack`), and
        // VoiceOver's scrub gesture does the same.
        .accessibilityAction(.escape) { onBack() }
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
        .onChange(of: viewModel.uiState.isLoadingStreams) { _, loading in
            guard !loading, preparingDownloadId != nil, let meta = viewModel.uiState.meta else { return }
            chooseDownload(meta: meta)
        }
        .onChange(of: isSourcesPresented) { _, presented in
            if !presented { isPickingDownload = false }
        }
        .confirmationDialog(
            viewModel.uiState.meta.map(downloadMenuTitle) ?? "",
            isPresented: Binding(get: { downloadMenuId != nil }, set: { if !$0 { downloadMenuId = nil } }),
            titleVisibility: .visible
        ) {
            if let meta = viewModel.uiState.meta { downloadMenuActions(meta: meta) }
        } message: {
            if let id = downloadMenuId, let record = downloads.record(for: id),
               let message = PhoneDownloadIcon.statusText(record: record, waiting: downloads.isWaitingForWiFi(record)) {
                Text(message)
            }
        }
        .onChange(of: viewModel.uiState.meta?.id, initial: true) { _, _ in refreshWatchedEpisodes() }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            refreshWatchedEpisodes()
        }
        .sheet(isPresented: $isSourcesPresented) {
            if let meta = viewModel.uiState.meta {
                PhoneSourcesSheet(
                    title: isPickingDownload
                        ? "Choose a Source to Download"
                        : pickerEpisode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? meta.name,
                    state: viewModel.uiState,
                    isResolving: isResolvingDebrid,
                    isPickingDownload: isPickingDownload,
                    downloadEpisode: downloadEpisode,
                    onRefresh: { prepareStreams(meta: meta, episode: pickerEpisode, force: true) },
                    onSelect: { stream in
                        if isPickingDownload {
                            isSourcesPresented = false
                            startDownload(meta: meta, stream: stream, episode: downloadEpisode)
                        } else {
                            play(stream, meta: meta)
                        }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        // The left-edge back swipe is added where ContentView presents this
        // page (`phoneEdgeSwipeBack`), alongside the other overlay pages.
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
                .safeAreaPadding(sideInset)
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onGeometryChange(for: PhoneSideInsets.self) { proxy in
            PhoneSideInsets(proxy.safeAreaInsets)
        } action: { sideInset = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            pageHeight = $0.height
            pageWidth = $0.width
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in scrollOffset = offset }
        .background { pageBackdrop(meta) }
    }

    private var isLandscape: Bool {
        phoneIsLandscape(width: pageWidth, height: pageHeight, fallback: verticalSizeClass == .compact)
    }

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
                    .modifier(PhoneParallaxScroll(offset: scrollOffset))
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
                .modifier(PhoneParallaxScroll(offset: scrollOffset))
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
                // Shows only once the delay is up *and* enough is buffered,
                // then fades back to the art when it ends.
                PhoneTrailerView(
                    meta: meta,
                    isActive: trailerShownID == meta.id
                        && artFade > 0.05
                        && !playerPresence.isVisible
                        && !isSourcesPresented
                        && scenePhase == .active
                )
                .id(meta.id)
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(meta.id)|\(trailersEnabled)|\(trailerDelay)") {
            trailerPreparedID = nil
            trailerShownID = nil
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
            .padding(.vertical, PhoneLayout.gutter)
            .padding(sideInset, plus: PhoneLayout.gutter)
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
                } else if !playDownloaded(meta) {
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

            if !meta.isSeries {
                downloadControl(meta: meta, episode: nil)
                    .frame(width: 48, height: 46)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    // MARK: Downloads

    private func downloadId(meta: NuvioMeta, episode: NuvioVideo?) -> String {
        episode?.id ?? meta.id
    }

    /// The download icon for the movie, or for one episode, and what tapping
    /// it does: start, retry, or show the download's options.
    private func downloadControl(meta: NuvioMeta, episode: NuvioVideo?) -> some View {
        let id = downloadId(meta: meta, episode: episode)
        let record = downloads.record(for: id)
        return Button {
            if let record, record.state == .failed {
                downloads.resume(record.contentId)
            } else if let record, record.state == .needsSource {
                // A season download found nothing within the limit: pick one.
                beginDownload(meta, episode: episode)
            } else if record != nil {
                downloadMenuId = id
            } else {
                beginDownload(meta, episode: episode)
            }
        } label: {
            PhoneDownloadIcon(
                record: record,
                isWaitingForWiFi: record.map(downloads.isWaitingForWiFi) ?? false,
                isPreparing: preparingDownloadId == id
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PhoneDownloadIcon.accessibilityLabel(record: record))
    }

    /// The options for `downloadMenuId`: play or delete a finished download;
    /// pause, resume or cancel one in progress.
    @ViewBuilder
    private func downloadMenuActions(meta: NuvioMeta) -> some View {
        if let id = downloadMenuId, let record = downloads.record(for: id) {
            switch record.state {
            case .completed:
                Button("Play Download") { _ = playDownloaded(meta: meta, contentId: id) }
                Button("Delete Download", role: .destructive) { downloads.delete(id) }
            case .downloading, .queued, .resolving:
                Button("Pause Download") { downloads.pause(id) }
                Button("Cancel Download", role: .destructive) { downloads.delete(id) }
            case .paused:
                Button("Resume Download") { downloads.resume(id) }
                Button("Cancel Download", role: .destructive) { downloads.delete(id) }
            case .failed:
                Button("Try Again") { downloads.resume(id) }
                Button("Remove", role: .destructive) { downloads.delete(id) }
            case .findingSource:
                Button("Cancel Download", role: .destructive) { downloads.delete(id) }
            case .needsSource:
                Button("Choose Source") {
                    beginDownload(meta, episode: meta.videos?.first { $0.id == id })
                }
                Button("Remove", role: .destructive) { downloads.delete(id) }
            }
        }
    }

    private func downloadMenuTitle(meta: NuvioMeta) -> String {
        guard let id = downloadMenuId, let record = downloads.record(for: id),
              let season = record.season, let episode = record.episode else { return meta.name }
        return "S\(season) E\(episode) · \(record.episodeTitle ?? meta.name)"
    }

    /// Download this season, or every episode. Each episode finds its own
    /// source in the background; those that cannot are left to pick.
    private func seasonDownloadMenu(meta: NuvioMeta, season: Int, list: [NuvioVideo]) -> some View {
        let all = orderedEpisodes(meta)
        let seasonDone = !list.isEmpty && list.allSatisfy { downloads.record(for: $0.id) != nil }
        return Menu {
            Button {
                downloads.enqueueEpisodes(meta: meta, episodes: list)
            } label: {
                Label(
                    "Download \(season == 0 ? "Specials" : "Season \(season)") (\(list.count))",
                    systemImage: "arrow.down.circle"
                )
            }
            .disabled(seasonDone)
            if seasons(meta).count > 1 {
                Button {
                    downloads.enqueueEpisodes(meta: meta, episodes: all)
                } label: {
                    Label("Download All Episodes (\(all.count))", systemImage: "square.and.arrow.down.on.square")
                }
            }
        } label: {
            Image(systemName: seasonDone ? "checkmark.circle" : "arrow.down.circle")
                .font(.title3)
                .padding(.horizontal, 6)
        }
        .accessibilityLabel("Download Season")
    }

    /// Fetches the sources, then downloads the one closest to the size limit
    /// — or asks, when the sizes cannot settle it.
    private func beginDownload(_ meta: NuvioMeta, episode: NuvioVideo?) {
        pickerEpisode = episode
        downloadEpisode = episode
        preparingDownloadId = downloadId(meta: meta, episode: episode)
        prepareStreams(meta: meta, episode: episode, force: false)
        if !viewModel.uiState.isLoadingStreams, !viewModel.uiState.streams.isEmpty {
            chooseDownload(meta: meta)
        }
    }

    private func chooseDownload(meta: NuvioMeta) {
        preparingDownloadId = nil
        let episode = downloadEpisode
        let store = ProfileSettings.current
        let debrid = DebridResolver(store: store).isEnabled
        let ordered = PhoneSourcesSheet.displayedStreams(state: viewModel.uiState)
        let limit = episode == nil
            ? DownloadSettings.maxMovieBytes(in: store)
            : DownloadSettings.maxEpisodeBytes(in: store)
        switch DownloadStreamChooser.choose(
            from: ordered,
            maxBytes: limit,
            debridEnabled: debrid,
            season: episode?.season,
            episode: episode?.episode,
            meta: meta
        ) {
        case .auto(let stream):
            startDownload(meta: meta, stream: stream, episode: episode)
        case .ask:
            isPickingDownload = true
            isSourcesPresented = true
        }
    }

    private func startDownload(meta: NuvioMeta, stream: NuvioStream, episode: NuvioVideo?) {
        downloads.start(
            meta: meta,
            stream: stream,
            contentId: downloadId(meta: meta, episode: episode),
            season: episode?.season,
            episode: episode?.episode,
            episodeTitle: episode?.title
        )
    }

    /// Plays a download of the movie or of one of its episodes. False when
    /// there is none.
    private func playDownloaded(meta: NuvioMeta, contentId: String) -> Bool {
        guard let record = downloads.record(for: contentId),
              let file = downloads.localFileURL(for: record) else { return false }
        let episode = meta.videos?.first { $0.id == contentId }
        let subtitleLine = episode.map { "S\($0.season) · E\($0.episode) · \($0.title)" } ?? ""
        // The whole season, so the player moves on to the next episode —
        // from the phone too when that one is downloaded.
        let episodes = episode == nil ? [] : orderedEpisodes(meta)
        onPlayClick(file.absoluteString, [:], meta, subtitleLine, record.playbackSubtitles, episode, episodes, nil)
        return true
    }

    private func playDownloaded(_ meta: NuvioMeta) -> Bool {
        playDownloaded(meta: meta, contentId: meta.id)
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
                seasonDownloadMenu(meta: meta, season: season, list: list)
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
                        actions: [
                            PhoneSwipeAction(
                                title: "Up to here",
                                systemImage: "checkmark.circle",
                                color: Color(white: 0.3),
                                action: { markWatchedThrough(episode, meta: meta) }
                            ),
                            PhoneSwipeAction(
                                title: isWatched ? "Unwatched" : "Watched",
                                systemImage: isWatched ? "eye.slash" : "eye",
                                color: .blue,
                                action: { toggleEpisodeWatched(episode, meta: meta) }
                            ),
                        ],
                        onTap: {
                            // A downloaded episode plays from the device.
                            if !playDownloaded(meta: meta, contentId: episode.id) {
                                openSources(meta: meta, episode: episode)
                            }
                        }
                    ) {
                        PhoneEpisodeRow(episode: episode, fallbackArt: meta.backgroundUrl, isWatched: isWatched) {
                            downloadControl(meta: meta, episode: episode)
                                .frame(width: 40, height: 40)
                        }
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
                PhoneKidsFiltered(items: viewModel.uiState.moreLikeThis.map(\.kidsCheckMeta)) { visible in
                let visibleIDs = Set(visible.map(\.id))
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(viewModel.uiState.moreLikeThis.filter { visibleIDs.contains($0.id) }, id: \.id) { title in
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

private struct PhoneEpisodeRow<Trailing: View>: View {
    let episode: NuvioVideo
    let fallbackArt: String?
    var isWatched = false
    /// The episode's download icon.
    @ViewBuilder var trailing: () -> Trailing

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
            trailing()
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
struct PhoneHorizontalPan: UIGestureRecognizerRepresentable {
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

/// One button behind a swiped row.
struct PhoneSwipeAction {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void
}

struct PhoneSwipeActionRow<Content: View>: View {
    /// Left to right. The last is the full-swipe action, and widens to fill
    /// the gap as a full swipe gets close.
    let actions: [PhoneSwipeAction]
    let onTap: () -> Void
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var rowWidth: CGFloat = 360
    @State private var isOpen = false

    private let buttonWidth: CGFloat = 92
    private var openOffset: CGFloat { -buttonWidth * CGFloat(actions.count) }
    private var fullSwipe: CGFloat { -rowWidth * 0.8 }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(Array(actions.enumerated()), id: \.offset) { index, item in
                    let isLast = index == actions.count - 1
                    actionButton(
                        title: item.title,
                        systemImage: item.systemImage,
                        color: item.color,
                        width: isLast
                            ? max(buttonWidth, -offset - buttonWidth * CGFloat(actions.count - 1))
                            : nil,
                        action: item.action
                    )
                }
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
                    actions.last?.action()
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
    var isPickingDownload = false
    /// Picking for this episode: sources named for another one are hidden.
    var downloadEpisode: NuvioVideo? = nil
    let onRefresh: () -> Void
    let onSelect: (NuvioStream) -> Void

    // The Mac's filters: sort, resolution and cached-only are the stored
    // preferences every source list reads; the provider is this sheet's own.
    @AppStorage(SettingsKey.streamSortOption) private var sortOption: StreamSortOption = .quality
    @AppStorage(SettingsKey.streamResolutionFilter) private var resolutionFilter: StreamResolutionFilter = .any
    @AppStorage(SettingsKey.cachedOnlyStreams) private var cachedOnly = false
    @State private var selectedAddonId: String?

    private var includesDebrid: Bool { DebridResolver(store: ProfileSettings.current).isEnabled }

    private var providers: [PhoneSourceFilterBar.Provider] {
        state.streamGroups
            .filter { !$0.streams.isEmpty || $0.isLoading }
            .map { .init(id: $0.addonId, name: $0.isLoading ? "\($0.displayName)…" : $0.displayName) }
    }

    private var streams: [NuvioStream] {
        let all = StreamPickerListBuilder.displayedStreams(
            streams: state.streams,
            groups: state.streamGroups,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includesDebrid,
            cachedOnly: cachedOnly,
            resolutionFilter: resolutionFilter
        )
        guard isPickingDownload else { return all }
        let debrid = DebridResolver(store: ProfileSettings.current).isEnabled
        return all.filter {
            DownloadStreamChooser.isDownloadable($0, debridEnabled: debrid)
                && DownloadStreamChooser.matches($0, season: downloadEpisode?.season, episode: downloadEpisode?.episode, meta: state.meta)
        }
    }

    /// The sources as the sheet lists them, best first.
    static func displayedStreams(state: DetailsUiState) -> [NuvioStream] {
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
                    Text(isPickingDownload
                        ? "None of these sources can be downloaded."
                        : state.streams.isEmpty
                            ? "No sources found. Check your add-ons in Settings."
                            : "No sources match these filters.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !state.streams.isEmpty || state.isLoadingStreams {
                    PhoneSourceFilterBar(
                        providers: providers,
                        selectedProvider: selectedAddonId,
                        onSelectProvider: { selectedAddonId = $0 },
                        resolution: $resolutionFilter,
                        sort: $sortOption,
                        cachedOnly: $cachedOnly,
                        showsCachedOnly: includesDebrid
                    )
                    .background(.bar)
                }
            }
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
                if let size = StreamBadgeSizing.fileSizeBytes(for: stream) {
                    badge(DownloadSettings.label(for: size))
                }
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
/// The page art on scroll: it drifts up at about half the content's speed,
/// so the page appears to slide over it, and stretches from the top when
/// the page is pulled down past its start.
struct PhoneParallaxScroll: ViewModifier {
    let offset: CGFloat
    private static let rate: CGFloat = 0.55

    func body(content: Content) -> some View {
        let pull = max(-offset, 0)
        let drift = -max(offset, 0) * Self.rate
        // The stretch grows the art by exactly the overscroll, relative to
        // its own height, so its bottom edge follows the content down. A
        // fixed divisor ballooned it on short screens: a 90pt bounce on the
        // iPhone Duo in landscape scaled the art by 36% and it snapped back.
        //
        // Never animated: the scroll position must land on the frame it's
        // read. Posters in the rows fade in as they load while the page
        // scrolls, and a scroll update sharing a frame with one of those
        // fades took on its animation — the art lagged behind the content
        // and then jumped to catch up.
        content.transaction { $0.animation = nil } body: { content in
            content.visualEffect { view, proxy in
                view
                    .scaleEffect(1 + pull / max(proxy.size.height, 1), anchor: .top)
                    .offset(y: drift)
            }
        }
    }
}
/// The movie page's download button: an arrow to start; a ring filling
/// with the progress (and the percentage) while downloading; Wi-Fi crossed
/// out while it waits for Wi-Fi; a tick once downloaded; a retry mark if it
/// failed.
struct PhoneDownloadIcon: View {
    let record: DownloadRecord?
    let isWaitingForWiFi: Bool
    let isPreparing: Bool

    var body: some View {
        Group {
            if isPreparing && record == nil {
                ProgressView().controlSize(.small)
            } else if let record {
                switch record.state {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                case .failed:
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.headline)
                        .foregroundStyle(.orange)
                case .paused:
                    ring(record.progress, symbol: "pause.fill")
                case .findingSource:
                    ProgressView().controlSize(.small)
                case .needsSource:
                    Image(systemName: "questionmark.circle")
                        .font(.headline)
                        .foregroundStyle(.orange)
                case .resolving, .queued:
                    if isWaitingForWiFi {
                        Image(systemName: "wifi.slash").font(.headline)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .downloading:
                    if isWaitingForWiFi {
                        Image(systemName: "wifi.slash").font(.headline)
                    } else {
                        ring(record.progress, percent: true)
                    }
                }
            } else {
                Image(systemName: "arrow.down.circle").font(.title3)
            }
        }
        .foregroundStyle(.white)
    }

    private func ring(_ progress: Double, symbol: String? = nil, percent: Bool = false) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            } else if percent {
                Text("\(Int((progress * 100).rounded()))")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
            }
        }
        .frame(width: 28, height: 28)
    }

    static func accessibilityLabel(record: DownloadRecord?) -> String {
        guard let record else { return "Download" }
        switch record.state {
        case .completed: return "Downloaded"
        case .downloading: return "Downloading, \(Int(record.progress * 100)) percent"
        case .paused: return "Download paused"
        case .failed: return "Download failed, retry"
        case .resolving, .queued: return "Download waiting"
        case .findingSource: return "Finding a source to download"
        case .needsSource: return "Choose a source to download"
        }
    }

    static func statusText(record: DownloadRecord, waiting: Bool) -> String? {
        DownloadStatusText.status(record: record, waiting: waiting)
    }
}
#endif

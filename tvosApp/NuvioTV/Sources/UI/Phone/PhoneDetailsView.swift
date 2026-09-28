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
    /// Side safe-area inset (the Dynamic Island in landscape), zero upright.
    @State private var sideInset: CGFloat = 0

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
        .onAppear { viewModel.loadDetails(id: id, type: type) }
        .onDisappear { viewModel.cancelAllTasks() }
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
        // Swipe from the left edge, the gesture a navigation stack would give.
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.startLocation.x < 30, value.translation.width > 80 { onBack() }
                }
        )
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
    }

    private func header(_ meta: NuvioMeta) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Fill-mode art sized in an overlay, so its natural width can't
            // push the card past the screen edge.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .overlay { PhoneArtwork(url: meta.backgroundUrl ?? meta.posterUrl, kind: .backdrop) }
                .clipped()
            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
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
                Image(systemName: viewModel.uiState.isWatched ? "eye.fill" : "eye")
                    .font(.headline)
                    .frame(width: 48, height: 46)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// The episode after the one in Continue Watching, else the first episode.
    private func nextEpisode(_ meta: NuvioMeta) -> NuvioVideo? {
        let episodes = orderedEpisodes(meta)
        if let item = ContinueWatchingStore.items().first(where: { $0.meta.id == meta.id }),
           let season = item.season, let number = item.episode,
           let match = episodes.first(where: { $0.season == season && $0.episode == number }) {
            return match
        }
        return episodes.first { $0.season > 0 } ?? episodes.first
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
                    Button { openSources(meta: meta, episode: episode) } label: {
                        PhoneEpisodeRow(episode: episode, fallbackArt: meta.backgroundUrl)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, PhoneLayout.gutter)
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhoneArtwork(url: episode.thumbnail ?? fallbackArt)
                .frame(width: 136, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .contentShape(Rectangle())
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

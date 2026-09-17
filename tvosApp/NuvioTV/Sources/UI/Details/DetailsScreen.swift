//
//  DetailsScreen.swift
//  NuvioTV
//
//  Content details screen with adaptive layouts for iOS/iPad/tvOS
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import ImageIO

struct DetailsScreen: View {
    let id: String
    let type: String
    /// (streamURL, httpHeaders, meta, episodeSubtitleLine, streamSubtitles, currentEpisode, orderedEpisodes).
    /// The last two carry series context for the player's next-episode auto-play;
    /// both are empty/nil for movies and trailers.
    let onPlayClick: (String, [String: String], NuvioMeta, String, [NuvioSubtitle], NuvioVideo?, [NuvioVideo], ExternalPlayer?) -> Void
    let onBack: () -> Void
    /// Open another title (More Like This / production catalog).
    var onOpenTitle: ((String, String) -> Void)? = nil
    /// Open a production company / network catalog.
    var onOpenProduction: ((MetaCompany) -> Void)? = nil
    /// Open the movies and series associated with a TMDB person.
    var onOpenPerson: ((TmdbPersonMetadata) -> Void)? = nil
    let initiallyPresentStreamPicker: Bool
    let initialStreamPickerEpisode: NuvioVideo?
    let onInitialStreamPickerPresented: (() -> Void)?

    @StateObject private var viewModel: DetailsViewModel
    @State private var isStreamPickerPresented = false
    @State private var isSmartPlaybackPending = false
    @State private var isPreparingPlayback = false
    /// Episode line shown under the title in the player ("" for movies).
    @State private var pendingEpisodeSubtitle = ""
    /// The episode a stream is being picked for (nil for movies); drives the
    /// season/episode header in the stream picker.
    @State private var pendingEpisode: NuvioVideo?
    @State private var didHandleInitialStreamPicker = false
    @State private var expandedComment: TraktCommentReview?
    /// Set while an episode card's context menu is up. tvOS hands the Menu press
    /// that dismisses the menu to this screen as well, and without this the
    /// screen would treat it as Back and return to Home.
    @State private var isEpisodeMenuPresented = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false
    @AppStorage(SettingsKey.smartStreamUseTopResult) private var smartStreamUseTopResult = false
    @AppStorage(SettingsKey.smartStreamQuality) private var smartStreamQuality = "Highest"
    @AppStorage(SettingsKey.smartSubtitleMatching) private var smartSubtitleMatching = true
    @AppStorage(SettingsKey.subtitleLanguages) private var subtitleLanguages = ""
    @AppStorage(SettingsKey.subtitleLanguage) private var subtitleLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguageSecondary) private var subtitleLanguageSecondary = "None"
    @AppStorage(SettingsKey.subtitleLanguageTertiary) private var subtitleLanguageTertiary = "None"
    @AppStorage(SettingsKey.tmdbEnabled) private var tmdbEnabled = false
    @AppStorage(SettingsKey.tmdbApiKey) private var tmdbApiKey = ""
    @AppStorage(SettingsKey.debridProvider) private var debridProvider = "None"
    @AppStorage(SettingsKey.debridApiKey) private var debridApiKey = ""
    /// True while a torrent stream is being resolved through the debrid provider,
    /// so the picker can keep its spinner up instead of appearing to hang.
    @State private var isResolvingDebrid = false

    init(
        id: String,
        type: String,
        repository: CatalogRepository,
        initiallyPresentStreamPicker: Bool = false,
        initialStreamPickerEpisode: NuvioVideo? = nil,
        onInitialStreamPickerPresented: (() -> Void)? = nil,
        onPlayClick: @escaping (String, [String: String], NuvioMeta, String, [NuvioSubtitle], NuvioVideo?, [NuvioVideo], ExternalPlayer?) -> Void,
        onBack: @escaping () -> Void,
        onOpenTitle: ((String, String) -> Void)? = nil,
        onOpenProduction: ((MetaCompany) -> Void)? = nil,
        onOpenPerson: ((TmdbPersonMetadata) -> Void)? = nil
    ) {
        self.id = id
        self.type = type
        self.onPlayClick = onPlayClick
        self.onBack = onBack
        self.onOpenTitle = onOpenTitle
        self.onOpenProduction = onOpenProduction
        self.onOpenPerson = onOpenPerson
        self.initiallyPresentStreamPicker = initiallyPresentStreamPicker
        self.initialStreamPickerEpisode = initialStreamPickerEpisode
        self.onInitialStreamPickerPresented = onInitialStreamPickerPresented
        _viewModel = StateObject(wrappedValue: DetailsViewModel(repository: repository))
        TVHomeDebugTrace.log("details.init id=\(id) type=\(type)")
    }

    var body: some View {
        ZStack {
            if viewModel.uiState.isLoading {
                // A bare ProgressView here was a single blue dot on a black
                // screen. Use the wordmark sweep the rest of the app loads on.
                BrandLoadingView(wordmarkWidth: 420)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.uiState.error {
                ErrorView(
                    error: error,
                    onRetry: { viewModel.loadDetails(id: id, type: type) },
                    onBack: handleBack
                )
            } else if viewModel.uiState.meta != nil {
                #if os(tvOS) || os(macOS)
                TvDetailsContent(
                    uiState: viewModel.uiState,
                    onPlayClick: {
                        // Movie (or a series with no episode list): make sure streams
                        // are loaded for the canonical title id, then either auto-select
                        // or open the picker.
                        pendingEpisodeSubtitle = ""
                        pendingEpisode = nil
                        startStreamFlow(streamId: viewModel.uiState.meta?.streamId ?? id, type: viewModel.uiState.meta?.type ?? type, reload: viewModel.uiState.streams.isEmpty)
                    },
                    onPlayManually: {
                        // Hold-to-play-manually: always open the picker even when Auto Select is on.
                        pendingEpisodeSubtitle = ""
                        pendingEpisode = nil
                        startStreamFlow(
                            streamId: viewModel.uiState.meta?.streamId ?? id,
                            type: viewModel.uiState.meta?.type ?? type,
                            reload: viewModel.uiState.streams.isEmpty,
                            forceManualPicker: true
                        )
                    },
                    onEpisodeSelected: { video in
                        pendingEpisodeSubtitle = "S\(video.season) · E\(video.episode) · \(video.title)"
                        pendingEpisode = video
                        let streamId = canonicalEpisodeStreamId(for: video, meta: viewModel.uiState.meta)
                        startStreamFlow(streamId: streamId, type: "series", reload: true)
                    },
                    onEpisodePlayManually: { video in
                        pendingEpisodeSubtitle = "S\(video.season) · E\(video.episode) · \(video.title)"
                        pendingEpisode = video
                        let streamId = canonicalEpisodeStreamId(for: video, meta: viewModel.uiState.meta)
                        startStreamFlow(streamId: streamId, type: "series", reload: true, forceManualPicker: true)
                    },
                    onEpisodeMenuPresented: { isPresented in
                        isEpisodeMenuPresented = isPresented
                    },
                    onWatchlistClick: { viewModel.toggleWatchlist() },
                    onWatchedClick: { viewModel.toggleWatched() },
                    onShareClick: { shareContent(viewModel.uiState.meta!) },
                    onTrailerClick: { openTrailer(for: viewModel.uiState.meta!) },
                    onOpenTitle: { contentId, contentType in
                        onOpenTitle?(contentId, contentType)
                    },
                    onOpenProduction: { company in
                        onOpenProduction?(company)
                    },
                    onOpenPerson: { person in
                        onOpenPerson?(person)
                    },
                    onCommentSelect: { comment in
                        expandedComment = comment
                    },
                    onBack: handleBack,
                    isStreamsPresented: $isStreamPickerPresented,
                    onSelectStream: { stream, player in
                        guard let meta = viewModel.uiState.meta else { return }
                        PlaybackStartupTiming.start(title: meta.name)
                        isStreamPickerPresented = false
                        isPreparingPlayback = true
                        playStream(stream, meta: meta, player: player)
                    },
                    streamsSubtitle: macStreamsSubtitle,
                    includeDebrid: DebridResolver(store: ProfileSettings.current).isEnabled
                )
                // While the stream picker is open it sits on top as a full-screen
                // overlay; disable the details content so the focus engine can't
                // route focus to the (hidden) buttons behind it. macOS shows the
                // streams in this page's own rail, so it must stay live.
                #if os(macOS)
                .disabled(expandedComment != nil || isSmartPlaybackPending || isResolvingDebrid || isPreparingPlayback)
                #else
                .disabled(isStreamPickerPresented || expandedComment != nil || isSmartPlaybackPending || isResolvingDebrid || isPreparingPlayback)
                #endif
                #else
                MobileDetailsContent(
                    uiState: viewModel.uiState,
                    onPlayClick: {
                        if let url = viewModel.uiState.streams.first?.url,
                           let meta = viewModel.uiState.meta {
                            onPlayClick(url, [:], meta, "", [], nil, [], nil)
                        }
                    },
                    onWatchlistClick: { viewModel.toggleWatchlist() },
                    onWatchedClick: { viewModel.toggleWatched() },
                    onShareClick: { shareContent(viewModel.uiState.meta!) },
                    onBack: handleBack
                )
                #endif
            }

            #if os(tvOS) || os(macOS)
            if let expandedComment {
                CommentDetailOverlay(
                    comment: expandedComment,
                    onDismiss: { self.expandedComment = nil }
                )
                .transition(.opacity)
                .zIndex(20)
            }

            if let meta = viewModel.uiState.meta,
               (isSmartPlaybackPending || isResolvingDebrid || isPreparingPlayback) && !isStreamPickerPresented {
                PlayerLoadingOverlay(
                    backdropUrl: meta.backgroundUrl ?? meta.posterUrl,
                    logoUrl: meta.logoUrl,
                    title: meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
                .zIndex(25)
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.18), value: isStreamPickerPresented)
        #if os(tvOS)
        // Present sources in an isolated full-screen focus hierarchy. Keeping
        // this overlay inside the details screen's vertical ScrollView ancestry
        // lets tvOS apply focus-visibility corrections to the shared host,
        // occasionally translating the filters and stream panel below screen.
        //
        // macOS has no equivalent step: the same streams appear in the details
        // rail, so the title stays on screen while you pick one.
        .modalCover(isPresented: $isStreamPickerPresented) {
            if let meta = viewModel.uiState.meta {
                TvStreamPickerOverlay(
                    meta: meta,
                    episode: pendingEpisode,
                    streams: viewModel.uiState.streams,
                    groups: viewModel.uiState.streamGroups,
                    streamsRevision: viewModel.uiState.streamsRevision,
                    isLoading: viewModel.uiState.isLoadingStreams,
                    emptyReason: viewModel.uiState.streamsEmptyReason,
                    includeDebrid: DebridResolver(store: ProfileSettings.current).isEnabled,
                    isResolvingDebrid: isResolvingDebrid,
                    onSelect: { stream, player in
                        PlaybackStartupTiming.start(title: meta.name)
                        isStreamPickerPresented = false
                        isPreparingPlayback = true
                        playStream(stream, meta: meta, player: player)
                    },
                    onDismiss: {
                        isStreamPickerPresented = false
                    }
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        // Menu-press safety net. While the stream picker is up, focus can be
        // in limbo for a few frames (details content is disabled, the picker
        // hasn't committed focus yet); a Menu press then skips the picker's
        // own onExitCommand and bubbles to the app shell, which backs out to
        // Home or suspends the app. Catching it here closes just the picker,
        // and otherwise behaves like the regular back action.
        .onExitCommand {
            if isEpisodeMenuPresented {
                // The context menu consumed this press to close itself; it
                // reaches here anyway. Swallow it so Details stays put.
                isEpisodeMenuPresented = false
            } else if expandedComment != nil {
                expandedComment = nil
            } else if isSmartPlaybackPending || isResolvingDebrid || isPreparingPlayback {
                PlaybackStartupTiming.cancel()
                isSmartPlaybackPending = false
                isResolvingDebrid = false
                isPreparingPlayback = false
            } else if isStreamPickerPresented {
                isStreamPickerPresented = false
            } else {
                handleBack()
            }
        }
        #endif
        .onChange(of: viewModel.uiState.isLoadingStreams) { _, isLoading in
            if !isLoading {
                finishSmartPlaybackIfPossible()
            }
        }
        .onChange(of: viewModel.uiState.streamsRevision) { _, _ in
            finishSmartPlaybackIfPossible()
        }
        .onChange(of: viewModel.uiState.isLoading) { _, isLoading in
            if !isLoading {
                presentInitialStreamPickerIfNeeded()
            }
        }
        .onAppear {
            PlaybackStartupTiming.cancel()
            isSmartPlaybackPending = false
            isResolvingDebrid = false
            isPreparingPlayback = false
            TVHomeDebugTrace.log("details.appear id=\(id) type=\(type)")
            viewModel.loadDetails(id: id, type: type)
            presentInitialStreamPickerIfNeeded()
        }
        .onDisappear {
            TVHomeDebugTrace.log("details.disappear id=\(id) type=\(type)")
            viewModel.cancelAllTasks()
        }
    }

    /// Stop Details work before asking the parent to remove this screen.
    /// Waiting for onDisappear is too late: enrichment can still publish
    /// updates while the opacity transition is trying to tear Details down.
    private func handleBack() {
        PlaybackStartupTiming.cancel()
        TVHomeDebugTrace.log("details.back.cancelTasks id=\(id)")
        viewModel.cancelAllTasks()
        onBack()
    }

    private func presentInitialStreamPickerIfNeeded() {
        guard initiallyPresentStreamPicker,
              !didHandleInitialStreamPicker,
              !viewModel.uiState.isLoading,
              let meta = viewModel.uiState.meta else { return }

        didHandleInitialStreamPicker = true
        onInitialStreamPickerPresented?()
        isSmartPlaybackPending = false
        // Prefer the entry from the guide this screen just loaded. A Continue
        // Watching card carries no episode guide, so it can only name the season
        // and episode — and the player queues the next episode by matching ids,
        // which a stand-in entry would not satisfy.
        let requestedEpisode = initialStreamPickerEpisode.map { requested in
            (meta.videos ?? []).first {
                $0.season == requested.season && $0.episode == requested.episode
            } ?? requested
        }
        pendingEpisode = requestedEpisode
        if let episode = requestedEpisode {
            pendingEpisodeSubtitle = "S\(episode.season) · E\(episode.episode) · \(episode.title)"
            let streamId = canonicalEpisodeStreamId(for: episode, meta: meta)
            viewModel.prepareStreams(forId: streamId, type: "series")
        } else {
            pendingEpisodeSubtitle = ""
            viewModel.prepareStreams(forId: meta.streamId, type: meta.type)
        }
        isStreamPickerPresented = true
    }

    private func canonicalEpisodeStreamId(for video: NuvioVideo, meta: NuvioMeta?) -> String {
        if video.id.hasPrefix("tt") {
            return video.id
        }
        if let metaStreamId = meta?.streamId, metaStreamId.hasPrefix("tt") {
            return "\(metaStreamId):\(video.season):\(video.episode)"
        }
        return video.id
    }

    /// Names what the rail's streams belong to, so a series does not just say
    /// "Streams" with no indication of which episode.
    private var macStreamsSubtitle: String? {
        guard let episode = pendingEpisode else { return viewModel.uiState.meta?.name }
        let number = "S\(episode.season)E\(episode.episode)"
        return episode.title.isEmpty ? number : "\(number) · \(episode.title)"
    }

    private func startStreamFlow(streamId: String, type: String, reload: Bool, forceManualPicker: Bool = false) {
        guard let meta = viewModel.uiState.meta else { return }

        if forceManualPicker || !smartStreamSelection {
            isSmartPlaybackPending = false
            if reload {
                viewModel.prepareStreams(forId: streamId, type: type)
            }
            isStreamPickerPresented = true
            return
        }

        PlaybackStartupTiming.start(title: meta.name)
        isSmartPlaybackPending = true
        isStreamPickerPresented = false

        if reload {
            viewModel.prepareStreams(forId: streamId, type: type, forceRefresh: true)
        }
        finishSmartPlaybackIfPossible(meta: meta)
    }

    private func finishSmartPlaybackIfPossible(meta explicitMeta: NuvioMeta? = nil) {
        guard isSmartPlaybackPending else { return }
        let meta = explicitMeta ?? viewModel.uiState.meta
        guard let meta else { return }

        let debrid = DebridResolver(store: ProfileSettings.current)
        let cachedOnly = (ProfileSettings.current.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false

        let candidateStream: NuvioStream?
        if smartStreamUseTopResult {
            let sortRaw = ProfileSettings.current.string(forKey: SettingsKey.streamSortOption)
            let sortOption = sortRaw.flatMap(StreamSortOption.init(rawValueOrSync:)) ?? .quality
            let displayed = StreamPickerListBuilder.displayedStreams(
                streams: viewModel.uiState.streams,
                groups: viewModel.uiState.streamGroups,
                selectedAddonId: nil,
                sortOption: sortOption,
                includeDebrid: debrid.isEnabled,
                cachedOnly: cachedOnly
            )
            // Filter out 0-res / ticket streams if valid streams exist
            let valid = displayed.filter {
                !SmartPlaybackSelector.isLowQualityOrTicketStream($0) && StreamPickerListBuilder.resolution(for: $0) >= 720
            }
            candidateStream = valid.first ?? displayed.first
        } else {
            candidateStream = SmartPlaybackSelector.bestStream(
                from: viewModel.uiState.streams,
                qualityPreference: smartStreamQuality,
                subtitleLanguages: subtitleLanguagePreferences,
                shouldMatchSubtitles: smartSubtitleMatching,
                includeDebrid: debrid.isEnabled,
                preferredTags: LastStreamQualityStore.load(metaId: meta.id),
                cachedOnly: cachedOnly
            )
        }

        if let stream = candidateStream {
            let isIdealMatch: Bool = {
                if !viewModel.uiState.isLoadingStreams { return true }
                if SmartPlaybackSelector.isLowQualityOrTicketStream(stream) { return false }
                let tags = StreamQualityTags.parse(stream: stream)
                let res = tags.resolution > 0 ? tags.resolution : SmartPlaybackSelector.inferredResolution(for: stream)
                let targetRes = (smartStreamQuality == "720p") ? 720 : 1080
                if debrid.isEnabled {
                    return tags.isCached && res >= targetRes
                }
                return res >= targetRes
            }()

            if isIdealMatch {
                isSmartPlaybackPending = false
                playStream(stream, meta: meta)
            }
        } else if !viewModel.uiState.isLoadingStreams && (viewModel.uiState.streamsEmptyReason != nil || !viewModel.uiState.streamGroups.isEmpty) {
            PlaybackStartupTiming.cancel()
            isSmartPlaybackPending = false
            isStreamPickerPresented = true
        }
    }

    /// Plays a chosen stream. Direct URLs go straight to the player; torrent-only
    /// streams are resolved through the configured debrid provider first, keeping
    /// the picker's spinner up until a link comes back (or the attempt fails).
    private func playStream(_ stream: NuvioStream, meta: NuvioMeta, player: ExternalPlayer? = nil) {
        LastStreamQualityStore.save(metaId: meta.id, stream: stream)
        PlaybackStartupBenchmark.shared.markSourcePicked(stream: stream)
        if let url = stream.url, !url.isEmpty {
            isStreamPickerPresented = false
            isPreparingPlayback = false
            onPlayClick(url, stream.httpHeaders ?? [:], meta, pendingEpisodeSubtitle, stream.subtitles, pendingEpisode, orderedEpisodes(for: meta), player)
            return
        }

        guard stream.isDebridResolvable, !isResolvingDebrid else {
            isPreparingPlayback = false
            return
        }
        let season = pendingEpisode?.season
        let episode = pendingEpisode?.episode
        isResolvingDebrid = true
        Task {
            let result = await DebridResolver(store: ProfileSettings.current)
                .resolvedURL(for: stream, season: season, episode: episode)
            await MainActor.run {
                isResolvingDebrid = false
                isPreparingPlayback = false
                if case let .success(url, _, _)? = result {
                    PlaybackStartupBenchmark.shared.markDebridResolved()
                    isStreamPickerPresented = false
                    onPlayClick(url.absoluteString, stream.httpHeaders ?? [:], meta, pendingEpisodeSubtitle, stream.subtitles, pendingEpisode, orderedEpisodes(for: meta), player)
                } else {
                    PlaybackStartupBenchmark.shared.cancel()
                    isStreamPickerPresented = true
                }
            }
        }
    }

    private var subtitleLanguagePreferences: [String] {
        SubtitleLanguagePreferences.ordered(
            encoded: subtitleLanguages,
            primary: subtitleLanguage,
            secondary: subtitleLanguageSecondary,
            tertiary: subtitleLanguageTertiary
        )
    }

    /// The series' episodes in playback order (specials last), handed to the
    /// player so it can offer the next one. Empty for movies.
    private func orderedEpisodes(for meta: NuvioMeta) -> [NuvioVideo] {
        guard meta.isSeries else { return [] }
        return (meta.videos ?? []).sorted {
            (Self.episodeSeasonSortKey($0.season), $0.episode) < (Self.episodeSeasonSortKey($1.season), $1.episode)
        }
    }

    private static func episodeSeasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    private func shareContent(_ meta: NuvioMeta) {
        var shareText = "Check out \(meta.name)"
        if let year = meta.year {
            shareText += " (\(year))"
        }
        shareText += "\n\n"
        if let description = meta.description {
            shareText += description
        }
        if let imdbId = meta.imdbId {
            shareText += "\n\nhttps://www.imdb.com/title/\(imdbId)"
        }

        #if os(macOS)
        // AppKit's share picker needs an anchor rect; the key window's content
        // view is the closest equivalent to presenting from the root controller.
        guard let anchor = NSApplication.shared.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [shareText])
        picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
        #elseif !os(tvOS)
        let activityVC = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #endif
    }

    private func openTrailer(for meta: NuvioMeta) {
        Task {
            if let source = await YouTubeTrailerResolver.shared.resolve(for: meta) {
                await MainActor.run {
                    onPlayClick(source.videoUrl, source.requestHeaders, meta, PlaybackMarkers.trailerSubtitle, [], nil, [], nil)
                }
            } else if let ytId = await preferredTrailerYouTubeId(for: meta) {
                let youtubeUrl = "https://www.youtube.com/watch?v=\(ytId)"
                await MainActor.run {
                    onPlayClick(youtubeUrl, [:], meta, PlaybackMarkers.trailerSubtitle, [], nil, [], nil)
                }
            }
        }
    }

    private func preferredTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        await YouTubeTrailerResolver.preferredTrailerYouTubeId(for: meta)
    }
}

actor YouTubeTrailerResolver {
    static let shared = YouTubeTrailerResolver()
    private var trailerIdCache: [String: String] = [:]
    private var trailerioCache: [String: TrailerPlaybackSource] = [:]

    private struct TrailerioResponse: Decodable {
        struct Meta: Decodable {
            struct Link: Decodable {
                let trailers: String?
                let provider: String?
            }
            let id: String?
            let links: [Link]?
        }
        let meta: Meta?
    }

    private func scoreTrailerioLink(_ provider: String, url: String) -> Int {
        let p = provider.lowercased()
        var score = 0
        if p.contains("apple tv") {
            score += 1000
        } else if p.contains("rotten tomatoes") || p.contains("fandango") {
            score += 800
        } else if p.contains("plex") {
            score += 700
        } else if p.contains("mubi") {
            score += 500
        } else if p.contains("imdb") {
            score += 300
        }

        if p.contains("4k") || p.contains("2160p") {
            score += 400
        } else if p.contains("1080p") {
            score += 300
        } else if p.contains("720p") {
            score += 200
        }

        if p.contains("atmos") || p.contains("5.1") {
            score += 50
        }

        let u = url.lowercased()
        if u.contains(".m3u8") || u.contains(".mp4") {
            score += 100
        }

        return score
    }

    func resolveTrailerio(imdbId: String, isSeries: Bool) async -> TrailerPlaybackSource? {
        let cleanImdb = NuvioMeta.canonicalImdbID(from: imdbId) ?? imdbId
        guard cleanImdb.hasPrefix("tt") else { return nil }

        if let cached = trailerioCache[cleanImdb] {
            return cached
        }

        let mediaType = isSeries ? "series" : "movie"
        guard let url = URL(string: "https://trailerio.cc/meta/\(mediaType)/\(cleanImdb).json") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("NuvioTV/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TrailerioResponse.self, from: data),
              let links = decoded.meta?.links, !links.isEmpty else {
            return nil
        }

        let validLinks = links.compactMap { link -> (url: String, provider: String)? in
            guard let rawUrl = link.trailers?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawUrl.isEmpty,
                  rawUrl.hasPrefix("http://") || rawUrl.hasPrefix("https://") else {
                return nil
            }
            return (url: rawUrl, provider: link.provider ?? "1080p")
        }

        guard !validLinks.isEmpty else { return nil }

        let sorted = validLinks.sorted { scoreTrailerioLink($0.provider, url: $0.url) > scoreTrailerioLink($1.provider, url: $1.url) }
        guard let best = sorted.first else { return nil }

        let source = TrailerPlaybackSource(
            videoUrl: best.url,
            audioUrl: nil,
            requestHeaders: [:],
            qualityLabel: best.provider,
            diagnostics: "TRAILER: \(best.provider) [Trailerio 1080p]"
        )
        trailerioCache[cleanImdb] = source
        return source
    }

    func resolve(for meta: NuvioMeta) async -> TrailerPlaybackSource? {
        // 1. Try Trailerio first (direct 1080p CDN streams from Apple TV, Rotten Tomatoes, Plex)
        if let imdbId = meta.imdbId ?? NuvioMeta.canonicalImdbID(from: meta.id),
           let source = await resolveTrailerio(imdbId: imdbId, isSeries: meta.isSeries) {
            return source
        }

        // 2. Fall back to YouTube resolver
        guard let ytId = await preferredTrailerYouTubeId(for: meta) else { return nil }
        return await resolve(
            youtubeVideoId: ytId,
            title: meta.name,
            year: meta.year.map(String.init)
        )
    }

    func resolvePreview(for meta: NuvioMeta) async -> TrailerPlaybackSource? {
        // 1. Try Trailerio first (direct 1080p CDN streams from Apple TV, Rotten Tomatoes, Plex)
        if let imdbId = meta.imdbId ?? NuvioMeta.canonicalImdbID(from: meta.id),
           let source = await resolveTrailerio(imdbId: imdbId, isSeries: meta.isSeries) {
            return source
        }

        // 2. Fall back to YouTube preview resolver
        guard let ytId = await preferredTrailerYouTubeId(for: meta) else { return nil }
        return await resolvePreview(
            youtubeVideoId: ytId,
            title: meta.name,
            year: meta.year.map(String.init)
        )
    }

    static func preferredTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        await shared.preferredTrailerYouTubeId(for: meta)
    }

    func preferredTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        let cacheKey = "\(meta.id)|\(meta.tmdbId ?? 0)"
        if let cached = trailerIdCache[cacheKey] {
            return cached.isEmpty ? nil : cached
        }

        var resolvedId: String? = nil

        if let ytId = meta.trailerYtIds?
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { Self.isYouTubeVideoId($0) }) {
            resolvedId = ytId
        } else if let ytId = await TmdbDetailsService.fetchTrailerYouTubeId(for: meta),
           Self.isYouTubeVideoId(ytId.trimmingCharacters(in: .whitespacesAndNewlines)) {
            resolvedId = ytId
        } else if let refreshed = try? await CinemetaCatalogRepository().getMetadata(
            id: meta.id,
            type: meta.type
        ), let ytId = refreshed.trailerYtIds?
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { Self.isYouTubeVideoId($0) }) {
            resolvedId = ytId
        }

        trailerIdCache[cacheKey] = resolvedId ?? ""
        return resolvedId
    }
    private struct Client {
        let key: String
        let id: String
        let version: String
        let userAgent: String
        let context: [String: Any]
        let priority: Int
    }

    private struct WatchConfig {
        let apiKey: String
        let visitorData: String?
        let fetchedAt: Date
    }

    private struct StreamCandidate {
        let clientKey: String
        let url: String
        let height: Int
        let score: Double
        let hasN: Bool
        let ext: String
        let priority: Int
    }

    private struct HlsCandidate {
        let manifestUrl: String
        let clientKey: String
        let height: Int
        let bandwidth: Int
        let priority: Int
    }

    private struct TrailerBackendResponse: Decodable {
        let url: String?
        let videoUrl: String?
        let streamUrl: String?
        let hls: String?
        let hlsUrl: String?
        let quality: String?
        let resolution: String?

        var effectiveUrl: String? {
            url ?? videoUrl ?? streamUrl ?? hls ?? hlsUrl
        }
    }

    private static let defaultUserAgent =
        "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let fallbackApiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private static let configTTL: TimeInterval = 3 * 60 * 60
    private static let resolverBaseKey = "nuvio.tv.settings.playback.trailerResolverBaseURL"
    private static let embeddedPlayerOrigin = "https://nuvioapp.space/"
    private static let probeTimeout: TimeInterval = 3
    private static let attemptBudget: TimeInterval = 12

    private static let clients: [Client] = [
        Client(
            key: "ios",
            id: "5",
            version: "20.10.1",
            userAgent: "com.google.ios.youtube/20.10.1 (iPhone16,2; U; CPU iOS 17_4 like Mac OS X)",
            context: [
                "clientName": "IOS",
                "clientVersion": "20.10.1",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "17.4.0.21E219",
                "platform": "MOBILE",
                "hl": "en",
                "gl": "US"
            ],
            priority: 0
        ),
        Client(
            key: "android",
            id: "3",
            version: "20.10.35",
            userAgent: "com.google.android.youtube/20.10.35 (Linux; U; Android 14; en_US) gzip",
            context: [
                "clientName": "ANDROID",
                "clientVersion": "20.10.35",
                "osName": "Android",
                "osVersion": "14",
                "platform": "MOBILE",
                "androidSdkVersion": 34,
                "hl": "en",
                "gl": "US"
            ],
            priority: 1
        ),
        Client(
            key: "android_vr",
            id: "28",
            version: "1.56.21",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1) gzip",
            context: [
                "clientName": "ANDROID_VR",
                "clientVersion": "1.56.21",
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "osName": "Android",
                "osVersion": "12",
                "platform": "MOBILE",
                "androidSdkVersion": 32,
                "hl": "en",
                "gl": "US"
            ],
            priority: 2
        )
    ]

    private var cachedConfig: WatchConfig?
    private var previewCache: [String: (source: TrailerPlaybackSource, date: Date)] = [:]
    private var probeResults: [String: Bool] = [:]
    private var attemptStartedAt: Date?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: configuration)
    }()

    private let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        return URLSession(configuration: configuration)
    }()

    func resolve(youtubeVideoId: String, title: String?, year: String?) async -> TrailerPlaybackSource? {
        guard Self.isYouTubeVideoId(youtubeVideoId) else { return nil }

        let youtubeUrl = "https://www.youtube.com/watch?v=\(youtubeVideoId)"
        if let source = await resolveWithBackend(
            videoId: youtubeVideoId,
            youtubeUrl: youtubeUrl,
            title: title,
            year: year
        ) {
            return source
        }

        // Full player supports 1080p adaptive video + audio pairs as well as HLS
        if let source = await resolveWithInnertube(
            videoId: youtubeVideoId,
            forceRefreshConfig: false,
            preferIntegratedStream: false
        ) {
            return source
        }

        guard !Task.isCancelled else { return nil }
        cachedConfig = nil

        // Retry with refreshed config
        if let source = await resolveWithInnertube(
            videoId: youtubeVideoId,
            forceRefreshConfig: true,
            preferIntegratedStream: false
        ) {
            return source
        }

        return nil
    }

    /// Returns an integrated preview stream and the headers required by its
    /// originating YouTube client.
    func resolvePreview(youtubeVideoId: String, title: String?, year: String?) async -> TrailerPlaybackSource? {
        guard Self.isYouTubeVideoId(youtubeVideoId) else { return nil }

        if let cached = previewCache[youtubeVideoId], Date().timeIntervalSince(cached.date) < 1800 {
            return cached.source
        }

        let youtubeUrl = "https://www.youtube.com/watch?v=\(youtubeVideoId)"
        if let source = await resolveWithBackend(
            videoId: youtubeVideoId,
            youtubeUrl: youtubeUrl,
            title: title,
            year: year
        ) {
            previewCache[youtubeVideoId] = (source, Date())
            return source
        }

        if let source = await resolveWithInnertube(
            videoId: youtubeVideoId,
            forceRefreshConfig: false,
            preferIntegratedStream: true
        ) {
            previewCache[youtubeVideoId] = (source, Date())
            return source
        }

        guard !Task.isCancelled else { return nil }
        cachedConfig = nil
        if let source = await resolveWithInnertube(
            videoId: youtubeVideoId,
            forceRefreshConfig: true,
            preferIntegratedStream: true
        ) {
            previewCache[youtubeVideoId] = (source, Date())
            return source
        }

        return nil
    }

    private func resolveWithInnertube(
        videoId: String,
        forceRefreshConfig: Bool,
        preferIntegratedStream: Bool = false
    ) async -> TrailerPlaybackSource? {
        guard !Task.isCancelled else { return nil }
        probeResults.removeAll(keepingCapacity: true)
        attemptStartedAt = Date()
        guard let config = try? await watchConfig(forceRefresh: forceRefreshConfig),
              canContinueAttempt else { return nil }
        var hlsCandidates: [HlsCandidate] = []
        var progressive: [StreamCandidate] = []
        var adaptiveVideo: [StreamCandidate] = []
        var adaptiveAudio: [StreamCandidate] = []

        for client in Self.clients {
            guard canContinueAttempt else { return nil }
            guard let playerResponse = try? await fetchPlayerResponse(
                apiKey: config.apiKey,
                videoId: videoId,
                client: client,
                visitorData: config.visitorData
            ) else {
                guard canContinueAttempt else { return nil }
                continue
            }
            guard canContinueAttempt else { return nil }

            if let status = stringValue(mapValue(playerResponse, key: "playabilityStatus"), key: "status"),
               status != "OK" {
                continue
            }

            guard let streamingData = mapValue(playerResponse, key: "streamingData") else { continue }

            if let manifestUrl = stringValue(streamingData, key: "hlsManifestUrl") {
                do {
                    let candidate = try await hlsCandidate(
                        manifestUrl: manifestUrl,
                        client: client,
                        includeReferer: false
                    )
                    hlsCandidates.append(candidate)
                } catch {
                }
            }
            guard canContinueAttempt else { return nil }

            for format in listMapValue(streamingData, key: "formats") {
                guard let url = stringValue(format, key: "url") else { continue }
                let mimeType = stringValue(format, key: "mimeType") ?? ""
                guard mimeType.contains("video/") else { continue }

                let height = Int(numberValue(format, key: "height") ?? Double(parseQualityLabel(stringValue(format, key: "qualityLabel")) ?? 0))
                let fps = Int(numberValue(format, key: "fps") ?? 0)
                let bitrate = numberValue(format, key: "bitrate") ?? numberValue(format, key: "averageBitrate") ?? 0

                progressive.append(
                    StreamCandidate(
                        clientKey: client.key,
                        url: url,
                        height: height,
                        score: videoScore(height: height, fps: fps, bitrate: bitrate),
                        hasN: hasNParam(url),
                        ext: mimeType.contains("webm") ? "webm" : "mp4",
                        priority: client.priority
                    )
                )
            }

            for format in listMapValue(streamingData, key: "adaptiveFormats") {
                guard let url = stringValue(format, key: "url") else { continue }
                let mimeType = stringValue(format, key: "mimeType") ?? ""
                let hasVideo = mimeType.contains("video/")
                let hasAudio = mimeType.contains("audio/") || mimeType.hasPrefix("audio/")

                if hasVideo {
                    let height = Int(numberValue(format, key: "height") ?? Double(parseQualityLabel(stringValue(format, key: "qualityLabel")) ?? 0))
                    let fps = Int(numberValue(format, key: "fps") ?? 0)
                    let bitrate = numberValue(format, key: "bitrate") ?? numberValue(format, key: "averageBitrate") ?? 0

                    adaptiveVideo.append(
                        StreamCandidate(
                            clientKey: client.key,
                            url: url,
                            height: height,
                            score: videoScore(height: height, fps: fps, bitrate: bitrate),
                            hasN: hasNParam(url),
                            ext: mimeType.contains("webm") ? "webm" : "mp4",
                            priority: client.priority
                        )
                    )
                } else if hasAudio {
                    let bitrate = numberValue(format, key: "bitrate") ?? numberValue(format, key: "averageBitrate") ?? 0
                    let sampleRate = numberValue(format, key: "audioSampleRate") ?? 0

                    adaptiveAudio.append(
                        StreamCandidate(
                            clientKey: client.key,
                            url: url,
                            height: 0,
                            score: audioScore(bitrate: bitrate, sampleRate: sampleRate),
                            hasN: hasNParam(url),
                            ext: mimeType.contains("webm") ? "webm" : "m4a",
                            priority: client.priority
                        )
                    )
                }
            }
        }

        let sortedHLS = hlsCandidates.sorted(by: sortHlsCandidates)
        let sortedAdaptiveVideo = adaptiveVideo.sorted(by: sortStreamCandidates)
        let sortedAdaptiveAudio = adaptiveAudio.sorted(by: sortStreamCandidates)
        let sortedProgressive = progressive.filter { $0.height > 0 }.sorted(by: sortStreamCandidates)

        var summaryParts: [String] = []
        let hlsDesc = sortedHLS.map { "\($0.clientKey):\($0.height)p" }.joined(separator: ", ")
        if !hlsDesc.isEmpty { summaryParts.append("HLS[\(hlsDesc)]") }
        let progDesc = sortedProgressive.map { "\($0.clientKey):\($0.height)p" }.joined(separator: ", ")
        if !progDesc.isEmpty { summaryParts.append("Prog[\(progDesc)]") }
        let adaptDesc = sortedAdaptiveVideo.prefix(6).map { "\($0.clientKey):\($0.height)p" }.joined(separator: ", ")
        if !adaptDesc.isEmpty { summaryParts.append("Adaptive[\(adaptDesc)]") }
        let availableSummary = summaryParts.joined(separator: " | ")

        let unthrottledAdaptiveVideo = sortedAdaptiveVideo
        let unthrottledAdaptiveAudio = sortedAdaptiveAudio

        // 1. Prioritize HD HLS master manifest (1080p / 720p).
        // HLS contains video+audio natively, decoded by AetherEngine / AVPlayer in full 1080p HD with zero 403 errors.
        if let bestHls = sortedHLS.first, bestHls.height >= 720 {
            let label = "\(bestHls.height)p (HLS)"
            let diag = "TRAILER: \(label) [\(bestHls.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: bestHls.manifestUrl,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: bestHls.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 2. Check for HD progressive streams (1080p / 720p muxed MP4)
        if let bestProg = await firstReachable(
            sortedProgressive.filter { $0.height >= 720 },
            includeReferer: false
        ) {
            let label = "\(bestProg.height)p (MP4)"
            let diag = "TRAILER: \(label) [\(bestProg.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: bestProg.url,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: bestProg.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 3. For full player: Check for 1080p+ unthrottled adaptive pair
        if !preferIntegratedStream,
           let pair = await firstReachableAdaptivePair(
               videos: unthrottledAdaptiveVideo.filter { $0.height >= 1080 },
               audios: unthrottledAdaptiveAudio,
               includeReferer: false
           ) {
            let label = "\(pair.video.height)p (Adaptive)"
            let diag = "TRAILER: \(label) [\(pair.video.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: pair.video.url,
                audioUrl: pair.audio.url,
                requestHeaders: requestHeaders(
                    for: pair.video.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 4. For full player: Check for 720p unthrottled adaptive pair
        if !preferIntegratedStream,
           let pair = await firstReachableAdaptivePair(
               videos: unthrottledAdaptiveVideo.filter { $0.height >= 720 },
               audios: unthrottledAdaptiveAudio,
               includeReferer: false
           ) {
            let label = "\(pair.video.height)p (Adaptive)"
            let diag = "TRAILER: \(label) [\(pair.video.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: pair.video.url,
                audioUrl: pair.audio.url,
                requestHeaders: requestHeaders(
                    for: pair.video.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 5. Fall back to any HLS stream (often contains 1080p/720p variants)
        if let bestHls = sortedHLS.first {
            let label = "\(bestHls.height > 0 ? "\(bestHls.height)p" : "Adaptive") (HLS)"
            let diag = "TRAILER: \(label) [\(bestHls.clientKey)] | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: bestHls.manifestUrl,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: bestHls.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 6. Fall back to standard progressive (e.g. 360p)
        if let progressiveMatch = await firstReachable(
            sortedProgressive,
            includeReferer: false
        ) {
            let label = "\(progressiveMatch.height)p (MP4)"
            let diag = "TRAILER: \(label) [\(progressiveMatch.clientKey)] fallback | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: progressiveMatch.url,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: progressiveMatch.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 7. For preview: fall back to best adaptive video if no integrated stream exists.
        // On Apple TV, card previews are muted by default and play the video track directly.
        if preferIntegratedStream,
           let bestAdaptive = await firstReachable(
               sortedAdaptiveVideo,
               includeReferer: false
           ) {
            let label = "\(bestAdaptive.height)p (Adaptive Video)"
            let diag = "TRAILER: \(label) [\(bestAdaptive.clientKey)] preview | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: bestAdaptive.url,
                audioUrl: nil,
                requestHeaders: requestHeaders(
                    for: bestAdaptive.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        // 8. For full player: Fall back to any adaptive pair
        if !preferIntegratedStream,
           let pair = await firstReachableAdaptivePair(
               videos: unthrottledAdaptiveVideo,
               audios: unthrottledAdaptiveAudio,
               includeReferer: false
           ) {
            let label = "\(pair.video.height)p (Adaptive)"
            let diag = "TRAILER: \(label) [\(pair.video.clientKey)] fallback | Available: \(availableSummary)"
            return TrailerPlaybackSource(
                videoUrl: pair.video.url,
                audioUrl: pair.audio.url,
                requestHeaders: requestHeaders(
                    for: pair.video.clientKey,
                    includeReferer: false
                ),
                qualityLabel: label,
                diagnostics: diag
            )
        }

        return nil
    }

    private func watchConfig(forceRefresh: Bool) async throws -> WatchConfig {
        if !forceRefresh,
           let cachedConfig,
           Date().timeIntervalSince(cachedConfig.fetchedAt) < Self.configTTL {
            return cachedConfig
        }

        // Return the reliable fallback Innertube API key directly.
        // Web scraping youtube.com/watch triggers 302 captcha/bot challenges that fail or stall on tvOS.
        let config = WatchConfig(
            apiKey: Self.fallbackApiKey,
            visitorData: nil,
            fetchedAt: Date()
        )
        cachedConfig = config
        return config
    }

    private func fetchPlayerResponse(
        apiKey: String,
        videoId: String,
        client: Client,
        visitorData: String?
    ) async throws -> [String: Any] {
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(encodedKey)") else {
            throw URLError(.badURL)
        }

        let context = client.context
        var requestContext: [String: Any] = ["client": context]
        if client.key == "web_embedded_player" || client.key == "tv_embedded" {
            requestContext["thirdParty"] = [
                "embedUrl": "https://www.youtube.com/embed/\(videoId)"
            ]
        }

        let payload: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": requestContext,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]
            ]
        ]

        var request = URLRequest(url: url)
        guard let timeout = requestTimeout(cap: 8) else { throw CancellationError() }
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        addDefaultHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if client.key == "web_embedded_player" || client.key == "tv_embedded" {
            request.setValue("https://www.youtube.com/embed/\(videoId)", forHTTPHeaderField: "Referer")
        }
        request.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func hlsCandidate(
        manifestUrl: String,
        client: Client,
        includeReferer: Bool
    ) async throws -> HlsCandidate {
        guard let url = URL(string: manifestUrl) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        guard let timeout = requestTimeout(cap: 6) else { throw CancellationError() }
        request.timeoutInterval = timeout
        addDefaultHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var best = HlsCandidate(
            manifestUrl: manifestUrl,
            clientKey: client.key,
            height: 0,
            bandwidth: 0,
            priority: client.priority
        )
        for index in lines.indices {
            let line = lines[index]
            guard line.hasPrefix("#EXT-X-STREAM-INF:"),
                  index + 1 < lines.count,
                  !lines[index + 1].hasPrefix("#") else {
                continue
            }

            let attrs = parseHlsAttributeList(line)
            let (_, height) = parseResolution(attrs["RESOLUTION"] ?? "")
            let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0

            if height > best.height ||
                (height == best.height && bandwidth > best.bandwidth) {
                best = HlsCandidate(
                    manifestUrl: manifestUrl,
                    clientKey: client.key,
                    height: height,
                    bandwidth: bandwidth,
                    priority: client.priority
                )
            }
        }

        if best.height == 0 && text.contains("#EXTM3U") {
            best = HlsCandidate(
                manifestUrl: manifestUrl,
                clientKey: client.key,
                height: 1080,
                bandwidth: 5_000_000,
                priority: client.priority
            )
        }

        return best
    }

    private func resolveWithBackend(
        videoId: String,
        youtubeUrl: String,
        title: String?,
        year: String?
    ) async -> TrailerPlaybackSource? {
        guard let baseUrl = configuredBackendBaseURL() else { return nil }
        let endpoint = baseUrl.lastPathComponent == "trailer" ? baseUrl : baseUrl.appendingPathComponent("trailer")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }

        components.queryItems = [
            URLQueryItem(name: "videoId", value: videoId),
            URLQueryItem(name: "youtube_url", value: youtubeUrl),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "year", value: year)
        ].filter { $0.value != nil }

        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            addDefaultHeaders(to: &request)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            let decoded = try JSONDecoder().decode(TrailerBackendResponse.self, from: data)
            guard let resolved = decoded.effectiveUrl,
                  resolved.hasPrefix("http://") || resolved.hasPrefix("https://") else {
                return nil
            }
            let label = decoded.quality ?? decoded.resolution ?? "1080p (Proxy)"
            let diag = "TRAILER: \(label) [backend proxy]"
            return TrailerPlaybackSource(
                videoUrl: resolved,
                audioUrl: nil,
                qualityLabel: label,
                diagnostics: diag
            )
        } catch {
            return nil
        }
    }

    private func configuredBackendBaseURL() -> URL? {
        let candidates = [
            UserDefaults.standard.string(forKey: Self.resolverBaseKey),
            Bundle.main.object(forInfoDictionaryKey: "NuvioTrailerAPIBaseURL") as? String
        ]

        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .flatMap(URL.init(string:))
    }

    private func addDefaultHeaders(to request: inout URLRequest) {
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
    }

    private func requestHeaders(for clientKey: String, includeReferer: Bool) -> [String: String] {
        guard let client = Self.clients.first(where: { $0.key == clientKey }) else {
            return ["User-Agent": Self.defaultUserAgent]
        }
        var headers = ["User-Agent": client.userAgent]
        if includeReferer {
            headers["Referer"] = client.key == "web_embedded_player"
                ? Self.embeddedPlayerOrigin
                : "https://www.youtube.com/"
        }
        return headers
    }

    private func addStreamHeaders(
        to request: inout URLRequest,
        client: Client,
        includeReferer: Bool
    ) {
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if includeReferer {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue(
                client.key == "web_embedded_player"
                    ? Self.embeddedPlayerOrigin
                    : "https://www.youtube.com/",
                forHTTPHeaderField: "Referer"
            )
        }
    }

    private func firstReachable(
        _ candidates: [StreamCandidate],
        includeReferer: Bool
    ) async -> StreamCandidate? {
        // Keep probing sequential and bounded: each candidate is an actual
        // network request, and a signed URL can fail independently of its API
        // response.
        for candidate in candidates.prefix(8) {
            guard canContinueAttempt else { return nil }
            if await isReachable(
                candidate.url,
                clientKey: candidate.clientKey,
                includeReferer: includeReferer
            ) {
                return candidate
            }
        }
        return nil
    }

    private func firstReachableAdaptivePair(
        videos: [StreamCandidate],
        audios: [StreamCandidate],
        includeReferer: Bool
    ) async -> (video: StreamCandidate, audio: StreamCandidate)? {
        var pairs: [(video: StreamCandidate, audio: StreamCandidate)] = []
        for video in videos.prefix(8) {
            guard canContinueAttempt else { return nil }
            let sameClient = audios.filter { $0.clientKey == video.clientKey }
            for audio in sameClient.prefix(3) {
                pairs.append((video: video, audio: audio))
            }
        }

        for pair in pairs.prefix(12) {
            guard canContinueAttempt else { return nil }
            guard await isReachable(
                pair.video.url,
                clientKey: pair.video.clientKey,
                includeReferer: includeReferer
            ) else {
                continue
            }
            guard await isReachable(
                pair.audio.url,
                clientKey: pair.audio.clientKey,
                includeReferer: includeReferer
            ) else {
                continue
            }
            return pair
        }
        return nil
    }

    private func isReachable(
        _ streamUrl: String,
        clientKey: String,
        includeReferer: Bool
    ) async -> Bool {
        guard canContinueAttempt else { return false }
        if let cached = probeResults[streamUrl] {
            return cached
        }
        guard let url = URL(string: streamUrl),
              let client = Self.clients.first(where: { $0.key == clientKey }) else {
            probeResults[streamUrl] = false
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let timeout = requestTimeout(cap: Self.probeTimeout) else { return false }
        request.timeoutInterval = timeout
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        addStreamHeaders(to: &request, client: client, includeReferer: includeReferer)
        do {
            let (bytes, response) = try await probeSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 206,
                  let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                  contentRange.hasPrefix("bytes 0-") else {
                probeResults[streamUrl] = false
                return false
            }
            // Touch only the first bounded response chunk. `bytes(for:)`
            // avoids buffering a server that ignores the requested range.
            var iterator = bytes.makeAsyncIterator()
            guard (try await iterator.next()) != nil, canContinueAttempt else {
                probeResults[streamUrl] = false
                return false
            }
            let reachable = true
            probeResults[streamUrl] = reachable
            return reachable
        } catch {
            probeResults[streamUrl] = false
            return false
        }
    }

    private var attemptBudgetExceeded: Bool {
        guard let attemptStartedAt else { return false }
        return Date().timeIntervalSince(attemptStartedAt) >= Self.attemptBudget
    }

    private var canContinueAttempt: Bool {
        !Task.isCancelled && !attemptBudgetExceeded
    }

    private func requestTimeout(cap: TimeInterval) -> TimeInterval? {
        guard canContinueAttempt else { return nil }
        guard let attemptStartedAt else { return cap }
        let remaining = Self.attemptBudget - Date().timeIntervalSince(attemptStartedAt)
        guard remaining > 0 else { return nil }
        return min(cap, remaining)
    }

    private func sortHlsCandidates(_ lhs: HlsCandidate, _ rhs: HlsCandidate) -> Bool {
        if lhs.height != rhs.height { return lhs.height > rhs.height }
        if lhs.bandwidth != rhs.bandwidth { return lhs.bandwidth > rhs.bandwidth }
        return lhs.priority < rhs.priority
    }

    private func sortStreamCandidates(_ lhs: StreamCandidate, _ rhs: StreamCandidate) -> Bool {
        let lhsTier = lhs.height >= 1080 ? (lhs.height >= 2160 ? 2160 : (lhs.height >= 1440 ? 1440 : 1080)) : lhs.height
        let rhsTier = rhs.height >= 1080 ? (rhs.height >= 2160 ? 2160 : (rhs.height >= 1440 ? 1440 : 1080)) : rhs.height
        if lhsTier != rhsTier { return lhsTier > rhsTier }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.hasN != rhs.hasN { return !lhs.hasN }
        if containerPreference(lhs.ext) != containerPreference(rhs.ext) {
            return containerPreference(lhs.ext) < containerPreference(rhs.ext)
        }
        return lhs.priority < rhs.priority
    }

    private func videoScore(height: Int, fps: Int, bitrate: Double) -> Double {
        Double(height) * 1_000_000_000 + Double(fps) * 1_000_000 + bitrate
    }

    private func audioScore(bitrate: Double, sampleRate: Double) -> Double {
        bitrate * 1_000_000 + sampleRate
    }

    private func containerPreference(_ ext: String) -> Int {
        switch ext.lowercased() {
        case "mp4", "m4a": return 0
        case "webm": return 1
        default: return 2
        }
    }

    private func parseQualityLabel(_ label: String?) -> Int? {
        guard let label else { return nil }
        return firstCapture(in: label, pattern: #"\b(\d{2,4})p\b"#).flatMap(Int.init)
    }

    private func hasNParam(_ url: String) -> Bool {
        URLComponents(string: url)?.queryItems?.contains { $0.name == "n" && !($0.value ?? "").isEmpty } ?? false
    }

    private func parseHlsAttributeList(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let raw = line[line.index(after: colon)...]
        var output: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuote = false

        for char in raw {
            if inKey {
                if char == "=" {
                    inKey = false
                } else {
                    key.append(char)
                }
                continue
            }

            if char == "\"" {
                inQuote.toggle()
                continue
            }

            if char == "," && !inQuote {
                let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedKey.isEmpty {
                    output[trimmedKey] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                key = ""
                value = ""
                inKey = true
                continue
            }

            value.append(char)
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            output[trimmedKey] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    private func parseResolution(_ raw: String) -> (Int, Int) {
        let parts = raw.split(separator: "x", maxSplits: 1)
        guard parts.count == 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }

    private func mapValue(_ dictionary: [String: Any]?, key: String) -> [String: Any]? {
        dictionary?[key] as? [String: Any]
    }

    private func listMapValue(_ dictionary: [String: Any], key: String) -> [[String: Any]] {
        (dictionary[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private func stringValue(_ dictionary: [String: Any]?, key: String) -> String? {
        guard let value = dictionary?[key] else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func numberValue(_ dictionary: [String: Any], key: String) -> Double? {
        if let number = dictionary[key] as? NSNumber { return number.doubleValue }
        if let string = dictionary[key] as? String { return Double(string) }
        return nil
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    static func isYouTubeVideoId(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { char in
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }
    }
}

enum SmartPlaybackSelector {
    static func bestStream(
        from streams: [NuvioStream],
        qualityPreference: String,
        subtitleLanguages: [String],
        shouldMatchSubtitles: Bool,
        includeDebrid: Bool = false,
        preferredTags: StreamQualityTags? = nil,
        cachedOnly: Bool = false
    ) -> NuvioStream? {
        rankedStreams(
            from: streams,
            qualityPreference: qualityPreference,
            subtitleLanguages: subtitleLanguages,
            shouldMatchSubtitles: shouldMatchSubtitles,
            includeDebrid: includeDebrid,
            preferredTags: preferredTags,
            cachedOnly: cachedOnly
        ).first
    }

    /// Ordered playable candidates: best match first (for resume failover).
    static func rankedStreams(
        from streams: [NuvioStream],
        qualityPreference: String,
        subtitleLanguages: [String],
        shouldMatchSubtitles: Bool,
        includeDebrid: Bool = false,
        preferredTags: StreamQualityTags? = nil,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        let playable = streams.enumerated().compactMap { index, stream -> (index: Int, stream: NuvioStream)? in
            if let url = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                return (index, stream)
            }
            // Torrent-only streams are candidates only when a debrid provider is
            // configured to resolve them into a direct URL.
            if includeDebrid, stream.isDebridResolvable { return (index, stream) }
            return nil
        }
        let compatible = playable.filter { isPlatformPlaybackCompatible($0.stream) }
        var candidates = compatible.filter { !isPromotionalStream($0.stream) }
        if candidates.isEmpty { candidates = compatible }
        let realLinks = candidates.filter { !isPaywallPlaceholderStream($0.stream) }
        if !realLinks.isEmpty { candidates = realLinks }
        if cachedOnly {
            candidates = candidates.filter { $0.stream.isLikelyCached }
        }

        // Strictly exclude ticket / N/A / 0-resolution streams whenever valid >= 720p streams exist.
        let validCandidates = candidates.filter { item in
            let tags = StreamQualityTags.parse(stream: item.stream)
            let res = tags.resolution > 0 ? tags.resolution : inferredResolution(for: item.stream)
            return !isLowQualityOrTicketStream(item.stream) && res >= 720
        }
        let candidatePool = validCandidates.isEmpty ? candidates : validCandidates

        let preferHardware = ProfileSettings.current.object(forKey: SettingsKey.preferHardwareDecodedStreams) as? Bool ?? true

        let ranked = candidatePool.map { index, stream -> (index: Int, stream: NuvioStream, score: Int) in
            let tags = StreamQualityTags.parse(stream: stream)
            let resolution = tags.resolution > 0 ? tags.resolution : inferredResolution(for: stream)
            let subtitleScore = shouldMatchSubtitles ? subtitleScore(in: stream, languages: subtitleLanguages) : 0
            let qualityScore = score(resolution: resolution, preference: qualityPreference)
            let featureScore = featureBoost(tags: tags, preference: qualityPreference)
            let resumeScore = preferredTags.map { tags.matchScore(against: $0) } ?? 0
            let cachedBoost = tags.isCached ? 15_000 : 0
            let lowQualityPenalty: Int = {
                if isLowQualityOrTicketStream(stream) || resolution == 0 {
                    return -300_000
                }
                if resolution < 720 {
                    return -100_000
                }
                return 0
            }()
            let hardwareBoost: Int
            if preferHardware, resolution >= 2160, !AppleTVCapability.current.supportsAV1HardwareDecode {
                if tags.isHardwareAccelerated() {
                    hardwareBoost = 25_000
                } else if tags.isAV1 {
                    hardwareBoost = -25_000
                } else {
                    hardwareBoost = 0
                }
            } else {
                hardwareBoost = 0
            }
            return (index, stream, subtitleScore + qualityScore + featureScore + resumeScore + cachedBoost + lowQualityPenalty + hardwareBoost)
        }

        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }.map(\.stream)
    }

    static func playableStreams(
        from streams: [NuvioStream],
        includeDebrid: Bool = false,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        let playable = streams.filter { stream in
            if let url = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                return true
            }
            return includeDebrid && stream.isDebridResolvable
        }
        let compatible = playable.filter(isPlatformPlaybackCompatible)
        let nonPromotional = compatible.filter { !isPromotionalStream($0) }
        var result = nonPromotional.isEmpty ? compatible : nonPromotional
        // Prefer real links. Only fall back to placeholders when nothing else
        // exists, so the list explains itself instead of going blank.
        let withoutPaywalls = result.filter { !isPaywallPlaceholderStream($0) }
        if !withoutPaywalls.isEmpty { result = withoutPaywalls }
        if cachedOnly {
            result = result.filter(\.isLikelyCached)
        }
        let valid = result.filter { stream in
            let tags = StreamQualityTags.parse(stream: stream)
            let res = tags.resolution > 0 ? tags.resolution : inferredResolution(for: stream)
            return !isLowQualityOrTicketStream(stream) && res >= 720
        }
        return valid.isEmpty ? result : valid
    }

    /// Prefer DV / HDR / Atmos when aiming for highest quality.
    private static func featureBoost(tags: StreamQualityTags, preference: String) -> Int {
        guard preference == "Highest" || preference == "4K" else { return 0 }
        var boost = 0
        if tags.isDolbyVision { boost += 12_000 }
        else if tags.isHDR { boost += 8_000 }
        if tags.isAtmos { boost += 6_000 }
        return boost
    }

    static func matchingSubtitles(in stream: NuvioStream, languages: [String]) -> [NuvioSubtitle] {
        var seen: Set<String> = []
        return languages.flatMap { language in
            stream.subtitles.filter { subtitle in
                SubtitleLanguagePreferences.matches(subtitle.language, target: language) ||
                SubtitleLanguagePreferences.matches(subtitle.label, target: language)
            }
        }
        .filter { subtitle in
            seen.insert(subtitle.url).inserted
        }
    }

    static func isLowQualityOrTicketStream(_ stream: NuvioStream) -> Bool {
        let res = StreamPickerListBuilder.resolution(for: stream)
        // Verified HD/UHD streams (>= 720p) are NEVER low quality or ticket streams,
        // even if add-ons like AIOStreams annotate them with the 🎫 (ticket/debrid) emoji.
        if res >= 720 {
            return false
        }
        let text = metadataSearchText(for: stream)
        if text.contains("🎫") || text.contains("[ticket]") || text.contains("ticket") || text.contains("download ticket") {
            return true
        }
        let nameLower = (stream.name ?? "").lowercased()
        if nameLower.contains("n/a") || text.contains("n/a") {
            return true
        }
        return res == 0
    }

    static func inferredResolution(for stream: NuvioStream) -> Int {
        let text = metadataSearchText(for: stream)
        return StreamQualityTags.resolution(in: text)
    }

    private static func metadataSearchText(for stream: NuvioStream) -> String {
        [stream.name, stream.description, stream.filename]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    static func score(resolution: Int, preference: String) -> Int {
        if resolution == 0 { return -200_000 }
        switch preference {
        case "4K":
            if resolution >= 2160 { return 250_000 + resolution }
            if resolution == 1440 { return 180_000 }
            if resolution == 1080 { return 150_000 }
            if resolution == 720 { return 60_000 }
            return 10_000
        case "1080p":
            if resolution == 1080 { return 250_000 }
            if resolution >= 2160 { return 180_000 }
            if resolution == 1440 { return 160_000 }
            if resolution == 720 { return 60_000 }
            return 10_000
        case "720p":
            if resolution == 720 { return 250_000 }
            if resolution == 1080 { return 150_000 }
            if resolution >= 2160 { return 80_000 }
            return 10_000
        case "Smallest":
            return resolution == 0 ? -100_000 : 200_000 - resolution
        default: // "Highest"
            return resolution >= 2160 ? 300_000 + resolution : resolution * 100
        }
    }

    private static func subtitleScore(in stream: NuvioStream, languages: [String]) -> Int {
        for (index, language) in languages.enumerated() {
            let priorityScore = max(1, 3 - index) * 3_000
            if !matchingSubtitles(in: stream, languages: [language]).isEmpty {
                return priorityScore + 4_000
            }
            if SubtitleLanguagePreferences.matches(searchableText(for: stream), target: language) {
                return priorityScore
            }
        }
        return 0
    }

    /// Paywall placeholders: add-ons advertising premium channels return a dummy
    /// link rather than a stream. Verified against a Premier League fixture —
    /// nine of ten streams pointed at `https://www.google.com` with a lock in
    /// the label, and the single real feed was the *lowest* resolution of the
    /// set. Ranking on quality alone therefore surfaced an unplayable 4K
    /// placeholder and buried the one stream that worked.
    static func isPaywallPlaceholderStream(_ stream: NuvioStream) -> Bool {
        let label = [stream.name, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
        if label.contains("🔒") { return true }
        let lowered = label.lowercased()
        if lowered.contains("upgrade to premium")
            || lowered.contains("upgrade to watch")
            || lowered.contains("upgrade to") {
            return true
        }
        // A placeholder host is never a media origin.
        guard let raw = stream.url,
              let host = URL(string: raw)?.host?.lowercased() else { return false }
        let placeholderHosts = ["google.com", "www.google.com", "example.com", "www.example.com"]
        return placeholderHosts.contains(host)
    }

    private static func isPromotionalStream(_ stream: NuvioStream) -> Bool {
        let text = ([stream.name, stream.description, stream.addonName, stream.url])
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return ["trailer", "teaser", "preview", "promo", "sample", "featurette", "youtube.com", "youtu.be"].contains { text.contains($0) }
    }

    private static func searchableText(for stream: NuvioStream) -> String {
        ([stream.name, stream.description, stream.addonName, stream.filename] +
         stream.subtitles.flatMap { [$0.language, $0.label, $0.url] })
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    /// Codec-relevant fields only (name / description / filename). Subtitle
    /// labels, languages, and URLs are intentionally excluded so AV1 detection
    /// does not scan large subtitle payloads during list derivation.
    static func isAV1LabeledStream(_ stream: NuvioStream) -> Bool {
        for field in [stream.name, stream.description, stream.filename] {
            guard let field, !field.isEmpty else { continue }
            if fieldContainsAV1CodecToken(field) { return true }
        }
        return false
    }

    /// Tokenizes a single field and looks for standalone `av1` / `av01` codec tags.
    private static func fieldContainsAV1CodecToken(_ field: String) -> Bool {
        // Lowercase only this field (not subtitles / joined blob).
        let lower = field.lowercased()
        var tokenStart: String.Index?
        var index = lower.startIndex
        while index <= lower.endIndex {
            let atEnd = index == lower.endIndex
            let isTokenChar = !atEnd && (lower[index].isLetter || lower[index].isNumber)
            if isTokenChar {
                if tokenStart == nil { tokenStart = index }
            } else if let start = tokenStart {
                let token = lower[start..<index]
                if token == "av1" || token == "av01" { return true }
                tokenStart = nil
            }
            if atEnd { break }
            index = lower.index(after: index)
        }
        return false
    }

    private static func isPlatformPlaybackCompatible(_ stream: NuvioStream) -> Bool {
        #if targetEnvironment(simulator)
        // AV1 falls back to software decoding in the tvOS simulator. Its
        // decoded frames then use MoltenVK/libplacebo's PBO upload path, which
        // MTLSimDriver can terminate as XPC API misuse. Prefer another stream;
        // physical Apple TV keeps AV1 available through its real Metal driver.
        if isAV1LabeledStream(stream) { return false }
        #endif
        // Apple TV HD cannot hardware-decode 4K/HDR/Dolby Vision sources.
        return AppleTVCapability.current.isPlayable(
            tags: StreamQualityTags.parse(stream: stream)
        )
    }

}

/// How the stream picker orders results. `.default` keeps the add-ons' own
/// order (usually already best-first); the others re-rank across all sources.
/// Resolution filter for the stream picker. Values are the minimum height the
/// stream must report; `any` disables the filter.
enum StreamResolutionFilter: String, CaseIterable, Identifiable {
    case any = "Any"
    case uhd = "4K"
    case qhd = "2K"
    case fhd = "1080p"
    case hd = "720p"
    case sd = "SD"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return L10n.string("details_res_any", fallback: "Any")
        case .uhd: return "4K"
        case .qhd: return "2K"
        case .fhd: return "1080p"
        case .hd:  return "720p"
        case .sd:  return L10n.string("details_res_sd", fallback: "SD")
        }
    }

    /// True when a stream of this height belongs in the filter. Bands rather
    /// than a floor, so picking 1080p does not also list every 4K release.
    func matches(resolution: Int) -> Bool {
        switch self {
        case .any: return true
        case .uhd: return resolution >= 2160
        case .qhd: return resolution >= 1440 && resolution < 2160
        case .fhd: return resolution >= 1080 && resolution < 1440
        case .hd:  return resolution >= 720 && resolution < 1080
        case .sd:  return resolution > 0 && resolution < 720
        }
    }
}

enum StreamSortOption: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case quality = "Quality"
    case size = "Size"
    case name = "Name"

    var id: String { rawValue }

    init?(rawValueOrSync: String) {
        let upper = rawValueOrSync.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch upper {
        case "DEFAULT":
            self = .default
        case "QUALITY", "QUALITY_DESC":
            self = .quality
        case "SIZE", "SIZE_DESC", "SIZE_ASC":
            self = .size
        case "NAME":
            self = .name
        default:
            if let direct = StreamSortOption(rawValue: rawValueOrSync) {
                self = direct
            } else {
                return nil
            }
        }
    }
}

/// Pure stream-list derivation for the tvOS stream picker. Kept free of view
/// state so focus movement cannot re-filter/sort, and unit tests can assert
/// caching/identity behavior without mounting SwiftUI.
enum StreamPickerListBuilder {
    /// Streams for the current add-on filter, preserving group order when "All".
    static func sourceStreams(
        streams: [NuvioStream],
        groups: [AddonStreamGroup],
        selectedAddonId: String?
    ) -> [NuvioStream] {
        if let selectedAddonId {
            if let group = groups.first(where: { $0.addonId == selectedAddonId }) {
                return deduplicated(group.streams)
            }
            let displayName = groups.first(where: { $0.addonId == selectedAddonId })?.displayName
            return deduplicated(streams.filter { $0.addonName == displayName })
        }
        if !groups.isEmpty {
            return deduplicated(groups.flatMap(\.streams))
        }
        return deduplicated(streams)
    }

    /// Collapses streams that are indistinguishable from one another.
    ///
    /// Live-sports add-ons hand the same entry back more than once — one
    /// fixture returned each of its four channels twice. `NuvioStream.id` is
    /// built from exactly the fields that would tell two streams apart (URL,
    /// label, description, add-on, filename), so a shared id means there is
    /// nothing to choose between them. Leaving them in repeats rows, and puts
    /// repeated ids in the macOS keyboard band, where the first match wins and
    /// Left/Right stick.
    private static func deduplicated(_ streams: [NuvioStream]) -> [NuvioStream] {
        var seen: Set<String> = []
        return streams.filter { seen.insert($0.id).inserted }
    }

    static func playableStreams(
        streams: [NuvioStream],
        groups: [AddonStreamGroup],
        selectedAddonId: String?,
        includeDebrid: Bool,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        let source = sourceStreams(streams: streams, groups: groups, selectedAddonId: selectedAddonId)
        return SmartPlaybackSelector.playableStreams(
            from: source,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
    }

    /// Filter + sort result shown in the picker list.
    static func displayedStreams(
        streams: [NuvioStream],
        groups: [AddonStreamGroup],
        selectedAddonId: String?,
        sortOption: StreamSortOption,
        includeDebrid: Bool,
        cachedOnly: Bool = false,
        resolutionFilter: StreamResolutionFilter = .any
    ) -> [NuvioStream] {
        let playable = playableStreams(
            streams: streams,
            groups: groups,
            selectedAddonId: selectedAddonId,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
        return sorted(filtered(playable, resolution: resolutionFilter), by: sortOption)
    }

    /// Constant-size cache key. Repository revision captures every publication,
    /// including metadata/subtitle changes with unchanged stream ids and counts.
    static func cacheKey(
        revision: UInt64,
        selectedAddonId: String?,
        sortOption: StreamSortOption,
        includeDebrid: Bool,
        cachedOnly: Bool = false,
        resolutionFilter: StreamResolutionFilter = .any
    ) -> StreamPickerListCacheKey {
        StreamPickerListCacheKey(
            resolutionFilter: resolutionFilter,
            revision: revision,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly
        )
    }

    /// Re-orders streams for the chosen sort matching Android TV's `DirectDebridStreamFilter.compareFacts`.
    /// `.default` preserves the add-on's own order for valid streams while sinking unknown/0-res items.
    /// `.quality` (Android's QUALITY_DESC) orders:
    ///   1. Resolution DESC (2160 > 1440 > 1080 > 720 > 576 > 480 > 360 > 0)
    ///   2. Release Quality DESC (Remux > BluRay > Web-DL > WebRip > HDRip > HD-Rip > DVDRip > HDTV > Cam/TS/TC/SCR > UNKNOWN)
    ///   3. Size bytes DESC
    ///   4. Apple TV hardware acceleration (AV1 check for 4K)
    ///   5. Stable original offset
    static func sorted(_ streams: [NuvioStream], by option: StreamSortOption) -> [NuvioStream] {
        switch option {
        case .default:
            return streams.enumerated().sorted {
                let bad0 = SmartPlaybackSelector.isLowQualityOrTicketStream($0.element) || resolution(for: $0.element) == 0
                let bad1 = SmartPlaybackSelector.isLowQualityOrTicketStream($1.element) || resolution(for: $1.element) == 0
                if bad0 != bad1 {
                    return !bad0 && bad1
                }
                return $0.offset < $1.offset
            }.map(\.element)
        case .quality:
            return streams.enumerated().sorted {
                let res0 = resolution(for: $0.element)
                let res1 = resolution(for: $1.element)
                let bad0 = SmartPlaybackSelector.isLowQualityOrTicketStream($0.element) || res0 == 0
                let bad1 = SmartPlaybackSelector.isLowQualityOrTicketStream($1.element) || res1 == 0
                if bad0 != bad1 {
                    return !bad0 && bad1
                }
                // Tier 1: Resolution DESC (Android DebridStreamSortKey.RESOLUTION)
                if res0 != res1 {
                    return res0 > res1
                }
                // Tier 2: Release Quality DESC (Android DebridStreamSortKey.QUALITY)
                let q0 = streamQuality(for: $0.element)
                let q1 = streamQuality(for: $1.element)
                if q0 != q1 {
                    return q0 > q1
                }
                // Tier 3: Size bytes DESC (Android DebridStreamSortKey.SIZE)
                let s0 = sizeBytes(for: $0.element)
                let s1 = sizeBytes(for: $1.element)
                if s0 != s1 {
                    return s0 > s1
                }
                // Tier 4: Hardware decode capability check (Apple TV AV1 decode at 4K)
                if res0 >= 2160, !AppleTVCapability.current.supportsAV1HardwareDecode {
                    let hw0 = StreamQualityTags.parse(stream: $0.element).isHardwareAccelerated()
                    let hw1 = StreamQualityTags.parse(stream: $1.element).isHardwareAccelerated()
                    if hw0 != hw1 {
                        return hw0 && !hw1
                    }
                }
                // Tier 5: Preserved original offset
                return $0.offset < $1.offset
            }.map(\.element)
        case .size:
            return streams.enumerated().sorted {
                let res0 = resolution(for: $0.element)
                let res1 = resolution(for: $1.element)
                let bad0 = SmartPlaybackSelector.isLowQualityOrTicketStream($0.element) || res0 == 0
                let bad1 = SmartPlaybackSelector.isLowQualityOrTicketStream($1.element) || res1 == 0
                if bad0 != bad1 {
                    return !bad0 && bad1
                }
                let s0 = sizeBytes(for: $0.element)
                let s1 = sizeBytes(for: $1.element)
                if s0 != s1 {
                    return s0 > s1
                }
                return $0.offset < $1.offset
            }.map(\.element)
        case .name:
            return streams.enumerated().sorted {
                let res0 = resolution(for: $0.element)
                let res1 = resolution(for: $1.element)
                let bad0 = SmartPlaybackSelector.isLowQualityOrTicketStream($0.element) || res0 == 0
                let bad1 = SmartPlaybackSelector.isLowQualityOrTicketStream($1.element) || res1 == 0
                if bad0 != bad1 {
                    return !bad0 && bad1
                }
                let c = ($0.element.name ?? "").localizedCaseInsensitiveCompare($1.element.name ?? "")
                if c != .orderedSame {
                    return c == .orderedAscending
                }
                return $0.offset < $1.offset
            }.map(\.element)
        }
    }

    /// Best-effort resolution parsed from a stream's release metadata (2160/1440/1080/720/576/480/360),
    /// 0 when unknown so untagged streams sink to the bottom of a Quality sort.
    static func resolution(for stream: NuvioStream) -> Int {
        let tags = StreamQualityTags.parse(stream: stream)
        if tags.resolution > 0 { return tags.resolution }
        return SmartPlaybackSelector.inferredResolution(for: stream)
    }

    /// Release year scraped from the stream's own text, or nil when nothing in
    /// it looks like a year.
    ///
    /// Best-effort by nature: release names are full of numbers that are not
    /// years. Only 19xx/20xx inside token boundaries count, resolutions and
    /// sizes are excluded, and anything past next year is discarded. Shown as a
    /// badge rather than used for filtering or sorting, so a wrong guess costs
    /// the viewer nothing.
    static func releaseYear(for stream: NuvioStream) -> Int? {
        let text = "\(stream.name ?? "") \(stream.description ?? "") \(stream.filename ?? "")"
        let pattern = #"(?:^|[^0-9a-zA-Z])((?:19|20)[0-9]{2})(?:[^0-9a-zA-Z]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let maxYear = Calendar.current.component(.year, from: Date()) + 1
        var found: Int?
        regex.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let match, let r = Range(match.range(at: 1), in: text),
                  let value = Int(text[r]), value <= maxYear else { return }
            // The first plausible year wins: release names lead with the title
            // and its year, and trail with encoder tags that can contain others.
            found = value
            stop.pointee = true
        }
        return found
    }

    /// Applies the resolution band, keeping unknown-resolution streams only
    /// when no filter is set — they cannot be placed in a band honestly.
    static func filtered(
        _ streams: [NuvioStream],
        resolution filter: StreamResolutionFilter
    ) -> [NuvioStream] {
        guard filter != .any else { return streams }
        return streams.filter { filter.matches(resolution: resolution(for: $0)) }
    }

    /// Release quality tier matching Android TV's `DebridStreamQuality`.
    static func streamQuality(for stream: NuvioStream) -> DebridStreamQuality {
        let text = "\(stream.name ?? "") \(stream.description ?? "") \(stream.filename ?? "")"
        return StreamQualityTags.quality(in: text)
    }

    /// Best-effort file size in bytes matching Android TV's `StreamTextSizeParser`:
    /// structured videoSize field first, then free-text parsing as last resort.
    static func sizeBytes(for stream: NuvioStream) -> Int64 {
        if let videoSize = stream.videoSize, videoSize > 0 {
            return videoSize
        }
        let text = "\(stream.description ?? "") \(stream.name ?? "")"
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|KB)\b"#
        guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return 0
        }
        let token = String(text[match])
        let number = token.replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .first { Double($0) != nil }
            .flatMap(Double.init) ?? 0
        let unit = token.uppercased()
        let multiplier: Double
        if unit.contains("TB") { multiplier = 1_099_511_627_776 }
        else if unit.contains("GB") { multiplier = 1_073_741_824 }
        else if unit.contains("MB") { multiplier = 1_048_576 }
        else { multiplier = 1024 }
        return Int64(number * multiplier)
    }
}

/// Small Equatable key used by the picker cache. It deliberately contains no
/// stream URLs, descriptions, or subtitle payloads, so focus changes are O(1).
#if os(macOS)
/// Memo box for the details rail's stream list. A reference type so a computed
/// property can fill it during a body pass without publishing state into the
/// update it is part of.
final class MacStreamListCache {
    var key: StreamPickerListCacheKey?
    var streams: [NuvioStream] = []
}
#endif

struct StreamPickerListCacheKey: Equatable {
    /// Part of the key: changing the filter must rebuild the list.
    var resolutionFilter: StreamResolutionFilter = .any
    let revision: UInt64
    let selectedAddonId: String?
    let sortOption: StreamSortOption
    let includeDebrid: Bool
    var cachedOnly: Bool = false
}

private enum TvDetailsFocusSection: Hashable {
    case actions
    case episodes
    case cast
    case related
    case network
    case production
    case comments
}

struct TvDetailsContent: View {
    let uiState: DetailsUiState
    let onPlayClick: () -> Void
    var onPlayManually: (() -> Void)? = nil
    let onEpisodeSelected: (NuvioVideo) -> Void
    var onEpisodePlayManually: ((NuvioVideo) -> Void)? = nil
    var onEpisodeMenuPresented: ((Bool) -> Void)? = nil
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    let onShareClick: () -> Void
    let onTrailerClick: () -> Void
    var onOpenTitle: ((String, String) -> Void)? = nil
    var onOpenProduction: ((MetaCompany) -> Void)? = nil
    var onOpenPerson: ((TmdbPersonMetadata) -> Void)? = nil
    var onCommentSelect: ((TraktCommentReview) -> Void)? = nil
    let onBack: () -> Void

    @FocusState private var actionFocus: DetailsActionFocus?
    @FocusState private var castHeaderFocus: DetailsCastHeaderFocus?
    /// Which episode control holds focus, as `TvEpisodeFocus` keys. Owned here
    /// rather than per card so focus can be put back on a specific episode.
    @FocusState private var episodeFocus: String?
    /// The section that currently owns focus. Other sections expose only their
    /// remembered entry anchor, matching Settings' pre-spatial focus lock.
    /// macOS shows streams in the rail rather than on a separate screen, so the
    /// details page needs the picker's data and its selection callback.
    var isStreamsPresented: Binding<Bool>? = nil
    var onSelectStream: ((NuvioStream, ExternalPlayer?) -> Void)? = nil
    var streamsSubtitle: String? = nil
    var includeDebrid: Bool = false

    @State private var focusedDetailsSection: TvDetailsFocusSection = .actions
    #if os(macOS)
    /// macOS drives its own focus; see `MacDetailsFocus`.
    @ObservedObject private var macFocus = MacDetailsFocus.shared
    /// The rail's own state. The season lives here because the rail owns the
    /// episode list on macOS; the tvOS episode strip is not rendered at all.
    @State private var macRailSeason: Int?
    /// The rail stays closed until Play opens it, so a series lands on the same
    /// uncluttered page a movie does.
    @State private var macRailOpen = false
    @State private var macRailOptions: MacPickerOptionList?
    @State private var macRailOptionIndex = 0
    @AppStorage(SettingsKey.streamSortOption) private var macSortOption: StreamSortOption = .quality
    @AppStorage(SettingsKey.streamResolutionFilter) private var macResolutionFilter: StreamResolutionFilter = .any
    @AppStorage(SettingsKey.cachedOnlyStreams) private var macCachedOnly = false
    @State private var macSelectedAddonId: String?
    /// The scroll proxy lives inside the reader, but the key handler has to sit
    /// on an ancestor of every control to receive the arrows at all.
    @State private var macScrollProxy: ScrollViewProxy?
    /// Memo for `macDisplayedStreams`. See the note there on why it is a
    /// reference type rather than `@State`.
    @State private var macStreamsCache = MacStreamListCache()
    @ObservedObject private var keyRouter = MacKeyRouter.shared
    /// This page's place in the router's stack.
    @State private var macKeyToken: UUID?
    #endif
    @State private var detailsFocusMoveGeneration = 0
    @State private var pendingPlayFocusGeneration: Int?
    /// Episode control to re-focus once the stream picker closes, captured when
    /// this content gets disabled. Same approach Home uses for the card you
    /// left when entering Details — see `restoreEpisodeFocus`.
    @State private var restoreEpisodeKey: String?
    @State private var restoreGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false
    /// Bumped whenever a watched mark or a progress write lands. Resume progress
    /// is read straight from the stores below rather than from `uiState`, so
    /// without this the episode strip keeps drawing the bar it rendered with —
    /// marking an episode watched cleared the stores but nothing re-read them.
    @State private var progressRevision = 0
    @State private var scrollOffset: CGFloat = 0

    private var isScrolledDown: Bool {
        focusedDetailsSection != .actions || episodeFocus != nil || castHeaderFocus != nil || scrollOffset > 30
    }

    private var backdropBlurRadius: CGFloat {
        isScrolledDown ? 22 : 0
    }

    var body: some View {
        if let meta = uiState.meta {
            let episodes = sortedEpisodes(meta)
            let continueItem = currentContinueWatchingItem(for: meta, revision: progressRevision)
            let playTarget = playTarget(for: meta, episodes: episodes, continueItem: continueItem)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    TvDetailsBackdrop(meta: meta, blurRadius: backdropBlurRadius)

                    TvDetailsScrolledBackdropDimmer(isScrolledDown: isScrolledDown)

                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            GeometryReader { geometry in
                                Color.clear
                                    .preference(
                                        key: TvDetailsScrollOffsetKey.self,
                                        value: geometry.frame(in: .named("tv-details-scroll")).minY
                                    )
                            }
                            .frame(height: 0)
                            .id(TvDetailsScrollID.topSection)

                            VStack(alignment: .leading, spacing: 34) {
                                TvDetailsLogo(meta: meta)
                                    .padding(.bottom, 10)

                                TvDetailsActionRow(
                                    isInWatchlist: uiState.isInWatchlist,
                                    isWatched: uiState.isWatched,
                                    playTitle: playTarget.label,
                                    playHint: smartStreamSelection
                                        ? L10n.string("details_play_hint_smart", fallback: "Plays the best link. Hold Select to choose a source manually.")
                                        : L10n.string("details_play_hint", fallback: "Starts playback or opens stream sources"),
                                    onPlayClick: {
                                        guard playTarget.isPlayable else { return }
                                        // Series: play the resume/next-up episode; movies
                                        // fall through to the stream picker.
                                        if let episode = playTarget.episode {
                                            onEpisodeSelected(episode)
                                        } else {
                                            onPlayClick()
                                        }
                                    },
                                    onPlayLongPress: smartStreamSelection ? {
                                        guard playTarget.isPlayable else { return }
                                        if let episode = playTarget.episode {
                                            if let onEpisodePlayManually {
                                                onEpisodePlayManually(episode)
                                            } else {
                                                onEpisodeSelected(episode)
                                            }
                                        } else if let onPlayManually {
                                            onPlayManually()
                                        } else {
                                            onPlayClick()
                                        }
                                    } : nil,
                                    onWatchlistClick: onWatchlistClick,
                                    onWatchedClick: onWatchedClick,
                                    onTrailerClick: onTrailerClick,
                                    focus: $actionFocus,
                                    entryLocked: focusedDetailsSection != .actions,
                                    playEntryLocked: focusedDetailsSection == .episodes,
                                    onFocus: {
                                        guard focusedDetailsSection != .actions else { return }
                                        focusedDetailsSection = .actions
                                        withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                            scrollProxy.scrollTo(TvDetailsScrollID.topSection, anchor: .top)
                                        }
                                    }
                                )
                                .padding(.bottom, 6)
                                // Unfocusable while an episode is being restored
                                // to, so the engine can't claim these instead.
                                .disabled(
                                    restoreEpisodeKey != nil
                                        || !isDetailsFocusReachable(.actions)
                                    )

                                TvDetailsSummary(meta: meta, simkl: uiState.simklRatings)

                                #if !os(macOS)
                                // macOS lists episodes in the rail beside this
                                // column instead, so both are on one page.
                                if !episodes.isEmpty {
                                    TvDetailsEpisodes(
                                        meta: meta,
                                        episodes: episodes,
                                        seriesRating: meta.rating,
                                        continueItem: continueItem,
                                        onFocus: {
                                            cancelPendingFocusHandoff()
                                            guard focusedDetailsSection != .episodes else { return }
                                            focusedDetailsSection = .episodes
                                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.episodesSection, anchor: .top)
                                            }
                                        },
                                        onSelect: onEpisodeSelected,
                                        onPlayManually: onEpisodePlayManually,
                                        onEpisodeMenuPresented: { onEpisodeMenuPresented?($0) },
                                        episodeFocus: $episodeFocus,
                                        restrictFocusToKey: restoreEpisodeKey,
                                        entryLocked: focusedDetailsSection != .episodes,
                                        onMoveUpFromSeason: {
                                            focusPlayFromEpisodes(using: scrollProxy)
                                        },
                                        onMoveDownFromEpisode: focusCastHeaderFromEpisodes
                                    )
                                    .padding(.top, 24)
                                    .id(TvDetailsScrollID.episodesSection)
                                    .disabled(!isDetailsFocusReachable(.episodes))
                                }
                                #endif

                                TvDetailsCastAndTrailer(
                                    meta: meta,
                                    people: uiState.people,
                                    onPersonClick: { person in
                                        onOpenPerson?(person)
                                    },
                                    onTrailerClick: onTrailerClick,
                                    headerFocus: $castHeaderFocus,
                                    entryLocked: focusedDetailsSection != .cast,
                                    onFocus: {
                                        guard focusedDetailsSection != .cast else { return }
                                        focusedDetailsSection = .cast
                                        withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                            scrollProxy.scrollTo(TvDetailsScrollID.castSection, anchor: .top)
                                        }
                                    }
                                )
                                .padding(.top, 34)
                                .id(TvDetailsScrollID.castSection)
                                .disabled(
                                    restoreEpisodeKey != nil
                                        || !isDetailsFocusReachable(.cast)
                                )

                                if !uiState.moreLikeThis.isEmpty {
                                    TvDetailsRelatedRow(
                                        title: L10n.string("settings_tmdb_module_more_like_this", fallback: "More Like This"),
                                        items: uiState.moreLikeThis,
                                        entryLocked: focusedDetailsSection != .related,
                                        macFocusedIndex: macFocusedIndex(in: .related),
                                        onSelect: { item in
                                            onOpenTitle?(item.id, item.type)
                                        },
                                        onFocus: {
                                            guard focusedDetailsSection != .related else { return }
                                            focusedDetailsSection = .related
                                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.moreLikeThisSection, anchor: .top)
                                            }
                                        }
                                    )
                                    .padding(.top, 40)
                                    .id(TvDetailsScrollID.moreLikeThisSection)
                                    .disabled(
                                        restoreEpisodeKey != nil
                                            || !isDetailsFocusReachable(.related)
                                    )
                                }

                                let productionCompanies = uiState.companies.filter { $0.kind == .production }
                                let networks = uiState.companies.filter { $0.kind == .network }

                                if !networks.isEmpty {
                                    TvDetailsProductionRow(
                                        title: L10n.string("details_network", fallback: "Network"),
                                        companies: networks,
                                        entryLocked: focusedDetailsSection != .network,
                                        macRow: .network,
                                        onSelect: { company in
                                            onOpenProduction?(company)
                                        },
                                        onFocus: {
                                            guard focusedDetailsSection != .network else { return }
                                            focusedDetailsSection = .network
                                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.networkSection, anchor: .top)
                                            }
                                        }
                                    )
                                    .padding(.top, 40)
                                    .id(TvDetailsScrollID.networkSection)
                                    .disabled(
                                        restoreEpisodeKey != nil
                                            || !isDetailsFocusReachable(.network)
                                    )
                                }

                                if !productionCompanies.isEmpty {
                                    TvDetailsProductionRow(
                                        title: L10n.string("details_production", fallback: "Production"),
                                        companies: productionCompanies,
                                        entryLocked: focusedDetailsSection != .production,
                                        macRow: .production,
                                        onSelect: { company in
                                            onOpenProduction?(company)
                                        },
                                        onFocus: {
                                            guard focusedDetailsSection != .production else { return }
                                            focusedDetailsSection = .production
                                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.productionSection, anchor: .top)
                                            }
                                        }
                                    )
                                    .padding(.top, 40)
                                    .id(TvDetailsScrollID.productionSection)
                                    .disabled(
                                        restoreEpisodeKey != nil
                                            || !isDetailsFocusReachable(.production)
                                    )
                                }

                                if !uiState.comments.isEmpty {
                                    TvDetailsCommentsRow(
                                        comments: uiState.comments,
                                        entryLocked: focusedDetailsSection != .comments,
                                        onSelect: { comment in
                                            onCommentSelect?(comment)
                                        },
                                        onFocus: {
                                            guard focusedDetailsSection != .comments else { return }
                                            focusedDetailsSection = .comments
                                            withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                                                scrollProxy.scrollTo(TvDetailsScrollID.commentsSection, anchor: .top)
                                            }
                                        }
                                    )
                                    .padding(.top, 40)
                                    .id(TvDetailsScrollID.commentsSection)
                                    .disabled(
                                        restoreEpisodeKey != nil
                                            || !isDetailsFocusReachable(.comments)
                                    )
                                }
                            }
                            // Match Home's TV row inset so details content
                            // lines up with the catalog cards.
                            .padding(.leading, 48)
                            .padding(.top, 78)
                            .padding(.bottom, 96)
                            .frame(width: detailsWidth(proxy, hasEpisodes: !episodes.isEmpty), alignment: .leading)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                        }
                        .scrollClipDisabledIfAvailable()
                        .coordinateSpace(name: "tv-details-scroll")
                        #if os(macOS)
                        .onAppear { macScrollProxy = scrollProxy }
                        #endif
                    }
                }
                .onPreferenceChange(TvDetailsScrollOffsetKey.self) { minY in
                    let newOffset = max(0, -minY)
                    if abs(newOffset - scrollOffset) > 2 {
                        scrollOffset = newOffset
                    }
                }
            }
            #if os(macOS)
            .overlay(alignment: .trailing) { macRail() }
            .overlay {
                if let list = macRailOptions {
                    MacPickerOptionsPanel(list: list, highlighted: macRailOptionIndex) { index in
                        guard list.options.indices.contains(index) else { return }
                        list.options[index].apply()
                        macRailOptions = nil
                    } onDismiss: {
                        macRailOptions = nil
                    }
                    .transition(.opacity)
                }
            }
            #endif
            .background(Color.black.ignoresSafeArea())
            .onExitCommand(perform: onBack)
            #if os(macOS)
            // Keys come from `MacKeyRouter`: this page is an overlay above a
            // still-mounted Home, and nothing here holds SwiftUI focus, so
            // `onMoveCommand` never fired for it.
            .onAppear {
                keyRouter.release(macKeyToken)
                macKeyToken = keyRouter.claim()
            }
            .onDisappear {
                keyRouter.release(macKeyToken)
                macKeyToken = nil
            }
            .onChange(of: keyRouter.latest) { _, press in
                guard let press, keyRouter.isFront(macKeyToken) else { return }
                handleMacKey(press.key)
            }
            .onChange(of: macFocus.row) { _, row in
                guard let anchor = macScrollAnchor(for: row) else { return }
                withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
                    macScrollProxy?.scrollTo(anchor, anchor: .top)
                }
            }
            // The rail's lengths move under the caret: streams arrive
            // progressively, a filter narrows the list, a season swaps it.
            .onChange(of: uiState.streamsRevision) { _, _ in macPublishRailCounts() }
            .onChange(of: uiState.streams.count) { _, _ in macPublishRailCounts() }
            .onChange(of: macRailSeason) { _, _ in macPublishRailCounts() }
            .onChange(of: macSelectedAddonId) { _, _ in macPublishRailCounts() }
            .onChange(of: macResolutionFilter) { _, _ in macPublishRailCounts() }
            .onChange(of: macSortOption) { _, _ in macPublishRailCounts() }
            .onChange(of: macCachedOnly) { _, _ in macPublishRailCounts() }
            .onChange(of: isStreamsPresented?.wrappedValue ?? false) { _, showingStreams in
                macPublishRailCounts()
                // Opening the streams should put the caret on them; closing
                // them hands it back to the episode list it came from.
                macFocus.focusRail()
                MacDiagnostics.log("rail.mode \(showingStreams ? "streams" : "episodes")")
            }
            #endif
            // tvOS doesn't re-run default-focus when this content swaps in after
            // the async load finishes, so focus lands nowhere / off the Play
            // button. Move it onto Play explicitly once the content appears
            // (async so it runs after the focus engine's own first pass).
            .onAppear {
                focusedDetailsSection = .actions
                DispatchQueue.main.async { actionFocus = .play }
                #if os(macOS)
                macFocus.begin(page: uiState.meta?.id ?? "")
                macFocus.setCount(MacDetailsActionSlot.allCases.count, for: .actions)
                macFocus.register(.actions) { index in
                    switch MacDetailsActionSlot(rawValue: index) {
                    case .play: macHandlePlay()
                    case .watchlist: onWatchlistClick()
                    case .watched: onWatchedClick()
                    case .trailer: onTrailerClick()
                    case nil: break
                    }
                }
                macRailOpen = false
                macFocus.register(.railHeader, activate: macActivateRailHeader)
                macFocus.register(.railList, activate: macActivateRailRow)
                macPublishRailCounts()
                #endif
            }
            // Opening the stream picker disables this content, and on the way
            // back tvOS re-places focus geometrically — which is how leaving an
            // episode's picker landed you on the season pills. Capture the
            // episode on the way out, and while that capture stands every other
            // control here is unfocusable, so the engine can only put focus back
            // where it was.
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    restoreGeneration &+= 1
                    restoreEpisodeKey = episodeFocus
                } else if let target = restoreEpisodeKey {
                    restoreEpisodeFocus(to: target, generation: restoreGeneration)
                }
            }
            #if os(macOS)
            .onChange(of: uiState.moreLikeThis.count, initial: true) { _, count in
                macFocus.begin(page: uiState.meta?.id ?? "")
                macFocus.setCount(count, for: .related)
                macFocus.register(.related) { index in
                    guard uiState.moreLikeThis.indices.contains(index) else { return }
                    let item = uiState.moreLikeThis[index]
                    onOpenTitle?(item.id, item.type)
                }
            }
            // Cast and the company rows sit below More Like This and were
            // absent from the keyboard model entirely, so Down stopped at the
            // related row and the bottom of the page was unreachable.
            .onChange(of: uiState.companies.count, initial: true) { _, _ in
                macFocus.begin(page: uiState.meta?.id ?? "")
                let networks = uiState.companies.filter { $0.kind == .network }
                let production = uiState.companies.filter { $0.kind == .production }
                macFocus.setCount(networks.count, for: .network)
                macFocus.setCount(production.count, for: .production)
                macFocus.register(.network) { index in
                    guard networks.indices.contains(index) else { return }
                    onOpenProduction?(networks[index])
                }
                macFocus.register(.production) { index in
                    guard production.indices.contains(index) else { return }
                    onOpenProduction?(production[index])
                }
            }
            #endif
            .onChange(of: episodeFocus) { _, newValue in
                // Restoration landed — lift the restriction.
                if let newValue, newValue == restoreEpisodeKey {
                    restoreEpisodeKey = nil
                }
            }
            // Marking an episode watched clears its progress across three
            // stores, and the remote provider's optimistic layer is cleared one
            // hop later — so every one of them has to be able to invalidate this
            // view, not just the mark itself.
            .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
                progressRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification)) { _ in
                progressRevision &+= 1
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: TraktSettingsStore.continueWatchingChangedNotification
                )
            ) { _ in
                progressRevision &+= 1
            }
        } else {
            EmptyView()
        }
    }

    /// Nudges focus back onto the captured episode control. The writes are
    /// delayed because the cards are unfocusable for a few frames while the
    /// picker fades, and the 1s clear is a safety net for a target that is gone
    /// (the season was switched, say) so the strip can't stay unfocusable.
    private func restoreEpisodeFocus(to target: String, generation: Int) {
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if restoreGeneration == generation, restoreEpisodeKey == target {
                    episodeFocus = target
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if restoreGeneration == generation, restoreEpisodeKey == target {
                restoreEpisodeKey = nil
            }
        }
    }

    /// Cancel a scroll-first handoff when a newly focused episode control
    /// indicates that the user changed direction.
    private func cancelPendingFocusHandoff() {
        guard pendingPlayFocusGeneration != nil else { return }
        pendingPlayFocusGeneration = nil
        detailsFocusMoveGeneration &+= 1
    }

    /// Route the season strip back to the primary action explicitly. tvOS has
    /// no spatial candidate above later season pills because Play sits at the
    /// far-left edge, so geometry alone can leave focus stuck on Season 2/3.
    private func focusPlayFromEpisodes(using scrollProxy: ScrollViewProxy) {
        detailsFocusMoveGeneration &+= 1
        let generation = detailsFocusMoveGeneration
        pendingPlayFocusGeneration = generation
        // Keep the episode section active until the scroll has finished. This
        // prevents tvOS from disabling the focused card and choosing an early
        // spatial replacement while the top section is moving into place.
        withAnimation(.easeOut(duration: TvDetailsScrollTiming.duration)) {
            scrollProxy.scrollTo(TvDetailsScrollID.topSection, anchor: .top)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + TvDetailsScrollTiming.focusHandoffDelay) {
            guard detailsFocusMoveGeneration == generation,
                  pendingPlayFocusGeneration == generation else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pendingPlayFocusGeneration = nil
                focusedDetailsSection = .actions
                actionFocus = .play
            }

            // tvOS may reassert its spatial choice on the next run-loop turn.
            DispatchQueue.main.async {
                guard detailsFocusMoveGeneration == generation else { return }
                if actionFocus != .play {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        actionFocus = .play
                    }
                }
            }
        }
    }

    /// Episodes enter the next section through its heading, matching the
    /// Settings-style focus graph instead of jumping over it to a person card.
    private func focusCastHeaderFromEpisodes() {
        detailsFocusMoveGeneration &+= 1
        let generation = detailsFocusMoveGeneration
        pendingPlayFocusGeneration = nil
        castHeaderFocus = .creatorAndCast

        DispatchQueue.main.async {
            guard detailsFocusMoveGeneration == generation else { return }
            castHeaderFocus = .creatorAndCast
        }
    }

    /// Settings has one destination pane; Details has a vertical chain of
    /// sections. Keep only the current section and its immediate neighbors in
    /// the focus graph so tvOS cannot skip Cast and land two rows away.
    private var detailsFocusOrder: [TvDetailsFocusSection] {
        var order: [TvDetailsFocusSection] = [.actions]
        if let meta = uiState.meta, !(meta.videos ?? []).isEmpty {
            order.append(.episodes)
        }
        order.append(.cast)
        if !uiState.moreLikeThis.isEmpty { order.append(.related) }
        if uiState.companies.contains(where: { $0.kind == .network }) {
            order.append(.network)
        }
        if uiState.companies.contains(where: { $0.kind == .production }) {
            order.append(.production)
        }
        if !uiState.comments.isEmpty { order.append(.comments) }
        return order
    }

    /// The caret's position within a row, or nil when it is elsewhere — and
    /// always nil off macOS, where the focus engine does this itself.
    private func macFocusedIndex(in row: MacDetailsRow) -> Int? {
        #if os(macOS)
        return macFocus.row == row ? macFocus.index : nil
        #else
        return nil
        #endif
    }

    #if os(macOS)
    // MARK: - Rail

    private var macRailMode: MacRailMode {
        (isStreamsPresented?.wrappedValue ?? false) ? .streams : .episodes
    }

    private var macSeasons: [Int] {
        guard let meta = uiState.meta else { return [] }
        return Array(Set(sortedEpisodes(meta).map(\.season))).sorted {
            (seasonSortKey($0), $0) < (seasonSortKey($1), $1)
        }
    }

    /// The season showing in the rail. Defaults to where the viewer left off.
    private var macActiveSeason: Int {
        if let macRailSeason, macSeasons.contains(macRailSeason) { return macRailSeason }
        guard let meta = uiState.meta else { return 1 }
        let episodes = sortedEpisodes(meta)
        let continueItem = currentContinueWatchingItem(for: meta, revision: progressRevision)
        let target = playTarget(for: meta, episodes: episodes, continueItem: continueItem)
        return target.episode?.season ?? macSeasons.first ?? 1
    }

    private var macSeasonEpisodes: [NuvioVideo] {
        guard let meta = uiState.meta else { return [] }
        return sortedEpisodes(meta)
            .filter { $0.season == macActiveSeason }
            .sorted { $0.episode < $1.episode }
    }

    /// Inputs that can change the visible list — not the caret.
    private var macStreamsCacheKey: StreamPickerListCacheKey {
        StreamPickerListBuilder.cacheKey(
            revision: uiState.streamsRevision,
            selectedAddonId: macSelectedAddonId,
            sortOption: macSortOption,
            includeDebrid: includeDebrid,
            cachedOnly: macCachedOnly,
            resolutionFilter: macResolutionFilter
        )
    }

    /// The rail's streams, memoised.
    ///
    /// This was a plain computed property, so the whole pipeline — five
    /// filters, a regex-heavy tag parse per stream, then a sort — re-ran on
    /// every SwiftUI body pass, and the rail redraws on every caret move. With
    /// eighty streams that is what made walking the list crawl. The tvOS picker
    /// has always cached it against exactly this key for the same reason.
    private var macDisplayedStreams: [NuvioStream] {
        if macStreamsCache.key == macStreamsCacheKey { return macStreamsCache.streams }
        let streams = StreamPickerListBuilder.displayedStreams(
            streams: uiState.streams,
            groups: uiState.streamGroups,
            selectedAddonId: macSelectedAddonId,
            sortOption: macSortOption,
            includeDebrid: includeDebrid,
            cachedOnly: macCachedOnly,
            resolutionFilter: macResolutionFilter
        )
        // A class, not `@State`: reading a computed property during a body pass
        // cannot publish state without re-entering the update it is part of.
        macStreamsCache.key = macStreamsCacheKey
        macStreamsCache.streams = streams
        return streams
    }

    /// Add-ons that actually returned something, so the filter never offers a
    /// provider with nothing behind it.
    private var macProviderGroups: [AddonStreamGroup] {
        uiState.streamGroups.filter { !$0.streams.isEmpty || $0.isLoading }
    }

    /// Header controls paired with what they do.
    ///
    /// Built together deliberately: the previous version mapped a caret index
    /// onto a `switch` in a second function, and a conditional control makes
    /// those two drift.
    private var macRailHeaderEntries: [MacRailHeaderEntry] {
        switch macRailMode {
        case .episodes:
            var entries = [MacRailHeaderEntry(
                item: MacRailHeaderItem(symbol: "chevron.left"),
                action: macCloseRail
            )]
            guard macSeasons.count > 1 else { return entries }
            entries += macSeasons.map { season in
                MacRailHeaderEntry(
                    item: MacRailHeaderItem(
                        label: macSeasonTitle(season),
                        isActive: season == macActiveSeason
                    ),
                    action: {
                        macRailSeason = season
                        macPublishRailCounts()
                    }
                )
            }
            return entries

        case .streams:
            var entries = [MacRailHeaderEntry(
                item: MacRailHeaderItem(symbol: "chevron.left"),
                action: {
                    // Back to the episode list on a series; off the page
                    // entirely on a movie, which has no list to return to.
                    if macHasEpisodes {
                        isStreamsPresented?.wrappedValue = false
                    } else {
                        macCloseRail()
                    }
                }
            )]
            entries.append(MacRailHeaderEntry(
                item: MacRailHeaderItem(
                    label: L10n.format(
                        "details_provider_format",
                        fallback: "Provider: %@",
                        macSelectedAddonId.flatMap { id in
                            macProviderGroups.first { $0.addonId == id }?.displayName
                        } ?? L10n.string("action_all", fallback: "All")
                    ),
                    isActive: macSelectedAddonId != nil
                ),
                action: { macOpenRailOptions(macProviderOptionList()) }
            ))
            entries.append(MacRailHeaderEntry(
                item: MacRailHeaderItem(
                    label: L10n.format("details_resolution_format", fallback: "Res: %@", macResolutionFilter.title),
                    isActive: macResolutionFilter != .any
                ),
                action: { macOpenRailOptions(macResolutionOptionList()) }
            ))
            entries.append(MacRailHeaderEntry(
                item: MacRailHeaderItem(
                    label: L10n.format("details_sort_format", fallback: "Sort: %@", L10n.optionLabel(macSortOption.rawValue)),
                    isActive: macSortOption != .quality
                ),
                action: { macOpenRailOptions(macSortOptionList()) }
            ))
            if includeDebrid {
                // Without this the setting still filtered — `playableStreams`
                // applies it with no fallback, unlike its other filters — and a
                // list of uncached streams simply went blank with no way back.
                entries.append(MacRailHeaderEntry(
                    item: MacRailHeaderItem(
                        label: macCachedOnly
                            ? L10n.string("details_cached_only", fallback: "Cached only")
                            : L10n.string("details_all_cache", fallback: "All cache"),
                        isActive: macCachedOnly
                    ),
                    action: {
                        macCachedOnly.toggle()
                        macPublishRailCounts()
                    }
                ))
            }
            return entries
        }
    }

    private var macRailHeaderItems: [MacRailHeaderItem] {
        macRailHeaderEntries.map(\.item)
    }

    private var macRailRows: [MacRailRow] {
        switch macRailMode {
        case .episodes:
            return macSeasonEpisodes.map(macEpisodeRow)
        case .streams:
            return macDisplayedStreams.map(macStreamRow)
        }
    }

    /// What the rail is actually about to draw, as opposed to what the filter
    /// thinks it selected — the two disagreed in testing.
    private func macTraceRails() {
        switch macRailMode {
        case .episodes:
            let all = uiState.meta.map(sortedEpisodes) ?? []
            MacDiagnostics.log(
                "rail.episodes season=\(macActiveSeason) stored=\(macRailSeason.map(String.init) ?? "nil")"
                    + " seasons=\(macSeasons) allSeasons=\(all.map(\.season))"
                    + " shown=\(macSeasonEpisodes.count)"
                    + " titles=\(macSeasonEpisodes.prefix(3).map(\.title))"
            )
        case .streams:
            let rows = macRailRows
            MacDiagnostics.log(
                "rail.streams res=\(macResolutionFilter.rawValue) cached=\(macCachedOnly)"
                    + " debrid=\(includeDebrid) in=\(uiState.streams.count)"
                    + " out=\(rows.count)"
                    + " rows=\(rows.prefix(4).map { "\($0.badge ?? "-")|\($0.title.prefix(28))" })"
            )
        }
    }

    private func macEpisodeRow(_ video: NuvioVideo) -> MacRailRow {
        let isWatched = uiState.meta.map {
            WatchedStore.containsEpisode(meta: $0, season: video.season, episode: video.episode)
        } ?? false
        let hasAired = EpisodeReleasePolicy.hasAired(video.released)
        return MacRailRow(
            id: video.id,
            thumbnailURL: video.thumbnail.flatMap(URL.init(string:)),
            title: "\(video.episode). \(video.title)",
            subtitle: macReleaseLabel(video.released),
            badge: isWatched
                ? L10n.string("details_watched", fallback: "Watched")
                : (hasAired ? nil : L10n.string("calendar_upcoming", fallback: "Upcoming")),
            badgeTint: isWatched ? Color.yellow : Color.green.opacity(0.8),
            progress: macContinueProgress(for: video)
        )
    }

    private func macStreamRow(_ stream: NuvioStream) -> MacRailRow {
        let resolution = StreamPickerListBuilder.resolution(for: stream)
        return MacRailRow(
            id: stream.id,
            leading: stream.addonName,
            title: stream.name?.replacingOccurrences(of: "\n", with: " ") ?? "Stream",
            subtitle: stream.filename ?? stream.description?.replacingOccurrences(of: "\n", with: " "),
            detail: macStreamDetail(stream),
            badge: resolution > 0 ? macResolutionLabel(resolution) : nil
        )
    }

    /// What the row says about a stream beyond its name: how big it is, what it
    /// is encoded as, and whether it will actually play well.
    ///
    /// The add-on buries all of this in a free-text description that the row
    /// already truncates to one line, so it is parsed out and stated plainly —
    /// size and swarm health are what decide between two otherwise identical
    /// 2160p entries.
    private func macStreamDetail(_ stream: NuvioStream) -> String? {
        let tags = StreamQualityTags.parse(stream: stream)
        var parts: [String] = []

        if let size = StreamBadgeSizing.fileSizeLabel(for: stream) {
            parts.append(size.replacingOccurrences(of: "Size ", with: ""))
        }
        if tags.quality != .unknown { parts.append(tags.quality.label) }
        if tags.isAV1 { parts.append("AV1") }
        else if tags.isHEVC { parts.append("HEVC") }
        else if tags.isAVC { parts.append("H.264") }
        if tags.isDolbyVision { parts.append("Dolby Vision") }
        else if tags.isHDR { parts.append("HDR") }
        if tags.isAtmos { parts.append("Atmos") }

        let searchText = [stream.name, stream.description, stream.filename]
            .compactMap { $0 }
            .joined(separator: " ")
        if let seeders = StreamQualityTags.seeders(in: searchText) {
            parts.append("\(seeders) seeders")
        }
        // Cached last: it is the strongest signal, so it reads as the verdict.
        if tags.isCached || stream.isLikelyCached { parts.append("Cached") }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func macSeasonTitle(_ season: Int) -> String {
        season <= 0
            ? L10n.string("details_specials", fallback: "Specials")
            : L10n.format("details_season_format", fallback: "Season %@", String(season))
    }

    private func macContinueProgress(for video: NuvioVideo) -> Double? {
        guard let meta = uiState.meta,
              let item = currentContinueWatchingItem(for: meta, revision: progressRevision),
              !item.isUpNextEntry,
              let numbers = item.episodeNumbers,
              numbers.season == video.season,
              numbers.episode == video.episode
        else { return nil }
        return item.progress
    }

    private func macResolutionLabel(_ height: Int) -> String {
        switch height {
        case 2160...: return "4K"
        case 1440..<2160: return "2K"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        default: return "SD"
        }
    }

    private func macReleaseLabel(_ released: String?) -> String? {
        guard let released, !released.isEmpty else { return nil }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        guard let date = day.date(from: String(released.prefix(10))) else { return nil }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    private func macActivateRailHeader(_ index: Int) {
        let entries = macRailHeaderEntries
        guard entries.indices.contains(index) else { return }
        entries[index].action()
    }

    private func macActivateRailRow(_ index: Int) {
        switch macRailMode {
        case .episodes:
            guard macSeasonEpisodes.indices.contains(index) else { return }
            onEpisodeSelected(macSeasonEpisodes[index])
        case .streams:
            let streams = macDisplayedStreams
            guard streams.indices.contains(index) else { return }
            onSelectStream?(streams[index], nil)
        }
    }

    /// The rail owns the season and the filters, so its row lengths change
    /// under the caret as streams arrive or a filter narrows the list.
    private func macPublishRailCounts() {
        macFocus.register(.railHeader, activate: macActivateRailHeader)
        macFocus.register(.railList, activate: macActivateRailRow)
        macFocus.setCount(macRailIsVisible ? macRailHeaderItems.count : 0, for: .railHeader)
        macFocus.setCount(macRailIsVisible ? macRailRows.count : 0, for: .railList)
        guard macRailIsVisible else { return }
        macTraceRails()
    }

    private var macHasEpisodes: Bool { !(uiState.meta?.videos ?? []).isEmpty }

    /// Nothing is listed until Play is pressed — then a series offers its
    /// episodes and a movie goes straight to its streams.
    private var macRailIsVisible: Bool {
        macRailMode == .streams || macRailOpen
    }

    /// Play on macOS reveals the rail rather than starting playback blind: a
    /// series shows its episodes to choose from, a movie its streams.
    private func macHandlePlay() {
        guard macHasEpisodes else {
            onPlayClick()
            return
        }
        macRailOpen = true
        macPublishRailCounts()
        macFocus.focusRail()
        MacDiagnostics.log("rail.open episodes")
    }

    private func macCloseRail() {
        macRailOpen = false
        isStreamsPresented?.wrappedValue = false
        macPublishRailCounts()
        macFocus.row = .actions
        macFocus.index = 0
        MacDiagnostics.log("rail.close")
    }

    @ViewBuilder
    private func macRail() -> some View {
        if macRailIsVisible {
            MacDetailsRail(
                mode: macRailMode,
                title: macRailTitle,
                subtitle: macRailMode == .streams ? streamsSubtitle : nil,
                headerItems: macRailHeaderItems,
                rows: macRailRows,
                isLoading: macRailMode == .streams && uiState.isLoadingStreams,
                emptyMessage: macRailEmptyMessage,
                focusedHeaderIndex: macFocus.row == .railHeader ? macFocus.index : nil,
                focusedRowIndex: macFocus.row == .railList ? macFocus.index : nil,
                onHeaderTap: { index in
                    macFocus.row = .railHeader
                    macFocus.index = index
                    macActivateRailHeader(index)
                },
                onRowTap: { index in
                    macFocus.row = .railList
                    macFocus.index = index
                    macActivateRailRow(index)
                }
            )
            .padding(.vertical, 70)
            .padding(.trailing, MacRailMetrics.gutter)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var macRailTitle: String {
        switch macRailMode {
        case .episodes:
            return L10n.string("details_episodes", fallback: "Episodes")
        case .streams:
            return L10n.string("details_streams", fallback: "Streams")
        }
    }

    private var macRailEmptyMessage: String? {
        switch macRailMode {
        case .episodes:
            return L10n.string("details_no_episodes", fallback: "No episodes listed")
        case .streams:
            guard !uiState.isLoadingStreams else { return nil }
            return L10n.string("details_no_streams", fallback: "No streams found")
        }
    }

    private func macOpenRailOptions(_ list: MacPickerOptionList) {
        macRailOptions = list
        macRailOptionIndex = max(list.options.firstIndex(where: \.isSelected) ?? 0, 0)
    }

    private func macProviderOptionList() -> MacPickerOptionList {
        var options = [MacPickerOption(
            label: L10n.string("action_all", fallback: "All"),
            isSelected: macSelectedAddonId == nil,
            apply: { macSelectedAddonId = nil }
        )]
        options += macProviderGroups.map { group in
            MacPickerOption(
                label: group.isLoading ? "\(group.displayName)…" : group.displayName,
                isSelected: macSelectedAddonId == group.addonId,
                apply: { macSelectedAddonId = group.addonId }
            )
        }
        return MacPickerOptionList(
            title: L10n.string("details_filter_provider", fallback: "Provider"),
            options: options
        )
    }

    private func macResolutionOptionList() -> MacPickerOptionList {
        MacPickerOptionList(
            title: L10n.string("details_filter_resolution", fallback: "Resolution"),
            options: StreamResolutionFilter.allCases.map { option in
                MacPickerOption(
                    label: option.title,
                    isSelected: macResolutionFilter == option,
                    apply: { macResolutionFilter = option }
                )
            }
        )
    }

    private func macSortOptionList() -> MacPickerOptionList {
        MacPickerOptionList(
            title: L10n.string("details_sort_streams_by", fallback: "Sort streams by"),
            options: StreamSortOption.allCases.map { option in
                MacPickerOption(
                    label: L10n.optionLabel(option.rawValue),
                    isSelected: macSortOption == option,
                    apply: { macSortOption = option }
                )
            }
        )
    }

    private func handleMacKey(_ key: MacKey) {
        if let list = macRailOptions {
            handleMacOptionKey(key, list: list)
            return
        }
        // The menu floats above this page, so it gets first refusal.
        guard let direction = MoveCommandDirection(key) else {
            if MacMenuState.shared.handleReturn() { return }
            MacDiagnostics.log("details.activate row=\(macFocus.row) index=\(macFocus.index)")
            macFocus.activateFocused()
            return
        }
        if MacMenuState.shared.handleMove(direction) { return }
        if !macFocus.move(direction) { MacMenuState.shared.open() }
        MacDiagnostics.log(
            "details.move dir=\(direction) row=\(macFocus.row) index=\(macFocus.index)"
                + " rows=\(macFocus.availableRows.map(\.rawValue))"
        )
    }

    private func handleMacOptionKey(_ key: MacKey, list: MacPickerOptionList) {
        switch key {
        case .up:
            macRailOptionIndex = max(macRailOptionIndex - 1, 0)
        case .down:
            macRailOptionIndex = min(macRailOptionIndex + 1, list.options.count - 1)
        case .left, .back:
            // Escape and Left both back out of the picker without choosing.
            macRailOptions = nil
        case .right:
            break
        case .activate:
            guard list.options.indices.contains(macRailOptionIndex) else { return }
            list.options[macRailOptionIndex].apply()
            macRailOptions = nil
        }
    }

    /// Where to scroll when keyboard focus moves to a row.
    private func macScrollAnchor(for row: MacDetailsRow) -> String? {
        switch row {
        case .actions: return TvDetailsScrollID.topSection
        case .cast: return TvDetailsScrollID.castSection
        case .related: return TvDetailsScrollID.moreLikeThisSection
        case .network: return TvDetailsScrollID.networkSection
        case .production: return TvDetailsScrollID.productionSection
        // The rail scrolls itself; the left column stays where it is.
        case .railHeader, .railList: return nil
        }
    }
    #endif

    private func isDetailsFocusReachable(_ section: TvDetailsFocusSection) -> Bool {
        guard let currentIndex = detailsFocusOrder.firstIndex(of: focusedDetailsSection),
              let sectionIndex = detailsFocusOrder.firstIndex(of: section) else {
            return true
        }
        return abs(sectionIndex - currentIndex) <= 1
    }

    // Give series more horizontal room so the episode cards aren't cramped.
    private func detailsWidth(_ proxy: GeometryProxy, hasEpisodes: Bool) -> CGFloat {
        #if os(macOS)
        // The rail takes the right-hand side while it is open, so the column is
        // whatever is left rather than the full-bleed width the tvOS episode
        // strip needed.
        if macRailIsVisible {
            return max(proxy.size.width - MacRailMetrics.width - MacRailMetrics.gutter * 3, 520)
        }
        return min(proxy.size.width * 0.64, 1180)
        #else
        return hasEpisodes ? min(proxy.size.width - 96, 2200) : min(proxy.size.width * 0.64, 1180)
        #endif
    }

    private func sortedEpisodes(_ meta: NuvioMeta) -> [NuvioVideo] {
        (meta.videos ?? []).sorted {
            (seasonSortKey($0.season), $0.episode) < (seasonSortKey($1.season), $1.episode)
        }
    }

    private func firstPlayableEpisode(_ episodes: [NuvioVideo]) -> NuvioVideo? {
        // Prefer a real season over season 0 specials.
        episodes.first(where: { $0.season > 0 }) ?? episodes.first
    }

    /// Primary-button target: resume the in-progress episode, advance to the
    /// next one after a finished episode, or start from the first playable one.
    /// Movies have no episode; the label alone flips between Play and Resume.
    private func playTarget(
        for meta: NuvioMeta,
        episodes: [NuvioVideo],
        continueItem: ContinueWatchingItem?
    ) -> (episode: NuvioVideo?, label: String, isPlayable: Bool) {
        guard !episodes.isEmpty else {
            return (nil, continueItem == nil ? L10n.string("action_play", fallback: "Play") : L10n.string("action_resume", fallback: "Resume"), true)
        }

        if let continueItem,
           let numbers = continueItem.episodeNumbers,
           let target = episodes.first(where: { $0.season == numbers.season && $0.episode == numbers.episode }) {
            if continueItem.isUpNextEntry, !continueItem.hasAired {
                let label = continueItem.airDateText.map { L10n.format("details_airs_date", fallback: "Airs %@", $0) } ?? L10n.string("details_upcoming", fallback: "Upcoming")
                return (target, label, false)
            }
            let verb = continueItem.isUpNextEntry ? L10n.string("details_next", fallback: "Next") : L10n.string("action_resume", fallback: "Resume")
            return (target, "\(verb) S\(target.season) E\(target.episode)", true)
        }

        // No progress entry (e.g. the episode just finished): continue with the
        // episode after the furthest completed/watched episode, ignoring earlier skipped episodes.
        let watched = WatchedStore.watchedEpisodeKeys(meta: meta)
        if !watched.isEmpty {
            let watchedPairs: [(season: Int, episode: Int)] = watched.compactMap { key in
                let parts = key.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
                return (parts[0], parts[1])
            }
            if let latestWatched = watchedPairs.max(by: { ($0.season, $0.episode) < ($1.season, $1.episode) }),
               let next = episodes.first(where: {
                   $0.season > 0
                       && ($0.season, $0.episode) > (latestWatched.season, latestWatched.episode)
                       && !watched.contains("\($0.season):\($0.episode)")
               }) {
                let verb = EpisodeReleasePolicy.hasAired(next.released) ? L10n.string("details_next", fallback: "Next") : L10n.string("details_upcoming", fallback: "Upcoming")
                return (next, "\(verb) S\(next.season) E\(next.episode)", EpisodeReleasePolicy.hasAired(next.released))
            }
            if let firstUnwatched = episodes.first(where: { $0.season > 0 && !watched.contains("\($0.season):\($0.episode)") }) {
                return (firstUnwatched, "\(L10n.string("details_next", fallback: "Next")) S\(firstUnwatched.season) E\(firstUnwatched.episode)", true)
            }
        }

        let first = firstPlayableEpisode(episodes)
        return (first, first.map { "\(L10n.string("action_play", fallback: "Play")) S\($0.season) E\($0.episode)" } ?? L10n.string("action_play", fallback: "Play"), true)
    }

    /// `revision` is deliberately unused: taking it forces the lookup to be
    /// re-run whenever ``progressRevision`` changes, which is what re-reads the
    /// stores after a watched mark clears an episode's progress.
    private func currentContinueWatchingItem(
        for meta: NuvioMeta,
        revision: Int
    ) -> ContinueWatchingItem? {
        if RemoteTrackingState.isProgressSourceAuthenticated {
            return TraktProgressService.currentContinueWatchingItem(for: meta)
        }
        return ContinueWatchingStore.item(for: meta.id)
    }

    private func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }
}

private enum TvDetailsScrollTiming {
    static let duration = 0.3
    /// The trace shows tvOS needs roughly 35–50 ms to commit programmatic
    /// focus. Arm the handoff in the scroll's final phase so visible focus and
    /// the explicit scroll settle together at approximately 300 ms.
    static let focusHandoffDelay = 0.25
}

private enum TvDetailsScrollID {
    static let topSection = "tv-details-top-section"
    static let castSection = "tv-details-cast-section"
    static let episodesSection = "tv-details-episodes-section"
    static let moreLikeThisSection = "tv-details-more-like-this"
    static let productionSection = "tv-details-production"
    static let networkSection = "tv-details-network"
    static let commentsSection = "tv-details-comments"
}

private struct TvDetailsScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TvDetailsScrolledBackdropDimmer: View {
    var isScrolledDown: Bool = false

    var body: some View {
        ZStack {
            Color.black
                .opacity(isScrolledDown ? 0.45 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            TvDetailsScrollTransitionShadow(progress: isScrolledDown ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.35), value: isScrolledDown)
    }
}

private struct TvDetailsScrollTransitionShadow: View {
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    .black.opacity(0.34 * progress),
                    .black.opacity(0.12 * progress),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 72)

            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TvDetailsBackdrop: View {
    let meta: NuvioMeta
    var blurRadius: CGFloat = 0
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        ZStack {
            if let imageUrl = meta.backgroundUrl ?? meta.posterUrl,
               let url = URL(string: imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        backdropColor
                    }
                }
                .blur(radius: blurRadius, opaque: true)
                .animation(.easeInOut(duration: 0.35), value: blurRadius)
                .ignoresSafeArea()
            } else {
                backdropColor.ignoresSafeArea()
            }

            GeometryReader { proxy in
                    LinearGradient(
                    stops: [
                        .init(color: backdropColor.opacity(0.95), location: 0),
                        .init(color: backdropColor.opacity(0.86), location: 0.25),
                        .init(color: backdropColor.opacity(0.64), location: 0.50),
                        .init(color: backdropColor.opacity(0.34), location: 0.70),
                        .init(color: backdropColor.opacity(0.10), location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.76)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

        }
        .ignoresSafeArea()
    }
}

private struct TvDetailsLogo: View {
    let meta: NuvioMeta

    var body: some View {
        Group {
            if let logoUrl = meta.logoUrl,
               let url = URL(string: logoUrl) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        titleFallback
                    }
                }
            } else {
                titleFallback
            }
        }
        .frame(width: 560, height: 162, alignment: .leading)
    }

    private var titleFallback: some View {
        Text(meta.name)
            .font(.system(size: 58, weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.74)
            .shadow(color: .black.opacity(0.65), radius: 14, y: 6)
            .frame(maxWidth: 560, alignment: .leading)
    }
}

/// Identifies the action-row buttons so focus can be driven programmatically
/// (tvOS doesn't auto-focus the primary button when the details content swaps in
/// after the async load — see `TvDetailsContent`).
private enum DetailsActionFocus: Hashable {
    case play, watchlist, watched, trailer
}

/// The action row's buttons by position, so the keyboard caret's index and the
/// button that runs can never disagree. Only macOS navigates by it, but the
/// shared action row names the type.
enum MacDetailsActionSlot: Int, CaseIterable {
    case play, watchlist, watched, trailer
}

private enum DetailsCastHeaderFocus: Hashable {
    case creatorAndCast, trailer
}

private struct TvDetailsActionRow: View {
    let isInWatchlist: Bool
    let isWatched: Bool
    var playTitle: String = L10n.string("action_play", fallback: "Play")
    var playHint: String = L10n.string("details_play_hint", fallback: "Starts playback or opens stream sources")
    let onPlayClick: () -> Void
    var onPlayLongPress: (() -> Void)? = nil
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    let onTrailerClick: () -> Void
    var focus: FocusState<DetailsActionFocus?>.Binding
    let entryLocked: Bool
    let playEntryLocked: Bool
    let onFocus: () -> Void

    #if os(macOS)
    @ObservedObject private var macFocus = MacDetailsFocus.shared
    #endif

    /// True when the macOS caret is on this button. Always false on tvOS,
    /// where the focus engine drives the same appearance.
    private func isMacFocused(_ slot: MacDetailsActionSlot) -> Bool {
        #if os(macOS)
        return macFocus.isFocused(.actions, slot.rawValue)
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: 26) {
            TvDetailsActionButton(
                title: playTitle,
                systemName: "play.fill",
                accessibilityLabel: playTitle,
                accessibilityHint: playHint,
                isPrimary: true,
                focus: focus,
                tag: .play,
                macIsFocused: isMacFocused(.play),
                action: onPlayClick,
                onFocus: onFocus,
                longPressAction: onPlayLongPress
            )
            .disabled(playEntryLocked)

            TvDetailsActionButton(
                title: nil,
                systemName: isInWatchlist ? "checkmark" : "plus",
                accessibilityLabel: isInWatchlist
                    ? L10n.string("details_in_library", fallback: "In library")
                    : L10n.string("details_add_to_library", fallback: "Add to library"),
                accessibilityHint: isInWatchlist
                    ? L10n.string("details_remove_from_library_hint", fallback: "Removes this title from your library")
                    : L10n.string("details_add_to_library_hint", fallback: "Adds this title to your library"),
                isPrimary: false,
                focus: focus,
                tag: .watchlist,
                macIsFocused: isMacFocused(.watchlist),
                action: onWatchlistClick,
                onFocus: onFocus
            )
            .disabled(entryLocked)

            TvDetailsActionButton(
                title: nil,
                systemName: isWatched ? "eye.fill" : "eye.slash.fill",
                accessibilityLabel: isWatched
                    ? L10n.string("details_watched", fallback: "Watched")
                    : L10n.string("details_not_watched", fallback: "Not watched"),
                accessibilityHint: isWatched
                    ? L10n.string("details_mark_unwatched_hint", fallback: "Marks this title as unwatched")
                    : L10n.string("details_mark_watched_hint", fallback: "Marks this title as watched"),
                isPrimary: false,
                focus: focus,
                tag: .watched,
                macIsFocused: isMacFocused(.watched),
                action: onWatchedClick,
                onFocus: onFocus
            )
            .disabled(entryLocked)

            TvDetailsActionButton(
                title: nil,
                systemName: "play.rectangle.fill",
                accessibilityLabel: L10n.string("details_trailer", fallback: "Trailer"),
                accessibilityHint: L10n.string("details_trailer_hint", fallback: "Plays the trailer when available"),
                isPrimary: false,
                focus: focus,
                tag: .trailer,
                macIsFocused: isMacFocused(.trailer),
                action: onTrailerClick,
                onFocus: onFocus
            )
            .disabled(entryLocked)
        }
    }
}

private struct TvDetailsActionButton: View {
    let title: String?
    let systemName: String
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    let isPrimary: Bool
    var focus: FocusState<DetailsActionFocus?>.Binding
    let tag: DetailsActionFocus
    /// Set by the parent on macOS, where nothing moves AppKit focus between
    /// these buttons. A stored value re-renders; a focus binding does not.
    var macIsFocused: Bool = false
    let action: () -> Void
    let onFocus: () -> Void
    var longPressAction: (() -> Void)? = nil

    @State private var didTriggerLongPress = false

    private var isFocused: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return focus.wrappedValue == tag
        #endif
    }

    var body: some View {
        Button(action: {
            if didTriggerLongPress {
                didTriggerLongPress = false
                return
            }
            action()
        }) {
            HStack(spacing: 16) {
                Image(systemName: systemName)
                    .font(.system(size: isPrimary ? 30 : 36, weight: .bold))
                    .accessibilityHidden(true)

                if let title {
                    Text(title)
                        .font(.system(size: 32, weight: .medium))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, isPrimary ? 44 : 0)
            .frame(minWidth: isPrimary ? 228 : 98, maxWidth: isPrimary ? nil : 98, minHeight: 98)
            .frame(height: 98)
            .modifier(TvDetailsGlassBackground(filled: isPrimary || isFocused, shape: Capsule()))
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0.18), radius: isFocused ? 18 : 7, y: 8)
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused(focus, equals: tag)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
            didTriggerLongPress = false
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.48).onEnded { _ in
                guard longPressAction != nil else { return }
                didTriggerLongPress = true
                longPressAction?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    didTriggerLongPress = false
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .modifier(OptionalAccessibilityHint(hint: accessibilityHint))
    }

    private var foregroundColor: Color {
        if isPrimary || isFocused {
            return .black
        }
        return .white
    }
}

private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let hint, !hint.isEmpty {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

private struct TvDetailsSummary: View {
    let meta: NuvioMeta
    var simkl: SimklTitleRatings? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let creatorLine {
                Text(creatorLine)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white.opacity(0.62))
            }

            if !externalRatingBadges.isEmpty {
                TvDetailsRatingsRow(badges: externalRatingBadges)
            }

            if let description = meta.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(.white)
                    .lineSpacing(8)
                    .frame(maxWidth: 950, alignment: .leading)
            }

            if !primaryMetaItems.isEmpty {
                Text(primaryMetaItems.joined(separator: "  •  "))
                    .font(.system(size: 27, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(2)
            }

            if statusLabel != nil || !secondaryMetaItems.isEmpty {
                HStack(spacing: 16) {
                    if let statusLabel {
                        Text(statusLabel)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.white.opacity(0.45), lineWidth: 2)
                            )
                    }

                    if !secondaryMetaItems.isEmpty {
                        Text((statusLabel != nil ? "•  " : "") + secondaryMetaItems.joined(separator: "  •  "))
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var creatorLine: String? {
        if let director = meta.director?.first, !director.isEmpty {
            return "Director: \(director)"
        }
        if let writer = meta.writer?.first, !writer.isEmpty {
            return "Writer: \(writer)"
        }
        return nil
    }

    /// Series status badge ("ENDED" / "ONGOING"); nil for movies.
    private var statusLabel: String? { meta.statusBadgeLabel }

    private var primaryMetaItems: [String] {
        var items = Array((meta.genres ?? []).prefix(3))
        // Series show the year range ("2026–"); movies show the full release date.
        if meta.isSeries {
            if let info = meta.releaseInfo, !info.isEmpty {
                items.append(info)
            } else if let year = meta.year {
                items.append(String(year))
            }
        } else if let date = releaseDisplay {
            items.append(date)
        } else if let year = meta.year {
            items.append(String(year))
        }
        return items
    }

    private var secondaryMetaItems: [String] {
        var items: [String] = []
        if let runtime = NuvioRuntimeDisplay.formatted(meta.runtime) {
            items.append(runtime)
        }
        if let country = meta.country, !country.isEmpty {
            items.append(country)
        }
        items.append(contentsOf: simklMetaItems)
        return items
    }

    /// Simkl's community numbers. Drop rate is Simkl-only — neither Trakt nor
    /// TMDB reports how many viewers gave up on a title.
    private var simklMetaItems: [String] {
        guard let simkl else { return [] }
        var items: [String] = []
        if let rating = simkl.rating {
            items.append(String(format: "★ %.1f Simkl", rating))
        }
        if let rank = simkl.rank {
            items.append("#\(rank)")
        }
        if let dropRate = simkl.dropRate, dropRate != "0%" {
            items.append("\(dropRate) dropped")
        }
        return items
    }

    private var releaseDisplay: String? {
        NuvioDateDisplay.formattedDate(meta.released ?? meta.releaseInfo)
    }

    private var externalRatingBadges: [TvRatingBadge] {
        let ratings = Dictionary(uniqueKeysWithValues: (meta.externalRatings ?? []).map { ($0.source, $0) })
        return TvRatingVisual.all.compactMap { visual in
            guard let rating = ratings[visual.source] else { return nil }
            return TvRatingBadge(visual: visual, rating: rating)
        }
    }
}

private struct TvRatingBadge: Identifiable {
    let visual: TvRatingVisual
    let rating: NuvioExternalRating

    var id: String { rating.source }
}

private struct TvRatingVisual {
    let source: String
    let displayName: String
    let assetName: String
    let iconWidth: CGFloat
    let color: Color
    let format: (Double) -> String

    static let all: [TvRatingVisual] = [
        TvRatingVisual(
            source: MdbListDetailsService.providerIMDb,
            displayName: "IMDb",
            assetName: "rating_imdb",
            iconWidth: 68,
            color: Color(red: 0.96, green: 0.77, blue: 0.09),
            format: { String(format: "%.1f", $0) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerTMDB,
            displayName: "TMDB",
            assetName: "rating_tmdb",
            iconWidth: 40,
            color: Color(red: 0.00, green: 0.71, blue: 0.89),
            format: { String(Int($0.rounded())) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerTomatoes,
            displayName: "Rotten Tomatoes",
            assetName: "rating_rotten_tomatoes",
            iconWidth: 38,
            color: Color(red: 0.98, green: 0.20, blue: 0.04),
            format: { "\(Int($0.rounded()))%" }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerAudience,
            displayName: "Audience Score",
            assetName: "rating_audience_score",
            iconWidth: 31,
            color: Color(red: 0.98, green: 0.20, blue: 0.04),
            format: { "\(Int($0.rounded()))%" }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerMetacritic,
            displayName: "Metacritic",
            assetName: "rating_metacritic",
            iconWidth: 38,
            color: Color(red: 1.00, green: 0.80, blue: 0.20),
            format: { String(Int($0.rounded())) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerTrakt,
            displayName: "Trakt",
            assetName: "rating_trakt",
            iconWidth: 38,
            color: Color(red: 0.93, green: 0.11, blue: 0.14),
            format: { String(Int($0.rounded())) }
        ),
        TvRatingVisual(
            source: MdbListDetailsService.providerLetterboxd,
            displayName: "Letterboxd",
            assetName: "rating_letterboxd",
            iconWidth: 38,
            color: Color(red: 0.00, green: 0.88, blue: 0.33),
            format: { String(format: "%.1f", $0) }
        ),
    ]
}

private struct TvDetailsRatingsRow: View {
    let badges: [TvRatingBadge]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 26) {
                ForEach(badges) { badge in
                    HStack(spacing: 9) {
                        Image(badge.visual.assetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: badge.visual.iconWidth, height: 38)
                            .accessibilityLabel(badge.visual.displayName)

                        Text(badge.visual.format(badge.rating.value))
                            .font(.system(size: 28, weight: .regular))
                            .foregroundColor(.white.opacity(0.62))
                    }
                }
            }
        }
        .frame(maxWidth: 950, alignment: .leading)
    }
}

private struct TvDetailsCastAndTrailer: View {
    let meta: NuvioMeta
    let people: [TmdbPersonMetadata]
    let onPersonClick: (TmdbPersonMetadata) -> Void
    let onTrailerClick: () -> Void
    var headerFocus: FocusState<DetailsCastHeaderFocus?>.Binding
    let entryLocked: Bool
    let onFocus: () -> Void

    @State private var focusedPersonIndex = 0
    #if os(macOS)
    @ObservedObject private var macFocus = MacDetailsFocus.shared
    #endif

    private func macIsFocused(_ index: Int) -> Bool {
        #if os(macOS)
        return macFocus.isFocused(.cast, index)
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 18) {
                TvDetailsSectionButton(
                    title: L10n.string("details_creator_and_cast", fallback: "Creator and Cast"),
                    isSelected: false,
                    focus: headerFocus,
                    tag: .creatorAndCast,
                    onFocus: onFocus
                ) {}

                Text("|")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))

                TvDetailsSectionButton(
                    title: L10n.string("details_trailer", fallback: "Trailer"),
                    isSelected: false,
                    focus: headerFocus,
                    tag: .trailer,
                    onFocus: onFocus,
                    action: onTrailerClick
                )
                    .disabled(entryLocked)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 58) {
                    ForEach(Array(displayPeople.enumerated()), id: \.element.id) { index, person in
                        TvDetailsPersonCard(
                            person: person,
                            macIsFocused: macIsFocused(index),
                            onSelect: { onPersonClick(person) },
                            onFocus: {
                                focusedPersonIndex = index
                                onFocus()
                            }
                        )
                        .disabled(entryLocked)
                    }
                }
                .padding(.trailing, 80)
            }
            .scrollClipDisabledIfAvailable()
        }
        #if os(macOS)
        .onChange(of: displayPeople.count, initial: true) { _, _ in
            publishMacRow()
        }
        #endif
    }

    /// The row caps the cast at eight and falls back to `meta.cast` when TMDB
    /// gave nothing, so only it knows how many cards are actually drawn — the
    /// page above would have published the wrong number either way.
    #if os(macOS)
    private func publishMacRow() {
        macFocus.setCount(displayPeople.count, for: .cast)
        macFocus.register(.cast) { index in
            guard displayPeople.indices.contains(index) else { return }
            onPersonClick(displayPeople[index])
        }
    }
    #endif

    private var displayPeople: [TmdbPersonMetadata] {
        if !people.isEmpty {
            return Array(people.prefix(8))
        }

        let cast = meta.cast ?? []
        if !cast.isEmpty {
            return Array(cast.prefix(8)).map {
                TmdbPersonMetadata(name: $0, role: nil, profileURL: nil, tmdbId: nil)
            }
        }

        let creators = (meta.director ?? []) + (meta.writer ?? [])
        if !creators.isEmpty {
            return Array(creators.prefix(8)).map {
                TmdbPersonMetadata(name: $0, role: nil, profileURL: nil, tmdbId: nil)
            }
        }

        return [TmdbPersonMetadata(name: L10n.string("details_cast", fallback: "Cast"), role: nil, profileURL: nil, tmdbId: nil)]
    }
}

private struct TvDetailsSectionButton: View {
    let title: String
    let isSelected: Bool
    var focus: FocusState<DetailsCastHeaderFocus?>.Binding
    let tag: DetailsCastHeaderFocus
    let onFocus: () -> Void
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == tag }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(.white.opacity(isFocused || isSelected ? 1 : 0.48))
                .padding(.horizontal, isSelected ? 0 : 4)
                .frame(height: 64)
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused(focus, equals: tag)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.035 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused {
                onFocus()
            }
        }
    }
}

// MARK: - More Like This / Production / Comments

private enum TvDetailsHorizontalStrip {
    static let verticalPadding: CGFloat = 28
    static let scrollSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)
}

private struct TvDetailsRelatedRow: View {
    let title: String
    let items: [RelatedTitle]
    let entryLocked: Bool
    /// Position of the macOS keyboard caret in this row, or nil when it is
    /// somewhere else on the page.
    var macFocusedIndex: Int? = nil
    let onSelect: (RelatedTitle) -> Void
    let onFocus: () -> Void

    @State private var scrollIndex = 0
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var cardWidth: CGFloat { homeLayout == "Compact" ? 170 : 210 }
    private var cardHeight: CGFloat { homeLayout == "Compact" ? 255 : 315 }
    private var spacing: CGFloat { homeLayout == "Compact" ? 22 : 28 }
    private var step: CGFloat { cardWidth + spacing }
    private var stripHeight: CGFloat {
        cardHeight + 36 + TvDetailsHorizontalStrip.verticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PosterCard(
                        meta: item.asMeta,
                        onFocus: { _ in
                            if scrollIndex != index { scrollIndex = index }
                            onFocus()
                        },
                        macFocusedCardKey: macFocusedIndex.flatMap { items.indices.contains($0) ? items[$0].id : nil },
                        layoutMode: homeLayout,
                        showPosterLabels: posterLabels,
                        smoothFocusAnimations: smoothFocus,
                        focusHighlighterEnabled: focusHighlighter
                    ) {
                        onSelect(item)
                    }
                    .disabled(entryLocked && index != scrollIndex)
                }
            }
            .padding(.vertical, TvDetailsHorizontalStrip.verticalPadding)
            .offset(x: -CGFloat(scrollIndex) * step)
            // Deliberately do not clip this strip to the text column. Like the
            // Home rows, posters keep drawing all the way to the screen edge.
            .frame(height: stripHeight, alignment: .leading)
            .animation(
                smoothFocus ? TvDetailsHorizontalStrip.scrollSpring : nil,
                value: scrollIndex
            )
        }
        .focusSection()
    }
}

private struct TvDetailsProductionRow: View {
    let title: String
    let companies: [MetaCompany]
    let entryLocked: Bool
    /// Which row of the macOS keyboard model this strip is. Network and
    /// Production are the same view twice, so it cannot infer its own place.
    var macRow: MacDetailsRow? = nil
    let onSelect: (MetaCompany) -> Void
    let onFocus: () -> Void

    @State private var focusedCompanyIndex = 0
    #if os(macOS)
    @ObservedObject private var macFocus = MacDetailsFocus.shared
    #endif

    private func macIsFocused(_ index: Int) -> Bool {
        #if os(macOS)
        guard let macRow else { return false }
        return macFocus.isFocused(macRow, index)
        #else
        return false
        #endif
    }

    private var entryCompanyIndex: Int {
        if companies.indices.contains(focusedCompanyIndex),
           companies[focusedCompanyIndex].tmdbId != nil {
            return focusedCompanyIndex
        }
        return companies.firstIndex { $0.tmdbId != nil } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 22) {
                    ForEach(Array(companies.enumerated()), id: \.element.id) { index, company in
                        TvDetailsCompanyCard(
                            company: company,
                            macIsFocused: macIsFocused(index),
                            onSelect: { onSelect(company) },
                            onFocus: {
                                focusedCompanyIndex = index
                                onFocus()
                            }
                        )
                        .disabled(entryLocked && index != entryCompanyIndex)
                    }
                }
                .padding(.trailing, 80)
                .padding(.vertical, 8)
            }
            .scrollClipDisabledIfAvailable()
        }
    }
}

private struct TvDetailsCompanyCard: View {
    let company: MetaCompany
    /// Driven by `MacDetailsFocus`; macOS has no focus engine to set `focused`.
    var macIsFocused = false
    let onSelect: () -> Void
    let onFocus: () -> Void

    @FocusState private var focused: Bool

    /// tvOS reads the focus engine; macOS has none, so the caret decides.
    private var isFocused: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return focused
        #endif
    }
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 14)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 14) {
                ZStack {
                    shape
                        .fill(Color.white.opacity(liquidGlassCards ? 0.90 : 1))
                    if let logo = company.logoURL, let url = URL(string: logo) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .padding(16)
                            } else {
                                Text(company.name)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.black)
                                    .multilineTextAlignment(.center)
                                    .padding(12)
                            }
                        }
                    } else {
                        Text(company.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.black)
                            .multilineTextAlignment(.center)
                            .padding(12)
                    }
                }
                .frame(width: 200, height: 100)
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: isFocused,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(
                    shape.stroke(
                        isFocused ? AppFocusOutline.color : Color.clear,
                        lineWidth: isFocused ? AppFocusOutline.width : 0
                    )
                )

                Text(company.name)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    // Reserve room for the longest label so one-line names do
                    // not change the vertical position of neighboring cards.
                    .frame(width: 200, height: 52, alignment: .top)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: focused) { _, focused in
            if focused { onFocus() }
        }
        .disabled(company.tmdbId == nil)
        .opacity(company.tmdbId == nil ? 0.55 : 1)
    }
}

private struct TvDetailsCommentsRow: View {
    let comments: [TraktCommentReview]
    let entryLocked: Bool
    let onSelect: (TraktCommentReview) -> Void
    let onFocus: () -> Void

    @State private var scrollIndex = 0
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true

    private let cardWidth: CGFloat = 420
    private let cardHeight: CGFloat = 240
    private let spacing: CGFloat = 22

    private var stripHeight: CGFloat {
        cardHeight + TvDetailsHorizontalStrip.verticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L10n.string("details_top_comments", fallback: "Top Comments"))
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            HStack(spacing: 22) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    TvDetailsCommentCard(
                        comment: comment,
                        onSelect: { onSelect(comment) },
                        onFocus: {
                            if scrollIndex != index { scrollIndex = index }
                            onFocus()
                        }
                    )
                    .disabled(entryLocked && index != scrollIndex)
                }
            }
            .padding(.vertical, TvDetailsHorizontalStrip.verticalPadding)
            .offset(x: -CGFloat(scrollIndex) * (cardWidth + spacing))
            // Keep comment cards edge-to-edge as well; the parent vertical
            // scroll view owns the viewport instead of this row clipping it.
            .frame(height: stripHeight, alignment: .leading)
            .animation(
                smoothFocus ? TvDetailsHorizontalStrip.scrollSpring : nil,
                value: scrollIndex
            )
        }
        .focusSection()
    }
}

private struct TvDetailsCommentCard: View {
    let comment: TraktCommentReview
    let onSelect: () -> Void
    let onFocus: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text(comment.author)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if comment.likes > 0 {
                        Label("\(comment.likes)", systemImage: "heart.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }

                Text(comment.spoiler ? L10n.string("details_spoiler_notice", fallback: "Spoiler — select to read") : comment.comment)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white.opacity(comment.spoiler ? 0.45 : 0.82))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let date = comment.displayDate {
                    Text(date)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(24)
            .frame(width: 420, height: 240, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        isFocused ? AppFocusOutline.color : Color.white.opacity(0.1),
                        lineWidth: isFocused ? AppFocusOutline.width : 1
                    )
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.03 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
        }
    }
}

private struct CommentDetailOverlay: View {
    let comment: TraktCommentReview
    let onDismiss: () -> Void

    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(comment.author)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.white)
                        if let date = comment.displayDate {
                            Text(date)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Text(L10n.string("action_close", fallback: "Close"))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(closeFocused ? .black : .white)
                            .padding(.horizontal, 26)
                            .frame(height: 54)
                            .modifier(
                                TvDetailsGlassBackground(
                                    filled: closeFocused,
                                    shape: Capsule()
                                )
                            )
                    }
                        .buttonStyle(PosterCardButtonStyle())
                        .nuvioFocusable()
                        .focused($closeFocused)
                }

                ScrollView {
                    Text(comment.comment)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(.white.opacity(0.92))
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if comment.likes > 0 {
                    Label(L10n.format("details_likes_count", fallback: "%d likes", comment.likes), systemImage: "heart.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .padding(48)
            .frame(maxWidth: 1100, maxHeight: 620)
            .modifier(
                TvStreamGlass(
                    shape: RoundedRectangle(cornerRadius: 28, style: .continuous),
                    tint: Color.black.opacity(0.34)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .onAppear { closeFocused = true }
        .onExitCommand(perform: onDismiss)
    }
}

actor PersonProfileImageCache {
    static let shared = PersonProfileImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    init() {
        cache.countLimit = 60
        cache.totalCostLimit = 20 * 1024 * 1024 // 20 MB
        #if canImport(UIKit) || os(macOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task {
                await PersonProfileImageCache.shared.purge()
            }
        }
        #endif
    }

    func purge() {
        cache.removeAllObjects()
    }

    func image(for url: NSURL) -> UIImage? {
        cache.object(forKey: url)
    }

    func insert(_ image: UIImage, for url: NSURL) {
        cache.setObject(image, forKey: url)
    }
}

private struct TvDetailsPersonCard: View {
    let person: TmdbPersonMetadata
    /// Driven by `MacDetailsFocus`; macOS has no focus engine to set `focused`.
    var macIsFocused = false
    let onSelect: () -> Void
    let onFocus: () -> Void

    @FocusState private var focused: Bool

    /// tvOS reads the focus engine; macOS has none, so the caret decides.
    private var isFocused: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return focused
        #endif
    }
    @State private var profileImage: UIImage?

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 18) {
                Circle()
                    .frame(width: 188, height: 188)
                    .modifier(TvDetailsGlassBackground(filled: isFocused, shape: Circle()))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(isFocused ? 0.0 : 0.22), lineWidth: 1)
                    )
                    .overlay {
                        if let profileImage {
                            Image(uiImage: profileImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 188, height: 188)
                                .clipShape(Circle())
                        } else {
                            Text(initials)
                                .font(.system(size: 44, weight: .medium))
                                .foregroundColor(isFocused ? .black : .white)
                        }
                    }

                Text(person.name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(isFocused ? .white : .white.opacity(0.74))
                    .lineLimit(1)
                    .frame(width: 210)

                if let role = person.role,
                   !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(role)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.white.opacity(isFocused ? 0.82 : 0.55))
                        .lineLimit(1)
                        .frame(width: 210)
                }
            }
            .frame(width: 220)
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .onChange(of: focused) { _, focused in
            if focused {
                onFocus()
            }
        }
        .task(id: person.profileURL) {
            await loadProfileImage()
        }
    }

    private var initials: String {
        let words = person.name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        let value = String(words).uppercased()
        return value.isEmpty ? "?" : value
    }

    private var profileURL: URL? {
        guard let profileURL = person.profileURL,
              !profileURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: profileURL)
    }

    private func loadProfileImage() async {
        guard profileImage == nil, let url = profileURL else { return }
        let cacheKey = url as NSURL
        if let cached = await PersonProfileImageCache.shared.image(for: cacheKey) {
            profileImage = cached
            return
        }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !Task.isCancelled else {
            return
        }

        let targetPixelSize: CGFloat = 376
        let downsampledImage: UIImage? = {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
                return UIImage(data: data)
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cgImage)
        }()

        guard let image = downsampledImage, !Task.isCancelled else { return }
        await PersonProfileImageCache.shared.insert(image, for: cacheKey)
        profileImage = image
    }
}

// MARK: - Series episodes

private struct TvDetailsEpisodes: View {
    let meta: NuvioMeta
    let episodes: [NuvioVideo]
    let seriesRating: Double?
    let continueItem: ContinueWatchingItem?
    let onFocus: () -> Void
    let onSelect: (NuvioVideo) -> Void
    var onPlayManually: ((NuvioVideo) -> Void)? = nil
    let onEpisodeMenuPresented: (Bool) -> Void
    var episodeFocus: FocusState<String?>.Binding
    /// While set, only the control with this key can take focus — see the
    /// restore in `TvDetailsContent`.
    let restrictFocusToKey: String?
    let entryLocked: Bool
    let onMoveUpFromSeason: () -> Void
    let onMoveDownFromEpisode: () -> Void

    @State private var selectedSeason: Int
    @State private var seasonEpisodes: [NuvioVideo]
    @State private var episodeScrollIndex: Int
    @State private var watchedEpisodeKeys: Set<String>
    @State private var userDidSelectSeason = false
    /// Episodes before the one just marked watched that are still unwatched,
    /// awaiting the viewer's decision. Empty dismisses the prompt.
    @State private var pendingCatchUpEpisodes: [NuvioVideo] = []
    @State private var showCatchUpPrompt = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false

    init(
        meta: NuvioMeta,
        episodes: [NuvioVideo],
        seriesRating: Double?,
        continueItem: ContinueWatchingItem?,
        onFocus: @escaping () -> Void,
        onSelect: @escaping (NuvioVideo) -> Void,
        onPlayManually: ((NuvioVideo) -> Void)? = nil,
        onEpisodeMenuPresented: @escaping (Bool) -> Void,
        episodeFocus: FocusState<String?>.Binding,
        restrictFocusToKey: String?,
        entryLocked: Bool,
        onMoveUpFromSeason: @escaping () -> Void,
        onMoveDownFromEpisode: @escaping () -> Void
    ) {
        self.meta = meta
        self.episodes = episodes
        self.seriesRating = seriesRating
        self.continueItem = continueItem
        self.onFocus = onFocus
        self.onSelect = onSelect
        self.onPlayManually = onPlayManually
        self.onEpisodeMenuPresented = onEpisodeMenuPresented
        self.episodeFocus = episodeFocus
        self.restrictFocusToKey = restrictFocusToKey
        self.entryLocked = entryLocked
        self.onMoveUpFromSeason = onMoveUpFromSeason
        self.onMoveDownFromEpisode = onMoveDownFromEpisode
        let watchedKeys = WatchedStore.watchedEpisodeKeys(meta: meta)
        let initialEpisode = Self.initialEpisode(
            episodes: episodes,
            continueItem: continueItem,
            watchedKeys: watchedKeys
        )
        let initialSeason = initialEpisode?.season ?? Self.defaultSeason(episodes)
        let initialSeasonEpisodes = episodes
            .filter { $0.season == initialSeason }
            .sorted { $0.episode < $1.episode }
        let initialIndex = initialEpisode.flatMap { target in
            initialSeasonEpisodes.firstIndex(where: { $0.id == target.id })
        } ?? 0
        _selectedSeason = State(initialValue: initialSeason)
        _seasonEpisodes = State(initialValue: initialSeasonEpisodes)
        _episodeScrollIndex = State(initialValue: initialIndex)
        _watchedEpisodeKeys = State(initialValue: watchedKeys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            seasonSelector
            episodeCardStrip
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            watchedEpisodeKeys = WatchedStore.watchedEpisodeKeys(meta: meta)
        }
        .confirmationDialog(
            L10n.format(
                "details_catch_up_title",
                fallback: "Mark %@ earlier episode(s) as watched too?",
                String(pendingCatchUpEpisodes.count)
            ),
            isPresented: $showCatchUpPrompt,
            titleVisibility: .visible
        ) {
            Button(L10n.string("details_catch_up_confirm", fallback: "Mark them watched")) {
                markCatchUpEpisodesWatched()
            }
            Button(L10n.string("action_cancel", fallback: "Cancel"), role: .cancel) {
                pendingCatchUpEpisodes = []
            }
        }
        .onChange(of: episodes) { _, newEpisodes in
            let watchedKeys = WatchedStore.watchedEpisodeKeys(meta: meta)
            let targetEpisode = Self.initialEpisode(
                episodes: newEpisodes,
                continueItem: continueItem,
                watchedKeys: watchedKeys
            )
            let targetSeason = targetEpisode?.season ?? Self.defaultSeason(newEpisodes)
            let currentSeasons = Array(Set(newEpisodes.map(\.season))).sorted {
                (seasonSortKey($0), $0) < (seasonSortKey($1), $1)
            }
            if !userDidSelectSeason || !currentSeasons.contains(selectedSeason) {
                selectedSeason = targetSeason
                let seasonEps = newEpisodes
                    .filter { $0.season == targetSeason }
                    .sorted { $0.episode < $1.episode }
                seasonEpisodes = seasonEps
                episodeScrollIndex = targetEpisode.flatMap { target in
                    seasonEps.firstIndex(where: { $0.id == target.id })
                } ?? 0
            } else {
                seasonEpisodes = newEpisodes
                    .filter { $0.season == selectedSeason }
                    .sorted { $0.episode < $1.episode }
            }
        }
        .onChange(of: selectedSeason) { _, newSeason in
            seasonEpisodes = episodes
                .filter { $0.season == newSeason }
                .sorted { $0.episode < $1.episode }
        }
    }

    /// Every unwatched episode released before this one, across seasons —
    /// season 0 specials excluded, since they are rarely part of a linear
    /// catch-up and marking them would surprise.
    private func unwatchedEpisodesBefore(_ video: NuvioVideo) -> [NuvioVideo] {
        let all = episodes.isEmpty ? seasonEpisodes : episodes
        return all
            .filter { candidate in
                guard candidate.season > 0 else { return false }
                let isEarlier = candidate.season < video.season
                    || (candidate.season == video.season && candidate.episode < video.episode)
                guard isEarlier else { return false }
                return !WatchedStore.containsEpisode(
                    meta: meta,
                    season: candidate.season,
                    episode: candidate.episode
                )
            }
            .sorted {
                $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season
            }
    }

    private func markCatchUpEpisodesWatched() {
        let episodesToMark = pendingCatchUpEpisodes
        pendingCatchUpEpisodes = []
        guard !episodesToMark.isEmpty else { return }
        // Grouped per season so each write covers a whole season at once
        // rather than re-encoding the store for every episode.
        let bySeason = Dictionary(grouping: episodesToMark, by: \.season)
        for (season, videos) in bySeason {
            WatchedStore.setSeasonWatched(
                meta: meta,
                season: season,
                episodes: videos.map(\.episode),
                isWatched: true
            )
        }
        watchedEpisodeKeys = WatchedStore.watchedEpisodeKeys(meta: meta)
    }

    private func materializedEpisodeIndices(visibleCardCount: Int) -> [Int] {
        guard !seasonEpisodes.isEmpty else { return [] }
        let focusIndex = min(max(episodeScrollIndex, 0), seasonEpisodes.count - 1)
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = min(seasonEpisodes.count - 1, focusIndex + visibleCardCount + 2)

        if let restriction = effectiveFocusRestriction {
            let prefix = "episode-card\u{1}"
            if restriction.hasPrefix(prefix) {
                let targetID = String(restriction.dropFirst(prefix.count))
                if let targetIndex = seasonEpisodes.firstIndex(where: { $0.id == targetID }) {
                    lowerBound = min(lowerBound, targetIndex)
                    upperBound = max(upperBound, targetIndex)
                }
            }
        }

        return Array(lowerBound...upperBound)
    }

    private var episodeCardStrip: some View {
        GeometryReader { geo in
            let edgeInset = max(0, geo.frame(in: .global).minX)
            let stripWidth = geo.size.width + edgeInset * 2
            let visibleCardCount = max(1, Int(ceil(stripWidth / TvEpisodeCardLayout.step)) + 1)
            let materializedIndices = materializedEpisodeIndices(visibleCardCount: visibleCardCount)

            HStack(alignment: .bottom, spacing: TvEpisodeCardLayout.spacing) {
                ForEach(materializedIndices, id: \.self) { itemIndex in
                    let video = seasonEpisodes[itemIndex]
                    TvEpisodeCard(
                        video: video,
                        fallbackRating: seriesRating,
                        continueProgress: continueProgress(for: video),
                        isWatched: watchedEpisodeKeys.contains("\(video.season):\(video.episode)"),
                        isSeasonWatched: isSeasonWatched,
                        onFocus: {
                            episodeScrollIndex = itemIndex
                            onFocus()
                        },
                        onToggleWatched: {
                            let nowWatched = WatchedStore.toggleEpisode(
                                meta: meta,
                                season: video.season,
                                episode: video.episode
                            )
                            // Only offer catch-up when marking watched. The
                            // episode the viewer picked is marked either way —
                            // Cancel declines the extras, it does not undo the
                            // action they actually took.
                            guard nowWatched else { return }
                            let earlier = unwatchedEpisodesBefore(video)
                            guard !earlier.isEmpty else { return }
                            pendingCatchUpEpisodes = earlier
                            showCatchUpPrompt = true
                        },
                        onToggleSeasonWatched: {
                            WatchedStore.setSeasonWatched(
                                meta: meta,
                                season: selectedSeason,
                                episodes: seasonEpisodes.map(\.episode),
                                isWatched: !isSeasonWatched
                            )
                        },
                        onMenuOpened: { onEpisodeMenuPresented(true) },
                        onMenuClosed: { onEpisodeMenuPresented(false) },
                        action: { onSelect(video) },
                        onPlayManually: onPlayManually != nil ? { onPlayManually?(video) } : nil,
                        smartStreamSelection: smartStreamSelection,
                        focus: episodeFocus,
                        restrictFocusToKey: effectiveFocusRestriction,
                        onMoveDown: onMoveDownFromEpisode,
                        onMoveUp: seasons.count <= 1 ? onMoveUpFromSeason : nil
                    )
                }
            }
            .padding(.leading, CGFloat(materializedIndices.first ?? 0) * TvEpisodeCardLayout.step)
            .padding(.vertical, TvEpisodeCardLayout.verticalPadding)
            .offset(x: edgeInset - CGFloat(episodeScrollIndex) * TvEpisodeCardLayout.step)
            .frame(width: stripWidth, height: TvEpisodeCardLayout.stripHeight, alignment: .leading)
            // Match the cast rail: episode cards may draw through the details
            // column up to the screen edge instead of being cut off early.
            .offset(x: -edgeInset)
            // Critically damped — same no-bounce Home strip feel.
            .animation(smoothFocus ? .spring(response: 0.3, dampingFraction: 1.0) : nil, value: episodeScrollIndex)
        }
        .frame(height: TvEpisodeCardLayout.stripHeight)
    }

    @ViewBuilder
    private var seasonSelector: some View {
        if seasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(seasons, id: \.self) { season in
                        TvSeasonPill(
                            title: seasonTitle(season),
                            isSelected: season == selectedSeason,
                            onFocus: onFocus,
                            onMoveUp: onMoveUpFromSeason,
                            action: {
                                userDidSelectSeason = true
                                selectedSeason = season
                                episodeScrollIndex = 0
                            }
                        )
                    }
                }
                .padding(.trailing, 96)
                .padding(.vertical, 8)
            }
            .scrollClipDisabledIfAvailable()
            // The pills are the strip's other focus target, and the one the
            // engine picked when an episode's picker closed.
            .disabled(effectiveFocusRestriction != nil)
        } else {
            Text(seasonTitle(selectedSeason))
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 34)
                .frame(height: 70)
                .background(Color.white, in: Capsule())
        }
    }

    private var seasons: [Int] {
        Array(Set(episodes.map(\.season))).sorted {
            (seasonSortKey($0), $0) < (seasonSortKey($1), $1)
        }
    }

    private var effectiveFocusRestriction: String? {
        if let restrictFocusToKey { return restrictFocusToKey }
        guard entryLocked, !seasonEpisodes.isEmpty else { return nil }
        let index = min(max(episodeScrollIndex, 0), seasonEpisodes.count - 1)
        return TvEpisodeFocus.card(seasonEpisodes[index].id)
    }

    /// A season counts as watched only when every episode in it is, which is
    /// what makes the menu item a genuine toggle rather than a re-mark.
    private var isSeasonWatched: Bool {
        !seasonEpisodes.isEmpty && seasonEpisodes.allSatisfy {
            watchedEpisodeKeys.contains("\(selectedSeason):\($0.episode)")
        }
    }

    private static func defaultSeason(_ episodes: [NuvioVideo]) -> Int {
        let seasons = Array(Set(episodes.map(\.season))).sorted {
            (seasonSortKey($0), $0) < (seasonSortKey($1), $1)
        }
        return seasons.first(where: { $0 > 0 }) ?? seasons.first ?? 1
    }

    /// Open a series where viewing actually left off. Continue Watching / Up
    /// Next is authoritative; if it is unavailable, advance one episode beyond
    /// the latest watched entry (or keep the last entry when the series is done).
    private static func initialEpisode(
        episodes: [NuvioVideo],
        continueItem: ContinueWatchingItem?,
        watchedKeys: Set<String>
    ) -> NuvioVideo? {
        let ordered = episodes.sorted {
            (seasonSortKey($0.season), $0.episode)
                < (seasonSortKey($1.season), $1.episode)
        }

        if let numbers = continueItem?.episodeNumbers,
           let progressEpisode = ordered.first(where: {
               $0.season == numbers.season && $0.episode == numbers.episode
           }) {
            return progressEpisode
        }

        guard let latestWatchedIndex = ordered.lastIndex(where: {
            watchedKeys.contains("\($0.season):\($0.episode)")
        }) else {
            return nil
        }

        if latestWatchedIndex + 1 < ordered.count,
           let nextEpisode = ordered[(latestWatchedIndex + 1)...].first(where: {
               !watchedKeys.contains("\($0.season):\($0.episode)")
           }) {
            return nextEpisode
        }
        return ordered[latestWatchedIndex]
    }

    private func seasonTitle(_ season: Int) -> String {
        season <= 0 ? "Specials" : "Season \(season)"
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    private func seasonSortKey(_ season: Int) -> Int {
        Self.seasonSortKey(season)
    }

    private func continueProgress(for video: NuvioVideo) -> Double? {
        guard let continueItem,
              !continueItem.isUpNextEntry,
              let numbers = continueItem.episodeNumbers,
              numbers.season == video.season,
              numbers.episode == video.episode else {
            return nil
        }
        return continueItem.progress
    }
}

/// Focus keys for episode cards in the strip.
private enum TvEpisodeFocus {
    static func card(_ videoID: String) -> String { "episode-card\u{1}\(videoID)" }
}

private enum TvEpisodeCardLayout {
    static let width: CGFloat = 660
    static let height: CGFloat = 430
    static let spacing: CGFloat = 40
    static let verticalPadding: CGFloat = 28
    static let stripHeight: CGFloat = height + verticalPadding * 2
    static let step: CGFloat = width + spacing
}

private struct TvSeasonPill: View {
    let title: String
    let isSelected: Bool
    let onFocus: () -> Void
    let onMoveUp: () -> Void
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(isSelected || isFocused ? .black : .white.opacity(0.66))
                .padding(.horizontal, 30)
                .frame(height: 70)
                .modifier(TvDetailsGlassBackground(filled: isSelected || isFocused, shape: Capsule()))
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
        }
        #if !os(macOS)
        // Nudges the tvOS focus engine off the pills. On macOS it would eat an
        // arrow the page's own handler needs.
        .onMoveCommand { direction in
            if direction == .up {
                onMoveUp()
            }
        }
        #endif
    }
}

private struct TvEpisodeCard: View {
    @AppStorage(SettingsKey.blurUnwatchedArtwork) private var blurUnwatchedArtwork = false
    let video: NuvioVideo
    let fallbackRating: Double?
    let continueProgress: Double?
    let isWatched: Bool
    let isSeasonWatched: Bool
    let onFocus: () -> Void
    let onToggleWatched: () -> Void
    let onToggleSeasonWatched: () -> Void
    /// Called when a long press raises the context menu, and again when one of
    /// its items closes it — see the `.contextMenu` below.
    let onMenuOpened: () -> Void
    let onMenuClosed: () -> Void
    let action: () -> Void
    var onPlayManually: (() -> Void)? = nil
    var smartStreamSelection: Bool = false
    var focus: FocusState<String?>.Binding
    let restrictFocusToKey: String?
    let onMoveDown: () -> Void
    var onMoveUp: (() -> Void)? = nil

    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

    private var cardKey: String { TvEpisodeFocus.card(video.id) }

    private var isFocused: Bool { focus.wrappedValue == cardKey }

    private let cardWidth: CGFloat = TvEpisodeCardLayout.width
    private let thumbHeight: CGFloat = 300
    private let cardHeight: CGFloat = TvEpisodeCardLayout.height

    private var episodeCornerRadius: CGFloat {
        AppCardStyle.episodeCornerRadius(for: cardCornerRadiusSetting)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: episodeCornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                episodeArtwork

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black.opacity(0.0), location: 0.12),
                        .init(color: .black.opacity(0.28), location: 0.46),
                        .init(color: .black.opacity(0.78), location: 0.78),
                        .init(color: .black.opacity(0.94), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.format("details_episode_number", fallback: "EPISODE %d", video.episode))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if liquidGlassCards {
                                Capsule()
                                    .fill(Color.white.opacity(0.14))
                                    .modifier(LiquidGlassBadgeModifier(cornerRadius: 16))
                            } else {
                                Capsule()
                                    .fill(Color.black.opacity(0.52))
                            }
                        }

                    Text(video.title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let overview = video.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.white.opacity(0.78))
                            .lineSpacing(4)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 8) {
                        if let ratingText {
                            Text("IMDb")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white.opacity(0.78))
                            Text(ratingText)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(Color(red: 0.96, green: 0.77, blue: 0.22))
                        }

                        Spacer(minLength: 12)

                        if let dateText {
                            Text(dateText)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white.opacity(0.62))
                        }
                    }
                }
                .padding(EdgeInsets(top: 24, leading: 24, bottom: continueProgress == nil ? 24 : 44, trailing: 24))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                    continueProgressOverlay
                }
                .frame(width: cardWidth, height: cardHeight)
                .background {
                    if liquidGlassCards {
                        #if os(tvOS) || os(macOS)
                        if #available(tvOS 26.0, macOS 26.0, *) {
                            shape
                                .fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                                .glassEffect(.regular, in: shape)
                        } else {
                            shape
                                .fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                        }
                        #else
                        shape.fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                        #endif
                    } else {
                        shape
                            .fill(isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                    }
                }
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: episodeCornerRadius,
                        isFocused: isFocused,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(alignment: .topTrailing) {
                    if isWatched {
                        WatchedCheckmarkIcon()
                    }
                }
                .overlay(
                    shape.stroke(
                        isFocused ? AppFocusOutline.color : Color.clear,
                        lineWidth: isFocused ? AppFocusOutline.width : 0
                    )
                )
                .shadow(
                    color: Color.black.opacity(isFocused ? 0.45 : 0.22),
                    radius: isFocused ? 20 : 10,
                    y: isFocused ? 14 : 6
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .nuvioFocusable()
            .focused(focus, equals: cardKey)
            .focusEffectDisabledIfAvailable()
            .disabled(restrictFocusToKey != nil && restrictFocusToKey != cardKey)
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused { onFocus() }
            }
            // tvOS delivers the Menu press that dismisses a context menu to the
            // view behind it as well, which backs Details out to Home. Telling
            // the screen a menu is up lets it swallow exactly that one press.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    onMenuOpened()
                }
            )
            .contextMenu {
                if smartStreamSelection, let onPlayManually {
                    Button {
                        performAfterMenuDismissal(onPlayManually)
                    } label: {
                        Label(
                            L10n.string("action_select_stream_manually", fallback: "Choose Source Manually"),
                            systemImage: "list.bullet"
                        )
                    }
                }

                Button {
                    performAfterMenuDismissal(onToggleWatched)
                } label: {
                    Label(
                        isWatched
                            ? L10n.string("details_mark_as_unwatched", fallback: "Mark as unwatched")
                            : L10n.string("details_mark_as_watched", fallback: "Mark as watched"),
                        systemImage: isWatched ? "eye.slash.fill" : "eye.fill"
                    )
                }

                Button {
                    performAfterMenuDismissal(onToggleSeasonWatched)
                } label: {
                    Label(
                        isSeasonWatched
                            ? L10n.string("details_mark_season_as_unwatched", fallback: "Mark season as unwatched")
                            : L10n.string("details_mark_season_as_watched", fallback: "Mark season as watched"),
                        systemImage: isSeasonWatched ? "eye.slash" : "eye"
                    )
                }
            }
        }
        #if !os(macOS)
        .onMoveCommand { direction in
            if direction == .down {
                onMoveDown()
            } else if direction == .up {
                onMoveUp?()
            }
        }
        #endif
    }

    /// A native tvOS context-menu action runs before the menu's presentation
    /// transaction has finished. Rebuilding the episode rail from a watched
    /// notification in that transaction produces SwiftUI's
    /// `setPresentationValue`/menu-lock warnings, so commit on the next settled
    /// main-loop turn instead.
    private func performAfterMenuDismissal(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onMenuClosed()
            action()
        }
    }

    private var episodeArtwork: some View {
        // Episode stills routinely spoil the episode they belong to, so an
        // unwatched one can be blurred out. Watched episodes are never blurred
        // — there is nothing left to spoil.
        let shouldBlur = blurUnwatchedArtwork && !isWatched
        return CachedPosterArtwork(
            urlString: video.thumbnail,
            width: cardWidth,
            height: cardHeight,
            placeholder: { placeholderThumb }
        )
        .frame(width: cardWidth, height: cardHeight)
        .blur(radius: shouldBlur ? 22 : 0)
        // Blur samples past the frame, so clip after it or the haze bleeds
        // over neighbouring cards.
        .clipped()
        .overlay {
            if shouldBlur {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var continueProgressOverlay: some View {
        if let continueProgress {
            let progress = CGFloat(min(max(continueProgress, 0), 1))
            GeometryReader { geo in
                let width = max(0, geo.size.width - 48)

                VStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.36))
                            .frame(width: width, height: 8)

                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(8, width * progress), height: 8)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var placeholderThumb: some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: "film")
                .font(.system(size: 52, weight: .regular))
                .foregroundColor(.white.opacity(0.28))
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(video.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            if let overview = video.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
                    .lineSpacing(4)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let ratingText {
                    Text("IMDb")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white.opacity(0.78))
                    Text(ratingText)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color(red: 0.96, green: 0.77, blue: 0.22))
                }

                Spacer(minLength: 12)

                if let dateText {
                    Text(dateText)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(22)
        .frame(width: cardWidth, height: 232, alignment: .topLeading)
    }

    private var ratingText: String? {
        if let r = video.rating?.trimmingCharacters(in: .whitespaces), !r.isEmpty {
            return r
        }
        if let fb = fallbackRating {
            return String(format: "%.1f", fb)
        }
        return nil
    }

    private var dateText: String? {
        if let formatted = NuvioDateDisplay.formattedDate(video.released) {
            return formatted
        }
        return L10n.string("details_date_tbd", fallback: "TBD")
    }
}

struct TvDetailsGlassBackground<S: InsettableShape>: ViewModifier {
    let filled: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled {
            if #available(tvOS 26.0, macOS 26.0, *) {
                content
                    .background(Color.white.opacity(0.96), in: shape)
                    .glassEffect(.regular, in: shape)
            } else {
                content.background(Color.white, in: shape)
            }
        } else if #available(tvOS 26.0, macOS 26.0, *) {
            content
                .background(Color.white.opacity(0.10), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Translucent "liquid glass" fill used by the stream picker panel and cards.
/// Uses real Liquid Glass on tvOS 26+, falling back to a frosted material with
/// a matching tint on older systems so the look stays consistent.
private struct TvStreamGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, macOS 26.0, *) {
            content
                .background(tint, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(tint, in: shape)
        }
    }
}

// The stream picker is a tvOS-only screen: macOS lists the same streams in
// the details rail, so nothing here is reachable there.
#if os(tvOS)
private struct TvStreamPickerOverlay: View {
    let meta: NuvioMeta
    let episode: NuvioVideo?
    let streams: [NuvioStream]
    let groups: [AddonStreamGroup]
    let streamsRevision: UInt64
    let isLoading: Bool
    let emptyReason: StreamsEmptyStateReason?
    /// Whether torrent-only streams should be listed (a debrid provider is set).
    let includeDebrid: Bool
    /// A torrent stream is being turned into a playable link right now.
    let isResolvingDebrid: Bool
    let onSelect: (NuvioStream, ExternalPlayer?) -> Void
    let onDismiss: () -> Void

    /// Filter by stable add-on id (not display name).
    @State private var selectedAddonId: String?
    @AppStorage(SettingsKey.streamSortOption) private var sortOption: StreamSortOption = .quality
    @State private var showSortOptions = false
    @AppStorage(SettingsKey.cachedOnlyStreams) private var cachedOnly = false
    /// Cached filter+sort result. Rebuilt only when derivation inputs change —
    /// never when focus moves between cards.
    @State private var displayedStreams: [NuvioStream] = []
    @State private var displayedStreamsCacheKey: StreamPickerListCacheKey?
    /// Badge matching is regex-heavy, so derive it with the stream-list cache
    /// instead of from SwiftUI card initializers during focus updates.
    @State private var streamCardPresentations: [String: TvStreamCardPresentation] = [:]
    @State private var streamBadgeSettingsRevision: UInt64 = 0
    // A single focus state for the whole picker (filter chips + stream cards),
    // keyed by string. Filter chips use the "filter::" prefix; stream cards use
    // their natural id. One shared state makes programmatic focus moves reliable
    // and lets us seed focus on appear so the picker is never in limbo.
    @FocusState private var focusedItem: String?
    /// Whether focus has been handed to a stream card yet. The picker usually
    /// mounts while discovery is still running, so the first seed can only land
    /// on the All chip; this drives the hand-off once results exist, once.
    @State private var didSeedStreamFocus = false
    @State private var streamBadgeSettings = StreamBadgeSettingsStore.snapshot
    @AppStorage(SettingsKey.streamResolutionFilter)
    private var resolutionFilter: StreamResolutionFilter = .any
    @State private var showResolutionOptions = false
    @State private var showProviderOptions = false

    private let filterAllKey = "filter::all"
    private let resolutionKey = "filter::resolution"
    private let sortKey = "filter::sort"
    private let cachedKey = "filter::cached"
    private func filterKey(_ addonId: String) -> String { "filter::\(addonId)" }

    /// Inputs that may change the visible stream list (not focus).
    private var listCacheKey: StreamPickerListCacheKey {
        StreamPickerListBuilder.cacheKey(
            revision: streamsRevision,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly,
            resolutionFilter: resolutionFilter
        )
    }

    private var streamCardPresentationCacheKey: TvStreamCardPresentationCacheKey {
        TvStreamCardPresentationCacheKey(
            listKey: displayedStreamsCacheKey,
            badgeSettingsRevision: streamBadgeSettingsRevision
        )
    }

    var body: some View {
        GeometryReader { proxy in
            // Keep the picker anchored to a stable top inset. A centered stack
            // can be displaced when tvOS gives the full-screen cover an
            // oversized height while its focus hierarchy is settling; that
            // leaves the filters and the first stream card below the viewport.
            let canvasWidth = min(proxy.size.width, 1_920)
            let canvasHeight = min(proxy.size.height, 1_080)
            let summaryWidth = min(canvasWidth * 0.34, 620)
            let panelWidth = min(canvasWidth * 0.56, 1_080)
            let panelHeight = min(max(canvasHeight - 300, 440), 720)
            let panelStackHeight = panelHeight + 118

            ZStack {
                TvDetailsBackdrop(meta: meta)

                // The summary and picker are independent layers. Their former
                // shared HStack let the summary's async logo/intrinsic height
                // move the picker during tvOS focus layout.
                leftSummary
                    .frame(width: summaryWidth, alignment: .leading)
                    .position(
                        x: 96 + summaryWidth / 2,
                        y: canvasHeight * 0.425
                    )

                VStack(alignment: .leading, spacing: 28) {
                    filterRow
                        // A horizontal ScrollView has no intrinsic cross-axis
                        // size, so constrain it independently of focus changes.
                        .frame(height: 90)

                    streamPanel
                        .frame(
                            width: panelWidth,
                            height: panelHeight
                        )
                }
                .frame(width: panelWidth, height: panelStackHeight, alignment: .top)
                .position(
                    x: canvasWidth - 64 - panelWidth / 2,
                    y: 168 + panelStackHeight / 2
                )

            }
            // The picker mounts before discovery finishes, so this seed usually
            // lands on the All chip; seedStreamFocusIfNeeded hands focus to the
            // first card once results exist.
            .onAppear {
                refreshDisplayedStreamsIfNeeded()
                seedInitialFocus()
            }
            // Progressive add-on results, filter chips, sort, and debrid toggle
            // all flow through this cache key. Focus is excluded.
            .onChange(of: listCacheKey) { _, _ in
                refreshDisplayedStreamsIfNeeded()
                seedStreamFocusIfNeeded()
            }
            // The focus engine can still reject the seed after grabFocus reads
            // back its own write and stops retrying — e.g. the panel's loading
            // spinner keeps real focus while it fades out, then its removal
            // makes the engine re-resolve and write nil into this binding,
            // visibly un-highlighting the first card. If focus evaporates while
            // the picker is up, grab it again — but only if it's *still* gone
            // after a beat. A fast scroll blips `focusedItem` to nil between
            // cards before landing on the next one; re-seeding on that blip
            // snaps focus back to the first stream (the reported bug), so we
            // debounce and bail when focus has already landed somewhere.
            .onChange(of: focusedItem) { _, newValue in
                guard newValue == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if focusedItem == nil {
                        seedInitialFocus()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: StreamBadgeSettingsStore.changedNotification)) { _ in
                streamCardPresentations.removeAll(keepingCapacity: true)
                streamBadgeSettings = StreamBadgeSettingsStore.snapshot
                streamBadgeSettingsRevision &+= 1
            }
            .onExitCommand(perform: onDismiss)
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: streamCardPresentationCacheKey, priority: .utility) {
            await rebuildStreamCardPresentations()
        }
    }

    /// Rendering always uses the cached list. A progressive source revision may
    /// leave it one SwiftUI update behind while `onChange` refreshes the cache,
    /// which is preferable to repeating the full filter pass during body layout.
    private var activeDisplayedStreams: [NuvioStream] {
        displayedStreams
    }

    /// Rebuilds the cached list only when derivation inputs actually change.
    private func refreshDisplayedStreamsIfNeeded() {
        let key = listCacheKey
        guard key != displayedStreamsCacheKey else { return }
        let refreshedStreams = StreamPickerListBuilder.displayedStreams(
            streams: streams,
            groups: groups,
            selectedAddonId: selectedAddonId,
            sortOption: sortOption,
            includeDebrid: includeDebrid,
            cachedOnly: cachedOnly,
            resolutionFilter: resolutionFilter
        )
        displayedStreams = refreshedStreams
        displayedStreamsCacheKey = key
    }

    @MainActor
    private func rebuildStreamCardPresentations() async {
        let cacheKey = streamCardPresentationCacheKey
        let streamsToBuild = activeDisplayedStreams
        let settings = streamBadgeSettings
        let missingStreams = streamsToBuild.filter {
            streamCardPresentations[$0.id] == nil
        }
        guard !missingStreams.isEmpty else { return }

        // Preserve completed cards as add-ons publish progressively. Larger
        // batches reduce whole-overlay SwiftUI invalidations while still giving
        // cancellation a chance between chunks when a new revision arrives.
        for startIndex in stride(from: 0, to: missingStreams.count, by: 16) {
            guard !Task.isCancelled else { return }
            let endIndex = min(startIndex + 16, missingStreams.count)
            let batch = Array(missingStreams[startIndex..<endIndex])
            let batchPresentations = await TvStreamCardPresentationBuilder.shared.build(
                streams: batch,
                settings: settings
            )
            guard !Task.isCancelled,
                  cacheKey == streamCardPresentationCacheKey else { return }
            var updatedPresentations = streamCardPresentations
            updatedPresentations.merge(batchPresentations) { _, new in new }
            streamCardPresentations = updatedPresentations
        }
    }

    private var leftSummary: some View {
        VStack(alignment: .leading, spacing: 34) {
            TvDetailsLogo(meta: meta)

            if let episode {
                VStack(spacing: 14) {
                    Text(L10n.format("details_season_episode", fallback: "Season %1$d · Episode %2$d", episode.season, episode.episode))
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.white)

                    Text(episode.title)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .lineSpacing(6)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .frame(width: 560, alignment: .center)
            } else if !summaryItems.isEmpty {
                Text(summaryItems.joined(separator: "  •  "))
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .frame(width: 560, alignment: .center)
            }
        }
    }

    /// Label for the provider dropdown: the chosen add-on, or All.
    private var selectedProviderLabel: String {
        guard let selectedAddonId else {
            return L10n.string("action_all", fallback: "All")
        }
        return filterGroups.first { $0.addonId == selectedAddonId }?.displayName
            ?? L10n.string("action_all", fallback: "All")
    }

    private var filterRow: some View {
        HStack(spacing: 18) {
            // A dropdown rather than a chip scroller: the provider list grows
            // with every installed add-on, and a long row pushed the sort and
            // filter controls off the edge.
            TvStreamFilterButton(
                title: L10n.format(
                    "details_provider_format",
                    fallback: "Provider: %@",
                    selectedProviderLabel
                ),
                isSelected: selectedAddonId != nil,
                focusBinding: $focusedItem,
                focusValue: filterAllKey,
                action: { showProviderOptions = true }
            )
            .fixedSize(horizontal: true, vertical: false)
            .confirmationDialog(
                L10n.string("details_filter_provider", fallback: "Provider"),
                isPresented: $showProviderOptions,
                titleVisibility: .visible
            ) {
                Button(L10n.string("action_all", fallback: "All")) {
                    selectedAddonId = nil
                }
                // Preserve configured add-on order from discovery groups.
                ForEach(filterGroups) { group in
                    Button(group.isLoading ? "\(group.displayName)…" : group.displayName) {
                        selectedAddonId = group.addonId
                    }
                }
            }

            Spacer(minLength: 0)

            if includeDebrid {
                TvStreamFilterButton(
                    title: cachedOnly
                        ? L10n.string("details_cached_only", fallback: "Cached only")
                        : L10n.string("details_all_cache", fallback: "All cache"),
                    isSelected: cachedOnly,
                    focusBinding: $focusedItem,
                    focusValue: cachedKey,
                    action: { cachedOnly.toggle() }
                )
                .fixedSize(horizontal: true, vertical: false)
            }

            TvStreamFilterButton(
                title: L10n.format(
                    "details_resolution_format",
                    fallback: "Res: %@",
                    resolutionFilter.title
                ),
                isSelected: resolutionFilter != .any,
                focusBinding: $focusedItem,
                focusValue: resolutionKey,
                action: { showResolutionOptions = true }
            )
            .fixedSize(horizontal: true, vertical: false)
            .confirmationDialog(
                L10n.string("details_filter_resolution", fallback: "Resolution"),
                isPresented: $showResolutionOptions,
                titleVisibility: .visible
            ) {
                ForEach(StreamResolutionFilter.allCases) { option in
                    Button(option.title) { resolutionFilter = option }
                }
            }

            // Sort remains pinned to the trailing edge instead of moving with
            // the add-on scroller.
            TvStreamFilterButton(
                title: L10n.format("details_sort_format", fallback: "Sort: %@", L10n.optionLabel(sortOption.rawValue)),
                isSelected: sortOption != .quality,
                focusBinding: $focusedItem,
                focusValue: sortKey,
                action: { showSortOptions = true }
            )
            .fixedSize(horizontal: true, vertical: false)
            .confirmationDialog(
                L10n.string("details_sort_streams_by", fallback: "Sort streams by"),
                isPresented: $showSortOptions,
                titleVisibility: .visible
            ) {
                ForEach(StreamSortOption.allCases) { option in
                    Button(L10n.optionLabel(option.rawValue)) { sortOption = option }
                }
            }
        }
        .padding(.vertical, 4)
        .focusSection()
    }

    private var streamPanel: some View {
        // Resolve once per panel body — focus changes hit the cache path only.
        let streamsToShow = activeDisplayedStreams
        let badgeSettings = streamBadgeSettings
        return ZStack {
            if isLoading && streamsToShow.isEmpty && selectedGroupError == nil {
                VStack(spacing: 24) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.6)

                    Text(L10n.string("details_finding_streams", fallback: "Finding streams"))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white.opacity(0.74))
                }
            } else if streamsToShow.isEmpty {
                VStack(spacing: 18) {
                    if selectedGroupIsLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.4)
                        Text(L10n.format("details_checking_addon", fallback: "Checking %@…", selectedGroupName))
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white.opacity(0.74))
                    } else {
                        Image(systemName: "play.slash")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundColor(.white.opacity(0.64))

                        Text(emptyPanelTitle)
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(.white.opacity(0.78))
                            .multilineTextAlignment(.center)

                        if let detail = emptyPanelDetail {
                            Text(detail)
                                .font(.system(size: 26, weight: .regular))
                                .foregroundColor(.white.opacity(0.55))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(.horizontal, 40)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 28) {
                        ForEach(streamsToShow) { stream in
                            // Focus appearance is owned by the card via local
                            // @FocusState + ExternalFocusBinding so only the
                            // old/new cards pay for outline/scale updates.
                            TvStreamCard(
                                stream: stream,
                                presentation: streamCardPresentations[stream.id]
                                    ?? TvStreamCardPresentation(pending: badgeSettings),
                                externalFocus: $focusedItem,
                                action: { onSelect(stream, nil) },
                                onSelectPlayer: { player in onSelect(stream, player) }
                            )
                        }

                        if isLoading {
                            HStack(spacing: 18) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text(L10n.string("details_checking_more_addons", fallback: "Checking more add-ons…"))
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundColor(.white.opacity(0.62))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                        }
                    }
                    .padding(40)
                }
                .focusSection()
            }

            // Torrent streams take a moment to cache/unrestrict on the debrid
            // provider; cover the panel so it doesn't look frozen.
            if isResolvingDebrid {
                VStack(spacing: 24) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.6)

                    Text(L10n.string("details_preparing_stream", fallback: "Preparing stream"))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white.opacity(0.74))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.55))
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keep outer panel Liquid Glass; cards use a cheap solid/material fill.
        .modifier(TvStreamGlass(shape: RoundedRectangle(cornerRadius: 32, style: .continuous), tint: Color.black.opacity(0.22)))
        // Clip the scrolling content to the panel so partial cards stay inside
        // the box (no overflow below it) until the user scrolls.
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    /// Groups shown as filter chips (configured order; includes loading/error).
    private var filterGroups: [AddonStreamGroup] {
        if !groups.isEmpty { return groups }
        // Fallback when only a flat stream list is available (mock path).
        let names = Array(Set(streams.compactMap(\.addonName))).sorted()
        return names.map { name in
            AddonStreamGroup(
                addonId: name,
                displayName: name,
                streams: streams.filter { $0.addonName == name },
                isLoading: false
            )
        }
    }

    private var selectedGroup: AddonStreamGroup? {
        selectedAddonId.flatMap { id in groups.first(where: { $0.addonId == id }) }
    }

    private var selectedGroupIsLoading: Bool {
        selectedGroup?.isLoading == true
    }

    private var selectedGroupName: String {
        selectedGroup?.displayName ?? L10n.string("details_addon_fallback", fallback: "add-on")
    }

    private var selectedGroupError: String? {
        selectedGroup?.error
    }

    private var emptyPanelTitle: String {
        if let selectedGroup {
            if selectedGroup.error != nil {
                return L10n.format("details_addon_failed", fallback: "%@ failed", selectedGroup.displayName)
            }
            return L10n.format("details_no_streams_from_addon", fallback: "No streams from %@", selectedGroup.displayName)
        }
        switch emptyReason {
        case .noAddonsConfigured:
            return L10n.string("details_no_stream_addons_configured", fallback: "No stream add-ons configured")
        case .noCompatibleAddons:
            return L10n.string("details_no_compatible_addons", fallback: "No compatible add-ons")
        case .noStreamsFound, .none:
            return isLoading
                ? L10n.string("details_finding_streams", fallback: "Finding streams")
                : L10n.string("details_no_playable_streams_found", fallback: "No playable streams found")
        }
    }

    private var emptyPanelDetail: String? {
        if let error = selectedGroupError {
            return error
        }
        switch emptyReason {
        case .noAddonsConfigured:
            return L10n.string("details_enable_stream_addon_settings", fallback: "Enable a stream add-on in Settings.")
        case .noCompatibleAddons:
            return L10n.string("details_addons_do_not_support_title", fallback: "Installed add-ons do not support this title.")
        case .noStreamsFound:
            return isLoading ? nil : L10n.string("details_try_another_addon_later", fallback: "Try another add-on or check back later.")
        case .none:
            return nil
        }
    }

    private var summaryItems: [String] {
        var items = Array((meta.genres ?? []).prefix(3))
        if let year = meta.year {
            items.append(String(year))
        }
        return items
    }

    /// Seeds focus when the picker appears. The picker is only mounted once
    /// streams are available, so this first appearance is a fresh focus
    /// transition where tvOS hasn't committed focus yet — setting `focusedItem`
    /// here wins, landing on the first stream (or the "All" chip if none).
    private func seedInitialFocus() {
        DispatchQueue.main.async {
            refreshDisplayedStreamsIfNeeded()
            if let firstID = activeDisplayedStreams.first?.id {
                didSeedStreamFocus = true
                grabFocus(firstID, attempt: 0)
            } else {
                grabFocus(filterAllKey, attempt: 0)
            }
        }
    }

    /// Hands focus to the first stream once discovery produces one, for the
    /// common case where the picker opened empty and had to seed the All chip.
    ///
    /// Runs once. Anything the user did in the meantime wins: if focus has moved
    /// off the chip the picker itself seeded — another add-on, sort, or a card
    /// that arrived earlier — the hand-off is dropped rather than yanking focus
    /// out from under them mid-scroll.
    private func seedStreamFocusIfNeeded() {
        guard !didSeedStreamFocus,
              let firstID = activeDisplayedStreams.first?.id else { return }
        didSeedStreamFocus = true
        guard focusedItem == nil || focusedItem == filterAllKey else { return }
        grabFocus(firstID, attempt: 0)
    }

    /// Asserts focus on `id` and retries for a short window, because the target
    /// view may not be hit-testable on the very first runloop tick after it
    /// renders. `id` is captured by value (never reads a stale `streams`), and
    /// it stops the moment focus lands.
    private func grabFocus(_ id: String, attempt: Int) {
        if focusedItem == id { return }
        focusedItem = id
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            grabFocus(id, attempt: attempt + 1)
        }
    }
}

private struct TvStreamFilterButton: View {
    let title: String
    let isSelected: Bool
    let focusBinding: FocusState<String?>.Binding
    let focusValue: String
    let action: () -> Void

    private var isFocused: Bool { focusBinding.wrappedValue == focusValue }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(isSelected || isFocused ? .black : .white.opacity(0.62))
                .padding(.horizontal, 26)
                .frame(height: 58)
                .modifier(TvDetailsGlassBackground(filled: isSelected || isFocused, shape: Capsule()))
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused(focusBinding, equals: focusValue)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}

private struct TvStreamCardPresentationCacheKey: Equatable {
    let listKey: StreamPickerListCacheKey?
    let badgeSettingsRevision: UInt64
}

private struct TvStreamCardPresentation {
    let importedBadges: [StreamBadgeFilter]
    let fileSizeLabel: String?
    let releaseYear: Int?
    let badgePlacement: StreamBadgePlacement
    let showAddonLogo: Bool

    init(stream: NuvioStream, badgeSettings: StreamBadgeSettingsSnapshot) {
        releaseYear = StreamPickerListBuilder.releaseYear(for: stream)
        importedBadges = StreamBadgeMatcher.matchedBadges(
            for: stream,
            rules: badgeSettings.rules
        )
        fileSizeLabel = badgeSettings.showFileSizeBadges
            ? StreamBadgeSizing.fileSizeLabel(for: stream)
            : nil
        badgePlacement = badgeSettings.badgePlacement
        showAddonLogo = badgeSettings.showAddonLogo
    }

    init(pending badgeSettings: StreamBadgeSettingsSnapshot) {
        importedBadges = []
        fileSizeLabel = nil
        releaseYear = nil
        badgePlacement = badgeSettings.badgePlacement
        showAddonLogo = badgeSettings.showAddonLogo
    }
}

private actor TvStreamCardPresentationBuilder {
    static let shared = TvStreamCardPresentationBuilder()

    func build(
        streams: [NuvioStream],
        settings: StreamBadgeSettingsSnapshot
    ) -> [String: TvStreamCardPresentation] {
        var presentations: [String: TvStreamCardPresentation] = [:]
        presentations.reserveCapacity(streams.count)
        for stream in streams {
            guard !Task.isCancelled else { return [:] }
            presentations[stream.id] = TvStreamCardPresentation(
                stream: stream,
                badgeSettings: settings
            )
        }
        return presentations
    }
}

private struct TvStreamCard: View {
    let stream: NuvioStream
    private let importedBadges: [StreamBadgeFilter]
    private let fileSizeLabel: String?
    private let releaseYear: Int?
    private let badgePlacement: StreamBadgePlacement
    private let showAddonLogo: Bool
    let externalFocus: FocusState<String?>.Binding
    let action: () -> Void
    var onSelectPlayer: ((ExternalPlayer) -> Void)? = nil

    /// Local focus drives appearance only for this card, so focus moves do not
    /// push `isFocused` through the parent ForEach for every sibling.
    @FocusState private var isFocused: Bool

    /// Precomputed once per card identity — not re-derived on every body tick.
    private let primaryName: String
    private let secondaryName: String?

    init(
        stream: NuvioStream,
        presentation: TvStreamCardPresentation,
        externalFocus: FocusState<String?>.Binding,
        action: @escaping () -> Void,
        onSelectPlayer: ((ExternalPlayer) -> Void)? = nil
    ) {
        self.stream = stream
        self.importedBadges = presentation.importedBadges
        self.fileSizeLabel = presentation.fileSizeLabel
        self.releaseYear = presentation.releaseYear
        self.badgePlacement = presentation.badgePlacement
        self.showAddonLogo = presentation.showAddonLogo
        self.externalFocus = externalFocus
        self.action = action
        self.onSelectPlayer = onSelectPlayer
        let lines = Self.nameLines(for: stream)
        self.primaryName = lines.first ?? "Stream"
        let rest = lines.dropFirst().joined(separator: " ")
        self.secondaryName = rest.isEmpty ? nil : rest
    }

    var body: some View {
        let showImportedBadges = !importedBadges.isEmpty || fileSizeLabel != nil || releaseYear != nil

        Button(action: action) {
            HStack(alignment: .center, spacing: 34) {
                VStack(alignment: .leading, spacing: 14) {
                    if showImportedBadges && badgePlacement == .top {
                        TvStreamImportedBadgeRow(
                            badges: importedBadges,
                            fileSizeLabel: fileSizeLabel,
                            releaseYear: releaseYear,
                            isScrolling: isFocused
                        )
                    }

                    Text(primaryName)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let secondaryName {
                        Text(secondaryName)
                            .font(.system(size: 38, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let description = stream.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 26, weight: .regular))
                            .foregroundColor(.white.opacity(0.62))
                            .lineSpacing(5)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if showImportedBadges && badgePlacement == .bottom {
                        TvStreamImportedBadgeRow(
                            badges: importedBadges,
                            fileSizeLabel: fileSizeLabel,
                            releaseYear: releaseYear,
                            isScrolling: isFocused
                        )
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showAddonLogo {
                    Spacer(minLength: 28)

                    VStack(spacing: 18) {
                        addonLogo

                        if let addonName = stream.addonName {
                            Text(addonName)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(.white.opacity(0.42))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 220)
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 34)
            .frame(minHeight: 250)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Lightweight fill instead of per-card Liquid Glass (panel keeps glass).
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        isFocused ? AppFocusOutline.color : Color.white.opacity(0.10),
                        lineWidth: isFocused ? AppFocusOutline.width : 1
                    )
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: stream.id))
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.025 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .contextMenu {
            Section("Play with") {
                ForEach(ExternalPlayer.allCases) { player in
                    Button {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            onSelectPlayer?(player)
                        }
                    } label: {
                        Label(player.rawValue, systemImage: player.systemImage)
                    }
                }
            }
        }
    }

    static func nameLines(for stream: NuvioStream) -> [String] {
        let raw = stream.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = raw?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return lines.isEmpty ? ["Stream"] : lines
    }

    /// The source add-on's real logo, falling back to a neutral stream glyph
    /// (never a warning-looking one) while it loads or when the manifest has none.
    @ViewBuilder
    private var addonLogo: some View {
        let fallback = Image(systemName: "play.tv.fill")
            .font(.system(size: 62, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))

        if let logo = stream.addonLogoURL, let url = URL(string: logo) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    fallback
                default:
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 96, height: 96)
        } else {
            fallback.frame(width: 96, height: 96)
        }
    }
}

private struct TvStreamBadgeRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TvStreamImportedBadgeRow: View {
    let badges: [StreamBadgeFilter]
    let fileSizeLabel: String?
    /// Best-effort year scraped from the release name. Shown so a same-titled
    /// release from another year is obvious without the app hiding anything.
    var releaseYear: Int? = nil
    let isScrolling: Bool

    @State private var contentWidth: CGFloat = 0
    @State private var animationStart = Date()

    var body: some View {
        GeometryReader { geometry in
            ViewThatFits(in: .horizontal) {
                // `fixedSize` gives this candidate its intrinsic width. It is
                // selected unchanged when every badge fits in the viewport.
                badgeContent

                // This fallback is selected only when the intrinsic row does
                // not fit, avoiding unreliable preference-width comparisons.
                overflowContent
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .compositingGroup()
            .onAppear {
                animationStart = Date()
            }
            .onChange(of: geometry.size.width) { _, width in
                _ = width
                animationStart = Date()
            }
            .onChange(of: isScrolling) { _, _ in
                animationStart = Date()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .frame(height: 42)
        .onPreferenceChange(TvStreamBadgeRowWidthKey.self) { width in
            guard abs(width - contentWidth) > 0.5 else { return }
            contentWidth = width
            animationStart = Date()
        }
    }

    @ViewBuilder
    private var overflowContent: some View {
        if isScrolling {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let cycleWidth = max(contentWidth + 28, 1)
                let elapsed = max(0, timeline.date.timeIntervalSince(animationStart))
                let offset = CGFloat(elapsed * 70)
                    .truncatingRemainder(dividingBy: cycleWidth)

                HStack(spacing: 28) {
                    badgeContent
                    badgeContent
                }
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: -offset)
            }
        } else {
            badgeContent
        }
    }

    private var badgeContent: some View {
        HStack(spacing: 10) {
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                TvStreamImportedBadge(badge: badge)
            }

            if let releaseYear {
                Text(String(releaseYear))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
            }

            if let fileSizeLabel {
                Text(fileSizeLabel)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(Color.white.opacity(0.12))
                    )
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TvStreamBadgeRowWidthKey.self,
                    value: geometry.size.width
                )
            }
        )
    }

}

private struct TvStreamImportedBadge: View {
    let badge: StreamBadgeFilter

    var body: some View {
        Group {
            if !badge.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = URL(string: badge.imageURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        fallbackText
                    default:
                        ProgressView().tint(.white)
                    }
                }
            } else {
                fallbackText
            }
        }
        .frame(minWidth: 54, maxWidth: 150, minHeight: 30, maxHeight: 30)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(border, lineWidth: border == .clear ? 0 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var fallbackText: some View {
        Text(badge.name)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(color(from: badge.textColor) ?? .white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var background: Color {
        guard badge.tagStyle.caseInsensitiveCompare("filled") == .orderedSame,
              let color = color(from: badge.tagColor) else {
            return Color.white.opacity(0.10)
        }
        return color.opacity(0.84)
    }

    private var border: Color {
        color(from: badge.borderColor) ?? .clear
    }

    private func color(from raw: String) -> Color? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }
        let alpha: Double
        let red: Double
        let green: Double
        let blue: Double
        if value.count == 8 {
            alpha = Double((number >> 24) & 0xff) / 255
            red = Double((number >> 16) & 0xff) / 255
            green = Double((number >> 8) & 0xff) / 255
            blue = Double(number & 0xff) / 255
        } else {
            alpha = 1
            red = Double((number >> 16) & 0xff) / 255
            green = Double((number >> 8) & 0xff) / 255
            blue = Double(number & 0xff) / 255
        }
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
#endif

struct MobileDetailsContent: View {
    let uiState: DetailsUiState
    let onPlayClick: () -> Void
    let onWatchlistClick: () -> Void
    let onWatchedClick: () -> Void
    let onShareClick: () -> Void
    let onBack: () -> Void

    var body: some View {
        guard let meta = uiState.meta else { return AnyView(EmptyView()) }

        return AnyView(
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Background image with gradient
                        ZStack(alignment: .bottom) {
                            if let backgroundUrl = meta.backgroundUrl ?? meta.posterUrl {
                                AsyncImage(url: URL(string: backgroundUrl)) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.black
                                }
                                .frame(height: 400)
                                .clipped()
                            }

                            // Gradient overlay
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.black.opacity(0.6),
                                    Color.black
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 400)
                        }

                        // Content
                        VStack(alignment: .leading, spacing: 24) {
                            // Metadata info
                            MetadataInfo(meta: meta)

                            // Action buttons
                            ActionButtons(
                                onPlayClick: onPlayClick,
                                onWatchlistClick: onWatchlistClick,
                                onWatchedClick: onWatchedClick,
                                onShareClick: onShareClick,
                                isInWatchlist: uiState.isInWatchlist,
                                isWatched: uiState.isWatched
                            )

                            // Cast and Crew
                            CastCrewSection(
                                cast: meta.cast,
                                director: meta.director,
                                writer: meta.writer
                            )
                        }
                        .padding(24)
                        .background(Color.black)
                    }
                }
                .ignoresSafeArea(edges: .top)

                // Back button overlay
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.5))
                        )
                }
                .buttonStyle(.plain)
                .padding(16)
            }
        )
    }
}

struct ErrorView: View {
    let error: String
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.string("common_error", fallback: "Error"))
                .font(.title)
                .foregroundColor(.red)

            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button(L10n.string("action_retry", fallback: "Retry"), action: onRetry)
                    .buttonStyle(.borderedProminent)

                Button(L10n.string("action_go_back", fallback: "Go Back"), action: onBack)
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
    }
}

/// A band of a details page. Only macOS navigates by them, but shared view
/// signatures name the type.
///
/// The macOS page is two columns: the title's own content on the left, and a
/// rail on the right holding either the episode list or the streams for what
/// was just selected.
/// The rows of a details page, in the order they appear down the screen —
/// `allCases` order is what Up and Down walk, so it has to match the layout.
enum MacDetailsRow: Int, Hashable, CaseIterable {
    case actions
    case cast
    case related
    case network
    case production
    /// Season controls, or the stream filters.
    case railHeader
    /// Episodes, or streams.
    case railList

    var isRail: Bool { self == .railHeader || self == .railList }

    /// The rail's list is a column of items, so Up/Down walk it rather than
    /// moving to another band.
    var isVertical: Bool { self == .railList }
}

#if os(macOS)
/// Keyboard focus for a details page on macOS.
///
/// macOS has no focus engine, so — exactly as Home does — the page tracks its
/// own focused position and each control renders from it. The sections own
/// their data (the rail owns the selected season, for instance), so they
/// publish their item count and register what Return should do, and this only
/// has to know where the caret is.
@MainActor
final class MacDetailsFocus: ObservableObject {
    static let shared = MacDetailsFocus()

    @Published var row: MacDetailsRow = .actions
    @Published var index = 0
    /// Item counts, published by the section that owns each row.
    @Published private(set) var counts: [MacDetailsRow: Int] = [:]

    private var activations: [MacDetailsRow: (Int) -> Void] = [:]
    /// Where each row was last left, so moving back into one resumes it rather
    /// than restarting at its first card. Cleared with the page.
    private var lastIndexByRow: [MacDetailsRow: Int] = [:]
    /// Id of the page these counts describe.
    private var page: String?

    private init() {}

    /// A details page is being shown: forget the last one's geometry.
    ///
    /// Every section calls this before publishing, and only the first call for
    /// a page does anything. SwiftUI runs a child's `onAppear` before its
    /// parent's, so a reset the parent owned alone would wipe counts the rail
    /// had already published.
    func begin(page id: String) {
        guard page != id else { return }
        page = id
        row = .actions
        index = 0
        counts = [:]
        activations = [:]
        lastIndexByRow = [:]
    }

    func setCount(_ count: Int, for row: MacDetailsRow) {
        guard counts[row] != count else { return }
        counts[row] = count
        if row == self.row, index >= count {
            index = max(count - 1, 0)
        }
    }

    func count(for row: MacDetailsRow) -> Int { counts[row] ?? 0 }

    func register(_ row: MacDetailsRow, activate: @escaping (Int) -> Void) {
        activations[row] = activate
    }

    func isFocused(_ row: MacDetailsRow, _ index: Int) -> Bool {
        self.row == row && self.index == index
    }

    /// Rows with something in them. A movie has no rail until Play is pressed,
    /// and a single-season series publishes no season controls.
    var availableRows: [MacDetailsRow] {
        MacDetailsRow.allCases.filter { count(for: $0) > 0 }
    }

    /// Move the caret to the rail, preferring its list over its header.
    func focusRail() {
        let rail = availableRows.filter(\.isRail)
        guard let target = rail.first(where: { $0 == .railList }) ?? rail.first else { return }
        row = target
        index = 0
    }

    /// - Returns: false when the press ran off the left edge of the page, which
    ///   is the caller's cue to open the menu.
    func move(_ direction: MoveCommandDirection) -> Bool {
        let all = availableRows
        guard !all.isEmpty else { return direction != .left }
        guard all.contains(row) else {
            row = all[0]
            index = 0
            return true
        }

        let inRail = row.isRail
        let column = all.filter { $0.isRail == inRail }
        let rowIndex = column.firstIndex(of: row) ?? 0
        let count = count(for: row)

        switch direction {
        case .left:
            // Leaving the rail returns to the title's own content; leaving the
            // left column opens the menu.
            if row.isVertical || index == 0 {
                guard inRail else { return false }
                focusMainColumn(in: all)
            } else {
                index -= 1
            }
        case .right:
            if row.isVertical { break }
            if index + 1 < count {
                index += 1
            } else if !inRail {
                focusRail()
            }
        case .up:
            if row.isVertical, index > 0 {
                index -= 1
            } else if rowIndex > 0 {
                enter(column[rowIndex - 1])
            }
        case .down:
            if row.isVertical, index + 1 < count {
                index += 1
            } else if rowIndex + 1 < column.count {
                enter(column[rowIndex + 1])
            }
        @unknown default:
            break
        }
        lastIndexByRow[row] = index
        return true
    }

    /// Enters a row where it was last left, or at its start.
    private func enter(_ target: MacDetailsRow) {
        row = target
        let remembered = lastIndexByRow[target] ?? 0
        index = min(remembered, max(count(for: target) - 1, 0))
    }

    private func focusMainColumn(in rows: [MacDetailsRow]) {
        guard let target = rows.first(where: { !$0.isRail }) else { return }
        row = target
        index = 0
    }

    func activateFocused() {
        activations[row]?(index)
    }
}
#endif

#if os(macOS)
/// One choice in a stream-picker dropdown.
struct MacPickerOption {
    let label: String
    let isSelected: Bool
    let apply: () -> Void
}

struct MacPickerOptionList: Identifiable {
    let id = UUID()
    let title: String
    let options: [MacPickerOption]
}

/// A dropdown for the stream picker, drawn inside the app's canvas.
///
/// `confirmationDialog` maps to an `NSAlert` on macOS, which allows at most
/// three buttons: the provider list hid every add-on past the third — including
/// the one actually serving the streams — and Resolution lost 1080p, 720p and
/// SD without any indication. This lists everything, scrolls when long, and is
/// driven by the picker's own keyboard model.
struct MacPickerOptionsPanel: View {
    let list: MacPickerOptionList
    let highlighted: Int
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(list.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 10)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        // Keyed by label, not position: swapping one dropdown
                        // for another reuses the rows at the same indices, and
                        // position identity would let stale content stand.
                        ForEach(Array(list.options.enumerated()), id: \.element.label) { index, option in
                            row(option, isHighlighted: index == highlighted)
                                .id(option.label)
                                .onTapGesture { onSelect(index) }
                        }
                    }
                }
                .onChange(of: highlighted) { _, index in
                    guard list.options.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(list.options[index].label, anchor: .center)
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 560, maxHeight: 620)
        .background {
            if #available(macOS 26.0, *) {
                shape.fill(Color.black.opacity(0.42)).glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(16)
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ option: MacPickerOption, isHighlighted: Bool) -> some View {
        HStack(spacing: 14) {
            Text(option.label)
                .font(.system(size: 26, weight: option.isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if option.isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
            }
        }
        .foregroundColor(isHighlighted || option.isSelected ? .white : .white.opacity(0.6))
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(isHighlighted ? 0.20 : 0))
        )
        .contentShape(Rectangle())
    }
}
#endif

#if os(macOS)
/// What the details rail is showing.
enum MacRailMode: Equatable {
    case episodes
    case streams
}

enum MacRailMetrics {
    static let width: CGFloat = 560
    /// Left column's share of the canvas once the rail has its own.
    static let gutter: CGFloat = 32
}

/// The right-hand rail: a series' episodes, or the streams for whatever was
/// just selected.
///
/// tvOS shows these as full-screen steps because a 10-foot UI can only hold one
/// thing at once. On a Mac that costs a page transition per choice and leaves
/// most of the window empty, so both live beside the title instead and the rail
/// swaps between them.
struct MacDetailsRail: View {
    let mode: MacRailMode
    let title: String
    let subtitle: String?
    /// Header controls, left to right.
    let headerItems: [MacRailHeaderItem]
    let rows: [MacRailRow]
    let isLoading: Bool
    let emptyMessage: String?
    let focusedHeaderIndex: Int?
    let focusedRowIndex: Int?
    let onHeaderTap: (Int) -> Void
    let onRowTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            list
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 22)
        .frame(width: MacRailMetrics.width)
        .background {
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            if #available(macOS 26.0, *) {
                shape.fill(Color.black.opacity(0.38)).glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }

            if !headerItems.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(headerItems.enumerated()), id: \.offset) { index, item in
                        headerChip(item, isFocused: focusedHeaderIndex == index)
                            .onTapGesture { onHeaderTap(index) }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func headerChip(_ item: MacRailHeaderItem, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
            }
            if let label = item.label {
                Text(label)
                    .font(.system(size: 17, weight: item.isActive ? .semibold : .regular))
                    .lineLimit(1)
            }
        }
        .foregroundColor(isFocused || item.isActive ? .black : .white.opacity(0.7))
        .padding(.horizontal, item.label == nil ? 12 : 16)
        .frame(height: 40)
        .background(
            Capsule().fill(
                isFocused
                    ? Color.white
                    : Color.white.opacity(item.isActive ? 0.85 : 0.14)
            )
        )
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var list: some View {
        if rows.isEmpty {
            VStack(spacing: 14) {
                if isLoading {
                    BrandLoadingView(wordmarkWidth: 200)
                        .frame(height: 90)
                    Text(L10n.string("details_finding_streams", fallback: "Finding streams"))
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                } else if let emptyMessage {
                    Text(emptyMessage)
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            // Identify by the row's own id, never by position.
                            // `.id(index)` here overrode the identity ForEach
                            // had just established, so switching season or
                            // filter kept whatever view already sat at that
                            // position — the list simply never changed.
                            MacRailRowView(row: row, isFocused: focusedRowIndex == index)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onRowTap(index) }
                        }

                        if isLoading {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .controlSize(.small)
                                Text(L10n.string("details_checking_more_addons", fallback: "Checking more add-ons…"))
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.55))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: focusedRowIndex) { _, index in
                    guard let index, rows.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(rows[index].id, anchor: .center)
                    }
                }
            }
        }
    }
}

/// A rail header control and what pressing it does, kept together so the
/// caret's index and the action can never disagree.
struct MacRailHeaderEntry {
    let item: MacRailHeaderItem
    let action: () -> Void
}

struct MacRailHeaderItem {
    var symbol: String?
    var label: String?
    var isActive: Bool = false
}

/// One line in the rail. Deliberately flat data: the rail draws episodes and
/// streams the same way, which is what makes a dozen of them fit where two
/// tvOS cards used to.
struct MacRailRow: Identifiable {
    let id: String
    var thumbnailURL: URL?
    var leading: String?
    var title: String
    var subtitle: String?
    var detail: String?
    var badge: String?
    var badgeTint: Color = .white.opacity(0.2)
    var progress: Double?
}

private struct MacRailRowView: View {
    let row: MacRailRow
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let url = row.thumbnailURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 92, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let progress = row.progress, progress > 0 {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.white)
                                .frame(width: geo.size.width * min(progress, 1), height: 3)
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                    }
                }
            } else if let leading = row.leading {
                Text(leading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(width: 74)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 17, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white)

            Spacer(minLength: 8)

            if let badge = row.badge {
                Text(badge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(row.badgeTint))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.20 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isFocused ? AppFocusOutline.color : .clear, lineWidth: 2)
        )
    }
}
#endif

#if os(iOS)
import SwiftUI

/// Loads Home for the phone: the same add-on catalogs, row order and Continue
/// Watching sources as tvOS `TVHomeView`, without its focus bookkeeping.
///
/// Deliberately simpler than tvOS for now: no skeleton rows, collections,
/// SMB/Jellyfin rows or partial-load retry. Rows arrive as each add-on answers.
@MainActor
final class PhoneHomeLoader: ObservableObject {
    @Published private(set) var sections: [TVHomeSection] = []
    @Published private(set) var continueWatching: [ContinueWatchingItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: CatalogRepository = CinemetaCatalogRepository()
    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [ContinueWatchingStore.changedNotification, ContinueWatchingDismissStore.changedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshContinueWatching() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// `key` identifies the profile + catalog revision; a new key reloads.
    func load(key: String, force: Bool = false) {
        guard force || key != loadedKey else { return }
        loadedKey = key
        refreshContinueWatching()
        loadTask?.cancel()
        loadTask = Task { await loadCatalogs() }
    }

    func reload() {
        guard let loadedKey else { return }
        load(key: loadedKey, force: true)
    }

    private func loadCatalogs() async {
        isLoading = true
        errorMessage = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            for try await catalogs in repository.homeCatalogsProgressively() {
                try Task.checkCancellation()
                let built = await makeSections(from: catalogs)
                try Task.checkCancellation()
                var seen = Set<String>()
                sections = TVHomeCatalogOrder.apply(to: built)
                    .filter { !$0.items.isEmpty && seen.insert($0.id).inserted }
            }
        } catch is CancellationError {
        } catch {
            if sections.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func makeSections(from catalogs: [NuvioCatalog]) async -> [TVHomeSection] {
        var result: [TVHomeSection] = []
        for catalog in catalogs {
            guard let items = catalog.items else { continue }
            let head = await TmdbDetailsService.localizedMetadata(for: Array(items.prefix(18)))
            let all = head + items.dropFirst(18)
            result.append(TVHomeSection(
                id: catalog.id,
                title: catalog.name,
                items: all.filter(isVisible),
                contentType: catalog.contentType,
                catalogId: catalog.catalogId,
                addonId: catalog.addonId,
                addonName: catalog.addonName,
                catalogGenre: catalog.catalogGenre,
                nextSkip: items.count,
                hasMore: catalog.contentType != nil && catalog.catalogId != nil
            ))
        }
        return result
    }

    /// Next page for a row once its last few posters come on screen.
    func loadMoreIfNeeded(sectionId: String, current meta: NuvioMeta) {
        guard let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let section = sections[index]
        guard section.hasMore, !section.isLoadingMore,
              let contentType = section.contentType, let catalogId = section.catalogId,
              let position = section.items.firstIndex(where: { $0.id == meta.id }),
              position >= section.items.count - 6 else { return }
        sections[index].isLoadingMore = true
        let skip = section.nextSkip ?? section.items.count
        Task {
            let page = try? await repository.browseCatalog(
                addonId: section.addonId,
                contentType: contentType,
                catalogId: catalogId,
                skip: skip,
                genre: section.catalogGenre
            )
            guard let latest = sections.firstIndex(where: { $0.id == sectionId }) else { return }
            sections[latest].isLoadingMore = false
            guard let page else { return }
            let existing = Set(sections[latest].items.map(\.id))
            let fresh = page.items.filter { !existing.contains($0.id) && isVisible($0) }
            sections[latest].items.append(contentsOf: fresh)
            sections[latest].nextSkip = page.nextSkip ?? (skip + page.items.count)
            sections[latest].hasMore = page.hasMore && !fresh.isEmpty
        }
    }

    // MARK: Continue Watching

    func refreshContinueWatching() {
        if RemoteTrackingState.isProgressSourceAuthenticated {
            progressTask?.cancel()
            progressTask = Task {
                let items = await TraktProgressService.fetchContinueWatching(
                    repository: repository,
                    source: TraktSettingsStore.watchProgressSource
                )
                guard !Task.isCancelled, let items else { return }
                var seen = Set<String>()
                continueWatching = items.filter { shouldDisplay($0) && seen.insert($0.meta.id).inserted }
            }
            return
        }
        var byId: [String: ContinueWatchingItem] = [:]
        for item in ContinueWatchingBuilder.pagedItems { byId[item.meta.id] = item }
        for item in ContinueWatchingStore.items() { byId[item.meta.id] = item }
        let visible = byId.values
            .sorted { $0.recencySortDate > $1.recencySortDate }
            .filter(shouldDisplay)
        let sort = ProfileSettings.current.string(forKey: SettingsKey.continueWatchingSort) ?? "Default"
        continueWatching = ContinueWatchingSortPolicy.sorted(visible, preference: sort)
    }

    private func shouldDisplay(_ item: ContinueWatchingItem) -> Bool {
        let showUnaired = (ProfileSettings.current.object(forKey: SettingsKey.showUnairedNextUp) as? Bool) ?? true
        return (!item.isUpNextEntry || ContinueWatchingFeatureFlags.nextUpCardsEnabled)
            && isVisible(item.meta)
            && (showUnaired || !item.isUpNextEntry || item.hasAired || item.isAiringToday)
            && !ContinueWatchingDismissStore.isDismissed(item)
    }

    private func isVisible(_ meta: NuvioMeta) -> Bool {
        let hideUnreleased = (ProfileSettings.current.object(forKey: SettingsKey.hideUnreleased) as? Bool) ?? false
        return !hideUnreleased || !ContentReleasePolicy.isUnreleased(meta)
    }
}

struct PhoneHomeView: View {
    @ObservedObject var loader: PhoneHomeLoader
    let onOpenDetails: (NuvioMeta) -> Void
    let onResume: (ContinueWatchingItem) -> Void
    let onStartOver: (ContinueWatchingItem) -> Void
    let onRemoveContinueWatching: (ContinueWatchingItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let hero = loader.sections.first?.items.first {
                    PhoneHeroCard(meta: hero) { onOpenDetails(hero) }
                }

                if !loader.continueWatching.isEmpty {
                    continueWatchingRow
                }

                ForEach(loader.sections) { section in
                    catalogRow(section)
                }

                if loader.sections.isEmpty {
                    emptyState
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { loader.reload() }
        .navigationTitle("Omni")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var continueWatchingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhoneSectionHeader(title: L10n.string("continue_watching", fallback: "Continue Watching"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(loader.continueWatching, id: \.meta.id) { item in
                        Button { onResume(item) } label: { PhoneContinueCard(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { onResume(item) } label: { Label("Resume", systemImage: "play.fill") }
                                Button { onStartOver(item) } label: { Label("Start Over", systemImage: "gobackward") }
                                Button { onOpenDetails(item.meta) } label: { Label("Details", systemImage: "info.circle") }
                                Button(role: .destructive) { onRemoveContinueWatching(item) } label: {
                                    Label("Remove", systemImage: "xmark")
                                }
                            }
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)
            }
        }
    }

    private func catalogRow(_ section: TVHomeSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PhoneSectionHeader(title: section.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(section.items, id: \.id) { meta in
                        Button { onOpenDetails(meta) } label: { PhonePosterCard(meta: meta) }
                            .buttonStyle(.plain)
                            .onAppear { loader.loadMoreIfNeeded(sectionId: section.id, current: meta) }
                    }
                    if section.isLoadingMore {
                        ProgressView().frame(width: 60, height: PhoneLayout.posterWidth * PhoneLayout.posterAspect)
                    }
                }
                .padding(.horizontal, PhoneLayout.gutter)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if loader.isLoading {
                ProgressView()
            } else if let error = loader.errorMessage {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { loader.reload() }
            } else {
                Image(systemName: "puzzlepiece.extension").font(.largeTitle)
                Text("No catalogs yet. Add-ons installed on your account will appear here.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }
}

/// The first title of the first row, shown large at the top of Home.
private struct PhoneHeroCard: View {
    let meta: NuvioMeta
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                PhoneArtwork(url: meta.backgroundUrl ?? meta.posterUrl)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    if let logo = meta.logoUrl {
                        PhoneArtwork(url: logo, contentMode: .fit)
                            .frame(maxWidth: 220, maxHeight: 70, alignment: .leading)
                    } else {
                        Text(meta.name).font(.title.weight(.bold))
                    }
                    Text([meta.year.map(String.init), meta.genres?.prefix(2).joined(separator: " · ")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(PhoneLayout.gutter)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, PhoneLayout.gutter)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
#endif

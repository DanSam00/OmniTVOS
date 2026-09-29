#if os(iOS)
import SwiftUI

/// The phone's main screen: a standard tab bar in place of the tvOS sidebar.
/// Details and the player are still presented by `ContentView` above this, so
/// each tab keeps its scroll position while they are open.
struct PhoneMainTabView: View {
    let activeProfile: Profile?
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var authManager: AuthManager
    let homeCatalogRevision: UInt
    let onOpenDetails: (String, String) -> Void
    let onResume: (ContinueWatchingItem) -> Void
    let onStartOver: (ContinueWatchingItem) -> Void
    let onRemoveContinueWatching: (ContinueWatchingItem) -> Void
    let onSwitchProfile: () -> Void
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onChangeProfileName: (String, String) -> Void
    let onChangeProfileAvatar: (String, String) -> Void
    let onChangeProfilePin: (String, String?, String?) async -> Bool
    let onVerifyProfilePin: (String, String) async -> Bool

    @StateObject private var homeLoader = PhoneHomeLoader()
    @State private var selection: TVTab = .home

    private var homeKey: String {
        "\(activeProfile?.id ?? "none")|\(homeCatalogRevision)"
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(TVTab.home.title, systemImage: TVTab.home.symbol, value: TVTab.home) {
                NavigationStack {
                    PhoneHomeView(
                        loader: homeLoader,
                        onOpenDetails: { onOpenDetails($0.id, $0.type) },
                        onResume: onResume,
                        onStartOver: onStartOver,
                        onRemoveContinueWatching: onRemoveContinueWatching
                    )
                }
            }
            Tab(TVTab.search.title, systemImage: TVTab.search.symbol, value: TVTab.search, role: .search) {
                NavigationStack {
                    PhoneSearchView(viewModel: searchViewModel) { onOpenDetails($0.id, $0.type) }
                }
            }
            Tab(TVTab.library.title, systemImage: TVTab.library.symbol, value: TVTab.library) {
                NavigationStack {
                    PhoneLibraryView(viewModel: libraryViewModel) { onOpenDetails($0, $1) }
                }
            }
            Tab(TVTab.calendar.title, systemImage: TVTab.calendar.symbol, value: TVTab.calendar) {
                NavigationStack {
                    PhoneCalendarView { onOpenDetails($0, $1) }
                        .id(activeProfile?.id ?? "none")
                }
            }
            Tab(TVTab.settings.title, systemImage: TVTab.settings.symbol, value: TVTab.settings) {
                NavigationStack {
                    // The full settings, shared with tvOS and macOS.
                    SettingsView(
                        activeProfile: activeProfile,
                        accountEmail: authManager.currentEmail,
                        isAuthenticated: authManager.isAuthenticated,
                        sessionNeedsReauthentication: authManager.sessionNeedsReauthentication,
                        onChangeProfileName: onChangeProfileName,
                        onChangeProfileAvatar: onChangeProfileAvatar,
                        onChangeProfilePin: onChangeProfilePin,
                        onVerifyProfilePin: onVerifyProfilePin,
                        onSignIn: onSignIn,
                        onSignOut: onSignOut
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onSwitchProfile) {
                                Image(systemName: "person.2.circle")
                            }
                            .accessibilityLabel("Switch Profile")
                        }
                    }
                    .id(activeProfile?.id ?? "none")
                }
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .onAppear { homeLoader.load(key: homeKey) }
        .onChange(of: homeKey) { _, key in homeLoader.load(key: key) }
    }
}

// MARK: - Search

struct PhoneSearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    let onSelect: (NuvioMeta) -> Void

    /// Held here so its filters and loaded pages survive leaving the tab.
    @StateObject private var discover = DiscoverViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Type", selection: Binding(
                    get: { viewModel.selectedType },
                    set: { viewModel.setType($0) }
                )) {
                    ForEach(SearchContentType.allCases, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, PhoneLayout.gutter)

                if viewModel.searchText.isEmpty {
                    recent
                    PhoneDiscoverSection(viewModel: discover, onSelect: onSelect)
                } else if viewModel.isLoading && viewModel.results.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if viewModel.results.isEmpty {
                    Text(viewModel.error ?? "No results")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    PhonePosterGrid(items: viewModel.results, onSelect: onSelect)
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(TVTab.search.title)
        .searchable(text: $viewModel.searchText, prompt: "Movies and shows")
        .onSubmit(of: .search) { viewModel.performSearch(query: viewModel.searchText) }
    }

    @ViewBuilder
    private var recent: some View {
        if !viewModel.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    Button("Clear") { viewModel.clearRecent() }.font(.subheadline)
                }
                ForEach(viewModel.recentSearches, id: \.self) { term in
                    Button { viewModel.applyRecent(term) } label: {
                        Label(term, systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, PhoneLayout.gutter)
        }
    }
}

// MARK: - Library

struct PhoneLibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onSelect: (String, String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)]

    var body: some View {
        let groups = viewModel.sortedAndGroupedItems
        ScrollView {
            if groups.values.allSatisfy(\.isEmpty) {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack").font(.largeTitle)
                    Text("Titles you add to your library appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groups.keys.sorted(), id: \.self) { key in
                        if groups.count > 1 { PhoneSectionHeader(title: key) }
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(groups[key] ?? [], id: \.id) { item in
                                Button { onSelect(item.id, item.contentType) } label: {
                                    GeometryReader { proxy in
                                        libraryCard(item, width: proxy.size.width)
                                    }
                                    .aspectRatio(1 / (PhoneLayout.posterAspect + 0.18), contentMode: .fit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, PhoneLayout.gutter)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(TVTab.library.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $viewModel.sortOption) {
                        ForEach(LibraryViewModel.SortOption.allCases) { Text($0.localizedTitle).tag($0) }
                    }
                    Picker("Watched", selection: $viewModel.watchedFilter) {
                        ForEach(LibraryViewModel.WatchedFilter.allCases) { Text($0.localizedTitle).tag($0) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onAppear { viewModel.loadLibrary() }
        .refreshable { await viewModel.refreshSelectedLibrary() }
    }

    private func libraryCard(_ item: StremioMeta, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PhoneArtwork(url: item.poster ?? item.background)
                .frame(width: width, height: width * PhoneLayout.posterAspect)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#endif

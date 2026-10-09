#if os(iOS)
import SwiftUI

/// The phone's main screen: a standard tab bar in place of the tvOS sidebar.
/// Details and the player are still presented by `ContentView` above this, so
/// each tab keeps its scroll position while they are open.
struct PhoneMainTabView: View {
    let activeProfile: Profile?
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
    @ObservedObject private var iptv = IPTVAvailability.shared
    @State private var selection: TVTab = .home
    /// Tabs opened so far. A page is built the first time it is chosen and
    /// then kept, hidden, so it holds its place as the system tabs did.
    @State private var visited: Set<TVTab> = [.home]
    @State private var isKeyboardShown = false

    /// The system tab bar holds five tabs on a phone and folds the rest into
    /// a "More" list, which showed Calendar twice once Live TV arrived; this
    /// bar holds them all. Live TV only while there is an IPTV source.
    private var barTabs: [TVTab] {
        iptv.hasSources
            ? [.home, .guide, .library, .calendar, .settings]
            : [.home, .library, .calendar, .settings]
    }

    private var homeKey: String {
        "\(activeProfile?.id ?? "none")|\(homeCatalogRevision)"
    }

    var body: some View {
        ZStack {
            page(.home) {
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
            page(.search) {
                NavigationStack {
                    PhoneSearchView { onOpenDetails($0.id, $0.type) }
                }
            }
            page(.guide) {
                NavigationStack {
                    IPTVGuideView(isActive: true) { onOpenDetails($0, $1) }
                        .id(activeProfile?.id ?? "none")
                }
            }
            page(.library) {
                NavigationStack {
                    PhoneLibraryView(viewModel: libraryViewModel) { onOpenDetails($0, $1) }
                }
            }
            page(.calendar) {
                NavigationStack {
                    PhoneCalendarView { onOpenDetails($0, $1) }
                        .id(activeProfile?.id ?? "none")
                }
            }
            page(.settings) {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isKeyboardShown {
                PhoneTabBar(tabs: barTabs, selection: $selection)
            }
        }
        .onChange(of: selection) { _, tab in visited.insert(tab) }
        .onReceive(iptv.$hasSources) { has in
            if !has, selection == .guide { selection = .home }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardShown = false
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .onAppear { homeLoader.load(key: homeKey) }
        #if OMNI_DEBUG_TOOLS
        // `-OmniDebugFocusSearch YES` opens Search and focuses its field, which
        // raises the on-screen keyboard without a tap.
        .task {
            guard UserDefaults.standard.bool(forKey: "OmniDebugFocusSearch") else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            selection = .search
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            NotificationCenter.default.post(name: PhoneSearchView.debugFocusNotification, object: nil)
        }
        #endif
        .onChange(of: homeKey) { _, key in homeLoader.load(key: key) }
        // Cast devices can take a while to answer; looking from launch means
        // the player's Cast button already lists them.
        .task { PhoneCastController.shared.startDiscovery() }
    }

    @ViewBuilder
    private func page<Content: View>(_ tab: TVTab, @ViewBuilder content: () -> Content) -> some View {
        if visited.contains(tab) || selection == tab {
            let shown = selection == tab
            content()
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
        }
    }
}

// MARK: - Tab bar

/// A floating bar in the style of the iOS 26 tab bar, with Search apart in
/// its own circle. Labels go when the tabs would not fit with them.
struct PhoneTabBar: View {
    let tabs: [TVTab]
    @Binding var selection: TVTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                items(labeled: true)
                items(labeled: false)
            }
            .padding(4)
            .phoneBarBackground(Capsule())

            Button { selection = .search } label: {
                Image(systemName: TVTab.search.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.white)
                    .background {
                        if selection == .search { Circle().fill(Color.white.opacity(0.16)).padding(4) }
                    }
            }
            .buttonStyle(.plain)
            .phoneBarBackground(Circle())
            .accessibilityLabel(TVTab.search.title)
            .accessibilityAddTraits(selection == .search ? .isSelected : [])
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func items(labeled: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: labeled ? 18 : 20, weight: .semibold))
                            .frame(height: 24)
                        if labeled {
                            Text(tab.title)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(selection == tab ? Color.white : Color.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func phoneBarBackground<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

// MARK: - Search

struct PhoneSearchView: View {
    let onSelect: (NuvioMeta) -> Void

    /// Owned here, not by `ContentView`. Every keystroke publishes a change;
    /// held at the root, that re-rendered the whole app — all five tabs and
    /// the full Settings tree — on each character, which on a signed-in phone
    /// ran past the 10-second watchdog and froze Search. Only this page
    /// depends on it now. Recent searches live in UserDefaults, so they are
    /// shared with the root instance that sign-out clears.
    @StateObject private var viewModel = SearchViewModel()

    /// Held here so its filters and loaded pages survive leaving the tab.
    @StateObject private var discover = DiscoverViewModel()
    @FocusState private var isSearchFocused: Bool

    static let debugFocusNotification = Notification.Name("omni.debug.focusSearch")

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
        .searchFocused($isSearchFocused)
        .onReceive(NotificationCenter.default.publisher(for: Self.debugFocusNotification)) { _ in
            isSearchFocused = true
        }
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
                                    libraryCard(item)
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

    private func libraryCard(_ item: StremioMeta) -> some View {
        // Sized by aspect ratio, not measured: see `PhoneFlexiblePoster`.
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1 / PhoneLayout.posterAspect, contentMode: .fit)
                .overlay { PhoneArtwork(url: item.poster ?? item.background) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

#endif

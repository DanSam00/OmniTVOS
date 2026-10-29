#if os(iOS)
import SwiftUI
import Combine

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
    let onPlayDownload: (DownloadRecord) -> Void

    @StateObject private var homeLoader = PhoneHomeLoader()
    @ObservedObject private var tabBar = PhoneTabBarState.shared
    @ObservedObject private var iptv = IPTVAvailability.shared
    @State private var selection: TVTab = .home
    /// Tabs opened so far. A page is built the first time it is chosen and
    /// then kept, hidden, so it holds its place as the system tabs did.
    @State private var visited: Set<TVTab> = [.home]
    @State private var isKeyboardShown = false
    @State private var librarySection: PhoneLibrarySection = .library
    @ObservedObject private var downloads = DownloadManager.shared
    /// Launched with no connection: Downloads opens once, on its own.
    @State private var appearedAt = Date()
    @State private var didOpenDownloadsOffline = false

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
        pageContainer
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isKeyboardShown, !PhoneDevice.usesSystemTabBar {
                PhoneTabBar(
                    tabs: barTabs,
                    selection: $selection,
                    isCollapsed: tabBar.isCollapsed,
                    onExpand: { tabBar.expand() },
                    onScrollToTop: { tabBar.scrollToTop() }
                )
            }
        }
        .onChange(of: selection, initial: true) { _, tab in
            visited.insert(tab)
            tabBar.expand()
            tabBar.currentTab = tab
        }
        .onChange(of: barTabs, initial: true) { _, tabs in tabBar.tabs = tabs }
        // A section chosen from the bar over a nested page.
        .onReceive(tabBar.tabRequests) { tab in selection = tab }
        // No connection at launch and something downloaded: Home cannot
        // load, so open on the downloads instead. Only at launch — a
        // connection dropping later leaves the user where they are.
        .onReceive(downloads.$isOffline) { offline in
            guard offline, !didOpenDownloadsOffline,
                  Date().timeIntervalSince(appearedAt) < 10 else { return }
            let profile = ProfileSettings.activeProfileScope
            guard downloads.records.values.contains(where: {
                $0.state == .completed && $0.profileId == profile
            }) else { return }
            didOpenDownloadsOffline = true
            librarySection = .downloads
            selection = .library
        }
        .onReceive(iptv.$hasSources) { has in
            if !has, selection == .guide { selection = .home }
        }
        // Judged by the keyboard's frame, not by which notification came:
        // turning an iPhone Duo sends "will show" for a keyboard of no
        // height, with no "will hide" after it, which hid the bar until the
        // phone switched screens. A hardware keyboard's slim shortcut bar
        // doesn't count either.
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
                .merge(with: NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification))
        ) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let screen = (note.object as? UIScreen)?.bounds
                ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
                ?? .zero
            isKeyboardShown = frame.height > 80 && frame.intersection(screen).height > 80
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

    /// iPhone Duo: the system tab bar, which the Duo draws as a pill down the
    /// screen's side, as its own apps have it. Elsewhere Omni's own floating
    /// bar along the bottom (`PhoneTabBar`).
    @ViewBuilder
    private var pageContainer: some View {
        if PhoneDevice.usesSystemTabBar {
            TabView(selection: $selection) {
                ForEach(barTabs + [.search]) { tab in
                    Tab(tab.title, systemImage: tab.symbol, value: tab, role: tab == .search ? .search : nil) {
                        pageContent(tab)
                    }
                }
            }
            .background(starterCollectionsTask)
        } else {
            ZStack {
                page(.home) { pageContent(.home) }
                page(.search) { pageContent(.search) }
                page(.guide) { pageContent(.guide) }
                page(.library) { pageContent(.library) }
                page(.calendar) { pageContent(.calendar) }
                page(.settings) { pageContent(.settings) }
                starterCollectionsTask
            }
        }
    }

    /// A new kids profile's starter collections (see CommunityCollections).
    private var starterCollectionsTask: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: activeProfile?.id) {
                // Picked in Add Profile, else a kids profile's starter set.
                // A kids profile never starts with 18+ switched on.
                if PhoneKidsMode.isActive { NSFWVisibility.shared.showsInSearch = false }
                await CommunityCollections.installPendingIfNeeded()
                #if OMNI_X
                guard PhoneKidsMode.isActive else { return }
                await CommunityCollections.seedKidsProfileIfNeeded()
                #else
                await CuratedLibrary.installCollectionsIfNeeded()
                #endif
            }
    }

    @ViewBuilder
    private func pageContent(_ tab: TVTab) -> some View {
        switch tab {
        case .home:
            NavigationStack {
                ZStack(alignment: .topTrailing) {
                    PhoneHomeView(
                        loader: homeLoader,
                        onOpenDetails: { onOpenDetails($0.id, $0.type) },
                        onResume: onResume,
                        onStartOver: onStartOver,
                        onRemoveContinueWatching: onRemoveContinueWatching
                    )
                    // Who's watching, as Settings has it; out of the way
                    // once the page is scrolled down.
                    Button(action: onSwitchProfile) {
                        ProfileAvatarView(
                            avatarId: activeProfile?.avatarId ?? ProfileAvatarCatalog.defaultId,
                            size: 36,
                            profileId: activeProfile?.id
                        )
                        .padding(3)
                        .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Switch Profile")
                    .padding(.trailing, 16)
                    .padding(.top, 4)
                    .opacity(tabBar.isCollapsed ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: tabBar.isCollapsed)
                }
            }
        case .search:
            NavigationStack {
                PhoneSearchView { onOpenDetails($0.id, $0.type) }
            }
        case .guide:
            NavigationStack {
                IPTVGuideView(isActive: true) { onOpenDetails($0, $1) }
                    .id(activeProfile?.id ?? "none")
            }
        case .library:
            NavigationStack {
                PhoneLibraryView(
                    viewModel: libraryViewModel,
                    section: $librarySection,
                    onSelect: { onOpenDetails($0, $1) },
                    onPlayDownload: onPlayDownload
                )
            }
        case .calendar:
            NavigationStack {
                PhoneCalendarView { onOpenDetails($0, $1) }
                    .id(activeProfile?.id ?? "none")
            }
        case .settings:
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
                        // The current profile's own picture, which is
                        // also the way to switch to another.
                        Button(action: onSwitchProfile) {
                            ProfileAvatarView(
                                avatarId: activeProfile?.avatarId ?? ProfileAvatarCatalog.defaultId,
                                size: 32,
                                profileId: activeProfile?.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Switch Profile")
                    }
                }
                .id(activeProfile?.id ?? "none")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func page<Content: View>(_ tab: TVTab, @ViewBuilder content: () -> Content) -> some View {
        if visited.contains(tab) || selection == tab {
            let shown = selection == tab
            content()
                .environment(\.phoneTabIsShown, shown)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
        }
    }
}

// MARK: - Tab bar

/// Whether the tab bar is folded down to its current section, as Apple
/// Music's does: scrolling down a page folds it, reaching the top again or
/// tapping it opens it out.
@MainActor
final class PhoneTabBarState: ObservableObject {
    static let shared = PhoneTabBarState()
    @Published private(set) var isCollapsed = false
    /// Bumped by the back-to-top button; the shown page's scroller answers.
    @Published private(set) var topRequest = 0
    /// The tab section on screen and the bar's sections, for the bar drawn
    /// over nested pages (`PhoneNestedTabBar`).
    @Published var currentTab: TVTab = .home
    @Published var tabs: [TVTab] = [.home]
    /// A page opened over the tabs (Details, a collection…) is up: the arrow
    /// moves it, not the tab page beneath.
    @Published var nestedPageActive = false
    /// That page is scrolled far enough down for the arrow to show.
    @Published var nestedScrolledFar = false
    /// A section chosen from the bar over a nested page.
    let tabRequests = PassthroughSubject<TVTab, Never>()

    /// The liquid fold and unfold: slower and softer than a tap's spring,
    /// with a little give at the end, as the system tab bar folds.
    static let motion = Animation.spring(duration: 0.55, bounce: 0.2)

    func expand() {
        guard isCollapsed else { return }
        withAnimation(Self.motion) { isCollapsed = false }
    }

    func scrollToTop() {
        topRequest += 1
        expand()
    }

    /// A page's scroll offset moved from `old` to `new` (0 at the top).
    func scrolled(from old: CGFloat, to new: CGFloat) {
        if new <= 12 {
            expand()
        } else if new - old > 3, new > 40, !isCollapsed {
            withAnimation(Self.motion) { isCollapsed = true }
        }
    }
}

extension View {
    /// Folds the tab bar as this scroll view is scrolled down, and opens it
    /// out back at the top. For each tab page's main vertical scroller. Also
    /// leaves room at the end of the content, so the last row can be
    /// scrolled clear of the bar rather than finishing under it.
    /// It also goes back to the top when the folded bar's arrow is tapped,
    /// if it is the page on screen.
    func phoneTabBarFoldsOnScroll() -> some View {
        modifier(PhoneTabBarFold())
    }
}

private struct PhoneTabBarFold: ViewModifier {
    @Environment(\.phoneTabIsShown) private var isShown
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, PhoneDevice.usesSystemTabBar ? 0 : 72, for: .scrollContent)
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { old, new in
                PhoneTabBarState.shared.scrolled(from: old, to: new)
            }
            .onReceive(PhoneTabBarState.shared.$topRequest.dropFirst()) { _ in
                // Every tab stays mounted; only the one on screen moves, and
                // not while a nested page is over it.
                guard isShown, !PhoneTabBarState.shared.nestedPageActive else { return }
                withAnimation(.smooth(duration: 0.45)) { position.scrollTo(edge: .top) }
            }
    }
}

private struct PhoneTabIsShownKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False on the tab pages kept mounted behind the current one.
    var phoneTabIsShown: Bool {
        get { self[PhoneTabIsShownKey.self] }
        set { self[PhoneTabIsShownKey.self] = newValue }
    }
}

/// A floating bar in the style of the iOS 26 tab bar, with Search apart in
/// its own circle. Icons only, no labels, so the icons can be larger. Folded,
/// it is one circle at the leading end showing the current section.
struct PhoneTabBar: View {
    let tabs: [TVTab]
    @Binding var selection: TVTab
    var isCollapsed = false
    var onExpand: () -> Void = {}
    /// Folded means scrolled down: the gap between the two ends then holds
    /// a back-to-top arrow.
    var onScrollToTop: () -> Void = {}
    /// Over a nested page the bar stays folded, so the arrow follows that
    /// page's own scroll instead.
    var showsScrollToTop: Bool? = nil
    @Namespace private var pill
    @Namespace private var glass
    /// The last section other than Search, which the folded circle shows
    /// while Search (which has its own circle) is open.
    @State private var lastTab: TVTab = .home

    private var foldedTab: TVTab {
        tabs.contains(selection) ? selection : (tabs.contains(lastTab) ? lastTab : (tabs.first ?? .home))
    }

    var body: some View {
        glassGroup {
            HStack(spacing: 10) {
                // One bar throughout: folding narrows the capsule into a
                // circle while the other sections slide shut into the current
                // one, so the glass flows rather than swapping one view for
                // another.
                items
                    .padding(4)
                    .frame(width: isCollapsed ? 56 : nil)
                    .phoneBarGlass(Capsule(), id: "tabs", in: glass)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button { selection = .search } label: {
                    Image(systemName: TVTab.search.symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .foregroundStyle(.white)
                        .background {
                            if selection == .search { Circle().fill(Color.white.opacity(0.16)).padding(4) }
                        }
                }
                .buttonStyle(.plain)
                .phoneBarGlass(Circle(), id: "search", in: glass)
                .accessibilityLabel(TVTab.search.title)
                .accessibilityAddTraits(selection == .search ? .isSelected : [])
            }
            .overlay {
                if showsScrollToTop ?? isCollapsed {
                    Button(action: onScrollToTop) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 56, height: 56)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .phoneBarGlass(Circle(), id: "top", in: glass)
                    .accessibilityLabel("Back to Top")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: selection) { _, tab in
            if tabs.contains(tab) { lastTab = tab }
        }
    }

    /// One glass container on iOS 26, so the bar and Search's circle are
    /// drawn as one material.
    @ViewBuilder
    private func glassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { content() }
        } else {
            content()
        }
    }

    private func icon(for tab: TVTab) -> some View {
        PhoneTabIcon(tab: tab)
    }

    private var items: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isFoldedAway = isCollapsed && tab != foldedTab
                Button {
                    if isCollapsed {
                        onExpand()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab }
                    }
                } label: {
                    icon(for: tab)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(height: 30)
                        .foregroundStyle(selection == tab || isCollapsed ? Color.white : Color.white.opacity(0.75))
                        .padding(.horizontal, isFoldedAway ? 0 : 10)
                        .frame(height: 48)
                        .frame(maxWidth: isFoldedAway ? 0 : .infinity)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(Color.white.opacity(isCollapsed ? 0 : 0.16))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Folding away: shrink and fade into the section that stays.
                .scaleEffect(isFoldedAway ? 0.4 : 1)
                .opacity(isFoldedAway ? 0 : 1)
                .blur(radius: isFoldedAway ? 3 : 0)
                .allowsHitTesting(!isFoldedAway)
                .accessibilityHidden(isFoldedAway)
                .accessibilityLabel(isCollapsed ? "\(tab.title), show all sections" : tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
    }
}

/// A section's icon in the tab bars. Without labels, a plain TV could be
/// anything, so Live TV's says LIVE on its screen.
struct PhoneTabIcon: View {
    let tab: TVTab

    var body: some View {
        if tab == .guide {
            Image(systemName: "tv")
                .overlay {
                    Text("LIVE")
                        .font(.system(size: 6.5, weight: .heavy))
                        .kerning(0.2)
                        .offset(y: -1.5)
                }
        } else {
            Image(systemName: tab.symbol)
        }
    }
}

private extension View {
    /// The bar's glass, tagged so a shape folding into another one (the bar
    /// into its circle) morphs rather than cross-fades.
    @ViewBuilder
    func phoneBarGlass<S: Shape>(_ shape: S, id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
                .matchedGeometryEffect(id: id, in: namespace)
        }
    }
}

// MARK: - Downloads

/// Everything downloaded to this phone, or downloading: movies, then each
/// show's episodes in order. A finished one plays from the device; one in
/// progress pauses or resumes on a tap; swipe to delete.
struct PhoneDownloadsView: View {
    let onPlay: (DownloadRecord) -> Void
    let onOpen: (String, String) -> Void

    @ObservedObject private var downloads = DownloadManager.shared

    private var mine: [DownloadRecord] {
        let profile = ProfileSettings.activeProfileScope
        return downloads.records.values.filter { $0.profileId == profile }
    }

    private var movies: [DownloadRecord] {
        mine.filter { $0.season == nil }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Shows by title, each with its episodes in season and episode order.
    private var shows: [(meta: NuvioMeta, episodes: [DownloadRecord])] {
        let grouped = Dictionary(grouping: mine.filter { $0.season != nil }, by: \.meta.id)
        return grouped.values
            .map { records in
                (records[0].meta, records.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) })
            }
            .sorted { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }
    }

    var body: some View {
        if mine.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle").font(.largeTitle)
                Text("Movies and episodes you download appear here, ready to watch without a connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 100)
            .padding(.horizontal, 40)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !movies.isEmpty {
                        header("Movies")
                        ForEach(movies) { row($0) }
                    }
                    ForEach(shows, id: \.meta.id) { show in
                        header(show.meta.name)
                        ForEach(show.episodes) { row($0) }
                    }
                    HStack {
                        Text("Storage Used")
                        Spacer()
                        Text(DownloadSettings.label(for: max(downloads.storageUsed, 0)))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.top, 10)
                }
                .padding(.horizontal, PhoneLayout.gutter)
                .padding(.vertical, 8)
            }
            .phoneTabBarFoldsOnScroll()
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .padding(.top, 10)
    }

    /// A card like the episode list's, swiped left for Go to Title and
    /// Delete (a full swipe deletes).
    private func row(_ record: DownloadRecord) -> some View {
        let waiting = downloads.isWaitingForWiFi(record)
        return PhoneSwipeActionRow(
            actions: [
                PhoneSwipeAction(
                    title: "Go to Title",
                    systemImage: "info.circle",
                    color: Color(white: 0.3),
                    action: { onOpen(record.meta.id, record.meta.type) }
                ),
                PhoneSwipeAction(
                    title: "Delete",
                    systemImage: "trash",
                    color: .red,
                    action: { downloads.delete(record.contentId) }
                ),
            ],
            onTap: { tap(record) }
        ) {
            HStack(spacing: 12) {
                PhoneArtwork(
                    url: DownloadManager.listArtwork(for: record),
                    kind: .backdrop
                )
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(record))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let status = PhoneDownloadIcon.statusText(record: record, waiting: waiting) {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(record.state == .failed || record.state == .needsSource ? Color.orange : Color.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                PhoneDownloadIcon(record: record, isWaitingForWiFi: waiting, isPreparing: false)
                    .frame(width: 32, height: 32)
            }
            .padding(8)
            .frame(minHeight: 88)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: .rect(cornerRadius: 10))
            .environment(\.colorScheme, .dark)
            .contentShape(Rectangle())
        }
    }

    private func title(_ record: DownloadRecord) -> String {
        guard let season = record.season, let episode = record.episode else { return record.meta.name }
        return "S\(season) E\(episode) · \(record.episodeTitle ?? "Episode \(episode)")"
    }

    private func tap(_ record: DownloadRecord) {
        switch record.state {
        case .completed: onPlay(record)
        case .downloading, .queued, .resolving: downloads.pause(record.contentId)
        case .paused, .failed: downloads.resume(record.contentId)
        // Picked on the title's page, from its source list.
        case .needsSource: onOpen(record.meta.id, record.meta.type)
        case .findingSource: break
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
    @ObservedObject private var nsfw = NSFWVisibility.shared
    @FocusState private var isSearchFocused: Bool

    static let debugFocusNotification = Notification.Name("omni.debug.focusSearch")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Only with results to narrow: Discover has its own filters.
                // One row, as Discover's: the kinds, then the 18+ switch
                // (off at every launch), which adds Adult to the kinds.
                if !viewModel.searchText.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(SearchContentType.visibleCases) { type in
                                PhoneFilterChip(title: type.title, isOn: viewModel.selectedType == type) {
                                    viewModel.setType(type)
                                }
                            }
                            if AdultContent.shared.hasAdultSources, !PhoneKidsMode.isActive {
                                PhoneFilterChip(title: "18+", isOn: nsfw.showsInSearch, onColor: .red) {
                                    nsfw.showsInSearch.toggle()
                                }
                            }
                        }
                        .padding(.horizontal, PhoneLayout.gutter)
                    }
                }

                if viewModel.searchText.isEmpty {
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
        .phoneTabBarFoldsOnScroll()
        .navigationTitle(TVTab.search.title)
        .navigationBarTitleDisplayMode(.inline)
        // Pinned under the title. Left automatic, iOS 26 puts the field at
        // the bottom of the screen, where the tab bar covers it.
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Movies and shows"
        )
        // Past searches matching what is typed so far — all of them while the
        // field is empty — from this session's and earlier ones.
        .searchSuggestions {
            ForEach(viewModel.matchingRecentSearches, id: \.self) { term in
                Label(term, systemImage: "clock.arrow.circlepath").searchCompletion(term)
            }
            if viewModel.searchText.isEmpty, !viewModel.recentSearches.isEmpty {
                Button("Clear Recent Searches", role: .destructive) { viewModel.clearRecent() }
            }
        }
        .searchFocused($isSearchFocused)
        .onReceive(NotificationCenter.default.publisher(for: Self.debugFocusNotification)) { _ in
            isSearchFocused = true
        }
        .onSubmit(of: .search) { viewModel.performSearch(query: viewModel.searchText) }
    }
}

// MARK: - Library

enum PhoneLibrarySection: String, CaseIterable {
    case library = "Library"
    /// The viewer's IPTV and Jellyfin on-demand folders (`PhoneFoldersView`),
    /// offered only when one is set up.
    case folders = "Folders"
    case downloads = "Downloads"
}

struct PhoneLibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    /// Held by the tab view, which opens Downloads when launched offline.
    @Binding var section: PhoneLibrarySection
    let onSelect: (String, String) -> Void
    let onPlayDownload: (DownloadRecord) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)]
    @State private var hasFolders = PhoneFoldersView.isAvailable

    private var sections: [PhoneLibrarySection] {
        PhoneLibrarySection.allCases.filter { $0 != .folders || hasFolders }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch section {
            case .library:
                libraryGrid
            case .folders:
                PhoneFoldersView(onSelect: onSelect)
            case .downloads:
                PhoneDownloadsView(onPlay: onPlayDownload, onOpen: onSelect)
            }
        }
        .navigationTitle(section == .library ? TVTab.library.title : section.rawValue)
        // The Library | Downloads switch is the bar's title, rather than a
        // large title with the switch under it: that took the top quarter of
        // the screen before the first poster.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $section) {
                    ForEach(sections, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: sections.count > 2 ? 330 : 260)
            }
        }
        .onAppear {
            viewModel.loadLibrary()
            hasFolders = PhoneFoldersView.isAvailable
        }
        .onReceive(NotificationCenter.default.publisher(for: IPTVSourceStore.changedNotification)) { _ in
            hasFolders = PhoneFoldersView.isAvailable
        }
        .onChange(of: hasFolders) { _, available in
            if !available, section == .folders { section = .library }
        }
    }

    private var libraryGrid: some View {
        let groups = viewModel.sortedAndGroupedItems
        return ScrollView {
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
        .phoneTabBarFoldsOnScroll()
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

/// The tab bar over a page opened from the tabs (Details, a collection, a
/// studio…), folded to the current section and Search until tapped open, so
/// any section is a tap or two away however deep the pages go. Choosing one
/// leaves those pages for it.
struct PhoneNestedTabBar: View {
    let onSelect: (TVTab) -> Void
    @ObservedObject private var state = PhoneTabBarState.shared
    @State private var isExpanded = false

    var body: some View {
        GeometryReader { proxy in
            // iPhone Duo, outside screen: the system bar beneath is a pill
            // down the side, so this one is too.
            if PhoneDevice.usesSystemTabBar, proxy.size.height > proxy.size.width {
                PhoneSideTabBar(
                    tabs: state.tabs,
                    selection: state.currentTab,
                    onSelect: onSelect,
                    onScrollToTop: { state.scrollToTop() },
                    showsScrollToTop: state.nestedScrolledFar,
                    trailingInset: proxy.safeAreaInsets.trailing,
                    bottomInset: proxy.safeAreaInsets.bottom
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            } else {
                bottomBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        // Only while a nested page is up: on the way back this bar is still
        // drawn for a moment over the tab's own, and must not take its taps.
        .allowsHitTesting(state.nestedPageActive)
    }

    private var bottomBar: some View {
        PhoneTabBar(
            tabs: state.tabs,
            selection: Binding(
                get: { state.currentTab },
                set: { tab in
                    isExpanded = false
                    onSelect(tab)
                }
            ),
            isCollapsed: !isExpanded,
            onExpand: { withAnimation(PhoneTabBarState.motion) { isExpanded = true } },
            onScrollToTop: {
                guard state.nestedPageActive else { return }
                state.scrollToTop()
            },
            showsScrollToTop: !isExpanded && state.nestedScrolledFar
        )
    }
}

/// The iPhone Duo's side bar, drawn over nested pages: the sections and
/// Search in one pill down the outside screen's status column, where the
/// system draws its own over the tab pages. Always open — it takes no room
/// from the page there.
struct PhoneSideTabBar: View {
    let tabs: [TVTab]
    let selection: TVTab
    let onSelect: (TVTab) -> Void
    let onScrollToTop: () -> Void
    let showsScrollToTop: Bool
    /// The screen's insets: the pill sits centred in the trailing one (the
    /// status column) and as far from the bottom edge as the system's.
    let trailingInset: CGFloat
    let bottomInset: CGFloat
    @Namespace private var glass

    private static let width: CGFloat = 48
    private static let bottomGap: CGFloat = 25

    /// From the safe area's trailing edge to the pill's centre, which the
    /// system sets a little inside the column's middle.
    private var offsetX: CGFloat {
        trailingInset >= Self.width + 8 ? trailingInset / 2 + Self.width / 2 - 6 : -12
    }

    var body: some View {
        VStack(spacing: 10) {
            if showsScrollToTop {
                Button(action: onScrollToTop) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: Self.width, height: Self.width)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .phoneBarGlass(Circle(), id: "top", in: glass)
                .accessibilityLabel("Back to Top")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            VStack(spacing: 2) {
                ForEach(tabs + [.search]) { tab in
                    Button {
                        onSelect(tab)
                    } label: {
                        PhoneTabIcon(tab: tab)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(selection == tab ? Color.white : Color.white.opacity(0.8))
                            .frame(width: Self.width - 8, height: 46)
                            .background {
                                if selection == tab { Capsule().fill(Color.white.opacity(0.16)) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(4)
            .phoneBarGlass(Capsule(), id: "tabs", in: glass)
        }
        .animation(.smooth(duration: 0.25), value: showsScrollToTop)
        // Measured from the screen's edge, not the safe area's: the home
        // indicator's inset would lift it above the system's.
        .offset(x: offsetX, y: max(bottomInset - Self.bottomGap, 0))
        .padding(.bottom, max(Self.bottomGap - bottomInset, 0))
        .sensoryFeedback(.selection, trigger: selection)
    }
}


/// The phone this runs on, where it changes the layout.
enum PhoneDevice {
    /// iPhone Duo: its own vertical tab bar down the side, rather than Omni's
    /// floating one along the bottom, which the Duo's tall inside screen left
    /// far from the hand.
    static let usesSystemTabBar: Bool = {
        let duoModels: Set<String> = ["iPhone19,4"]
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return duoModels.contains(simulated)
        }
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return duoModels.contains(model)
    }()
}

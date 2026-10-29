import SwiftUI

/// Library → Folders on the Apple TV and the Mac: the viewer's own on-demand
/// libraries as their sources arrange them. An IPTV provider's films and
/// shows by its categories, and a Jellyfin server's libraries and folders.
/// The iPhone draws the same thing with its own navigation (`PhoneFoldersView`).
///
/// The screen is a stack of levels inside the Library tab, so the source
/// switch stays on screen and Menu/Escape steps back one level.
@MainActor
final class LibraryFoldersModel: ObservableObject {
    enum Level: Hashable {
        case root
        case iptvCategories(sourceID: String, kind: IPTVVODBrowser.Kind)
        case iptvEntries(sourceID: String, kind: IPTVVODBrowser.Kind, categoryID: String, title: String)
        case jellyfin(serverID: String, folderID: String, title: String)
    }

    struct Tile: Identifiable, Hashable {
        enum Action: Hashable {
            case push(Level)
            case open(contentID: String, type: String)
            /// Nothing to open, only something to say: a Jellyfin title in a
            /// library Omni doesn't sync, or a server that didn't answer.
            case notice(String)
        }

        let id: String
        let title: String
        let subtitle: String?
        let poster: String?
        let symbol: String
        let action: Action

        var opensLevel: Bool {
            if case .push = action { return true }
            return false
        }
    }

    /// A tile the screen should put focus on. The token makes asking for the
    /// same tile twice still count as a change.
    struct FocusRequest: Equatable {
        let tileID: String
        let token = UUID()
    }

    static let backID = "folders.back"

    @Published private(set) var path: [Level] = [.root]
    /// The current level's tiles; nil while they load.
    @Published private(set) var tiles: [Tile]?
    @Published private(set) var notice: String?
    @Published private(set) var focusRequest: FocusRequest?
    /// The tile a title's page was opened from, while that page is up and
    /// just after it closes. Everything else on the Library is disabled
    /// meanwhile, so the focus engine can only come back to this tile.
    @Published var restoringID: String?

    /// The tile opened from each level, so stepping back lands on it.
    private var openedTile: [Level: String] = [:]
    private var cache: [Level: [Tile]] = [:]
    private var loadedOnce = false

    /// Whether there is anything to browse: the Library only offers Folders then.
    static var isAvailable: Bool {
        !IPTVVODBrowser.sources().isEmpty || !JellyfinServerStore.shared.servers.isEmpty
    }

    var level: Level { path.last ?? .root }
    var isRoot: Bool { path.count <= 1 }

    /// Categories and the root are lists; titles and Jellyfin folders are posters.
    var usesGrid: Bool {
        switch level {
        case .root, .iptvCategories: return false
        case .iptvEntries, .jellyfin: return true
        }
    }

    var title: String {
        switch level {
        case .root: return L10n.string("library_source_folders", fallback: "Folders")
        case .iptvCategories(_, let kind): return kind.title
        case .iptvEntries(_, _, _, let title), .jellyfin(_, _, let title): return title
        }
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await load()
    }

    /// Sources were added or removed: start again from the top.
    func reset() {
        path = [.root]
        cache = [:]
        openedTile = [:]
        notice = nil
        tiles = nil
        loadedOnce = false
    }

    /// Opens a tile. Returns the title to show when it is one.
    func activate(_ tileID: String) -> (contentID: String, type: String)? {
        guard let tile = tiles?.first(where: { $0.id == tileID }) else { return nil }
        notice = nil
        switch tile.action {
        case .push(let next):
            openedTile[level] = tile.id
            path.append(next)
            Task { await load() }
            return nil
        case .open(let contentID, let type):
            openedTile[level] = tile.id
            return (contentID, type)
        case .notice(let text):
            notice = text
            return nil
        }
    }

    func pop() {
        guard !isRoot else { return }
        path.removeLast()
        notice = nil
        Task { await load() }
    }

    private func load() async {
        let level = self.level
        if let cached = cache[level] {
            tiles = cached
            requestFocus(in: cached, level: level)
            return
        }
        tiles = nil
        let loaded = Self.unique(await Self.tiles(for: level))
        cache[level] = loaded
        guard self.level == level else { return }
        tiles = loaded
        requestFocus(in: loaded, level: level)
    }

    private func requestFocus(in tiles: [Tile], level: Level) {
        let target = openedTile[level].flatMap { id in tiles.first { $0.id == id }?.id } ?? tiles.first?.id
        if let target { focusRequest = FocusRequest(tileID: target) }
    }

    /// Providers list the odd title twice; a repeated id breaks the grid.
    private static func unique(_ tiles: [Tile]) -> [Tile] {
        var seen = Set<String>()
        return tiles.filter { seen.insert($0.id).inserted }
    }

    private static func tiles(for level: Level) async -> [Tile] {
        switch level {
        case .root:
            return await rootTiles()

        case .iptvCategories(let sourceID, let kind):
            guard let source = IPTVVODBrowser.sources().first(where: { $0.id == sourceID }) else { return [] }
            return await IPTVVODBrowser.shared.categories(source: source, kind: kind).map { category in
                Tile(
                    id: "cat.\(category.id)",
                    title: category.name,
                    subtitle: nil,
                    poster: nil,
                    symbol: "folder",
                    action: .push(.iptvEntries(sourceID: sourceID, kind: kind, categoryID: category.id, title: category.name))
                )
            }

        case .iptvEntries(let sourceID, let kind, let categoryID, _):
            guard let source = IPTVVODBrowser.sources().first(where: { $0.id == sourceID }) else { return [] }
            return await IPTVVODBrowser.shared.entries(source: source, kind: kind, categoryID: categoryID).map { entry in
                Tile(
                    id: entry.contentID,
                    title: entry.name,
                    subtitle: entry.year.map(String.init),
                    poster: entry.poster,
                    symbol: kind == .movies ? "film" : "tv",
                    action: .open(contentID: entry.contentID, type: entry.type)
                )
            }

        case .jellyfin(let serverID, let folderID, _):
            guard let server = JellyfinServerStore.shared.servers.first(where: { $0.id == serverID }),
                  let client = JellyfinBrowse.client(for: server),
                  let items = try? await client.children(userId: server.userId, parentId: folderID)
            else { return [] }
            return items.compactMap { item in
                let poster = JellyfinBrowse.imageURL(server: server, item: item)
                if item.isTitle {
                    let contentID = JellyfinLibraryIndex.contentId(serverID: server.id, itemId: item.id)
                    let type = item.type == "Series" ? "series" : "movie"
                    let synced = JellyfinLibraryIndex.shared.meta(forContentId: contentID) != nil
                    return Tile(
                        id: item.id,
                        title: item.name,
                        subtitle: item.year.map(String.init),
                        poster: poster,
                        symbol: type == "series" ? "tv" : "film",
                        action: synced
                            ? .open(contentID: contentID, type: type)
                            : .notice("\(item.name) is in a library Omni hasn't synced. Turn that library on in Settings → Jellyfin, then sync.")
                    )
                }
                guard item.isFolder else { return nil }
                return Tile(
                    id: item.id,
                    title: item.name,
                    subtitle: nil,
                    poster: poster,
                    symbol: "folder.fill",
                    action: .push(.jellyfin(serverID: server.id, folderID: item.id, title: item.name))
                )
            }
        }
    }

    private static func rootTiles() async -> [Tile] {
        var tiles: [Tile] = []
        for source in IPTVVODBrowser.sources() {
            for kind in IPTVVODBrowser.Kind.allCases {
                tiles.append(Tile(
                    id: "iptv.\(source.id).\(kind.rawValue)",
                    title: kind.title,
                    subtitle: source.name.vodNonBlank ?? "IPTV",
                    poster: nil,
                    symbol: kind == .movies ? "film" : "tv",
                    action: .push(.iptvCategories(sourceID: source.id, kind: kind))
                ))
            }
        }
        for server in JellyfinServerStore.shared.servers {
            guard let client = JellyfinBrowse.client(for: server),
                  let libraries = try? await client.libraries(userId: server.userId)
            else {
                tiles.append(Tile(
                    id: "jf.\(server.id).unreachable",
                    title: server.displayName,
                    subtitle: "Couldn't reach this server",
                    poster: nil,
                    symbol: "exclamationmark.triangle",
                    action: .notice("\(server.displayName) didn't answer. Check it's running and reachable from this device.")
                ))
                continue
            }
            for library in libraries {
                tiles.append(Tile(
                    id: "jf.\(server.id).\(library.id)",
                    title: library.name,
                    subtitle: server.displayName,
                    poster: nil,
                    symbol: JellyfinBrowse.symbol(for: library.collectionType),
                    action: .push(.jellyfin(serverID: server.id, folderID: library.id, title: library.name))
                ))
            }
        }
        return tiles
    }
}

/// Jellyfin lookups the Folders screens share on every platform.
enum JellyfinBrowse {
    @MainActor
    static func client(for server: JellyfinServerConfig) -> JellyfinClient? {
        guard let baseURL = server.baseURL else { return nil }
        return JellyfinClient(baseURL: baseURL, accessToken: JellyfinCredentialStore.token(forServerID: server.id))
    }

    @MainActor
    static func imageURL(server: JellyfinServerConfig, item: JellyfinBrowseItem) -> String? {
        guard let baseURL = server.baseURL, let tag = item.primaryImageTag else { return nil }
        return JellyfinClient.imageURL(
            baseURL: baseURL, itemId: item.id, imageType: "Primary", tag: tag,
            accessToken: JellyfinCredentialStore.token(forServerID: server.id)
        )?.absoluteString
    }

    static func symbol(for collectionType: String?) -> String {
        switch collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "boxsets": return "square.stack"
        default: return "folder"
        }
    }
}

/// The current level of `LibraryFoldersModel`: a back chip once below the
/// top, then a list (sources, categories) or a poster grid (titles, folders).
struct LibraryFoldersView: View {
    @ObservedObject var model: LibraryFoldersModel
    let gridColumns: [GridItem]
    /// Where the Mac's caret is: a tile id or `LibraryFoldersModel.backID`.
    var macFocusedID: String? = nil
    /// A title's page is over the Library.
    var isOverlayPresented = false
    /// Bumped when that page has gone, so focus can be put back.
    var overlayClosedGeneration: UInt = 0
    let onOpen: (String, String) -> Void

    @FocusState private var focusedID: String?
    @State private var lastFocusedID: String?
    /// A title was just opened from here, so the page that comes up is ours
    /// (not one opened from another tab while the Library sits behind).
    @State private var openedTitle = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !model.isRoot {
                        backChip.id(LibraryFoldersModel.backID)
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    content
                }
                .padding(.top, 16)
                .padding(.horizontal, 12)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusSection()
            .onChange(of: macFocusedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        #if os(tvOS)
        // Menu steps back a level. Not `onExitCommand`: the tab sidebar takes
        // Menu first. Only while below the top and focus is on these folders:
        // a title's page over the Library, or the open sidebar, gets Menu.
        .background {
            if !model.isRoot {
                MenuPressCatcher(isActive: { focusedID != nil }) { model.pop() }
            }
        }
        #endif
        .task { await model.loadIfNeeded() }
        .onChange(of: focusedID) { _, id in
            guard let id else { return }
            lastFocusedID = id
            if !isOverlayPresented, id == model.restoringID { model.restoringID = nil }
        }
        // A new level: focus its first tile, or on the way back the one
        // that was opened. The tiles appear a frame or two after the
        // request, so it is repeated briefly.
        .onChange(of: model.focusRequest) { _, request in
            guard let request else { return }
            refocus(request.tileID)
        }
        // A title's page hides the Library without disabling it, and on the
        // way back focus would land on the first thing it finds. Lock it to
        // the tile the page was opened from until focus is back on it.
        .onChange(of: isOverlayPresented) { _, presented in
            if presented, openedTitle { model.restoringID = lastFocusedID }
            openedTitle = false
        }
        .onChange(of: overlayClosedGeneration) { _, _ in
            guard let target = model.restoringID else { return }
            refocus(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if model.restoringID == target { model.restoringID = nil }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tiles = model.tiles {
            if tiles.isEmpty {
                Text(model.isRoot
                     ? "Add an IPTV login or a Jellyfin server in Settings to browse its folders here."
                     : "Nothing in this folder.")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if model.usesGrid {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: LibraryGridMetrics.posterGap) {
                    ForEach(tiles) { tile in
                        LibraryFolderCard(tile: tile, focus: $focusedID, macIsFocused: macFocusedID == tile.id) {
                            activate(tile)
                        }
                        .disabled(isLocked(tile.id))
                        .id(tile.id)
                    }
                }
            } else {
                ForEach(tiles) { tile in
                    LibraryFolderRow(tile: tile, focus: $focusedID, macIsFocused: macFocusedID == tile.id) {
                        activate(tile)
                    }
                    .disabled(isLocked(tile.id))
                    .id(tile.id)
                }
            }
        } else {
            BrandLoadingView(wordmarkWidth: 360)
                .frame(maxWidth: .infinity, minHeight: 400)
        }
    }

    private func isLocked(_ id: String) -> Bool {
        model.restoringID != nil && model.restoringID != id
    }

    private var backChip: some View {
        LibraryFolderBackChip(
            title: model.title,
            focus: $focusedID,
            macIsFocused: macFocusedID == LibraryFoldersModel.backID
        ) {
            model.pop()
        }
        .disabled(model.restoringID != nil)
    }

    private func activate(_ tile: LibraryFoldersModel.Tile) {
        lastFocusedID = tile.id
        if let open = model.activate(tile.id) {
            openedTitle = true
            onOpen(open.contentID, open.type)
        }
    }

    private func refocus(_ id: String) {
        lastFocusedID = id
        for delay in [0.05, 0.15, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if lastFocusedID == id { focusedID = id }
            }
        }
    }
}

private struct LibraryFolderBackChip: View {
    let title: String
    let focus: FocusState<String?>.Binding
    let macIsFocused: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private var showsFocus: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return isFocused
        #endif
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(showsFocus ? .black : .white)
            .padding(.horizontal, 24)
            .frame(height: 52)
            .modifier(GlassChipBackground(filled: showsFocus))
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: focus, id: LibraryFoldersModel.backID))
        .focusEffectDisabledIfAvailable()
        .scaleEffect(showsFocus ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: showsFocus)
    }
}

/// A source, library or category: one line, opening the next level.
private struct LibraryFolderRow: View {
    let tile: LibraryFoldersModel.Tile
    let focus: FocusState<String?>.Binding
    let macIsFocused: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private var showsFocus: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return isFocused
        #endif
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let subtitle = tile.subtitle {
                        Text(subtitle)
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if tile.opensLevel {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(showsFocus ? 0.18 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(showsFocus ? AppFocusOutline.color : .clear, lineWidth: showsFocus ? AppFocusOutline.width : 0)
            )
            .scaleEffect(showsFocus ? 1.015 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: focus, id: tile.id))
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.15), value: showsFocus)
    }
}

/// A title or a Jellyfin folder, drawn as the Library's posters are. Folders
/// rarely have artwork, so the name is always shown under the card.
private struct LibraryFolderCard: View {
    let tile: LibraryFoldersModel.Tile
    let focus: FocusState<String?>.Binding
    let macIsFocused: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true

    private var showsFocus: Bool {
        #if os(macOS)
        return macIsFocused
        #else
        return isFocused
        #endif
    }

    private var cornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                CachedPosterArtwork(
                    urlString: tile.poster,
                    width: LibraryGridMetrics.posterWidth,
                    height: LibraryGridMetrics.posterHeight,
                    maximumWidth: LibraryGridMetrics.posterWidth
                ) {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.07))
                        Image(systemName: tile.symbol)
                            .font(.system(size: 44))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .frame(width: LibraryGridMetrics.posterWidth, height: LibraryGridMetrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, isFocused: showsFocus, isEnabled: liquidGlassCards))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(showsFocus ? AppFocusOutline.color : .clear, lineWidth: AppFocusOutline.width)
                )
                .shadow(color: .black.opacity(showsFocus ? 0.5 : 0.2), radius: showsFocus ? 16 : 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(showsFocus ? .white : .white.opacity(0.78))
                        .lineLimit(2)
                    if let subtitle = tile.subtitle {
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
                .frame(width: LibraryGridMetrics.posterWidth, alignment: .leading)
            }
            .scaleEffect(showsFocus ? 1.06 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: focus, id: tile.id))
        .focusEffectDisabledIfAvailable()
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: showsFocus)
        .zIndex(showsFocus ? 1 : 0)
    }
}

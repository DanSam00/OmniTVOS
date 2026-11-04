import SwiftUI
import Combine

/// How a folder's contents are ordered in Library → Folders, on every
/// platform. Kept per profile.
enum FolderSortOrder: String, CaseIterable, Identifiable {
    /// As the provider or server lists them.
    case standard
    case alphabetical
    case reverseAlphabetical
    case recentlyAdded
    case oldestAdded
    case popular
    case newestRelease

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .alphabetical: return "A–Z"
        case .reverseAlphabetical: return "Z–A"
        case .recentlyAdded: return "Recently Added"
        case .oldestAdded: return "Oldest Added"
        case .popular: return "Most Popular"
        case .newestRelease: return "Newest Release"
        }
    }

    static let storageKey = "omni.library.folderSort"

    static var current: FolderSortOrder {
        get { FolderSortOrder(rawValue: ProfileSettings.current.string(forKey: storageKey) ?? "") ?? .standard }
        set { ProfileSettings.current.set(newValue.rawValue, forKey: storageKey) }
    }

    /// Items without the value sorted on go last, in name order; folders stay
    /// ahead of titles. Categories carry only names, so only the A–Z orders
    /// move them.
    func sorted<T>(
        _ items: [T],
        name: (T) -> String,
        isFolder: (T) -> Bool = { _ in false },
        added: (T) -> Date? = { _ in nil },
        rating: (T) -> Double? = { _ in nil },
        year: (T) -> Int? = { _ in nil }
    ) -> [T] {
        guard self != .standard else { return items }
        func byName(_ a: T, _ b: T) -> Bool {
            name(a).localizedStandardCompare(name(b)) == .orderedAscending
        }
        func byValue<V: Comparable>(_ a: T, _ b: T, _ value: (T) -> V?, descending: Bool) -> Bool {
            switch (value(a), value(b)) {
            case let (x?, y?) where x != y: return descending ? x > y : x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return byName(a, b)
            }
        }
        return items.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            if isFolder(a) != isFolder(b) { return isFolder(a) }
            switch self {
            case .standard: return lhs.offset < rhs.offset
            case .alphabetical: return byName(a, b)
            case .reverseAlphabetical: return byName(b, a)
            case .recentlyAdded: return byValue(a, b, added, descending: true)
            case .oldestAdded: return byValue(a, b, added, descending: false)
            case .popular: return byValue(a, b, rating, descending: true)
            case .newestRelease: return byValue(a, b, year, descending: true)
            }
        }.map(\.element)
    }
}

/// Library → Folders drawn as cards (like a collection's folders) or as a
/// list. Kept per profile.
enum FolderViewMode: String, CaseIterable, Identifiable {
    case tiles
    case list

    var id: String { rawValue }
    var title: String { self == .tiles ? "Tiles" : "List" }

    static let storageKey = "omni.library.folderView"

    static var current: FolderViewMode {
        get { FolderViewMode(rawValue: ProfileSettings.current.string(forKey: storageKey) ?? "") ?? .tiles }
        set { ProfileSettings.current.set(newValue.rawValue, forKey: storageKey) }
    }
}

/// IPTV categories the viewer has hidden from Library → Folders. Kept per
/// profile and synced with the account; Settings → IPTV shows them again.
///
/// Keyed by kind and the provider's category id, which stays the same on
/// every device signed in to the same provider. The name is kept only to
/// list the folder in Settings.
enum HiddenLibraryFolders {
    struct Folder: Codable, Hashable, Identifiable {
        /// `IPTVVODBrowser.Kind` raw value.
        let kind: String
        let categoryID: String
        let name: String

        var id: String { "\(kind)|\(categoryID)" }

        var kindTitle: String {
            (IPTVVODBrowser.Kind(rawValue: kind) ?? .movies).title
        }
    }

    static let changedNotification = Notification.Name("omni.hiddenLibraryFolders.changed")

    static func decode(_ raw: String) -> [Folder] {
        guard let data = raw.data(using: .utf8),
              let folders = try? JSONDecoder().decode([Folder].self, from: data)
        else { return [] }
        return folders
    }

    static var all: [Folder] {
        decode(ProfileSettings.current.string(forKey: SettingsKey.hiddenLibraryFolders) ?? "")
    }

    static var hiddenIDs: Set<String> { Set(all.map(\.id)) }

    static func hide(_ folder: Folder) {
        var folders = all.filter { $0.id != folder.id }
        folders.append(folder)
        save(folders)
    }

    static func show(_ folder: Folder) {
        save(all.filter { $0.id != folder.id })
    }

    static func showAll() {
        save([])
    }

    private static func save(_ folders: [Folder]) {
        // An empty list is still written: sync only sends keys that exist,
        // so removing it would leave the account's last list to come back.
        guard let data = try? JSONEncoder().encode(folders), let raw = String(data: data, encoding: .utf8) else { return }
        ProfileSettings.current.set(raw, forKey: SettingsKey.hiddenLibraryFolders)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        // Pushes the change to the account, like any other setting.
        ProfileSettings.notifySettingsChanged()
    }
}

/// `HiddenLibraryFolders` for views. `@AppStorage` does not hear writes made
/// through `ProfileSettings` to a dotted key, so a hidden folder stayed on
/// screen until the view was rebuilt.
@MainActor
final class HiddenLibraryFoldersStore: ObservableObject {
    static let shared = HiddenLibraryFoldersStore()

    @Published private(set) var folders = HiddenLibraryFolders.all
    private var observers: Set<AnyCancellable> = []

    var ids: Set<String> { Set(folders.map(\.id)) }

    private init() {
        NotificationCenter.default.publisher(for: HiddenLibraryFolders.changedNotification)
            .merge(with: NotificationCenter.default.publisher(for: ProfileSettings.settingsChangedNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let folders = HiddenLibraryFolders.all
                if folders != self.folders { self.folders = folders }
            }
            .store(in: &observers)
    }
}

/// The country (or language) an IPTV category is for, read from the code
/// providers put in front of its name: "[EN] ACTION", "UK | SKY CINEMA",
/// "US: NETFLIX", "|AU| KIDS". Library → Folders filters by it.
enum FolderRegion {
    static let storageKey = "omni.library.folderCountry"
    /// The filter's value for titles with no code.
    static let other = "Other"

    /// The filter chosen, by display name; nil for every country.
    static var current: String? {
        get { ProfileSettings.current.string(forKey: storageKey)?.vodNonBlank }
        set { ProfileSettings.current.set(newValue ?? "", forKey: storageKey) }
    }

    /// Codes providers use that are not ISO region codes, or that Locale
    /// names in a way nobody would look for. Languages are named as such.
    private static let names: [String: String] = [
        "UK": "United Kingdom", "GB": "United Kingdom", "EN": "English",
        "US": "United States", "USA": "United States",
        "AU": "Australia", "AUS": "Australia", "NZ": "New Zealand",
        "CA": "Canada", "CAN": "Canada", "IE": "Ireland", "IRL": "Ireland",
        "IN": "India", "IND": "India", "PK": "Pakistan", "BD": "Bangladesh",
        "FR": "France", "FRA": "France", "DE": "Germany", "GER": "Germany", "DEU": "Germany",
        "ES": "Spain", "ESP": "Spain", "IT": "Italy", "ITA": "Italy",
        "NL": "Netherlands", "NLD": "Netherlands", "BE": "Belgium", "BEL": "Belgium",
        "PT": "Portugal", "POR": "Portugal", "BR": "Brazil", "BRA": "Brazil",
        "TR": "Turkey", "TUR": "Turkey", "AR": "Arabic", "ARA": "Arabic", "ARAB": "Arabic",
        "AL": "Albania", "ALB": "Albania", "EXYU": "Ex-Yu", "YU": "Ex-Yu",
        "PL": "Poland", "POL": "Poland", "RO": "Romania", "ROM": "Romania",
        "GR": "Greece", "GRE": "Greece", "SE": "Sweden", "SWE": "Sweden",
        "NO": "Norway", "NOR": "Norway", "DK": "Denmark", "DEN": "Denmark",
        "FI": "Finland", "FIN": "Finland", "RU": "Russia", "RUS": "Russia",
        "LAT": "Latino", "LATAM": "Latino", "MX": "Mexico", "MEX": "Mexico",
        "KR": "Korea", "KOR": "Korea", "JP": "Japan", "JPN": "Japan",
        "CN": "China", "CHN": "China", "AFR": "Africa", "ZA": "South Africa",
        "NG": "Nigeria", "PH": "Philippines", "PHI": "Philippines",
        "CH": "Switzerland", "AT": "Austria", "HU": "Hungary", "CZ": "Czechia",
        "SK": "Slovakia", "BG": "Bulgaria", "HR": "Croatia", "RS": "Serbia",
        "BA": "Bosnia", "MK": "North Macedonia", "SI": "Slovenia",
        "KU": "Kurdish", "KUR": "Kurdish", "PER": "Persian", "IR": "Iran",
        "IL": "Israel", "VN": "Vietnam", "TH": "Thailand", "MY": "Malaysia",
        "ID": "Indonesia", "SG": "Singapore", "CAR": "Caribbean",
        // IPTV conventions that differ from ISO: these are languages or
        // regions, not the countries Locale would name.
        "SC": "Scandinavia", "NORDIC": "Scandinavia", "SW": "Sweden",
        "GE": "Germany", "KO": "Korea", "PTBR": "Brazil",
        "MULTI": "Multi-Language", "MULTILANG": "Multi-Language",
    ]

    /// Two letters that look like a code but are not one.
    private static let notCodes: Set<String> = ["TV", "HD", "SD", "UHD", "FHD", "VIP", "PPV", "VOD", "NEW", "TOP", "ALL", "XXX", "OK"]

    /// "[EN]", "UK |", "US:", "|AU|", "EN -": a short capitalised code
    /// closed off from the rest of the name.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*[\[\(\|▎┃]?\s*([A-Z]{2,6}(?:-[A-Z]{2,4})?)\s*(?:[\]\)\|▎┃:]|\s[-–]\s)"#
    )

    /// The display name for a category's code, or nil when it has none.
    static func of(_ name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = pattern.firstMatch(in: name, range: range),
              let codeRange = Range(match.range(at: 1), in: name)
        else { return nil }
        let code = name[codeRange].replacingOccurrences(of: "-", with: "")
        guard !notCodes.contains(code) else { return nil }
        // CH is Switzerland, except to the providers that file China there.
        if code == "CH" { return name.uppercased().contains("CHIN") ? "China" : "Switzerland" }
        if let known = names[code] { return known }
        guard code.count == 2 else { return nil }
        return Locale(identifier: "en").localizedString(forRegionCode: code)
    }

    /// The filter's choices for these names, by name; nil when there is
    /// nothing to choose between.
    static func choices(for names: [String]) -> [String]? {
        var regions = Set<String>()
        var hasOther = false
        for name in names {
            if let region = of(name) { regions.insert(region) } else { hasOther = true }
        }
        guard !regions.isEmpty, regions.count + (hasOther ? 1 : 0) > 1 else { return nil }
        let sorted = regions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return hasOther ? sorted + [other] : sorted
    }

    static func matches(_ name: String, region: String) -> Bool {
        (of(name) ?? other) == region
    }
}

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
        var added: Date? = nil
        var rating: Double? = nil
        var year: Int? = nil
        /// An IPTV category, which the viewer can hide.
        var hideable: HiddenLibraryFolders.Folder? = nil

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
    /// The current level's tiles, in the chosen order; nil while they load.
    @Published private(set) var tiles: [Tile]?
    @Published var sort = FolderSortOrder.current {
        didSet {
            FolderSortOrder.current = sort
            refilter()
        }
    }
    @Published var viewMode = FolderViewMode.current {
        didSet { FolderViewMode.current = viewMode }
    }
    /// The country filter, by name; nil for every country. Kept when a level
    /// has none of it, and only applied where it has.
    @Published var region = FolderRegion.current {
        didSet {
            FolderRegion.current = region
            refilter()
        }
    }
    /// The countries this level's folders are for; nil when they are all
    /// for one, or name none.
    @Published private(set) var regionChoices: [String]?
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
    private var hiddenIDs = HiddenLibraryFolders.hiddenIDs
    private var observers: Set<AnyCancellable> = []

    init() {
        // Hidden here, shown again in Settings, or changed on another device.
        NotificationCenter.default.publisher(for: HiddenLibraryFolders.changedNotification)
            .merge(with: NotificationCenter.default.publisher(for: ProfileSettings.settingsChangedNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let ids = HiddenLibraryFolders.hiddenIDs
                guard ids != self.hiddenIDs else { return }
                self.hiddenIDs = ids
                self.refilter()
            }
            .store(in: &observers)
    }

    /// The country filter in effect on this level.
    var activeRegion: String? {
        guard let region, regionChoices?.contains(region) == true else { return nil }
        return region
    }

    /// Whether there is anything to browse: the Library only offers Folders then.
    static var isAvailable: Bool {
        !IPTVVODBrowser.sources().isEmpty || !JellyfinServerStore.shared.servers.isEmpty
    }

    var level: Level { path.last ?? .root }
    var isRoot: Bool { path.count <= 1 }

    /// Titles and Jellyfin folders: posters as tiles. Sources and
    /// categories are folders.
    var holdsTitles: Bool {
        switch level {
        case .root, .iptvCategories: return false
        case .iptvEntries, .jellyfin: return true
        }
    }

    /// A grid of cards rather than a list of rows.
    var usesGrid: Bool { viewMode == .tiles }

    /// Folder cards a row, in Tiles (fixed, so the Mac's caret can count them).
    static let folderTileColumns = 4

    /// What the level shows: without hidden folders, in the chosen country
    /// and order.
    private func present(_ loaded: [Tile]) -> [Tile] {
        let visible = loaded.filter { tile in
            guard let folder = tile.hideable else { return true }
            return !hiddenIDs.contains(folder.id)
        }
        regionChoices = FolderRegion.choices(for: visible.map(\.title))
        let shown = activeRegion.map { region in visible.filter { FolderRegion.matches($0.title, region: region) } } ?? visible
        return sorted(shown)
    }

    private func refilter() {
        if let loaded = cache[level] { tiles = present(loaded) }
    }

    /// Takes an IPTV category out of Folders; Settings → IPTV brings it back.
    func hide(_ tileID: String) {
        guard let folder = tiles?.first(where: { $0.id == tileID })?.hideable else { return }
        HiddenLibraryFolders.hide(folder)
        notice = "“\(folder.name)” is hidden. Show it again in Settings → IPTV."
    }

    private func sorted(_ tiles: [Tile]) -> [Tile] {
        sort.sorted(
            tiles,
            name: \.title,
            isFolder: { $0.opensLevel && Self.holdsTitles($0) },
            added: \.added,
            rating: \.rating,
            year: \.year
        )
    }

    /// A folder among titles (a Jellyfin subfolder), kept ahead of them.
    private static func holdsTitles(_ tile: Tile) -> Bool {
        if case .push(.jellyfin) = tile.action { return true }
        return false
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
            tiles = present(cached)
            requestFocus(in: tiles ?? [], level: level)
            return
        }
        tiles = nil
        regionChoices = nil
        let loaded = Self.unique(await Self.tiles(for: level))
        cache[level] = loaded
        guard self.level == level else { return }
        tiles = present(loaded)
        requestFocus(in: tiles ?? [], level: level)
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
                    action: .push(.iptvEntries(sourceID: sourceID, kind: kind, categoryID: category.id, title: category.name)),
                    hideable: HiddenLibraryFolders.Folder(kind: kind.rawValue, categoryID: category.id, name: category.name)
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
                    action: .open(contentID: entry.contentID, type: entry.type),
                    added: entry.added,
                    rating: entry.rating,
                    year: entry.year
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
                            : .notice("\(item.name) is in a library Omni hasn't synced. Turn that library on in Settings → Jellyfin, then sync."),
                        added: item.added,
                        rating: item.rating,
                        year: item.year
                    )
                }
                guard item.isFolder else { return nil }
                return Tile(
                    id: item.id,
                    title: item.name,
                    subtitle: nil,
                    poster: poster,
                    symbol: "folder.fill",
                    action: .push(.jellyfin(serverID: server.id, folderID: item.id, title: item.name)),
                    added: item.added
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
    /// A folder's hold-Select menu is up. tvOS hands the Menu press that
    /// closes it to the screen as well, which would step back a level.
    @State private var folderMenuShown = false

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
            // A fresh scroll view per level and layout. Kept across them, a
            // short level opened from deep in a long one sat scrolled past its
            // own end: loaded, but blank until the Library was rebuilt.
            .id("\(model.path.count)|\(model.level.hashValue)|\(model.viewMode.rawValue)")
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
                MenuPressCatcher(isActive: { focusedID != nil }) {
                    if folderMenuShown {
                        folderMenuShown = false
                    } else {
                        model.pop()
                    }
                }
            }
        }
        #endif
        .task { await model.loadIfNeeded() }
        .onChange(of: focusedID) { _, id in
            guard let id else { return }
            if id != lastFocusedID { folderMenuShown = false }
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
            } else if model.usesGrid, !model.holdsTitles {
                // Sources and categories as a collection's folders are drawn.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: LibraryFoldersModel.folderTileColumns),
                    alignment: .leading,
                    spacing: 28
                ) {
                    ForEach(tiles) { tile in
                        LibraryFolderTile(
                            tile: tile, focus: $focusedID, macIsFocused: macFocusedID == tile.id,
                            onHide: hideAction(tile), onMenuShown: { folderMenuShown = true }
                        ) {
                            activate(tile)
                        }
                        .disabled(isLocked(tile.id))
                        .id(tile.id)
                    }
                }
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
                    LibraryFolderRow(
                        tile: tile, focus: $focusedID, macIsFocused: macFocusedID == tile.id,
                        onHide: hideAction(tile), onMenuShown: { folderMenuShown = true }
                    ) {
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

    private func hideAction(_ tile: LibraryFoldersModel.Tile) -> (() -> Void)? {
        guard tile.hideable != nil else { return nil }
        return {
            folderMenuShown = false
            model.hide(tile.id)
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
    var onHide: (() -> Void)? = nil
    var onMenuShown: () -> Void = {}
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
                if tile.poster != nil || !tile.opensLevel {
                    // A title in List: its poster, small.
                    CachedPosterArtwork(urlString: tile.poster, width: 64, height: 96, maximumWidth: 64) {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.07))
                            Image(systemName: tile.symbol)
                                .font(.system(size: 22))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .frame(width: 64, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: tile.symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 44)
                }

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
        .modifier(FolderHideMenu(title: tile.title, macIsFocused: macIsFocused, onHide: onHide, onMenuShown: onMenuShown))
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

/// A source, library or category in Tiles, drawn as a collection's folders
/// are on Home: a glass card with its symbol, and its name on it, since
/// these folders have no artwork of their own.
private struct LibraryFolderTile: View {
    let tile: LibraryFoldersModel.Tile
    let focus: FocusState<String?>.Binding
    let macIsFocused: Bool
    var onHide: (() -> Void)? = nil
    var onMenuShown: () -> Void = {}
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

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
            ZStack(alignment: .topLeading) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white.opacity(showsFocus ? 0.9 : 0.55))
                    .padding(24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle = tile.subtitle {
                        Text(subtitle)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .modifier(LiquidGlassSurface(cornerRadius: cornerRadius, prominent: showsFocus))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(showsFocus ? AppFocusOutline.color : .clear, lineWidth: AppFocusOutline.width)
            )
            .shadow(color: .black.opacity(showsFocus ? 0.5 : 0.2), radius: showsFocus ? 16 : 6)
            .scaleEffect(showsFocus ? 1.04 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: focus, id: tile.id))
        .focusEffectDisabledIfAvailable()
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: showsFocus)
        .zIndex(showsFocus ? 1 : 0)
        .modifier(FolderHideMenu(title: tile.title, macIsFocused: macIsFocused, onHide: onHide, onMenuShown: onMenuShown))
    }
}

/// "Hide Folder" on an IPTV category: hold Select on the Apple TV,
/// right-click or ⌥↩ on the Mac. Nothing on folders that can't be hidden.
private struct FolderHideMenu: ViewModifier {
    let title: String
    let macIsFocused: Bool
    let onHide: (() -> Void)?
    let onMenuShown: () -> Void

    static let label = "Hide Folder"

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onHide {
            content
                #if os(tvOS)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onMenuShown() })
                #endif
                .contextMenu {
                    Button(role: .destructive) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onHide)
                    } label: {
                        Label(Self.label, systemImage: "eye.slash")
                    }
                }
                .macContextMenu(title: title, isFocused: macIsFocused) {
                    [ContextAction(label: Self.label, isDestructive: true, perform: onHide)]
                }
        } else {
            content
        }
    }
}

/// Tiles or List, as two icons side by side; the chosen one is filled.
struct FolderViewSwitch: View {
    @Binding var mode: FolderViewMode
    /// Which icon the Mac's caret is on (`macItemID(for:)`), if either.
    var macFocusedItem: String? = nil

    static func macItemID(for mode: FolderViewMode) -> String { "folderView.\(mode.rawValue)" }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FolderViewMode.allCases) { option in
                FolderViewSwitchButton(
                    option: option,
                    isSelected: mode == option,
                    macIsFocused: macFocusedItem == Self.macItemID(for: option)
                ) {
                    mode = option
                }
            }
        }
        .padding(4)
        .modifier(GlassChipBackground(filled: false))
    }
}

private struct FolderViewSwitchButton: View {
    let option: FolderViewMode
    let isSelected: Bool
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
            Image(systemName: option == .tiles ? "square.grid.2x2.fill" : "list.bullet")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(isSelected ? .black : .white.opacity(showsFocus ? 1 : 0.75))
                .frame(width: 64, height: 52)
                .background(Capsule().fill(Color.white.opacity(isSelected ? 1 : (showsFocus ? 0.18 : 0))))
                .overlay(
                    Capsule()
                        .strokeBorder(showsFocus ? AppFocusOutline.color : .clear, lineWidth: showsFocus ? AppFocusOutline.width : 0)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .nuvioFocusable()
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(showsFocus ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: showsFocus)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .accessibilityLabel(option.title)
    }
}

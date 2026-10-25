import Foundation
import Combine

/// Which titles come from 18+ add-ons, so Search and Continue Watching can
/// leave them out.
///
/// Learnt from each add-on manifest as Omni loads it (`StremioManifestDataCache`):
/// an add-on is adult when its manifest says so (`behaviorHints.adult`, as TPB
/// and Porn Tube do) or its name reads that way; a catalog is adult when its
/// add-on is, or its own name does ("Philippines R-18 Movies"). A title is
/// then adult by
/// - its type, when only adult add-ons list that type ("Porn", "JAV"),
/// - its id prefix, when only adult add-ons declare it ("ptx:", "jstrm:";
///   TPB's "mal:" is Anime Kitsu's too, so it does not count), or
/// - its id having been listed by an adult catalog: Pinoy's R-18 films carry
///   plain IMDb ids, which nothing else would give away.
/// All of it is kept in Caches, so Continue Watching can tell at launch,
/// before any manifest has loaded.
final class AdultContent: @unchecked Sendable {
    static let shared = AdultContent()

    private struct Addon: Codable {
        let url: String
        let adult: Bool
        let types: [String]
        let prefixes: [String]
        /// "type|catalogId" of each adult catalog.
        let adultCatalogs: [String]
        /// Types of the add-on's catalogs that are not adult.
        let otherCatalogTypes: [String]
    }

    private struct Stored: Codable {
        var addons: [String: Addon] = [:]
        var ids: [String] = []
    }

    private let lock = NSLock()
    private var addons: [String: Addon] = [:]
    /// Keyed by the manifest's folder URL, which catalog requests are built on.
    private var addonByBase: [String: Addon] = [:]
    private var ids = Set<String>()
    private var idOrder: [String] = []
    private var adultTypes = Set<String>()
    private var adultPrefixes: [String] = []
    private var saveScheduled = false

    private static let maxIds = 20_000
    /// Types no ordinary add-on uses.
    private static let knownAdultTypes: Set<String> = ["porn", "jav", "hentai", "xxx", "adult"]
    private static let hints = ["r-18", "r18", "18+", "xxx", "porn", "adult", "nsfw", "hentai"]

    private init() {
        guard let file = Self.file, let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        addons = stored.addons
        idOrder = stored.ids
        ids = Set(stored.ids)
        rebuild()
    }

    // MARK: Asking

    func isAdult(_ meta: NuvioMeta) -> Bool {
        isAdult(id: meta.id, type: meta.type)
    }

    func isAdult(id: String, type: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if adultTypes.contains(type.lowercased()) || ids.contains(id) { return true }
        let lowered = id.lowercased()
        return adultPrefixes.contains { Self.id(lowered, hasPrefix: $0) }
    }

    /// Whether any installed add-on or catalog is 18+; the toggles only
    /// show when there is something for them to hide.
    var hasAdultSources: Bool {
        lock.lock()
        defer { lock.unlock() }
        return addonByBase.values.contains { $0.adult || !$0.adultCatalogs.isEmpty }
    }

    /// An adult add-on's catalog, or one named that way.
    func isAdultCatalog(addonId: String, type: String, catalogId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if adultTypes.contains(type.lowercased()) { return true }
        guard let addon = addons[addonId] else { return false }
        return addon.adult || addon.adultCatalogs.contains("\(type)|\(catalogId)")
    }

    /// A prefix ends in a separator ("ptx:", "mp-"), or it is followed by one
    /// or a digit: Porn Tube's bare "pt" must not catch every id that happens
    /// to start with those letters.
    private static func id(_ id: String, hasPrefix prefix: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        if let last = prefix.last, ":-_".contains(last) { return true }
        guard let next = id.dropFirst(prefix.count).first else { return false }
        return next.isNumber || ":-_".contains(next)
    }

    // MARK: Learning

    /// Reads a manifest as it is fetched.
    func learn(manifest data: Data, from url: URL) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["id"] as? String else { return }
        let name = json["name"] as? String ?? ""
        let hints = json["behaviorHints"] as? [String: Any]
        let adult = (hints?["adult"] as? Bool) == true || Self.readsAdult(name)
        var adultCatalogs: [String] = []
        var otherTypes: [String] = []
        for catalog in json["catalogs"] as? [[String: Any]] ?? [] {
            guard let type = catalog["type"] as? String, let catalogId = catalog["id"] as? String else { continue }
            if adult || Self.readsAdult(catalog["name"] as? String ?? "") {
                adultCatalogs.append("\(type)|\(catalogId)")
            } else {
                otherTypes.append(type)
            }
        }
        let addon = Addon(
            url: Self.base(of: url),
            adult: adult,
            types: (json["types"] as? [String]) ?? [],
            prefixes: ((json["idPrefixes"] as? [String]) ?? []).map { $0.lowercased() },
            adultCatalogs: adultCatalogs,
            otherCatalogTypes: otherTypes
        )
        lock.lock()
        addons[id] = addon
        rebuild()
        lock.unlock()
        scheduleSave()
    }

    /// Remembers what an adult catalog listed that type and prefix do not
    /// already give away.
    func note(_ metas: [NuvioMeta], base: URL, type: String, catalogId: String) {
        guard !metas.isEmpty else { return }
        lock.lock()
        guard let addon = addonByBase[Self.base(of: base)],
              addon.adult || addon.adultCatalogs.contains("\(type)|\(catalogId)") else {
            lock.unlock()
            return
        }
        var added = false
        for meta in metas where !ids.contains(meta.id) {
            let lowered = meta.id.lowercased()
            if adultTypes.contains(meta.type.lowercased())
                || adultPrefixes.contains(where: { Self.id(lowered, hasPrefix: $0) }) { continue }
            ids.insert(meta.id)
            idOrder.append(meta.id)
            added = true
        }
        if idOrder.count > Self.maxIds {
            let dropped = idOrder.prefix(idOrder.count - Self.maxIds)
            ids.subtract(dropped)
            idOrder.removeFirst(dropped.count)
        }
        lock.unlock()
        if added { scheduleSave() }
    }

    private static func readsAdult(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return hints.contains { lowered.contains($0) }
    }

    /// Called with the lock held.
    private func rebuild() {
        let installed = Set(CinemetaCatalogRepository.configuredStreamAddonManifestURLs.map { Self.base(of: $0) })
        // Add-ons since removed no longer count, on either side.
        let current = addons.values.filter { installed.isEmpty || installed.contains($0.url) }
        addonByBase = Dictionary(current.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })

        var types = Self.knownAdultTypes
        var otherTypes = Set<String>()
        var prefixes = Set<String>()
        var otherPrefixes = Set<String>()
        for addon in current {
            for entry in addon.adultCatalogs {
                if let type = entry.split(separator: "|").first { types.insert(type.lowercased()) }
            }
            otherTypes.formUnion(addon.otherCatalogTypes.map { $0.lowercased() })
            if addon.adult {
                types.formUnion(addon.types.map { $0.lowercased() })
                prefixes.formUnion(addon.prefixes)
            } else {
                otherTypes.formUnion(addon.types.map { $0.lowercased() })
                otherPrefixes.formUnion(addon.prefixes.map(Self.stem))
            }
        }
        // "series" or "movie" from an adult add-on would hide everything, and
        // "live" every channel: TPB lists its cams as "Live", which their
        // "sc:" ids already give away.
        adultTypes = types.subtracting(otherTypes)
            .subtracting(["movie", "series", "tv", "channel", "live", "anime", "other"])
        adultPrefixes = prefixes.filter { !otherPrefixes.contains(Self.stem($0)) && Self.stem($0).count >= 2 }
    }

    /// "mal:" and "mal" are the same prefix.
    private static func stem(_ prefix: String) -> String {
        prefix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":-_"))
    }

    private static func base(of url: URL) -> String {
        var text = url.absoluteString
        if text.hasSuffix("manifest.json") { text = String(text.dropLast("manifest.json".count)) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: Storage

    private static var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("adult-content.json")
    }

    private func scheduleSave() {
        lock.lock()
        guard !saveScheduled else {
            lock.unlock()
            return
        }
        saveScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            saveScheduled = false
            let stored = Stored(addons: addons, ids: idOrder)
            lock.unlock()
            guard let file = Self.file, let data = try? JSONEncoder().encode(stored) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// Whether 18+ titles show, separately for Search and Continue Watching.
/// Off at every launch: nothing is saved, so each session starts hidden.
@MainActor
final class NSFWVisibility: ObservableObject {
    static let shared = NSFWVisibility()

    @Published var showsInSearch = false
    @Published var showsInContinueWatching = false {
        didSet { NotificationCenter.default.post(name: Self.continueWatchingChanged, object: nil) }
    }
    /// Adult titles in Continue Watching, shown or not; the toggle only
    /// appears when there are some.
    @Published private(set) var continueWatchingAdultCount = 0

    static let continueWatchingChanged = Notification.Name("omni.nsfw.continueWatchingChanged")
    /// The Apple TV and Mac row's toggle card.
    static let toggleCardID = "omni.nsfw.toggle"

    private init() {}

    func searchFiltered(_ metas: [NuvioMeta]) -> [NuvioMeta] {
        guard !showsInSearch else { return metas }
        let kept = metas.filter { !AdultContent.shared.isAdult($0) }
        #if os(macOS)
        if kept.count != metas.count { MacDiagnostics.log("nsfw.search hidden=\(metas.count - kept.count) of=\(metas.count)") }
        #endif
        return kept
    }

    /// Continue Watching without its adult titles unless they are shown, and
    /// counts them for the toggle.
    func continueWatchingFiltered(_ items: [ContinueWatchingItem]) -> [ContinueWatchingItem] {
        let adult = items.filter { AdultContent.shared.isAdult($0.meta) }
        if continueWatchingAdultCount != adult.count {
            continueWatchingAdultCount = adult.count
            #if os(macOS)
            MacDiagnostics.log("nsfw.cw adult=\(adult.count) of=\(items.count) shown=\(showsInContinueWatching)")
            #endif
        }
        guard !showsInContinueWatching, !adult.isEmpty else { return items }
        return items.filter { !AdultContent.shared.isAdult($0.meta) }
    }

    /// The carousel's toggle slide, after its titles.
    var toggleSlide: ContinueWatchingItem {
        ContinueWatchingItem(
            meta: toggleCardMeta,
            streamUrl: "",
            position: 0,
            duration: 1,
            lastWatchedAt: .distantPast,
            cardKind: Self.toggleCardID
        )
    }

    /// The Apple TV and Mac row's toggle card: a plain title card at the end.
    var toggleCardMeta: NuvioMeta {
        NuvioMeta(
            id: Self.toggleCardID,
            name: showsInContinueWatching
                ? L10n.string("nsfw_hide_cw", fallback: "Hide 18+")
                : L10n.format("nsfw_show_cw", fallback: "Show 18+ (%d)", continueWatchingAdultCount),
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: "other",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }
}

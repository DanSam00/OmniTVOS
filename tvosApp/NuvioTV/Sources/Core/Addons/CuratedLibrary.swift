import Foundation

/// The add-ons and collections Omni (the public app) uses to organise what it
/// shows, fixed in code.
///
/// Nothing here supplies a stream. Add-ons are used for catalogs and metadata
/// only, collections are rows of TMDB/Trakt/MDBList/catalog titles, and the
/// things that can actually be played come from the viewer's own IPTV
/// (Xtream / M3U), Jellyfin and SMB sources.
///
/// The viewer cannot see, add, remove or reorder any of this: Settings has no
/// Add-ons or Collections page in Omni, account sync neither reads nor writes
/// them, and `CinemetaCatalogRepository.configuredStreamAddonPreferences`
/// returns this list whatever is stored. Omni X is unaffected.
enum CuratedLibrary {
    // MARK: Catalog / metadata add-ons

    static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"
    static let rottenTomatoes = "https://7a82163c306e-rottentomatoes.baby-beamup.club/manifest.json"

    /// Regular profiles.
    static let catalogAddonURLs: [String] = [
        cinemeta,
        rottenTomatoes,
    ]

    /// Kids profiles: metadata only, no reviews or critics' rows.
    static let kidsCatalogAddonURLs: [String] = [
        cinemeta,
    ]

    /// Rotten Tomatoes' two rows, shown on Home by default.
    static let homeCatalogKeys: [String] = OmniDefaultAddons.homeCatalogKeys

    static func addonPreferences(forKids kids: Bool) -> [StreamAddonPreference] {
        (kids ? kidsCatalogAddonURLs : catalogAddonURLs).map {
            StreamAddonPreference(url: $0, enabled: true)
        }
    }

    /// Whether a manifest URL is one of the fixed add-ons (either profile type).
    static func isCuratedAddon(_ url: String) -> Bool {
        let wanted = url.lowercased()
        return (catalogAddonURLs + kidsCatalogAddonURLs).contains { $0.lowercased() == wanted }
    }

    // MARK: Collections

    /// Collection entries (nuvio.tv community-collections ids) every regular
    /// profile gets, in this order.
    static let regularCollections: [(id: String, title: String)] = [
        ("kaptain-s-mega-collection-v0-4", "Kaptain's Mega Collection"),
    ]

    /// Kids profiles fetch none: they get `KidsStarterTemplate`, the
    /// approved kids set built into the app, so a new kids profile has its
    /// collections even when nuvio.tv does not answer.
    static let kidsCollections: [(id: String, title: String)] = []

    /// Bump when the lists above change so profiles re-install them.
    static let version = 1
}

#if !OMNI_X
extension CuratedLibrary {
    private static let installedVersionKey = "omni.curated.installedVersion"

    /// Puts the fixed collections on the current profile: the TMDB-built
    /// Streaming Services, Studios & Franchises and Genres rows, then the
    /// curated community collections (regular or kids). Runs once per
    /// `version` per profile; a profile that is signed out of Nuvio gets the
    /// built-in rows now and the community ones the next time it is opened.
    @MainActor
    @discardableResult
    static func installCollectionsIfNeeded() async -> Int {
        let store = ProfileSettings.current
        guard store.integer(forKey: installedVersionKey) < version else { return 0 }
        let kids = store.bool(forKey: SettingsKey.kidsProfile)

        var rows: [[String: Any]] = []
        func add(_ id: String, _ payload: [String: Any]) {
            var row = payload
            row["id"] = id
            rows.append(row)
        }
        add("omni.curated.streaming-services",
            StreamingServicesCollectionTemplate.payload(logoURLs: StreamingServicesCollectionTemplate.fallbackLogoURLs))
        add("omni.curated.studios-franchises", StudiosFranchisesCollectionTemplate.payload())
        add("omni.curated.genres", DiscoverGenresCollectionTemplate.payload())
        if kids { rows = CommunityCollections.forKids(rows) + KidsStarterTemplate.collections }

        var communityComplete = true
        for entry in (kids ? kidsCollections : regularCollections) {
            let item = CommunityCollections.Item(
                id: entry.id, title: entry.title, description: "", tags: [],
                imageURL: nil, likes: 0, installs: 0, isPack: false
            )
            guard let fetched = try? await CommunityCollections.collections(for: item) else {
                communityComplete = false
                continue
            }
            rows += kids
                ? CommunityCollections.forKids(
                    fetched,
                    madeForKids: CommunityCollections.entryIsMadeForKids(title: item.title)
                )
                : fetched
        }

        // Replace by id so a later version updates rows in place.
        var current = CollectionsStore.rawCollections()
        for row in rows {
            if let id = row["id"] as? String, let index = current.firstIndex(where: { ($0["id"] as? String) == id }) {
                current[index] = row
            } else {
                current.append(row)
            }
        }
        CollectionsStore.saveLocalEdit(current)
        if communityComplete { store.set(version, forKey: installedVersionKey) }
        return rows.count
    }
}
#endif

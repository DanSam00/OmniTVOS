import Foundation

/// A community / curated Stremio add-on that can be one-tap installed.
struct CommunityAddon: Identifiable, Equatable, Codable {
    var id: String { manifestURL }
    let name: String
    let description: String
    let manifestURL: String
    let categories: [String]
    let logoURL: String?

    init(
        name: String,
        description: String,
        manifestURL: String,
        categories: [String] = [],
        logoURL: String? = nil
    ) {
        self.name = name
        self.description = description
        self.manifestURL = manifestURL
        self.categories = categories
        self.logoURL = logoURL
    }
}

/// Loads a remote community catalog when available, otherwise a curated fallback.
enum CommunityAddonCatalog {
    /// Public collection used by several Stremio clients. Fails soft to curated list.
    private static let remoteURL = URL(string: "https://stremio-addons.com/catalog.json")

    static let curated: [CommunityAddon] = [
        CommunityAddon(
            name: "Torrentio",
            description: "Popular torrent stream aggregator with debrid support",
            manifestURL: "https://torrentio.strem.fun/manifest.json",
            categories: ["Streams", "Torrents"]
        ),
        CommunityAddon(
            name: "Cinemeta",
            description: "Default movies & series metadata catalog",
            manifestURL: "https://v3-cinemeta.strem.io/manifest.json",
            categories: ["Catalog", "Metadata"]
        ),
        CommunityAddon(
            name: "OpenSubtitles v3",
            description: "Community subtitle add-on",
            manifestURL: "https://opensubtitles-v3.strem.io/manifest.json",
            categories: ["Subtitles"]
        ),
        CommunityAddon(
            name: "AIO Metadata",
            description: "Rich metadata catalogs for movies and series",
            manifestURL: "https://aiometadata.elfhosted.com/manifest.json",
            categories: ["Catalog", "Metadata"]
        ),
        CommunityAddon(
            name: "Comet",
            description: "Debrid-oriented stream aggregator",
            manifestURL: "https://comet.elfhosted.com/manifest.json",
            categories: ["Streams", "Debrid"]
        ),
        CommunityAddon(
            name: "MediaFusion",
            description: "Multi-source streams with debrid integrations",
            manifestURL: "https://mediafusion.elfhosted.com/manifest.json",
            categories: ["Streams"]
        ),
        CommunityAddon(
            name: "Annatar",
            description: "Torrent + debrid stream provider",
            manifestURL: "https://annatar.elfhosted.com/manifest.json",
            categories: ["Streams"]
        ),
        CommunityAddon(
            name: "Jackettio",
            description: "Jackett-backed torrent streams (self-host / public instances)",
            manifestURL: "https://jackettio.elfhosted.com/manifest.json",
            categories: ["Streams", "Torrents"]
        )
    ]

    static func load(preferRemote: Bool = true) async -> [CommunityAddon] {
        if preferRemote, let remote = await fetchRemote() {
            return merge(remote: remote, curated: curated)
        }
        return curated
    }

    /// Installs (or re-enables) a community add-on and notifies account sync.
    @discardableResult
    static func install(manifestURL raw: String) -> Bool {
        guard let url = CinemetaCatalogRepository.normalizedManifestURL(from: raw) else {
            return false
        }
        var preferences = CinemetaCatalogRepository.configuredStreamAddonPreferences
        if let index = preferences.firstIndex(where: { $0.url == url.absoluteString }) {
            preferences[index].enabled = true
        } else {
            preferences.append(StreamAddonPreference(url: url.absoluteString, enabled: true))
        }
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(preferences)
        NotificationCenter.default.post(
            name: NuvioSyncManager.addonOrderChangedNotification,
            object: preferences
        )
        return true
    }

    static func isInstalled(_ manifestURL: String) -> Bool {
        guard let url = CinemetaCatalogRepository.normalizedManifestURL(from: manifestURL) else {
            return false
        }
        return CinemetaCatalogRepository.configuredStreamAddonPreferences.contains {
            $0.url == url.absoluteString && $0.enabled
        }
    }

    // MARK: - Remote

    private static func fetchRemote() async -> [CommunityAddon]? {
        guard let remoteURL else { return nil }
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return parseRemote(data)
        } catch {
            return nil
        }
    }

    /// Tolerant parser for several community-catalog JSON shapes.
    private static func parseRemote(_ data: Data) -> [CommunityAddon]? {
        if let list = try? JSONDecoder().decode([RemoteAddonDTO].self, from: data) {
            let mapped = list.compactMap { $0.toCommunityAddon() }
            return mapped.isEmpty ? nil : mapped
        }
        if let wrapper = try? JSONDecoder().decode(RemoteCatalogWrapper.self, from: data) {
            let source = wrapper.addons ?? wrapper.catalog ?? wrapper.results ?? []
            let mapped = source.compactMap { $0.toCommunityAddon() }
            return mapped.isEmpty ? nil : mapped
        }
        return nil
    }

    private static func merge(remote: [CommunityAddon], curated: [CommunityAddon]) -> [CommunityAddon] {
        var seen = Set<String>()
        var result: [CommunityAddon] = []
        for addon in curated + remote {
            let key = addon.manifestURL.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(addon)
        }
        return result
    }
}

// MARK: - Remote DTOs

private struct RemoteCatalogWrapper: Decodable {
    let addons: [RemoteAddonDTO]?
    let catalog: [RemoteAddonDTO]?
    let results: [RemoteAddonDTO]?
}

private struct RemoteAddonDTO: Decodable {
    let name: String?
    let manifestName: String?
    let description: String?
    let manifest: String?
    let manifestURL: String?
    let url: String?
    let transportUrl: String?
    let categories: [String]?
    let logo: String?
    let logoURL: String?

    func toCommunityAddon() -> CommunityAddon? {
        let manifest = [manifestURL, manifest, transportUrl, url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let manifest, !manifest.isEmpty else { return nil }
        let title = (name ?? manifestName ?? URL(string: manifest)?.host ?? "Add-on")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommunityAddon(
            name: title.isEmpty ? "Add-on" : title,
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            manifestURL: manifest,
            categories: categories ?? [],
            logoURL: logoURL ?? logo
        )
    }
}

/// Add-ons every Omni account starts with, on top of whatever Nuvio gives a
/// new account. Added once per account profile — the first sync in Omni — so
/// one the user later removes stays removed.
enum OmniDefaultAddons {
    static let manifestURLs: [String] = [
        // Nuvio Live Sports
        "https://nuviosports.xyz/manifest.json",
        // More Live Sports
        "https://sports.highfly.to/eyJpbmNsdWRlU3BvcnRzIjpbImJhc2tldGJhbGwiLCJmb290YmFsbCIsImFtZXJpY2FuLWZvb3RiYWxsIiwibW90b3Itc3BvcnRzIiwiZmlnaHQiLCJiYXNlYmFsbCIsImhvY2tleSIsInRlbm5pcyIsInJ1Z2J5IiwiZ29sZiIsImJpbGxpYXJkcyIsImFmbCIsImRhcnRzIiwiY3JpY2tldCIsIm90aGVyIl19/manifest.json",
        // Cinemeta
        "https://v3-cinemeta.strem.io/manifest.json",
        // AU TV
        "https://kangaroostreams.hayd.uk/Brisbane/radio/ausports/nz/nzradio/nzsports/uktv/uksports/ustv/ussports/catv/casports/eusports/worldsports/epl/extras/exgrp-ca-dazn/exgrp-int-netflix-events/exgrp-int-dirtvision/exgrp-uk-epl/exgrp-uk-dazn/exgrp-au-kayo-sports/exgrp-uk-tnt-sports/exgrp-uk-sky-sports/exgrp-nz-sky-sport/exgrp-int-f1-tv/exgrp-uk-spfl/exgrp-int-rugby-events/exgrp-au-stan-sports-events/exgrp-ppv-events/manifest.json",
        // YouTube
        "https://v3-channels.strem.io/manifest.json",
        // WatchHub
        "https://watchhub.strem.io/manifest.json",
        // Rotten Tomatoes
        "https://7a82163c306e-rottentomatoes.baby-beamup.club/manifest.json",
    ]

    /// Rotten Tomatoes' two catalogs, put on Home rather than held back the way
    /// a new add-on's catalogs otherwise are.
    static let homeCatalogKeys: [String] = [
        "pw.ers.rottentomatoes_movie_rtfresh_movie",
        "pw.ers.rottentomatoes_series_rtfresh_series",
    ]

    /// One-time steps, recorded per account profile on this device.
    enum Step: String {
        /// The add-ons, pushed to the profile that owns them.
        case addons
        /// The Rotten Tomatoes rows, put on this profile's Home.
        case homeRows
    }

    private static func key(_ step: Step, userId: String, remoteProfileId: Int) -> String {
        "omni.defaults.\(step.rawValue).\(userId).\(remoteProfileId)"
    }

    static func isDone(_ step: Step, userId: String, remoteProfileId: Int) -> Bool {
        UserDefaults.standard.bool(forKey: key(step, userId: userId, remoteProfileId: remoteProfileId))
    }

    static func markDone(_ step: Step, userId: String, remoteProfileId: Int) {
        UserDefaults.standard.set(true, forKey: key(step, userId: userId, remoteProfileId: remoteProfileId))
    }

    /// Accounts signed in on this device since the defaults arrived. Only
    /// these get them: an account already signed in keeps the add-ons it has.
    private static func signedInKey(_ userId: String) -> String {
        "omni.defaults.signedIn.\(userId)"
    }

    static func markSignedIn(userId: String) {
        UserDefaults.standard.set(true, forKey: signedInKey(userId))
    }

    static func appliesTo(userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: signedInKey(userId))
    }
}

import Foundation

/// Stremio account import.
///
/// **Import-only, by design.** Nuvio Sync (and optionally Trakt / Simkl) already
/// own the write side of library and watch state. A second service writing back
/// would put two accounts in a last-writer-wins fight over the same watched
/// flags and resume positions, which is exactly the collision class the Trakt /
/// Simkl code already has to manage. Nothing here ever POSTs a mutation to
/// Stremio: it reads the account's library and merges it locally.
enum StremioAccountService {
    static let changedNotification = Notification.Name("nuvio.tv.stremio.changed")

    private static let apiBase = URL(string: "https://api.strem.io/api")!

    // Only the auth key is persisted — never the password, which is used for the
    // login request and then discarded.
    private static let authKeyKey = "nuvio.tv.stremio.authKey"
    private static let emailKey = "nuvio.tv.stremio.email"
    private static let lastImportKey = "nuvio.tv.stremio.lastImport"

    // MARK: - Account state

    static var authKey: String? {
        let value = ProfileSettings.current.string(forKey: authKeyKey)
        return (value?.isEmpty == false) ? value : nil
    }

    static var signedInEmail: String? {
        let value = ProfileSettings.current.string(forKey: emailKey)
        return (value?.isEmpty == false) ? value : nil
    }

    static var isSignedIn: Bool { authKey != nil }

    static var lastImportDate: Date? {
        let raw = ProfileSettings.current.double(forKey: lastImportKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    static func signOut() {
        ProfileSettings.current.removeObject(forKey: authKeyKey)
        ProfileSettings.current.removeObject(forKey: emailKey)
        ProfileSettings.current.removeObject(forKey: lastImportKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    // MARK: - Errors

    enum ServiceError: LocalizedError {
        case badCredentials(String)
        case transport(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .badCredentials(let message): return message
            case .transport(let message): return message
            case .malformedResponse:
                return L10n.string(
                    "stremio_error_malformed",
                    fallback: "Stremio returned a response the app could not read."
                )
            }
        }
    }

    // MARK: - Login

    /// Exchanges credentials for an auth key. The password is not retained.
    @discardableResult
    static func signIn(email: String, password: String) async throws -> String {
        struct LoginRequest: Encodable {
            let type = "Login"
            let email: String
            let password: String
        }
        struct LoginResponse: Decodable {
            struct Result: Decodable { let authKey: String? }
            struct APIError: Decodable { let message: String? }
            let result: Result?
            let error: APIError?
        }

        let body = try JSONEncoder().encode(LoginRequest(email: email, password: password))
        let data = try await post(path: "login", body: body)

        guard let decoded = try? JSONDecoder().decode(LoginResponse.self, from: data) else {
            throw ServiceError.malformedResponse
        }
        if let message = decoded.error?.message, !message.isEmpty {
            throw ServiceError.badCredentials(message)
        }
        guard let key = decoded.result?.authKey, !key.isEmpty else {
            throw ServiceError.malformedResponse
        }

        ProfileSettings.current.set(key, forKey: authKeyKey)
        ProfileSettings.current.set(email, forKey: emailKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        return key
    }

    // MARK: - Import

    struct ImportSummary {
        var libraryAdded = 0
        var libraryskipped = 0
        var watchedMarked = 0
        var total = 0
    }

    /// Pulls the account's `libraryItem` collection and merges it locally.
    @discardableResult
    static func importLibrary() async throws -> ImportSummary {
        guard let authKey else {
            throw ServiceError.badCredentials(
                L10n.string("stremio_error_signed_out", fallback: "Not signed in to Stremio.")
            )
        }

        struct DatastoreRequest: Encodable {
            let authKey: String
            let collection = "libraryItem"
            let all = true
        }
        struct DatastoreResponse: Decodable {
            let result: [StremioLibraryItem]?
        }

        let body = try JSONEncoder().encode(DatastoreRequest(authKey: authKey))
        let data = try await post(path: "datastoreGet", body: body)
        guard let decoded = try? JSONDecoder().decode(DatastoreResponse.self, from: data),
              let items = decoded.result else {
            throw ServiceError.malformedResponse
        }

        var summary = ImportSummary()
        summary.total = items.count

        // Batched deliberately. `LibraryStore.add` and `WatchedStore.markWatched`
        // each re-encode the *whole* store, write it to disk, and post a change
        // notification — and a library change notification kicks off a Nuvio sync
        // push. Calling them per item turned an 800-title import into 800 full
        // rewrites and 800 sync pushes, which flooded the device for minutes and
        // starved playback of bandwidth. The bulk merges persist once.
        var libraryToAdd: [LibraryStoreItem] = []
        var watchedToAdd: [WatchedStoreItem] = []
        let watchSource = TraktSettingsStore.watchProgressSource(in: ProfileSettings.current).rawValue

        for item in items {
            // `removed` is Stremio's soft delete; `temp` marks an item it tracked
            // only because something was played, never explicitly saved. Only the
            // latter is excluded from the library — its progress still matters.
            guard !item.removed else { continue }
            guard let meta = item.asMeta() else {
                summary.libraryskipped += 1
                continue
            }

            if !item.temp {
                if LibraryStore.contains(metaId: meta.id, type: meta.type) {
                    summary.libraryskipped += 1
                } else {
                    libraryToAdd.append(LibraryStoreItem(meta: meta, addedAt: Date()))
                    summary.libraryAdded += 1
                }
            }

            // A finished item carries the watch through as a local mark so the
            // green ticks line up with what Stremio already knew.
            if item.state?.isFinished == true {
                let season = item.state?.season
                let episode = item.state?.episode
                let hasEpisode = (season ?? 0) > 0 && (episode ?? 0) > 0
                let alreadyMarked = hasEpisode
                    ? WatchedStore.containsEpisode(meta: meta, season: season!, episode: episode!)
                    : WatchedStore.contains(meta: meta)
                if !alreadyMarked, hasEpisode || !meta.isSeries {
                    watchedToAdd.append(
                        WatchedStoreItem(
                            meta: meta.persistenceSnapshot,
                            watchedAt: Date(),
                            season: hasEpisode ? season : nil,
                            episode: hasEpisode ? episode : nil,
                            sources: [watchSource]
                        )
                    )
                    summary.watchedMarked += 1
                }
            }
        }

        if !libraryToAdd.isEmpty { LibraryStore.mergeRemote(libraryToAdd) }
        if !watchedToAdd.isEmpty {
            // Stremio cannot confirm deletions made in another backend, so local
            // tombstones must keep blocking rather than being resurrected here.
            _ = WatchedStore.mergeRemote(watchedToAdd, confirmsTombstoneDeletions: false)
        }

        ProfileSettings.current.set(Date().timeIntervalSince1970, forKey: lastImportKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        return summary
    }

    // MARK: - Transport

    private static func post(path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: apiBase.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ServiceError.transport(
                    L10n.format(
                        "stremio_error_status",
                        fallback: "Stremio returned HTTP %@.",
                        String(http.statusCode)
                    )
                )
            }
            return data
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.transport(error.localizedDescription)
        }
    }
}

/// One row of Stremio's `libraryItem` datastore.
struct StremioLibraryItem: Decodable {
    struct State: Decodable {
        let timeOffset: Double?
        let duration: Double?
        let season: Int?
        let episode: Int?
        let timesWatched: Int?
        let lastWatched: String?

        /// Stremio does not store an explicit "finished" flag; the client treats
        /// a title as watched once it is far enough through, or once it has been
        /// watched at least once.
        var isFinished: Bool {
            if let timesWatched, timesWatched > 0 { return true }
            guard let timeOffset, let duration, duration > 0 else { return false }
            return timeOffset / duration >= 0.9
        }
    }

    let _id: String
    let name: String?
    let type: String?
    let poster: String?
    let background: String?
    let logo: String?
    let year: String?
    let removed: Bool
    let temp: Bool
    let state: State?

    private enum CodingKeys: String, CodingKey {
        case _id, name, type, poster, background, logo, year, removed, temp, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decode(String.self, forKey: ._id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        poster = try? container.decodeIfPresent(String.self, forKey: .poster)
        background = try? container.decodeIfPresent(String.self, forKey: .background)
        logo = try? container.decodeIfPresent(String.self, forKey: .logo)
        // Stremio has shipped both a string and a number here over the years.
        if let raw = try? container.decodeIfPresent(String.self, forKey: .year) {
            year = raw
        } else if let raw = try? container.decodeIfPresent(Int.self, forKey: .year) {
            year = String(raw)
        } else {
            year = nil
        }
        removed = (try? container.decodeIfPresent(Bool.self, forKey: .removed)) ?? false
        temp = (try? container.decodeIfPresent(Bool.self, forKey: .temp)) ?? false
        state = try? container.decodeIfPresent(State.self, forKey: .state)
    }

    /// Maps to the app's own meta. Returns nil for rows without enough to show.
    func asMeta() -> NuvioMeta? {
        guard !_id.isEmpty, let name, !name.isEmpty else { return nil }
        let resolvedType = (type?.isEmpty == false ? type! : "movie").lowercased()
        return NuvioMeta(
            id: _id,
            name: name,
            description: nil,
            posterUrl: poster,
            backgroundUrl: background,
            logoUrl: logo,
            imdbId: _id.hasPrefix("tt") ? _id : nil,
            tmdbId: nil,
            type: resolvedType,
            year: year.flatMap { Int($0.prefix(4)) },
            genres: nil,
            rating: nil,
            releaseInfo: year,
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

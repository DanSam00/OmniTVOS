import Foundation

enum SimklConfig {
    static let apiBaseURL = "https://api.simkl.com"
    static let appName = "nuvio-tvos"
    static let developerSettingsURL = "https://simkl.com/settings/developer/"
    static let pinVerificationURL = "https://simkl.com/pin"
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
    /// Omni's own Simkl API app (simkl.com/settings/developer, "Omni V2", AUTH V2).
    /// Built in so people sign in with just a code, without registering an app
    /// of their own. It identifies the app, not the person, and the device
    /// flow needs no secret, so it is safe to ship.
    static let builtInClientID = "c7f058a90a448709164d898ea3aa990fe08d5fec483183cccd82a1ebdc33beeb"
    /// Omni's original AUTH V1 app, kept only for public lookups made without
    /// a user (Simkl ratings on a show page, IMDb id resolution) for profiles
    /// not connected to Simkl. A V2 client id answers those 401
    /// `user_token_required`. Simkl retires V1 apps around April 2027; these
    /// lookups then need a connected profile.
    static let publicLookupClientID = "ebf41598317e4b5003ba658abd0ba7fa03cb28745a25af2c87787943884745e8"
    /// What Omni asks for: reading the library and history, and writing
    /// scrobbles and progress. Without `media:write` nothing could be saved.
    static let scope = "media:read media:write"

    static var clientID: String {
        clientID(in: ProfileSettings.current)
    }

    static var isConfigured: Bool {
        isConfigured(in: ProfileSettings.current)
    }

    /// Always Omni's own V2 app. A Client ID saved by an older build is a V1
    /// app, which AUTH V2 rejects (`invalid_client`); a connection made under
    /// it is cleared by the Client ID check, and the user signs in again once.
    static func clientID(in store: UserDefaults) -> String {
        builtInClientID
    }

    static func isConfigured(in store: UserDefaults) -> Bool {
        !clientID(in: store).isEmpty
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var userAgent: String {
        "NuvioTV/\(appVersion)"
    }
}

struct SimklHTTPResult<T> {
    let statusCode: Int
    let value: T?
    let rawData: Data
    let errorMessage: String?

    func valueOrThrow() throws -> T {
        guard (200..<300).contains(statusCode) else {
            throw SimklServiceError.message(errorMessage ?? "Simkl request failed (\(statusCode)).")
        }
        guard let value else {
            throw SimklServiceError.message(errorMessage ?? "Simkl returned an empty response.")
        }
        return value
    }
}

enum SimklServiceError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

/// Shared HTTP transport for Simkl. Every request carries the required
/// `client_id`, `app-name`, `app-version` query params and `User-Agent` header.
final class SimklAPIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get<T: Decodable>(
        path: String,
        clientID: String,
        accessToken: String? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> SimklHTTPResult<T> {
        let request = try makeRequest(
            path: path,
            method: "GET",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: queryItems,
            body: nil as Data?
        )
        return try await perform(request)
    }

    /// `POST` with no request body. Simkl serves `/users/settings` and
    /// `/users/{id}/stats` this way "for historical reasons" — both are reads
    /// that take no payload, and neither answers `GET`.
    func postEmptyBody<T: Decodable>(
        path: String,
        clientID: String,
        accessToken: String?
    ) async throws -> SimklHTTPResult<T> {
        let request = try makeRequest(
            path: path,
            method: "POST",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: [],
            body: Data("{}".utf8)
        )
        return try await perform(request)
    }

    func post<B: Encodable>(
        path: String,
        clientID: String,
        accessToken: String,
        queryItems: [URLQueryItem] = [],
        body: B
    ) async throws -> SimklHTTPResult<Data> {
        let request = try makeRequest(
            path: path,
            method: "POST",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: queryItems,
            body: try encoder.encode(body)
        )
        return try await performRaw(request)
    }

    /// Simkl only honours a real `DELETE` here — `POST` or `GET` against the
    /// same URL answers without deleting anything. Success is `204`, so there
    /// is no body to decode.
    func delete(
        path: String,
        clientID: String,
        accessToken: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> SimklHTTPResult<Data> {
        let request = try makeRequest(
            path: path,
            method: "DELETE",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: queryItems,
            body: nil as Data?
        )
        return try await performRaw(request)
    }

    /// A form-encoded `POST` without the API's usual query parameters or a
    /// user token: AUTH V2's `/oauth2/device` and `/oauth2/token`.
    func postForm<T: Decodable>(
        path: String,
        fields: [String: String]
    ) async throws -> SimklHTTPResult<T> {
        let normalizedBase = SimklConfig.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(normalizedBase)/\(normalizedPath)") else {
            throw SimklServiceError.message("Invalid Simkl URL.")
        }
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(SimklConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // `+` must not survive into the body: a form decoder reads it as a space.
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        return try await perform(request)
    }

    func getRaw(
        path: String,
        clientID: String,
        accessToken: String? = nil
    ) async throws -> SimklHTTPResult<Data> {
        let request = try makeRequest(
            path: path,
            method: "GET",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: [],
            body: nil as Data?
        )
        return try await performRaw(request)
    }

    private func makeRequest(
        path: String,
        method: String,
        clientID: String,
        accessToken: String?,
        queryItems: [URLQueryItem],
        body: Data?
    ) throws -> URLRequest {

        let normalizedBase = SimklConfig.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(normalizedBase)/\(normalizedPath)") else {
            throw SimklServiceError.message("Invalid Simkl URL.")
        }

        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "app-name", value: SimklConfig.appName),
            URLQueryItem(name: "app-version", value: SimklConfig.appVersion)
        ])
        items.append(contentsOf: queryItems)
        components.queryItems = items

        guard let url = components.url else {
            throw SimklServiceError.message("Invalid Simkl URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        // PIN creation is a GET endpoint but every response is a unique,
        // short-lived credential. Cached responses immediately produce an
        // invalid PIN on the first poll. Sync/activity reads must also remain
        // authoritative, so Simkl requests never use URLCache.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(SimklConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> SimklHTTPResult<T> {
        let raw = try await performRaw(request)
        var value: T?
        if (200..<300).contains(raw.statusCode), !raw.rawData.isEmpty {
            do {
                value = try decoder.decode(T.self, from: raw.rawData)
            } catch {
                return SimklHTTPResult(
                    statusCode: raw.statusCode,
                    value: nil,
                    rawData: raw.rawData,
                    errorMessage: raw.errorMessage
                        ?? "Simkl response could not be read (\(error.localizedDescription))."
                )
            }
        }
        return SimklHTTPResult(
            statusCode: raw.statusCode,
            value: value,
            rawData: raw.rawData,
            errorMessage: Self.friendlyError(raw.errorMessage, status: raw.statusCode)
        )
    }

    private func performRaw(_ request: URLRequest, allowsRefresh: Bool = true) async throws -> SimklHTTPResult<Data> {
        var request = request
        let bearerPrefix = "Bearer "
        // AUTH V2 tokens last seven days: swap in a refreshed one before it
        // runs out, and once more if Simkl turns this one down.
        if allowsRefresh,
           let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix(bearerPrefix) {
            let token = String(header.dropFirst(bearerPrefix.count))
            let usable = await SimklTokenRefresher.usableToken(for: token)
            if usable != token { request.setValue(bearerPrefix + usable, forHTTPHeaderField: "Authorization") }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimklServiceError.message("Invalid Simkl response.")
        }
        if allowsRefresh, http.statusCode == 401,
           let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix(bearerPrefix),
           let fresh = await SimklTokenRefresher.tokenAfterRejection(of: String(header.dropFirst(bearerPrefix.count))) {
            var retry = request
            retry.setValue(bearerPrefix + fresh, forHTTPHeaderField: "Authorization")
            return try await performRaw(retry, allowsRefresh: false)
        }
        return SimklHTTPResult(
            statusCode: http.statusCode,
            value: data,
            rawData: data,
            errorMessage: Self.errorMessage(from: data)
        )
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["message", "error_description", "error", "msg"] {
            if let string = object[key] as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func friendlyError(_ raw: String?, status: Int) -> String? {
        switch status {
        case 401:
            return raw ?? "Simkl access was revoked. Connect again."
        case 403:
            return raw ?? "Simkl rejected this request. Check your Client ID."
        case 412:
            // 412 is `client_id_failed`, which Simkl also returns once an app
            // has burned through its request quota or picked up a throttling
            // block — not only when the ID itself is wrong.
            return raw ?? "Simkl rejected the Client ID, or this app has hit its request limit. "
                + "Check the value, or wait and try again."
        case 429:
            return raw ?? "Simkl is rate limiting requests. Wait and try again."
        case 500...599:
            return raw ?? "Simkl is temporarily unavailable (\(status))."
        default:
            return raw
        }
    }
}

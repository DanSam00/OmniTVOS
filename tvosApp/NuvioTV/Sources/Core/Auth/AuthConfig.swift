//
//  AuthConfig.swift
//  NuvioTV
//
//  Backend credentials for the Nuvio account API.
//

import Foundation

/// Nuvio account API credentials for the account / TV-login system.
enum AuthConfig {
    static let apiBaseURL = "https://api.nuvio.tv"

    /// Public publishable key from the Nuvio Public API docs.
    static let publishableKey = "sb_publishable_1Clq8rlTVACkdcZuqr6_AD__xUUC_EN"

    static var apiKey: String { publishableKey }

    /// The backend function that deletes the signed-in user and everything
    /// stored under the account (called as `/rest/v1/rpc/<name>` with the
    /// user's token). Must exist on the Nuvio backend; if it does not, the
    /// in-app delete reports that deletion is unavailable and nothing changes.
    static let deleteAccountFunction = "delete_my_account"

    /// Base URL the phone opens to approve a TV login. Matches the Android
    /// `TV_LOGIN_WEB_BASE_URL` default; the backend ultimately returns the real
    /// `web_url` to encode in the QR code, so this is only a fallback hint.
    static let tvLoginWebBaseURL = "https://nuvio.tv/tv-login"
    static let legacyTvLoginWebBaseURL = "https://app.nuvio.tv/tv-login"

    static var isConfigured: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var normalizedAPIBaseURL: String {
        var url = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}

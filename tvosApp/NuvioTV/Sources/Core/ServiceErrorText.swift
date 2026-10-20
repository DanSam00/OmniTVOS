import Foundation

/// Plain words for a web service's HTTP status, for messages people read.
/// "TMDB returned HTTP 401" tells a viewer nothing; "TMDB didn't accept the
/// key" tells them what to fix. The number stays in the log, not on screen.
enum ServiceErrorText {
    static func describe(status: Int, service: String) -> String {
        switch status {
        case 401:
            return "\(service) didn't accept the sign-in or key. Check it in Settings."
        case 403:
            return "\(service) refused the request. The account may not have access to it."
        case 404:
            return "\(service) couldn't find what was asked for."
        case 408, 504:
            return "\(service) took too long to answer. Try again in a moment."
        case 429:
            return "\(service) is limiting requests right now. Try again in a minute."
        case 500...599:
            return "\(service) is having problems right now. Try again later."
        default:
            return "\(service) couldn't complete the request (error \(status))."
        }
    }
}

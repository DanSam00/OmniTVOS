#if !OMNI_X
import Foundation

/// Omni has no torrent or debrid support. These keep the shared playback code
/// compiling; they never enable anything.
struct DebridResolver {
    init(store: UserDefaults) {}
    var isEnabled: Bool { false }

    func resolvedURL(for stream: NuvioStream, season: Int?, episode: Int?) async -> DebridResult? { nil }
}

enum DebridResult: Equatable {
    case success(url: URL, filename: String?, videoSize: Int64?)
    case missingApiKey
    case stale
    case error
}
#endif

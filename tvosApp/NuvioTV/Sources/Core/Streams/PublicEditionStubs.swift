#if !OMNI_X
import Foundation

/// Omni has no torrent or debrid support. These keep the shared playback code
/// compiling; they never enable anything.
struct DebridResolver {
    init(store: UserDefaults) {}
    var isEnabled: Bool { false }

    func resolvedURL(for stream: NuvioStream, season: Int?, episode: Int?) async -> DebridResult? { nil }
    /// Shared playback code names the provider a stream came through.
    var selectedKind: PublicDebridKind { .none }
}

/// Stands in for `DebridProviderKind`, which Omni does not contain.
enum PublicDebridKind: String {
    case none = ""
}

enum DebridResult: Equatable {
    case success(url: URL, filename: String?, videoSize: Int64?)
    case missingApiKey
    case stale
    case error
}
#endif

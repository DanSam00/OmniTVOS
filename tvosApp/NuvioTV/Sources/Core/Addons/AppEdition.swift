import Foundation

/// Which app this binary is.
///
/// - **Omni** (the public, App Store app): an IPTV (Xtream / M3U) player with
///   its own libraries (Jellyfin, SMB). Metadata and organisation only come
///   from the fixed `CuratedLibrary`; no add-on supplies a stream, and the
///   code for torrent/debrid providers is not compiled in.
/// - **Omni X** (the original app, built with the `OMNI_X` compilation
///   condition): everything, including user-installed stream add-ons.
///
/// Anything that must exist only in Omni X is wrapped in `#if OMNI_X`, so it is
/// absent from the Omni binary rather than merely switched off.
enum AppEdition {
    #if OMNI_X
    static let isOmniX = true
    static let displayName = "Omni X"
    #else
    static let isOmniX = false
    static let displayName = "Omni"
    #endif

    /// True for the public app: add-ons, collections and stream sources are
    /// fixed in code and not shown in Settings.
    static var isPublic: Bool { !isOmniX }
}

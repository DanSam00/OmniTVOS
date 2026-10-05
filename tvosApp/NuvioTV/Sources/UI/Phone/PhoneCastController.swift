#if os(iOS)
import GoogleCast
import SwiftUI

/// Google Cast for the phone player. The Chromecast fetches the stream itself
/// with Google's Default Media Receiver, so this hands it the source URL (not
/// the engine's local loopback), then mirrors the receiver's state for the
/// remote-control screen.
@MainActor
final class PhoneCastController: NSObject, ObservableObject {
    static let shared = PhoneCastController()

    /// A receiver is connected (whether or not it is playing our media yet).
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName: String?
    /// The receiver is playing, or loading, media this app sent.
    @Published private(set) var hasMedia = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    /// Set when the receiver ends playback on its own (finished or failed),
    /// for the player to pick up from.
    @Published var lastError: String?

    private var positionTimer: Timer?

    private override init() {
        super.init()
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        // Discovery starts when the player opens (startDiscovery), not on
        // the first tap of the Cast button: waiting for the tap left the
        // device list empty when it opened, so no Chromecast was offered.
        options.startDiscoveryAfterFirstTapOnCastButton = false
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().discoveryManager.add(self)
        GCKCastContext.sharedInstance().sessionManager.add(self)
        if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
            attach(session)
        }
    }

    /// Looks for Cast devices on the network. The first call is when iOS
    /// asks for Local Network access.
    func startDiscovery() {
        let discovery = GCKCastContext.sharedInstance().discoveryManager
        discovery.passiveScan = false
        discovery.startDiscovery()
        #if OMNI_DEBUG_TOOLS
        NSLog("Cast discovery: started, state %d", discovery.discoveryState.rawValue)
        #endif
    }

    private var client: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    // MARK: Commands

    /// Sends the current stream to the receiver. Returns a reason when it
    /// can't be cast at all.
    @discardableResult
    func load(_ media: CastableMedia) -> String? {
        guard let client else { return "No Cast device connected" }
        if let host = media.url.host?.lowercased(),
           host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return "This source plays from the phone and can't be cast"
        }

        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(media.title, forKey: kGCKMetadataKeyTitle)
        if !media.subtitle.isEmpty {
            metadata.setString(media.subtitle, forKey: kGCKMetadataKeySubtitle)
        }
        if let poster = media.posterURL {
            metadata.addImage(GCKImage(url: poster, width: 480, height: 720))
        }
        if let backdrop = media.backdropURL {
            metadata.addImage(GCKImage(url: backdrop, width: 1280, height: 720))
        }

        var tracks: [GCKMediaTrack] = []
        var activeTrackIDs: [NSNumber] = []
        for (index, subtitle) in media.subtitles.enumerated() {
            let id = index + 1
            guard let track = GCKMediaTrack(
                identifier: id,
                contentIdentifier: subtitle.url,
                contentType: "text/vtt",
                type: .text,
                textSubtype: .subtitles,
                name: subtitle.label ?? subtitle.language,
                languageCode: subtitle.language,
                customData: nil
            ) else { continue }
            tracks.append(track)
            if subtitle.url == media.activeSubtitleURL { activeTrackIDs.append(NSNumber(value: id)) }
        }

        let builder = GCKMediaInformationBuilder(contentURL: media.url)
        builder.contentType = Self.contentType(for: media)
        builder.streamType = media.isLive ? .live : .buffered
        builder.metadata = metadata
        if !tracks.isEmpty { builder.mediaTracks = tracks }
        if media.duration > 0 { builder.streamDuration = media.duration }

        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        request.autoplay = true
        if !media.isLive, media.position > 1 { request.startTime = media.position }
        if !activeTrackIDs.isEmpty { request.activeTrackIDs = activeTrackIDs }

        lastError = nil
        hasMedia = true
        isBuffering = true
        position = media.position
        duration = media.duration
        client.loadMedia(with: request.build()).delegate = self
        return nil
    }

    func togglePlayPause() {
        guard let client else { return }
        if isPlaying { client.pause() } else { client.play() }
    }

    func seek(to seconds: Double) {
        let options = GCKMediaSeekOptions()
        options.interval = max(seconds, 0)
        options.resumeState = .unchanged
        client?.seek(with: options)
        position = max(seconds, 0)
    }

    func skip(by seconds: Double) {
        seek(to: min(max(position + seconds, 0), duration > 0 ? duration : .greatestFiniteMagnitude))
    }

    /// Stops the receiver and disconnects. Returns where it got to.
    func stopCasting() -> Double {
        let reached = position
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        return reached
    }

    // MARK: State

    private func attach(_ session: GCKCastSession) {
        isConnected = true
        deviceName = session.device.friendlyName
        session.remoteMediaClient?.add(self)
        update(from: session.remoteMediaClient?.mediaStatus)
        startPositionTimer()
    }

    private func detach() {
        isConnected = false
        deviceName = nil
        hasMedia = false
        isPlaying = false
        isBuffering = false
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func update(from status: GCKMediaStatus?) {
        guard let status else { return }
        switch status.playerState {
        case .playing:
            isPlaying = true; isBuffering = false; hasMedia = true
        case .paused:
            isPlaying = false; isBuffering = false; hasMedia = true
        case .buffering, .loading:
            isBuffering = true; hasMedia = true
        case .idle:
            isPlaying = false
            isBuffering = false
            switch status.idleReason {
            case .finished, .cancelled: hasMedia = false
            case .error:
                hasMedia = false
                lastError = "The Cast device couldn't play this source"
            default: break
            }
        default:
            break
        }
        if let streamDuration = status.mediaInformation?.streamDuration,
           streamDuration.isFinite, streamDuration > 0 {
            duration = streamDuration
        }
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let client = self.client, self.hasMedia else { return }
                let approximate = client.approximateStreamPosition()
                if approximate.isFinite { self.position = approximate }
            }
        }
    }

    /// The Default Media Receiver goes by MIME type, not by file extension.
    private static func contentType(for media: CastableMedia) -> String {
        let name = (media.filename ?? media.url.path).lowercased()
        if name.hasSuffix(".m3u8") || media.url.absoluteString.lowercased().contains(".m3u8") {
            return "application/x-mpegURL"
        }
        if name.hasSuffix(".mpd") { return "application/dash+xml" }
        if name.hasSuffix(".mkv") { return "video/x-matroska" }
        if name.hasSuffix(".webm") { return "video/webm" }
        return "video/mp4"
    }
}

extension PhoneCastController: @preconcurrency GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        attach(session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        attach(session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        detach()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        detach()
        lastError = "Couldn't connect to the Cast device"
    }
}

extension PhoneCastController: @preconcurrency GCKDiscoveryManagerListener {
    func didUpdateDeviceList() {
        #if OMNI_DEBUG_TOOLS
        let discovery = GCKCastContext.sharedInstance().discoveryManager
        NSLog("Cast discovery: %d device(s), state %d", discovery.deviceCount, discovery.discoveryState.rawValue)
        #endif
    }
}

extension PhoneCastController: @preconcurrency GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        update(from: mediaStatus)
    }
}

extension PhoneCastController: @preconcurrency GCKRequestDelegate {
    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        hasMedia = false
        isBuffering = false
        lastError = "The Cast device couldn't play this source"
    }
}

/// Google's Cast button: picks a device, and shows connected state.
struct PhoneCastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = .white
        return button
    }

    func updateUIView(_ button: GCKUICastButton, context: Context) {}
}

/// The player while casting: the phone becomes a remote for the receiver.
struct PhoneCastingView: View {
    @ObservedObject var cast: PhoneCastController
    let title: String
    let subtitle: String
    let backdropURL: String?
    let seekStep: Int
    let onStop: () -> Void
    let onClose: () -> Void

    @State private var scrubValue: Double?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let backdropURL {
                PhoneArtwork(url: backdropURL, kind: .backdrop)
                    .ignoresSafeArea()
                    .opacity(0.35)
                    .blur(radius: 18)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close player")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    Spacer()
                    PhoneCastButton().frame(width: 44, height: 44)
                }

                Spacer(minLength: 8)

                VStack(spacing: 6) {
                    Image(systemName: "tv.and.mediabox")
                        .font(.largeTitle)
                    Text("Playing on \(cast.deviceName ?? "Cast device")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer(minLength: 8)

                HStack(spacing: 56) {
                    Button { cast.skip(by: -Double(seekStep)) } label: {
                        Image(systemName: "gobackward.\(seekStep)").font(.title)
                            .frame(width: 52, height: 52)
                    }
                    Button { cast.togglePlayPause() } label: {
                        Group {
                            if cast.isBuffering {
                                ProgressView().tint(.white).controlSize(.large)
                            } else {
                                Image(systemName: cast.isPlaying ? "pause.fill" : "play.fill")
                            }
                        }
                        .font(.largeTitle)
                        .frame(width: 64, height: 64)
                    }
                    Button { cast.skip(by: Double(seekStep)) } label: {
                        Image(systemName: "goforward.\(seekStep)").font(.title)
                            .frame(width: 52, height: 52)
                    }
                }

                Spacer(minLength: 8)

                timeline

                HStack {
                    Spacer()
                    Button(action: onStop) {
                        Label("Stop Casting", systemImage: "stop.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .foregroundStyle(.white)
    }

    private var timeline: some View {
        let duration = max(cast.duration, 1)
        let shown = min(scrubValue ?? cast.position, duration)
        return VStack(spacing: 4) {
            PhoneScrubBar(
                fraction: shown / duration,
                isScrubbing: scrubValue != nil,
                onChanged: { scrubValue = $0 * duration },
                onEnded: {
                    if let target = scrubValue {
                        cast.seek(to: target)
                        scrubValue = nil
                    }
                }
            )
            HStack {
                Text(PhonePlayerTimeline.format(shown))
                Spacer()
                Text("-" + PhonePlayerTimeline.format(max(duration - shown, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}
#endif

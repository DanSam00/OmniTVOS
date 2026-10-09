#if os(macOS)
import AVKit
import AetherEngine
import Foundation
import Network
import SwiftUI

/// A Chromecast found on the network.
struct MacCastDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// Google Cast for the Mac player.
///
/// Google ships no Cast SDK for macOS, so this speaks the Cast v2 protocol
/// itself: Bonjour discovery of `_googlecast._tcp`, a TLS connection to port
/// 8009, length-prefixed protobuf `CastMessage` frames carrying JSON. As on the
/// iPhone it launches Google's Default Media Receiver and hands it the source
/// URL, so the Chromecast fetches the stream itself; the Mac becomes a remote.
@MainActor
final class MacCastController: ObservableObject {
    static let shared = MacCastController()

    @Published private(set) var devices: [MacCastDevice] = []
    /// Connecting to a device and starting the receiver app on it.
    @Published private(set) var isConnecting = false
    /// The receiver app is running and ready for media.
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName: String?
    /// The receiver is playing, or loading, media this app sent.
    @Published private(set) var hasMedia = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    /// Set when casting fails or the receiver gives up, for the player to show.
    @Published var lastError: String?

    private static let defaultMediaReceiver = "CC1AD845"
    private static let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    private static let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    private static let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    private static let nsMedia = "urn:x-cast:com.google.cast.media"

    private var browser: NWBrowser?
    private var channel: MacCastChannel?
    private var transportId: String?
    private var appSessionId: String?
    private var mediaSessionId: Int?
    private var requestId = 0
    private var pendingMedia: CastableMedia?
    private var heartbeatTimer: Timer?
    private var positionTimer: Timer?
    /// The receiver's position at its last status, and when that arrived, so
    /// the bar can move smoothly between statuses.
    private var statusPosition: Double = 0
    private var statusAt = Date()

    private init() {}

    // MARK: Discovery

    /// Looks for Chromecasts on the network. The first call is when macOS asks
    /// for Local Network access.
    func startDiscovery() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [MacCastDevice] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var friendly = name
                var id = name
                if case let .bonjour(txt) = result.metadata {
                    if let fn = txt["fn"], !fn.isEmpty { friendly = fn }
                    if let deviceID = txt["id"], !deviceID.isEmpty { id = deviceID }
                }
                return MacCastDevice(id: id, name: friendly, endpoint: result.endpoint)
            }
            // A device on Wi-Fi and Ethernet is listed once per interface.
            var unique: [String: MacCastDevice] = [:]
            for device in found where unique[device.id] == nil { unique[device.id] = device }
            let devices = unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                self?.devices = devices
                MacDiagnostics.log("cast.discovery devices=\(devices.map(\.name))")
            }
        }
        browser.stateUpdateHandler = { state in
            Task { @MainActor in MacDiagnostics.log("cast.discovery state=\(state)") }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: Session

    /// Connects to `device` and starts the media receiver on it. `media` is
    /// sent as soon as the receiver is ready.
    func connect(to device: MacCastDevice, media: CastableMedia) {
        disconnect(stopReceiver: false)
        lastError = nil
        isConnecting = true
        deviceName = device.name
        pendingMedia = media
        MacDiagnostics.log("cast.connect \(device.name)")
        let channel = MacCastChannel(endpoint: device.endpoint)
        channel.onReady = { [weak self] in self?.channelReady() }
        channel.onMessage = { [weak self] namespace, source, payload in
            self?.handle(namespace: namespace, source: source, payload: payload)
        }
        channel.onFailure = { [weak self] reason in
            guard let self else { return }
            MacDiagnostics.log("cast.channel.failed \(reason)")
            let wasCasting = self.isConnected || self.isConnecting
            self.detach()
            if wasCasting { self.lastError = "Lost the connection to the Cast device" }
        }
        self.channel = channel
        channel.start()
    }

    /// Stops the receiver and disconnects. Returns where it had got to.
    @discardableResult
    func stopCasting() -> Double {
        let reached = position
        disconnect(stopReceiver: true)
        return reached
    }

    private func disconnect(stopReceiver: Bool) {
        if let channel {
            if stopReceiver {
                if let transportId, let mediaSessionId {
                    send(Self.nsMedia, to: transportId, ["type": "STOP", "mediaSessionId": mediaSessionId])
                }
                if let appSessionId {
                    send(Self.nsReceiver, to: "receiver-0", ["type": "STOP", "sessionId": appSessionId])
                }
            }
            if let transportId { send(Self.nsConnection, to: transportId, ["type": "CLOSE"]) }
            send(Self.nsConnection, to: "receiver-0", ["type": "CLOSE"])
            channel.cancel(after: 0.3)
        }
        detach()
    }

    private func detach() {
        channel = nil
        transportId = nil
        appSessionId = nil
        mediaSessionId = nil
        pendingMedia = nil
        isConnecting = false
        isConnected = false
        deviceName = nil
        hasMedia = false
        isPlaying = false
        isBuffering = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func channelReady() {
        send(Self.nsConnection, to: "receiver-0", ["type": "CONNECT"])
        send(Self.nsReceiver, to: "receiver-0", ["type": "LAUNCH", "appId": Self.defaultMediaReceiver])
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.send(Self.nsHeartbeat, to: "receiver-0", ["type": "PING"])
                // A status now and then keeps the bar honest between events.
                if let self, let transportId = self.transportId, self.hasMedia {
                    self.send(Self.nsMedia, to: transportId, ["type": "GET_STATUS"])
                }
            }
        }
    }

    // MARK: Commands

    func togglePlayPause() {
        guard let transportId, let mediaSessionId else { return }
        send(Self.nsMedia, to: transportId, ["type": isPlaying ? "PAUSE" : "PLAY", "mediaSessionId": mediaSessionId])
    }

    func seek(to seconds: Double) {
        guard let transportId, let mediaSessionId else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        send(Self.nsMedia, to: transportId, ["type": "SEEK", "mediaSessionId": mediaSessionId, "currentTime": target])
        position = target
        statusPosition = target
        statusAt = Date()
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    // MARK: Messages

    private func send(_ namespace: String, to destination: String, _ body: [String: Any]) {
        var body = body
        if namespace == Self.nsReceiver || namespace == Self.nsMedia {
            requestId += 1
            body["requestId"] = requestId
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return }
        channel?.send(namespace: namespace, destination: destination, payload: json)
    }

    private func handle(namespace: String, source: String, payload: String) {
        guard let data = payload.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch (namespace, type) {
        case (Self.nsHeartbeat, "PING"):
            send(Self.nsHeartbeat, to: source, ["type": "PONG"])
        case (Self.nsReceiver, "RECEIVER_STATUS"):
            handleReceiverStatus(message)
        case (Self.nsReceiver, "LAUNCH_ERROR"):
            MacDiagnostics.log("cast.launch.error \(payload)")
            detach()
            lastError = "The Cast device couldn't start playback"
        case (Self.nsMedia, "MEDIA_STATUS"):
            handleMediaStatus(message)
        case (Self.nsMedia, "LOAD_FAILED"), (Self.nsMedia, "LOAD_CANCELLED"), (Self.nsMedia, "INVALID_REQUEST"):
            MacDiagnostics.log("cast.media.\(type) \(payload)")
            hasMedia = false
            isBuffering = false
            lastError = "The Cast device couldn't play this source"
        case (Self.nsConnection, "CLOSE"):
            MacDiagnostics.log("cast.closed by receiver")
            let wasCasting = isConnected
            disconnect(stopReceiver: false)
            if wasCasting { hasMedia = false }
        default:
            break
        }
    }

    private func handleReceiverStatus(_ message: [String: Any]) {
        guard let status = message["status"] as? [String: Any] else { return }
        let apps = status["applications"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { ($0["appId"] as? String) == Self.defaultMediaReceiver }),
              let transport = app["transportId"] as? String else {
            // Someone else's app took over the receiver, or ours was closed
            // from the TV's own remote.
            if isConnected {
                MacDiagnostics.log("cast.app.gone")
                disconnect(stopReceiver: false)
            }
            return
        }
        appSessionId = app["sessionId"] as? String
        guard transport != transportId else { return }
        transportId = transport
        send(Self.nsConnection, to: transport, ["type": "CONNECT"])
        isConnecting = false
        isConnected = true
        MacDiagnostics.log("cast.ready \(deviceName ?? "?")")
        if let media = pendingMedia {
            pendingMedia = nil
            sendLoad(media, to: transport)
        }
    }

    private func handleMediaStatus(_ message: [String: Any]) {
        guard let status = (message["status"] as? [[String: Any]])?.first else { return }
        if let id = status["mediaSessionId"] as? Int { mediaSessionId = id }
        if let media = status["media"] as? [String: Any],
           let total = media["duration"] as? Double, total.isFinite, total > 0 {
            duration = total
        }
        if let time = status["currentTime"] as? Double, time.isFinite {
            position = time
            statusPosition = time
            statusAt = Date()
        }
        switch status["playerState"] as? String {
        case "PLAYING":
            isPlaying = true; isBuffering = false; hasMedia = true
        case "PAUSED":
            isPlaying = false; isBuffering = false; hasMedia = true
        case "BUFFERING":
            isBuffering = true; hasMedia = true
        case "IDLE":
            isPlaying = false
            isBuffering = false
            switch status["idleReason"] as? String {
            case "FINISHED", "CANCELLED", "INTERRUPTED":
                hasMedia = false
            case "ERROR":
                hasMedia = false
                lastError = "The Cast device couldn't play this source"
            default:
                break
            }
        default:
            break
        }
    }

    // MARK: Load

    /// Sends the current stream to the receiver. Returns a reason when it can't
    /// be cast at all.
    private func sendLoad(_ media: CastableMedia, to transport: String) {
        var metadata: [String: Any] = ["metadataType": 0, "title": media.title]
        if !media.subtitle.isEmpty { metadata["subtitle"] = media.subtitle }
        let images = [media.posterURL, media.backdropURL].compactMap { $0?.absoluteString }
        if !images.isEmpty { metadata["images"] = images.map { ["url": $0] } }

        var tracks: [[String: Any]] = []
        var activeTrackIds: [Int] = []
        for (index, subtitle) in media.subtitles.enumerated() {
            let id = index + 1
            var track: [String: Any] = [
                "trackId": id,
                "type": "TEXT",
                "subtype": "SUBTITLES",
                "trackContentId": subtitle.url,
                "trackContentType": "text/vtt",
                "name": subtitle.label ?? subtitle.language,
            ]
            if !subtitle.language.isEmpty { track["language"] = subtitle.language }
            tracks.append(track)
            if subtitle.url == media.activeSubtitleURL { activeTrackIds.append(id) }
        }

        var info: [String: Any] = [
            "contentId": media.url.absoluteString,
            "contentType": Self.contentType(for: media),
            "streamType": media.isLive ? "LIVE" : "BUFFERED",
            "metadata": metadata,
        ]
        if !tracks.isEmpty { info["tracks"] = tracks }
        if media.duration > 0 { info["duration"] = media.duration }

        var load: [String: Any] = ["type": "LOAD", "media": info, "autoplay": true]
        if !media.isLive, media.position > 1 { load["currentTime"] = media.position }
        if !activeTrackIds.isEmpty { load["activeTrackIds"] = activeTrackIds }

        lastError = nil
        hasMedia = true
        isBuffering = true
        position = media.position
        statusPosition = media.position
        statusAt = Date()
        duration = media.duration
        send(Self.nsMedia, to: transport, load)
        startPositionTimer()
        MacDiagnostics.log("cast.load \(Self.contentType(for: media)) live=\(media.isLive) at=\(Int(media.position))")
    }

    /// Why `media` can't be cast, or nil when it can.
    static func unsupportedReason(_ media: CastableMedia) -> String? {
        if let host = media.url.host?.lowercased(),
           host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return "This source plays from the Mac and can't be cast"
        }
        return nil
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasMedia, self.isPlaying else { return }
                let estimate = self.statusPosition + Date().timeIntervalSince(self.statusAt)
                self.position = self.duration > 0 ? min(estimate, self.duration) : estimate
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

/// One TLS connection to a Chromecast, framing Cast v2 messages.
///
/// A frame is a 4-byte big-endian length then a protobuf `CastMessage`:
/// protocol_version (1), source_id (2), destination_id (3), namespace (4),
/// payload_type (5, 0 = string) and payload_utf8 (6).
private final class MacCastChannel {
    var onReady: (@MainActor () -> Void)?
    var onMessage: (@MainActor (_ namespace: String, _ source: String, _ payload: String) -> Void)?
    var onFailure: (@MainActor (_ reason: String) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "omni.cast.channel")
    private static let senderId = "sender-0"

    init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        // Chromecasts present a self-signed certificate.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, DispatchQueue(label: "omni.cast.tls"))
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: .init()))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { @MainActor in self.onReady?() }
                self.receiveFrame()
            case .failed(let error):
                Task { @MainActor in self.onFailure?("\(error)") }
            case .waiting(let error):
                Task { @MainActor in self.onFailure?("waiting: \(error)") }
                self.connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [connection] in
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    func send(namespace: String, destination: String, payload: String) {
        var message = Data()
        message.append(contentsOf: [0x08, 0x00])
        Self.appendString(2, Self.senderId, to: &message)
        Self.appendString(3, destination, to: &message)
        Self.appendString(4, namespace, to: &message)
        message.append(contentsOf: [0x28, 0x00])
        Self.appendString(6, payload, to: &message)
        var frame = Data()
        let length = UInt32(message.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(message)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receiveFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let header, header.count == 4 else {
                if isComplete || error != nil {
                    Task { @MainActor in self.onFailure?("closed \(error.map { "\($0)" } ?? "")") }
                }
                return
            }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length < 1 << 20 else {
                Task { @MainActor in self.onFailure?("bad frame length \(length)") }
                return
            }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard error == nil, let body else {
                    Task { @MainActor in self.onFailure?("read \(error.map { "\($0)" } ?? "")") }
                    return
                }
                if let parsed = Self.parse(body) {
                    Task { @MainActor in self.onMessage?(parsed.namespace, parsed.source, parsed.payload) }
                }
                self.receiveFrame()
            }
        }
    }

    // MARK: Protobuf

    private static func appendVarint(_ value: Int, to data: inout Data) {
        var value = UInt64(value)
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }

    private static func appendString(_ field: Int, _ string: String, to data: inout Data) {
        let bytes = Data(string.utf8)
        appendVarint(field << 3 | 2, to: &data)
        appendVarint(bytes.count, to: &data)
        data.append(bytes)
    }

    private static func parse(_ data: Data) -> (namespace: String, source: String, payload: String)? {
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> Int? {
            var result = 0
            var shift = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        var namespace = "", source = "", payload = ""
        while index < bytes.count {
            guard let key = varint() else { return nil }
            let field = key >> 3
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let length = varint(), index + length <= bytes.count else { return nil }
                let value = String(decoding: bytes[index ..< index + length], as: UTF8.self)
                index += length
                switch field {
                case 2: source = value
                case 4: namespace = value
                case 6: payload = value
                default: break
                }
            case 5: index += 4
            case 1: index += 8
            default: return nil
            }
        }
        return namespace.isEmpty ? nil : (namespace, source, payload)
    }
}

// MARK: - AirPlay

/// The system AirPlay picker, kept under the player's own AirPlay button so
/// Return can open it as well as a click. Given the engine's AVPlayer, it
/// offers video receivers — an Apple TV — not just speakers.
@MainActor
enum MacAirPlay {
    /// True while the system AirPlay list is open. The player's own key
    /// handling stands aside then, so the arrows and Return reach the list.
    static var isPresenting = false
    private static var lastOpened: Date?

    /// Held strongly: SwiftUI can drop and remake the view, and a weak
    /// reference left the button with nothing to open in between.
    fileprivate static var picker: AVRoutePickerView?

    /// Posted when AirPlay is opened on a stream only its sound can follow.
    static let soundOnly = Notification.Name("MacAirPlaySoundOnly")

    static func open() {
        guard let picker, let button = firstButton(in: picker) else {
            MacDiagnostics.log("airplay.open no picker")
            return
        }
        // Off if a receiver refused the last stream; the viewer is asking again.
        picker.player?.allowsExternalPlayback = true
        let hasPlayer = picker.player != nil
        let allows = picker.player?.allowsExternalPlayback ?? false
        MacDiagnostics.log("airplay.open player=\(hasPlayer ? "set" : "nil") allowsExternal=\(allows)")
        // A stream Apple's player could not open plays in mpv, and AirPlay video
        // goes through Apple's player only: the list still opens, for the sound.
        if !hasPlayer { NotificationCenter.default.post(name: soundOnly, object: nil) }
        // The picker does not announce opening when the app opens it, only
        // closing, so mark it open here; the close callback clears it.
        isPresenting = true
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        button.performClick(nil)
        // The list is drawn by a system process inside a remote view, not a
        // window of Omni's, so there is no window to focus; keys reach it as
        // long as the player lets them past, which `isPresenting` sees to.
        // If the list ever opens a window of its own, focus that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let opened = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
            MacDiagnostics.log("airplay.list windows=\(opened.map { String(describing: type(of: $0)) })")
            opened.last?.makeKey()
        }
        // The close callback clears the flag; this only guards against it never
        // arriving, which would leave the player deaf to the keyboard.
        let opening = Date()
        lastOpened = opening
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if isPresenting, lastOpened == opening { isPresenting = false }
        }
    }

    private static func firstButton(in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton { return button }
            if let nested = firstButton(in: subview) { return nested }
        }
        return nil
    }
}

/// Lies under the AirPlay button, all but invisible: the system draws the
/// receiver list from it.
struct MacAirPlayRoutePicker: NSViewRepresentable {
    @ObservedObject var engine: AetherEngine

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        // The picker only anchors the list the app opens; the control bar has its
        // own AirPlay button. Its icon showed through over dark frames even at 2%.
        for state: AVRoutePickerView.ButtonState in [.normal, .normalHighlighted, .active, .activeHighlighted] {
            picker.setRoutePickerButtonColor(.clear, for: state)
        }
        picker.delegate = context.coordinator
        attach(engine.currentAVPlayer, to: picker)
        MacAirPlay.picker = picker
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        if picker.player !== engine.currentAVPlayer { attach(engine.currentAVPlayer, to: picker) }
        MacAirPlay.picker = picker
    }

    private func attach(_ player: AVPlayer?, to picker: AVRoutePickerView) {
        picker.player = player
        // Allowed by default, but said outright: without it the list offers
        // the TVs for sound only, which is all that happened on the first try.
        player?.allowsExternalPlayback = true
        MacDiagnostics.log("airplay.picker player=\(player == nil ? "nil" : "set")")
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVRoutePickerViewDelegate {
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            let player = routePickerView.player
            // Read again a moment later: the switch to the receiver lands after
            // the list closes.
            MacAirPlay.isPresenting = false
            // A receiver that refused the stream switches external playback off
            // to bring the picture back. The list can stay open through that,
            // and a TV picked from it afterwards then got the sound only; the
            // choice made, video may go out again.
            player?.allowsExternalPlayback = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MacDiagnostics.log("airplay.chosen " + Self.describe(player))
            }
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            MacAirPlay.isPresenting = true
        }

        private static func describe(_ player: AVPlayer?) -> String {
            guard let player else { return "player=nil" }
            let external = player.isExternalPlaybackActive
            let status = player.currentItem?.status.rawValue ?? -1
            return "player=set external=\(external) rate=\(player.rate) item=\(status)"
        }
    }
}

// MARK: - Cast device list

/// The Cast device list over the player, driven by the keyboard as well as the
/// pointer. Holds the key router while it is up.
struct MacCastPickerPanel: View {
    @ObservedObject private var cast = MacCastController.shared
    let isCasting: Bool
    let onChoose: (MacCastDevice) -> Void
    let onStop: () -> Void
    let onClose: () -> Void

    @State private var highlighted = 0
    @State private var token: UUID?
    private let keyRouter = MacKeyRouter.shared

    private enum Row: Hashable {
        case device(MacCastDevice)
        case stop
    }

    private var rows: [Row] {
        cast.devices.map(Row.device) + (isCasting ? [.stop] : [])
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "tv.badge.wifi")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Cast to")
                        .font(.system(size: 34, weight: .bold))
                }
                .foregroundColor(.white)

                if rows.isEmpty {
                    HStack(spacing: 14) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Looking for Chromecasts on your network…")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.vertical, 10)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                            rowView(row, isHighlighted: index == min(highlighted, rows.count - 1))
                                .onTapGesture { activate(row) }
                        }
                    }
                }

                Text("↑ ↓ to choose · Return to cast · Esc to close")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(36)
            .frame(width: 620, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial))
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black.opacity(0.35)))
        }
        .onAppear {
            cast.startDiscovery()
            token = keyRouter.claim()
            if let current = cast.deviceName,
               let index = cast.devices.firstIndex(where: { $0.name == current }) {
                highlighted = index
            }
        }
        .onDisappear {
            keyRouter.release(token)
            token = nil
        }
        .onReceive(keyRouter.presses.map(Optional.some)) { press in
            guard let press, keyRouter.isFront(token) else { return }
            switch press.key {
            case .up: highlighted = max(0, highlighted - 1)
            case .down: highlighted = min(max(rows.count - 1, 0), highlighted + 1)
            case .activate:
                guard !rows.isEmpty else { return }
                activate(rows[min(highlighted, rows.count - 1)])
            case .back: onClose()
            case .left, .right: break
            }
        }
    }

    private func activate(_ row: Row) {
        switch row {
        case .device(let device): onChoose(device)
        case .stop: onStop()
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, isHighlighted: Bool) -> some View {
        HStack(spacing: 16) {
            switch row {
            case .device(let device):
                Image(systemName: "tv")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 32)
                Text(device.name)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCasting, cast.deviceName == device.name {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                }
            case .stop:
                Image(systemName: "stop.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 32)
                Text("Stop Casting")
                    .font(.system(size: 24, weight: .semibold))
                Spacer(minLength: 8)
            }
        }
        .foregroundColor(isHighlighted ? .black : .white)
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHighlighted ? Color.white : Color.white.opacity(0.08))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Casting

/// The player while casting: the Mac becomes a remote for the Chromecast.
/// Left and Right move between the buttons, Return presses one.
struct MacCastingView: View {
    @ObservedObject private var cast = MacCastController.shared
    let title: String
    let subtitle: String
    let backdropURL: URL?
    let seekStep: Int
    let onStop: () -> Void

    private enum Button: Int, CaseIterable {
        case back, playPause, forward, stop
    }

    @State private var caret = Button.playPause
    @State private var token: UUID?
    private let keyRouter = MacKeyRouter.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let backdropURL {
                AsyncImage(url: backdropURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
                .ignoresSafeArea()
                .opacity(0.32)
                .blur(radius: 24)
                .allowsHitTesting(false)
            }

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "tv.badge.wifi")
                    .font(.system(size: 64, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 44, weight: .bold))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 36) {
                    circleButton(.back, systemImage: "gobackward.\(seekStep)")
                    circleButton(.playPause, systemImage: cast.isPlaying ? "pause.fill" : "play.fill", large: true)
                    circleButton(.forward, systemImage: "goforward.\(seekStep)")
                }
                .padding(.top, 10)
                timeline
                    .frame(width: 1100)
                stopButton
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 80)
        }
        .onAppear { token = keyRouter.claim() }
        .onDisappear {
            keyRouter.release(token)
            token = nil
        }
        .onReceive(keyRouter.presses.map(Optional.some)) { press in
            guard let press, keyRouter.isFront(token) else { return }
            switch press.key {
            case .left: caret = Button(rawValue: max(caret.rawValue - 1, 0)) ?? caret
            case .right: caret = Button(rawValue: min(caret.rawValue + 1, Button.allCases.count - 1)) ?? caret
            case .activate: perform(caret)
            case .up, .down, .back: break
            }
        }
    }

    private var statusText: String {
        let name = cast.deviceName ?? "Cast device"
        if cast.isConnecting { return "Connecting to \(name)…" }
        if cast.isBuffering { return "Loading on \(name)…" }
        return "Playing on \(name)"
    }

    private func perform(_ button: Button) {
        switch button {
        case .back: cast.skip(by: -Double(seekStep))
        case .playPause: cast.togglePlayPause()
        case .forward: cast.skip(by: Double(seekStep))
        case .stop: onStop()
        }
    }

    private func circleButton(_ button: Button, systemImage: String, large: Bool = false) -> some View {
        let isCaret = caret == button
        return Image(systemName: systemImage)
            .font(.system(size: large ? 34 : 28, weight: .semibold))
            .foregroundColor(isCaret ? .black : .white)
            .frame(width: large ? 92 : 74, height: large ? 92 : 74)
            .background(Circle().fill(isCaret ? Color.white : Color.white.opacity(0.14)))
            .contentShape(Circle())
            .onTapGesture {
                caret = button
                perform(button)
            }
    }

    private var stopButton: some View {
        let isCaret = caret == .stop
        return Label("Stop Casting", systemImage: "stop.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(isCaret ? .black : .white)
            .padding(.horizontal, 26)
            .frame(height: 54)
            .background(Capsule().fill(isCaret ? Color.white : Color.white.opacity(0.14)))
            .contentShape(Capsule())
            .onTapGesture {
                caret = .stop
                onStop()
            }
    }

    private var timeline: some View {
        let total = max(cast.duration, 1)
        let shown = min(cast.position, total)
        return VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white)
                        .frame(width: proxy.size.width * CGFloat(shown / total))
                }
            }
            .frame(height: 8)
            HStack {
                Text(Self.format(shown))
                Spacer()
                Text("-" + Self.format(max(total - shown, 0)))
            }
            .font(.system(size: 20, weight: .medium).monospacedDigit())
            .foregroundColor(.white.opacity(0.75))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
#endif

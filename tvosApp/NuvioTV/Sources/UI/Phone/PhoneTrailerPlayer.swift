#if os(iOS)
import AVFoundation
import SwiftUI

/// The trailer behind a show or movie page.
///
/// Unlike the TV's `TrailerPreviewPlayer`, which reveals on the first decoded
/// frame, this one holds back until several seconds are buffered: on a phone
/// connection the first frame often arrived long before the rest, and the
/// trailer sat frozen on it. It also measures any letterbox bars baked into
/// the video and zooms just enough to hide them.
struct PhoneTrailerView: View {
    let meta: NuvioMeta
    /// The page's own conditions: the delay has run out, the art is on
    /// screen, nothing is covering it. Playback also waits for the buffer.
    let isActive: Bool

    @StateObject private var controller = PhoneTrailerController()
    @AppStorage(SettingsKey.trailerPreviewSound) private var trailerPreviewSound = false

    private var isShowing: Bool {
        isActive && controller.isBuffered && !controller.didFinish
    }

    var body: some View {
        GeometryReader { proxy in
            TrailerPlayerSurface(player: controller.player, onReadyForDisplay: {})
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(controller.zoom(toFill: proxy.size))
                .animation(.easeInOut(duration: 0.4), value: controller.contentFraction)
        }
        .opacity(isShowing ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: isShowing)
        .allowsHitTesting(false)
        .task(id: meta.id) { await controller.load(meta) }
        .onChange(of: isShowing, initial: true) { _, showing in
            if showing {
                applySound()
                controller.player.play()
            } else {
                controller.player.pause()
            }
        }
        .onChange(of: trailerPreviewSound) { _, _ in applySound() }
        .onDisappear { controller.tearDown() }
    }

    private func applySound() {
        controller.player.isMuted = !trailerPreviewSound
        if trailerPreviewSound { PlaybackAudioSession.activateMoviePlayback() }
    }
}

@MainActor
final class PhoneTrailerController: ObservableObject {
    /// Enough is buffered to play without stalling straight away.
    @Published private(set) var isBuffered = false
    @Published private(set) var didFinish = false
    /// Height of the picture inside the video, as a fraction of its frame:
    /// below 1 when the trailer carries letterbox bars. Nil until measured.
    @Published private(set) var contentFraction: CGFloat?
    @Published private(set) var videoAspect: CGFloat = 16.0 / 9.0

    let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private var endObserver: NSObjectProtocol?
    private var watchTask: Task<Void, Never>?
    private var lastMeasurement: CGFloat?

    /// Seconds buffered ahead before the trailer is allowed to show.
    private static let requiredBuffer: Double = 6

    func load(_ meta: NuvioMeta) async {
        tearDown()
        guard let source = await YouTubeTrailerResolver.shared.resolvePreview(for: meta),
              let url = URL(string: source.videoUrl),
              !Task.isCancelled else { return }

        var options: [String: Any] = [:]
        if let agent = source.requestHeaders["User-Agent"], !agent.isEmpty {
            options[AVURLAssetHTTPUserAgentKey] = agent
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = 15
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        self.output = output
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = true
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish = true }
        }
        watchTask = Task { [weak self] in await self?.watch(item) }
    }

    func tearDown() {
        watchTask?.cancel()
        watchTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        output = nil
        isBuffered = false
        didFinish = false
        contentFraction = nil
        lastMeasurement = nil
    }

    /// How much to scale an aspect-fill video in `box` so its letterbox bars
    /// fall outside the box.
    func zoom(toFill box: CGSize) -> CGFloat {
        guard let content = contentFraction, content < 0.98, box.width > 0, box.height > 0 else { return 1 }
        // Aspect fill draws the video at least as tall as the box; the share
        // of its height that shows is box / drawn height.
        let drawnHeight = max(box.height, box.width / videoAspect)
        let visible = box.height / drawnHeight
        return min(max(visible / content, 1), 1.6)
    }

    // MARK: Buffer and bars

    private func watch(_ item: AVPlayerItem) async {
        var prerolled = false
        var readySince: Date?
        while !Task.isCancelled {
            if item.status == .failed { return }
            if item.status == .readyToPlay {
                let size = item.presentationSize
                if size.width > 0, size.height > 0 { videoAspect = size.width / size.height }
                if !prerolled, player.rate == 0 {
                    prerolled = true
                    player.preroll(atRate: 1) { _ in }
                }
                readySince = readySince ?? Date()
                if !isBuffered, hasEnoughBuffer(item, waitedSince: readySince) {
                    isBuffered = true
                }
                if contentFraction == nil { measureBars(item) }
                // Bars measured and buffered: nothing more to watch.
                if isBuffered, contentFraction != nil { return }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func hasEnoughBuffer(_ item: AVPlayerItem, waitedSince: Date?) -> Bool {
        let now = item.currentTime().seconds
        let duration = item.duration.seconds
        let ahead = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .first { $0.containsTime(item.currentTime()) || $0.start.seconds <= now + 0.1 }
            .map { $0.end.seconds - now } ?? 0
        if ahead >= Self.requiredBuffer { return true }
        // A short trailer that is fully loaded counts as buffered.
        if duration.isFinite, duration > 0, now + ahead >= duration - 0.5 { return true }
        // AVPlayer can stop filling while paused; after a long wait, settle
        // for its own judgement that playback will keep up.
        if let waitedSince, Date().timeIntervalSince(waitedSince) > 15, item.isPlaybackLikelyToKeepUp {
            return true
        }
        return false
    }

    /// Looks for black bands at the top and bottom of the current frame.
    /// A frame counts only when its picture fills most of the height and the
    /// bands match, so a black title card or a logo on black is skipped; the
    /// answer is taken once two frames agree.
    private func measureBars(_ item: AVPlayerItem) {
        guard let output else { return }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) || lastMeasurement == nil,
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
              let fraction = Self.contentFraction(in: buffer) else { return }
        if let last = lastMeasurement, abs(last - fraction) < 0.015 {
            contentFraction = min(last, fraction)
        } else {
            lastMeasurement = fraction
        }
    }

    private static func contentFraction(in buffer: CVPixelBuffer) -> CGFloat? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 16, height > 16 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let columnStep = max(width / 48, 1)

        func isDark(_ y: Int) -> Bool {
            let row = pixels + y * rowBytes
            var x = columnStep / 2
            while x < width {
                let p = row + x * 4
                // BGRA: brightest channel against a near-black threshold.
                if max(p[0], p[1], p[2]) > 30 { return false }
                x += columnStep
            }
            return true
        }

        var top = 0
        while top < height / 2, isDark(top) { top += 1 }
        var bottom = 0
        while bottom < height / 2, isDark(height - 1 - bottom) { bottom += 1 }

        let topShare = CGFloat(top) / CGFloat(height)
        let bottomShare = CGFloat(bottom) / CGFloat(height)
        let content = 1 - topShare - bottomShare
        // Whole frame black, or a small logo: not a frame to judge by.
        guard content >= 0.6 else { return nil }
        // Letterboxing is symmetric; a dark sky or floor on one side is not.
        guard abs(topShare - bottomShare) <= 0.02 else { return nil }
        return content
    }
}
#endif

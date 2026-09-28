#if os(iOS)
import SwiftUI

/// Touch controls over the shared player: tap to show/hide, double-tap either
/// side to skip, a draggable scrubber, and menus for subtitles, audio and
/// speed. Stands in for tvOS `PlayerControls` and its Siri Remote catchers.
struct PhonePlayerControls: View {
    @ObservedObject var viewModel: PlayerViewModel
    let isReady: Bool
    let onClose: () -> Void

    @State private var isVisible = true
    @State private var scrubValue: Double?
    @State private var hideTask: Task<Void, Never>?

    private var isPlaying: Bool { viewModel.status == .playing }

    var body: some View {
        ZStack {
            // Full-screen tap target; also the double-tap-to-skip zones.
            HStack(spacing: 0) {
                tapZone { viewModel.skipBackward() }
                tapZone { viewModel.skipForward() }
            }

            if isVisible {
                chrome
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .onAppear {
            scheduleHide()
            PhoneOrientation.request(.landscape)
        }
        .onDisappear { PhoneOrientation.request(.portrait) }
        .onChange(of: viewModel.status) { _, status in
            if status == .playing { scheduleHide() } else { hideTask?.cancel() }
        }
        .statusBarHidden(!isVisible)
        .persistentSystemOverlays(.hidden)
    }

    private func tapZone(onDoubleTap: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onDoubleTap()
                reveal()
            }
            .onTapGesture {
                isVisible.toggle()
                if isVisible { scheduleHide() }
            }
    }

    private var chrome: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if isReady { transport }
                Spacer()
                if isReady { timeline }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close player")

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.title).font(.headline).lineLimit(1)
                if !viewModel.subtitle.isEmpty {
                    Text(viewModel.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            .padding(.top, 10)

            Spacer()

            if isReady { optionsMenu }
        }
    }

    private var transport: some View {
        HStack(spacing: 56) {
            Button { viewModel.skipBackward(); reveal() } label: {
                Image(systemName: "gobackward.\(viewModel.seekStepSeconds)").font(.title)
            }
            Button { viewModel.togglePlayPause(); reveal() } label: {
                Group {
                    if viewModel.status == .buffering {
                        // The shared player draws the buffering spinner in
                        // the centre; a second one here stacked on top of it.
                        Color.clear
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .font(.system(.largeTitle))
                .frame(width: 64, height: 64)
            }
            Button { viewModel.skipForward(); reveal() } label: {
                Image(systemName: "goforward.\(viewModel.seekStepSeconds)").font(.title)
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if viewModel.isLiveStream {
            Text("LIVE").font(.caption.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            PhonePlayerTimeline(
                clock: viewModel.clock,
                scrubValue: $scrubValue,
                onBeginScrub: { hideTask?.cancel() },
                onCommit: { target in
                    viewModel.seek(to: target)
                    scheduleHide()
                }
            )
        }
    }

    private var optionsMenu: some View {
        Menu {
            if viewModel.subtitles.count > 1 {
                Menu {
                    ForEach(viewModel.subtitles) { track in
                        Button { viewModel.selectSubtitle(track) } label: {
                            trackLabel(track.name.isEmpty ? track.language : track.name, isSelected: track.isSelected)
                        }
                    }
                } label: { Label("Subtitles", systemImage: "captions.bubble") }
            }
            if viewModel.audioTracks.count > 1 {
                Menu {
                    ForEach(viewModel.audioTracks) { track in
                        Button { viewModel.selectAudio(track) } label: {
                            trackLabel(track.name.isEmpty ? track.languageName : track.name, isSelected: track.isSelected)
                        }
                    }
                } label: { Label("Audio", systemImage: "speaker.wave.2") }
            }
            Picker(selection: Binding(get: { viewModel.playbackSpeed }, set: { viewModel.setSpeed($0) })) {
                ForEach(PlaybackSpeed.allCases) { speed in
                    Text(String(format: "%gx", speed.rawValue)).tag(speed)
                }
            } label: { Label("Speed", systemImage: "gauge.with.dots.needle.67percent") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .onTapGesture { hideTask?.cancel() }
    }

    @ViewBuilder
    private func trackLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func reveal() {
        isVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, scrubValue == nil else { return }
            isVisible = false
        }
    }
}


/// Position and scrubber. Observes `PlaybackClock` directly: the clock ticks
/// many times a second and is kept off `PlayerViewModel` so those ticks
/// re-render only this.
private struct PhonePlayerTimeline: View {
    @ObservedObject var clock: PlaybackClock
    @Binding var scrubValue: Double?
    let onBeginScrub: () -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        let duration = max(clock.duration, 1)
        let shown = scrubValue ?? clock.position
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { shown }, set: { scrubValue = $0 }),
                in: 0...duration,
                onEditingChanged: { editing in
                    if editing {
                        onBeginScrub()
                    } else if let target = scrubValue {
                        scrubValue = nil
                        onCommit(target)
                    }
                }
            )
            .tint(.white)
            HStack {
                Text(Self.format(shown))
                Spacer()
                Text("-" + Self.format(max(duration - shown, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Turns the phone to landscape for video and back afterwards, as video apps
/// do. The user can still rotate freely; this only sets the starting point.
enum PhoneOrientation {
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif

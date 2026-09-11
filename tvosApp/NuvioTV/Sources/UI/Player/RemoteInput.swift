import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)
/// macOS trackpad/scroll capture, standing in for the Siri Remote trackpad.
///
/// The tvOS version restricts a pan recognizer to `.indirect` touches so the
/// focus engine does not swallow it. The Mac has no indirect-touch concept, and
/// AppKit reports trackpad scrolling as `.scrollWheel` events rather than pans,
/// so the equivalent capture is a window-level scroll monitor.
///
/// The callback contract is deliberately identical: cumulative x/y translation
/// in points, so `PlayerViewModel`'s scrub/peek maths is untouched. AppKit's
/// `scrollingDelta` is per-event rather than cumulative, hence the running total.
struct RemoteTouchCatcher: NSViewRepresentable {
    let isActive: () -> Bool
    let onBegan: () -> Void
    let onMoved: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> TouchHostView {
        let view = TouchHostView()
        view.configure(isActive: isActive, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
        return view
    }

    func updateNSView(_ nsView: TouchHostView, context: Context) {
        nsView.configure(isActive: isActive, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    static func dismantleNSView(_ nsView: TouchHostView, coordinator: ()) {
        nsView.removeRecognizers()
    }
}

final class TouchHostView: NSView {
    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var isTracking = false
    /// A mouse wheel has no begin/end phases, so a gap in events ends the gesture.
    private var wheelIdleTimer: Timer?

    private var isActive: () -> Bool = { false }
    private var onBegan: () -> Void = {}
    private var onMoved: (CGFloat, CGFloat) -> Void = { _, _ in }
    private var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }

    func configure(
        isActive: @escaping () -> Bool,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (CGFloat, CGFloat) -> Void,
        onEnded: @escaping (CGFloat, CGFloat) -> Void
    ) {
        self.isActive = isActive
        self.onBegan = onBegan
        self.onMoved = onMoved
        self.onEnded = onEnded
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeRecognizers()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func removeRecognizers() {
        endGestureIfTracking()
        wheelIdleTimer?.invalidate()
        wheelIdleTimer = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        wheelIdleTimer?.invalidate()
    }

    /// Returns true when the event was consumed by scrubbing.
    private func handle(_ event: NSEvent) -> Bool {
        guard isActive() else { return false }

        switch event.phase {
        case .began:
            beginGesture()
        case .changed:
            guard isTracking else { return false }
            accumulate(event)
        case .ended, .cancelled:
            guard isTracking else { return false }
            endGestureIfTracking()
        default:
            // Mouse wheel (and momentum tails): synthesise a gesture around it.
            guard event.momentumPhase == [] else { return isTracking }
            if !isTracking { beginGesture() }
            accumulate(event)
            scheduleWheelIdleEnd()
        }
        return true
    }

    private func beginGesture() {
        accumulatedX = 0
        accumulatedY = 0
        isTracking = true
        onBegan()
    }

    private func accumulate(_ event: NSEvent) {
        accumulatedX += event.scrollingDeltaX
        accumulatedY += event.scrollingDeltaY
        onMoved(accumulatedX, accumulatedY)
    }

    private func endGestureIfTracking() {
        guard isTracking else { return }
        isTracking = false
        onEnded(accumulatedX, accumulatedY)
    }

    private func scheduleWheelIdleEnd() {
        wheelIdleTimer?.invalidate()
        wheelIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.endGestureIfTracking()
        }
    }
}

/// Space / K for play-pause, replacing tvOS's dedicated `onPlayPauseCommand`.
/// There is no play-pause command on macOS, and these are the two keys every
/// Mac video player binds.
struct MacPlayPauseKeyCatcher: NSViewRepresentable {
    let onToggle: () -> Void

    func makeNSView(context: Context) -> PlayPauseKeyHostView {
        let view = PlayPauseKeyHostView()
        view.onToggle = onToggle
        return view
    }

    func updateNSView(_ nsView: PlayPauseKeyHostView, context: Context) {
        nsView.onToggle = onToggle
    }

    static func dismantleNSView(_ nsView: PlayPauseKeyHostView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

final class PlayPauseKeyHostView: NSView {
    var onToggle: () -> Void = {}

    private static let spaceKeyCode: UInt16 = 49
    private static let kKeyCode: UInt16 = 40

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == Self.spaceKeyCode || event.keyCode == Self.kKeyCode else { return event }
            // Modified presses belong to menu commands, and auto-repeat should
            // not toggle playback dozens of times.
            let disqualifying: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard !event.isARepeat,
                  event.modifierFlags.intersection(disqualifying).isEmpty else { return event }
            self.onToggle()
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
#else
/// Window-level Siri Remote trackpad capture. Uses a `UIPanGestureRecognizer`
/// restricted to `.indirect` touches so the focus engine does not swallow pans.
/// Active only while the player needs it (bare video / scrubbing).
struct RemoteTouchCatcher: UIViewRepresentable {
    let isActive: () -> Bool
    let onBegan: () -> Void
    let onMoved: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> TouchHostView {
        let view = TouchHostView()
        view.configure(isActive: isActive, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
        return view
    }

    func updateUIView(_ uiView: TouchHostView, context: Context) {
        uiView.configure(isActive: isActive, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    static func dismantleUIView(_ uiView: TouchHostView, coordinator: ()) {
        uiView.removeRecognizers()
    }
}

final class TouchHostView: UIView, UIGestureRecognizerDelegate {
    private var pan: UIPanGestureRecognizer?
    private weak var attachedWindow: UIWindow?

    private var isActive: () -> Bool = { false }
    private var onBegan: () -> Void = {}
    private var onMoved: (CGFloat, CGFloat) -> Void = { _, _ in }
    private var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }

    func configure(
        isActive: @escaping () -> Bool,
        onBegan: @escaping () -> Void,
        onMoved: @escaping (CGFloat, CGFloat) -> Void,
        onEnded: @escaping (CGFloat, CGFloat) -> Void
    ) {
        self.isActive = isActive
        self.onBegan = onBegan
        self.onMoved = onMoved
        self.onEnded = onEnded
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizers()
        guard let window else { return }
        let p = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        p.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        p.cancelsTouchesInView = false
        p.delegate = self
        window.addGestureRecognizer(p)
        pan = p
        attachedWindow = window
    }

    func removeRecognizers() {
        if let attachedWindow, let pan {
            attachedWindow.removeGestureRecognizer(pan)
        }
        pan = nil
        attachedWindow = nil
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard isActive() else { return }
        let t = g.translation(in: g.view)
        switch g.state {
        case .began: onBegan()
        case .changed: onMoved(t.x, t.y)
        case .ended, .cancelled, .failed: onEnded(t.x, t.y)
        default: break
        }
    }

    func gestureRecognizer(
        _ g: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        isActive()
    }
}
#endif

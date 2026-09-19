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

/// The player's keyboard, replacing tvOS's remote commands.
///
/// macOS has no play-pause command and `onMoveCommand` only reaches a view that
/// holds SwiftUI focus, which the player usually does not — so the bindings
/// every Mac video player carries are installed as a window-level monitor
/// instead. Space/K toggle, J/L and the arrows seek, E and S open the panels.
struct MacPlayerKeyCatcher: NSViewRepresentable {
    let onTogglePlayPause: () -> Void
    /// Signed seconds.
    let onSeek: (Double) -> Void
    let onRevealControls: () -> Void
    let onEpisodes: () -> Void
    let onSources: () -> Void
    let onSettings: () -> Void
    let seekStep: () -> Double
    let onToggleHelp: () -> Void
    /// A panel owns Up/Down/Return while it is open: the same keys move its
    /// rows instead of seeking the film behind it.
    let isPanelOpen: () -> Bool
    let onPanelMove: (Int) -> Void
    let onPanelActivate: () -> Void
    /// Closes whatever is on top. False when there was nothing to close, which
    /// lets Escape fall through to leaving the player.
    let onDismissTopmost: () -> Bool
    /// While the reference is up it swallows everything except its own keys.
    let isHelpVisible: () -> Bool
    /// The settings panel drives its own caret through `MacKeyRouter`, so this
    /// monitor must let its keys past rather than seeking the film behind it.
    let isSettingsOpen: () -> Bool
    /// Offered the arrows before they seek. True when the player's caret took
    /// the key.
    let onCaretMove: (MoveCommandDirection) -> Bool
    /// Offered Return. True when something under the caret was pressed.
    let onCaretActivate: () -> Bool
    /// True while a full-screen layer (the post-play screen) is up: play/pause
    /// and the seek keys must not reach the film behind it.
    let swallowsTransportKeys: () -> Bool

    func makeNSView(context: Context) -> PlayerKeyHostView {
        let view = PlayerKeyHostView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: PlayerKeyHostView, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: PlayerKeyHostView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    private func apply(to view: PlayerKeyHostView) {
        view.onTogglePlayPause = onTogglePlayPause
        view.onSeek = onSeek
        view.onRevealControls = onRevealControls
        view.onEpisodes = onEpisodes
        view.onSources = onSources
        view.seekStep = seekStep
        view.onSettings = onSettings
        view.onToggleHelp = onToggleHelp
        view.isPanelOpen = isPanelOpen
        view.onPanelMove = onPanelMove
        view.onPanelActivate = onPanelActivate
        view.onDismissTopmost = onDismissTopmost
        view.isHelpVisible = isHelpVisible
        view.isSettingsOpen = isSettingsOpen
        view.onCaretMove = onCaretMove
        view.onCaretActivate = onCaretActivate
        view.swallowsTransportKeys = swallowsTransportKeys
    }
}

final class PlayerKeyHostView: NSView {
    var onTogglePlayPause: () -> Void = {}
    var onSeek: (Double) -> Void = { _ in }
    var onRevealControls: () -> Void = {}
    var onEpisodes: () -> Void = {}
    var onSources: () -> Void = {}
    var seekStep: () -> Double = { 10 }
    var onSettings: () -> Void = {}
    var onToggleHelp: () -> Void = {}
    var isPanelOpen: () -> Bool = { false }
    var onPanelMove: (Int) -> Void = { _ in }
    var onPanelActivate: () -> Void = {}
    var onDismissTopmost: () -> Bool = { false }
    var isHelpVisible: () -> Bool = { false }
    var isSettingsOpen: () -> Bool = { false }
    var onCaretMove: (MoveCommandDirection) -> Bool = { _ in false }
    var onCaretActivate: () -> Bool = { false }
    var swallowsTransportKeys: () -> Bool = { false }

    private enum Key {
        static let space: UInt16 = 49
        static let k: UInt16 = 40
        static let j: UInt16 = 38
        static let l: UInt16 = 37
        static let e: UInt16 = 14
        static let s: UInt16 = 1
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
        static let slash: UInt16 = 44
        static let escape: UInt16 = 53
        static let comma: UInt16 = 43
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
    }

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Modified presses belong to menu commands.
            let disqualifying: NSEvent.ModifierFlags = [.command, .option, .control]
            guard event.modifierFlags.intersection(disqualifying).isEmpty else { return event }

            // `?` is shift-/ — the standard "what can I press" key, and the only
            // reason shift is not disqualifying above.
            let isHelpKey = event.keyCode == Key.slash && event.modifierFlags.contains(.shift)
            if isHelpKey {
                guard !event.isARepeat else { return nil }
                self.onToggleHelp()
                return nil
            }
            if self.isHelpVisible() {
                // Escape closes it; everything else is swallowed so the film
                // does not seek behind an open reference sheet.
                if event.keyCode == Key.escape { self.onToggleHelp() }
                return nil
            }

            // Escape backs out one layer at a time. Only once there is nothing
            // left to close does it fall through to leaving the player.
            if event.keyCode == Key.escape {
                guard !event.isARepeat else { return nil }
                return self.onDismissTopmost() ? nil : event
            }

            // The settings panel owns everything else while it is up. Comma
            // still closes it, and Escape was handled just above.
            if self.isSettingsOpen() {
                guard event.keyCode == Key.comma else { return event }
                guard !event.isARepeat else { return nil }
                self.onSettings()
                return nil
            }

            // E, S and comma always reach here, panel open or not — that is
            // what makes them toggles rather than one-way doors.
            switch event.keyCode {
            case Key.e:
                guard !event.isARepeat else { return nil }
                self.onEpisodes()
                return nil
            case Key.s:
                guard !event.isARepeat else { return nil }
                self.onSources()
                return nil
            case Key.comma:
                guard !event.isARepeat else { return nil }
                self.onSettings()
                return nil
            default:
                break
            }

            // An open panel owns the arrows and Return; the film behind it must
            // not seek while the viewer is picking an episode.
            if self.isPanelOpen() {
                switch event.keyCode {
                case Key.upArrow: self.onPanelMove(-1)
                case Key.downArrow: self.onPanelMove(1)
                case Key.returnKey, Key.keypadEnter:
                    guard !event.isARepeat else { return nil }
                    self.onPanelActivate()
                default: return event
                }
                return nil
            }

            let caretDirection: MoveCommandDirection? = switch event.keyCode {
            case Key.leftArrow: .left
            case Key.rightArrow: .right
            case Key.upArrow: .up
            case Key.downArrow: .down
            default: nil
            }
            if let caretDirection, self.onCaretMove(caretDirection) {
                return nil
            }
            if event.keyCode == Key.returnKey || event.keyCode == Key.keypadEnter {
                guard !event.isARepeat else { return nil }
                return self.onCaretActivate() ? nil : event
            }

            if self.swallowsTransportKeys() { return nil }

            switch event.keyCode {
            case Key.space, Key.k:
                // Auto-repeat would toggle playback dozens of times.
                guard !event.isARepeat else { return nil }
                self.onTogglePlayPause()
            case Key.j, Key.leftArrow:
                self.onSeek(-self.seekStep())
            case Key.l, Key.rightArrow:
                self.onSeek(self.seekStep())
            case Key.upArrow, Key.downArrow:
                guard !event.isARepeat else { return nil }
                self.onRevealControls()
            default:
                return event
            }
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

/// The keyboard reference, opened with `?`.
///
/// These bindings are invisible otherwise: a player has no menus to read them
/// off, and a viewer who does not already know that J and L seek will never
/// discover it. Drawn inside the canvas so it scales with the rest of the app.
struct MacPlayerShortcutsOverlay: View {
    let seekStep: Int
    let showsEpisodes: Bool
    let showsSources: Bool
    let onDismiss: () -> Void

    private var rows: [(keys: String, action: String)] {
        var rows: [(String, String)] = [
            ("Space  ·  K", "Play / pause"),
            ("←  ·  J", "Back \(seekStep)s"),
            ("→  ·  L", "Forward \(seekStep)s"),
            ("Hold ←  ·  Hold →", "Continuous seek"),
            ("↑  ·  ↓", "Show the controls"),
        ]
        if showsEpisodes { rows.append(("E", "Episodes — press again to close")) }
        if showsSources { rows.append(("S", "Sources — press again to close")) }
        rows.append((",", "Playback settings"))
        rows.append(("↑  ·  ↓  ·  ↩", "Move and choose, in a panel"))
        rows.append(("?", "This list"))
        rows.append(("Esc", "Back out one layer"))
        return rows.map { (keys: $0.0, action: $0.1) }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 22) {
                Text(L10n.string("player_shortcuts_title", fallback: "Keyboard Shortcuts"))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(rows, id: \.keys) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 28) {
                            Text(row.keys)
                                .font(.system(size: 21, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .frame(width: 220, alignment: .leading)
                            Text(row.action)
                                .font(.system(size: 21))
                                .foregroundColor(.white.opacity(0.72))
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(44)
            .frame(width: 640, alignment: .leading)
            .background {
                if #available(macOS 26.0, *) {
                    shape.fill(Color.black.opacity(0.45)).glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
        }
    }
}

/// Hides the pointer after three idle seconds while a film is playing, and
/// brings it back the moment the mouse moves.
///
/// `setHiddenUntilMouseMoves` rather than `NSCursor.hide()`: hide/unhide are a
/// balanced pair, and any path that hid without unhiding — a window change, the
/// view going away mid-timer — would leave the pointer invisible for the whole
/// app. The system restores it on the next movement on its own.
/// A click target that wins against an AppKit view underneath it.
///
/// SwiftUI draws its own content into the hosting view, but a representable is
/// a genuine NSView subview, so it hit-tests above any SwiftUI button drawn
/// beneath it however the z-order reads in SwiftUI. This is an NSView too, and
/// a later sibling, so the click comes back.
struct MacClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> ClickCatcherView {
        let view = ClickCatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ClickCatcherView, context: Context) {
        nsView.onClick = onClick
    }
}

final class ClickCatcherView: NSView {
    var onClick: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

struct MacCursorAutoHide: NSViewRepresentable {
    let isActive: Bool

    func makeNSView(context: Context) -> CursorAutoHideView {
        let view = CursorAutoHideView()
        view.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: CursorAutoHideView, context: Context) {
        nsView.setActive(isActive)
    }

    static func dismantleNSView(_ nsView: CursorAutoHideView, coordinator: ()) {
        nsView.setActive(false)
    }
}

final class CursorAutoHideView: NSView {
    private static let idleDelay: TimeInterval = 3

    private var monitor: Any?
    private var timer: Timer?
    private var isActive = false

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startMonitoring()
            scheduleHide()
        } else {
            stopMonitoring()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard isActive else { return }
        if window == nil { stopMonitoring() } else { startMonitoring(); scheduleHide() }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.scheduleHide()
            return event
        }
    }

    private func scheduleHide() {
        timer?.invalidate()
        guard isActive else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    deinit {
        timer?.invalidate()
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

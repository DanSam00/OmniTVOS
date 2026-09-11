#if os(macOS)
import AppKit
import SwiftUI

/// Makes the window full-bleed, sizes it sensibly, and restores the shape it
/// had last time — without going through SwiftUI's `.windowStyle`.
///
/// `.windowStyle(.hiddenTitleBar)` produces the right look but routes through
/// `AppKitWindowController.updateToolbarIfNeeded`, which calls `setToolbar:`
/// synchronously inside a constraint pass. During a fullscreen transition that
/// re-enters the same code and the second pass removes a KVO observer the first
/// one already removed — an uncaught `NSException`, and the app dies inside
/// AppKit with no frames of ours on the stack.
///
/// Setting the same properties on `NSWindow` directly gets the identical
/// appearance and never installs a toolbar for AppKit to shuffle.
struct MacWindowConfigurator: NSViewRepresentable {
    /// AppKit persists the frame itself under this name; fullscreen is not part
    /// of a saved frame, so that is tracked separately.
    private static let frameAutosaveName = "OmniMainWindow"
    private static let wasFullScreenKey = "OmniMainWindowWasFullScreen"

    /// The layout is designed for a 16:9 TV screen, so the window keeps that
    /// shape. These are only used the first time the app runs — after that the
    /// saved frame wins.
    private static let defaultSize = NSSize(width: 1600, height: 900)
    private static let minimumSize = NSSize(width: 1200, height: 675)

    final class Coordinator {
        var didApplyInitialFrame = false
        var fullScreenObservers: [NSObjectProtocol] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached yet during make; configure on the next turn
        // of the run loop, and again on update in case the view is re-hosted.
        DispatchQueue.main.async { configure(view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        coordinator.fullScreenObservers = []
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // Nothing in this UI belongs in a toolbar, and leaving one attached is
        // what triggers the AppKit re-entrancy above.
        window.toolbar = nil
        // The app draws its own backdrop; without this the window flashes the
        // system background during resize and fullscreen transitions.
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.minSize = Self.minimumSize

        guard !coordinator.didApplyInitialFrame else { return }
        coordinator.didApplyInitialFrame = true

        applySavedOrDefaultFrame(to: window)
        trackFullScreenChanges(for: window, coordinator: coordinator)
        restoreFullScreenIfNeeded(window)

        MacDiagnostics.log(
            "window.configured size=\(Int(window.frame.width))x\(Int(window.frame.height)) "
                + "fullScreen=\(window.styleMask.contains(.fullScreen))"
        )
    }

    private func applySavedOrDefaultFrame(to window: NSWindow) {
        // AppKit stores the frame under this key; its presence is how we know
        // whether this is a first run or a returning one.
        let defaultsKey = "NSWindow Frame \(Self.frameAutosaveName)"
        let hasSavedFrame = UserDefaults.standard.string(forKey: defaultsKey) != nil

        window.setFrameAutosaveName(Self.frameAutosaveName)

        // macOS may have already restored the window into fullscreen before we
        // run. Sizing it now would fight that transition, and saving the frame
        // would record the screen-sized one as the windowed default.
        guard !window.styleMask.contains(.fullScreen) else {
            MacDiagnostics.log("window.frame.skipped reason=fullScreen")
            return
        }

        guard !hasSavedFrame else {
            MacDiagnostics.log("window.frame.restored \(NSStringFromRect(window.frame))")
            return
        }

        // First run: open at the design size, shrunk to fit if the display is
        // smaller, and centred.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: .zero, size: Self.defaultSize)
        let width = min(Self.defaultSize.width, visible.width - 40)
        let height = min(Self.defaultSize.height, visible.height - 40)
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(frame, display: true)
        window.saveFrame(usingName: Self.frameAutosaveName)
        MacDiagnostics.log("window.frame.default \(NSStringFromRect(frame))")
    }

    private func trackFullScreenChanges(for window: NSWindow, coordinator: Coordinator) {
        let center = NotificationCenter.default
        let record: (Bool) -> Void = { isFullScreen in
            UserDefaults.standard.set(isFullScreen, forKey: Self.wasFullScreenKey)
        }
        coordinator.fullScreenObservers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                record(true)
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                record(false)
            },
        ]
    }

    private func restoreFullScreenIfNeeded(_ window: NSWindow) {
        guard UserDefaults.standard.bool(forKey: Self.wasFullScreenKey),
              !window.styleMask.contains(.fullScreen) else { return }
        // Toggling before the window is on screen leaves AppKit mid-transition,
        // so let this launch settle first.
        DispatchQueue.main.async {
            guard !window.styleMask.contains(.fullScreen) else { return }
            MacDiagnostics.log("window.restoringFullScreen")
            window.toggleFullScreen(nil)
        }
    }
}

extension View {
    /// Applies the full-bleed window treatment; a no-op anywhere but macOS.
    func macFullBleedWindow() -> some View {
        background(MacWindowConfigurator().frame(width: 0, height: 0))
    }
}
#endif

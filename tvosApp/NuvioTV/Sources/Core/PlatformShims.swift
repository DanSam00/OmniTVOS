#if os(macOS)
import AppKit
import SwiftUI
import IOKit.pwr_mgt
import CoreAudio

/// AppKit stand-ins for the UIKit types this codebase names directly.
///
/// The app was written for tvOS, so UIKit names are threaded through the player
/// stack, the QR/auth helpers and the card views. Aliasing them is far less
/// invasive than rewriting every reference, and it keeps one shared source of
/// truth for tvOS and macOS rather than forking the UI.
///
/// This is not a claim that the types are interchangeable. Where the APIs
/// genuinely differ — view-lifecycle signatures, image initialisers, anything
/// tvOS-only such as `AVDisplayManager` — the call sites still need their own
/// `#if os(macOS)` branch. The aliases only remove the noise so those real
/// differences are what is left.
typealias UIView = NSView
typealias UIViewController = NSViewController
typealias UIWindow = NSWindow
typealias UIImage = NSImage
typealias UIColor = NSColor
typealias UIFont = NSFont
typealias UIBezierPath = NSBezierPath
typealias UIEdgeInsets = NSEdgeInsets
typealias UIViewRepresentable = NSViewRepresentable
typealias UIViewControllerRepresentable = NSViewControllerRepresentable
typealias UIGestureRecognizer = NSGestureRecognizer
typealias UIPanGestureRecognizer = NSPanGestureRecognizer
typealias UILongPressGestureRecognizer = NSPressGestureRecognizer
typealias UIGestureRecognizerDelegate = NSGestureRecognizerDelegate
typealias UIResponder = NSResponder

extension NSImage {
    /// `UIImage(cgImage:)` has no direct AppKit twin — `NSImage` needs a size,
    /// which it takes from the bitmap itself here.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension NSView {
    /// UIKit's layout-invalidation pair, spelled the AppKit way.
    func setNeedsLayout() { needsLayout = true }
    func layoutIfNeeded() { layoutSubtreeIfNeeded() }
}

/// `UIScreen.main` is non-optional and carries metrics AppKit spreads across
/// `NSScreen` under different names. This exposes the four properties the app
/// actually reads, with sane fallbacks for a headless or screenless launch.
enum UIScreen {
    static var main: MacDisplayMetrics {
        MacDisplayMetrics(screen: NSScreen.main ?? NSScreen.screens.first)
    }
}

struct MacDisplayMetrics {
    let screen: NSScreen?

    var bounds: CGRect { screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080) }
    var scale: CGFloat { screen?.backingScaleFactor ?? 2 }
    /// AppKit draws in backing-store pixels, so there is no separate "native"
    /// scale to distinguish from the nominal one.
    var nativeScale: CGFloat { scale }
    var maximumFramesPerSecond: Int { screen?.maximumFramesPerSecond ?? 60 }
}

/// The slice of `UIApplication` this codebase touches. Keeping the mapping in
/// one place means the lifecycle notifications translate identically for both
/// player controllers rather than each inventing its own equivalence.
///
/// AppKit has no background/foreground transition — an app that is not frontmost
/// is still running and still rendering — so resign/become-active is the closest
/// signal, and it is the one that matters here: releasing and rebinding the
/// video surface. Memory-warning notifications have no counterpart at all; the
/// name below is never posted, which leaves those observers correctly inert.
final class UIApplication {
    static let shared = UIApplication()

    static let didEnterBackgroundNotification = NSApplication.didResignActiveNotification
    static let willEnterForegroundNotification = NSApplication.willBecomeActiveNotification
    static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    static let didReceiveMemoryWarningNotification = Notification.Name("OmniMacMemoryWarningNeverPosted")

    var isIdleTimerDisabled: Bool {
        get { MacIdleSleep.isPrevented }
        set { MacIdleSleep.setPrevented(newValue) }
    }

    func canOpenURL(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    @discardableResult
    func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) -> Bool {
        let opened = NSWorkspace.shared.open(url)
        completionHandler?(opened)
        return opened
    }
}

extension NSView {
    /// UIKit's content modes, as used by the animated-image view. AppKit
    /// expresses the same thing as a layer `contentsGravity`.
    enum ContentMode {
        case scaleAspectFill
        case scaleAspectFit
        case scaleToFill

        var contentsGravity: CALayerContentsGravity {
            switch self {
            case .scaleAspectFill: return .resizeAspectFill
            case .scaleAspectFit: return .resizeAspect
            case .scaleToFill: return .resize
            }
        }
    }
}

extension NSImage {
    /// AppKit spells this as a method taking three (optional) arguments. The
    /// shared code reads it as a property, the way UIKit exposes it.
    var shimCGImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension NSImage {
    /// `UIImage.pngData()`, via the bitmap representation AppKit needs anyway.
    func pngData() -> Data? {
        guard let cgImage = shimCGImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// `UIImage.withRenderingMode(.alwaysOriginal)` has no AppKit counterpart:
    /// an `NSImage` is only treated as a template when explicitly marked, and
    /// these composited avatars never are. Kept so the shared code reads the
    /// same on both platforms.
    func withRenderingMode(_ mode: RenderingMode) -> NSImage {
        isTemplate = false
        return self
    }

    enum RenderingMode {
        case alwaysOriginal
        case alwaysTemplate
        case automatic
    }
}

/// Minimal stand-in for `UIGraphicsImageRenderer`: draws into an AppKit bitmap
/// of the same pixel dimensions and hands back an `NSImage`.
struct UIGraphicsImageRenderer {
    let size: CGSize

    init(size: CGSize) {
        self.size = size
    }

    func image(_ actions: (Context) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size.width, height: size.height))
        image.lockFocusFlipped(true)
        if let cgContext = NSGraphicsContext.current?.cgContext {
            actions(Context(cgContext: cgContext))
        }
        image.unlockFocus()
        return image
    }

    struct Context {
        let cgContext: CGContext

        func fill(_ rect: CGRect) {
            cgContext.fill(rect)
        }
    }
}

extension NSColor {
    /// UIKit's `setFill` writes into the current graphics context; AppKit's
    /// `set()` does the same for both fill and stroke.
    func setFill() {
        set()
    }
}

extension Image {
    /// SwiftUI names this initialiser per-platform. Keeping the UIKit spelling
    /// available means the artwork views need no branch.
    init(uiImage: NSImage) {
        self.init(nsImage: uiImage)
    }
}

/// macOS has no software keyboard, so there is nothing to configure — but the
/// settings rows still declare the kind of text they expect, and that intent is
/// worth keeping in the shared code rather than conditioning out.
enum UIKeyboardType {
    case `default`
    case emailAddress
}

/// Autofill hints, kept for the same reason as `UIKeyboardType`: the intent is
/// worth stating in shared code even where the platform cannot act on it.
enum UITextContentType {
    case username
    case password
    case newPassword
    case emailAddress
}

/// The default audio output device, read straight from CoreAudio. tvOS gets
/// this from `AVAudioSession`, which does not exist on macOS.
enum MacAudioRoute {
    /// Stands in for `AVAudioSession.routeChangeNotification`. CoreAudio reports
    /// this as a property change on the system object rather than a
    /// notification, so the listener republishes it through NotificationCenter
    /// to keep the observing code identical on both platforms.
    static let changeNotification = Notification.Name("OmniMacAudioRouteChanged")

    private static var isMonitoring = false
    private static var listenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Idempotent: the listener lives for the life of the process, matching the
    /// audio session observer it replaces.
    static func startMonitoringIfNeeded() {
        guard !isMonitoring else { return }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &listenerAddress,
            DispatchQueue.main
        ) { _, _ in
            NotificationCenter.default.post(name: changeNotification, object: nil)
        }
        isMonitoring = status == noErr
    }

    static var outputDeviceName: String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &nameAddress, 0, nil, &nameSize, &name
        ) == noErr else { return nil }

        let resolved = (name as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? nil : resolved
    }
}

/// `UIApplication.shared.isIdleTimerDisabled` has no macOS equivalent: sleep is
/// managed through IOKit power assertions instead. See `PlaybackWakeLock`.
enum MacIdleSleep {
    private static var assertionID: IOPMAssertionID = 0
    private static var isHeld = false

    static var isPrevented: Bool { isHeld }

    static func setPrevented(_ prevented: Bool) {
        if prevented, !isHeld {
            var id: IOPMAssertionID = 0
            let reason = "Omni video playback" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                isHeld = true
            }
        } else if !prevented, isHeld {
            IOPMAssertionRelease(assertionID)
            isHeld = false
        }
    }
}
#endif

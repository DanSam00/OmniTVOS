#if os(macOS)
import AppKit
import OSLog

/// Crash and lifecycle tracing for the Mac build.
///
/// A SwiftUI app that dies inside AppKit leaves a `.ips` report with a stack but
/// no reason string, which makes an `NSException` crash hard to read. This logs
/// the reason (and our own launch/window events) to a plain file next to the
/// system reports, so a crash can be diagnosed without decoding a crash dump.
///
/// Log file: `~/Library/Logs/Omni/omni.log`
enum MacDiagnostics {
    private static let logger = Logger(subsystem: "com.saminaden.omni.mac", category: "Diagnostics")
    private static let queue = DispatchQueue(label: "com.saminaden.omni.diagnostics")
    private static var didStart = false

    static var logFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Omni", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("omni.log")
    }

    static func start() {
        guard !didStart else { return }
        didStart = true

        NSSetUncaughtExceptionHandler { exception in
            // Keep this synchronous: the process is about to die, so a queued
            // write would never reach the disk.
            MacDiagnostics.writeSynchronously(
                """
                UNCAUGHT EXCEPTION \(exception.name.rawValue)
                reason: \(exception.reason ?? "(none)")
                userInfo: \(exception.userInfo.map(String.init(describing:)) ?? "(none)")
                stack:
                \(exception.callStackSymbols.joined(separator: "\n"))
                """
            )
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("launch — Omni \(version) (\(build)) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        startHitchWatchdog()

        observe(NSApplication.didFinishLaunchingNotification, as: "app.didFinishLaunching")
        observe(NSApplication.didBecomeActiveNotification, as: "app.didBecomeActive")
        observe(NSApplication.didResignActiveNotification, as: "app.didResignActive")
        observe(NSWindow.didEnterFullScreenNotification, as: "window.didEnterFullScreen")
        observe(NSWindow.didExitFullScreenNotification, as: "window.didExitFullScreen")
        observe(NSWindow.didResizeNotification, as: "window.didResize")
    }

    /// Counts arrow keys as they arrive, without consuming them. If these
    /// outnumber the moves Home receives, something between the two is
    /// swallowing the event.
    private static var keyMonitor: Any?

    static func watchArrowKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let names: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up"]
            if let name = names[event.keyCode] {
                let responder = NSApplication.shared.keyWindow?.firstResponder
                let kind = responder.map { String(describing: type(of: $0)) } ?? "nil"
                log("key." + name + " responder=" + kind)
            }
            return event
        }
    }

    static func log(_ message: @autoclosure () -> String) {
        let line = message()
        logger.log("\(line, privacy: .public)")
        queue.async { writeSynchronously(line) }
    }

    /// Reports whenever the main thread is busy long enough to be felt,
    /// wherever it happens.
    ///
    /// A timer that should fire every 100ms is late by exactly as long as the
    /// main thread was blocked, so its lateness measures the stall without
    /// needing to know which screen caused it.
    private static func startHitchWatchdog() {
        var expected = CFAbsoluteTimeGetCurrent() + 0.1
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            let lateMs = (now - expected) * 1000
            expected = now + 0.1
            guard lateMs >= 200 else { return }
            log(String(format: "hitch blocked=%.0fms", lateMs))
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func observe(_ name: Notification.Name, as label: String) {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            log(label)
        }
    }

    private static func writeSynchronously(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
        let url = logFileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif

#if os(macOS)
import SwiftUI

/// Tab switching from the menu bar.
///
/// The tvOS tab bar reveals itself when focus moves up off the top row, which
/// depends on the focus engine macOS does not have — so on the Mac there was no
/// way to change tabs at all. A real menu with ⌘1…⌘5 is the native answer:
/// discoverable, keyboard-driven, and independent of where focus happens to be.
///
/// `selectedTab` is view state inside `ContentView`, which a `Scene`'s commands
/// cannot reach, so requests are published here and the view applies them.
@MainActor
final class MacTabCommandBus: ObservableObject {
    static let shared = MacTabCommandBus()

    @Published var requestedTab: TVTab?

    /// Only the tabs that exist on macOS right now. Search, Library, Calendar
    /// and the profile switcher are parked while keyboard navigation is being
    /// settled — see the `#if !os(macOS)` fences in `TVMainTabView.tabs`.
    static let availableTabs: [TVTab] = [.home, .search, .settings]

    private init() {}

    func request(_ tab: TVTab) {
        requestedTab = tab
    }
}

struct MacTabCommands: Commands {
    /// Only the tabs that exist on macOS right now. Search, Library, Calendar
    /// and the profile switcher are parked while keyboard navigation is being
    /// settled — see the `#if !os(macOS)` fences in `TVMainTabView.tabs`.
    private static let tabs: [(TVTab, KeyEquivalent)] = [
        (.home, "1"),
        (.search, "2"),
        (.settings, "3"),
    ]

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Self.tabs, id: \.0) { tab, key in
                Button(tab.title) {
                    MacTabCommandBus.shared.request(tab)
                }
                .keyboardShortcut(key, modifiers: .command)
            }
            Divider()
        }
    }
}

/// A directional key, once the modifier noise is stripped off.
enum MacKey: Equatable {
    case left, right, up, down, activate
}

/// Delivers arrow keys and Return to whichever screen is in front.
///
/// SwiftUI routes `onMoveCommand` to the focused view and its ancestors only.
/// On macOS there is no focus engine to put focus anywhere, so key delivery
/// depended on something having happened to claim focus — and the moment a
/// screen changed, focus went nowhere and every arrow was silently dropped.
/// The log showed exactly that: arrows still arriving at the window, no handler
/// firing.
///
/// A local event monitor sees the keys regardless of focus. Screens claim the
/// front position when they appear and release it when they go, and the press
/// is republished so each screen handles it inside a normal SwiftUI update with
/// current state rather than through a closure captured at registration time.
@MainActor
final class MacKeyRouter: ObservableObject {
    static let shared = MacKeyRouter()

    struct Press: Equatable {
        let key: MacKey
        /// Distinguishes repeats of the same key, which are otherwise equal.
        let sequence: Int
    }

    @Published private(set) var latest: Press?

    private var stack: [UUID] = []
    private var sequence = 0
    private var monitor: Any?

    private init() {}

    /// Take the front position. Returns the token to release later.
    func claim() -> UUID {
        installMonitorIfNeeded()
        let token = UUID()
        stack.append(token)
        return token
    }

    func release(_ token: UUID?) {
        guard let token else { return }
        stack.removeAll { $0 == token }
    }

    func isFront(_ token: UUID?) -> Bool {
        guard let token else { return false }
        return stack.last == token
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let key = Self.key(for: event) else { return event }
        // Never take arrows away from a text field — Search is typed into, and
        // its caret needs Left/Right far more than the grid does.
        if let responder = event.window?.firstResponder, responder is NSText {
            return event
        }
        guard !stack.isEmpty else { return event }
        sequence &+= 1
        latest = Press(key: key, sequence: sequence)
        return nil
    }

    private static func key(for event: NSEvent) -> MacKey? {
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 36, 76: return .activate
        default: return nil
        }
    }
}

extension MoveCommandDirection {
    /// The existing handlers are written against `MoveCommandDirection`; the
    /// router speaks in raw keys, so translate at the boundary.
    init?(_ key: MacKey) {
        switch key {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        case .activate: return nil
        }
    }
}
#endif

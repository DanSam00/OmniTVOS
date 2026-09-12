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
    static let availableTabs: [TVTab] = [.home, .search, .library, .calendar, .settings]

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
        (.library, "3"),
        (.calendar, "4"),
        (.settings, "5"),
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
        // A focused text field owns typing, the text cursor and Return. It has
        // no use for Up/Down though, and swallowing those left the caret stuck
        // in the search field with no way down to the results.
        if let responder = event.window?.firstResponder, responder is NSText {
            switch key {
            case .left, .right, .activate: return event
            case .up, .down: break
            }
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

/// Which tab is on screen.
///
/// A `TabView` keeps every tab mounted, so `onAppear`/`onDisappear` do not mark
/// a screen as current — claiming the key router from them leaves every screen
/// holding a token and makes front-ness a matter of launch order.
@MainActor
final class MacTabState: ObservableObject {
    static let shared = MacTabState()
    @Published var current: TVTab = .home
    private init() {}
}

/// One horizontal band of a screen: a row of controls, or a grid.
struct MacFocusBand {
    let id: String
    let items: [String]
    /// Items per row. A row of pills is one row `items.count` wide; a grid is
    /// its column count; a single control is 1.
    var columns: Int

    init(id: String, items: [String], columns: Int? = nil) {
        self.id = id
        self.items = items
        self.columns = max(columns ?? items.count, 1)
    }

    var rowCount: Int { items.isEmpty ? 0 : (items.count + columns - 1) / columns }
}

/// Keyboard focus for a whole screen, as a vertical stack of bands.
///
/// macOS has no focus engine, so every screen has to simulate one. Home and
/// Details each grew their own; this is the shared version, because the shape
/// keeps repeating — a search field above filter pills above a grid, a column
/// of catalog rows, a list beside a pane.
///
/// The screen owns the highlight as a plain value: a `@FocusState` is not a
/// render dependency, and SwiftUI drops writes to one when nothing holds focus,
/// which on macOS is most of the time.
@MainActor
final class MacScreenFocus: ObservableObject {
    /// Band and item the caret sits on.
    @Published private(set) var bandID: String?
    @Published private(set) var itemID: String?

    private var bands: [MacFocusBand] = []
    private var token: UUID?
    private let name: String

    init(_ name: String) {
        self.name = name
    }

    /// Republish whenever the screen's contents change. The caret stays where
    /// it is when that item still exists, so a filter or a new result set does
    /// not throw it back to the top.
    func update(_ bands: [MacFocusBand]) {
        self.bands = bands.filter { !$0.items.isEmpty }
        guard let itemID, let bandID,
              self.bands.first(where: { $0.id == bandID })?.items.contains(itemID) == true
        else {
            seed()
            return
        }
    }

    /// Put the caret on the first item of the first band that has one.
    func seed() {
        guard let first = bands.first else {
            bandID = nil
            itemID = nil
            return
        }
        bandID = first.id
        itemID = first.items.first
    }

    func focus(band: String, item: String) {
        guard bands.first(where: { $0.id == band })?.items.contains(item) == true else { return }
        bandID = band
        itemID = item
    }

    func isFocused(_ band: String, _ item: String) -> Bool {
        bandID == band && itemID == item
    }

    /// Hold the front of the key router only while this screen is current. A
    /// `TabView` keeps every tab mounted, so appear/disappear cannot decide it.
    func syncClaim(isCurrent: Bool) {
        if isCurrent {
            guard token == nil else { return }
            token = MacKeyRouter.shared.claim()
            MacDiagnostics.log("screen.claim \(name) bands=\(bands.map { "\($0.id):\($0.items.count)" })")
        } else {
            guard token != nil else { return }
            MacKeyRouter.shared.release(token)
            token = nil
            MacDiagnostics.log("screen.release \(name)")
        }
    }

    func release() {
        MacKeyRouter.shared.release(token)
        token = nil
    }

    var isFront: Bool { MacKeyRouter.shared.isFront(token) }

    /// Handle one press. `activate` runs for Return on the focused position.
    /// - Returns: true when the press was consumed.
    @discardableResult
    func handle(_ key: MacKey, activate: (String, String) -> Void) -> Bool {
        guard isFront else { return false }
        // The menu floats above every screen, so it gets first refusal.
        if let direction = MoveCommandDirection(key) {
            if MacMenuState.shared.handleMove(direction) { return true }
        } else if MacMenuState.shared.handleReturn() {
            return true
        }

        guard !bands.isEmpty else {
            if key == .left { MacMenuState.shared.open() }
            return true
        }

        guard let bandID, let itemID,
              let bandIndex = bands.firstIndex(where: { $0.id == bandID }),
              let index = bands[bandIndex].items.firstIndex(of: itemID)
        else {
            seed()
            return true
        }

        let band = bands[bandIndex]
        let column = index % band.columns
        let row = index / band.columns

        switch key {
        case .activate:
            activate(bandID, itemID)
        case .left:
            // Column 0 is the screen's left edge: step off it into the menu.
            if column == 0 {
                MacMenuState.shared.open()
            } else {
                self.itemID = band.items[index - 1]
            }
        case .right:
            if column < band.columns - 1, index + 1 < band.items.count {
                self.itemID = band.items[index + 1]
            }
        case .up:
            if row > 0 {
                self.itemID = band.items[index - band.columns]
            } else {
                moveToBand(before: bandIndex, column: column)
            }
        case .down:
            if row < band.rowCount - 1 {
                self.itemID = band.items[min(index + band.columns, band.items.count - 1)]
            } else {
                moveToBand(after: bandIndex, column: column)
            }
        }

        MacDiagnostics.log(
            "screen.move \(name) key=\(key) band=\(self.bandID ?? "none")"
                + " index=\(currentIndex ?? -1) of=\(currentBand?.items.count ?? 0)"
                + " columns=\(currentBand?.columns ?? 0)"
        )
        return true
    }

    private var currentBand: MacFocusBand? {
        bands.first { $0.id == bandID }
    }

    private var currentIndex: Int? {
        guard let itemID else { return nil }
        return currentBand?.items.firstIndex(of: itemID)
    }

    /// Entering a neighbouring band keeps the column where it can, so moving up
    /// and down a screen does not drift to the left edge.
    private func moveToBand(before index: Int, column: Int) {
        guard index > 0 else { return }
        let target = bands[index - 1]
        bandID = target.id
        // Land on the *last* row of the band above, under the same column.
        let lastRowStart = (target.rowCount - 1) * target.columns
        itemID = target.items[min(lastRowStart + column, target.items.count - 1)]
    }

    private func moveToBand(after index: Int, column: Int) {
        guard index + 1 < bands.count else { return }
        let target = bands[index + 1]
        bandID = target.id
        itemID = target.items[min(column, target.items.count - 1)]
    }
}
#endif

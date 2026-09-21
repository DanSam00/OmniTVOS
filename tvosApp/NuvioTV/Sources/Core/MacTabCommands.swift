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

    /// What the menu column offers, in order.
    ///
    /// Profile leads, as it does in the tvOS tab bar. It is not a tab here —
    /// the macOS `TabView` has no page behind it — so choosing it switches
    /// profiles rather than selecting anything; see the request handler in
    /// `ContentView`.
    static let availableTabs: [TVTab] = [.profile, .home, .search, .library, .calendar, .settings]

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
    /// Escape. tvOS delivers this as the Menu button through
    /// `onExitCommand`, which on macOS needs SwiftUI focus that a screen
    /// driving its own caret never has — so it is routed like every other key.
    case back
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
    private var barriers: [(token: UUID, depth: Int)] = []
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
        guard let token, isRoutable else { return false }
        return stack.last == token
    }

    /// Claims made before this point stop receiving keys until the barrier is
    /// lifted.
    ///
    /// A full-screen overlay with its own key monitor — the player — covers
    /// the tab screens, but those screens go on holding the router: the tab
    /// view keeps every tab mounted, so their claim tracks which tab is
    /// current and knows nothing about what is on top of it. Since the router
    /// consumes every key it routes, the player's monitor never saw one, and
    /// the log showed calendar holding the keyboard across four playback
    /// sessions in a row. The barrier masks what is underneath without
    /// disturbing it, and anything claimed above it — the player's own
    /// settings panel — still routes normally.
    func pushBarrier() -> UUID {
        installMonitorIfNeeded()
        let token = UUID()
        barriers.append((token, stack.count))
        MacDiagnostics.log("keys.barrier up depth=\(stack.count)")
        return token
    }

    func popBarrier(_ token: UUID?) {
        guard let token, barriers.contains(where: { $0.token == token }) else { return }
        barriers.removeAll { $0.token == token }
        MacDiagnostics.log("keys.barrier down")
    }

    /// False while every live claim sits below a barrier.
    private var isRoutable: Bool {
        stack.count > (barriers.last?.depth ?? 0)
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
            case .left, .right, .activate, .back: return event
            case .up, .down: break
            }
        }
        guard !stack.isEmpty, isRoutable else { return event }
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
        case 53: return .back
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
        case .activate, .back: return nil
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
    /// Whether leaving this band keeps the caret in the same column.
    ///
    /// Off by default, because a screen's bands are usually independent lists —
    /// row 2 of Home has nothing to do with row 1, so the caret returns to
    /// where that row was left. A band that is one row of a matrix is the
    /// exception: the calendar's weeks share a meaning per column (the
    /// weekday), and stepping from Wednesday to "wherever I was last in that
    /// week" is not how a calendar reads.
    var carriesColumn: Bool

    init(id: String, items: [String], columns: Int? = nil, carriesColumn: Bool = false) {
        self.id = id
        self.items = items
        self.columns = max(columns ?? items.count, 1)
        self.carriesColumn = carriesColumn
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
    /// Where each band was last left, so returning to one resumes rather than
    /// restarting. Kept for the life of the screen — "per session", not
    /// persisted.
    private var lastItemByBand: [String: String] = [:]
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
        lastItemByBand[band] = item
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
        // Escape is the screen's own business — it means "go back", and the
        // screen handles it before calling here. Falling through would reach
        // the Return branch below, since it is not a direction.
        guard key != .back else { return false }
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
        case .back:
            // Guarded out above; the screen owns "go back".
            return false
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
                moveToBand(before: bandIndex, from: band, column: column)
            }
        case .down:
            if row < band.rowCount - 1 {
                self.itemID = band.items[min(index + band.columns, band.items.count - 1)]
            } else {
                moveToBand(after: bandIndex, from: band, column: column)
            }
        }

        if let bandID = self.bandID, let itemID = self.itemID {
            lastItemByBand[bandID] = itemID
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

    /// Entering a neighbouring band puts the caret back where that band was
    /// left, or on its first item if it has not been visited yet.
    ///
    /// Carrying the column across instead — the obvious reading of "don't drift
    /// to the left edge" — meant that stepping down from the twelfth card of one
    /// row landed on the twelfth card of the next, with the first eleven behind
    /// the caret and the row already scrolled along. Rows are independent lists,
    /// not columns of a table, so a shared column index means nothing between
    /// them.
    /// Two bands that both carry the column are rows of one matrix, so the
    /// caret keeps its column between them (see `MacFocusBand.carriesColumn`).
    private func enter(band target: MacFocusBand, from origin: MacFocusBand?, column: Int?) {
        bandID = target.id
        if target.carriesColumn, origin?.carriesColumn == true,
           let column, target.items.indices.contains(column) {
            itemID = target.items[column]
            return
        }
        if let remembered = lastItemByBand[target.id],
           target.items.contains(remembered) {
            itemID = remembered
        } else {
            itemID = target.items.first
        }
    }

    private func moveToBand(before index: Int, from origin: MacFocusBand? = nil, column: Int? = nil) {
        guard index > 0 else { return }
        enter(band: bands[index - 1], from: origin, column: column)
    }

    private func moveToBand(after index: Int, from origin: MacFocusBand? = nil, column: Int? = nil) {
        guard index + 1 < bands.count else { return }
        enter(band: bands[index + 1], from: origin, column: column)
    }
}

/// What an embedded section contributes to its host screen's keyboard model.
///
/// A section like Discover is never a screen in its own right, so it has no
/// business claiming the key router — but the host cannot describe the
/// section's contents either, because they live in the section's own view
/// model. So the section hands up its bands and what Return means to each of
/// them, and the host splices them into its own stack.
struct MacFocusContribution {
    var bands: [MacFocusBand] = []
    var activate: (String, String) -> Void = { _, _ in }
}

/// Settings detail-pane rows, as the macOS keyboard sees them.
///
/// The pane renders eight category views built from a dozen row types, so a
/// hand-written list of its rows would be a second description of the UI that
/// drifts the moment a row is added. Each row publishes itself through a
/// preference instead — SwiftUI collects those in view-tree order, so the band
/// is always exactly what is on screen, in the order it appears.
struct MacSettingsRowsKey: PreferenceKey {
    static var defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value.append(contentsOf: nextValue())
    }
}

@MainActor
final class MacSettingsRowFocus: ObservableObject {
    static let shared = MacSettingsRowFocus()

    /// Row the caret is on, or nil while it is in the category sidebar.
    @Published var focusedRowID: String?
    /// Bumped to run the focused row's own action. Rows compare
    /// `activatingRowID` rather than the caret, so a row that moves the caret
    /// as a side effect of acting still fires exactly once.
    @Published private(set) var activationTick = 0
    private(set) var activatingRowID: String?

    func activate(_ id: String) {
        activatingRowID = id
        activationTick += 1
    }
}

private struct MacSettingsRowIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Id of the settings row being rendered. `SettingsRowShell` reads it, so
    /// every row type draws the macOS highlight without knowing it exists.
    var macSettingsRowID: String? {
        get { self[MacSettingsRowIDKey.self] }
        set { self[MacSettingsRowIDKey.self] = newValue }
    }
}

private struct MacSettingsRowModifier: ViewModifier {
    let id: String
    let action: () -> Void
    @ObservedObject private var focus = MacSettingsRowFocus.shared

    init(id: String, action: @escaping () -> Void) {
        self.id = id
        self.action = action
    }

    func body(content: Content) -> some View {
        content
            .environment(\.macSettingsRowID, id)
            .preference(key: MacSettingsRowsKey.self, value: [id])
            // The rows sit in a ScrollView the caret has to drag along with it.
            .id(id)
            .onChange(of: focus.activationTick) { _, _ in
                guard focus.activatingRowID == id else { return }
                action()
            }
    }
}

extension View {
    /// Registers this settings row with the macOS keyboard model: its place in
    /// the pane, its highlight, and what Return does to it.
    func macSettingsRow(_ id: String, action: @escaping () -> Void) -> some View {
        modifier(MacSettingsRowModifier(id: id, action: action))
    }
}

/// The one dropdown presenter for the whole app.
///
/// `confirmationDialog` becomes an `NSAlert` on macOS, which shows at most
/// three buttons and silently drops the rest — it hid every stream provider
/// past the third, half the resolution filters, most of Library's sort
/// options, and reduced Calendar's sport picker to all-or-nothing.
///
/// The stream picker already worked around this with `MacPickerOptionsPanel`,
/// but owned the presentation state itself. Four more hosts would have meant
/// four more copies of it, so the state lives here instead and a control's
/// only job is to hand over its options. Like the menu, this claims the key
/// router while it is up, which is what stops the screen underneath from also
/// acting on the arrow keys.
@MainActor
final class MacOptionPanel: ObservableObject {
    static let shared = MacOptionPanel()

    @Published private(set) var title = ""
    @Published private(set) var options: [FilterOption] = []
    @Published private(set) var highlighted = 0
    private var token: UUID?

    var isPresented: Bool { !options.isEmpty }

    func present(title: String, options: [FilterOption]) {
        guard !options.isEmpty else { return }
        self.title = title
        self.options = options
        // Open on what is already chosen, so a long list does not start at the
        // top and make the current value look unset.
        highlighted = options.firstIndex(where: \.isSelected) ?? 0
        if token == nil { token = MacKeyRouter.shared.claim() }
        MacDiagnostics.log("panel.present \(title) options=\(options.count)")
    }

    func dismiss() {
        guard isPresented || token != nil else { return }
        options = []
        MacKeyRouter.shared.release(token)
        token = nil
        MacDiagnostics.log("panel.dismiss")
    }

    /// - Returns: true when the press was consumed.
    @discardableResult
    func handle(_ key: MacKey) -> Bool {
        guard isPresented, MacKeyRouter.shared.isFront(token) else { return false }
        switch key {
        case .up:
            highlighted = max(0, highlighted - 1)
        case .down:
            highlighted = min(options.count - 1, highlighted + 1)
        case .activate:
            let choice = options[min(highlighted, options.count - 1)]
            // Dismiss first: applying can rebuild the screen underneath, and
            // the router token has to be back before it re-claims.
            dismiss()
            choice.apply()
        case .back:
            // Escape on a dropdown closes it without choosing.
            dismiss()
        case .left, .right:
            // A dropdown is one column. Sideways means "leave it alone".
            dismiss()
        }
        return true
    }
}

/// Hosts `MacOptionPanel` inside the canvas, so it is scaled and positioned
/// with the rest of the app rather than against the window.
struct MacOptionPanelHost: View {
    @ObservedObject private var panel = MacOptionPanel.shared
    @ObservedObject private var keyRouter = MacKeyRouter.shared

    var body: some View {
        ZStack {
            if panel.isPresented {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { panel.dismiss() }

                MacPickerOptionsPanel(
                    list: MacPickerOptionList(
                        title: panel.title,
                        options: panel.options.map {
                            MacPickerOption(label: $0.label, isSelected: $0.isSelected, apply: $0.apply)
                        }
                    ),
                    highlighted: panel.highlighted,
                    onSelect: { index in
                        guard panel.options.indices.contains(index) else { return }
                        let choice = panel.options[index]
                        panel.dismiss()
                        choice.apply()
                    },
                    onDismiss: { panel.dismiss() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: panel.isPresented)
        .onChange(of: keyRouter.latest) { _, press in
            guard let press else { return }
            panel.handle(press.key)
        }
    }
}
#endif

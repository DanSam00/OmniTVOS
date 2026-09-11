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
    static let availableTabs: [TVTab] = [.home, .settings]

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
        (.settings, "2"),
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
#endif

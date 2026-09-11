#if os(macOS)
import SwiftUI

/// Shared state for the macOS menu column.
///
/// The menu lives beside the tab content while focus is driven from Home, so
/// the two need a common place to agree on who currently holds focus.
@MainActor
final class MacMenuState: ObservableObject {
    static let shared = MacMenuState()

    /// True while the menu column owns keyboard focus rather than a card.
    @Published var isFocused = false
    /// The row the caret sits on, which is not yet the selected tab.
    @Published var highlighted: TVTab = .home

    private init() {}

    /// Tabs the macOS build actually has; mirrors the fences in
    /// `TVMainTabView.tabs`.
    var tabs: [TVTab] { MacTabCommandBus.availableTabs }

    func moveHighlight(by offset: Int, from current: TVTab) {
        guard let index = tabs.firstIndex(of: current) else { return }
        let next = index + offset
        guard tabs.indices.contains(next) else { return }
        highlighted = tabs[next]
    }
}

/// The visible menu: a column of tabs that keyboard focus can reach.
///
/// tvOS reveals its tab bar by moving focus up off the first row, which needs
/// the focus engine macOS does not have — so on the Mac the menu was
/// unreachable and the ⌘-number shortcuts were the only way to change tabs.
/// This puts it on screen and into the focus model: Left from the first card
/// opens it, Right returns, Up/Down move along it, Return switches tab.
struct MacHomeMenu: View {
    @Binding var selectedTab: TVTab
    @ObservedObject private var state = MacMenuState.shared
    @Namespace private var glassNamespace

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
    }

    var body: some View {
        column
            .frame(width: state.isFocused ? 260 : 96, alignment: .leading)
            .background { panel }
            .animation(.easeOut(duration: 0.18), value: state.isFocused)
    }

    @ViewBuilder
    private var column: some View {
        let stack = VStack(alignment: .leading, spacing: 8) {
            ForEach(state.tabs) { tab in
                row(for: tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 12)

        // A container lets the caret's glass blend with its neighbours as it
        // travels the column, instead of each row refracting in isolation.
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 14) { stack }
        } else {
            stack
        }
    }

    /// The column's own surface. Collapsed the menu is a bare icon strip over
    /// the backdrop; opening it floats the glass panel.
    @ViewBuilder
    private var panel: some View {
        if state.isFocused {
            if #available(macOS 26.0, *) {
                panelShape
                    .fill(Color.black.opacity(0.18))
                    .glassEffect(.regular, in: panelShape)
            } else {
                panelShape.fill(.ultraThinMaterial)
            }
        }
    }

    @ViewBuilder
    private func row(for tab: TVTab) -> some View {
        let isCaret = state.isFocused && state.highlighted == tab
        let isCurrent = selectedTab == tab

        HStack(spacing: 14) {
            Image(systemName: tab.symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 34)
            if state.isFocused {
                Text(tab.title)
                    .font(.system(size: 20, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
            }
        }
        .foregroundColor(isCaret || isCurrent ? .white : .white.opacity(0.55))
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MacMenuRowGlass(isCaret: isCaret, namespace: glassNamespace))
        .contentShape(Rectangle())
        .onTapGesture { selectedTab = tab }
    }
}

/// The caret's highlight. Split out of `MacHomeMenu.row` so the availability
/// branch does not have to be re-typed at each use, and so the type checker
/// sees one shape rather than a nested conditional.
private struct MacMenuRowGlass: ViewModifier {
    let isCaret: Bool
    let namespace: Namespace.ID

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isCaret {
            // Only the caret is glass; giving every row a surface would turn
            // the column into a stack of plates.
            content
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .glassEffectID("caret", in: namespace)
        } else {
            content.background(shape.fill(Color.white.opacity(0.22)))
        }
    }
}
#endif

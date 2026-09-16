#if os(macOS)
import SwiftUI

/// Shared state for the macOS menu column.
///
/// The menu floats above every screen while focus is driven separately by Home
/// and by Details, so the three need a common place to agree on who currently
/// holds focus.
@MainActor
final class MacMenuState: ObservableObject {
    static let shared = MacMenuState()

    /// True while the menu column owns keyboard focus rather than the screen.
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

    /// Open the menu because focus ran off the left edge of a screen. The
    /// highlight is left where it was, so the menu remembers its place.
    func open() {
        guard !isFocused else { return }
        isFocused = true
        MacDiagnostics.log("menu.open")
    }

    /// Every screen offers the menu the arrow first, so one implementation
    /// serves Home, Details and anything added later.
    /// - Returns: true when the menu consumed the key.
    func handleMove(_ direction: MoveCommandDirection) -> Bool {
        guard isFocused else { return false }
        switch direction {
        case .up:
            moveHighlight(by: -1, from: highlighted)
        case .down:
            moveHighlight(by: 1, from: highlighted)
        case .right:
            // Back to the content, on whatever it left focused.
            isFocused = false
            MacDiagnostics.log("menu.close")
        default:
            break
        }
        return true
    }

    /// - Returns: true when the menu consumed Return.
    func handleReturn() -> Bool {
        guard isFocused else { return false }
        MacDiagnostics.log("menu.select " + highlighted.rawValue)
        MacTabCommandBus.shared.request(highlighted)
        isFocused = false
        return true
    }
}

enum MacMenuMetrics {
    /// The collapsed menu is drawn in the window's top-left corner, outside
    /// any screen's own layout, so screens have to be told how much room it
    /// takes. These mirror the paddings in `MacHomeMenu`: 28pt in from each
    /// edge, then the column's 12 and the row's 14/12 around a 30×26 glyph.
    static let edgeLeading: CGFloat = 28
    static let edgeTop: CGFloat = 28
    static let collapsedWidth: CGFloat = 82
    static let collapsedHeight: CGFloat = 74

    /// Right edge of the collapsed icon, measured from the window.
    static let collapsedTrailing: CGFloat = edgeLeading + collapsedWidth
    /// Vertical centre of the collapsed icon, for a header that lines its
    /// title up with the glyph rather than clearing it.
    static let collapsedCenterY: CGFloat = edgeTop + collapsedHeight / 2

    /// Where a screen's title starts, measured from the window's leading edge
    /// rather than from the screen's own container: far enough right of the
    /// icon that the two read as a pair instead of a collision.
    static let headerLeading: CGFloat = collapsedTrailing + 22

    /// Space a screen must leave clear at its top-left so the collapsed menu
    /// icon is not drawn over. Home needs none — its tvOS inset is already
    /// wider — but the screens that start their header at the very edge do.
    ///
    /// Prefer `macMenuAlignedHeader(containerLeading:)`, which works out this
    /// gap from the inset the screen already carries. A single constant cannot:
    /// Library indents its page by 36 and Settings its sidebar by 58, so the
    /// same number lands the two titles in different places.
    static let headerInset: CGFloat = 96

    /// Clearance for a screen whose title cannot sit beside the icon and has
    /// to start below it instead.
    static let headerTopInset: CGFloat = edgeTop + collapsedHeight + 14
}

extension View {
    /// Lines a screen's title up with the collapsed menu icon: centred on the
    /// glyph's own centre line, and indented clear of it.
    ///
    /// The menu is drawn in the window's corner, outside every screen's own
    /// layout, so each screen would otherwise guess its own inset — and they
    /// drifted apart, some overlapping the icon and others sitting well below
    /// it. `containerLeading` is the inset the screen already applies, so the
    /// title lands at the same place on every screen whatever that is.
    ///
    /// The caller still has to start its content at `MacMenuMetrics.edgeTop`
    /// for the vertical half to line up.
    func macMenuAlignedHeader(containerLeading: CGFloat) -> some View {
        frame(height: MacMenuMetrics.collapsedHeight, alignment: .leading)
            .padding(.leading, max(0, MacMenuMetrics.headerLeading - containerLeading))
    }
}

/// The visible menu: a column of tabs that keyboard focus can reach.
///
/// tvOS reveals its tab bar by moving focus up off the first row, which needs
/// the focus engine macOS does not have — so on the Mac the menu was
/// unreachable and the ⌘-number shortcuts were the only way to change tabs.
/// This puts it on screen and into the focus model: Left off the edge of a
/// screen opens it, Right returns, Up/Down move along it, Return switches tab.
struct MacHomeMenu: View {
    @Binding var selectedTab: TVTab
    /// False while a details or browse screen covers the tabs, where no menu
    /// item is current and the collapsed menu is a plain hamburger instead.
    var isShowingTabPage: Bool = true
    @ObservedObject private var state = MacMenuState.shared
    @Namespace private var glassNamespace
    @ObservedObject private var keyRouter = MacKeyRouter.shared
    /// Held only while the menu is open: it floats above every screen, so
    /// while it has focus it is the front key handler regardless of which
    /// screen is underneath.
    @State private var keyToken: UUID?
    /// Widest row, so every highlight is the same width even though the titles
    /// are not. Measured from the row content, before the width is applied
    /// back, so this settles in one pass instead of feeding back on itself.
    @State private var rowWidth: CGFloat = 0

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
    }

    var body: some View {
        column
            // Sized by its own icons and labels rather than a fixed column, so
            // the collapsed menu is just one glyph wide and the open menu just
            // wide enough for the longest title.
            .fixedSize()
            .background { panel }
            .padding(.leading, 28)
            .padding(.top, 28)
            .animation(.easeOut(duration: 0.18), value: state.isFocused)
            .onChange(of: state.isFocused) { _, focused in
                // Labels appear and disappear with the open state, so the
                // measured width has to be taken again.
                rowWidth = 0
                if focused {
                    keyRouter.release(keyToken)
                    keyToken = keyRouter.claim()
                } else {
                    keyRouter.release(keyToken)
                    keyToken = nil
                }
            }
            .onChange(of: keyRouter.latest) { _, press in
                guard let press, keyRouter.isFront(keyToken) else { return }
                if let direction = MoveCommandDirection(press.key) {
                    _ = state.handleMove(direction)
                } else {
                    _ = state.handleReturn()
                }
            }
            .onDisappear {
                keyRouter.release(keyToken)
                keyToken = nil
            }
    }

    @ViewBuilder
    private var column: some View {
        let stack = VStack(alignment: .leading, spacing: 8) {
            if state.isFocused {
                ForEach(state.tabs) { tab in
                    row(for: tab)
                }
            } else {
                // Closed, the menu says only where you are — the current tab's
                // icon, or a hamburger on a page that is not a tab at all.
                collapsedRow
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .onPreferenceChange(MacMenuRowWidthKey.self) { width in
            if width > rowWidth { rowWidth = width }
        }

        // A container lets the caret's glass blend with its neighbours as it
        // travels the column, instead of each row refracting in isolation.
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 14) { stack }
        } else {
            stack
        }
    }

    @ViewBuilder
    private var collapsedRow: some View {
        let symbol = isShowingTabPage ? selectedTab.symbol : "line.3.horizontal"
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .medium))
            .frame(width: 30)
            .foregroundColor(.white.opacity(0.82))
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .onTapGesture { state.open() }
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
                .frame(width: 30)
            if state.isFocused {
                Text(tab.title)
                    .font(.system(size: 20, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundColor(isCaret || isCurrent ? .white : .white.opacity(0.55))
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MacMenuRowWidthKey.self, value: proxy.size.width)
            }
        }
        .frame(width: rowWidth > 0 ? rowWidth : nil, alignment: .leading)
        .modifier(MacMenuRowGlass(isCaret: isCaret, namespace: glassNamespace))
        .contentShape(Rectangle())
        .onTapGesture { selectedTab = tab }
    }
}

private struct MacMenuRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

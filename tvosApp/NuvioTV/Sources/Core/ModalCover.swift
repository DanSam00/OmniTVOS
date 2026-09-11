import SwiftUI

/// `fullScreenCover` is unavailable on macOS, where a window-filling modal is
/// spelled as a sheet. Both presentations are modal and dismiss the same way,
/// so the shared UI names the intent and each platform supplies its own.
extension View {
    @ViewBuilder
    func modalCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(macOS)
        sheet(item: item, onDismiss: onDismiss, content: content)
        #else
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder
    func modalCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }
}

extension View {
    /// Opts a view into keyboard focus.
    ///
    /// On tvOS every Button is focusable by definition — the focus engine is the
    /// only way to reach anything. macOS is the opposite: a control takes
    /// keyboard focus only under Full Keyboard Access, which is off by default,
    /// so `@FocusState`/`.focused()` silently do nothing and the whole UI
    /// becomes unreachable from the keyboard. Declaring focusability explicitly
    /// restores the tvOS behaviour without depending on a system setting.
    @ViewBuilder
    func nuvioFocusable() -> some View {
        #if os(macOS)
        focusable()
        #else
        self
        #endif
    }
}

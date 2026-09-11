import SwiftUI

/// `fullScreenCover` is unavailable on macOS, so the shared UI names the intent
/// and each platform supplies its own presentation.
///
/// macOS cannot use a sheet here. A sheet is attached to the `NSWindow`, which
/// puts it *outside* `MacTVCanvas` — so this app's fixed tvOS layouts, written
/// for 1920×1080 points, are presented at neither the canvas's scale nor its
/// size. The stream picker came out as a small floating panel showing nothing
/// but one add-on's logo. An in-place overlay stays inside the canvas and fills
/// it, which is what `fullScreenCover` does on tvOS.
///
/// Both call sites drive dismissal through their own closure and binding rather
/// than `@Environment(\.dismiss)`, so nothing depends on this being a real
/// presentation.
extension View {
    @ViewBuilder
    func modalCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(macOS)
        modifier(MacModalCover(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        ), onDismiss: onDismiss) {
            if let value = item.wrappedValue {
                content(value)
            }
        })
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
        modifier(MacModalCover(isPresented: isPresented, onDismiss: onDismiss, content: content))
        #else
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }
}

#if os(macOS)
private struct MacModalCover<Cover: View>: ViewModifier {
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?
    @ViewBuilder var content: () -> Cover

    func body(content base: Content) -> some View {
        ZStack {
            base

            if isPresented {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { onDismiss?() }
        }
    }
}
#endif

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

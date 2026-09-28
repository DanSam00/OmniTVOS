// iOS-only vocabulary for the shared tvOS view code.
//
// The tvOS screens are written against the focus engine and the Siri Remote:
// `focusSection()`, `onMoveCommand`, `onExitCommand`, `onPlayPauseCommand` and
// the `.card` button style. SwiftUI marks all of them unavailable on iOS, so
// these same-named module-level declarations win overload resolution there
// and compile to no-ops. A phone has no remote to route: touch screens get
// their own navigation, and these shims only keep the shared code building.
#if os(iOS)
import SwiftUI

/// Shadows SwiftUI's tvOS/macOS-only `MoveCommandDirection`.
enum MoveCommandDirection {
    case up, down, left, right
}

extension View {
    func focusSection() -> some View { self }

    func onExitCommand(perform action: (() -> Void)?) -> some View { self }

    func onMoveCommand(perform action: ((MoveCommandDirection) -> Void)?) -> some View { self }

    func onPlayPauseCommand(perform action: (() -> Void)?) -> some View { self }
}

/// Stand-in for tvOS's `CardButtonStyle`: a light press-down instead of the
/// focus lift, which has nothing to respond to under a finger.
struct IOSCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == IOSCardButtonStyle {
    static var card: IOSCardButtonStyle { IOSCardButtonStyle() }
}
#endif

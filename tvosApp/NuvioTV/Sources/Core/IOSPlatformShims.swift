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

/// Fixed point sizes in the shared views are 10-foot sizes: 22pt row titles,
/// 38pt headers, read from across a room. This module-level overload shadows
/// SwiftUI's on iOS and maps them onto the phone's type ramp (22 -> 16,
/// 17 -> 13, 38 -> 26), so every shared screen shown on the phone (Settings,
/// player overlays) reads at phone size without touching its call sites.
/// The phone's own views use semantic styles (`.headline`, `.caption`) and are
/// unaffected unless they pass a literal size.
extension Font {
    static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        // Built through UIFont: calling `.system(size:)` here would recurse.
        let phoneSize = (size * 0.6 + 3).rounded()
        let base = UIFont.systemFont(ofSize: phoneSize, weight: Self.uiWeight(weight ?? .regular))
        guard let design, design != .default,
              let descriptor = base.fontDescriptor.withDesign(Self.uiDesign(design)) else {
            return Font(base)
        }
        return Font(UIFont(descriptor: descriptor, size: phoneSize))
    }

    private static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    private static func uiDesign(_ design: Font.Design) -> UIFontDescriptor.SystemDesign {
        switch design {
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .serif: return .serif
        default: return .default
        }
    }
}
#endif

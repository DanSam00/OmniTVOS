#if os(iOS)
import SwiftUI
import UIKit
import WidgetKit

extension WidgetTheme {
    /// Copies the active profile's theme colour for the widgets and redraws
    /// them when it changed. Called whenever Omni comes to the front or goes
    /// to the background, which covers a change in Settings or a profile switch.
    @MainActor
    static func publishFromSettings() {
        let theme = ProfileSettings.current.string(forKey: SettingsKey.theme) ?? SettingsAccent.white.rawValue
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        UIColor(SettingsAccent.color(for: theme)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        if store(red: Double(red), green: Double(green), blue: Double(blue)) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
#endif

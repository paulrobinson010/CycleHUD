import SwiftUI
import UIKit

/// Central place for colours and styling so the HUD stays consistent and
/// high-contrast for outdoor, at-a-glance reading. The neutral palette adapts to
/// light/dark; the radar threat ramp and accent stay vivid in both.
enum Theme {
    static let background = Color(light: Color(white: 0.97),
                                  dark: Color(red: 0.05, green: 0.06, blue: 0.08))
    static let panel = Color(light: Color(white: 0.91),
                             dark: Color(red: 0.11, green: 0.12, blue: 0.15))
    static let panelRaised = Color(light: Color(white: 0.85),
                                   dark: Color(red: 0.16, green: 0.17, blue: 0.21))

    static let textPrimary = Color(light: Color(white: 0.10), dark: .white)
    static let textSecondary = Color(light: Color(white: 0.42), dark: Color(white: 0.62))

    static let accent = Color(red: 0.0, green: 0.62, blue: 0.96)        // calm blue
    static let good = Color(red: 0.18, green: 0.80, blue: 0.44)         // "all clear" green

    // Radar threat severity ramp
    static let threatLow = Color(red: 1.0, green: 0.85, blue: 0.25)     // yellow
    static let threatMedium = Color(red: 1.0, green: 0.55, blue: 0.10)  // orange
    static let threatHigh = Color(red: 0.95, green: 0.20, blue: 0.22)   // red

    /// Large value font for the metric tiles / speed readout.
    static func valueFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    static let labelFont = Font.system(size: 13, weight: .semibold, design: .rounded)
}

extension Color {
    /// A colour that resolves differently in light vs dark, so the palette
    /// follows the chosen appearance automatically.
    init(light: Color, dark: Color) {
        self = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

import SwiftUI

/// Central place for colours and styling so the HUD stays consistent and
/// high-contrast for outdoor, at-a-glance reading.
enum Theme {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let panelRaised = Color(red: 0.16, green: 0.17, blue: 0.21)

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)

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

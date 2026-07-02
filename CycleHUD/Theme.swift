import SwiftUI
import UIKit

/// The rider's appearance choice: a clean light theme, an all-black dark HUD,
/// or the neon Cyberpunk theme matching the CycleHUD artwork/website.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case light, dark, cyberpunk

    var id: String { rawValue }

    /// The system colour scheme underneath (drives sheets, forms, status bar).
    var colorScheme: ColorScheme { self == .light ? .light : .dark }

    var label: LocalizedStringKey {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .cyberpunk: return "Cyberpunk"
        }
    }
}

/// Central place for colours and styling so the HUD stays consistent and
/// high-contrast for outdoor, at-a-glance reading. Light/dark share one neutral
/// palette that adapts via traits; Cyberpunk swaps in the website's neon
/// palette (docs/style.css) on a deep purple-black. Threat colours stay
/// semantically yellow/orange/red in every theme — it's a safety display.
enum Theme {
    /// The active appearance, kept in sync by AppSettings. Views re-render on
    /// the settings change (the ride screen re-identifies its layout), so the
    /// computed colours below take effect immediately.
    static var appearance: AppearanceTheme = .light
    private static var cyber: Bool { appearance == .cyberpunk }

    // MARK: Light/dark adaptive palette (as before)

    private static let baseBackground = Color(light: Color(white: 0.97),
                                              dark: Color(red: 0.05, green: 0.06, blue: 0.08))
    private static let basePanel = Color(light: Color(white: 0.91),
                                         dark: Color(red: 0.11, green: 0.12, blue: 0.15))
    private static let basePanelRaised = Color(light: Color(white: 0.85),
                                               dark: Color(red: 0.16, green: 0.17, blue: 0.21))
    private static let baseTextPrimary = Color(light: Color(white: 0.10), dark: .white)
    private static let baseTextSecondary = Color(light: Color(white: 0.42), dark: Color(white: 0.62))

    // MARK: Cyberpunk palette (website: --bg / --panel / --text / --muted / --grad)

    private static let cyberBackground = Color(red: 0x0C / 255, green: 0x0A / 255, blue: 0x12 / 255)
    private static let cyberPanel = Color(red: 0x1A / 255, green: 0x14 / 255, blue: 0x26 / 255)
    private static let cyberPanelRaised = Color(red: 0x24 / 255, green: 0x1B / 255, blue: 0x33 / 255)
    private static let cyberTextPrimary = Color(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xFA / 255)
    private static let cyberTextSecondary = Color(red: 0xA7 / 255, green: 0x9F / 255, blue: 0xC0 / 255)
    private static let cyberAccent = Color(red: 0x25 / 255, green: 0xE3 / 255, blue: 0xEE / 255)  // neon cyan
    private static let cyberGood = Color(red: 0x3B / 255, green: 0xFF / 255, blue: 0xA8 / 255)    // neon mint
    private static let cyberThreatLow = Color(red: 1.0, green: 0.91, blue: 0.29)                  // neon yellow
    private static let cyberThreatMedium = Color(red: 1.0, green: 0.62, blue: 0.11)               // neon orange
    private static let cyberThreatHigh = Color(red: 1.0, green: 0.23, blue: 0.36)                 // neon red-pink

    // MARK: Active colours

    static var background: Color { cyber ? cyberBackground : baseBackground }
    static var panel: Color { cyber ? cyberPanel : basePanel }
    static var panelRaised: Color { cyber ? cyberPanelRaised : basePanelRaised }
    static var textPrimary: Color { cyber ? cyberTextPrimary : baseTextPrimary }
    static var textSecondary: Color { cyber ? cyberTextSecondary : baseTextSecondary }

    static var accent: Color {
        cyber ? cyberAccent : Color(red: 0.0, green: 0.62, blue: 0.96)          // calm blue
    }
    static var good: Color {
        cyber ? cyberGood : Color(red: 0.18, green: 0.80, blue: 0.44)           // "all clear" green
    }

    // Radar threat severity ramp
    static var threatLow: Color {
        cyber ? cyberThreatLow : Color(red: 1.0, green: 0.85, blue: 0.25)       // yellow
    }
    static var threatMedium: Color {
        cyber ? cyberThreatMedium : Color(red: 1.0, green: 0.55, blue: 0.10)    // orange
    }
    static var threatHigh: Color {
        cyber ? cyberThreatHigh : Color(red: 0.95, green: 0.20, blue: 0.22)     // red
    }

    /// Neon glow behind big values/buttons — clear (invisible) outside Cyberpunk,
    /// so views can apply it unconditionally.
    static var glow: Color { cyber ? cyberAccent.opacity(0.55) : .clear }

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

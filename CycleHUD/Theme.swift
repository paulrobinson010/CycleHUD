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

/// How the big metric numerals are drawn: the standard rounded system font, or
/// the retro 7-segment "digital clock" display font (bundled, original
/// outlines). Independent of the colour theme — LCD digits suit any of them.
enum DigitStyle: String, CaseIterable, Identifiable {
    case standard, digital

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .standard: return "Standard"
        case .digital: return "Digital"
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
    /// The numeral style, kept in sync by AppSettings (like `appearance`).
    static var digitStyle: DigitStyle = .standard
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

    // MARK: Cyberpunk chrome (all no-ops in Light/Dark, so views apply them
    // unconditionally and only Cyberpunk lights up)

    private static let cyberPink = Color(red: 0xFF / 255, green: 0x4F / 255, blue: 0xD8 / 255)
    private static let cyberPurple = Color(red: 0x9B / 255, green: 0x6B / 255, blue: 0xFF / 255)
    private static let cyberBgTop = Color(red: 0x04 / 255, green: 0x17 / 255, blue: 0x1E / 255)   // deep cyan-teal
    private static let cyberBgBottom = Color(red: 0x22 / 255, green: 0x07 / 255, blue: 0x20 / 255) // deep magenta

    /// Screen backdrop: the flat theme colour normally; a dark cyan→magenta
    /// wash in Cyberpunk. Use as `Rectangle().fill(Theme.backgroundStyle)`.
    static var backgroundStyle: AnyShapeStyle {
        cyber ? AnyShapeStyle(LinearGradient(
                    colors: [cyberBgTop, cyberBackground, cyberBgBottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
              : AnyShapeStyle(background)
    }

    /// Neon cyan→magenta rim for tiles and panels (clear outside Cyberpunk).
    static var tileStroke: AnyShapeStyle {
        cyber ? AnyShapeStyle(LinearGradient(
                    colors: [cyberAccent.opacity(0.55), cyberPink.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
              : AnyShapeStyle(Color.clear)
    }
    static var tileStrokeWidth: CGFloat { cyber ? 1 : 0 }

    /// Ink for the big metric numerals: a cyan→purple gradient in Cyberpunk,
    /// the plain text colour otherwise.
    static var valueStyle: AnyShapeStyle {
        cyber ? AnyShapeStyle(LinearGradient(colors: [cyberAccent, cyberPurple],
                                             startPoint: .top, endPoint: .bottom))
              : AnyShapeStyle(textPrimary)
    }

    /// Unit labels next to the numerals: neon pink in Cyberpunk.
    static var unitColor: Color { cyber ? cyberPink.opacity(0.85) : textSecondary }

    /// Status pills/capsules get a visible neon rim in Cyberpunk.
    static var pillStrokeOpacity: Double { cyber ? 0.5 : 0 }

    /// The radar lane's resting border (its threat flood overrides this).
    static var radarIdleStroke: Color {
        cyber ? cyberAccent.opacity(0.4) : Color.white.opacity(0.08)
    }

    /// Large value font for the metric tiles / speed readout. The digital style
    /// only carries digits and separators — any other text (Now, None, n/a)
    /// falls back to the system font automatically.
    static func valueFont(_ size: CGFloat) -> Font {
        switch digitStyle {
        case .standard: return .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        case .digital: return .custom("CycleHUD7Seg", size: size)
        }
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

extension View {
    /// Theme chrome for the settings-style screens (Forms/Lists): in Cyberpunk
    /// the system list background is hidden so the gradient backdrop shows
    /// through, and controls take the theme accent. Light/Dark keep the stock
    /// system look, so those themes are unchanged.
    func themedList() -> some View {
        self
            .scrollContentBackground(Theme.appearance == .cyberpunk ? .hidden : .automatic)
            .background(Rectangle().fill(Theme.backgroundStyle).ignoresSafeArea())
            .tint(Theme.accent)
    }
}

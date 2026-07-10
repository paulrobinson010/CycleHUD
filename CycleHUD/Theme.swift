import SwiftUI
import UIKit

/// The rider's appearance choice: a clean light theme, an all-black dark HUD,
/// the neon Cyberpunk theme matching the CycleHUD artwork/website — or its
/// antithesis, the pastel Unicorn theme.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case light, dark, cyberpunk, unicorn

    var id: String { rawValue }

    /// The system colour scheme underneath (drives sheets, forms, status bar).
    var colorScheme: ColorScheme {
        self == .light || self == .unicorn ? .light : .dark
    }

    var label: LocalizedStringKey {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .cyberpunk: return "Cyberpunk"
        case .unicorn: return "Unicorn"
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
    private static var unicorn: Bool { appearance == .unicorn }

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

    fileprivate static let cyberBackground = Color(red: 0x0C / 255, green: 0x0A / 255, blue: 0x12 / 255)
    private static let cyberPanel = Color(red: 0x1A / 255, green: 0x14 / 255, blue: 0x26 / 255)
    private static let cyberPanelRaised = Color(red: 0x24 / 255, green: 0x1B / 255, blue: 0x33 / 255)
    private static let cyberTextPrimary = Color(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xFA / 255)
    private static let cyberTextSecondary = Color(red: 0xA7 / 255, green: 0x9F / 255, blue: 0xC0 / 255)
    private static let cyberAccent = Color(red: 0x25 / 255, green: 0xE3 / 255, blue: 0xEE / 255)  // neon cyan
    private static let cyberGood = Color(red: 0x3B / 255, green: 0xFF / 255, blue: 0xA8 / 255)    // neon mint
    private static let cyberThreatLow = Color(red: 1.0, green: 0.91, blue: 0.29)                  // neon yellow
    private static let cyberThreatMedium = Color(red: 1.0, green: 0.62, blue: 0.11)               // neon orange
    private static let cyberThreatHigh = Color(red: 1.0, green: 0.23, blue: 0.36)                 // neon red-pink

    // MARK: Unicorn palette — Cyberpunk's antithesis: pastel lavender-pink
    // wash, candy accents, deep-plum ink so the numbers stay legible in
    // daylight, and threat colours that are sweeter but still unmistakably
    // yellow/orange/red (it's a safety display, glitter or not).

    fileprivate static let uniBackground = Color(red: 0xFB / 255, green: 0xF4 / 255, blue: 0xFB / 255)
    private static let uniPanel = Color(red: 0xF6 / 255, green: 0xE9 / 255, blue: 0xF6 / 255)
    private static let uniPanelRaised = Color(red: 0xEF / 255, green: 0xDD / 255, blue: 0xF1 / 255)
    private static let uniTextPrimary = Color(red: 0x46 / 255, green: 0x2A / 255, blue: 0x5C / 255)   // deep plum
    private static let uniTextSecondary = Color(red: 0x8E / 255, green: 0x71 / 255, blue: 0xA6 / 255) // mauve
    private static let uniAccent = Color(red: 0xB1 / 255, green: 0x5B / 255, blue: 0xDD / 255)        // orchid
    private static let uniGood = Color(red: 0x2E / 255, green: 0xC1 / 255, blue: 0x8B / 255)          // spring mint
    private static let uniThreatLow = Color(red: 1.0, green: 0.78, blue: 0.24)                        // sherbet yellow
    private static let uniThreatMedium = Color(red: 1.0, green: 0.55, blue: 0.28)                     // peach-tangerine
    private static let uniThreatHigh = Color(red: 0.94, green: 0.25, blue: 0.45)                      // raspberry

    // MARK: Active colours

    static var background: Color {
        cyber ? cyberBackground : unicorn ? uniBackground : baseBackground
    }
    static var panel: Color {
        cyber ? cyberPanel : unicorn ? uniPanel : basePanel
    }
    static var panelRaised: Color {
        cyber ? cyberPanelRaised : unicorn ? uniPanelRaised : basePanelRaised
    }
    static var textPrimary: Color {
        cyber ? cyberTextPrimary : unicorn ? uniTextPrimary : baseTextPrimary
    }
    static var textSecondary: Color {
        cyber ? cyberTextSecondary : unicorn ? uniTextSecondary : baseTextSecondary
    }

    static var accent: Color {
        cyber ? cyberAccent : unicorn ? uniAccent
              : Color(red: 0.0, green: 0.62, blue: 0.96)                        // calm blue
    }
    static var good: Color {
        cyber ? cyberGood : unicorn ? uniGood
              : Color(red: 0.18, green: 0.80, blue: 0.44)                       // "all clear" green
    }

    // Radar threat severity ramp
    static var threatLow: Color {
        cyber ? cyberThreatLow : unicorn ? uniThreatLow
              : Color(red: 1.0, green: 0.85, blue: 0.25)                        // yellow
    }
    static var threatMedium: Color {
        cyber ? cyberThreatMedium : unicorn ? uniThreatMedium
              : Color(red: 1.0, green: 0.55, blue: 0.10)                        // orange
    }
    static var threatHigh: Color {
        cyber ? cyberThreatHigh : unicorn ? uniThreatHigh
              : Color(red: 0.95, green: 0.20, blue: 0.22)                       // red
    }

    /// Glow behind big values/buttons — neon cyan in Cyberpunk, a soft pink
    /// halo in Unicorn, clear (invisible) elsewhere, so views apply it
    /// unconditionally.
    static var glow: Color {
        cyber ? cyberAccent.opacity(0.55) : unicorn ? uniPink.opacity(0.35) : .clear
    }

    // MARK: Cyberpunk chrome (all no-ops in Light/Dark, so views apply them
    // unconditionally and only Cyberpunk lights up)

    fileprivate static let cyberPink = Color(red: 0xFF / 255, green: 0x4F / 255, blue: 0xD8 / 255)
    fileprivate static let cyberPurple = Color(red: 0x9B / 255, green: 0x6B / 255, blue: 0xFF / 255)
    fileprivate static let cyberBgTop = Color(red: 0x06 / 255, green: 0x22 / 255, blue: 0x2B / 255)    // dark teal
    fileprivate static let cyberBgBottom = Color(red: 0x2E / 255, green: 0x09 / 255, blue: 0x30 / 255) // dark magenta
    fileprivate static let cyberCyan = cyberAccent

    // Unicorn chrome
    fileprivate static let uniPink = Color(red: 0xF5 / 255, green: 0x8F / 255, blue: 0xC6 / 255)       // candy pink
    fileprivate static let uniMint = Color(red: 0x9F / 255, green: 0xE8 / 255, blue: 0xCB / 255)       // pastel mint
    fileprivate static let uniLilac = Color(red: 0xCD / 255, green: 0xB4 / 255, blue: 0xF6 / 255)      // pastel lilac
    fileprivate static let uniSky = Color(red: 0xAD / 255, green: 0xD8 / 255, blue: 0xF7 / 255)        // pastel sky

    /// Screen backdrop: the flat theme colour normally; the neon wash + glow
    /// blobs in Cyberpunk. Kept for ShapeStyle call sites — full-screen
    /// backdrops should use `ThemeBackground` (it layers the glows).
    static var backgroundStyle: AnyShapeStyle {
        if cyber {
            return AnyShapeStyle(LinearGradient(
                colors: [cyberBgTop, cyberBackground, cyberBgBottom],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if unicorn {
            return AnyShapeStyle(LinearGradient(
                colors: [uniPink.opacity(0.45), uniBackground, uniMint.opacity(0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(background)
    }

    /// Fill for the primary call-to-action buttons (Start / Start Riding): the
    /// website's cyan→purple→pink gradient in Cyberpunk, a candy rainbow in
    /// Unicorn, the base colour otherwise.
    static func ctaStyle(_ base: Color) -> AnyShapeStyle {
        if cyber {
            return AnyShapeStyle(LinearGradient(colors: [cyberAccent, cyberPurple, cyberPink],
                                                startPoint: .leading, endPoint: .trailing))
        }
        if unicorn {
            return AnyShapeStyle(LinearGradient(colors: [uniAccent, uniPink, uniGood],
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(base)
    }

    /// Tile/panel rims: neon cyan→magenta in Cyberpunk, pastel pink→mint in
    /// Unicorn, clear otherwise.
    static var tileStroke: AnyShapeStyle {
        if cyber {
            return AnyShapeStyle(LinearGradient(
                colors: [cyberAccent.opacity(0.55), cyberPink.opacity(0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        if unicorn {
            return AnyShapeStyle(LinearGradient(
                colors: [uniPink.opacity(0.9), uniLilac.opacity(0.9), uniMint.opacity(0.9)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(Color.clear)
    }
    static var tileStrokeWidth: CGFloat { cyber || unicorn ? 1 : 0 }

    /// Ink for the big metric numerals. Cyberpunk used a cyan→purple
    /// gradient, but under the CRT scanlines it lost too much contrast —
    /// white reads at a glance, and the neon glow shadow keeps the look.
    static var valueStyle: AnyShapeStyle {
        AnyShapeStyle(textPrimary)
    }

    /// Unit labels next to the numerals: neon pink in Cyberpunk, orchid in
    /// Unicorn.
    static var unitColor: Color {
        cyber ? cyberPink.opacity(0.85) : unicorn ? uniAccent.opacity(0.9) : textSecondary
    }

    /// Status pills/capsules get a visible rim in the fun themes.
    static var pillStrokeOpacity: Double { cyber ? 0.5 : unicorn ? 0.4 : 0 }

    /// The radar lane's resting border (its threat flood overrides this).
    static var radarIdleStroke: Color {
        cyber ? cyberAccent.opacity(0.4)
              : unicorn ? uniAccent.opacity(0.35) : Color.white.opacity(0.08)
    }

    /// Large value font for the metric tiles / speed readout. The digital style
    /// only carries digits and separators — any other text (Now, None, n/a)
    /// falls back to the system font automatically. Unicorn swaps the standard
    /// numerals for Chalkboard SE — the fun hand-drawn face iOS ships with
    /// (its digits aren't monospaced, so they wobble a little; that's part of
    /// the charm).
    static func valueFont(_ size: CGFloat) -> Font {
        switch digitStyle {
        case .standard:
            return unicorn ? .custom("ChalkboardSE-Bold", size: size)
                           : .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        case .digital: return .custom("CycleHUD7Seg", size: size)
        }
    }

    static var labelFont: Font {
        unicorn ? .custom("ChalkboardSE-Regular", size: 13)
                : .system(size: 13, weight: .semibold, design: .rounded)
    }
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

/// Full-screen backdrop. Light/Dark: the flat theme colour. Cyberpunk: a dark
/// teal→magenta wash with big soft neon glows in the corners (cyan top-left,
/// magenta bottom-right, a faint purple heart) — the website hero's lighting.
/// Content sits on solid panels, so the backdrop can afford to be loud.
struct ThemeBackground: View {
    /// Captured at construction: with no stored inputs SwiftUI would memoize
    /// this view and keep the previous theme's backdrop after a switch (light/
    /// dark showing the Cyberpunk wash). The changing input forces a re-render.
    var appearance: AppearanceTheme = Theme.appearance

    var body: some View {
        if appearance == .cyberpunk {
            GeometryReader { geo in
                let r = max(geo.size.width, geo.size.height)
                ZStack {
                    LinearGradient(colors: [Theme.cyberBgTop, Theme.cyberBackground, Theme.cyberBgBottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [Theme.cyberCyan.opacity(0.30), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: r * 0.75)
                    RadialGradient(colors: [Theme.cyberPink.opacity(0.26), .clear],
                                   center: .bottomTrailing, startRadius: 0, endRadius: r * 0.8)
                    RadialGradient(colors: [Theme.cyberPurple.opacity(0.14), .clear],
                                   center: .center, startRadius: 0, endRadius: r * 0.6)
                }
            }
        } else if appearance == .unicorn {
            // The Cyberpunk wash through a candy filter: pink dawn top-left,
            // mint meadow bottom-right, a lilac shimmer in the middle and a
            // hint of sky — pastel, but the panels on top keep the data crisp.
            GeometryReader { geo in
                let r = max(geo.size.width, geo.size.height)
                ZStack {
                    Theme.uniBackground
                    RadialGradient(colors: [Theme.uniPink.opacity(0.55), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: r * 0.75)
                    RadialGradient(colors: [Theme.uniMint.opacity(0.50), .clear],
                                   center: .bottomTrailing, startRadius: 0, endRadius: r * 0.8)
                    RadialGradient(colors: [Theme.uniSky.opacity(0.35), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: r * 0.7)
                    RadialGradient(colors: [Theme.uniLilac.opacity(0.30), .clear],
                                   center: .center, startRadius: 0, endRadius: r * 0.6)
                }
            }
        } else {
            Theme.background
        }
    }
}

extension View {
    /// Theme chrome for the settings-style screens (Forms/Lists): in Cyberpunk
    /// the system list background is hidden so the gradient backdrop shows
    /// through, and controls take the theme accent. Light/Dark keep the stock
    /// system look, so those themes are unchanged.
    func themedList() -> some View {
        self
            .scrollContentBackground(
                Theme.appearance == .cyberpunk || Theme.appearance == .unicorn
                    ? .hidden : .automatic)
            .background(ThemeBackground().ignoresSafeArea())
            .tint(Theme.accent)
    }
}

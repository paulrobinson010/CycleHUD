import Foundation

/// Locale-aware number formatting for display.
///
/// The app's *units* (km vs mi, m/s internally) stay user-chosen and are handled
/// by `SpeedUnit`/`DistanceUnit`; this only decides how a number is written —
/// the decimal mark and digit grouping follow the device locale, so a French
/// phone shows `24,3` and `1 234` rather than `24.3` and `1,234`.
enum Fmt {
    /// Locale used for number formatting. Defaults to the device locale, but is
    /// pointed at the in-app language override when the rider picks one, so
    /// numbers (decimal mark, grouping) follow the chosen language too.
    static var locale: Locale = .autoupdatingCurrent

    /// Whole number with locale grouping.
    static func int(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    /// Rounded whole number with locale grouping.
    static func int(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.locale(locale))
    }

    /// Fixed-fraction decimal with locale separators (e.g. 2 → `24.30` / `24,30`).
    static func decimal(_ value: Double, _ places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)).locale(locale))
    }
}

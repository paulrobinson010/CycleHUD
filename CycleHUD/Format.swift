import Foundation

/// Locale-aware number formatting for display.
///
/// The app's *units* (km vs mi, m/s internally) stay user-chosen and are handled
/// by `SpeedUnit`/`DistanceUnit`; this only decides how a number is written —
/// the decimal mark and digit grouping follow the device locale, so a French
/// phone shows `24,3` and `1 234` rather than `24.3` and `1,234`.
enum Fmt {
    /// Whole number with locale grouping.
    static func int(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// Rounded whole number with locale grouping.
    static func int(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number)
    }

    /// Fixed-fraction decimal with locale separators (e.g. 2 → `24.30` / `24,30`).
    static func decimal(_ value: Double, _ places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }
}

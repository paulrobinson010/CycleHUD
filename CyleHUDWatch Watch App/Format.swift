import Foundation

/// Locale-aware number formatting for the Watch display — the decimal mark and
/// digit grouping follow the device locale (matches the phone app's `Fmt`).
enum Fmt {
    static func int(_ value: Int) -> String {
        value.formatted(.number)
    }
    static func int(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number)
    }
    static func decimal(_ value: Double, _ places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }
}

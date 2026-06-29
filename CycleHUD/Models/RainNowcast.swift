import Foundation

/// A short-term (next-hour) rain summary distilled from WeatherKit, for the
/// at-a-glance pill: is it about to rain, how soon, how hard and for how long.
struct RainNowcast: Equatable {
    enum Intensity: Int, Comparable {
        case none = 0, light, moderate, heavy
        static func < (l: Intensity, r: Intensity) -> Bool { l.rawValue < r.rawValue }

        /// Bucket a precipitation rate in mm/hr (the meteorological convention:
        /// <2.5 light, 2.5–7.6 moderate, >7.6 heavy). Thresholds are easy to
        /// re-tune once verified against real WeatherKit values on-device.
        static func from(mmPerHour v: Double) -> Intensity {
            if v <= 0 { return .none }
            if v < 2.5 { return .light }
            if v < 7.6 { return .moderate }
            return .heavy
        }

        var label: String {
            switch self {
            case .none: return "—"
            case .light: return String(localized: "light")
            case .moderate: return String(localized: "moderate")
            case .heavy: return String(localized: "heavy")
            }
        }
    }

    /// Raining at the current location right now.
    let isRaining: Bool
    /// Minutes until rain begins (nil if it's already raining, or none in range).
    let startsInMinutes: Int?
    /// How long the current/upcoming rain lasts within the forecast window
    /// (nil if open-ended beyond the window).
    let durationMinutes: Int?
    /// Peak intensity over the current/upcoming wet spell.
    let peak: Intensity
    /// True when built from minute-by-minute data; false = coarser hourly fallback.
    let usedMinuteData: Bool
    let asOf: Date

    /// Any rain to surface at all (now or soon).
    var hasRain: Bool { isRaining || startsInMinutes != nil }

    /// "Imminent" — within the next 15 minutes — used to fire an alert.
    var isImminent: Bool {
        if isRaining { return true }
        if let m = startsInMinutes { return m <= 15 }
        return false
    }

    /// One-line text for the imminent-rain notification.
    var alertMessage: String {
        let hard = peak != .none ? " (\(peak.label))" : ""
        if isRaining { return String(localized: "Rain has started\(hard).") }
        if let m = startsInMinutes {
            let when = usedMinuteData ? String(localized: "in about \(Fmt.int(m)) min")
                                      : String(localized: "within the hour")
            return String(localized: "Rain expected \(when)\(hard).")
        }
        return String(localized: "Rain expected soon.")
    }
}

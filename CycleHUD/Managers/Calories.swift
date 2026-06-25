import Foundation

/// Heart-rate based calorie estimation (Keytel et al., 2005). Only meaningful
/// when a live heart rate is available (from the paired Watch). Body metrics are
/// read from Apple Health where possible, with sensible fallbacks.
enum Calories {
    /// Kilocalories burned per minute at a given heart rate.
    static func kcalPerMinute(heartRate hr: Double,
                              weightKg: Double,
                              ageYears: Double,
                              isFemale: Bool) -> Double {
        let perMinute: Double
        if isFemale {
            perMinute = (-20.4022 + 0.4472 * hr - 0.1263 * weightKg + 0.074 * ageYears) / 4.184
        } else {
            perMinute = (-55.0969 + 0.6309 * hr + 0.1988 * weightKg + 0.2017 * ageYears) / 4.184
        }
        return max(0, perMinute)
    }

    /// Kilocalories burned per minute estimated from cycling speed, for when no
    /// heart rate is available (no Watch). Uses standard cycling MET values:
    /// kcal/min = MET × 3.5 × weightKg / 200.
    static func kcalPerMinute(speedMps: Double, weightKg: Double) -> Double {
        let kmh = speedMps * 3.6
        let met: Double
        switch kmh {
        case ..<1:   met = 1.0     // essentially stopped (resting)
        case ..<16:  met = 4.0     // easy
        case ..<19:  met = 6.8
        case ..<22:  met = 8.0
        case ..<25:  met = 10.0
        case ..<30:  met = 12.0
        default:     met = 15.8    // fast
        }
        return met * 3.5 * weightKg / 200.0
    }
}

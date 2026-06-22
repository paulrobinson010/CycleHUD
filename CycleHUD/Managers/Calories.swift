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
}

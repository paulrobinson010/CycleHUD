import Foundation

/// Current conditions distilled from WeatherKit for the ride tiles: air
/// temperature and wind. Kept separate from `RainNowcast` (which is purely the
/// short-term rain outlook) so each tile reads exactly what it needs.
struct WeatherConditions: Equatable {
    /// Air temperature in degrees Celsius (converted for display).
    let temperatureC: Double
    /// Wind speed in metres per second.
    let windSpeedMps: Double
    /// Peak gust in metres per second, when reported.
    let gustMps: Double?
    /// Direction the wind is blowing *from*, in degrees clockwise from north
    /// (WeatherKit's convention).
    let windFromDegrees: Double
    let asOf: Date

    /// The component of the wind along the rider's direction of travel, in m/s.
    /// Positive = headwind (opposing), negative = tailwind (assisting). `course`
    /// is the rider's heading in degrees clockwise from north.
    func headwindMps(course: Double) -> Double {
        let delta = (windFromDegrees - course) * .pi / 180
        return windSpeedMps * cos(delta)
    }
}

import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// The ride Live Activity's data contract, shared between the app (which
/// starts and updates the activity) and the widget extension (which draws
/// it on the Lock Screen / Dynamic Island). Unit conversion factors travel
/// in the attributes so the extension needs no app models or settings.
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speedMps: Double
        var distanceMeters: Double
        var movingTimeSeconds: Double
        var heartRate: Int?
        /// Highest current radar threat: 0 clear, 1 low, 2 medium, 3 high.
        var threatLevel: Int
        /// Vehicles currently tracked behind the rider.
        var threatCount: Int
        var paused: Bool
        var radarConnected: Bool
    }

    /// "km/h" or "mph".
    var speedUnitLabel: String
    /// "km" or "mi".
    var distanceUnitLabel: String
    /// Multiply m/s by this for the display speed.
    var speedFactor: Double
    /// Multiply metres by this for the display distance.
    var distanceFactor: Double
}
#endif

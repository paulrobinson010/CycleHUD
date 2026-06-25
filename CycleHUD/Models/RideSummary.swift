import Foundation

/// A completed ride's headline stats, shown in the end-of-ride summary and the
/// previous-rides list. Persisted locally so history works without Apple Health.
struct RideSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date                  // ride start
    let distanceMeters: Double
    let movingTimeSeconds: Double
    let elevationGainMeters: Double
    let caloriesKcal: Double

    var averageSpeedMps: Double {
        movingTimeSeconds > 0 ? distanceMeters / movingTimeSeconds : 0
    }
}

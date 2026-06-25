import Foundation
import CoreLocation

/// A single route coordinate, Codable for local persistence.
struct Coord: Codable, Equatable {
    let lat: Double
    let lon: Double
}

/// A completed ride's headline stats, shown in the end-of-ride summary and the
/// previous-rides list. Persisted locally so history works without Apple Health.
struct RideSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date                  // ride start
    let distanceMeters: Double
    let movingTimeSeconds: Double
    let elevationGainMeters: Double
    let caloriesKcal: Double
    // Optional so summaries saved before these fields existed still decode.
    let averageHeartRate: Int?
    let maxHeartRate: Int?
    let routePoints: [Coord]?       // downsampled GPS track for the summary map
    let radarPoints: [Coord]?       // where vehicles were detected behind the rider
    let passes: [VehiclePass]?      // per-vehicle approach traces for review

    var averageSpeedMps: Double {
        movingTimeSeconds > 0 ? distanceMeters / movingTimeSeconds : 0
    }

    var coordinates: [CLLocationCoordinate2D] {
        (routePoints ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var radarCoordinates: [CLLocationCoordinate2D] {
        (radarPoints ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
}

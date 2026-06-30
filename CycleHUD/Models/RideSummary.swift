import Foundation
import CoreLocation

/// A single route coordinate, Codable for local persistence.
struct Coord: Codable, Equatable {
    let lat: Double
    let lon: Double
}

/// A periodic snapshot during a ride, for the summary's speed / heart-rate /
/// elevation graphs. Sampled every couple of seconds while riding and
/// downsampled on save. Speed in m/s; altitude in metres *relative to the ride's
/// start* (climbs positive, descents negative).
struct TrackSample: Codable, Equatable {
    let t: Double            // seconds since ride start
    let speedMps: Double
    let hr: Int?
    let altitude: Double
}

/// A manually-marked lap split: its duration and the distance covered since the
/// previous lap (or the ride start).
struct Lap: Codable, Equatable, Identifiable {
    let id: UUID
    let number: Int
    let durationSeconds: Double
    let distanceMeters: Double

    var averageSpeedMps: Double {
        durationSeconds > 0 ? distanceMeters / durationSeconds : 0
    }
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
    let routeSpeeds: [Double]?      // m/s at each route point, for colouring the line by speed
    let radarPoints: [Coord]?       // where vehicles were detected behind the rider
    let passes: [VehiclePass]?      // per-vehicle approach traces for review
    let track: [TrackSample]?       // downsampled speed/HR/elevation series for graphs
    let laps: [Lap]?                // manually-marked lap splits, if any

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

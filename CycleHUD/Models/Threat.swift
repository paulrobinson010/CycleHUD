import SwiftUI

/// Severity level used to colour a radar threat. Derived from approach speed
/// and proximity (the radar protocol itself only gives us id/distance/speed).
enum ThreatLevel: Int, Comparable {
    case low = 0      // approaching slowly / far away
    case medium = 1
    case high = 2     // fast and/or close — most urgent

    static func < (lhs: ThreatLevel, rhs: ThreatLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: Color {
        switch self {
        case .low: return Theme.threatLow
        case .medium: return Theme.threatMedium
        case .high: return Theme.threatHigh
        }
    }
}

/// A single vehicle detected behind the rider by the radar.
struct Threat: Identifiable, Equatable {
    let id: Int            // radar-assigned threat id (used to detect *new* cars)
    var distanceMeters: Double
    var approachSpeedKmh: Double
    var lastSeen: Date

    var level: ThreatLevel {
        // Closing fast or very close ⇒ high. Tuned for road riding.
        // Tuned for the ~50 m radar lane so the colour spans the visible range:
        // far third yellow, middle orange, nearest red (and a fast closing speed
        // escalates regardless of distance).
        if approachSpeedKmh >= 35 || distanceMeters <= 15 { return .high }
        if approachSpeedKmh >= 20 || distanceMeters <= 30 { return .medium }
        return .low
    }
}

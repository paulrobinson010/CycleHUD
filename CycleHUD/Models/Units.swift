import Foundation

/// Speed display units. Values are always stored internally in metres/second.
enum SpeedUnit: String, CaseIterable, Identifiable, Codable {
    case kmh
    case mph

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kmh: return "km/h"
        case .mph: return "mph"
        }
    }

    /// Convert a speed in m/s into this unit.
    func value(fromMps mps: Double) -> Double {
        switch self {
        case .kmh: return mps * 3.6
        case .mph: return mps * 2.2369362920544
        }
    }
}

/// Distance display units. Values are always stored internally in metres.
enum DistanceUnit: String, CaseIterable, Identifiable, Codable {
    case km
    case mi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .km: return "km"
        case .mi: return "mi"
        }
    }

    /// Convert a distance in metres into this unit (km or miles).
    func value(fromMeters m: Double) -> Double {
        switch self {
        case .km: return m / 1000.0
        case .mi: return m / 1609.344
        }
    }

    /// Short distances (radar threats) follow the same system: metres or feet.
    var shortLabel: String {
        switch self {
        case .km: return "m"
        case .mi: return "ft"
        }
    }

    func shortValue(fromMeters m: Double) -> Double {
        switch self {
        case .km: return m
        case .mi: return m * 3.280839895
        }
    }
}

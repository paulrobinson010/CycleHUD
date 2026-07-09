import SwiftUI

/// One selectable metric for the ride screen's tile grid. The rider chooses
/// which of these to show, and in what order, in Settings → Ride screen. The
/// raw values are persisted, so don't rename existing cases.
enum MetricKind: String, CaseIterable, Identifiable, Codable {
    case speed, avgSpeed, maxSpeed, cadence, distance, time, ascent
    case heartRate, calories, gradient, lapTime, temperature, wind, rain
    case compass, junction, climb, power

    var id: String { rawValue }

    /// The tiles shown by default, in order — the original ride-screen layout.
    /// The extra metrics (gradient, temperature, wind, max/lap) are available to
    /// add in Settings → Ride screen tiles but aren't shown out of the box.
    static let defaultOrder: [MetricKind] = [
        .speed, .avgSpeed, .cadence,
        .distance, .time, .ascent,
        .heartRate, .calories, .rain
    ]

    var title: LocalizedStringKey {
        switch self {
        case .speed: return "Speed"
        case .avgSpeed: return "Avg Speed"
        case .maxSpeed: return "Max Speed"
        case .cadence: return "Cadence"
        case .distance: return "Distance"
        case .time: return "Time"
        case .ascent: return "Ascent"
        case .heartRate: return "Heart Rate"
        case .calories: return "Calories"
        case .gradient: return "Gradient"
        case .lapTime: return "Lap"
        case .temperature: return "Temp"
        case .wind: return "Wind"
        case .rain: return "Rain"
        case .compass: return "Compass"
        case .junction: return "Junction"
        case .climb: return "Distance and climb"
        case .power: return "Power"
        }
    }

    var systemImage: String {
        switch self {
        case .speed: return "speedometer"
        case .avgSpeed: return "gauge.with.dots.needle.50percent"
        case .maxSpeed: return "gauge.with.dots.needle.100percent"
        case .cadence: return "bicycle"
        case .distance: return "ruler"
        case .time: return "clock"
        case .ascent: return "mountain.2"
        case .heartRate: return "heart.fill"
        case .calories: return "flame.fill"
        case .gradient: return "angle"
        case .lapTime: return "flag.checkered"
        case .temperature: return "thermometer.medium"
        case .wind: return "wind"
        case .rain: return "cloud.rain"
        case .compass: return "safari"
        case .junction: return "arrow.triangle.branch"
        case .climb: return "chart.line.uptrend.xyaxis"
        case .power: return "bolt.fill"
        }
    }

    /// Takes a whole grid row (the climb row: distance/gradient/ascent over
    /// the route's elevation profile).
    var isFullRow: Bool {
        self == .climb
    }

    /// Needs WeatherKit data, so it's hidden when Weather is turned off.
    var requiresWeather: Bool {
        self == .temperature || self == .wind || self == .rain
    }

    /// Needs OpenStreetMap road data, so it's hidden when Upcoming junctions
    /// is turned off.
    var requiresJunctions: Bool {
        self == .junction
    }
}

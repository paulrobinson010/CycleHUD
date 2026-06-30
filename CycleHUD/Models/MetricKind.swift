import SwiftUI

/// One selectable metric for the ride screen's tile grid. The rider chooses
/// which of these to show, and in what order, in Settings → Ride screen. The
/// raw values are persisted, so don't rename existing cases.
enum MetricKind: String, CaseIterable, Identifiable, Codable {
    case speed, avgSpeed, maxSpeed, cadence, distance, time, ascent
    case heartRate, calories, gradient, lapTime, temperature, wind, rain

    var id: String { rawValue }

    /// The tiles shown by default, in order — the layout the app shipped with,
    /// plus the gradient/weather tiles.
    static let defaultOrder: [MetricKind] = [
        .speed, .avgSpeed, .cadence,
        .distance, .time, .ascent,
        .heartRate, .calories, .rain,
        .gradient, .temperature, .wind
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
        }
    }

    /// Needs WeatherKit data, so it's hidden when Weather is turned off.
    var requiresWeather: Bool {
        self == .temperature || self == .wind || self == .rain
    }
}

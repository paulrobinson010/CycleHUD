import Foundation

/// One tracked bike part. Wear is measured against its BIKE's odometer:
/// `baselineMeters` is that odometer's reading when the part was installed
/// (or last serviced), so wear is simply `odometer − baseline`.
struct BikeComponent: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// The bike's odometer at install / last service.
    var baselineMeters: Double
    /// Check-it interval in metres (nil = just track the distance).
    var serviceIntervalMeters: Double?
    /// Odometer reading when the due notification last fired, so one
    /// crossing notifies once (reset by "Mark serviced").
    var notifiedAtMeters: Double?

    func wearMeters(lifetime: Double) -> Double { max(0, lifetime - baselineMeters) }
}

/// What kind of bike this is: sets the icon, and the starting wheel size and
/// feature defaults when the profile is created. Nothing is locked to it —
/// every value stays editable afterwards.
enum BikeKind: String, Codable, CaseIterable, Identifiable {
    case road, gravel, mtb, other
    var id: String { rawValue }

    /// Shown in the type picker and under each bike's name.
    var label: String {
        switch self {
        case .road: return String(localized: "Road", bundle: Lang.bundle)
        case .gravel: return String(localized: "Gravel", bundle: Lang.bundle)
        case .mtb: return String(localized: "Mountain", bundle: Lang.bundle)
        case .other: return String(localized: "Other", bundle: Lang.bundle)
        }
    }

    /// The name a newly-added bike of this kind starts with — distinct per
    /// kind so a second road bike doesn't silently duplicate the first.
    var defaultName: String {
        switch self {
        case .road: return String(localized: "Road bike", bundle: Lang.bundle)
        case .gravel: return String(localized: "Gravel bike", bundle: Lang.bundle)
        case .mtb: return String(localized: "Mountain bike", bundle: Lang.bundle)
        case .other: return String(localized: "Bike", bundle: Lang.bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .road: return "bicycle"
        case .gravel: return "bicycle"
        case .mtb: return "figure.outdoor.cycle"
        case .other: return "bicycle.circle"
        }
    }

    /// Typical rolling circumference (mm) for the kind — a starting point.
    /// Road 700×25c, gravel ~700×40c, MTB 29×2.25".
    var defaultWheelMM: Double {
        switch self {
        case .road: return 2105
        case .gravel: return 2200
        case .mtb: return 2290
        case .other: return 2105
        }
    }

    /// Off-road, an 8 g impact is a root or a rock and stopping afterwards is
    /// normal, so impact-plus-stop crash detection false-positives; and the
    /// junction graph is road-only, so it can't see trail junctions and would
    /// just burn data. Both stay switchable per bike.
    var suitsRoadFeatures: Bool { self != .mtb }
}

/// One of the rider's bikes. Each carries the settings that genuinely differ
/// between bikes (wheel circumference for the speed sensor, and whether the
/// road-oriented features make sense), its own odometer and component list,
/// and the sensors fitted to it — so connecting a bike's sensor can select it
/// without the rider touching anything.
struct BikeProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var kind: BikeKind = .road
    /// Rolling circumference for THIS bike's speed sensor.
    var wheelCircumferenceMM: Double
    var crashDetectionEnabled: Bool = false
    var junctionsEnabled: Bool = false
    /// Distance ridden on this bike (all rides recorded against it).
    var odometerMeters: Double = 0
    var components: [BikeComponent] = []
    /// Saved BLE device ids fitted to this bike (speed/cadence/power — the
    /// bike-mounted ones). Used to auto-select the bike on connection.
    var sensorIDs: [UUID] = []
}

import Foundation
import CoreLocation

/// One sampled instant during a vehicle's approach (~2 Hz, the radar's frame
/// rate). Distances in metres, speeds in km/h.
struct PassSample: Codable, Equatable {
    let t: Double            // seconds since first detection
    let distance: Double     // metres to the vehicle
    let closingKmh: Double   // radar-reported approach (closing) speed
    let riderKmh: Double     // the rider's own speed at that instant
}

/// A single vehicle's approach, from first detection to passing, captured during
/// a ride so a close or fast pass can be reviewed afterwards. The radar reports
/// distance and a closing speed; combined with the rider's own speed (and any
/// slowing) this gives a picture of how each pass actually unfolded.
struct VehiclePass: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date           // first detection
    let lat: Double?
    let lon: Double?
    let samples: [PassSample]

    var duration: Double { samples.last?.t ?? 0 }
    var minDistance: Double { samples.map(\.distance).min() ?? 0 }
    var maxClosingKmh: Double { samples.map(\.closingKmh).max() ?? 0 }

    /// The sample at the closest point of approach.
    var closestSample: PassSample? { samples.min(by: { $0.distance < $1.distance }) }

    /// Rider speed at the closest point of approach.
    var riderKmhAtClosest: Double { closestSample?.riderKmh ?? 0 }
    /// Fastest rider speed during the encounter — used to tell if they slowed.
    var riderKmhPeak: Double { samples.map(\.riderKmh).max() ?? 0 }
    /// How much the rider slowed from their peak to the closest point (km/h).
    var riderSlowedKmh: Double { max(0, riderKmhPeak - riderKmhAtClosest) }

    /// Estimated vehicle ground speed at closest approach. A vehicle overtaking
    /// from behind closes at (its speed − the rider's), so we add the rider's
    /// speed back onto the radar's closing speed. An estimate, not exact.
    var estVehicleKmh: Double {
        closestSample.map { $0.riderKmh + $0.closingKmh } ?? maxClosingKmh
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Flag a close pass worth reviewing — the vehicle came within 15 m.
    var isClose: Bool { minDistance <= 15 }
}

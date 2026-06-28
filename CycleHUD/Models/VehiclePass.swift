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

    /// Plausibility bounds for a radar frame. The TR70 detects to ~50 m and
    /// reports closing speed in whole m/s; a single frame occasionally decodes to
    /// a wild value (e.g. 190 m at 122 km/h) that would spike the charts and
    /// inflate the headline speeds. Anything outside these is dropped.
    static let maxPlausibleDistance = 60.0      // metres (radar real max ~50)
    static let maxPlausibleClosingKmh = 90.0    // km/h closing differential

    /// Samples with obviously-bad radar frames removed. All stats and charts use
    /// these so one glitchy reading can't distort the pass.
    var cleanSamples: [PassSample] {
        let good = samples.filter {
            $0.distance > 0 && $0.distance <= Self.maxPlausibleDistance
                && $0.closingKmh >= 0 && $0.closingKmh <= Self.maxPlausibleClosingKmh
        }
        return good.isEmpty ? samples : good   // never blank the trace entirely
    }

    var duration: Double { cleanSamples.last?.t ?? 0 }
    var minDistance: Double { cleanSamples.map(\.distance).min() ?? 0 }
    var maxClosingKmh: Double { cleanSamples.map(\.closingKmh).max() ?? 0 }

    /// The sample at the closest point of approach.
    var closestSample: PassSample? { cleanSamples.min(by: { $0.distance < $1.distance }) }

    /// Rider speed at the closest point of approach.
    var riderKmhAtClosest: Double { closestSample?.riderKmh ?? 0 }
    /// Fastest rider speed during the encounter — used to tell if they slowed.
    var riderKmhPeak: Double { cleanSamples.map(\.riderKmh).max() ?? 0 }
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

    /// Danger colour for the pass, keyed on how fast the vehicle *closed* rather
    /// than how near it got. On a road most passes are close (you share a lane),
    /// so distance alone paints everything red; closing speed is the better
    /// danger signal — a vehicle that comes up fast gives the least reaction
    /// time. Closing speed is quantised to whole m/s by the radar (≈3.6 km/h
    /// steps), so the thresholds line up with that.
    var level: ThreatLevel {
        if maxClosingKmh >= 25 { return .high }     // ~7 m/s+ : came up fast
        if maxClosingKmh >= 12 { return .medium }   // ~3-6 m/s
        return .low
    }
}

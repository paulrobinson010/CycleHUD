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

    /// Samples with single-frame radar glitches removed. The radar occasionally
    /// decodes one frame to a wild value (e.g. 190 m mid-approach, or a closing
    /// speed far above the rest), which would spike the charts and inflate the
    /// headline speeds. Rather than capping by an absolute limit — high closing
    /// speeds are genuine on fast roads — a sample is dropped only when it's a
    /// local outlier: far from the median of its immediate neighbours. A genuine
    /// approach changes smoothly frame-to-frame, so real data is preserved while
    /// lone spikes are removed. All stats and charts use these so already-saved
    /// rides also render correctly.
    var cleanSamples: [PassSample] {
        guard samples.count >= 5 else { return samples }
        let kept = samples.indices.filter { i in
            let lo = max(0, i - 2), hi = min(samples.count - 1, i + 2)
            let neighbours = (lo...hi).filter { $0 != i }
            let s = samples[i]
            let md = Self.median(neighbours.map { samples[$0].distance })
            let mc = Self.median(neighbours.map { samples[$0].closingKmh })
            // Within ~150% of the neighbours' median (with a floor so small,
            // legitimately-varying values near zero aren't over-trimmed).
            let distOK = abs(s.distance - md) <= max(10, md * 1.5)
            let closeOK = abs(s.closingKmh - mc) <= max(15, mc * 1.5)
            return distOK && closeOK
        }.map { samples[$0] }
        return kept.count >= 3 ? kept : samples   // never blank the trace entirely
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let n = s.count
        return n.isMultiple(of: 2) ? (s[n/2 - 1] + s[n/2]) / 2 : s[n/2]
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

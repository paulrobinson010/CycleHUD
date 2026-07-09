import SwiftUI

/// Classic 7-zone power model from FTP (Coggan levels): the power tile
/// colours by the zone being ridden, and ride summaries show normalized
/// power and time in zones.
enum PowerZones {
    /// Zone lower bounds as a fraction of FTP; zone 1 starts at 0.
    static let bounds: [Double] = [0, 0.56, 0.76, 0.91, 1.06, 1.21, 1.51]

    static func zone(watts: Int, ftp: Int) -> Int {
        guard ftp > 0 else { return 1 }
        let frac = Double(watts) / Double(ftp)
        var z = 1
        for (i, low) in bounds.enumerated() where frac >= low { z = i + 1 }
        return z
    }

    static func color(_ zone: Int) -> Color {
        switch zone {
        case 1: return .gray
        case 2: return .blue
        case 3: return .green
        case 4: return .yellow
        case 5: return .orange
        case 6: return .red
        default: return .purple
        }
    }

    /// Normalized power over the ride's track samples (~2 s cadence): a 30 s
    /// rolling average, raised to the 4th power, averaged, 4th-rooted — the
    /// standard estimate of the ride's physiological cost. nil without
    /// meaningful power data.
    static func normalizedPower(_ samples: [TrackSample]) -> Int? {
        let watts = samples.map { Double($0.power ?? 0) }
        guard watts.contains(where: { $0 > 0 }), watts.count >= 30 else { return nil }
        let window = 15                          // ~30 s of 2 s samples
        var rolling: [Double] = []
        var sum = 0.0
        for (i, w) in watts.enumerated() {
            sum += w
            if i >= window { sum -= watts[i - window] }
            if i >= window - 1 { rolling.append(sum / Double(window)) }
        }
        guard !rolling.isEmpty else { return nil }
        let mean4 = rolling.reduce(0) { $0 + pow($1, 4) } / Double(rolling.count)
        return Int(pow(mean4, 0.25).rounded())
    }

    /// Seconds spent in each of the 7 zones, from track samples.
    static func timeInZones(_ samples: [TrackSample], ftp: Int) -> [Double]? {
        guard ftp > 0 else { return nil }
        var zones = [Double](repeating: 0, count: 7)
        var any = false
        for (i, s) in samples.enumerated() {
            guard let w = s.power else { continue }
            any = true
            let dt = i + 1 < samples.count ? max(0, samples[i + 1].t - s.t) : 2
            zones[zone(watts: w, ftp: ftp) - 1] += dt
        }
        return any ? zones : nil
    }
}

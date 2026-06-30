import Foundation

/// Builds a realistic completed ride for screenshots/testing: a loop of Central
/// Park, New York, with a GPS track, radar detection points, and a few vehicle
/// passes (one a close pass). Added to history from the diagnostics screen.
enum SampleRide {

    static func centralPark(now: Date) -> RideSummary {
        let route = loopRoute()
        let radar = radarDetections(along: route)
        let passes = vehiclePasses(now: now, route: route)

        let distance = 9800.0
        let movingTime = 1490.0           // ~24.8 min → avg ~23.7 km/h
        return RideSummary(
            id: UUID(),
            date: now.addingTimeInterval(-(movingTime + 180)),
            distanceMeters: distance,
            movingTimeSeconds: movingTime,
            elevationGainMeters: 78,
            caloriesKcal: 352,
            averageHeartRate: 143,
            maxHeartRate: 169,
            routePoints: route,
            routeSpeeds: routeSpeeds(for: route),
            radarPoints: radar.isEmpty ? nil : radar,
            passes: passes.isEmpty ? nil : passes,
            track: trackSamples(movingTime: movingTime),
            laps: sampleLaps(distance: distance, movingTime: movingTime)
        )
    }

    /// Three even laps so the summary shows the lap splits.
    private static func sampleLaps(distance: Double, movingTime: Double) -> [Lap] {
        (1...3).map { n in
            Lap(id: UUID(), number: n, durationSeconds: movingTime / 3,
                distanceMeters: distance / 3)
        }
    }

    /// A plausible speed (m/s) at each route point so the map line colours by
    /// speed: slower on the rolling climbs, faster on the descents.
    private static func routeSpeeds(for route: [Coord]) -> [Double] {
        let n = max(1, route.count - 1)
        return route.indices.map { i in
            let p = Double(i) / Double(n)
            let hill = sin(p * .pi * 4)                  // -1…1, matches the elevation profile
            let kmh = 26 - hill * 8 + sin(Double(i) / 7) * 1.2
            return max(3, kmh) / 3.6
        }
    }

    /// A plausible speed / heart-rate / elevation series over the ride so the
    /// summary graphs have something to draw: a couple of climbs (HR rising with
    /// gradient, speed dipping) and descents.
    private static func trackSamples(movingTime: Double) -> [TrackSample] {
        var samples: [TrackSample] = []
        let step = 6.0
        var t = 0.0
        while t <= movingTime {
            let p = t / movingTime                      // 0…1 through the ride
            // Two rolling climbs over the loop.
            let hill = sin(p * .pi * 4)                 // -1…1
            let altitude = 22 * (1 - cos(p * .pi * 4)) + hill * 6   // metres, rolling
            let speedKmh = 26 - hill * 7 + sin(t / 40) * 1.5        // slower uphill
            let hr = Int((138 + hill * 18 + sin(t / 55) * 4).rounded())
            samples.append(TrackSample(t: t, speedMps: max(2, speedKmh) / 3.6,
                                       hr: hr, altitude: altitude))
            t += step
        }
        return samples
    }

    /// Perimeter loop of Central Park, clockwise from Columbus Circle,
    /// interpolated into a smooth GPS-like track.
    private static func loopRoute() -> [Coord] {
        let waypoints: [(Double, Double)] = [
            (40.7679, -73.9814), (40.7700, -73.9819), (40.7740, -73.9810),
            (40.7790, -73.9796), (40.7840, -73.9783), (40.7890, -73.9770),
            (40.7930, -73.9755), (40.7958, -73.9740), (40.7968, -73.9710),
            (40.7966, -73.9660), (40.7955, -73.9600), (40.7920, -73.9580),
            (40.7870, -73.9588), (40.7820, -73.9600), (40.7760, -73.9612),
            (40.7710, -73.9628), (40.7682, -73.9645), (40.7672, -73.9700),
            (40.7672, -73.9760), (40.7679, -73.9814)
        ]
        var route: [Coord] = []
        let stepsPer = 12
        for i in 0 ..< waypoints.count - 1 {
            let a = waypoints[i], b = waypoints[i + 1]
            for s in 0 ..< stepsPer {
                let t = Double(s) / Double(stepsPer)
                // Tiny perpendicular wiggle so it reads like a recorded track.
                let wob = sin(Double(route.count) / 3.0) * 0.00006
                route.append(Coord(lat: a.0 + (b.0 - a.0) * t + wob,
                                   lon: a.1 + (b.1 - a.1) * t + wob))
            }
        }
        route.append(Coord(lat: waypoints[waypoints.count - 1].0,
                           lon: waypoints[waypoints.count - 1].1))
        return route
    }

    /// Spread vehicle-detection pins along the loop.
    private static func radarDetections(along route: [Coord]) -> [Coord] {
        var radar: [Coord] = []
        var i = 14
        while i < route.count {
            radar.append(route[i])
            i += 19
        }
        return radar
    }

    /// A handful of approaches, including a close pass (within 15 m).
    private static func vehiclePasses(now: Date, route: [Coord]) -> [VehiclePass] {
        // (closest m, peak closing km/h, rider km/h, route index)
        let specs: [(Double, Double, Double, Int)] = [
            (28, 22, 24, 40),
            (9,  31, 23, 95),    // close + fast pass
            (18, 19, 25, 150),
            (34, 16, 26, 60),
            (12, 27, 22, 178),   // fast pass
        ]
        var passes: [VehiclePass] = []
        for (i, spec) in specs.enumerated() {
            let (closest, peakClosing, riderKmh, routeIdx) = spec
            var samples: [PassSample] = []
            let startDist = closest + 24
            var d = startDist, t = 0.0
            while d >= closest {
                let frac = (startDist - d) / max(1, startDist - closest)
                let closing = 8 + (peakClosing - 8) * frac        // ramps up as it nears
                samples.append(PassSample(t: t, distance: d, closingKmh: closing,
                                          riderKmh: riderKmh + sin(t) * 0.8))
                d -= closing / 3.6 * 0.5                          // metres in 0.5 s
                t += 0.5
            }
            let c = route[min(routeIdx, route.count - 1)]
            passes.append(VehiclePass(id: UUID(),
                                      date: now.addingTimeInterval(Double(-1490 + i * 250)),
                                      lat: c.lat, lon: c.lon, samples: samples))
        }
        return passes
    }
}

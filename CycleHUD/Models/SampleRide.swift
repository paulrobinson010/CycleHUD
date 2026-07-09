import Foundation

/// Builds a realistic completed ride for screenshots/testing: a loop of Central
/// Park, New York, with a GPS track, radar detection points, and a few vehicle
/// passes (one a close pass). Added to history from the diagnostics screen.
enum SampleRide {

    static func centralPark(now: Date) -> RideSummary {
        let route = loopRoute()
        let radar = radarDetections(along: route)
        let passes = vehiclePasses(now: now, route: route)

        let distance = 8300.0             // matches the drawn loop's geometry
        let movingTime = 1270.0           // ~21.2 min → avg ~23.5 km/h
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

    /// The Central Park loop drive, counterclockwise from Columbus Circle —
    /// the park's real one-way direction. Traced in the park's own rotated
    /// grid (Manhattan runs ~29° off true north) so the track stays on the
    /// drives: Center Drive weaving past the Pond, East Drive up beside the
    /// reservoir, the northern curves at Harlem Meer, West Drive down past
    /// the Lake. Interpolated into a smooth GPS-like track.
    private static func loopRoute() -> [Coord] {
        let waypoints: [(Double, Double)] = [
            (40.76860, -73.97936), (40.76783, -73.97830), (40.76725, -73.97697),
            (40.76699, -73.97554), (40.76716, -73.97421), (40.76765, -73.97292),
            (40.76816, -73.97175), (40.76904, -73.97072), (40.77024, -73.96967),
            (40.77171, -73.96876), (40.77321, -73.96790), (40.77473, -73.96709),
            (40.77628, -73.96612), (40.77790, -73.96531), (40.77945, -73.96434),
            (40.78083, -73.96302), (40.78191, -73.96172), (40.78306, -73.96057),
            (40.78443, -73.95946), (40.78588, -73.95850), (40.78735, -73.95759),
            (40.78871, -73.95689), (40.79012, -73.95629), (40.79153, -73.95570),
            (40.79263, -73.95532), (40.79377, -73.95505), (40.79480, -73.95499),
            (40.79576, -73.95525), (40.79670, -73.95566), (40.79756, -73.95612),
            (40.79810, -73.95682), (40.79799, -73.95770), (40.79742, -73.95851),
            (40.79657, -73.95938), (40.79558, -73.96021), (40.79441, -73.96085),
            (40.79323, -73.96148), (40.79201, -73.96248), (40.79089, -73.96348),
            (40.78975, -73.96442), (40.78844, -73.96522), (40.78708, -73.96591),
            (40.78576, -73.96671), (40.78457, -73.96776), (40.78338, -73.96881),
            (40.78209, -73.96966), (40.78075, -73.97041), (40.77949, -73.97110),
            (40.77835, -73.97204), (40.77721, -73.97299), (40.77595, -73.97368),
            (40.77472, -73.97442), (40.77355, -73.97531), (40.77244, -73.97631),
            (40.77130, -73.97725), (40.77016, -73.97819), (40.76926, -73.97897),
            (40.76860, -73.97936)
        ]
        var route: [Coord] = []
        let stepsPer = 6
        for i in 0 ..< waypoints.count - 1 {
            let a = waypoints[i], b = waypoints[i + 1]
            for s in 0 ..< stepsPer {
                let t = Double(s) / Double(stepsPer)
                // Tiny wiggle so it reads like a recorded track, small enough
                // (~3 m) to stay on the road.
                let wob = sin(Double(route.count) / 3.0) * 0.00003
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
        // (closest m, peak closing km/h, rider km/h, fraction along the loop)
        let specs: [(Double, Double, Double, Double)] = [
            (28, 22, 24, 0.14),
            (9,  31, 23, 0.33),  // close + fast pass
            (18, 19, 25, 0.52),
            (34, 16, 26, 0.24),
            (12, 27, 22, 0.71),  // fast pass
        ]
        var passes: [VehiclePass] = []
        for (i, spec) in specs.enumerated() {
            let (closest, peakClosing, riderKmh, fraction) = spec
            let routeIdx = Int(Double(route.count - 1) * fraction)
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
                                      date: now.addingTimeInterval(Double(-1270 + i * 210)),
                                      lat: c.lat, lon: c.lon, samples: samples))
        }
        return passes
    }
}

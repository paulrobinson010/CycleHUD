import Foundation
import CoreLocation

/// A saved planned route: the rider's markers and the road-following path
/// computed between them (quiet-road cycling profile).
struct PlannedRoute: Codable, Identifiable, Equatable {

    struct Point: Codable, Equatable {
        var lat: Double
        var lon: Double
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
        init(_ c: CLLocationCoordinate2D) { lat = c.latitude; lon = c.longitude }
    }

    var id = UUID()
    var name: String
    /// The rider's tapped markers: start first, then vias; for a non-loop
    /// route the last marker is the finish.
    var waypoints: [Point]
    /// True (default) = the route returns to the start; false = A→B.
    var loop: Bool = true
    /// The routed polyline along roads, start→finish.
    var path: [Point]
    var distanceMeters: Double
    var createdAt = Date()
    /// Elevation (m) per path point when the source provides it (BRouter does,
    /// GPX usually does) — powers the climb-profile strip. Optional so routes
    /// saved/shared before this existed still decode.
    var elevations: [Double]? = nil
    /// Ghost rider: the best complete run of this route — elapsed seconds at
    /// each path point (dense, forward-filled), and when it was set. Travels
    /// with shared route files, so friends can race your ghost.
    var bestTimes: [Double]? = nil
    var bestDate: Date? = nil

    // MARK: - Ride-time geometry

    /// East/north metres from `a` to `b` (planar — fine at ride scale).
    static func delta(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (Double, Double) {
        let dy = (b.latitude - a.latitude) * 111_320
        let dx = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (dx, dy)
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (dx, dy) = delta(a, b)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (dx, dy) = delta(a, b)
        let deg = atan2(dx, dy) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Perpendicular distance of `p` from segment a→b, the clamped projection
    /// parameter t ∈ [0, 1], and the segment length — all in metres.
    static func project(_ p: CLLocationCoordinate2D,
                        onto a: CLLocationCoordinate2D,
                        _ b: CLLocationCoordinate2D) -> (distance: Double, t: Double, length: Double) {
        let (abx, aby) = delta(a, b)
        let (apx, apy) = delta(a, p)
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return (meters(a, p), 0, 0) }
        let t = max(0, min(1, (apx * abx + apy * aby) / len2))
        let ox = apx - abx * t
        let oy = apy - aby * t
        return ((ox * ox + oy * oy).squareRoot(), t, len2.squareRoot())
    }

    /// The rider's match on the path: the SEGMENT the position projects onto
    /// (index of its start point), the perpendicular distance to it, and how
    /// far along the segment the projection sits.
    ///
    /// Segments, not vertices: the routed path's nodes can be hundreds of
    /// metres apart on straight roads, so nearest-VERTEX distance reads
    /// "200 m off route" from the middle of a straight the rider is actually
    /// on (seen on device).
    ///
    /// With a `hint` the search is windowed around the last known position
    /// (fast, and keeps progress from jumping backwards where a loop crosses
    /// itself); pass nil to scan the whole path.
    ///
    /// `course` disambiguates out-and-back stretches: on a loop whose first
    /// and last kilometres share the same road, the outbound and homebound
    /// legs overlap — a rider heading home must match the HOMEBOUND leg or
    /// the remaining distance (and junction guidance) jumps to the outbound
    /// one. Segments whose travel direction opposes the course are penalised,
    /// so same-spot ties always resolve to the leg being ridden.
    func nearestPathIndex(to coord: CLLocationCoordinate2D,
                          hint: Int? = nil, windowMeters: Double = 800,
                          course: Double? = nil) -> (index: Int, meters: Double, along: Double)? {
        guard path.count > 1 else {
            guard let only = path.first else { return nil }
            return (0, Self.meters(coord, only.coordinate), 0)
        }
        var lo = 0, hi = path.count - 2          // segment start indices
        if let hint {
            // ~10 m between path points is typical; window generously.
            let span = max(40, Int(windowMeters / 10))
            lo = max(0, hint - span / 4)
            hi = min(path.count - 2, hint + span)
        }
        var best: (index: Int, meters: Double, along: Double, score: Double)?
        for i in lo...hi {
            let a = path[i].coordinate
            let b = path[i + 1].coordinate
            let (d, t, len) = Self.project(coord, onto: a, b)
            var score = d
            if let course, Self.angleDiff(Self.bearing(a, b), course) > 100 {
                score += 500      // soft wrong-way penalty, not a hard filter
            }
            if best == nil || score < best!.score {
                best = (i, d, t * len, score)
            }
        }
        guard let r = best else { return nil }
        return (r.index, r.meters, r.along)
    }

    /// Riding distance along the path from `index` to the finish.
    func remainingMeters(from index: Int) -> Double {
        guard index < path.count - 1 else { return 0 }
        var total = 0.0
        for i in index..<(path.count - 1) {
            total += Self.meters(path[i].coordinate, path[i + 1].coordinate)
        }
        return total
    }

    /// The direction the route arrives at point `index` from, averaged over
    /// ~`lookback` metres of approach.
    func bearingBefore(index: Int, lookback: Double = 25) -> Double? {
        guard index > 0 else { return nil }
        var travelled = 0.0
        var i = index
        while i > 0, travelled < lookback {
            travelled += Self.meters(path[i - 1].coordinate, path[i].coordinate)
            i -= 1
        }
        guard i < index else { return nil }
        return Self.bearing(path[i].coordinate, path[index].coordinate)
    }

    /// The next place the route bends sharply after `index`: walks up to
    /// `within` metres ahead and reports the first vertex where the heading
    /// changes by ≥ 40° (measured over ~25 m either side, so gentle curves
    /// don't trigger). `deltaDegrees` is signed: negative = left turn.
    func nextTurn(after index: Int, within: Double)
        -> (index: Int, distanceMeters: Double, deltaDegrees: Double)? {
        var dist = 0.0
        var i = index + 1
        while i < path.count - 1, dist <= within {
            dist += Self.meters(path[i - 1].coordinate, path[i].coordinate)
            if dist > within { break }
            if let before = bearingBefore(index: i),
               let after = bearingAfter(index: i) {
                let delta = (after - before + 540).truncatingRemainder(dividingBy: 360) - 180
                if abs(delta) >= 40 {
                    return (i, dist, delta)
                }
            }
            i += 1
        }
        return nil
    }

    /// The direction the route heads roughly `lookahead` metres after passing
    /// nearest-point `index` — used to pick the junction arm to highlight.
    func bearingAfter(index: Int, lookahead: Double = 25) -> Double? {
        guard index < path.count - 1 else { return nil }
        var travelled = 0.0
        var i = index
        while i < path.count - 1, travelled < lookahead {
            travelled += Self.meters(path[i].coordinate, path[i + 1].coordinate)
            i += 1
        }
        guard i > index else { return nil }
        return Self.bearing(path[index].coordinate, path[i].coordinate)
    }
}

/// On-disk / shared file envelope, versioned so old builds can reject newer
/// files gracefully. This is the `.cyclehudroute` format.
struct RouteFile: Codable {
    var cyclehudRoute: Int = 1
    var route: PlannedRoute
}

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

    /// Index of the path point nearest `coord`, plus its distance in metres.
    /// With a `hint` the search is windowed around the last known position
    /// (fast, and keeps progress from jumping backwards where a loop crosses
    /// itself); pass nil to scan the whole path.
    func nearestPathIndex(to coord: CLLocationCoordinate2D,
                          hint: Int? = nil, windowMeters: Double = 800) -> (index: Int, meters: Double)? {
        guard !path.isEmpty else { return nil }
        var lo = 0, hi = path.count - 1
        if let hint {
            // ~10 m between path points is typical; window generously.
            let span = max(40, Int(windowMeters / 10))
            lo = max(0, hint - span / 4)
            hi = min(path.count - 1, hint + span)
        }
        var best = (index: lo, meters: Double.greatestFiniteMagnitude)
        for i in lo...hi {
            let d = Self.meters(coord, path[i].coordinate)
            if d < best.meters { best = (i, d) }
        }
        return best
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

import Foundation
import CoreLocation

/// Checks whether a route runs along any one-way road (OpenStreetMap data via
/// Overpass) — used to block "Ride in reverse": the original route follows
/// one-ways legally, so flipping the path would send the rider the wrong way
/// up them.
enum OneWayChecker {

    /// True/false when the check completes; nil when it couldn't run
    /// (offline, Overpass down) — the caller decides how cautious to be.
    static func routeUsesOneWay(path: [PlannedRoute.Point]) async -> Bool? {
        guard path.count >= 2 else { return false }
        let lats = path.map(\.lat)
        let lons = path.map(\.lon)
        let pad = 0.001                                   // ~100 m of slack
        let bbox = "\(lats.min()! - pad),\(lons.min()! - pad),\(lats.max()! + pad),\(lons.max()! + pad)"
        // One-way roads plus roundabouts (implicitly one-way in OSM).
        let query = "[out:json][timeout:15];("
            + "way[\"highway\"][\"oneway\"~\"^(yes|1|true|-1)$\"](\(bbox));"
            + "way[\"highway\"][\"junction\"=\"roundabout\"](\(bbox));"
            + ");out geom;"

        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("CycleHUD iOS (+https://cyclehud.robbo-online.uk)",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query))
            .data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return nil }

        // One-way road segments into a coarse spatial hash (~250 m cells).
        typealias Segment = (a: CLLocationCoordinate2D, b: CLLocationCoordinate2D)
        var grid: [Int64: [Segment]] = [:]
        let cell = 0.0025
        func key(_ c: CLLocationCoordinate2D, _ dLat: Int = 0, _ dLon: Int = 0) -> Int64 {
            (Int64((c.latitude / cell).rounded(.down)) + Int64(dLat)) &* 1_000_000
                &+ Int64((c.longitude / cell).rounded(.down)) &+ Int64(dLon)
        }
        for way in elements where way["type"] as? String == "way" {
            guard let geometry = way["geometry"] as? [[String: Any]], geometry.count >= 2 else { continue }
            var prev: CLLocationCoordinate2D?
            for node in geometry {
                guard let lat = node["lat"] as? Double, let lon = node["lon"] as? Double else { continue }
                let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if let p = prev { grid[key(p), default: []].append((p, c)) }
                prev = c
            }
        }
        guard !grid.isEmpty else { return false }

        // A sample point lying along a one-way segment (close AND parallel —
        // crossing one perpendicular doesn't count) means the reverse is
        // illegal somewhere. Long route segments are sampled every ~50 m so a
        // short one-way stretch between sparse route nodes can't slip through.
        func liesOnOneWay(_ point: CLLocationCoordinate2D, heading: Double) -> Bool {
            for dLat in -1...1 {
                for dLon in -1...1 {
                    for seg in grid[key(point, dLat, dLon)] ?? [] {
                        let (d, _, _) = PlannedRoute.project(point, onto: seg.a, seg.b)
                        guard d < 12 else { continue }
                        let diff = PlannedRoute.angleDiff(PlannedRoute.bearing(seg.a, seg.b), heading)
                        if diff < 30 || diff > 150 { return true }
                    }
                }
            }
            return false
        }
        for i in 0..<(path.count - 1) {
            let a = path[i].coordinate
            let b = path[i + 1].coordinate
            let heading = PlannedRoute.bearing(a, b)
            let samples = max(1, Int(PlannedRoute.meters(a, b) / 50))
            for s in 0...samples {
                let t = Double(s) / Double(samples)
                let point = CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t)
                if liesOnOneWay(point, heading: heading) { return true }
            }
        }
        return false
    }
}

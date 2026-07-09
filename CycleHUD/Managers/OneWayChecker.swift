import Foundation
import CoreLocation

/// Analyses a route against OpenStreetMap one-way data (via Overpass) before
/// it's ridden in reverse. One-way *streets* make a reversal illegal outright;
/// *roundabouts* are only directional — the reversed route just needs its arc
/// re-routed the legal way round, so they're reported as spans to fix rather
/// than blockers.
enum OneWayChecker {

    struct Analysis {
        /// The path lies along a one-way street somewhere — reversal illegal.
        var oneWayHit: Bool
        /// Path SEGMENT index ranges lying on roundabouts — re-route these.
        var roundaboutSpans: [ClosedRange<Int>]
    }

    /// Nil when the check couldn't run (offline, Overpass down).
    static func analyze(path: [PlannedRoute.Point]) async -> Analysis? {
        guard path.count >= 2 else { return Analysis(oneWayHit: false, roundaboutSpans: []) }
        let lats = path.map(\.lat)
        let lons = path.map(\.lon)
        let pad = 0.001                                   // ~100 m of slack
        let bbox = "\(lats.min()! - pad),\(lons.min()! - pad),\(lats.max()! + pad),\(lons.max()! + pad)"
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

        // Separate spatial hashes: one-way streets vs roundabout arcs.
        typealias Segment = (a: CLLocationCoordinate2D, b: CLLocationCoordinate2D)
        var oneWayGrid: [Int64: [Segment]] = [:]
        var roundaboutGrid: [Int64: [Segment]] = [:]
        let cell = 0.0025
        func key(_ c: CLLocationCoordinate2D, _ dLat: Int = 0, _ dLon: Int = 0) -> Int64 {
            (Int64((c.latitude / cell).rounded(.down)) + Int64(dLat)) &* 1_000_000
                &+ Int64((c.longitude / cell).rounded(.down)) &+ Int64(dLon)
        }
        for way in elements where way["type"] as? String == "way" {
            guard let geometry = way["geometry"] as? [[String: Any]], geometry.count >= 2 else { continue }
            let tags = way["tags"] as? [String: Any]
            let isRoundabout = (tags?["junction"] as? String) == "roundabout"
            var prev: CLLocationCoordinate2D?
            for node in geometry {
                guard let lat = node["lat"] as? Double, let lon = node["lon"] as? Double else { continue }
                let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if let p = prev {
                    if isRoundabout { roundaboutGrid[key(p), default: []].append((p, c)) }
                    else { oneWayGrid[key(p), default: []].append((p, c)) }
                }
                prev = c
            }
        }
        if oneWayGrid.isEmpty && roundaboutGrid.isEmpty {
            return Analysis(oneWayHit: false, roundaboutSpans: [])
        }

        // Close (<12 m) AND parallel (within 30°) = riding along it, not
        // crossing it. Long route segments sample every ~50 m so a short
        // stretch between sparse nodes can't slip through.
        func lies(on grid: [Int64: [Segment]],
                  point: CLLocationCoordinate2D, heading: Double) -> Bool {
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

        var roundaboutSegments: [Int] = []
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
                if lies(on: oneWayGrid, point: point, heading: heading) {
                    return Analysis(oneWayHit: true, roundaboutSpans: [])
                }
                if lies(on: roundaboutGrid, point: point, heading: heading) {
                    roundaboutSegments.append(i)
                    break
                }
            }
        }

        // Merge marked segments (small gaps included) into spans.
        var spans: [ClosedRange<Int>] = []
        for i in roundaboutSegments {
            if let last = spans.last, i <= last.upperBound + 3 {
                spans[spans.count - 1] = last.lowerBound...max(last.upperBound, i)
            } else {
                spans.append(i...i)
            }
        }
        return Analysis(oneWayHit: false, roundaboutSpans: spans)
    }
}

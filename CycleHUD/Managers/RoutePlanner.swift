import Foundation
import CoreLocation

/// Computes a road-following cycling path between the rider's markers using
/// the public BRouter service (OpenStreetMap data). The `trekking` profile is
/// BRouter's quiet-roads cycling profile: it prefers cycleways, lanes and
/// low-traffic roads over main roads.
///
/// Privacy: planning a route sends the tapped waypoints to brouter.de — this
/// only ever happens from the route editor, never during a ride.
enum RoutePlanner {

    enum PlanError: LocalizedError {
        case tooFewPoints
        case network(String)
        case noRoute

        var errorDescription: String? {
            switch self {
            case .tooFewPoints:
                return String(localized: "Add at least two points.", bundle: Lang.bundle)
            case .network(let m):
                return m
            case .noRoute:
                return String(localized: "No cycling route found between these points.", bundle: Lang.bundle)
            }
        }
    }

    /// Route through `waypoints` in order; when `loop` is set the path returns
    /// to the first marker. Returns the road-following path and its length.
    static func plan(through waypoints: [PlannedRoute.Point], loop: Bool) async throws
        -> (path: [PlannedRoute.Point], distanceMeters: Double) {
        var points = waypoints
        if loop, let first = points.first { points.append(first) }
        guard points.count >= 2 else { throw PlanError.tooFewPoints }

        let lonlats = points.map { "\($0.lon),\($0.lat)" }.joined(separator: "|")
        var comps = URLComponents(string: "https://brouter.de/brouter")!
        comps.queryItems = [
            URLQueryItem(name: "lonlats", value: lonlats),
            URLQueryItem(name: "profile", value: "trekking"),
            URLQueryItem(name: "alternativeidx", value: "0"),
            URLQueryItem(name: "format", value: "geojson")
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 20
        request.setValue("CycleHUD iOS (+https://cyclehud.robbo-online.uk)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PlanError.network(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // BRouter reports routing problems as plain-text error bodies.
            let text = String(data: data, encoding: .utf8) ?? ""
            throw text.isEmpty ? PlanError.noRoute : PlanError.network(String(text.prefix(120)))
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]],
              let feature = features.first,
              let geometry = feature["geometry"] as? [String: Any],
              let coords = geometry["coordinates"] as? [[Any]], coords.count >= 2 else {
            throw PlanError.noRoute
        }
        let path: [PlannedRoute.Point] = coords.compactMap { c in
            guard c.count >= 2,
                  let lon = (c[0] as? NSNumber)?.doubleValue,
                  let lat = (c[1] as? NSNumber)?.doubleValue else { return nil }
            return PlannedRoute.Point(lat: lat, lon: lon)
        }
        guard path.count >= 2 else { throw PlanError.noRoute }

        // BRouter reports the length in properties["track-length"] (a string of
        // metres); fall back to summing the polyline if it's ever absent.
        var distance = 0.0
        if let props = feature["properties"] as? [String: Any],
           let lenText = props["track-length"] as? String, let len = Double(lenText) {
            distance = len
        } else {
            for i in 0..<(path.count - 1) {
                distance += PlannedRoute.meters(path[i].coordinate, path[i + 1].coordinate)
            }
        }
        return (path, distance)
    }
}

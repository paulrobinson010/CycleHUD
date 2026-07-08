import Foundation

/// Imports a GPX file (the lingua franca of Strava / Komoot / RideWithGPS
/// route exports) as a `PlannedRoute`. Reads track points (`trkpt`) or, if
/// the file only has a planned route, route points (`rtept`), with elevation
/// when present. Very long tracks are downsampled to keep ride-time matching
/// fast.
enum GPXRouteImporter {

    static func route(from data: Data, fallbackName: String) -> PlannedRoute? {
        let parser = Parser()
        guard let (name, points) = parser.parse(data), points.count >= 2 else { return nil }

        // Downsample dense recordings (1 Hz GPX can be 10k+ points) to ~2000.
        let stride = max(1, points.count / 2000)
        var sampled = Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
        if let last = points.last, sampled.last! != last { sampled.append(last) }

        let path = sampled.map { PlannedRoute.Point(lat: $0.lat, lon: $0.lon) }
        let elevations = sampled.map(\.ele)
        let hasElevation = elevations.contains { $0 != 0 }

        var distance = 0.0
        for i in 0..<(path.count - 1) {
            distance += PlannedRoute.meters(path[i].coordinate, path[i + 1].coordinate)
        }
        guard distance > 100 else { return nil }     // not a usable route

        let isLoop = PlannedRoute.meters(path.first!.coordinate, path.last!.coordinate) < 200
        return PlannedRoute(name: name ?? fallbackName,
                            waypoints: [path.first!, path.last!],
                            loop: isLoop,
                            path: path,
                            distanceMeters: distance,
                            elevations: hasElevation ? elevations : nil)
    }

    private struct GPXPoint: Equatable {
        var lat: Double
        var lon: Double
        var ele: Double
    }

    /// Minimal streaming GPX reader: collects trkpt (preferred) and rtept
    /// coordinates plus their <ele>, and the first <name> in the file.
    private final class Parser: NSObject, XMLParserDelegate {
        private var trackPoints: [GPXPoint] = []
        private var routePoints: [GPXPoint] = []
        private var name: String?

        private var currentKind: String?         // "trkpt" | "rtept" while inside one
        private var currentPoint: GPXPoint?
        private var readingEle = false
        private var readingName = false
        private var eleText = ""
        private var nameText = ""

        func parse(_ data: Data) -> (name: String?, points: [GPXPoint])? {
            let parser = XMLParser(data: data)
            parser.delegate = self
            guard parser.parse() || !trackPoints.isEmpty || !routePoints.isEmpty else { return nil }
            let points = trackPoints.count >= 2 ? trackPoints : routePoints
            return (name, points)
        }

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch element {
            case "trkpt", "rtept":
                guard let lat = attributes["lat"].flatMap(Double.init),
                      let lon = attributes["lon"].flatMap(Double.init) else { return }
                currentKind = element
                currentPoint = GPXPoint(lat: lat, lon: lon, ele: 0)
            case "ele" where currentPoint != nil:
                readingEle = true
                eleText = ""
            case "name" where name == nil && currentPoint == nil:
                readingName = true
                nameText = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if readingEle { eleText += string }
            if readingName { nameText += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "ele":
                if readingEle, var p = currentPoint {
                    p.ele = Double(eleText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    currentPoint = p
                }
                readingEle = false
            case "name":
                if readingName {
                    let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { name = trimmed }
                }
                readingName = false
            case "trkpt", "rtept":
                if let p = currentPoint {
                    if currentKind == "trkpt" { trackPoints.append(p) }
                    else { routePoints.append(p) }
                }
                currentPoint = nil
                currentKind = nil
            default:
                break
            }
        }
    }
}

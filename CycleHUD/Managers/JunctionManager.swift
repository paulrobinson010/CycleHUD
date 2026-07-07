import Foundation
import CoreLocation

/// The next road junction ahead of the rider, resolved from OpenStreetMap data.
struct JunctionInfo: Equatable {
    /// Riding distance to the junction along the road, in metres.
    var distanceMeters: Double
    /// Compass bearings (° from north) of every road arm leaving the junction,
    /// including the arm the rider arrives on.
    var armBearings: [Double]
    /// The bearing the rider arrives at the junction on (last edge walked).
    var approachBearing: Double
    var isRoundabout: Bool
    /// OSM node id — stable identity while approaching the same junction.
    var nodeID: Int64
    /// The junction's position (used to match it against a planned route).
    var latitude: Double
    var longitude: Double
}

/// Finds the next road junction ahead using OpenStreetMap road data.
///
/// No Apple API reports "the next intersection" without a navigation route, so
/// this fetches the surrounding road network from OSM's Overpass API (one small
/// bounding-box query per ~kilometre travelled, cached in memory), map-matches
/// the rider onto the nearest heading-aligned road segment, and walks forward
/// along the way graph to the first node where three or more road edges meet.
/// Everything after the fetch is local math, so the distance counts down from
/// GPS alone between fetches.
///
/// Privacy: enabling this sends the rider's approximate location to the public
/// Overpass server — that's why it's off by default and disclosed in Settings.
final class JunctionManager: ObservableObject {

    @Published private(set) var next: JunctionInfo?

    /// Supplied by the app: current location and whether the feature is on.
    var locationProvider: (() -> CLLocation?)?
    var isEnabled: (() -> Bool)?

    // MARK: - Road graph (OSM), owned by `workQueue`

    private var nodeCoords: [Int64: CLLocationCoordinate2D] = [:]
    private var neighbors: [Int64: Set<Int64>] = [:]
    private var roundaboutNodes: Set<Int64> = []
    /// Spatial hash of edges for map-matching (~250 m cells, key = packed cell).
    private var edgeGrid: [Int64: [(a: Int64, b: Int64)]] = [:]

    /// Centre + radius (m) of the area the graph covers; refetch near the edge.
    private var coverage: (center: CLLocation, radius: Double)?
    private var fetching = false
    private var lastFetchAttempt: Date?
    private var lastCourse: Double?

    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "cyclehud.junctions", qos: .utility)

    /// Rideable roads only — footpaths and driveways (`service`) would flood the
    /// graph with junctions that aren't junctions on a ride.
    private static let highwayFilter =
        "motorway|motorway_link|trunk|trunk_link|primary|primary_link|" +
        "secondary|secondary_link|tertiary|tertiary_link|unclassified|" +
        "residential|living_street|cycleway|road"

    private static let fetchRadius: Double = 1500       // half-size of the bbox, m
    private static let refetchMargin: Double = 400      // refetch this close to the edge
    private static let matchRadius: Double = 35         // max GPS→road distance, m
    private static let headingTolerance: Double = 55    // course vs road bearing, °
    private static let maxLookahead: Double = 1200      // stop walking past this, m

    /// Begin the once-a-second tick (idempotent). Cheap while disabled.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard isEnabled?() ?? false else {
            if next != nil { next = nil }
            return
        }
        guard let loc = locationProvider?() else { return }
        // GPS course needs movement; hold the last known course briefly so the
        // countdown doesn't blank at a slow rolling stop.
        if loc.course >= 0, loc.speed > 1.0 { lastCourse = loc.course }
        let course = lastCourse
        maybeFetch(around: loc)
        workQueue.async { [weak self] in
            guard let self else { return }
            let found = course.flatMap { self.findNextJunction(from: loc, course: $0) }
            DispatchQueue.main.async {
                if self.next != found { self.next = found }
            }
        }
    }

    // MARK: - Overpass fetch

    private func maybeFetch(around loc: CLLocation) {
        if let coverage,
           loc.distance(from: coverage.center) < coverage.radius - Self.refetchMargin {
            return                                       // still well inside the graph
        }
        guard !fetching else { return }
        if let last = lastFetchAttempt, Date().timeIntervalSince(last) < 20 { return }
        fetching = true
        lastFetchAttempt = Date()

        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        let dLat = Self.fetchRadius / 111_320
        let dLon = Self.fetchRadius / (111_320 * max(0.2, cos(lat * .pi / 180)))
        let bbox = "\(lat - dLat),\(lon - dLon),\(lat + dLat),\(lon + dLon)"
        let query = "[out:json][timeout:10];way[\"highway\"~\"^(\(Self.highwayFilter))$\"](\(bbox));out geom;"

        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("CycleHUD iOS (+https://cyclehud.robbo-online.uk)",
                         forHTTPHeaderField: "User-Agent")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.fetching = false } }
            guard error == nil, let data,
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                AppLog.shared.log("Junctions: Overpass fetch failed (\(error?.localizedDescription ?? "HTTP"))")
                return                                   // keep the old graph; retry throttled
            }
            self.workQueue.async {
                self.ingest(data)
                DispatchQueue.main.async {
                    self.coverage = (loc, Self.fetchRadius)
                }
            }
        }.resume()
    }

    /// Merge an Overpass response into the road graph (on `workQueue`).
    private func ingest(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return }
        for way in elements where way["type"] as? String == "way" {
            guard let ids = way["nodes"] as? [NSNumber],
                  let geometry = way["geometry"] as? [[String: Any]],
                  ids.count == geometry.count, ids.count >= 2 else { continue }
            let tags = way["tags"] as? [String: Any]
            let isRoundabout = (tags?["junction"] as? String) == "roundabout"
            var prevID: Int64?
            for (i, num) in ids.enumerated() {
                let id = num.int64Value
                guard let lat = geometry[i]["lat"] as? Double,
                      let lon = geometry[i]["lon"] as? Double else { prevID = nil; continue }
                nodeCoords[id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if isRoundabout { roundaboutNodes.insert(id) }
                if let p = prevID, p != id, let pc = nodeCoords[p] {
                    let isNewEdge = !(neighbors[p]?.contains(id) ?? false)
                    neighbors[p, default: []].insert(id)
                    neighbors[id, default: []].insert(p)
                    if isNewEdge {
                        edgeGrid[cellKey(pc), default: []].append((a: p, b: id))
                    }
                }
                prevID = id
            }
        }
    }

    // MARK: - Matching + walking (on `workQueue`)

    private func findNextJunction(from loc: CLLocation, course: Double) -> JunctionInfo? {
        let rider = loc.coordinate
        // Nearest heading-aligned edge in the 3×3 cells around the rider.
        var best: (a: Int64, b: Int64, along: Double, offset: Double)?
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = cellKey(rider, dLat: dLat, dLon: dLon)
                for edge in edgeGrid[key] ?? [] {
                    guard let pa = nodeCoords[edge.a], let pb = nodeCoords[edge.b] else { continue }
                    // Orient the edge with travel: try a→b, then b→a.
                    for (from, to, fc, tc) in [(edge.a, edge.b, pa, pb), (edge.b, edge.a, pb, pa)] {
                        guard angleDiff(bearing(fc, tc), course) <= Self.headingTolerance else { continue }
                        let (offset, along, length) = project(rider, onto: fc, tc)
                        guard offset <= Self.matchRadius, along <= length else { continue }
                        if best == nil || offset < best!.offset {
                            best = (from, to, length - along, offset)
                        }
                    }
                }
            }
        }
        guard let match = best else { return nil }

        // Walk forward until three or more road edges meet (or a roundabout).
        var prev = match.a
        var cur = match.b
        var dist = match.along
        for _ in 0..<150 {
            guard dist <= Self.maxLookahead else { return nil }
            let nbrs = neighbors[cur] ?? []
            if nbrs.count >= 3 || roundaboutNodes.contains(cur) {
                guard let at = nodeCoords[cur], let from = nodeCoords[prev] else { return nil }
                let arms = nbrs.compactMap { nodeCoords[$0].map { n in bearing(at, n) } }
                return JunctionInfo(distanceMeters: dist,
                                    armBearings: arms,
                                    approachBearing: bearing(from, at),
                                    isRoundabout: roundaboutNodes.contains(cur),
                                    nodeID: cur,
                                    latitude: at.latitude,
                                    longitude: at.longitude)
            }
            guard let nxt = nbrs.first(where: { $0 != prev }),
                  let a = nodeCoords[cur], let b = nodeCoords[nxt] else { return nil }
            dist += meters(a, b)
            prev = cur
            cur = nxt
        }
        return nil
    }

    // MARK: - Planar geometry (fine at ride scale)

    private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (dx, dy) = delta(a, b)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// East/north metres from `a` to `b`.
    private func delta(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (Double, Double) {
        let dy = (b.latitude - a.latitude) * 111_320
        let dx = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (dx, dy)
    }

    /// Compass bearing (° from north, clockwise) from `a` to `b`.
    private func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (dx, dy) = delta(a, b)
        let deg = atan2(dx, dy) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    private func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Perpendicular offset of `p` from segment a→b, distance along it to the
    /// projection (clamped), and the segment length — all in metres.
    private func project(_ p: CLLocationCoordinate2D,
                         onto a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> (offset: Double, along: Double, length: Double) {
        let (abx, aby) = delta(a, b)
        let (apx, apy) = delta(a, p)
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return (meters(a, p), 0, 0) }
        let t = max(0, min(1, (apx * abx + apy * aby) / len2))
        let ox = apx - abx * t, oy = apy - aby * t
        return ((ox * ox + oy * oy).squareRoot(), t * len2.squareRoot(), len2.squareRoot())
    }

    /// ~250 m spatial-hash key for a coordinate (with optional cell offset).
    private func cellKey(_ c: CLLocationCoordinate2D, dLat: Int = 0, dLon: Int = 0) -> Int64 {
        let cell = 0.0025
        let x = Int64((c.longitude / cell).rounded(.down)) + Int64(dLon)
        let y = Int64((c.latitude / cell).rounded(.down)) + Int64(dLat)
        return y &* 1_000_000 &+ x
    }
}

import Foundation
import CoreLocation

/// Saved planned routes: local JSON persistence, the active-route selection,
/// and share/import of the proprietary `.cyclehudroute` file format.
final class RouteStore: ObservableObject {

    @Published private(set) var routes: [PlannedRoute] = []
    /// The route currently being followed on the ride screen (persisted).
    @Published var activeRouteID: UUID? {
        didSet {
            defaults.set(activeRouteID?.uuidString ?? "", forKey: "activeRouteID")
            joinedActiveRoute = false
            leadIn = nil
        }
    }

    /// Road path from the rider to the active route's start — the "route me
    /// to the start" leg. Fetched from BRouter when a route is picked away
    /// from the rider, refreshed if they stray off it, dropped once joined.
    @Published private(set) var leadIn: [PlannedRoute.Point]?

    /// Supplied by the app so the lead-in updater can see the rider.
    var locationProvider: (() -> CLLocation?)?

    /// Whether the rider has reached the active route yet. Until they have,
    /// the ride panel directs them to the START marker rather than treating
    /// them as "off route" from some arbitrary nearest point.
    private(set) var joinedActiveRoute = false

    var activeRoute: PlannedRoute? {
        guard let id = activeRouteID else { return nil }
        return routes.first { $0.id == id }
    }

    private let defaults = UserDefaults.standard
    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("plannedRoutes.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PlannedRoute].self, from: data) {
            routes = decoded
        }
        if let raw = defaults.string(forKey: "activeRouteID"), let id = UUID(uuidString: raw),
           routes.contains(where: { $0.id == id }) {
            activeRouteID = id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(routes) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ route: PlannedRoute) {
        routes.append(route)
        persist()
    }

    /// Replace an existing route (same id) — used by the route editor.
    func update(_ route: PlannedRoute) {
        guard let idx = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[idx] = route
        persist()
    }

    func delete(_ route: PlannedRoute) {
        routes.removeAll { $0.id == route.id }
        if activeRouteID == route.id { activeRouteID = nil }
        persist()
    }

    // MARK: - Share / import

    /// Write the route as a shareable GPX file — the format everything
    /// speaks. Waypoint markers become `<wpt>`, the path a `<trk>` with
    /// elevation, and the route's best run (the ghost) rides along as
    /// per-point `<time>` stamps — semantically a recorded best ride, so a
    /// friend who imports it races your ghost.
    func exportFile(for route: PlannedRoute) -> URL? {
        let safeName = route.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName.isEmpty ? "Route" : safeName)
            .appendingPathExtension("gpx")
        do {
            try gpxString(for: route).data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    private func gpxString(for route: PlannedRoute) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let iso = ISO8601DateFormatter()
        // Ghost timestamps: absolute times whose DELTAS are the best run
        // (anchored so the track ends when the best was set).
        let ghostBase: Date? = route.bestTimes.map { times in
            (route.bestDate ?? route.createdAt).addingTimeInterval(-(times.last ?? 0))
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\" creator=\"CycleHUD\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        out += "  <metadata><name>\(esc(route.name))</name></metadata>\n"
        for wp in route.waypoints {
            out += "  <wpt lat=\"\(String(format: "%.6f", wp.lat))\" lon=\"\(String(format: "%.6f", wp.lon))\"/>\n"
        }
        out += "  <trk><name>\(esc(route.name))</name><trkseg>\n"
        for (i, p) in route.path.enumerated() {
            out += "    <trkpt lat=\"\(String(format: "%.6f", p.lat))\" lon=\"\(String(format: "%.6f", p.lon))\">"
            if let elevations = route.elevations, i < elevations.count {
                out += "<ele>\(String(format: "%.1f", elevations[i]))</ele>"
            }
            if let ghostBase, let times = route.bestTimes, i < times.count {
                out += "<time>\(iso.string(from: ghostBase.addingTimeInterval(times[i])))</time>"
            }
            out += "</trkpt>\n"
        }
        out += "  </trkseg></trk>\n</gpx>\n"
        return out
    }

    /// Import a shared route file (from the file picker or an open-with URL):
    /// CycleHUD's own `.cyclehudroute`, or a `.gpx` from Strava / Komoot /
    /// RideWithGPS and friends. The imported route gets a fresh id so
    /// re-imports never collide.
    @discardableResult
    func importRoute(from url: URL) -> PlannedRoute? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }

        if url.pathExtension.lowercased() == "gpx" {
            let fallback = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
            guard let route = GPXRouteImporter.route(from: data, fallbackName: fallback)
            else { return nil }
            add(route)
            return route
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(RouteFile.self, from: data),
              file.cyclehudRoute == 1,
              !file.route.path.isEmpty else { return nil }
        var route = file.route
        route.id = UUID()
        add(route)
        return route
    }

    // MARK: - Lead-in to the start

    private var leadInTimer: Timer?
    private var leadInFetching = false
    private var lastLeadInFetch: Date?

    /// Begin the periodic lead-in check (idempotent; cheap while irrelevant).
    func startLeadInUpdates() {
        guard leadInTimer == nil else { return }
        leadInTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.tickLeadIn()
        }
    }

    private func tickLeadIn() {
        guard let route = activeRoute, !joinedActiveRoute,
              let loc = locationProvider?()?.coordinate else {
            if leadIn != nil { leadIn = nil }
            return
        }
        // Close to the route already: the panel's own guidance covers it.
        if let near = route.nearestPathIndex(to: loc), near.meters < 150 {
            if leadIn != nil { leadIn = nil }
            return
        }
        // Still on the current leg? Keep it — no refetch needed.
        if let leg = leadIn,
           leg.contains(where: { PlannedRoute.meters(loc, $0.coordinate) < 100 }) {
            return
        }
        guard !leadInFetching, let start = route.path.first else { return }
        if let last = lastLeadInFetch, Date().timeIntervalSince(last) < 30 { return }
        leadInFetching = true
        lastLeadInFetch = Date()
        Task { @MainActor in
            defer { leadInFetching = false }
            guard let result = try? await RoutePlanner.plan(
                through: [PlannedRoute.Point(loc), start], loop: false) else { return }
            // Only publish if it's still the situation we planned for.
            if activeRouteID == route.id, !joinedActiveRoute {
                leadIn = result.path
            }
        }
    }

    // MARK: - Ghost rider

    /// This ride's elapsed-seconds-at-each-path-point, being recorded so a
    /// complete run can become the route's best. -1 = not reached yet.
    private var ghostRun: [Double]?
    private var ghostRouteID: UUID?
    /// Elapsed when the rider first touched the route — both this run and the
    /// stored best are measured from their own first touch, so a long ride to
    /// the start doesn't poison the race.
    private var ghostRunStart: Double?

    /// Call at ride start: begin recording a candidate best run.
    func beginGhostRun() {
        ghostRun = activeRoute.map { Array(repeating: -1, count: $0.path.count) }
        ghostRouteID = activeRouteID
        ghostRunStart = nil
    }

    /// Call each tick while riding: stamp the rider's progress point.
    func recordGhost(elapsed: Double) {
        guard var run = ghostRun, let route = activeRoute, route.id == ghostRouteID,
              joinedActiveRoute, let idx = progressHint, idx < run.count else { return }
        if ghostRunStart == nil { ghostRunStart = elapsed }
        let onRoute = elapsed - (ghostRunStart ?? elapsed)
        if run[idx] < 0 {
            run[idx] = onRoute
            ghostRun = run
        }
    }

    /// Call at ride stop: a run that covered ≥90% of the route and beat the
    /// stored best becomes the new ghost.
    func endGhostRun() {
        defer { ghostRun = nil; ghostRouteID = nil; ghostRunStart = nil }
        guard let run = ghostRun, let routeID = ghostRouteID,
              let idx = routes.firstIndex(where: { $0.id == routeID }) else { return }
        let covered = run.filter { $0 >= 0 }.count
        guard Double(covered) >= 0.9 * Double(run.count), covered >= 2 else { return }
        // Dense, monotonic timeline: forward-fill unvisited points.
        var filled = run
        var last = 0.0
        for i in filled.indices {
            if filled[i] < 0 || filled[i] < last { filled[i] = last } else { last = filled[i] }
        }
        let final = filled.last ?? 0
        guard final > 60 else { return }
        let currentBest = routes[idx].bestTimes?.last
        if currentBest == nil || final < currentBest! {
            routes[idx].bestTimes = filled
            routes[idx].bestDate = Date()
            persist()
        }
    }

    /// Live race state: seconds ahead (−) or behind (+) the route's best run,
    /// measured from each run's own first touch of the route.
    func ghostDelta(elapsed: Double) -> Double? {
        guard joinedActiveRoute, let route = activeRoute,
              let best = route.bestTimes, let idx = progressHint, idx < best.count,
              let start = ghostRunStart else { return nil }
        return (elapsed - start) - best[idx]
    }

    /// Where the ghost is right now (it "set off" when this run first touched
    /// the route) — drawn as a marker on the route map.
    func ghostCoordinate(elapsed: Double) -> CLLocationCoordinate2D? {
        guard joinedActiveRoute, let route = activeRoute, let best = route.bestTimes,
              best.count == route.path.count, let start = ghostRunStart else { return nil }
        let onRoute = elapsed - start
        var i = best.firstIndex(where: { $0 > onRoute }) ?? best.count
        i = max(0, i - 1)
        return route.path[i].coordinate
    }

    // MARK: - Ride-time progress

    /// Last matched path index, kept so per-second lookups stay windowed and
    /// progress can't jump backwards where a loop crosses itself.
    private var progressHint: Int?
    private var progressRouteID: UUID?

    /// The rider's last matched path index — the junction guidance uses it to
    /// look only FORWARD along the route (an out-and-back road would otherwise
    /// match the outbound leg on the way home).
    var currentPathIndex: Int? { progressHint }

    /// Where the rider is along the active route: nearest path index, distance
    /// off the path, and metres remaining to the finish. Nil if no active route.
    /// `course` (direction of travel) disambiguates shared out-and-back roads.
    func progress(at coord: CLLocationCoordinate2D, course: Double? = nil)
        -> (index: Int, offMeters: Double, remainingMeters: Double)? {
        guard let route = activeRoute else { progressHint = nil; return nil }
        if progressRouteID != route.id {
            progressHint = nil
            progressRouteID = route.id
            joinedActiveRoute = false
        }
        // Windowed search near the last position; if the rider has strayed
        // (off route / restarted elsewhere), fall back to a whole-path scan.
        var match = route.nearestPathIndex(to: coord, hint: progressHint, course: course)
        if let m = match, m.meters > 150, progressHint != nil {
            match = route.nearestPathIndex(to: coord, hint: nil, course: course)
        }
        guard let m = match else { return nil }
        progressHint = m.index
        if m.meters < 60 { joinedActiveRoute = true }
        // Remaining distance measured from the projection, not the segment
        // start, so it ticks down smoothly along sparse straight segments.
        let remaining = max(0, route.remainingMeters(from: m.index) - m.along)
        return (m.index, m.meters, remaining)
    }
}

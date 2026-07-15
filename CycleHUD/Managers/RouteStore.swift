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
        pushToCloud()
    }

    // MARK: - iCloud sync

    /// Wired in by the app; nil = sync off.
    var cloud: CloudSync?

    /// Deleted route ids (tombstones) so a deletion on one phone doesn't get
    /// resurrected by a merge from another. Bounded.
    private var deletedIDs: [UUID] {
        get { (defaults.stringArray(forKey: "deletedRouteIDs") ?? []).compactMap(UUID.init) }
        set { defaults.set(newValue.suffix(200).map(\.uuidString), forKey: "deletedRouteIDs") }
    }

    private func recordDeletion(_ id: UUID) {
        deletedIDs = deletedIDs + [id]
    }

    private struct CloudPayload: Codable {
        var routes: [PlannedRoute]
        var deleted: [UUID]
    }

    private func pushToCloud() {
        guard let cloud else { return }
        let payload = CloudPayload(routes: routes, deleted: deletedIDs)
        if let data = try? JSONEncoder().encode(payload) {
            cloud.push(data, file: "routes.json")
        }
    }

    /// Merge the cloud copy into this device: per-route newest edit wins, a
    /// FASTER ghost always wins (two phones race each other honestly), and
    /// deletions from either side hold.
    func syncFromCloud() {
        guard let cloud else { return }
        guard let data = cloud.pull(file: "routes.json"),
              let payload = try? JSONDecoder().decode(CloudPayload.self, from: data) else {
            pushToCloud()          // nothing in the cloud yet — seed it
            return
        }
        let deleted = Set(deletedIDs).union(payload.deleted)
        deletedIDs = Array(deleted)

        var byID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        for remote in payload.routes where !deleted.contains(remote.id) {
            if let local = byID[remote.id] {
                let localStamp = local.modifiedAt ?? local.createdAt
                let remoteStamp = remote.modifiedAt ?? remote.createdAt
                var winner = remoteStamp > localStamp ? remote : local
                // Ghost merges independently: keep the faster complete run.
                let fastest = [local, remote]
                    .compactMap { r in r.bestTimes?.last.map { ($0, r) } }
                    .min { $0.0 < $1.0 }?.1
                if let fastest {
                    winner.bestTimes = fastest.bestTimes
                    winner.bestDate = fastest.bestDate
                }
                byID[remote.id] = winner
            } else {
                byID[remote.id] = remote
            }
        }
        let merged = byID.values.filter { !deleted.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        if merged != routes {
            routes = merged
            if let active = activeRouteID, !merged.contains(where: { $0.id == active }) {
                activeRouteID = nil
            }
            if let data = try? JSONEncoder().encode(routes) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        pushToCloud()
    }

    func add(_ route: PlannedRoute) {
        var stamped = route
        stamped.modifiedAt = Date()
        routes.append(stamped)
        persist()
    }

    /// Replace an existing route (same id) — used by the route editor.
    func update(_ route: PlannedRoute) {
        guard let idx = routes.firstIndex(where: { $0.id == route.id }) else { return }
        var stamped = route
        stamped.modifiedAt = Date()
        routes[idx] = stamped
        persist()
    }

    enum ReverseOutcome {
        case activated          // reversed twin saved and following
        case blockedOneWay      // route rides along a one-way street
        case rerouteFailed      // roundabout fix needed but routing failed
    }

    /// Activate a reversed twin of `route` — the same roads ridden the other
    /// way (handy when the wind colouring says the loop is better backwards).
    /// The reversal is checked against OSM first: a one-way STREET on the
    /// route blocks it outright, while ROUNDABOUTS (directional but
    /// re-navigable) get their arcs re-routed the legal way round via BRouter
    /// and spliced in. The twin is a saved route named "<name> ⇋" (reversing
    /// a "⇋" route finds its original), reusing an existing twin instead of
    /// stacking copies. Ghosts don't transfer: a best time raced the other
    /// direction. If the OSM check can't run at all (offline), the naive
    /// reversal proceeds — a guard, not a gate.
    func rideInReverse(_ route: PlannedRoute) async -> ReverseOutcome {
        let targetName = route.name.hasSuffix(" ⇋")
            ? String(route.name.dropLast(2))
            : route.name + " ⇋"
        if let existing = routes.first(where: { $0.name == targetName }) {
            await MainActor.run { activeRouteID = existing.id }
            return .activated
        }

        var path = Array(route.path.reversed())
        var elevations = route.elevations.map { Array($0.reversed()) }

        if let analysis = await OneWayChecker.analyze(path: path) {
            if analysis.oneWayHit { return .blockedOneWay }
            if !analysis.roundaboutSpans.isEmpty {
                guard let fixed = await splicingReroutes(into: path, elevations: elevations,
                                                         spans: analysis.roundaboutSpans) else {
                    return .rerouteFailed
                }
                (path, elevations) = fixed
            }
        }

        var reversed = route
        reversed.id = UUID()
        reversed.name = targetName
        reversed.path = path
        reversed.waypoints = route.waypoints.reversed()
        reversed.elevations = elevations
        var distance = 0.0
        for i in 0..<(path.count - 1) {
            distance += PlannedRoute.meters(path[i].coordinate, path[i + 1].coordinate)
        }
        reversed.distanceMeters = distance
        reversed.bestTimes = nil
        reversed.bestDate = nil
        reversed.createdAt = Date()
        await MainActor.run {
            add(reversed)
            activeRouteID = reversed.id
        }
        return .activated
    }

    /// Replace each roundabout span (expanded by a small margin) with a
    /// BRouter leg between the span's ends — the legal arc in this direction.
    /// Elevations splice too when both sides carry them; nil on any failure.
    private func splicingReroutes(into path: [PlannedRoute.Point],
                                  elevations: [Double]?,
                                  spans: [ClosedRange<Int>]) async
        -> (path: [PlannedRoute.Point], elevations: [Double]?)? {
        let margin = 3
        var merged: [(lo: Int, hi: Int)] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lo = max(0, span.lowerBound - margin)
            let hi = min(path.count - 2, span.upperBound + margin)
            if let last = merged.last, lo <= last.hi + 4 {
                merged[merged.count - 1].hi = max(last.hi, hi)
            } else {
                merged.append((lo, hi))
            }
        }
        var outPath: [PlannedRoute.Point] = []
        var outElev: [Double]? = elevations != nil ? [] : nil
        var cursor = 0
        for span in merged {
            let end = min(span.hi + 1, path.count - 1)
            guard span.lo >= cursor else { return nil }
            outPath.append(contentsOf: path[cursor..<span.lo])
            if outElev != nil, let e = elevations {
                outElev?.append(contentsOf: e[cursor..<span.lo])
            }
            guard let leg = try? await RoutePlanner.plan(
                through: [path[span.lo], path[end]], loop: false) else { return nil }
            outPath.append(contentsOf: leg.path)
            if outElev != nil {
                if let legElev = leg.elevations { outElev?.append(contentsOf: legElev) }
                else { outElev = nil }
            }
            cursor = end + 1
        }
        if cursor < path.count {
            outPath.append(contentsOf: path[cursor...])
            if outElev != nil, let e = elevations {
                outElev?.append(contentsOf: e[cursor...])
            }
        }
        if let elev = outElev, elev.count != outPath.count { outElev = nil }
        return outPath.count >= 2 ? (outPath, outElev) : nil
    }

    func delete(_ route: PlannedRoute) {
        routes.removeAll { $0.id == route.id }
        if activeRouteID == route.id { activeRouteID = nil }
        recordDeletion(route.id)
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
        completionFired = false
        completion = nil
        routeStart = nil
    }

    /// Call each tick while riding: stamp the rider's progress point.
    func recordGhost(elapsed: Double) {
        guard var run = ghostRun, let route = activeRoute, route.id == ghostRouteID,
              joinedActiveRoute, let idx = progressHint, idx < run.count else { return }
        if ghostRunStart == nil {
            ghostRunStart = elapsed
            // First touch of the route: the run's clock starts here — tell the
            // rider the race is on, and what time they're chasing.
            routeStart = RouteStart(routeName: route.name,
                                    bestSeconds: route.bestTimes?.last)
        }
        let onRoute = elapsed - (ghostRunStart ?? elapsed)
        if run[idx] < 0 {
            run[idx] = onRoute
            ghostRun = run
        }
        checkCompletion(run: run, route: route, index: idx, onRoute: onRoute)
    }

    /// Fired once when the run first touches the route — the ride screen
    /// toasts "route started" with the time to beat.
    struct RouteStart: Equatable {
        let routeName: String
        let bestSeconds: Double?    // nil = no ghost yet; this run sets it
    }

    @Published var routeStart: RouteStart?

    /// The moment the rider crosses the finish: fires once per run, with the
    /// final time and how it compares to the route's (previous) best.
    struct RouteCompletion: Equatable {
        let routeName: String
        let seconds: Double
        /// vs the previous best (negative = faster); nil = first completion.
        let deltaToBest: Double?
        let newBest: Bool
    }

    /// Set when the active route is completed mid-ride; the ride screen shows
    /// it as a toast and clears it.
    @Published var completion: RouteCompletion?
    private var completionFired = false

    private func checkCompletion(run: [Double], route: PlannedRoute, index: Int, onRoute: Double) {
        // Finish = reaching the last path points having actually ridden the
        // route (same 90% coverage bar as the ghost, and long enough that a
        // loop's shared start/finish can't fire at the first pedal stroke).
        guard !completionFired, index >= run.count - 2, onRoute > 60 else { return }
        let covered = run.filter { $0 >= 0 }.count
        guard Double(covered) >= 0.9 * Double(run.count) else { return }
        completionFired = true
        routeStart = nil     // the finish card replaces a lingering start card
        let best = route.bestTimes?.last
        completion = RouteCompletion(routeName: route.name,
                                     seconds: onRoute,
                                     deltaToBest: best.map { onRoute - $0 },
                                     newBest: best.map { onRoute < $0 } ?? true)
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
            routes[idx].modifiedAt = Date()
            persist()
        }
    }

    /// Live race state: seconds ahead (−) or behind (+) the route's best run,
    /// measured from each run's own first touch of the route. The best run's
    /// clock is interpolated at the rider's exact position along the current
    /// segment — comparing against best[idx] alone made the readout lurch at
    /// every path point (they can be hundreds of metres apart on straights).
    func ghostDelta(elapsed: Double) -> Double? {
        guard joinedActiveRoute, let route = activeRoute,
              let best = route.bestTimes, let idx = progressHint, idx < best.count,
              let start = ghostRunStart else { return nil }
        var bestHere = best[idx]
        if idx + 1 < best.count {
            bestHere += (best[idx + 1] - bestHere) * progressFrac
        }
        return (elapsed - start) - bestHere
    }

    /// Where the ghost is right now (it "set off" when this run first touched
    /// the route) — drawn as a marker on the route map. Interpolated along its
    /// current segment by time, so it glides instead of jumping point-to-point
    /// (route points can be hundreds of metres apart on straights), and its
    /// direction of travel comes along so the marker can face the right way.
    func ghostPosition(elapsed: Double) -> (coordinate: CLLocationCoordinate2D, bearing: Double?)? {
        guard joinedActiveRoute, let route = activeRoute, let best = route.bestTimes,
              best.count == route.path.count, best.count >= 2,
              let start = ghostRunStart else { return nil }
        let onRoute = elapsed - start
        var i = best.firstIndex(where: { $0 > onRoute }) ?? best.count
        i = max(0, i - 1)
        let a = route.path[i].coordinate
        guard i + 1 < route.path.count else {
            // Finished: sit on the last point, facing the way the route ends.
            return (a, PlannedRoute.bearing(route.path[i - 1].coordinate, a))
        }
        let b = route.path[i + 1].coordinate
        let t0 = best[i], t1 = best[i + 1]
        // Forward-filled best times can repeat; a zero-length window means the
        // ghost passes instantly, so sit on the segment start.
        let f = t1 > t0 ? min(1, max(0, (onRoute - t0) / (t1 - t0))) : 0
        let coord = CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * f,
            longitude: a.longitude + (b.longitude - a.longitude) * f)
        return (coord, PlannedRoute.bearing(a, b))
    }

    // MARK: - Ride-time progress

    /// Last matched path index, kept so per-second lookups stay windowed and
    /// progress can't jump backwards where a loop crosses itself.
    private var progressHint: Int?
    private var progressRouteID: UUID?
    /// How far along the current segment the rider is (0…1), from the last
    /// progress() call — lets the ghost delta interpolate between path points.
    private var progressFrac: Double = 0

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
        if m.index + 1 < route.path.count {
            let segLen = PlannedRoute.meters(route.path[m.index].coordinate,
                                             route.path[m.index + 1].coordinate)
            progressFrac = segLen > 0 ? min(1, max(0, m.along / segLen)) : 0
        } else {
            progressFrac = 0
        }
        if m.meters < 60 { joinedActiveRoute = true }
        // Remaining distance measured from the projection, not the segment
        // start, so it ticks down smoothly along sparse straight segments.
        let remaining = max(0, route.remainingMeters(from: m.index) - m.along)
        return (m.index, m.meters, remaining)
    }
}

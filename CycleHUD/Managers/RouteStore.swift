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
        }
    }

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

    func delete(_ route: PlannedRoute) {
        routes.removeAll { $0.id == route.id }
        if activeRouteID == route.id { activeRouteID = nil }
        persist()
    }

    // MARK: - Share / import (.cyclehudroute)

    /// Write the route as a shareable `.cyclehudroute` file (JSON envelope).
    func exportFile(for route: PlannedRoute) -> URL? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(RouteFile(route: route)) else { return nil }
        let safeName = route.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName.isEmpty ? "Route" : safeName)
            .appendingPathExtension("cyclehudroute")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    /// Import a shared route file (from the file picker or an open-with URL).
    /// The imported route gets a fresh id so re-imports never collide.
    @discardableResult
    func importRoute(from url: URL) -> PlannedRoute? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
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

    // MARK: - Ride-time progress

    /// Last matched path index, kept so per-second lookups stay windowed and
    /// progress can't jump backwards where a loop crosses itself.
    private var progressHint: Int?
    private var progressRouteID: UUID?

    /// Where the rider is along the active route: nearest path index, distance
    /// off the path, and metres remaining to the finish. Nil if no active route.
    func progress(at coord: CLLocationCoordinate2D)
        -> (index: Int, offMeters: Double, remainingMeters: Double)? {
        guard let route = activeRoute else { progressHint = nil; return nil }
        if progressRouteID != route.id {
            progressHint = nil
            progressRouteID = route.id
            joinedActiveRoute = false
        }
        // Windowed search near the last position; if the rider has strayed
        // (off route / restarted elsewhere), fall back to a whole-path scan.
        var match = route.nearestPathIndex(to: coord, hint: progressHint)
        if let m = match, m.meters > 150, progressHint != nil {
            match = route.nearestPathIndex(to: coord, hint: nil)
        }
        guard let m = match else { return nil }
        progressHint = m.index
        if m.meters < 60 { joinedActiveRoute = true }
        return (m.index, m.meters, route.remainingMeters(from: m.index))
    }
}

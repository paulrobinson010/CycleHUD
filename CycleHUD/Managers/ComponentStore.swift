import Foundation

/// One tracked bike part. Wear is measured against the app's lifetime
/// odometer: `baselineMeters` is the odometer reading when the part was
/// installed (or last serviced), so its wear is simply `lifetime − baseline`.
struct BikeComponent: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// Lifetime odometer at install / last service.
    var baselineMeters: Double
    /// Check-it interval in metres (nil = just track the distance).
    var serviceIntervalMeters: Double?
    /// Odometer reading when the due notification last fired, so one
    /// crossing notifies once (reset by "Mark serviced").
    var notifiedAtMeters: Double?

    func wearMeters(lifetime: Double) -> Double { max(0, lifetime - baselineMeters) }
}

/// Component wear tracking ("chain at 2,500 km — check it"): a lifetime
/// odometer fed by every finished ride, and a list of parts measured against
/// it. Stored as JSON in Documents; the odometer itself lives in defaults so
/// it survives independently of the file.
final class ComponentStore: ObservableObject {

    @Published private(set) var components: [BikeComponent] = []
    @Published private(set) var lifetimeMeters: Double = 0

    private let defaults = UserDefaults.standard
    private let lifetimeKey = "componentLifetimeMeters"
    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bike-components.json")
    }

    /// Common parts with sensible check-it intervals (km) — starting points,
    /// all editable. Sources: typical chain-checker guidance and pad/tyre
    /// wear ranges; riders adjust to their conditions.
    static let presets: [(name: String, intervalKm: Int?)] = [
        ("Chain", 3000),
        ("Cassette", 9000),
        ("Brake pads", 4000),
        ("Tyres", 5000),
        ("Bar tape", nil),
        ("Bottom bracket", 15000),
    ]

    init() {
        lifetimeMeters = defaults.double(forKey: lifetimeKey)
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([BikeComponent].self, from: data) {
            components = list
        }
    }

    /// First run only: start the odometer from the recorded ride history, so
    /// wear tracking begins with the story so far rather than at zero.
    func seedIfNeeded(historyMeters: Double) {
        guard defaults.object(forKey: lifetimeKey) == nil else { return }
        lifetimeMeters = historyMeters
        defaults.set(lifetimeMeters, forKey: lifetimeKey)
    }

    /// Call once per finished (real) ride. Advances the odometer and fires a
    /// service reminder for any part that crossed its interval on this ride.
    func recordRide(distanceMeters: Double) {
        guard distanceMeters > 0 else { return }
        lifetimeMeters += distanceMeters
        defaults.set(lifetimeMeters, forKey: lifetimeKey)
        for i in components.indices {
            guard let interval = components[i].serviceIntervalMeters else { continue }
            let wear = components[i].wearMeters(lifetime: lifetimeMeters)
            guard wear >= interval, components[i].notifiedAtMeters == nil else { continue }
            components[i].notifiedAtMeters = lifetimeMeters
            NotificationManager.shared.notifyComponentDue(name: components[i].name)
            AppLog.shared.log("Component due: \(components[i].name) at \(Int(wear / 1000)) km")
        }
        persist()
    }

    func add(name: String, intervalKm: Int?) {
        components.append(BikeComponent(
            name: name,
            baselineMeters: lifetimeMeters,
            serviceIntervalMeters: intervalKm.map { Double($0) * 1000 }))
        persist()
    }

    func update(_ component: BikeComponent) {
        guard let i = components.firstIndex(where: { $0.id == component.id }) else { return }
        components[i] = component
        persist()
    }

    /// "Mark serviced": wear starts over from the current odometer.
    func markServiced(_ component: BikeComponent) {
        guard let i = components.firstIndex(where: { $0.id == component.id }) else { return }
        components[i].baselineMeters = lifetimeMeters
        components[i].notifiedAtMeters = nil
        persist()
    }

    func remove(at offsets: IndexSet) {
        components.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(components) {
            try? data.write(to: fileURL)
        }
    }
}

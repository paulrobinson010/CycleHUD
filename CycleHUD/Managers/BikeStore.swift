import Foundation
import Combine

/// The rider's bikes, and which one they're on.
///
/// A few settings genuinely differ per bike — the wheel circumference the
/// speed sensor needs, and whether the road-oriented features (crash
/// detection, junctions) suit it — so each profile owns them, and selecting a
/// bike applies them to the live settings. Changing one of those settings
/// while a bike is selected writes back into that bike, so the profile is
/// always what the rider last chose for it.
///
/// Each bike also owns its odometer and component list: a mountain-bike
/// drivetrain wears far faster than a road one, and mixing the two made both
/// sets of numbers meaningless.
final class BikeStore: ObservableObject {

    @Published private(set) var bikes: [BikeProfile] = []
    @Published private(set) var activeBikeID: UUID?

    var active: BikeProfile? {
        bikes.first { $0.id == activeBikeID } ?? bikes.first
    }

    /// Wired by the app: never auto-switch bikes mid-ride.
    var rideActive: (() -> Bool)?

    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private let activeKey = "activeBikeID"
    /// True while a profile is being applied to `settings`, so the write-back
    /// subscriptions don't immediately store what they just received.
    private var applyingProfile = false
    private var subs: [AnyCancellable] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bikes.json")
    }

    /// Common parts with sensible check-it intervals (km) — starting points,
    /// all editable. Mud and grit eat a mountain-bike drivetrain far faster,
    /// which is exactly why each bike counts its own distance.
    static let presets: [(name: String, intervalKm: Int?)] = [
        ("Chain", 3000),
        ("Cassette", 9000),
        ("Brake pads", 4000),
        ("Tyres", 5000),
        ("Bar tape", nil),
        ("Bottom bracket", 15000),
    ]

    init(settings: AppSettings) {
        self.settings = settings
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([BikeProfile].self, from: data) {
            bikes = list
        }
        if let raw = defaults.string(forKey: activeKey), let id = UUID(uuidString: raw) {
            activeBikeID = id
        }
        observeSettings()
    }

    // MARK: - Settings write-through

    /// Keep the active profile in step with the settings it owns: if the rider
    /// edits the wheel size (or the crash/junction toggles) while a bike is
    /// selected, that's a statement about THAT bike.
    private func observeSettings() {
        settings.$wheelCircumferenceMM
            .dropFirst()
            .sink { [weak self] mm in self?.storeToActive { $0.wheelCircumferenceMM = mm } }
            .store(in: &subs)
        settings.$crashDetectionEnabled
            .dropFirst()
            .sink { [weak self] on in self?.storeToActive { $0.crashDetectionEnabled = on } }
            .store(in: &subs)
        settings.$junctionsEnabled
            .dropFirst()
            .sink { [weak self] on in self?.storeToActive { $0.junctionsEnabled = on } }
            .store(in: &subs)
    }

    private func storeToActive(_ edit: (inout BikeProfile) -> Void) {
        guard !applyingProfile, let id = active?.id,
              let i = bikes.firstIndex(where: { $0.id == id }) else { return }
        edit(&bikes[i])
        persist()
    }

    /// Push a profile's own settings into the live settings.
    private func apply(_ bike: BikeProfile) {
        applyingProfile = true
        settings.wheelCircumferenceMM = bike.wheelCircumferenceMM
        settings.crashDetectionEnabled = bike.crashDetectionEnabled
        settings.junctionsEnabled = bike.junctionsEnabled
        applyingProfile = false
    }

    // MARK: - Lifecycle

    /// First run: build one bike from what the app already knows — the
    /// current wheel size and feature toggles, the existing component list,
    /// and an odometer seeded from recorded ride history — so nothing is lost
    /// and wear tracking continues uninterrupted.
    func migrateIfNeeded(historyMeters: Double) {
        guard bikes.isEmpty else {
            if activeBikeID == nil { select(bikes[0].id) }
            return
        }
        let legacyKey = "componentLifetimeMeters"
        let legacyOdometer = defaults.object(forKey: legacyKey) != nil
            ? defaults.double(forKey: legacyKey) : historyMeters
        let legacyFile = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bike-components.json")
        let legacyComponents = (try? Data(contentsOf: legacyFile))
            .flatMap { try? JSONDecoder().decode([BikeComponent].self, from: $0) } ?? []

        let first = BikeProfile(name: String(localized: "My bike", bundle: Lang.bundle),
                                kind: .road,
                                wheelCircumferenceMM: settings.wheelCircumferenceMM,
                                crashDetectionEnabled: settings.crashDetectionEnabled,
                                junctionsEnabled: settings.junctionsEnabled,
                                odometerMeters: legacyOdometer,
                                components: legacyComponents)
        bikes = [first]
        activeBikeID = first.id
        defaults.set(first.id.uuidString, forKey: activeKey)
        persist()
        AppLog.shared.log("Bikes: migrated to profiles (\(Int(legacyOdometer / 1000)) km, \(legacyComponents.count) components)")
    }

    func select(_ id: UUID) {
        guard let bike = bikes.first(where: { $0.id == id }) else { return }
        activeBikeID = id
        defaults.set(id.uuidString, forKey: activeKey)
        apply(bike)
        AppLog.shared.log("Bike selected: \(bike.name)")
    }

    /// A saved sensor connected: if exactly one bike claims it, that's the
    /// bike the rider is on. Never mid-ride — the ride's numbers (and its
    /// wear) belong to the bike it started on.
    func sensorConnected(_ sensorID: UUID) {
        guard !(rideActive?() ?? false) else { return }
        let claiming = bikes.filter { $0.sensorIDs.contains(sensorID) }
        guard claiming.count == 1, let bike = claiming.first,
              bike.id != active?.id else { return }
        AppLog.shared.log("Bike auto-selected from sensor: \(bike.name)")
        select(bike.id)
    }

    // MARK: - Bikes

    func add(name: String, kind: BikeKind) -> UUID {
        let bike = BikeProfile(name: name, kind: kind,
                               wheelCircumferenceMM: kind.defaultWheelMM,
                               crashDetectionEnabled: kind.suitsRoadFeatures
                                   && settings.crashDetectionEnabled,
                               junctionsEnabled: kind.suitsRoadFeatures
                                   && settings.junctionsEnabled)
        bikes.append(bike)
        persist()
        return bike.id
    }

    func update(_ bike: BikeProfile) {
        guard let i = bikes.firstIndex(where: { $0.id == bike.id }) else { return }
        bikes[i] = bike
        persist()
        if bike.id == active?.id { apply(bike) }
    }

    /// Remove a bike (and its component history). The last bike can't be
    /// removed — the app always has a bike to record against.
    func remove(_ id: UUID) {
        guard bikes.count > 1 else { return }
        bikes.removeAll { $0.id == id }
        persist()
        if activeBikeID == id, let first = bikes.first { select(first.id) }
    }

    /// Which bike (if any) a sensor is currently assigned to.
    func bikeOwning(sensor id: UUID) -> BikeProfile? {
        bikes.first { $0.sensorIDs.contains(id) }
    }

    /// Assign a sensor to one bike, clearing it from any other (a wheel magnet
    /// lives on exactly one bike).
    func assign(sensor sensorID: UUID, to bikeID: UUID?) {
        for i in bikes.indices {
            bikes[i].sensorIDs.removeAll { $0 == sensorID }
            if bikes[i].id == bikeID { bikes[i].sensorIDs.append(sensorID) }
        }
        persist()
    }

    // MARK: - Rides and wear

    /// Call once per finished (real) ride: advance that bike's odometer and
    /// fire a service reminder for any part that crossed its interval.
    func recordRide(distanceMeters: Double, bikeID: UUID?) {
        guard distanceMeters > 0,
              let i = bikes.firstIndex(where: { $0.id == (bikeID ?? active?.id) }) else { return }
        bikes[i].odometerMeters += distanceMeters
        let odometer = bikes[i].odometerMeters
        let bikeName = bikes[i].name
        for c in bikes[i].components.indices {
            guard let interval = bikes[i].components[c].serviceIntervalMeters else { continue }
            let wear = bikes[i].components[c].wearMeters(lifetime: odometer)
            guard wear >= interval, bikes[i].components[c].notifiedAtMeters == nil else { continue }
            bikes[i].components[c].notifiedAtMeters = odometer
            NotificationManager.shared.notifyComponentDue(
                name: bikes[i].components[c].name, bike: bikeName)
            AppLog.shared.log("Component due: \(bikes[i].components[c].name) on \(bikeName) at \(Int(wear / 1000)) km")
        }
        persist()
    }

    // MARK: - Components (scoped to a bike)

    func addComponent(name: String, intervalKm: Int?, to bikeID: UUID) {
        guard let i = bikes.firstIndex(where: { $0.id == bikeID }) else { return }
        bikes[i].components.append(BikeComponent(
            name: name,
            baselineMeters: bikes[i].odometerMeters,
            serviceIntervalMeters: intervalKm.map { Double($0) * 1000 }))
        persist()
    }

    func updateComponent(_ component: BikeComponent, on bikeID: UUID) {
        guard let i = bikes.firstIndex(where: { $0.id == bikeID }),
              let c = bikes[i].components.firstIndex(where: { $0.id == component.id }) else { return }
        bikes[i].components[c] = component
        persist()
    }

    /// "Mark serviced": wear starts over from this bike's current odometer.
    func markServiced(_ component: BikeComponent, on bikeID: UUID) {
        guard let i = bikes.firstIndex(where: { $0.id == bikeID }),
              let c = bikes[i].components.firstIndex(where: { $0.id == component.id }) else { return }
        bikes[i].components[c].baselineMeters = bikes[i].odometerMeters
        bikes[i].components[c].notifiedAtMeters = nil
        persist()
    }

    func removeComponents(at offsets: IndexSet, on bikeID: UUID) {
        guard let i = bikes.firstIndex(where: { $0.id == bikeID }) else { return }
        bikes[i].components.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bikes) {
            try? data.write(to: fileURL)
        }
    }
}

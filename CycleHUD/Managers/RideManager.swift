import Foundation
import CoreLocation
import CoreMotion
import Combine
import UIKit

enum RideStatus: Equatable {
    case idle          // no ride in progress
    case running       // actively recording
    case paused        // manually paused by the rider
    case autoPaused    // automatically paused (stopped at lights, etc.)

    var isActive: Bool { self != .idle }
    var isMoving: Bool { self == .running }
}

/// Drives the ride: distance, moving time, current/average speed, and the
/// auto-pause / auto-resume logic. Reads live speed from the wheel sensor when
/// available, otherwise GPS.
final class RideManager: ObservableObject {

    // Movement threshold: "below 1 km/h" counts as stopped.
    private let movingThresholdMps = 1.0 / 3.6
    private let autoPauseDelay: TimeInterval = 5.0     // stopped this long ⇒ auto-pause
    private let autoResumeDelay: TimeInterval = 1.0    // moving this long ⇒ auto-resume

    @Published private(set) var status: RideStatus = .idle
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var movingTimeSeconds: Double = 0
    @Published private(set) var currentSpeedMps: Double = 0
    @Published private(set) var elevationGainMeters: Double = 0   // total ascent this ride
    @Published private(set) var caloriesKcal: Double = 0
    @Published private(set) var currentHeartRate: Int?            // from the Watch, if present

    var averageSpeedMps: Double {
        movingTimeSeconds > 0 ? distanceMeters / movingTimeSeconds : 0
    }

    private let ble: BluetoothManager
    private let location: LocationManager
    private let settings: AppSettings
    private let health: HealthKitManager
    private let watch: WatchConnectivityManager

    // Recorded GPS track + body metrics for the workout / calories.
    private var route: [CLLocation] = []
    private var rideStart: Date?
    private var bodyWeightKg = 75.0
    private var bodyAgeYears = 40.0
    private var bodyIsFemale = false
    private var mirrorTick = 0

    private var ticker: Timer?
    private var lastTick: Date?
    private var stationarySeconds: Double = 0
    private var movingSeconds: Double = 0
    private var lastGatedLocation: CLLocation?

    // Elevation: prefer the barometer (accurate climb); fall back to GPS altitude.
    private let altimeter = CMAltimeter()
    private var usingBarometer = false
    private var lastRelativeAltitude: Double?
    private var lastGpsAltitude: Double?

    init(ble: BluetoothManager, location: LocationManager, settings: AppSettings,
         health: HealthKitManager, watch: WatchConnectivityManager) {
        self.ble = ble
        self.location = location
        self.settings = settings
        self.health = health
        self.watch = watch
        self.location.onLocation = { [weak self] loc in self?.accumulate(loc) }
        self.ble.onDemoFinished = { [weak self] in self?.stopDemo() }
        self.ble.onNewCar = { [weak self] in self?.watch.sendNewCarHaptic() }
    }

    // MARK: - Controls

    func start() {
        guard status == .idle else { return }
        stopDemo()
        distanceMeters = 0
        movingTimeSeconds = 0
        elevationGainMeters = 0
        caloriesKcal = 0
        currentHeartRate = nil
        route = []
        rideStart = Date()
        stationarySeconds = 0
        movingSeconds = 0
        lastGatedLocation = nil
        lastGpsAltitude = nil
        lastRelativeAltitude = nil
        lastTick = Date()
        loadBodyMetrics()
        status = .running
        location.start(background: true)
        startTicker()
        startAltimeter()
        applyScreenLock()
    }

    /// Snapshot the body metrics used for HR-based calories (from Health, with
    /// the Settings weight as fallback).
    private func loadBodyMetrics() {
        bodyAgeYears = health.ageYears() ?? 40
        bodyIsFemale = health.isFemale() ?? false
        bodyWeightKg = settings.riderWeightKg
        Task { [weak self] in
            if let kg = await self?.health.latestWeightKg() {
                await MainActor.run { self?.bodyWeightKg = kg }
            }
        }
    }

    /// Toggle between running and a manual pause.
    func togglePause() {
        switch status {
        case .running: status = .paused
        case .paused, .autoPaused: status = .running
        case .idle: break
        }
        stationarySeconds = 0
        movingSeconds = 0
    }

    func stop() {
        let start = rideStart ?? Date()
        let end = Date()
        let savedDistance = distanceMeters
        let savedCalories = caloriesKcal
        let savedRoute = route

        status = .idle
        stopTicker()
        stopAltimeter()
        location.stop(background: true)
        currentSpeedMps = 0
        UIApplication.shared.isIdleTimerDisabled = false
        sendMirror()

        // Save a cycling workout for any ride worth keeping.
        if savedDistance >= 50 {
            Task { [health] in
                await health.saveRide(start: start, end: end,
                                      distanceMeters: savedDistance,
                                      calories: savedCalories, route: savedRoute)
            }
        }

        route = []
        caloriesKcal = 0
        currentHeartRate = nil
        rideStart = nil
    }

    // MARK: - Demo metrics
    //
    // Simulates a realistic in-progress ride for the radar demo: speed wobbles
    // around a base, distance integrates from it over ticking time (so avg =
    // distance / time stays consistent), and ascent slowly accrues.

    @Published private(set) var demoActive = false
    @Published private(set) var demoPaused = false
    private var demoTimer: Timer?
    private var demoBaseSpeedMps = 0.0

    func startDemo() {
        guard status == .idle, !demoActive else { return }
        demoActive = true
        demoPaused = false
        let avg = Double.random(in: 6.4...8.3)              // ~23–30 km/h base
        let elapsed = Double(Int.random(in: 900...2700))    // seed: 15–45 min in
        demoBaseSpeedMps = avg
        movingTimeSeconds = elapsed
        distanceMeters = avg * elapsed                      // so avg matches exactly
        elevationGainMeters = Double(Int.random(in: 60...420))
        currentSpeedMps = avg
        lastTick = Date()
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.demoTick()
        }
    }

    func stopDemo() {
        guard demoActive else { return }
        demoActive = false
        demoPaused = false
        demoTimer?.invalidate()
        demoTimer = nil
        distanceMeters = 0
        movingTimeSeconds = 0
        elevationGainMeters = 0
        currentSpeedMps = 0
    }

    /// Pause/resume the demo (mirrors a manual pause on a real ride).
    func toggleDemoPause() {
        guard demoActive else { return }
        demoPaused.toggle()
        ble.setDemoPaused(demoPaused)
        lastTick = Date()
    }

    private func demoTick() {
        let now = Date()
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0.5
        lastTick = now
        guard !demoPaused else { return }
        movingTimeSeconds += dt
        let wobble = sin(movingTimeSeconds / 6.0) * 1.2 + Double.random(in: -0.4...0.4)
        currentSpeedMps = max(0, demoBaseSpeedMps + wobble)
        distanceMeters += currentSpeedMps * dt
        if Double.random(in: 0...1) < 0.5 {
            elevationGainMeters += Double.random(in: 0...0.7)
        }
    }

    // MARK: - Elevation (barometer)

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        usingBarometer = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let alt = data.relativeAltitude.doubleValue   // metres relative to start
            defer { self.lastRelativeAltitude = alt }
            guard self.status == .running, let last = self.lastRelativeAltitude else { return }
            let delta = alt - last
            if delta > 0 { self.elevationGainMeters += delta }
        }
    }

    private func stopAltimeter() {
        if usingBarometer { altimeter.stopRelativeAltitudeUpdates() }
        usingBarometer = false
    }

    // MARK: - Ticker

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let now = Date()
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now

        currentSpeedMps = resolvedSpeed()
        currentHeartRate = watch.freshHeartRate()

        switch status {
        case .running:
            movingTimeSeconds += dt
            accumulateCalories(dt: dt)
            updateAutoPause(dt: dt)
        case .autoPaused:
            updateAutoResume(dt: dt)
        case .paused, .idle:
            break
        }

        // Mirror to the Watch at ~2 Hz.
        mirrorTick += 1
        if mirrorTick % 2 == 0 { sendMirror() }
    }

    /// HR-based calories (only when the Watch is supplying a heart rate).
    private func accumulateCalories(dt: Double) {
        guard let hr = currentHeartRate, hr > 0 else { return }
        let perMinute = Calories.kcalPerMinute(heartRate: Double(hr), weightKg: bodyWeightKg,
                                               ageYears: bodyAgeYears, isFemale: bodyIsFemale)
        caloriesKcal += perMinute * (dt / 60.0)
    }

    private func sendMirror() {
        let levels = ble.threats.map { $0.level.rawValue }
        let nearest = ble.threats.map { Int($0.distanceMeters.rounded()) }.min()
        watch.sendMirror(speedMps: currentSpeedMps,
                         distanceMeters: distanceMeters,
                         rideStatusRaw: statusRaw,
                         threatLevel: levels.max() ?? -1,
                         nearestThreatMeters: nearest)
    }

    private var statusRaw: String {
        switch status {
        case .idle: return "idle"
        case .running: return "running"
        case .paused: return "paused"
        case .autoPaused: return "autoPaused"
        }
    }

    /// Live speed source: the wheel sensor is primary (responsive, accurate when
    /// the wheel circumference is set), but a confident GPS reading that
    /// disagrees sharply overrides it — a big gap usually means the wheel size is
    /// wrong or the sensor glitched, and GPS is the absolute reference.
    private func resolvedSpeed() -> Double {
        guard let sensor = ble.freshSensorSpeed() else { return location.speedMps }
        guard location.hasFix else { return sensor }
        let gps = location.speedMps
        // Only arbitrate when GPS is actually moving (it's noisy near standstill).
        if gps > 1.5 {
            let disagreement = abs(sensor - gps)
            if disagreement > max(2.0, 0.5 * gps) { return gps }
        }
        return sensor
    }

    private func updateAutoPause(dt: Double) {
        guard settings.autoPauseEnabled else { return }
        if currentSpeedMps < movingThresholdMps {
            stationarySeconds += dt
            if stationarySeconds >= autoPauseDelay {
                status = .autoPaused
                movingSeconds = 0
            }
        } else {
            stationarySeconds = 0
        }
    }

    private func updateAutoResume(dt: Double) {
        if currentSpeedMps >= movingThresholdMps {
            movingSeconds += dt
            if movingSeconds >= autoResumeDelay {
                status = .running
                stationarySeconds = 0
            }
        } else {
            movingSeconds = 0
        }
    }

    // MARK: - Distance integration

    private func accumulate(_ loc: CLLocation) {
        guard status == .running else {
            // Keep a reference point so we don't count the paused gap as distance.
            lastGatedLocation = nil
            lastGpsAltitude = nil
            return
        }
        defer { lastGatedLocation = loc }

        // Record reasonably-accurate fixes for the saved workout route.
        if loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 30 {
            route.append(loc)
        }

        let step = lastGatedLocation.map { loc.distance(from: $0) } ?? 0
        // Ignore GPS jitter while essentially stationary.
        if step >= 0.5 {
            distanceMeters += step
        }

        // Fallback ascent from GPS altitude when no barometer is available.
        if !usingBarometer, loc.verticalAccuracy > 0 {
            if let lastAlt = lastGpsAltitude {
                let dAlt = loc.altitude - lastAlt
                if dAlt > 1.0 { elevationGainMeters += dAlt }   // 1 m threshold filters noise
            }
            lastGpsAltitude = loc.altitude
        }
    }

    private func applyScreenLock() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
    }
}

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

    var averageSpeedMps: Double {
        movingTimeSeconds > 0 ? distanceMeters / movingTimeSeconds : 0
    }

    private let ble: BluetoothManager
    private let location: LocationManager
    private let settings: AppSettings

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

    init(ble: BluetoothManager, location: LocationManager, settings: AppSettings) {
        self.ble = ble
        self.location = location
        self.settings = settings
        self.location.onLocation = { [weak self] loc in self?.accumulate(loc) }
        self.ble.onDemoFinished = { [weak self] in self?.stopDemo() }
    }

    // MARK: - Controls

    func start() {
        guard status == .idle else { return }
        stopDemo()
        distanceMeters = 0
        movingTimeSeconds = 0
        elevationGainMeters = 0
        stationarySeconds = 0
        movingSeconds = 0
        lastGatedLocation = nil
        lastGpsAltitude = nil
        lastRelativeAltitude = nil
        lastTick = Date()
        status = .running
        location.start(background: true)
        startTicker()
        startAltimeter()
        applyScreenLock()
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
        status = .idle
        stopTicker()
        stopAltimeter()
        location.stop(background: true)
        currentSpeedMps = 0
        UIApplication.shared.isIdleTimerDisabled = false
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

        switch status {
        case .running:
            movingTimeSeconds += dt
            updateAutoPause(dt: dt)
        case .autoPaused:
            updateAutoResume(dt: dt)
        case .paused, .idle:
            break
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

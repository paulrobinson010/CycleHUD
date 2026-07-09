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

/// Persisted so an in-progress ride survives the app being killed (e.g. phone
/// pocketed while carrying the bike). The ride only truly ends on Stop.
private struct RideSnapshot: Codable {
    var statusRaw: String
    var distance: Double
    var movingTime: Double
    var elevation: Double
    var calories: Double
    var startEpoch: Double
}

private struct RoutePoint: Codable {
    var lat: Double, lon: Double, alt: Double
    var hAcc: Double, vAcc: Double, course: Double, speed: Double, t: Double
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
    @Published private(set) var currentGradientPercent: Double?   // live road gradient (%)
    @Published private(set) var maxSpeedMps: Double = 0           // peak speed this ride
    @Published private(set) var laps: [Lap] = []                  // manually-marked splits
    @Published private(set) var currentLapTimeSeconds: Double = 0 // elapsed in the current lap

    var averageSpeedMps: Double {
        movingTimeSeconds > 0 ? distanceMeters / movingTimeSeconds : 0
    }

    /// Set when a ride finishes, to present the end-of-ride summary sheet.
    /// Cleared when the sheet is dismissed.
    @Published var finishedSummary: RideSummary?

    /// Whether the end-of-ride summary should offer the 1–10 effort prompt:
    /// workout saving is on, and the OS supports Apple's effort score (iOS 18+).
    var canPromptEffort: Bool { settings.saveWorkouts && health.supportsEffortScore }

    /// Wired in by the app: route following (turn cues + ghost rider) reads
    /// the rider's progress from here.
    var routes: RouteStore?

    /// Rider's perceived effort from the end-of-ride prompt → Apple Health.
    func recordEffort(_ score: Int) { health.recordEffort(score: score) }

    private let ble: BluetoothManager
    private let location: LocationManager
    private let settings: AppSettings
    private let health: HealthKitManager
    private let watch: WatchConnectivityManager
    private let history: RideHistory
    private let sos: SOSManager
    private let crash = CrashDetector()
    /// When a big impact was detected; the SOS fires only if the rider stops
    /// (< 1 km/h) within `crashConfirmWindow` of it — a hard bump you ride
    /// through is not a crash.
    private var crashCandidateAt: Date?
    private let crashConfirmWindow: TimeInterval = 5
    private var crashSettingSub: AnyCancellable?

    // Recorded GPS track + body metrics for the workout / calories.
    private var route: [CLLocation] = []
    /// Locations where a new vehicle was detected behind the rider, overlaid on
    /// the ride summary map. Capped so a very busy ride can't grow unbounded.
    private var radarPoints: [Coord] = []

    // Per-vehicle approach traces (distance/speed from detection to pass), for
    // reviewing close or fast passes after the ride.
    private var passes: [VehiclePass] = []
    private var openPass: (start: Date, lat: Double?, lon: Double?, samples: [PassSample])?
    private var lastPassFrameSeen: Date?     // de-dupes 4 Hz ticks to ~2 Hz frames
    private var lastThreatPresentAt: Date?   // grace period before closing a pass

    private var rideStart: Date?
    private var bodyWeightKg = 75.0
    private var bodyAgeYears = 40.0
    private var bodyIsFemale = false
    private var lastCalorieAscent = 0.0   // ascent already counted toward calories
    private var saveTick = 0
    private var radarWasConnected = false   // edge-detect radar drop-out for the Watch alert

    // Heart-rate accumulation for the ride summary.
    private var hrSum = 0.0
    private var powerSum = 0.0          // watt-seconds while running
    private var powerTime = 0.0
    private var hrCount = 0
    private var hrMax = 0

    // Crash/termination recovery
    private let snapshotKey = "activeRideSnapshot"
    private var routeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("active-route.json")
    }

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
    /// Current altitude relative to the ride's start (climbs +, descents −), fed
    /// into the elevation graph. Barometer when available, GPS otherwise.
    private var relativeAltitude: Double = 0
    private var firstGpsAltitude: Double?

    // Periodic speed/HR/elevation samples for the summary graphs.
    private var track: [TrackSample] = []
    private var lastTrackAt: Date?

    // Rolling (distance, altitude) buffer for the live gradient, computed over a
    // short trailing window so the reading is stable but responsive.
    private var gradientWindow: [(dist: Double, alt: Double)] = []

    // Lap splits: where (in moving time / distance) the current lap began.
    private var lapStartMovingTime: Double = 0
    private var lapStartDistance: Double = 0

    init(ble: BluetoothManager, location: LocationManager, settings: AppSettings,
         health: HealthKitManager, watch: WatchConnectivityManager, history: RideHistory,
         sos: SOSManager) {
        self.ble = ble
        self.location = location
        self.settings = settings
        self.health = health
        self.watch = watch
        self.history = history
        self.sos = sos
        // An impact alone is just a candidate — road bumps spike the
        // accelerometer too. The SOS only fires if the rider actually comes to
        // a stop within a few seconds of the impact (see tick()).
        self.crash.onCrash = { [weak self] in
            guard let self, self.status != .idle, !self.demoActive,
                  self.settings.crashDetectionEnabled else { return }
            self.crashCandidateAt = Date()
            AppLog.shared.log("Crash candidate (impact) — awaiting stop confirmation")
        }
        // Honour the setting live: switching crash detection off mid-ride must
        // stop it firing (and switching it on mid-ride must arm it).
        self.crashSettingSub = settings.$crashDetectionEnabled.sink { [weak self] enabled in
            guard let self, self.status != .idle else { return }
            if enabled {
                self.crash.start()
            } else {
                self.crash.stop()
                self.crashCandidateAt = nil
            }
        }
        self.location.onLocation = { [weak self] loc in self?.accumulate(loc) }
        self.ble.onDemoFinished = { [weak self] in self?.demoFramesFinished() }
        self.ble.onNewCar = { [weak self] in
            guard let self else { return }
            if self.settings.hapticsEnabled { self.watch.sendNewCarHaptic() }
            self.recordRadarDetection()
        }
        // Only alert (beep + wrist haptic) while actually riding or in the demo —
        // not while idle with the radar connected.
        self.ble.alertsAllowed = { [weak self] in self?.alertsLive ?? false }
        restoreActiveRide()
    }

    // MARK: - Controls

    func start() {
        guard status == .idle else { return }
        stopDemo()
        ble.stopScan()             // never leave a power-hungry BLE scan running on a ride
        ble.cancelSensorMonitor()  // a new ride — no "sensors left on" reminder needed
        distanceMeters = 0
        movingTimeSeconds = 0
        elevationGainMeters = 0
        caloriesKcal = 0
        currentHeartRate = nil
        hrSum = 0; hrCount = 0; hrMax = 0
        powerSum = 0; powerTime = 0
        lastCalorieAscent = 0
        route = []
        radarPoints = []
        passes = []
        openPass = nil
        lastPassFrameSeen = nil
        lastThreatPresentAt = nil
        rideStart = Date()
        stationarySeconds = 0
        movingSeconds = 0
        lastTurnCueIndex = -1
        routes?.beginGhostRun()
        lastGatedLocation = nil
        lastGpsAltitude = nil
        lastRelativeAltitude = nil
        relativeAltitude = 0
        firstGpsAltitude = nil
        track = []
        lastTrackAt = nil
        gradientWindow = []
        currentGradientPercent = nil
        maxSpeedMps = 0
        laps = []
        currentLapTimeSeconds = 0
        lapStartMovingTime = 0
        lapStartDistance = 0
        lastTick = Date()
        loadBodyMetrics()
        status = .running
        location.setMode(.recording)
        startTicker()
        startAltimeter()
        if settings.crashDetectionEnabled { crash.start() }
        crashCandidateAt = nil
        applyScreenLock()
        try? FileManager.default.removeItem(at: routeURL)
        persistSnapshot()
        AppLog.shared.log("Ride START")
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

    /// Close the current lap and start a new one. Ignored when idle, in the demo,
    /// or on an accidental double-tap (a lap under a second long).
    func markLap() {
        guard status != .idle, !demoActive else { return }
        let duration = movingTimeSeconds - lapStartMovingTime
        guard duration >= 1 else { return }
        laps.append(Lap(id: UUID(), number: laps.count + 1, durationSeconds: duration,
                        distanceMeters: distanceMeters - lapStartDistance))
        lapStartMovingTime = movingTimeSeconds
        lapStartDistance = distanceMeters
        currentLapTimeSeconds = 0
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
        persistSnapshot()
    }

    func stop() {
        AppLog.shared.log("Ride STOP (user) dist=\(Int(distanceMeters))m time=\(Int(movingTimeSeconds))s")
        routes?.endGhostRun()                    // a complete run may become the ghost
        finalizeOpenPass()                       // capture a pass in progress at stop
        // If the rider marked any laps, close the final partial lap too so the
        // splits cover the whole ride.
        if !laps.isEmpty {
            let duration = movingTimeSeconds - lapStartMovingTime
            if duration >= 1 {
                laps.append(Lap(id: UUID(), number: laps.count + 1, durationSeconds: duration,
                                distanceMeters: distanceMeters - lapStartDistance))
            }
        }
        let savedLaps = laps
        let start = rideStart ?? Date()
        let end = Date()
        let savedDistance = distanceMeters
        let savedTime = movingTimeSeconds
        let savedAscent = elevationGainMeters
        let savedCalories = caloriesKcal
        let savedRoute = route
        let savedRadarPoints = radarPoints
        let savedPasses = passes
        let savedTrack = downsampledTrack(track)

        status = .idle
        stopTicker()
        stopAltimeter()
        crash.stop()
        crashCandidateAt = nil
        location.setMode(.idle)        // back to low-power once the ride ends
        // Reset all live metrics to a clean slate (the ride is saved to Health
        // below), THEN mirror the zeros so the Watch clears too — otherwise it
        // keeps showing the last ride's distance until a new one starts.
        currentSpeedMps = 0
        distanceMeters = 0
        movingTimeSeconds = 0
        elevationGainMeters = 0
        caloriesKcal = 0
        currentHeartRate = nil
        currentGradientPercent = nil
        gradientWindow = []
        UIApplication.shared.isIdleTimerDisabled = false
        sendMirror()

        // Record any ride worth keeping: local history + end-of-ride summary, and
        // the authoritative Apple Health workout.
        if savedDistance >= 50 {
            let routeDown = downsampledRoute(savedRoute)
            let points = routeDown.points
            let summary = RideSummary(id: UUID(), date: start, distanceMeters: savedDistance,
                                      movingTimeSeconds: savedTime, elevationGainMeters: savedAscent,
                                      caloriesKcal: savedCalories,
                                      averageHeartRate: hrCount > 0 ? Int((hrSum / Double(hrCount)).rounded()) : nil,
                                      maxHeartRate: hrMax > 0 ? hrMax : nil,
                                      routePoints: points.isEmpty ? nil : points,
                                      routeSpeeds: routeDown.speeds.isEmpty ? nil : routeDown.speeds,
                                      radarPoints: savedRadarPoints.isEmpty ? nil : savedRadarPoints,
                                      passes: savedPasses.isEmpty ? nil : savedPasses,
                                      track: savedTrack.isEmpty ? nil : savedTrack,
                                      laps: savedLaps.isEmpty ? nil : savedLaps,
                                      averagePower: powerTime > 60
                                          ? Int((powerSum / powerTime).rounded()) : nil)
            history.add(summary)
            finishedSummary = summary
            if settings.saveWorkouts {
                Task { [health] in
                    await health.saveRide(start: start, end: end,
                                          distanceMeters: savedDistance,
                                          calories: savedCalories, route: savedRoute)
                }
            }
        }

        route = []
        radarPoints = []
        passes = []
        track = []
        laps = []
        currentLapTimeSeconds = 0
        maxSpeedMps = 0
        rideStart = nil
        clearPersistence()
        ble.beginSensorMonitor()   // remind later if the sensors are left switched on
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
    // While set, the demo is in its closing "radar dropped out" preview window.
    private var demoRadarLostUntil: Date?

    // Final demo beat: a looping demo route with waypoints shown in the radar
    // slot, the rider gliding along it, so route-following can be previewed
    // without planning anything.
    @Published private(set) var demoRoute: PlannedRoute?
    @Published private(set) var demoRouteIndex = 0
    /// Seconds into the route preview — drives the demo ghost race.
    @Published private(set) var demoRouteElapsed = 0.0
    /// A staged junction ahead on the demo loop (arms + countdown), so the
    /// junction tile/badge demo without any OSM fetch.
    @Published private(set) var demoJunction: JunctionInfo?
    /// The arm the demo "route" takes at that junction (drawn green).
    @Published private(set) var demoJunctionExitBearing: Double?
    private var demoJunctionTarget = 0
    private var demoRouteUntil: Date?
    private var demoRouteCarry = 0.0

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
        // Plausible riding heart rate and a calorie total consistent with the
        // elapsed time, so the demo (and App Store screenshots) show full data.
        currentHeartRate = Int.random(in: 132...148)
        caloriesKcal = (elapsed / 60.0) * Double.random(in: 9...12)
        currentGradientPercent = Double.random(in: -2...4)
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
        demoRadarLostUntil = nil
        demoRoute = nil
        demoRouteIndex = 0
        demoRouteElapsed = 0
        demoJunction = nil
        demoJunctionExitBearing = nil
        demoJunctionTarget = 0
        demoRouteUntil = nil
        demoRouteCarry = 0
        demoTimer?.invalidate()
        demoTimer = nil
        // The BLE side keeps cadence/power flowing to the end of the demo;
        // stop it with the rest (safe to call twice when the UI already has).
        ble.stopDemo()
        distanceMeters = 0
        movingTimeSeconds = 0
        elevationGainMeters = 0
        currentSpeedMps = 0
        currentHeartRate = nil
        caloriesKcal = 0
        currentGradientPercent = nil
        // Tell the Watch it's over: resets speed, clears threats, ends its
        // workout (which zeroes the heart rate).
        sendMirror()
    }

    /// Pause/resume the demo (mirrors a manual pause on a real ride).
    func toggleDemoPause() {
        guard demoActive else { return }
        demoPaused.toggle()
        ble.setDemoPaused(demoPaused)
        lastTick = Date()
    }

    /// The scripted threat frames have run; before ending the demo, preview the
    /// radar drop-out alert (distinct buzz + RADAR OFF banner) so the rider can
    /// feel and fine-tune every Watch alert in one demo, not just car taps.
    private func demoFramesFinished() {
        guard demoActive, demoRadarLostUntil == nil else { return }
        demoRadarLostUntil = Date().addingTimeInterval(3.5)
        watch.sendRadarLostHaptic()   // the distinct double-buzz, once
        sendMirror()                  // push the RADAR OFF banner immediately
    }

    /// A ~2 km organic loop around the rider (or a fixed spot with no fix),
    /// with waypoint markers dotted around it — the demo's route preview.
    private func makeDemoRoute() -> PlannedRoute {
        let center = location.currentLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 52.4414, longitude: -0.8329)
        var path: [PlannedRoute.Point] = []
        let n = 160
        for i in 0...n {
            let t = Double(i) / Double(n) * 2 * .pi
            // Wobbled radius so the loop bends like real lanes, not a circle.
            let r = 260 + 90 * sin(2 * t) + 50 * sin(3 * t + 1)
            let dLat = r * cos(t) / 111_320
            let dLon = r * sin(t) / (111_320 * cos(center.latitude * .pi / 180))
            path.append(PlannedRoute.Point(lat: center.latitude + dLat,
                                           lon: center.longitude + dLon))
        }
        var dist = 0.0
        for i in 0..<(path.count - 1) {
            dist += PlannedRoute.meters(path[i].coordinate, path[i + 1].coordinate)
        }
        let waypoints = stride(from: 0, to: path.count, by: max(1, path.count / 6)).map { path[$0] }
        // Rolling synthetic elevations (climb strip) and a ghost that rides a
        // touch slower than the demo speed, so the rider visibly pulls ahead.
        let elevations = (0...n).map { i -> Double in
            let t = Double(i) / Double(n) * 2 * .pi
            return 100 + 26 * sin(2 * t + 0.6) + 9 * sin(5 * t)
        }
        var bestTimes: [Double] = [0]
        for i in 0..<(path.count - 1) {
            bestTimes.append(bestTimes[i]
                + PlannedRoute.meters(path[i].coordinate, path[i + 1].coordinate) / 6.2)
        }
        return PlannedRoute(name: String(localized: "Demo route", bundle: Lang.bundle),
                            waypoints: waypoints, loop: true,
                            path: path, distanceMeters: dist,
                            elevations: elevations,
                            bestTimes: bestTimes, bestDate: Date())
    }

    /// Stage the next pretend junction ahead of the demo rider and keep its
    /// countdown live; every third one is a roundabout for variety.
    private func updateDemoJunction() {
        guard let route = demoRoute else { return }
        let spacing = 40                                       // path points apart
        if demoJunctionTarget <= demoRouteIndex + 2 {
            demoJunctionTarget = ((demoRouteIndex / spacing) + 1) * spacing
        }
        guard demoJunctionTarget < route.path.count - 1 else {
            demoJunction = nil
            return
        }
        let at = route.path[demoJunctionTarget].coordinate
        let approach = PlannedRoute.bearing(route.path[demoJunctionTarget - 1].coordinate, at)
        func norm(_ d: Double) -> Double {
            var v = d.truncatingRemainder(dividingBy: 360)
            if v < 0 { v += 360 }
            return v
        }
        var dist = 0.0
        for i in demoRouteIndex..<demoJunctionTarget {
            dist += PlannedRoute.meters(route.path[i].coordinate, route.path[i + 1].coordinate)
        }
        let exit = norm(approach + 85)
        demoJunction = JunctionInfo(distanceMeters: dist,
                                    armBearings: [norm(approach), exit,
                                                  norm(approach - 95), norm(approach + 180)],
                                    approachBearing: approach,
                                    isRoundabout: (demoJunctionTarget / spacing) % 3 == 0,
                                    nodeID: Int64(demoJunctionTarget),
                                    latitude: at.latitude, longitude: at.longitude)
        demoJunctionExitBearing = exit
    }

    private func demoTick() {
        let now = Date()
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0.5
        lastTick = now
        guard !demoPaused else { return }

        // Closing radar-lost preview: hold the RADAR OFF banner, then move on
        // to the final beat — following a demo route in the radar slot.
        if let until = demoRadarLostUntil {
            if now >= until {
                demoRadarLostUntil = nil
                demoRoute = makeDemoRoute()
                demoRouteIndex = 0
                demoRouteElapsed = 0
                demoRouteCarry = 0
                demoJunctionTarget = 0
                updateDemoJunction()
                demoRouteUntil = now.addingTimeInterval(16)
            } else {
                sendMirror()
            }
            return
        }

        // Route preview: glide along the demo loop — junction countdown, climb
        // strip and the ghost race all live — then finish for real.
        if let until = demoRouteUntil {
            if now >= until { stopDemo(); return }
            demoRouteElapsed += dt
            demoRouteCarry += max(3, currentSpeedMps) * dt
            while let route = demoRoute, demoRouteIndex < route.path.count - 1 {
                let seg = PlannedRoute.meters(route.path[demoRouteIndex].coordinate,
                                              route.path[demoRouteIndex + 1].coordinate)
                guard demoRouteCarry >= seg else { break }
                demoRouteCarry -= seg
                demoRouteIndex += 1
            }
            updateDemoJunction()
        }
        movingTimeSeconds += dt
        let wobble = sin(movingTimeSeconds / 6.0) * 1.2 + Double.random(in: -0.4...0.4)
        currentSpeedMps = max(0, demoBaseSpeedMps + wobble)
        distanceMeters += currentSpeedMps * dt
        if Double.random(in: 0...1) < 0.5 {
            elevationGainMeters += Double.random(in: 0...0.7)
        }
        // Keep HR/calories alive too. Drift HR within a believable band and tick
        // calories up at ~10 kcal/min so nothing reads "—" during the demo.
        let hr = (currentHeartRate ?? 140) + Int.random(in: -1...1)
        currentHeartRate = min(155, max(126, hr))
        caloriesKcal += (10.0 / 60.0) * dt
        currentGradientPercent = sin(movingTimeSeconds / 18.0) * 4 + Double.random(in: -0.4...0.4)
        sendMirror()   // drive the Watch (mirror + escalating haptics) during the demo too
    }

    // MARK: - Elevation (barometer)

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        usingBarometer = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let alt = data.relativeAltitude.doubleValue   // metres relative to start
            self.relativeAltitude = alt
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
        // Baseline the radar state so resuming a ride doesn't fire a spurious
        // drop-out alert on the first tick.
        radarWasConnected = ble.status(for: .radar) == .connected
        // 2 Hz: plenty for the metric tiles (no one reads faster) and half the
        // per-second UI redraws / wake-ups of the old 4 Hz tick, to save battery.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
        // Prefer the Apple Watch (already streaming during a ride); fall back to a
        // paired BLE heart-rate strap so HR/calories work without a Watch.
        currentHeartRate = watch.freshHeartRate() ?? ble.freshSensorHeartRate()

        // Crash confirmation: a big impact only becomes an SOS if the rider
        // comes to a stop shortly after it. Still moving = it was just a bump.
        if let impactAt = crashCandidateAt {
            if now.timeIntervalSince(impactAt) > crashConfirmWindow {
                crashCandidateAt = nil
                AppLog.shared.log("Crash candidate dismissed — still moving")
            } else if currentSpeedMps < 1.0 / 3.6, settings.crashDetectionEnabled {
                crashCandidateAt = nil
                AppLog.shared.log("Crash CONFIRMED (impact + stop) — SOS countdown")
                sos.trigger()
            }
        }
        if let hr = currentHeartRate, hr > 0 {
            hrSum += Double(hr); hrCount += 1; hrMax = max(hrMax, hr)
        }
        // Time-weighted power average (coasting at 0 W counts — that's honest).
        if status == .running, let watts = ble.freshSensorPower() {
            powerSum += Double(watts) * dt
            powerTime += dt
        }

        switch status {
        case .running:
            movingTimeSeconds += dt
            maxSpeedMps = max(maxSpeedMps, currentSpeedMps)
            currentLapTimeSeconds = movingTimeSeconds - lapStartMovingTime
            accumulateCalories(dt: dt)
            updateAutoPause(dt: dt)
            sampleTrack(now: now)
            updateGradient()
            checkTurnCue()
            routes?.recordGhost(elapsed: movingTimeSeconds)
        case .autoPaused:
            updateAutoResume(dt: dt)
        case .paused, .idle:
            break
        }

        // Watch radar drop-out alert, then mirror state every tick (~2 Hz).
        checkRadarPresence()
        if status == .running || status == .autoPaused { updatePassLog(now: now) }
        sendMirror()

        // Persist so the ride survives the app being killed mid-ride. Tick is now
        // 2 Hz, so these counts target ~2 s and ~15 s.
        saveTick += 1
        if saveTick % 4 == 0 { persistSnapshot() }      // ~every 2 s
        if saveTick % 30 == 0 { persistRoute() }        // ~every 15 s
    }

    /// Record a speed/HR/elevation sample roughly every 2 s while riding, for the
    /// summary graphs. Bounded so a very long ride can't grow without limit
    /// (downsampled again to ~250 points when the ride is saved).
    private func sampleTrack(now: Date) {
        guard let start = rideStart else { return }
        if let last = lastTrackAt, now.timeIntervalSince(last) < 2 { return }
        lastTrackAt = now
        guard track.count < 3000 else { return }
        track.append(TrackSample(t: now.timeIntervalSince(start),
                                 speedMps: currentSpeedMps,
                                 hr: currentHeartRate,
                                 altitude: relativeAltitude))
    }

    /// Live road gradient (%), as rise over run across a short trailing window of
    /// travel. Uses the same altitude source as the elevation graph (barometer
    /// when available, GPS otherwise) against cumulative distance. Needs a few
    /// metres of travel before it reads, and is clamped to a sane road range.
    private func updateGradient() {
        let d = distanceMeters
        gradientWindow.append((d, relativeAltitude))
        while let first = gradientWindow.first, d - first.dist > 60 { gradientWindow.removeFirst() }
        // Baseline ~20 m back (or the oldest sample we have); require ≥8 m of run
        // so the percentage isn't dominated by GPS/altitude noise at low distance.
        let base = gradientWindow.first { d - $0.dist >= 20 } ?? gradientWindow.first
        guard let base, d - base.dist >= 8 else { currentGradientPercent = nil; return }
        let run = d - base.dist
        guard run > 0 else { currentGradientPercent = nil; return }
        let g = (relativeAltitude - base.alt) / run * 100
        currentGradientPercent = max(-30, min(30, g))
    }

    /// Calories. Uses heart rate (Keytel) when the Watch supplies one, otherwise
    /// falls back to a speed-based estimate so calories still work without a Watch.
    /// Only computed when rides are saved as workouts and a body weight is known —
    /// without a weight the estimate would be meaningless, so calories stay hidden.
    private func accumulateCalories(dt: Double) {
        guard settings.saveWorkouts, bodyWeightKg > 0 else { return }
        if let hr = currentHeartRate, hr > 0 {
            // Heart rate already reflects climbing effort — no ascent term.
            let perMinute = Calories.kcalPerMinute(heartRate: Double(hr), weightKg: bodyWeightKg,
                                                   ageYears: bodyAgeYears, isFemale: bodyIsFemale)
            caloriesKcal += perMinute * (dt / 60.0)
        } else {
            // No heart rate: speed-based MET, plus the climbing energy for any
            // ascent gained this interval so hilly legs aren't undercounted.
            let perMinute = Calories.kcalPerMinute(speedMps: currentSpeedMps, weightKg: bodyWeightKg)
            caloriesKcal += perMinute * (dt / 60.0)
            let climbed = max(0, elevationGainMeters - lastCalorieAscent)
            caloriesKcal += Calories.climbKcal(ascentMeters: climbed, weightKg: bodyWeightKg)
        }
        lastCalorieAscent = elevationGainMeters
    }

    private func sendMirror() {
        let levels = ble.threats.map { $0.level.rawValue }
        let nearest = ble.threats.map { Int($0.distanceMeters.rounded()) }.min()
        // The demo announces itself as "demo": the Watch displays it exactly
        // like a running ride (mirror, haptics) but must NOT start a workout
        // session — a session orphaned by a suspended watch app after a demo
        // is eventually saved by watchOS as a phantom empty workout.
        watch.sendMirror(speedDisplay: settings.speedUnit.value(fromMps: currentSpeedMps),
                         speedUnit: settings.speedUnit.label,
                         distanceDisplay: settings.distanceUnit.value(fromMeters: distanceMeters),
                         distanceUnit: settings.distanceUnit.label,
                         rideStatusRaw: demoActive ? "demo" : statusRaw,
                         threatLevel: levels.max() ?? -1,
                         nearestThreatMeters: nearest,
                         radarLost: demoActive ? (demoRadarLostUntil != nil) : radarConfiguredButDown,
                         hrWarningBpm: settings.effectiveHRWarningBpm,
                         hapticsMuted: !settings.hapticsEnabled)
    }

    /// Whether new-vehicle alerts should fire: only during an active ride (incl.
    /// auto-pause at a light, where a car behind still matters) or the demo.
    private var alertsLive: Bool {
        demoActive || status == .running || status == .autoPaused
    }

    /// True when a radar is set up but not currently connected — the state that
    /// drives the Watch "RADAR OFF" banner and the drop-out haptic.
    private var radarConfiguredButDown: Bool {
        let s = ble.status(for: .radar)
        return s != .connected && s != .notConfigured
    }

    /// Buzz the Watch the moment the radar drops mid-ride — a safety device going
    /// dark should be felt, not just seen. Edge-triggered; only while riding.
    private func checkRadarPresence() {
        let connected = ble.status(for: .radar) == .connected
        let riding = (status == .running || status == .autoPaused) && !demoActive
        if riding, radarWasConnected, !connected {
            watch.sendRadarLostHaptic()
        }
        radarWasConnected = connected
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

    /// Where the rider was when auto-pause engaged — the position-based
    /// resume check compares against this.
    private var autoPausedAt: CLLocation?

    // MARK: - Route turn cues

    /// Path index of the last turn announced, so each turn cues exactly once.
    private var lastTurnCueIndex = -1
    private var lastTurnCueTime: Date?

    /// While following a route, announce the next sharp bend as it approaches:
    /// a spoken "Left/Right turn ahead" and a wrist tap. Cue distance scales
    /// with speed (~12 s out, clamped 80–250 m). A short cooldown collapses
    /// bends that span adjacent path vertices into a single cue.
    private func checkTurnCue() {
        guard settings.routeTurnAlertsEnabled,
              let store = routes, store.joinedActiveRoute,
              let route = store.activeRoute, let idx = store.currentPathIndex,
              let turn = route.nextTurn(after: idx, within: 300),
              turn.index != lastTurnCueIndex else { return }
        if let last = lastTurnCueTime, Date().timeIntervalSince(last) < 8 { return }
        let cueAt = max(80, min(250, currentSpeedMps * 12))
        guard turn.distanceMeters <= cueAt else { return }
        lastTurnCueIndex = turn.index
        lastTurnCueTime = Date()
        let text = turn.deltaDegrees < 0
            ? String(localized: "Left turn ahead", bundle: Lang.bundle)
            : String(localized: "Right turn ahead", bundle: Lang.bundle)
        AudioAlerts.shared.speak(text, language:
            settings.appLanguage.isEmpty ? Locale.current.identifier : settings.appLanguage)
        watch.sendTurnHaptic()
        AppLog.shared.log("Turn cue: \(text) in \(Int(turn.distanceMeters)) m")
    }

    private func updateAutoPause(dt: Double) {
        guard settings.autoPauseEnabled else { return }
        if currentSpeedMps < movingThresholdMps {
            stationarySeconds += dt
            if stationarySeconds >= autoPauseDelay {
                status = .autoPaused
                movingSeconds = 0
                autoPausedAt = location.currentLocation
                AppLog.shared.log("Auto-paused")
            }
        } else {
            stationarySeconds = 0
        }
    }

    private func updateAutoResume(dt: Double) {
        // Position check first: if the rider has clearly moved away from the
        // pause spot, resume regardless of what the speed estimate says. The
        // speed can wedge near zero (a wheel sensor's 16-bit event clock wraps
        // every 64 s, so its first frame after a long stop computes garbage;
        // GPS speed reads invalid for a while after standstill) — but the
        // POSITION always moves when the rider does. This is what stranded a
        // real ride paused for kilometres.
        if let ref = autoPausedAt, let cur = location.currentLocation,
           cur.horizontalAccuracy >= 0, cur.horizontalAccuracy < 50,
           cur.distance(from: ref) > 30 {
            resumeFromAutoPause(reason: "moved \(Int(cur.distance(from: ref))) m from pause spot")
            return
        }
        if currentSpeedMps >= movingThresholdMps {
            movingSeconds += dt
            if movingSeconds >= autoResumeDelay {
                resumeFromAutoPause(reason: "speed")
            }
        } else {
            movingSeconds = 0
        }
    }

    private func resumeFromAutoPause(reason: String) {
        status = .running
        stationarySeconds = 0
        movingSeconds = 0
        autoPausedAt = nil
        AppLog.shared.log("Auto-resumed (\(reason))")
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
            if firstGpsAltitude == nil { firstGpsAltitude = loc.altitude }
            relativeAltitude = loc.altitude - (firstGpsAltitude ?? loc.altitude)
        }
    }

    /// Log where a vehicle was first detected behind the rider, using the most
    /// recent good GPS fix. Real rides only (not the demo) and only with a fix.
    private func recordRadarDetection() {
        guard !demoActive, status == .running || status == .autoPaused else { return }
        guard radarPoints.count < 1000, let loc = route.last else { return }
        radarPoints.append(Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude))
    }

    /// Sample the nearest vehicle's distance/closing-speed plus the rider's own
    /// speed, building a trace per approach. Called each tick during a ride; only
    /// records a new point when the radar reports a fresh frame, and closes the
    /// encounter ~1.5 s after the lane clears.
    private func updatePassLog(now: Date) {
        if let nearest = ble.threats.min(by: { $0.distanceMeters < $1.distanceMeters }) {
            if openPass == nil {
                let loc = route.last
                openPass = (start: now, lat: loc?.coordinate.latitude,
                            lon: loc?.coordinate.longitude, samples: [])
            }
            // Only append on a genuinely new radar frame (lastSeen advances), and
            // cap the sample count so a long tail-gating car can't grow unbounded.
            // Raw frames are stored as-is (no value cap, since high closing speeds
            // are real on fast roads); lone glitch frames are removed later by
            // VehiclePass.cleanSamples as statistical outliers.
            if nearest.distanceMeters > 0, nearest.lastSeen != lastPassFrameSeen,
               var p = openPass, p.samples.count < 240 {
                p.samples.append(PassSample(t: now.timeIntervalSince(p.start),
                                            distance: nearest.distanceMeters,
                                            closingKmh: nearest.approachSpeedKmh,
                                            riderKmh: currentSpeedMps * 3.6))
                openPass = p
                lastPassFrameSeen = nearest.lastSeen
            }
            lastThreatPresentAt = now
        } else if openPass != nil,
                  let last = lastThreatPresentAt, now.timeIntervalSince(last) >= 1.5 {
            finalizeOpenPass()
        }
    }

    /// Store the in-progress approach if it's substantial enough to be useful.
    private func finalizeOpenPass() {
        if let p = openPass, p.samples.count >= 3, passes.count < 300 {
            passes.append(VehiclePass(id: UUID(), date: p.start, lat: p.lat,
                                      lon: p.lon, samples: p.samples))
        }
        openPass = nil
        lastPassFrameSeen = nil
        lastThreatPresentAt = nil
    }

    /// Reduce the speed/HR/elevation series to ~250 samples for storage.
    private func downsampledTrack(_ samples: [TrackSample]) -> [TrackSample] {
        guard samples.count > 250 else { return samples }
        let stride = samples.count / 250
        return samples.enumerated().compactMap { idx, s in idx % stride == 0 ? s : nil }
    }

    /// Reduce the GPS track to ~250 points (plus a per-point speed in m/s, for
    /// colouring the route line) for a lightweight stored summary map.
    private func downsampledRoute(_ locations: [CLLocation]) -> (points: [Coord], speeds: [Double]) {
        guard !locations.isEmpty else { return ([], []) }
        let stride = max(1, locations.count / 250)
        var kept = locations.enumerated().compactMap { idx, loc in idx % stride == 0 ? loc : nil }
        if let last = locations.last, kept.last !== last { kept.append(last) }   // keep the true endpoint

        let points = kept.map { Coord(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        let speeds: [Double] = kept.enumerated().map { i, loc in
            if loc.speed >= 0 { return loc.speed }            // GPS speed when valid
            guard i > 0 else { return 0 }                     // else derive from the previous point
            let prev = kept[i - 1]
            let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
            return dt > 0 ? loc.distance(from: prev) / dt : 0
        }
        return (points, speeds)
    }

    private func applyScreenLock() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
    }

    // MARK: - Crash / termination recovery

    private func persistSnapshot() {
        guard status != .idle else { return }
        let snap = RideSnapshot(statusRaw: statusRaw, distance: distanceMeters,
                                movingTime: movingTimeSeconds, elevation: elevationGainMeters,
                                calories: caloriesKcal,
                                startEpoch: (rideStart ?? Date()).timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }

    private func persistRoute() {
        let points = route.map {
            RoutePoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, alt: $0.altitude,
                       hAcc: $0.horizontalAccuracy, vAcc: $0.verticalAccuracy,
                       course: $0.course, speed: $0.speed, t: $0.timestamp.timeIntervalSince1970)
        }
        if let data = try? JSONEncoder().encode(points) { try? data.write(to: routeURL) }
    }

    private func clearPersistence() {
        UserDefaults.standard.removeObject(forKey: snapshotKey)
        try? FileManager.default.removeItem(at: routeURL)
    }

    /// On launch, resume an in-progress ride that was interrupted by the app
    /// being killed — so the ride only ever ends when the rider taps Stop.
    private func restoreActiveRide() {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(RideSnapshot.self, from: data),
              snap.statusRaw != "idle" else { return }
        let start = Date(timeIntervalSince1970: snap.startEpoch)
        guard Date().timeIntervalSince(start) < 12 * 3600 else { clearPersistence(); return }

        distanceMeters = snap.distance
        movingTimeSeconds = snap.movingTime
        elevationGainMeters = snap.elevation
        caloriesKcal = snap.calories
        lastCalorieAscent = snap.elevation   // don't re-count ascent already banked
        rideStart = start
        route = loadRoute()
        switch snap.statusRaw {
        case "paused": status = .paused
        case "autoPaused": status = .autoPaused
        default: status = .running
        }
        loadBodyMetrics()
        lastTick = Date()
        location.setMode(.recording)
        startTicker()
        startAltimeter()
        if settings.crashDetectionEnabled { crash.start() }
        applyScreenLock()
        AppLog.shared.log("Restored in-progress ride (status=\(snap.statusRaw), dist=\(Int(distanceMeters))m) — prior session likely crashed/terminated")
    }

    private func loadRoute() -> [CLLocation] {
        guard let data = try? Data(contentsOf: routeURL),
              let points = try? JSONDecoder().decode([RoutePoint].self, from: data) else { return [] }
        return points.map {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                       altitude: $0.alt, horizontalAccuracy: $0.hAcc, verticalAccuracy: $0.vAcc,
                       course: $0.course, speed: $0.speed,
                       timestamp: Date(timeIntervalSince1970: $0.t))
        }
    }
}

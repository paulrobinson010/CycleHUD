import Foundation
import Combine
import WatchConnectivity
import HealthKit
import WatchKit

/// Watch side of the link. Mirrors the phone's ride data, taps the wrist on
/// new-car alerts, and runs an `HKWorkoutSession` while the ride is active so it
/// can stream heart rate back to the phone (which computes calories and saves
/// the workout). The watch workout itself is discarded — the phone owns the
/// authoritative Health workout (it has the GPS route).
final class WatchSessionManager: NSObject, ObservableObject {

    @Published var speedMps: Double = 0
    @Published var distanceMeters: Double = 0
    @Published var statusRaw: String = "idle"
    @Published var threatLevel: Int = -1
    @Published var nearestThreatMeters: Int?
    @Published var heartRate: Int = 0
    @Published var radarLost: Bool = false   // radar dropped out mid-ride

    // Diagnostics surfaced on-screen so we can see where the HR chain breaks.
    @Published var healthRequested = false
    @Published var workoutActive = false

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private let hrType = HKQuantityType(.heartRate)
    private let hrUnit = HKUnit.count().unitDivided(by: .minute())

    private var rideActive = false     // run the workout session only during a ride

    /// Start/stop the workout session. A live `HKWorkoutSession` is the single
    /// biggest battery drain on the watch, so we run it ONLY during an actual
    /// ride — never just because the app is on screen. When idle, heart rate
    /// comes from the low-power HealthKit sample stream (startHeartRateQuery).
    private func updateWorkout() {
        let want = rideActive
        if want, workoutSession == nil {
            startWorkout()
        } else if !want, workoutSession != nil {
            stopWorkout()
        }
    }

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        requestHealthAuthorization()
        discardOrphanedWorkout()
    }

    /// If a previous run was killed mid-ride, watchOS keeps that workout session
    /// alive in the background and will eventually save it as an (empty) workout.
    /// The watch must NEVER own a workout — the phone saves the authoritative one
    /// — so recover any such session on launch and discard it immediately.
    private func discardOrphanedWorkout() {
        guard HKHealthStore.isHealthDataAvailable(), healthUsageStringsPresent else { return }
        healthStore.recoverActiveWorkoutSession { [weak self] session, _ in
            guard let self, let session else { return }
            DispatchQueue.main.async {
                self.workoutSession = session
                self.builder = session.associatedWorkoutBuilder()
                session.delegate = self
                self.builder?.delegate = self
                session.end()   // → didChangeTo .ended → endCollection + discardWorkout
            }
        }
    }

    /// True only when the HealthKit usage-description keys exist in this target's
    /// Info.plist. HealthKit hard-crashes if you touch it without them.
    private var healthUsageStringsPresent: Bool {
        let info = Bundle.main.infoDictionary
        return info?["NSHealthShareUsageDescription"] != nil
            && info?["NSHealthUpdateUsageDescription"] != nil
    }

    private func requestHealthAuthorization() {
        guard HKHealthStore.isHealthDataAvailable(), healthUsageStringsPresent else { return }
        healthRequested = true
        let share: Set<HKSampleType> = [HKQuantityType(.activeEnergyBurned), hrType]
        let read: Set<HKObjectType> = [hrType]
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] success, _ in
            if success { self?.startHeartRateQuery() }
        }
    }

    // MARK: - Idle heart rate (no workout required)

    private var hrQuery: HKAnchoredObjectQuery?

    /// Streams the latest recorded heart rate from HealthKit even when no ride
    /// is running, so opening the app shows a value. At rest watchOS samples HR
    /// every few minutes; during a ride the workout session updates it live.
    private func startHeartRateQuery() {
        guard hrQuery == nil else { return }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-3600),
                                                    end: nil, options: [])
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
            [weak self] _, samples, _, _, _ in
            guard let self, let last = (samples as? [HKQuantitySample])?.last else { return }
            let hr = last.quantity.doubleValue(for: self.hrUnit)
            DispatchQueue.main.async {
                self.heartRate = Int(hr.rounded())
                self.sendHeartRate(hr)
            }
        }
        let query = HKAnchoredObjectQuery(type: hrType, predicate: predicate, anchor: nil,
                                          limit: HKObjectQueryNoLimit, resultsHandler: handler)
        query.updateHandler = handler
        healthStore.execute(query)
        hrQuery = query
    }

    // MARK: - Workout session (heart rate source)

    private func startWorkout() {
        guard workoutSession == nil, HKHealthStore.isHealthDataAvailable(),
              healthUsageStringsPresent else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                         workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            self.builder = builder
            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, _ in }
            workoutActive = true
        } catch {
            workoutSession = nil
            builder = nil
        }
    }

    private func stopWorkout() {
        // Actual teardown (finish + discard) happens in the session-state
        // delegate, so a system-initiated end is handled the same way.
        workoutSession?.end()
    }

    private var hrSeq = 0
    private func sendHeartRate(_ hr: Double) {
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            // Instant path when the phone app is foreground.
            WCSession.default.sendMessage(["heartRate": hr], replyHandler: nil, errorHandler: nil)
        } else {
            // Background-capable path when the phone is pocketed/screen-off.
            hrSeq += 1
            try? WCSession.default.updateApplicationContext(["heartRate": hr, "hrSeq": hrSeq])
        }
    }

    // MARK: - Apply mirrored state

    private func apply(_ data: [String: Any]) {
        if let v = data["speed"] as? Double { speedMps = v }
        if let v = data["distance"] as? Double { distanceMeters = v }
        if let v = data["threat"] as? Int { threatLevel = v }
        nearestThreatMeters = data["nearest"] as? Int
        if let v = data["radarLost"] as? Bool { radarLost = v }
        if let s = data["status"] as? String {
            statusRaw = s
            rideActive = (s != "idle")
            updateWorkout()
        }
        updateHapticLoop()
    }

    // MARK: - Proximity haptics
    //
    // While a vehicle is behind, the wrist is tapped repeatedly, getting faster
    // and stronger as the car closes in.

    private var hapticTimer: Timer?

    /// Start the wrist-tap loop when a car appears, stop it when the lane clears.
    private func updateHapticLoop() {
        let carPresent = threatLevel >= 0
        if carPresent {
            if hapticTimer == nil { scheduleNextHaptic(after: 0) }   // tap right away
        } else if hapticTimer != nil {
            hapticTimer?.invalidate()
            hapticTimer = nil
        }
    }

    /// Schedule exactly one tap, then reschedule from inside it — so the timer
    /// only fires when a haptic actually plays, instead of polling several times
    /// a second while a car is behind us.
    private func scheduleNextHaptic(after delay: TimeInterval) {
        hapticTimer?.invalidate()
        hapticTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, delay), repeats: false) {
            [weak self] _ in
            guard let self, self.threatLevel >= 0 else { return }
            self.playHaptic()
            // Cadence: ~5 s apart when far, down to ~0.6 s when right behind.
            let distance = Double(self.nearestThreatMeters ?? 120)
            self.scheduleNextHaptic(after: max(0.6, min(5.0, distance / 24.0)))
        }
    }

    private func playHaptic() {
        // Strength matches the on-screen threat colour so the wrist tells you the
        // severity without looking: red = double tap, orange = firm tap, yellow =
        // light tick. Cadence (how often) is handled by scheduleNextHaptic and
        // tightens with proximity.
        let device = WKInterfaceDevice.current()
        switch threatLevel {
        case 2:   // high — red
            device.play(.notification)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { device.play(.notification) }
        case 1:   // medium — orange
            device.play(.notification)
        default:  // low — yellow
            device.play(.click)
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.apply(applicationContext) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let event = message["event"] as? String else { return }
        DispatchQueue.main.async { self.playEventHaptic(event) }
    }

    /// One-shot wrist alerts pushed from the phone. The radar-lost pattern is
    /// deliberately distinct from a car tap — a double `.failure` buzz reads as
    /// "something's wrong", not "car behind".
    private func playEventHaptic(_ event: String) {
        let device = WKInterfaceDevice.current()
        switch event {
        case "newCar":
            device.play(.notification)
        case "radarLost":
            device.play(.failure)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { device.play(.failure) }
        default:
            break
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchSessionManager: HKWorkoutSessionDelegate {
    func workoutSession(_ session: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        // DISCARD, never finish — the phone saves the authoritative workout (with
        // the GPS route), so the watch must never save its own. Niling the
        // session lets it auto-restart if the ride is still going.
        guard let builder else {
            DispatchQueue.main.async { self.clearWorkout() }
            return
        }
        builder.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.builder?.discardWorkout()
            DispatchQueue.main.async { self?.clearWorkout() }
        }
    }

    private func clearWorkout() {
        workoutSession = nil
        builder = nil
        workoutActive = false
        heartRate = 0
    }

    func workoutSession(_ session: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.workoutSession = nil
            self.builder = nil
            self.workoutActive = false
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchSessionManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let quantity = stats.mostRecentQuantity() else { return }
        let hr = quantity.doubleValue(for: hrUnit)
        DispatchQueue.main.async {
            self.heartRate = Int(hr.rounded())
            self.sendHeartRate(hr)
        }
    }
}

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

    // Diagnostics surfaced on-screen so we can see where the HR chain breaks.
    @Published var healthRequested = false
    @Published var workoutActive = false

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private let hrType = HKQuantityType(.heartRate)
    private let hrUnit = HKUnit.count().unitDivided(by: .minute())

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        requestHealthAuthorization()
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
        healthStore.requestAuthorization(toShare: share, read: read) { _, _ in }
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
        if let s = data["status"] as? String {
            statusRaw = s
            if s == "running", workoutSession == nil {
                startWorkout()
            } else if s == "idle", workoutSession != nil {
                stopWorkout()
            }
        }
        updateHapticLoop()
    }

    // MARK: - Proximity haptics
    //
    // While a vehicle is behind, the wrist is tapped repeatedly, getting faster
    // and stronger as the car closes in.

    private var hapticTimer: Timer?
    private var lastHapticAt: Date?

    private func updateHapticLoop() {
        let carPresent = threatLevel >= 0
        if carPresent, hapticTimer == nil {
            lastHapticAt = nil
            hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.evaluateHaptic()
            }
        } else if !carPresent, hapticTimer != nil {
            hapticTimer?.invalidate()
            hapticTimer = nil
        }
    }

    private func evaluateHaptic() {
        guard threatLevel >= 0 else { return }
        let distance = Double(nearestThreatMeters ?? 120)

        // Cadence: ~5 s apart when far, down to ~0.6 s when right behind.
        let interval = max(0.6, min(5.0, distance / 24.0))
        if let last = lastHapticAt, Date().timeIntervalSince(last) < interval { return }
        lastHapticAt = Date()

        // Strength escalates with proximity.
        let device = WKInterfaceDevice.current()
        if distance <= 25 {
            device.play(.notification)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { device.play(.notification) }
        } else if distance <= 60 {
            device.play(.notification)
        } else {
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
        if message["event"] as? String == "newCar" {
            DispatchQueue.main.async { WKInterfaceDevice.current().play(.notification) }
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchSessionManager: HKWorkoutSessionDelegate {
    func workoutSession(_ session: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        // Finish and DISCARD — the phone saves the authoritative workout (with
        // the GPS route), so the watch must never save its own. Niling the
        // session lets it auto-restart if the ride is still going.
        builder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.builder?.discardWorkout()
            DispatchQueue.main.async {
                self?.workoutSession = nil
                self?.builder = nil
                self?.workoutActive = false
                self?.heartRate = 0
            }
        }
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

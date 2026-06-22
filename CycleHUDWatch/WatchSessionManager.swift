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

    private func requestHealthAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKQuantityType(.activeEnergyBurned), hrType]
        let read: Set<HKObjectType> = [hrType]
        healthStore.requestAuthorization(toShare: share, read: read) { _, _ in }
    }

    // MARK: - Workout session (heart rate source)

    private func startWorkout() {
        guard workoutSession == nil, HKHealthStore.isHealthDataAvailable() else { return }
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
        } catch {
            workoutSession = nil
            builder = nil
        }
    }

    private func stopWorkout() {
        guard let session = workoutSession else { return }
        session.end()
        builder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.builder?.discardWorkout()
            self?.workoutSession = nil
            self?.builder = nil
            DispatchQueue.main.async { self?.heartRate = 0 }
        }
    }

    private func sendHeartRate(_ hr: Double) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["heartRate": hr], replyHandler: nil, errorHandler: nil)
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
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {}
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
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

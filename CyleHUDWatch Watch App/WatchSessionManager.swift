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

    // Speed/distance arrive already in the rider's units (converted by the phone).
    @Published var speedDisplay: Double = 0
    @Published var speedUnitLabel: String = "km/h"
    @Published var distanceDisplay: Double = 0
    @Published var distanceUnitLabel: String = "km"
    @Published var statusRaw: String = "idle"
    @Published var threatLevel: Int = -1
    @Published var nearestThreatMeters: Int?
    @Published var heartRate: Int = 0
    @Published var radarLost: Bool = false   // radar dropped out mid-ride
    @Published private(set) var hrWarningActive = false   // HR at/over the warning threshold
    private var hapticsMuted = false         // rider muted vehicle wrist taps from the phone

    private var hrWarningBpm = 0             // warning threshold from the phone (0 = off)
    private var lastHRWarnAt: Date?

    // Crash SOS mirrored from the phone: the wrist can cancel, or call the
    // emergency contact, when the phone is mounted out of reach after a crash.
    @Published private(set) var sosActive = false
    @Published private(set) var sosSeconds = 0
    @Published private(set) var sosContactName = ""
    private var sosContactPhone = ""
    private var sosHapticTimer: Timer?

    // Diagnostics surfaced on-screen so we can see where the HR chain breaks.
    @Published var healthRequested = false
    @Published var workoutActive = false

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    // Discard lifecycle (mirrors a proven implementation): between stop() and the
    // session's `.ended` delegate we hold the refs and discard there — never via
    // endCollection/finish, which would let watchOS save the workout. A timeout
    // force-finalises the discard if the `.ended` callback never arrives.
    private var pendingDiscard = false
    private var discardTimeoutTimer: Timer?
    private static let discardTimeout: TimeInterval = 5

    // HKWorkoutSession.startActivity silently fails if called before the HealthKit
    // auth request resolves, so a start that arrives early is deferred until then.
    private var authorizationComplete = false
    private var startWhenAuthorized = false

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
                self.pendingDiscard = true
                self.startDiscardTimeout()
                session.end()   // → didChangeTo .ended → finalizeDiscard (discards)
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
        guard !healthRequested else { return }   // already asked; the completion resolves it
        healthRequested = true
        // Workout-type WRITE access is required for HKWorkoutSession.startActivity
        // to succeed on watchOS — without it the session silently fails to start
        // and watchOS offers its own workout. (The watch still never saves one;
        // it always discards.) Energy/HR share lets the live builder collect HR.
        let share: Set<HKSampleType> = [HKObjectType.workoutType(),
                                        HKQuantityType(.activeEnergyBurned), hrType]
        let read: Set<HKObjectType> = [hrType]
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationComplete = true
                if success { self.startHeartRateQuery() }
                // A ride may have started while auth was still in flight; run the
                // deferred workout start now that startActivity won't silently fail.
                if self.startWhenAuthorized {
                    self.startWhenAuthorized = false
                    self.updateWorkout()
                }
            }
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
                self.evaluateHRWarning()
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
        guard workoutSession == nil, !pendingDiscard, HKHealthStore.isHealthDataAvailable(),
              healthUsageStringsPresent else { return }
        // Don't start until the HealthKit auth request has resolved, or
        // startActivity silently fails (no HR, watchOS offers its own workout).
        guard authorizationComplete else {
            startWhenAuthorized = true
            requestHealthAuthorization()   // no-op if already asked; completion re-runs the start
            return
        }
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
            // Collect into the builder so watchOS keeps the app running in an
            // active workout — this is what stops the "Start a workout?" prompt and
            // the app suspending when you lower your wrist (which was breaking the
            // live mirror, speed and heart-rate updates). The workout is ALWAYS
            // discarded at the end (see the session-state delegate), so the watch
            // never saves one — the phone owns the authoritative workout.
            builder.beginCollection(withStart: start) { _, _ in }
            workoutActive = true
            startHeartRateQuery()
        } catch {
            workoutSession = nil
        }
    }

    private func stopWorkout() {
        guard let session = workoutSession, !pendingDiscard else { return }
        pendingDiscard = true
        startDiscardTimeout()
        session.end()   // → didChangeTo .ended → finalizeDiscard (discards, never saves)
    }

    /// Discard the watch's workout once the session has ended — called from the
    /// `.ended`/failure delegate and from the safety timeout. Discards DIRECTLY:
    /// never endCollection/finishWorkout, which is what makes watchOS save it.
    /// The existence guard keeps a double call (delegate + timeout) idempotent.
    private func finalizeDiscard() {
        guard workoutSession != nil || builder != nil || pendingDiscard else { return }
        pendingDiscard = false
        discardTimeoutTimer?.invalidate()
        discardTimeoutTimer = nil
        builder?.discardWorkout()
        clearWorkout()
        updateWorkout()   // if a ride is somehow still active, start a fresh session
    }

    private func startDiscardTimeout() {
        discardTimeoutTimer?.invalidate()
        discardTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.discardTimeout,
                                                   repeats: false) { [weak self] _ in
            self?.finalizeDiscard()
        }
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

    /// How old a mirrored "running" state may be and still start/keep a ride.
    /// applicationContext is persisted and replayed on watch app activation, so
    /// without this a leftover "running" from a past ride/demo (whose final
    /// "idle" never transferred) would start a phantom workout session hours
    /// later — which watchOS then saves as an empty workout when the app dies.
    private static let mirrorFreshness: TimeInterval = 60

    private func apply(_ data: [String: Any]) {
        if let v = data["spdV"] as? Double { speedDisplay = v }
        if let v = data["spdU"] as? String { speedUnitLabel = v }
        if let v = data["dstV"] as? Double { distanceDisplay = v }
        if let v = data["dstU"] as? String { distanceUnitLabel = v }
        if let v = data["threat"] as? Int { threatLevel = v }
        nearestThreatMeters = data["nearest"] as? Int
        if let v = data["radarLost"] as? Bool { radarLost = v }
        if let v = data["hrWarn"] as? Int { hrWarningBpm = v }
        if let v = data["hapticsMuted"] as? Bool { hapticsMuted = v }
        if var s = data["status"] as? String {
            // Staleness guard: only a *recent* payload may claim an active ride.
            // A missing/old timestamp downgrades to idle (payloads are sent ~2 Hz
            // during a real ride, so a fresh one always follows within seconds).
            if s != "idle" {
                let sentAt = data["sentAt"] as? TimeInterval ?? 0
                if Date().timeIntervalSince1970 - sentAt > Self.mirrorFreshness {
                    s = "idle"
                }
            }
            statusRaw = s
            rideActive = (s != "idle")
            if rideActive { lastMirrorAt = Date() }
            updateWorkout()
            updateRideWatchdog()
        }
        updateHapticLoop()
        evaluateHRWarning()
    }

    // MARK: - Ride watchdog
    //
    // The phone mirrors state ~2 Hz during a ride. If those updates stop for
    // minutes while we still think a ride is running (phone app killed, link
    // gone), end and discard the workout session rather than letting an
    // orphaned session run until watchOS saves it as an empty workout.

    private var lastMirrorAt: Date?
    private var rideWatchdog: Timer?
    private static let mirrorTimeout: TimeInterval = 300   // 5 min without updates

    private func updateRideWatchdog() {
        if rideActive {
            guard rideWatchdog == nil else { return }
            rideWatchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
                [weak self] _ in self?.checkMirrorLiveness()
            }
        } else {
            rideWatchdog?.invalidate()
            rideWatchdog = nil
        }
    }

    private func checkMirrorLiveness() {
        guard rideActive,
              Date().timeIntervalSince(lastMirrorAt ?? .distantPast) > Self.mirrorTimeout
        else { return }
        statusRaw = "idle"
        rideActive = false
        updateWorkout()        // ends the session → discarded, never saved
        updateRideWatchdog()
        updateHapticLoop()
    }

    // MARK: - Heart-rate warning
    //
    // When the rider sets a max heart rate on the phone, the watch double-buzzes
    // and flips the HR readout red once their heart rate reaches it.

    /// Re-evaluate against the latest heart rate / threshold. Double-buzzes on
    /// the rising edge and again every 30 s while sustained; the red state clears
    /// once HR falls a few bpm back below (hysteresis stops it flickering).
    private func evaluateHRWarning() {
        let over = hrWarningBpm > 0 && heartRate >= hrWarningBpm
        if over {
            hrWarningActive = true
        } else if heartRate < hrWarningBpm - 3 {
            hrWarningActive = false
            lastHRWarnAt = nil               // re-arm so the next crossing buzzes
        }
        guard rideActive, over else { return }
        let now = Date()
        if lastHRWarnAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            playHeartRateWarningHaptic()
            lastHRWarnAt = now
        }
    }

    /// Distinct from car taps: a double notification buzz meaning "heart rate high".
    private func playHeartRateWarningHaptic() {
        let device = WKInterfaceDevice.current()
        device.play(.notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { device.play(.notification) }
    }

    // MARK: - Proximity haptics
    //
    // While a vehicle is behind, the wrist is tapped repeatedly, getting faster
    // and stronger as the car closes in.

    private var hapticTimer: Timer?

    /// Start the wrist-tap loop when a car appears, stop it when the lane clears.
    /// Gated on an active ride so a stale mirror can't tap the wrist while idle.
    private func updateHapticLoop() {
        let carPresent = threatLevel >= 0 && rideActive && !hapticsMuted
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
        // Strongest available wrist buzz for EVERY car, at any distance (rider's
        // request). watchOS has no amplitude control, so we use the firm
        // `.notification` pattern played twice for maximum noticeability. Urgency
        // is conveyed by cadence (scheduleNextHaptic), which tightens as a car
        // closes in — not by varying the strength.
        let device = WKInterfaceDevice.current()
        device.play(.notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { device.play(.notification) }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // Apply the last-known state immediately, so opening the app mid-ride
        // picks up the running status (and starts the HR session) without waiting
        // for the next push from the phone.
        let ctx = session.receivedApplicationContext
        if !ctx.isEmpty { DispatchQueue.main.async { self.apply(ctx) } }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.apply(applicationContext) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            if let active = message["sosActive"] as? Bool {
                self.applySOS(active: active,
                              seconds: message["sosSeconds"] as? Int ?? 0,
                              name: message["sosName"] as? String ?? "",
                              phone: message["sosPhone"] as? String ?? "")
            } else if let event = message["event"] as? String {
                self.playEventHaptic(event)       // one-shot wrist alert
            } else {
                self.apply(message)               // live ride mirror
            }
        }
    }

    /// Mirror the phone's crash-SOS state: buzz hard while it's live so a
    /// dazed rider notices the wrist, and keep buzzing through the call stage
    /// until someone dismisses it.
    private func applySOS(active: Bool, seconds: Int, name: String, phone: String) {
        let wasActive = sosActive
        sosActive = active
        sosSeconds = seconds
        if !name.isEmpty { sosContactName = name }
        if !phone.isEmpty { sosContactPhone = phone }
        if active && !wasActive {
            sosHapticTimer?.invalidate()
            sosHapticTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
                WKInterfaceDevice.current().play(.failure)
            }
            WKInterfaceDevice.current().play(.failure)
        } else if !active {
            sosHapticTimer?.invalidate()
            sosHapticTimer = nil
        }
    }

    /// "I'm OK" from the wrist: dismiss here and tell the phone to stand down.
    func cancelSOS() {
        sosActive = false
        sosHapticTimer?.invalidate()
        sosHapticTimer = nil
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["sosCancel": true], replyHandler: nil, errorHandler: nil)
        }
    }

    /// Ring the emergency contact from the wrist — relayed through the phone
    /// when in Bluetooth range, or directly on cellular models. This is the
    /// action that works when the phone is on the bike and the rider isn't.
    func callEmergencyContact() {
        let digits = sosContactPhone.filter { "+0123456789".contains($0) }
        guard !digits.isEmpty, let url = URL(string: "tel:\(digits)") else { return }
        WKExtension.shared().openSystemURL(url)
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
        case "turn":
            // Route turn coming up — distinct from car taps; the phone
            // speaks which way.
            device.play(.directionUp)
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
        // DISCARD, never finish — the phone saves the authoritative workout (with
        // the GPS route), so the watch must never save its own.
        if toState == .ended {
            DispatchQueue.main.async { [weak self] in self?.finalizeDiscard() }
        }
    }

    private func clearWorkout() {
        workoutSession = nil
        builder = nil
        workoutActive = false
        heartRate = 0
        hrWarningActive = false
        lastHRWarnAt = nil
    }

    func workoutSession(_ session: HKWorkoutSession, didFailWithError error: Error) {
        // Treat a failed session like an end — discard so nothing is saved.
        DispatchQueue.main.async { [weak self] in self?.finalizeDiscard() }
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
            self.evaluateHRWarning()
        }
    }
}

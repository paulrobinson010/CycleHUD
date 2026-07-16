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
    /// True while mirroring the phone's DEMO: display like a ride, no workout.
    private var workoutSuppressed = false

    /// Start/stop the workout session. A live `HKWorkoutSession` is the single
    /// biggest battery drain on the watch, so we run it ONLY during an actual
    /// ride — never just because the app is on screen, and never for the
    /// phone's demo. When idle, heart rate comes from the low-power HealthKit
    /// sample stream (startHeartRateQuery).
    private func updateWorkout() {
        let want = rideActive && !workoutSuppressed
        if want, workoutSession == nil {
            startWorkout()
        } else if !want, workoutSession != nil {
            stopWorkout(reason: workoutSuppressed ? "demo mirror"
                                                  : "ride over (status \(statusRaw))")
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
        wlog("watch app \(buildStamp) launched")
    }

    // MARK: - Event log (relayed to the phone's diagnostics)
    //
    // Session lifecycle events are the evidence we need when the watch drops
    // heart rate in the field: every start/stop/discard/failure is stamped,
    // kept on-screen (last few lines) and relayed to the phone, where it lands
    // in AppLog with a WATCH: prefix — readable post-ride from Diagnostics.

    @Published private(set) var recentLog: [String] = []

    /// "v1.0 (7)" — shown on the watch face so a stale install is obvious.
    var buildStamp: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v)(\(b))"
    }

    private func wlog(_ line: String) {
        let entry = "\(Date().formatted(date: .omitted, time: .standard)) \(line)"
        print("WATCHLOG \(entry)")
        DispatchQueue.main.async {
            self.recentLog.append(entry)
            if self.recentLog.count > 10 {
                self.recentLog.removeFirst(self.recentLog.count - 10)
            }
        }
        guard WCSession.default.activationState == .activated else { return }
        let payload = ["watchLog": entry]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(payload)   // queue it instead
            }
        } else {
            WCSession.default.transferUserInfo(payload)       // queued, survives background
        }
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
        // Workout READ access lets the purge below find (and delete) any
        // workout this app accidentally saved.
        let read: Set<HKObjectType> = [hrType, HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationComplete = true
                if success {
                    self.startHeartRateQuery()
                    self.purgeAccidentalWorkouts()
                }
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
            wlog("session start deferred until HealthKit auth resolves")
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
            wlog("workout session started")
        } catch {
            workoutSession = nil
            wlog("session create FAILED: \(error.localizedDescription)")
        }
    }

    private func stopWorkout(reason: String) {
        guard let session = workoutSession, !pendingDiscard else { return }
        wlog("ending session — \(reason)")
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
        wlog("session discarded")
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

    private func apply(_ data: [String: Any], replay: Bool = false) {
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
            // Staleness guard: only a *recent* payload may START a ride — a
            // replayed applicationContext hours after a dead ride was starting
            // phantom workout sessions. But a stale payload must never STOP a
            // live one: watchOS coalesces context transfers, so right after a
            // Bluetooth hiccup mid-ride the queued context arrives minutes old,
            // and downgrading it to idle killed the workout session (and with
            // it the app's keep-alive and the heart-rate stream) on every link
            // burp. While a ride is already active, abandonment is the 5-minute
            // watchdog's call, not this guard's.
            if s != "idle" {
                let sentAt = data["sentAt"] as? TimeInterval ?? 0
                let age = Date().timeIntervalSince1970 - sentAt
                if replay {
                    // Replayed contexts (app launch, wrist-raise) are history,
                    // not news. The phone pushes context at least every ~2 s
                    // while riding, so anything older than 15 s means the ride
                    // is over or the phone is gone — and unlike live mirrors,
                    // a stale REPLAY also ENDS a lingering session: it's how a
                    // watch that missed the final "idle" recovers the moment
                    // the rider looks at it.
                    if age > 15 {
                        wlog("replayed \(s) context is \(Int(age)) s old — treating as idle")
                        s = "idle"
                    }
                } else if !rideActive, age > Self.mirrorFreshness {
                    wlog("stale \(s) mirror (\(Int(age)) s old) — not starting a ride from it")
                    s = "idle"
                }
            }
            if rideActive, s == "idle" {
                wlog("mirror says idle — ride over\(replay ? " (from replayed context)" : "")")
            }
            // The phone's demo: display exactly like a running ride, but NEVER
            // start a workout session for it — a session orphaned when watchOS
            // suspends the app right after a short demo is eventually saved by
            // the system as a phantom empty workout. Demos are watched wrist-up,
            // so nothing needs the workout keep-alive.
            workoutSuppressed = (s == "demo")
            if workoutSuppressed { s = "running" }
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
    /// Generous on purpose: the session is ALWAYS discarded (never saved), so
    /// a long-lived orphan can't pollute Health — the watchdog only guards
    /// battery. The old 5-minute timeout was killing live rides whenever
    /// mirror delivery went quiet with the app backgrounded, which dropped
    /// the workout keep-alive, suspended the app and lost heart rate.
    private static let mirrorTimeout: TimeInterval = 1800   // 30 min without updates

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
        // A reachable phone means the link is alive even if mirrors aren't
        // being parsed right now — never kill a ride out from under it.
        guard rideActive, !WCSession.default.isReachable,
              Date().timeIntervalSince(lastMirrorAt ?? .distantPast) > Self.mirrorTimeout
        else { return }
        wlog("watchdog: 30 min without mirrors and phone unreachable — ending ride")
        statusRaw = "idle"
        rideActive = false
        updateWorkout()        // ends the session → discarded, never saved
        updateRideWatchdog()
        updateHapticLoop()
    }

    /// Re-apply the last mirrored state — applicationContext persists across
    /// launches — so a watch app reopened mid-ride restarts its workout
    /// session on the spot instead of waiting for the next push. The
    /// staleness guard still stops a long-dead "running" from starting a
    /// phantom session.
    func refreshFromContext() {
        let ctx = WCSession.default.receivedApplicationContext
        if !ctx.isEmpty { apply(ctx, replay: true) }
        purgeAccidentalWorkouts()
    }

    // MARK: - Phantom-workout purge
    //
    // The watch must NEVER own a saved workout — the phone saves the
    // authoritative one. But if watchOS suspends the app in the gap between
    // session.end() and the discard callback, the system finalises the orphan
    // itself and SAVES it as an empty workout (one bad morning of link churn
    // minted 21 of them). So any workout this app's source ever saved is by
    // definition an accident: find them all and delete them, including
    // historical strays from before this backstop existed.

    private var lastPurgeAt = Date.distantPast

    private func purgeAccidentalWorkouts() {
        guard HKHealthStore.isHealthDataAvailable(), healthUsageStringsPresent,
              authorizationComplete, !rideActive,
              Date().timeIntervalSince(lastPurgeAt) > 300 else { return }
        lastPurgeAt = Date()
        let ownSource = HKQuery.predicateForObjects(from: HKSource.default())
        let query = HKSampleQuery(sampleType: .workoutType(), predicate: ownSource,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) {
            [weak self] _, samples, _ in
            guard let self, let workouts = samples, !workouts.isEmpty else { return }
            self.healthStore.delete(workouts) { done, error in
                self.wlog("purged \(workouts.count) accidental workout(s): "
                          + (done ? "OK" : error?.localizedDescription ?? "failed"))
            }
        }
        healthStore.execute(query)
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
        if !ctx.isEmpty { DispatchQueue.main.async { self.apply(ctx, replay: true) } }
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
            // speaks which way. Gated on an active ride like the car taps.
            guard rideActive else { break }
            device.play(.directionUp)
        case "routeDone":
            // Route completed — a celebratory double success tap.
            device.play(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { device.play(.success) }
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
        // the GPS route), so the watch must never save its own. finalizeDiscard
        // re-runs updateWorkout afterwards, so a session that ended WITHOUT us
        // asking (watchOS reclaiming it, water lock, a system stop) restarts
        // immediately while the ride is still active.
        wlog("session state \(fromState.rawValue) → \(toState.rawValue)")
        switch toState {
        case .ended:
            DispatchQueue.main.async { [weak self] in self?.finalizeDiscard() }
        case .stopped:
            // A stop we didn't request: drive it to .ended so the discard +
            // restart path runs.
            session.end()
        default:
            break
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
        wlog("session FAILED: \(error.localizedDescription)")
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

import Foundation
import Combine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone side of the iPhone ⇄ Apple Watch link.
///
/// - Receives live **heart rate** from the Watch (which runs a workout session
///   to access the sensor) for HR-based calories and the HR tile.
/// - Sends the Watch a compact **mirror payload** (speed, distance, ride state,
///   radar threat level) to display, and one-shot **new-car haptic** triggers.
///
/// Designed to no-op gracefully when no Watch is paired/reachable.
final class WatchConnectivityManager: NSObject, ObservableObject {

    @Published private(set) var latestHeartRate: Int?
    private var heartRateUpdatedAt: Date?

    #if canImport(WatchConnectivity)
    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }
    #endif

    override init() {
        super.init()
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        #endif
    }

    /// Fresh heart rate, or nil if the Watch hasn't reported recently.
    func freshHeartRate(staleAfter seconds: TimeInterval = 6) -> Int? {
        guard let hr = latestHeartRate, let at = heartRateUpdatedAt else { return nil }
        return Date().timeIntervalSince(at) <= seconds ? hr : nil
    }

    /// Heart rate for on-screen display. Short window so a value only shows while
    /// the Watch is actively feeding it — once the Watch app is off/stale, the
    /// tile clears to "—" rather than showing a minutes-old reading. (During a
    /// ride the Watch streams HR every few seconds, so this won't flicker.)
    var displayHeartRate: Int? { freshHeartRate(staleAfter: 20) }

    // MARK: - Outgoing

    /// Push the current ride state to the Watch face (best-effort, low priority).
    func sendMirror(speedMps: Double, distanceMeters: Double, rideStatusRaw: String,
                    threatLevel: Int, nearestThreatMeters: Int?, radarLost: Bool,
                    hrWarningBpm: Int) {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated else { return }
        var payload: [String: Any] = [
            "speed": speedMps,
            "distance": distanceMeters,
            "status": rideStatusRaw,
            "threat": threatLevel,
            "radarLost": radarLost,
            "hrWarn": hrWarningBpm
        ]
        if let nearestThreatMeters { payload["nearest"] = nearestThreatMeters }
        // applicationContext is the reliable background path (latest state always
        // gets through), but it's coalesced and slow. When the Watch app is open
        // (reachable), also push it live via sendMessage so speed/HR update in
        // real time and the Watch starts its workout promptly.
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        #endif
    }

    /// Tell the Watch to tap the wrist for a newly-detected vehicle.
    func sendNewCarHaptic() {
        #if canImport(WatchConnectivity)
        guard let session, session.isReachable else { return }
        session.sendMessage(["event": "newCar"], replyHandler: nil, errorHandler: nil)
        #endif
    }

    /// Tell the Watch the radar has dropped out — a distinct safety alert.
    func sendRadarLostHaptic() {
        #if canImport(WatchConnectivity)
        guard let session, session.isReachable else { return }
        session.sendMessage(["event": "radarLost"], replyHandler: nil, errorHandler: nil)
        #endif
    }
}

#if canImport(WatchConnectivity)
extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate for a possibly-switched Watch.
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncoming(applicationContext)
    }

    private func handleIncoming(_ message: [String: Any]) {
        guard let hr = message["heartRate"] as? Double else { return }
        DispatchQueue.main.async {
            self.latestHeartRate = Int(hr.rounded())
            self.heartRateUpdatedAt = Date()
        }
    }
}
#endif

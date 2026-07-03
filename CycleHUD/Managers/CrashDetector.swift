import Foundation
import CoreMotion

/// Watches the accelerometer for a sharp impact during a ride, to trigger the
/// SOS flow. Runs only while a ride is active (started/stopped by RideManager)
/// so it costs nothing when idle.
///
/// Detection is deliberately simple — a spike in gravity-removed acceleration
/// above a threshold — because the SOS countdown lets the rider cancel a false
/// positive (a dropped phone, a kerb hop). The threshold is easy to tune.
final class CrashDetector {

    private let motion = CMMotionManager()
    private let queue = OperationQueue()

    /// Impact threshold in g (gravity already removed by device motion). Road
    /// riding proved 4 g far too twitchy — potholes and kerbs fired it — so this
    /// demands a genuinely violent spike. The stop-confirmation in RideManager
    /// (rider must be stationary within seconds) does the real filtering; this
    /// just needs to be above ordinary road chatter.
    private let impactThresholdG = 8.0
    /// Don't re-trigger within this window (one event, not a burst).
    private let cooldown: TimeInterval = 30
    private var lastTrigger: Date?

    /// Called on the main thread when a likely impact is detected.
    var onCrash: (() -> Void)?

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.02   // 50 Hz — impacts are brief
        queue.maxConcurrentOperationCount = 1
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.userAcceleration
            let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            if g >= self.impactThresholdG { self.fire() }
        }
    }

    func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    private func fire() {
        let now = Date()
        if let last = lastTrigger, now.timeIntervalSince(last) < cooldown { return }
        lastTrigger = now
        DispatchQueue.main.async { [weak self] in self?.onCrash?() }
    }
}

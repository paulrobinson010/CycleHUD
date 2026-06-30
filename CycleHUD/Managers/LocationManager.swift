import Foundation
import CoreLocation
import Combine

/// Wraps CoreLocation to provide GPS speed and feed location fixes to the
/// ride recorder for distance integration.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    @Published var speedMps: Double = 0          // GPS-derived ground speed (>= 0)
    @Published var altitudeMeters: Double?       // GPS altitude above sea level
    @Published var courseDegrees: Double?        // direction of travel (last valid)
    @Published var hasFix: Bool = false
    @Published var horizontalAccuracy: Double = -1
    @Published var authorization: CLAuthorizationStatus = .notDetermined

    /// Called for every accepted location fix (used for distance accumulation).
    var onLocation: ((CLLocation) -> Void)?

    /// The most recent accepted fix, kept across mode changes for one-off needs
    /// like a weather lookup (distinct from `lastAcceptedLocation`, which resets
    /// per ride for speed derivation).
    private(set) var currentLocation: CLLocation?

    private var lastAcceptedLocation: CLLocation?   // for position-derived speed

    /// Power profile for GPS. Full-accuracy navigation GPS is a heavy battery
    /// drain, so we only use it while actually recording a ride; when idle on the
    /// main screen we drop to a low-power fix just to show GPS is available.
    enum Mode { case off, idle, recording }
    private(set) var mode: Mode = .off

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Apply a power profile. `.idle` is a low-power fix for the GPS indicator;
    /// `.recording` is full accuracy with background updates for the ride.
    func setMode(_ newMode: Mode) {
        mode = newMode
        switch newMode {
        case .off:
            manager.allowsBackgroundLocationUpdates = false
            manager.stopUpdatingLocation()
            lastAcceptedLocation = nil
            hasFix = false
        case .idle:
            manager.allowsBackgroundLocationUpdates = false
            manager.pausesLocationUpdatesAutomatically = true
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
            manager.startUpdatingLocation()
            lastAcceptedLocation = nil   // don't carry a speed reference across rides
        case .recording:
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
            manager.startUpdatingLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            if mode != .off { setMode(mode) }   // (re)start with the current power profile
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // Reject stale/cached fixes. CoreLocation hands back the last known
        // location first (and after a pause), which can be old and far away —
        // the "GPS memory" that inflates distance/average and reports a wrong
        // speed. Only trust fixes from the last few seconds.
        guard abs(loc.timestamp.timeIntervalSinceNow) < 5 else { return }

        horizontalAccuracy = loc.horizontalAccuracy
        // Reject obviously bad fixes. While recording we demand a tight fix for
        // distance/speed quality; when idle (low-power GPS) we accept a coarser
        // one just to light the "GPS ready" indicator.
        let accuracyLimit: Double = mode == .recording ? 50 : 150
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < accuracyLimit else { return }

        hasFix = true

        // Ground speed: start from the GPS Doppler value (accurate while moving,
        // but -1 when unavailable and occasionally stuck low). Correct it upward
        // with a position-derived speed ONLY when the movement clearly exceeds the
        // GPS error — so standstill jitter can't invent speed, but a genuinely
        // under-reporting Doppler gets caught.
        var speed = max(0, loc.speed)
        if let last = lastAcceptedLocation {
            let dt = loc.timestamp.timeIntervalSince(last.timestamp)
            let moved = loc.distance(from: last)
            if dt > 0.3, dt < 10, moved > max(loc.horizontalAccuracy, 2) {
                speed = max(speed, moved / dt)   // take the higher of the two
            }
        }
        speedMps = speed
        lastAcceptedLocation = loc
        currentLocation = loc

        if loc.verticalAccuracy > 0 { altitudeMeters = loc.altitude }
        // Course is only meaningful when moving; keep the last valid heading so a
        // momentary stop doesn't blank the headwind/tailwind reading.
        if loc.course >= 0, loc.speed > 0.8 { courseDegrees = loc.course }
        onLocation?(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient GPS errors are expected; nothing to do.
    }
}

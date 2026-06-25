import Foundation
import CoreLocation
import Combine

/// Wraps CoreLocation to provide GPS speed and feed location fixes to the
/// ride recorder for distance integration.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()

    @Published var speedMps: Double = 0          // GPS-derived ground speed (>= 0)
    @Published var altitudeMeters: Double?       // GPS altitude above sea level
    @Published var hasFix: Bool = false
    @Published var horizontalAccuracy: Double = -1
    @Published var authorization: CLAuthorizationStatus = .notDetermined

    /// Called for every accepted location fix (used for distance accumulation).
    var onLocation: ((CLLocation) -> Void)?

    private var lastAcceptedLocation: CLLocation?   // for position-derived speed

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Begin continuous updates. `background` enables updates while the screen
    /// is locked (used while a ride is recording).
    func start(background: Bool) {
        if background {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
        }
        manager.startUpdatingLocation()
    }

    func stop(background: Bool) {
        if background {
            manager.allowsBackgroundLocationUpdates = false
        }
        manager.stopUpdatingLocation()
        lastAcceptedLocation = nil   // don't carry a speed reference across rides
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
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
        // Reject obviously bad fixes.
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { return }

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

        if loc.verticalAccuracy > 0 { altitudeMeters = loc.altitude }
        onLocation?(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient GPS errors are expected; nothing to do.
    }
}

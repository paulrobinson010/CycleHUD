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

        horizontalAccuracy = loc.horizontalAccuracy
        // Reject obviously bad fixes.
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { return }

        hasFix = true
        speedMps = max(0, loc.speed)   // loc.speed is -1 when unavailable
        if loc.verticalAccuracy > 0 { altitudeMeters = loc.altitude }
        onLocation?(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient GPS errors are expected; nothing to do.
    }
}

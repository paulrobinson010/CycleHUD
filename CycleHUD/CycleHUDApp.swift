import SwiftUI

@main
struct CycleHUDApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var ble: BluetoothManager
    @StateObject private var location: LocationManager
    @StateObject private var health: HealthKitManager
    @StateObject private var watch: WatchConnectivityManager
    @StateObject private var ride: RideManager

    init() {
        AppLog.shared.installCrashHandlers()
        AppLog.shared.prune()                 // keep ~14 days
        AppLog.shared.log("=== App launch ===")
        let settings = AppSettings()
        let ble = BluetoothManager(settings: settings)
        let location = LocationManager()
        let health = HealthKitManager()
        let watch = WatchConnectivityManager()
        let ride = RideManager(ble: ble, location: location, settings: settings,
                               health: health, watch: watch)
        _settings = StateObject(wrappedValue: settings)
        _ble = StateObject(wrappedValue: ble)
        _location = StateObject(wrappedValue: location)
        _health = StateObject(wrappedValue: health)
        _watch = StateObject(wrappedValue: watch)
        _ride = StateObject(wrappedValue: ride)
    }

    var body: some Scene {
        WindowGroup {
            RideView()
                .environmentObject(settings)
                .environmentObject(ble)
                .environmentObject(location)
                .environmentObject(ride)
                .environmentObject(watch)
                .preferredColorScheme(.dark)
                .onAppear {
                    location.requestAuthorization()
                    location.start(background: false)
                    health.requestAuthorization()
                }
        }
    }
}

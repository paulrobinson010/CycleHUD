import SwiftUI

@main
struct CycleHUDApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var ble: BluetoothManager
    @StateObject private var location: LocationManager
    @StateObject private var ride: RideManager

    init() {
        let settings = AppSettings()
        let ble = BluetoothManager(settings: settings)
        let location = LocationManager()
        let ride = RideManager(ble: ble, location: location, settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _ble = StateObject(wrappedValue: ble)
        _location = StateObject(wrappedValue: location)
        _ride = StateObject(wrappedValue: ride)
    }

    var body: some Scene {
        WindowGroup {
            RideView()
                .environmentObject(settings)
                .environmentObject(ble)
                .environmentObject(location)
                .environmentObject(ride)
                .preferredColorScheme(.dark)
                .onAppear {
                    location.requestAuthorization()
                    location.start(background: false)
                }
        }
    }
}

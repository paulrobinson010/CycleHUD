import SwiftUI
import UIKit

/// Gates which interface orientations the app allows. The Info.plist lists all
/// orientations, but this delegate is the runtime authority: it stays portrait
/// unless the rider turns on the landscape layout in Settings.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

@main
struct CycleHUDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var ble: BluetoothManager
    @StateObject private var location: LocationManager
    @StateObject private var health: HealthKitManager
    @StateObject private var watch: WatchConnectivityManager
    @StateObject private var history: RideHistory
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
        let history = RideHistory()
        let ride = RideManager(ble: ble, location: location, settings: settings,
                               health: health, watch: watch, history: history)
        _settings = StateObject(wrappedValue: settings)
        _ble = StateObject(wrappedValue: ble)
        _location = StateObject(wrappedValue: location)
        _health = StateObject(wrappedValue: health)
        _watch = StateObject(wrappedValue: watch)
        _history = StateObject(wrappedValue: history)
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
                .environmentObject(history)
                .preferredColorScheme(.dark)
                .onAppear {
                    location.requestAuthorization()
                    location.start(background: false)
                    health.requestAuthorization()
                    applyOrientation(settings.landscapeEnabled)
                }
                .onChange(of: settings.landscapeEnabled) { _, on in
                    applyOrientation(on)
                }
        }
    }

    /// Allow (or forbid) landscape, and snap back to portrait when the rider
    /// turns the landscape layout off while the phone is rotated.
    private func applyOrientation(_ landscape: Bool) {
        AppDelegate.orientationLock = landscape ? .allButUpsideDown : .portrait
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if !landscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}

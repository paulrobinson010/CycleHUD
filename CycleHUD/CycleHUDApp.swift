import SwiftUI
import UIKit

/// Gates which interface orientations the app allows. The Info.plist lists all
/// orientations, but this delegate is the runtime authority: screens lock
/// themselves to portrait or landscape via `lock(_:rotateTo:)`. Default portrait.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    /// Restrict the app to `mask` and rotate the interface into `rotateTo` now.
    /// The landscape HUD locks to `.landscape`; portrait screens lock to
    /// `.portrait`, so the phone is fixed rather than rotation-driven.
    ///
    /// No-ops when the lock is already `mask`: several `onChange` hooks call this
    /// with the same target (e.g. re-asserting portrait while Settings is open),
    /// and re-issuing the geometry update makes the interface visibly flip twice.
    static func lock(_ mask: UIInterfaceOrientationMask, rotateTo: UIInterfaceOrientationMask) {
        guard mask != orientationLock else { return }
        orientationLock = mask
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: rotateTo))
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
    @StateObject private var weather: WeatherManager
    @StateObject private var sos: SOSManager
    /// Branded splash (website hero) shown over the HUD at launch, then faded.
    @State private var showSplash = true

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
        let sos = SOSManager()
        let ride = RideManager(ble: ble, location: location, settings: settings,
                               health: health, watch: watch, history: history, sos: sos)
        let weather = WeatherManager()
        _settings = StateObject(wrappedValue: settings)
        _ble = StateObject(wrappedValue: ble)
        _location = StateObject(wrappedValue: location)
        _health = StateObject(wrappedValue: health)
        _watch = StateObject(wrappedValue: watch)
        _history = StateObject(wrappedValue: history)
        _ride = StateObject(wrappedValue: ride)
        _weather = StateObject(wrappedValue: weather)
        _sos = StateObject(wrappedValue: sos)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                mainContent
                if showSplash {
                    SplashView()
                        .zIndex(1)
                        .transition(.opacity)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation(.easeOut(duration: 0.5)) { showSplash = false }
                }
            }
        }
    }

    private var mainContent: some View {
        RideView()
            .environmentObject(settings)
            .environmentObject(ble)
            .environmentObject(location)
            .environmentObject(ride)
            .environmentObject(watch)
            .environmentObject(history)
            .environmentObject(weather)
            .environmentObject(sos)
            .preferredColorScheme(settings.appearanceTheme.colorScheme)
            .onAppear {
                location.requestAuthorization()
                location.setMode(.idle)        // low-power fix until a ride starts
                health.requestAuthorization()
                NotificationManager.shared.configure()
                NotificationManager.shared.requestAuthorization()
                weather.locationProvider = { location.currentLocation }
                weather.isEnabled = { settings.weatherEnabled }
                weather.start()
                sos.locationProvider = { location.currentLocation }
                sos.contactProvider = { settings.emergencyContact }
                sos.stateChanged = { active, seconds in
                    watch.sendSOSState(active: active, secondsRemaining: seconds,
                                       contactName: settings.emergencyContactName,
                                       contactPhone: settings.emergencyContactPhone)
                }
                watch.onSOSCancel = {
                    sos.cancel()
                    sos.composerFinished()
                }
            }
    }
}

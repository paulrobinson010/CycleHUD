import Foundation
import CoreLocation
import CoreBluetooth
import HealthKit
import UIKit

/// A missing OS permission the app needs, with rider-facing guidance on the fix.
struct PermissionIssue: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    /// Whether the fix lives on the app's own iOS Settings page (Location,
    /// Bluetooth) — Health sharing is set in the Health app instead.
    let opensAppSettings: Bool
}

/// Checks the permissions CycleHUD relies on and explains how to fix any that are
/// off. Health *sharing* (workouts / active energy) is only required when the
/// rider has chosen to save rides as workouts.
enum Permissions {
    private static let locationManager = CLLocationManager()
    private static let healthStore = HKHealthStore()

    static func currentIssues(saveWorkouts: Bool) -> [PermissionIssue] {
        var issues: [PermissionIssue] = []

        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            issues.append(.init(id: "location",
                title: String(localized: "Location is off"),
                message: String(localized: "CycleHUD needs Location to record your speed, distance and route. Turn it on in Settings → CycleHUD → Location, set to “While Using the App”."),
                opensAppSettings: true))
        default: break
        }

        switch CBManager.authorization {
        case .denied, .restricted:
            issues.append(.init(id: "bluetooth",
                title: String(localized: "Bluetooth is off"),
                message: String(localized: "CycleHUD needs Bluetooth to connect to your radar and sensors. Allow it in Settings → CycleHUD → Bluetooth."),
                opensAppSettings: true))
        default: break
        }

        if saveWorkouts, HKHealthStore.isHealthDataAvailable() {
            let workoutDenied = healthStore.authorizationStatus(for: .workoutType()) == .sharingDenied
            let energyDenied = healthStore.authorizationStatus(for: HKQuantityType(.activeEnergyBurned)) == .sharingDenied
            if workoutDenied || energyDenied {
                issues.append(.init(id: "health",
                    title: String(localized: "Health access is off"),
                    message: String(localized: "CycleHUD can't save your rides as workouts. Open the Health app → Sharing → Apps → CycleHUD and allow Workouts and Active Energy — or turn off “Save rides as workouts”."),
                    opensAppSettings: false))
            }
        }

        return issues
    }

    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

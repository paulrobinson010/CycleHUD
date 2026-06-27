import Foundation
import UserNotifications

/// Local notifications. Used to remind the rider to switch off sensors that were
/// left on after a ride — the radar and CSC sensors run on their own batteries.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Cached so the sensor-reminder monitor can skip its (battery-costing) work
    /// entirely when notifications are off — no point keeping sensors alive to
    /// fire a reminder that can't be shown.
    private(set) var isAuthorized = false

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.isAuthorized = granted }
        }
    }

    /// Fire the "sensors still on" reminder now. `names` are the human role names
    /// of the sensors still connected (e.g. ["Radar", "Cadence"]).
    func notifySensorsLeftOn(_ names: [String]) {
        guard !names.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sensors still on"
        content.body = Self.body(for: names)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "sensors-still-on",
                                            content: content, trigger: nil)   // deliver now
        UNUserNotificationCenter.current().add(request)
    }

    static func body(for names: [String]) -> String {
        let list: String
        switch names.count {
        case 1:  list = names[0]
        case 2:  list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + " and \(names.last!)"
        }
        let isAre = names.count == 1 ? "is" : "are"
        let itThem = names.count == 1 ? "it" : "them"
        return "\(list) \(isAre) still connected after your ride. Switch \(itThem) off to save battery."
    }

    // Show the reminder even if the app happens to be in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

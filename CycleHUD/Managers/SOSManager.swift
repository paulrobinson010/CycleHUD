import Foundation
import CoreLocation
import Combine
import UIKit

/// Drives the post-crash SOS flow: a cancellable countdown, then a pre-filled
/// emergency text to the rider's contact with their location.
///
/// iOS can't send an SMS fully automatically (no app may send a text without the
/// user tapping Send), so when the countdown elapses we present a pre-filled
/// message composer for the rider — or a bystander — to send. The countdown and
/// the loud alert are there to get attention and let the rider cancel a false
/// alarm.
final class SOSManager: ObservableObject {

    /// Seconds the rider has to cancel before the alert is raised.
    let countdownSeconds = 20

    @Published private(set) var isCountingDown = false
    @Published private(set) var secondsRemaining = 0
    /// Drives presentation of the message composer (countdown elapsed or the
    /// rider tapped "Send now").
    @Published var presentComposer = false

    /// Supplied by the app.
    var locationProvider: (() -> CLLocation?)?
    var contactProvider: (() -> (name: String, phone: String)?)?
    /// Mirrors the SOS to the Apple Watch (active = countdown or composer up),
    /// so a rider thrown clear of the bike can cancel — or call — from the
    /// wrist while the phone stays mounted out of reach.
    var stateChanged: ((_ active: Bool, _ secondsRemaining: Int) -> Void)?

    private var timer: Timer?

    /// Whether an emergency contact is configured (otherwise SOS is pointless).
    var hasContact: Bool { contactProvider?() != nil }

    /// Start the cancellable countdown. No-op if already running, mid-compose, or
    /// no contact is set.
    func trigger() {
        guard !isCountingDown, !presentComposer, hasContact else { return }
        secondsRemaining = countdownSeconds
        isCountingDown = true
        stateChanged?(true, secondsRemaining)
        AudioAlerts.shared.playSOSAlert()
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickDown()
        }
    }

    private func tickDown() {
        secondsRemaining -= 1
        stateChanged?(true, max(0, secondsRemaining))
        if secondsRemaining % 5 == 0 { AudioAlerts.shared.playSOSAlert() }
        if secondsRemaining <= 0 { sendNow() }
    }

    /// Rider is OK — abandon the alert.
    func cancel() {
        timer?.invalidate(); timer = nil
        isCountingDown = false
        secondsRemaining = 0
        stateChanged?(false, 0)
    }

    /// Skip the rest of the countdown and raise the alert now. The Watch stays
    /// in SOS mode (its call button matters most when the phone is out of
    /// reach) until the rider dismisses on either device.
    func sendNow() {
        timer?.invalidate(); timer = nil
        isCountingDown = false
        secondsRemaining = 0
        presentComposer = true
        stateChanged?(true, 0)
    }

    func composerFinished() {
        presentComposer = false
        stateChanged?(false, 0)
    }

    // MARK: - Message content

    var recipients: [String] {
        contactProvider?().map { [$0.phone] } ?? []
    }

    /// Pre-filled emergency text, including a maps link to the current location.
    var messageBody: String {
        var text = String(localized: "I may have crashed while cycling and might need help.",
                          bundle: Lang.bundle)
        if let loc = locationProvider?() {
            let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
            let coords = String(format: "%.5f, %.5f", lat, lon)
            let link = "https://maps.apple.com/?ll=\(lat),\(lon)"
            text += "\n\n" + String(localized: "My location: \(coords)", bundle: Lang.bundle) + "\n" + link
        }
        return text
    }
}

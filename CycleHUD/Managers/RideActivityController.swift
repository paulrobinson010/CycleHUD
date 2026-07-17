import Foundation
import ActivityKit

/// Runs the ride's Live Activity (Lock Screen banner / Dynamic Island):
/// started with the ride, updated from the ride ticker, ended with the ride.
/// Updates are throttled to every few seconds except for the moments
/// that matter — a vehicle appearing, threat level changing, pausing — which
/// go out immediately.
final class RideActivityController {
    private var activity: Activity<RideActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: RideActivityAttributes.ContentState?

    func start(speedUnit: SpeedUnit, distanceUnit: DistanceUnit,
               state: RideActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        // A restored ride (app killed mid-ride) may still have its Live
        // Activity up — adopt it rather than stacking a second one.
        if let existing = Activity<RideActivityAttributes>.activities.first {
            activity = existing
            update(state)
            return
        }
        let attributes = RideActivityAttributes(
            speedUnitLabel: speedUnit.label,
            distanceUnitLabel: distanceUnit.label,
            speedFactor: speedUnit.value(fromMps: 1),
            distanceFactor: distanceUnit == .km ? 0.001 : 1 / 1609.344)
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil))
        lastState = state
        lastUpdate = Date()
    }

    func update(_ state: RideActivityAttributes.ContentState) {
        guard let activity else { return }
        guard state != lastState else { return }
        // Threat/pause/radar transitions jump the throttle; steady metrics
        // wait. 6 s is plenty for a lock-screen speed/distance readout, and
        // every ActivityKit update costs a cross-process render.
        let urgent = state.threatLevel != lastState?.threatLevel
            || state.threatCount != lastState?.threatCount
            || state.paused != lastState?.paused
            || state.radarConnected != lastState?.radarConnected
        guard urgent || Date().timeIntervalSince(lastUpdate) >= 6 else { return }
        lastState = state
        lastUpdate = Date()
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end(_ state: RideActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .immediate)
        }
    }
}

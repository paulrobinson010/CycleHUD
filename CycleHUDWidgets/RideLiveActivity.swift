import ActivityKit
import WidgetKit
import SwiftUI

/// The ride on the Lock Screen and in the Dynamic Island: live speed,
/// distance, time and heart rate — and, uniquely, the radar. When a vehicle
/// is behind, the whole strip floods with the threat colour, so a pocketed
/// phone on a cafe table still shows what's coming.
///
/// Deliberately wordless (numbers, units and symbols only) so the extension
/// needs no translations.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenRideView(context: context)
                .activityBackgroundTint(threatColor(context.state.threatLevel)?.opacity(0.92)
                                        ?? Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ValueUnit(value: speedText(context),
                              unit: context.attributes.speedUnitLabel,
                              size: 28)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusGlyph(context.state, size: 26)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 14) {
                        ValueUnit(value: distanceText(context),
                                  unit: context.attributes.distanceUnitLabel, size: 17)
                        ValueUnit(value: timeText(context.state.movingTimeSeconds),
                                  unit: nil, size: 17)
                        if let hr = context.state.heartRate {
                            HStack(spacing: 3) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                                Text(verbatim: "\(hr)")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                            }
                        }
                        Spacer()
                        if context.state.paused {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Text(verbatim: speedText(context))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } compactTrailing: {
                statusGlyph(context.state, size: 14)
            } minimal: {
                statusGlyph(context.state, size: 14)
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenRideView: View {
    let context: ActivityViewContext<RideActivityAttributes>

    var body: some View {
        HStack(spacing: 16) {
            ValueUnit(value: speedText(context),
                      unit: context.attributes.speedUnitLabel, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                ValueUnit(value: distanceText(context),
                          unit: context.attributes.distanceUnitLabel, size: 17)
                ValueUnit(value: timeText(context.state.movingTimeSeconds),
                          unit: nil, size: 17)
            }
            if let hr = context.state.heartRate {
                VStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                    Text(verbatim: "\(hr)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            Spacer()
            VStack(spacing: 4) {
                statusGlyph(context.state, size: 24)
                if context.state.threatCount > 1 {
                    Text(verbatim: "×\(context.state.threatCount)")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                }
                if context.state.paused {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// A number with its unit tucked after it, baseline-aligned.
private struct ValueUnit: View {
    let value: String
    let unit: String?
    let size: CGFloat

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text(verbatim: value)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .monospacedDigit()
            if let unit {
                Text(verbatim: unit)
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .opacity(0.75)
            }
        }
    }
}

// MARK: - Shared bits

/// The radar's state at a glance: a coloured car when something's behind,
/// a green shield when clear, a struck-through antenna with no radar.
@ViewBuilder
private func statusGlyph(_ state: RideActivityAttributes.ContentState, size: CGFloat) -> some View {
    if state.threatLevel > 0 {
        // The background floods with the threat colour; the car stays white.
        Image(systemName: "car.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
    } else if state.radarConnected {
        Image(systemName: "checkmark.shield.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.green)
    } else {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.gray)
    }
}

/// nil when clear — the lock screen keeps its dark background.
private func threatColor(_ level: Int) -> Color? {
    switch level {
    case 3: return Color(red: 0.86, green: 0.16, blue: 0.16)
    case 2: return Color(red: 0.92, green: 0.52, blue: 0.10)
    case 1: return Color(red: 0.82, green: 0.68, blue: 0.05)
    default: return nil
    }
}

private func speedText(_ context: ActivityViewContext<RideActivityAttributes>) -> String {
    String(format: "%.1f", context.state.speedMps * context.attributes.speedFactor)
}

private func distanceText(_ context: ActivityViewContext<RideActivityAttributes>) -> String {
    String(format: "%.1f", context.state.distanceMeters * context.attributes.distanceFactor)
}

private func timeText(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s >= 3600 {
        return "\(s / 3600):\(String(format: "%02d", (s % 3600) / 60)):\(String(format: "%02d", s % 60))"
    }
    return "\(s / 60):\(String(format: "%02d", s % 60))"
}

import SwiftUI

/// Glanceable mirror of the phone: speed, heart rate, distance, and a radar
/// threat banner that turns amber/red when a vehicle is closing in.
struct WatchContentView: View {
    @EnvironmentObject var session: WatchSessionManager

    var body: some View {
        if session.sosActive {
            sosScreen
        } else {
            mirrorBody
        }
    }

    /// Crash SOS mirrored from the phone: cancel from the wrist, or ring the
    /// emergency contact — the action that works when the phone is out of reach.
    private var sosScreen: some View {
        VStack(spacing: 8) {
            Text("Possible crash")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if session.sosSeconds > 0 {
                Text(verbatim: "\(session.sosSeconds)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            Button { session.cancelSOS() } label: {
                Text("I’m OK")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            Button { session.callEmergencyContact() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "phone.fill")
                    Text(session.sosContactName.isEmpty
                            ? String(localized: "Call")
                            : session.sosContactName)
                        .lineLimit(1)
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 4)
        .containerBackground(Color.red.gradient, for: .navigation)
    }

    private var mirrorBody: some View {
        VStack(spacing: 6) {
            threatBanner

            Text(Fmt.decimal(session.speedDisplay, 1))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(session.speedUnitLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack {
                metric(label: String(localized: "HR"),
                       value: session.heartRate > 0 ? Fmt.int(session.heartRate) : "—",
                       alert: session.hrWarningActive)
                Spacer()
                metric(label: session.distanceUnitLabel.uppercased(),
                       value: Fmt.decimal(session.distanceDisplay, 2))
            }
            .padding(.top, 2)

            // Field diagnostics: which build is on the wrist, and whether the
            // workout keep-alive is live (● running / ○ not) — the two facts
            // needed when heart rate drops mid-ride.
            Text(verbatim: "\(session.buildStamp) \(session.workoutActive ? "●" : "○")")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .containerBackground(bannerColor.gradient, for: .navigation)
    }

    private var threatBanner: some View {
        Group {
            if session.threatLevel >= 0 {
                HStack(spacing: 6) {
                    Image(systemName: "car.fill")
                    Text(nearestThreatText ?? String(localized: "Car"))
                        .fontWeight(.bold)
                }
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(bannerColor))
            } else if session.radarLost && session.statusRaw != "idle" {
                // Radar dropped out: warn explicitly — never show a green "Clear",
                // which would falsely imply the road behind is being watched.
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    Text("RADAR OFF").fontWeight(.bold)
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(red: 0.95, green: 0.20, blue: 0.22)))
            } else {
                Text(session.statusRaw == "running" ? String(localized: "Clear") : statusLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func metric(label: String, value: String, alert: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(alert ? Color.white.opacity(0.9) : .secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(alert ? .white : .primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(alert ? Color(red: 0.95, green: 0.20, blue: 0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var bannerColor: Color {
        switch session.threatLevel {
        case 2: return Color(red: 0.95, green: 0.20, blue: 0.22)
        case 1: return Color(red: 1.0, green: 0.55, blue: 0.10)
        case 0: return Color(red: 1.0, green: 0.85, blue: 0.25)
        default: return .black
        }
    }

    /// Nearest-vehicle distance for the banner, shown in feet for imperial riders
    /// (matching their distance unit) or metres otherwise. The raw value stays in
    /// metres on `session` so the haptic cadence is unaffected.
    private var nearestThreatText: String? {
        guard let m = session.nearestThreatMeters else { return nil }
        if session.distanceUnitLabel == "mi" {
            return "\(Fmt.int(Double(m) * 3.280839895)) ft"
        }
        return "\(Fmt.int(m)) m"
    }

    private var statusLabel: String {
        switch session.statusRaw {
        case "paused": return String(localized: "Paused")
        case "autoPaused": return String(localized: "Auto-paused")
        default: return String(localized: "Ready")
        }
    }
}

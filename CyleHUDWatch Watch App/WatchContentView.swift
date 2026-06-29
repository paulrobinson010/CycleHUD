import SwiftUI

/// Glanceable mirror of the phone: speed, heart rate, distance, and a radar
/// threat banner that turns amber/red when a vehicle is closing in.
struct WatchContentView: View {
    @EnvironmentObject var session: WatchSessionManager

    var body: some View {
        VStack(spacing: 6) {
            threatBanner

            Text(Fmt.decimal(session.speedMps * 3.6, 1))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("km/h")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack {
                metric(label: String(localized: "HR"),
                       value: session.heartRate > 0 ? Fmt.int(session.heartRate) : "—",
                       alert: session.hrWarningActive)
                Spacer()
                metric(label: "KM", value: Fmt.decimal(session.distanceMeters / 1000, 2))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 6)
        .containerBackground(bannerColor.gradient, for: .navigation)
    }

    private var threatBanner: some View {
        Group {
            if session.threatLevel >= 0 {
                HStack(spacing: 6) {
                    Image(systemName: "car.fill")
                    Text(session.nearestThreatMeters.map { "\(Fmt.int($0)) m" } ?? String(localized: "Car"))
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

    private var statusLabel: String {
        switch session.statusRaw {
        case "paused": return String(localized: "Paused")
        case "autoPaused": return String(localized: "Auto-paused")
        default: return String(localized: "Ready")
        }
    }
}

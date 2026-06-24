import SwiftUI

/// Glanceable mirror of the phone: speed, heart rate, distance, and a radar
/// threat banner that turns amber/red when a vehicle is closing in.
struct WatchContentView: View {
    @EnvironmentObject var session: WatchSessionManager

    var body: some View {
        VStack(spacing: 6) {
            threatBanner

            Text(String(format: "%.1f", session.speedMps * 3.6))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("km/h")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack {
                metric(label: "HR", value: session.heartRate > 0 ? "\(session.heartRate)" : "—")
                Spacer()
                metric(label: "KM", value: String(format: "%.2f", session.distanceMeters / 1000))
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
                    Text(session.nearestThreatMeters.map { "\($0) m" } ?? "Car")
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
                Text(session.statusRaw == "running" ? "Clear" : statusLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
        }
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
        case "paused": return "Paused"
        case "autoPaused": return "Auto-paused"
        default: return "Ready"
        }
    }
}

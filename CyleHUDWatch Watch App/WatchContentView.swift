import SwiftUI

/// Swipeable watch face: page 1 is the radar/safety glance, page 2 is the full
/// ride stats. Both keep the threat-colour background so a closing vehicle glows
/// red on whichever page you're on, and the wrist haptics fire regardless of
/// page — so swiping away from the radar never costs you the alert.
struct WatchContentView: View {
    @EnvironmentObject var session: WatchSessionManager

    var body: some View {
        TabView {
            RadarPage().environmentObject(session)
            StatsPage().environmentObject(session)
        }
        .tabViewStyle(.page)
    }
}

// MARK: - Page 1: radar / safety glance

private struct RadarPage: View {
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
                metric("HR", session.heartRate > 0 ? "\(session.heartRate)" : "—")
                Spacer()
                metric("KM", String(format: "%.2f", session.distanceMeters / 1000))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 6)
        .containerBackground(threatColor(session.threatLevel).gradient, for: .navigation)
    }

    private var threatBanner: some View {
        Group {
            if session.threatLevel >= 0 {
                bannerCapsule(icon: "car.fill",
                              text: session.nearestThreatMeters.map { "\($0) m" } ?? "Car",
                              color: threatColor(session.threatLevel))
            } else if session.radarLost && session.statusRaw != "idle" {
                // Radar dropped out: warn explicitly — never show a green "Clear",
                // which would falsely imply the road behind is being watched.
                bannerCapsule(icon: "antenna.radiowaves.left.and.right.slash",
                              text: "RADAR OFF", color: threatColor(2))
            } else {
                Text(session.statusRaw == "running" ? "Clear" : statusLabel(session.statusRaw))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func bannerCapsule(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).fontWeight(.bold)
        }
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Capsule().fill(color))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
        }
    }
}

// MARK: - Page 2: full ride stats

private struct StatsPage: View {
    @EnvironmentObject var session: WatchSessionManager

    var body: some View {
        VStack(spacing: 7) {
            row(cell("SPEED", kmh(session.speedMps), "km/h"),
                cell("AVG", kmh(session.avgSpeedMps), "km/h"))
            row(cell("DIST", String(format: "%.2f", session.distanceMeters / 1000), "km"),
                cell("TIME", timeString(session.movingTimeSeconds), ""))
            row(cell("HR", session.heartRate > 0 ? "\(session.heartRate)" : "—", "bpm"),
                session.cadence > 0
                    ? cell("CAD", "\(session.cadence)", "rpm")
                    : cell("ASCENT", "\(Int(session.ascentMeters))", "m"))
        }
        .padding(.horizontal, 8)
        .containerBackground(threatColor(session.threatLevel).gradient, for: .navigation)
    }

    private func row<L: View, R: View>(_ left: L, _ right: R) -> some View {
        HStack(spacing: 6) { left; right }
    }

    private func cell(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
            if !unit.isEmpty {
                Text(unit).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func kmh(_ mps: Double) -> String { String(format: "%.1f", mps * 3.6) }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Shared

/// Threat colour shared by both pages: yellow → orange → red, black when clear.
private func threatColor(_ level: Int) -> Color {
    switch level {
    case 2: return Color(red: 0.95, green: 0.20, blue: 0.22)
    case 1: return Color(red: 1.0, green: 0.55, blue: 0.10)
    case 0: return Color(red: 1.0, green: 0.85, blue: 0.25)
    default: return .black
    }
}

private func statusLabel(_ raw: String) -> String {
    switch raw {
    case "paused": return "Paused"
    case "autoPaused": return "Auto-paused"
    default: return "Ready"
    }
}

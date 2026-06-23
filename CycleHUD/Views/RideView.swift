import SwiftUI

/// The main riding screen: radar-first, with the data grid and ride controls
/// beneath it. No map.
struct RideView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BluetoothManager
    @EnvironmentObject var location: LocationManager
    @EnvironmentObject var ride: RideManager
    @EnvironmentObject var watch: WatchConnectivityManager

    private enum ActiveSheet: Int, Identifiable {
        case pairing, settings
        var id: Int { rawValue }
    }
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                statusBar
                RadarView(threats: ble.threats, distanceUnit: settings.distanceUnit)
                    .frame(maxHeight: .infinity)
                metricsGrid
                controlBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .pairing: PairingView().environmentObject(ble)
            case .settings: SettingsView().environmentObject(settings).environmentObject(ble).environmentObject(ride)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasChosenUnits },
            set: { _ in }
        )) {
            UnitsOnboardingView().environmentObject(settings)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            RolePill(label: "RAD", fullName: "Radar", status: ble.status(for: .radar))
            RolePill(label: "SPD", fullName: "Speed", status: ble.status(for: .speed))
            RolePill(label: "CAD", fullName: "Cadence", status: ble.status(for: .cadence))
            gpsPill

            Spacer(minLength: 4)

            if controlStatus != .idle { statusBadge }

            Button { activeSheet = .pairing } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Button { activeSheet = .settings } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var gpsPill: some View {
        let connected = location.hasFix
        return Text("GPS")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(connected ? Theme.good : Theme.textSecondary)
            .frame(height: 30)
            .padding(.horizontal, 10)
            .background(Capsule().fill(connected ? Theme.good.opacity(0.18) : Theme.panel))
            .accessibilityLabel(connected ? "GPS: fix acquired" : "GPS: searching")
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(statusColor.opacity(0.18)))
    }

    /// The status that drives the badge and controls — the demo presents itself
    /// as a running (or paused) ride so the bottom controls behave normally.
    private var controlStatus: RideStatus {
        guard ride.demoActive else { return ride.status }
        return ride.demoPaused ? .paused : .running
    }

    private var statusText: String {
        switch controlStatus {
        case .idle: return "STOPPED"
        case .running: return "● REC"
        case .paused: return "PAUSED"
        case .autoPaused: return "AUTO-PAUSED"
        }
    }

    private var statusColor: Color {
        switch controlStatus {
        case .idle: return Theme.textSecondary
        case .running: return Theme.threatHigh
        case .paused, .autoPaused: return Theme.threatLow
        }
    }

    // MARK: - Metrics

    private var metricsGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                MetricTile(title: "Speed",
                           value: speedString(ride.currentSpeedMps),
                           unit: settings.speedUnit.label, valueSize: 32, height: 90)
                MetricTile(title: "Avg Speed",
                           value: speedString(ride.averageSpeedMps),
                           unit: settings.speedUnit.label, valueSize: 32, height: 90)
                MetricTile(title: "Cadence",
                           value: ble.freshCadence.map { "\($0)" } ?? "—",
                           unit: "rpm", valueSize: 32, height: 90)
            }
            HStack(spacing: 8) {
                MetricTile(title: "Distance",
                           value: distanceString(ride.distanceMeters),
                           unit: settings.distanceUnit.label, valueSize: 32, height: 90)
                MetricTile(title: "Time",
                           value: timeString(ride.movingTimeSeconds),
                           unit: "", valueSize: 32, height: 90)
                MetricTile(title: "Ascent",
                           value: elevationString(ride.elevationGainMeters),
                           unit: settings.distanceUnit.shortLabel, valueSize: 32, height: 90)
            }
            HStack(spacing: 8) {
                MetricTile(title: "Heart Rate",
                           value: (watch.displayHeartRate ?? ride.currentHeartRate).map { "\($0)" } ?? "—",
                           unit: "bpm", valueSize: 32, height: 90)
                MetricTile(title: "Calories",
                           value: ride.caloriesKcal >= 1 ? "\(Int(ride.caloriesKcal))" : "—",
                           unit: "kcal", valueSize: 32, height: 90)
            }
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            if controlStatus == .idle {
                primaryButton(title: "Start", system: "play.fill", color: Theme.good) {
                    ble.stopDemo()
                    ride.start()
                }
            } else {
                primaryButton(title: controlStatus == .running ? "Pause" : "Resume",
                              system: controlStatus == .running ? "pause.fill" : "play.fill",
                              color: Theme.accent) {
                    ride.demoActive ? ride.toggleDemoPause() : ride.togglePause()
                }
                primaryButton(title: "Stop", system: "stop.fill", color: Theme.threatHigh) {
                    if ride.demoActive {
                        ble.stopDemo()
                        ride.stopDemo()
                    } else {
                        ride.stop()
                    }
                }
            }
        }
    }

    private func primaryButton(title: String, system: String, color: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: system)
                Text(title)
            }
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 16).fill(color))
        }
    }

    // MARK: - Formatting

    private func speedString(_ mps: Double) -> String {
        String(format: "%.1f", settings.speedUnit.value(fromMps: mps))
    }

    private func distanceString(_ meters: Double) -> String {
        String(format: "%.2f", settings.distanceUnit.value(fromMeters: meters))
    }

    private func elevationString(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return "\(Int(settings.distanceUnit.shortValue(fromMeters: meters).rounded()))"
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

/// Connection-status pill for a sensor role: shows connected (green),
/// connecting (spinner), retrying (rotating arrow), failed (red), or not set up.
struct RolePill: View {
    let label: String
    let fullName: String
    let status: RoleStatus

    @State private var spin = false

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
            trailing
        }
        .foregroundStyle(status.color)
        .frame(height: 30)
        .padding(.horizontal, 10)
        .background(Capsule().fill(status == .connected
                                   ? Theme.good.opacity(0.18) : Theme.panel))
        .overlay(
            Capsule().stroke(status.color.opacity(status == .failed ? 0.8 : 0), lineWidth: 1)
        )
        .accessibilityLabel("\(fullName): \(status.detail)")
    }

    /// Only non-connected states add a glyph; connected reads as a plain green icon.
    @ViewBuilder private var trailing: some View {
        if status.showsSpinner {
            ProgressView()
                .controlSize(.mini)
                .tint(status.color)
        } else if status.showsRetry {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
        } else if status == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
        }
    }
}

import SwiftUI
import UIKit
import MessageUI

/// The main riding screen: radar-first, with the data grid and ride controls
/// beneath it. No map.
struct RideView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BluetoothManager
    @EnvironmentObject var location: LocationManager
    @EnvironmentObject var ride: RideManager
    @EnvironmentObject var watch: WatchConnectivityManager
    @EnvironmentObject var history: RideHistory
    @EnvironmentObject var weather: WeatherManager
    @EnvironmentObject var sos: SOSManager

    private enum ActiveSheet: Int, Identifiable {
        case pairing, settings
        var id: Int { rawValue }
    }
    @State private var activeSheet: ActiveSheet?
    @State private var carMarkFlash = false
    @State private var pairingFromOnboarding = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var showPermissionAlert = false
    @State private var currentIssue: PermissionIssue?
    @State private var dismissedIssueID: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            GeometryReader { geo in
                let landscape = settings.landscapeEnabled && geo.size.width > geo.size.height
                Group {
                    if landscape { landscapeLayout } else { portraitLayout }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .environment(\.locale, settings.appLocale)
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .pairing: PairingView(showAccessHint: pairingFromOnboarding).environmentObject(ble)
                case .settings: SettingsView().environmentObject(settings).environmentObject(ble)
                        .environmentObject(ride).environmentObject(history).environmentObject(weather)
                        .environmentObject(sos)
                }
            }
            .preferredColorScheme(appColorScheme).environment(\.locale, settings.appLocale)
        }
        .sheet(item: $ride.finishedSummary) { summary in
            RideSummaryView(summary: summary).environmentObject(settings)
                .preferredColorScheme(appColorScheme).environment(\.locale, settings.appLocale)
        }
        .fullScreenCover(isPresented: Binding(
            get: { sos.isCountingDown },
            set: { if !$0 { sos.cancel() } }
        )) {
            SOSCountdownView(sos: sos).environment(\.locale, settings.appLocale)
        }
        .sheet(isPresented: $sos.presentComposer) { sosComposer }
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasChosenUnits },
            set: { _ in }
        )) {
            UnitsOnboardingView().environmentObject(settings)
                .preferredColorScheme(appColorScheme).environment(\.locale, settings.appLocale)
        }
        .onAppear { updateOrientation(); checkPermissions() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                checkPermissions()
                ble.resumeFromBackground()        // reconnect sensors we dropped
                Task { await weather.refresh(force: true) }   // fresh rain value on return
            case .background:
                // Not riding? Drop sensor connections so the app isn't kept alive
                // in the background processing the radar stream. During a ride
                // (screen off / pocketed) we keep them — the ride needs them.
                if ride.status == .idle && !ride.demoActive {
                    ble.suspendForBackground()
                }
            default:
                break
            }
        }
        .onChange(of: settings.saveWorkouts) { _, _ in checkPermissions(force: true) }
        .alert(currentIssue?.title ?? "Permission needed",
               isPresented: $showPermissionAlert, presenting: currentIssue) { issue in
            if issue.opensAppSettings {
                Button("Open Settings") { Permissions.openAppSettings() }
                Button("Later", role: .cancel) { dismissedIssueID = issue.id }
            } else {
                Button("Don’t save workouts") {
                    settings.saveWorkouts = false
                    dismissedIssueID = issue.id
                }
                Button("OK", role: .cancel) { dismissedIssueID = issue.id }
            }
        } message: { issue in
            Text(issue.message)
        }
        .onChange(of: settings.landscapeEnabled) { _, _ in updateOrientation() }
        .onChange(of: activeSheet) { _, sheet in
            updateOrientation()
            if sheet == nil { pairingFromOnboarding = false; checkPermissions() }
        }
        .onChange(of: ride.finishedSummary) { _, _ in updateOrientation() }
        .onChange(of: settings.hasChosenUnits) { old, new in
            updateOrientation()
            if new && !old {
                // Finishing onboarding drops the rider straight into Devices so
                // they can pair, with a hint on how to get back here later.
                pairingFromOnboarding = true
                // Let the onboarding cover finish dismissing before presenting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    activeSheet = .pairing
                }
            } else if old && !new {
                // Onboarding was reset (from Diagnostics) — close any open sheet
                // so the welcome screen presents instead of hiding behind it.
                activeSheet = nil
            }
        }
    }

    /// The app-wide light/dark choice, applied to presented sheets/covers too so
    /// toggling it updates onboarding and Settings live, not just the main screen.
    private var appColorScheme: ColorScheme { settings.darkModeEnabled ? .dark : .light }

    /// The SOS message composer, or a manual fallback when the device can't send
    /// texts (no SIM/iMessage) — showing the number and message to send by hand.
    @ViewBuilder private var sosComposer: some View {
        if MFMessageComposeViewController.canSendText() {
            MessageComposeView(recipients: sos.recipients, body: sos.messageBody) {
                sos.composerFinished()
            }
            .ignoresSafeArea()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 40)).foregroundStyle(Theme.threatHigh)
                Text("Can’t send a text from this device")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                if let contact = settings.emergencyContact {
                    Text(contact.name.isEmpty ? contact.phone : "\(contact.name) — \(contact.phone)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                Text(sos.messageBody)
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Close") { sos.composerFinished() }
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .padding(.top, 8)
            }
            .padding(28)
        }
    }

    /// Surface any missing OS permission the app relies on. `force` re-shows even
    /// after the rider dismissed it — used when they change a setting (e.g. turn
    /// on workout saving) that introduces a new requirement.
    private func checkPermissions(force: Bool = false) {
        // Only on the main HUD — don't try to present over onboarding or a sheet.
        guard settings.hasChosenUnits, activeSheet == nil else { return }
        let issues = Permissions.currentIssues(saveWorkouts: settings.saveWorkouts)
        guard let first = issues.first else {
            showPermissionAlert = false
            currentIssue = nil
            dismissedIssueID = nil            // re-arm now that everything's resolved
            return
        }
        if force { dismissedIssueID = nil }
        guard dismissedIssueID != first.id else { return }   // already dismissed this one
        currentIssue = first
        showPermissionAlert = true
    }

    /// The HUD is fixed landscape when the setting is on and nothing is presented
    /// over it; every modal (Settings, pairing, the ride summary, onboarding)
    /// drops back to portrait. So the main screen is *always* landscape rather
    /// than rotation-driven, while Settings stays portrait.
    private func updateOrientation() {
        let liveHUD = settings.landscapeEnabled
            && activeSheet == nil
            && ride.finishedSummary == nil
            && settings.hasChosenUnits
        if liveHUD {
            AppDelegate.lock(.landscape, rotateTo: .landscapeRight)
        } else {
            AppDelegate.lock(.portrait, rotateTo: .portrait)
        }
    }

    // MARK: - Layouts

    /// Default stacked layout: status, radar, metrics, controls top-to-bottom.
    private var portraitLayout: some View {
        VStack(spacing: 12) {
            statusBar
            radarPanel.frame(maxHeight: .infinity)
            metricsGrid
            controlBar
        }
    }

    /// Landscape split: the top half (status + radar) on the left, the bottom
    /// half (metrics + controls) on the right.
    private var landscapeLayout: some View {
        HStack(spacing: 12) {
            VStack(spacing: 8) {
                statusBar
                radarPanel.frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                metricsGrid
                Spacer(minLength: 0)
                controlBar
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The radar lane plus its debug "Mark car" overlay, shared by both layouts.
    private var radarPanel: some View {
        RadarView(threats: ble.threats, distanceUnit: settings.distanceUnit,
                  radarConnected: ble.status(for: .radar) == .connected,
                  batteryPercent: ble.radarBatteryPercent)
            .overlay(alignment: .topTrailing) {
                MuteControls(settings: settings).padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                if settings.radarDebugEnabled { carMarkButton }
            }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            RolePill(label: String(localized: "RAD", comment: "3-letter pill for the Radar sensor"),
                     fullName: String(localized: "Radar"), status: ble.status(for: .radar))
            RolePill(label: String(localized: "SPD", comment: "3-letter pill for the Speed sensor"),
                     fullName: String(localized: "Speed"), status: ble.status(for: .speed))
            RolePill(label: String(localized: "CAD", comment: "3-letter pill for the Cadence sensor"),
                     fullName: String(localized: "Cadence"), status: ble.status(for: .cadence))
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
        case .idle: return String(localized: "STOPPED")
        case .running: return "● " + String(localized: "REC")
        case .paused: return String(localized: "PAUSED")
        case .autoPaused: return String(localized: "AUTO-PAUSED")
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

    /// The rider's chosen tiles, laid out three per row. Weather tiles are hidden
    /// when Weather is off. Short rows are padded so tile widths stay uniform.
    private var metricsGrid: some View {
        let kinds = settings.metricKinds.filter { !$0.requiresWeather || settings.weatherEnabled }
        let rows = kinds.chunked(into: 3)
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        if i < row.count {
                            metricTile(for: row[i])
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 90)
                        }
                    }
                }
            }
        }
    }

    /// Build the tile for one metric, pulling live values from the managers.
    @ViewBuilder
    private func metricTile(for kind: MetricKind) -> some View {
        switch kind {
        case .speed:
            MetricTile(title: kind.title, value: speedString(ride.currentSpeedMps),
                       unit: settings.speedUnit.label, valueSize: 32, height: 90)
        case .avgSpeed:
            MetricTile(title: kind.title, value: speedString(ride.averageSpeedMps),
                       unit: settings.speedUnit.label, valueSize: 32, height: 90)
        case .maxSpeed:
            MetricTile(title: kind.title, value: speedString(ride.maxSpeedMps),
                       unit: settings.speedUnit.label, valueSize: 32, height: 90)
        case .cadence:
            MetricTile(title: kind.title, value: ble.freshCadence.map { Fmt.int($0) } ?? "—",
                       unit: "rpm", valueSize: 32, height: 90)
        case .distance:
            MetricTile(title: kind.title, value: distanceString(ride.distanceMeters),
                       unit: settings.distanceUnit.label, valueSize: 32, height: 90)
        case .time:
            MetricTile(title: kind.title, value: timeString(ride.movingTimeSeconds),
                       unit: "", valueSize: 32, height: 90)
        case .ascent:
            MetricTile(title: kind.title, value: elevationString(ride.elevationGainMeters),
                       unit: settings.distanceUnit.shortLabel, valueSize: 32, height: 90)
        case .heartRate:
            let hr = watch.displayHeartRate ?? ride.currentHeartRate ?? ble.freshSensorHeartRate()
            MetricTile(title: kind.title, value: hr.map { Fmt.int($0) } ?? "—",
                       unit: "bpm", valueSize: 32, height: 90,
                       alert: settings.hrWarningEnabled && (hr ?? 0) >= settings.hrWarningBpm)
        case .calories:
            MetricTile(title: kind.title, value: ride.caloriesKcal >= 1 ? Fmt.int(ride.caloriesKcal) : "—",
                       unit: "kcal", valueSize: 32, height: 90)
        case .gradient:
            MetricTile(title: kind.title, value: gradientString, unit: "%",
                       valueSize: 32, height: 90)
        case .lapTime:
            MetricTile(title: kind.title, value: timeString(ride.currentLapTimeSeconds),
                       unit: "", valueSize: 32, height: 90)
        case .temperature:
            MetricTile(title: kind.title, value: temperatureValue, unit: temperatureUnit,
                       valueSize: 32, height: 90)
        case .wind:
            windTile
        case .rain:
            WeatherTile(nowcast: weather.nowcast, status: weather.status, height: 90)
        }
    }

    /// Live road gradient as a signed percentage (— until enough travel).
    private var gradientString: String {
        guard let g = ride.currentGradientPercent else { return "—" }
        return Fmt.decimal(g, 1)
    }

    /// Imperial temperature (°F) when the rider uses miles, otherwise °C.
    private var imperialTemperature: Bool { settings.distanceUnit == .mi }
    private var temperatureUnit: String { imperialTemperature ? "°F" : "°C" }
    private var temperatureValue: String {
        guard let c = weather.conditions else { return "—" }
        let t = imperialTemperature ? c.temperatureC * 9 / 5 + 32 : c.temperatureC
        return Fmt.int(t)
    }

    /// Headwind / tailwind along the rider's heading, or absolute wind speed when
    /// no heading is available yet.
    private var windTile: some View {
        let speedLabel = settings.speedUnit.label
        if let c = weather.conditions, let course = location.courseDegrees {
            let head = c.headwindMps(course: course)
            let value = Fmt.int(settings.speedUnit.value(fromMps: abs(head)))
            return MetricTile(title: head >= 0 ? "Headwind" : "Tailwind",
                              value: value, unit: speedLabel, valueSize: 32, height: 90)
        } else if let c = weather.conditions {
            return MetricTile(title: "Wind",
                              value: Fmt.int(settings.speedUnit.value(fromMps: c.windSpeedMps)),
                              unit: speedLabel, valueSize: 32, height: 90)
        } else {
            return MetricTile(title: "Wind", value: "—", unit: "", valueSize: 32, height: 90)
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
                if controlStatus == .running && !ride.demoActive { lapButton }
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

    /// Compact icon-only lap button: closes the current lap and starts a new one.
    private var lapButton: some View {
        Button {
            ride.markLap()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            Image(systemName: "flag.checkered")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelRaised))
        }
        .accessibilityLabel("Mark lap")
    }

    private func primaryButton(title: LocalizedStringKey, system: String, color: Color,
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

    // MARK: - Car mark (protocol-decode aid)

    /// Tapped when a real car passes, to drop a timestamp in the log so sparse
    /// car events can be matched against captured radar packets.
    private var carMarkButton: some View {
        Button {
            ble.markCarObserved()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeOut(duration: 0.12)) { carMarkFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeIn(duration: 0.3)) { carMarkFlash = false }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "car.fill")
                Text(carMarkFlash ? String(localized: "Marked \(ble.carMarkCount)") : String(localized: "Mark car"))
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule().fill(carMarkFlash ? Theme.good : Color.black.opacity(0.55)))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .padding(12)
        .accessibilityLabel("Mark that a car just passed")
    }

    // MARK: - Formatting

    private func speedString(_ mps: Double) -> String {
        Fmt.decimal(settings.speedUnit.value(fromMps: mps), 1)
    }

    private func distanceString(_ meters: Double) -> String {
        Fmt.decimal(settings.distanceUnit.value(fromMeters: meters), 2)
    }

    private func elevationString(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return Fmt.int(settings.distanceUnit.shortValue(fromMeters: meters))
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

import SwiftUI

/// Field debugging for sensors — shows the discovered Bluetooth services /
/// characteristics and live radar packet flow, so we can confirm what the radar
/// actually speaks.
struct DiagnosticsView: View {
    @EnvironmentObject var ble: BluetoothManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var history: RideHistory
    @EnvironmentObject var weather: WeatherManager
    @State private var logText = ""
    @State private var sampleAdded = false

    var body: some View {
        List {
            Section {
                ShareLink(item: AppLog.shared.fileURL) {
                    Label("Share log file", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    AppLog.shared.clear()
                    logText = ""
                } label: {
                    Label("Clear log", systemImage: "trash")
                }
            } header: {
                Text("Activity log")
            } footer: {
                Text("A record of your rides and sensor activity, kept on your device. If something didn't work as expected, you can share it so the problem can be looked into.")
            }

            Section {
                Toggle("Show “Mark car” button", isOn: $settings.radarDebugEnabled)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Adds a “Mark car” button to the ride screen so you can tag the moment a vehicle passes — handy for checking radar timing. Most riders can leave this off.")
            }

            Section {
                Button {
                    settings.hasChosenUnits = false
                } label: {
                    Label("Show welcome screen again", systemImage: "sparkles")
                }
            } header: {
                Text("Onboarding")
            } footer: {
                Text("Re-shows the welcome screen you saw when you first opened the app. Close Settings (or reopen the app) to see it. Your rides and other settings are kept.")
            }

            Section {
                Button {
                    history.add(SampleRide.centralPark(now: Date()))
                    sampleAdded = true
                } label: {
                    Label(sampleAdded ? "Sample ride added" : "Add sample ride (Central Park)",
                          systemImage: sampleAdded ? "checkmark.circle.fill" : "map")
                        .foregroundStyle(sampleAdded ? Theme.good : Theme.accent)
                }
                .disabled(sampleAdded)
            } header: {
                Text("Sample data")
            } footer: {
                Text("Adds one example ride (a Central Park loop with a route, vehicles on the map and vehicle passes) to Previous rides, so you can see how a completed ride looks. Swipe to delete it there when you're done.")
            }

            Section("Recent log") {
                Text(logText.isEmpty ? "No log yet." : logText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section {
                LabeledContent("Enabled", value: settings.weatherEnabled ? "Yes" : "No")
                LabeledContent("Status", value: weatherStatus)
                if let u = weather.lastUpdated {
                    LabeledContent("Last updated",
                                   value: u.formatted(date: .omitted, time: .standard))
                }
                if let n = weather.nowcast {
                    Text(n.alertMessage).foregroundStyle(Theme.good)
                }
                if let e = weather.lastErrorText {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Technical details").font(.caption).foregroundStyle(.secondary)
                        Text(e).font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                Button {
                    Task { await weather.refresh(force: true) }
                } label: {
                    Label("Refresh weather now", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Weather")
            } footer: {
                Text("The rain forecast uses Apple Weather and needs your location and an internet connection. If it shows “unavailable”, it's usually temporary — make sure you're online with a GPS signal and tap Refresh. You can turn the forecast off in Settings → Weather.")
            }

            Section("Radar") {
                LabeledContent("Updates received", value: "\(ble.radarPacketCount)")
                Text(ble.radarPacketCount > 0 ? "Radar is sending data ✓" : "No radar data yet")
                    .foregroundStyle(ble.radarPacketCount > 0 ? Theme.good : .orange)
                if !ble.lastRadarHex.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Latest signal (technical)").font(.caption).foregroundStyle(.secondary)
                        Text(ble.lastRadarHex)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Sensor details") {
                if ble.diagnostics.isEmpty {
                    Text("Connect a sensor from the Sensors screen to see its connection details here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(ble.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            AppLog.shared.log("Sensor diagnostics opened (radar packets=\(ble.radarPacketCount))")
            logText = lastLines(AppLog.shared.contents(), 120)
        }
        .refreshable { logText = lastLines(AppLog.shared.contents(), 120) }
    }

    private var weatherStatus: String {
        switch weather.status {
        case .idle: return "Idle"
        case .loading: return "Checking…"
        case .ready: return "OK"
        case .unavailable: return "Unavailable"
        }
    }

    /// Show only the most recent lines so the view stays light.
    private func lastLines(_ text: String, _ count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }
}

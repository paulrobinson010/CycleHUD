import SwiftUI

/// Field debugging for sensors — shows the discovered Bluetooth services /
/// characteristics and live radar packet flow, so we can confirm what the radar
/// actually speaks.
struct DiagnosticsView: View {
    @EnvironmentObject var ble: BluetoothManager
    @State private var logText = ""

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
                Text("Event log")
            } footer: {
                Text("Records ride events, sensor activity and any crash. Share this file after a ride that misbehaved.")
            }

            Section("Recent log") {
                Text(logText.isEmpty ? "No log yet." : logText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Radar data") {
                LabeledContent("Packets received", value: "\(ble.radarPacketCount)")
                Text(ble.radarPacketCount > 0 ? "Radar is streaming ✓" : "No radar data received yet")
                    .foregroundStyle(ble.radarPacketCount > 0 ? Theme.good : .orange)
                if !ble.lastRadarHex.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last packet (hex)").font(.caption).foregroundStyle(.secondary)
                        Text(ble.lastRadarHex)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Discovered Bluetooth") {
                if ble.diagnostics.isEmpty {
                    Text("Connect a sensor (Sensors screen) to list its services and characteristics here.")
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
        .onAppear { logText = lastLines(AppLog.shared.contents(), 120) }
        .refreshable { logText = lastLines(AppLog.shared.contents(), 120) }
    }

    /// Show only the most recent lines so the view stays light.
    private func lastLines(_ text: String, _ count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }
}

import SwiftUI

/// Scan for and connect to the radar and speed/cadence sensors. Remembered
/// devices persist across launches and reconnect automatically.
struct PairingView: View {
    @EnvironmentObject var ble: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !ble.savedDevices.isEmpty {
                    Section("Remembered") {
                        ForEach(ble.savedDevices) { device in
                            savedRow(device)
                        }
                    }
                }

                Section {
                    ForEach(discoverable) { device in
                        Button { ble.connect(device.id) } label: {
                            availableRow(device)
                        }
                    }
                    if discoverable.isEmpty {
                        Text(ble.isScanning ? "Searching…" : "No new devices found.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Available")
                        Spacer()
                        if ble.isScanning { ProgressView() }
                    }
                }

                if !ble.poweredOn {
                    Section {
                        Label("Turn on Bluetooth to find your sensors.", systemImage: "bolt.slash")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Sensors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ble.isScanning ? "Stop" : "Scan") {
                        ble.isScanning ? ble.stopScan() : ble.startScan()
                    }
                }
            }
            .onAppear { if ble.poweredOn { ble.startScan() } }
            .onDisappear { ble.stopScan() }
        }
    }

    private var discoverable: [DiscoveredDevice] {
        let savedIDs = Set(ble.savedDevices.map(\.id))
        return ble.discovered
            .filter { !savedIDs.contains($0.id) }
            .sorted { $0.rssi > $1.rssi }
    }

    // MARK: - Rows

    private func savedRow(_ device: SavedDevice) -> some View {
        let state = ble.deviceState(device.id)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.headline)
                if device.roles.isEmpty {
                    Text("Sensor").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(device.roles, id: \.rawValue) { role in
                            roleChip(role)
                        }
                    }
                }
            }
            Spacer()
            stateIndicator(state)
            Button(role: .destructive) { ble.forget(device.id) } label: {
                Text("Forget").font(.caption.bold())
            }
            .buttonStyle(.borderless)
        }
    }

    private func availableRow(_ device: DiscoveredDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.headline)
                if device.roles.isEmpty {
                    Text("Tap to connect").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(device.roles), id: \.rawValue) { roleChip($0) }
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
    }

    private func roleChip(_ role: DeviceRole) -> some View {
        Label(role.rawValue, systemImage: role.systemImage)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }

    @ViewBuilder private func stateIndicator(_ state: ConnectionState) -> some View {
        switch state {
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.good)
        case .connecting:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Connecting").font(.caption2) }
                .foregroundStyle(.secondary)
        case .retrying:
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Retrying").font(.caption2)
            }
            .foregroundStyle(.orange)
        }
    }
}

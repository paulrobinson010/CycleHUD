import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BluetoothManager
    @EnvironmentObject var ride: RideManager
    @Environment(\.dismiss) private var dismiss

    struct WheelPreset: Identifiable {
        let name: String
        let mm: Double
        var id: Double { mm }
    }

    // Common wheel circumferences (mm) for quick selection.
    private let wheelPresets: [WheelPreset] = [
        .init(name: "700x23c", mm: 2096), .init(name: "700x25c", mm: 2105),
        .init(name: "700x28c", mm: 2136), .init(name: "700x32c", mm: 2155),
        .init(name: "650b x 47", mm: 2030), .init(name: "Custom", mm: -1)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Speed", selection: $settings.speedUnit) {
                        ForEach(SpeedUnit.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Distance", selection: $settings.distanceUnit) {
                        ForEach(DistanceUnit.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Picker("Wheel size", selection: wheelPresetBinding) {
                        ForEach(wheelPresets) { Text($0.name).tag($0.mm) }
                    }
                    HStack {
                        Text("Circumference")
                        Spacer()
                        TextField("mm", value: $settings.wheelCircumferenceMM, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("mm").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Speed Sensor")
                } footer: {
                    Text("Used to convert wheel revolutions into speed. GPS is used when no speed sensor is connected.")
                }

                Section {
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField("kg", value: $settings.riderWeightKg, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("kg").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Rider")
                } footer: {
                    Text("Used with heart rate from a paired Apple Watch to estimate calories. Read from Apple Health when available.")
                }

                Section("Alerts & Ride") {
                    Toggle("Beep on new vehicle", isOn: $settings.beepEnabled)
                    Toggle("Auto-pause when stopped", isOn: $settings.autoPauseEnabled)
                    Toggle("Keep screen on while riding", isOn: $settings.keepScreenOn)
                }

                Section {
                    Button {
                        if ble.demoActive {
                            ble.stopDemo()
                            ride.stopDemo()
                        } else {
                            ride.startDemo()
                            ble.startDemo()
                            dismiss()                     // close so the rider can watch
                        }
                    } label: {
                        Label(ble.demoActive ? "Stop radar demo" : "Start radar demo",
                              systemImage: ble.demoActive ? "stop.circle.fill" : "play.circle.fill")
                            .foregroundStyle(ble.demoActive ? Theme.threatHigh : Theme.accent)
                    }
                } header: {
                    Text("Demo")
                } footer: {
                    Text("Plays a one-time preview on the main screen showing low (yellow), medium (orange) and high (red) threats, with the new-vehicle beep and realistic live ride stats, so you can see and hear what to expect. It runs through once and stops; starting a ride also stops it.")
                }

                Section {
                    Text("CycleHUD pairs with a Coospo TR70 (or other Varia-compatible) rear radar and standard CSC speed/cadence sensors.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var wheelPresetBinding: Binding<Double> {
        Binding(
            get: {
                wheelPresets.first { $0.mm == settings.wheelCircumferenceMM }?.mm ?? -1
            },
            set: { newValue in
                if newValue > 0 { settings.wheelCircumferenceMM = newValue }
            }
        )
    }
}

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BluetoothManager
    @EnvironmentObject var ride: RideManager
    @EnvironmentObject var history: RideHistory
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
                Section {
                    NavigationLink {
                        RideHistoryView().environmentObject(history).environmentObject(settings)
                    } label: {
                        Label("Previous rides", systemImage: "list.bullet.rectangle")
                    }
                }

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

                Section {
                    Toggle("Beep on new vehicle", isOn: $settings.beepEnabled)
                    Toggle("Auto-pause when stopped", isOn: $settings.autoPauseEnabled)
                    Toggle("Keep screen on while riding", isOn: $settings.keepScreenOn)
                    Toggle("Save rides as workouts", isOn: $settings.saveWorkouts)
                } header: {
                    Text("Alerts & Ride")
                } footer: {
                    Text("The new-vehicle beep plays through the phone, and alerts only fire while you're riding (not when idle with the radar on). A paired Apple Watch taps your wrist — once for each new vehicle, faster as one closes in, and a distinct double-buzz if the radar drops out mid-ride. When “Save rides as workouts” is on, each ride is written to Apple Health.")
                }

                Section {
                    Toggle("Landscape layout", isOn: $settings.landscapeEnabled)
                } header: {
                    Text("Display")
                } footer: {
                    Text("When on, the ride screen is fixed in landscape — radar on the left, ride data and controls on the right. It won't flip back when you rotate the phone; Settings and other screens stay in portrait.")
                }

                Section {
                    Toggle("Heart-rate warning", isOn: $settings.hrWarningEnabled)
                    if settings.hrWarningEnabled {
                        Picker("Warn above", selection: $settings.hrWarningBpm) {
                            ForEach(Array(stride(from: 120, through: 220, by: 5)), id: \.self) { bpm in
                                Text("\(bpm) bpm").tag(bpm)
                            }
                        }
                    }
                } header: {
                    Text("Heart Rate")
                } footer: {
                    Text("When your heart rate reaches this, the heart-rate readout turns red and a paired Apple Watch double-buzzes — repeating every 30 seconds while it stays high.")
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
                    Text("Plays a one-time preview on the main screen — low (yellow), medium (orange) and high (red) vehicles, the new-vehicle beep, escalating Apple Watch wrist taps, and a “radar off” wrist alert at the end — so you can feel and fine-tune every alert before a ride. It runs through once and stops; starting a ride also stops it.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView().environmentObject(ble).environmentObject(settings)
                    } label: {
                        Label("Sensor diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("Shows the Bluetooth services your sensors expose and live radar packets — useful if the radar connects but shows nothing.")
                }

                Section {
                    Text("CycleHUD is a personal quality-of-life cycling HUD built around the Coospo TR70 rear radar. Vehicles behind you appear on a clear radar lane with Apple Watch wrist alerts, and each ride is saved as an Apple Health workout. Also works with Garmin Varia–compatible radars and standard CSC speed/cadence sensors.")
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

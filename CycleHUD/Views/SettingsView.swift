import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BluetoothManager
    @EnvironmentObject var ride: RideManager
    @EnvironmentObject var history: RideHistory
    @EnvironmentObject var weather: WeatherManager
    @EnvironmentObject var sos: SOSManager
    @Environment(\.dismiss) private var dismiss

    /// Set when the rider explicitly picks "Custom" in the wheel-size picker, so
    /// the picker stays on Custom (letting them type a value) even if that value
    /// happens to coincide with a preset.
    @State private var wheelIsCustom = false
    @State private var showResetConfirm = false
    @FocusState private var circumferenceFocused: Bool

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
                    Picker("Language", selection: $settings.appLanguage) {
                        ForEach(AppSettings.supportedLanguages) { Text($0.name).tag($0.code) }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Choose the app's language, or follow your device. Some text (such as system permission prompts) updates after you reopen the app.")
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
                            .focused($circumferenceFocused)
                        Text("mm").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Speed Sensor")
                } footer: {
                    Text("Used to convert wheel revolutions into speed. GPS is used when no speed sensor is connected.")
                }

                Section {
                    Toggle("Save rides as workouts", isOn: $settings.saveWorkouts)
                    if settings.saveWorkouts {
                        HStack {
                            Text("Weight")
                            Spacer()
                            TextField("kg", text: weightText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("kg").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Workouts")
                } footer: {
                    Text("Each ride is saved to Apple Health. Your weight is used with Apple Watch heart rate to estimate calories — without a weight, calories aren't shown. Read from Apple Health when available.")
                }

                Section {
                    Toggle("Beep on new vehicle", isOn: $settings.beepEnabled)
                    Toggle("Spoken vehicle call-outs", isOn: $settings.voiceAlertsEnabled)
                    Toggle("Wrist haptics", isOn: $settings.hapticsEnabled)
                    Toggle("Auto-pause when stopped", isOn: $settings.autoPauseEnabled)
                    Toggle("Keep screen on while riding", isOn: $settings.keepScreenOn)
                } header: {
                    Text("Alerts & Ride")
                } footer: {
                    Text("The new-vehicle beep plays through the phone, and alerts only fire while you're riding (not when idle with the radar on). Spoken call-outs announce each vehicle (\u{201C}car behind\u{201D} with its distance) — handy with bone-conduction headphones, and works alongside or instead of the beep. A paired Apple Watch taps your wrist — once for each new vehicle, faster as one closes in, and a distinct double-buzz if the radar drops out mid-ride. You can mute the beep and the wrist taps (separately or together) straight from the radar screen while riding.")
                }

                Section {
                    Toggle("Rain nowcast", isOn: $settings.weatherEnabled)
                    AppleWeatherAttribution()
                } header: {
                    Text("Weather")
                } footer: {
                    Text("A short-term rain forecast (next hour) appears on the ride screen — when rain is coming, with its intensity, how soon it starts and how long it lasts — alongside the temperature and the wind (shown as headwind or tailwind relative to the way you're heading). It updates every minute while the app is open. A live road-gradient tile is shown too. Uses Apple Weather and your location.")
                }

                Section {
                    Toggle("Upcoming junctions", isOn: $settings.junctionsEnabled)
                    if settings.junctionsEnabled {
                        Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                            HStack {
                                Text("Road data © OpenStreetMap contributors")
                                    .font(.footnote)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Junctions")
                } footer: {
                    Text("Adds a Junction tile to the ride screen showing the next intersection ahead — its layout and the distance to it, counting down as you approach. Road data around your route is fetched from OpenStreetMap while this is on, which sends your approximate location to OpenStreetMap's servers. Nothing is sent while it's off.")
                }

                Section {
                    Toggle("Route planning", isOn: $settings.routePlanningEnabled)
                    if settings.routePlanningEnabled {
                        Toggle("Turn alerts", isOn: $settings.routeTurnAlertsEnabled)
                        Toggle("Route elevation", isOn: $settings.routeElevationEnabled)
                    }
                } header: {
                    Text("Routes")
                } footer: {
                    Text("Adds a map button to the ride screen for planning and picking routes. Plan by tapping start and waypoints on a map — the path snaps to quiet roads and cycle paths, and loops back to the start unless you choose a separate finish. While following a route it appears in the radar panel whenever the road behind is clear, and the Junction tile points the way; pick a route while away from it and CycleHUD also plots a lead-in to the start. Planning and the lead-in send the needed points to the BRouter routing service (brouter.de, OpenStreetMap data); saved routes stay on your device and can be shared as files.")
                }

                Section {
                    NavigationLink {
                        MetricTilesView().environmentObject(settings)
                    } label: {
                        Label("Ride screen tiles", systemImage: "square.grid.2x2")
                    }
                    Toggle("Show units on tiles", isOn: $settings.showTileUnits)
                    Picker("Appearance", selection: $settings.appearanceTheme) {
                        ForEach(AppearanceTheme.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Digits", selection: $settings.digitStyle) {
                        ForEach(DigitStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Landscape layout", isOn: $settings.landscapeEnabled)
                    if settings.landscapeEnabled {
                        Toggle("Radar on the right (landscape)", isOn: $settings.radarOnRight)
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Choose which metric tiles show on the ride screen, and in what order. Appearance offers a clean light theme, an all-black dark theme, or a neon Cyberpunk theme matching the CycleHUD artwork. Landscape layout fixes the ride screen in landscape — radar on the left, ride data and controls on the right — and won't flip when you rotate the phone; Settings and other screens stay in portrait.")
                }

                Section {
                    Toggle("Crash detection", isOn: $settings.crashDetectionEnabled)
                    if settings.crashDetectionEnabled {
                        HStack {
                            Text("Contact name")
                            Spacer()
                            TextField("Name", text: $settings.emergencyContactName)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Contact phone")
                            Spacer()
                            TextField("Number", text: $settings.emergencyContactPhone)
                                .keyboardType(.phonePad)
                                .multilineTextAlignment(.trailing)
                        }
                        Button {
                            dismiss()   // close Settings so the alert can present over the HUD
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sos.trigger() }
                        } label: {
                            Label("Send a test alert", systemImage: "bell.badge")
                        }
                        .disabled(settings.emergencyContact == nil)
                    }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("If a hard impact is detected while you're riding and you come to a stop within a few seconds, a 20-second countdown starts. If you don't cancel it, CycleHUD opens a text to your emergency contact with your location, ready to send. (iOS requires you — or someone nearby — to tap Send; an app can't send a text on its own.) Test it any time with your contact set.")
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
                    Text("Plays a one-time preview on the main screen — a vehicle closing in from low (yellow) through medium (orange) to high (red), the new-vehicle beep, escalating Apple Watch wrist taps, a “radar off” wrist alert, and to finish, a demo route gliding by in the radar panel — so you can feel and fine-tune every alert before a ride. It runs through once and stops; starting a ride also stops it.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView().environmentObject(ble).environmentObject(settings)
                            .environmentObject(history).environmentObject(weather)
                    } label: {
                        Label("Sensor diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("Connection details and live sensor activity — handy if a sensor connects but isn't showing data.")
                }

                Section {
                    Text("CycleHUD is a personal quality-of-life cycling HUD built around the Coospo TR70 rear radar. Vehicles behind you appear on a clear radar lane with Apple Watch wrist alerts, and each ride is saved as an Apple Health workout. Also works with Garmin Varia–compatible radars and standard CSC speed/cadence sensors.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button(role: .destructive) { showResetConfirm = true } label: {
                        Label("Reset to defaults", systemImage: "arrow.counterclockwise")
                    }
                    .confirmationDialog("Reset to defaults?",
                                        isPresented: $showResetConfirm, titleVisibility: .visible) {
                        Button("Reset", role: .destructive) { settings.resetToDefaults() }
                        Button("Cancel", role: .cancel) {}
                    }
                } footer: {
                    Text("Restores the original tiles (three rows, nothing above the radar) and the display and alert settings. Your units, language, weight, wheel size, emergency contact, paired sensors and ride history are kept.")
                }
            }
            .themedList()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        circumferenceFocused = false
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil)
                    }
                }
            }
        }
        .preferredColorScheme(settings.appearanceTheme.colorScheme)
    }

    /// Weight as text so the field is empty (not "0") until a value is entered.
    private var weightText: Binding<String> {
        Binding(
            get: { settings.riderWeightKg > 0 ? String(format: "%g", settings.riderWeightKg) : "" },
            set: { settings.riderWeightKg = Double($0) ?? 0 }
        )
    }

    private var wheelPresetBinding: Binding<Double> {
        Binding(
            get: {
                if wheelIsCustom { return -1 }
                return wheelPresets.first { $0.mm == settings.wheelCircumferenceMM }?.mm ?? -1
            },
            set: { newValue in
                if newValue > 0 {
                    wheelIsCustom = false
                    settings.wheelCircumferenceMM = newValue
                } else {
                    // "Custom": keep the current value but let the field drive it,
                    // and jump the keyboard straight to the circumference field.
                    wheelIsCustom = true
                    circumferenceFocused = true
                }
            }
        )
    }
}

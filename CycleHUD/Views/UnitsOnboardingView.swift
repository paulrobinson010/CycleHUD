import SwiftUI

/// Shown once on first launch to ask the rider for their preferred units.
struct UnitsOnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @FocusState private var weightFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityLabel("CycleHUD")
            VStack(spacing: 6) {
                Text("Welcome to CycleHUD")
                    .font(.title.bold())
                Text("Choose your preferred units. You can change these any time in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(alignment: .leading, spacing: 18) {
                pickerRow(title: "Language") {
                    Picker("Language", selection: $settings.appLanguage) {
                        ForEach(AppSettings.supportedLanguages) { Text($0.name).tag($0.code) }
                    }
                    .pickerStyle(.menu)
                }
                pickerRow(title: "Speed") {
                    Picker("Speed", selection: $settings.speedUnit) {
                        ForEach(SpeedUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                pickerRow(title: "Distance") {
                    Picker("Distance", selection: $settings.distanceUnit) {
                        ForEach(DistanceUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Save rides as Apple Health workouts", isOn: $settings.saveWorkouts)
                        .font(.subheadline.weight(.semibold))
                    if settings.saveWorkouts {
                        HStack(spacing: 8) {
                            TextField("Weight", text: weightText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .focused($weightFocused)
                            Text("kg").foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text("Your weight is used with Apple Watch heart rate to estimate calories. Read from Apple Health when available; without a weight, calories aren't shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                pickerRow(title: "Appearance") {
                    Picker("Appearance", selection: $settings.appearanceTheme) {
                        ForEach(AppearanceTheme.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 28)

            Spacer()

            Button {
                settings.hasChosenUnits = true
            } label: {
                Text("Start Riding")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent))
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(settings.appearanceTheme.colorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { weightFocused = false }
            }
        }
    }

    /// Weight as text so the field is empty (not "0") until a value is entered.
    private var weightText: Binding<String> {
        Binding(
            get: { settings.riderWeightKg > 0 ? String(format: "%g", settings.riderWeightKg) : "" },
            set: { settings.riderWeightKg = Double($0) ?? 0 }
        )
    }

    private func pickerRow<Content: View>(title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }
}

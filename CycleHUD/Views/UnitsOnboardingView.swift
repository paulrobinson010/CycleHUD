import SwiftUI

/// Shown once on first launch to ask the rider for their preferred units.
struct UnitsOnboardingView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "bicycle.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
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
                pickerRow(title: "Weight (for calories)") {
                    HStack {
                        TextField("kg", value: $settings.riderWeightKg, format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("kg").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                pickerRow(title: "Appearance") {
                    Picker("Appearance", selection: $settings.darkModeEnabled) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
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

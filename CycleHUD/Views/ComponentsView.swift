import SwiftUI

/// Bike part wear (Settings → Bike): each tracked part measured against the
/// app's lifetime odometer, with a progress bar toward its check-it interval
/// and a one-tap "serviced" reset. Parts are added from presets and are
/// fully editable.
struct ComponentsView: View {
    @EnvironmentObject var components: ComponentStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                if components.components.isEmpty {
                    Text("Nothing tracked yet — add your chain and every ride counts toward its next check.")
                        .foregroundStyle(.secondary)
                }
                ForEach(components.components) { comp in
                    NavigationLink {
                        ComponentDetailView(component: comp)
                            .environmentObject(components)
                            .environmentObject(settings)
                    } label: {
                        row(comp)
                    }
                }
                .onDelete { components.remove(at: $0) }
            } footer: {
                Text("Distances count up from each part's install or last service. The intervals are starting points — adjust them to your parts and conditions.")
            }
            Section {
                Menu {
                    ForEach(ComponentStore.presets, id: \.name) { preset in
                        Button(LocalizedStringKey(preset.name)) {
                            components.add(
                                name: String(localized: String.LocalizationValue(preset.name),
                                             bundle: Lang.bundle),
                                intervalKm: preset.intervalKm)
                        }
                    }
                } label: {
                    Label("Add component", systemImage: "plus")
                }
            } footer: {
                Text("Bike total: \(distText(components.lifetimeMeters))")
            }
        }
        .navigationTitle("Components")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ c: BikeComponent) -> some View {
        let wear = c.wearMeters(lifetime: components.lifetimeMeters)
        let frac = c.serviceIntervalMeters.map { wear / $0 }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: c.name)
                    .fontWeight(.semibold)
                Spacer()
                Text(verbatim: distText(wear))
                    .monospacedDigit()
                    .foregroundStyle(wearColor(frac))
            }
            if let frac {
                ProgressView(value: min(1, frac))
                    .tint(wearColor(frac))
            }
        }
        .padding(.vertical, 2)
    }

    /// Green while fresh, amber from 80% of the interval, red once due.
    private func wearColor(_ frac: Double?) -> Color {
        guard let frac else { return Theme.textSecondary }
        if frac >= 1 { return Theme.threatHigh }
        if frac >= 0.8 { return Theme.threatLow }
        return Theme.good
    }

    private func distText(_ meters: Double) -> String {
        "\(Fmt.int(settings.distanceUnit.value(fromMeters: meters))) \(settings.distanceUnit.label)"
    }
}

/// One part: rename, pick the interval, see the wear, mark it serviced.
struct ComponentDetailView: View {
    @EnvironmentObject var components: ComponentStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let component: BikeComponent

    @State private var name = ""
    @State private var intervalKm = 0    // 0 = no interval, just tracking

    /// The live stored copy (edits and "serviced" apply to the store).
    private var current: BikeComponent? {
        components.components.first(where: { $0.id == component.id })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            }
            Section {
                // Interval stored in km; shown in the rider's unit.
                Picker("Service interval", selection: $intervalKm) {
                    Text("Off").tag(0)
                    if intervalKm > 0 && intervalKm % 500 != 0 {
                        Text(verbatim: intervalText(intervalKm)).tag(intervalKm)
                    }
                    ForEach(Array(stride(from: 500, through: 20000, by: 500)), id: \.self) { km in
                        Text(verbatim: intervalText(km)).tag(km)
                    }
                }
                .pickerStyle(.navigationLink)
            } footer: {
                Text("You'll get a notification at the end of the ride that crosses it.")
            }
            Section {
                LabeledContent("Since install") {
                    Text(verbatim: distText((current ?? component)
                        .wearMeters(lifetime: components.lifetimeMeters)))
                        .monospacedDigit()
                }
                Button("Mark serviced") {
                    saveEdits()
                    if let current { components.markServiced(current) }
                    dismiss()
                }
            } footer: {
                Text("Marking it serviced restarts the count from today — use it when the part is replaced, cleaned or checked.")
            }
        }
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = component.name
            intervalKm = Int((component.serviceIntervalMeters ?? 0) / 1000)
        }
        .onDisappear { saveEdits() }
    }

    /// Apply name/interval onto the STORE's current copy — never onto the
    /// stale `component` snapshot (that would undo a just-tapped "serviced").
    private func saveEdits() {
        guard var c = current else { return }
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { c.name = name }
        let newInterval: Double? = intervalKm > 0 ? Double(intervalKm) * 1000 : nil
        if newInterval != c.serviceIntervalMeters {
            c.serviceIntervalMeters = newInterval
            c.notifiedAtMeters = nil   // re-arm the reminder for the new bar
        }
        components.update(c)
    }

    private func intervalText(_ km: Int) -> String {
        "\(Fmt.int(settings.distanceUnit.value(fromMeters: Double(km) * 1000))) \(settings.distanceUnit.label)"
    }

    private func distText(_ meters: Double) -> String {
        "\(Fmt.int(settings.distanceUnit.value(fromMeters: meters))) \(settings.distanceUnit.label)"
    }
}

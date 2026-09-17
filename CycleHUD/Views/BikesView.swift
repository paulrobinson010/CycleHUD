import SwiftUI

/// The rider's bikes (Settings → Bike): pick the one you're riding, and keep
/// each one's wheel size, features, sensors and component wear separate.
struct BikesView: View {
    @EnvironmentObject var bikes: BikeStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BluetoothManager

    /// Wheel circumferences (mm), road through mountain — starting points for
    /// a new bike; measure your own for exact distance.
    static let wheelPresets: [(name: String, mm: Double)] = [
        ("700x23c", 2096), ("700x25c", 2105), ("700x28c", 2136), ("700x32c", 2155),
        ("700x40c", 2200), ("650b x 47", 2030),
        ("26 x 1.75\"", 2023), ("26 x 2.1\"", 2068), ("26 x 2.35\"", 2083),
        ("27.5 x 2.25\"", 2180), ("27.5 x 2.4\"", 2215),
        ("29 x 2.1\"", 2265), ("29 x 2.25\"", 2290), ("29 x 2.4\"", 2330)
    ]

    var body: some View {
        List {
            Section {
                ForEach(bikes.bikes) { bike in
                    NavigationLink {
                        BikeDetailView(bikeID: bike.id)
                            .environmentObject(bikes)
                            .environmentObject(settings)
                            .environmentObject(ble)
                    } label: {
                        row(bike)
                    }
                }
            } header: {
                Text("Your bikes")
            } footer: {
                Text("Tap a bike to select it — rides, distance and component wear are recorded against whichever bike is selected. Assign a bike's speed or cadence sensor to it and CycleHUD selects that bike by itself when the sensor connects.")
            }

            Section {
                ForEach(BikeKind.allCases) { kind in
                    Button {
                        bikes.select(bikes.add(name: kind.defaultName, kind: kind))
                    } label: {
                        Label(kind.label, systemImage: kind.systemImage)
                    }
                }
            } header: {
                Text("Add a bike")
            }
        }
        .navigationTitle("Bikes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ bike: BikeProfile) -> some View {
        let isActive = bike.id == bikes.active?.id
        return HStack(spacing: 12) {
            Button {
                bikes.select(bike.id)
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isActive ? Theme.good : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: bike.name)
                    .fontWeight(isActive ? .semibold : .regular)
                Text(verbatim: "\(bike.kind.label) · \(distText(bike.odometerMeters))"
                     + (bike.components.isEmpty ? ""
                        : " · \(bike.components.count) \(String(localized: "parts", bundle: Lang.bundle))"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func distText(_ meters: Double) -> String {
        "\(Fmt.int(settings.distanceUnit.value(fromMeters: meters))) \(settings.distanceUnit.label)"
    }
}

/// One bike: its name and kind, the wheel size its speed sensor needs, which
/// road features suit it, the sensors fitted to it, and its components.
struct BikeDetailView: View {
    @EnvironmentObject var bikes: BikeStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: BluetoothManager
    @Environment(\.dismiss) private var dismiss
    let bikeID: UUID

    @State private var name = ""
    @State private var wheelMM = ""

    private var bike: BikeProfile? { bikes.bikes.first { $0.id == bikeID } }

    var body: some View {
        Form {
            if let bike {
                Section {
                    TextField("Name", text: $name)
                    Picker("Type", selection: kindBinding(bike)) {
                        ForEach(BikeKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Circumference")
                        Spacer()
                        TextField("mm", text: $wheelMM)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("mm").foregroundStyle(.secondary)
                    }
                    Menu {
                        ForEach(BikesView.wheelPresets, id: \.name) { preset in
                            Button(preset.name) {
                                wheelMM = String(Int(preset.mm))
                                save()
                            }
                        }
                    } label: {
                        Label("Pick a tyre size", systemImage: "list.bullet")
                    }
                } header: {
                    Text("Wheel")
                } footer: {
                    Text("Used to turn this bike's wheel-sensor revolutions into speed and distance. A mountain bike's wheel is much bigger than a road bike's, so a road figure left in place reports both several percent low. GPS is used when no speed sensor is connected.")
                }

                Section {
                    Toggle("Crash detection", isOn: boolBinding(bike, \.crashDetectionEnabled))
                    Toggle("Junctions", isOn: boolBinding(bike, \.junctionsEnabled))
                } header: {
                    Text("Features on this bike")
                } footer: {
                    Text("Both are usually worth having on the road and awkward off it: rough ground trips the impact detector, and stopping after it is normal on a trail, while the junction map covers roads and cycleways — not paths, tracks or bridleways. Selecting this bike applies these.")
                }

                Section {
                    LabeledContent("Distance") {
                        Text(verbatim: distText(bike.odometerMeters)).monospacedDigit()
                    }
                    NavigationLink {
                        ComponentsView(bikeID: bikeID)
                            .environmentObject(bikes)
                            .environmentObject(settings)
                    } label: {
                        HStack {
                            Label("Components", systemImage: "wrench.and.screwdriver")
                            Spacer()
                            Text(verbatim: "\(bike.components.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !assignableSensors.isEmpty {
                    Section {
                        ForEach(assignableSensors) { dev in
                            Button {
                                let owned = bike.sensorIDs.contains(dev.id)
                                bikes.assign(sensor: dev.id, to: owned ? nil : bikeID)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: dev.name.isEmpty
                                             ? String(localized: "Sensor", bundle: Lang.bundle)
                                             : dev.name)
                                            .foregroundStyle(Theme.textPrimary)
                                        if let other = bikes.bikeOwning(sensor: dev.id),
                                           other.id != bikeID {
                                            Text(verbatim: other.name)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if bike.sensorIDs.contains(dev.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.good)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Sensors on this bike")
                    } footer: {
                        Text("When one of these connects, CycleHUD selects this bike — so swapping bikes needs nothing from you. A sensor belongs to one bike at a time.")
                    }
                }

                if bikes.bikes.count > 1 {
                    Section {
                        Button("Remove bike", role: .destructive) {
                            bikes.remove(bikeID)
                            dismiss()
                        }
                    } footer: {
                        Text("Removes this bike and its component history. Rides already recorded against it are kept.")
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = bike?.name ?? ""
            wheelMM = String(Int((bike?.wheelCircumferenceMM ?? 2105).rounded()))
        }
        .onDisappear { save() }
    }

    /// Bike-mounted sensors only — a heart-rate strap is on the rider, so it
    /// says nothing about which bike is being ridden.
    private var assignableSensors: [SavedDevice] {
        ble.savedDevices.filter { !$0.roles.contains(.heartRate) || $0.roles.count > 1 }
    }

    /// Toggles and the type picker write straight through (discrete actions).
    private func boolBinding(_ bike: BikeProfile,
                             _ key: WritableKeyPath<BikeProfile, Bool>) -> Binding<Bool> {
        Binding(get: { bike[keyPath: key] },
                set: { new in
                    var copy = bike
                    copy[keyPath: key] = new
                    bikes.update(copy)
                })
    }

    private func kindBinding(_ bike: BikeProfile) -> Binding<BikeKind> {
        Binding(get: { bike.kind },
                set: { new in
                    var copy = bike
                    copy.kind = new
                    bikes.update(copy)
                })
    }

    /// Text fields are saved on submit/leave, onto the store's CURRENT copy so
    /// a toggle changed in between isn't clobbered by a stale snapshot.
    private func save() {
        guard var current = bike else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { current.name = trimmed }
        if let mm = Double(wheelMM.filter(\.isNumber)), mm >= 500, mm <= 3500 {
            current.wheelCircumferenceMM = mm
        }
        bikes.update(current)
    }

    private func distText(_ meters: Double) -> String {
        "\(Fmt.int(settings.distanceUnit.value(fromMeters: meters))) \(settings.distanceUnit.label)"
    }
}

/// One bike's part wear: each part measured against that bike's own distance,
/// with a progress bar toward its check-it interval and a one-tap reset.
struct ComponentsView: View {
    @EnvironmentObject var bikes: BikeStore
    @EnvironmentObject var settings: AppSettings
    let bikeID: UUID

    private var bike: BikeProfile? { bikes.bikes.first { $0.id == bikeID } }

    var body: some View {
        List {
            Section {
                if bike?.components.isEmpty ?? true {
                    Text("Nothing tracked yet — add your chain and every ride counts toward its next check.")
                        .foregroundStyle(.secondary)
                }
                ForEach(bike?.components ?? []) { comp in
                    NavigationLink {
                        ComponentDetailView(bikeID: bikeID, component: comp)
                            .environmentObject(bikes)
                            .environmentObject(settings)
                    } label: {
                        row(comp)
                    }
                }
                .onDelete { bikes.removeComponents(at: $0, on: bikeID) }
            } footer: {
                Text("Distances count up from each part's install or last service. The intervals are starting points — adjust them to your parts and conditions.")
            }
            Section {
                Menu {
                    ForEach(BikeStore.presets, id: \.name) { preset in
                        Button(LocalizedStringKey(preset.name)) {
                            bikes.addComponent(
                                name: String(localized: String.LocalizationValue(preset.name),
                                             bundle: Lang.bundle),
                                intervalKm: preset.intervalKm, to: bikeID)
                        }
                    }
                } label: {
                    Label("Add component", systemImage: "plus")
                }
            } footer: {
                Text("\(bike?.name ?? "") total: \(distText(bike?.odometerMeters ?? 0))")
            }
        }
        .navigationTitle("Components")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ c: BikeComponent) -> some View {
        let odometer = bike?.odometerMeters ?? 0
        let wear = c.wearMeters(lifetime: odometer)
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
    @EnvironmentObject var bikes: BikeStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let bikeID: UUID
    let component: BikeComponent

    @State private var name = ""
    @State private var intervalKm = 0    // 0 = no interval, just tracking

    private var bike: BikeProfile? { bikes.bikes.first { $0.id == bikeID } }
    /// The live stored copy (edits and "serviced" apply to the store).
    private var current: BikeComponent? {
        bike?.components.first { $0.id == component.id }
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
                        .wearMeters(lifetime: bike?.odometerMeters ?? 0)))
                        .monospacedDigit()
                }
                Button("Mark serviced") {
                    saveEdits()
                    if let current { bikes.markServiced(current, on: bikeID) }
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
        bikes.updateComponent(c, on: bikeID)
    }

    private func intervalText(_ km: Int) -> String {
        "\(Fmt.int(settings.distanceUnit.value(fromMeters: Double(km) * 1000))) \(settings.distanceUnit.label)"
    }

    private func distText(_ meters: Double) -> String {
        "\(Fmt.int(settings.distanceUnit.value(fromMeters: meters))) \(settings.distanceUnit.label)"
    }
}

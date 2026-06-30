import SwiftUI

/// Lets the rider choose which metric tiles appear on the ride screen, and in
/// what order. Tap Edit to reorder or remove shown tiles; tap a tile in
/// "Available" to add it.
struct MetricTilesView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(shown) { kind in row(kind, isShown: true) }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
            } header: {
                Text("Shown")
            } footer: {
                Text("Tap Edit to reorder or remove tiles. Weather tiles (Rain, Temp, Wind) only appear when Weather is turned on.")
            }

            if !available.isEmpty {
                Section("Available") {
                    ForEach(available) { kind in
                        Button { add(kind) } label: { row(kind, isShown: false) }
                    }
                }
            }
        }
        .navigationTitle("Ride screen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    // MARK: - Data

    private var shown: [MetricKind] { settings.metricKinds }
    private var available: [MetricKind] {
        let chosen = Set(settings.metricTiles)
        return MetricKind.allCases.filter { !chosen.contains($0.rawValue) }
    }

    private func row(_ kind: MetricKind, isShown: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            Text(kind.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if !isShown {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.good)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Mutations

    private func move(from offsets: IndexSet, to destination: Int) {
        var tiles = settings.metricTiles
        tiles.move(fromOffsets: offsets, toOffset: destination)
        settings.metricTiles = tiles
    }

    private func delete(at offsets: IndexSet) {
        var tiles = settings.metricTiles
        tiles.remove(atOffsets: offsets)
        settings.metricTiles = tiles
    }

    private func add(_ kind: MetricKind) {
        guard !settings.metricTiles.contains(kind.rawValue) else { return }
        settings.metricTiles.append(kind.rawValue)
    }
}

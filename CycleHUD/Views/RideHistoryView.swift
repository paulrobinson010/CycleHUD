import SwiftUI

/// List of previous rides (from the local store). Tapping one shows the same
/// summary sheet you get at the end of a ride.
struct RideHistoryView: View {
    @EnvironmentObject var history: RideHistory
    @EnvironmentObject var settings: AppSettings
    @State private var selected: RideSummary?

    var body: some View {
        List {
            if history.rides.isEmpty {
                Text("No rides yet. Your completed rides will appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.rides) { ride in
                    Button { selected = ride } label: { row(ride) }
                        .buttonStyle(.plain)
                }
                .onDelete { history.delete(at: $0) }
            }
        }
        .themedList()
        .navigationTitle("Previous Rides")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { ride in
            RideSummaryView(summary: ride).environmentObject(settings)
                .environmentObject(history)
        }
    }

    private func row(_ ride: RideSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(ride.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 15, weight: .semibold))
                Text("\(distance(ride))  ·  \(time(ride))")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func distance(_ ride: RideSummary) -> String {
        "\(Fmt.decimal(settings.distanceUnit.value(fromMeters: ride.distanceMeters), 2)) \(settings.distanceUnit.label)"
    }
    private func time(_ ride: RideSummary) -> String {
        let s = Int(ride.movingTimeSeconds)
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

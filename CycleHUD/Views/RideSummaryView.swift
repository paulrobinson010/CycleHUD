import SwiftUI

/// A ride's stats, shown as a sheet both at the end of a ride and when tapping a
/// ride in the history list. Self-contained with its own close button.
struct RideSummaryView: View {
    let summary: RideSummary
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    statGrid
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Ride Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(distanceValue)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            Text(settings.distanceUnit.label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 6)
        }
        .padding(.top, 8)
    }

    private var statGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            stat("Time", timeValue, "")
            stat("Avg Speed", avgSpeedValue, settings.speedUnit.label)
            stat("Ascent", ascentValue, settings.distanceUnit.shortLabel)
            stat("Calories", caloriesValue, "kcal")
        }
    }

    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Theme.labelFont)
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.valueFont(28))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
    }

    // MARK: - Formatting

    private var distanceValue: String {
        String(format: "%.2f", settings.distanceUnit.value(fromMeters: summary.distanceMeters))
    }
    private var avgSpeedValue: String {
        String(format: "%.1f", settings.speedUnit.value(fromMps: summary.averageSpeedMps))
    }
    private var ascentValue: String {
        "\(Int(settings.distanceUnit.shortValue(fromMeters: summary.elevationGainMeters).rounded()))"
    }
    private var caloriesValue: String {
        summary.caloriesKcal >= 1 ? "\(Int(summary.caloriesKcal))" : "—"
    }
    private var timeValue: String {
        let s = Int(summary.movingTimeSeconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

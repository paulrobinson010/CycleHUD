import SwiftUI
import MapKit

/// A ride's stats, shown as a sheet both at the end of a ride and when tapping a
/// ride in the history list. Self-contained with its own close button.
struct RideSummaryView: View {
    let summary: RideSummary
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showRouteMap = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    routeMap
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

    @ViewBuilder private var routeMap: some View {
        let coords = summary.coordinates
        if coords.count >= 2 {
            Button { showRouteMap = true } label: {
                Map(initialPosition: .region(Self.region(for: coords))) {
                    MapPolyline(coordinates: coords)
                        .stroke(Theme.accent, lineWidth: 4)
                    ForEach(Array(summary.radarCoordinates.enumerated()), id: \.offset) { _, c in
                        Annotation("", coordinate: c) { Self.radarDot }
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .allowsHitTesting(false)   // tap goes to the button (expands the map)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(10)
                }
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $showRouteMap) {
                RouteMapView(coordinates: coords, radarCoordinates: summary.radarCoordinates)
            }
        }
    }

    /// A small dot marking where a vehicle was detected behind the rider.
    static var radarDot: some View {
        Circle()
            .fill(Theme.threatHigh)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }

    private var statGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(stats, id: \.0) { stat($0.0, $0.1, $0.2) }
        }
    }

    /// Stat cells, including heart rate only when the ride captured it.
    private var stats: [(String, String, String)] {
        var s: [(String, String, String)] = [
            ("Time", timeValue, ""),
            ("Avg Speed", avgSpeedValue, settings.speedUnit.label),
        ]
        if let avg = summary.averageHeartRate {
            s.append(("Avg HR", "\(avg)", "bpm"))
            s.append(("Max HR", summary.maxHeartRate.map { "\($0)" } ?? "—", "bpm"))
        }
        s.append(("Ascent", ascentValue, settings.distanceUnit.shortLabel))
        s.append(("Calories", caloriesValue, "kcal"))
        if let radar = summary.radarPoints, !radar.isEmpty {
            s.append(("Vehicles", "\(radar.count)", ""))
        }
        return s
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

    // MARK: - Map region

    static func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        // Pad the bounds so the track isn't flush to the edges.
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.003),
                                    longitudeDelta: max((maxLon - minLon) * 1.4, 0.003))
        return MKCoordinateRegion(center: center, span: span)
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

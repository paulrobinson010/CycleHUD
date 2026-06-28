import SwiftUI
import MapKit
import Charts

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
                    graphs
                    passesLink
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
                RouteMapView(coordinates: coords,
                             radarCoordinates: summary.radarCoordinates,
                             passes: summary.passes ?? [])
                    .environmentObject(settings)
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

    /// Link to the per-vehicle pass review, shown only when passes were logged.
    @ViewBuilder private var passesLink: some View {
        if let passes = summary.passes, !passes.isEmpty {
            let fast = passes.filter { $0.level == .high }.count
            NavigationLink {
                VehiclePassesView(passes: passes).environmentObject(settings)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "car.2.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(fast > 0 ? Theme.threatHigh : Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vehicle passes")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text(fast > 0 ? "\(passes.count) logged · \(fast) fast"
                                       : "\(passes.count) logged")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            }
            .buttonStyle(.plain)
        }
    }

    /// Speed / heart-rate / elevation over the ride, as stacked line charts that
    /// share a minutes x-axis. Heart rate is only shown if the ride captured any.
    @ViewBuilder private var graphs: some View {
        if let track = summary.track, track.count >= 2 {
            VStack(spacing: 16) {
                metricChart(title: "Speed", unit: settings.speedUnit.label,
                            color: Theme.accent,
                            points: track.map { ($0.t, settings.speedUnit.value(fromMps: $0.speedMps)) })
                if track.contains(where: { ($0.hr ?? 0) > 0 }) {
                    metricChart(title: "Heart rate", unit: "bpm", color: Theme.threatHigh,
                                points: track.compactMap { s in s.hr.map { (s.t, Double($0)) } })
                }
                metricChart(title: "Elevation", unit: settings.distanceUnit.shortLabel,
                            color: Theme.good, filled: true,
                            points: track.map { ($0.t, settings.distanceUnit.shortValue(fromMeters: $0.altitude)) })
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        }
    }

    private func metricChart(title: String, unit: String, color: Color,
                             filled: Bool = false,
                             points: [(Double, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(unit)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            Chart {
                ForEach(points.indices, id: \.self) { i in
                    if filled {
                        AreaMark(x: .value("min", points[i].0 / 60.0),
                                 y: .value(title, points[i].1))
                            .foregroundStyle(color.opacity(0.16))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("min", points[i].0 / 60.0),
                             y: .value(title, points[i].1))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let m = value.as(Double.self) {
                            Text("\(Int(m))′")
                        }
                    }
                }
            }
            .frame(height: 96)
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

import SwiftUI
import MapKit
import Charts

/// Riding trends, personal records and — uniquely — traffic statistics from
/// the radar, computed across the whole local ride history. Everything here
/// is derived on-device from data the app already keeps.
struct InsightsView: View {
    @EnvironmentObject var history: RideHistory
    @EnvironmentObject var settings: AppSettings

    @State private var data: InsightsData?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let data {
                    if data.rideCount == 0 {
                        Text("No rides yet — insights build as you ride.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 40)
                    } else {
                        trendsCard(data)
                        recordsCard(data)
                        trafficCard(data)
                        if !data.passCoordinates.isEmpty {
                            hotspotCard(data)
                        }
                    }
                } else {
                    ProgressView().padding(.top, 60)
                }
            }
            .padding()
        }
        .background(ThemeBackground().ignoresSafeArea())
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let rides = history.rides
            data = await Task.detached(priority: .utility) {
                InsightsData(rides: rides)
            }.value
        }
    }

    // MARK: - Trends

    private func trendsCard(_ data: InsightsData) -> some View {
        card("Trends") {
            Text("Distance by week")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Chart(data.weeks, id: \.start) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear),
                        y: .value("Distance", settings.distanceUnit.value(fromMeters: week.distanceMeters)))
                    .foregroundStyle(Theme.accent)
                    .cornerRadius(3)
            }
            .frame(height: 110)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) {
                    AxisValueLabel(format: .dateTime.day().month(), centered: true)
                        .font(.system(size: 9))
                }
            }
            Text("Ascent by week")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 6)
            Chart(data.weeks, id: \.start) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear),
                        y: .value("Ascent", week.ascentMeters))
                    .foregroundStyle(Theme.good)
                    .cornerRadius(3)
            }
            .frame(height: 80)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) {
                    AxisValueLabel(format: .dateTime.day().month(), centered: true)
                        .font(.system(size: 9))
                }
            }
        }
    }

    // MARK: - Records

    private func recordsCard(_ data: InsightsData) -> some View {
        card("Records") {
            if let r = data.longestRide {
                recordRow("Longest ride", distText(r.distanceMeters), r.date)
            }
            if let r = data.mostClimbing {
                recordRow("Most climbing", "↗ \(Fmt.int(r.elevationGainMeters)) m", r.date)
            }
            if let r = data.fastestAverage {
                recordRow("Fastest average",
                          "\(Fmt.decimal(settings.speedUnit.value(fromMps: r.averageSpeedMps), 1)) \(settings.speedUnit.label)",
                          r.date)
            }
            if let (speed, date) = data.topSpeed {
                recordRow("Top speed",
                          "\(Fmt.decimal(settings.speedUnit.value(fromMps: speed), 1)) \(settings.speedUnit.label)",
                          date)
            }
        }
    }

    private func recordRow(_ title: LocalizedStringKey, _ value: String, _ date: Date) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Traffic

    private func trafficCard(_ data: InsightsData) -> some View {
        card("Traffic") {
            statRow("Vehicles detected", Fmt.int(data.totalVehicles))
            statRow("Detections per km",
                    data.totalKm > 0 ? Fmt.decimal(Double(data.totalVehicles) / data.totalKm, 1) : "—")
            if let fastest = data.fastestOvertakeMps {
                statRow("Fastest overtake",
                        "\(Fmt.int(settings.speedUnit.value(fromMps: fastest))) \(settings.speedUnit.label)")
            }
            if let r = data.busiestRide {
                recordRow("Busiest ride",
                          "\(Fmt.decimal(r.perKm, 1)) /km", r.date)
            }
        }
    }

    private func statRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(verbatim: value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Hotspots

    private func hotspotCard(_ data: InsightsData) -> some View {
        card("Where vehicles passed you") {
            Map(initialPosition: .region(data.passRegion)) {
                ForEach(Array(data.passCoordinates.enumerated()), id: \.offset) { _, c in
                    Annotation("", coordinate: c) {
                        Circle()
                            .fill(Theme.threatHigh.opacity(0.55))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Chrome

    private func card(_ title: LocalizedStringKey,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
    }

    private func distText(_ meters: Double) -> String {
        "\(Fmt.decimal(settings.distanceUnit.value(fromMeters: meters), 1)) \(settings.distanceUnit.label)"
    }
}

/// Everything the screen shows, computed once off the main thread.
struct InsightsData {
    struct Week {
        let start: Date
        var distanceMeters: Double
        var ascentMeters: Double
    }
    struct BusiestRide {
        let date: Date
        let perKm: Double
    }

    let rideCount: Int
    let totalKm: Double
    let weeks: [Week]
    let longestRide: RideSummary?
    let mostClimbing: RideSummary?
    let fastestAverage: RideSummary?
    let topSpeed: (Double, Date)?
    let totalVehicles: Int
    let fastestOvertakeMps: Double?
    let busiestRide: BusiestRide?
    let passCoordinates: [CLLocationCoordinate2D]
    let passRegion: MKCoordinateRegion

    init(rides: [RideSummary]) {
        rideCount = rides.count
        totalKm = rides.reduce(0) { $0 + $1.distanceMeters } / 1000

        // Last 8 ISO weeks, empty weeks included so gaps show honestly.
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        var buckets: [Date: Week] = [:]
        for offset in 0..<8 {
            if let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek) {
                buckets[start] = Week(start: start, distanceMeters: 0, ascentMeters: 0)
            }
        }
        for ride in rides {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: ride.date)?.start,
                  buckets[start] != nil else { continue }
            buckets[start]?.distanceMeters += ride.distanceMeters
            buckets[start]?.ascentMeters += ride.elevationGainMeters
        }
        weeks = buckets.values.sorted { $0.start < $1.start }

        longestRide = rides.max { $0.distanceMeters < $1.distanceMeters }
        mostClimbing = rides.filter { $0.elevationGainMeters > 1 }
            .max { $0.elevationGainMeters < $1.elevationGainMeters }
        fastestAverage = rides.filter { $0.distanceMeters >= 5000 }
            .max { $0.averageSpeedMps < $1.averageSpeedMps }
        topSpeed = rides.compactMap { ride -> (Double, Date)? in
            guard let top = ride.routeSpeeds?.max(), top > 0 else { return nil }
            return (top, ride.date)
        }.max { $0.0 < $1.0 }

        var vehicles = 0
        for ride in rides { vehicles += ride.radarPoints?.count ?? 0 }
        totalVehicles = vehicles

        // Estimated overtake speed = closing speed + the rider's own speed.
        // (Plain loops: the chained flatMap/map/max version type-checked too
        // slowly for the compiler.)
        var fastest: Double?
        for ride in rides {
            for pass in ride.passes ?? [] {
                for sample in pass.cleanedSamples {
                    let speedMps: Double = (sample.closingKmh + sample.riderKmh) / 3.6
                    if speedMps > (fastest ?? 0) { fastest = speedMps }
                }
            }
        }
        fastestOvertakeMps = fastest

        var busiest: BusiestRide?
        for ride in rides where ride.distanceMeters >= 5000 {
            let count = Double(ride.radarPoints?.count ?? 0)
            let perKm: Double = count / (ride.distanceMeters / 1000)
            if perKm > (busiest?.perKm ?? 0) {
                busiest = BusiestRide(date: ride.date, perKm: perKm)
            }
        }
        busiestRide = busiest

        // Pass locations, most recent first, capped so the map stays light.
        let coords = rides.flatMap { ride in
            (ride.passes ?? []).compactMap { pass -> CLLocationCoordinate2D? in
                guard let lat = pass.lat, let lon = pass.lon else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        passCoordinates = Array(coords.prefix(500))
        if passCoordinates.isEmpty {
            passRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
        } else {
            let lats = passCoordinates.map(\.latitude)
            let lons = passCoordinates.map(\.longitude)
            passRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                               longitude: (lons.min()! + lons.max()!) / 2),
                span: MKCoordinateSpan(latitudeDelta: max(0.02, (lats.max()! - lats.min()!) * 1.4),
                                       longitudeDelta: max(0.02, (lons.max()! - lons.min()!) * 1.4)))
        }
    }
}

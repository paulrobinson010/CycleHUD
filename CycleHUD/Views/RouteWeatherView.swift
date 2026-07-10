import SwiftUI
import MapKit

/// "How would this route play out?" — pick a start time and the route is
/// simulated against the hourly forecast: riding time predicted from the
/// rider's own past rides on similar terrain, the map coloured by the wind
/// AT THE TIME each stretch would be ridden, and an hour-by-hour timeline of
/// conditions from rollout to finish.
struct RouteWeatherView: View {
    let route: PlannedRoute
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var history: RideHistory
    @EnvironmentObject var weather: WeatherManager
    @Environment(\.dismiss) private var dismiss

    @State private var startDate = Calendar.current.date(
        bySettingHour: Calendar.current.component(.hour, from: Date()) + 1,
        minute: 0, second: 0, of: Date()) ?? Date()
    @State private var hours: [WeatherManager.HourForecast]?
    @State private var loaded = false

    /// Predicted speed from past rides on similar terrain (hilliness-matched).
    private var estimatedSpeedMps: Double {
        Self.estimatedSpeed(for: route, history: history.rides)
    }
    private var elapsedSeconds: Double { route.distanceMeters / estimatedSpeedMps }
    private var finishDate: Date { startDate.addingTimeInterval(elapsedSeconds) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    DatePicker("Start time", selection: $startDate,
                               in: Date()...Date().addingTimeInterval(8 * 24 * 3600))
                        .font(Theme.font(size: 15, weight: .semibold))
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))

                    predictionCard
                    if let hours, !relevantHours(hours).isEmpty {
                        windMap(hours)
                        timeline(hours)
                        HStack {
                            AppleWeatherAttribution()
                            Spacer()
                        }
                    } else if loaded {
                        Text("No forecast available.")
                            .font(Theme.font(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ProgressView().padding(.top, 30)
                    }
                }
                .padding()
            }
            .background(ThemeBackground().ignoresSafeArea())
            .navigationTitle("Weather preview")
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
            .task {
                let mid = route.path[route.path.count / 2].coordinate
                hours = await weather.hourly(at: mid)
                loaded = true
            }
        }
    }

    // MARK: - Prediction

    private var predictionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Riding time")
                        .font(Theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: timeText(elapsedSeconds))
                        .font(Theme.font(size: 22, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Estimated finish")
                        .font(Theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(finishDate.formatted(date: .omitted, time: .shortened))
                        .font(Theme.font(size: 22, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Text("Based on your rides on similar terrain.")
                .font(Theme.font(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
    }

    private func timeText(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }

    /// Average speed of the 5 past rides (≥5 km) closest in hilliness to this
    /// route; falls back to the overall average, then a 20 km/h default.
    static func estimatedSpeed(for route: PlannedRoute, history: [RideSummary]) -> Double {
        let candidates = history.filter { $0.distanceMeters >= 5000 && $0.movingTimeSeconds > 60 }
        guard !candidates.isEmpty else { return 20.0 / 3.6 }
        let overall = candidates.reduce(0.0) { $0 + $1.averageSpeedMps } / Double(candidates.count)
        guard let elevations = route.elevations, route.distanceMeters > 0 else { return overall }
        let routeAscent = zip(elevations, elevations.dropFirst())
            .reduce(0.0) { $0 + max(0, $1.1 - $1.0) }
        let routeHilliness = routeAscent / route.distanceMeters
        let similar = candidates
            .sorted {
                abs($0.elevationGainMeters / $0.distanceMeters - routeHilliness)
                    < abs($1.elevationGainMeters / $1.distanceMeters - routeHilliness)
            }
            .prefix(5)
        return similar.reduce(0.0) { $0 + $1.averageSpeedMps } / Double(similar.count)
    }

    // MARK: - Wind-at-arrival map

    private struct Run: Identifiable {
        let id: Int
        let coords: [CLLocationCoordinate2D]
        let exposure: Int
    }

    private func windMap(_ hours: [WeatherManager.HourForecast]) -> some View {
        let runs = arrivalWindRuns(hours)
        let coords = route.path.map(\.coordinate)
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                           longitude: (lons.min()! + lons.max()!) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 1.4),
                                   longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.4)))
        return Map(initialPosition: .region(region)) {
            ForEach(runs) { run in
                MapPolyline(coordinates: run.coords)
                    .stroke(run.exposure > 0 ? Theme.threatMedium
                                : (run.exposure < 0 ? Theme.good : Theme.accent),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let start = coords.first {
                Annotation("", coordinate: start) {
                    Circle().fill(Theme.good).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// The wind colouring, but against the forecast at each stretch's ARRIVAL
    /// time rather than the wind right now.
    private func arrivalWindRuns(_ hours: [WeatherManager.HourForecast]) -> [Run] {
        let path = route.path
        guard path.count >= 2 else { return [] }
        var dist = 0.0
        func exposure(_ i: Int) -> Int {
            let arrival = startDate.addingTimeInterval(dist / estimatedSpeedMps)
            guard let hour = hours.last(where: { $0.date <= arrival }) ?? hours.first,
                  abs(hour.date.timeIntervalSince(arrival)) < 2 * 3600 else { return 0 }
            let course = PlannedRoute.bearing(path[i].coordinate, path[i + 1].coordinate)
            let head = hour.windSpeedMps
                * cos((hour.windFromDegrees - course) * .pi / 180)
            if head > 1.5 { return 1 }
            if head < -1.5 { return -1 }
            return 0
        }
        var runs: [Run] = []
        var startIdx = 0
        var current = exposure(0)
        for i in 1..<(path.count - 1) {
            dist += PlannedRoute.meters(path[i - 1].coordinate, path[i].coordinate)
            let k = exposure(i)
            if k != current {
                runs.append(Run(id: runs.count,
                                coords: path[startIdx...i].map(\.coordinate),
                                exposure: current))
                startIdx = i
                current = k
            }
        }
        runs.append(Run(id: runs.count,
                        coords: path[startIdx...].map(\.coordinate),
                        exposure: current))
        return runs
    }

    // MARK: - Timeline

    private func relevantHours(_ hours: [WeatherManager.HourForecast]) -> [WeatherManager.HourForecast] {
        hours.filter {
            $0.date > startDate.addingTimeInterval(-3600)
                && $0.date < finishDate.addingTimeInterval(1800)
        }
    }

    private func timeline(_ hours: [WeatherManager.HourForecast]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(relevantHours(hours).enumerated()), id: \.offset) { _, hour in
                HStack(spacing: 10) {
                    Text(hour.date.formatted(date: .omitted, time: .shortened))
                        .font(Theme.font(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 64, alignment: .leading)
                    Image(systemName: hour.symbolName)
                        .font(Theme.font(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26)
                    Text(verbatim: temperatureText(hour.temperatureC))
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 42, alignment: .leading)
                    HStack(spacing: 3) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(hour.windFromDegrees + 180))
                        Text(verbatim: "\(Fmt.int(settings.speedUnit.value(fromMps: hour.windSpeedMps))) \(settings.speedUnit.label)")
                            .font(Theme.font(size: 13, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if hour.precipitationChance >= 0.15 {
                        Text(verbatim: "☂ \(Fmt.int(hour.precipitationChance * 100))%")
                            .font(Theme.font(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
    }

    private func temperatureText(_ celsius: Double) -> String {
        let imperial = settings.distanceUnit == .mi
        let t = imperial ? celsius * 9 / 5 + 32 : celsius
        return "\(Fmt.int(t))°"
    }
}

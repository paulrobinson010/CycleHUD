import SwiftUI
import Charts

/// A reviewable list of every vehicle that approached during a ride, newest
/// first, with close passes (within 15 m) flagged. Tap a row for the full trace.
struct VehiclePassesView: View {
    let passes: [VehiclePass]
    @EnvironmentObject var settings: AppSettings

    private var ordered: [VehiclePass] { passes.sorted { $0.date > $1.date } }
    private var closeCount: Int { passes.filter(\.isClose).count }

    var body: some View {
        List {
            if closeCount > 0 {
                Section {
                    Label("\(closeCount) close \(closeCount == 1 ? "pass" : "passes") (within 15 m)",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.threatHigh)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
            }
            Section {
                ForEach(ordered) { pass in
                    NavigationLink {
                        PassDetailView(pass: pass).environmentObject(settings)
                    } label: {
                        row(pass)
                    }
                }
            } header: {
                Text("\(passes.count) \(passes.count == 1 ? "vehicle" : "vehicles")")
            } footer: {
                Text("“Closing speed” is what the radar measured as the vehicle approached. Estimated vehicle speed adds your own speed back on, since a car overtaking from behind closes at its speed minus yours.")
            }
        }
        .navigationTitle("Vehicle passes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ pass: VehiclePass) -> some View {
        HStack(spacing: 12) {
            Image(systemName: pass.isClose ? "car.fill" : "car")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(pass.isClose ? Theme.threatHigh : Theme.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(closest(pass)).fontWeight(.bold)
                        .foregroundStyle(pass.isClose ? Theme.threatHigh : Theme.textPrimary)
                    Text("· \(estSpeed(pass))")
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(subtitle(pass))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(pass.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ pass: VehiclePass) -> String {
        var parts = ["you \(speedString(pass.riderKmhAtClosest))"]
        if pass.riderSlowedKmh >= 3 {
            parts.append("slowed \(Int(slowedDisplay(pass).rounded())) \(settings.speedUnit.label)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Formatting (model stores metres + km/h; convert to the user's units)

    private func closest(_ p: VehiclePass) -> String {
        "\(Int(settings.distanceUnit.shortValue(fromMeters: p.minDistance).rounded())) \(settings.distanceUnit.shortLabel)"
    }
    private func estSpeed(_ p: VehiclePass) -> String { speedString(p.estVehicleKmh) }
    private func speedString(_ kmh: Double) -> String {
        "\(Int(settings.speedUnit.value(fromMps: kmh / 3.6).rounded())) \(settings.speedUnit.label)"
    }
    private func slowedDisplay(_ p: VehiclePass) -> Double {
        settings.speedUnit.value(fromMps: p.riderSlowedKmh / 3.6)
    }
}

/// The full trace of one approach: headline stats plus distance- and speed-over-
/// time charts from first detection to passing.
struct PassDetailView: View {
    let pass: VehiclePass
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statGrid
                chartCard(title: "Distance", unit: settings.distanceUnit.shortLabel) {
                    distanceChart
                }
                chartCard(title: "Speed", unit: settings.speedUnit.label) {
                    speedChart
                }
                Text("Distance and closing speed are measured by the radar (~2 readings/second). Estimated vehicle speed adds your own speed onto the closing speed and is an approximation.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(pass.date.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Stats

    private var statGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            stat("Closest", distanceStr(pass.minDistance), pass.isClose ? Theme.threatHigh : Theme.textPrimary)
            stat("Vehicle (est.)", speedStr(pass.estVehicleKmh), Theme.textPrimary)
            stat("Your speed", speedStr(pass.riderKmhAtClosest), Theme.textPrimary)
            stat("Closing", speedStr(pass.maxClosingKmh), Theme.textPrimary)
            stat("Slowed by", speedStr(pass.riderSlowedKmh), pass.riderSlowedKmh >= 3 ? Theme.good : Theme.textPrimary)
            stat("Duration", String(format: "%.0f s", pass.duration), Theme.textPrimary)
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Theme.labelFont)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Theme.valueFont(24))
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
    }

    // MARK: - Charts

    private func chartCard<Content: View>(title: String, unit: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(unit).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            content()
                .frame(height: 180)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
    }

    private var distanceChart: some View {
        Chart(pass.samples, id: \.t) { s in
            LineMark(x: .value("Seconds", s.t),
                     y: .value("Distance", distanceVal(s.distance)))
                .foregroundStyle(Theme.accent)
                .interpolationMethod(.monotone)
        }
        .chartXAxisLabel("seconds")
    }

    private var speedChart: some View {
        Chart {
            ForEach(pass.samples, id: \.t) { s in
                LineMark(x: .value("Seconds", s.t),
                         y: .value("Speed", speedVal(s.riderKmh)),
                         series: .value("Series", "You"))
                    .foregroundStyle(by: .value("Series", "You"))
                    .interpolationMethod(.monotone)
            }
            ForEach(pass.samples, id: \.t) { s in
                LineMark(x: .value("Seconds", s.t),
                         y: .value("Speed", speedVal(s.riderKmh + s.closingKmh)),
                         series: .value("Series", "Vehicle (est.)"))
                    .foregroundStyle(by: .value("Series", "Vehicle (est.)"))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(["You": Theme.good, "Vehicle (est.)": Theme.threatHigh])
        .chartXAxisLabel("seconds")
    }

    // MARK: - Formatting

    private func distanceVal(_ m: Double) -> Double { settings.distanceUnit.shortValue(fromMeters: m) }
    private func speedVal(_ kmh: Double) -> Double { settings.speedUnit.value(fromMps: kmh / 3.6) }
    private func distanceStr(_ m: Double) -> String {
        "\(Int(distanceVal(m).rounded())) \(settings.distanceUnit.shortLabel)"
    }
    private func speedStr(_ kmh: Double) -> String {
        "\(Int(speedVal(kmh).rounded())) \(settings.speedUnit.label)"
    }
}

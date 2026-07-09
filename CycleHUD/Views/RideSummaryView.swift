import SwiftUI
import MapKit
import Charts

/// A ride's stats, shown as a sheet both at the end of a ride and when tapping a
/// ride in the history list. Self-contained with its own close button.
struct RideSummaryView: View {
    let summary: RideSummary
    /// Present only on the end-of-ride sheet (nil from history): receives the
    /// rider's 1–10 perceived effort, written to the just-saved Health workout.
    var effort: ((Int) -> Void)? = nil
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var history: RideHistory
    @Environment(\.dismiss) private var dismiss
    @State private var effortScore: Int?
    /// Stretches of this ride ridden before, compared against the previous best.
    @State private var comparisons: [SegmentComparison] = []
    @State private var showRouteMap = false
    @State private var exportFile: ExportFile?
    @State private var showExportError = false
    /// Scrub position (seconds into the ride): tap/drag any graph or the map
    /// and the same moment is highlighted on all of them — a rule line through
    /// the charts and a marker on the route.
    @State private var scrubT: Double?

    /// Identifiable wrapper so an exported file URL can drive a `.sheet(item:)`.
    private struct ExportFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    effortCard
                    statGrid
                    routeMap
                    graphs
                    lapsSection
                    passesLink
                    comparisonsSection
                }
                .padding()
            }
            .background(ThemeBackground().ignoresSafeArea())
            .navigationTitle("Ride Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if RideExporter.canExport(summary) {
                    ToolbarItem(placement: .topBarLeading) { exportMenu }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(items: [file.url])
            }
            .task(id: summary.id) {
                // Match this ride's route against previous rides off the main
                // thread; the card only appears when something matched.
                let current = summary
                let rides = history.rides
                comparisons = await Task.detached(priority: .utility) {
                    SegmentComparer.compare(current, against: rides)
                }.value
            }
            .alert("Couldn’t export this ride", isPresented: $showExportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This ride doesn’t have enough GPS track to export.")
            }
        }
    }

    /// Export the ride as a GPX or TCX file and hand it to the system share sheet,
    /// so it can be sent to Strava, Komoot, Ride with GPS, Files, etc.
    private var exportMenu: some View {
        Menu {
            Button { export(.gpx) } label: { Label("Export GPX", systemImage: "doc.text") }
            Button { export(.tcx) } label: { Label("Export TCX", systemImage: "doc.text") }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityLabel("Export or share this ride")
    }

    private func export(_ format: RideExporter.Format) {
        if let url = RideExporter.writeTemporaryFile(for: summary, format: format) {
            exportFile = ExportFile(url: url)
        } else {
            showExportError = true
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(distanceValue)
                .font(Theme.valueFont(56))
                .foregroundStyle(Theme.textPrimary)
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

    /// The route mini-map. Tap or drag along the route to scrub (the marker and
    /// the graphs' rule line follow); the corner button opens the full map.
    @ViewBuilder private var routeMap: some View {
        let coords = summary.coordinates
        if coords.count >= 2 {
            MapReader { proxy in
                Map(initialPosition: .region(Self.region(for: coords))) {
                    if let speeds = summary.routeSpeeds, speeds.count == coords.count {
                        Self.speedColoredRoute(coords, speeds: speeds, lineWidth: 4)
                    } else {
                        MapPolyline(coordinates: coords).stroke(Theme.accent, lineWidth: 4)
                    }
                    ForEach(Array(summary.radarCoordinates.enumerated()), id: \.offset) { _, c in
                        Annotation("", coordinate: c) { Self.radarDot }
                    }
                    if let c = scrubCoordinate {
                        Annotation("", coordinate: c) { scrubMarker }
                    }
                }
                .allowsHitTesting(false)   // fixed camera; touches go to the overlay
                .frame(height: 180)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            scrub(toMapPoint: drag.location, proxy: proxy, coords: coords)
                        })
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    Button { showRouteMap = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(10)
                }
            }
            .fullScreenCover(isPresented: $showRouteMap) {
                RouteMapView(coordinates: coords,
                             routeSpeeds: summary.routeSpeeds ?? [],
                             radarCoordinates: summary.radarCoordinates,
                             passes: summary.passes ?? [])
                    .environmentObject(settings)
            }
        }
    }

    // MARK: - Scrubbing (graphs ⇄ map)
    //
    // The stored route has no per-point timestamps, but GPS fixes arrive at a
    // steady rate and both the route and the metrics track were downsampled
    // uniformly — so a moment t maps to the route by simple time fraction.

    /// The ride's time span (the metrics track's last sample, or moving time).
    private var trackDuration: Double {
        max(1, summary.track?.last?.t ?? summary.movingTimeSeconds)
    }

    /// Route position for the current scrub time.
    private var scrubCoordinate: CLLocationCoordinate2D? {
        guard let t = scrubT else { return nil }
        let coords = summary.coordinates
        guard coords.count >= 2 else { return nil }
        let frac = min(max(t / trackDuration, 0), 1)
        return coords[Int((frac * Double(coords.count - 1)).rounded())]
    }

    /// The track sample nearest the scrub time, for the readout row.
    private var scrubSample: TrackSample? {
        guard let t = scrubT, let track = summary.track, !track.isEmpty else { return nil }
        return track.min(by: { abs($0.t - t) < abs($1.t - t) })
    }

    /// Map a touch on the mini-map to the nearest route point, then to time.
    private func scrub(toMapPoint point: CGPoint, proxy: MapProxy,
                       coords: [CLLocationCoordinate2D]) {
        guard let tap = proxy.convert(point, from: .local) else { return }
        let cosLat = cos(tap.latitude * .pi / 180)
        var best = 0
        var bestD = Double.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let dLat = c.latitude - tap.latitude
            let dLon = (c.longitude - tap.longitude) * cosLat
            let d = dLat * dLat + dLon * dLon
            if d < bestD { bestD = d; best = i }
        }
        scrubT = Double(best) / Double(max(1, coords.count - 1)) * trackDuration
    }

    private var scrubMarker: some View {
        ZStack {
            Circle().fill(Theme.accent)
            Circle().stroke(.white, lineWidth: 2.5)
        }
        .frame(width: 16, height: 16)
        .shadow(color: .black.opacity(0.4), radius: 2)
    }

    /// A small dot marking where a vehicle was detected behind the rider.
    static var radarDot: some View {
        Circle()
            .fill(Theme.threatHigh)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }

    /// Post-ride effort prompt (end-of-ride only): Apple's 1–10 workout effort
    /// scale, related to the workout just saved to Health. Tap again to revise;
    /// ignoring it simply leaves the workout without a score.
    @ViewBuilder private var effortCard: some View {
        if effort != nil {
            VStack(spacing: 10) {
                HStack {
                    Text("How hard was that ride?")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let effortScore {
                        // Strips carry no numbers (matching the Watch picker),
                        // so echo the pick here: "7 · Hard".
                        Text(verbatim: "\(effortScore) · \(effortBandName(effortScore))")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(effortColor(effortScore))
                    }
                }
                // Rising strips like the Watch workout app's effort picker:
                // 1 shortest → 10 tallest, tinted by band, with a wider gap
                // at each band boundary. Strips up to the pick fill solid.
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(1...10, id: \.self) { i in
                        Button {
                            effortScore = i
                            effort?(i)
                        } label: {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(effortColor(i)
                                            .opacity(i <= (effortScore ?? 0) ? 1 : 0.22))
                                    .frame(height: 14 + CGFloat(i - 1) * 30 / 9)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)          // full-height tap target
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, [3, 6, 8].contains(i) ? 4 : 0)
                        .accessibilityLabel(Text(verbatim: "\(i) — \(effortBandName(i))"))
                    }
                }
                // Band names centred under their strips (3/3/2/2 of the width).
                GeometryReader { geo in
                    let labels: [(String, CGFloat)] = [
                        (String(localized: "Easy", bundle: Lang.bundle), 0.15),
                        (String(localized: "Moderate", bundle: Lang.bundle), 0.45),
                        (String(localized: "Hard", bundle: Lang.bundle), 0.70),
                        (String(localized: "All out", bundle: Lang.bundle), 0.90)
                    ]
                    ForEach(labels, id: \.1) { label in
                        Text(verbatim: label.0)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                            .position(x: geo.size.width * label.1, y: 6)
                    }
                }
                .frame(height: 12)
                if effortScore != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                        Text("Saved to Apple Health")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        Spacer()
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        }
    }

    /// Apple's effort bands: 1–3 easy, 4–6 moderate, 7–8 hard, 9–10 all out.
    private func effortBandName(_ score: Int) -> String {
        switch score {
        case ...3: return String(localized: "Easy", bundle: Lang.bundle)
        case ...6: return String(localized: "Moderate", bundle: Lang.bundle)
        case ...8: return String(localized: "Hard", bundle: Lang.bundle)
        default:   return String(localized: "All out", bundle: Lang.bundle)
        }
    }

    private func effortColor(_ score: Int) -> Color {
        switch score {
        case ...3: return Theme.good
        case ...6: return .yellow
        case ...8: return .orange
        default:   return Theme.threatHigh
        }
    }

    private var statGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(stats, id: \.0) { stat($0.0, $0.1, $0.2) }
        }
    }

    /// Stretches ridden before, split where past rides joined or left this
    /// route, each against the fastest previous time over the same stretch.
    @ViewBuilder private var comparisonsSection: some View {
        if !comparisons.isEmpty {
            let comparedMeters = comparisons.reduce(0) { $0 + $1.lengthMeters }
            let totalDelta = comparisons.reduce(0) { $0 + $1.deltaSeconds }
            VStack(spacing: 0) {
                HStack {
                    Text("Previous bests")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.bottom, 4)
                HStack {
                    Text(String(localized: "\(distText(comparedMeters)) of \(distText(summary.distanceMeters)) \(settings.distanceUnit.label) compared",
                                bundle: Lang.bundle))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(totalDelta <= 0
                            ? String(localized: "\(lapTimeString(abs(totalDelta))) faster", bundle: Lang.bundle)
                            : String(localized: "\(lapTimeString(totalDelta)) slower", bundle: Lang.bundle))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(totalDelta <= 0 ? Theme.good : Theme.threatHigh)
                }
                .padding(.bottom, 8)
                ForEach(comparisons) { c in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: rangeText(c))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Text(String(localized: "Best: \(bestText(c))", bundle: Lang.bundle))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(verbatim: lapTimeString(c.currentSeconds))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                        Text(verbatim: deltaText(c))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(c.isFastest ? Theme.good : Theme.threatHigh))
                    }
                    .padding(.vertical, 7)
                    if c.id != comparisons.last?.id { Divider() }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        }
    }

    private func distText(_ meters: Double) -> String {
        Fmt.decimal(settings.distanceUnit.value(fromMeters: meters), 1)
    }

    /// "2.1–8.3 km" along this ride, in the rider's units.
    private func rangeText(_ c: SegmentComparison) -> String {
        let a = Fmt.decimal(settings.distanceUnit.value(fromMeters: c.startMeters), 1)
        let b = Fmt.decimal(settings.distanceUnit.value(fromMeters: c.endMeters), 1)
        return "\(a)–\(b) \(settings.distanceUnit.label)"
    }

    private func bestText(_ c: SegmentComparison) -> String {
        "\(lapTimeString(c.bestSeconds)) · \(c.bestDate.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Signed difference to the previous best, e.g. "−0:24" (faster, green).
    private func deltaText(_ c: SegmentComparison) -> String {
        let sign = c.isFastest ? "−" : "+"
        return sign + lapTimeString(abs(c.deltaSeconds))
    }

    /// Manually-marked lap splits, shown only when the rider logged any.
    @ViewBuilder private var lapsSection: some View {
        if let laps = summary.laps, !laps.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Text("Laps").font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.bottom, 8)
                ForEach(laps) { lap in
                    HStack {
                        Text("\(Fmt.int(lap.number))")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, alignment: .leading)
                        Text(lapTimeString(lap.durationSeconds))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(Fmt.decimal(settings.distanceUnit.value(fromMeters: lap.distanceMeters), 2)) \(settings.distanceUnit.label)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(Fmt.decimal(settings.speedUnit.value(fromMps: lap.averageSpeedMps), 1)) \(settings.speedUnit.label)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                    if lap.id != laps.last?.id { Divider() }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        }
    }

    private func lapTimeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
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
                        Text(fast > 0 ? String(localized: "\(passes.count) logged · \(fast) fast")
                                       : String(localized: "\(passes.count) logged"))
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
    /// Tap or drag across any chart to scrub — the moment is marked on all the
    /// charts and on the route map, with a readout of the values at that point.
    @ViewBuilder private var graphs: some View {
        if let track = summary.track, track.count >= 2 {
            VStack(spacing: 16) {
                scrubReadout
                metricChart(title: String(localized: "Speed"), unit: settings.speedUnit.label,
                            color: Theme.accent,
                            points: track.map { ($0.t, settings.speedUnit.value(fromMps: $0.speedMps)) })
                if track.contains(where: { ($0.hr ?? 0) > 0 }) {
                    metricChart(title: String(localized: "Heart rate"), unit: "bpm", color: Theme.threatHigh,
                                points: track.compactMap { s in s.hr.map { (s.t, Double($0)) } })
                }
                metricChart(title: String(localized: "Elevation"), unit: settings.distanceUnit.shortLabel,
                            color: Theme.good, filled: true,
                            points: track.map { ($0.t, settings.distanceUnit.shortValue(fromMeters: $0.altitude)) })
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        }
    }

    /// The values at the scrub point (time · speed · HR · elevation) + clear.
    @ViewBuilder private var scrubReadout: some View {
        if let t = scrubT, let s = scrubSample {
            HStack(spacing: 12) {
                Text(verbatim: lapTimeString(t))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: "\(Fmt.decimal(settings.speedUnit.value(fromMps: s.speedMps), 1)) \(settings.speedUnit.label)")
                    .foregroundStyle(Theme.accent)
                if let hr = s.hr, hr > 0 {
                    Text(verbatim: "♥ \(Fmt.int(hr))")
                        .foregroundStyle(Theme.threatHigh)
                }
                Text(verbatim: "\(Fmt.int(settings.distanceUnit.shortValue(fromMeters: s.altitude))) \(settings.distanceUnit.shortLabel)")
                    .foregroundStyle(Theme.good)
                Spacer()
                Button { scrubT = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel(Text(verbatim: "Clear"))
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
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
                if let t = scrubT {
                    RuleMark(x: .value("min", t / 60.0))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    if let y = Self.interpolate(points, atSeconds: t) {
                        PointMark(x: .value("min", t / 60.0), y: .value(title, y))
                            .foregroundStyle(color)
                            .symbolSize(70)
                    }
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
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            guard let pf = proxy.plotFrame else { return }
                            let x = drag.location.x - geo[pf].origin.x
                            if let m: Double = proxy.value(atX: x) {
                                scrubT = min(max(0, m * 60), trackDuration)
                            }
                        })
                }
            }
            .frame(height: 96)
        }
    }

    /// Linear interpolation of a chart series at `t` seconds into the ride.
    private static func interpolate(_ points: [(Double, Double)], atSeconds t: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 1..<points.count where points[i].0 >= t {
            let (t0, v0) = points[i - 1]
            let (t1, v1) = points[i]
            let span = t1 - t0
            let w = span > 0 ? (t - t0) / span : 0
            return v0 + (v1 - v0) * w
        }
        return last.1
    }

    /// Stat cells, including heart rate only when the ride captured it.
    private var stats: [(String, String, String)] {
        var s: [(String, String, String)] = [
            (String(localized: "Time"), timeValue, ""),
            (String(localized: "Avg Speed"), avgSpeedValue, settings.speedUnit.label),
        ]
        if let avg = summary.averageHeartRate {
            s.append((String(localized: "Avg HR"), Fmt.int(avg), "bpm"))
            s.append((String(localized: "Max HR"), summary.maxHeartRate.map { Fmt.int($0) } ?? "—", "bpm"))
        }
        if let watts = summary.averagePower {
            s.append((String(localized: "Avg Power"), Fmt.int(watts), "W"))
        }
        s.append((String(localized: "Ascent"), ascentValue, settings.distanceUnit.shortLabel))
        s.append((String(localized: "Calories"), caloriesValue, "kcal"))
        if let radar = summary.radarPoints, !radar.isEmpty {
            s.append((String(localized: "Vehicles"), Fmt.int(radar.count), ""))
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

    // MARK: - Speed-coloured route

    /// Draw the route as per-segment polylines coloured by speed (blue = slow →
    /// red = fast), normalised to the ride. Falls back handled by the caller when
    /// no speed data is present.
    @MapContentBuilder
    static func speedColoredRoute(_ coords: [CLLocationCoordinate2D], speeds: [Double],
                                  lineWidth: CGFloat) -> some MapContent {
        let bounds = speedBounds(speeds)
        ForEach(Array(coords.indices.dropLast()), id: \.self) { i in
            let a = speeds[min(i, speeds.count - 1)]
            let b = speeds[min(i + 1, speeds.count - 1)]
            MapPolyline(coordinates: [coords[i], coords[i + 1]])
                .stroke(speedColor((a + b) / 2, lo: bounds.0, hi: bounds.1), lineWidth: lineWidth)
        }
    }

    /// Colour on a blue(slow)→red(fast) ramp for a speed within the ride's range.
    static func speedColor(_ speed: Double, lo: Double, hi: Double) -> Color {
        let t = hi > lo ? min(1, max(0, (speed - lo) / (hi - lo))) : 0.5
        return Color(hue: 0.6 * (1 - t), saturation: 0.85, brightness: 0.95)
    }

    /// Robust slow/fast bounds (10th–90th percentile) so a GPS spike doesn't
    /// flatten the whole colour range.
    static func speedBounds(_ speeds: [Double]) -> (Double, Double) {
        let s = speeds.filter { $0 > 0 }.sorted()
        guard s.count >= 2 else { return (0, 1) }
        let lo = s[Int(Double(s.count) * 0.1)]
        let hi = s[Int(Double(s.count) * 0.9)]
        return lo < hi ? (lo, hi) : (s.first!, max(s.first! + 0.1, s.last!))
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
        Fmt.decimal(settings.distanceUnit.value(fromMeters: summary.distanceMeters), 2)
    }
    private var avgSpeedValue: String {
        Fmt.decimal(settings.speedUnit.value(fromMps: summary.averageSpeedMps), 1)
    }
    private var ascentValue: String {
        Fmt.int(settings.distanceUnit.shortValue(fromMeters: summary.elevationGainMeters))
    }
    private var caloriesValue: String {
        summary.caloriesKcal >= 1 ? Fmt.int(summary.caloriesKcal) : "—"
    }
    private var timeValue: String {
        let s = Int(summary.movingTimeSeconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

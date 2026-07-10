import SwiftUI
import MapKit

/// Plan a route on the map: tap to set the start, keep tapping to add
/// waypoints, and the path between them snaps to quiet roads and cycle paths
/// (BRouter's trekking profile over OpenStreetMap data). Routes loop back to
/// the start unless "Loop back to start" is turned off, in which case the
/// last marker is the finish.
struct RouteEditorView: View {
    @EnvironmentObject var routes: RouteStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var weather: WeatherManager
    @Environment(\.dismiss) private var dismiss

    /// Present with a route to edit it in place; nil creates a new one.
    /// Changing the points (or the loop setting) clears the route's ghost —
    /// its best time raced the old roads — while a rename keeps it.
    private let editing: PlannedRoute?

    @State private var waypoints: [PlannedRoute.Point]
    @State private var loop: Bool
    @State private var name: String
    @State private var path: [PlannedRoute.Point]
    @State private var distanceMeters: Double
    @State private var elevations: [Double]?
    @State private var planning = false
    @State private var planError: String?
    @State private var planTask: Task<Void, Never>?
    @State private var camera: MapCameraPosition

    init(editing: PlannedRoute? = nil) {
        self.editing = editing
        _waypoints = State(initialValue: editing?.waypoints ?? [])
        _loop = State(initialValue: editing?.loop ?? true)
        _name = State(initialValue: editing?.name ?? "")
        _path = State(initialValue: editing?.path ?? [])
        _distanceMeters = State(initialValue: editing?.distanceMeters ?? 0)
        _elevations = State(initialValue: editing?.elevations)
        if let path = editing?.path, path.count > 1 {
            let lats = path.map(\.lat), lons = path.map(\.lon)
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                               longitude: (lons.min()! + lons.max()!) / 2),
                span: MKCoordinateSpan(latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 1.4),
                                       longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.4)))
            _camera = State(initialValue: .region(region))
        } else {
            _camera = State(initialValue: .userLocation(
                fallback: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 52.44, longitude: -0.83),
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                controls
            }
            .background(ThemeBackground().ignoresSafeArea())
            .navigationTitle(editing == nil ? Text("New route") : Text("Edit route"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.bold)
                        .disabled(path.count < 2 || planning
                                    || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                UserAnnotation()
                // The routed path, coloured by today's wind: amber where you'd
                // fight a headwind, green where it pushes you — so "which way
                // round do I ride this loop?" answers itself at a glance.
                ForEach(Array(windRuns.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: run.coords)
                        .stroke(windColor(run.exposure),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(waypoints.enumerated()), id: \.offset) { i, wp in
                    Annotation(markerLabel(i), coordinate: wp.coordinate) {
                        marker(index: i)
                    }
                }
            }
            .mapControls { MapUserLocationButton() }
            .onTapGesture { screenPoint in
                guard let coord = proxy.convert(screenPoint, from: .local) else { return }
                waypoints.append(PlannedRoute.Point(coord))
                replan()
            }
        }
    }

    /// The path split into wind-exposure runs (shared helper): amber =
    /// headwind, green = tailwind, accent = cross/calm or no weather data.
    private var windRuns: [PlannedRoute.WindRun] {
        guard path.count >= 2 else { return [] }
        guard settings.weatherEnabled, let conditions = weather.conditions else {
            return [PlannedRoute.WindRun(coords: path.map(\.coordinate), exposure: 0)]
        }
        return PlannedRoute.windRuns(path: path, conditions: conditions)
    }

    private func windColor(_ exposure: Int) -> Color {
        exposure > 0 ? Theme.threatMedium : (exposure < 0 ? Theme.good : Theme.accent)
    }

    /// Legend for the wind colouring, shown while there's a routed path and
    /// live wind to colour it with.
    @ViewBuilder private var windLegend: some View {
        if path.count >= 2, settings.weatherEnabled, let c = weather.conditions {
            HStack(spacing: 10) {
                Image(systemName: "wind")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: "\(Fmt.int(settings.speedUnit.value(fromMps: c.windSpeedMps))) \(settings.speedUnit.label)")
                    .font(Theme.font(size: 12, weight: .semibold))
                legendKey(Theme.threatMedium, "Headwind")
                legendKey(Theme.good, "Tailwind")
                Spacer()
            }
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private func legendKey(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(label)
                .font(Theme.font(size: 12, weight: .medium))
        }
    }

    private func markerLabel(_ i: Int) -> String {
        if i == 0 { return String(localized: "Start point", bundle: Lang.bundle) }
        if !loop, i == waypoints.count - 1, waypoints.count >= 2 {
            return String(localized: "Finish", bundle: Lang.bundle)
        }
        return ""
    }

    private func marker(index i: Int) -> some View {
        let isStart = i == 0
        let isFinish = !loop && i == waypoints.count - 1 && waypoints.count >= 2
        return Circle()
            .fill(isStart ? Theme.good : (isFinish ? Theme.threatHigh : Theme.accent))
            .frame(width: isStart || isFinish ? 18 : 12,
                   height: isStart || isFinish ? 18 : 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                if planning {
                    ProgressView().controlSize(.small)
                    Text("Finding quiet roads…")
                        .font(Theme.font(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                } else if let planError {
                    Text(verbatim: planError)
                        .font(Theme.font(size: 13, weight: .medium))
                        .foregroundStyle(Theme.threatHigh)
                        .lineLimit(2)
                } else if path.count >= 2 {
                    Text(verbatim: "\(Fmt.decimal(settings.distanceUnit.value(fromMeters: distanceMeters), 1)) \(settings.distanceUnit.label)")
                        .font(Theme.font(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text("Tap the map to set the start, then keep tapping to add waypoints.")
                        .font(Theme.font(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    _ = waypoints.popLast()
                    replan()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(waypoints.isEmpty)
                .accessibilityLabel("Undo last point")
                Button {
                    waypoints = []
                    replan()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(waypoints.isEmpty)
                .accessibilityLabel("Clear all points")
            }
            windLegend
            Toggle("Loop back to start", isOn: $loop)
                .font(Theme.font(size: 15, weight: .medium))
                .onChange(of: loop) { _, _ in replan() }
            TextField("Route name", text: $name)
                .textFieldStyle(.roundedBorder)
            if pointsChanged, editing?.bestTimes != nil {
                Text("Changing the points clears this route’s best time — the ghost raced the old roads. Renaming keeps it.")
                    .font(Theme.font(size: 12, weight: .medium))
                    .foregroundStyle(Theme.threatMedium)
            }
        }
        .padding(14)
    }

    /// Whether the ridden geometry differs from the route being edited.
    private var pointsChanged: Bool {
        guard let editing else { return false }
        return waypoints != editing.waypoints || loop != editing.loop
    }

    /// Re-route after every marker change, debounced so quick tapping doesn't
    /// spam the routing service.
    private func replan() {
        planTask?.cancel()
        path = []
        distanceMeters = 0
        planError = nil
        guard waypoints.count >= 2 else {      // loop or A→B, either needs two markers
            planning = false
            return
        }
        planning = true
        let wps = waypoints
        let isLoop = loop
        planTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await RoutePlanner.plan(through: wps, loop: isLoop)
                guard !Task.isCancelled else { return }
                path = result.path
                distanceMeters = result.distanceMeters
                elevations = result.elevations
                planning = false
            } catch {
                guard !Task.isCancelled else { return }
                planError = error.localizedDescription
                planning = false
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let editing {
            var updated = editing
            updated.name = trimmed
            updated.waypoints = waypoints
            updated.loop = loop
            updated.path = path
            updated.distanceMeters = distanceMeters
            updated.elevations = elevations
            if pointsChanged {
                // The best time raced different roads — it can't be compared.
                updated.bestTimes = nil
                updated.bestDate = nil
            }
            routes.update(updated)
        } else {
            let route = PlannedRoute(name: trimmed,
                                     waypoints: waypoints, loop: loop,
                                     path: path, distanceMeters: distanceMeters,
                                     elevations: elevations)
            routes.add(route)
            routes.activeRouteID = route.id
        }
        dismiss()
    }
}

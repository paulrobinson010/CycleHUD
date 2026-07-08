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
    @Environment(\.dismiss) private var dismiss

    @State private var waypoints: [PlannedRoute.Point] = []
    @State private var loop = true
    @State private var name = ""
    @State private var path: [PlannedRoute.Point] = []
    @State private var distanceMeters: Double = 0
    @State private var elevations: [Double]?
    @State private var planning = false
    @State private var planError: String?
    @State private var planTask: Task<Void, Never>?
    @State private var camera: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 52.44, longitude: -0.83),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))))

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                controls
            }
            .background(ThemeBackground().ignoresSafeArea())
            .navigationTitle("New route")
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
                if path.count >= 2 {
                    MapPolyline(coordinates: path.map(\.coordinate))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4,
                                                                 lineCap: .round, lineJoin: .round))
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
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                } else if let planError {
                    Text(verbatim: planError)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.threatHigh)
                        .lineLimit(2)
                } else if path.count >= 2 {
                    Text(verbatim: "\(Fmt.decimal(settings.distanceUnit.value(fromMeters: distanceMeters), 1)) \(settings.distanceUnit.label)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text("Tap the map to set the start, then keep tapping to add waypoints.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
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
            Toggle("Loop back to start", isOn: $loop)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .onChange(of: loop) { _, _ in replan() }
            TextField("Route name", text: $name)
                .textFieldStyle(.roundedBorder)
        }
        .padding(14)
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
        let route = PlannedRoute(name: name.trimmingCharacters(in: .whitespaces),
                                 waypoints: waypoints, loop: loop,
                                 path: path, distanceMeters: distanceMeters,
                                 elevations: elevations)
        routes.add(route)
        routes.activeRouteID = route.id
        dismiss()
    }
}

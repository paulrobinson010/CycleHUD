import SwiftUI
import MapKit

/// Full-screen, interactive view of a ride's route. Shown when the summary's map
/// thumbnail is tapped. Includes an "Open in Maps" hand-off (Apple Maps can't
/// render the recorded line, so that just centres Maps on the ride).
struct RouteMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    var radarCoordinates: [CLLocationCoordinate2D] = []
    var passes: [VehiclePass] = []
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPass: VehiclePass?

    /// Logged passes that have a location, shown as tappable pins.
    private var mappablePasses: [VehiclePass] { passes.filter { $0.coordinate != nil } }

    var body: some View {
        NavigationStack {
            Map(initialPosition: .region(RideSummaryView.region(for: coordinates))) {
                MapPolyline(coordinates: coordinates)
                    .stroke(Theme.accent, lineWidth: 5)
                if mappablePasses.isEmpty {
                    // No reviewable passes — just mark where vehicles were seen.
                    ForEach(Array(radarCoordinates.enumerated()), id: \.offset) { _, c in
                        Annotation("Vehicle", coordinate: c) { vehiclePin(color: Theme.threatHigh) }
                    }
                } else {
                    // Tappable pins, coloured by closing speed; tap opens the pass.
                    ForEach(mappablePasses) { pass in
                        Annotation("Vehicle", coordinate: pass.coordinate!) {
                            Button { selectedPass = pass } label: { vehiclePin(color: pass.level.color) }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let start = coordinates.first {
                    Marker("Start", systemImage: "flag.fill", coordinate: start)
                        .tint(Theme.good)
                }
                if let end = coordinates.last {
                    Marker("Finish", systemImage: "flag.checkered", coordinate: end)
                        .tint(Theme.threatHigh)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedPass) { pass in
                NavigationStack {
                    PassDetailView(pass: pass)
                        .environmentObject(settings)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { selectedPass = nil }
                            }
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openInMaps() } label: {
                        Label("Open in Maps", systemImage: "map")
                    }
                }
            }
        }
    }

    private func vehiclePin(color: Color) -> some View {
        Image(systemName: "car.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1))
    }

    private func openInMaps() {
        guard let start = coordinates.first else { return }
        let region = RideSummaryView.region(for: coordinates)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: start))
        item.name = "Ride"
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: region.center),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: region.span)
        ])
    }
}

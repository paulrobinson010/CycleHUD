import SwiftUI
import UniformTypeIdentifiers

/// Saved planned routes: pick one to follow on the ride screen, create a new
/// one on the map, share a route as a `.cyclehudroute` file, or import one.
struct RoutesView: View {
    @EnvironmentObject var routes: RouteStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var weather: WeatherManager
    @Environment(\.dismiss) private var dismiss

    @State private var showEditor = false
    @State private var editRoute: PlannedRoute?
    @State private var showImporter = false
    @State private var shareURL: ShareURL?
    @State private var importFailed = false

    private struct ShareURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    static let routeType = UTType(exportedAs: "uk.co.robbo-online.cyclehud.route",
                                  conformingTo: .json)

    var body: some View {
        NavigationStack {
            List {
                if routes.routes.isEmpty {
                    Section {
                        Text("No routes yet. Tap + to plan one on the map, or import a shared route file.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Section {
                        ForEach(routes.routes) { route in
                            row(route)
                        }
                        .onDelete { offsets in
                            offsets.map { routes.routes[$0] }.forEach { routes.delete($0) }
                        }
                    } footer: {
                        Text("Tap a route to follow it on the ride screen; tap again to stop following. The route replaces the radar lane until a vehicle appears.")
                    }
                }
            }
            .themedList()
            .navigationTitle("Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showImporter = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import route")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showEditor = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New route")
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel("Close")
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                RouteEditorView()
                    .environmentObject(routes)
                    .environmentObject(settings)
                    .environmentObject(weather)
            }
            .sheet(item: $editRoute) { route in
                RouteEditorView(editing: route)
                    .environmentObject(routes)
                    .environmentObject(settings)
                    .environmentObject(weather)
            }
            .sheet(item: $shareURL) { share in
                ShareSheet(items: [share.url])
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [Self.routeType, .json,
                                                UTType(filenameExtension: "gpx") ?? .xml]) { result in
                if case .success(let url) = result, routes.importRoute(from: url) != nil {
                    return
                }
                importFailed = true
            }
            .alert("Couldn’t import that file", isPresented: $importFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("It doesn’t look like a CycleHUD route or a GPX file.")
            }
        }
    }

    private func row(_ route: PlannedRoute) -> some View {
        let active = routes.activeRouteID == route.id
        return HStack(spacing: 12) {
            Image(systemName: active ? "checkmark.circle.fill" : "map")
                .font(.system(size: 20))
                .foregroundStyle(active ? Theme.good : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: route.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(verbatim: "\(distText(route.distanceMeters)) \(settings.distanceUnit.label)"
                        + (route.loop ? " ⟳" : "")
                        + (route.bestTimes?.last.map { " · 🏁 \(timeText($0))" } ?? ""))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { editRoute = route } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit route")
            Button {
                if let url = routes.exportFile(for: route) { shareURL = ShareURL(url: url) }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share route")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            routes.activeRouteID = active ? nil : route.id
        }
    }

    private func distText(_ meters: Double) -> String {
        Fmt.decimal(settings.distanceUnit.value(fromMeters: meters), 1)
    }

    /// The route's best (ghost) time, "1:02:33" or "48:12".
    private func timeText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            return "\(s / 3600):\(String(format: "%02d", (s % 3600) / 60)):\(String(format: "%02d", s % 60))"
        }
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

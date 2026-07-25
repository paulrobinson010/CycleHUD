import SwiftUI
import MapKit
import CoreLocation

/// The radar panel's clear-road filler when no route is being followed (an
/// opt-in — Settings → Map): a street map of wherever the rider is, rotated
/// so the direction of travel points up, with the rider in the lower third.
/// The radar view takes the slot back the moment a vehicle is detected, and
/// the radar's safety signals (not-connected warning, battery) survive the
/// swap exactly as they do on the route panel.
struct FreeRideMapPanel: View {
    let location: CLLocation
    let course: Double?
    let radarConnected: Bool
    var batteryPercent: Int? = nil
    /// Apple's live traffic layer (jams and closure icons painted on the map).
    var showTraffic: Bool = false

    /// Pinch-zoom altitude, preserved across camera updates.
    @State private var zoomDistance: Double = 1500

    /// The camera as owned state, moved only when the rider has meaningfully
    /// moved or turned — the same battery-saving gate as the route panel
    /// (see RoutePanel): re-issuing a camera every SwiftUI render keeps a
    /// MapKit animation running continuously.
    @State private var camera: MapCameraPosition = .automatic
    @State private var camCenter: CLLocationCoordinate2D?
    @State private var camHeading: Double = 0
    @State private var camDistance: Double = 1500
    /// Last real course, so stopping at lights doesn't snap the map north.
    @State private var heldCourse: Double = 0

    var body: some View {
        map
            .background(RoundedRectangle(cornerRadius: 24).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 24)
                .stroke(Theme.radarIdleStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(alignment: .topLeading) { header }
            .overlay(alignment: .bottom) { radarWarning }
    }

    private var heading: Double { course ?? heldCourse }

    private var map: some View {
        Map(position: $camera, interactionModes: .zoom) {
            Annotation("", coordinate: location.coordinate) {
                // Up on screen = direction of travel (the camera provides the
                // rotation), so the fixed up-arrow always points the right way.
                Image(systemName: "location.north.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll,
                            showsTraffic: showTraffic))
        // Pinch zoom is the one interaction allowed (no panning — the camera
        // follows the rider). Remember the chosen zoom so camera refreshes
        // don't undo it.
        .onMapCameraChange(frequency: .onEnd) { context in
            let d = context.camera.distance
            if abs(d - zoomDistance) > 1 { zoomDistance = min(8000, max(400, d)) }
        }
        .onAppear {
            if let course { heldCourse = course }
            updateCamera(animated: false)
        }
        .onChange(of: CameraKey(lat: location.coordinate.latitude,
                                lon: location.coordinate.longitude,
                                course: course, zoom: zoomDistance)) { _, _ in
            if let course { heldCourse = course }
            updateCamera()
        }
    }

    /// Everything the camera target depends on, as one Equatable trigger.
    private struct CameraKey: Equatable {
        let lat: Double
        let lon: Double
        let course: Double?
        let zoom: Double
    }

    /// Re-aim the camera — but only when the rider has moved ≥ 3 m, turned
    /// ≥ 2°, or the zoom changed (the RoutePanel gate).
    private func updateCamera(animated: Bool = true) {
        // Centre ahead of the rider so most of the view is road to come.
        let center = coordinate(from: location.coordinate,
                                meters: zoomDistance * 0.10, bearing: heading)
        if let last = camCenter {
            let moved = PlannedRoute.meters(last, center)
            let turned = abs(angleDelta(heading, camHeading))
            let zoomed = abs(zoomDistance - camDistance)
            guard moved >= 3 || turned >= 2 || zoomed > 1 else { return }
        }
        camCenter = center
        camHeading = heading
        camDistance = zoomDistance
        let target = MapCameraPosition.camera(
            MapCamera(centerCoordinate: center, distance: zoomDistance, heading: heading))
        if animated {
            withAnimation(.easeInOut(duration: 0.45)) { camera = target }
        } else {
            camera = target
        }
    }

    /// Signed smallest difference between two bearings, in degrees.
    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// The coordinate `meters` away from `c` along `bearing`.
    private func coordinate(from c: CLLocationCoordinate2D, meters: Double,
                            bearing: Double) -> CLLocationCoordinate2D {
        let rad = bearing * .pi / 180
        let dLat = meters * cos(rad) / 111_320
        let dLon = meters * sin(rad) / (111_320 * max(0.2, cos(c.latitude * .pi / 180)))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat,
                                      longitude: c.longitude + dLon)
    }

    /// Radar battery in the corner, same as the route panel — never out of
    /// sight while the map has the slot.
    @ViewBuilder private var header: some View {
        if radarConnected, let batteryPercent {
            HStack(spacing: 4) {
                Image(systemName: "battery.100",
                      variableValue: Double(batteryPercent) / 100.0)
                    .font(.system(size: 11, weight: .bold))
                Text(verbatim: "\(batteryPercent)%")
                    .font(Theme.font(size: 12, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(batteryColor(batteryPercent))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.panel.opacity(0.85)))
            .padding(12)
        }
    }

    private func batteryColor(_ pct: Int) -> Color {
        if pct <= 15 { return Theme.threatHigh }
        if pct <= 30 { return Theme.threatLow }
        return Theme.good
    }

    /// Radar-down warning, styled like the radar lane's own badge, so swapping
    /// the panel for the map never hides the safety state.
    @ViewBuilder private var radarWarning: some View {
        if !radarConnected {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                Text("NOT CONNECTED")
            }
            .font(Theme.font(size: 13, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.threatHigh))
            .padding(.bottom, 12)
        }
    }
}

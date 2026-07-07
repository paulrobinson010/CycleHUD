import SwiftUI
import MapKit
import CoreLocation

/// The active route shown in the radar panel's slot while the road behind is
/// clear: a real street map, rotated so the direction of travel points up,
/// with the route in blue, the lead-in leg to the start in green, waypoint
/// dots, and the rider in the lower third. The radar view takes the slot back
/// whenever a vehicle is detected.
struct RoutePanel: View {
    let route: PlannedRoute
    let location: CLLocation?
    let course: Double?
    /// Progress from RouteStore (index along path, metres off it, remaining).
    let progress: (index: Int, offMeters: Double, remainingMeters: Double)?
    /// Whether the rider has reached the route yet (RouteStore tracks this).
    /// Until then, directions target the START marker, not the nearest point.
    let joined: Bool
    /// Road leg from the rider to the start (BRouter), when one is available:
    /// drawn green, with the arrow and distance following the leg.
    let leadIn: [PlannedRoute.Point]?
    /// The radar's safety signal must survive the panel swap: when it's not
    /// connected, a warning overlays the route view.
    let radarConnected: Bool
    let distanceUnit: DistanceUnit

    /// Strayed after joining — amber "back to route" guidance.
    private var offRoute: Bool { joined && (progress?.offMeters ?? 0) > 80 }
    /// Not there yet — calm "to the start" guidance.
    private var headingToStart: Bool { !joined && (progress?.offMeters ?? 0) > 80 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let location, let progress {
                    routeMap(rider: location.coordinate, progress: progress)
                } else {
                    Text("Waiting for GPS…")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
                if offRoute || headingToStart, let location, let progress {
                    directions(w: geo.size.width, h: geo.size.height,
                               rider: location.coordinate, progress: progress)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(RoundedRectangle(cornerRadius: 24).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 24)
                .stroke(offRoute ? Theme.threatMedium : Theme.radarIdleStroke,
                        lineWidth: offRoute ? 3 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(alignment: .topLeading) { header }
            .overlay(alignment: .bottom) { radarWarning }
        }
    }

    // MARK: - The street map

    /// Camera: up = direction of travel, centred a little ahead of the rider
    /// so most of the panel shows what's coming.
    private func routeMap(rider: CLLocationCoordinate2D,
                          progress: (index: Int, offMeters: Double, remainingMeters: Double)) -> some View {
        let heading = course ?? routeHeading(progress.index)
        let center = coordinate(from: rider, meters: 170, bearing: heading)
        return Map(position: .constant(.camera(
            MapCamera(centerCoordinate: center, distance: 1500, heading: heading)))) {
            MapPolyline(coordinates: route.path.map(\.coordinate))
                .stroke(Theme.accent,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if headingToStart, let leg = leadIn, leg.count >= 2 {
                MapPolyline(coordinates: leg.map(\.coordinate))
                    .stroke(Theme.good,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(route.waypoints.enumerated()), id: \.offset) { _, wp in
                Annotation("", coordinate: wp.coordinate) {
                    Circle().fill(Theme.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
            }
            if let start = route.path.first {
                Annotation("", coordinate: start.coordinate) {
                    Circle().fill(Theme.good)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            if !route.loop, let end = route.path.last {
                Annotation("", coordinate: end.coordinate) {
                    Circle().fill(Theme.threatHigh)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            Annotation("", coordinate: rider) {
                // Up on screen = direction of travel (the camera provides the
                // rotation), so the fixed up-arrow always points the right way.
                Image(systemName: "location.north.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(offRoute ? Theme.threatMedium : Theme.accent)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .disabled(true)   // glanceable HUD, not an interactive map
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: route.name)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.4), radius: 2)
            if offRoute {
                Text("Off route")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.threatMedium))
            } else if headingToStart {
                distancePill(route.distanceMeters)
            } else if let progress {
                distancePill(progress.remainingMeters)
            }
        }
        .padding(12)
    }

    /// Distance readout that stays readable over any map imagery.
    private func distancePill(_ meters: Double) -> some View {
        Text(verbatim: "\(Fmt.decimal(distanceUnit.value(fromMeters: meters), 1)) \(distanceUnit.label)")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.panel.opacity(0.85)))
    }

    /// Radar-down warning, styled like the radar lane's own badge, so swapping
    /// the panel for the route never hides the safety state.
    @ViewBuilder private var radarWarning: some View {
        if !radarConnected {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                Text("NOT CONNECTED")
            }
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.threatHigh))
            .padding(.bottom, 12)
        }
    }

    // MARK: - Guidance overlay

    /// Directions when the rider isn't on the path: an arrow pointing at the
    /// target (in the rider's frame — the same heading the map camera uses, so
    /// arrow and map can never disagree) with the distance to cover. Before
    /// the route is joined the target follows the green lead-in leg (or the
    /// start itself); after joining it's the nearest point of the path.
    private func directions(w: CGFloat, h: CGFloat,
                            rider: CLLocationCoordinate2D,
                            progress: (index: Int, offMeters: Double, remainingMeters: Double)) -> some View {
        let leg = headingToStart ? leadInGuidance(rider: rider) : nil
        let target = leg?.target ?? directionsTarget(progress: progress)
        let toTarget = PlannedRoute.bearing(rider, target)
        let distance = leg?.remaining
            ?? (headingToStart ? PlannedRoute.meters(rider, target) : progress.offMeters)
        let heading = course ?? routeHeading(progress.index)
        let tint = headingToStart ? (leg != nil ? Theme.good : Theme.accent) : Theme.threatMedium
        return VStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(toTarget - heading))
                .shadow(color: .black.opacity(0.5), radius: 4)
                .animation(.easeInOut(duration: 0.4), value: toTarget - heading)
            Text(verbatim: offDistText(distance))
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.panel.opacity(0.85)))
            Text(headingToStart ? "To the start" : "Back to route")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.panel.opacity(0.85)))
        }
        .position(x: w / 2, y: h * 0.35)
    }

    /// Where the guidance points: the start until the route is joined, then
    /// the nearest point of the path.
    private func directionsTarget(progress: (index: Int, offMeters: Double, remainingMeters: Double))
        -> CLLocationCoordinate2D {
        if headingToStart, let start = route.path.first { return start.coordinate }
        return route.path[min(progress.index, route.path.count - 1)].coordinate
    }

    /// Follow-the-leg guidance while a lead-in exists. The rider is projected
    /// onto the leg's SEGMENTS (nodes can be 100+ m apart on straights, so a
    /// nearest-node aim can point the arrow at the wrong bend); the arrow aims
    /// ~30 m along the leg from that projection, and the distance reported is
    /// the road distance left to the start.
    private func leadInGuidance(rider: CLLocationCoordinate2D)
        -> (target: CLLocationCoordinate2D, remaining: Double)? {
        guard let leg = leadIn, leg.count >= 2 else { return nil }
        var bestSeg = 0
        var bestT = 0.0
        var bestD = Double.greatestFiniteMagnitude
        for i in 0..<(leg.count - 1) {
            let (d, t) = project(rider, onto: leg[i].coordinate, leg[i + 1].coordinate)
            if d < bestD { bestD = d; bestSeg = i; bestT = t }
        }
        let a = leg[bestSeg].coordinate
        let b = leg[bestSeg + 1].coordinate
        let segLen = PlannedRoute.meters(a, b)
        let projection = CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * bestT,
            longitude: a.longitude + (b.longitude - a.longitude) * bestT)

        // Aim ~30 m along the leg from the projection.
        var aim = projection
        var budget = 30.0
        var carry = segLen * (1 - bestT)
        var i = bestSeg
        while budget > 0, i < leg.count - 1 {
            if carry >= budget {
                let from = i == bestSeg ? projection : leg[i].coordinate
                let toward = leg[i + 1].coordinate
                let f = budget / max(1, PlannedRoute.meters(from, toward))
                aim = CLLocationCoordinate2D(
                    latitude: from.latitude + (toward.latitude - from.latitude) * min(1, f),
                    longitude: from.longitude + (toward.longitude - from.longitude) * min(1, f))
                budget = 0
            } else {
                budget -= carry
                i += 1
                aim = leg[i].coordinate
                carry = i < leg.count - 1
                    ? PlannedRoute.meters(leg[i].coordinate, leg[i + 1].coordinate) : 0
            }
        }

        var remaining = segLen * (1 - bestT)
        for j in (bestSeg + 1)..<(leg.count - 1) {
            remaining += PlannedRoute.meters(leg[j].coordinate, leg[j + 1].coordinate)
        }
        return (aim, remaining)
    }

    /// Perpendicular distance of `p` from segment a→b and the clamped
    /// projection parameter t ∈ [0, 1], in metres.
    private func project(_ p: CLLocationCoordinate2D,
                         onto a: CLLocationCoordinate2D,
                         _ b: CLLocationCoordinate2D) -> (distance: Double, t: Double) {
        let (abx, aby) = PlannedRoute.delta(a, b)
        let (apx, apy) = PlannedRoute.delta(a, p)
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return (PlannedRoute.meters(a, p), 0) }
        let t = max(0, min(1, (apx * abx + apy * aby) / len2))
        let ox = apx - abx * t
        let oy = apy - aby * t
        return ((ox * ox + oy * oy).squareRoot(), t)
    }

    /// Short distances in radar-style metres/feet; longer ones in km/mi.
    private func offDistText(_ m: Double) -> String {
        if m < 950 {
            return "\(Fmt.int(distanceUnit.shortValue(fromMeters: m))) \(distanceUnit.shortLabel)"
        }
        return "\(Fmt.decimal(distanceUnit.value(fromMeters: m), 1)) \(distanceUnit.label)"
    }

    /// Fallback orientation before GPS course exists: point the route's own
    /// local direction up.
    private func routeHeading(_ index: Int) -> Double {
        route.bearingAfter(index: index, lookahead: 30) ?? 0
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
}

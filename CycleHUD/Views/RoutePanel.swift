import SwiftUI
import CoreLocation

/// The active route drawn in the radar panel's slot while the road behind is
/// clear: the upcoming path in the rider's frame (up = direction of travel,
/// rider marker in the lower third), with the distance remaining and an
/// off-route warning. The radar view takes the slot back whenever a vehicle
/// is detected.
struct RoutePanel: View {
    let route: PlannedRoute
    let location: CLLocation?
    let course: Double?
    /// Progress from RouteStore (index along path, metres off it, remaining).
    let progress: (index: Int, offMeters: Double, remainingMeters: Double)?
    /// Whether the rider has reached the route yet (RouteStore tracks this).
    /// Until then, directions target the START marker, not the nearest point.
    let joined: Bool
    /// The radar's safety signal must survive the panel swap: when it's not
    /// connected, a warning overlays the route view.
    let radarConnected: Bool
    let distanceUnit: DistanceUnit

    /// How much route to draw ahead of the rider (metres of window height).
    private let windowAhead: Double = 500
    /// Strayed after joining — amber "back to route" guidance.
    private var offRoute: Bool { joined && (progress?.offMeters ?? 0) > 80 }
    /// Not there yet — calm "to the start" guidance.
    private var headingToStart: Bool { !joined && (progress?.offMeters ?? 0) > 80 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                if let location, let progress {
                    pathCanvas(w: w, h: h, rider: location.coordinate, progress: progress)
                } else {
                    Text("Waiting for GPS…")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
                rider(w: w, h: h)
                if offRoute || headingToStart, let location, let progress {
                    directions(w: w, h: h, rider: location.coordinate, progress: progress)
                }
            }
            .frame(width: w, height: h)
            .background(RoundedRectangle(cornerRadius: 24).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 24)
                .stroke(offRoute ? Theme.threatMedium : Theme.radarIdleStroke,
                        lineWidth: offRoute ? 3 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(alignment: .topLeading) { header }
            .overlay(alignment: .bottom) { radarWarning }
        }
    }

    /// Radar-down warning, styled like the radar lane's own badge, so swapping
    /// the panel for the route never hides the safety state. Bottom-centre:
    /// the top row belongs to the route name and the mute controls.
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: route.name)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if offRoute {
                Text("Off route")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.threatMedium)
            } else if headingToStart {
                Text(verbatim: "\(Fmt.decimal(distanceUnit.value(fromMeters: route.distanceMeters), 1)) \(distanceUnit.label)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            } else if let progress {
                Text(verbatim: "\(Fmt.decimal(distanceUnit.value(fromMeters: progress.remainingMeters), 1)) \(distanceUnit.label)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(12)
    }

    /// Directions when the rider isn't on the path: an arrow pointing at the
    /// target (in the rider's frame, so "up" = keep going, "right" = it's off
    /// to your right) with the distance to cover. Before the route has been
    /// joined the target is the START marker; after that it's the nearest
    /// point of the path. The canvas also draws a dashed link to the same spot.
    private func directions(w: CGFloat, h: CGFloat,
                            rider: CLLocationCoordinate2D,
                            progress: (index: Int, offMeters: Double, remainingMeters: Double)) -> some View {
        let target = directionsTarget(progress: progress)
        let toTarget = PlannedRoute.bearing(rider, target)
        let distance = headingToStart ? PlannedRoute.meters(rider, target) : progress.offMeters
        let heading = course ?? routeHeading(progress.index)
        let tint = headingToStart ? Theme.accent : Theme.threatMedium
        return VStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(toTarget - heading))
                .shadow(color: Theme.glow, radius: 8)
                .animation(.easeInOut(duration: 0.4), value: toTarget - heading)
            Text(verbatim: offDistText(distance))
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(headingToStart ? "To the start" : "Back to route")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .position(x: w / 2, y: h * 0.38)
    }

    /// Where the guidance points: the start until the route is joined, then
    /// the nearest point of the path.
    private func directionsTarget(progress: (index: Int, offMeters: Double, remainingMeters: Double))
        -> CLLocationCoordinate2D {
        if headingToStart, let start = route.path.first { return start.coordinate }
        return route.path[min(progress.index, route.path.count - 1)].coordinate
    }

    /// Short distances in radar-style metres/feet; longer ones in km/mi.
    private func offDistText(_ m: Double) -> String {
        if m < 950 {
            return "\(Fmt.int(distanceUnit.shortValue(fromMeters: m))) \(distanceUnit.shortLabel)"
        }
        return "\(Fmt.decimal(distanceUnit.value(fromMeters: m), 1)) \(distanceUnit.label)"
    }

    /// The rider marker: same bare arrow as the radar lane, always pointing up
    /// (the world rotates around it).
    private func rider(w: CGFloat, h: CGFloat) -> some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(offRoute ? Theme.threatMedium : Theme.accent)
            .shadow(color: Theme.glow, radius: 8)
            .position(x: w / 2, y: h * 0.72)
    }

    private func pathCanvas(w: CGFloat, h: CGFloat,
                            rider: CLLocationCoordinate2D,
                            progress: (index: Int, offMeters: Double, remainingMeters: Double)) -> some View {
        Canvas { context, size in
            // Rider-frame transform: metres → points, rotated so the travel
            // direction points up. The rider sits at (w/2, 0.72h) so most of
            // the window shows what's coming.
            let scale = (size.height * 0.72) / windowAhead
            let origin = CGPoint(x: size.width / 2, y: size.height * 0.72)
            let heading = (course ?? routeHeading(progress.index)) * .pi / 180

            func place(_ c: CLLocationCoordinate2D) -> CGPoint {
                let (dx, dy) = PlannedRoute.delta(rider, c)
                // Rotate east/north into the rider frame (heading up): a point
                // at bearing b lands at screen angle b − heading, matching the
                // guidance arrow's math.
                let rx = dx * cos(heading) - dy * sin(heading)
                let ry = dx * sin(heading) + dy * cos(heading)
                return CGPoint(x: origin.x + rx * scale, y: origin.y - ry * scale)
            }

            // Slice of the path around the rider: a little behind, plenty ahead.
            let start = max(0, progress.index - 30)
            var lastVisible = progress.index
            var travelled = 0.0
            while lastVisible < route.path.count - 1, travelled < windowAhead * 1.6 {
                travelled += PlannedRoute.meters(route.path[lastVisible].coordinate,
                                                 route.path[lastVisible + 1].coordinate)
                lastVisible += 1
            }
            guard lastVisible > start else { return }

            // Away from the path: a dashed link from the rider to the guidance
            // target — the start until joined, then the nearest point.
            if progress.offMeters > 80 {
                let target = joined
                    ? route.path[progress.index].coordinate
                    : (route.path.first?.coordinate ?? route.path[progress.index].coordinate)
                var link = Path()
                link.move(to: origin)
                link.addLine(to: place(target))
                context.stroke(link, with: .color(joined ? Theme.threatMedium : Theme.accent),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 7]))
                // Green start dot at the target when it's in the window.
                if !joined {
                    let p = place(target)
                    let dot = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                    context.fill(dot, with: .color(Theme.good))
                    context.stroke(dot, with: .color(.white), lineWidth: 2)
                }
            }

            // Ridden portion (dim) then the road ahead (bright).
            var behind = Path()
            behind.addLines((start...progress.index).map { place(route.path[$0].coordinate) })
            context.stroke(behind, with: .color(Theme.accent.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

            var ahead = Path()
            ahead.addLines((progress.index...lastVisible).map { place(route.path[$0].coordinate) })
            context.stroke(ahead, with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

            // Finish flag when it comes into the window.
            if lastVisible == route.path.count - 1, let last = route.path.last {
                let p = place(last.coordinate)
                let dot = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                context.fill(dot, with: .color(Theme.good))
                context.stroke(dot, with: .color(.white), lineWidth: 2)
            }
        }
    }

    /// Fallback orientation before GPS course exists: point the route's own
    /// local direction up.
    private func routeHeading(_ index: Int) -> Double {
        route.bearingAfter(index: index, lookahead: 30) ?? 0
    }
}

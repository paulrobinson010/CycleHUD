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
    /// Radar battery %, shown under the distance so it's never out of sight.
    var batteryPercent: Int? = nil
    /// Estimated seconds to the finish at the ride's average speed.
    var etaSeconds: Double? = nil
    /// Ghost rider: seconds vs this route's best run (− = ahead), and where
    /// the ghost is right now on the map (with its direction of travel, so
    /// the marker faces the way it's going).
    var ghostDeltaSeconds: Double? = nil
    var ghostCoordinate: CLLocationCoordinate2D? = nil
    var ghostBearing: Double? = nil
    /// False when the climb row tile is on the current page — the row carries
    /// the profile, so the map keeps its full height.
    var showClimbStrip: Bool = true
    /// The next junction, when junctions are on but the Junction tile isn't
    /// on the current page — shown as a badge on the map instead.
    var junction: JunctionInfo? = nil
    var junctionRouteBearing: Double? = nil
    /// Apple's live traffic layer (jams and closure icons painted on the map).
    var showTraffic: Bool = false
    /// Today's wind — the route underlay is tinted amber (headwind) / green
    /// (tailwind) per stretch when available.
    var windConditions: WeatherConditions? = nil
    let distanceUnit: DistanceUnit

    /// Pinch-zoom altitude, preserved across the once-a-second camera updates.
    @State private var zoomDistance: Double = 1500

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
                        .font(Theme.font(size: 14, weight: .semibold))
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
            .overlay(alignment: .topTrailing) { junctionBadge }
            .overlay(alignment: .bottom) {
                VStack(spacing: 6) {
                    if let climb = activeClimb, let progress {
                        // On (or about to start) a climb: THIS climb takes the
                        // strip's slot — and appears even when the whole-route
                        // strip is off or living in the Distance & Climb row.
                        ClimbCard(route: route, climb: climb,
                                  riddenMeters: max(0, route.remainingMeters(from: 0) - progress.remainingMeters),
                                  progressIndex: progress.index,
                                  distanceUnit: distanceUnit)
                            .frame(height: 54)
                            .padding(.horizontal, 10)
                    } else {
                        climbStrip
                    }
                    radarWarning
                }
            }
        }
    }

    /// Climbs are detected once per route and cached (main-thread only).
    private static var climbCache: [UUID: [PlannedRoute.Climb]] = [:]

    private var routeClimbs: [PlannedRoute.Climb] {
        if let cached = Self.climbCache[route.id] { return cached }
        let detected = route.climbs()
        Self.climbCache[route.id] = detected
        return detected
    }

    /// The climb the rider is on — or about to start within 200 m — while
    /// riding the route.
    private var activeClimb: PlannedRoute.Climb? {
        guard joined, let progress else { return nil }
        let ridden = max(0, route.remainingMeters(from: 0) - progress.remainingMeters)
        return routeClimbs.first {
            ridden >= $0.startMeters - 200 && ridden < $0.endMeters - 20
        }
    }

    /// The junction tile's essentials as a map badge — the arms schematic
    /// (route arm highlighted green) and the countdown — sitting below the
    /// mute controls when the tile itself isn't on the page.
    @ViewBuilder private var junctionBadge: some View {
        if let junction {
            HStack(spacing: 6) {
                JunctionGlyph(info: junction, routeBearing: junctionRouteBearing)
                    .frame(width: 30, height: 30)
                Text(verbatim: "\(Fmt.int(distanceUnit.shortValue(fromMeters: junction.distanceMeters))) \(distanceUnit.shortLabel)")
                    .font(Theme.font(size: 13, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.panel.opacity(0.85)))
            .padding(.trailing, 10)
            .padding(.top, 64)     // clear of the mute controls above
        }
    }

    /// Whether the climb strip will render (used to keep the rider marker
    /// clear of it).
    private var hasClimbStrip: Bool {
        showClimbStrip
            && (route.elevations?.count ?? -1) == route.path.count && route.path.count > 1
    }

    /// The WHOLE route in profile along the bottom of the map — visible from
    /// the moment a route is picked (before reaching the start too), with a
    /// marker walking the profile once the rider is on the route and the
    /// gradient-just-ahead label while riding it.
    @ViewBuilder private var climbStrip: some View {
        if hasClimbStrip, let elevations = route.elevations {
            // Position marker always: nearest point once riding the route,
            // pinned to the start (0) while still heading there.
            let ridden = joined
                ? progress.map { max(0, route.remainingMeters(from: 0) - $0.remainingMeters) }
                : 0
            ClimbProfileStrip(route: route, elevations: elevations,
                              progressMeters: ridden,
                              gradientFromIndex: (joined && !offRoute) ? progress?.index : nil)
                .frame(height: 44)
                .padding(.horizontal, 10)
        }
    }

    // MARK: - The street map

    /// Camera: up = direction of travel, centred a little ahead of the rider
    /// so most of the panel shows what's coming.
    private func routeMap(rider: CLLocationCoordinate2D,
                          progress: (index: Int, offMeters: Double, remainingMeters: Double)) -> some View {
        let heading = course ?? routeHeading(progress.index)
        // Centre ahead of the rider so most of the view is road to come — but
        // less so when the climb strip occupies the bottom of the panel, or
        // the rider's own arrow ends up hidden behind it (seen on device).
        let aheadFactor = hasClimbStrip ? 0.04 : 0.10
        let center = coordinate(from: rider, meters: zoomDistance * aheadFactor, bearing: heading)
        return Map(position: .constant(.camera(
            MapCamera(centerCoordinate: center, distance: zoomDistance, heading: heading))),
                   interactionModes: .zoom) {
            // Whole route as a muted underlay — tinted by today's wind when
            // known (amber = headwind stretch, green = tailwind) — with only
            // the NEXT kilometre bright. Where a loop crosses itself (or
            // shares an out-and-back road) both passes are drawn, and without
            // the bright/muted split the homebound leg reads as "the way" at
            // an outbound junction.
            ForEach(Array(underlayRuns.enumerated()), id: \.offset) { _, run in
                MapPolyline(coordinates: run.coords)
                    .stroke(underlayColor(run.exposure),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            MapPolyline(coordinates: upcomingSlice(from: joined ? progress.index : 0))
                .stroke(Theme.accent,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
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
            if let ghostCoordinate {
                Annotation("", coordinate: ghostCoordinate) {
                    // The route's best run, riding it live alongside you —
                    // facing its own direction of travel (annotations are
                    // screen-aligned, so subtract the camera's rotation).
                    // Without a bearing it's a dot, never a wrong-way arrow.
                    if let ghostBearing {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.ghost.opacity(0.85))
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .rotationEffect(.degrees(ghostBearing - heading))
                    } else {
                        Circle()
                            .fill(Theme.ghost.opacity(0.85))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.4), radius: 2)
                    }
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
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll,
                            showsTraffic: showTraffic))
        // Pinch zoom is the one interaction allowed (no panning — the camera
        // follows the rider). Remember the chosen zoom so the per-second
        // camera refresh doesn't undo it.
        .onMapCameraChange(frequency: .onEnd) { context in
            let d = context.camera.distance
            if abs(d - zoomDistance) > 1 { zoomDistance = min(8000, max(400, d)) }
        }
    }

    /// The route underlay split by wind exposure (single plain run when no
    /// wind data is available).
    private var underlayRuns: [PlannedRoute.WindRun] {
        if let windConditions {
            return PlannedRoute.windRuns(path: route.path, conditions: windConditions)
        }
        return [PlannedRoute.WindRun(coords: route.path.map(\.coordinate), exposure: 0)]
    }

    private func underlayColor(_ exposure: Int) -> Color {
        switch exposure {
        case 1: return Theme.threatMedium.opacity(0.55)
        case -1: return Theme.good.opacity(0.55)
        default: return Theme.accent.opacity(0.35)
        }
    }

    /// The next ~kilometre of route from `index` — the stretch drawn bright.
    private func upcomingSlice(from index: Int) -> [CLLocationCoordinate2D] {
        let start = min(max(0, index), route.path.count - 1)
        var end = start
        var acc = 0.0
        while end < route.path.count - 1, acc < 1000 {
            acc += PlannedRoute.meters(route.path[end].coordinate,
                                       route.path[end + 1].coordinate)
            end += 1
        }
        return route.path[start...end].map(\.coordinate)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: route.name)
                .font(Theme.font(size: 13, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.4), radius: 2)
            if offRoute {
                Text("Off route")
                    .font(Theme.font(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.threatMedium))
            } else if headingToStart {
                distancePill(route.distanceMeters)
            } else if let progress {
                distancePill(progress.remainingMeters)
            }
            if let etaSeconds, !offRoute, !headingToStart {
                bigPill(icon: "clock", text: etaText(etaSeconds),
                        tint: Theme.textPrimary)
            }
            if let ghostDeltaSeconds, !offRoute, !headingToStart {
                // The race against this route's best run: green = ahead.
                bigPill(icon: "flag.checkered",
                        text: deltaText(ghostDeltaSeconds),
                        tint: ghostDeltaSeconds <= 0 ? Theme.good : Theme.threatHigh)
            }
            if radarConnected, let batteryPercent {
                infoPill(icon: "battery.100",
                         iconVariable: Double(batteryPercent) / 100.0,
                         text: "\(batteryPercent)%",
                         tint: batteryColor(batteryPercent))
            }
        }
        .padding(12)
    }

    /// Small readout pill (ETA, radar battery) under the distance.
    private func infoPill(icon: String, iconVariable: Double = 1,
                          text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon, variableValue: iconVariable)
                .font(.system(size: 11, weight: .bold))
            Text(verbatim: text)
                .font(Theme.font(size: 12, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.panel.opacity(0.85)))
    }

    /// The numbers being ridden against — ETA and the ghost race — at twice
    /// the info-pill size, readable at a glance on the bars. (The radar
    /// battery keeps the small pill; it's a check, not a race.)
    private func bigPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
            Text(verbatim: text)
                .font(Theme.font(size: 24, weight: .heavy))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.panel.opacity(0.85)))
    }

    /// "−0:14" / "+1:02" vs the ghost.
    private func deltaText(_ seconds: Double) -> String {
        let s = Int(abs(seconds).rounded())
        return "\(seconds <= 0 ? "−" : "+")\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// "≈ 38 min" / "≈ 1 h 05" at the ride's average speed.
    private func etaText(_ seconds: Double) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        if m < 60 { return "≈ \(m) min" }
        return "≈ \(m / 60) h \(String(format: "%02d", m % 60))"
    }

    private func batteryColor(_ pct: Int) -> Color {
        if pct <= 15 { return Theme.threatHigh }
        if pct <= 30 { return Theme.threatLow }
        return Theme.good
    }

    /// Distance readout that stays readable over any map imagery.
    private func distancePill(_ meters: Double) -> some View {
        Text(verbatim: "\(Fmt.decimal(distanceUnit.value(fromMeters: meters), 1)) \(distanceUnit.label)")
            .font(Theme.font(size: 15, weight: .heavy))
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
            .font(Theme.font(size: 13, weight: .heavy))
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
                .font(Theme.font(size: 17, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.panel.opacity(0.85)))
            Text(headingToStart ? "To the start" : "Back to route")
                .font(Theme.font(size: 12, weight: .semibold))
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

/// The climb underway: how much further to the top, the ascent left, the
/// grade of what remains, and the climb's own profile filling in as the
/// rider gains it. Takes the elevation strip's slot while a climb is live.
struct ClimbCard: View {
    let route: PlannedRoute
    let climb: PlannedRoute.Climb
    let riddenMeters: Double
    let progressIndex: Int
    let distanceUnit: DistanceUnit

    private var toTopMeters: Double { max(0, climb.endMeters - riddenMeters) }
    private var ascentLeft: Double {
        guard let elevations = route.elevations else { return 0 }
        let at = min(max(progressIndex, climb.startIndex), climb.endIndex)
        return max(0, elevations[climb.endIndex] - elevations[at])
    }
    private var gradeLeft: Double {
        toTopMeters > 20 ? ascentLeft / toTopMeters * 100 : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            profile
                .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: toTopText)
                    .font(Theme.font(size: 17, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(verbatim: "↗ \(Fmt.int(ascentLeft)) m · \(String(format: "%.1f", gradeLeft))%")
                    .font(Theme.font(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(gradeLeft > 6 ? Theme.threatMedium : Theme.textSecondary)
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel.opacity(0.9)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// "820 m" close in, "1.4 km" further out (rider's units).
    private var toTopText: String {
        if toTopMeters < 950 {
            return "\(Fmt.int(distanceUnit.shortValue(fromMeters: toTopMeters))) \(distanceUnit.shortLabel)"
        }
        return "\(Fmt.decimal(distanceUnit.value(fromMeters: toTopMeters), 1)) \(distanceUnit.label)"
    }

    /// Just this climb in profile, the gained part filled solid.
    private var profile: some View {
        Canvas { context, size in
            guard let elevations = route.elevations else { return }
            let lo = climb.startIndex, hi = climb.endIndex
            guard hi > lo else { return }
            let eles = Array(elevations[lo...hi])
            let bottom = eles.min() ?? 0
            let range = max(10, (eles.max() ?? 0) - bottom)
            let span = max(1, climb.lengthMeters)
            func pt(_ k: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(k) / CGFloat(hi - lo),
                        y: size.height - 3 - (size.height - 8) * (eles[k] - bottom) / range)
            }
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for k in 0...(hi - lo) { area.addLine(to: pt(k)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(Theme.accent.opacity(0.25)))

            // The part already gained, filled solid up to the rider.
            let frac = min(1, max(0, (riddenMeters - climb.startMeters) / span))
            if frac > 0 {
                context.clip(to: Path(CGRect(x: 0, y: 0,
                                             width: size.width * frac, height: size.height)))
                context.fill(area, with: .color(Theme.accent.opacity(0.8)))
            }
        }
    }
}

/// The whole route in profile — every climb and descent of the ride at a
/// glance. A marker walks the profile as the rider progresses; the label
/// shows the gradient of the road immediately ahead (while on the route) and
/// the route's total ascent.
struct ClimbProfileStrip: View {
    let route: PlannedRoute
    let elevations: [Double]
    /// Metres ridden along the route (nil before joining — no marker).
    var progressMeters: Double? = nil
    /// Rider's path index for the gradient-ahead label (nil hides it).
    var gradientFromIndex: Int? = nil
    /// Drawn inside another tile (the climb row): no labels, no chrome — the
    /// host supplies background, border and overlaid stats.
    var embedded: Bool = false

    var body: some View {
        let samples = profileSamples()
        let gradient = gradientFromIndex.flatMap(aheadGradient)
        let ascent = zip(samples, samples.dropFirst())
            .reduce(0.0) { $0 + max(0, $1.1.ele - $1.0.ele) }
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                guard samples.count >= 2, let span = samples.last?.dist, span > 0 else { return }
                let eles = samples.map(\.ele)
                let lo = eles.min() ?? 0
                // Keep at least 40 m of vertical scale so flat roads don't
                // amplify noise into fake mountains.
                let range = max(40, (eles.max() ?? 0) - lo)
                func pt(_ s: (dist: Double, ele: Double)) -> CGPoint {
                    CGPoint(x: size.width * s.dist / span,
                            y: size.height - 4 - (size.height - 10) * (s.ele - lo) / range)
                }
                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height))
                samples.forEach { area.addLine(to: pt($0)) }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(Theme.accent.opacity(0.35)))

                var line = Path()
                line.move(to: pt(samples[0]))
                samples.dropFirst().forEach { line.addLine(to: pt($0)) }
                context.stroke(line, with: .color(Theme.accent),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // Where the rider is along the profile — a clear solid line.
                if let progressMeters {
                    let x = size.width * min(1, max(0, progressMeters / span))
                    var mark = Path()
                    mark.move(to: CGPoint(x: x, y: 2))
                    mark.addLine(to: CGPoint(x: x, y: size.height - 2))
                    context.stroke(mark, with: .color(Theme.textPrimary.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    // Dot riding the profile line itself.
                    if let s = samples.last(where: { $0.dist <= progressMeters }) ?? samples.first {
                        let p = pt((progressMeters, s.ele))
                        let dot = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                        context.fill(dot, with: .color(Theme.accent))
                        context.stroke(dot, with: .color(.white), lineWidth: 1.5)
                    }
                }
            }
            if !embedded {
                HStack(spacing: 6) {
                    if let gradient {
                        Text(verbatim: String(format: "%+.1f%%", gradient))
                            .foregroundStyle(gradient > 3 ? Theme.threatMedium
                                                : (gradient < -1 ? Theme.good : Theme.textPrimary))
                    }
                    if ascent >= 5 {
                        Text(verbatim: "↗ \(Fmt.int(ascent)) m")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(Theme.font(size: 11, weight: .bold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.top, 3)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(embedded ? Color.clear : Theme.panel.opacity(0.85)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Cumulative (distance, elevation) over the whole route, downsampled so
    /// the canvas stays cheap for dense paths.
    private func profileSamples() -> [(dist: Double, ele: Double)] {
        let step = max(1, route.path.count / 240)
        var samples: [(dist: Double, ele: Double)] = [(0, elevations[0])]
        var dist = 0.0
        for i in 1..<route.path.count {
            dist += PlannedRoute.meters(route.path[i - 1].coordinate, route.path[i].coordinate)
            if i % step == 0 || i == route.path.count - 1 {
                samples.append((dist, elevations[i]))
            }
        }
        return samples
    }

    /// Slope of the ~120 m of route ahead of `index`, as a percentage.
    private func aheadGradient(_ index: Int) -> Double? {
        guard index < route.path.count - 1 else { return nil }
        var dist = 0.0
        var i = index
        while i < route.path.count - 1, dist < 120 {
            dist += PlannedRoute.meters(route.path[i].coordinate, route.path[i + 1].coordinate)
            i += 1
        }
        guard dist >= 40 else { return nil }
        return (elevations[i] - elevations[index]) / dist * 100
    }
}

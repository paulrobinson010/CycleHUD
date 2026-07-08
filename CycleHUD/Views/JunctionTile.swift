import SwiftUI

/// The upcoming-junction tile: distance counting down on the left, and a
/// schematic of the intersection on the right — its road arms drawn at their
/// true angles in the rider's frame (up = your direction of travel, the road
/// you're on entering from the bottom), with a ring for roundabouts. Matches
/// MetricTile's chrome so it sits uniformly in the grid.
struct JunctionTile: View {
    let title: LocalizedStringKey
    var value: String
    var unit: String
    var valueSize: CGFloat = 28
    var height: CGFloat = 84
    var info: JunctionInfo?
    /// The direction a followed route leaves this junction; that arm is
    /// highlighted green so the tile points the way to go.
    var routeBearing: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textCase(.uppercase)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(Theme.valueFont(valueSize))
                        .foregroundStyle(Theme.valueStyle)
                        .shadow(color: Theme.glow, radius: 6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: max(11, valueSize * 0.3),
                                          weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.unitColor)
                    }
                }
                Spacer(minLength: 4)
                if let info {
                    JunctionGlyph(info: info, routeBearing: routeBearing)
                        .frame(width: valueSize * 1.5, height: valueSize * 1.5)
                        .shadow(color: Theme.glow, radius: 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.tileStroke, lineWidth: Theme.tileStrokeWidth))
    }
}

/// The junction schematic. Arms are rotated into the rider's frame: an arm's
/// screen angle is its bearing minus the approach bearing, so straight-ahead
/// points up and the road you arrive on always enters from the bottom (drawn
/// dimmer — it's behind you).
struct JunctionGlyph: View {
    let info: JunctionInfo
    var routeBearing: Double? = nil
    var color: Color = Theme.accent

    /// The arm closest to the route's exit direction (never the one behind).
    private var routeArm: Double? {
        guard let routeBearing else { return nil }
        func diff(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        return info.armBearings
            .filter { diff($0, info.approachBearing + 180) > 30 }
            .min { diff($0, routeBearing) < diff($1, routeBearing) }
            .flatMap { diff($0, routeBearing) <= 50 ? $0 : nil }
    }

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 1
            let lineWidth = max(2.5, r * 0.22)
            let highlighted = routeArm
            for arm in info.armBearings {
                let relDeg = ((arm - info.approachBearing).truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                let rel = relDeg * .pi / 180
                let end = CGPoint(x: c.x + r * sin(rel), y: c.y - r * cos(rel))
                // The return arm (≈180° in the rider's frame) is where you come
                // from; mute it so the roads ahead stand out — but keep it
                // clearly visible (0.35 washed out in low light on device).
                let behind = abs(relDeg - 180) < 25
                let isRoute = highlighted == arm
                var path = Path()
                path.move(to: c)
                path.addLine(to: end)
                context.stroke(path,
                               with: .color(isRoute ? Theme.good
                                                    : color.opacity(behind ? 0.6 : 1)),
                               style: StrokeStyle(lineWidth: isRoute ? lineWidth * 1.4
                                                             : (behind ? lineWidth * 0.8 : lineWidth),
                                                  lineCap: .round))
            }
            if info.isRoundabout {
                let ring = Path(ellipseIn: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45,
                                                  width: r * 0.9, height: r * 0.9))
                context.fill(ring, with: .color(Theme.panel))
                context.stroke(ring, with: .color(color),
                               style: StrokeStyle(lineWidth: lineWidth * 0.8))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: info.nodeID)
    }
}

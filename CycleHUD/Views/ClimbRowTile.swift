import SwiftUI

/// The climb row: a full-width tile with the active route's elevation profile
/// as its background (position marker included) and distance / live gradient /
/// ascent overlaid on top. Adding it moves the profile off the route map —
/// the map keeps its full height and the row carries the vertical story.
/// Without an active route (or one without elevation data) it's simply a
/// three-stat row.
struct ClimbRowTile: View {
    var route: PlannedRoute?
    var progressMeters: Double?
    let distanceValue: String
    let distanceUnit: String
    let gradientValue: String
    let gradientUnit: String
    let ascentValue: String
    let ascentUnit: String
    var valueSize: CGFloat = 28
    var height: CGFloat = 84

    var body: some View {
        ZStack {
            if let route, let elevations = route.elevations,
               elevations.count == route.path.count, route.path.count > 1 {
                ClimbProfileStrip(route: route, elevations: elevations,
                                  progressMeters: progressMeters,
                                  embedded: true)
            }
            HStack(spacing: 8) {
                stat("Distance", distanceValue, distanceUnit)
                stat("Gradient", gradientValue, gradientUnit)
                stat("Ascent", ascentValue, ascentUnit)
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.tileStroke, lineWidth: Theme.tileStrokeWidth))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textCase(.uppercase)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

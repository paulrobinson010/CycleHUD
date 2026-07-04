import SwiftUI

/// A metric tile with a direction arrow on the right — wind (arrow shows where
/// the wind is blowing relative to your direction of travel, so pointing down
/// = headwind) and the compass (arrow points north). Matches MetricTile's
/// chrome so it sits uniformly in the grid.
struct DirectionTile: View {
    let title: LocalizedStringKey
    let value: String
    let unit: String
    var valueSize: CGFloat = 28
    var height: CGFloat = 84
    /// Degrees to rotate the arrow from pointing straight up; nil hides it.
    var arrowDegrees: Double?
    var arrowColor: Color = Theme.accent

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textCase(.uppercase)
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.textSecondary)
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
            if let deg = arrowDegrees {
                Image(systemName: "location.north.fill")
                    .font(.system(size: valueSize * 0.66, weight: .bold))
                    .foregroundStyle(arrowColor)
                    .rotationEffect(.degrees(deg))
                    .shadow(color: Theme.glow, radius: 6)
                    .animation(.easeInOut(duration: 0.4), value: deg)
            }
        }
        .frame(height: height)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.tileStroke, lineWidth: Theme.tileStrokeWidth))
    }
}

/// A single labelled metric (value + unit). All tiles in a row share the same
/// `valueSize` and `height` so the grid stays visually uniform.
struct MetricTile: View {
    let title: LocalizedStringKey
    let value: String
    let unit: String
    var valueSize: CGFloat = 28
    var height: CGFloat = 84
    /// When true the tile floods red — used for the heart-rate warning.
    var alert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textCase(.uppercase)
                .font(Theme.labelFont)
                .foregroundStyle(alert ? Color.white.opacity(0.85) : Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.valueFont(valueSize))
                    .foregroundStyle(alert ? AnyShapeStyle(Color.white) : Theme.valueStyle)
                    .shadow(color: alert ? .clear : Theme.glow, radius: 6)   // neon in Cyberpunk
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: max(11, valueSize * 0.3),
                                      weight: .semibold, design: .rounded))
                        .foregroundStyle(alert ? Color.white.opacity(0.85) : Theme.unitColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(alert ? Theme.threatHigh : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.tileStroke, lineWidth: alert ? 0 : Theme.tileStrokeWidth))
        .animation(.easeInOut(duration: 0.25), value: alert)
    }
}

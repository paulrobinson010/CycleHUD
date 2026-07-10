import SwiftUI

/// A metric tile with a direction arrow on the right — wind (arrow shows where
/// the wind is blowing relative to your direction of travel, so pointing down
/// = headwind) and the compass (arrow points north). Matches MetricTile's
/// chrome so it sits uniformly in the grid.
struct DirectionTile: View {
    let title: LocalizedStringKey
    /// Empty = arrow-only (the compass): the needle becomes the tile's content.
    var value: String = ""
    var unit: String = ""
    var valueSize: CGFloat = 28
    var height: CGFloat = 84
    /// Degrees to rotate the arrow from pointing straight up; nil = no reading.
    var arrowDegrees: Double?
    var arrowColor: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The title spans the whole tile (never squeezed by the arrow) and
            // stays on one line — longer translations scale down, not wrap.
            Text(title)
                .textCase(.uppercase)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            if value.isEmpty {
                // Compass: just the needle, centred.
                Group {
                    if arrowDegrees != nil {
                        arrow(size: valueSize)
                    } else {
                        Text(verbatim: "—")
                            .font(Theme.valueFont(valueSize))
                            .foregroundStyle(Theme.valueStyle)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 6) {
                    // Unit tucked in small under the value (never beside it),
                    // so the number and the arrow keep their room.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(value)
                            .font(Theme.valueFont(valueSize))
                            .foregroundStyle(Theme.valueStyle)
                            .shadow(color: Theme.glow, radius: 6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.3), value: value)
                        if !unit.isEmpty {
                            Text(unit)
                                .font(Theme.font(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.unitColor)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if arrowDegrees != nil {
                        arrow(size: valueSize * 0.66)
                    }
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

    private func arrow(size: CGFloat) -> some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(arrowColor)
            .rotationEffect(.degrees(arrowDegrees ?? 0))
            .shadow(color: Theme.glow, radius: 6)
            .animation(.easeInOut(duration: 0.4), value: arrowDegrees)
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
    /// Tints the value — used for the power tile's zone colouring.
    var accent: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textCase(.uppercase)
                .font(Theme.labelFont)
                .foregroundStyle(alert ? Color.white.opacity(0.85) : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(Theme.valueFont(valueSize))
                .foregroundStyle(alert ? AnyShapeStyle(Color.white)
                                 : accent.map(AnyShapeStyle.init) ?? Theme.valueStyle)
                .shadow(color: alert ? .clear : Theme.glow, radius: 6)   // neon in Cyberpunk
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: value)
            // Unit tucked in small under the value, so the number keeps the
            // whole width to itself.
            if !unit.isEmpty {
                Text(unit)
                    .font(Theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(alert ? Color.white.opacity(0.85) : Theme.unitColor)
                    .lineLimit(1)
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

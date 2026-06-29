import SwiftUI

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
                    .foregroundStyle(alert ? Color.white : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: max(13, valueSize * 0.38),
                                      weight: .semibold, design: .rounded))
                        .foregroundStyle(alert ? Color.white.opacity(0.85) : Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(alert ? Theme.threatHigh : Theme.panel))
        .animation(.easeInOut(duration: 0.25), value: alert)
    }
}

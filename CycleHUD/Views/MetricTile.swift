import SwiftUI

/// A single labelled metric (value + unit). All tiles in a row share the same
/// `valueSize` and `height` so the grid stays visually uniform.
struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    var valueSize: CGFloat = 28
    var height: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(Theme.labelFont)
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.valueFont(valueSize))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: max(13, valueSize * 0.38),
                                      weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
    }
}

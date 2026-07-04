import SwiftUI

/// Tap-through detail for the wind tile: speed, gusts, where the wind is
/// blowing from, and the head/tailwind component along the rider's heading —
/// with the mandatory Apple Weather attribution.
struct WindDetailView: View {
    let conditions: WeatherConditions
    /// The rider's travel/compass heading, when known.
    let heading: Double?
    let speedUnit: SpeedUnit
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Wind")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24)).foregroundStyle(Theme.textSecondary)
                }
            }
            row(String(localized: "Speed", bundle: Lang.bundle),
                speedText(conditions.windSpeedMps))
            if let gust = conditions.gustMps, gust > conditions.windSpeedMps {
                row(String(localized: "Gusts", bundle: Lang.bundle), speedText(gust))
            }
            row(String(localized: "Direction", bundle: Lang.bundle),
                "\(Self.cardinal(conditions.windFromDegrees)) · \(Fmt.int(conditions.windFromDegrees))°")
            if let heading {
                let head = conditions.headwindMps(course: heading)
                row(head >= 0 ? String(localized: "Headwind", bundle: Lang.bundle)
                              : String(localized: "Tailwind", bundle: Lang.bundle),
                    speedText(abs(head)),
                    color: head > 1 ? Theme.threatMedium
                                    : (head < -1 ? Theme.good : Theme.textPrimary))
            }
            Spacer(minLength: 0)
            AppleWeatherAttribution()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeBackground().ignoresSafeArea())
    }

    private func row(_ label: String, _ value: String,
                     color: Color = Theme.textPrimary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private func speedText(_ mps: Double) -> String {
        "\(Fmt.decimal(speedUnit.value(fromMps: mps), 1)) \(speedUnit.label)"
    }

    /// Compass point for the "wind from" bearing.
    static func cardinal(_ deg: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = (deg.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return names[Int((normalized / 45).rounded()) % 8]
    }
}

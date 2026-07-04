import SwiftUI

/// Rain nowcast as a grid metric tile, matching `MetricTile` so it sits uniformly
/// alongside the other metrics (bottom-right, next to Calories). The value is
/// tinted by intensity when rain is current/coming; tap for the full detail.
struct WeatherTile: View {
    let nowcast: RainNowcast?
    var status: WeatherManager.Status = .idle
    var height: CGFloat = 90
    /// Mirrors the app-wide "show units on tiles" setting (hides the "min").
    var showUnit: Bool = true
    @State private var showDetail = false

    var body: some View {
        Button { if nowcast != nil { showDetail = true } } label: { tile }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDetail) {
                if let n = nowcast {
                    WeatherDetailView(nowcast: n).presentationDetents([.height(260)])
                }
            }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RAIN")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.valueFont(32))
                    .foregroundStyle(valueInk)
                    .shadow(color: Theme.glow, radius: 6)   // neon in Cyberpunk
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.unitColor)
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

    // MARK: - Content

    /// Digital digits carry no letters, so word values swap for glyphs the LCD
    /// font has: "—" for nothing to show, "0 min" for raining now, "1 h" for
    /// the hourly fallback. "—" also replaces "None"/"n/a" in standard mode —
    /// it matches how every other tile shows an empty value.
    private var digital: Bool { Theme.digitStyle == .digital }

    private var value: String {
        guard let n = nowcast else {
            if status == .unavailable { return "—" }
            return digital ? "—" : "…"                    // still loading
        }
        if n.isRaining { return digital ? "0" : String(localized: "Now", bundle: Lang.bundle) }
        if let m = n.startsInMinutes {
            if n.usedMinuteData { return Fmt.int(m) }
            return digital ? "1" : String(localized: "<1h", bundle: Lang.bundle)
        }
        return "—"                                        // no rain expected
    }

    private var unit: String {
        guard showUnit, let n = nowcast else { return "" }
        if n.isRaining { return digital ? "min" : "" }    // "0 min" = raining now
        guard n.hasRain else { return "" }
        if n.usedMinuteData { return "min" }
        return digital ? "h" : ""                         // "1 h" = within the hour
    }

    /// No rain to colour semantically → the theme's numeral ink (gradient in
    /// Cyberpunk, matching the other tiles); otherwise the intensity colour.
    private var valueInk: AnyShapeStyle {
        guard let n = nowcast, n.hasRain else { return Theme.valueStyle }
        switch n.peak {
        case .heavy: return AnyShapeStyle(Theme.threatHigh)
        case .moderate: return AnyShapeStyle(Theme.threatMedium)
        default: return AnyShapeStyle(Theme.accent)
        }
    }
}

/// Apple-required attribution for WeatherKit data: the Apple Weather mark
/// linking to the data-sources legal page. Shown wherever weather data appears
/// (rain and wind details, and next to the Settings toggle).
struct AppleWeatherAttribution: View {
    private let legalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    var body: some View {
        Link(destination: legalURL) {
            HStack(spacing: 4) {
                Image(systemName: "apple.logo").font(.system(size: 12, weight: .semibold))
                Text("Weather").font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Tap-through detail: the summary in words plus the mandatory Apple Weather
/// attribution and a link to the data-source legal page.
struct WeatherDetailView: View {
    let nowcast: RainNowcast
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rain nowcast")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24)).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(detail)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !nowcast.usedMinuteData {
                Text("Minute-by-minute data isn't available here, so this is an hourly estimate.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            AppleWeatherAttribution()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeBackground().ignoresSafeArea())
    }

    private var detail: String {
        if nowcast.isRaining {
            let d = nowcast.durationMinutes.map { String(localized: " for about \(format($0))", bundle: Lang.bundle) } ?? ""
            return String(localized: "It's raining now (\(nowcast.peak.label))\(d).", bundle: Lang.bundle)
        }
        if let m = nowcast.startsInMinutes {
            let when = nowcast.usedMinuteData ? String(localized: "in about \(Fmt.int(m)) min", bundle: Lang.bundle)
                                              : String(localized: "within the hour", bundle: Lang.bundle)
            let d = nowcast.durationMinutes.map { String(localized: ", lasting about \(format($0))", bundle: Lang.bundle) } ?? ""
            return String(localized: "Rain expected \(when) — \(nowcast.peak.label)\(d).", bundle: Lang.bundle)
        }
        return String(localized: "No rain expected in the next hour.", bundle: Lang.bundle)
    }

    private func format(_ minutes: Int) -> String {
        minutes >= 90 ? String(localized: "\(Fmt.int(Double(minutes) / 60)) hours", bundle: Lang.bundle)
                      : String(localized: "\(Fmt.int(minutes)) min", bundle: Lang.bundle)
    }
}

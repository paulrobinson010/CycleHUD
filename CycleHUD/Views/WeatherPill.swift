import SwiftUI

/// At-a-glance rain nowcast. Compact form (ride screen) shows only when rain is
/// current or coming; full form (start screen) also shows a muted "dry" state
/// and the required Apple Weather attribution. Tap for a little detail sheet.
struct WeatherPill: View {
    let nowcast: RainNowcast?
    var compact = false
    @State private var showDetail = false

    var body: some View {
        if let n = nowcast, n.hasRain || !compact {
            Button { showDetail = true } label: { pill(n) }
                .buttonStyle(.plain)
                .sheet(isPresented: $showDetail) {
                    WeatherDetailView(nowcast: n)
                        .presentationDetents([.height(260)])
                }
        }
    }

    private func pill(_ n: RainNowcast) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon(n))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint(n))
            Text(headline(n))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(n.hasRain ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(tint(n).opacity(n.hasRain ? 0.5 : 0.15), lineWidth: 1))
    }

    // MARK: - Presentation

    private func icon(_ n: RainNowcast) -> String {
        if n.isRaining { return "cloud.rain.fill" }
        if n.hasRain { return "cloud.drizzle.fill" }
        return "sun.max.fill"
    }

    private func tint(_ n: RainNowcast) -> Color {
        if !n.hasRain { return Theme.good }
        switch n.peak {
        case .heavy: return Theme.threatHigh
        case .moderate: return Theme.threatMedium
        default: return Theme.accent
        }
    }

    /// e.g. "Rain in 12 min · light · ~25 min", "Raining · moderate · ~15 min left".
    private func headline(_ n: RainNowcast) -> String {
        guard n.hasRain else { return "Dry next hour" }
        var parts: [String] = []
        if n.isRaining {
            parts.append("Raining")
        } else if let m = n.startsInMinutes {
            parts.append(n.usedMinuteData ? "Rain in \(m) min" : "Rain within the hour")
        }
        if n.peak != .none { parts.append(n.peak.label) }
        if let d = n.durationMinutes {
            let dur = d >= 90 ? "~\(Int((Double(d)/60).rounded()))h" : "~\(d) min"
            parts.append(n.isRaining ? "\(dur) left" : dur)
        }
        return parts.joined(separator: " · ")
    }
}

/// Tap-through detail: the summary in words plus the mandatory Apple Weather
/// attribution and a link to the data-source legal page.
struct WeatherDetailView: View {
    let nowcast: RainNowcast
    @Environment(\.dismiss) private var dismiss

    private let legalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

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
            // Apple-required attribution + legal link.
            Link(destination: legalURL) {
                HStack(spacing: 4) {
                    Image(systemName: "apple.logo").font(.system(size: 12, weight: .semibold))
                    Text("Weather").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.ignoresSafeArea())
    }

    private var detail: String {
        if nowcast.isRaining {
            let d = nowcast.durationMinutes.map { " for about \(format($0))" } ?? ""
            return "It's raining now (\(nowcast.peak.label))\(d)."
        }
        if let m = nowcast.startsInMinutes {
            let when = nowcast.usedMinuteData ? "in about \(m) min" : "within the hour"
            let d = nowcast.durationMinutes.map { ", lasting about \(format($0))" } ?? ""
            return "Rain expected \(when) — \(nowcast.peak.label)\(d)."
        }
        return "No rain expected in the next hour."
    }

    private func format(_ minutes: Int) -> String {
        minutes >= 90 ? "\(Int((Double(minutes)/60).rounded())) hours" : "\(minutes) min"
    }
}

import SwiftUI

/// The rear-radar lane. The rider sits at the top; vehicles behind are shown
/// trailing below, nearest at the top, furthest at the bottom. When any vehicle
/// is present the whole panel floods with the threat colour and blips turn
/// black with bold amber/red distances, so it's unmissable at a glance.
struct RadarView: View {
    let threats: [Threat]
    let distanceUnit: DistanceUnit
    let radarConnected: Bool

    private let maxRange: Double = 150          // metres shown top-to-bottom
    private let rings: [Double] = [30, 60, 90, 120]

    private var topLevel: ThreatLevel? { threats.map(\.level).max() }
    private var alertActive: Bool { topLevel != nil }
    private var alertColor: Color { topLevel?.color ?? Color.white.opacity(0.08) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Perspective: wide at the top (near the rider), narrow at the
            // bottom (far away).
            let nearWidth = w * 0.80
            let farWidth = w * 0.34

            ZStack {
                lane(w: w, h: h, nearWidth: nearWidth, farWidth: farWidth)
                ringLines(w: w, h: h, nearWidth: nearWidth, farWidth: farWidth)
                threatMarkers(w: w, h: h)
                rider(w: w)
                if threats.isEmpty { centerBadge(h: h) }
            }
            .frame(width: w, height: h)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(alertColor, lineWidth: alertActive ? 4 : 1)
                    .shadow(color: alertColor.opacity(alertActive ? 0.9 : 0), radius: 14)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .animation(.easeInOut(duration: 0.3), value: threats)
            .animation(.easeInOut(duration: 0.3), value: alertActive)
        }
    }

    private var panelBackground: AnyShapeStyle {
        if let level = topLevel {
            return AnyShapeStyle(
                LinearGradient(colors: [level.color, level.color.opacity(0.78)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
        return AnyShapeStyle(Theme.panel)
    }

    // MARK: - Geometry helpers

    /// y for a given distance: 0 m sits just below the rider (top), maxRange at
    /// the bottom.
    private func y(for distance: Double, h: CGFloat) -> CGFloat {
        let clamped = min(max(distance, 0), maxRange)
        let topInset: CGFloat = 62      // room for the rider at the top
        let bottomInset: CGFloat = 26
        let usable = h - topInset - bottomInset
        return topInset + CGFloat(clamped / maxRange) * usable
    }

    /// Lane half-width at a given vertical position (wide at top, narrow at bottom).
    private func halfWidth(atY yy: CGFloat, h: CGFloat, nearWidth: CGFloat, farWidth: CGFloat) -> CGFloat {
        let t = max(0, min(1, yy / h))   // 0 at top, 1 at bottom
        return (nearWidth + (farWidth - nearWidth) * t) / 2
    }

    // MARK: - Layers

    private func lane(w: CGFloat, h: CGFloat, nearWidth: CGFloat, farWidth: CGFloat) -> some View {
        let cx = w / 2
        return Path { p in
            p.move(to: CGPoint(x: cx - nearWidth / 2, y: 0))
            p.addLine(to: CGPoint(x: cx + nearWidth / 2, y: 0))
            p.addLine(to: CGPoint(x: cx + farWidth / 2, y: h))
            p.addLine(to: CGPoint(x: cx - farWidth / 2, y: h))
            p.closeSubpath()
        }
        .fill(Color.black.opacity(alertActive ? 0.16 : 0.0))
        .overlay(
            Path { p in
                p.move(to: CGPoint(x: cx - nearWidth / 2, y: 0))
                p.addLine(to: CGPoint(x: cx + nearWidth / 2, y: 0))
                p.addLine(to: CGPoint(x: cx + farWidth / 2, y: h))
                p.addLine(to: CGPoint(x: cx - farWidth / 2, y: h))
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color.white.opacity(0.05), Color.white.opacity(0.0)],
                                 startPoint: .top, endPoint: .bottom))
        )
    }

    private func ringLines(w: CGFloat, h: CGFloat, nearWidth: CGFloat, farWidth: CGFloat) -> some View {
        let lineColor = alertActive ? Color.black.opacity(0.28) : Color.white.opacity(0.10)
        let labelColor = alertActive ? Color.black.opacity(0.7) : Theme.textSecondary
        return ForEach(rings, id: \.self) { distance in
            let yy = y(for: distance, h: h)
            let hw = halfWidth(atY: yy, h: h, nearWidth: nearWidth, farWidth: farWidth)
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w / 2 - hw, y: yy))
                    p.addLine(to: CGPoint(x: w / 2 + hw, y: yy))
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1, dash: [4, 5]))

                Text(distanceLabel(distance))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(labelColor)
                    .position(x: min(w / 2 + hw + 16, w - 24), y: yy)
            }
        }
    }

    private func threatMarkers(w: CGFloat, h: CGFloat) -> some View {
        ForEach(threats) { threat in
            let yy = y(for: threat.distanceMeters, h: h)
            let proximity = 1 - min(threat.distanceMeters, maxRange) / maxRange
            let scale = 0.85 + proximity * 0.6
            VStack(spacing: 3) {
                CarGlyph(color: alertActive ? .black : threat.level.color)
                    .frame(width: 42 * scale, height: 27 * scale)
                Text(distanceLabel(threat.distanceMeters))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(threat.level.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black))
            }
            .position(x: w / 2, y: yy)
        }
    }

    private func rider(w: CGFloat) -> some View {
        Image(systemName: "bicycle")
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(riderColor)
            .position(x: w / 2, y: 30)
    }

    private var riderColor: Color {
        if !radarConnected { return Theme.threatHigh }   // red: no radar
        return alertActive ? Color.white : Theme.good
    }

    @ViewBuilder private func centerBadge(h: CGFloat) -> some View {
        VStack(spacing: 8) {
            if radarConnected {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.good)
                Text("Clear")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.good)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.threatHigh)
                Text("NOT CONNECTED")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.threatHigh))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, h * 0.44)
    }

    private func distanceLabel(_ meters: Double) -> String {
        let v = distanceUnit.shortValue(fromMeters: meters)
        return "\(Int(v.rounded())) \(distanceUnit.shortLabel)"
    }
}

/// Simple top-down vehicle glyph with two "headlights".
private struct CarGlyph: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: h * 0.3)
                    .fill(color)
                HStack {
                    Circle().fill(Color.white.opacity(0.9)).frame(width: h * 0.22)
                    Spacer()
                    Circle().fill(Color.white.opacity(0.9)).frame(width: h * 0.22)
                }
                .padding(.horizontal, w * 0.16)
                .padding(.top, h * 0.12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

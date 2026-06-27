import SwiftUI

/// The rear-radar lane. The rider sits at the top; vehicles behind are shown
/// trailing below, nearest at the top, furthest at the bottom. When any vehicle
/// is present the whole panel floods with the threat colour and blips turn
/// black with bold amber/red distances, so it's unmissable at a glance.
struct RadarView: View {
    let threats: [Threat]
    let distanceUnit: DistanceUnit
    let radarConnected: Bool
    var batteryPercent: Int? = nil

    @Environment(\.colorScheme) private var colorScheme

    // The TR70's real-world detection range tops out around ~50 m, so the lane is
    // drawn to that — otherwise every car clusters in the top third and "looks
    // close". Anything further (rare) clamps to the bottom of the lane.
    private let maxRange: Double = 50           // metres shown top-to-bottom

    /// Ring distances in metres, chosen to be round numbers in the rider's unit
    /// (10/20/30/40 m, or 40/80/120/160 ft).
    private var rings: [Double] {
        switch distanceUnit {
        case .km: return [10, 20, 30, 40]
        case .mi: return [40, 80, 120, 160].map { $0 / 3.280839895 }
        }
    }

    private var topLevel: ThreatLevel? { threats.map(\.level).max() }
    private var alertActive: Bool { topLevel != nil }
    private var alertColor: Color { topLevel?.color ?? Color.white.opacity(0.08) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Straight lane (constant width): nearer the rider is up, further is
            // down — no perspective taper.
            let nearWidth = w * 0.66
            let farWidth = w * 0.66

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
            .overlay(alignment: .topLeading) { batteryBadge }
            .animation(.easeInOut(duration: 0.3), value: threats)
            .animation(.easeInOut(duration: 0.3), value: alertActive)
        }
    }

    @ViewBuilder private var batteryBadge: some View {
        if radarConnected, let pct = batteryPercent {
            HStack(spacing: 4) {
                Image(systemName: "battery.100", variableValue: Double(pct) / 100.0)
                Text("\(pct)%")
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(batteryColor(pct))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(12)
        }
    }

    private func batteryColor(_ pct: Int) -> Color {
        if pct <= 15 { return Theme.threatHigh }
        if pct <= 30 { return Theme.threatLow }
        return Theme.good
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
        // Rings and their distance labels are white over the coloured alert
        // flood and over the dark theme's panel; only a *clear* panel in *light*
        // mode falls back to the dark secondary colour, where white wouldn't read.
        let clearLight = !alertActive && colorScheme == .light
        let lineColor = clearLight ? Theme.textSecondary.opacity(0.28) : Color.white.opacity(0.32)
        let labelColor = clearLight ? Theme.textSecondary : Color.white.opacity(0.9)
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
            let scale = 0.95 + proximity * 0.6
            VStack(spacing: 4) {
                CarGlyph(color: alertActive ? .black : threat.level.color)
                    .frame(width: 38 * scale, height: 60 * scale)
                Text(distanceLabel(threat.distanceMeters))
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black))
            }
            .position(x: w / 2, y: yy)
        }
    }

    private func rider(w: CGFloat) -> some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(riderColor)
            .frame(width: 46, height: 46)
            .overlay(Circle().stroke(riderColor, lineWidth: 3))
            .position(x: w / 2, y: 38)
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

/// Top-down car (front pointing up, toward the rider). The body is filled with
/// `color`; the windscreen and rear window are punched through so the panel
/// shows as tinted glass — high-contrast and clearly a car at a glance.
private struct CarGlyph: View {
    let color: Color
    var body: some View {
        ZStack {
            CarBodyShape().fill(color)
            CarWindowsShape().fill(Color.black).blendMode(.destinationOut)
        }
        .compositingGroup()   // so destinationOut only punches the windows
    }
}

/// The car outline: a tapered rounded body with two small wing mirrors.
private struct CarBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        let mirrorW = w * 0.14, mirrorH = h * 0.07, mirrorY = h * 0.20
        p.addRoundedRect(in: CGRect(x: 0, y: mirrorY, width: mirrorW, height: mirrorH),
                         cornerSize: CGSize(width: 3, height: 3))
        p.addRoundedRect(in: CGRect(x: w - mirrorW, y: mirrorY, width: mirrorW, height: mirrorH),
                         cornerSize: CGSize(width: 3, height: 3))
        let inset = w * 0.05
        p.addRoundedRect(in: CGRect(x: inset, y: 0, width: w - inset * 2, height: h),
                         cornerSize: CGSize(width: w * 0.36, height: w * 0.36))
        return p
    }
}

/// Windscreen (front) and rear window, as trapezoids.
private struct CarWindowsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.34, y: h * 0.16))
        p.addLine(to: CGPoint(x: w * 0.66, y: h * 0.16))
        p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.31))
        p.addLine(to: CGPoint(x: w * 0.26, y: h * 0.31))
        p.closeSubpath()
        p.move(to: CGPoint(x: w * 0.25, y: h * 0.47))
        p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.47))
        p.addLine(to: CGPoint(x: w * 0.71, y: h * 0.80))
        p.addLine(to: CGPoint(x: w * 0.29, y: h * 0.80))
        p.closeSubpath()
        return p
    }
}

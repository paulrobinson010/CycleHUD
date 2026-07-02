import SwiftUI

/// Branded launch splash matching the website's hero: near-black backdrop, the
/// radar logo with its purple glow, the gradient wordmark and the tagline.
/// Shown briefly over the HUD at launch, then fades out (see CycleHUDApp).
/// Brand text is deliberately verbatim (not localized), same as the site.
struct SplashView: View {
    // Website palette (docs/style.css): --bg, --text, --grad and the logo glow.
    private static let background = Color(red: 0x0C / 255, green: 0x0A / 255, blue: 0x12 / 255)
    private static let textColor = Color(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xFA / 255)
    private static let glow = Color(red: 0x9B / 255, green: 0x6B / 255, blue: 0xFF / 255)
    private static let gradient = LinearGradient(
        colors: [Color(red: 0x25 / 255, green: 0xE3 / 255, blue: 0xEE / 255),   // cyan
                 Color(red: 0x9B / 255, green: 0x6B / 255, blue: 0xFF / 255),   // purple
                 Color(red: 0xFF / 255, green: 0x4F / 255, blue: 0xD8 / 255)],  // pink
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        ZStack {
            Self.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .shadow(color: Self.glow.opacity(0.45), radius: 30)
                Text(verbatim: "CycleHUD")
                    .font(.system(size: 48, weight: .bold))
                    .kerning(-1)
                    .foregroundStyle(Self.gradient)
                    .padding(.top, 18)
                Text(verbatim: "Eyes on the road. Radar on your wrist.")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Self.textColor)
                    .padding(.top, 10)
            }
        }
    }
}

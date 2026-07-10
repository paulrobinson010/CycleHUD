import SwiftUI

/// CRT dressing for the Cyberpunk theme: phosphor scanlines and a corner
/// vignette all the time, and — at random intervals — a brief burst of
/// "magnetic interference": the picture jitters sideways, tear lines flash
/// across it, a sync bar rolls down and the colours fringe, like a tube
/// monitor next to an unshielded speaker.
///
/// Overlay-only (the content is never duplicated), so the map and radar
/// stay cheap. Glitches hold off while a vehicle is on the radar — an
/// alert must never be garbled.
struct CRTEffect: ViewModifier {
    let enabled: Bool
    /// False while a vehicle is behind; the interference waits its turn.
    let glitchesAllowed: Bool

    @State private var jitterX: CGFloat = 0
    @State private var flash: Double = 0
    @State private var tears: [Tear] = []
    /// Sync-bar position as a fraction of height; < 0 = parked off-screen.
    @State private var rollY: CGFloat = -1

    private struct Tear: Identifiable {
        let id = UUID()
        let y: CGFloat        // fraction of height
        let height: CGFloat   // points
        let shift: CGFloat    // sideways displacement, points
        let tint: Color
    }

    func body(content: Content) -> some View {
        content
            .offset(x: enabled ? jitterX : 0)
            .overlay {
                if enabled { dressing }
            }
            .task(id: enabled && glitchesAllowed) {
                guard enabled, glitchesAllowed else { return }
                while !Task.isCancelled {
                    let wait = UInt64.random(in: 5_000_000_000...14_000_000_000)
                    try? await Task.sleep(nanoseconds: wait)
                    guard !Task.isCancelled else { return }
                    await runGlitch()
                }
            }
    }

    // MARK: - Always-on tube dressing

    private var dressing: some View {
        GeometryReader { geo in
            ZStack {
                scanlines
                vignette
                if rollY >= 0 { rollBar(size: geo.size) }
                ForEach(tears) { tearBand($0, size: geo.size) }
                Color.white.opacity(flash)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Thin dark lines every 3 pt — the phosphor raster. Drawn once; Canvas
    /// only re-renders when the size changes.
    private var scanlines: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1.2)),
                         with: .color(.black.opacity(0.5)))
                y += 3
            }
        }
        .opacity(0.62)
    }

    /// Corners fall off into dark, like a tube's shadow mask.
    private var vignette: some View {
        RadialGradient(colors: [.clear, .clear, .black.opacity(0.32)],
                       center: .center, startRadius: 0, endRadius: 520)
    }

    // MARK: - Interference

    /// A soft bright band with cyan/magenta fringes that sweeps down the
    /// screen during a glitch — the vertical-hold losing its grip.
    private func rollBar(size: CGSize) -> some View {
        VStack(spacing: 0) {
            Color(red: 0.2, green: 1.0, blue: 0.95).opacity(0.10).frame(height: 3)
            LinearGradient(colors: [.clear, .white.opacity(0.13), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 70)
            Color(red: 1.0, green: 0.25, blue: 0.85).opacity(0.10).frame(height: 3)
        }
        .frame(width: size.width)
        .position(x: size.width / 2, y: rollY * size.height)
        .blendMode(.screen)
    }

    /// One horizontal tear: a displaced glowing sliver.
    private func tearBand(_ tear: Tear, size: CGSize) -> some View {
        Rectangle()
            .fill(tear.tint.opacity(0.35))
            .frame(width: size.width, height: tear.height)
            .offset(x: tear.shift)
            .position(x: size.width / 2, y: tear.y * size.height)
            .blendMode(.screen)
    }

    /// ~0.4 s of chaos: discrete jumps every 45 ms read more "broken" than
    /// anything smoothly animated, while the sync bar rolls through once.
    @MainActor private func runGlitch() async {
        rollY = -0.1
        withAnimation(.linear(duration: 0.42)) { rollY = 1.15 }
        let magenta = Color(red: 1.0, green: 0.25, blue: 0.85)
        let cyan = Color(red: 0.2, green: 1.0, blue: 0.95)
        for _ in 0..<8 {
            guard !Task.isCancelled else { break }
            jitterX = CGFloat.random(in: -8...8)
            flash = Double.random(in: 0...0.05)
            tears = (0..<Int.random(in: 2...4)).map { _ in
                Tear(y: .random(in: 0.02...0.98),
                     height: .random(in: 2...7),
                     shift: .random(in: -18...18),
                     tint: Bool.random() ? cyan : magenta)
            }
            try? await Task.sleep(nanoseconds: 45_000_000)
        }
        jitterX = 0
        flash = 0
        tears = []
        rollY = -1
    }
}

extension View {
    /// CRT scanlines + random magnetic-interference glitches, Cyberpunk only.
    func crtEffect(enabled: Bool, glitchesAllowed: Bool) -> some View {
        modifier(CRTEffect(enabled: enabled, glitchesAllowed: glitchesAllowed))
    }
}

import SwiftUI

/// Quick-access mute toggles shown on the radar panel, so the rider can silence
/// the new-vehicle beep and/or the Apple Watch wrist taps mid-ride (handy in a
/// busy town). Two round buttons — beep and haptics. A muted button flips to a
/// bold red, slashed state so what's silenced is obvious at a glance.
struct MuteControls: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            muteButton(on: settings.beepEnabled,
                       onIcon: "speaker.wave.2.fill", offIcon: "speaker.slash.fill") {
                settings.beepEnabled.toggle()
            }
            muteButton(on: settings.hapticsEnabled,
                       onIcon: "applewatch.radiowaves.left.and.right", offIcon: "applewatch.slash") {
                settings.hapticsEnabled.toggle()
            }
        }
    }

    private func muteButton(on: Bool, onIcon: String, offIcon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? onIcon : offIcon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(on ? Theme.textPrimary : .white)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(on ? AnyShapeStyle(.ultraThinMaterial)
                                     : AnyShapeStyle(Theme.threatHigh))
                }
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

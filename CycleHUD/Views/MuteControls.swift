import SwiftUI

/// Quick-access mute toggles shown on the radar panel, so the rider can silence
/// the new-vehicle beep and/or the Apple Watch wrist taps mid-ride (handy in a
/// busy town). Three buttons: beep, haptics, and a master that mutes/unmutes
/// both at once. A muted control flips to a bold red, slashed state so what's
/// silenced is obvious at a glance.
struct MuteControls: View {
    @ObservedObject var settings: AppSettings

    private var bothMuted: Bool { !settings.beepEnabled && !settings.hapticsEnabled }

    var body: some View {
        HStack(spacing: 4) {
            muteButton(on: settings.beepEnabled,
                       onIcon: "speaker.wave.2.fill", offIcon: "speaker.slash.fill",
                       label: "Beep") { settings.beepEnabled.toggle() }
            muteButton(on: settings.hapticsEnabled,
                       onIcon: "applewatch.radiowaves.left.and.right", offIcon: "applewatch.slash",
                       label: "Buzz") { settings.hapticsEnabled.toggle() }
            Divider().frame(height: 30).overlay(Theme.textSecondary.opacity(0.4))
            muteButton(on: !bothMuted,
                       onIcon: "bell.fill", offIcon: "bell.slash.fill",
                       label: "All") {
                let turnOn = bothMuted               // both off → restore both
                settings.beepEnabled = turnOn
                settings.hapticsEnabled = turnOn
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func muteButton(on: Bool, onIcon: String, offIcon: String,
                            label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: on ? onIcon : offIcon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(on ? Theme.textPrimary : .white)
                    .frame(width: 38, height: 26)
                    .background(on ? Color.clear : Theme.threatHigh,
                                in: RoundedRectangle(cornerRadius: 8))
                Text(label)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(on ? Theme.textSecondary : Theme.threatHigh)
            }
            .frame(minWidth: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

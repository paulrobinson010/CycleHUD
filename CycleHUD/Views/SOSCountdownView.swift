import SwiftUI

/// Full-screen, high-contrast crash-alert countdown. Big targets so a shaken
/// rider can cancel a false alarm, or raise the alert immediately.
struct SOSCountdownView: View {
    @ObservedObject var sos: SOSManager

    var body: some View {
        ZStack {
            Theme.threatHigh.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(.white)
                Text("Possible crash detected")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Sending an SOS to your emergency contact in")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                Text("\(sos.secondsRemaining)")
                    .font(.system(size: 80, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Spacer()
                Button { sos.cancel() } label: {
                    Text("I’m OK — cancel")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.threatHigh)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
                }
                Button { sos.sendNow() } label: {
                    Text("Send SOS now")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(RoundedRectangle(cornerRadius: 18)
                            .stroke(.white, lineWidth: 2))
                }
            }
            .padding(28)
        }
    }
}

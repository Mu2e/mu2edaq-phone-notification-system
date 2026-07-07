import SwiftUI

/// Splash screen shown while the app loads.
struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.07, blue: 0.16),
                                    Color(red: 0.06, green: 0.13, blue: 0.28)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "bell.badge.waveform.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.cyan, .white)
                    .scaleEffect(pulse ? 1.06 : 0.94)
                    .animation(.easeInOut(duration: 0.9)
                        .repeatForever(autoreverses: true), value: pulse)
                Text("Mu2e DAQ Notify")
                    .font(.title.bold())
                    .foregroundColor(.white)
                Text("Fermilab · Mu2e Experiment")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                ProgressView()
                    .tint(.white)
                    .padding(.top, 8)
            }
        }
        .onAppear { pulse = true }
    }
}

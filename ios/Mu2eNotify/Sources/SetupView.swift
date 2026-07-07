import SwiftUI

/// First-run registration: scan the enrollment QR code from the server's
/// web interface, or paste an auto-configuration URL.
struct SetupView: View {
    @EnvironmentObject var state: AppState
    @State private var showScanner = false
    @State private var manualURL = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "bell.badge.waveform.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.cyan, .primary)
                Text("Connect to the DAQ")
                    .font(.title2.bold())
                Text("On the notification server's web interface open "
                     + "Devices → Enroll a new phone, then scan the QR "
                     + "code, or paste the auto-configuration URL below.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                VStack(spacing: 8) {
                    TextField("https://server/api/autoconfig/…",
                              text: $manualURL)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Button("Configure from URL") {
                        busy = true
                        Task {
                            await state.register(
                                fromAutoconfigURL: manualURL)
                            busy = false
                        }
                    }
                    .disabled(manualURL.isEmpty || busy)
                }
                .padding(.horizontal)

                if busy { ProgressView() }
                if let err = state.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .padding(.top, 48)
            .navigationTitle("Mu2e Notify")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showScanner) {
                QRScannerView { text in
                    showScanner = false
                    if let cfg = EnrollmentConfig.parse(text) {
                        Task { await state.register(with: cfg) }
                    } else if text.hasPrefix("http") {
                        Task {
                            await state.register(fromAutoconfigURL: text)
                        }
                    } else {
                        state.lastError =
                            "That QR code is not a Mu2e Notify enrollment code"
                    }
                }
            }
        }
    }
}

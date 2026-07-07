import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmUnregister = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("URL", value: state.serverUrl)
                    Button("Re-request push permission") {
                        Task { await state.requestPushPermission() }
                    }
                }
                Section("This device") {
                    TextField("Device name", text: $state.deviceName)
                        .onSubmit { Task { await state.pushSettings() } }
                    Picker("Minimum severity",
                           selection: Binding(
                               get: { state.minSeverity },
                               set: { newValue in
                                   state.minSeverity = newValue
                                   Task { await state.pushSettings() }
                               })) {
                        ForEach(Severity.allCases, id: \.self) { sev in
                            Label(sev.rawValue.capitalized,
                                  systemImage: sev.symbol).tag(sev)
                        }
                    }
                }
                Section {
                    Button("Unregister this device", role: .destructive) {
                        confirmUnregister = true
                    }
                } footer: {
                    Text("Removes the stored server address and device "
                         + "token. Also delete the device on the server's "
                         + "Devices page to stop pushes immediately.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Unregister this device?",
                                isPresented: $confirmUnregister,
                                titleVisibility: .visible) {
                Button("Unregister", role: .destructive) {
                    state.unregister()
                }
            }
        }
    }
}

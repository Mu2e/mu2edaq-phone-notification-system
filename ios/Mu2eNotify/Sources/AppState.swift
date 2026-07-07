import Foundation
import SwiftUI
import UserNotifications

/// Central application state: registration with the server, the cached
/// event list, and APNs token plumbing.
@MainActor
final class AppState: ObservableObject {
    @AppStorage("serverUrl") var serverUrl: String = ""
    @AppStorage("deviceToken") private var storedDeviceToken: String = ""
    @AppStorage("deviceName") var deviceName: String = UIDevice.current.name
    @AppStorage("minSeverity") var minSeverityRaw: String =
        Severity.warning.rawValue

    @Published var events: [NotifyEvent] = []
    @Published var lastError: String?
    @Published var isRefreshing = false

    private var pendingApnsToken: String?

    var isRegistered: Bool {
        !serverUrl.isEmpty && !storedDeviceToken.isEmpty
    }

    var minSeverity: Severity {
        get { Severity(rawValue: minSeverityRaw) ?? .warning }
        set { minSeverityRaw = newValue.rawValue }
    }

    private var client: ServerClient? {
        guard let url = URL(string: serverUrl), isRegistered else {
            return nil
        }
        return ServerClient(baseURL: url, bearerToken: storedDeviceToken)
    }

    // Registration ---------------------------------------------------------

    /// Complete enrollment from a scanned QR code or manual entry.
    func register(with config: EnrollmentConfig) async {
        guard let url = URL(string: config.serverUrl) else {
            lastError = "Bad server URL in configuration"
            return
        }
        do {
            let result = try await ServerClient.register(
                serverUrl: url, enrollmentToken: config.enrollmentToken,
                name: deviceName, apnsToken: pendingApnsToken)
            serverUrl = result.serverUrl
            storedDeviceToken = result.deviceToken
            lastError = nil
            await requestPushPermission()
            await refreshEvents()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fetch the auto-configuration payload from an enrollment URL.
    func register(fromAutoconfigURL urlText: String) async {
        guard let url = URL(string: urlText.trimmingCharacters(
            in: .whitespacesAndNewlines)) else {
            lastError = "Not a valid URL"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let cfg = try? JSONDecoder().decode(EnrollmentConfig.self,
                                                      from: data) else {
                lastError = "URL did not return a Mu2e Notify configuration"
                return
            }
            await register(with: cfg)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unregister() {
        serverUrl = ""
        storedDeviceToken = ""
        events = []
    }

    // Push notifications -----------------------------------------------------

    func requestPushPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
        if granted {
            await UIApplication.shared.registerForRemoteNotifications()
        } else {
            lastError = "Push notification permission was not granted"
        }
    }

    func apnsTokenReceived(_ token: String) async {
        pendingApnsToken = token
        if let client = client {
            do {
                try await client.updateApnsToken(token)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // Events -----------------------------------------------------------------

    func refreshEvents() async {
        guard let client = client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            events = try await client.fetchEvents()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pushSettings() async {
        guard let client = client else { return }
        do {
            try await client.updateSettings(name: deviceName,
                                            minSeverity: minSeverity)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

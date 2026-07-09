import Foundation
import SwiftUI
import UserNotifications

/// Central application state: registration with the server, the cached
/// event list, and APNs token plumbing.
@MainActor
final class AppState: ObservableObject {
    @AppStorage("serverUrl") var serverUrl: String = ""
    @AppStorage("deviceToken") private var storedDeviceToken: String = ""
    @AppStorage("apnsToken") private var storedApnsToken: String = ""
    @AppStorage("deviceName") var deviceName: String = UIDevice.current.name
    @AppStorage("minSeverity") var minSeverityRaw: String =
        Severity.warning.rawValue

    @Published var events: [NotifyEvent] = []
    @Published var categories: [String] = []
    @Published var lastError: String?
    @Published var isRefreshing = false
    @Published var pushStatus = "Unknown"
    @Published var serverApnsEnabled: Bool?

    var hasApnsToken: Bool { !storedApnsToken.isEmpty }
    var serverApnsStatus: String {
        guard let serverApnsEnabled else { return "Unknown" }
        return serverApnsEnabled ? "Enabled" : "Log-only"
    }

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
                name: deviceName,
                apnsToken: storedApnsToken.isEmpty ? nil : storedApnsToken)
            serverUrl = result.serverUrl
            storedDeviceToken = result.deviceToken
            lastError = nil
            await syncPushRegistration()
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
        storedApnsToken = ""
        events = []
    }

    // Push notifications -----------------------------------------------------

    func requestPushPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
        if granted {
            pushStatus = "Allowed; waiting for APNS token"
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            pushStatus = "Denied"
            lastError = "Push notification permission was not granted"
        }
    }

    func syncPushRegistration() async {
        guard isRegistered else { return }
        let settings = await UNUserNotificationCenter.current()
            .notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            pushStatus = "Permission not requested"
            await requestPushPermission()
        case .denied:
            pushStatus = "Denied"
            lastError = "Push notifications are disabled in iOS Settings"
        case .authorized, .provisional, .ephemeral:
            pushStatus = storedApnsToken.isEmpty
                ? "Allowed; waiting for APNS token"
                : "Allowed"
            UIApplication.shared.registerForRemoteNotifications()
            if !storedApnsToken.isEmpty, let client = client {
                do {
                    try await client.updateApnsToken(storedApnsToken)
                } catch {
                    lastError = error.localizedDescription
                }
            }
        @unknown default:
            pushStatus = "Unknown"
        }
    }

    func apnsTokenReceived(_ token: String) async {
        storedApnsToken = token
        pushStatus = "Allowed"
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
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let fetchedEvents = client.fetchEvents()
            async let fetchedHealth = client.fetchHealth()
            async let fetchedCategories = client.fetchCategories()
            events = try await fetchedEvents
            if let health = try? await fetchedHealth {
                serverApnsEnabled = health.apnsEnabled
            }
            if let fetchedCategories = try? await fetchedCategories {
                categories = fetchedCategories
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshEventsPeriodically(every seconds: UInt64 = 5) async {
        await refreshEvents()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch {
                return
            }
            await refreshEvents()
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

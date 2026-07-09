// Mu2e Notify: receives push notifications from the Mu2e DAQ
// notification server and shows an event dashboard.

import SwiftUI
import UserNotifications

@main
struct Mu2eNotifyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(state)
                    .onAppear { appDelegate.state = state }
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                withAnimation(.easeOut(duration: 0.5)) { showSplash = false }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if state.isRegistered {
            TabView {
                DashboardView()
                    .tabItem { Label("Dashboard", systemImage: "bell.badge") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .task {
                await state.syncPushRegistration()
                await state.refreshEvents()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await state.syncPushRegistration()
                        await state.refreshEvents()
                    }
                }
            }
        } else {
            SetupView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate,
                         UNUserNotificationCenterDelegate {
    weak var state: AppState?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken
                     deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await state?.apnsTokenReceived(token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError
                     error: Error) {
        Task { @MainActor in
            state?.lastError = "APNs registration failed: " +
                error.localizedDescription
        }
    }

    // Show banners even while the app is in the foreground, and refresh
    // the dashboard from the server.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        await state?.refreshEvents()
        return [.banner, .sound, .badge, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse)
        async {
        await state?.refreshEvents()
    }
}

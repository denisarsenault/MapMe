import SwiftUI
import WatchKit

@main
struct MapMeWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    @StateObject private var auth = AuthService()
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var roleStore = AppRoleStore()
    @StateObject private var connectivity = WatchConnectivitySession.shared
    @StateObject private var location = WatchLocationService.shared

    @Environment(\.scenePhase) private var scenePhase

    /// See `MapMeApp.splashDismissed` for the layered (not swapped) splash
    /// rationale.
    @State private var splashDismissed = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                WatchRootView()
                    .environmentObject(auth)
                    .environmentObject(roleStore)
                    .environmentObject(connectivity)
                    .environmentObject(location)
                    .environment(\.managedObjectContext, persistence.container.viewContext)

                if !splashDismissed {
                    WatchSplashView()
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .milliseconds(1400))
                            withAnimation(.easeOut(duration: 0.35)) {
                                splashDismissed = true
                            }
                        }
                }
            }
            .task {
                // Register the watch as a trusted device — idempotent,
                // refreshes lastActiveAt on every launch. Deferred out
                // of init so the splash / first frame paints first
                // (same reasoning as GuardianAudioAlertService on iOS).
                try? await Task.sleep(for: .milliseconds(200))
                TrustedDeviceService.shared.registerCurrentDevice()
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            auth.lock()
            // Make sure we have a pending background fetch scheduled even if
            // the app exits cleanly.
            delegate.scheduleNextBackgroundRefresh()
        default:
            break
        }
    }
}

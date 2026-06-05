import SwiftUI
import CloudKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@main
struct MapMeApp: App {
    #if os(iOS) || os(tvOS)
    @UIApplicationDelegateAdaptor(MapMeAppDelegate.self) private var delegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MapMeAppDelegate.self) private var delegate
    #endif

    @StateObject private var auth = AuthService()
    @StateObject private var persistence = PersistenceController.shared
    @StateObject private var roleStore = AppRoleStore()
    @StateObject private var guardianSync = GuardianSyncService()
    #if os(iOS)
    @StateObject private var location = LocationService()
    @StateObject private var phoneResponder = PhoneConnectivityResponder.shared
    #endif
    @Environment(\.scenePhase) private var scenePhase

    /// `true` once the launch splash has dismissed. We layer SplashView on
    /// top of RootView so RootView's StateObjects / CoreData stack get a
    /// head start during the splash beat — feels snappier than swapping.
    @State private var splashDismissed = false

    init() {
        #if os(iOS)
        BackgroundTaskScheduler.register()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(auth)
                    .environmentObject(roleStore)
                    .environmentObject(guardianSync)
                    .environment(\.managedObjectContext, persistence.container.viewContext)
                    #if os(iOS)
                    .environmentObject(location)
                    #endif

                if !splashDismissed {
                    SplashView()
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .milliseconds(1400))
                            withAnimation(.easeOut(duration: 0.35)) {
                                splashDismissed = true
                            }
                        }
                }
            }
                .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
                .task {
                    if roleStore.role == .guardian {
                        await guardianSync.ensureSubscription()
                    }
                }
                .onChange(of: roleStore.role) { _, newValue in
                    if newValue == .guardian {
                        Task { await guardianSync.ensureSubscription() }
                    }
                }
                #if os(iOS)
                .task {
                    // Hand the live AuthService to the WatchConnectivity
                    // responder so the watch can ask the phone "are you
                    // unlocked?" instead of prompting for its own PIN.
                    phoneResponder.attach(auth: auth)
                }
                .sheet(item: $phoneResponder.pendingShareItem) { item in
                    // Watch handed us a CKShare URL — present a real iOS
                    // share sheet so the user can pick Messages / AirDrop /
                    // Mail with the iPhone's full keyboard + contact list.
                    ShareSheet(url: item.url) {
                        phoneResponder.pendingShareItem = nil
                    }
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)
        #endif
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            auth.lock()
            #if os(iOS)
            BackgroundTaskScheduler.scheduleNextDailyArchive()
            #endif
        case .active:
            #if os(iOS)
            if roleStore.role == .minor {
                ArchiveService(context: persistence.container.newBackgroundContext())
                    .runArchivePassIfNeeded()
            }
            #endif
        default:
            break
        }
    }
}

// MARK: - Platform AppDelegate

#if os(iOS) || os(tvOS)
final class MapMeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    /// Called by iOS/tvOS when the user taps a CloudKit share invitation URL.
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in
            do {
                try await SharingService().acceptShare(metadata: metadata)
            } catch {
                #if DEBUG
                print("Failed to accept share: \(error)")
                #endif
            }
        }
    }
}
#elseif os(macOS)
final class MapMeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in
            do {
                try await SharingService().acceptShare(metadata: metadata)
            } catch {
                #if DEBUG
                print("Failed to accept share: \(error)")
                #endif
            }
        }
    }
}
#endif

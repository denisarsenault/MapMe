import SwiftUI
import CloudKit
import os
import UserNotifications
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif 
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Subsystem-shared logger for the share-accept path. Filter in
/// Console.app by subsystem `com.mybrightzone.app` + category
/// `sharing` to see only these messages.
private let shareLog = Logger(subsystem: "com.mybrightzone.app", category: "sharing")


/// Posts a local notification (already-authorized cases only) so the
/// Guardian gets a visible "couldn't accept invite" message when
/// `acceptShare` throws. Without this, a failed cold-launch accept
/// just silently logs and the user thinks "tapping the link did
/// nothing."
///
/// tvOS doesn't surface alert-style notifications — the OS marks
/// `UNMutableNotificationContent.title`/`.body`/`.sound` as unavailable
/// there. We still want the accept handler to RUN on tvOS (Apple TV
/// can be a Guardian dashboard), so this function is a no-op on
/// tvOS; the error is already logged via `shareLog` on every
/// platform.
private func notifyShareAcceptFailure(_ error: Error) {
    #if os(tvOS)
    _ = error
    #else
    let content = UNMutableNotificationContent()
    content.title = "MapMe couldn't accept the invite"
    content.body = error.localizedDescription
    content.sound = .default
    let request = UNNotificationRequest(
        identifier: "com.mapme.share-accept-failed",
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
    #endif
}

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
    #if os(iOS) || os(macOS)
    @StateObject private var location = LocationService.shared
    #endif
    #if os(iOS)
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
        // GuardianAudioAlertService.shared touch was here but got
        // moved into a background `.task` on the root view — see
        // `body`. Its init calls `start()` which registers a
        // NotificationCenter observer keyed on
        // `PersistenceController.shared.container.persistentStoreCoordinator`.
        // Touching that from `MapMeApp.init()` synchronously
        // forces the entire NSPersistentCloudKitContainer to
        // initialise before SwiftUI has a chance to render the
        // splash — and when the CloudKit backlog is large, that
        // init runs long enough that the splash stays stuck on
        // screen for tens of seconds. Deferring it lets the UI
        // paint first; the service is still up in time to catch
        // real user-driven events.
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(auth)
                    .environmentObject(roleStore)
                    .environmentObject(guardianSync)
                    .environment(\.managedObjectContext, persistence.container.viewContext)
                    #if os(iOS) || os(macOS)
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
                .task {
                    // Deferred `GuardianAudioAlertService.shared`
                    // touch — see `init()` for why this can't run
                    // inline at app init. A short sleep lets the
                    // splash + first frame paint before we force
                    // the CloudKit stack + audio session + observer
                    // registration.
                    try? await Task.sleep(for: .milliseconds(200))
                    _ = GuardianAudioAlertService.shared
                    // Also touch TrustedDeviceService and register
                    // this device — idempotent, refreshes the
                    // lastActiveAt column on every launch so the
                    // Trusted Devices list stays honest.
                    TrustedDeviceService.shared.registerCurrentDevice()
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

        // macOS-native Settings scene: adds a "Settings…" entry under
        // the app menu with the ⌘, shortcut. Independent of the
        // dashboard toolbar's Settings button (which can be pushed
        // into the toolbar overflow on narrow windows), so a user
        // running with a small window still has a reliable path to
        // Settings.
        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(auth)
                .environmentObject(roleStore)
                .environmentObject(guardianSync)
                .environmentObject(location)
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .frame(minWidth: 480, minHeight: 420)
        }
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
            LaunchReminderService.shared.recordAppActivity()
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
            shareLog.notice("userDidAcceptCloudKitShareWith fired (share: \(metadata.share.recordID.recordName, privacy: .public))")
            do {
                try await SharingService().acceptShare(metadata: metadata)
                shareLog.notice("acceptShare succeeded — Guardian should now see the new device in Family")
            } catch {
                shareLog.error("acceptShare FAILED: \(error.localizedDescription, privacy: .public)")
                notifyShareAcceptFailure(error)
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
            shareLog.notice("userDidAcceptCloudKitShareWith fired (share: \(metadata.share.recordID.recordName, privacy: .public))")
            do {
                try await SharingService().acceptShare(metadata: metadata)
                shareLog.notice("acceptShare succeeded — Guardian should now see the new device in Family")
            } catch {
                shareLog.error("acceptShare FAILED: \(error.localizedDescription, privacy: .public)")
                notifyShareAcceptFailure(error)
            }
        }
    }
}
#endif

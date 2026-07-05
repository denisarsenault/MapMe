import WatchKit
import Foundation
import UserNotifications

/// Owns the watchOS background-task lifecycle. Schedules the next refresh
/// every ~15 minutes and drives `WatchLocationService.performBackgroundLocationFetch`
/// when the system fires the task.
///
/// Also serves as `UNUserNotificationCenterDelegate` so banner-style
/// notifications (the Test alert button + the real "tracking paused"
/// watchdog) show up even when MapMe is in the foreground. watchOS
/// suppresses the system banner for foreground notifications by
/// default, which made the Test alert button appear broken — the
/// notification was scheduled fine, just never visually surfaced.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    static let backgroundRefreshInterval: TimeInterval = 15 * 60

    func applicationDidFinishLaunching() {
        scheduleNextBackgroundRefresh()
        // Wire ourselves as the notification-center delegate so
        // `userNotificationCenter(_:willPresent:withCompletionHandler:)`
        // below gets called for any incoming notification while MapMe
        // is on screen. Without this, foreground notifications go
        // silently to the notification log with no visual.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidBecomeActive() {
        // Re-arm whenever the app comes to the foreground. After a battery
        // drain + recharge the watch reboots and silently drops every pending
        // background-refresh request; watchOS never background-launches the
        // app on boot, so the self-rearming chain is dead until *something*
        // launches us. A user opening the app is one such trigger — make sure
        // it restarts the chain.
        scheduleNextBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        // Re-arm the app-refresh chain on EVERY background wake, whatever its
        // type. This is the recovery path after a power-off: once a MapMe
        // complication on the active face causes watchOS to background-launch
        // us for a snapshot/refresh, this call rebuilds the schedule the
        // reboot wiped. Done once per delivery, before dispatching tasks.
        scheduleNextBackgroundRefresh()

        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                handleAppRefresh(refresh)

            case let snapshot as WKSnapshotRefreshBackgroundTask:
                snapshot.setTaskCompleted(
                    restoredDefaultState: false,
                    estimatedSnapshotExpiration: .distantFuture,
                    userInfo: nil
                )

            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    func scheduleNextBackgroundRefresh() {
        let when = Date(timeIntervalSinceNow: Self.backgroundRefreshInterval)
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: when,
            userInfo: nil
        ) { error in
            #if DEBUG
            if let error {
                print("scheduleBackgroundRefresh: \(error)")
            }
            #endif
        }
    }

    private func handleAppRefresh(_ task: WKApplicationRefreshBackgroundTask) {
        // The next refresh was already queued in `handle(_:)` before any task
        // was dispatched, so the chain survives even if the work below crashes.
        Task { @MainActor in
            WatchLocationService.shared.performBackgroundLocationFetch {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension WatchAppDelegate: UNUserNotificationCenterDelegate {
    /// Called for every notification that arrives while MapMe is on
    /// screen. Returning `[.banner, .sound]` asks watchOS to show the
    /// same banner + haptic it would show in the background — without
    /// this, the Test alert button would silently log the notification
    /// and the user would see nothing.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

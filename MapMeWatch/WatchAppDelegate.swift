import WatchKit
import Foundation

/// Owns the watchOS background-task lifecycle. Schedules the next refresh
/// every ~15 minutes and drives `WatchLocationService.performBackgroundLocationFetch`
/// when the system fires the task.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    static let backgroundRefreshInterval: TimeInterval = 15 * 60

    func applicationDidFinishLaunching() {
        scheduleNextBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
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
        // Always queue the next one before doing any work — if we crash, we
        // still get woken up next interval.
        scheduleNextBackgroundRefresh()

        Task { @MainActor in
            WatchLocationService.shared.performBackgroundLocationFetch {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

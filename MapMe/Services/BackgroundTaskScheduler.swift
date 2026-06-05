#if os(iOS)
import Foundation
import BackgroundTasks

enum BackgroundTaskScheduler {
    static let dailyArchiveID = "com.mapme.daily-archive"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: dailyArchiveID,
            using: nil
        ) { task in
            handleDailyArchive(task: task as! BGAppRefreshTask)
        }
    }

    static func scheduleNextDailyArchive() {
        let request = BGAppRefreshTaskRequest(identifier: dailyArchiveID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("BG schedule error: \(error)")
            #endif
        }
    }

    private static func handleDailyArchive(task: BGAppRefreshTask) {
        scheduleNextDailyArchive()

        let context = PersistenceController.shared.newBackgroundContext()
        let service = ArchiveService(context: context)

        let work = DispatchWorkItem {
            service.runArchivePass()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }

        DispatchQueue.global(qos: .background).async(execute: work)
    }
}
#endif

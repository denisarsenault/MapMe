import CoreData
import CloudKit
import os

/// Wraps `NSPersistentCloudKitContainer` with two stores so the same model is
/// mirrored against both the user's CloudKit private DB (where their own
/// recordings live) and the CloudKit shared DB (where records from minors that
/// have invited this device land).
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    private(set) var privateStore: NSPersistentStore?
    private(set) var sharedStore: NSPersistentStore?

    /// Per-launch latch that prevents the history-truncation recovery
    /// from running more than once. If a single truncate doesn't fix
    /// the corruption, looping the recovery would just thrash the disk;
    /// one attempt per cold launch is enough.
    private var attemptedHistoryRecovery = false
    /// Token bag so we can detach the notification observer in `deinit`
    /// (the shared singleton never deinits in practice, but the test
    /// in-memory variant might).
    private var cloudKitEventObserver: NSObjectProtocol?
    /// Dedicated logger for the recovery path so we can grep for it in
    /// Console.app without dragging the wider `PerfLog` helper back in
    /// (the prior iPhone perf-instrumentation pass got reverted).
    private static let log = Logger(subsystem: "com.mybrightzone.app", category: "cloudkit")

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "MapMe")

        guard let privateDescription = container.persistentStoreDescriptions.first else {
            fatalError("Missing persistent store description")
        }

        if inMemory {
            privateDescription.url = URL(fileURLWithPath: "/dev/null")
            privateDescription.cloudKitContainerOptions = nil
            container.persistentStoreDescriptions = [privateDescription]
        } else {
            // ── Private store ────────────────────────────────────────────────
            privateDescription.shouldMigrateStoreAutomatically = true
            privateDescription.shouldInferMappingModelAutomatically = true
            privateDescription.setOption(true as NSNumber,
                                         forKey: NSPersistentHistoryTrackingKey)
            privateDescription.setOption(true as NSNumber,
                                         forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let privateOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.mapme.app"
            )
            privateOptions.databaseScope = .private
            privateDescription.cloudKitContainerOptions = privateOptions

            // ── Shared store (mirror of CloudKit shared DB) ──────────────────
            let storesURL = privateDescription.url?.deletingLastPathComponent()
            let sharedURL = storesURL?.appendingPathComponent("MapMeShared.sqlite")

            let sharedDescription = privateDescription.copy() as! NSPersistentStoreDescription
            sharedDescription.url = sharedURL
            let sharedOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.mapme.app"
            )
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions

            container.persistentStoreDescriptions = [privateDescription, sharedDescription]
        }

        container.loadPersistentStores { [weak self] description, error in
            if let error = error as NSError? {
                assertionFailure("CoreData failed to load: \(error)")
                return
            }
            guard let self,
                  let url = description.url,
                  let store = self.container.persistentStoreCoordinator.persistentStore(for: url)
            else { return }
            switch description.cloudKitContainerOptions?.databaseScope {
            case .private: self.privateStore = store
            case .shared:  self.sharedStore = store
            default:       break
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        observeCloudKitMirroringEvents()
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }

    /// Polls until the shared store is loaded, or `timeout` elapses.
    /// `loadPersistentStores` is async-by-callback and the system can
    /// invoke `userDidAcceptCloudKitShareWith:` immediately on cold-
    /// launch — long before our shared store description's callback
    /// fires. Without this wait, `SharingService.acceptShare`
    /// hit `sharedStore == nil`, force-unwrapped, and crashed the app
    /// silently. From the Guardian's perspective: "tapped link,
    /// nothing happened."
    @discardableResult
    func waitForSharedStore(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while sharedStore == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        return sharedStore != nil
    }

    deinit {
        if let token = cloudKitEventObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - CloudKit mirroring health

    /// Subscribes to `NSPersistentCloudKitContainer.eventChangedNotification`
    /// and watches for the "history analysis failed" error (`NSCocoaErrorDomain`
    /// code 134421). When CloudKit mirroring throws an unhandled
    /// `NSSet.removeObject(nil)` inside its history-analysis path, it
    /// goes into a "never successfully initialized" state and *every*
    /// subsequent import/export request is aborted — sync is broken
    /// until something clears the corrupted history entries. The store
    /// doesn't self-heal.
    ///
    /// Recovery: truncate the persistent history (clears the change-log
    /// entries CloudKit is choking on without dropping any actual
    /// entity data), then let the next sync cycle bootstrap cleanly
    /// from current store state. The CloudKit mirroring delegate
    /// stays broken for the rest of THIS launch, but a clean
    /// history table means the next cold launch initialises fresh
    /// and sync resumes.
    ///
    /// Latched per launch so we never loop the recovery.
    private func observeCloudKitMirroringEvents() {
        let name = NSPersistentCloudKitContainer.eventChangedNotification
        cloudKitEventObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: container,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            guard let error = event.error as NSError? else { return }
            // The signature error we see on iPhone + watch is:
            //   NSCocoaErrorDomain Code=134421
            //   NSUnderlyingException = *** -[__NSSetM removeObject:]: object cannot be nil
            guard error.domain == NSCocoaErrorDomain, error.code == 134421 else { return }
            self.attemptHistoryRecoveryOnce()
        }
    }

    /// Drops everything from the persistent history table. Safe — no
    /// entity data is lost; we just lose the "what changed since last
    /// sync" log that CloudKit uses to compute deltas. The next sync
    /// will re-mirror from current state.
    ///
    /// Runs on a background context so the main thread never blocks
    /// on the SQLite write. Updates `attemptedHistoryRecovery` so we
    /// never loop the recovery within a single launch even if the
    /// error notification fires repeatedly.
    private func attemptHistoryRecoveryOnce() {
        guard !attemptedHistoryRecovery else { return }
        attemptedHistoryRecovery = true
        Self.log.error("CloudKit mirroring error 134421 (history analysis) — attempting truncate-history recovery")
        let ctx = newBackgroundContext()
        ctx.perform {
            let request = NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture)
            do {
                try ctx.execute(request)
                try ctx.save()
                Self.log.notice("CloudKit recovery: truncated persistent history OK — next launch should re-initialise sync")
            } catch {
                Self.log.error("CloudKit recovery FAILED: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Guardian sync reset (user-facing "last resort" action)

    /// Wipes cached `LocationRecord` + `DayArchive` rows in both the
    /// private and shared stores, then truncates the persistent
    /// history table. Preserves `MinorProfile` entries so pairings
    /// (CKShares the Guardian has accepted) survive — nuking them
    /// would force the user to re-invite every device from every
    /// Minor.
    ///
    /// Intended for the "Reset sync cache" button in Guardian
    /// Settings. When `NSPersistentCloudKitContainer` gets wedged
    /// (import queue stuck, records visible in the private zone but
    /// not the shared mirror, tokens out of sync with server state)
    /// the safest recovery short of reinstalling is to drop the
    /// local cache and let CloudKit re-import from the shared
    /// zones. That happens automatically on the next sync cycle
    /// after this method completes.
    ///
    /// Runs on a background context. Completion fires on the main
    /// queue with an optional error string so the caller can show
    /// a toast / alert.
    func resetGuardianSharedCache(completion: @escaping (_ error: String?) -> Void) {
        Self.log.notice("resetGuardianSharedCache: starting")
        let ctx = newBackgroundContext()
        ctx.perform {
            do {
                // Batch-delete each entity across both stores. Batch
                // deletes bypass the managed-object cache — cheap
                // even when there are tens of thousands of rows.
                for name in ["LocationRecord", "DayArchive"] {
                    let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
                    let delete = NSBatchDeleteRequest(fetchRequest: request)
                    delete.resultType = .resultTypeCount
                    let result = try ctx.execute(delete) as? NSBatchDeleteResult
                    let count = (result?.result as? Int) ?? -1
                    Self.log.notice("resetGuardianSharedCache: batch-deleted \(count) \(name, privacy: .public) rows")
                }
                // Truncate persistent history so CloudKit's next sync
                // cycle bootstraps cleanly from current store state
                // rather than replaying stale change entries.
                let history = NSPersistentHistoryChangeRequest.deleteHistory(before: Date.distantFuture)
                try ctx.execute(history)
                try ctx.save()
                Self.log.notice("resetGuardianSharedCache: complete")
                DispatchQueue.main.async { completion(nil) }
            } catch {
                Self.log.error("resetGuardianSharedCache FAILED: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { completion(error.localizedDescription) }
            }
        }
    }
}

import CoreData
import CloudKit

/// Wraps `NSPersistentCloudKitContainer` with two stores so the same model is
/// mirrored against both the user's CloudKit private DB (where their own
/// recordings live) and the CloudKit shared DB (where records from minors that
/// have invited this device land).
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer
    private(set) var privateStore: NSPersistentStore?
    private(set) var sharedStore: NSPersistentStore?

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
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return ctx
    }
}

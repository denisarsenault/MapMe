import Foundation
import CloudKit

/// Subscribes the Guardian device to changes on the CloudKit shared DB so
/// silent push wakes the app whenever a paired Minor pushes new locations.
@MainActor
final class GuardianSyncService: ObservableObject {
    private let container: CKContainer
    private static let subscriptionID = "MapMe.guardianSharedDB"

    @Published var isSubscribed = false
    @Published var lastError: String?

    init(containerIdentifier: String = "iCloud.com.mapme.app") {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    func ensureSubscription() async {
        do {
            let database = container.sharedCloudDatabase
            if (try? await database.subscription(for: Self.subscriptionID)) != nil {
                applySubscribed(true)
                return
            }
            let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true   // silent push
            subscription.notificationInfo = info
            _ = try await database.save(subscription)
            applySubscribed(true)
            applyError(nil)
        } catch {
            applyError(error.localizedDescription)
        }
    }

    // MARK: - @Published mutations dispatched on main

    /// Combine's `objectWillChange` validates `Thread.isMainThread` at the
    /// moment of mutation. After an `await` in `ensureSubscription`, the
    /// runtime may resume on a cooperative thread that isn't yet flagged
    /// as main, even though we're on the @MainActor. Using
    /// `DispatchQueue.main.async` skips that race entirely — the assignment
    /// happens on the next main-runloop tick, where `Thread.isMainThread`
    /// is reliably `true`.
    private func applySubscribed(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isSubscribed = value
        }
    }

    private func applyError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = message
        }
    }
}

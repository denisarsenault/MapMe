import Foundation
import CoreData
import CloudKit
#if canImport(UIKit)
import UIKit
#endif
#if os(watchOS)
import WatchKit
#endif

/// Creates and accepts CloudKit shares for the minor's profile object.
/// The minor shares a single `MinorProfile` row; CoreData/CloudKit migrates
/// the row plus its related `LocationRecord`/`DayArchive` children into a
/// shared zone, and any newly inserted children referencing that profile
/// land in the same zone automatically.
@MainActor
final class SharingService: ObservableObject {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - Minor profile

    /// Returns the singleton `MinorProfile` for this device, creating one on
    /// first call. The profile lives in the private store and becomes the
    /// root of the share once `makeShare` is called.
    @discardableResult
    func ensureMinorProfile(displayName: String? = nil) -> MinorProfile {
        let ctx = persistence.container.viewContext
        let deviceID = DeviceID.current

        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        // One profile per *physical device*, not per iCloud account. Without
        // this filter, the watch would adopt the iPhone's profile (or vice
        // versa) and the Guardian would only ever see one tracked device.
        request.predicate = NSPredicate(format: "deviceIdentifier == %@", deviceID)
        request.fetchLimit = 1
        // Look in the private store only — a Guardian-side accepted share
        // also creates a mirrored MinorProfile in the shared store, and we
        // must never confuse the two.
        if let privateStore = persistence.privateStore {
            request.affectedStores = [privateStore]
        }
        if let existing = try? ctx.fetch(request).first { return existing }

        let p = MinorProfile(context: ctx)
        // Pin to the private store BEFORE we set any attributes so the row
        // can never end up in the shared mirror by accident.
        if let privateStore = persistence.privateStore {
            ctx.assign(p, to: privateStore)
        }
        p.id = UUID()
        p.createdAt = Date()
        p.displayName = displayName ?? DeviceID.displayName
        p.deviceIdentifier = deviceID
        // Self-grant consent on creation so the device starts recording its
        // own history immediately — without this, every `LocationRecord` is
        // silently dropped at the consent gate in `LocationService.persist`
        // (or `WatchLocationService.persist`) until a Guardian explicitly
        // grants. Once a Guardian has accepted a CKShare and wants to
        // assert parental control, they can revoke from the Mac/iPad
        // dashboard; the consent observer reacts in real time and pauses
        // tracking.
        p.consentGrantedAt = Date()
        try? ctx.save()
        return p
    }

    private static func defaultDeviceName() -> String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(watchOS)
        return WKInterfaceDevice.current().name
        #else
        return "Device"
        #endif
    }

    private static func defaultDeviceIdentifier() -> String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        #elseif os(macOS)
        return Host.current().name ?? "unknown"
        #elseif os(watchOS)
        // `Host` is macOS-only; the watch's vendor identifier is fine here.
        return WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "unknown"
        #else
        return "unknown"
        #endif
    }

    // MARK: - Share creation (Minor)

    /// Creates (or returns the existing) CKShare for `profile`. The returned
    /// values are ready to hand to a `UICloudSharingController` so the user
    /// can pick a delivery channel (Messages, Mail, etc.).
    func makeShare(for profile: MinorProfile) async throws -> (CKShare, CKContainer) {
        let (_, share, ckContainer) = try await persistence.container.share([profile], to: nil)
        share[CKShare.SystemFieldKey.title] = "MapMe – \(profile.displayName ?? "Minor")" as CKRecordValue
        share.publicPermission = .none
        return (share, ckContainer)
    }

    /// Variant of `makeShare(for:)` that waits for iCloud to populate
    /// `share.url`. The plain `makeShare` returns as soon as the share is
    /// saved; on slower networks the URL can take a few hundred ms to
    /// appear, which matters on watchOS where we hand it straight to a
    /// `ShareLink` rather than presenting a `UICloudSharingController`.
    func makeShareAndAwaitURL(
        for profile: MinorProfile,
        timeout: TimeInterval = 10
    ) async throws -> (CKShare, CKContainer, URL) {
        let (share, container) = try await makeShare(for: profile)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let url = share.url {
                return (share, container, url)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw NSError(
            domain: "MapMe.Share",
            code: 100,
            userInfo: [NSLocalizedDescriptionKey: "iCloud didn't return a share URL in time. Try again."]
        )
    }

    /// Stops sharing this profile with all participants.
    func stopSharing(_ profile: MinorProfile) async throws {
        guard let share = try persistence.container.fetchShares(matching: [profile.objectID])[profile.objectID] else { return }
        try await persistence.container.purgeObjectsAndRecordsInZone(with: share.recordID.zoneID, in: nil)
    }

    /// Removes a `MinorProfile` from the local view.
    ///
    /// Behaviour depends on which store owns the row:
    /// - **Shared store** (Guardian side, accepted via `CKShare`): the
    ///   share's record zone is purged locally, which calls Apple's
    ///   "leave share" path. The Minor's data is preserved on their
    ///   device; the Guardian simply stops receiving updates.
    /// - **Private store** (Minor's own row): the share is torn down (if
    ///   one was issued), and the profile + its records are removed
    ///   locally. CloudKit syncs the deletion across the Minor's devices.
    func removeProfile(_ profile: MinorProfile) async throws {
        let shares = try persistence.container.fetchShares(matching: [profile.objectID])
        if let share = shares[profile.objectID] {
            // For both Guardian and Minor sides, purging the zone is the
            // correct call: a participant leaves the share, the owner
            // tears it down. The framework picks the right behaviour
            // based on who's making the call.
            _ = try await persistence.container.purgeObjectsAndRecordsInZone(
                with: share.recordID.zoneID,
                in: nil
            )
        } else {
            // No share yet — just remove the local row. Capture the
            // `objectID` (Sendable) instead of the `MinorProfile`
            // (not Sendable) so the `@Sendable` `ctx.perform` closure
            // compiles under Swift 6 strict concurrency. Re-resolve the
            // managed object on the context's queue inside the closure.
            let objectID = profile.objectID
            let ctx = profile.managedObjectContext ?? persistence.container.viewContext
            await ctx.perform {
                if let row = try? ctx.existingObject(with: objectID) {
                    ctx.delete(row)
                    try? ctx.save()
                }
            }
        }
    }

    // MARK: - Share acceptance (Guardian)

    /// Called from the `UIApplicationDelegate` /
    /// `NSApplicationDelegate` callback when iOS hands us a share invitation.
    func acceptShare(metadata: CKShare.Metadata) async throws {
        try await persistence.container.acceptShareInvitations(
            from: [metadata],
            into: persistence.sharedStore!
        )
    }
}

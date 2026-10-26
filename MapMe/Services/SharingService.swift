import Foundation
import CoreData
import CloudKit
import os
#if canImport(UIKit)
import UIKit
#endif
#if os(watchOS)
import WatchKit
#endif

/// Filter Console.app to `subsystem: com.mybrightzone.app category:
/// sharing` to see the share-creation path. Complements the
/// higher-level `pairing` category owned by `PairingView`.
private let shareLog = Logger(subsystem: "com.mybrightzone.app", category: "sharing")

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
        // Preflight — a "share hangs forever" symptom is almost always
        // one of these, so log them explicitly before we call the
        // NSPersistentCloudKitContainer path (which can block in ways
        // that produce no diagnostic on their own).
        shareLog.notice("makeShare preflight: checking iCloud account status")
        let container = CKContainer(identifier: "iCloud.com.mapme.app")
        let status: CKAccountStatus = await withCheckedContinuation { cont in
            container.accountStatus { s, err in
                if let err {
                    shareLog.error("accountStatus error: \(err.localizedDescription, privacy: .public)")
                }
                cont.resume(returning: s)
            }
        }
        shareLog.notice("iCloud accountStatus = \(String(describing: status))")
        switch status {
        case .available:
            break
        case .noAccount:
            throw NSError(
                domain: "MapMe.Sharing", code: 400,
                userInfo: [NSLocalizedDescriptionKey:
                    "No iCloud account is signed in on this device. Open Settings → [your name] and sign in."]
            )
        case .restricted:
            throw NSError(
                domain: "MapMe.Sharing", code: 401,
                userInfo: [NSLocalizedDescriptionKey:
                    "This device's iCloud account is restricted (Screen Time or parental controls). MapMe can't create a share until that's lifted."]
            )
        case .temporarilyUnavailable, .couldNotDetermine:
            throw NSError(
                domain: "MapMe.Sharing", code: 402,
                userInfo: [NSLocalizedDescriptionKey:
                    "iCloud is currently unreachable. Check your connection and try again in a moment."]
            )
        @unknown default:
            shareLog.error("Unknown accountStatus (\(status.rawValue)) — proceeding anyway")
        }

        // fetchShares FIRST. `NSPersistentCloudKitContainer.share([profile],
        // to: nil)` is documented as "returns the existing share if
        // there is one" but in practice — especially after a partial
        // 134421 recovery — it can hang forever if the mirroring
        // delegate is between states. `fetchShares` is a much lighter
        // synchronous read against the store and reveals whether a
        // share already exists for this profile.
        //
        // Runs off the main actor via GCD + a checked continuation.
        // `SharingService` is `@MainActor`, so a direct call would
        // inline the synchronous `fetchShares` onto the main thread.
        // When the persistent store coordinator is contended — most
        // commonly by a large CloudKit export draining an initial-
        // sync fan-out — the synchronous read parks the main thread
        // waiting for the coordinator lock, which freezes the entire
        // UI (touches drop, the pairing-status ticker starves, the
        // app looks dead). Hopping to a background queue means
        // coordinator contention parks a worker thread instead; the
        // main runloop stays responsive, and the `await` here
        // suspends this @MainActor context without holding it.
        // Both `pcContainer` and `objectID` are `Sendable`
        // (NSPersistentCloudKitContainer is thread-safe;
        // NSManagedObjectID is documented thread-safe once obtained).
        let objectID = profile.objectID
        let pcContainer = persistence.container
        let fetchResult: Result<[NSManagedObjectID: CKShare], Error>
        do {
            let value: [NSManagedObjectID: CKShare] = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try pcContainer.fetchShares(matching: [objectID])
                        cont.resume(returning: result)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            fetchResult = .success(value)
        } catch {
            fetchResult = .failure(error)
        }
        switch fetchResult {
        case .success(let existing):
            if let existingShare = existing[objectID] {
                shareLog.notice("fetchShares found existing share for profile — reusing (no CK call needed)")
                existingShare[CKShare.SystemFieldKey.title] = "MapMe – \(profile.displayName ?? "Minor")" as CKRecordValue
                existingShare.publicPermission = .readWrite
                return (existingShare, ckContainerForDefault())
            } else {
                shareLog.notice("fetchShares returned no existing share — proceeding to create")
            }
        case .failure(let error):
            shareLog.error("fetchShares threw: \(error.localizedDescription, privacy: .public) — proceeding to create anyway")
        }

        shareLog.notice("Calling NSPersistentCloudKitContainer.share([profile], to: nil)")
        let start = Date()
        let (_, share, ckContainer) = try await persistence.container.share([profile], to: nil)
        let elapsed = Date().timeIntervalSince(start)
        shareLog.notice("container.share returned after \(Int(elapsed * 1000)) ms")
        share[CKShare.SystemFieldKey.title] = "MapMe – \(profile.displayName ?? "Minor")" as CKRecordValue
        // `.readWrite`, not `.none`. The Guardian must be able to write
        // `consentGrantedAt` back into this shared profile — that's the whole
        // point of the consent gate. Most invites are delivered as a raw
        // CKShare URL (macOS link, watch → iPhone share sheet), and a link
        // recipient only inherits the share's *public* permission: with
        // `.none` they join read-only (or can't join), which silently breaks
        // "Grant consent" on the Guardian side. The invite URL itself is the
        // secret here — it's sent privately over Messages/Mail/AirDrop — so
        // link-based read-write is the intended model. The iOS
        // `UICloudSharingController` path additionally pins per-participant
        // read-write by omitting `.allowReadOnly` from its available
        // permissions (see `CloudShareSheet`), so no send path can produce a
        // read-only Guardian.
        share.publicPermission = .readWrite
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

    /// Removes every `MinorProfile` that has zero `LocationRecord`s.
    ///
    /// Fixes the "Guardian dashboard is cluttered with 5 duplicate
    /// profiles that all say 'No data yet'" scenario. Each
    /// re-invite from a Minor (uninstall + reinstall, or repeated
    /// tap of Invite Guardian after a `deviceIdentifier` change)
    /// creates a fresh `MinorProfile` in the shared zone; when the
    /// old one goes silent it just sits in the list forever.
    /// Manually swipe-deleting 5+ rows is tedious.
    ///
    /// Returns the number of profiles removed. Runs each removal
    /// through `removeProfile(_:)` so CKShares are torn down
    /// properly on the way out.
    @discardableResult
    func removeEmptyProfiles() async -> Int {
        let ctx = persistence.container.viewContext
        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        guard let all = try? ctx.fetch(request) else { return 0 }

        // "Empty" = zero location records. Count via SQLite index so
        // huge tracked profiles don't materialise rows just to check
        // if they have any.
        var toRemove: [MinorProfile] = []
        for profile in all {
            let count = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
            count.predicate = NSPredicate(format: "profile == %@", profile)
            let n = (try? ctx.count(for: count)) ?? 0
            if n == 0 { toRemove.append(profile) }
        }

        var removed = 0
        for profile in toRemove {
            do {
                try await removeProfile(profile)
                removed += 1
            } catch {
                // Best-effort — one failed removal shouldn't stop
                // the rest. The user can retry.
            }
        }
        return removed
    }

    /// The container we use for all CloudKit operations. Kept as a
    /// helper so the `fetchShares`-reuse path can return the same
    /// CKContainer instance that the standard `share([...], to: nil)`
    /// path would have handed back.
    private func ckContainerForDefault() -> CKContainer {
        CKContainer(identifier: "iCloud.com.mapme.app")
    }

    // MARK: - Share acceptance (Guardian)

    /// Called from the `UIApplicationDelegate` /
    /// `NSApplicationDelegate` callback when iOS hands us a share
    /// invitation.
    ///
    /// Cold-launch races used to crash here — iOS calls
    /// `userDidAcceptCloudKitShareWith:` the moment the app starts
    /// (before `loadPersistentStores` has called its callback), so
    /// `persistence.sharedStore` was nil and the force-unwrap
    /// terminated the app silently. From the Guardian's perspective,
    /// tapping the invite link did nothing. We now `await` the
    /// shared store to become available before importing, and throw
    /// a descriptive error if the wait times out so the caller can
    /// surface it instead of swallowing.
    func acceptShare(metadata: CKShare.Metadata) async throws {
        let ready = await persistence.waitForSharedStore()
        guard ready, let sharedStore = persistence.sharedStore else {
            throw NSError(
                domain: "MapMe.Sharing",
                code: 200,
                userInfo: [NSLocalizedDescriptionKey:
                    "MapMe's shared CloudKit store didn't finish loading in time. Reopen MapMe and tap the invite link again."]
            )
        }
        try await persistence.container.acceptShareInvitations(
            from: [metadata],
            into: sharedStore
        )
    }
}

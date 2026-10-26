#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
import Foundation
import CoreData
import Combine
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if os(watchOS)
import WatchKit
#endif

/// Family-wide register of every device that has ever launched MapMe
/// under this iCloud account.
///
/// The record lives in the **private** CloudKit database so every
/// device signed into the same iCloud sees the same trust list —
/// exactly what we want for "trusted device management" across the
/// user's own hardware. Guardians see rows via the CKShare mirror
/// on the shared store (a MinorProfile's owner shares the record
/// hierarchy so the Guardian's dashboard can display the paired
/// devices too — that piece lands in the approval-flow build).
///
/// This service handles:
///   - Auto-registering the current device on every launch (idempotent —
///     one row per `deviceIdentifier`).
///   - Refreshing `lastActiveAt` so the "last seen" column in the UI
///     stays honest.
///   - Listing all trusted devices (bounded fetch).
///   - Revoking a device (soft-delete via `revokedAt`; the row stays
///     so audit trail is preserved).
///
/// Not yet handled (deferred to later builds):
///   - Approval gate: for now, every new device is implicitly
///     approved. Build 11 will insert new devices with
///     `approvedAt == nil` and require an existing device to accept.
///   - Passkey registration: build 12.
///   - App Attest key registration + verification: build 13.
@MainActor
final class TrustedDeviceService: ObservableObject {
    static let shared = TrustedDeviceService()

    nonisolated private static let log = Logger(
        subsystem: "com.mybrightzone.app",
        category: "trusted-device"
    )

    private let persistence: PersistenceController
    /// `@Published` so the Trusted Devices view re-renders when a
    /// remote-change notification imports a new row from CloudKit.
    @Published private(set) var trustedDevices: [TrustedDevice] = []

    private var remoteChangeObserver: NSObjectProtocol?

    private init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        // Fresh reload on every remote-change so a new device joining
        // the family from an iPad shows up in this device's Settings
        // list within seconds — no manual refresh.
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let t = remoteChangeObserver {
            NotificationCenter.default.removeObserver(t)
        }
    }

    // MARK: - Public API

    /// Insert-or-update the current device's TrustedDevice row.
    ///
    /// Idempotent — safe to call on every launch. If a row already
    /// exists with this `deviceIdentifier`, we just refresh
    /// `lastActiveAt` (and any drift-corrected fields like display
    /// name after the user renames their iPhone). If not, we insert
    /// a new row and set `firstSeenAt = now`.
    func registerCurrentDevice() {
        let ctx = persistence.newBackgroundContext()
        let now = Date()
        let deviceID = DeviceID.current
        let name = DeviceID.displayName
        let platform = Self.platformString
        let model = Self.modelString

        ctx.perform { [weak self] in
            let request = NSFetchRequest<TrustedDevice>(entityName: "TrustedDevice")
            request.predicate = NSPredicate(format: "deviceIdentifier == %@", deviceID)
            request.fetchLimit = 1
            // Look only in the private store — the shared store's
            // mirror will contain rows from OTHER family members'
            // devices, and we don't want to accidentally update one
            // of those with this device's info.
            if let privateStore = self?.persistence.privateStore {
                request.affectedStores = [privateStore]
            }

            if let existing = try? ctx.fetch(request).first {
                existing.lastActiveAt = now
                // Refresh display name in case the user renamed the
                // device in System Settings. Model + platform don't
                // change per device so we don't rewrite those.
                if existing.displayName != name { existing.displayName = name }
            } else {
                let row = TrustedDevice(context: ctx)
                if let privateStore = self?.persistence.privateStore {
                    ctx.assign(row, to: privateStore)
                }
                row.id = UUID()
                row.deviceIdentifier = deviceID
                row.displayName = name
                row.model = model
                row.platform = platform
                row.firstSeenAt = now
                row.lastActiveAt = now
                // Auto-approve for now. Build 11 will change this to
                // `nil` and require an existing trusted device to
                // accept.
                row.approvedAt = now
                Self.log.notice("registered new trusted device: \(name, privacy: .public) [\(platform, privacy: .public)]")
            }
            try? ctx.save()

            Task { @MainActor in self?.reload() }
        }
    }

    /// Reloads the in-memory list from the view context. Cheap —
    /// bounded to 100 devices (nobody has more than that on their
    /// iCloud in practice; the count is a sanity net).
    func reload() {
        let ctx = persistence.container.viewContext
        let request = NSFetchRequest<TrustedDevice>(entityName: "TrustedDevice")
        request.sortDescriptors = [
            NSSortDescriptor(key: "revokedAt", ascending: true),        // active first
            NSSortDescriptor(key: "lastActiveAt", ascending: false),
        ]
        request.fetchLimit = 100
        trustedDevices = (try? ctx.fetch(request)) ?? []
    }

    /// Marks a trusted device as revoked. Soft-delete so the audit
    /// trail (first-seen, last-active) survives — Guardian can see
    /// "iPad was revoked 3 days ago" instead of the row vanishing.
    func revoke(_ device: TrustedDevice) {
        let objectID = device.objectID
        let ctx = persistence.newBackgroundContext()
        ctx.perform { [weak self] in
            guard let bg = try? ctx.existingObject(with: objectID) as? TrustedDevice else { return }
            bg.revokedAt = Date()
            try? ctx.save()
            Task { @MainActor in self?.reload() }
        }
    }

    /// Un-revoke a previously-revoked device. Used from the
    /// Settings UI's "restore" action if the Guardian accidentally
    /// revoked a device they meant to keep.
    func restore(_ device: TrustedDevice) {
        let objectID = device.objectID
        let ctx = persistence.newBackgroundContext()
        ctx.perform { [weak self] in
            guard let bg = try? ctx.existingObject(with: objectID) as? TrustedDevice else { return }
            bg.revokedAt = nil
            bg.lastActiveAt = Date()
            try? ctx.save()
            Task { @MainActor in self?.reload() }
        }
    }

    /// True when the current device's TrustedDevice row exists and
    /// is not revoked. Callers gate destructive/user-facing actions
    /// on this before Build 11's approval flow lands.
    var isCurrentDeviceTrusted: Bool {
        trustedDevices.contains {
            $0.deviceIdentifier == DeviceID.current && $0.revokedAt == nil
        }
    }

    // MARK: - Platform strings

    /// Compact platform tag ("iPhone", "iPad", "Mac", "Apple Watch",
    /// "Apple TV") for the display list. `nonisolated` static so the
    /// registration path can compute it off-main.
    nonisolated static var platformString: String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #elseif os(macOS)
        return "Mac"
        #elseif os(tvOS)
        return "Apple TV"
        #elseif os(watchOS)
        return "Apple Watch"
        #else
        return "Device"
        #endif
    }

    /// Best-effort model string. Fine to be approximate — this is
    /// for the user's own eye in the Trusted Devices list, not for
    /// any programmatic decisions.
    nonisolated static var modelString: String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.model
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(watchOS)
        return WKInterfaceDevice.current().model
        #else
        return "Unknown"
        #endif
    }
}
#endif

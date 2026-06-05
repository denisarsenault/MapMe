import Foundation
import CoreLocation

/// Lightweight bridge between the watch app and the watch widget extension.
///
/// **Why a plist file rather than `UserDefaults(suiteName:)`?**
/// On modern watchOS, `UserDefaults(suiteName:)` for an App Group container
/// defaults to `kCFPreferencesAnyUser`, which the OS now restricts to
/// system containers. Third-party apps that try it get this on every read:
///
///     Couldn't read values in CFPrefsPlistSource… Using kCFPreferencesAnyUser
///     with a container is only allowed for System Containers, detaching from
///     cfprefsd
///
/// Even with a valid App Group entitlement and provisioning profile, cfprefsd
/// refuses to mount the container. Reading/writing a plist file directly
/// inside the App Group's container directory sidesteps cfprefsd entirely —
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` is
/// the supported, supported-since-iOS-8 way to share data between apps in a
/// group.
enum WatchSharedState {
    static let appGroupID = "group.com.mybrightzone.shared"

    /// Path to the shared state plist inside the App Group container.
    /// `nil` if the entitlement isn't actually applied — in that case
    /// reads and writes silently no-op (preferable to the cfprefsd noise).
    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("MapMeWatchState.plist")
    }

    /// Serial queue so concurrent writes inside the watch app process can't
    /// race. Cross-process safety (watch app vs. widget extension) relies on
    /// `Data.write(to:options:.atomic)` and the fact that the widget never
    /// writes — only reads.
    private static let queue = DispatchQueue(label: "com.mybrightzone.MapMe.SharedState")

    // MARK: - Writes (watch app only)

    static func writeFix(_ location: CLLocation, isLive: Bool) {
        let previous = readSnapshot()
        let next = Snapshot(
            lastTimestamp: location.timestamp,
            lastLatitude: location.coordinate.latitude,
            lastLongitude: location.coordinate.longitude,
            isLive: isLive,
            consentGranted: previous.consentGranted,
            profileExists: previous.profileExists
        )
        write(next)
    }

    static func writeStatus(consentGranted: Bool, profileExists: Bool, isLive: Bool) {
        let previous = readSnapshot()
        let next = Snapshot(
            lastTimestamp: previous.lastTimestamp,
            lastLatitude: previous.lastLatitude,
            lastLongitude: previous.lastLongitude,
            isLive: isLive,
            consentGranted: consentGranted,
            profileExists: profileExists
        )
        write(next)
    }

    // MARK: - Read (both processes)

    static func readSnapshot() -> Snapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data)
        else {
            return .empty
        }
        return snapshot
    }

    // MARK: - Internal

    private static func write(_ snapshot: Snapshot) {
        guard let url = fileURL else { return }
        queue.async {
            guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    struct Snapshot: Codable, Equatable {
        let lastTimestamp: Date?
        let lastLatitude: Double?
        let lastLongitude: Double?
        let isLive: Bool
        let consentGranted: Bool
        let profileExists: Bool

        static let empty = Snapshot(
            lastTimestamp: nil,
            lastLatitude: nil,
            lastLongitude: nil,
            isLive: false,
            consentGranted: false,
            profileExists: false
        )
    }
}

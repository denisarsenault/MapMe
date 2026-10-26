#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import AppIntents
import CoreData
import CoreLocation
import os

/// `pet` / `device` MinorProfiles surfaced to the Shortcuts app as a
/// picker in `LogTrackerLocationIntent`. Filters out `.person` profiles
/// so the user isn't accidentally routing a pet's tracker updates
/// into their kid's location trail.
struct TrackerEntity: AppEntity {
    let id: String
    let name: String
    let kindLabel: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Tracker")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(kindLabel)")
    }

    static var defaultQuery = TrackerQuery()
}

/// Backing query — hands the Shortcuts app the current list of
/// non-person profiles from the private CloudKit store. Uses the
/// existing `PersistenceController.shared` so the intent extension
/// hits the same store the app writes to.
struct TrackerQuery: EntityQuery {
    func entities(for identifiers: [TrackerEntity.ID]) async throws -> [TrackerEntity] {
        return await allTrackers().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TrackerEntity] {
        return await allTrackers()
    }

    @MainActor
    private func allTrackers() async -> [TrackerEntity] {
        let ctx = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        request.sortDescriptors = [NSSortDescriptor(key: "displayName", ascending: true)]
        // No `kindRaw != nil` predicate — the fetch scans in memory and
        // filters via the typed `kind` accessor so nil (legacy = .person)
        // gets excluded correctly. Profile lists are tiny (single-digit
        // to low-double-digit), so the in-memory filter is fine.
        let all = (try? ctx.fetch(request)) ?? []
        return all.compactMap { profile -> TrackerEntity? in
            guard profile.kind != .person else { return nil }
            let idString = profile.objectID.uriRepresentation().absoluteString
            return TrackerEntity(
                id: idString,
                name: profile.displayName ?? "Unnamed tracker",
                kindLabel: profile.kind.label
            )
        }
    }
}

/// The Shortcuts action third-party tracker apps (Tractive, Fi,
/// Pebblebee, etc.) call — either directly through their own
/// Shortcut integration or via a user-authored Shortcut that stitches
/// their "get location" output into this action's input.
///
/// Writes a single `LocationRecord` on a background Core Data context
/// so the Shortcuts app returns immediately instead of blocking on
/// CloudKit's export queue.
struct LogTrackerLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Log tracker location"
    static var description: IntentDescription = IntentDescription(
        "Records a location fix for a MapMe tracker (pet or third-party device). Wire this into a Shortcut driven by your tracker's app to feed its fixes onto the MapMe map."
    )

    @Parameter(title: "Tracker")
    var tracker: TrackerEntity

    @Parameter(title: "Latitude")
    var latitude: Double

    @Parameter(title: "Longitude")
    var longitude: Double

    /// Timestamp of the fix. Optional — when the caller doesn't have
    /// one (e.g. "current location" style shortcuts) we stamp now.
    @Parameter(title: "Timestamp",
               description: "Time of the fix. Defaults to now if omitted.")
    var timestamp: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$tracker) at \(\.$latitude), \(\.$longitude)")
    }

    private static let log = Logger(subsystem: "com.mybrightzone.app",
                                    category: "tracker-intent")

    @MainActor
    func perform() async throws -> some IntentResult {
        // Resolve the tracker's Core Data URI back to a live object.
        // If it can't be found (deleted between listing and execution),
        // throw a helpful error the Shortcuts UI can surface.
        let viewCtx = PersistenceController.shared.container.viewContext
        guard let url = URL(string: tracker.id),
              let coord = viewCtx.persistentStoreCoordinator,
              let objectID = coord.managedObjectID(forURIRepresentation: url),
              let profile = try? viewCtx.existingObject(with: objectID) as? MinorProfile
        else {
            Self.log.error("Tracker not found: \(tracker.id, privacy: .public)")
            throw IntentError.trackerMissing
        }

        // Write on a background context so the Shortcuts host isn't
        // held on a viewContext save (which under CloudKit push can
        // legitimately take a few seconds).
        let bg = PersistenceController.shared.newBackgroundContext()
        let profileID = profile.objectID
        let capturedTimestamp = timestamp ?? Date()
        let capturedLat = latitude
        let capturedLon = longitude

        try await bg.perform {
            guard let bgProfile = try? bg.existingObject(with: profileID) as? MinorProfile else {
                throw IntentError.trackerMissing
            }
            let record = LocationRecord(context: bg)
            // Pin to the private store so tracker fixes stay on this
            // Guardian's device rather than fanning into shared zones
            // meant for consented Minors.
            if let privateStore = PersistenceController.shared.privateStore {
                bg.assign(record, to: privateStore)
            }
            record.id = UUID()
            record.timestamp = capturedTimestamp
            record.latitude = capturedLat
            record.longitude = capturedLon
            record.horizontalAccuracy = 50   // typical vendor tracker resolution
            record.verticalAccuracy = -1
            record.speed = -1
            record.course = -1
            record.altitude = 0
            record.deviceName = bgProfile.displayName
            record.deviceIdentifier = bgProfile.deviceIdentifier ?? "tracker-\(bgProfile.objectID.uriRepresentation().absoluteString)"
            record.profile = bgProfile
            try bg.save()
        }

        Self.log.notice("Logged tracker fix for \(self.tracker.name, privacy: .public)")
        return .result()
    }
}

enum IntentError: Error, LocalizedError {
    case trackerMissing

    var errorDescription: String? {
        switch self {
        case .trackerMissing:
            return "That tracker isn't set up in MapMe anymore. Open the app and re-add it."
        }
    }
}

// MARK: - Guardian Siri intents (all platforms that have MapMe)
//
// These are read-only against Core Data — safe to run on tvOS where
// the Minor-side tracking intents (below) don't apply. `MinorProfileEntity`
// is the Siri-visible handle for a paired device the Guardian can
// ask about ("Where is Denis' iPhone?").

/// One paired MinorProfile as seen by Siri. Filters out `.person`-kind
/// (or leaves them in — see `MinorProfileQuery.suggestedEntities()`)
/// so the Shortcuts app / Siri picker shows every paired device the
/// Guardian can ask about.
struct MinorProfileEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Device")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = MinorProfileQuery()
}

/// Feeds the Siri picker with the Guardian's currently paired
/// MinorProfiles. `nonisolated`-safe because we route the Core Data
/// touch through `@MainActor` — the AppIntents runtime dispatches
/// `entities(matching:)` on its own executor.
struct MinorProfileQuery: EntityQuery {
    @MainActor
    private func fetchProfiles(matching ids: [String]?) -> [MinorProfileEntity] {
        let ctx = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        let profiles = (try? ctx.fetch(request)) ?? []
        let all = profiles.map { p -> MinorProfileEntity in
            let uri = p.objectID.uriRepresentation().absoluteString
            return MinorProfileEntity(id: uri, name: p.displayName ?? "Device")
        }
        guard let ids else { return all }
        return all.filter { ids.contains($0.id) }
    }

    @MainActor
    func entities(for identifiers: [MinorProfileEntity.ID]) async throws -> [MinorProfileEntity] {
        fetchProfiles(matching: identifiers)
    }

    @MainActor
    func suggestedEntities() async throws -> [MinorProfileEntity] {
        fetchProfiles(matching: nil)
    }
}

/// "Hey Siri, where is Jake's iPhone?" — returns the latest known
/// coordinate + human relative age. Available on every platform
/// that has Guardian dashboards.
struct WhereIsIntent: AppIntent {
    static var title: LocalizedStringResource = "Where is device"
    static var description: IntentDescription = IntentDescription(
        "Returns the last known location and time for a paired MapMe device."
    )

    @Parameter(title: "Device")
    var target: MinorProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Where is \(\.$target)?")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let ctx = PersistenceController.shared.container.viewContext
        guard let url = URL(string: target.id),
              let objectID = ctx.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
              let profile = try? ctx.existingObject(with: objectID) as? MinorProfile
        else {
            return .result(value: "Not found",
                           dialog: "That device isn't paired in MapMe.")
        }
        let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        request.predicate = NSPredicate(format: "profile == %@", profile)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 1
        guard let latest = try? ctx.fetch(request).first, let ts = latest.timestamp else {
            let name = profile.displayName ?? "That device"
            return .result(value: "No fixes",
                           dialog: "\(name) hasn't reported a location yet.")
        }
        let age = relativeAge(from: ts)
        let name = profile.displayName ?? "The device"
        let coord = String(format: "%.5f, %.5f", latest.latitude, latest.longitude)
        return .result(
            value: coord,
            dialog: "\(name) was at \(coord), \(age)."
        )
    }
}

/// "Hey Siri, when did MapMe last see Jake's iPhone?" — a lighter
/// variant of `WhereIsIntent` that returns just the freshness.
struct WhenLastSeenIntent: AppIntent {
    static var title: LocalizedStringResource = "When last seen"
    static var description: IntentDescription = IntentDescription(
        "Returns how long ago MapMe last received a location for a paired device."
    )

    @Parameter(title: "Device")
    var target: MinorProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("When did MapMe last see \(\.$target)?")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ctx = PersistenceController.shared.container.viewContext
        guard let url = URL(string: target.id),
              let objectID = ctx.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
              let profile = try? ctx.existingObject(with: objectID) as? MinorProfile
        else {
            return .result(dialog: "That device isn't paired in MapMe.")
        }
        let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        request.predicate = NSPredicate(format: "profile == %@", profile)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 1
        let name = profile.displayName ?? "That device"
        guard let latest = try? ctx.fetch(request).first, let ts = latest.timestamp else {
            return .result(dialog: "\(name) hasn't reported a location yet.")
        }
        return .result(dialog: "\(name) was last seen \(relativeAge(from: ts)).")
    }
}

/// Compact relative age string shared by the Guardian intents.
/// Not localised for now — Siri reads it verbatim, and the phrasing
/// ("just now", "5 minutes ago", "2 hours ago") is picked for
/// natural-sounding TTS.
private func relativeAge(from date: Date) -> String {
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 60 { return "just now" }
    if elapsed < 3600 {
        let m = Int(elapsed / 60)
        return m == 1 ? "1 minute ago" : "\(m) minutes ago"
    }
    if elapsed < 86400 {
        let h = Int(elapsed / 3600)
        return h == 1 ? "1 hour ago" : "\(h) hours ago"
    }
    let d = Int(elapsed / 86400)
    return d == 1 ? "1 day ago" : "\(d) days ago"
}

// MARK: - Minor-side Siri intents (iOS + macOS only)
//
// tvOS never self-tracks (Guardian-only surface), so these intents
// live behind an iOS/macOS gate. `LocationService.shared` is the
// same singleton the app's SwiftUI graph observes, so the "Start"
// / "Stop" state flips through to the UI live.

#if os(iOS) || os(macOS)

/// "Hey Siri, start MapMe tracking."
struct StartTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start tracking"
    static var description: IntentDescription = IntentDescription(
        "Turns MapMe location tracking on."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = LocationService.shared
        service.requestAuthorization()
        service.startTracking()
        if service.isTracking {
            return .result(dialog: "MapMe is tracking your location.")
        }
        // Auth not yet granted, or tracking blocked (consent pending).
        return .result(dialog: "MapMe couldn't start tracking. Open the app to grant permission.")
    }
}

/// "Hey Siri, stop MapMe tracking."
struct StopTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop tracking"
    static var description: IntentDescription = IntentDescription(
        "Pauses MapMe location tracking."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        LocationService.shared.stopTracking()
        return .result(dialog: "MapMe tracking stopped.")
    }
}

/// "Hey Siri, is MapMe tracking?"
struct TrackingStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Tracking status"
    static var description: IntentDescription = IntentDescription(
        "Returns whether MapMe is currently recording your location."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let on = LocationService.shared.isTracking
        return .result(value: on,
                       dialog: on
                            ? "Yes, MapMe is tracking."
                            : "No, MapMe tracking is off.")
    }
}

#endif // iOS || macOS

/// Ships the intents to the Shortcuts app on first launch. Without
/// this AppShortcuts registration, actions still work from manually
/// built Shortcuts, but don't appear in the "MapMe Actions" section
/// of the Shortcuts gallery or as suggested phrases when the user
/// says "Hey Siri" without knowing the exact command.
///
/// Guardian intents ship on every platform; the Minor-side tracking
/// intents are gated to iOS/macOS since tvOS never self-tracks.
struct MapMeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhereIsIntent(),
            phrases: [
                "Where is \(\.$target) in \(.applicationName)",
                "Show me \(\.$target) in \(.applicationName)",
                "Ask \(.applicationName) where \(\.$target) is",
            ],
            shortTitle: "Where is a device",
            systemImageName: "location.magnifyingglass"
        )
        AppShortcut(
            intent: WhenLastSeenIntent(),
            phrases: [
                "When did \(.applicationName) last see \(\.$target)",
                "Last update for \(\.$target) in \(.applicationName)",
            ],
            shortTitle: "When last seen",
            systemImageName: "clock.arrow.circlepath"
        )
        #if os(iOS) || os(macOS)
        AppShortcut(
            intent: StartTrackingIntent(),
            phrases: [
                "Start tracking in \(.applicationName)",
                "Start \(.applicationName)",
                "Turn on \(.applicationName)",
            ],
            shortTitle: "Start tracking",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: StopTrackingIntent(),
            phrases: [
                "Stop tracking in \(.applicationName)",
                "Stop \(.applicationName)",
                "Turn off \(.applicationName)",
            ],
            shortTitle: "Stop tracking",
            systemImageName: "location.slash.fill"
        )
        AppShortcut(
            intent: TrackingStatusIntent(),
            phrases: [
                "Is \(.applicationName) tracking",
                "\(.applicationName) status",
            ],
            shortTitle: "Tracking status",
            systemImageName: "waveform.badge.magnifyingglass"
        )
        AppShortcut(
            intent: LogTrackerLocationIntent(),
            phrases: [
                "Log tracker location in \(.applicationName)",
                "Update tracker in \(.applicationName)",
            ],
            shortTitle: "Log tracker location",
            systemImageName: "pawprint.circle.fill"
        )
        #endif
    }
}
#endif

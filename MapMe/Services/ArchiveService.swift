import Foundation
import CoreData
import CoreLocation

/// Aggregates raw `LocationRecord` rows into per-day `DayArchive` summaries.
/// Runs once per launch (via `runArchivePassIfNeeded`) and from the daily
/// background-app-refresh task on iOS.
///
/// **Cross-store discipline.** With the `private` + `shared` mirror setup in
/// `PersistenceController`, this service operates *only* on records the user
/// owns (the private store). Shared records arriving via accepted `CKShare`s
/// belong to the originating Minor and are archived on their device, not
/// here — including them would create cross-store relationships that
/// CoreData refuses to save.
final class ArchiveService {
    private let context: NSManagedObjectContext
    private let privateStore: NSPersistentStore?
    private static let kLastRunKey = "MapMe.lastArchiveRun"

    /// `LocationRecord` rows older than this are hard-deleted after
    /// they've been summarized into a `DayArchive`. The summary
    /// (recordCount, distanceMeters, min/max lat/long) survives — only
    /// the per-fix detail is dropped.
    ///
    /// **Why this exists:** `NSPersistentCloudKitContainer` mirrors the
    /// *entire* private CloudKit zone. Because the iPhone, iPad, watch,
    /// and Mac all share the same iCloud account, every device pulls
    /// every other device's `LocationRecord`s on initial sync — even
    /// though the UI filters them out via `deviceIdentifier ==
    /// DeviceID.current`. Without a TTL the zone grows unbounded and
    /// the watch's first-launch import logs the 30+ s
    /// "CoreData: CloudKit Import" background-task warning, risking
    /// termination if the user backgrounds the app mid-sync.
    ///
    /// 14 days keeps two weeks of full per-fix history (plenty for the
    /// Guardian to scroll back in `DayDetailView`) and rolls older days
    /// down to summary-only. `DayDetailView` renders a "Summary only"
    /// banner when an archive's `records` set is empty but
    /// `recordCount > 0` so the user knows the detail was pruned, not
    /// missing.
    static let retentionDays: Int = 14

    init(context: NSManagedObjectContext,
         privateStore: NSPersistentStore? = PersistenceController.shared.privateStore) {
        self.context = context
        self.privateStore = privateStore
    }

    func runArchivePassIfNeeded(force: Bool = false) {
        if !force, let last = UserDefaults.standard.object(forKey: Self.kLastRunKey) as? Date,
           Date().timeIntervalSince(last) < 6 * 3600 {
            return
        }
        runArchivePass()
        UserDefaults.standard.set(Date(), forKey: Self.kLastRunKey)
    }

    func runArchivePass() {
        context.performAndWait {
            // ── 1. Archive: roll new days into DayArchive summaries ─────
            let cutoff = Calendar.current.startOfDay(for: Date())
            let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
            // Each device archives only the records it produced. This avoids
            // the iPhone "stealing" the watch's records into iPhone-owned
            // DayArchives (and vice versa) once both devices write to their
            // own per-device MinorProfile.
            request.predicate = NSPredicate(
                format: "archive == nil AND timestamp < %@ AND profile.deviceIdentifier == %@",
                cutoff as NSDate, DeviceID.current
            )
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            if let privateStore { request.affectedStores = [privateStore] }

            let records = (try? context.fetch(request)) ?? []
            if !records.isEmpty {
                let grouped = Dictionary(grouping: records) {
                    Calendar.current.startOfDay(for: $0.timestamp ?? .distantPast)
                }
                for (day, dayRecords) in grouped {
                    let archive = upsertArchive(for: day)
                    attach(records: dayRecords, to: archive)
                    summarize(archive: archive, records: dayRecords)
                }
            }

            // ── 2. Prune: hard-delete per-fix detail past retentionDays ─
            //
            // Only records that have already been summarized into a
            // DayArchive are eligible — never touch fresh fixes that
            // haven't been rolled up yet. Scoped to THIS device's
            // records so the watch doesn't try to prune the iPhone's
            // history (CloudKit would propagate that delete back and
            // we'd lose the iPhone's data — definitely not what we
            // want). The deletions go through the regular context
            // (not NSBatchDeleteRequest) so CloudKit mirroring picks
            // them up and propagates the removal to other devices on
            // this iCloud account.
            let pruneCutoff = Calendar.current.date(
                byAdding: .day,
                value: -Self.retentionDays,
                to: Date()
            ) ?? Date.distantPast
            let pruneRequest = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
            pruneRequest.predicate = NSPredicate(
                format: "archive != nil AND timestamp < %@ AND profile.deviceIdentifier == %@",
                pruneCutoff as NSDate, DeviceID.current
            )
            if let privateStore { pruneRequest.affectedStores = [privateStore] }
            let toPrune = (try? context.fetch(pruneRequest)) ?? []
            for record in toPrune {
                context.delete(record)
            }
            #if DEBUG
            if !toPrune.isEmpty {
                print("ArchiveService pruned \(toPrune.count) LocationRecord row(s) older than \(Self.retentionDays) days")
            }
            #endif

            // Nothing changed → skip the save (avoids a no-op CloudKit push).
            guard !records.isEmpty || !toPrune.isEmpty else { return }

            do {
                try context.save()
            } catch {
                #if DEBUG
                print("ArchiveService save failed: \(error)")
                #endif
            }
        }
    }

    private func upsertArchive(for day: Date) -> DayArchive {
        // Each (day, device) pair gets its own DayArchive — the watch and
        // iPhone produce separate summaries for the same day, since they
        // attach to separate MinorProfiles in the Guardian's family list.
        let request = NSFetchRequest<DayArchive>(entityName: "DayArchive")
        request.predicate = NSPredicate(
            format: "date == %@ AND profile.deviceIdentifier == %@",
            day as NSDate, DeviceID.current
        )
        request.fetchLimit = 1
        if let privateStore { request.affectedStores = [privateStore] }
        if let existing = try? context.fetch(request).first {
            return existing
        }
        let archive = DayArchive(context: context)
        // Pin the new archive to the private store so it never ends up in
        // the shared mirror (which would make the relationship cross-store).
        if let privateStore {
            context.assign(archive, to: privateStore)
        }
        archive.id = UUID()
        archive.date = day

        // Link the archive to THIS device's MinorProfile so it rides the
        // correct CKShare into the Guardian's shared zone.
        let profileRequest = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        profileRequest.predicate = NSPredicate(
            format: "deviceIdentifier == %@", DeviceID.current
        )
        profileRequest.fetchLimit = 1
        if let privateStore { profileRequest.affectedStores = [privateStore] }
        if let profile = try? context.fetch(profileRequest).first {
            archive.profile = profile
        }
        return archive
    }

    private func attach(records: [LocationRecord], to archive: DayArchive) {
        for r in records { r.archive = archive }
    }

    private func summarize(archive: DayArchive, records: [LocationRecord]) {
        let lats = records.map(\.latitude)
        let lons = records.map(\.longitude)
        archive.minLatitude = lats.min() ?? 0
        archive.maxLatitude = lats.max() ?? 0
        archive.minLongitude = lons.min() ?? 0
        archive.maxLongitude = lons.max() ?? 0
        archive.recordCount = Int32(records.count)
        archive.distanceMeters = totalDistance(records)
    }

    private func totalDistance(_ records: [LocationRecord]) -> Double {
        guard records.count > 1 else { return 0 }
        var total: Double = 0
        var previous: CLLocation?
        for r in records {
            let loc = CLLocation(latitude: r.latitude, longitude: r.longitude)
            if let prev = previous {
                total += loc.distance(from: prev)
            }
            previous = loc
        }
        return total
    }
}

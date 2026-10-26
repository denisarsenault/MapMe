// This service is only used on iOS and macOS. tvOS lacks most of
// CLLocationManager's tracking API (`startUpdatingLocation`,
// `requestAlwaysAuthorization`, etc. are unavailable). watchOS supports
// CLLocationManager but with a different battery profile and lifecycle, so
// the watch target ships its own `WatchLocationService` that uses
// `WKExtendedRuntimeSession` and `WKApplicationRefreshBackgroundTask`.
#if os(iOS) || os(macOS)

import Foundation
import CoreLocation
@preconcurrency import CoreData
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class LocationService: NSObject, ObservableObject {
    /// Process-wide singleton so Siri AppIntents (which run in a
    /// short-lived background context and can't reach the SwiftUI
    /// @StateObject held by MapMeApp) can drive tracking too. The
    /// app root uses this same instance via
    /// `@StateObject private var location = LocationService.shared`
    /// so views observe the same object the intent path mutates.
    static let shared = LocationService()

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?
    @Published var isTracking: Bool = false
    @Published var trackingError: String?
    /// True when a `MinorProfile` exists but the Guardian has not yet written
    /// `consentGrantedAt`. Drives the "Waiting for approval" UI.
    @Published var consentRequired: Bool = false

    /// User-selected battery / accuracy tradeoff. Persisted in
    /// `UserDefaults`; changes apply to `CLLocationManager` immediately.
    @Published var powerProfile: PowerProfile {
        didSet {
            UserDefaults.standard.set(powerProfile.rawValue, forKey: Self.kPowerProfileKey)
            applyPowerProfile()
        }
    }
    private static let kPowerProfileKey = "MapMe.powerProfile"

    private let manager = CLLocationManager()
    private let persistence: PersistenceController
    private var writeContext: NSManagedObjectContext { persistence.newBackgroundContext() }

    private var lastWriteAt: Date?
    /// The last CL fix we actually accepted (post-filter). Used by
    /// the teleport guard in `persist` to compute implied speed
    /// against the *previous accepted* fix, not whatever raw CL
    /// happened to deliver in between.
    private var lastAcceptedLocation: CLLocation?
    /// Rolling window of recently accepted fixes. Used by the
    /// stationary-cluster suppressor. Capped at
    /// `stationaryClusterWindow` — appending pops the oldest.
    private var recentAcceptedFixes: [CLLocation] = []

    // MARK: - Batched writes
    //
    // Every accepted fix used to be its own `ctx.save()`, which under
    // `NSPersistentCloudKitContainer` triggered a fresh CloudKit export
    // op per save. Under continuous tracking (30 s cadence at
    // HighAccuracy) that produced enough export ops per minute to
    // overwhelm the CloudKit scheduler — the console filled with
    // "updateTaskRequest called for an already running/updated task"
    // warnings, exports queued faster than they could drain, and
    // eventually iOS jetsammed the app in the background as a
    // misbehaving process. Guardian devices then saw no new records
    // for hours.
    //
    // Batching collapses N accepted fixes into ONE save, which is ONE
    // CloudKit export op. At `writeBatchSize = 3` that's 3× less
    // scheduler pressure; combined with `Balanced`'s 90 s cadence
    // gate the sync queue drains comfortably.
    //
    // The buffer is also flushed on `willResignActive`, `stopTracking`,
    // and every `flushIntervalSeconds` so the worst-case data loss
    // if the app crashes between flushes is one batch (~90–270 s
    // depending on cadence) rather than an unbounded queue.
    private struct PendingWrite {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let speed: Double
        let course: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let deviceName: String
        let deviceId: String
    }
    private var pendingWrites: [PendingWrite] = []
    private static let writeBatchSize: Int = 3
    private static let flushIntervalSeconds: TimeInterval = 300
    private var flushTimer: Timer?

    // MARK: - Stationary heartbeat
    //
    // Guardian dashboards mark a device "offline" (grey dot) if no
    // fresh fix has arrived within `GuardianAudioAlertService`'s
    // 30-min freshness window. A device that's genuinely stationary
    // stops writing new fixes — the cluster + jitter filters
    // deliberately reject repeated fixes at the same spot, since
    // recording them adds no map information. That combination
    // meant "parked at desk for 45 min" read the same as
    // "vanished off the network" to the Guardian.
    //
    // Fix: while `isTracking` is true, a low-frequency timer emits
    // a fresh record every `heartbeatIntervalSeconds` using the
    // last-known coordinate, bypassing the location-quality
    // filters. Guardian's `lastFixAt` stays inside the online
    // window; the dot stays green as long as the device is truly
    // running. On watchOS the same pattern lives in
    // `WatchLocationService`.
    private static let heartbeatIntervalSeconds: TimeInterval = 15 * 60
    private var heartbeatTimer: Timer?

    /// Rate-limit on motion-triggered immediate flush. See watch
    /// twin for the rationale — unbounded per-fix flushing tripped
    /// `BGSystemTaskSchedulerErrorDomain Code=3`. 15 s spacing
    /// keeps CloudKit export ops around ~4/min at most.
    private static let motionFlushMinSpacing: TimeInterval = 15
    private var lastMotionFlushAt: Date?

    // MARK: - Fix-quality guards
    //
    // These reject obviously-bad CL fixes BEFORE the time coalescer
    // so a single bad fix can't burn a cadence slot. Bad fixes are
    // what produce the "zigzag scribble" pattern on the map when a
    // device is actually stationary — CL falls back to cell/Wi-Fi
    // positioning indoors, which can swing the reported coordinate by
    // hundreds of metres between samples. Snap-to-roads then routes
    // walking paths between every pair of ghost fixes and the result
    // looks like the user was sprinting through buildings.

    /// Maximum acceptable horizontal accuracy in metres. Anything
    /// worse is cell-tower triangulation (typically 500–2000 m) with
    /// no GPS contribution — useless for trail rendering. Negative
    /// values are CL's "no position available" sentinel and are
    /// always rejected.
    ///
    /// Sizing rationale (was 100 m, broke standalone GPS):
    ///   - GPS, clear sky:                 5–15 m   ✓
    ///   - GPS + cell/Wi-Fi (urban):      20–80 m   ✓
    ///   - Standalone GPS (Apple Watch
    ///     without iPhone, indoor/foliage
    ///     obstruction, first cold fix): 150–300 m  ← we want these
    ///   - Cell-tower triangulation only: 500+ m    ✗
    ///
    /// 100 m sat *inside* the "legitimate but obstructed pure-GPS"
    /// band and silently dropped tracking on devices without
    /// Wi-Fi/cell help. 300 m keeps the cell-tower-only garbage out
    /// while letting standalone GPS through.
    private static let maxHorizontalAccuracyMeters: CLLocationDistance = 300

    /// Maximum age of a CL fix before we treat it as stale. CL
    /// sometimes delivers cached samples from minutes ago when the
    /// app wakes from background; persisting those would create
    /// false history. 30 s is generous enough for normal CL latency
    /// but tight enough to catch wake-from-suspend cache hits.
    private static let maxFixStalenessSeconds: TimeInterval = 30

    /// Implied speed (km/h) above which a fix is treated as a
    /// teleport — typically a stale cached fix at the start of a
    /// session, or a sudden cell-tower reassignment. Highway is
    /// ~120 km/h, aircraft ~900 km/h; 250 catches teleports without
    /// rejecting fast commuter rail or planes.
    private static let maxRealisticSpeedKmh: Double = 250

    /// Reported speed (km/h) below which the device is treated as
    /// "essentially stationary" for the purposes of the jitter
    /// filter. Tightened to 0.5 km/h because CL routinely reports
    /// 0 speed when the device is actually moving at parking-lot
    /// crawl pace (3–8 km/h) — at low velocity the doppler-based
    /// speed estimate is unreliable. The previous 1 km/h threshold
    /// caused real parking-lot movement to be filtered as drift.
    private static let stationarySpeedKmh: Double = 0.5

    /// Minimum displacement floor (metres) for the jitter filter.
    /// Reduced from 15 m to 8 m so legitimate slow movement
    /// (walking around a building, driving through a parking lot)
    /// isn't rejected as drift. 8 m is still wider than the
    /// 3–5 m drift pattern of a *truly* stationary good-fix
    /// device, so the zigzag-on-the-desk case stays filtered.
    /// For genuinely noisy fixes the floor widens automatically
    /// to the fix's own `horizontalAccuracy`.
    private static let stationaryJitterFloorMeters: CLLocationDistance = 8

    /// Displacement (m) above which the cadence gate is bypassed.
    /// Slow movement that takes longer than the cadence interval
    /// (parking lots at .balanced's 90 s cadence, pedestrian
    /// shortcuts at .battery's 5 min cadence) would otherwise
    /// lose every intermediate fix to coalescing — the trail
    /// looks like teleportation between two fixed waypoints, or
    /// disappears entirely if the slow leg is short. 25 m is
    /// well above stationary jitter noise but tight enough that a
    /// 30 s drive through a Starbucks lot produces 3-5 writes
    /// instead of 0-1.
    private static let cadenceBypassMeters: CLLocationDistance = 25

    /// Cluster-suppression radius (m). When the new fix is within this
    /// distance of the centroid of the last few accepted fixes AND we
    /// aren't clearly moving fast, treat it as more of the same rest
    /// cluster and reject. This is what catches the "watch on desk,
    /// GPS jitters 10–20 m every write" case without breaking slow
    /// legitimate movement — walking / driving progresses the
    /// centroid, so real moves keep exiting the cluster.
    private static let stationaryClusterRadiusMeters: CLLocationDistance = 25
    /// Size of the rolling window used to compute the cluster centroid.
    /// Enough recent fixes to average out one bad sample; small enough
    /// that a real walk moves the centroid within a couple of writes.
    private static let stationaryClusterWindow: Int = 5

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        // Load profile from UserDefaults; default to .balanced.
        let stored = UserDefaults.standard.string(forKey: Self.kPowerProfileKey)
        self.powerProfile = stored.flatMap(PowerProfile.init(rawValue:)) ?? .balanced
        super.init()
        manager.delegate = self
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.activityType = .otherNavigation
        #endif
        applyPowerProfile()
        // Don't read `manager.authorizationStatus` synchronously on the main
        // thread — iOS 17+ flags this as a UI-responsiveness hazard. The
        // CLLocationManagerDelegate fires `locationManagerDidChangeAuthorization`
        // immediately after the manager comes up, which populates the state
        // on the next run-loop tick.

        // React to Guardian-side consent changes that arrive via CloudKit.
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConsentAndApply() }
        }
        // Also react to local saves (e.g. same-device testing, or the
        // Guardian writing into the shared store on this same device).
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConsentAndApply() }
        }
        // Seed initial state so `consentRequired` is correct at first launch.
        refreshConsentAndApply()

        #if os(iOS)
        // Drain the pending-write buffer when the app is about to
        // resign active — user is backgrounding, locking the phone,
        // or an interruption is coming (call, alarm). Without this,
        // fixes we accepted just before the transition would sit in
        // memory until the next batch trigger and could be lost if
        // iOS suspends + terminates before the batch fills.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flushPendingWrites() }
        }
        #endif

        #if os(iOS)
        // Motion watchdog: if tracking was ever stopped (backgrounded
        // over the OS suspend threshold, a subsystem crash, user
        // manually stopped from the widget) but the user then starts
        // moving, promote back to tracking automatically. This
        // realises the "Live in the background as the device moves"
        // requirement without needing the user to reopen the app.
        //
        // macOS is a Guardian role with no meaningful motion signal
        // to react to, so this is iOS-only.
        Task { @MainActor [weak self] in
            guard let self else { return }
            MotionActivityMonitor.shared.start()
            self.motionCancellable = MotionActivityMonitor.shared.$isMoving
                .receive(on: DispatchQueue.main)
                .sink { [weak self] moving in
                    guard let self, moving, !self.isTracking else { return }
                    self.startTracking()
                }
        }
        #endif
    }

    #if os(iOS)
    /// Retained subscription to `MotionActivityMonitor.isMoving`.
    /// Nilling it would stop the auto-restart, so we hold it for the
    /// lifetime of the service singleton. iOS-only because Core
    /// Motion isn't relevant on macOS.
    private var motionCancellable: AnyCancellable?
    #endif

    /// Applies the current `powerProfile` to the `CLLocationManager`. Called
    /// at init and whenever the user picks a new profile in Settings.
    /// If we're mid-tracking, also restarts the appropriate update mode
    /// (continuous vs SLC-only) so the change takes effect immediately.
    private func applyPowerProfile() {
        manager.desiredAccuracy = powerProfile.desiredAccuracy
        manager.distanceFilter = powerProfile.distanceFilter
        manager.pausesLocationUpdatesAutomatically = powerProfile.pausesLocationUpdatesAutomatically

        guard isTracking else { return }
        if powerProfile.usesContinuousUpdates {
            manager.startUpdatingLocation()
        } else {
            // Battery mode: stop the GPS stream and rely on the SLC + visit
            // wakeups that are already running from `startTracking()`.
            manager.stopUpdatingLocation()
        }
    }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Called when CoreData is updated remotely (Guardian grants/revokes
    /// consent), so the Minor app reacts to the change without restart.
    func refreshConsentAndApply() {
        let granted = isConsentGranted()
        let exists = profileExists()
        consentRequired = exists && !granted
        if !granted, isTracking {
            stopTracking()
        } else if granted, !isTracking {
            // Auto-start when consent is freshly granted. Safe to call even
            // when not yet authorized — `startTracking` will gate itself.
            startTracking()
        }
    }

    func startTracking() {
        // Skip `CLLocationManager.locationServicesEnabled()` — iOS 17+
        // flags that static call as a UI-responsiveness hazard. If services
        // are disabled system-wide we'll see `.denied`/`.restricted` here
        // (or `didFailWithError` from the manager), both of which already
        // surface through `trackingError`.
        // Don't try to start without authorization — the user must grant first.
        // The auth-change delegate will call us back once they do.
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            return
        }

        // Ensure this device has a MinorProfile so its records have
        // a parent to attach to. Without this, `persist()` writes
        // records with `record.profile = nil`, they sit in the
        // private store detached from any CKShare hierarchy, and
        // the device never appears in Guardian's family list —
        // even though tracking is technically running. Mac users
        // hit this most because they typically click Start Tracking
        // without ever going through the Invite Guardian flow that
        // used to be the only path to `ensureMinorProfile()`.
        // Idempotent: no-op when a profile already exists for this
        // device's `deviceIdentifier`.
        _ = SharingService(persistence: persistence).ensureMinorProfile()

        // Block tracking until a paired Guardian has written consent.
        if profileExists(), !isConsentGranted() {
            consentRequired = true
            trackingError = nil
            return
        }
        consentRequired = false
        // Continuous GPS only when the profile asks for it. Battery mode
        // skips it entirely and stays on SLC + visits.
        if powerProfile.usesContinuousUpdates {
            manager.startUpdatingLocation()
        }
        #if os(iOS)
        // SLC + visits run regardless of profile — they're the cheap
        // wakeup channel that lets the app catch large movements even
        // while suspended.
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()
        #endif
        isTracking = true
        trackingError = nil
        armHeartbeatTimer()
        #if os(iOS)
        LaunchReminderService.setTrackingActive(true)
        #endif
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        #endif
        isTracking = false
        #if os(iOS)
        LaunchReminderService.setTrackingActive(false)
        #endif
        cancelHeartbeatTimer()
        // Drain anything still buffered so a stop-and-relaunch
        // cycle doesn't lose the tail of the previous session.
        flushPendingWrites()
        cancelFlushTimer()
    }

    private func persist(_ location: CLLocation) {
        // ── 1. Reject obviously-bad fixes ──────────────────────────
        //
        // Done BEFORE the time coalescer so a bad fix can't burn a
        // cadence slot — otherwise a single ghost fix at minute zero
        // means we wait another 90 s (Balanced) for the next real
        // one. These three guards catch the dominant noise sources:
        //
        //   - horizontalAccuracy < 0:    CL "no position" sentinel.
        //   - horizontalAccuracy > 100m: cell/Wi-Fi triangulation, the
        //                                source of indoor scribble.
        //   - stale fix (> 30 s old):    cached sample from before
        //                                the app woke; not "now".
        let now = Date()
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maxHorizontalAccuracyMeters,
              now.timeIntervalSince(location.timestamp) <= Self.maxFixStalenessSeconds
        else {
            return
        }

        // Teleport guard: implied speed from the previous accepted
        // fix > 250 km/h means CL handed us a stale cache or a
        // wildly wrong cell-tower position. Drop it. We compare
        // against `lastAcceptedLocation` (post-filter) so a chain
        // of bad fixes can't keep poisoning the reference point.
        if let last = lastAcceptedLocation {
            let distance = location.distance(from: last)
            let dt = max(1, location.timestamp.timeIntervalSince(last.timestamp))
            let implied = (distance / 1000) / (dt / 3600)
            if implied > Self.maxRealisticSpeedKmh {
                return
            }
        }

        // ── 2. Coalesce writes ─────────────────────────────────────
        //
        // Two cadences are available:
        //   1. PowerProfile fixed cadence (battery=300 s,
        //      balanced=90 s, highAccuracy=30 s). Always-on default.
        //   2. AdaptiveSamplingConfig speed-driven cadence — when
        //      enabled in Settings, the minimum interval depends on
        //      the current speed band (Stationary/Walking/Running/
        //      Vehicle). Lets a kid in a car write every 15 s while
        //      a kid in class writes every 5 min, all on the same
        //      physical device.
        // CL reports speed in m/s; -1 means "unavailable" so clamp.
        let speedKmh = max(0, location.speed) * 3.6
        let adaptive = AdaptiveSamplingConfig.shared
        let minInterval = adaptive.isEnabled
            ? adaptive.interval(forSpeedKmh: speedKmh)
            : powerProfile.minimumWriteIntervalSeconds

        // Distance-based cadence bypass. If the device has moved
        // farther than `cadenceBypassMeters` since the last accepted
        // fix, write this one even though the cadence interval
        // hasn't elapsed. Without the bypass, a 30 s parking-lot
        // crawl at .balanced (90 s cadence) produces 0–1 fixes and
        // the trail looks like teleportation between waypoints.
        let displacementSinceLastAccept = lastAcceptedLocation
            .map { location.distance(from: $0) } ?? .infinity
        let bypassCadence = displacementSinceLastAccept >= Self.cadenceBypassMeters

        if !bypassCadence,
           let last = lastWriteAt,
           now.timeIntervalSince(last) < minInterval {
            return
        }

        // ── 3. Stationary jitter filter ────────────────────────────
        //
        // Past the cadence check, so we'd normally write this fix.
        // But a "perfect" CL fix from a stationary device still
        // drifts 5–10 m between samples — that drift is exactly
        // what becomes the zigzag scribble on the map once
        // snap-to-roads routes walking paths between each pair of
        // ghost positions.
        //
        // Rule: if CL is reporting we're barely moving (< 1 km/h)
        // AND the displacement from the last accepted fix is
        // smaller than our noise tolerance, skip the write. We
        // *don't* update `lastWriteAt` here, so the next real
        // movement (or a fix that genuinely exits the noise ring)
        // can still write immediately rather than waiting for the
        // next cadence tick. Net effect: a device sitting on a
        // desk for an hour produces ONE record at the location,
        // not 40 of them in a small zigzag.
        if let last = lastAcceptedLocation {
            let distance = location.distance(from: last)
            let tolerance = max(Self.stationaryJitterFloorMeters,
                                location.horizontalAccuracy)
            if speedKmh < Self.stationarySpeedKmh, distance < tolerance {
                return
            }
        }

        // ── 4. Stationary cluster suppression ──────────────────────
        //
        // Catches the case the pair-wise jitter filter above misses:
        // a stationary device whose fixes drift 15–25 m each write.
        // Each new fix is >8 m from the previous accepted fix (passes
        // jitter check) but still just orbiting the true resting
        // location. Comparing to the CENTROID of the last few writes
        // exposes that orbit — a genuinely stationary GPS trail
        // produces a tight cluster the centroid parks in the middle
        // of, so a new fix within `stationaryClusterRadiusMeters` of
        // that centroid is more noise, not new movement.
        //
        // We only apply this when CL is reporting we're barely
        // moving — so a slow walk that happens to double back
        // through the same street still records.
        if speedKmh < Self.stationarySpeedKmh,
           let centroid = clusterCentroid(),
           location.distance(from: centroid) < Self.stationaryClusterRadiusMeters {
            return
        }

        lastWriteAt = now
        lastAcceptedLocation = location
        appendToClusterWindow(location)

        // Buffer instead of writing immediately. See the PendingWrite
        // block near the top of this file for the CloudKit-scheduler
        // rationale. Real save happens in `flushPendingWrites()` when
        // the buffer hits `writeBatchSize`, the periodic timer fires,
        // the app resigns active, or tracking stops.
        pendingWrites.append(PendingWrite(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            speed: location.speed,
            course: location.course,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            deviceName: currentDeviceName(),
            deviceId: currentDeviceIdentifier()
        ))
        armFlushTimer()
        // Motion-triggered immediate flush, rate-limited. Every
        // moving fix used to flush right away and overwhelmed the
        // BGTaskScheduler quota; 15 s spacing keeps CloudKit
        // export ops manageable while preserving seconds-latency
        // Live updates for the Guardian.
        if speedKmh > Self.stationarySpeedKmh {
            let now = Date()
            let elapsed = lastMotionFlushAt.map { now.timeIntervalSince($0) } ?? .infinity
            if elapsed >= Self.motionFlushMinSpacing {
                lastMotionFlushAt = now
                flushPendingWrites()
            } else if pendingWrites.count >= Self.writeBatchSize {
                flushPendingWrites()
            }
        } else if pendingWrites.count >= Self.writeBatchSize {
            flushPendingWrites()
        }
    }

    // MARK: - Batched write flush

    /// Drains `pendingWrites` into a single Core Data save. Callers:
    ///
    /// - `persist()` when the buffer hits `writeBatchSize`
    /// - The periodic `flushTimer` (see `armFlushTimer()`)
    /// - `willResignActive` — user backgrounds the app / locks phone
    /// - `stopTracking()` — no more fixes coming, drain what's queued
    ///
    /// The profile fetch is done ONCE per flush (previously once per
    /// fix), and all records ride the same `ctx.save()`, so
    /// CloudKit's export queue sees one op per batch instead of one
    /// per fix.
    private func flushPendingWrites() {
        guard !pendingWrites.isEmpty else { return }
        let batch = pendingWrites
        pendingWrites.removeAll()

        let ctx = writeContext
        let privateStore = persistence.privateStore
        ctx.perform {
            let profileRequest = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
            profileRequest.predicate = NSPredicate(
                format: "deviceIdentifier == %@", DeviceID.current
            )
            profileRequest.fetchLimit = 1
            if let privateStore { profileRequest.affectedStores = [privateStore] }
            let profile = try? ctx.fetch(profileRequest).first
            if let profile, profile.consentGrantedAt == nil {
                return
            }

            for draft in batch {
                let record = LocationRecord(context: ctx)
                if let privateStore {
                    ctx.assign(record, to: privateStore)
                }
                record.id = UUID()
                record.timestamp = draft.timestamp
                record.latitude = draft.latitude
                record.longitude = draft.longitude
                record.altitude = draft.altitude
                record.speed = draft.speed
                record.course = draft.course
                record.horizontalAccuracy = draft.horizontalAccuracy
                record.verticalAccuracy = draft.verticalAccuracy
                record.deviceName = draft.deviceName
                record.deviceIdentifier = draft.deviceId
                if let profile {
                    record.profile = profile
                }
            }

            do {
                try ctx.save()
            } catch {
                #if DEBUG
                print("LocationService flush failed: \(error)")
                #endif
            }
        }
    }

    /// Schedules a periodic timer to drain the buffer even if fixes
    /// stop coming (e.g. device sits idle just under `writeBatchSize`
    /// pending writes). Idempotent — same-thread callers can invoke
    /// repeatedly without stacking timers.
    private func armFlushTimer() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushIntervalSeconds,
                                          repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushPendingWrites()
            }
        }
    }

    private func cancelFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    // MARK: - Heartbeat

    private func armHeartbeatTimer() {
        guard heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatIntervalSeconds,
                                              repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.writeHeartbeatIfIdle()
            }
        }
    }

    private func cancelHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Emits a synthetic record at the last-known coordinate,
    /// bypassing the quality / jitter / cluster filters that
    /// would otherwise reject repeated stationary fixes. Refreshes
    /// `lastWriteAt` and flushes any pending buffer so the
    /// Guardian's freshness clock resets.
    ///
    /// Skipped when:
    /// - tracking isn't running (nothing to heartbeat about)
    /// - we've never accepted a fix (no coordinate to write)
    /// - a real fix was written within the heartbeat interval
    ///   already (the batch flush covers us)
    private func writeHeartbeatIfIdle() {
        guard isTracking else { return }
        guard let last = lastAcceptedLocation else { return }
        if let lw = lastWriteAt,
           Date().timeIntervalSince(lw) < Self.heartbeatIntervalSeconds {
            return
        }
        pendingWrites.append(PendingWrite(
            timestamp: Date(),
            latitude: last.coordinate.latitude,
            longitude: last.coordinate.longitude,
            altitude: last.altitude,
            speed: 0,
            course: -1,
            horizontalAccuracy: last.horizontalAccuracy,
            verticalAccuracy: last.verticalAccuracy,
            deviceName: currentDeviceName(),
            deviceId: currentDeviceIdentifier()
        ))
        lastWriteAt = Date()
        flushPendingWrites()
    }

    private func fetchProfile() -> MinorProfile? {
        let ctx = persistence.container.viewContext
        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        request.fetchLimit = 1
        return try? ctx.fetch(request).first
    }

    private func profileExists() -> Bool { fetchProfile() != nil }

    private func isConsentGranted() -> Bool {
        guard let profile = fetchProfile() else { return true } // no pairing yet → no gate
        return profile.consentGrantedAt != nil
    }

    // MARK: - Stationary cluster helpers

    /// Centroid of the rolling window, or `nil` if we haven't
    /// accumulated at least 3 fixes yet — with too few samples the
    /// centroid is dominated by any single noisy fix and the check
    /// misfires in either direction.
    private func clusterCentroid() -> CLLocation? {
        guard recentAcceptedFixes.count >= 3 else { return nil }
        let n = Double(recentAcceptedFixes.count)
        let lat = recentAcceptedFixes.map(\.coordinate.latitude).reduce(0, +) / n
        let lon = recentAcceptedFixes.map(\.coordinate.longitude).reduce(0, +) / n
        return CLLocation(latitude: lat, longitude: lon)
    }

    /// Appends a fix and evicts the oldest when the window overflows.
    private func appendToClusterWindow(_ location: CLLocation) {
        recentAcceptedFixes.append(location)
        if recentAcceptedFixes.count > Self.stationaryClusterWindow {
            recentAcceptedFixes.removeFirst(recentAcceptedFixes.count - Self.stationaryClusterWindow)
        }
    }

    private func currentDeviceName() -> String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Device"
        #endif
    }

    private func currentDeviceIdentifier() -> String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        #else
        return Host.current().name ?? "unknown"
        #endif
    }
}

extension LocationService: CLLocationManagerDelegate {
    // NOTE: Using `DispatchQueue.main.async` (rather than
    // `Task { @MainActor in ... }`) for all delegate-driven @Published
    // mutations. Combine's objectWillChange validator checks
    // `Thread.isMainThread` at assignment time, and there's a window
    // where Task @MainActor closures fire willChange before the runtime
    // has updated that flag — producing the "Publishing changes from
    // background threads" warning under SWIFT_STRICT_CONCURRENCY: minimal.
    // DispatchQueue.main.async enqueues directly on the main thread.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                self.startTracking()
            case .denied, .restricted:
                self.trackingError = "Location access denied. Enable it in Settings to record history."
                self.isTracking = false
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastLocation = location
            self.persist(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `CLError.locationUnknown` (code 0) is transient — CL will keep
        // trying on its own. Per Apple, "don't disable the service when
        // you receive this error." Don't surface it to the UI; it just
        // shows up during normal acquisition lulls and looks like a bug.
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return
        }
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            self?.trackingError = message
        }
    }

    #if os(iOS)
    /// Visit monitoring: extremely low-power channel that reports
    /// arrivals and departures at notable locations. Critical to Battery
    /// mode — without continuous GPS, this is what fills in the gaps
    /// between SLC fires (~500 m granularity) with "they were at school
    /// from 8 to 3."
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // CLVisit carries its own coordinate + arrival/departure dates.
        // Persist the arrival as a synthetic LocationRecord; the existing
        // pipeline handles consent gating and CloudKit sharing.
        let location = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastLocation = location
            self.persist(location)
        }
    }
    #endif
}

#endif // os(iOS) || os(macOS)


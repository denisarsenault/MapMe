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
    /// filter. 1 km/h is slower than a slow walk; anything below
    /// it is rest-state CL noise rather than actual movement.
    private static let stationarySpeedKmh: Double = 1.0

    /// Minimum displacement floor (metres) for the jitter filter.
    /// Even with a "perfect" 3-metre accuracy fix, consecutive
    /// samples from a stationary device routinely drift 5–10 m
    /// — that drift is what produces the zigzag scribble on the
    /// map. We require at least 15 m of movement before counting
    /// it as real; for noisier fixes the threshold widens to the
    /// fix's own `horizontalAccuracy`.
    private static let stationaryJitterFloorMeters: CLLocationDistance = 15

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
    }

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
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        #endif
        isTracking = false
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
        if let last = lastWriteAt,
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

        lastWriteAt = now
        lastAcceptedLocation = location

        let deviceName = currentDeviceName()
        let deviceId = currentDeviceIdentifier()

        let ctx = writeContext
        let privateStore = persistence.privateStore
        ctx.perform {
            // Scope to the private store so we don't accidentally pull a
            // mirrored MinorProfile from the shared store of a Guardian-side
            // accepted share — that would trigger a cross-store relationship
            // on save. Also filter by THIS device's identifier so the iPhone
            // doesn't end up writing its records into the watch's profile
            // (or vice versa) once both devices have created their own.
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

            let record = LocationRecord(context: ctx)
            // Pin the new record to the private store before any relationship
            // assignment — otherwise CoreData may place it in the shared
            // store and the save will fail with NSCocoaError 134020.
            if let privateStore {
                ctx.assign(record, to: privateStore)
            }
            record.id = UUID()
            record.timestamp = location.timestamp
            record.latitude = location.coordinate.latitude
            record.longitude = location.coordinate.longitude
            record.altitude = location.altitude
            record.speed = location.speed
            record.course = location.course
            record.horizontalAccuracy = location.horizontalAccuracy
            record.verticalAccuracy = location.verticalAccuracy
            record.deviceName = deviceName
            record.deviceIdentifier = deviceId

            // Link to the MinorProfile so the record rides the same share
            // into the Guardian's shared CloudKit zone.
            if let profile {
                record.profile = profile
            }

            do {
                try ctx.save()
            } catch {
                #if DEBUG
                print("LocationService persist failed: \(error)")
                #endif
            }
        }
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


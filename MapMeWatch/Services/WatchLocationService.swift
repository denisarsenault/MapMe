import Foundation
import CoreLocation
import CoreData
import Combine
import WatchKit
import WidgetKit

/// Hybrid watchOS tracking:
///
/// 1. **Periodic background fetches** via `WKApplicationRefreshBackgroundTask`
///    (~every 15 min, scheduled by `WatchAppDelegate`). Each fire takes a
///    single fix with `requestLocation()` and saves it. Battery‑friendly,
///    works while the watch is on the wrist.
/// 2. **Live tracking sessions** via `WKExtendedRuntimeSession` started by the
///    user from `WatchLiveView`. Streams continuous updates for up to ~1 h.
///
/// Same consent gate as iOS: a `MinorProfile` with `consentGrantedAt == nil`
/// blocks all writes.
@MainActor
final class WatchLocationService: NSObject, ObservableObject {
    static let shared = WatchLocationService()

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?
    @Published var isLiveTracking: Bool = false
    @Published var trackingError: String?
    @Published var consentRequired: Bool = false

    /// User-selected battery / accuracy tradeoff, mirroring the iOS picker.
    /// Persisted in the same `UserDefaults` key so a paired iPhone-watch
    /// pair starts at consistent settings on first launch.
    ///
    /// On watchOS the profile drives:
    /// - CL accuracy + distance filter
    /// - Whether `startLiveTracking` is allowed (Battery saver only uses
    ///   the periodic `WKApplicationRefreshBackgroundTask` channel)
    /// - Whether expiring `WKExtendedRuntimeSession`s chain back-to-back
    ///   (only High accuracy chains)
    /// - Coalesce window for `LocationRecord` saves
    @Published var powerProfile: PowerProfile {
        didSet {
            UserDefaults.standard.set(powerProfile.rawValue, forKey: Self.kPowerProfileKey)
            applyPowerProfile()
        }
    }
    private static let kPowerProfileKey = "MapMe.powerProfile"

    private let manager = CLLocationManager()
    private let persistence: PersistenceController
    private var runtimeSession: WKExtendedRuntimeSession?
    private var oneShotCompletion: (() -> Void)?
    private var lastWriteAt: Date?
    /// Last CL fix we accepted (post-filter). Anchor for the
    /// teleport guard in `persist` — see the matching field +
    /// thresholds on iOS' `LocationService` for the rationale.
    private var lastAcceptedLocation: CLLocation?

    // MARK: - Fix-quality guards (mirror of iOS LocationService)

    /// Watch CL is *noisier* than iPhone CL — smaller antenna,
    /// frequent battery-saver mode, and (critically) the watch falls
    /// back to standalone GPS the moment the paired iPhone goes out
    /// of range. Standalone-GPS accuracy on the watch is routinely
    /// 150–300 m in obstructed conditions or right after a cold fix,
    /// so a tight 100 m cap silently killed tracking for any user
    /// whose watch left iPhone range. 300 m matches the iOS threshold
    /// and only excludes cell-tower-only fixes (which an Apple Watch
    /// can't generate anyway — there's no cell radio in non-cellular
    /// models, and the cellular models still use GPS as the primary
    /// source). See the matching comment on iOS' `LocationService`
    /// for the full accuracy band rationale.
    private static let maxHorizontalAccuracyMeters: CLLocationDistance = 300
    private static let maxFixStalenessSeconds: TimeInterval = 30
    private static let maxRealisticSpeedKmh: Double = 250
    /// Stationary jitter thresholds — see the matching constants on
    /// iOS' `LocationService`. Identical values so a paired phone /
    /// watch produce comparable trails when both are recording.
    private static let stationarySpeedKmh: Double = 1.0
    private static let stationaryJitterFloorMeters: CLLocationDistance = 15

    private init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        let stored = UserDefaults.standard.string(forKey: Self.kPowerProfileKey)
        self.powerProfile = stored.flatMap(PowerProfile.init(rawValue:)) ?? .balanced
        super.init()
        manager.delegate = self
        // Apply the loaded profile to the CL manager. `applyPowerProfile()`
        // handles accuracy + distanceFilter; we deliberately don't touch
        // `pausesLocationUpdatesAutomatically` here because it isn't
        // available on watchOS (the property is iOS/macOS-only).
        applyPowerProfile()
        // Don't set `allowsBackgroundLocationUpdates` here. On the watchOS
        // simulator, flipping this property during static-singleton init can
        // crash with EXC_BAD_ACCESS before the entitlement is fully wired
        // up. We toggle it on per-session inside `startLiveTracking()` and
        // reset it in `stopLiveTracking()`.
        //
        // Don't read `manager.authorizationStatus` synchronously on the
        // main thread either — watchOS 10+ flags it as a UI-responsiveness
        // hazard. The delegate's `locationManagerDidChangeAuthorization`
        // fires once the manager is ready and populates the published
        // value on the next run-loop tick.

        observeRemoteChanges()
        // Refresh + mirror are deferred to the next main-actor tick so we
        // don't call `WidgetCenter.shared.reloadTimelines` while the
        // singleton's `static let shared` is still running.
        Task { @MainActor [weak self] in
            self?.refreshConsentAndApply()
        }
    }

    // MARK: - Power profile

    /// Pushes the current `powerProfile` into the CL manager. Called at
    /// init and whenever the user picks a new profile in `WatchSettingsView`.
    private func applyPowerProfile() {
        manager.desiredAccuracy = powerProfile.desiredAccuracy
        manager.distanceFilter = powerProfile.distanceFilter
        // `pausesLocationUpdatesAutomatically` doesn't exist on watchOS,
        // so we can't honour that field here.
    }

    // MARK: - Authorisation

    func requestAuthorization() {
        // Read our `@Published` snapshot rather than `manager.authorizationStatus`
        // — the latter is flagged on watchOS 10+ as a UI-responsiveness
        // hazard when accessed on the main thread. The snapshot is kept up
        // to date by `locationManagerDidChangeAuthorization`.
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: - Background single-fix

    /// Called by the background app refresh task. Performs a single
    /// `requestLocation()` and invokes `completion` once a fix lands or
    /// fails. Always invokes `completion` exactly once.
    func performBackgroundLocationFetch(completion: @escaping () -> Void) {
        guard isAuthorized, isConsentGranted() else {
            completion()
            return
        }
        // Replace any pending one-shot.
        oneShotCompletion?()
        oneShotCompletion = completion
        manager.requestLocation()

        // Hard timeout — a stuck fix shouldn't keep the BG task alive.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            await MainActor.run {
                if let cb = self?.oneShotCompletion {
                    self?.oneShotCompletion = nil
                    cb()
                }
            }
        }
    }

    // MARK: - Live tracking (extended runtime)

    func startLiveTracking() {
        // Note: the old design refused Live tracking in Battery mode
        // (because Battery was SLC-only, with no continuous GPS). The
        // PowerProfile redesign keeps GPS on across every profile, so
        // Live tracking now works in any mode — Battery just samples
        // sparsely (500 m distance filter, 5-min coalesce). No guard
        // needed.
        // Skip `CLLocationManager.locationServicesEnabled()` — watchOS 10+
        // flags that static call as a UI-responsiveness hazard. If services
        // are disabled system-wide we'll get `.denied` here or a
        // `didFailWithError` from the manager, both of which are surfaced
        // through `trackingError`.
        guard isAuthorized else {
            requestAuthorization()
            return
        }
        if profileExists(), !isConsentGranted() {
            consentRequired = true
            trackingError = nil
            return
        }
        consentRequired = false
        if runtimeSession == nil {
            let session = WKExtendedRuntimeSession()
            session.delegate = self
            session.start()
            runtimeSession = session
        }
        // Enabling background updates here (rather than in init) is what
        // requires `UIBackgroundModes = [location]` in the watch plist.
        // CL asserts at this point if the plist key is missing.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isLiveTracking = true
        trackingError = nil
        mirrorStatusToAppGroup()
    }

    func stopLiveTracking() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        runtimeSession?.invalidate()
        runtimeSession = nil
        isLiveTracking = false
        mirrorStatusToAppGroup()
    }

    // MARK: - App Group mirror (drives the complication)

    /// Pushes the current tracking state into the App Group `UserDefaults`
    /// the widget reads, then asks WidgetKit to refresh timelines.
    private func mirrorStatusToAppGroup() {
        WatchSharedState.writeStatus(
            consentGranted: isConsentGranted(),
            profileExists: profileExists(),
            isLive: isLiveTracking
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "com.mapme.app.status")
    }

    // MARK: - Consent

    func refreshConsentAndApply() {
        let granted = isConsentGranted()
        let exists = profileExists()
        consentRequired = exists && !granted
        if !granted, isLiveTracking {
            stopLiveTracking()
        }
        mirrorStatusToAppGroup()
    }

    private func observeRemoteChanges() {
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConsentAndApply() }
        }
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConsentAndApply() }
        }
    }

    private func fetchProfile() -> MinorProfile? {
        let ctx = persistence.container.viewContext
        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        // Match the *watch's* profile, not whatever profile happens to have
        // sync'd in from the iPhone. This is what makes the watch a
        // separate entry in the Guardian's family list.
        request.predicate = NSPredicate(
            format: "deviceIdentifier == %@", DeviceID.current
        )
        request.fetchLimit = 1
        if let privateStore = persistence.privateStore {
            request.affectedStores = [privateStore]
        }
        return try? ctx.fetch(request).first
    }

    private func profileExists() -> Bool { fetchProfile() != nil }

    private func isConsentGranted() -> Bool {
        guard let profile = fetchProfile() else { return true }
        return profile.consentGrantedAt != nil
    }

    private var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    // MARK: - Persistence

    private func persist(_ location: CLLocation) {
        // ── 1. Reject obviously-bad fixes ──────────────────────────
        //
        // Mirrors the iOS LocationService — see the comments there
        // for the rationale. The watch is *more* prone to bad fixes
        // because its smaller antenna falls back to cell/Wi-Fi
        // positioning faster than the iPhone, so without these
        // guards a stationary watch produces a violent zigzag on
        // the map. Done before the coalescer so one bad fix can't
        // burn a cadence slot.
        let now = Date()
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maxHorizontalAccuracyMeters,
              now.timeIntervalSince(location.timestamp) <= Self.maxFixStalenessSeconds
        else {
            return
        }
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
        // Two cadences mirror the iOS service:
        //   1. PowerProfile fixed cadence — Battery/Balanced/HighAccuracy.
        //   2. AdaptiveSamplingConfig speed-driven cadence (opt-in in
        //      WatchSettingsView). Watch and iPhone keep independent
        //      UserDefaults so each device's knobs reflect its own
        //      role.
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
        // Mirrors the iOS LocationService. The watch is *more*
        // prone to stationary jitter than the iPhone because its
        // smaller antenna lets the position estimate drift further
        // between samples even with a "good" reported accuracy.
        // Without this, a watch on a wrist while the wearer sits
        // at a desk produces a tight zigzag scribble that snap-to-
        // roads then routes as fake walking detours through nearby
        // streets.
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

        let liveSnapshot = isLiveTracking
        let ctx = persistence.newBackgroundContext()
        let privateStore = persistence.privateStore
        ctx.perform {
            // Scope to the private store. Records arriving from accepted
            // CKShares live in the shared store and must not influence the
            // Minor's writes here. Also filter by THIS device's identifier
            // so the watch's records always attach to the watch's profile.
            let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
            request.predicate = NSPredicate(
                format: "deviceIdentifier == %@", DeviceID.current
            )
            request.fetchLimit = 1
            if let privateStore { request.affectedStores = [privateStore] }
            let profile = try? ctx.fetch(request).first
            if let profile, profile.consentGrantedAt == nil {
                return
            }

            let record = LocationRecord(context: ctx)
            // Pin to the private store before relationships are wired —
            // otherwise CoreData refuses the save with NSCocoaError 134020.
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
            record.deviceName = DeviceID.displayName
            record.deviceIdentifier = DeviceID.current
            if let profile { record.profile = profile }
            try? ctx.save()

            // Mirror the latest fix into the App Group so the complication
            // can render "Live · 3 m" without spinning up Core Data.
            WatchSharedState.writeFix(location, isLive: liveSnapshot)
            WidgetCenter.shared.reloadTimelines(ofKind: "com.mapme.app.status")
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WatchLocationService: CLLocationManagerDelegate {
    // NOTE: All three callbacks intentionally use `DispatchQueue.main.async`
    // rather than `Task { @MainActor in … }`. Combine's @Published machinery
    // uses `Thread.isMainThread` to validate `objectWillChange` calls; with
    // `SWIFT_STRICT_CONCURRENCY: minimal` there's a window where a Task
    // @MainActor closure can fire `objectWillChange` before the runtime has
    // updated `Thread.isMainThread`, producing the "Publishing changes from
    // background threads" warning. `DispatchQueue.main.async` enqueues
    // directly onto the main thread, which Combine sees correctly.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            self?.authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastLocation = location
            self.persist(location)
            if let cb = self.oneShotCompletion {
                self.oneShotCompletion = nil
                cb()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `CLError.locationUnknown` (code 0) is transient — CL will keep
        // trying on its own. Per Apple, "don't disable the service when
        // you receive this error." Surfacing it to the UI just confuses
        // the user during normal acquisition lulls (indoors, poor signal).
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return
        }
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trackingError = message
            if let cb = self.oneShotCompletion {
                self.oneShotCompletion = nil
                cb()
            }
        }
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension WatchLocationService: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { [weak self] in
            // The system warns ~1 min before expiration. Only High accuracy
            // chains a fresh session — Balanced lets the 1 h session expire
            // and stops; Battery saver doesn't reach this code path because
            // `startLiveTracking` refuses to start in that mode. If the
            // chained session can't start (CSLS denial, simulator), CL
            // keeps streaming via `allowsBackgroundLocationUpdates` until
            // the OS suspends us.
            guard let self,
                  self.powerProfile == .highAccuracy,
                  self.isLiveTracking,
                  self.isConsentGranted() else {
                return
            }
            let next = WKExtendedRuntimeSession()
            next.delegate = self
            next.start()
            self.runtimeSession = next
            self.mirrorStatusToAppGroup()
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        DispatchQueue.main.async { [weak self] in
            // Don't tear down location updates here. The runtime session is
            // a *bonus* on top of `allowsBackgroundLocationUpdates`; CSLS
            // denies sessions on the simulator and for unapproved categories
            // ("client not approved"), but CL itself keeps emitting fixes
            // for as long as the OS allows. Only drop the session reference
            // so we don't try to invalidate it again later.
            guard let self else { return }
            if self.runtimeSession === extendedRuntimeSession {
                self.runtimeSession = nil
            }
        }
    }
}

import Foundation
import CoreLocation
import CoreData
import Combine
import WatchKit
import WidgetKit
import HealthKit
import UserNotifications

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

    /// When on, MapMe arms a "tracking paused" local notification that fires
    /// if no fix is recorded for `Self.watchdogInterval`. Every successful
    /// fix pushes it forward, so it only ever delivers when tracking actually
    /// stops — most importantly after the watch runs out of power and is
    /// recharged, since watchOS won't relaunch the app on its own. Opt-in
    /// (default off): a watch left off-wrist on the charger can legitimately
    /// stop refreshing, which would otherwise alert at an unexpected time.
    @Published var pauseAlertEnabled: Bool {
        didSet {
            UserDefaults.standard.set(pauseAlertEnabled, forKey: Self.kPauseAlertKey)
            if pauseAlertEnabled {
                requestNotificationAuthorization()
                armTrackingWatchdog()
            } else {
                cancelTrackingWatchdog()
            }
        }
    }
    private static let kPauseAlertKey = "MapMe.pauseAlertEnabled"

    /// How long without a recorded fix before the "tracking paused" alert
    /// fires. 30 min is aggressive — it catches real outages quickly but
    /// can false-alert if watchOS defers a background refresh during a
    /// tight-battery window, or if the user takes the watch off for a
    /// workout that runs long. The toggle's footer in
    /// `WatchSettingsView` warns about the off-wrist case.
    private static let watchdogInterval: TimeInterval = 30 * 60
    private static let watchdogNotificationID = "com.mapme.tracking-watchdog"

    /// When on, `MotionActivityMonitor` transitions from stationary →
    /// moving (walking, running, cycling, automotive) automatically
    /// call `startLiveTracking()`. This is what the user meant by "when
    /// the device starts moving, MapMe should be running Live in the
    /// background" — without motion classification the app has no way
    /// to know movement started until CL happens to deliver a fix, and
    /// CL only delivers reliably when Live is *already* running.
    ///
    /// Default `true`: matches the requested behaviour. User can turn
    /// it off in `WatchSettingsView` if they want manual control only.
    @Published var autoStartOnMotion: Bool {
        didSet {
            UserDefaults.standard.set(autoStartOnMotion, forKey: Self.kAutoStartOnMotionKey)
            if autoStartOnMotion {
                MotionActivityMonitor.shared.start()
            }
        }
    }
    private static let kAutoStartOnMotionKey = "MapMe.autoStartOnMotion"

    /// Timestamp of the last "motion detected" transition. Used to
    /// gate the auto-stop side: we only auto-stop Live if the classifier
    /// has been reporting stationary continuously for
    /// `autoStopStationaryInterval` — a single stationary blip during
    /// a walk (traffic light, checking a shop window) shouldn't kill
    /// the workout session.
    private var lastMotionAt: Date?
    private static let autoStopStationaryInterval: TimeInterval = 5 * 60

    private var motionCancellable: AnyCancellable?

    private let manager = CLLocationManager()
    private let persistence: PersistenceController
    private let healthStore = HKHealthStore()
    /// Active `HKWorkoutSession` if Live tracking landed on the
    /// HealthKit path. Workout sessions on the watch get effectively
    /// unlimited runtime, which is the whole point of using them here
    /// — `WKExtendedRuntimeSession` caps out around ~1-3 hours total
    /// per day and Live tracking dies after that.
    private var workoutSession: HKWorkoutSession?
    /// The workout builder that goes with `workoutSession`. We don't
    /// actually collect any health samples, but the builder has to
    /// exist for the session to be valid; we end it without saving
    /// in `stopLiveTracking()`.
    private var workoutBuilder: HKLiveWorkoutBuilder?
    /// `WKExtendedRuntimeSession` fallback used only when HealthKit
    /// isn't authorised. This is the original Live-tracking channel —
    /// works for ~1-3 hours then the OS suspends us. Pre-existing
    /// users who haven't tapped Start Live since this change use this
    /// path until they grant Health permission.
    private var runtimeSession: WKExtendedRuntimeSession?
    private var oneShotCompletion: (() -> Void)?
    private var lastWriteAt: Date?
    /// Last CL fix we accepted (post-filter). Anchor for the
    /// teleport guard in `persist` — see the matching field +
    /// thresholds on iOS' `LocationService` for the rationale.
    private var lastAcceptedLocation: CLLocation?
    /// Rolling window of recently accepted fixes, used by the
    /// stationary cluster suppressor. Capped at
    /// `stationaryClusterWindow`.
    private var recentAcceptedFixes: [CLLocation] = []

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
    private static let stationarySpeedKmh: Double = 0.5
    private static let stationaryJitterFloorMeters: CLLocationDistance = 8
    /// Distance-based cadence bypass — see comment on the iOS twin.
    /// Without this, parking-lot crawls (<90 s through the lot) lose
    /// every intermediate fix to the cadence coalescer.
    private static let cadenceBypassMeters: CLLocationDistance = 25

    /// Stationary cluster suppressor — see iOS twin. Watch GPS jitter
    /// is typically worse than iPhone (smaller antenna, wrist
    /// obstruction), so this filter is what actually stops the
    /// scribble around a stationary rest location.
    private static let stationaryClusterRadiusMeters: CLLocationDistance = 25
    private static let stationaryClusterWindow: Int = 5

    private init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        let stored = UserDefaults.standard.string(forKey: Self.kPowerProfileKey)
        self.powerProfile = stored.flatMap(PowerProfile.init(rawValue:)) ?? .balanced
        self.pauseAlertEnabled = UserDefaults.standard.bool(forKey: Self.kPauseAlertKey)
        // Default `true` for auto-start on motion so the "MapMe should
        // be running Live when the device is moving" behaviour holds
        // out of the box. UserDefaults returns `false` for a missing
        // key, so seed a default the first launch.
        if UserDefaults.standard.object(forKey: Self.kAutoStartOnMotionKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.kAutoStartOnMotionKey)
        }
        self.autoStartOnMotion = UserDefaults.standard.bool(forKey: Self.kAutoStartOnMotionKey)
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
        // Wire the shared motion classifier. Even if the user has
        // `autoStartOnMotion` off, we let the monitor run so a later
        // toggle-on has fresh data. The subscription is guarded — we
        // only auto-start Live if the flag is true AND consent is
        // granted.
        Task { @MainActor [weak self] in
            guard let self else { return }
            MotionActivityMonitor.shared.start()
            self.motionCancellable = MotionActivityMonitor.shared.$isMoving
                .receive(on: DispatchQueue.main)
                .sink { [weak self] moving in
                    self?.handleMotionChange(moving: moving)
                }
        }
        // Refresh + mirror are deferred to the next main-actor tick so we
        // don't call `WidgetCenter.shared.reloadTimelines` while the
        // singleton's `static let shared` is still running.
        Task { @MainActor [weak self] in
            self?.refreshConsentAndApply()
        }
    }

    /// Reacts to a `MotionActivityMonitor.isMoving` transition. When
    /// the user starts moving and auto-start is enabled, this brings
    /// Live tracking up. When they stop moving for
    /// `autoStopStationaryInterval`, we tear the session down so a
    /// watch parked on a desk doesn't hold `HKWorkoutSession` open
    /// forever (burning battery + skewing daily activity metrics).
    private func handleMotionChange(moving: Bool) {
        guard autoStartOnMotion else { return }
        guard isAuthorized, isConsentGranted() else { return }
        if moving {
            lastMotionAt = Date()
            if !isLiveTracking { startLiveTracking() }
        } else {
            // Stationary. Debounce the auto-stop so a brief pause
            // doesn't tear down the workout session.
            let sinceLast = lastMotionAt.map { Date().timeIntervalSince($0) } ?? 0
            if isLiveTracking, sinceLast >= Self.autoStopStationaryInterval {
                stopLiveTracking()
            }
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

    // MARK: - Live tracking (HealthKit workout session, with runtime-session fallback)

    /// Starts Live tracking. Tries to host the session as an
    /// `HKWorkoutSession` (effectively unlimited runtime on the
    /// watch). If HealthKit isn't authorised yet, requests it; if the
    /// user denies or HealthKit is unavailable, falls back to the
    /// classic `WKExtendedRuntimeSession` (1-3 hour ceiling).
    ///
    /// **Why a workout session?** `WKExtendedRuntimeSession` chains
    /// only ~2-4 hours of total runtime per day before the OS refuses
    /// to start a new one and silently suspends the app —
    /// observed in the field by users who left Start Live on while
    /// the watch was on their wrist for a full afternoon.
    /// `HKWorkoutSession` is the API Apple actually intends for
    /// hours-long GPS sessions, and it has no equivalent budget cap
    /// for the duration of the session.
    ///
    /// We use `.other` activity type because MapMe isn't a fitness
    /// app — we don't want to credit fake exercise minutes against
    /// the user's Activity rings. The workout sample is discarded on
    /// stop (`discardWorkout()`), so nothing lands in the Health app.
    func startLiveTracking() {
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

        // Bring up the host session (workout or runtime) FIRST so the
        // app has runtime budget before we start streaming CL fixes.
        // Both paths mark `isLiveTracking = true` and call
        // `beginStreaming()`.
        if HKHealthStore.isHealthDataAvailable() {
            // Ask for an *empty* share/read set — `HKWorkoutSession`
            // requires authorization to have happened, but we don't
            // actually want any types. An empty share set is treated
            // as "no access requested," which is exactly right since
            // we never read or write samples.
            healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                             read: []) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startWorkoutSession()
                    } else {
                        self.startRuntimeSessionFallback()
                    }
                }
            }
        } else {
            // No HealthKit on this device (shouldn't happen on a
            // modern Apple Watch, but the simulator can land here).
            startRuntimeSessionFallback()
        }
    }

    /// HealthKit-backed path. Creates an `HKWorkoutSession` of
    /// `.other` activity type, attaches a live workout builder
    /// (required for the session to be valid), and starts the session
    /// + builder. On success, calls `beginStreaming()`.
    private func startWorkoutSession() {
        guard workoutSession == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore,
                                               configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config
            )
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            workoutBuilder = builder
            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, _ in
                // Collection-start failures are non-fatal — the
                // session itself drives the runtime budget; the
                // builder is just plumbing. We ignore the error.
            }
            beginStreaming()
        } catch {
            // Workout-session start failed (HealthKit unavailable
            // mid-flight, or denied by Screen Time / corporate
            // policy). Fall back to the runtime-session path.
            trackingError = nil
            startRuntimeSessionFallback()
        }
    }

    /// Pre-HealthKit fallback path. Same behaviour as before — the
    /// app gets ~1-3 hours of runtime, then watchOS suspends it. We
    /// keep this path so users who deny HealthKit can still use Live
    /// tracking for short trips.
    private func startRuntimeSessionFallback() {
        if runtimeSession == nil {
            let session = WKExtendedRuntimeSession()
            session.delegate = self
            session.start()
            runtimeSession = session
        }
        beginStreaming()
    }

    /// Common path: enable background CL + start streaming. Called
    /// after EITHER `HKWorkoutSession` OR `WKExtendedRuntimeSession`
    /// is up so the host always exists before CL produces fixes.
    private func beginStreaming() {
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

        // Tear down whichever host is active. Both paths are nilled
        // out at the bottom regardless so a Stop after the host was
        // already invalidated (session denial, OS reclamation) is a
        // safe no-op.
        if let session = workoutSession {
            // Per-Apple guidance: end the builder's collection first,
            // then end the session, then DISCARD the workout (we
            // never save samples — the workout was purely a runtime
            // container, not exercise data we want in the user's
            // Health app).
            workoutBuilder?.endCollection(withEnd: Date()) { [weak self] _, _ in
                self?.workoutBuilder?.discardWorkout()
            }
            session.end()
        }
        runtimeSession?.invalidate()
        workoutSession = nil
        workoutBuilder = nil
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
        // Arm if tracking is now eligible; the method cancels itself when
        // consent is revoked or authorization is missing.
        armTrackingWatchdog()
    }

    // MARK: - Tracking-paused watchdog

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// (Re)schedules the watchdog notification `watchdogInterval` from now,
    /// replacing any previously-armed one. A steady stream of fixes keeps
    /// pushing the fire time forward so it never delivers; when fixes stop
    /// (power-off, suspended refresh) the last-armed one fires on schedule —
    /// even though the app is no longer running, because it was handed to the
    /// system in advance. Only arms when the feature is on, consent is
    /// granted, and we're authorized — i.e. tracking is *meant* to be running.
    func armTrackingWatchdog() {
        guard pauseAlertEnabled, isAuthorized, isConsentGranted() else {
            cancelTrackingWatchdog()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "MapMe tracking paused"
        content.body = "No location update in a while. Open MapMe to resume tracking."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: Self.watchdogInterval,
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: Self.watchdogNotificationID,
            content: content,
            trigger: trigger
        )
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.watchdogNotificationID])
        center.add(request)
    }

    func cancelTrackingWatchdog() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.watchdogNotificationID])
    }

    /// Fires the watchdog alert immediately. Used by the "Test alert"
    /// button in `WatchSettingsView` so the user can verify the
    /// notification permission was granted and the watch is set up to
    /// deliver the alert, without having to wait for the
    /// `watchdogInterval` to elapse. Always requests authorization
    /// first — the toggle's didSet does too, but a user who skipped
    /// the prompt then tapped Test should still get a fresh chance.
    func fireTestPauseAlert(completion: @escaping (_ delivered: Bool, _ reason: String?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                completion(false, error?.localizedDescription
                           ?? "Notifications are off for MapMe in Settings → MapMe → Notifications.")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "MapMe tracking paused (test)"
            content.body = "If you see this on your watch, the real alert will fire when tracking actually pauses."
            content.sound = .default
            // No trigger → deliver immediately.
            let request = UNNotificationRequest(
                identifier: "com.mapme.tracking-watchdog.test",
                content: content,
                trigger: nil
            )
            center.add(request) { err in
                completion(err == nil, err?.localizedDescription)
            }
        }
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

    // MARK: - Stationary cluster helpers

    /// Centroid of the rolling window, or `nil` until we've
    /// accumulated at least 3 fixes — with fewer samples any single
    /// noisy fix dominates and the check misfires in either direction.
    private func clusterCentroid() -> CLLocation? {
        guard recentAcceptedFixes.count >= 3 else { return nil }
        let n = Double(recentAcceptedFixes.count)
        let lat = recentAcceptedFixes.map(\.coordinate.latitude).reduce(0, +) / n
        let lon = recentAcceptedFixes.map(\.coordinate.longitude).reduce(0, +) / n
        return CLLocation(latitude: lat, longitude: lon)
    }

    private func appendToClusterWindow(_ location: CLLocation) {
        recentAcceptedFixes.append(location)
        if recentAcceptedFixes.count > Self.stationaryClusterWindow {
            recentAcceptedFixes.removeFirst(recentAcceptedFixes.count - Self.stationaryClusterWindow)
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

        // Distance-based cadence bypass — mirror of the iOS twin.
        // Slow movement that takes longer than the cadence interval
        // (parking lots, hallway walking) would otherwise be
        // coalesced into entry/exit-only fixes and the trail
        // vanishes.
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

        // ── 4. Stationary cluster suppression ──────────────────────
        //
        // Watch GPS drifts 10–25 m per fix while stationary — far
        // more than iPhone in the same conditions. The pair-wise
        // jitter filter above catches consecutive-fix noise, but
        // not the case where each new fix jumps 15 m in a new
        // direction (still passes the >8 m gate but never actually
        // leaves the rest cluster). Comparing to the centroid of the
        // last few writes exposes the orbit and rejects the fix.
        if speedKmh < Self.stationarySpeedKmh,
           let centroid = clusterCentroid(),
           location.distance(from: centroid) < Self.stationaryClusterRadiusMeters {
            return
        }

        lastWriteAt = now
        lastAcceptedLocation = location
        appendToClusterWindow(location)

        // A fix landed → tracking is alive. Push the "paused" watchdog
        // forward so it only fires if fixes actually stop coming.
        armTrackingWatchdog()

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

// MARK: - HKWorkoutSessionDelegate

extension WatchLocationService: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        // We don't need to react to .running / .paused transitions —
        // the workout session is just hosting our CL streaming. We DO
        // want to clear our reference when the session ends so a
        // later Start Live can spin up a fresh one.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch toState {
            case .ended, .stopped:
                if self.workoutSession === workoutSession {
                    self.workoutSession = nil
                    self.workoutBuilder = nil
                }
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        // Session start/run failed mid-flight. Drop our reference and,
        // if Live is still meant to be on, fall back to the runtime
        // session. CL keeps streaming via
        // `allowsBackgroundLocationUpdates` either way.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.workoutSession === workoutSession {
                self.workoutSession = nil
                self.workoutBuilder = nil
            }
            if self.isLiveTracking, self.runtimeSession == nil {
                self.startRuntimeSessionFallback()
            }
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchLocationService: HKLiveWorkoutBuilderDelegate {
    // We don't actually collect any health samples — the builder
    // exists purely because `HKWorkoutSession` requires one. Both
    // delegate callbacks are intentional no-ops; the workout will be
    // discarded (not saved) by `stopLiveTracking()`.
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {}
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

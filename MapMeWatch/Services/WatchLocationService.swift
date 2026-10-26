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

    /// When on, WatchLocationService posts a local notification +
    /// plays a haptic every time Live tracking transitions on/off —
    /// including the auto-start-on-motion path, so the user can tell
    /// the feature actually fired. Without this the transition is
    /// invisible unless the user opens the app and looks at the
    /// "Live" pill. Default `true` because the whole point of the
    /// auto-start feature is to run in the background and the user
    /// needs a signal.
    @Published var trackingChangeAlertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(trackingChangeAlertsEnabled,
                                      forKey: Self.kTrackingChangeAlertsKey)
        }
    }
    private static let kTrackingChangeAlertsKey = "MapMe.trackingChangeAlerts"

    /// When on, the watch tries to maintain a live `HKWorkoutSession`
    /// continuously — auto-starts on app launch, auto-restarts if the
    /// session dies, and ignores the auto-stop-when-stationary path.
    ///
    /// This is the "always-on tracking" mode requested to eliminate
    /// the 15-min background-refresh wake-up gap. Battery cost with
    /// the current Balanced profile is ~10-14% per hour on a Series 6+
    /// (Apple Watch screen off, GPS active, no cellular). Users who
    /// want the old manual behaviour can turn this off in the watch
    /// Settings screen.
    ///
    /// Default `true` — the user asked for always-on to be the
    /// default. A dedicated toggle in `WatchSettingsView` lets them
    /// opt out for battery-critical days.
    @Published var alwaysOnTracking: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTracking, forKey: Self.kAlwaysOnKey)
            if alwaysOnTracking {
                ensureLiveTracking()
            }
        }
    }
    private static let kAlwaysOnKey = "MapMe.watchAlwaysOnTracking"

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
    /// Set true when `beginStreaming()` flips intent to Live. The
    /// tracking-started haptic + notification only fires once a
    /// *real* CL fix arrives after this flag is set — previously
    /// we announced the moment CL was asked to stream, which is
    /// before the HK workout session has confirmed `.running` and
    /// before any fix has been delivered. If the host silently fails
    /// to reach `.running`, the wearer saw "tracking started" but
    /// the watch never actually recorded anything.
    private var pendingStartAnnounceOnFirstFix: Bool = false
    /// When `beginStreaming()` last ran. Kept for diagnostics but no
    /// longer used to trigger a zombie-repair — the "no fix since
    /// start" heuristic proved too eager (indoors, cold-start fixes
    /// can take several minutes) and re-cycled the HK workout
    /// session repeatedly, which drained battery and spammed
    /// tracking-change notifications on every 15-min background
    /// refresh. Only a truly dead host (both `workoutSession` and
    /// `runtimeSession` nil) counts as zombie now.
    private var lastBeginStreamingAt: Date?
    /// When we last did a zombie-repair `stop → start` cycle. Rate-
    /// limit further cycles so a broken environment (permission
    /// revoked, HK unavailable) doesn't burn the battery in a tight
    /// retry loop.
    private var lastZombieRecycleAt: Date?
    /// Minimum spacing between zombie-repair cycles.
    private static let zombieRecycleCooldown: TimeInterval = 5 * 60
    /// How long we wait for the HK workout session to transition
    /// to `.running` before assuming it silently failed and falling
    /// back to `WKExtendedRuntimeSession`.
    private static let hkRunningWatchdogSeconds: TimeInterval = 10

    // MARK: - Batched writes
    //
    // Same rationale as `LocationService.PendingWrite` on iOS — one
    // CloudKit export op per batch instead of one per fix, which
    // matters even more on watchOS given the tiny background runtime
    // budget. See the iOS twin for the full write-up.
    private struct PendingWrite {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let speed: Double
        let course: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
    }
    private var pendingWrites: [PendingWrite] = []

    // MARK: - Diagnostics (read-only accessors for Settings)
    //
    // The wearer needs a way to tell whether "MapMe is tracking me"
    // and "Guardian isn't seeing me" are the same problem or two
    // different ones. If `recordsWrittenToday()` is climbing and
    // `pendingWriteCount` stays small, the watch IS producing +
    // saving fixes and the issue is downstream (share missing on the
    // Guardian side, or CloudKit sync stalled). If `recordsWrittenToday`
    // is zero, tracking never activated and the problem is on this
    // device.

    /// Number of accepted fixes currently buffered locally, waiting
    /// for the next `flushPendingWrites` cycle to save them to Core
    /// Data. `nonisolated` so the SwiftUI Settings view can read it
    /// without an actor hop mid-render.
    var pendingWriteCount: Int { pendingWrites.count }

    /// Timestamp of the newest CL fix that passed our accuracy /
    /// staleness / teleport filters. `nil` before the first fix.
    /// Used by the diagnostics row so the wearer can see "watch got
    /// a fix 12 s ago" vs "watch hasn't seen a fix in 40 min."
    var lastAcceptedFixTimestamp: Date? { lastAcceptedLocation?.timestamp }

    /// When we last actually wrote a record to Core Data (heartbeat
    /// or accepted fix). `nil` before the first save.
    var lastPersistedAt: Date? { lastWriteAt }

    /// Counts today's `LocationRecord` rows written by this watch
    /// (matched by `deviceIdentifier`). Runs a `count(for:)` — no
    /// rows hydrated — so it's cheap enough to call on every Settings
    /// render.
    func recordsWrittenToday() -> Int {
        let ctx = persistence.container.viewContext
        let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        let startOfDay = Calendar.current.startOfDay(for: Date())
        request.predicate = NSPredicate(
            format: "deviceIdentifier == %@ AND timestamp >= %@",
            DeviceID.current, startOfDay as NSDate
        )
        return (try? ctx.count(for: request)) ?? 0
    }
    /// Fixes buffered before a Core Data save flushes. Was 3, dropped
    /// to 2 after Guardian users reported the watch marker lagging
    /// several minutes behind reality on Live mode — 3 × 60 s
    /// cadence = up to 3 min in the buffer before flush. 2 halves
    /// that and still keeps CloudKit export ops well under the
    /// scheduler backlog threshold.
    private static let writeBatchSize: Int = 2
    /// Periodic drain even if the buffer hasn't filled. Was 300 s
    /// (5 min) — dropped to 60 s so no accepted fix waits more
    /// than a minute in the buffer, capping the "not tweening
    /// because no fresh data" period the Guardian sees.
    private static let flushIntervalSeconds: TimeInterval = 60
    private var flushTimer: Timer?

    /// Minimum spacing between motion-triggered immediate flushes.
    /// Every accepted moving fix used to flush right away —
    /// that fired an unbounded number of CloudKit export ops per
    /// minute and tripped `BGSystemTaskSchedulerErrorDomain
    /// Code=3` (too many pending task requests). 15 s caps the
    /// export rate at ~4/min while keeping Live-view latency
    /// perceptually seconds-not-minutes.
    private static let motionFlushMinSpacing: TimeInterval = 15
    private var lastMotionFlushAt: Date?

    // Stationary heartbeat — see the iOS `LocationService` twin for
    // the full rationale. TL;DR: a genuinely stationary device stops
    // writing fixes (cluster filter rejects them), so the Guardian's
    // "online" dot goes grey after 30 min even though the device is
    // fine. This timer emits a synthetic record every ~15 min at
    // the last-known coordinate so the freshness clock stays alive.
    private static let heartbeatIntervalSeconds: TimeInterval = 15 * 60
    private var heartbeatTimer: Timer?
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
    /// Stationary jitter thresholds. Wider than the iPhone twin
    /// (12 m vs 8 m) because wrist-mounted GPS has structurally more
    /// noise: smaller antenna, arm-motion obstruction, and body-
    /// worn thermal drift. The tighter iPhone floor over-triggered
    /// the "moving" branch and produced zigzag scribble around
    /// stationary rest locations on the watch.
    private static let stationarySpeedKmh: Double = 0.5
    private static let stationaryJitterFloorMeters: CLLocationDistance = 12
    /// Distance-based cadence bypass — see comment on the iOS twin.
    /// Without this, parking-lot crawls (<90 s through the lot) lose
    /// every intermediate fix to the cadence coalescer.
    private static let cadenceBypassMeters: CLLocationDistance = 25

    /// Stationary cluster suppressor — see iOS twin. Watch GPS jitter
    /// is typically worse than iPhone (smaller antenna, wrist
    /// obstruction), so this filter is what actually stops the
    /// scribble around a stationary rest location. 40 m (up from
    /// iOS' 25 m) matches the wider jitter budget the wrist-
    /// mounted radio needs.
    private static let stationaryClusterRadiusMeters: CLLocationDistance = 40
    private static let stationaryClusterWindow: Int = 5

    /// Watch-side minimum write interval per PowerProfile. Denser than
    /// the shared `PowerProfile.minimumWriteIntervalSeconds` because
    /// snap-to-roads on the watch needs closer waypoints to avoid
    /// dashed-fallback segments. See the call site in `persist(_:)`
    /// for the trade-off analysis.
    private static func watchOverriddenInterval(for profile: PowerProfile) -> TimeInterval {
        switch profile {
        case .battery:      return 300  // unchanged — battery mode stays coarse on purpose
        case .balanced:     return 60   // was 90 (from PowerProfile) — tighter for snap density
        case .highAccuracy: return 20   // was 30 — even denser under HighAccuracy
        }
    }

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
        // Same first-launch defaulting for tracking-change alerts.
        if UserDefaults.standard.object(forKey: Self.kTrackingChangeAlertsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.kTrackingChangeAlertsKey)
        }
        self.trackingChangeAlertsEnabled = UserDefaults.standard.bool(forKey: Self.kTrackingChangeAlertsKey)
        // Always-on defaults to `true` — the user's stated goal is
        // "keep it on and active all the time". Users can opt out
        // from `WatchSettingsView` for a battery-critical day.
        if UserDefaults.standard.object(forKey: Self.kAlwaysOnKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.kAlwaysOnKey)
        }
        self.alwaysOnTracking = UserDefaults.standard.bool(forKey: Self.kAlwaysOnKey)
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
        // Low-power-mode observer. When the watch's battery hits
        // reserve capacity, watchOS enters Reserve Mode — apps get
        // suspended, tracking sessions get torn down, background
        // refresh queue gets cleared. When the user charges back
        // up and Reserve Mode exits, `NSProcessInfoPowerStateDidChange`
        // fires. That's the moment to (a) re-arm Live tracking
        // via `ensureLiveTracking` and (b) push an immediate
        // heartbeat so Guardian devices see "I'm back" without
        // waiting up to 15 min for the next scheduled beat.
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Only act when the transition is low-power → normal.
            // Low-power → low-power (unchanged) is a no-op; we
            // don't want to double-start on every notification.
            if !ProcessInfo.processInfo.isLowPowerModeEnabled {
                Task { @MainActor in
                    self.ensureLiveTracking()
                    self.writeHeartbeatIfIdle()
                }
            }
        }

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
            // Motion resumed — escalate GPS accuracy immediately so
            // the first fix after a rest is precise. Cost of running
            // Best is only paid while actually moving.
            applyDynamicAccuracy(stationary: false)
        } else {
            // Stationary. Debounce the auto-stop so a brief pause
            // doesn't tear down the workout session.
            //
            // When `alwaysOnTracking` is ON, skip the auto-stop
            // entirely — the whole point of always-on is that Live
            // never gets torn down for stationary periods. Instead
            // we take the battery win by widening `desiredAccuracy`
            // + `distanceFilter` — GPS radio still runs but the
            // ranging duty cycle drops sharply once CL knows we
            // don't need sub-100 m fidelity.
            if alwaysOnTracking {
                applyDynamicAccuracy(stationary: true)
                return
            }
            let sinceLast = lastMotionAt.map { Date().timeIntervalSince($0) } ?? 0
            if isLiveTracking, sinceLast >= Self.autoStopStationaryInterval {
                stopLiveTracking()
            }
        }
    }

    /// Adjusts the CL manager for the current motion state.
    ///
    /// - Moving → `powerProfile`'s desired accuracy + a tight
    ///   `distanceFilter` (20 m ≈ 65 ft). PowerProfile's default
    ///   filter is 100 m on Balanced, which meant CL wouldn't
    ///   deliver a new fix until the watch had travelled a full
    ///   100 m — the Guardian's Live view saw nothing until the
    ///   wearer had covered ~330 ft. 20 m lets updates flow every
    ///   ~65 ft of movement, comfortably inside the user's 200 ft
    ///   "should be real-time" expectation.
    /// - Stationary (and always-on) → `hundredMeters` + `100 m`
    ///   filter. GPS ranging drops from ~1 Hz to opportunistic;
    ///   sub-100 m precision is meaningless when the fix hasn't
    ///   moved anyway.
    ///
    /// Ignored when `alwaysOnTracking` is off — in the manual-control
    /// world, the profile the user picked is authoritative.
    private static let movingDistanceFilterMeters: CLLocationDistance = 20

    private func applyDynamicAccuracy(stationary: Bool) {
        guard alwaysOnTracking else { return }
        if stationary {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 100
        } else {
            manager.desiredAccuracy = powerProfile.desiredAccuracy
            manager.distanceFilter = Self.movingDistanceFilterMeters
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
        guard HKHealthStore.isHealthDataAvailable() else {
            // No HealthKit on this device (shouldn't happen on a
            // modern Apple Watch, but the simulator can land here).
            startRuntimeSessionFallback()
            return
        }

        // Fast path: don't call `requestAuthorization` if the user
        // already granted (or explicitly denied). Two reasons:
        //   1. On a locked watch, `requestAuthorization` can defer
        //      its completion callback until unlock — turning
        //      "always-on tracking" into "tracking that never
        //      starts if the watch was locked when it was asked to
        //      start", which matches the wearer's report of a
        //      1.5-mile walk with zero fixes recorded.
        //   2. The prompt-dialog case only exists on the very first
        //      run; after that `.sharingAuthorized` / `.sharingDenied`
        //      is stable and re-asking wastes a runloop hop.
        let hkStatus = healthStore.authorizationStatus(for: HKObjectType.workoutType())
        switch hkStatus {
        case .sharingAuthorized:
            startWorkoutSession()
        case .sharingDenied:
            startRuntimeSessionFallback()
        case .notDetermined:
            // First run — ask, then dispatch on the callback. The
            // dialog only shows when the watch is unlocked; if the
            // user is on a walk right now the callback won't fire
            // until they unlock, which is the expected UX for a
            // first-time permission prompt.
            healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                             read: []) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.startWorkoutSession() }
                    else { self.startRuntimeSessionFallback() }
                }
            }
        @unknown default:
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
        // `.walking` (not `.other`) is deliberate. watchOS grants
        // `.walking` / `.running` / `.hiking` / `.cycling` real
        // background-GPS priority — CL keeps delivering fixes even
        // when the watch is locked or the wrist is down. `.other`
        // is treated as a generic session and can lose GPS delivery
        // to power management, which matched the wearer's report of
        // a 1.5-mile walk producing zero recorded fixes because
        // watchOS quietly suspended CL updates once the app went
        // inactive. Health app impact is nil: `stopLiveTracking`
        // calls `discardWorkout()` so no sample is ever saved.
        config.activityType = .walking
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore,
                                               configuration: config)
            let builder = session.associatedWorkoutBuilder()
            // Data source is REQUIRED for `beginCollection` to succeed —
            // without it, the builder can't start, `beginCollection`
            // errors out, and the workout session gets invalidated by
            // watchOS, which kills the runtime budget. A previous
            // attempt to skip the data source (to keep the HR sensor
            // asleep) had exactly this failure mode: the watch stopped
            // getting GPS fixes, and Guardian devices saw the watch
            // fall off the network entirely.
            //
            // Accepting the ~5-10 % / hr HR polling here — future
            // optimisation is to call
            // `dataSource.disableCollection(for: .heartRate)` etc.
            // to suppress specific metric types while keeping the
            // data source alive.
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
            // Watchdog: if the session doesn't reach `.running`
            // within 10 s, fall back to WKExtendedRuntimeSession.
            // `.startActivity` is asynchronous and can silently
            // fail to transition — the delegate's
            // `didFailWithError` covers explicit failures, but
            // stuck-in-`.preparing` cases have been observed on
            // real watches when the session was requested while
            // the watch was locked or another workout was running.
            // Without this watchdog the wearer thinks tracking is
            // up but the session never activates, CL loses
            // background GPS priority, and no fixes flow.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hkRunningWatchdogSeconds) { [weak self, weak session] in
                guard let self, let session,
                      self.workoutSession === session,
                      session.state != .running else { return }
                // Still not running. Drop the HK ref and start the
                // runtime fallback so we have SOMETHING keeping
                // the app alive for CL.
                self.workoutSession = nil
                self.workoutBuilder = nil
                if self.runtimeSession == nil {
                    self.startRuntimeSessionFallback()
                }
            }
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
        let wasTracking = isLiveTracking
        isLiveTracking = true
        trackingError = nil
        mirrorStatusToAppGroup()
        armHeartbeatTimer()
        LaunchReminderService.setTrackingActive(true)
        lastBeginStreamingAt = Date()
        // Defer the "tracking started" haptic + notification until we
        // actually receive a fix. Firing it here — before any fix
        // arrives — is what produced the wearer's "notification says
        // tracking, but nothing was moving on Guardian" report:
        // `HKWorkoutSession.startActivity` is asynchronous and can
        // silently fail to reach `.running`, at which point CL only
        // delivers fixes while the app is foreground. Waiting for a
        // real fix means the announce only fires when tracking is
        // demonstrably working.
        if !wasTracking { pendingStartAnnounceOnFirstFix = true }
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

        let wasTracking = isLiveTracking
        isLiveTracking = false
        pendingStartAnnounceOnFirstFix = false
        lastBeginStreamingAt = nil
        mirrorStatusToAppGroup()
        LaunchReminderService.setTrackingActive(false)
        // Drain any fixes still buffered before we tear down. On the
        // watch this matters a lot — a stopped session that's never
        // flushed loses the tail permanently since there's no
        // background wake-up to catch up later.
        flushPendingWrites()
        cancelFlushTimer()
        cancelHeartbeatTimer()
        if wasTracking { announceTrackingChange(started: false) }
    }

    // MARK: - Tracking-change alerts

    /// Fires a haptic + local notification whenever Live tracking
    /// transitions on/off. This is the visible / tactile signal that
    /// the auto-start-on-motion feature actually kicked in — without
    /// it the transition happens silently in the background and the
    /// wearer never knows the state changed.
    ///
    /// Silent when `trackingChangeAlertsEnabled` is false (user opted
    /// out) or when notifications are denied. The haptic still plays
    /// so wristward-glance still tells you something happened.
    private func announceTrackingChange(started: Bool) {
        guard trackingChangeAlertsEnabled else { return }
        // Skip during a zombie-repair recycle — the wearer's intent
        // is still "keep tracking", the plumbing is just being
        // renewed. See `ensureLiveTracking`.
        guard !isRecycling else { return }
        WKInterfaceDevice.current().play(started ? .start : .stop)

        let content = UNMutableNotificationContent()
        content.title = started ? "MapMe tracking started" : "MapMe tracking stopped"
        content.body = started
            ? "Your watch just started recording Live location."
            : "Your watch stopped recording Live location."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "com.mapme.tracking-change-\(started ? "on" : "off")",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
        // If always-on is on and consent just became available, kick
        // the tracking session immediately instead of waiting for a
        // motion event.
        ensureLiveTracking()
    }

    /// Idempotent "start Live tracking if it should be running and
    /// isn't." No-op when:
    ///
    /// - `alwaysOnTracking` is off (user opted for manual control)
    /// - `isLiveTracking` is already true (nothing to do)
    /// - consent hasn't been granted for this device's `MinorProfile`
    /// - CoreLocation isn't yet authorized
    ///
    /// Safe to call as often as we want — the app delegate calls it
    /// on every `applicationDidBecomeActive` so a session that got
    /// torn down (workout ended by the user starting a real workout,
    /// OS-side runtime reclamation, unlock-from-suspend after a
    /// battery-out crash) revives the moment the app is next opened.
    func ensureLiveTracking() {
        guard alwaysOnTracking else { return }
        guard isAuthorized else { return }
        guard isConsentGranted() else { return }

        // Fast path: not tracking → start.
        if !isLiveTracking {
            startLiveTracking()
            return
        }

        // Zombie-state repair — very narrow. Only recycle when BOTH
        // hosts are gone, which is the only genuinely broken shape
        // (no HKWorkoutSession AND no WKExtendedRuntimeSession means
        // the process has no background runtime, so CL will only
        // fire while foreground).
        //
        // Earlier attempt also recycled on "no fix in 60 s since
        // start", but that hit legitimate slow-cold-start cases
        // indoors and burned the battery in a stop→start→new-HK-
        // session loop every 15 min. Only the "both hosts nil"
        // shape is a true zombie.
        let hostIsDead = (workoutSession == nil && runtimeSession == nil)
        guard hostIsDead else { return }

        // Rate-limit: at most one recycle per `zombieRecycleCooldown`
        // regardless of how many `applicationDidBecomeActive` /
        // background-refresh calls come through, so a permanently-
        // broken environment (permission revoked mid-session, HK
        // disabled by parental controls) can't drain the battery in
        // a tight retry loop.
        if let last = lastZombieRecycleAt,
           Date().timeIntervalSince(last) < Self.zombieRecycleCooldown {
            return
        }
        lastZombieRecycleAt = Date()

        // Silent recycle — we don't want a "tracking stopped" +
        // "tracking started" notification pair every time we repair
        // a dead host. The wearer's intent is still "keep tracking";
        // this is just plumbing the OS asked us to redo.
        // `isRecycling` gates both `announceTrackingChange` and the
        // deferred first-fix announce below.
        isRecycling = true
        stopLiveTracking()
        startLiveTracking()
        isRecycling = false
        // Suppress the deferred first-fix announce too — startLive
        // above already set the flag, but we clear it because a
        // recycle should be invisible to the wearer.
        pendingStartAnnounceOnFirstFix = false
    }

    /// True only for the tiny window inside `ensureLiveTracking`'s
    /// zombie-repair path where a `stop → start` cycle would
    /// otherwise fire "tracking stopped" + "tracking started"
    /// notifications back-to-back. `announceTrackingChange` skips
    /// when this is set.
    private var isRecycling: Bool = false

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
        // Watch-specific cadence: denser than iPhone's default so
        // MKDirections has enough intermediate fixes to snap the
        // walking polyline end-to-end (below `maxWalkingSnapDistanceMeters`).
        // At 90 s of walking pace ~= 100 m per gap, which sits right
        // at snap's fallback boundary and produced the dashed
        // segments in the earlier watch trail. 60 s ~= 65 m gaps —
        // comfortably inside the snap window. Battery hit is modest
        // (~2-3 %/hr extra) and stays within the "Balanced always-on"
        // envelope.
        let minInterval = adaptive.isEnabled
            ? adaptive.interval(forSpeedKmh: speedKmh)
            : Self.watchOverriddenInterval(for: powerProfile)

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

        // Buffer instead of writing immediately — see the batching
        // block at the top of the file for CloudKit-scheduler rationale.
        pendingWrites.append(PendingWrite(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            speed: location.speed,
            course: location.course,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy
        ))
        armFlushTimer()
        // Motion-triggered immediate flush, rate-limited to at
        // most once per `motionFlushMinSpacing`. Without the rate
        // limit, one CloudKit export op per moving fix overwhelmed
        // the BGTaskScheduler (Code=3 "too many pending"). 15 s
        // spacing caps the export rate at ~4/min while keeping
        // Live-view latency in the seconds range.
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

        // App-Group mirror happens on every accepted fix so the
        // complication reads the freshest coordinate the moment it
        // renders. Widget timeline refresh is THROTTLED because
        // `WidgetCenter.reloadTimelines` triggers a WidgetKit
        // rendering pass every call — at HighAccuracy 30 s cadence
        // that's 120 renders per hour, and each render pulls a fresh
        // snapshot from the App Group + evaluates the timeline. 30 s
        // throttle preserves the "Live · N m ago" feel without
        // paying for 4× more widget renders than needed.
        WatchSharedState.writeFix(location, isLive: isLiveTracking)
        throttledWidgetReload()
    }

    /// Timestamp of the last `WidgetCenter.reloadTimelines` we let
    /// through. `nil` on first fire.
    private var lastWidgetReloadAt: Date?
    private static let widgetReloadMinInterval: TimeInterval = 30

    private func throttledWidgetReload() {
        let now = Date()
        if let last = lastWidgetReloadAt,
           now.timeIntervalSince(last) < Self.widgetReloadMinInterval {
            return
        }
        lastWidgetReloadAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: "com.mapme.app.status")
    }

    // MARK: - Batched write flush

    /// Same rationale as `LocationService.flushPendingWrites` on iOS —
    /// N accepted fixes ride ONE `ctx.save()` so CloudKit sees one
    /// export op per batch instead of one per fix. On watchOS this
    /// matters even more: the watch has severe background runtime
    /// limits, so if CloudKit exports back up beyond what one refresh
    /// window can drain, writes pile forever.
    ///
    /// `internal` (not `private`) so `WatchAppDelegate.applicationWillResignActive`
    /// can drain the buffer on wrist-down / suspend transitions.
    func flushPendingWrites() {
        guard !pendingWrites.isEmpty else { return }
        let batch = pendingWrites
        pendingWrites.removeAll()

        let ctx = persistence.newBackgroundContext()
        let privateStore = persistence.privateStore
        ctx.perform {
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
                record.deviceName = DeviceID.displayName
                record.deviceIdentifier = DeviceID.current
                if let profile { record.profile = profile }
            }
            try? ctx.save()
        }
    }

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

    /// Synthetic record at the last-known coordinate — see iOS
    /// twin for the full rationale.
    private func writeHeartbeatIfIdle() {
        guard isLiveTracking else { return }
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
            verticalAccuracy: last.verticalAccuracy
        ))
        lastWriteAt = Date()
        flushPendingWrites()
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
            // First real fix after a start? Fire the deferred
            // "tracking started" announce now — this is the point at
            // which we can honestly tell the wearer tracking is
            // working. Any earlier and we're announcing intent, not
            // reality. See `beginStreaming()` for the reasoning.
            if self.pendingStartAnnounceOnFirstFix {
                self.pendingStartAnnounceOnFirstFix = false
                self.announceTrackingChange(started: true)
            }
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

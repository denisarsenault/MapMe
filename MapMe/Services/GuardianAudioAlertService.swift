#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import CoreData
import CoreLocation
import AVFoundation
import Combine
import os
#if os(macOS)
import CoreAudio
#endif

/// Filter Console.app to subsystem `com.mybrightzone.app` + category
/// `guardian-alerts` to trace which announcements fire and why. Kept
/// silent under `.notice` so it survives release builds — useful when
/// diagnosing "why did the Guardian just repeat this alert five
/// times" without adding print noise to Debug.
private let alertLog = Logger(subsystem: "com.mybrightzone.app", category: "guardian-alerts")

/// Guardian-side motion announcer + trip logger.
///
/// Watches the shared CloudKit-mirrored store for new `LocationRecord`
/// arrivals and drives a per-profile state machine:
///
///   - **Stationary** at some anchor. When the anchor's set,
///     stationary means "the latest fixes have stayed within a small
///     radius." Announcement is silent — the interesting thing is
///     when the device leaves.
///   - **Moving**: entered when a fix lands more than
///     `tripStartDistance` from the anchor. Fires a "started trip N"
///     announcement, opens a new `Trip` record, and pins that trip's
///     number to the profile.
///   - **Stop detected**: entered when the profile has been Moving
///     but no new fix has arrived for `stopDetectionInterval`. Fires
///     a "stopped [at PlaceName], trip N" announcement, closes the
///     current Trip with the last known fix as the end location, and
///     reverse-geocodes that fix to include a POI or street name in
///     the announcement.
///
/// Design decisions (per user scope):
///  - Nicknames stay **local** to each Guardian device (UserDefaults),
///    keyed by profile UUID. Falls back to `MinorProfile.displayName`.
///  - Trip numbering is **sequential per device forever**. "Trip 138"
///    for Alice means "her 138th trip ever," not "her 138th today."
///  - Speech always includes the trip number so start + stop pair.
///  - Reverse-geocode failures fall back to a bare "stopped" so an
///    offline Guardian device still gets the alert.
@MainActor
final class GuardianAudioAlertService: ObservableObject {
    static let shared = GuardianAudioAlertService()

    // MARK: - Persistent settings

    /// Controls the AUDIO channel only. When off, the service still
    /// observes CloudKit changes and still fires visual balloons on
    /// every tracking transition — the Guardian just doesn't hear
    /// spoken announcements. This split was added after a user
    /// reported turning off the Speak toggle expecting silent
    /// notifications, but got no visual either — the previous
    /// design gated observation, audio, and balloon all behind
    /// this single toggle.
    ///
    /// The property name / storage key are kept for backward compat
    /// even though the semantic is now audio-only; renaming would
    /// require a UserDefaults migration and the Settings UI label
    /// ("Speak when a device starts moving") already reads as
    /// audio-only.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.kEnabledKey) }
    }
    private static let kEnabledKey = "MapMe.guardianAudioAlerts.enabled"

    /// Per-profile nickname overrides. Keyed by `MinorProfile.id`
    /// (UUID string). Falls back to `displayName` at speak time.
    private var nicknames: [String: String] {
        didSet { UserDefaults.standard.set(nicknames, forKey: Self.kNicknamesKey) }
    }
    private static let kNicknamesKey = "MapMe.guardianAudioAlerts.nicknames"

    /// Per-profile state machine snapshots. Persisted so a relaunch
    /// resumes with the same running trip / anchor / count instead of
    /// mis-announcing "started trip 1" every restart.
    private var profileStates: [String: ProfileState] {
        didSet { saveProfileStates() }
    }
    private static let kStatesKey = "MapMe.guardianAudioAlerts.states"

    /// Completed trip log per profile. Kept in UserDefaults for now
    /// (no CoreData migration required) so a future Trips UI can read
    /// it directly without touching the sync layer.
    private var tripLog: [String: [Trip]] {
        didSet { saveTripLog() }
    }
    private static let kTripsKey = "MapMe.guardianAudioAlerts.trips"

    // MARK: - Tunables

    /// Distance from the anchor at which we flip to Moving and start
    /// a new trip. 50 m per user spec.
    private static let tripStartDistance: CLLocationDistance = 50

    /// How long the profile can go without a fresh fix while Moving
    /// before we conclude they've stopped. 5 min per user spec.
    private static let stopDetectionInterval: TimeInterval = 5 * 60

    /// How often the stop-detection timer wakes to check. Doesn't
    /// need to be tight — the announcement precision is
    /// `stopDetectionInterval` anyway, plus this cadence.
    private static let stopCheckInterval: TimeInterval = 60

    /// Minimum spacing between announcements for the same profile,
    /// to guard against a rapid-fire pattern (fix arrives → announce
    /// start; loses signal instantly → 5 min later announce stop;
    /// signal returns → announce start again).
    private static let minAlertSpacing: TimeInterval = 30

    /// Maximum age of an incoming fix that can still trigger a
    /// motion-transition announcement. CloudKit sync from a Minor
    /// device to Guardian can legitimately be delayed by tens of
    /// minutes when the Minor was in a poor-signal area, in
    /// airplane mode, or when the CloudKit export queue is backed
    /// up. Was 15 min — too tight; user reported no balloons for
    /// records arriving via CloudKit catch-up. 60 min is generous
    /// enough for real backlogs while still keeping "bulk
    /// historical import" imports (yesterday's trip suddenly
    /// arriving today) from firing spurious announcements.
    private static let maxAnnounceableFixAgeSeconds: TimeInterval = 60 * 60

    /// If we haven't seen a fresh fix from a profile in this long,
    /// the next fresh arrival is treated as a "device reconnected"
    /// event and gets its own announcement. Bumped from 30 min to
    /// 60 min after real-world CloudKit sync gaps under normal
    /// backlog conditions consistently crossed the 30-min line,
    /// spamming the Guardian with "back online" every burst cycle.
    /// 60 min is generous enough that only genuine offline periods
    /// trip it.
    private static let reconnectSilenceThreshold: TimeInterval = 60 * 60

    /// Additional dedup window on top of the phrase-level 30 s
    /// dedup. Prevents a profile that keeps going in-and-out of
    /// range from firing reconnect on every reappearance. If we
    /// already announced reconnect for a profile within this
    /// window, we skip subsequent reconnects even if the silence
    /// gate is met.
    private static let reconnectMinSpacing: TimeInterval = 60 * 60

    // MARK: - Types

    struct ProfileState: Codable {
        /// Latest fix we've seen for this profile.
        var latestFixAt: Date?
        var latestFixLat: Double?
        var latestFixLon: Double?

        /// Anchor of the last confirmed rest. When set, "moving"
        /// means "fix > 50m from this anchor."
        var anchorLat: Double?
        var anchorLon: Double?

        /// Whether we're currently in the Moving state.
        var isMoving: Bool = false

        /// Rolling trip counter, sequential per device forever. First
        /// motion assigns trip 1.
        var tripsCount: Int = 0

        /// Metadata for the trip currently in flight, if any.
        var currentTripStartAt: Date?
        var currentTripStartLat: Double?
        var currentTripStartLon: Double?
        var currentTripNumber: Int?

        /// Debounce timestamps.
        var lastAnnouncedAt: Date?
        /// When the profile last fired a "back online" reconnect
        /// announcement. Prevents repeat-fire when a profile
        /// oscillates between silent + fresh across sync bursts.
        var lastReconnectAt: Date?
    }

    /// One in-flight announcement suitable for balloon display.
    /// Includes the same phrase we tried to speak so a Guardian who
    /// can't hear the audio still gets the alert content.
    struct Announcement: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let createdAt: Date
    }

    /// Balloon queue. Rendered by `GuardianBalloonOverlay`. Only
    /// populated when we detect the audio channel is unlikely to be
    /// heard (system volume < 20% or no output route) so a user
    /// listening to the speech doesn't ALSO get a redundant on-screen
    /// balloon. Auto-expires each entry after `visualAnnouncementTTL`.
    @Published private(set) var visualAnnouncements: [Announcement] = []

    /// How long each balloon stays on screen before auto-fading.
    /// 6 s is long enough to read even a two-clause announcement
    /// aloud in your head, short enough that a staccato series of
    /// trips doesn't pile up an unreadable stack.
    private static let visualAnnouncementTTL: TimeInterval = 6

    /// Maximum simultaneous balloons. Anything past this displaces
    /// the oldest.
    private static let maxVisualAnnouncements: Int = 5

    /// Volume threshold below which we consider the audio channel
    /// "unlikely to be heard" and fall through to the balloon UI.
    private static let silentAudioThreshold: Float = 0.20

    struct Trip: Codable, Identifiable, Hashable {
        var id: String { "\(number)-\(Int(startAt.timeIntervalSince1970))" }
        let number: Int
        let startAt: Date
        let startLat: Double
        let startLon: Double
        let endAt: Date
        let endLat: Double
        let endLon: Double
        let endPlaceName: String?
    }

    // MARK: - Runtime

    private let synthesizer = AVSpeechSynthesizer()
    private let geocoder = CLGeocoder()
    private var remoteChangeObserver: NSObjectProtocol?
    private var stopCheckTimer: Timer?

    /// Profiles the service has evaluated at least once this session.
    /// The FIRST evaluation of each profile after app launch is a
    /// silent state-seed — it updates the in-memory anchor and
    /// `latestFixAt` without firing any announcement — so a Guardian
    /// restart doesn't dump a backlog of catch-up alerts ("X started
    /// trip 3, X is back online, X stopped at Publix, X started trip
    /// 4") for every device at once. Only fresh events observed
    /// AFTER the seeding pass produce announcements.
    ///
    /// Reset on `stop()` so a service tear-down + restart within the
    /// same process (unlikely, but happens in tests) also gets a
    /// fresh seeding pass.
    private var seededProfileUUIDs: Set<String> = []

    private init() {
        // Default to ON for the never-toggled case. The stored key is
        // read with `object(forKey:)` first so we can distinguish
        // "user explicitly turned it off" (stored `false`) from
        // "never touched the setting" (nil → default ON). Alerts are
        // the whole point of Guardian mode — a fresh install
        // shouldn't need the user to hunt through Settings before it
        // starts announcing.
        if let stored = UserDefaults.standard.object(forKey: Self.kEnabledKey) as? Bool {
            self.isEnabled = stored
        } else {
            self.isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.kEnabledKey)
        }
        self.nicknames = (UserDefaults.standard.dictionary(forKey: Self.kNicknamesKey)
                          as? [String: String]) ?? [:]
        if let data = UserDefaults.standard.data(forKey: Self.kStatesKey),
           let decoded = try? JSONDecoder().decode([String: ProfileState].self, from: data) {
            self.profileStates = decoded
        } else {
            self.profileStates = [:]
        }
        if let data = UserDefaults.standard.data(forKey: Self.kTripsKey),
           let decoded = try? JSONDecoder().decode([String: [Trip]].self, from: data) {
            self.tripLog = decoded
        } else {
            self.tripLog = [:]
        }
        // Observation is unconditional now — the balloon path must
        // fire even when the audio toggle is off, so the service has
        // to keep watching for CloudKit changes regardless of
        // `isEnabled`. The audio side is gated inside `speak()`.
        start()
    }

    // MARK: - Nickname API

    func nickname(for profile: MinorProfile) -> String {
        if let uuid = profile.id?.uuidString,
           let custom = nicknames[uuid],
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return profile.displayName?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? "Your device"
    }

    func setNickname(_ raw: String?, for profile: MinorProfile) {
        guard let uuid = profile.id?.uuidString else { return }
        let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: uuid)
        } else {
            nicknames[uuid] = trimmed
        }
    }

    /// Wipes every piece of announcement state — per-profile state
    /// machines, the completed-trip log, the seeded-UUID set, and any
    /// in-flight speech / geocode. After the next remote-change
    /// notification the service re-seeds each profile from scratch,
    /// so the Guardian starts fresh from "wherever each Minor is
    /// right now" with no historical trip numbers or stale isMoving
    /// flags carried forward.
    ///
    /// User-facing entry point behind the "Reset alerts state" button
    /// in Guardian Settings. Diagnostic escape hatch when persisted
    /// state has drifted into "keeps replaying the same events" or
    /// "won't announce anything anymore" territory.
    func resetAllAnnouncementState() {
        alertLog.notice("resetAllAnnouncementState: wiping \(self.profileStates.count) profile states, \(self.tripLog.values.reduce(0) { $0 + $1.count }) trips")
        synthesizer.stopSpeaking(at: .immediate)
        geocoder.cancelGeocode()
        profileStates = [:]
        tripLog = [:]
        seededProfileUUIDs.removeAll()
        visualAnnouncements.removeAll()
        recentPhrases.removeAll()
    }

    /// Completed trips for a profile, newest first. Used by the
    /// (future) Trips UI. Returns `[]` when there's nothing logged.
    func trips(for profile: MinorProfile) -> [Trip] {
        guard let uuid = profile.id?.uuidString else { return [] }
        return (tripLog[uuid] ?? []).sorted { $0.startAt > $1.startAt }
    }

    // MARK: - Lifecycle

    private func start() {
        guard remoteChangeObserver == nil else { return }
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: PersistenceController.shared.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateOnRecord()
            }
        }
        // Periodic stop-detection tick. `.main` common mode so it
        // fires during scroll on iOS (unlikely for a Guardian device,
        // but cheap insurance).
        stopCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.stopCheckInterval,
                                              repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateStops()
            }
        }
        if let timer = stopCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        configureAudioSession()
    }

    private func stop() {
        if let token = remoteChangeObserver {
            NotificationCenter.default.removeObserver(token)
            remoteChangeObserver = nil
        }
        stopCheckTimer?.invalidate()
        stopCheckTimer = nil
        synthesizer.stopSpeaking(at: .immediate)
        geocoder.cancelGeocode()
        // Wipe the seeded set so a stop+restart cycle runs a fresh
        // silent seeding pass instead of announcing the moment
        // records start arriving again.
        seededProfileUUIDs.removeAll()
        recentPhrases.removeAll()
    }

    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        #endif
    }

    // MARK: - New-record path (motion start)

    /// Called on every remote-change notification. Walks every
    /// profile, updates its state from its newest record, and fires
    /// a "started trip N" announcement if the transition is a fresh
    /// stationary → moving flip.
    private func evaluateOnRecord() {
        guard isGuardianRole else { return }
        let ctx = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        guard let profiles = try? ctx.fetch(request) else { return }
        for profile in profiles {
            evaluate(profile: profile, ctx: ctx)
        }
    }

    /// The service does no work on Minor devices — its whole job is
    /// to react to other people's movement on the Guardian side. On
    /// a Minor iPhone the shared singleton would otherwise still fire
    /// `evaluateOnRecord` on every push (which under Live tracking
    /// is constant), just to fetch profiles and find nothing to
    /// announce. Read the role directly from UserDefaults so we
    /// don't need to observe `AppRoleStore` from a non-view context.
    private var isGuardianRole: Bool {
        UserDefaults.standard.string(forKey: "MapMe.role") == "guardian"
    }

    private func evaluate(profile: MinorProfile, ctx: NSManagedObjectContext) {
        guard let uuid = profile.id?.uuidString else { return }
        guard let newest = latestRecord(for: profile),
              let ts = newest.timestamp else { return }
        // Ignore very-stale imports (bulk historical sync). Fixes
        // within `maxAnnounceableFixAgeSeconds` still count as
        // "current" — see the constant's comment for the rationale
        // for that generous 60-min window.
        guard Date().timeIntervalSince(ts) <= Self.maxAnnounceableFixAgeSeconds else {
            recordFix(uuid: uuid, ts: ts, lat: newest.latitude, lon: newest.longitude,
                      preserveMovingState: true)
            return
        }

        // Startup-seed suppression. FIRST evaluate for each profile
        // this session updates the state silently — no reconnect
        // announcement, no motion announcement, no stop side-effect.
        // After that this profile is marked "seeded" and subsequent
        // evaluate calls follow the normal announce path. This
        // stops a Guardian restart from dumping a burst of catch-up
        // alerts as CloudKit delivers accumulated records.
        //
        // Anchor + isMoving are RESET (not preserved) — persisted
        // state from a previous session can be arbitrarily wrong
        // (device moved a lot while the app was closed) and
        // preserving it caused spurious "started trip" alerts the
        // moment the seeded state met a fresh fix. Fresh session =
        // fresh anchor at the current location + Stationary
        // assumption. The first genuine >50m displacement in this
        // session announces normally.
        let isFirstEvaluateThisSession = !seededProfileUUIDs.contains(uuid)
        if isFirstEvaluateThisSession {
            var seed = profileStates[uuid] ?? ProfileState()
            seed.latestFixAt = ts
            seed.latestFixLat = newest.latitude
            seed.latestFixLon = newest.longitude
            seed.anchorLat = newest.latitude
            seed.anchorLon = newest.longitude
            seed.isMoving = false
            seed.currentTripStartAt = nil
            seed.currentTripStartLat = nil
            seed.currentTripStartLon = nil
            seed.currentTripNumber = nil
            profileStates[uuid] = seed
            seededProfileUUIDs.insert(uuid)
            alertLog.notice("seed profile=\(uuid, privacy: .public) ts=\(ts, privacy: .public) — no announce")
            return
        }

        var state = profileStates[uuid] ?? ProfileState()

        // Reconnect detection — before we overwrite `latestFixAt`,
        // look at the previous value to see if this Minor has been
        // silent long enough to warrant a "back online" announcement.
        // Skipped on the very first fix (previousLastSeen == nil) so
        // the Guardian's fresh install doesn't announce every paired
        // device coming online in a burst.
        let previousLastSeen = state.latestFixAt
        state.latestFixAt = ts
        state.latestFixLat = newest.latitude
        state.latestFixLon = newest.longitude
        if let previous = previousLastSeen,
           Date().timeIntervalSince(previous) >= Self.reconnectSilenceThreshold,
           allowsAnnouncement(uuid: uuid),
           allowsReconnectAnnouncement(state: state)
        {
            let name = nickname(for: profile)
            speak("\(name) is back online.")
            stampAnnouncement(uuid: uuid)
            state.lastReconnectAt = Date()
            // Don't return — a reconnect fix may ALSO cross the
            // motion threshold, in which case the state-machine
            // logic below still fires the "started trip N" alert.
        }

        // If we don't have an anchor yet, seed one from this fix and
        // stay Stationary — announcing on the very first fix a
        // Guardian ever receives would be noise.
        guard let anchorLat = state.anchorLat, let anchorLon = state.anchorLon else {
            state.anchorLat = newest.latitude
            state.anchorLon = newest.longitude
            profileStates[uuid] = state
            return
        }

        let anchorLoc = CLLocation(latitude: anchorLat, longitude: anchorLon)
        let newLoc = CLLocation(latitude: newest.latitude, longitude: newest.longitude)
        let distanceFromAnchor = newLoc.distance(from: anchorLoc)

        if !state.isMoving && distanceFromAnchor >= Self.tripStartDistance {
            // Stationary → Moving: start a new trip.
            state.isMoving = true
            state.tripsCount += 1
            state.currentTripNumber = state.tripsCount
            state.currentTripStartAt = ts
            state.currentTripStartLat = newest.latitude
            state.currentTripStartLon = newest.longitude
            profileStates[uuid] = state
            if allowsAnnouncement(uuid: uuid) {
                let name = nickname(for: profile)
                speak("\(name) started trip \(state.tripsCount).")
                stampAnnouncement(uuid: uuid)
            }
            return
        }

        if state.isMoving && distanceFromAnchor < Self.tripStartDistance {
            // Circling the anchor while nominally Moving — don't
            // change state, but keep the timestamp fresh so the stop
            // timer doesn't misfire.
        }

        profileStates[uuid] = state
    }

    /// Fast path when we don't want to trip any state machine —
    /// just capture the newest fix for `evaluateStops` to reason about.
    private func recordFix(uuid: String, ts: Date, lat: Double, lon: Double,
                           preserveMovingState: Bool) {
        var state = profileStates[uuid] ?? ProfileState()
        state.latestFixAt = ts
        state.latestFixLat = lat
        state.latestFixLon = lon
        profileStates[uuid] = state
    }

    // MARK: - Timer path (motion stop)

    /// Called on the `stopCheckTimer`. Walks every Moving profile and
    /// checks whether it's been silent long enough to conclude
    /// "stopped."
    private func evaluateStops() {
        guard isGuardianRole else { return }
        let now = Date()
        for (uuid, var state) in profileStates {
            // Startup-seed suppression: don't fire "stopped" for a
            // profile the current session hasn't observed a fresh
            // record for yet. Persisted state from the previous
            // session might have left `isMoving = true` with a
            // stale `latestFixAt`, which would spuriously trigger
            // a stop announcement the first time the stop timer
            // ticks after launch. The seeding pass in `evaluate()`
            // resets the anchor + timestamp; until that runs for
            // this profile, we stay silent.
            guard seededProfileUUIDs.contains(uuid) else { continue }
            guard state.isMoving,
                  let latestAt = state.latestFixAt,
                  now.timeIntervalSince(latestAt) >= Self.stopDetectionInterval else {
                continue
            }
            guard let lat = state.latestFixLat, let lon = state.latestFixLon,
                  let tripStartAt = state.currentTripStartAt,
                  let tripStartLat = state.currentTripStartLat,
                  let tripStartLon = state.currentTripStartLon,
                  let tripNumber = state.currentTripNumber else {
                // Missing pieces — bail on this profile without
                // announcing to avoid spurious speech.
                state.isMoving = false
                state.currentTripStartAt = nil
                state.currentTripStartLat = nil
                state.currentTripStartLon = nil
                state.currentTripNumber = nil
                profileStates[uuid] = state
                continue
            }

            // Flip to Stationary and pin the anchor to the resting
            // spot immediately so a spontaneous refresh doesn't
            // re-fire "started trip N+1" for a fix we haven't
            // finished announcing yet.
            state.isMoving = false
            state.anchorLat = lat
            state.anchorLon = lon
            state.currentTripStartAt = nil
            state.currentTripStartLat = nil
            state.currentTripStartLon = nil
            state.currentTripNumber = nil
            profileStates[uuid] = state

            let profileName = resolveNickname(uuid: uuid)
            let stopLocation = CLLocation(latitude: lat, longitude: lon)

            // Reverse-geocode the stop location asynchronously. When
            // it returns (with or without a POI name), close the trip
            // and speak.
            reverseGeocode(stopLocation) { [weak self] placeName in
                // No `isEnabled` gate — visual balloon must fire on
                // stop even when audio is off, matching the split
                // behavior described at the top of the file.
                guard let self else { return }
                Task { @MainActor in
                    let trip = Trip(
                        number: tripNumber,
                        startAt: tripStartAt,
                        startLat: tripStartLat,
                        startLon: tripStartLon,
                        endAt: latestAt,
                        endLat: lat,
                        endLon: lon,
                        endPlaceName: placeName
                    )
                    self.appendTrip(trip, uuid: uuid)
                    if self.allowsAnnouncement(uuid: uuid) {
                        let phrase = placeName.map { "\(profileName) stopped at \($0), trip \(tripNumber)." }
                            ?? "\(profileName) stopped, trip \(tripNumber)."
                        self.speak(phrase)
                        self.stampAnnouncement(uuid: uuid)
                    }
                }
            }
        }
    }

    // MARK: - Trip storage

    private func appendTrip(_ trip: Trip, uuid: String) {
        var trips = tripLog[uuid] ?? []
        trips.append(trip)
        tripLog[uuid] = trips
    }

    // MARK: - Reverse geocoding

    /// Reverse-geocodes `location` and calls `completion` on the main
    /// queue with a friendly place name (POI, or thoroughfare
    /// fallback), or `nil` if geocoding failed / returned nothing
    /// worth speaking. `CLGeocoder`'s free/rate-limited API is enough
    /// for occasional stop alerts — no caching layer needed at this
    /// volume.
    private func reverseGeocode(_ location: CLLocation,
                                completion: @escaping (_ placeName: String?) -> Void) {
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            let name = placemarks?.first.flatMap(Self.friendlyPlaceName(from:))
            DispatchQueue.main.async { completion(name) }
        }
    }

    // nonisolated: pure helper passed into CLGeocoder's background
    // completion handler, so it must not require the main actor.
    private nonisolated static func friendlyPlaceName(from placemark: CLPlacemark) -> String? {
        // Prefer POI names (Starbucks, Central Park). Fall back to
        // thoroughfare (street name) so "stopped at Rookery Ave" is
        // still meaningful even without a POI hit.
        if let poi = placemark.name?.trimmingCharacters(in: .whitespaces).nonEmpty,
           poi != placemark.thoroughfare {
            return poi
        }
        if let street = placemark.thoroughfare?.trimmingCharacters(in: .whitespaces).nonEmpty {
            return street
        }
        return nil
    }

    // MARK: - Debounce + speech

    private func allowsAnnouncement(uuid: String) -> Bool {
        let last = profileStates[uuid]?.lastAnnouncedAt
        let elapsed = last.map { Date().timeIntervalSince($0) } ?? .infinity
        return elapsed >= Self.minAlertSpacing
    }

    /// Extra dedup layer specifically for "back online" reconnect
    /// announcements. Even if the silence-gate + generic
    /// `allowsAnnouncement` gate are both met, a profile that
    /// fired reconnect within `reconnectMinSpacing` isn't allowed
    /// to fire again. Fixes the case where a device oscillates
    /// in-and-out of range across sync bursts.
    private func allowsReconnectAnnouncement(state: ProfileState) -> Bool {
        guard let last = state.lastReconnectAt else { return true }
        return Date().timeIntervalSince(last) >= Self.reconnectMinSpacing
    }

    private func stampAnnouncement(uuid: String) {
        var state = profileStates[uuid] ?? ProfileState()
        state.lastAnnouncedAt = Date()
        profileStates[uuid] = state
    }

    private func resolveNickname(uuid: String) -> String {
        if let custom = nicknames[uuid]?
            .trimmingCharacters(in: .whitespaces).nonEmpty {
            return custom
        }
        // Look up displayName from the store as a fallback.
        let ctx = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<MinorProfile>(entityName: "MinorProfile")
        request.predicate = NSPredicate(format: "id == %@", uuid)
        request.fetchLimit = 1
        if let profile = try? ctx.fetch(request).first,
           let name = profile.displayName?
            .trimmingCharacters(in: .whitespaces).nonEmpty {
            return name
        }
        return "Your device"
    }

    private func speak(_ phrase: String) {
        // Cross-profile phrase dedup. Duplicate `MinorProfile` rows
        // (from re-invites, reinstalls, or CKShare re-accepts) each
        // independently fire the same announcement — without this
        // guard, "Denis' Personal iPhone is back online" plays 5×
        // when there are 5 duplicate iPhone profiles. Balloon dedup
        // handled the visual side; this covers audio too.
        //
        // Window matches the balloon TTL + a little slack. Anything
        // longer starts to swallow legitimate re-announcements
        // (device stops and starts again within the window).
        let now = Date()
        recentPhrases = recentPhrases.filter { now.timeIntervalSince($0.value) < Self.phraseDedupWindow }
        if recentPhrases[phrase] != nil {
            alertLog.notice("dedup: skipping duplicate phrase \(phrase, privacy: .public)")
            return
        }
        recentPhrases[phrase] = now

        alertLog.notice("announce: \(phrase, privacy: .public) audio=\(self.isEnabled) silent=\(self.audioLikelySilent)")
        // Audio path — gated by the user-facing "Speak when a device
        // starts moving" toggle AND by whether audio is even
        // audible right now.
        if isEnabled, !audioLikelySilent {
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.05
            utterance.postUtteranceDelay = 0.1
            synthesizer.speak(utterance)
        }

        // Balloon path — ALWAYS fires. The Guardian sees a visual
        // confirmation of every tracking transition regardless of
        // whether audio is on. This matches the redesigned split:
        // the toggle controls audio only, visual is always available.
        enqueueVisualAnnouncement(phrase)
    }

    /// Recently-spoken phrase → last-emitted timestamp. Used by
    /// `speak()` to short-circuit duplicate announcements arriving
    /// in quick succession from different `MinorProfile` rows. Not
    /// persisted — starting a fresh session gets a fresh dedup
    /// window (the seed pass already suppresses catch-up alerts).
    private var recentPhrases: [String: Date] = [:]
    private static let phraseDedupWindow: TimeInterval = 30

    /// Appends an announcement to the balloon stack and schedules its
    /// auto-expiry. Also caps the stack to avoid unbounded growth
    /// during a burst.
    private func enqueueVisualAnnouncement(_ text: String) {
        // De-duplicate: if the exact same phrase is already on
        // screen (or was queued within the last few seconds), don't
        // stack another copy. Fixes the "5 duplicate MinorProfiles
        // for the same physical iPhone all fire 'is back online'
        // at once → 5 identical balloons" scenario the user saw.
        // The nickname / phrase alone is a good enough key; we
        // don't need to track the source profile.
        let now = Date()
        if visualAnnouncements.contains(where: {
            $0.text == text && now.timeIntervalSince($0.createdAt) < Self.visualAnnouncementTTL
        }) {
            return
        }

        let ann = Announcement(text: text, createdAt: now)
        visualAnnouncements.append(ann)
        if visualAnnouncements.count > Self.maxVisualAnnouncements {
            visualAnnouncements.removeFirst(visualAnnouncements.count - Self.maxVisualAnnouncements)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.visualAnnouncementTTL))
            self?.visualAnnouncements.removeAll { $0.id == ann.id }
        }
    }

    /// `true` when we think a spoken announcement won't be heard.
    /// Two conditions trip this:
    ///   1. The current output volume is below `silentAudioThreshold`.
    ///   2. There's no active audio output route (rare on iPhone,
    ///      common on Apple TV when the receiver is off or between
    ///      HDMI-CEC handshakes).
    ///
    /// On macOS we walk the CoreAudio device tree ourselves since
    /// there's no `AVAudioSession` equivalent for reading the
    /// system default output volume.
    var audioLikelySilent: Bool {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        if session.currentRoute.outputs.isEmpty { return true }
        return session.outputVolume < Self.silentAudioThreshold
        #elseif os(macOS)
        guard let volume = Self.macOSDefaultOutputVolume() else {
            // If we can't read the volume at all, assume the audio
            // won't be heard so the balloon path fires.
            return true
        }
        return volume < Self.silentAudioThreshold
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// Reads the master volume of the default output device via
    /// CoreAudio. Returns `nil` if any of the property queries
    /// fail — caller treats nil as "assume silent."
    private static func macOSDefaultOutputVolume() -> Float? {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout.size(ofValue: deviceID))
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            0, nil,
            &deviceIDSize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != 0 else { return nil }

        var volume: Float32 = 0
        var volumeSize = UInt32(MemoryLayout.size(ofValue: volume))
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volumeStatus = AudioObjectGetPropertyData(
            deviceID,
            &volumeAddress,
            0, nil,
            &volumeSize,
            &volume
        )
        return volumeStatus == noErr ? volume : nil
    }
    #endif

    // MARK: - Fetch helpers

    private func latestRecord(for profile: MinorProfile) -> LocationRecord? {
        // Fetch instead of materialising the whole `records` relationship
        // via `profile.records as? Set<LocationRecord>` — under Live
        // tracking the store can have tens of thousands of rows per
        // profile and the previous approach caused an out-of-memory
        // crash the moment a Minor iPhone opened the Guardian tab
        // (each remote-change notification re-materialised every row
        // just to `.max` them). This runs against the SQLite index and
        // returns exactly one row.
        guard let ctx = profile.managedObjectContext else { return nil }
        let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        request.predicate = NSPredicate(format: "profile == %@", profile)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 1
        return try? ctx.fetch(request).first
    }

    // MARK: - Persistence helpers

    private func saveProfileStates() {
        if let data = try? JSONEncoder().encode(profileStates) {
            UserDefaults.standard.set(data, forKey: Self.kStatesKey)
        }
    }

    private func saveTripLog() {
        if let data = try? JSONEncoder().encode(tripLog) {
            UserDefaults.standard.set(data, forKey: Self.kTripsKey)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespaces).isEmpty ? nil : self
    }
}
#endif

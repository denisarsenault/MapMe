#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
import Foundation
import MapKit
import CoreLocation

/// Serializes `MKDirections.calculate()` calls across the entire app so we
/// stay under Apple's documented short-window throttle (50 requests per 60
/// seconds, observed empirically via `GEOErrorDomain Code=-3` "Throttled
/// Directions request"). Without this, multiple parallel snap Tasks — one per
/// family member's trail in the FamilyDashboardView, for example — each fire
/// directions requests independently and trip the limit within seconds.
private actor DirectionsRateLimiter {
    private var lastFire: Date = .distantPast
    /// 50 / 60 = 0.833 req/s. We pad to 1.5s/req so we never sit at exactly
    /// the ceiling — a little headroom accommodates clock jitter and sub-
    /// second bursts that would otherwise occasionally spill over.
    private let minInterval: TimeInterval = 1.5

    /// When MKDirections actually returns a throttle error
    /// (GEOErrorDomain -3), it tells us how many seconds until the
    /// window resets. We park ALL subsequent `acquire()`s until then,
    /// so a single throttle doesn't cascade into hundreds more
    /// rejected requests (which is exactly what the logs showed).
    private var backOffUntil: Date = .distantPast

    func acquire() async {
        // Respect both the steady-state spacing and any active
        // throttle cooldown. Loop because a long sleep could still
        // leave us inside another constraint when we wake.
        while true {
            let now = Date()
            let spacingWait = minInterval - now.timeIntervalSince(lastFire)
            let cooldownWait = backOffUntil.timeIntervalSince(now)
            let wait = max(spacingWait, cooldownWait)
            if wait <= 0 { break }
            try? await Task.sleep(for: .seconds(wait))
        }
        lastFire = Date()
    }

    /// Park all future requests until `seconds` from now. Called when
    /// a `calculate()` comes back with the GEOErrorDomain throttle
    /// code. Idempotent-ish: only extends the cooldown, never shortens.
    func backOff(seconds: TimeInterval) {
        let until = Date().addingTimeInterval(max(1, seconds))
        if until > backOffUntil { backOffUntil = until }
    }
}

/// Aggregate snap progress across all in-flight Tasks. Lets the UI show
/// "snapping 12/47…" instead of a generic "working" spinner.
struct SnapProgress: Equatable, Sendable {
    var completed: Int
    var total: Int
    var isWorking: Bool { total > 0 && completed < total }
    /// Fraction in 0...1 for a `ProgressView`. Returns 1.0 when idle so a
    /// determinate `ProgressView(value:)` doesn't show a half-empty bar.
    var fraction: Double { total == 0 ? 1.0 : Double(completed) / Double(total) }
}

/// A polyline that carries a stable identity across view re-renders.
/// SwiftUI's `ForEach` uses the `id` to diff its children; trips whose
/// underlying fixes haven't changed keep the same id, which lets
/// `MapPolyline` reuse the same Metal drawable rather than tearing one
/// down and standing a new one up every body invocation.
struct IdentifiedTrip: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    /// `true` for the raw straight-line chord that snap fell back to
    /// when a segment couldn't be routed (gap too wide, time gap too
    /// long, sparse data). Renderers style these differently — dashed
    /// + lighter — so the user can visually tell "this part is
    /// interpolation, not a real path." `false` for everything else,
    /// including the rawTrips output (snap-off mode).
    let isFallback: Bool
    /// Timestamp of the first fix in the trip (or the parent trip,
    /// for fallback/snapped chunks). Optional because some legacy
    /// callers construct trips without timestamps. Renderers use it
    /// to label each polyline with its start time (HH:MM).
    let startDate: Date?

    init(id: String,
         coordinates: [CLLocationCoordinate2D],
         isFallback: Bool = false,
         startDate: Date? = nil) {
        self.id = id
        self.coordinates = coordinates
        self.isFallback = isFallback
        self.startDate = startDate
    }
}

/// A single timestamped GPS fix. `Sendable` so it crosses concurrency
/// boundaries without warnings; `Hashable` so it can participate in cache
/// keys. We deliberately store latitude/longitude as `Double` instead of
/// embedding `CLLocationCoordinate2D` because the C struct isn't `Hashable`
/// or `Sendable` and adding conformances risks duplicate-conformance
/// conflicts with future Apple changes.
struct TimedFix: Sendable, Hashable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date

    init(latitude: Double, longitude: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Map‑matches a sequence of raw GPS fixes to the underlying road network
/// using `MKDirections`. The result is a polyline that follows actual road
/// geometry instead of cutting straight lines across buildings and parks.
///
/// **How it works:** the input trail is first subsampled (drops jitter
/// clusters and reduces the number of segments needed by 5–10×). For each
/// pair of consecutive subsampled coordinates, we ask `MKDirections` for a
/// walking route. The resulting polylines are concatenated. Snapped paths
/// are cached both in memory and on disk (under `Caches/MapMe`) so previously
/// snapped trails are instant on subsequent renders, even across launches.
///
/// **Why walking and not driving:** driving routes return one‑way street
/// directions and force the polyline to follow legal vehicle paths, which
/// looks wrong for a kid walking through a neighbourhood. Walking gives
/// the closest "where they actually were" approximation.
///
/// **Throttling:** all `MKDirections` requests across the app go through a
/// single `DirectionsRateLimiter` actor (1.3 s minimum spacing) so we stay
/// under Apple's 50/min cap even when multiple trails snap in parallel.
@MainActor
final class SnapToRoadsService: ObservableObject {
    static let shared = SnapToRoadsService()

    /// User preference: whether snap-to-roads applies to map views across
    /// the app. Persisted in `UserDefaults` so the toggle survives
    /// relaunch. Default is `true` on iOS, iPadOS, macOS, and tvOS;
    /// `false` on watchOS where every snap is a network round-trip and
    /// battery is at a premium.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.kEnabledKey) }
    }
    private static let kEnabledKey = "MapMe.snapToRoads.enabled"

    /// Draw the raw GPS polyline underneath the snapped one so the user
    /// can see how much got smoothed out. Useful for spot-checking
    /// whether a "missing" trip was actually dropped or just collapsed
    /// into a clean street centerline by `MKDirections`. No effect when
    /// `isEnabled` is false (raw IS the rendered polyline already).
    @Published var showRawOverlay: Bool {
        didSet { UserDefaults.standard.set(showRawOverlay, forKey: Self.kRawOverlayKey) }
    }
    private static let kRawOverlayKey = "MapMe.snapToRoads.showRawOverlay"

    /// One contiguous polyline piece, annotated with whether it's the
    /// real snapped geometry or a raw straight-line chord that snap
    /// fell back to. Renderers style fallback chunks dashed so the
    /// user can tell "this part is interpolation, not a real path."
    struct SnappedChunk {
        let coords: [CLLocationCoordinate2D]
        let isFallback: Bool
    }

    /// Cached snapped polylines, keyed by a hash of the (subsampled)
    /// raw coordinates. Each value is a list of contiguous chunks; a
    /// trip is split into multiple chunks whenever the snap/raw kind
    /// flips so each chunk can be rendered with its own style.
    /// `@Published` so SwiftUI views re‑render when a snap completes.
    @Published private(set) var cache: [String: [SnappedChunk]] = [:]

    /// Whether at least one snap is currently in flight.
    @Published private(set) var isWorking: Bool = false

    /// Aggregate progress across in-flight snaps. UI surfaces this as
    /// "snapping X/Y segments…".
    @Published private(set) var progress: SnapProgress = .init(completed: 0, total: 0)

    /// `true` when at least one currently-cached snapped trail is degraded —
    /// MKDirections throttled us (`GEOErrorDomain -3`) past retry exhaustion,
    /// so some of that trail's segments are showing the raw GPS trace instead
    /// of a road match. The UI surfaces this so a rate-limited render is
    /// distinguishable from a genuine data gap. Clears when those trails
    /// re-snap cleanly (cache invalidation / relaunch) or are evicted.
    @Published private(set) var hasThrottledResults: Bool = false

    /// Cache keys whose latest snap fell back due to throttling. Tracked so
    /// `hasThrottledResults` reflects only trails still in the cache.
    private var throttledKeys: Set<String> = []

    /// Subsampling minimum segment length in metres. 90 m drops standing-
    /// still GPS clusters and dense walking samples, cutting the number of
    /// MKDirections requests sharply without visibly changing the snapped
    /// route (MKDirections fills in the road geometry between waypoints).
    /// Was 50 m, but combined with the wider vehicle snap distance that
    /// generated enough segments to trip Apple's Directions throttle.
    static let subsampleThresholdMeters: CLLocationDistance = 90

    /// On-disk LRU cap. ~128 trails at maybe 5–10 KB each ≈ 1 MB worst case
    /// — small enough to keep, large enough to cover a couple weeks of daily
    /// trails for a family of four.
    private static let maxCacheEntries = 128

    /// Requests currently being computed, deduplicated by cache key.
    private var inFlight: Set<String> = []
    /// Per-in-flight progress used to compute `progress`.
    private var perKeyProgress: [String: (completed: Int, total: Int)] = [:]
    /// Insertion timestamps for cache entries (used for LRU eviction).
    private var entryAddedAt: [String: Date] = [:]

    /// Debounced disk-save task so we don't write on every single update.
    private var pendingSaveTask: Task<Void, Never>?

    private init() {
        if UserDefaults.standard.object(forKey: Self.kEnabledKey) != nil {
            self.isEnabled = UserDefaults.standard.bool(forKey: Self.kEnabledKey)
        } else {
            #if os(watchOS)
            self.isEnabled = false
            #else
            self.isEnabled = true
            #endif
        }
        self.showRawOverlay = UserDefaults.standard.bool(forKey: Self.kRawOverlayKey)
        loadFromDisk()
    }

    /// Time gap (seconds) used to break a stream of fixes into distinct
    /// trips. Two fixes separated by more than this become endpoints of
    /// adjacent trips — the device was stationary or out of contact in
    /// between. 10 min handles "kid sits in class for 50 min, then walks
    /// home" naturally.
    static let tripBreakGapSeconds: TimeInterval = 600

    /// Distance gap (metres) that also forces a trip break, even when
    /// the time gap is below `tripBreakGapSeconds`. Catches the
    /// off-grid case (iPhone XR / standalone watch with no cellular)
    /// where GPS loses lock for several minutes, re-acquires several
    /// km away, and the fixes happen to be within the 10-min window
    /// — without this gate, snap would draw a fictional chord across
    /// the whole gap and the trail would look "sporadic." 2 km is far
    /// enough that a normal cadenced fix at vehicle pace stays under
    /// it (90 s at 60 km/h = 1.5 km) but obviously sparse
    /// lost-lock-and-recovered gaps don't.
    // `nonisolated` so callers running off the main actor (the
    // background persistence task, the detached snap segmenter) can
    // read this constant without crossing the actor boundary — and
    // so the default-argument expression on `segmentIntoTrips` below
    // resolves in any isolation context. Safe because the value is
    // an immutable `let`.
    nonisolated static let tripBreakGapMeters: CLLocationDistance = 2000

    /// Minimum total trip displacement (metres) at or above which a
    /// trip is eligible for `MKDirections` snapping. Below this we
    /// don't snap at all — we render the raw fixes.
    ///
    /// Rationale: at very short distances, `MKDirections` reliably
    /// picks the *nearest road* it can route between the two
    /// endpoints, which is often a parallel street rather than the
    /// one the user is actually on. A user sitting at "651 Rookery
    /// Ave" with the watch GPS drifting a few metres got snapped
    /// onto Phonetia Dr because the drifted coords happened to be
    /// fractionally closer to that street. For a trip that totals
    /// less than 200 m of movement, the raw cluster of fixes near
    /// the actual location is more truthful than a fictional road
    /// route on the wrong street.
    nonisolated static let minSnapTripMeters: CLLocationDistance = 200

    /// Maximum allowed ratio of `snapped-route-length / raw-chord-length`
    /// per segment. A snapped route that's much longer than the
    /// straight-line distance between its endpoints almost always
    /// means MKDirections chose the wrong road and is routing
    /// around the block to get back to the destination. We reject
    /// the snap and use the raw chord instead so the trail doesn't
    /// lie about where the user actually was.
    ///
    /// 1.8× balances: a legitimate snap on a curved street is
    /// typically 1.05–1.4× longer than the chord; a clearly-wrong
    /// snap (out-and-back on a side street) is 2.5× and up.
    nonisolated static let maxSnapStretchRatio: Double = 1.8

    /// Implied speed (km/h) above which a snap segment switches from
    /// `MKDirections` *walking* to *automobile*. Below this we ask for a
    /// walking route — kids cut through parks and along sidewalks that
    /// drivers can't use; walking routes capture that better. Above
    /// 30 km/h the device is clearly in a car or bus, and asking for a
    /// walking route invents a sidewalk path that has nothing to do
    /// with where the vehicle actually drove (the symptom: a 15-km
    /// drive showing up as a fictional walking detour through random
    /// neighbourhoods because MKDirections found "a way to walk it").
    static let vehicleSnapSpeedKmh: Double = 30

    /// Maximum straight-line distance (metres) between two consecutive
    /// fixes for a **walking** snap segment. Pedestrians don't cover
    /// much ground between fixes, so a gap wider than this is almost
    /// certainly missing data — inventing a walking route across it
    /// produces the fictional-detour problem. Falls back to a raw
    /// chord instead.
    static let maxWalkingSnapDistanceMeters: CLLocationDistance = 800

    /// Maximum straight-line distance (metres) between two consecutive
    /// fixes for a **vehicle** snap segment. Cars legitimately cover a
    /// lot of ground between fixes — at 50 km/h the default 90 s
    /// Balanced cadence is ~1.25 km/fix, and even the adaptive Vehicle
    /// interval can space fixes several hundred metres apart. The old
    /// single 800 m cap meant *every* drive fell back to raw chords
    /// (snap looked broken). 5 km lets a real drive snap to actual
    /// roads via `.automobile` while still rejecting absurd
    /// cross-town teleports.
    static let maxVehicleSnapDistanceMeters: CLLocationDistance = 5000

    /// Maximum time delta (seconds) between two consecutive fixes for
    /// snapping. Within a trip, fixes are already ≤ `tripBreakGapSeconds`
    /// apart (wider gaps split the trip), so this is mostly a redundant
    /// safety net at the same 10-min value. Kept explicit so the snap
    /// gate doesn't silently depend on the trip-segmentation constant.
    static let maxSnapTimeDeltaSeconds: TimeInterval = 600  // 10 min

    /// Returns one snapped polyline per trip, where trips are separated
    /// by gaps larger than `tripBreakGapSeconds`. Within each trip,
    /// segments wider than `maxSnapDistanceMeters` or longer than
    /// `maxSnapTimeDeltaSeconds` fall back to raw straight lines instead
    /// of asking `MKDirections` for an invented route. Otherwise the
    /// transport type is picked by speed (`vehicleSnapSpeedKmh`).
    ///
    /// Each returned `IdentifiedTrip` has a stable `id` derived from the
    /// trip's first + last fix timestamps and point count. Stable IDs let
    /// SwiftUI's `ForEach` reuse the same `MapPolyline` (and the Metal
    /// drawable underneath) across re-renders when the trip hasn't
    /// changed — reducing the drawable-lifecycle churn that occasionally
    /// trips MapKit's debug assertion under Metal API Validation.
    func snappedTrips(_ fixes: [TimedFix]) -> [IdentifiedTrip] {
        let trips = Self.segmentIntoTrips(fixes,
                                          maxGapSeconds: Self.tripBreakGapSeconds)
        return trips.enumerated().flatMap { (idx, trip) -> [IdentifiedTrip] in
            let baseID = Self.tripID(trip, index: idx)
            let chunks = snapTripChunks(trip)
            // All chunks of a single trip share its start time (the
            // first fix's timestamp) so the renderer can stamp the
            // *whole* trip — not the chunk — with one label.
            let tripStart = trip.first?.timestamp
            // Tag each chunk with the parent trip ID + the chunk index
            // + its kind so a snap result that flips between snapped
            // and fallback partway through still keeps stable IDs per
            // chunk across renders.
            return chunks.enumerated().map { (chunkIdx, chunk) in
                IdentifiedTrip(
                    id: "\(baseID)#\(chunkIdx)\(chunk.isFallback ? "f" : "s")",
                    coordinates: chunk.coords,
                    isFallback: chunk.isFallback,
                    startDate: tripStart
                )
            }
        }
    }

    /// Same trip segmentation but skips snapping. Used by the raw overlay
    /// path and as a fallback when snap is disabled. Returns one
    /// `IdentifiedTrip` per logical trip, `isFallback: false` (user
    /// has snap off and is intentionally looking at raw geometry, so
    /// there's nothing to dash).
    static func rawTrips(_ fixes: [TimedFix]) -> [IdentifiedTrip] {
        segmentIntoTrips(fixes, maxGapSeconds: tripBreakGapSeconds)
            .enumerated()
            .map { (idx, trip) in
                IdentifiedTrip(
                    id: tripID(trip, index: idx),
                    coordinates: trip.map(\.coordinate),
                    isFallback: false,
                    startDate: trip.first?.timestamp
                )
            }
    }

    /// Stable identity for a trip: composes the first timestamp, last
    /// timestamp, and point count. A new fix appended to the trip changes
    /// the last timestamp and the count → new ID → `ForEach` knows to
    /// refresh that one polyline. Unchanged trips keep the same ID across
    /// renders, so SwiftUI reuses the existing Metal drawables.
    static func tripID(_ trip: [TimedFix], index: Int) -> String {
        guard let first = trip.first, let last = trip.last else {
            return "empty-\(index)"
        }
        return "\(Int(first.timestamp.timeIntervalSince1970))-"
            + "\(Int(last.timestamp.timeIntervalSince1970))-"
            + "\(trip.count)"
    }

    /// Internal: snap a single trip. Subsample first, look in cache, kick
    /// off async snap if missing.
    ///
    /// We deliberately do NOT cap the segment count here. An earlier
    /// version re-strided long trips down to a fixed number of
    /// waypoints to limit MKDirections requests — but striding by
    /// *index* (not distance) opened gaps wider than the snap distance
    /// gate, so those segments fell back to raw straight chords and the
    /// map showed missing/diagonal pieces. Request volume is instead
    /// bounded by the 90 m subsample (a trip can't have more segments
    /// than its length / 90 m) and throttled gracefully by the shared
    /// `DirectionsRateLimiter` (1.5 s spacing + backoff-on-throttle).
    /// Worst case a very long trip snaps slowly; it never loses
    /// segments.
    /// Returns one-or-more contiguous chunks for the trip, each
    /// labelled snapped or fallback. While the async snap is pending,
    /// returns a single placeholder chunk with the raw coords marked
    /// `isFallback: false` (it'll get replaced by the real chunked
    /// result once snap completes — we don't want it dashing
    /// optimistically during the loading flash).
    private func snapTripChunks(_ trip: [TimedFix]) -> [SnappedChunk] {
        guard trip.count >= 2 else {
            return [SnappedChunk(coords: trip.map(\.coordinate), isFallback: false)]
        }
        // Micro-trip guard: don't ask MKDirections to route trips
        // whose total displacement is too small. At sub-200 m scale
        // the routing engine reliably picks the nearest parallel
        // street rather than the one the user is actually on (the
        // "at home, snapped onto Phonetia Dr instead of Rookery Ave"
        // case). Raw fixes near the actual location are more
        // truthful than a fictional snap to the wrong road.
        if Self.totalDisplacement(trip) < Self.minSnapTripMeters {
            return [SnappedChunk(coords: trip.map(\.coordinate), isFallback: false)]
        }
        let sampled = Self.subsample(trip,
                                     minSegmentMeters: Self.subsampleThresholdMeters)
        let key = cacheKey(sampled.map(\.coordinate))
        if let cached = cache[key] { return cached }
        scheduleSnap(key: key, fixes: sampled)
        return [SnappedChunk(coords: trip.map(\.coordinate), isFallback: false)]
    }

    /// Sum of consecutive raw-chord distances across the trip.
    /// Used by the micro-trip snap guard. Returns 0 for ≤1-fix trips.
    nonisolated private static func totalDisplacement(_ trip: [TimedFix]) -> CLLocationDistance {
        guard trip.count >= 2 else { return 0 }
        var total: CLLocationDistance = 0
        for i in 1..<trip.count {
            let a = CLLocation(latitude: trip[i - 1].latitude, longitude: trip[i - 1].longitude)
            let b = CLLocation(latitude: trip[i].latitude,     longitude: trip[i].longitude)
            total += b.distance(from: a)
        }
        return total
    }

    /// Splits a chronologically-sorted sequence of fixes into separate
    /// trips, breaking wherever the gap between consecutive fixes exceeds
    /// `maxGapSeconds`. Empty input → empty output. Single-fix trips are
    /// kept so the caller can decide whether to render them as a point.
    static func segmentIntoTrips(_ fixes: [TimedFix],
                                 maxGapSeconds: TimeInterval,
                                 maxGapMeters: CLLocationDistance = tripBreakGapMeters) -> [[TimedFix]]
    {
        guard !fixes.isEmpty else { return [] }
        var trips: [[TimedFix]] = []
        var current: [TimedFix] = [fixes[0]]
        for i in 1..<fixes.count {
            let fix = fixes[i]
            let last = current[current.count - 1]
            let dt = fix.timestamp.timeIntervalSince(last.timestamp)
            let lastLoc = CLLocation(latitude: last.latitude, longitude: last.longitude)
            let thisLoc = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
            let distance = thisLoc.distance(from: lastLoc)
            // Break on EITHER a long time gap OR a long distance gap.
            // The distance gate catches the off-grid case where GPS
            // re-acquires several km away within the time window —
            // without it, the next segment would render as a single
            // fictional chord across the whole gap.
            if dt > maxGapSeconds || distance > maxGapMeters {
                trips.append(current)
                current = [fix]
            } else {
                current.append(fix)
            }
        }
        trips.append(current)
        return trips
    }

    /// Drops cached snapped routes (in-memory and on-disk).
    func invalidateCache() {
        cache.removeAll()
        entryAddedAt.removeAll()
        throttledKeys.removeAll()
        hasThrottledResults = false
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    // MARK: - Subsampling

    /// Reduces a trail to a sparser sequence by skipping points that are
    /// closer than `minSegmentMeters` to the previous kept point. The
    /// first and last points are always preserved so the trail's true
    /// endpoints don't move. Typical urban walks (1–3 m apart raw points)
    /// reduce by ~10–20× — a 100-point trail becomes ~5–10 snap segments.
    /// Timestamps ride along so the snap step can apply speed/time gating.
    static func subsample(_ fixes: [TimedFix],
                          minSegmentMeters: CLLocationDistance) -> [TimedFix]
    {
        guard fixes.count > 2 else { return fixes }
        var result: [TimedFix] = [fixes[0]]
        var lastKept = CLLocation(latitude: fixes[0].latitude,
                                  longitude: fixes[0].longitude)
        for i in 1..<(fixes.count - 1) {
            let here = CLLocation(latitude: fixes[i].latitude,
                                  longitude: fixes[i].longitude)
            if here.distance(from: lastKept) >= minSegmentMeters {
                result.append(fixes[i])
                lastKept = here
            }
        }
        result.append(fixes.last!)
        return result
    }

    // MARK: - Internal scheduling

    private func scheduleSnap(key: String, fixes: [TimedFix]) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let segmentCount = max(0, fixes.count - 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.perKeyProgress[key] = (completed: 0, total: segmentCount)
            self.recomputeProgress()
        }

        Task { [weak self] in
            let (snapped, complete) = await Self.compute(fixes: fixes)
            await MainActor.run {
                guard let self else { return }
                // Cache in memory either way so we don't re-request the
                // same trip this session. But only persist to disk +
                // mark it for LRU when the snap was COMPLETE — if some
                // segments fell back to raw because we got throttled,
                // we don't want that degraded result frozen into the
                // on-disk cache. A later launch re-snaps it cleanly.
                self.cache[key] = snapped
                if complete {
                    self.entryAddedAt[key] = Date()
                    self.throttledKeys.remove(key)
                } else {
                    // Incomplete == throttled (the only path that sets
                    // `complete = false`). Flag it so the UI can show the
                    // render is rate-limited, not data-gapped.
                    self.throttledKeys.insert(key)
                }
                self.hasThrottledResults = !self.throttledKeys.isEmpty
                self.inFlight.remove(key)
                self.perKeyProgress.removeValue(forKey: key)
                self.recomputeProgress()
                self.evictIfNeeded()
                if complete {
                    self.scheduleDiskSave()
                }
            }
        }
    }

    private func recomputeProgress() {
        var completed = 0
        var total = 0
        for (_, p) in perKeyProgress {
            completed += p.completed
            total += p.total
        }
        progress = SnapProgress(completed: completed, total: total)
        isWorking = !inFlight.isEmpty
    }

    private func evictIfNeeded() {
        guard cache.count > Self.maxCacheEntries else { return }
        let sorted = entryAddedAt.sorted { $0.value < $1.value }
        let removeCount = cache.count - Self.maxCacheEntries
        for (key, _) in sorted.prefix(removeCount) {
            cache.removeValue(forKey: key)
            entryAddedAt.removeValue(forKey: key)
            throttledKeys.remove(key)
        }
        hasThrottledResults = !throttledKeys.isEmpty
    }

    /// Process-wide throttle for `MKDirections.calculate()`. Shared across
    /// every `compute()` invocation so parallel snap Tasks (multiple trails
    /// snapping at once) collectively stay under Apple's 50/min cap.
    private static let limiter = DirectionsRateLimiter()

    /// Snaps a subsampled trip. Returns a list of contiguous chunks
    /// (each labelled snapped or fallback) plus a `complete` flag —
    /// `false` means at least one segment fell back to raw because
    /// MKDirections throttled us past retry exhaustion, so the caller
    /// should keep the result in memory but NOT freeze it into the
    /// on-disk cache.
    ///
    /// Chunk boundaries fall wherever the snap/raw kind changes, so a
    /// trip that snaps fine for a while then hits a sparse-gap chord
    /// then resumes snapping comes back as three chunks: snapped /
    /// fallback / snapped. Renderers style fallback chunks as dashed
    /// to make the interpolation visible.
    private static func compute(
        fixes: [TimedFix]
    ) async -> (chunks: [SnappedChunk], complete: Bool) {
        let total = max(0, fixes.count - 1)
        var chunks: [SnappedChunk] = []
        var current: (coords: [CLLocationCoordinate2D], isFallback: Bool)? = nil
        var complete = true

        // Append a snapped/raw segment to the current chunk if its
        // kind matches; otherwise close the current chunk and open a
        // new one. The first coord of a follow-on segment duplicates
        // the previous segment's endpoint, so we drop it when merging.
        func appendSegment(_ segCoords: [CLLocationCoordinate2D],
                           isFallback kind: Bool) {
            guard !segCoords.isEmpty else { return }
            if var cur = current, cur.isFallback == kind {
                cur.coords.append(contentsOf: segCoords.dropFirst())
                current = cur
            } else {
                if let cur = current {
                    chunks.append(SnappedChunk(coords: cur.coords, isFallback: cur.isFallback))
                }
                // Start the new chunk with the shared endpoint so the
                // visual line stays connected across the kind boundary
                // (otherwise there'd be a 1-segment gap at every flip).
                var start: [CLLocationCoordinate2D] = []
                if let prevLast = current?.coords.last {
                    start = [prevLast]
                }
                start.append(contentsOf: segCoords)
                current = (coords: start, isFallback: kind)
            }
        }

        for i in 0..<total {
            let from = fixes[i]
            let to = fixes[i + 1]
            let fromCoord = from.coordinate
            let toCoord = to.coordinate

            let fromLoc = CLLocation(latitude: from.latitude, longitude: from.longitude)
            let toLoc = CLLocation(latitude: to.latitude, longitude: to.longitude)
            let distance = fromLoc.distance(from: toLoc)
            let timeDelta = max(1, to.timestamp.timeIntervalSince(from.timestamp))
            let speedKmh = (distance / 1000) / (timeDelta / 3600)

            // Pick the MKDirections transport type by implied speed
            // FIRST, because the acceptable gap distance depends on it.
            // Vehicle-pace segments must use `.automobile` — otherwise
            // MKDirections returns a *walking* route, which can wander
            // through neighbourhoods the car never touched (the long
            // Orange City / Lake Helen detour symptom). Walking pace
            // stays on `.walking`, which captures kid-on-foot shortcuts
            // (parks, alleys, footpaths) that `.automobile` would
            // refuse.
            let isVehicle = speedKmh > vehicleSnapSpeedKmh
            let transportType: MKDirectionsTransportType = isVehicle
                ? .automobile
                : .walking
            // Mode-aware distance gate. Walking gaps must be small
            // (pedestrians don't cover ground fast — a big gap means
            // missing data, and a fake walking route across it is the
            // fictional-detour bug). Vehicle gaps can be large (a car
            // really does cover 1–5 km between fixes at speed), so a
            // single tight cap would make every drive fall back to raw
            // chords and snap would look broken.
            let maxDistance = isVehicle
                ? maxVehicleSnapDistanceMeters
                : maxWalkingSnapDistanceMeters

            // Hard gates: fall back to a raw straight chord (so the
            // user SEES the sparse gap rather than a fictional route).
            //   - GPS jitter (< 10 m): the two fixes are essentially
            //     the same point; snapping just round-trips for no gain.
            //   - distance > maxDistance: too sparse for this mode.
            //   - timeDelta > maxSnapTimeDeltaSeconds: ditto, time-wise.
            //   - implausible speed (> 250 km/h): teleport / stale fix.
            if distance < 10
                || distance > maxDistance
                || timeDelta > maxSnapTimeDeltaSeconds
                || speedKmh > 250
            {
                // Hard-gate raw fallback — flagged so the renderer can
                // dash it.
                appendSegment([fromCoord, toCoord], isFallback: true)
                continue
            }

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: fromCoord))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: toCoord))
            request.transportType = transportType
            request.requestsAlternateRoutes = false

            // Snap this segment, retrying through a throttle. We do NOT
            // fall back to raw just because we got throttled — that's
            // what produced visible missing/diagonal segments. Instead,
            // on a GEOErrorDomain -3 we park the shared limiter for the
            // reset window and retry the SAME segment; once the window
            // clears the retry succeeds and the route stays continuous.
            // Only a genuine routing failure (no route exists, bad
            // coordinates) falls back to a raw chord.
            var segmentCoords: [CLLocationCoordinate2D]? = nil
            var throttleRetries = 0
            while segmentCoords == nil {
                // Globally serialize calls to stay under MKDirections'
                // 50/min throttle (spacing) and honour any active
                // backoff window before firing.
                await limiter.acquire()
                do {
                    let response = try await MKDirections(request: request).calculate()
                    if let route = response.routes.first {
                        let polyline = route.polyline
                        var coords = [CLLocationCoordinate2D](
                            repeating: CLLocationCoordinate2D(),
                            count: polyline.pointCount
                        )
                        polyline.getCoordinates(
                            &coords,
                            range: NSRange(location: 0, length: polyline.pointCount)
                        )
                        // Snap-quality guard. If the route MKDirections
                        // returned is meaningfully longer than the
                        // straight-line distance between the two
                        // endpoints, it almost certainly chose the
                        // wrong road and is detouring around the
                        // block. Reject it and fall back to the raw
                        // chord — better to under-draw a curved road
                        // than to misattribute the user's path to a
                        // street they were never on.
                        if route.distance > distance * Self.maxSnapStretchRatio {
                            segmentCoords = [fromCoord, toCoord]
                        } else {
                            segmentCoords = coords
                        }
                    } else {
                        // Empty route response (no path exists): accept
                        // the raw straight line for this segment.
                        segmentCoords = [fromCoord, toCoord]
                    }
                } catch {
                    let nsError = error as NSError
                    let throttled = nsError.domain == "GEOErrorDomain" && nsError.code == -3
                    if throttled, throttleRetries < 3 {
                        // Park the limiter for the reset window, then
                        // retry the same segment (don't lose it).
                        throttleRetries += 1
                        let reset = (nsError.userInfo["timeUntilReset"] as? NSNumber)?
                            .doubleValue ?? 60
                        await limiter.backOff(seconds: reset)
                        continue
                    }
                    // Throttle retries exhausted, or a non-throttle
                    // failure: fall back to raw and mark incomplete so
                    // the result isn't frozen into the disk cache.
                    if throttled { complete = false }
                    segmentCoords = [fromCoord, toCoord]
                }
            }

            // Determine fallback flag for this segment: if MKDirections
            // returned a route, the coords contain its polyline → snapped
            // chunk. If it returned an empty route, or all retries hit
            // throttle, segmentCoords is just [from, to] → fallback chunk.
            let coords = segmentCoords ?? [fromCoord, toCoord]
            // Heuristic: a "real" snap returns the route geometry which
            // is typically several intermediate points between from and
            // to. A fallback is exactly the 2-point straight line. We
            // also pass through `complete=false` info — fallback after
            // throttle exhaustion both forces this segment to fallback
            // AND marks the whole result incomplete (no disk cache).
            let isFallback = coords.count <= 2
            appendSegment(coords, isFallback: isFallback)
        }

        if let cur = current {
            chunks.append(SnappedChunk(coords: cur.coords, isFallback: cur.isFallback))
        }
        return (chunks, complete)
    }

    private func cacheKey(_ coords: [CLLocationCoordinate2D]) -> String {
        // 5 decimals ≈ 1 m precision — stable enough that minor numerical
        // wobble doesn't bust the cache, fine enough that two genuinely
        // different paths get different keys.
        coords.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
            .joined(separator: "|")
    }

    // MARK: - Disk persistence

    /// Codable wrapper. CLLocationCoordinate2D itself is a C struct without
    /// Codable conformance, and adding it would risk duplicate-conformance
    /// conflicts with future Apple changes — wrap explicitly instead.
    private struct StoredCoord: Codable {
        let lat: Double
        let lon: Double
        init(_ c: CLLocationCoordinate2D) {
            self.lat = c.latitude
            self.lon = c.longitude
        }
        var coord: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private struct StoredChunk: Codable {
        let coords: [StoredCoord]
        let isFallback: Bool
    }

    private struct DiskEntry: Codable {
        let key: String
        let chunks: [StoredChunk]
        let addedAt: Date
    }

    private struct DiskCache: Codable {
        let version: Int
        let entries: [DiskEntry]
    }

    // `nonisolated` so the background `persistToDisk` Task.detached can read
    // these without hopping back to the MainActor. Pure compile-time / stable
    // values — no actor-protected state.
    //
    // v2: tightened snap gates + added the `.automobile` transport
    //     branch for vehicle-pace segments.
    // v3: mode-aware distance gate (800 m walking / 5 km vehicle).
    // v4: subsample 50 m → 90 m + per-trip segment cap.
    // v5: removed the segment cap — striding by index opened gaps
    //     wider than the snap distance gate, so capped trips rendered
    //     missing/diagonal raw segments. Throttle handled by retry-
    //     after-backoff instead.
    // v6: cached value type changed from a flat `[StoredCoord]`
    //     polyline to `[StoredChunk]` so each fallback chord can
    //     be rendered dashed independently from the snapped
    //     portions. v5 entries can't be deserialized into the new
    //     shape; bump invalidates them cleanly.
    // v7 (this bump): trip-level micro-trip guard (< 200 m total
    //     displacement → no snap) + per-segment stretch-ratio
    //     guard (snap rejected if > 1.8× straight distance). v6
    //     entries that captured wrong-road routes from before the
    //     guards have to be flushed; bump invalidates them.
    nonisolated private static let cacheVersion = 7

    /// `Caches/MapMe/snap-roads-cache.json`. We use `.cachesDirectory` (not
    /// `.applicationSupportDirectory`) because this data is rebuildable from
    /// source records — the system may evict it under storage pressure and
    /// the app keeps working. The first cold render after eviction just
    /// re-snaps from MKDirections.
    nonisolated private static var cacheURL: URL {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MapMe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("snap-roads-cache.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let disk = try? JSONDecoder().decode(DiskCache.self, from: data),
              disk.version == Self.cacheVersion
        else { return }
        for entry in disk.entries {
            cache[entry.key] = entry.chunks.map {
                SnappedChunk(coords: $0.coords.map(\.coord),
                             isFallback: $0.isFallback)
            }
            entryAddedAt[entry.key] = entry.addedAt
        }
    }

    private func scheduleDiskSave() {
        // Debounce: cancel any pending write and re-arm. Multiple snaps
        // completing in quick succession (e.g. the four-family-member case)
        // collapse into one disk write a couple seconds after the last.
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            // `persistToDisk` is a synchronous MainActor-isolated method;
            // this Task is already MainActor-isolated (inherited from
            // `scheduleDiskSave`'s caller), so no `await` is needed and
            // Swift 6 would warn "No 'async' operations occur within
            // 'await' expression" if we kept it.
            self?.persistToDisk()
        }
    }

    private func persistToDisk() {
        // Snapshot on MainActor (we are MainActor-isolated), then encode +
        // write off the main thread so a large cache doesn't stutter the UI.
        // We pre-flatten SnappedChunk into a Sendable [(coords, isFallback)]
        // tuple here so the Task.detached closure doesn't capture
        // SnappedChunk by reference into a non-Sendable context.
        let snapshot: [(String, [(coords: [CLLocationCoordinate2D], isFallback: Bool)], Date)] = cache.map { (k, chunks) in
            (k,
             chunks.map { (coords: $0.coords, isFallback: $0.isFallback) },
             entryAddedAt[k] ?? Date())
        }
        Task.detached(priority: .background) {
            let entries = snapshot.map { (k, chunks, addedAt) in
                DiskEntry(
                    key: k,
                    chunks: chunks.map {
                        StoredChunk(coords: $0.coords.map { StoredCoord($0) },
                                    isFallback: $0.isFallback)
                    },
                    addedAt: addedAt
                )
            }
            let disk = DiskCache(version: Self.cacheVersion, entries: entries)
            if let data = try? JSONEncoder().encode(disk) {
                try? data.write(to: Self.cacheURL, options: .atomic)
            }
        }
    }
}
#endif

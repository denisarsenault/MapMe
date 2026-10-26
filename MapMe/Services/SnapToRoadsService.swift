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

/// Deterministic 64-bit FNV-1a, used to build snap cache keys.
///
/// Deliberately **not** Swift's `Hasher`: that is seeded per process, so
/// keys derived from it wouldn't match across launches and the on-disk
/// cache would never hit. FNV-1a is stable forever, cheap (one multiply +
/// xor per byte, no allocation), and 64 bits is far more than enough to
/// keep collisions out of a cache that holds ≤ 128 trails.
///
/// Coordinates are quantized to 1e-5 degrees (~1 m) before hashing, which
/// preserves the old keys' tolerance for numerical wobble.
struct FNV1a {
    private var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    mutating func combine(_ value: Int64) {
        var v = UInt64(bitPattern: value)
        for _ in 0..<8 {
            hash = (hash ^ (v & 0xff)) &* Self.prime
            v >>= 8
        }
    }

    /// Quantize to ~1 m and fold in. Matches the precision of the
    /// `"%.5f"` keys this replaced.
    mutating func combine(_ coordinate: CLLocationCoordinate2D) {
        combine(Int64((coordinate.latitude * 100_000).rounded()))
        combine(Int64((coordinate.longitude * 100_000).rounded()))
    }

    mutating func combine(_ fix: TimedFix) {
        combine(fix.coordinate)
        combine(Int64(fix.timestamp.timeIntervalSince1970))
    }

    var value: UInt64 { hash }

    /// Hex form, for the `String`-keyed caches (the on-disk cache
    /// serializes its keys as JSON object names).
    var keyString: String { String(hash, radix: 16) }
}

/// Great-circle distance in metres between two coordinates.
///
/// Exists because the trip pipeline (`segmentIntoTrips`, `subsample`,
/// `totalDisplacement`) runs on the main actor inside a SwiftUI `body`,
/// once per profile, and previously allocated two `CLLocation` objects per
/// fix per pass. On a Live Guardian view — 30 fps marker tweening × three
/// passes × a few thousand fixes × N profiles — that was tens of thousands
/// of ObjC allocations and their ARC traffic per frame, which is what made
/// the interface feel heavy with snap on. This does the same job in
/// registers.
///
/// Haversine on a spherical Earth is within ~0.3 % of `CLLocation`'s
/// ellipsoidal result — irrelevant against thresholds of 10 m, 90 m,
/// 200 m, 800 m and 5 km.
@inline(__always)
func metersBetween(_ a: CLLocationCoordinate2D,
                   _ b: CLLocationCoordinate2D) -> CLLocationDistance {
    let earthRadius: Double = 6_372_797.6
    let toRad = Double.pi / 180
    let dLat = (b.latitude - a.latitude) * toRad
    let dLon = (b.longitude - a.longitude) * toRad
    let lat1 = a.latitude * toRad
    let lat2 = b.latitude * toRad
    let sinDLat = sin(dLat / 2)
    let sinDLon = sin(dLon / 2)
    let h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLon * sinDLon
    return 2 * earthRadius * asin(min(1, h.squareRoot()))
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

    /// Per-**segment** snap cache. Key is the (rounded) coord-pair;
    /// value is the snapped polyline (or `.fallback` when
    /// MKDirections legitimately couldn't route or returned a
    /// route we rejected by stretch-ratio). Populated whenever a
    /// segment gets its first successful snap and reused across
    /// every subsequent whole-trip snap that walks over the same
    /// pair.
    ///
    /// Why this exists: `cache` above is keyed by the FULL sequence
    /// of subsampled coords. On the Guardian's Live view of a
    /// device that's actively writing fixes (especially the watch,
    /// now that we drove `distanceFilter` down to 20 m), the trip
    /// grows by a point every 15-30 s and every append mints a new
    /// whole-trip key → the trip-level cache never hits and the
    /// polyline sits in the raw placeholder forever. The
    /// segment-level cache turns each fresh whole-trip snap into
    /// "N-1 instant hits + 1 MKDirections call for the new tail",
    /// which typically returns fast enough that the next render
    /// finds the new trip key populated and swaps to snapped
    /// geometry before the wearer takes another few steps.
    ///
    /// Not `@Published` — mutations from `MainActor.run` after each
    /// `compute()` completion flow through `cache`'s own change
    /// signal, which is what actually drives the re-render.
    private var segmentCache: [String: SegmentSnap] = [:]
    /// Insertion timestamps for `segmentCache` LRU eviction.
    private var segmentAddedAt: [String: Date] = [:]
    /// In-memory cap for `segmentCache`. Each entry is a segment's
    /// snapped polyline coords (typically 20-100 CLLocationCoord2Ds
    /// ≈ 400 B – 2 KB). LRU-evicted past the cap. tvOS gets a much
    /// smaller cap: the 4th-gen Apple TV (`AppleTV5,3`) runs with
    /// ~256 MB app budget and jetsam-killed the process when the
    /// segment + whole-trip caches accumulated under Live tracking.
    /// 400 entries covers a couple of days of walking for a small
    /// family and stays comfortably inside the tvOS envelope.
    #if os(tvOS)
    private static let maxSegmentCacheEntries = 400
    #else
    private static let maxSegmentCacheEntries = 2000
    #endif

    /// One segment's snap result. `.snapped(coords)` is the route
    /// polyline returned by MKDirections. `.fallback` means either
    /// MKDirections gave us no route at all, or the route it gave
    /// us was rejected by the stretch-ratio guard — in both cases
    /// the renderer draws the raw chord between endpoints.
    enum SegmentSnap: Sendable {
        case snapped([CLLocationCoordinate2D])
        case fallback
    }

    /// Cache key for one segment pair, quantized to 5 decimals
    /// (~1 m precision at temperate latitudes). Two subsequent
    /// snap runs that pass through the same waypoint pair — even
    /// as the whole-trip key churns — hit the same segment cache
    /// entry.
    ///
    /// Built from `stableHash` rather than `String(format:)`: a
    /// whole-trip snap calls this once per segment, and on the
    /// Guardian's Live view that ran on every 30 fps marker tick.
    /// Formatting four doubles per segment was a measurable slice
    /// of each frame's main-thread budget for no benefit — the key
    /// is never shown to anyone, it only has to be stable.
    fileprivate static func segmentKey(_ from: CLLocationCoordinate2D,
                                       _ to: CLLocationCoordinate2D) -> String {
        var h = FNV1a()
        h.combine(from)
        h.combine(to)
        return h.keyString
    }

    /// Memoized `snappedTrips(_:)` output, keyed by a stable hash of the
    /// input fixes. Dropped wholesale whenever `cache` changes (see
    /// `invalidateTripsMemo`), so a memo can never outlive the snap
    /// result it was derived from.
    ///
    /// Why this matters: `snappedTrips` is called from inside a SwiftUI
    /// `body`, and the Guardian views re-render constantly for reasons
    /// that have nothing to do with the trail data — the Live marker
    /// animator ticks at 30 fps, CoreData remote-change notifications
    /// fire on every incoming fix, and this service's own `isWorking` /
    /// `progress` publishes invalidate the view too. Each of those used
    /// to re-run trip segmentation, the micro-trip displacement sum,
    /// subsampling and cache-key construction for every profile on
    /// screen. With snap off, `rawTrips` skips three of those four
    /// passes — which is exactly why the lag showed up only with snap
    /// on. Now identical input is answered from the memo in one hash
    /// pass, and real work happens only when the fixes or the snap
    /// cache actually change.
    /// A memoized result plus the set of trip cache keys it consulted
    /// while being built. Tracking the dependencies lets a completing
    /// snap invalidate only the trails that were actually waiting on it
    /// — with several devices on screen, each snap completion otherwise
    /// dropped every profile's memo, and since snaps complete
    /// continuously (the rate limiter spaces them 1.5 s apart) no memo
    /// survived long enough to be used.
    private struct TripsMemo {
        let trips: [IdentifiedTrip]
        let dependsOn: Set<String>
    }

    private var tripsMemo: [UInt64: TripsMemo] = [:]

    /// Collects the trip cache keys consulted by the in-progress
    /// `computeSnappedTrips` call. Non-nil only for the duration of that
    /// call, which is synchronous and MainActor-isolated, so there's no
    /// reentrancy to worry about.
    private var currentLookupKeys: Set<String>?

    /// Memo cap. One entry per (profile, trail) currently on screen, so
    /// a handful in practice; the cap only guards against a view that
    /// churns its input in a way we didn't anticipate.
    private static let maxTripsMemoEntries = 32

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
    /// trails for a family of four. tvOS uses a much smaller cap (24) to
    /// stay inside the 4th-gen Apple TV's ~256 MB app budget; the cache
    /// is a nice-to-have rather than a correctness feature, so trimming
    /// it there costs a few extra MKDirections calls but no user-visible
    /// data.
    #if os(tvOS)
    private static let maxCacheEntries = 24
    #else
    private static let maxCacheEntries = 128
    #endif

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
        // One cheap, allocation-free hash pass stands in for the whole
        // pipeline below when nothing has changed since the last render.
        var h = FNV1a()
        h.combine(Int64(fixes.count))
        for fix in fixes { h.combine(fix) }
        let memoKey = h.value
        if let memo = tripsMemo[memoKey] { return memo.trips }

        currentLookupKeys = []
        let result = computeSnappedTrips(fixes)
        let dependsOn = currentLookupKeys ?? []
        currentLookupKeys = nil

        if tripsMemo.count >= Self.maxTripsMemoEntries { tripsMemo.removeAll() }
        tripsMemo[memoKey] = TripsMemo(trips: result, dependsOn: dependsOn)
        return result
    }

    /// Uncached body of `snappedTrips(_:)`.
    private func computeSnappedTrips(_ fixes: [TimedFix]) -> [IdentifiedTrip] {
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
        // Record the dependency so the memo holding this result is
        // dropped when — and only when — this key's snap lands.
        currentLookupKeys?.insert(key)
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
            total += metersBetween(trip[i - 1].coordinate, trip[i].coordinate)
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
            let distance = metersBetween(last.coordinate, fix.coordinate)
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

    /// Drops every memoized `snappedTrips` result. Must be called from
    /// anywhere `cache` is mutated: a memo built while a trip was still
    /// showing its raw placeholder would otherwise keep being returned
    /// after the real snapped geometry landed, and the polyline would
    /// never swap.
    private func invalidateTripsMemo() {
        tripsMemo.removeAll(keepingCapacity: true)
    }

    /// Targeted variant: drops only the memos that consulted `key`.
    /// Everything else — every other device's trail on the same map —
    /// keeps its memo and stays off the recompute path.
    private func invalidateTripsMemo(dependingOn key: String) {
        guard !tripsMemo.isEmpty else { return }
        for (memoKey, memo) in tripsMemo where memo.dependsOn.contains(key) {
            tripsMemo.removeValue(forKey: memoKey)
        }
    }

    /// Drops cached snapped routes (in-memory and on-disk).
    func invalidateCache() {
        cache.removeAll()
        invalidateTripsMemo()
        entryAddedAt.removeAll()
        throttledKeys.removeAll()
        segmentCache.removeAll()
        segmentAddedAt.removeAll()
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
        result.reserveCapacity(fixes.count / 8 + 2)
        var lastKept = fixes[0].coordinate
        for i in 1..<(fixes.count - 1) {
            let here = fixes[i].coordinate
            if metersBetween(here, lastKept) >= minSegmentMeters {
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

        // Snapshot the per-segment cache so `compute()` can look up
        // previously-snapped pairs without a MainActor hop. Dict
        // value-type copy is cheap (Swift COW) — mutations we
        // make below never leak back into `existing`.
        let existing = self.segmentCache

        Task { [weak self] in
            let (snapped, complete, newSegments) = await Self.compute(
                fixes: fixes, existing: existing
            )
            await MainActor.run {
                guard let self else { return }
                // Cache in memory either way so we don't re-request the
                // same trip this session. But only persist to disk +
                // mark it for LRU when the snap was COMPLETE — if some
                // segments fell back to raw because we got throttled,
                // we don't want that degraded result frozen into the
                // on-disk cache. A later launch re-snaps it cleanly.
                self.cache[key] = snapped
                self.invalidateTripsMemo(dependingOn: key)
                if complete {
                    self.entryAddedAt[key] = Date()
                    self.throttledKeys.remove(key)
                } else {
                    // Incomplete == throttled (the only path that sets
                    // `complete = false`). Flag it so the UI can show the
                    // render is rate-limited, not data-gapped.
                    self.throttledKeys.insert(key)
                }
                // Merge each newly-snapped segment into the shared
                // per-segment cache so subsequent whole-trip snaps
                // (Live-mode re-runs after another fix appends) reuse
                // them and don't spend MKDirections calls on the
                // stable prefix.
                let now = Date()
                for (segKey, snap) in newSegments {
                    self.segmentCache[segKey] = snap
                    self.segmentAddedAt[segKey] = now
                }
                self.evictSegmentCacheIfNeeded()
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

    private func evictSegmentCacheIfNeeded() {
        guard segmentCache.count > Self.maxSegmentCacheEntries else { return }
        let sorted = segmentAddedAt.sorted { $0.value < $1.value }
        let removeCount = segmentCache.count - Self.maxSegmentCacheEntries
        for (key, _) in sorted.prefix(removeCount) {
            segmentCache.removeValue(forKey: key)
            segmentAddedAt.removeValue(forKey: key)
        }
    }

    /// Trailing-edge coalescing window for `progress` / `isWorking`
    /// publishes. Both are purely cosmetic (the "snapping 3/9…" badge),
    /// but each assignment invalidates every view observing this service
    /// — which on a Guardian dashboard means re-running the CoreData
    /// fetch and map content build for every profile on screen. A snap
    /// storm (one trip per profile, each flipping isWorking on and off)
    /// turned that into a stream of full-dashboard rebuilds. 250 ms
    /// keeps the badge feeling live while capping the cost at 4
    /// invalidations per second.
    private static let progressPublishInterval: TimeInterval = 0.25
    private var progressPublishTask: Task<Void, Never>?

    /// Coalesced. Recomputes and publishes at most once per
    /// `progressPublishInterval`; the pending publish reads whatever
    /// state is current when it fires, so the last value always lands.
    private func recomputeProgress() {
        guard progressPublishTask == nil else { return }
        progressPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.progressPublishInterval))
            guard let self else { return }
            self.progressPublishTask = nil
            self.publishProgressNow()
        }
    }

    private func publishProgressNow() {
        var completed = 0
        var total = 0
        for (_, p) in perKeyProgress {
            completed += p.completed
            total += p.total
        }
        let newProgress = SnapProgress(completed: completed, total: total)
        // Skip no-op writes: `@Published` fires its willSet on every
        // assignment, equal or not, and an equal assignment costs a
        // full view invalidation for a value nobody can see change.
        if newProgress != progress { progress = newProgress }
        let working = !inFlight.isEmpty
        if working != isWorking { isWorking = working }
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
        invalidateTripsMemo()
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
        fixes: [TimedFix],
        existing: [String: SegmentSnap] = [:]
    ) async -> (chunks: [SnappedChunk], complete: Bool, newSegments: [String: SegmentSnap]) {
        let total = max(0, fixes.count - 1)
        var chunks: [SnappedChunk] = []
        var current: (coords: [CLLocationCoordinate2D], isFallback: Bool)? = nil
        var complete = true
        // Segments we snap live in this run and hand back to the
        // caller, who folds them into the instance-level
        // `segmentCache` under a MainActor.run so the next whole-
        // trip snap can reuse them without another MKDirections
        // call. Read-only `existing` (a snapshot from before this
        // compute started) means every subsequent-trip snap that
        // walks over the same pair short-circuits the network call
        // entirely.
        var newSegments: [String: SegmentSnap] = [:]

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

            let distance = metersBetween(fromCoord, toCoord)
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
                // dash it. Not cached in `newSegments`: the gate is
                // pure geometry and re-evaluates instantly next time,
                // no benefit to spending a cache slot on it.
                appendSegment([fromCoord, toCoord], isFallback: true)
                continue
            }

            // Segment-level cache lookup. Skips the network call
            // (and, importantly, the shared `limiter.acquire()`
            // wait) when this exact pair has been snapped before —
            // the common case on Live-mode re-runs where the trip
            // grew by one fix at the end and every prior segment
            // is unchanged.
            let segKey = segmentKey(fromCoord, toCoord)
            if let cached = existing[segKey] {
                switch cached {
                case .snapped(let coords):
                    appendSegment(coords, isFallback: false)
                case .fallback:
                    appendSegment([fromCoord, toCoord], isFallback: true)
                }
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
            // Stash the result for reuse by the next whole-trip
            // snap. Cache the geometric fallback (empty route / bad
            // coords / rejected by stretch-ratio) — those decisions
            // are stable and re-checking them next render just
            // burns another MKDirections call. Do NOT cache
            // throttle-exhausted fallbacks: those are transient
            // (the throttle window will clear), and caching them as
            // fallback would freeze a raw chord in place across the
            // whole trail. The `complete == false` gate already
            // prevents the trip-level cache from being persisted;
            // matching that behaviour here keeps the two caches
            // consistent.
            if isFallback {
                if complete {
                    newSegments[segKey] = .fallback
                }
            } else {
                newSegments[segKey] = .snapped(coords)
            }
        }

        if let cur = current {
            chunks.append(SnappedChunk(coords: cur.coords, isFallback: cur.isFallback))
        }
        return (chunks, complete, newSegments)
    }

    private func cacheKey(_ coords: [CLLocationCoordinate2D]) -> String {
        // Quantized to ~1 m — stable enough that minor numerical wobble
        // doesn't bust the cache, fine enough that two genuinely
        // different paths get different keys.
        //
        // Was a `"%.5f,%.5f"`-per-point string joined with "|", i.e. a
        // ~25 B-per-waypoint allocation (a few KB for a long trail) that
        // then had to be hashed in full on every dictionary lookup —
        // built fresh on every SwiftUI render, for every profile. The
        // hash carries the same information in 16 characters.
        var h = FNV1a()
        for coord in coords { h.combine(coord) }
        return h.keyString
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
    // v8 (this bump): cache keys switched from a
    //     `"%.5f,%.5f"`-per-waypoint joined string to a stable FNV-1a
    //     hash, and the distance math moved from `CLLocation.distance`
    //     to haversine (both for main-thread cost — see
    //     `metersBetween`). v7 keys can no longer be regenerated, so
    //     those entries would sit in the file forever without ever
    //     hitting; the bump drops them. Cost is one re-snap pass.
    nonisolated private static let cacheVersion = 8

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

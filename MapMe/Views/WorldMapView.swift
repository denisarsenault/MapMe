#if os(iOS) || os(macOS) || os(tvOS)
import SwiftUI
import CoreData
import CoreLocation
import MapKit

/// Renders multiple `MinorProfile`s on one map.
///
/// - `dateRange`: lower/upper inclusive bounds for filtering each profile's
///   `LocationRecord`s. The Mac dashboard supplies a single day (Day mode)
///   or a 7-day rolling window (Week mode), the tvOS dashboard supplies a
///   single day, and Live mode supplies the last 24 hours.
/// - `timeCutoff`: if non-nil, additionally drops records whose timestamp
///   exceeds the cutoff. Drives the time-of-day scrubber.
/// - `liveMode`: when true, renders the latest fix as an animated pulsing
///   marker rather than the standard pin, and forces a thicker polyline.
/// - `mapSelection`: two-way binding so tapping a marker sets the binding
///   to the corresponding `MinorProfile.objectID`.
struct WorldMapView: View {
    let archiveID: NSManagedObjectID?
    let profiles: [MinorProfile]
    let dateRange: ClosedRange<Date>
    let timeCutoff: Date?
    let liveMode: Bool
    let snapToRoads: Bool
    let colors: [NSManagedObjectID: Color]
    @Binding var mapSelection: NSManagedObjectID?
    /// Map base style — standard streets, satellite imagery, or hybrid
    /// (imagery + labels). Defaults to `.standard` so existing callers
    /// (Mac dashboard, day detail) keep their current rendering.
    var style: WorldMapStyle = .standard
    /// Pulse counters driven by external Zoom In / Zoom Out buttons
    /// (tvOS has no pinch gesture; the dashboard wires these to its
    /// top-bar zoom controls). Each increment shrinks the camera span
    /// by 0.5× (zoom in) or doubles it (zoom out). Default of 0 keeps
    /// existing callers unaffected.
    var zoomInPulse: Int = 0
    var zoomOutPulse: Int = 0
    /// Optional "where should the map start?" hint used only when
    /// no visible records exist for the current date range. Guardian
    /// dashboards populate this from `StartingLocationRequester` so
    /// a fresh install with no Minor data yet lands the camera on
    /// the Guardian's own neighbourhood instead of a globe view.
    /// When records ARE present, this is ignored — record coords
    /// always win.
    var fallbackCenter: CLLocationCoordinate2D? = nil

    @State private var camera: MapCameraPosition = .automatic
    @ObservedObject private var snapService = SnapToRoadsService.shared

    /// Per-profile fix/count cache. See `TrailDataCache` — without it,
    /// every marker-tween tick refetched every profile's whole trail.
    @StateObject private var trailCache = TrailDataCache(
        fetchLimit: WorldMapView.recordFetchLimit
    )

    /// Per-profile smooth-marker animators. Only populated /
    /// consulted when `liveMode == true` — Day/Week views draw the
    /// marker at the actual latest coord with no tweening. Using
    /// `@StateObject`-style ownership via `@State` dict + explicit
    /// `@ObservedObject` at the render site would produce sub-view
    /// invalidation instead of whole-Map re-render on every 30 fps
    /// tick, but SwiftUI Map's `Annotation` doesn't accept ObservableObject
    /// bindings in its coordinate arg — the whole `profileContent`
    /// rebuild is unavoidable. Fine at 30 fps; polylines have
    /// stable IDs so their Metal drawables are reused.
    @StateObject private var liveMarkerAnimators = LiveMarkerAnimatorPool()

    var body: some View {
        Map(position: $camera, selection: $mapSelection) {
            ForEach(profiles, id: \.objectID) { profile in
                profileContent(for: profile)
            }
        }
        .mapStyle(style.mapKitStyle)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .topLeading) { legend }
        .overlay(alignment: .bottomLeading) { dateBadge }
        .onAppear { zoomToFit() }
        // Deliberately NOT auto-fitting on every `profiles` array
        // change. `@FetchRequest` re-emits a fresh `Array` on every
        // CoreData notification (Live mode in particular fires these
        // constantly via `refreshAllObjects`), and re-fitting on
        // each emit was snapping the camera back to fit-all-profiles
        // every time the user panned or zoomed — most visibly on
        // tvOS where the user enters pan mode, repositions, then
        // exits and watches the map jump back.
        //
        // The two genuinely user-driven triggers (date change, time
        // scrubber) still re-fit so changing the date range gives a
        // fresh framing. Zoom buttons adjust the current camera.
        .onChange(of: dateRange) { _, _ in zoomToFit() }
        .onChange(of: timeCutoff) { _, _ in zoomToFit() }
        .onChange(of: zoomInPulse) { _, _ in zoomBy(factor: 0.5) }
        .onChange(of: zoomOutPulse) { _, _ in zoomBy(factor: 2.0) }
        // The fallback coordinate arrives asynchronously (CLLocationManager
        // one-shot). Re-fit when it lands so the initial `.automatic`
        // globe view snaps to the Guardian's neighbourhood as soon as
        // the OS returns a fix — but ONLY if no records have populated
        // the map by then.
        .onChange(of: fallbackCoordinateKey) { _, _ in zoomToFit() }
    }

    /// `CLLocationCoordinate2D` isn't `Equatable`, so we can't attach
    /// `.onChange(of:)` to it directly. This packs the two components
    /// into a hashable string so SwiftUI's diff can detect the change.
    private var fallbackCoordinateKey: String {
        guard let c = fallbackCenter else { return "" }
        return "\(c.latitude),\(c.longitude)"
    }

    // MARK: - Per-profile map content

    /// Marker at the most recent fix, plus one polyline per *trip*. A trip
    /// is a continuous span of fixes separated from its neighbours by more
    /// than `SnapToRoadsService.tripBreakGapSeconds` — so a kid's morning
    /// walk and afternoon walk become two distinct polylines instead of
    /// one tangled line that pretends they're connected.
    @MapContentBuilder
    private func profileContent(for profile: MinorProfile) -> some MapContent {
        let color = colors[profile.objectID] ?? .gray
        let fixes = fixesFor(profile)

        // Marker at the most recent fix
        if let last = fixes.last {
            let coord = last.coordinate
            if liveMode {
                // Tween the marker to `coord` via the per-profile
                // animator instead of teleporting. The animator
                // reads `coord` as the new target on every render;
                // if it differs from the currently displayed value
                // it kicks a 0.8 s ease-out tween. Views observing
                // the pool re-render on each 30 fps tick so
                // MapKit re-anchors the annotation many times per
                // second — reads as smooth motion.
                let animatedCoord = liveMarkerAnimators.displayedCoord(
                    for: profile.objectID, target: coord
                )
                // Offline = no fresh fix in the alert-service's
                // online window (currently 30 min). Marker keeps
                // its last-known coord; `PulsingMarker(isOffline:)`
                // swaps the pulse for an X so the Guardian can tell
                // "here's where they were" from "here's where they
                // are right now."
                let offline = !GuardianAudioAlertService.isOnline(lastFixAt: last.timestamp)
                Annotation(profile.displayName ?? "Device", coordinate: animatedCoord) {
                    PulsingMarker(color: color, isOffline: offline)
                }
                .tag(profile.objectID)
            } else if profile.kind != .person {
                // Pet / device — reuse the profile colour but overlay
                // the kind's SF Symbol on the marker so the Guardian
                // can tell a paw-print from a person-marker at a
                // glance without reading the label. `Marker(_:
                // systemImage:coordinate:)` swaps the standard pin's
                // glyph while keeping MapKit's tint / hit-testing.
                Marker(profile.displayName ?? "Tracker",
                       systemImage: profile.kind.systemImage,
                       coordinate: coord)
                    .tint(color)
                    .tag(profile.objectID)
            } else {
                Marker(profile.displayName ?? "Device", coordinate: coord)
                    .tint(color)
                    .tag(profile.objectID)
            }
        }

        // Trip polylines (snapped or raw). `ForEach(trips)` uses each
        // trip's stable `id`, so unchanged trips keep their existing
        // `MapPolyline` (and Metal drawable) across re-renders.
        //
        // NOTE: a previous attempt added a sibling `ForEach` of
        // `Annotation` here to stamp each trip with its start time
        // (HH:MM capsule). Doing so triggered Map's automatic
        // framing to fire on every annotation churn — undoing the
        // pan-mode camera-preservation fix from the prior commit.
        // Trip start-time labels will need a separate rendering
        // path (e.g. SwiftUI overlay outside the Map projected via
        // MapReader / MapProxy) so they don't perturb the Map's
        // internal camera state.
        // Live mode + snap is disabled on tvOS AND macOS. Both hit
        // trouble when Live tracking's constant fix arrival keeps
        // invalidating snap cache keys — tvOS runs out of memory
        // (the 4th-gen Apple TV's ~256 MB budget can't hold the
        // whole-trip + per-segment caches while they churn), and
        // macOS starves the main thread with the render + MKDirections
        // request storm the churn produces. Snap stays available in
        // Day/Week views (where trips are frozen and the cache
        // amortises); the raw polyline still renders in Live so the
        // trail is visible, only the road-snap smoothing is
        // dropped. iOS keeps snap in Live — small phone maps don't
        // pile up nearly as many polyline draws per frame.
        #if os(tvOS) || os(macOS)
        let effectiveSnap = snapToRoads && !liveMode
        #else
        let effectiveSnap = snapToRoads
        #endif
        let trips: [IdentifiedTrip] = effectiveSnap
            ? snapService.snappedTrips(fixes)
            : SnapToRoadsService.rawTrips(fixes)
        ForEach(trips) { trip in
            if trip.coordinates.count > 1 {
                MapPolyline(coordinates: trip.coordinates)
                    .stroke(
                        trip.isFallback ? color.opacity(0.55) : color,
                        style: trip.isFallback
                            ? StrokeStyle(lineWidth: liveMode ? 4 : 3, dash: [10, 6])
                            : StrokeStyle(lineWidth: liveMode ? 5 : 4)
                    )
            }
        }

        // Raw GPS overlay underneath the snapped polylines. Same trip
        // segmentation so the overlay lines up with what got smoothed.
        // Uses `effectiveSnap` so the overlay is only drawn when we're
        // actually snapping (i.e. hidden on tvOS Live where snap is
        // short-circuited).
        if effectiveSnap, snapService.showRawOverlay {
            let raw = SnapToRoadsService.rawTrips(fixes)
            ForEach(raw) { trip in
                if trip.coordinates.count > 1 {
                    MapPolyline(coordinates: trip.coordinates)
                        .stroke(color.opacity(0.35), lineWidth: 2)
                }
            }
        }

        // Journey markers — one inverted pin per completed round-trip,
        // numbered 1..N per calendar day, positioned at the turnaround
        // (farthest point from the anchor). See JourneyDetector for the
        // detection heuristics.
        //
        // Placed AFTER the polylines so the pin sits on top of the
        // trail. Live mode hides journeys because the trailing 24 h
        // window straddles midnight and the numbering would flicker
        // as fixes fall out of the window.
        if !liveMode {
            let journeys = JourneyDetector.journeys(from: fixes)
            ForEach(journeys) { journey in
                Annotation("Journey \(journey.number)",
                           coordinate: journey.turnaround,
                           anchor: .bottom) {
                    JourneyPin(number: journey.number, color: color)
                }
            }
        }
    }

    /// This profile's visible fixes, served from `trailCache`.
    private func fixesFor(_ profile: MinorProfile) -> [TimedFix] {
        trailCache.fixes(for: profile,
                         range: dateRange,
                         cutoff: timeCutoff)
    }

    // MARK: - Overlays

    private var legend: some View {
        Group {
            if profiles.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(profiles, id: \.objectID) { p in
                        let count = countFor(p)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colors[p.objectID] ?? .gray)
                                .frame(width: 10, height: 10)
                            Text(p.displayName ?? "—")
                                .font(.caption)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
    }

    private var dateBadge: some View {
        HStack(spacing: 6) {
            if liveMode {
                Image(systemName: "dot.radiowaves.right")
                    .foregroundStyle(.green)
                Text("Live · last 24 h")
            } else {
                Text(dateBadgeText)
            }
            if let cutoff = timeCutoff,
               !Calendar.current.isDate(cutoff, equalTo: dateRange.upperBound, toGranularity: .minute) {
                Text("· up to \(cutoff.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if snapToRoads, snapService.isWorking {
                Image(systemName: "road.lanes")
                let p = snapService.progress
                Text(p.total > 0
                     ? "snapping \(p.completed)/\(p.total)…"
                     : "snapping…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .padding(12)
    }

    private var dateBadgeText: String {
        let cal = Calendar.current
        let lo = dateRange.lowerBound
        let hi = dateRange.upperBound
        if cal.isDate(lo, inSameDayAs: hi) {
            return lo.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(lo.formatted(date: .abbreviated, time: .omitted)) – \(hi.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: - Data

    /// Fetch cap per profile per render. tvOS runs on the 4th-gen
    /// Apple TV (AppleTV5,3) with ~256 MB per-app jetsam budget, so
    /// materialising 5 000 rows × N profiles crashed the process
    /// (`Terminated due to memory issue`, code 11). 1 500 covers a
    /// ~4 h Live window at 10 s cadence — comfortably more than a
    /// dashboard user is glancing at. iOS/macOS keep the wider
    /// window since they have real memory headroom and the extra
    /// history is useful for Day/Week retrospectives on those
    /// surfaces.
    #if os(tvOS)
    static let recordFetchLimit = 1500
    #else
    static let recordFetchLimit = 5000
    #endif

    /// Number of visible fixes for the legend, served from `trailCache`.
    private func countFor(_ profile: MinorProfile) -> Int {
        trailCache.count(for: profile,
                         range: dateRange,
                         cutoff: timeCutoff)
    }

    private func zoomToFit() {
        let allCoords: [CLLocationCoordinate2D] = profiles.flatMap { profile in
            fixesFor(profile).map(\.coordinate)
        }
        guard !allCoords.isEmpty else {
            if let fallback = fallbackCenter {
                // No records yet — use the Guardian's own device
                // location as a starting frame. 5 km span (~0.05°)
                // shows the immediate neighbourhood without being
                // so tight that the user can't see any surrounding
                // context.
                camera = .region(MKCoordinateRegion(
                    center: fallback,
                    span: MKCoordinateSpan(latitudeDelta: 0.05,
                                           longitudeDelta: 0.05)
                ))
            } else {
                camera = .automatic
            }
            return
        }
        let lats = allCoords.map(\.latitude)
        let lons = allCoords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
            longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta:  max(0.01, ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.4),
            longitudeDelta: max(0.01, ((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.4)
        )
        camera = .region(MKCoordinateRegion(center: center, span: span))
    }

    /// Multiplies the current camera region's span by `factor`,
    /// preserving the centre. Used by the dashboard's Zoom In (0.5)
    /// and Zoom Out (2.0) buttons, since tvOS has no pinch gesture.
    /// Clamps spans so we can't zoom in past street level or out past
    /// the whole globe.
    private func zoomBy(factor: Double) {
        guard let region = camera.region else {
            // Camera is in `.automatic` mode and hasn't resolved to a
            // concrete region yet. Force a fit first so we have a
            // baseline to multiply.
            zoomToFit()
            return
        }
        let newSpan = MKCoordinateSpan(
            latitudeDelta:  min(170, max(0.0008, region.span.latitudeDelta  * factor)),
            longitudeDelta: min(170, max(0.0008, region.span.longitudeDelta * factor))
        )
        withAnimation(.easeInOut(duration: 0.25)) {
            camera = .region(MKCoordinateRegion(center: region.center, span: newSpan))
        }
    }
}

// MARK: - TrailDataCache

/// Caches each profile's visible fixes (and total count) for the current
/// date range, invalidating on CoreData change rather than on view
/// render.
///
/// **Why this exists.** `WorldMapView`'s body re-evaluates far more often
/// than the underlying data changes, and it used to run one bounded fetch
/// (up to `recordFetchLimit` rows) plus one `COUNT(*)` **per profile, per
/// evaluation**. In Live mode that compounded badly:
///
/// - each `LiveMarkerAnimator` ticks at 15 fps and the pool re-publishes
///   upward, invalidating the whole `Map`;
/// - with N devices on screen there are N animators, so up to 15 × N
///   invalidations per second;
/// - every invalidation refetched all N trails.
///
/// So the fetch rate grew as **15 × N²** — about 15/s watching one
/// device, but ~240/s once four were selected, which is the "fine at
/// first, slow after I picked the older devices" cliff. Worse, the
/// Guardian dashboards call `refreshAllObjects()` on every remote change,
/// which faults every managed object, so each of those refetches paid
/// full re-hydration cost.
///
/// Two things fix it: serve repeat reads from this cache, and fetch as
/// dictionaries so no `NSManagedObject`s are hydrated at all.
@MainActor
final class TrailDataCache: ObservableObject {
    /// Identity of one cached query. The date range and cutoff are part
    /// of the key so the scrubber and Day/Week switches don't serve
    /// stale rows.
    private struct Key: Hashable {
        let profile: NSManagedObjectID
        let lower: Date
        let upper: Date
        let cutoff: Date?
    }

    private var fixCache: [Key: [TimedFix]] = [:]
    private var countCache: [Key: Int] = [:]
    private let fetchLimit: Int
    private var observers: [NSObjectProtocol] = []

    /// Cap on distinct cached queries. Normally one entry per profile on
    /// screen; the cap only bounds a caller that churns its date range.
    private static let maxEntries = 16

    init(fetchLimit: Int) {
        self.fetchLimit = fetchLimit
        // Any CoreData mutation — a local save, a merge from the
        // CloudKit import context, or a `refreshAllObjects()` — drops
        // everything. Clearing is cheap and being liberal about it
        // keeps the map honest: we'd rather refetch than draw a trail
        // that's missing the fix that just arrived.
        //
        // This deliberately does NOT publish. The dashboards' own
        // `@FetchRequest`s and remote-change handlers already re-render
        // the view on data changes; if this sent `objectWillChange` too
        // it would add a second invalidation for every fix that lands.
        let names: [Notification.Name] = [
            .NSManagedObjectContextObjectsDidChange,
            .NSPersistentStoreRemoteChange,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clear() }
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func clear() {
        fixCache.removeAll(keepingCapacity: true)
        countCache.removeAll(keepingCapacity: true)
    }

    func fixes(for profile: MinorProfile,
               range: ClosedRange<Date>,
               cutoff: Date?) -> [TimedFix] {
        let key = Key(profile: profile.objectID,
                      lower: range.lowerBound,
                      upper: range.upperBound,
                      cutoff: cutoff)
        if let hit = fixCache[key] { return hit }
        let fetched = fetchFixes(for: profile, range: range, cutoff: cutoff)
        if fixCache.count >= Self.maxEntries { fixCache.removeAll(keepingCapacity: true) }
        fixCache[key] = fetched
        return fetched
    }

    func count(for profile: MinorProfile,
               range: ClosedRange<Date>,
               cutoff: Date?) -> Int {
        let key = Key(profile: profile.objectID,
                      lower: range.lowerBound,
                      upper: range.upperBound,
                      cutoff: cutoff)
        if let hit = countCache[key] { return hit }
        let counted = fetchCount(for: profile, range: range, cutoff: cutoff)
        if countCache.count >= Self.maxEntries { countCache.removeAll(keepingCapacity: true) }
        countCache[key] = counted
        return counted
    }

    /// Bounded, newest-first fetch returned in ascending time order.
    ///
    /// Uses `.dictionaryResultType` with an explicit property list: we
    /// only ever need three scalars per row, and hydrating full
    /// `LocationRecord` objects meant thousands of `NSManagedObject`
    /// allocations (plus fault fulfilment after `refreshAllObjects()`)
    /// for data we immediately flattened into `TimedFix` anyway.
    private func fetchFixes(for profile: MinorProfile,
                            range: ClosedRange<Date>,
                            cutoff: Date?) -> [TimedFix] {
        guard let ctx = profile.managedObjectContext else { return [] }
        let request = NSFetchRequest<NSDictionary>(entityName: "LocationRecord")
        request.predicate = Self.predicate(for: profile, range: range, cutoff: cutoff)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["latitude", "longitude", "timestamp"]
        // Newest-first so `fetchLimit` keeps the most recent tail when
        // we truncate; reversed below so polyline callers get
        // chronological order.
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = fetchLimit
        let rows = (try? ctx.fetch(request)) ?? []
        var fixes: [TimedFix] = []
        fixes.reserveCapacity(rows.count)
        for row in rows {
            // Drop rows with a missing timestamp — relative-date
            // formatting would render those as "2025 yrs ago".
            guard let ts = row["timestamp"] as? Date,
                  let lat = row["latitude"] as? Double,
                  let lon = row["longitude"] as? Double
            else { continue }
            fixes.append(TimedFix(latitude: lat, longitude: lon, timestamp: ts))
        }
        return fixes.reversed()
    }

    /// `SELECT COUNT(*)` — returns the true total even when
    /// `fetchFixes` truncated at `fetchLimit`, which is what the legend
    /// wants to show.
    private func fetchCount(for profile: MinorProfile,
                            range: ClosedRange<Date>,
                            cutoff: Date?) -> Int {
        guard let ctx = profile.managedObjectContext else { return 0 }
        let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        request.predicate = Self.predicate(for: profile, range: range, cutoff: cutoff)
        return (try? ctx.count(for: request)) ?? 0
    }

    private static func predicate(for profile: MinorProfile,
                                  range: ClosedRange<Date>,
                                  cutoff: Date?) -> NSPredicate {
        var parts: [NSPredicate] = [
            NSPredicate(format: "profile == %@", profile),
            NSPredicate(format: "timestamp >= %@ AND timestamp <= %@",
                        range.lowerBound as NSDate,
                        range.upperBound as NSDate),
        ]
        if let cutoff = cutoff {
            parts.append(NSPredicate(format: "timestamp <= %@", cutoff as NSDate))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }
}

/// Base map style. Kept as our own enum (rather than passing
/// `MapKit.MapStyle` directly) so the dashboard can store it in
/// `@State` without conformance gymnastics — `MapStyle` isn't
/// `Equatable`, which breaks `@State`'s diff-on-change behaviour.
enum WorldMapStyle: String, CaseIterable, Hashable {
    case standard, satellite, hybrid

    var mapKitStyle: MapStyle {
        switch self {
        case .standard:  return .standard
        case .satellite: return .imagery
        case .hybrid:    return .hybrid
        }
    }

    var label: String {
        switch self {
        case .standard:  return "Standard"
        case .satellite: return "Satellite"
        case .hybrid:    return "Hybrid"
        }
    }

    var icon: String {
        switch self {
        case .standard:  return "map"
        case .satellite: return "globe.americas.fill"
        case .hybrid:    return "map.fill"
        }
    }

    /// Cycle order for the tvOS style-toggle button (Standard →
    /// Satellite → Hybrid → Standard). Single-button cycle keeps
    /// the top-bar footprint tight versus a 3-segment picker.
    var next: WorldMapStyle {
        switch self {
        case .standard:  return .satellite
        case .satellite: return .hybrid
        case .hybrid:    return .standard
        }
    }
}

// MARK: - PulsingMarker

/// A custom annotation view used in Live mode: a solid coloured dot with
/// an outward-pulsing halo, like the "live tracking" pin in the Find My app.
///
/// `isOffline == true` swaps the pulse for a static dimmed dot with a
/// small white X overlay — visual shorthand for "here's where the
/// device was last seen, but it's not connected right now." The
/// marker stays at the last-known coord so the Guardian can still
/// see where the device is; only the affordance changes to signal
/// "no fresh fixes."
private struct PulsingMarker: View {
    let color: Color
    var isOffline: Bool = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            if !isOffline {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 36, height: 36)
                    .scaleEffect(pulse ? 1.8 : 0.6)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(isOffline ? color.opacity(0.45) : color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            if isOffline {
                // Small white X centred on the dot. Rendered as a
                // ZStack of two rotated capsules rather than an SF
                // Symbol so the strokes stay crisp inside the 14pt
                // marker — an `xmark` glyph at that size renders
                // as a fuzzy blob on non-Retina Macs.
                ZStack {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 10, height: 2)
                        .rotationEffect(.degrees(45))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 10, height: 2)
                        .rotationEffect(.degrees(-45))
                }
            }
        }
        .onAppear { if !isOffline { pulse = true } }
    }
}

/// Inverted map pin used to mark a completed journey — round head on
/// the bottom (sitting on the turnaround coordinate), pointed tip on
/// top. The journey number sits centered in the head. Coloured to
/// match the profile so the reader can tell whose journey it is when
/// two devices share the day view.
///
/// Anchored `.bottom` at the annotation site so the head — not the
/// tip — is what actually pins to the map coordinate.
private struct JourneyPin: View {
    let number: Int
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            // Upward-pointing tip. Sits directly on top of the head so
            // the pair reads as a single inverted teardrop.
            Triangle()
                .fill(color)
                .frame(width: 14, height: 10)
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Text("\(number)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .shadow(radius: 2)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
#endif

#if os(iOS) || os(macOS) || os(tvOS)

#Preview("Light Mode") {
    WorldMapView(
        archiveID: nil,
        profiles: [],
        dateRange: Date().addingTimeInterval(-86400)...Date(),
        timeCutoff: nil,
        liveMode: false,
        snapToRoads: false,
        colors: [:],
        mapSelection: .constant(nil)
    )
}

#Preview("Dark Mode") {
    WorldMapView(
        archiveID: nil,
        profiles: [],
        dateRange: Date().addingTimeInterval(-86400)...Date(),
        timeCutoff: nil,
        liveMode: false,
        snapToRoads: false,
        colors: [:],
        mapSelection: .constant(nil)
    )
    .preferredColorScheme(.dark)
}

#Preview("iPhone 15") {
    WorldMapView(
        archiveID: nil,
        profiles: [],
        dateRange: Date().addingTimeInterval(-86400)...Date(),
        timeCutoff: nil,
        liveMode: false,
        snapToRoads: false,
        colors: [:],
        mapSelection: .constant(nil)
    )
    .preferredColorScheme(.dark)
}

#endif

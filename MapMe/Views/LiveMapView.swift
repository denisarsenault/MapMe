#if os(iOS) || os(macOS)
import SwiftUI
import MapKit
import CoreData

struct LiveMapView: View {
    // Env-injected on both iOS and macOS so this view sees the same
    // singleton the app-level start/stop UI and the Siri intents
    // mutate. The old `#else @StateObject private var location =
    // LocationService()` branch on macOS produced a SEPARATE
    // LocationService instance with its own CLLocationManager, which
    // meant the Settings-app Start button (which touches
    // LocationService.shared) and this view's tracking state
    // disagreed — flipping the Settings toggle didn't turn on the
    // manager backing the map, and the map's `isTracking` never
    // reflected reality.
    @EnvironmentObject private var location: LocationService

    @ObservedObject private var snapService = SnapToRoadsService.shared

    /// Today's own-device records, bounded.
    ///
    /// Two guards on top of "timestamp >= startOfDay":
    ///
    ///   1. `deviceIdentifier == DeviceID.current` — scopes to fixes
    ///      this device wrote. Without this, a Guardian-role device
    ///      that ALSO recorded local fixes would pull in every
    ///      Minor's records from the shared store (via CloudKit) and
    ///      render everyone on the "my Live tracking" map.
    ///   2. `fetchLimit: 3_000` — cap on rows materialised into the
    ///      SwiftUI `FetchedResults` cache. HighAccuracy writes ~2×/
    ///      minute, so 3000 covers ~24 h with headroom. Without a cap,
    ///      an all-day HighAccuracy session at 1-Hz cadence
    ///      snowballed the resident set into hundreds of MB — every
    ///      `NSPersistentStoreRemoteChange` re-hydrated the entire
    ///      set, and the map polyline builders allocated a fresh
    ///      `[TimedFix]` copy on every body invocation. That plus
    ///      the CloudKit export backlog made the whole tab OOM-prone
    ///      when a tab switch pushed extra allocations through.
    @FetchRequest(fetchRequest: Self.buildTodayRequest(),
                  animation: .default)
    private var todayRecords: FetchedResults<LocationRecord>

    private static func buildTodayRequest() -> NSFetchRequest<LocationRecord> {
        let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "timestamp >= %@",
                        Calendar.current.startOfDay(for: Date()) as NSDate),
            NSPredicate(format: "deviceIdentifier == %@", DeviceID.current),
        ])
        request.fetchLimit = 3_000
        return request
    }

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        let fixes = todayRecords.reversed().compactMap { rec -> TimedFix? in
            guard let ts = rec.timestamp else { return nil }
            return TimedFix(latitude: rec.latitude,
                            longitude: rec.longitude,
                            timestamp: ts)
        }
        // Same pattern as DayDetailView: snapped polylines per trip if
        // the user has snap on, raw polylines otherwise. Live mode runs
        // through the same SnapToRoadsService instance, so the trail the
        // device draws of its own movement matches what the Guardian
        // sees of it across CloudKit.
        let trips: [IdentifiedTrip] = snapService.isEnabled
            ? snapService.snappedTrips(fixes)
            : SnapToRoadsService.rawTrips(fixes)
        // Only segmented when the overlay is actually being drawn. This
        // used to be computed unconditionally, which meant every render
        // — including the constant ones Live tracking produces — paid
        // for a full trip segmentation pass whose result was thrown
        // away in the common case where the overlay is off.
        let rawTrips: [IdentifiedTrip] =
            (snapService.isEnabled && snapService.showRawOverlay)
            ? SnapToRoadsService.rawTrips(fixes)
            : []

        Map(position: $camera) {
            UserAnnotation()
            if snapService.isEnabled, snapService.showRawOverlay {
                ForEach(rawTrips) { trip in
                    if trip.coordinates.count > 1 {
                        MapPolyline(coordinates: trip.coordinates)
                            .stroke(Color.gray.opacity(0.45), lineWidth: 2)
                    }
                }
            }
            ForEach(trips) { trip in
                if trip.coordinates.count > 1 {
                    MapPolyline(coordinates: trip.coordinates)
                        .stroke(
                            trip.isFallback ? AnyShapeStyle(Color.accentColor.opacity(0.55)) : AnyShapeStyle(.tint),
                            style: trip.isFallback
                                ? StrokeStyle(lineWidth: 3, dash: [10, 6])
                                : StrokeStyle(lineWidth: 4)
                        )
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .top) { topOverlay }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    snapService.isEnabled.toggle()
                } label: {
                    Label(
                        snapService.isEnabled ? "Snapping on" : "Snap to roads",
                        systemImage: "road.lanes"
                    )
                    .foregroundStyle(snapService.isEnabled ? Color.accentColor : .primary)
                }
                .help("Route your live track along real roads via MKDirections")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    snapService.showRawOverlay.toggle()
                } label: {
                    Label(
                        snapService.showRawOverlay ? "Raw overlay on" : "Show raw GPS",
                        systemImage: "scribble.variable"
                    )
                    .foregroundStyle(snapService.showRawOverlay ? Color.orange : .primary)
                }
                .help("Overlay the raw GPS polyline beneath the snapped one")
                .disabled(!snapService.isEnabled)
            }
        }
        .task {
            location.requestAuthorization()
        }
    }

    /// LiveMapView is a TabView leaf with no `NavigationStack`, so
    /// there's no nav bar to host a `.mapMeBrandToolbar()`. Instead
    /// we stack the full `MMLogo` wordmark and the live-tracking
    /// status pill as two centered overlay rows pinned to the top of
    /// the map.
    private var topOverlay: some View {
        VStack(spacing: 8) {
            // `.thinMaterial` follows the colour scheme — light grey in
            // light mode, dark grey in dark mode — so the adaptive
            // wordmark renders with the matching text colour
            // automatically.
            MapMeBrandImage()
                .frame(height: 36)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())

            statusBar

            // Siri hint chip — StartTrackingIntent is the useful
            // command from this screen for the Minor. Dismissible;
            // stays dismissed across relaunches once the user has
            // seen it.
            MapMeSiriTip(
                intent: StartTrackingIntent(),
                storageKey: "MapMe.siriTip.liveMap"
            )
        }
        .padding(.top, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(location.isTracking ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(location.isTracking ? "Tracking" : "Idle")
                .font(.footnote.weight(.medium))

            // Snap status pill — visible whenever snap is on, whether
            // a snap is in flight ("Snapping X/Y") or idle ("Snap on").
            // Lets the user see at a glance whether the live polyline
            // they're looking at is raw fixes or road-matched, and
            // whether MKDirections is currently grinding through the
            // tail of the day.
            if snapService.isEnabled {
                Image(systemName: "road.lanes")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
                if snapService.isWorking {
                    let p = snapService.progress
                    Text(p.total > 0 ? "Snapping \(p.completed)/\(p.total)" : "Snapping…")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Snap on")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
            if let last = location.lastLocation {
                Text(last.timestamp, style: .time)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal)
    }
}
#endif

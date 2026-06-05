import SwiftUI
import CoreData
import CoreLocation
import MapKit

struct WatchLiveView: View {
    @EnvironmentObject private var location: WatchLocationService
    @EnvironmentObject private var connectivity: WatchConnectivitySession
    @ObservedObject private var snapService = SnapToRoadsService.shared

    // Filter to *this watch's* MinorProfile only — see WatchSettingsView
    // for the same rationale (the iPhone's profile syncs into our private
    // store via CloudKit and would otherwise hijack the empty/waiting UI).
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: true)],
        predicate: NSPredicate(format: "deviceIdentifier == %@", DeviceID.current),
        animation: .default
    ) private var profiles: FetchedResults<MinorProfile>

    /// Stored history for *this watch*, newest first. The map renders these
    /// even when Live mode is off, so the user always sees their last known
    /// position (and trail) instead of a blank map waiting for a fresh fix.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "timestamp", ascending: false)],
        predicate: NSPredicate(format: "profile.deviceIdentifier == %@", DeviceID.current),
        animation: .default
    ) private var recentRecords: FetchedResults<LocationRecord>

    var body: some View {
        // Layout note: the `Map` deliberately lives OUTSIDE the
        // `ScrollView`. MapKit's gesture system reads the enclosing
        // ScrollView's contentOffset binding to arbitrate between map
        // pan and scroll pan, which trips SwiftUI's diagnostic:
        //
        //   "ScrollView contentOffset binding has been read; this will
        //    cause grossly inefficient view performance as the
        //    ScrollView's content will be updated whenever its
        //    contentOffset changes."
        //
        // On each layout pass that meant ~4× re-renders of the whole
        // ScrollView body, which on a watch is visibly stuttery. Put
        // the status row + map at the top in a fixed VStack; only the
        // small action button + optional error text scroll, which is
        // enough since the map is fixed-height (110 pt).
        VStack(alignment: .leading, spacing: 8) {
            if profiles.isEmpty {
                ScrollView { setupBanner.padding(.horizontal, 4) }
            } else if profiles.first?.consentGrantedAt == nil {
                ScrollView { waitingBanner.padding(.horizontal, 4) }
            } else {
                statusRow
                    .padding(.horizontal, 4)
                mapSection
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        actionButton
                        if let err = location.trackingError {
                            Text(err).font(.caption2).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            }
        }
        .navigationTitle("Live")
        .task { location.requestAuthorization() }
    }

    // MARK: - Empty / waiting states

    private var setupBanner: some View {
        VStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Invite a Guardian")
                .font(.caption.weight(.semibold))
            Text("Pair this watch with a parent's MapMe app. Tap Settings → Guardian → Invite Guardian.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 4) {
                Image(systemName: connectivity.isReachable ? "iphone" : "iphone.slash")
                Text(connectivity.isReachable ? "Or finish from iPhone" : "iPhone not reachable")
            }
            .font(.caption2)
            .foregroundStyle(connectivity.isReachable ? .secondary : .secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var waitingBanner: some View {
        VStack(spacing: 4) {
            Image(systemName: "person.crop.circle.badge.clock")
                .font(.title3)
                .foregroundStyle(.orange)
            Text("Awaiting Guardian consent")
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Tracking is paused until your Guardian approves.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Active tracking UI

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(location.isLiveTracking ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(location.isLiveTracking ? "Live" : "Idle")
                .font(.caption)
            Spacer()
            if let stamp = lastTimestamp {
                Text(stamp, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if location.isLiveTracking {
            Button(role: .destructive) {
                location.stopLiveTracking()
            } label: {
                Label("Stop Live", systemImage: "stop.fill")
            }
        } else {
            Button {
                location.startLiveTracking()
            } label: {
                Label("Start Live (≈1 h)", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Map (live + history)

    @ViewBuilder
    private var mapSection: some View {
        if let center = mapCenter {
            // Snap is opt-in on the watch — every MKDirections call is a
            // network round-trip on a battery-constrained device. Default
            // off; user enables in Settings → Map.
            // One polyline per trip — gaps > 10 min split into separate
            // trips so a back-and-forth pattern from sparse background
            // fetches doesn't render as one tangled line that pretends
            // the watch walked the route between them. Stable trip IDs
            // let `ForEach` reuse `MapPolyline`s across renders.
            let trips: [IdentifiedTrip] = snapService.isEnabled
                ? snapService.snappedTrips(pathFixes)
                : SnapToRoadsService.rawTrips(pathFixes)
            Map(initialPosition: .region(MKCoordinateRegion(
                center: center,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            ))) {
                ForEach(trips) { trip in
                    if trip.coordinates.count > 1 {
                        MapPolyline(coordinates: trip.coordinates)
                            .stroke(.tint, lineWidth: 4)
                    }
                }
                Marker("", coordinate: center)
                    .tint(.red)
            }
            .overlay(alignment: .top) {
                // The watch screen is small — show just a compact pill at
                // the top so the map stays usable.
                if snapService.isEnabled, snapService.isWorking {
                    let p = snapService.progress
                    HStack(spacing: 4) {
                        Image(systemName: "road.lanes")
                        Text(p.total > 0
                             ? "\(p.completed)/\(p.total)"
                             : "snap")
                            .monospacedDigit()
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 4)
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.thinMaterial)
                VStack(spacing: 4) {
                    Image(systemName: "location.slash")
                        .foregroundStyle(.secondary)
                    Text("No fixes yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Tap Start Live to begin")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Derived

    /// The most recent location to mark on the map. Prefers an in-memory
    /// fix from the active Live session; otherwise falls back to the most
    /// recently saved `LocationRecord` for this watch.
    private var mapCenter: CLLocationCoordinate2D? {
        if let live = location.lastLocation {
            return live.coordinate
        }
        if let record = recentRecords.first {
            return CLLocationCoordinate2D(
                latitude: record.latitude,
                longitude: record.longitude
            )
        }
        return nil
    }

    private var lastTimestamp: Date? {
        if let live = location.lastLocation { return live.timestamp }
        return recentRecords.first?.timestamp
    }

    /// Up to the last 100 fixes, ascending by time, with timestamps —
    /// the format `SnapToRoadsService.snappedTrips` / `rawTrips` consumes.
    /// Timestamps drive trip segmentation and the speed/time snap gates.
    private var pathFixes: [TimedFix] {
        Array(recentRecords.prefix(100))
            .compactMap { record -> TimedFix? in
                guard let ts = record.timestamp else { return nil }
                return TimedFix(
                    latitude: record.latitude,
                    longitude: record.longitude,
                    timestamp: ts
                )
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Up to the last 100 fixes, ascending by time, ready for a polyline.
    private var pathCoordinates: [CLLocationCoordinate2D] {
        Array(recentRecords.prefix(100))
            .compactMap { record -> (Date, CLLocationCoordinate2D)? in
                guard let ts = record.timestamp else { return nil }
                return (ts, CLLocationCoordinate2D(
                    latitude: record.latitude,
                    longitude: record.longitude
                ))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}


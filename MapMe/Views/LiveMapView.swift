#if os(iOS) || os(macOS)
import SwiftUI
import MapKit
import CoreData

struct LiveMapView: View {
    #if os(iOS)
    @EnvironmentObject private var location: LocationService
    #else
    @StateObject private var location = LocationService()
    #endif

    @ObservedObject private var snapService = SnapToRoadsService.shared

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "timestamp", ascending: false)],
        predicate: NSPredicate(format: "timestamp >= %@", Calendar.current.startOfDay(for: Date()) as NSDate),
        animation: .default
    ) private var todayRecords: FetchedResults<LocationRecord>

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
        let rawTrips = SnapToRoadsService.rawTrips(fixes)

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

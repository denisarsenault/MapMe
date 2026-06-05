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

    @State private var camera: MapCameraPosition = .automatic
    @ObservedObject private var snapService = SnapToRoadsService.shared

    var body: some View {
        Map(position: $camera, selection: $mapSelection) {
            ForEach(profiles, id: \.objectID) { profile in
                profileContent(for: profile)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .topLeading) { legend }
        .overlay(alignment: .bottomLeading) { dateBadge }
        .onAppear { zoomToFit() }
        .onChange(of: profiles.map(\.objectID)) { _, _ in zoomToFit() }
        .onChange(of: dateRange) { _, _ in zoomToFit() }
        .onChange(of: timeCutoff) { _, _ in zoomToFit() }
    }

    // MARK: - Per-profile map content

    /// Marker at the most recent fix, plus one polyline per *trip*. A trip
    /// is a continuous span of fixes separated from its neighbours by more
    /// than `SnapToRoadsService.tripBreakGapSeconds` — so a kid's morning
    /// walk and afternoon walk become two distinct polylines instead of
    /// one tangled line that pretends they're connected.
    @MapContentBuilder
    private func profileContent(for profile: MinorProfile) -> some MapContent {
        let records = recordsFor(profile)
        let color = colors[profile.objectID] ?? .gray
        let fixes = timedFixes(from: records)

        // Marker at the most recent fix
        if let last = records.last {
            let coord = CLLocationCoordinate2D(
                latitude: last.latitude,
                longitude: last.longitude
            )
            if liveMode {
                Annotation(profile.displayName ?? "Device", coordinate: coord) {
                    PulsingMarker(color: color)
                }
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
        let trips: [IdentifiedTrip] = snapToRoads
            ? snapService.snappedTrips(fixes)
            : SnapToRoadsService.rawTrips(fixes)
        ForEach(trips) { trip in
            if trip.coordinates.count > 1 {
                MapPolyline(coordinates: trip.coordinates)
                    .stroke(color, lineWidth: liveMode ? 5 : 4)
            }
        }

        // Raw GPS overlay underneath the snapped polylines. Same trip
        // segmentation so the overlay lines up with what got smoothed.
        if snapToRoads, snapService.showRawOverlay {
            let raw = SnapToRoadsService.rawTrips(fixes)
            ForEach(raw) { trip in
                if trip.coordinates.count > 1 {
                    MapPolyline(coordinates: trip.coordinates)
                        .stroke(color.opacity(0.35), lineWidth: 2)
                }
            }
        }
    }

    /// Convert `LocationRecord`s to `TimedFix`es, dropping any with a
    /// missing timestamp (relative-date formatting would render those as
    /// "2025 yrs ago" anyway).
    private func timedFixes(from records: [LocationRecord]) -> [TimedFix] {
        records.compactMap { rec in
            guard let ts = rec.timestamp else { return nil }
            return TimedFix(
                latitude: rec.latitude,
                longitude: rec.longitude,
                timestamp: ts
            )
        }
    }

    // MARK: - Overlays

    private var legend: some View {
        Group {
            if profiles.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(profiles, id: \.objectID) { p in
                        let count = recordsFor(p).count
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

    private func recordsFor(_ profile: MinorProfile) -> [LocationRecord] {
        let set = (profile.records as? Set<LocationRecord>) ?? []
        return set
            .filter { rec in
                guard let ts = rec.timestamp else { return false }
                if !dateRange.contains(ts) { return false }
                if let cutoff = timeCutoff, ts > cutoff { return false }
                return true
            }
            .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

    private func zoomToFit() {
        let allCoords: [CLLocationCoordinate2D] = profiles.flatMap { profile in
            recordsFor(profile).map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
        }
        guard !allCoords.isEmpty else {
            camera = .automatic
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
}

// MARK: - PulsingMarker

/// A custom annotation view used in Live mode: a solid coloured dot with
/// an outward-pulsing halo, like the "live tracking" pin in the Find My app.
private struct PulsingMarker: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 36, height: 36)
                .scaleEffect(pulse ? 1.8 : 0.6)
                .opacity(pulse ? 0 : 0.8)
                .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
        }
        .onAppear { pulse = true }
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

import SwiftUI
import CoreData
#if canImport(MapKit)
import MapKit
#endif

struct DayDetailView: View {
    let archiveID: NSManagedObjectID
    @Environment(\.managedObjectContext) private var ctx
    #if os(iOS) || os(macOS)
    @ObservedObject private var snapService = SnapToRoadsService.shared
    #endif

    var body: some View {
        if let archive = try? ctx.existingObject(with: archiveID) as? DayArchive {
            content(for: archive)
        } else {
            ContentUnavailableView("Archive missing", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func content(for archive: DayArchive) -> some View {
        let records = sortedRecords(of: archive)
        VStack(spacing: 0) {
            #if os(iOS) || os(macOS)
            mapSection(records: records, archive: archive)
                .frame(minHeight: 320)
            #endif
            List {
                Section("Summary") {
                    LabeledContent("Date", value: archive.date.map { $0.formatted(date: .complete, time: .omitted) } ?? "—")
                    LabeledContent("Points", value: "\(archive.recordCount)")
                    LabeledContent("Distance", value: formatDistance(archive.distanceMeters))
                }
                Section("Points") {
                    if records.isEmpty, archive.recordCount > 0 {
                        // The day was recorded (recordCount > 0) but the
                        // per-fix detail has been hard-deleted by the
                        // ArchiveService TTL prune. Tell the user *why*
                        // the list is empty so this doesn't look like a
                        // bug. The Summary section above still has the
                        // distance / count / bounds for the day.
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Summary only", systemImage: "archivebox")
                                .font(.footnote.weight(.semibold))
                            Text("Per-fix detail for this day was pruned after \(ArchiveService.retentionDays) days. The totals above still reflect what was recorded.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if records.isEmpty {
                        Text("No points recorded.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(records, id: \.objectID) { r in
                            VStack(alignment: .leading) {
                                Text(r.timestamp ?? .distantPast, style: .time)
                                    .font(.footnote.monospacedDigit())
                                Text(String(format: "%.5f, %.5f", r.latitude, r.longitude))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(archive.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Day")
        .mapMeBrandToolbar()
        #if os(iOS) || os(macOS)
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
                .help("Route the day's track along real roads via MKDirections")
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
        #endif
    }

    #if os(iOS) || os(macOS)
    private func mapSection(records: [LocationRecord], archive: DayArchive) -> some View {
        let fixes = records.compactMap { rec -> TimedFix? in
            guard let ts = rec.timestamp else { return nil }
            return TimedFix(latitude: rec.latitude,
                            longitude: rec.longitude,
                            timestamp: ts)
        }
        // One polyline per trip, gaps > 10 min split into separate trips.
        // Stable trip IDs preserve `MapPolyline` identity across renders.
        let trips: [IdentifiedTrip] = snapService.isEnabled
            ? snapService.snappedTrips(fixes)
            : SnapToRoadsService.rawTrips(fixes)
        let rawTrips = SnapToRoadsService.rawTrips(fixes)
        let firstCoord = trips.first?.coordinates.first
        let lastCoord = trips.last?.coordinates.last
        let totalCoords = trips.reduce(0) { $0 + $1.coordinates.count }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (archive.minLatitude + archive.maxLatitude) / 2,
                longitude: (archive.minLongitude + archive.maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.005, archive.maxLatitude - archive.minLatitude) * 1.4,
                longitudeDelta: max(0.005, archive.maxLongitude - archive.minLongitude) * 1.4
            )
        )
        return Map(initialPosition: .region(region)) {
            // Raw GPS overlay underneath the snapped polylines so the
            // user can spot what got smoothed out.
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
            if let start = firstCoord {
                Marker("Start", coordinate: start).tint(.green)
            }
            if let end = lastCoord, totalCoords > 1 {
                Marker("End", coordinate: end).tint(.red)
            }
        }
        .overlay(alignment: .topTrailing) {
            if snapService.isEnabled, snapService.isWorking {
                snapProgressBadge
                    .padding(12)
            }
        }
    }

    private var snapProgressBadge: some View {
        let p = snapService.progress
        return HStack(spacing: 8) {
            Image(systemName: "road.lanes")
            VStack(alignment: .leading, spacing: 2) {
                Text(p.total > 0
                     ? "Snapping \(p.completed)/\(p.total)"
                     : "Snapping…")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    #endif

    private func sortedRecords(of archive: DayArchive) -> [LocationRecord] {
        let set = (archive.records as? Set<LocationRecord>) ?? []
        return set.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

    private func formatDistance(_ meters: Double) -> String {
        let km = meters / 1000
        return String(format: km >= 1 ? "%.2f km" : "%.0f m", km >= 1 ? km : meters)
    }
}

//#Preview("Light Mode") {
//    let archiveID: NSManagedObjectID?
//
//    DayDetailView(archiveID: archiveID!)
//}
//
//#Preview("Dark Mode") {
//    let archiveID: NSManagedObjectID?
//
//    DayDetailView(archiveID: archiveID!)
//        .preferredColorScheme(.dark)
//}

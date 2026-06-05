import SwiftUI
import CoreData
#if canImport(MapKit)
import MapKit
#endif

struct FamilyDashboardView: View {
    @EnvironmentObject private var guardianSync: GuardianSyncService
    @StateObject private var sharing = SharingService()

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "displayName", ascending: true)],
        animation: .default
    ) private var profiles: FetchedResults<MinorProfile>

    @State private var profileToDelete: MinorProfile?
    @State private var deleteError: String?
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            List {
                if profiles.isEmpty {
                    ContentUnavailableView(
                        "No paired family yet",
                        systemImage: "person.2.slash",
                        description: Text("Have a Minor device send you an invite from their MapMe app, then tap the link.")
                    )
                } else {
                    ForEach(profiles, id: \.objectID) { profile in
                        NavigationLink(value: profile.objectID) {
                            row(for: profile)
                        }
                        #if !os(tvOS)
                        // Swipe actions are unavailable on tvOS; the
                        // contextMenu below covers the same destructive path
                        // via long-press on the focused row.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                profileToDelete = profile
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        #endif
                        .contextMenu {
                            Button(role: .destructive) {
                                profileToDelete = profile
                            } label: {
                                Label("Remove from Family", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Family")
            .toolbar {
                // Brand mark in the navigation bar so the user always
                // has a visible cue that they're in MapMe — useful for
                // screenshots / multitasking when the app icon isn't
                // visible. We use MMBrandMark (square pin-only) here,
                // not the wordmark MMLogo, because a wordmark shrunk
                // into a 40-pt square becomes unreadable. 40 pt lets
                // the pin read clearly without crowding the nav title.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("MMBrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                        Text("MapMe")
                            .font(.headline)
                    }
                }
            }
            .navigationDestination(for: NSManagedObjectID.self) { id in
                MinorDetailView(profileID: id)
            }
            .task { await guardianSync.ensureSubscription() }
            .refreshable {
                // Pull-to-refresh re-asks the system to fetch from the shared DB.
                await guardianSync.ensureSubscription()
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .confirmationDialog(
                "Remove this device?",
                isPresented: Binding(
                    get: { profileToDelete != nil && !isDeleting },
                    set: { if !$0 { profileToDelete = nil } }
                ),
                presenting: profileToDelete
            ) { profile in
                Button("Remove", role: .destructive) {
                    Task { await remove(profile) }
                }
                Button("Cancel", role: .cancel) {
                    profileToDelete = nil
                }
            } message: { profile in
                Text("\(profile.displayName ?? "This device") will stop sharing location with you. The minor's own history is not deleted.")
            }
            .alert(
                "Couldn't remove device",
                isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                ),
                presenting: deleteError
            ) { _ in
                Button("OK", role: .cancel) { deleteError = nil }
            } message: { msg in
                Text(msg)
            }
        }
    }

    @MainActor
    private func remove(_ profile: MinorProfile) async {
        isDeleting = true
        defer {
            isDeleting = false
            profileToDelete = nil
        }
        do {
            try await sharing.removeProfile(profile)

            // `purgeObjectsAndRecordsInZone` cleans CloudKit and the on-disk
            // SQLite, but @FetchRequest's in-memory snapshot doesn't observe
            // purge events the way it observes regular context saves. Force
            // the viewContext to drop its cached rows so the deleted profile
            // disappears from the list immediately rather than at next launch.
            let viewContext = PersistenceController.shared.container.viewContext
            viewContext.refreshAllObjects()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func row(for p: MinorProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.displayName ?? "Unknown").font(.headline)
                if p.consentGrantedAt == nil {
                    Text("Needs approval")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            if let timestamp = lastTimestamp(of: p) {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text(timestamp, style: .relative)
                    Text("ago")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if p.consentGrantedAt == nil {
                Text("Tap to grant tracking consent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for first location…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// The most recent valid timestamp across this profile's records. We
    /// can't fall back to `.distantPast` for the display string — relative
    /// formatting on a year-1 AD date renders as "2025 yrs ago".
    private func lastTimestamp(of p: MinorProfile) -> Date? {
        let set = (p.records as? Set<LocationRecord>) ?? []
        return set.compactMap(\.timestamp).max()
    }
}

struct MinorDetailView: View {
    let profileID: NSManagedObjectID
    @Environment(\.managedObjectContext) private var ctx
    #if os(iOS) || os(macOS)
    @ObservedObject private var snapService = SnapToRoadsService.shared
    #endif

    var body: some View {
        if let profile = try? ctx.existingObject(with: profileID) as? MinorProfile {
            content(for: profile)
        } else {
            ContentUnavailableView("Profile missing", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func content(for profile: MinorProfile) -> some View {
        let records = sortedRecords(of: profile)
        VStack(spacing: 0) {
            #if os(iOS) || os(macOS)
            mapSection(records: records, displayName: profile.displayName ?? "Last")
                .frame(minHeight: 320)
            #endif
            List {
                Section {
                    consentRow(profile)
                } header: {
                    Text("Tracking consent")
                } footer: {
                    Text("Tracking on this minor's device is gated by your approval. You can revoke at any time and tracking stops on the next sync.")
                }

                Section("Recent points") {
                    ForEach(records.suffix(50).reversed(), id: \.objectID) { r in
                        VStack(alignment: .leading) {
                            if let ts = r.timestamp {
                                Text(ts, style: .relative)
                                    .font(.footnote.monospacedDigit())
                            } else {
                                Text("—")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(String(format: "%.5f, %.5f", r.latitude, r.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(profile.displayName ?? "Minor")
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
                .help("Route the track along real roads via MKDirections")
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

    @ViewBuilder
    private func consentRow(_ profile: MinorProfile) -> some View {
        if let granted = profile.consentGrantedAt {
            VStack(alignment: .leading, spacing: 6) {
                Label("Granted", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("Granted \(granted.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Revoke consent", role: .destructive) {
                    profile.consentGrantedAt = nil
                    try? profile.managedObjectContext?.save()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Not granted", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text("This minor's device cannot record or share location until you grant consent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Grant consent") {
                    profile.consentGrantedAt = Date()
                    try? profile.managedObjectContext?.save()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    #if os(iOS) || os(macOS)
    private func mapSection(records: [LocationRecord], displayName: String) -> some View {
        Group {
            if let last = records.last {
                let fixes = records.suffix(200).compactMap { rec -> TimedFix? in
                    guard let ts = rec.timestamp else { return nil }
                    return TimedFix(latitude: rec.latitude,
                                    longitude: rec.longitude,
                                    timestamp: ts)
                }
                // One polyline per trip — gaps > 10 min split into separate
                // trips so the kid's morning + afternoon walks render
                // independently. Stable trip IDs let `ForEach` reuse the
                // same `MapPolyline` across re-renders for unchanged
                // trips, reducing Metal drawable churn.
                let trips: [IdentifiedTrip] = snapService.isEnabled
                    ? snapService.snappedTrips(fixes)
                    : SnapToRoadsService.rawTrips(fixes)
                let rawTrips = SnapToRoadsService.rawTrips(fixes)
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
                    latitudinalMeters: 1500,
                    longitudinalMeters: 1500
                ))) {
                    Marker(displayName, coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                    // Raw GPS overlay underneath the snapped polylines so
                    // the user can see what got smoothed out.
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
                                .stroke(.tint, lineWidth: 4)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if snapService.isEnabled, snapService.isWorking {
                        let p = snapService.progress
                        HStack(spacing: 8) {
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
                        .padding(12)
                    }
                }
            } else {
                ContentUnavailableView("No location yet", systemImage: "location.slash")
            }
        }
    }
    #endif

    private func sortedRecords(of profile: MinorProfile) -> [LocationRecord] {
        let set = (profile.records as? Set<LocationRecord>) ?? []
        return set.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }
}

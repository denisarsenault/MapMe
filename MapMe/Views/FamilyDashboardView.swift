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
            .mapMeBrandToolbar()
            .navigationDestination(for: NSManagedObjectID.self) { id in
                MinorDetailView(profileID: id)
            }
            .task {
                await guardianSync.ensureSubscription()
            }
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

    var body: some View {
        // Resolve the row once, then hand it to a child view that holds it as
        // an @ObservedObject. Observing the profile is what makes the consent
        // toggle (and any synced change) re-render this screen — without it,
        // tapping "Grant consent" mutated + saved the object but SwiftUI had
        // no dependency on it, so the button appeared to do nothing.
        if let profile = try? ctx.existingObject(with: profileID) as? MinorProfile {
            MinorDetailContent(profile: profile)
        } else {
            ContentUnavailableView("Profile missing", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct MinorDetailContent: View {
    @ObservedObject var profile: MinorProfile
    @State private var consentError: String?
    @State private var nicknameDraft: String = ""
    #if os(iOS) || os(macOS)
    @ObservedObject private var snapService = SnapToRoadsService.shared
    #endif

    var body: some View {
        content(for: profile)
            .alert(
                "Couldn't update consent",
                isPresented: Binding(
                    get: { consentError != nil },
                    set: { if !$0 { consentError = nil } }
                ),
                presenting: consentError
            ) { _ in
                Button("OK", role: .cancel) { consentError = nil }
            } message: { msg in
                Text(msg)
            }
    }

    /// Writes the new consent timestamp and surfaces any save failure instead
    /// of swallowing it — a save to the shared (Guardian-side) profile can
    /// fail for real reasons (e.g. the CKShare granted only read access, or
    /// the shared zone hasn't finished its first sync on a freshly paired
    /// device), and the user needs to see that rather than a dead button.
    private func setConsent(_ date: Date?) {
        profile.consentGrantedAt = date
        do {
            try profile.managedObjectContext?.save()
        } catch {
            profile.managedObjectContext?.rollback()
            consentError = error.localizedDescription
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

                nicknameSection(for: profile)

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

    /// Local-only "spoken name" override. Editable on this Guardian
    /// device; falls back to `displayName` if the field is left blank.
    /// See `GuardianAudioAlertService` for the persistence + speech
    /// pipeline. Seeds the draft from stored state on appearance and
    /// commits it on `.onSubmit` / focus loss.
    @ViewBuilder
    private func nicknameSection(for profile: MinorProfile) -> some View {
        Section {
            TextField(
                profile.displayName ?? "Nickname",
                text: $nicknameDraft
            )
            #if os(iOS)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled(true)
            #endif
            .onSubmit {
                GuardianAudioAlertService.shared.setNickname(nicknameDraft,
                                                             for: profile)
            }
            .onAppear {
                nicknameDraft = GuardianAudioAlertService.shared
                    .nickname(for: profile)
            }
            .onChange(of: nicknameDraft) { _, newValue in
                GuardianAudioAlertService.shared.setNickname(newValue,
                                                             for: profile)
            }
        } header: {
            Text("Spoken nickname")
        } footer: {
            Text("Used by MapMe's audio alerts when this device starts moving — e.g. \"Alice is on the move.\" Local to this device; other Guardian devices set their own.")
        }
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
                    setConsent(nil)
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
                    setConsent(Date())
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
                                .stroke(
                                    trip.isFallback ? AnyShapeStyle(Color.accentColor.opacity(0.55)) : AnyShapeStyle(.tint),
                                    style: trip.isFallback
                                        ? StrokeStyle(lineWidth: 3, dash: [10, 6])
                                        : StrokeStyle(lineWidth: 4)
                                )
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
                .overlay(alignment: .bottomLeading) {
                    // Distinguish a rate-limited render (some solid segments
                    // are raw GPS, not road-matched — they'll snap on a later
                    // view) from a genuine data gap (dashed). Hidden while a
                    // snap is actively in flight so it doesn't fight the
                    // progress badge.
                    if snapService.isEnabled,
                       snapService.hasThrottledResults,
                       !snapService.isWorking {
                        Label("Snapping rate-limited — some segments shown as raw GPS",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
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

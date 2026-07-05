#if os(macOS)
import SwiftUI
import CoreData

/// Mac-class layout for the Guardian role.
///
/// **Sidebar (left)** — list of paired devices with multi-select; in Day
/// mode also exposes a time-of-day scrubber so you can rewind through a
/// single day's locations.
///
/// **Detail (right)** — a `WorldMapView` showing every selected device's
/// track for the chosen date range. Tapping a marker on the map drives the
/// sidebar selection (and vice versa) so the two stay in sync.
///
/// **Toolbar** — view-mode picker (Day / Week / Live), date picker, Today
/// shortcut, and a Settings sheet button.
struct MacGuardianDashboardView: View {
    @EnvironmentObject private var guardianSync: GuardianSyncService
    @StateObject private var sharing = SharingService()

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "displayName", ascending: true)],
        animation: .default
    ) private var profiles: FetchedResults<MinorProfile>

    // Selection / filtering
    @State private var selectedProfileIDs: Set<NSManagedObjectID> = []
    @State private var mapSelection: NSManagedObjectID?

    // Date / mode
    @State private var viewMode: DashboardViewMode = .day
    @State private var selectedDate: Date = Date()
    @State private var timeOfDaySeconds: Double = 86_399  // end-of-day default

    // Map presentation — snap toggle is a global @Published on the service
    // so it stays in sync with the iPhone, watch, and tvOS toggles via
    // each device's own UserDefaults.
    @ObservedObject private var snapService = SnapToRoadsService.shared

    // UI
    @State private var showSettings = false
    @State private var profileToDelete: MinorProfile?
    @State private var deleteError: String?
    @State private var isDeleting = false

    var body: some View {
        // Kept deliberately small — SwiftUI's type-checker won't tolerate
        // the full chain of toolbar / sheet / 4 onChange / onReceive /
        // confirmationDialog / alert in one expression. The lifecycle
        // handlers live in `DashboardLifecycle`, the destructive UI in
        // `DashboardDeletionUI`.
        splitView
            .toolbar { toolbarContent }
            .sheet(isPresented: $showSettings) {
                MacSettingsSheet()
                    .frame(minWidth: 540, minHeight: 480)
            }
            .task { await guardianSync.ensureSubscription() }
            .modifier(DashboardLifecycle(
                viewMode: viewMode,
                selectedDate: selectedDate,
                mapSelection: $mapSelection,
                selectedProfileIDs: $selectedProfileIDs,
                timeOfDaySeconds: $timeOfDaySeconds
            ))
            .modifier(DashboardDeletionUI(
                profileToDelete: $profileToDelete,
                deleteError: $deleteError,
                isDeleting: isDeleting,
                onConfirm: { profile in Task { await remove(profile) } }
            ))
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Family")
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            detailPane
                .navigationTitle("MapMe")
                .navigationSubtitle(subtitle)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if profiles.isEmpty {
                ContentUnavailableView(
                    "No paired family",
                    systemImage: "person.2.slash",
                    description: Text("Accept an invite from a Minor's MapMe app to start mapping their device here.")
                )
            } else {
                List(selection: $selectedProfileIDs) {
                    if viewMode == .day {
                        timeScrubberSection
                    }

                    Section {
                        Button {
                            selectedProfileIDs.removeAll()
                        } label: {
                            Label("All devices (\(profiles.count))",
                                  systemImage: "person.2.fill")
                                .foregroundStyle(selectedProfileIDs.isEmpty ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text("Show on map")
                    } footer: {
                        Text("⌘-click to select multiple devices, or click All to show everyone.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Section("Devices") {
                        ForEach(profiles, id: \.objectID) { profile in
                            deviceRow(profile)
                                .tag(profile.objectID)
                                .contextMenu {
                                    if profile.consentGrantedAt == nil {
                                        Button {
                                            profile.consentGrantedAt = Date()
                                            try? profile.managedObjectContext?.save()
                                        } label: {
                                            Label("Grant consent", systemImage: "checkmark.shield.fill")
                                        }
                                    } else {
                                        Button {
                                            profile.consentGrantedAt = nil
                                            try? profile.managedObjectContext?.save()
                                        } label: {
                                            Label("Revoke consent", systemImage: "exclamationmark.shield")
                                        }
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        profileToDelete = profile
                                    } label: {
                                        Label("Remove from Family", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        profileToDelete = profile
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var timeScrubberSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(timeOfDayLabel)
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button("All day") {
                        timeOfDaySeconds = 86_399
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .disabled(timeOfDaySeconds >= 86_399)
                }
                Slider(value: $timeOfDaySeconds, in: 0...86_399, step: 60)
                    .controlSize(.small)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Time of day")
        } footer: {
            Text("Drag to rewind through this day's fixes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func deviceRow(_ p: MinorProfile) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: p))
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(p.displayName ?? "Unknown")
                        .font(.body)
                        .lineLimit(1)
                    if p.consentGrantedAt == nil {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                            .help("Awaiting consent")
                    }
                }
                if let ts = lastTimestamp(of: p) {
                    Text("Last fix \(ts, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No data yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail (map)

    private var detailPane: some View {
        Group {
            if profiles.isEmpty {
                ContentUnavailableView(
                    "Nothing to map yet",
                    systemImage: "map",
                    description: Text("Once a Minor invites you and grants consent, every paired device shows up here at once.")
                )
            } else {
                WorldMapView(
                    archiveID: nil,
                    profiles: visibleProfiles,
                    dateRange: effectiveDateRange,
                    timeCutoff: effectiveTimeCutoff,
                    liveMode: viewMode == .live,
                    snapToRoads: snapService.isEnabled,
                    colors: colorMap,
                    mapSelection: $mapSelection
                )
                .overlay(alignment: .top) {
                    ConsentBanner(profiles: pendingConsentProfiles)
                }
            }
        }
    }

    /// Profiles in the current sidebar filter that haven't been granted
    /// consent yet. Drives the banner over the map.
    private var pendingConsentProfiles: [MinorProfile] {
        visibleProfiles.filter { $0.consentGrantedAt == nil }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Brand mark on the navigation/leading edge so the window
        // has a visible MapMe identity even when the sidebar is
        // collapsed. `.navigation` slots it next to the
        // back/forward-style chrome on macOS Sequoia+.
        //
        // `MapMeBrandImage` picks the black-text MMLogoLight on a
        // light toolbar and white-text MMLogo on a dark toolbar so
        // the wordmark is always legible — the previous raw
        // `Image("MMLogo")` always used white text and disappeared
        // into the standard light macOS toolbar. Height-only frame
        // preserves the wordmark's 10:3 aspect (a 22×22 square
        // crushed it to a ~22×7 smudge).
        ToolbarItem(placement: .navigation) {
            MapMeBrandImage()
                .frame(height: 24)
        }
        ToolbarItemGroup(placement: .principal) {
            Picker("View mode", selection: $viewMode) {
                ForEach(DashboardViewMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Switch between a single day, a 7-day window, or live tracking")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                selectedDate = Calendar.current.startOfDay(for: Date())
            } label: {
                Label("Today", systemImage: "calendar.badge.clock")
            }
            .help("Jump back to today")
            .disabled(viewMode == .live)

            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .help("Pick a date to centre the view on")
                .disabled(viewMode == .live)

            Button {
                snapService.isEnabled.toggle()
            } label: {
                Label(
                    snapService.isEnabled ? "Snapping on" : "Snap to roads",
                    systemImage: "road.lanes"
                )
                .foregroundStyle(snapService.isEnabled ? Color.accentColor : .primary)
            }
            .help(snapService.isEnabled
                  ? "Tracks follow road geometry via MKDirections. Toggle off for raw GPS lines."
                  : "Route each segment along real roads instead of drawing straight lines. Adds a few seconds the first time per polyline.")

            // Live progress indicator. Without this the user has no
            // visible cue that snap is running in the background — the
            // tracks just look stale until they suddenly resolve.
            if snapService.isWorking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Snapping \(snapService.progress.completed)/\(snapService.progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Snap-to-roads is computing routes via MKDirections. Apple's throttle limits this to ~50 segments/min; a long drive can take a minute or two on first view.")
            }

            Button {
                snapService.showRawOverlay.toggle()
            } label: {
                Label(
                    snapService.showRawOverlay ? "Raw overlay on" : "Show raw GPS",
                    systemImage: "scribble.variable"
                )
                .foregroundStyle(snapService.showRawOverlay ? Color.orange : .primary)
            }
            .help("Overlay the raw GPS polyline (thin, translucent) beneath the snapped one — useful to spot what got smoothed out.")
            .disabled(!snapService.isEnabled)

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open settings")
        }
    }

    // MARK: - Derived state

    private var visibleProfiles: [MinorProfile] {
        if selectedProfileIDs.isEmpty {
            return Array(profiles)
        }
        return profiles.filter { selectedProfileIDs.contains($0.objectID) }
    }

    private var colorMap: [NSManagedObjectID: Color] {
        let palette: [Color] = [
            .blue, .green, .red, .orange, .purple,
            .pink, .cyan, .mint, .indigo, .teal, .yellow
        ]
        return Dictionary(uniqueKeysWithValues: profiles.enumerated().map {
            ($0.element.objectID, palette[$0.offset % palette.count])
        })
    }

    private func color(for p: MinorProfile) -> Color {
        colorMap[p.objectID] ?? .gray
    }

    private func lastTimestamp(of p: MinorProfile) -> Date? {
        let set = (p.records as? Set<LocationRecord>) ?? []
        return set.compactMap(\.timestamp).max()
    }

    /// Inclusive date range that filters records, derived from `viewMode`
    /// and `selectedDate`.
    private var effectiveDateRange: ClosedRange<Date> {
        let cal = Calendar.current
        switch viewMode {
        case .day:
            let start = cal.startOfDay(for: selectedDate)
            let end = cal.date(byAdding: .second, value: 86_399, to: start) ?? start
            return start...end
        case .week:
            let endOfDay = cal.date(byAdding: .second, value: 86_399, to: cal.startOfDay(for: selectedDate)) ?? selectedDate
            let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: selectedDate)) ?? selectedDate
            return start...endOfDay
        case .live:
            let now = Date()
            let start = now.addingTimeInterval(-24 * 3600)
            return start...now
        }
    }

    /// Time-of-day cutoff applied on top of `effectiveDateRange`. Only
    /// meaningful in Day mode; otherwise nil.
    private var effectiveTimeCutoff: Date? {
        guard viewMode == .day else { return nil }
        let dayStart = Calendar.current.startOfDay(for: selectedDate)
        return dayStart.addingTimeInterval(timeOfDaySeconds)
    }

    private var timeOfDayLabel: String {
        guard let cutoff = effectiveTimeCutoff else { return "—" }
        return cutoff.formatted(date: .omitted, time: .shortened)
    }

    private var subtitle: String {
        switch viewMode {
        case .day:
            if Calendar.current.isDateInToday(selectedDate)     { return "Today" }
            if Calendar.current.isDateInYesterday(selectedDate) { return "Yesterday" }
            return selectedDate.formatted(date: .abbreviated, time: .omitted)
        case .week:
            let lo = effectiveDateRange.lowerBound
            let hi = effectiveDateRange.upperBound
            return "\(lo.formatted(date: .abbreviated, time: .omitted)) – \(hi.formatted(date: .abbreviated, time: .omitted))"
        case .live:
            return "Live · last 24 h"
        }
    }

    // MARK: - Actions

    @MainActor
    private func remove(_ profile: MinorProfile) async {
        isDeleting = true
        defer {
            isDeleting = false
            profileToDelete = nil
        }
        do {
            try await sharing.removeProfile(profile)
            selectedProfileIDs.remove(profile.objectID)
            PersistenceController.shared.container.viewContext.refreshAllObjects()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Consent banner

/// Overlays the map with a card for each visible `MinorProfile` whose
/// `consentGrantedAt` is still nil. Without this banner, the Guardian had
/// no on-screen way to actually approve a Minor on the Mac (the sidebar
/// row only showed the "Needs approval" badge as a status indicator).
private struct ConsentBanner: View {
    let profiles: [MinorProfile]

    var body: some View {
        Group {
            if profiles.isEmpty {
                EmptyView()
            } else {
                VStack(spacing: 8) {
                    ForEach(profiles, id: \.objectID) { profile in
                        row(for: profile)
                    }
                }
                .padding(12)
            }
        }
    }

    private func row(for profile: MinorProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(profile.displayName ?? "Device") is awaiting consent")
                    .font(.callout.weight(.semibold))
                Text("Their device won't record or share location until you approve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                profile.consentGrantedAt = Date()
                try? profile.managedObjectContext?.save()
            } label: {
                Label("Grant consent", systemImage: "checkmark.shield.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

// MARK: - Settings sheet wrapper

/// Wraps `SettingsView` so the Mac sheet has a confirmable Done button.
/// `SettingsView` itself stays platform-neutral — on iPhone/iPad it lives
/// inside a tab, where a Done button would be wrong; on Mac the sheet
/// presentation needs an explicit dismiss control plus a Return‑key
/// shortcut so it feels native.
private struct MacSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
    }
}

// MARK: - View modifiers (extracted to keep `body` under the SwiftUI
// type-checker complexity ceiling)

private struct DashboardLifecycle: ViewModifier {
    let viewMode: DashboardViewMode
    let selectedDate: Date
    @Binding var mapSelection: NSManagedObjectID?
    @Binding var selectedProfileIDs: Set<NSManagedObjectID>
    @Binding var timeOfDaySeconds: Double

    func body(content: Content) -> some View {
        content
            .onChange(of: mapSelection) { _, newValue in
                // Tap-on-map → narrow sidebar selection to that device.
                if let id = newValue {
                    selectedProfileIDs = [id]
                }
            }
            .onChange(of: selectedProfileIDs) { _, newValue in
                // Sidebar single-select → highlight that marker on the map.
                let target = newValue.count == 1 ? newValue.first : nil
                if mapSelection != target { mapSelection = target }
            }
            .onChange(of: viewMode) { _, newMode in
                // When Day mode re-engages, reset the time scrubber.
                if newMode == .day { timeOfDaySeconds = 86_399 }
            }
            .onChange(of: selectedDate) { _, _ in
                timeOfDaySeconds = 86_399
            }
            .onReceive(NotificationCenter.default
                .publisher(for: .NSPersistentStoreRemoteChange)
                .receive(on: DispatchQueue.main)
            ) { _ in
                // Drop cached managed objects on EVERY remote-change so
                // @FetchRequest re-resolves with fresh records and the
                // map redraws. The previous `guard viewMode == .live`
                // filter kept Day / Week views stale: a Minor device
                // could push a fresh fix but the marker wouldn't move
                // until the user clicked something (which triggered a
                // separate render pass that happened to re-resolve the
                // fetch). The FetchRequest's own predicate already
                // filters by date range, so this is cheap when the new
                // record falls outside the visible window — no visible
                // redraw happens.
                //
                // `.receive(on: DispatchQueue.main)` is critical here —
                // CloudKit posts the remote-change notification from its
                // background import thread, and `refreshAllObjects`
                // cascades into SwiftUI's @Published state. Mutating from
                // the background trips Combine's "Publishing changes from
                // background threads" warning. Marshaling to main fixes it.
                PersistenceController.shared.container.viewContext.refreshAllObjects()
            }
    }
}

private struct DashboardDeletionUI: ViewModifier {
    @Binding var profileToDelete: MinorProfile?
    @Binding var deleteError: String?
    let isDeleting: Bool
    let onConfirm: (MinorProfile) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Remove this device?",
                isPresented: Binding(
                    get: { profileToDelete != nil && !isDeleting },
                    set: { if !$0 { profileToDelete = nil } }
                ),
                presenting: profileToDelete
            ) { profile in
                Button("Remove", role: .destructive) { onConfirm(profile) }
                Button("Cancel", role: .cancel) { profileToDelete = nil }
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
#endif

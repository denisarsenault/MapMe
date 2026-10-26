#if os(iOS)
import SwiftUI
import CoreData
import CoreLocation
import MapKit

/// iPad Guardian dashboard. Structurally mirrors
/// `AppleTVGuardianDashboardView` — full-screen map behind a two-row
/// top bar and a horizontal device-card row — but uses touch idioms
/// throughout: no focus engine, no pan mode (the map is always
/// pannable), long-press for destructive actions, sheet-based
/// Settings / Help / Pairing.
///
/// iPhone continues to use the tabbed `FamilyDashboardView`; the
/// dispatch happens in `RootView.GuardianTabsView` on
/// `UIDevice.current.userInterfaceIdiom == .pad`.
struct IPadGuardianDashboardView: View {
    @EnvironmentObject private var guardianSync: GuardianSyncService
    @StateObject private var sharing = SharingService()

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "displayName", ascending: true)],
        animation: .default
    ) private var profiles: FetchedResults<MinorProfile>

    @State private var selectedProfileIDs: Set<NSManagedObjectID> = []
    @State private var mapSelection: NSManagedObjectID?
    @State private var selectedDate: Date = Date()
    @State private var liveMode: Bool = false
    @State private var mapStyle: WorldMapStyle = .standard
    @State private var zoomInPulse: Int = 0
    @State private var zoomOutPulse: Int = 0

    @State private var settingsVisible: Bool = false
    @State private var helpVisible: Bool = false
    @State private var pairingVisible: Bool = false
    @State private var addTrackerVisible: Bool = false
    @State private var detailProfileID: NSManagedObjectID?

    @State private var profileToDelete: MinorProfile?
    @State private var deleteError: String?
    @State private var isDeleting: Bool = false

    @AppStorage("MapMe.iPadHelpDismissed") private var helpDismissed: Bool = false

    /// Compact size class on iPhone; regular on iPad + iPhone
    /// landscape on larger phones. Drives the adaptive top-bar
    /// layout — iPhone gets a single-row essentials bar with an
    /// overflow Menu; iPad stays two-row.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact }
    /// Compact vertical means iPhone landscape (roughly ~390 pt
    /// tall). The bottom card row (110 pt) + top bar (~45 pt) + safe
    /// areas would eat almost the whole map. Hide the card row in
    /// that shape and drive device selection through the overflow
    /// menu / long-press on map markers instead — same trick the
    /// tvOS layout uses to keep the map dominant in "wide mode."
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isShortHeight: Bool { vSizeClass == .compact }

    /// One-shot Guardian-device location fetch. Feeds
    /// `WorldMapView.fallbackCenter` so a fresh install with no
    /// Minor records yet still lands the camera on a useful spot.
    @StateObject private var startingLocation = StartingLocationRequester()

    @ObservedObject private var snapService = SnapToRoadsService.shared

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
            chromeLayer
            // Motion-alert balloon overlay, same one used on every
            // Guardian surface. `.zIndex(200)` keeps it above the
            // help sheet backdrop.
            GuardianBalloonOverlay()
                .zIndex(200)
        }
        .onAppear {
            if !helpDismissed { helpVisible = true }
            startingLocation.request()
        }
        .task { await guardianSync.ensureSubscription() }
        .onReceive(NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .receive(on: DispatchQueue.main)
        ) { _ in
            // Refresh on EVERY remote-change so a fresh fix from a
            // Minor device paints in the current date range without
            // waiting for the user to interact. Bounded fetches in
            // WorldMapView + the card row keep this cheap.
            PersistenceController.shared.container.viewContext.refreshAllObjects()
        }
        .onChange(of: mapSelection) { _, newValue in
            if let id = newValue {
                selectedProfileIDs = [id]
            }
        }
        .sheet(isPresented: $settingsVisible) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $helpVisible) {
            helpSheet
        }
        .sheet(isPresented: $pairingVisible) {
            NavigationStack { PairingView() }
        }
        .sheet(isPresented: $addTrackerVisible) {
            AddTrackerView()
        }
        .sheet(item: Binding(
            get: { detailProfileID.map { IdentifiableID(id: $0) } },
            set: { detailProfileID = $0?.id }
        )) { wrapper in
            NavigationStack {
                MinorDetailView(profileID: wrapper.id)
            }
        }
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

    // MARK: - Layers

    @ViewBuilder
    private var mapLayer: some View {
        if profiles.isEmpty {
            ContentUnavailableView {
                Label("No paired family", systemImage: "person.2.slash")
            } description: {
                Text("Send yourself an invite from a Minor device — the pairing sheet is behind the shield button in the top bar.")
            } actions: {
                Button {
                    pairingVisible = true
                } label: {
                    Label("Open pairing", systemImage: "shield")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            WorldMapView(
                archiveID: nil,
                profiles: visibleProfiles,
                dateRange: effectiveDateRange,
                timeCutoff: nil,
                liveMode: liveMode,
                snapToRoads: snapService.isEnabled,
                colors: colorMap,
                mapSelection: $mapSelection,
                style: mapStyle,
                zoomInPulse: zoomInPulse,
                zoomOutPulse: zoomOutPulse,
                fallbackCenter: startingLocation.coordinate
            )
            .ignoresSafeArea()
        }
    }

    private var chromeLayer: some View {
        VStack(spacing: 0) {
            topBar
            if !profiles.isEmpty && !isShortHeight {
                deviceCardRow
            }
            // Siri hint chip — a single WhereIsIntent suggestion so
            // the Guardian sees the exact phrase to speak to Siri.
            // Sits just below the card row (or top bar on iPhone
            // landscape where the row is hidden) so it reads as
            // dashboard chrome rather than content. Dismissible;
            // auto-hides after the user invokes the intent once.
            if !profiles.isEmpty {
                MapMeSiriTip(
                    intent: WhereIsIntent(),
                    storageKey: "MapMe.siriTip.guardianDashboard"
                )
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.22), value: isShortHeight)
        .animation(.easeInOut(duration: 0.22), value: isCompact)
    }

    // MARK: - Top bar (adaptive: single row on iPhone, two rows on iPad)

    @ViewBuilder
    private var topBar: some View {
        if isCompact {
            compactTopBar
        } else {
            regularTopBar
        }
    }

    /// iPad layout — two rows with brand mark centered, dedicated
    /// buttons for every action. Wide enough to fit.
    private var regularTopBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                dateControlsGroup
                Spacer(minLength: 16)
                brandMark
                Spacer(minLength: 16)
                modeToggleGroup
            }
            HStack(spacing: 12) {
                mapToolsGroup
                Spacer(minLength: 12)
                addTrackerButton
                pairingButton
                settingsButton
                helpButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    /// iPhone layout — single row with the essentials (compact date
    /// stepper, tiny brand pin, Snap indicator, Live toggle,
    /// overflow Menu). Everything else lives inside the Menu so
    /// the bar never overflows the screen width.
    private var compactTopBar: some View {
        HStack(spacing: 8) {
            Image("MMBrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)

            compactDateButton
            Spacer(minLength: 4)
            compactSnapChip
            compactLiveToggle
            compactOverflowMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    /// Icon-only chip mirroring the Live toggle style. Accent tint
    /// when snap is on, muted when off. Tap toggles. Sits inline
    /// so the user can see snap state without opening the overflow
    /// menu (which was the only entry point before).
    private var compactSnapChip: some View {
        Button {
            snapService.isEnabled.toggle()
        } label: {
            Image(systemName: "road.lanes")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    (snapService.isEnabled
                     ? Color.accentColor.opacity(0.20)
                     : Color(.tertiarySystemBackground)),
                    in: Capsule()
                )
                .foregroundStyle(snapService.isEnabled ? Color.accentColor : .primary)
        }
        .accessibilityLabel(snapService.isEnabled ? "Snap to roads on" : "Snap to roads off")
    }

    /// Compact "Today · Aug 23" button that opens a date picker
    /// sheet. Doubles as the "step back a day" affordance via a
    /// long-press context menu.
    private var compactDateButton: some View {
        Menu {
            Button {
                selectedDate = Calendar.current
                    .date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            } label: {
                Label("Previous day", systemImage: "chevron.left")
            }
            .disabled(liveMode)
            if !Calendar.current.isDateInToday(selectedDate) {
                Button {
                    selectedDate = Calendar.current
                        .date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                } label: {
                    Label("Next day", systemImage: "chevron.right")
                }
                .disabled(liveMode)
                Button {
                    selectedDate = Date()
                } label: {
                    Label("Today", systemImage: "calendar")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(dateLabel)
                    .lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
        }
        .disabled(liveMode)
        .foregroundStyle(.primary)
    }

    private var compactLiveToggle: some View {
        Button {
            liveMode.toggle()
            if liveMode { selectedDate = Date() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.right")
                Text(liveMode ? "Live" : "Live")
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                (liveMode ? Color.green.opacity(0.20) : Color(.tertiarySystemBackground)),
                in: Capsule()
            )
            .foregroundStyle(liveMode ? Color.green : .primary)
        }
    }

    /// Ellipsis menu with everything that didn't fit in the compact
    /// bar — snap toggle, zoom, map style, add tracker, pairing,
    /// settings, help. Menu is native and free — no bespoke layout
    /// concerns.
    private var compactOverflowMenu: some View {
        Menu {
            // Device selector — surfaced in the overflow because
            // iPhone landscape (compact vertical) hides the bottom
            // card row so the map can dominate. Without this entry
            // there'd be no way to focus a single device in that
            // shape. Also handy on iPhone portrait for jumping
            // straight to a device without scrolling the card row.
            if !profiles.isEmpty {
                Section("Devices") {
                    Button {
                        selectedProfileIDs.removeAll()
                    } label: {
                        Label(
                            selectedProfileIDs.isEmpty ? "All devices ✓" : "All devices",
                            systemImage: "person.2.fill"
                        )
                    }
                    ForEach(profiles, id: \.objectID) { p in
                        Button {
                            selectedProfileIDs = [p.objectID]
                        } label: {
                            let checked = selectedProfileIDs == [p.objectID]
                            Label(
                                (p.displayName ?? "Device") + (checked ? " ✓" : ""),
                                systemImage: p.kind.systemImage
                            )
                        }
                    }
                }
            }
            Section("View") {
                Button {
                    zoomInPulse &+= 1
                } label: {
                    Label("Zoom in", systemImage: "plus.magnifyingglass")
                }
                Button {
                    zoomOutPulse &+= 1
                } label: {
                    Label("Zoom out", systemImage: "minus.magnifyingglass")
                }
                Button {
                    mapStyle = mapStyle.next
                } label: {
                    Label("Map style: \(mapStyle.label)", systemImage: mapStyle.icon)
                }
                Button {
                    snapService.isEnabled.toggle()
                } label: {
                    Label(snapService.isEnabled ? "Snap on" : "Snap off",
                          systemImage: "road.lanes")
                }
                // One-tap battery mode — mirrors the regular bar's
                // `batteryModeButton`. Flips Power profile to
                // Battery, exits Live, turns snap off.
                Button {
                    activateBatteryMode()
                } label: {
                    Label("Save battery", systemImage: "leaf.fill")
                }
            }
            Section {
                Button {
                    addTrackerVisible = true
                } label: {
                    Label("Add pet or device", systemImage: "plus.circle")
                }
                Button {
                    pairingVisible = true
                } label: {
                    Label("Pair a Minor", systemImage: "shield")
                }
            }
            Section {
                Button {
                    settingsVisible = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    helpVisible = true
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.primary)
        }
    }

    private var brandMark: some View {
        HStack(spacing: 10) {
            Image("MMBrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
            Text("MapMe")
                .font(.headline.weight(.semibold))
        }
    }

    private var dateControlsGroup: some View {
        HStack(spacing: 8) {
            Button {
                selectedDate = Calendar.current
                    .date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(liveMode)

            VStack(spacing: 0) {
                Text(dateLabel)
                    .font(.callout.weight(.semibold))
                Text(dateSubLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150)

            if !liveMode, !Calendar.current.isDateInToday(selectedDate) {
                Button {
                    selectedDate = Calendar.current
                        .date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)

                Button {
                    selectedDate = Date()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text("Today")
                    }
                    .fixedSize()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var modeToggleGroup: some View {
        HStack(spacing: 8) {
            Button {
                liveMode.toggle()
                if liveMode { selectedDate = Date() }
            } label: {
                Label(liveMode ? "Live · ON" : "Live",
                      systemImage: "dot.radiowaves.right")
                    .foregroundStyle(liveMode ? Color.green : .primary)
            }
            .buttonStyle(.bordered)

            Button {
                snapService.isEnabled.toggle()
            } label: {
                Label(snapService.isEnabled ? "Snap · ON" : "Snap",
                      systemImage: "road.lanes")
                    .foregroundStyle(snapService.isEnabled ? Color.accentColor : .primary)
            }
            .buttonStyle(.bordered)

            batteryModeButton
        }
    }

    /// One-tap "shed drain" affordance. Flips the three biggest
    /// battery contributors to their low-power states in one go so a
    /// user who notices their iPhone warming up doesn't have to walk
    /// three different Settings surfaces:
    ///
    ///   1. `LocationService.powerProfile = .battery` — swaps
    ///      continuous GPS for SLC + visits (~80 % drop in GPS
    ///      drain). Takes effect immediately.
    ///   2. `liveMode = false` — stops the Guardian's 30 fps
    ///      SwiftUI invalidations driven by `LiveMarkerAnimator`
    ///      and the 20 s poll on CloudKit shared-DB queries.
    ///   3. `snapService.isEnabled = false` — stops MKDirections
    ///      calls + the per-render polyline recompute.
    ///
    /// Does NOT auto-restore when toggled off — the user turns the
    /// individual knobs back on as they want them. Keeping it
    /// one-direction keeps the button's behaviour obvious ("tap
    /// this and the drain stops"), and avoids the trap where a user
    /// toggles battery mode off and silently gets handed back
    /// settings they'd meant to leave alone.
    @ViewBuilder
    private var batteryModeButton: some View {
        Button {
            activateBatteryMode()
        } label: {
            Label("Save battery", systemImage: "leaf.fill")
                .foregroundStyle(Color.green)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Switch to battery saver mode")
    }

    /// Core of `batteryModeButton` — exposed as a method so the
    /// compact overflow menu can call the same path.
    private func activateBatteryMode() {
        LocationService.shared.powerProfile = .battery
        liveMode = false
        snapService.isEnabled = false
    }

    private var mapToolsGroup: some View {
        HStack(spacing: 8) {
            Button {
                zoomInPulse &+= 1
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)

            Button {
                zoomOutPulse &+= 1
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)

            Button {
                mapStyle = mapStyle.next
            } label: {
                Label(mapStyle.label, systemImage: mapStyle.icon)
            }
            .buttonStyle(.bordered)
        }
    }

    private var pairingButton: some View {
        Button {
            pairingVisible = true
        } label: {
            Image(systemName: "shield")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Pair a new device")
    }

    private var addTrackerButton: some View {
        Button {
            addTrackerVisible = true
        } label: {
            Image(systemName: "plus.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Add pet or device tracker")
    }

    private var settingsButton: some View {
        Button {
            settingsVisible = true
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Settings")
    }

    private var helpButton: some View {
        Button {
            helpVisible = true
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Help")
    }

    // MARK: - Device cards

    private var deviceCardRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                allDevicesCard
                ForEach(profiles, id: \.objectID) { p in
                    deviceCard(for: p)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.thinMaterial)
    }

    private static let deviceCardWidth: CGFloat = 200
    private static let deviceCardHeight: CGFloat = 110

    private var allDevicesCard: some View {
        let isAll = selectedProfileIDs.isEmpty
        return Button {
            selectedProfileIDs.removeAll()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.tint)
                    Spacer()
                    if isAll {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                Text("All devices")
                    .font(.headline)
                Text("\(profiles.count) paired")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: Self.deviceCardWidth, height: Self.deviceCardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isAll ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isAll ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func deviceCard(for profile: MinorProfile) -> some View {
        let isSelected = selectedProfileIDs.contains(profile.objectID)
        let color = colorMap[profile.objectID] ?? .gray
        let inRangeCount = fetchCount(for: profile, in: effectiveDateRange)
        let fixInfo = fetchLatestFixInfo(for: profile)
        let lastSeen = fixInfo.timestamp
        let needsApproval = profile.consentGrantedAt == nil
        let motionStatus = GuardianAudioAlertService.motionStatus(
            lastFixAt: lastSeen, latestSpeedMS: fixInfo.speedMS
        )

        return Button {
            if isSelected {
                selectedProfileIDs.remove(profile.objectID)
            } else {
                selectedProfileIDs.insert(profile.objectID)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                    // Attached-status dot next to the profile color
                    // swatch. Green + pulse when fixes are flowing,
                    // grey when quiet — same 30-min window as the
                    // "back online" audio + balloon announcement.
                    OnlineIndicatorDot(status: motionStatus, diameter: 8)
                    if needsApproval {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(color)
                    }
                }

                Text(profile.displayName ?? "Unknown")
                    .font(.headline)
                    .lineLimit(1)

                Group {
                    if needsApproval {
                        Text("Needs approval")
                            .foregroundStyle(.orange)
                    } else if let ts = lastSeen {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text(ts, style: .relative)
                            Text("ago")
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else {
                        Text("No fixes yet")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                Text("\(inRangeCount) fix\(inRangeCount == 1 ? "" : "es") in view")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: Self.deviceCardWidth, height: Self.deviceCardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? color.opacity(0.16) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? color : Color.gray.opacity(0.35), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                detailProfileID = profile.objectID
            } label: {
                Label("Show details", systemImage: "list.bullet.rectangle")
            }
            Button(role: .destructive) {
                profileToDelete = profile
            } label: {
                Label("Remove from Family", systemImage: "trash")
            }
        }
    }

    // MARK: - Help sheet

    private var helpSheet: some View {
        NavigationStack {
            List {
                Section {
                    helpRow(icon: "arrow.left.arrow.right",
                            title: "Step through dates",
                            detail: "Use ◀ ▶ in the top bar; Today snaps back to the current day.")
                    helpRow(icon: "dot.radiowaves.right",
                            title: "Live mode",
                            detail: "Shows the last 24 hours with a pulsing pin on each device's latest fix.")
                    helpRow(icon: "road.lanes",
                            title: "Snap to roads",
                            detail: "Routes trails along actual roads via MKDirections instead of straight lines.")
                    helpRow(icon: "plus.magnifyingglass",
                            title: "Zoom in / out",
                            detail: "Pinch on the map, or use the ± buttons in the top bar.")
                    helpRow(icon: "map",
                            title: "Map style",
                            detail: "Cycles Standard → Satellite → Hybrid on each tap.")
                    helpRow(icon: "person.2.fill",
                            title: "Filter devices",
                            detail: "Tap a device card to show only that one. Tap All devices to reset.")
                    helpRow(icon: "list.bullet.rectangle",
                            title: "Device details",
                            detail: "Long-press a card for the detail view and the Remove action.")
                    helpRow(icon: "shield",
                            title: "Pair a new device",
                            detail: "The shield button opens the pairing sheet — generate an invite for a new Minor.")
                    helpRow(icon: "gearshape",
                            title: "Settings",
                            detail: "Role, security, Family alerts, and versions all live behind the gear icon.")
                }
            }
            .navigationTitle("Navigating MapMe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it") {
                        helpVisible = false
                        helpDismissed = true
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func helpRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24, alignment: .center)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Removal

    @MainActor
    private func remove(_ profile: MinorProfile) async {
        isDeleting = true
        defer {
            isDeleting = false
            profileToDelete = nil
        }
        do {
            try await sharing.removeProfile(profile)
            PersistenceController.shared.container.viewContext.refreshAllObjects()
            // If the removed profile was filtered in, clear the filter so
            // the map doesn't stay showing an empty device.
            selectedProfileIDs.remove(profile.objectID)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: - Bounded store fetches (mirror the tvOS pattern)

    private func fetchLatestTimestamp(for profile: MinorProfile) -> Date? {
        fetchLatestFixInfo(for: profile).timestamp
    }

    /// Newest fix timestamp + raw CLLocation speed (m/s) for the
    /// three-state online indicator. Same bounded fetchLimit=1
    /// pattern as the timestamp-only helper — no set materialisation.
    private func fetchLatestFixInfo(for profile: MinorProfile) -> (timestamp: Date?, speedMS: Double?) {
        guard let ctx = profile.managedObjectContext else { return (nil, nil) }
        let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        request.predicate = NSPredicate(format: "profile == %@", profile)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 1
        guard let rec = try? ctx.fetch(request).first else { return (nil, nil) }
        return (rec.timestamp, rec.speed)
    }

    private func fetchCount(for profile: MinorProfile, in range: ClosedRange<Date>) -> Int {
        guard let ctx = profile.managedObjectContext else { return 0 }
        let request = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        request.predicate = NSPredicate(
            format: "profile == %@ AND timestamp >= %@ AND timestamp <= %@",
            profile, range.lowerBound as NSDate, range.upperBound as NSDate
        )
        return (try? ctx.count(for: request)) ?? 0
    }

    // MARK: - Derived

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

    private var effectiveDateRange: ClosedRange<Date> {
        let cal = Calendar.current
        if liveMode {
            let now = Date()
            return now.addingTimeInterval(-24 * 3600)...now
        }
        let start = cal.startOfDay(for: selectedDate)
        let end = cal.date(byAdding: .second, value: 86_399, to: start) ?? start
        return start...end
    }

    private var dateLabel: String {
        if liveMode { return "Live tracking" }
        let cal = Calendar.current
        if cal.isDateInToday(selectedDate)     { return "Today" }
        if cal.isDateInYesterday(selectedDate) { return "Yesterday" }
        return selectedDate.formatted(date: .abbreviated, time: .omitted)
    }

    private var dateSubLabel: String {
        if liveMode { return "LAST 24 H" }
        return selectedDate.formatted(date: .abbreviated, time: .omitted)
    }
}

/// SwiftUI's `.sheet(item:)` requires `Identifiable`. `NSManagedObjectID`
/// isn't `Identifiable` (Apple provides one on iOS 15+ but only via
/// CoreData extensions that don't compose with SwiftUI's `item:`
/// binding cleanly), so we wrap it here.
private struct IdentifiableID: Identifiable, Hashable {
    let id: NSManagedObjectID
}

#Preview {
    IPadGuardianDashboardView()
}
#endif

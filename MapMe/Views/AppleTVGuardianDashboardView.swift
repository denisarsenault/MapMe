#if os(tvOS)
import SwiftUI
import CoreData
// NOTE: do NOT add `import WidgetKit` here. tvOS doesn't ship the
// WidgetKit framework — Xcode's autocomplete will occasionally re-add
// the import (because some sibling files reference it on other
// platforms), which breaks the tvOS build with "Unable to find module
// dependency: 'WidgetKit'". This file has no WidgetKit usage and
// doesn't need it.

/// Apple TV Guardian dashboard. Read-only by design (tvOS has no GPS, no
/// keyboard, no contextual menus on Siri Remote).
///
/// **Two interaction modes** — without this, once focus lands on the
/// `Map` view the Siri Remote swipes get eaten as pan gestures and
/// there's no way back to the top-bar buttons:
///
/// - **Controls mode** (default). The `Map` is rendered but has
///   `allowsHitTesting(false)`, so focus stays on the top bar and the
///   device card row. The user navigates the dashboard like any other
///   tvOS app: swipe between focusable controls, Click to activate.
/// - **Map mode**. Toggled on by the "Pan map" button (top right) or
///   the Play/Pause button on the Siri Remote. Hit testing is handed
///   to the Map and the chrome dims. A floating "Done" button in the
///   top-right is the only focusable element above the map, so the
///   user can always swipe up from a panning gesture and Click their
///   way back to Controls mode.
///
/// We deliberately skip Week mode and the time scrubber here — both
/// rely on input modalities the Siri Remote doesn't have a great
/// answer for.
struct AppleTVGuardianDashboardView: View {
    @EnvironmentObject private var guardianSync: GuardianSyncService

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "displayName", ascending: true)],
        animation: .default
    ) private var profiles: FetchedResults<MinorProfile>

    @State private var selectedProfileIDs: Set<NSManagedObjectID> = []
    @State private var mapSelection: NSManagedObjectID?
    @State private var selectedDate: Date = Date()
    @State private var liveMode: Bool = false
    /// When true, hit testing + focus are handed to the Map for
    /// panning. When false, the Map is a static backdrop and focus
    /// stays on the top-bar chrome / device card row. Defaults to
    /// false so a fresh launch can't strand the user inside a panning
    /// Map with no obvious way out.
    @State private var mapInteractive: Bool = false
    /// Persisted "user has seen the navigation tutorial" flag. The
    /// first-launch help overlay shows when this is false; the user
    /// can dismiss it for good with the Got it button, or reopen via
    /// the (?) icon in the top bar at any time.
    @AppStorage("MapMe.tvosHelpDismissed") private var helpDismissed: Bool = false
    /// Drives the help sheet independently of `helpDismissed` so the
    /// user can re-open the help even after dismissing it the first
    /// time. We seed it to !helpDismissed in `.onAppear` so a fresh
    /// install lands the user on the tutorial automatically.
    @State private var helpVisible: Bool = false
    @ObservedObject private var snapService = SnapToRoadsService.shared

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
            if !mapInteractive {
                chromeLayer
            } else {
                exitMapOverlay
            }
            if helpVisible {
                helpOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: helpVisible)
        .onAppear {
            // Seed the help sheet on first launch only. After the
            // user taps Got it, `helpDismissed` flips and the sheet
            // stays closed across subsequent app launches.
            if !helpDismissed { helpVisible = true }
        }
        .onPlayPauseCommand {
            // Play/Pause on the Siri Remote is unused on this screen,
            // so we repurpose it as a quick "toggle pan-mode" shortcut.
            // Users who land on Map mode without realising it can hit
            // Play/Pause to escape back to the focus-engine controls.
            mapInteractive.toggle()
        }
        .task { await guardianSync.ensureSubscription() }
        .onReceive(NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .receive(on: DispatchQueue.main)
        ) { _ in
            // `.receive(on: DispatchQueue.main)` marshals CloudKit's
            // background-thread notification onto main before we
            // touch viewContext / cascade into @Published state.
            guard liveMode else { return }
            PersistenceController.shared.container.viewContext.refreshAllObjects()
        }
        .onChange(of: mapSelection) { _, newValue in
            if let id = newValue {
                selectedProfileIDs = [id]
            }
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var mapLayer: some View {
        if profiles.isEmpty {
            ContentUnavailableView(
                "No paired family",
                systemImage: "person.2.slash",
                description: Text("Accept a Minor's MapMe invite from your iPhone — once it's in, this screen will fill with their map.")
            )
        } else {
            WorldMapView(
                // `archiveID: nil` — the tvOS dashboard pulls live
                // profile data via @FetchRequest, never an archived
                // day. The Mac dashboard uses the same nil here; the
                // archive path is the iPhone's DayDetailView only.
                archiveID: nil,
                profiles: visibleProfiles,
                dateRange: effectiveDateRange,
                timeCutoff: nil,
                liveMode: liveMode,
                snapToRoads: snapService.isEnabled,
                colors: colorMap,
                mapSelection: $mapSelection
            )
            .ignoresSafeArea()
            // Hit testing gated by `mapInteractive` so the Map only
            // claims focus + pan gestures when the user explicitly
            // entered Map mode. In Controls mode it's a static
            // backdrop and the focus engine ignores it.
            .allowsHitTesting(mapInteractive)
        }
    }

    private var chromeLayer: some View {
        VStack(spacing: 0) {
            topBar
                .focusSection()
            if !profiles.isEmpty {
                deviceCardRow
                    .focusSection()
            }
            Spacer()
        }
    }

    /// Floating "Done" button shown only while in Map mode. It's the
    /// single focusable element above the panning Map, so a swipe-up
    /// from the map naturally lands on it.
    private var exitMapOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    mapInteractive = false
                } label: {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.trailing, 60)
                .padding(.top, 60)
            }
            Spacer()
        }
    }

    // MARK: - Top bar

    /// Compact top bar. Two design constraints driving this:
    ///
    /// 1. **Uniform footprint.** tvOS focus engine inflates whichever
    ///    button is currently focused, so heterogeneous button styles
    ///    in one row look chaotic (one giant `.borderedProminent`
    ///    button towering over `.bordered` siblings). Everything here
    ///    is `.bordered` with `.font(.callout)` so the resting and
    ///    focused sizes are comparable.
    /// 2. **No "tall floating card" effect.** When the user is on
    ///    today, the forward chevron + "Today" button used to render
    ///    as disabled-but-still-laid-out boxes that floated awkwardly
    ///    between the date label and the toggles. We now *hide* them
    ///    when they'd be no-ops (instead of just disabling) so the
    ///    bar collapses back to "◀ Date" when there's nothing to skip
    ///    forward to.
    private var topBar: some View {
        HStack(spacing: 18) {
            brandMark
            dateControlsGroup
            modeToggleGroup
            Spacer(minLength: 12)
            helpButton
            panMapButton
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    /// Non-focusable logo + wordmark on the leading edge of the top
    /// bar. Identifies the app on a TV screen the user might be
    /// looking at from across the room.
    ///
    /// 56 pt is the empirical "comfortably readable at 10 ft" floor
    /// — at 36 pt it disappeared into the chrome on a typical
    /// living-room couch. Title2 wordmark balances the visual weight
    /// without dominating the top bar's actionable buttons.
    ///
    /// Deliberately not wrapped in a `Button` — making it focusable
    /// would just add a dead stop in the Siri Remote's focus path
    /// that doesn't do anything when Clicked.
    private var brandMark: some View {
        // MMBrandMark = square pin-only icon (not the wordmark MMLogo).
        // At 88 pt it reads cleanly from couch distance without competing
        // visually with the top-bar action buttons.
        HStack(spacing: 16) {
            Image("MMBrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
            Text("MapMe")
                .font(.title2.weight(.semibold))
        }
    }

    private var dateControlsGroup: some View {
        HStack(spacing: 10) {
            Button {
                selectedDate = Calendar.current
                    .date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.left")
                    .font(.callout)
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
            .frame(minWidth: 200)

            // Hide (don't disable) when there's nothing forward to step
            // to. Disabled-but-present chevrons floated as awkward grey
            // boxes in the previous design; collapsing them out
            // tightens the layout and removes a confusing focus target.
            if !liveMode, !Calendar.current.isDateInToday(selectedDate) {
                Button {
                    selectedDate = Calendar.current
                        .date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.callout)
                }
                .buttonStyle(.bordered)

                Button {
                    selectedDate = Date()
                } label: {
                    Label("Today", systemImage: "calendar")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Live + Snap toggles. Same `.bordered` style + `.callout` font
    /// as the date controls so all top-bar buttons sit at the same
    /// resting size. Active state shown through icon colour + the
    /// "· ON" suffix.
    private var modeToggleGroup: some View {
        HStack(spacing: 10) {
            Button {
                liveMode.toggle()
                if liveMode { selectedDate = Date() }
            } label: {
                Label(liveMode ? "Live · ON" : "Live",
                      systemImage: "dot.radiowaves.right")
                    .font(.callout)
                    .foregroundStyle(liveMode ? Color.green : .primary)
            }
            .buttonStyle(.bordered)

            Button {
                snapService.isEnabled.toggle()
            } label: {
                Label(snapService.isEnabled ? "Snap · ON" : "Snap",
                      systemImage: "road.lanes")
                    .font(.callout)
                    .foregroundStyle(snapService.isEnabled ? Color.accentColor : .primary)
            }
            .buttonStyle(.bordered)
        }
    }

    /// Help (?) button. Re-opens the navigation tutorial overlay
    /// even after the user has dismissed it once. Icon-only to keep
    /// it small — focus state still inflates it but it doesn't
    /// crowd the bar.
    private var helpButton: some View {
        Button {
            helpVisible = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.callout)
        }
        .buttonStyle(.bordered)
    }

    /// Primary action: hands map control to the Siri Remote. Same
    /// `.bordered` style + `.callout` font as the other top-bar
    /// buttons so the resting + focused footprints match — the
    /// blue tint is enough visual distinction without making the
    /// button physically larger than its neighbours (which was the
    /// problem with `.borderedProminent` in the previous design).
    private var panMapButton: some View {
        Button {
            mapInteractive = true
        } label: {
            Label("Pan map", systemImage: "hand.draw.fill")
                .font(.callout)
                .foregroundStyle(.blue)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Device cards

    /// Horizontal row of focusable device cards. Each card carries
    /// enough info that the user can pick the right device without
    /// loading the full detail view: color swatch (matches the map
    /// pin / polyline), display name, "needs approval" badge if
    /// applicable, relative last-seen timestamp, and fix count for
    /// the current date range.
    ///
    /// Selection toggles whether that device appears on the map.
    /// "All devices" clears the filter back to "show everyone".
    private var deviceCardRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                allDevicesCard
                ForEach(profiles, id: \.objectID) { p in
                    deviceCard(for: p)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 12)
        }
        .background(.thinMaterial)
    }

    /// Card dimensions. tvOS semantic fonts render ~30 % larger than
    /// on iOS (tuned for a 10-ft viewing distance), so a card sized
    /// for an iOS-like density clips the bottom line. 145 pt is the
    /// empirical "all three info lines visible" floor for the current
    /// padding + font mix below; if you tighten either, you can lower
    /// this — but verify against the longest device name and the
    /// `"15 days, 7 hr ago"` style relative timestamp.
    private static let deviceCardWidth: CGFloat = 220
    private static let deviceCardHeight: CGFloat = 145
    /// Explicit pixel sizes for the subtitle lines. We can't rely on
    /// `.caption2` here — its tvOS-resolved size is large enough that
    /// the third row gets clipped at the bottom of the card. Pinning
    /// to `system(size:)` gives us a known footprint per line. These
    /// are readable at 10 ft (icon-paired text on a contrasty
    /// material background) without burning vertical budget.
    private static let cardSubtitleSize: CGFloat = 16
    private static let cardCaptionSize: CGFloat = 14

    private var allDevicesCard: some View {
        let isAll = selectedProfileIDs.isEmpty
        return Button {
            selectedProfileIDs.removeAll()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "person.2.fill")
                        .font(.callout)
                        .foregroundStyle(.tint)
                    Spacer()
                    if isAll {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.tint)
                    }
                }
                Text("All devices")
                    .font(.system(size: 20, weight: .semibold))
                Text("\(profiles.count) paired")
                    .font(.system(size: Self.cardCaptionSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: Self.deviceCardWidth, height: Self.deviceCardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isAll ? Color.accentColor.opacity(0.20) : Color.gray.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isAll ? Color.accentColor : Color.gray.opacity(0.4),
                            lineWidth: 2)
            )
        }
        .buttonStyle(.card)
    }

    private func deviceCard(for profile: MinorProfile) -> some View {
        let isSelected = selectedProfileIDs.contains(profile.objectID)
        let color = colorMap[profile.objectID] ?? .gray
        let allRecords = (profile.records as? Set<LocationRecord>) ?? []
        let inRange = allRecords.filter { rec in
            guard let ts = rec.timestamp else { return false }
            return effectiveDateRange.contains(ts)
        }
        let lastSeen = allRecords.compactMap(\.timestamp).max()
        let needsApproval = profile.consentGrantedAt == nil

        return Button {
            if isSelected {
                selectedProfileIDs.remove(profile.objectID)
            } else {
                selectedProfileIDs.insert(profile.objectID)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                    if needsApproval {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: Self.cardCaptionSize))
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(color)
                    }
                }

                Text(profile.displayName ?? "Unknown")
                    .font(.system(size: 20, weight: .semibold))
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
                .font(.system(size: Self.cardSubtitleSize, weight: .semibold))

                Text("\(inRange.count) fix\(inRange.count == 1 ? "" : "es") in view")
                    .font(.system(size: Self.cardCaptionSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: Self.deviceCardWidth, height: Self.deviceCardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? color.opacity(0.18) : Color.gray.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? color : Color.gray.opacity(0.4),
                            lineWidth: 2)
            )
        }
        .buttonStyle(.card)
    }

    // MARK: - Help overlay

    /// Centered tutorial card. Shown automatically on first launch
    /// (and re-openable from the (?) button) so a Guardian who picks
    /// up the Siri Remote with no context can see "Pan map ⇆ Done /
    /// Play-Pause ⇆ Click a card to filter" up front. We dim the
    /// background so the help is unmistakably modal — focus engine
    /// lands on the Got it button right away.
    private var helpOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text("Navigating MapMe on Apple TV")
                        .font(.title3.weight(.semibold))
                }

                VStack(alignment: .leading, spacing: 10) {
                    helpRow(icon: "arrow.left.arrow.right",
                            title: "Step through dates",
                            detail: "Use ◀ ▶ to move day-by-day; Today returns to live data.")
                    helpRow(icon: "dot.radiowaves.right",
                            title: "Live mode",
                            detail: "Shows the last 24 hours with a pulsing pin on each device's latest fix.")
                    helpRow(icon: "hand.draw.fill",
                            title: "Pan map",
                            detail: "Hands the Siri Remote to the map so you can swipe to pan and click to zoom. Press Play/Pause anytime as a shortcut.")
                    helpRow(icon: "checkmark.circle.fill",
                            title: "Done (top-right while panning)",
                            detail: "Returns control to the buttons. Play/Pause does the same thing.")
                    helpRow(icon: "person.2.fill",
                            title: "Tap a device card",
                            detail: "Filters the map to that one device. Tap All devices to show everyone again.")
                }

                HStack {
                    Spacer()
                    Button {
                        helpVisible = false
                        helpDismissed = true
                    } label: {
                        Label("Got it", systemImage: "checkmark")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .padding(.horizontal, 80)
        }
    }

    private func helpRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28, alignment: .center)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
        return selectedDate.formatted(date: .complete, time: .omitted)
    }

    /// Secondary line under the date label. Live mode shows the
    /// rolling window; date mode shows the absolute date so the user
    /// can confirm "Today" really is the day they expect (handy across
    /// midnight boundaries with a forgotten Apple TV left on).
    private var dateSubLabel: String {
        if liveMode { return "LAST 24 H" }
        return selectedDate.formatted(date: .abbreviated, time: .omitted)
    }
}


#Preview("Light Mode") {
    AppleTVGuardianDashboardView()
}

#Preview("Dark Mode") {
    AppleTVGuardianDashboardView()
        .preferredColorScheme(.dark)
}
#endif



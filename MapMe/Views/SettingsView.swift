import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var roleStore: AppRoleStore
    @EnvironmentObject private var guardianSync: GuardianSyncService
    @Environment(\.managedObjectContext) private var ctx
    #if os(iOS) || os(macOS)
    @EnvironmentObject private var location: LocationService
    #endif
    #if os(iOS) || os(macOS)
    /// Speed-driven sampling knobs. Lives as a `@MainActor` singleton so
    /// the watch, iPhone, iPad and Mac each keep their own UserDefaults.
    @ObservedObject private var adaptive = AdaptiveSamplingConfig.shared
    #endif
    @State private var showResetConfirm = false
    @State private var showChangePasscode = false
    @State private var showRoleResetConfirm = false
    @State private var showSyncCacheResetConfirm = false
    @State private var syncCacheResetMessage: String?
    @State private var showRemoveEmptyConfirm = false
    @State private var removeEmptyMessage: String?
    @State private var isForceSyncing = false
    @State private var forceSyncStatus: String?
    @StateObject private var sharing = SharingService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Role") {
                    LabeledContent("Mode", value: roleLabel)
                    Button("Switch role…", role: .destructive) { showRoleResetConfirm = true }
                }

                Section("Security") {
                    Toggle("Use Face ID / Touch ID", isOn: $auth.biometricsEnabled)
                    Button("Change security code") { showChangePasscode = true }
                    Button("Lock now") { auth.lock() }
                }

                #if os(iOS) || os(macOS)
                Section("Tracking") {
                    LabeledContent("Authorization", value: authText)
                    if location.isTracking {
                        Button("Pause tracking") { location.stopTracking() }
                    } else {
                        Button("Start tracking") {
                            location.requestAuthorization()
                            location.startTracking()
                        }
                    }
                    if let err = location.trackingError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section {
                    Picker(selection: $location.powerProfile) {
                        ForEach(PowerProfile.allCases) { profile in
                            Label(profile.label, systemImage: profile.systemImage)
                                .tag(profile)
                        }
                    } label: {
                        Text("Profile")
                    }
                    .pickerStyle(.menu)

                    Text(location.powerProfile.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Power")
                } footer: {
                    Text("Battery saver uses ‘significant location changes’ + visit monitoring instead of continuous GPS — coarser tracks but ~80 % less drain. Switch any time; the change applies immediately.")
                        .font(.caption2)
                }
                #endif

                #if os(iOS) || os(macOS)
                adaptiveSamplingSection
                #endif

                #if os(iOS)
                launchReminderSection
                #endif

                if roleStore.role == .guardian {
                    guardianAudioAlertSection
                }

                Section("Data") {
                    Button("Run archive pass now") {
                        ArchiveService(context: PersistenceController.shared.newBackgroundContext())
                            .runArchivePass()
                    }
                    Button("Delete all history", role: .destructive) { showResetConfirm = true }
                }

                // Guardian-only "last resort" section for when
                // CloudKit sync gets wedged. Nukes the local record
                // cache without touching pairings so records
                // re-import fresh from the shared zones on the next
                // sync cycle. See `PersistenceController.resetGuardianSharedCache`.
                if roleStore.role == .guardian {
                    guardianSyncDiagnosticsSection

                    Section {
                        Button {
                            forceSyncNow()
                        } label: {
                            Label(forceSyncStatus ?? "Force sync now",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isForceSyncing)

                        Button(role: .destructive) {
                            showSyncCacheResetConfirm = true
                        } label: {
                            Label("Reset sync cache", systemImage: "arrow.clockwise.circle")
                        }
                        Button(role: .destructive) {
                            showRemoveEmptyConfirm = true
                        } label: {
                            Label("Remove empty profiles", systemImage: "person.crop.circle.badge.xmark")
                        }
                    } header: {
                        Text("Advanced")
                    } footer: {
                        Text("Force sync now: pokes NSPersistentCloudKitContainer to push local writes + pull pending changes immediately, instead of waiting for its next natural cycle. Use when a newly-added device doesn't appear within a few minutes. Reset sync cache: nukes local record cache; keeps pairings intact. Remove empty profiles: bulk-deletes paired devices that have zero fixes (usually old duplicates from reinstalls).")
                            .font(.caption2)
                    }
                }

                Section {
                    NavigationLink {
                        TrustedDevicesView()
                    } label: {
                        Label("Trusted Devices", systemImage: "checkmark.shield")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Devices signed into your iCloud that have opened MapMe. Revoke any you don't recognise.")
                        .font(.caption2)
                }

                Section {
                    LabeledContent("MapMe", value: appVersion)
                    LabeledContent(osLabel, value: osVersion)
                } header: {
                    Text("Versions")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .navigationTitle("Settings")
            .mapMeBrandToolbar()
            .sheet(isPresented: $showChangePasscode) {
                NavigationStack { SetPasscodeView() }
            }
            .confirmationDialog("Delete all stored history?",
                                isPresented: $showResetConfirm,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: deleteAll)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Switch role and re-run setup?",
                                isPresented: $showRoleResetConfirm,
                                titleVisibility: .visible) {
                Button("Switch", role: .destructive) { roleStore.reset() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Reset local sync cache?",
                                isPresented: $showSyncCacheResetConfirm,
                                titleVisibility: .visible) {
                Button("Reset", role: .destructive) { runSyncCacheReset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the local record cache and forces CloudKit to re-import from your paired Minors' shared zones. Pairings, settings, nicknames, and role selection are preserved. Use only when Minor devices show 'Connected' but no fresh fixes appear.")
            }
            .alert("Sync cache reset",
                   isPresented: Binding(
                    get: { syncCacheResetMessage != nil },
                    set: { if !$0 { syncCacheResetMessage = nil } }
                   ),
                   presenting: syncCacheResetMessage) { _ in
                Button("OK", role: .cancel) { syncCacheResetMessage = nil }
            } message: { msg in
                Text(msg)
            }
            .confirmationDialog("Remove all empty profiles?",
                                isPresented: $showRemoveEmptyConfirm,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { runRemoveEmpty() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes every paired device that has zero fixes. Active devices (any recorded location) are preserved. Removed devices can re-pair by tapping Invite Guardian on their side.")
            }
            .alert("Remove empty profiles",
                   isPresented: Binding(
                    get: { removeEmptyMessage != nil },
                    set: { if !$0 { removeEmptyMessage = nil } }
                   ),
                   presenting: removeEmptyMessage) { _ in
                Button("OK", role: .cancel) { removeEmptyMessage = nil }
            } message: { msg in
                Text(msg)
            }
        }
    }

    private func runRemoveEmpty() {
        Task {
            let removed = await sharing.removeEmptyProfiles()
            await MainActor.run {
                PersistenceController.shared.container.viewContext.refreshAllObjects()
                removeEmptyMessage = removed == 0
                    ? "No empty profiles found."
                    : "Removed \(removed) empty profile\(removed == 1 ? "" : "s")."
            }
        }
    }

    /// Nudges `NSPersistentCloudKitContainer` to push local writes +
    /// pull pending imports NOW rather than waiting for its next
    /// natural cycle.
    ///
    /// What actually kicks the export: writing something. We use an
    /// idempotent touch on the current device's TrustedDevice row via
    /// `registerCurrentDevice()` — it updates `lastActiveAt = Date()`
    /// on every call, which is a real Core Data change that the
    /// mirroring delegate picks up and turns into a CloudKit export
    /// op. On the import side, `refreshAllObjects()` invalidates
    /// stale caches so any pending imports become visible.
    ///
    /// Also re-arms `GuardianSyncService.ensureSubscription()` — if
    /// the CKDatabaseSubscription got torn down by a prior reset,
    /// this restores it so remote-change notifications can wake the
    /// app going forward.
    ///
    /// UI-wise: shows "Syncing…" for ~2 s while the async work runs
    /// so the tap gives visible feedback, then flips back to "Force
    /// sync now" once done.
    private func forceSyncNow() {
        guard !isForceSyncing else { return }
        isForceSyncing = true
        forceSyncStatus = "Syncing…"

        // 1. Poke a local write to make the mirroring delegate export.
        TrustedDeviceService.shared.registerCurrentDevice()

        // 2. Force the viewContext to drop stale objects so pending
        //    imports become visible to open Family / Map views.
        PersistenceController.shared.container.viewContext.refreshAllObjects()

        // 3. Re-arm the shared-DB subscription if it dropped.
        Task {
            await guardianSync.ensureSubscription()
        }

        // Reset the button label after a short delay — CloudKit's
        // actual round-trip is 15 s – a few minutes, but 2 s of
        // "Syncing…" is enough visible feedback that the tap
        // registered. Real completion is invisible; the user watches
        // the sidebar populate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isForceSyncing = false
            forceSyncStatus = nil
        }
    }

    private func runSyncCacheReset() {
        PersistenceController.shared.resetGuardianSharedCache { error in
            if let error {
                syncCacheResetMessage = "Reset failed: \(error)"
            } else {
                // Also nuke the announcement state machines so the
                // freshly-reimported records start counting trips
                // from 1 again for each profile.
                GuardianAudioAlertService.shared.resetAllAnnouncementState()
                // Force viewContext to drop caches so any open
                // Family / Map view re-fetches from the emptied
                // stores instead of showing stale cached results.
                PersistenceController.shared.container.viewContext.refreshAllObjects()
                syncCacheResetMessage = "Local cache cleared. Fresh records should arrive from CloudKit within a minute."
            }
        }
    }

    // MARK: - Guardian audio alerts

    /// Guardian-side audio alerts. When enabled, the app speaks a
    /// Minor's nickname aloud on the Guardian device whenever a fresh
    /// fix arrives after ≥ 10 min of stillness — "Alice is on the
    /// move." Backed by `GuardianAudioAlertService.shared`. Only
    /// shown when the current role is `.guardian`; nickname editing
    /// lives on each profile's detail screen. Available on iOS,
    /// macOS, and tvOS.
    @ViewBuilder
    private var guardianAudioAlertSection: some View {
        Section {
            // tvOS: use a plain-string Toggle so the focus engine can
            // land on the switch. A `Toggle` with a `VStack` label
            // makes the descriptive text steal focus and leaves the
            // switch un-clickable via the Siri Remote.
            //
            // iOS / macOS: keep the richer VStack label so the
            // description sits inline like every other Toggle in
            // Form.
            #if os(tvOS)
            Toggle("Speak when a device starts moving", isOn: Binding(
                get: { GuardianAudioAlertService.shared.isEnabled },
                set: { GuardianAudioAlertService.shared.isEnabled = $0 }
            ))
            Text("Announces the device's nickname aloud when new fixes arrive after a period of stillness. Balloons still show even when speak is off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #else
            Toggle(isOn: Binding(
                get: { GuardianAudioAlertService.shared.isEnabled },
                set: { GuardianAudioAlertService.shared.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speak when a device starts moving")
                    Text("Announces the device's nickname aloud when new fixes arrive after a period of stillness. Balloons still show even when speak is off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #endif

            // Diagnostic escape hatch. If persisted state has
            // drifted into "keeps replaying the same events" (or
            // conversely "won't announce anything") territory,
            // wiping resets every profile's state machine + trip
            // log so the next fix from each Minor re-seeds cleanly.
            // No confirmation dialog on tvOS because the tvOS Form
            // stack can't gracefully host one; a stray click here
            // is cheap to recover from anyway (state re-seeds
            // silently on the next fix).
            Button(role: .destructive) {
                GuardianAudioAlertService.shared.resetAllAnnouncementState()
            } label: {
                Label("Reset alert state", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Family alerts")
        } footer: {
            Text("Edit each device's spoken nickname from the Family tab → tap a device. Reset alert state clears trip counters + \"back online\" tracking if announcements start repeating or fall silent.")
                .font(.footnote)
        }
    }

    // MARK: - Adaptive sampling (iOS/macOS only; watch has its own screen)

    #if os(iOS) || os(macOS)
    @ViewBuilder
    private var adaptiveSamplingSection: some View {
        Section {
            Toggle("Enable", isOn: $adaptive.isEnabled)

            if adaptive.isEnabled {
                // Threshold sliders (km/h). Ordering is enforced by the
                // ranges below: stationary < walking < running. We don't
                // try to be clever about cross-clamping — if the user
                // drags a knob past a sibling, the band logic still
                // works (the lower threshold just absorbs the higher one).
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Stationary < \(adaptive.stationaryThresholdKmh, specifier: "%.1f") km/h") {
                        EmptyView()
                    }
                    Slider(value: $adaptive.stationaryThresholdKmh, in: 0.1...5, step: 0.1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Walking < \(adaptive.walkingThresholdKmh, specifier: "%.1f") km/h") {
                        EmptyView()
                    }
                    Slider(value: $adaptive.walkingThresholdKmh, in: 2...20, step: 0.5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Running < \(adaptive.runningThresholdKmh, specifier: "%.1f") km/h") {
                        EmptyView()
                    }
                    Slider(value: $adaptive.runningThresholdKmh, in: 5...40, step: 0.5)
                }

                Divider()

                // Interval sliders (seconds). Stationary tops out at 10 min
                // — past that we may as well not be running at all.
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Stationary every \(Int(adaptive.stationaryInterval)) s") {
                        EmptyView()
                    }
                    Slider(value: $adaptive.stationaryInterval, in: 30...600, step: 10)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Walking every \(Int(adaptive.walkingInterval)) s") {
                        EmptyView()
                    }
                    Slider(value: $adaptive.walkingInterval, in: 15...300, step: 5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Running every \(Int(adaptive.runningInterval)) s") {
                        EmptyView()
                    }
                    Slider(value: $adaptive.runningInterval, in: 10...180, step: 5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Vehicle every \(Int(adaptive.vehicleInterval)) s") {
                        EmptyView()
                    }
                    Slider(value: $adaptive.vehicleInterval, in: 5...120, step: 5)
                }

                Divider()

                liveAdaptiveDiagnostic

                Button("Reset to defaults", role: .destructive) {
                    adaptive.resetToDefaults()
                }
            }
        } header: {
            Text("Adaptive sampling")
        } footer: {
            Text("Cadence varies by motion speed. Off → the Power profile's fixed interval applies. On → writes are throttled per band. Each device keeps its own settings.")
                .font(.caption2)
        }
    }

    /// Shows the current speed (from the live LocationService on iOS) and
    /// which band it maps to, plus the resulting write cadence. Useful when
    /// you're tuning the thresholds and want to see whether you've moved
    /// the kid out of the "Walking" bucket by hand-tweaking sliders.
    @ViewBuilder
    private var liveAdaptiveDiagnostic: some View {
        #if os(iOS)
        let speedKmh = max(0, location.lastLocation?.speed ?? -1) * 3.6
        let band = adaptive.band(forSpeedKmh: speedKmh)
        let interval = adaptive.interval(forSpeedKmh: speedKmh)
        VStack(alignment: .leading, spacing: 2) {
            Text("Now: \(speedKmh, specifier: "%.1f") km/h → \(band)")
                .font(.footnote.monospacedDigit())
            Text("Writing every \(Int(interval)) s")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        #else
        // Mac has no live LocationService env object here, but the user
        // can still tune the bands and the iPhone/iPad/Watch will pick
        // them up from their own UserDefaults on their own devices.
        Text("Live speed available on devices that record their own location.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        #endif
    }
    #endif

    #if os(iOS)
    @ObservedObject private var launchReminder = LaunchReminderService.shared

    private var launchReminderSection: some View {
        Section {
            Toggle("Remind me to open MapMe", isOn: $launchReminder.isEnabled)
            if launchReminder.isEnabled {
                Stepper(value: $launchReminder.reminderHour, in: 1...23) {
                    Text("Daily reminder at \(hourLabel(launchReminder.reminderHour))")
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Fires a local notification once a day (unless you opened MapMe in the last 4 hours), and again when your phone detects you've started moving without tracking on. Movement wake needs ‘Always’ location permission.")
                .font(.caption2)
        }
    }

    private func hourLabel(_ h: Int) -> String {
        var comps = DateComponents()
        comps.hour = h
        comps.minute = 0
        let cal = Calendar.current
        let date = cal.date(from: comps) ?? Date()
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
    #endif

    // MARK: - Guardian sync diagnostics
    //
    // Per-paired-device readout so a "device isn't showing active"
    // report can be triaged without a debugger. For each MinorProfile
    // in the shared store: display name, total record count, most
    // recent record timestamp. If a device is paired but its record
    // count is 0 or its latest timestamp is hours old, it's a sync
    // problem on the Minor side (or the CKShare is broken); if it's
    // recent, the problem is the freshness display, not the data.

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "displayName", ascending: true)],
        animation: .default
    ) private var diagProfiles: FetchedResults<MinorProfile>

    @ViewBuilder
    private var guardianSyncDiagnosticsSection: some View {
        if !diagProfiles.isEmpty {
            Section {
                ForEach(diagProfiles, id: \.objectID) { profile in
                    let (ts, count) = profileSyncStats(for: profile)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName ?? "Unknown device")
                            .font(.callout.weight(.medium))
                        HStack(spacing: 6) {
                            Text("\(count) fix\(count == 1 ? "" : "es")")
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(latestFixLabel(ts))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Sync diagnostics")
            } footer: {
                Text("Per paired device. 0 fixes means this Guardian has never received a record from the device — the device's Invite Guardian flow was probably never run + accepted here. Old timestamp means the Minor stopped uploading (out of range, low battery, or a stalled CloudKit queue).")
                    .font(.caption2)
            }
        }
    }

    /// Fetches (latest timestamp, total record count) for a paired
    /// device. Both are cheap SQLite reads — `fetchLimit=1` +
    /// `count(for:)`. No rows are hydrated for the count.
    private func profileSyncStats(for profile: MinorProfile) -> (Date?, Int) {
        let ctx = ctx
        let latestRequest = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        latestRequest.predicate = NSPredicate(format: "profile == %@", profile)
        latestRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        latestRequest.fetchLimit = 1
        let latest = (try? ctx.fetch(latestRequest).first)?.timestamp

        let countRequest = NSFetchRequest<LocationRecord>(entityName: "LocationRecord")
        countRequest.predicate = NSPredicate(format: "profile == %@", profile)
        let count = (try? ctx.count(for: countRequest)) ?? 0
        return (latest, count)
    }

    private func latestFixLabel(_ date: Date?) -> String {
        guard let date else { return "no fixes yet" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    private var roleLabel: String {
        switch roleStore.role {
        case .unset:    return "Not set"
        case .minor:    return "Tracked device (Minor)"
        case .guardian: return "Guardian"
        }
    }

    #if os(iOS) || os(macOS)
    private var authText: String {
        switch location.authorizationStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When in use"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not determined"
        @unknown default: return "Unknown"
        }
    }
    #endif

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    /// Human-friendly label for the current OS (e.g. "iOS", "iPadOS",
    /// "macOS", "tvOS"). Distinguishes iPhone from iPad on iOS where
    /// the user might have both.
    private var osLabel: String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #else
        return "OS"
        #endif
    }

    /// Semantic-version string of the running OS (e.g. "17.5.1").
    /// Uses `ProcessInfo`'s canonical version string rather than
    /// `UIDevice.systemVersion` so all platforms take the same path.
    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion > 0 {
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    private func deleteAll() {
        let names = ["LocationRecord", "DayArchive"]
        for name in names {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
            let delete = NSBatchDeleteRequest(fetchRequest: request)
            _ = try? ctx.execute(delete)
        }
        try? ctx.save()
    }
}

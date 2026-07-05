import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var roleStore: AppRoleStore
    @Environment(\.managedObjectContext) private var ctx
    #if os(iOS)
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

                #if os(iOS)
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
            Toggle(isOn: Binding(
                get: { GuardianAudioAlertService.shared.isEnabled },
                set: { GuardianAudioAlertService.shared.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speak when a device starts moving")
                    Text("Announces the device's nickname aloud when new fixes arrive after a period of stillness.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Family alerts")
        } footer: {
            Text("Edit each device's spoken nickname from the Family tab → tap a device.")
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

    private var roleLabel: String {
        switch roleStore.role {
        case .unset:    return "Not set"
        case .minor:    return "Tracked device (Minor)"
        case .guardian: return "Guardian"
        }
    }

    #if os(iOS)
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

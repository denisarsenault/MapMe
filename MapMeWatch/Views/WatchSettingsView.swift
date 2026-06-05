import SwiftUI
import CoreData
import CloudKit
import WatchKit

struct WatchSettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var location: WatchLocationService
    @EnvironmentObject private var connectivity: WatchConnectivitySession

    @StateObject private var sharing = SharingService()
    @ObservedObject private var snapService = SnapToRoadsService.shared
    /// Speed-driven sampling knobs for *this watch*. UserDefaults-backed
    /// singleton — slider drags take effect on the very next CL fix.
    @ObservedObject private var adaptive = AdaptiveSamplingConfig.shared

    // Filter to *this watch's* MinorProfile only. Without this, CloudKit
    // sync of the paired iPhone's profile lands in our private store too,
    // and `profiles.first` would show the iPhone's name in the Mode row.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: true)],
        predicate: NSPredicate(format: "deviceIdentifier == %@", DeviceID.current),
        animation: .default
    ) private var profiles: FetchedResults<MinorProfile>

    @State private var inviteURL: URL?
    @State private var inviteError: String?
    @State private var isGenerating = false
    @State private var isSendingViaPhone = false

    var body: some View {
        List {
            Section {
                Label("Tracked device", systemImage: "location")
                    .font(.caption)
                Text(profileSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Mode")
            }

            guardianSection

            Section("Tracking") {
                Text("Auth: \(authText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if location.isLiveTracking {
                    Button("Stop live", role: .destructive) {
                        location.stopLiveTracking()
                    }
                    .font(.caption)
                } else {
                    Button("Request access") { location.requestAuthorization() }
                        .font(.caption)
                }
            }

            Section {
                Picker(selection: $location.powerProfile) {
                    ForEach(PowerProfile.allCases) { profile in
                        Label(profile.label, systemImage: profile.systemImage)
                            .tag(profile)
                    }
                } label: {
                    Text("Profile").font(.caption)
                }

                Text(location.powerProfile.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Power")
            } footer: {
                Text("Battery saver disables Live tracking and relies on the periodic background fetch (~15 min). High accuracy chains 1 h sessions for near‑continuous tracking. Same profile syncs from your iPhone if it's signed into the same iCloud.")
                    .font(.caption2)
            }

            adaptiveSamplingSection

            Section {
                Toggle(isOn: $snapService.isEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Snap to roads").font(.caption)
                        Text("Routes the path along streets. Each new segment hits the network, so leave off for low‑signal trips.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Map")
            }

            Section("Lock") {
                Button("Lock now") { auth.lock() }
                    .font(.caption)
            }

            Section("iPhone") {
                HStack {
                    Image(systemName: connectivity.isReachable ? "iphone" : "iphone.slash")
                    Text(connectivity.isReachable ? "Reachable" : "Not reachable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }

    // MARK: - Adaptive sampling section

    /// Compact speed-band sliders for the watch. Each slider's value reads
    /// and writes through `AdaptiveSamplingConfig.shared`'s `@Published`
    /// vars, which persist to UserDefaults on every change. The watch and
    /// the iPhone keep independent settings, so dialing the watch into a
    /// car-friendly "Vehicle every 15 s" doesn't change the iPhone's
    /// cadence (which often sits in the user's pocket and should write less).
    @ViewBuilder
    private var adaptiveSamplingSection: some View {
        Section {
            Toggle(isOn: $adaptive.isEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Adaptive").font(.caption)
                    Text("Cadence varies by motion speed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if adaptive.isEnabled {
                // Live diagnostic up top so the user can watch which band
                // they're in while dragging sliders below.
                let speedKmh = max(0, location.lastLocation?.speed ?? -1) * 3.6
                let band = adaptive.band(forSpeedKmh: speedKmh)
                let interval = adaptive.interval(forSpeedKmh: speedKmh)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now: \(speedKmh, specifier: "%.1f") km/h → \(band)")
                        .font(.caption2.monospacedDigit())
                    Text("Writing every \(Int(interval)) s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Thresholds (km/h). Crown-friendly steps keep these usable
                // on the tiny screen. We deliberately don't enforce
                // ordering across the three knobs — the band logic in
                // `interval(forSpeedKmh:)` falls through cleanly if the
                // user drags walking below stationary.
                adaptiveSlider(
                    title: "Stationary <",
                    value: $adaptive.stationaryThresholdKmh,
                    range: 0.1...5,
                    step: 0.1,
                    unit: "km/h",
                    format: "%.1f"
                )
                adaptiveSlider(
                    title: "Walking <",
                    value: $adaptive.walkingThresholdKmh,
                    range: 2...20,
                    step: 0.5,
                    unit: "km/h",
                    format: "%.1f"
                )
                adaptiveSlider(
                    title: "Running <",
                    value: $adaptive.runningThresholdKmh,
                    range: 5...40,
                    step: 0.5,
                    unit: "km/h",
                    format: "%.1f"
                )

                // Intervals (seconds). Vehicle floor of 5 s mirrors the
                // hottest cadence we'd ever want — anything tighter just
                // burns CloudKit quota without adding map detail.
                adaptiveIntervalSlider(
                    title: "Stationary",
                    value: $adaptive.stationaryInterval,
                    range: 30...600,
                    step: 10
                )
                adaptiveIntervalSlider(
                    title: "Walking",
                    value: $adaptive.walkingInterval,
                    range: 15...300,
                    step: 5
                )
                adaptiveIntervalSlider(
                    title: "Running",
                    value: $adaptive.runningInterval,
                    range: 10...180,
                    step: 5
                )
                adaptiveIntervalSlider(
                    title: "Vehicle",
                    value: $adaptive.vehicleInterval,
                    range: 5...120,
                    step: 5
                )

                Button("Reset defaults", role: .destructive) {
                    adaptive.resetToDefaults()
                }
                .font(.caption2)
            }
        } header: {
            Text("Adaptive sampling")
        } footer: {
            Text("Off → Power profile interval. On → cadence depends on speed band, per this watch.")
                .font(.caption2)
        }
    }

    /// Shared slider row for a `km/h` threshold. The label refreshes live
    /// because the `@Published` binding emits `objectWillChange` on each
    /// drag tick.
    @ViewBuilder
    private func adaptiveSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(String(format: format, value.wrappedValue)) \(unit)")
                .font(.caption2.monospacedDigit())
            Slider(value: value, in: range, step: step)
        }
    }

    /// Shared slider row for a `seconds` interval. Whole-number formatting
    /// since sub-second cadence isn't meaningful for CL write rates.
    @ViewBuilder
    private func adaptiveIntervalSlider(
        title: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) every \(Int(value.wrappedValue)) s")
                .font(.caption2.monospacedDigit())
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: - Guardian section

    @ViewBuilder
    private var guardianSection: some View {
        Section("Guardian") {
            if let profile = profiles.first, profile.consentGrantedAt != nil {
                Label("Connected", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let url = inviteURL {
                // watchOS ShareLink with iCloud share URLs is unreliable —
                // it can no-op silently. The "Send via iPhone" path uses
                // WatchConnectivity to hand the URL to the phone, which
                // opens UIActivityViewController with a real keyboard +
                // contact picker. We keep the ShareLink as a fallback in
                // case the iPhone is out of reach.
                if connectivity.isReachable {
                    Button {
                        Task { await sendViaPhone(url) }
                    } label: {
                        if isSendingViaPhone {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text("Opening on iPhone…").font(.caption)
                            }
                        } else {
                            Label("Send via iPhone", systemImage: "iphone")
                                .font(.caption)
                        }
                    }
                    .disabled(isSendingViaPhone)
                }

                ShareLink(item: url) {
                    Label("Send from watch", systemImage: "square.and.arrow.up")
                }
                .font(.caption)

                Text(connectivity.isReachable
                     ? "Send via iPhone for a normal Messages compose flow. The watch's share sheet often fails on iCloud links."
                     : "iPhone not reachable — use the watch share sheet, or unlock your iPhone nearby and try again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Generate new") {
                    Task { await generateInvite(replacingExisting: true) }
                }
                .font(.caption2)
                .disabled(isGenerating)
            } else {
                Button {
                    Task { await generateInvite(replacingExisting: false) }
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Creating…").font(.caption)
                        }
                    } else {
                        Label("Invite Guardian", systemImage: "shield.lefthalf.filled")
                            .font(.caption)
                    }
                }
                .disabled(isGenerating)
            }

            if let inviteError {
                Text(inviteError).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func generateInvite(replacingExisting: Bool) async {
        isGenerating = true
        inviteError = nil
        defer { isGenerating = false }
        do {
            let displayName = profiles.first?.displayName
                ?? WKInterfaceDevice.current().name
            let profile = sharing.ensureMinorProfile(displayName: displayName)
            if profile.displayName != displayName {
                profile.displayName = displayName
                try? profile.managedObjectContext?.save()
            }
            // makeShare is a no-op-then-return if a share already exists for
            // this object; pass it back through the same path either way so
            // we end up with a populated `share.url`.
            let (_, _, url) = try await sharing.makeShareAndAwaitURL(for: profile)
            if replacingExisting { inviteURL = nil }
            inviteURL = url
        } catch {
            inviteError = error.localizedDescription
        }
    }

    @MainActor
    private func sendViaPhone(_ url: URL) async {
        isSendingViaPhone = true
        inviteError = nil
        defer { isSendingViaPhone = false }
        let ok = await connectivity.sendShareURL(url)
        if !ok {
            inviteError = "Couldn't reach iPhone. Make sure MapMe is foregrounded on your phone, then try again."
        }
    }

    // MARK: - Derived strings

    private var profileSummary: String {
        guard let profile = profiles.first else {
            return "No profile yet — invite a Guardian to get started."
        }
        if profile.consentGrantedAt == nil {
            return "Waiting for Guardian to grant consent."
        }
        return profile.displayName ?? "Active"
    }

    private var authText: String {
        switch location.authorizationStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When in use"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not set"
        @unknown default: return "Unknown"
        }
    }
}

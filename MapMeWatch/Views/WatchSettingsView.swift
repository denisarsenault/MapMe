import SwiftUI
import CoreData
import CloudKit
import WatchKit
import WidgetKit

struct WatchSettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var location: WatchLocationService
    @EnvironmentObject private var connectivity: WatchConnectivitySession

    @StateObject private var sharing = SharingService()
    @ObservedObject private var snapService = SnapToRoadsService.shared

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

    /// `true` once we've confirmed no MapMe complication is on the active
    /// watch face. Drives the recovery nudge — without a complication,
    /// watchOS won't background-launch MapMe after the watch is recharged /
    /// restarted, so background tracking silently stops until the app is
    /// opened by hand. Starts `false` so the nudge never flashes before the
    /// async check completes (and stays hidden if the check fails).
    @State private var complicationMissing = false

    /// Inline status under the "Test alert" button — populated with
    /// "Sent…" on success or the failure reason ("Notifications are
    /// off in Settings → MapMe → Notifications.") on denial, so a
    /// dropped permission isn't misread as a broken feature.
    @State private var pauseAlertTestStatus: String?

    /// Kind of the watch complication (`MapMeStatusWidget.kind`). The widget
    /// lives in a separate extension target, so we match by literal — the
    /// same identifier the app already uses for `reloadTimelines(ofKind:)`.
    private static let complicationKind = "com.mapme.app.status"

    var body: some View {
        // NavigationStack is required for the `NavigationLink` into
        // `WatchAdaptiveSamplingView`. Previously the body was a bare
        // `List` and `.navigationTitle("Settings")` was decoration —
        // wrapping it in `NavigationStack` makes the title bar real
        // and the push transition work.
        NavigationStack {
            settingsList
                .navigationTitle("Settings")
        }
    }

    private var settingsList: some View {
        List {
            complicationNudgeSection

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

            Section {
                Toggle(isOn: $location.autoStartOnMotion) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-start on motion").font(.caption)
                        Text("Starts Live tracking automatically when the watch detects you've started walking, running, cycling, or driving. Stops it again after five minutes of stillness.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Motion")
            } footer: {
                Text("Requires Motion & Fitness permission. Turn off if you'd rather start and stop Live yourself.")
                    .font(.caption2)
            }

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

            Section {
                NavigationLink {
                    WatchAdaptiveSamplingView()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Adaptive sampling").font(.caption)
                        Text("Cadence varies by motion speed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sampling")
            }

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

            Section {
                Toggle(isOn: $location.pauseAlertEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Alert if tracking pauses").font(.caption)
                        Text("Notifies you to reopen MapMe if no location is recorded for ~30 minutes — e.g. after the watch runs out of power and is recharged.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Lets a user verify the notification permission + delivery
                // chain works *now*, instead of waiting two hours for the
                // real watchdog to fire. Surfaces the failure reason inline
                // (e.g. "Notifications are off in Settings → MapMe") so a
                // silently-denied permission isn't misread as a broken feature.
                Button {
                    pauseAlertTestStatus = "Sending…"
                    location.fireTestPauseAlert { delivered, reason in
                        DispatchQueue.main.async {
                            pauseAlertTestStatus = delivered
                                ? "Sent — check your wrist for the notification."
                                : (reason ?? "Couldn't deliver test alert.")
                        }
                    }
                } label: {
                    Label("Test alert", systemImage: "bell.badge")
                        .font(.caption)
                }
                if let pauseAlertTestStatus {
                    Text(pauseAlertTestStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("A watch left on the charger off your wrist can also pause tracking, so this may occasionally alert when you don't expect it.")
                    .font(.caption2)
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
        // Re-check on every appearance so the nudge clears as soon as the
        // user comes back from adding the complication to their face.
        .onAppear { checkComplicationStatus() }
    }

    // MARK: - Complication nudge

    @ViewBuilder
    private var complicationNudgeSection: some View {
        if complicationMissing {
            Section {
                Label("Add a watch face complication", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("If your watch loses power, MapMe can't resume background tracking on its own after recharging. Adding a MapMe complication to your watch face lets the system relaunch it automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Touch and hold the watch face → Edit → Complications → pick MapMe.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Background tracking")
            }
        }
    }

    /// Asks WidgetKit which complications are currently installed and flips
    /// `complicationMissing` when none of ours is on the active face. Fails
    /// safe to "installed" (no nudge) if the query errors, so a transient
    /// failure never nags the user. Uses the closure-based API (watchOS 9+)
    /// rather than the async `currentConfigurations()` (watchOS 11+).
    private func checkComplicationStatus() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            let missing: Bool
            switch result {
            case .success(let widgets):
                missing = !widgets.contains { $0.kind == Self.complicationKind }
            case .failure:
                missing = false
            }
            DispatchQueue.main.async { complicationMissing = missing }
        }
    }

    // Adaptive-sampling sliders now live in `WatchAdaptiveSamplingView`
    // (pushed via NavigationLink). See that file for the rationale —
    // SwiftUI Sliders inside a List read the parent ScrollView's
    // contentOffset, which spams the "grossly inefficient" warning;
    // hosting them in a dedicated screen confines the warning to one
    // view and keeps this Settings list quiet.

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
                    WKInterfaceDevice.current().play(.click)
                    Task { await generateInvite(replacingExisting: true) }
                }
                .font(.caption2)
                .disabled(isGenerating)
            } else {
                Button {
                    // Immediate tap acknowledgement — the share-creation
                    // call below can take several seconds while CloudKit
                    // sets up the shared zone (the WAL-checkpoint busy
                    // messages in the console are CK mirroring locking
                    // SQLite during that), so without a tap haptic the
                    // user has no idea the button registered.
                    WKInterfaceDevice.current().play(.click)
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
            // Distinct success haptic so the user knows the share is
            // ready before they look at the screen — the call can take
            // 3-8 s on slower connections.
            WKInterfaceDevice.current().play(.success)
        } catch {
            inviteError = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }

    @MainActor
    private func sendViaPhone(_ url: URL) async {
        WKInterfaceDevice.current().play(.click)
        isSendingViaPhone = true
        inviteError = nil
        defer { isSendingViaPhone = false }
        let ok = await connectivity.sendShareURL(url)
        if ok {
            WKInterfaceDevice.current().play(.success)
        } else {
            inviteError = "Couldn't reach iPhone. Make sure MapMe is foregrounded on your phone, then try again."
            WKInterfaceDevice.current().play(.failure)
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

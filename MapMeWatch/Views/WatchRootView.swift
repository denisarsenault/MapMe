import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var roleStore: AppRoleStore
    @EnvironmentObject private var connectivity: WatchConnectivitySession

    var body: some View {
        Group {
            switch auth.state {
            case .unconfigured:
                WatchSetPINView()
            case .locked:
                WatchLockView()
            case .unlocked:
                WatchMinorTabsView()
            }
        }
        .task {
            // The Apple Watch target is Minor-only by design — there's no
            // Guardian dashboard here, only self-tracking + sync. Pin the
            // role so an old install (or a CloudKit-synced AppRoleStore in
            // the future) can't surface Guardian UI.
            if roleStore.role != .minor {
                roleStore.role = .minor
            }
            // Make sure this watch has its OWN MinorProfile in the private
            // store before any tracking starts. Without this, the watch
            // would write `LocationRecord`s with no `profile` relationship
            // (and the Settings UI would show the synced iPhone profile
            // by mistake) until the user tapped Invite Guardian for the
            // first time. Idempotent — `ensureMinorProfile` is keyed by
            // `DeviceID.current`, so it's a no-op on later launches.
            _ = SharingService().ensureMinorProfile(
                displayName: DeviceID.displayName
            )
            // If we're locked and the iPhone is reachable + already
            // authenticated, adopt that unlock state for this session.
            if auth.state == .locked, connectivity.isReachable {
                let phoneUnlocked = await connectivity.requestPhoneUnlockState()
                if phoneUnlocked {
                    auth.unlockFromTrustedPeer()
                }
            }
        }
    }
}

private struct WatchMinorTabsView: View {
    var body: some View {
        TabView {
            WatchLiveView()
                .tabItem { Label("Live", systemImage: "location.fill") }
            WatchSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

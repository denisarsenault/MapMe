import SwiftUI
import CoreData

struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var roleStore: AppRoleStore

    var body: some View {
        Group {
            switch auth.state {
            case .unconfigured:
                SetPasscodeView()
            case .locked:
                LockView()
            case .unlocked:
                switch roleStore.role {
                case .unset:    RoleChooserView()
                case .minor:    MinorTabsView()
                case .guardian: GuardianTabsView()
                }
            }
        }
        .task {
            if auth.state == .locked {
                _ = await auth.tryBiometricUnlock()
            }
        }
    }
}

private struct MinorTabsView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: true)]
    ) private var profiles: FetchedResults<MinorProfile>

    var body: some View {
        // If a profile exists and consent is missing, gate everything except
        // the Guardian / Settings tabs behind the waiting screen.
        if let profile = profiles.first, profile.consentGrantedAt == nil {
            TabView {
                WaitingForConsentView(profile: profile)
                    .tabItem { Label("Status", systemImage: "person.crop.circle.badge.clock") }

                #if os(iOS) || os(macOS)
                NavigationStack { PairingView() }
                    .tabItem { Label("Guardian", systemImage: "shield") }
                #endif

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        } else {
            TabView {
                #if os(iOS) || os(macOS)
                LiveMapView()
                    .tabItem { Label("Live", systemImage: "location.fill") }
                #endif

                HistoryListView()
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

                #if os(iOS) || os(macOS)
                NavigationStack { PairingView() }
                    .tabItem { Label("Guardian", systemImage: "shield") }
                #endif

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}

private struct GuardianTabsView: View {
    var body: some View {
        #if os(macOS)
        // Mac gets a proper desktop layout: sidebar of devices + world map
        // detail pane + toolbar date scrubber + Day/Week/Live modes.
        MacGuardianDashboardView()
        #elseif os(tvOS)
        // Apple TV gets a focus-engine-friendly full-screen map with a
        // top bar of date controls and device chips.
        AppleTVGuardianDashboardView()
        #else
        // iPhone AND iPad both get the map-first dashboard — the
        // Live map IS the primary window, with a chip row for
        // device selection and toolbar buttons for Settings /
        // pairing / add-tracker. Matches the tvOS + macOS UX
        // (map-first). The old iPhone-only tabbed FamilyDashboardView
        // + modal Live sheet is deprecated; MinorDetailView is
        // still reachable via the "Show details" context menu on
        // device chips.
        IPadGuardianDashboardView()
        #endif
    }
}

#if os(watchOS)
import Foundation
import AppIntents
import CoreData
import CoreLocation

/// watchOS Siri AppIntents. The watch is a self-tracking device
/// (Minor role — it produces its own fixes into the shared
/// CloudKit zone) and doesn't have a Guardian dashboard, so the
/// intents here are all "control my own tracking" flavour:
///
///   - "Hey Siri, start live tracking in MapMe"
///   - "Hey Siri, stop live tracking in MapMe"
///   - "Hey Siri, is MapMe tracking"
///
/// The iOS/macOS `MinorProfileEntity` + Guardian intents
/// (`WhereIsIntent`, `WhenLastSeenIntent`) don't apply here —
/// there's no notion of "a paired device I ask Siri about" on the
/// watch itself.

struct WatchStartLiveTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start live tracking"
    static var description: IntentDescription = IntentDescription(
        "Starts continuous MapMe Live tracking on this watch."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = WatchLocationService.shared
        // `ensureLiveTracking` respects the same auth + consent gates
        // the app's own Start button uses, so a Siri call from a
        // never-set-up device gracefully no-ops instead of crashing.
        service.ensureLiveTracking()
        if !service.isLiveTracking {
            // Fall back to a direct start in case always-on is off
            // (Siri users may have manual-control mode enabled).
            service.startLiveTracking()
        }
        return .result(
            dialog: service.isLiveTracking
                ? "Live tracking is on."
                : "Couldn't start Live tracking. Open MapMe to check permission."
        )
    }
}

struct WatchStopLiveTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop live tracking"
    static var description: IntentDescription = IntentDescription(
        "Stops MapMe Live tracking on this watch."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        WatchLocationService.shared.stopLiveTracking()
        return .result(dialog: "Live tracking stopped.")
    }
}

struct WatchTrackingStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Tracking status"
    static var description: IntentDescription = IntentDescription(
        "Returns whether MapMe is currently tracking on this watch."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let on = WatchLocationService.shared.isLiveTracking
        return .result(value: on,
                       dialog: on ? "Yes, MapMe is tracking." : "No, MapMe is idle.")
    }
}

/// Ships the watch intents to Shortcuts / Siri on first launch.
/// Watch target has its OWN AppShortcutsProvider — the iOS/macOS
/// provider (`MapMeShortcuts` in `LogTrackerLocationIntent.swift`)
/// isn't compiled into this target.
struct WatchMapMeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WatchStartLiveTrackingIntent(),
            phrases: [
                "Start live tracking in \(.applicationName)",
                "Start \(.applicationName)",
                "Turn on \(.applicationName)",
            ],
            shortTitle: "Start live tracking",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: WatchStopLiveTrackingIntent(),
            phrases: [
                "Stop live tracking in \(.applicationName)",
                "Stop \(.applicationName)",
                "Turn off \(.applicationName)",
            ],
            shortTitle: "Stop live tracking",
            systemImageName: "location.slash.fill"
        )
        AppShortcut(
            intent: WatchTrackingStatusIntent(),
            phrases: [
                "Is \(.applicationName) tracking",
                "\(.applicationName) status",
            ],
            shortTitle: "Tracking status",
            systemImageName: "waveform.badge.magnifyingglass"
        )
    }
}
#endif

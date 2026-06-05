import WidgetKit
import Foundation

struct MapMeStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> MapMeStatusEntry {
        MapMeStatusEntry(
            date: Date(),
            isLive: false,
            consentGranted: true,
            profileExists: true,
            lastTimestamp: Date().addingTimeInterval(-300)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (MapMeStatusEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MapMeStatusEntry>) -> Void) {
        // The watch app calls `WidgetCenter.shared.reloadTimelines` whenever
        // tracking state changes, but we still ask the system to refresh on
        // its own every 5 minutes so the "minutes ago" copy stays current
        // even if the app process is gone.
        let now = Date()
        let entries = [currentEntry()]
        let next = now.addingTimeInterval(5 * 60)
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    private func currentEntry() -> MapMeStatusEntry {
        let snap = WatchSharedState.readSnapshot()
        return MapMeStatusEntry(
            date: Date(),
            isLive: snap.isLive,
            consentGranted: snap.consentGranted,
            profileExists: snap.profileExists,
            lastTimestamp: snap.lastTimestamp
        )
    }
}

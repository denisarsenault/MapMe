import WidgetKit
import Foundation

struct MapMeStatusEntry: TimelineEntry {
    let date: Date
    let isLive: Bool
    let consentGranted: Bool
    let profileExists: Bool
    let lastTimestamp: Date?
}

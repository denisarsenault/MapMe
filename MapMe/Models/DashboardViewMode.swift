import Foundation

/// How the Guardian dashboard scopes its map data.
///
/// - `day`: a single calendar day, optionally clipped by a time-of-day
///   slider (useful for "where were they at 3 pm?").
/// - `week`: the seven days ending at the selected date — overlapping
///   tracks with one polyline per device.
/// - `live`: a rolling 24-hour window with pulsing markers, auto-refreshes
///   on `NSPersistentStoreRemoteChange` so new fixes appear immediately.
enum DashboardViewMode: String, CaseIterable, Hashable {
    case day, week, live

    var label: String {
        switch self {
        case .day:  return "Day"
        case .week: return "Week"
        case .live: return "Live"
        }
    }

    var icon: String {
        switch self {
        case .day:  return "sun.max"
        case .week: return "calendar"
        case .live: return "dot.radiowaves.right"
        }
    }
}

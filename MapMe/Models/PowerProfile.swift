import Foundation
import CoreLocation

/// Tradeoff between battery life and location-fix granularity.
///
/// **All profiles run GPS as the primary positioning source**, with
/// cell / Wi-Fi as supplemental signals when available. The earlier
/// design coarsened accuracy down to cell-tower-only in Battery mode,
/// which silently broke tracking on devices out of cell / Wi-Fi range
/// (especially standalone Apple Watch). The profile knobs now control
/// *how often* GPS samples are taken and written, not *whether* GPS is
/// running.
///
/// The Minor's `LocationService` reads this and configures
/// `CLLocationManager` accordingly: accuracy, distance filter,
/// auto-pause behaviour, and whether to also keep
/// `startUpdatingLocation()` running (vs. just SLC + visits).
///
/// The user picks this in `SettingsView`; it persists in `UserDefaults`.
enum PowerProfile: String, CaseIterable, Codable, Identifiable {
    /// GPS on, large distance filter (500 m), aggressive coalescing
    /// + auto-pause when stationary. Cheapest while still keeping GPS
    /// as the primary positioning source.
    case battery

    /// GPS on, medium cadence (100 m), auto-pause when stationary.
    /// Recommended default.
    case balanced

    /// GPS on, tight cadence (25 m), never pauses. Highest fidelity,
    /// highest battery cost.
    case highAccuracy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .battery:      return "Battery saver"
        case .balanced:     return "Balanced"
        case .highAccuracy: return "High accuracy"
        }
    }

    var systemImage: String {
        switch self {
        case .battery:      return "leaf"
        case .balanced:     return "bolt.badge.clock"
        case .highAccuracy: return "scope"
        }
    }

    var summary: String {
        switch self {
        case .battery:
            return "GPS on, records every ~500 m. Pauses when stationary. Lowest battery cost while still tracking via GPS."
        case .balanced:
            return "GPS on, records every ~100 m. Pauses when stationary. Recommended for daily use."
        case .highAccuracy:
            return "GPS on, records every ~25 m. Never pauses. Drains battery the fastest."
        }
    }

    // MARK: - CLLocationManager parameters

    /// Desired accuracy. All profiles request GPS-grade accuracy so
    /// the radio actually engages — `kCLLocationAccuracyHundredMeters`
    /// or coarser tells CL "you don't need GPS, Wi-Fi/cell is fine",
    /// which is exactly what broke standalone-watch tracking.
    /// Battery mode uses `NearestTenMeters` instead of `Best` so the
    /// OS has a bit more leeway to skip duty cycles; the actual
    /// sample rate is still bounded by `distanceFilter`.
    var desiredAccuracy: CLLocationAccuracy {
        switch self {
        case .battery:      return kCLLocationAccuracyNearestTenMeters
        case .balanced:     return kCLLocationAccuracyBest
        case .highAccuracy: return kCLLocationAccuracyBest
        }
    }

    var distanceFilter: CLLocationDistance {
        switch self {
        case .battery:      return 500
        case .balanced:     return 100
        case .highAccuracy: return 25
        }
    }

    var pausesLocationUpdatesAutomatically: Bool {
        switch self {
        case .battery, .balanced: return true
        case .highAccuracy:       return false
        }
    }

    /// Whether the service should keep `startUpdatingLocation()`
    /// running. All profiles do — Battery used to skip it (relying on
    /// SLC + visits, which are cell-tower-only and gave no fixes
    /// without cell / Wi-Fi). Power savings in Battery mode now come
    /// from the larger `distanceFilter` + auto-pause + sparse write
    /// cadence, not from disabling continuous GPS.
    var usesContinuousUpdates: Bool {
        switch self {
        case .battery, .balanced, .highAccuracy: return true
        }
    }

    /// Minimum spacing between persisted records, on top of the CL
    /// `distanceFilter`. Battery mode also coalesces hard so CloudKit
    /// pushes don't hammer.
    var minimumWriteIntervalSeconds: TimeInterval {
        switch self {
        case .battery:      return 300   // 5 min
        case .balanced:     return 90
        case .highAccuracy: return 30
        }
    }
}

import Foundation
import Combine

/// Per-device adaptive sampling: the minimum write interval for new
/// `LocationRecord`s varies by the device's current motion speed.
///
/// **Why:** A single fixed cadence (`PowerProfile.minimumWriteIntervalSeconds`)
/// is wrong for both ends of the spectrum. A kid sitting in class doesn't
/// need a fix every 90 s — that just burns battery and CloudKit quota.
/// A kid in a car at 50 km/h needs writes every ~15 s or the polyline
/// has 700 m gaps. Speed-driven intervals fix both at once.
///
/// **How it gets used:** `LocationService.persist` (iOS/macOS) and
/// `WatchLocationService.persist` (watchOS) read
/// `interval(forSpeedKmh:)` based on `location.speed` and gate writes on
/// the returned interval. When `isEnabled` is false, the fixed
/// `PowerProfile` cadence is used instead.
///
/// **Persistence:** each `@Published` property has a `didSet` that writes
/// to `UserDefaults` immediately. Defaults are device-local — the watch,
/// iPhone, iPad, and Mac each keep their own settings.
@MainActor
final class AdaptiveSamplingConfig: ObservableObject {
    static let shared = AdaptiveSamplingConfig()

    /// Master switch. Defaults to off so existing installs keep their
    /// `PowerProfile`-driven cadence until the user opts in.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.kEnabled) }
    }

    // MARK: - Speed band thresholds (km/h)
    //
    // Speed buckets are open at the bottom and closed at the top:
    //   [0, stationaryThresholdKmh)        → Stationary
    //   [stationaryThresholdKmh, walking…) → Walking
    //   [walkingThresholdKmh, running…)    → Running
    //   [runningThresholdKmh, ∞)           → Vehicle

    @Published var stationaryThresholdKmh: Double {
        didSet { UserDefaults.standard.set(stationaryThresholdKmh, forKey: Self.kStationary) }
    }
    @Published var walkingThresholdKmh: Double {
        didSet { UserDefaults.standard.set(walkingThresholdKmh, forKey: Self.kWalking) }
    }
    @Published var runningThresholdKmh: Double {
        didSet { UserDefaults.standard.set(runningThresholdKmh, forKey: Self.kRunning) }
    }

    // MARK: - Write interval per band (seconds)

    @Published var stationaryInterval: TimeInterval {
        didSet { UserDefaults.standard.set(stationaryInterval, forKey: Self.kStationaryInt) }
    }
    @Published var walkingInterval: TimeInterval {
        didSet { UserDefaults.standard.set(walkingInterval, forKey: Self.kWalkingInt) }
    }
    @Published var runningInterval: TimeInterval {
        didSet { UserDefaults.standard.set(runningInterval, forKey: Self.kRunningInt) }
    }
    @Published var vehicleInterval: TimeInterval {
        didSet { UserDefaults.standard.set(vehicleInterval, forKey: Self.kVehicleInt) }
    }

    // MARK: - Keys

    private static let kEnabled = "MapMe.adaptive.enabled"
    private static let kStationary = "MapMe.adaptive.stationaryThreshold"
    private static let kWalking = "MapMe.adaptive.walkingThreshold"
    private static let kRunning = "MapMe.adaptive.runningThreshold"
    private static let kStationaryInt = "MapMe.adaptive.stationaryInterval"
    private static let kWalkingInt = "MapMe.adaptive.walkingInterval"
    private static let kRunningInt = "MapMe.adaptive.runningInterval"
    private static let kVehicleInt = "MapMe.adaptive.vehicleInterval"

    private init() {
        let d = UserDefaults.standard
        self.isEnabled = d.bool(forKey: Self.kEnabled)
        self.stationaryThresholdKmh = Self.readDouble(Self.kStationary, fallback: 1.0)
        self.walkingThresholdKmh    = Self.readDouble(Self.kWalking,    fallback: 8.0)
        self.runningThresholdKmh    = Self.readDouble(Self.kRunning,    fallback: 15.0)
        self.stationaryInterval     = Self.readDouble(Self.kStationaryInt, fallback: 300)
        self.walkingInterval        = Self.readDouble(Self.kWalkingInt,    fallback: 60)
        self.runningInterval        = Self.readDouble(Self.kRunningInt,    fallback: 30)
        self.vehicleInterval        = Self.readDouble(Self.kVehicleInt,    fallback: 15)
    }

    /// Minimum write interval (seconds) for a CL fix at the given speed
    /// (km/h). Speeds < 0 (CL's "unavailable" sentinel) are treated as
    /// stationary — safer to over-coalesce than to over-write.
    func interval(forSpeedKmh speed: Double) -> TimeInterval {
        let s = max(0, speed)
        if s < stationaryThresholdKmh { return stationaryInterval }
        if s < walkingThresholdKmh    { return walkingInterval }
        if s < runningThresholdKmh    { return runningInterval }
        return vehicleInterval
    }

    /// Human-readable band name for a given speed. Used by the dev UI to
    /// show the user which interval their motion is currently mapped to.
    func band(forSpeedKmh speed: Double) -> String {
        let s = max(0, speed)
        if s < stationaryThresholdKmh { return "Stationary" }
        if s < walkingThresholdKmh    { return "Walking" }
        if s < runningThresholdKmh    { return "Running" }
        return "Vehicle"
    }

    /// Restores all knobs to the shipped defaults. Useful in the UI as a
    /// "Reset to defaults" button when the user has tuned too aggressively
    /// and stopped recording any locations.
    func resetToDefaults() {
        isEnabled = false
        stationaryThresholdKmh = 1.0
        walkingThresholdKmh = 8.0
        runningThresholdKmh = 15.0
        stationaryInterval = 300
        walkingInterval = 60
        runningInterval = 30
        vehicleInterval = 15
    }

    private static func readDouble(_ key: String, fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
}

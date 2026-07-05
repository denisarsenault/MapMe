#if os(iOS) || os(watchOS)
import Foundation
import CoreMotion
import Combine

/// Wraps `CMMotionActivityManager` so the location services can react to
/// "the user just started moving" without each one needing to spin up
/// their own Core Motion plumbing.
///
/// Publishes:
///  - `isMoving`: `true` when the classifier reports walking / running /
///    cycling / automotive with at least `.medium` confidence.
///  - `activityDescription`: a short label suitable for logging.
///
/// Availability:
///  - iOS: works while the app is running OR suspended, provided
///    `startActivityUpdates(to:)` was called at some point. The
///    OS resumes delivery on next foreground/background wake.
///  - watchOS: only fires while the app has runtime (foreground,
///    live workout session, or an extended runtime session). On a
///    plain suspended watch app the queue is silent — hence the
///    watch service pairs this monitor with its background-refresh
///    ping so a wake-up can re-evaluate motion state.
@MainActor
final class MotionActivityMonitor: ObservableObject {
    static let shared = MotionActivityMonitor()

    @Published private(set) var isMoving: Bool = false
    @Published private(set) var activityDescription: String = "unknown"

    /// True once we've successfully asked CMMotionActivityManager for
    /// updates. If the user denies the "Motion & Fitness" permission,
    /// this stays true (we asked) but `isMoving` will never flip —
    /// which is a deliberate silent failure so a denied permission
    /// doesn't hard-block tracking.
    private(set) var isAuthorizedAndRunning: Bool = false

    private let manager = CMMotionActivityManager()
    private var queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MapMe.MotionActivityMonitor"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private init() {}

    /// Starts activity classification. Idempotent — safe to call from
    /// service init even if the monitor was already running.
    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        guard !isAuthorizedAndRunning else { return }
        isAuthorizedAndRunning = true

        manager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let self, let activity else { return }
            // The classifier can flag *multiple* modes at once (e.g.
            // "walking + unknown"). We want a single Boolean for "user
            // is moving," so treat any locomotion flag as movement.
            let confidenceOK = activity.confidence != .low
            let moving = confidenceOK && (activity.walking || activity.running
                                          || activity.cycling || activity.automotive)
            let label = Self.describe(activity)

            // The Core Motion queue is a background OperationQueue, so
            // hop to the main actor before touching @Published state.
            Task { @MainActor in
                self.activityDescription = label
                if self.isMoving != moving {
                    self.isMoving = moving
                }
            }
        }
    }

    func stop() {
        guard isAuthorizedAndRunning else { return }
        manager.stopActivityUpdates()
        isAuthorizedAndRunning = false
    }

    private static func describe(_ a: CMMotionActivity) -> String {
        var parts: [String] = []
        if a.stationary { parts.append("stationary") }
        if a.walking    { parts.append("walking") }
        if a.running    { parts.append("running") }
        if a.cycling    { parts.append("cycling") }
        if a.automotive { parts.append("automotive") }
        if a.unknown    { parts.append("unknown") }
        if parts.isEmpty { parts.append("idle") }
        let confidence: String
        switch a.confidence {
        case .low:    confidence = "low"
        case .medium: confidence = "med"
        case .high:   confidence = "high"
        @unknown default: confidence = "?"
        }
        return "\(parts.joined(separator: "+")) (\(confidence))"
    }
}
#endif

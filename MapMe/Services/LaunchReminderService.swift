#if os(iOS) || os(watchOS)
import Foundation
import UserNotifications
import os
#if os(iOS)
import UIKit
import CoreLocation
#endif
#if os(watchOS)
import WatchKit
#endif

/// Prompts the user to open MapMe so tracking can resume.
///
/// Two triggers, either can fire:
/// - **Daily calendar notification** — schedules a `UNCalendarNotification`
///   at the user's preferred hour (default 8:00). Fires whether the app
///   is running or terminated; if MapMe was opened within
///   `activityQuietWindow` (4 h) the notification content decision
///   suppresses it.
/// - **Movement-triggered (iOS only)** — starts significant-location-change
///   monitoring so iOS wakes the app briefly on meaningful movement.
///   When we get woken and detect we're not currently live-tracking,
///   we post a one-shot notification. Needs `Always` location auth to
///   actually wake us from a terminated state; degrades to a no-op
///   when the user only granted `When In Use`.
///
/// State is persisted in `UserDefaults` under `MapMe.launchReminder.*`
/// so the toggle + hour survive relaunches. Default `isEnabled = true`
/// — the wearer's expectation is "the app should nag me if it stopped
/// tracking", not "silently drop coverage."
@MainActor
final class LaunchReminderService: NSObject, ObservableObject {
    static let shared = LaunchReminderService()

    nonisolated private static let log = Logger(subsystem: "com.mybrightzone.app", category: "launch-reminder")

    // MARK: - UserDefaults keys
    //
    // All `nonisolated` — UserDefaults access is thread-safe, and
    // completion handlers from `UNUserNotificationCenter` + the
    // `CLLocationManagerDelegate` calls arrive on background threads
    // that can't hop to the main actor synchronously.

    nonisolated private static let kEnabledKey = "MapMe.launchReminder.enabled"
    nonisolated private static let kReminderHourKey = "MapMe.launchReminder.hour"
    nonisolated private static let kLastActivityKey = "MapMe.launchReminder.lastActivityAt"
    nonisolated private static let kLastSLCReminderKey = "MapMe.launchReminder.lastSLCReminderAt"
    /// Written by `LocationService` / `WatchLocationService` from
    /// `startTracking()` + `stopTracking()`. Read from cold-launch
    /// SLC / background-refresh contexts where the in-memory
    /// `@Published isTracking` isn't available yet (the app was
    /// terminated when the wake fired). Cross-process-safe because
    /// it's just `UserDefaults.standard`.
    nonisolated static let kTrackingActiveKey = "MapMe.launchReminder.trackingActive"

    /// Small helper for tracking services to keep the persisted flag
    /// in lockstep with their in-memory `isTracking`. Static +
    /// `nonisolated` so callers don't have to touch the singleton
    /// (avoids waking the notification stack on every start/stop)
    /// and can be called from any actor context.
    nonisolated static func setTrackingActive(_ active: Bool) {
        UserDefaults.standard.set(active, forKey: Self.kTrackingActiveKey)
    }

    nonisolated static func isTrackingActive() -> Bool {
        UserDefaults.standard.bool(forKey: Self.kTrackingActiveKey)
    }

    /// Identifiers used with `UNUserNotificationCenter` — kept as
    /// constants so the daily-reschedule path can cleanly cancel the
    /// prior request before adding a new one, and the movement path
    /// can dedup its own notifications.
    private static let dailyRequestID = "com.mapme.launchReminder.daily"
    private static let movementRequestID = "com.mapme.launchReminder.movement"

    // MARK: - Windows

    /// If the user has opened MapMe within this window, we suppress
    /// the reminder — the intent is "wake me if I forgot", not "spam
    /// me while I'm actively using the app."
    static let activityQuietWindow: TimeInterval = 4 * 60 * 60

    /// Minimum gap between two movement-triggered reminders — SLC can
    /// fire every ~500 m of travel, and we don't want to flood the
    /// user's Notification Center on a road trip.
    static let movementReminderCooldown: TimeInterval = 6 * 60 * 60

    // MARK: - Published state

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.kEnabledKey)
            applyEnabledState()
        }
    }

    @Published var reminderHour: Int {
        didSet {
            UserDefaults.standard.set(reminderHour, forKey: Self.kReminderHourKey)
            if isEnabled { scheduleDailyReminder() }
        }
    }

    // MARK: - iOS SLC

    #if os(iOS)
    /// Dedicated CL manager for SLC — kept separate from
    /// `LocationService`'s manager so enabling/disabling reminders
    /// doesn't perturb the live-tracking pipeline's authorization
    /// dialog or delegate.
    private lazy var slcManager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        return m
    }()
    #endif

    // MARK: - Init

    private override init() {
        // Default ON — the user explicitly asked for "remind me to
        // launch if I'm not running."
        if UserDefaults.standard.object(forKey: Self.kEnabledKey) != nil {
            self.isEnabled = UserDefaults.standard.bool(forKey: Self.kEnabledKey)
        } else {
            self.isEnabled = true
        }
        let storedHour = UserDefaults.standard.integer(forKey: Self.kReminderHourKey)
        self.reminderHour = (1...23).contains(storedHour) ? storedHour : 8
        super.init()
        // Apply on next runloop tick so we don't force notification
        // permission prompts inside the singleton init (which can be
        // touched during app startup).
        DispatchQueue.main.async { [weak self] in
            self?.applyEnabledState()
        }
    }

    // MARK: - Activity tracking

    /// Call whenever the app becomes active or the user interacts
    /// with a tracking-related surface. The daily notification's
    /// content-decision path reads this to suppress the alert when
    /// the user was clearly here recently.
    func recordAppActivity() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.kLastActivityKey)
    }

    private var lastActivityAt: Date? {
        let ts = UserDefaults.standard.double(forKey: Self.kLastActivityKey)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private var withinQuietWindow: Bool {
        guard let last = lastActivityAt else { return false }
        return Date().timeIntervalSince(last) < Self.activityQuietWindow
    }

    // MARK: - Apply toggle

    private func applyEnabledState() {
        if isEnabled {
            requestAuthorizationThenSchedule()
            #if os(iOS)
            startSLCMonitoring()
            #endif
        } else {
            cancelAllReminders()
            #if os(iOS)
            stopSLCMonitoring()
            #endif
        }
    }

    private func requestAuthorizationThenSchedule() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
            if let error {
                Self.log.error("notification auth error: \(error.localizedDescription, privacy: .public)")
            }
            guard granted else {
                Self.log.notice("notification auth denied — reminders won't fire")
                return
            }
            DispatchQueue.main.async {
                self?.scheduleDailyReminder()
            }
        }
    }

    // MARK: - Daily notification

    private func scheduleDailyReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.dailyRequestID])

        let content = UNMutableNotificationContent()
        content.title = "MapMe isn't tracking"
        content.body = "Open MapMe so today's trip gets recorded."
        content.sound = .default

        var comps = DateComponents()
        comps.hour = reminderHour
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.dailyRequestID,
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                Self.log.error("scheduleDailyReminder failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.notice("daily reminder scheduled for \(comps.hour ?? -1):00")
            }
        }
    }

    private func cancelAllReminders() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.dailyRequestID, Self.movementRequestID]
        )
    }

    // MARK: - Movement (SLC / watch background) reminders

    /// Posts a one-shot "MapMe isn't tracking" notification if the
    /// suppression rules allow it. Called by the SLC delegate on iOS
    /// and by `WatchAppDelegate.handleAppRefresh` on watchOS.
    func fireMovementReminderIfNeeded(isCurrentlyTracking: Bool) {
        guard isEnabled else { return }
        guard !isCurrentlyTracking else { return }
        guard !withinQuietWindow else { return }

        let ts = UserDefaults.standard.double(forKey: Self.kLastSLCReminderKey)
        let lastReminder = ts > 0 ? Date(timeIntervalSince1970: ts) : Date.distantPast
        guard Date().timeIntervalSince(lastReminder) > Self.movementReminderCooldown else { return }

        let content = UNMutableNotificationContent()
        content.title = "MapMe stopped tracking"
        content.body = "Tap to open MapMe and resume your trip."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.movementRequestID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("fireMovementReminder failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.notice("movement reminder posted")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.kLastSLCReminderKey)
            }
        }
    }

    // MARK: - iOS SLC lifecycle

    #if os(iOS)
    private func startSLCMonitoring() {
        // Only useful if we can be woken while terminated. That
        // requires `Always` auth; `When In Use` will still fire
        // callbacks while the app is foreground but that path is
        // covered by the user just using the app.
        let status = slcManager.authorizationStatus
        guard status == .authorizedAlways else {
            Self.log.notice("startSLCMonitoring skipped — auth is \(status.rawValue) (need Always)")
            return
        }
        slcManager.startMonitoringSignificantLocationChanges()
        Self.log.notice("SLC monitoring started")
    }

    private func stopSLCMonitoring() {
        slcManager.stopMonitoringSignificantLocationChanges()
        Self.log.notice("SLC monitoring stopped")
    }
    #endif
}

#if os(iOS)
extension LaunchReminderService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        // Read the cross-process tracking flag rather than touching
        // LocationService — the SLC wake can arrive in a cold-launched
        // process where the app's SwiftUI graph (and its
        // LocationService StateObject) hasn't spun up yet.
        let tracking = LaunchReminderService.isTrackingActive()
        DispatchQueue.main.async { [weak self] in
            self?.fireMovementReminderIfNeeded(isCurrentlyTracking: tracking)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // If the user granted Always after we already flipped
            // reminders on, start monitoring now.
            if self.isEnabled {
                self.startSLCMonitoring()
            }
        }
    }
}
#endif
#endif

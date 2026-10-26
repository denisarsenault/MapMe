#if os(iOS) || os(macOS)
import Foundation
import CoreLocation
import Combine

/// One-shot, best-effort "where is this device right now" fetcher for
/// Guardian dashboards. Publishes a single `CLLocationCoordinate2D`
/// once the OS returns a fix; consumers observe it and hand it off
/// to `WorldMapView.fallbackCenter` so the first frame of a fresh
/// Guardian dashboard has a useful centre even before any Minor
/// records arrive.
///
/// Deliberately separate from `LocationService` — that class is the
/// Minor's continuous tracker with a battery-tuned power profile
/// and CoreData writes on every fix. Here we want the OPPOSITE:
/// no persistence, no re-fires, no background modes, and a coarse
/// accuracy so the OS can hand us a cached fix in milliseconds
/// instead of firing up the GPS radio.
///
/// Authorization is handled gracefully — if the user has denied
/// location or the state is restricted, we just publish nothing.
/// Guardian users may reasonably refuse location access ("I don't
/// track myself, I only watch the kids") and we don't want the
/// dashboard nagging them.
@MainActor
final class StartingLocationRequester: NSObject, ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager: CLLocationManager
    /// Guards `requestLocation()` — the delegate can be called back
    /// multiple times if authorization flips while we're waiting.
    /// We only want the first fix.
    private var hasReceivedFix: Bool = false

    override init() {
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        // 100 m is plenty for the initial camera fit. `hundredMeters`
        // lets the OS return a cached fix immediately in most cases
        // instead of powering up the GPS chip — critical because
        // Guardian devices (Mac, iPad-as-Guardian) may never actively
        // record and won't have a warm GPS cache from tracking.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Kick off a one-shot request. Safe to call multiple times —
    /// subsequent calls short-circuit once `coordinate` is set.
    func request() {
        guard coordinate == nil, !hasReceivedFix else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // The delegate's authorization-change callback will
            // continue the flow if the user grants access.
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            // Silent — Guardian may legitimately refuse, and the
            // starting-location fallback is best-effort.
            break
        @unknown default:
            break
        }
    }
}

extension StartingLocationRequester: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                if self.coordinate == nil, !self.hasReceivedFix {
                    manager.requestLocation()
                }
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation])
    {
        guard let loc = locations.last else { return }
        let coord = loc.coordinate
        Task { @MainActor in
            self.hasReceivedFix = true
            self.coordinate = coord
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error)
    {
        // Silent — starting-location is best-effort. If the OS can't
        // supply a fix (airplane mode, denied post-auth, etc.) the
        // dashboard just falls back to `.automatic` framing.
    }
}
#endif

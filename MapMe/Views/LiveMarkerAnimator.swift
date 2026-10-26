#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import CoreLocation
import Combine
import CoreData

/// Drives smooth marker interpolation on Guardian Live-mode maps.
///
/// CloudKit push latency means new fixes arrive irregularly (~5-30 s
/// apart under normal load, sometimes much longer). Without
/// interpolation the map's live marker teleports from old fix to new,
/// which reads as janky compared to Find My / Uber / Life360 where
/// markers glide.
///
/// Behaviour: `moveTo(_:)` starts a ~0.8 s ease-out cubic tween from
/// the currently displayed coord to the new target. A 30 FPS `Timer`
/// updates `displayed` in place. Views observing `displayed` (via
/// `@ObservedObject`) re-render on each tick, and the `Annotation`
/// they draw re-anchors to the new coord — visually smooth.
///
/// Effectively a no-op when the new target is within ~1 metre of the
/// current position (the heartbeat writes produce these — no need
/// to burn 24 ticks tweening zero distance).
///
/// One instance per profile per Live map. Owned by `WorldMapView`'s
/// `@State` dict, so lifetime matches the view's lifetime.
final class LiveMarkerAnimator: ObservableObject {
    @Published private(set) var displayed: CLLocationCoordinate2D

    private var startCoord: CLLocationCoordinate2D
    private var targetCoord: CLLocationCoordinate2D
    private var startTime: Date?
    private var timer: Timer?

    private static let duration: TimeInterval = 0.8
    /// 15 FPS instead of 30 — cuts SwiftUI re-render pressure in
    /// half. With multiple moving profiles the 30 FPS rate was
    /// producing 60–240 whole-Map invalidations per second on
    /// Guardian iPhone and visibly slowing taps + boot. Motion
    /// still reads as smooth at 15 fps for this style of
    /// coordinate tween (subtle position drift, not a fast
    /// animation the eye tracks).
    private static let tickInterval: TimeInterval = 1.0 / 15.0
    /// Below this many degrees of change we don't tween — heartbeats
    /// write the same coord repeatedly and there's no visible motion
    /// to smooth over. ~1 metre at temperate latitudes.
    private static let epsilonDegrees: Double = 0.00001

    init(initial: CLLocationCoordinate2D) {
        self.displayed = initial
        self.startCoord = initial
        self.targetCoord = initial
    }

    deinit {
        timer?.invalidate()
    }

    /// Kicks a new tween toward `new`. Cancels any in-flight tween.
    /// If the new target is effectively the same as the current
    /// displayed coord, snaps without tweening.
    ///
    /// Idempotent: if we're already tweening toward this exact
    /// target, don't restart. Prevents thrashing when SwiftUI
    /// re-renders while a tween is in flight and hands us the
    /// same target repeatedly.
    func moveTo(_ new: CLLocationCoordinate2D) {
        // Already heading here — leave the tween running.
        if abs(new.latitude - targetCoord.latitude) < Self.epsilonDegrees
            && abs(new.longitude - targetCoord.longitude) < Self.epsilonDegrees
            && timer != nil {
            return
        }

        let dLat = abs(new.latitude - displayed.latitude)
        let dLon = abs(new.longitude - displayed.longitude)
        if dLat < Self.epsilonDegrees && dLon < Self.epsilonDegrees {
            // Effectively unchanged. Snap without spinning a timer.
            displayed = new
            targetCoord = new
            startCoord = new
            timer?.invalidate()
            timer = nil
            startTime = nil
            return
        }

        startCoord = displayed
        targetCoord = new
        startTime = Date()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval,
                                     repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let start = startTime else {
            timer?.invalidate()
            timer = nil
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let t = min(1.0, elapsed / Self.duration)
        // Ease-out cubic — starts fast, decelerates. Matches the
        // "arrived and settling" feel of a live vehicle marker
        // better than linear (which reads mechanical).
        let eased = 1 - pow(1 - t, 3)
        displayed = CLLocationCoordinate2D(
            latitude: startCoord.latitude + (targetCoord.latitude - startCoord.latitude) * eased,
            longitude: startCoord.longitude + (targetCoord.longitude - startCoord.longitude) * eased
        )
        if t >= 1.0 {
            timer?.invalidate()
            timer = nil
            startTime = nil
        }
    }
}

/// Owns per-profile `LiveMarkerAnimator` instances and re-publishes
/// their `displayed` changes upward so `WorldMapView` (which holds
/// this pool as a `@StateObject`) re-renders on each tween tick.
///
/// SwiftUI Map's `Annotation` doesn't accept an `ObservableObject`
/// binding for its `coordinate:` arg, so we need the parent view to
/// re-render whenever any animator ticks. Grouping the animators
/// under a single `ObservableObject` keeps the observation surface
/// tidy — one `@StateObject` in the view instead of N.
final class LiveMarkerAnimatorPool: ObservableObject {
    private var animators: [NSManagedObjectID: LiveMarkerAnimator] = [:]
    private var cancellables: [NSManagedObjectID: AnyCancellable] = [:]
    /// Last target handed to each animator, so a re-render that hands us
    /// an unchanged target doesn't queue a pointless `moveTo` hop.
    private var lastTargets: [NSManagedObjectID: CLLocationCoordinate2D] = [:]
    /// Set while an upward `objectWillChange` is already queued for this
    /// runloop turn. N animators ticking in the same turn used to send N
    /// separate publishes, each invalidating the whole `Map` — so the
    /// invalidation rate grew linearly with the number of devices on
    /// screen (and the work each invalidation triggered grew with it
    /// too, making the total cost quadratic). One publish per turn is
    /// all the view can act on anyway: it re-reads every animator's
    /// `displayed` when it re-renders.
    private var publishQueued = false

    /// Returns the currently-displayed (interpolated) coord for
    /// `profileID`, kicking a fresh tween to `target` if the target
    /// has changed. Idempotent when called with the same target.
    ///
    /// State mutations (moveTo, animator creation, upward
    /// objectWillChange) are deferred with `DispatchQueue.main.async`
    /// so they land AFTER SwiftUI's current view-update pass —
    /// otherwise the animator's `@Published displayed` mutating
    /// during render triggers "Publishing changes from within view
    /// updates is not allowed" warnings hundreds of times per
    /// second.
    func displayedCoord(for profileID: NSManagedObjectID,
                        target: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if let existing = animators[profileID] {
            // Only queue the tween kick when the target actually moved.
            // This is called once per profile on every render, and
            // renders are frequent (the tween itself causes them), so
            // the unconditional version queued a main-thread block per
            // profile per frame to tell each animator something it
            // already knew.
            if lastTargets[profileID].map({ !Self.isSame($0, target) }) ?? true {
                lastTargets[profileID] = target
                DispatchQueue.main.async {
                    existing.moveTo(target)
                }
            }
            return existing.displayed
        }
        // First render for this profile — set up the animator now
        // so the return value is stable, but defer the fan-out
        // wire-up (objectWillChange) so we don't republish during
        // this render pass.
        let created = LiveMarkerAnimator(initial: target)
        animators[profileID] = created
        lastTargets[profileID] = target
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cancellables[profileID] = created.objectWillChange.sink { [weak self] _ in
                self?.queuePublish()
            }
        }
        return created.displayed
    }

    /// Coalesces upward publishes to one per runloop turn, however many
    /// animators ticked in it.
    private func queuePublish() {
        guard !publishQueued else { return }
        publishQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishQueued = false
            self.objectWillChange.send()
        }
    }

    /// ~1 m at temperate latitudes — same epsilon the animator uses to
    /// decide a target is unchanged.
    private static func isSame(_ a: CLLocationCoordinate2D,
                               _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 0.00001
            && abs(a.longitude - b.longitude) < 0.00001
    }

    /// Drops any animators for profiles no longer in `activeIDs`.
    /// Called when the profile set changes so we don't leak timers
    /// for de-paired devices.
    func prune(to activeIDs: Set<NSManagedObjectID>) {
        for id in Array(animators.keys) where !activeIDs.contains(id) {
            animators.removeValue(forKey: id)
            cancellables.removeValue(forKey: id)
            lastTargets.removeValue(forKey: id)
        }
    }
}
#endif

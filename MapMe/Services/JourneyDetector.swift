#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import CoreLocation

/// A round-trip: the device left a stationary anchor, visited at least
/// one other place, and returned within `returnRadiusMeters` of the
/// anchor. Journeys are numbered 1..N within a calendar day and shown
/// on the day map as an inverted pin at the turnaround point (the
/// fix that was farthest from the anchor).
///
/// Distinct from `IdentifiedTrip` — a trip is a continuous fix span
/// separated from neighbours by a gap, while a journey aggregates one
/// or more trips into a "there and back" arc. A single drive across
/// town and home again is two trips but one journey.
struct Journey: Identifiable, Hashable {
    let id: String
    /// 1-based sequence within the calendar day this journey belongs to.
    let number: Int
    /// Where the loop began (and, within the return radius, ended).
    let start: CLLocationCoordinate2D
    /// The fix in the journey with the greatest distance from `start` —
    /// the "how far did they go" answer.
    let turnaround: CLLocationCoordinate2D
    let startDate: Date
    let endDate: Date

    static func == (lhs: Journey, rhs: Journey) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum JourneyDetector {
    /// A journey opens once the device has moved at least this far from
    /// its anchor. Below this the excursion is treated as GPS drift or
    /// yard-wandering, not a real departure. 200 m matches the snap-
    /// to-roads `minSnapTripMeters` gate for the same reason: shorter
    /// motion isn't meaningful map behavior.
    static let departThresholdMeters: CLLocationDistance = 200
    /// The device is considered "back" once it returns within this
    /// distance of the anchor. 100 m tolerates GPS wander at the door
    /// without waiting for a pinpoint match — a fix inside a house
    /// often reads 30-60 m off the recorded anchor even when the user
    /// is standing on the same rug.
    static let returnRadiusMeters: CLLocationDistance = 100

    /// Detects journeys from a chronologically-sorted fix stream.
    /// Grouped by calendar day so numbering resets at midnight local.
    ///
    /// The caller controls the calendar (mostly so tests don't depend
    /// on the process time zone); real callers pass `.current`.
    static func journeys(from fixes: [TimedFix],
                         calendar: Calendar = .current) -> [Journey]
    {
        guard !fixes.isEmpty else { return [] }

        // Group by day-start. `Dictionary(grouping:)` preserves order
        // within each bucket because Swift's dictionary preserves
        // insertion order per-key on the first insert, and the input
        // is already time-sorted.
        let byDay = Dictionary(grouping: fixes) { fix in
            calendar.startOfDay(for: fix.timestamp)
        }

        var results: [Journey] = []
        for day in byDay.keys.sorted() {
            guard let dayFixes = byDay[day], !dayFixes.isEmpty else { continue }
            results.append(contentsOf: detect(inDay: day, fixes: dayFixes))
        }
        return results
    }

    private static func detect(inDay day: Date,
                               fixes: [TimedFix]) -> [Journey]
    {
        var journeys: [Journey] = []
        var counter = 0

        var anchor = fixes[0]
        var maxDist: CLLocationDistance = 0
        var turnaround = fixes[0]
        var hasDeparted = false

        for i in 1..<fixes.count {
            let fix = fixes[i]
            let d = distance(fix, anchor)

            if d > maxDist {
                maxDist = d
                turnaround = fix
            }

            if !hasDeparted {
                if d > departThresholdMeters {
                    hasDeparted = true
                }
            } else if d < returnRadiusMeters {
                counter += 1
                journeys.append(Journey(
                    id: "j-\(Int(day.timeIntervalSince1970))-\(counter)",
                    number: counter,
                    start: anchor.coordinate,
                    turnaround: turnaround.coordinate,
                    startDate: anchor.timestamp,
                    endDate: fix.timestamp
                ))
                // Reset for the next potential journey. New anchor is
                // the return point — usually within a few metres of
                // the original anchor, but using the actual fix keeps
                // the next journey's departure math honest even if
                // "home" drifted slightly (or if the user set a new
                // dwell location a block away).
                anchor = fix
                maxDist = 0
                turnaround = fix
                hasDeparted = false
            }
        }
        return journeys
    }

    private static func distance(_ a: TimedFix,
                                 _ b: TimedFix) -> CLLocationDistance
    {
        let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return aLoc.distance(from: bLoc)
    }
}
#endif

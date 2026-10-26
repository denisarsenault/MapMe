import Foundation
import CoreData

/// What a `MinorProfile` actually represents. Existing profiles
/// created before this attribute existed default to `.person` (the
/// original meaning of the entity), so migrations don't need to
/// backfill any data — an unset `kindRaw` reads as `.person`.
///
/// `.pet` and `.device` share every downstream code path with
/// `.person` (records, map rendering, colors, deletion), differing
/// only in:
///
///   - Consent flow — pets/devices don't have a human to consent, so
///     `consentGrantedAt` is stamped at creation time and the "waiting
///     for consent" screen doesn't apply.
///   - Location source — records arrive via the
///     `LogTrackerLocationIntent` Shortcuts action (fed by a
///     third-party tracker's own app), not via `LocationService`
///     writing on this device.
///   - Icon overlay — the map marker gets a small paw / watch badge so
///     the Guardian can tell kinds apart at a glance.
enum TrackerKind: String, CaseIterable, Identifiable, Hashable {
    case person
    case pet
    case device

    var id: String { rawValue }

    var label: String {
        switch self {
        case .person: return "Person"
        case .pet:    return "Pet"
        case .device: return "Device"
        }
    }

    /// SF Symbol used as the small overlay badge on the profile's
    /// map marker AND as the picker row icon in the Add-tracker UI.
    var systemImage: String {
        switch self {
        case .person: return "person.crop.circle.fill"
        case .pet:    return "pawprint.circle.fill"
        case .device: return "applewatch"
        }
    }

    /// Whether this kind uses the paired-Minor consent flow. Only
    /// people can consent, so pets/devices bypass the
    /// `WaitingForConsentView` screen.
    var requiresConsent: Bool { self == .person }
}

extension MinorProfile {
    /// Typed accessor for the raw string attribute. Absent value maps
    /// to `.person` so profiles created before this attribute existed
    /// (or by older app versions) keep their original meaning.
    var kind: TrackerKind {
        get {
            guard let raw = kindRaw, let k = TrackerKind(rawValue: raw) else {
                return .person
            }
            return k
        }
        set { kindRaw = newValue.rawValue }
    }
}

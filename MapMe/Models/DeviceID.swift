import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(watchOS)
import WatchKit
#endif

/// Stable per-device identifier used to key the singleton `MinorProfile`
/// for *this* physical device.
///
/// **Why this exists.** With CloudKit sync, every device on the same iCloud
/// account sees every `MinorProfile` in its private DB. So the iPhone, the
/// Apple Watch, and any iPad all see the same set of profiles after sync.
/// If we look up "my profile" by "first row," the watch ends up writing its
/// `LocationRecord`s into the iPhone's profile and the Guardian sees a
/// single mixed feed instead of two separate devices. Filtering every fetch
/// by `deviceIdentifier == DeviceID.current` keeps each device on its own
/// profile, with its own `CKShare`.
enum DeviceID {
    /// Stable identifier for this physical device.
    /// - iOS / iPadOS / tvOS: `UIDevice.current.identifierForVendor`
    /// - watchOS: `WKInterfaceDevice.current().identifierForVendor`
    /// - macOS: hostname (best stable option without IOKit)
    static var current: String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown-ios"
        #elseif os(watchOS)
        return WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "unknown-watch"
        #elseif os(macOS)
        return Host.current().name ?? "unknown-mac"
        #else
        return "unknown"
        #endif
    }

    /// Human-readable label for the Guardian's family list.
    static var displayName: String {
        #if os(iOS) || os(tvOS)
        return UIDevice.current.name
        #elseif os(watchOS)
        return WKInterfaceDevice.current().name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Device"
        #endif
    }
}

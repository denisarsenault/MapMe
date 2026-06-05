import Foundation
import Combine

/// How this device participates in the family.
/// - `unset` = first launch, role chooser is shown
/// - `minor` = device that records and shares its location
/// - `guardian` = device that subscribes to one or more minors' shared zones
enum AppRole: String, CaseIterable, Codable {
    case unset, minor, guardian
}

@MainActor
final class AppRoleStore: ObservableObject {
    private static let key = "MapMe.role"

    @Published var role: AppRole {
        didSet { UserDefaults.standard.set(role.rawValue, forKey: Self.key) }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppRole.unset.rawValue
        self.role = AppRole(rawValue: raw) ?? .unset
    }

    func reset() { role = .unset }
}

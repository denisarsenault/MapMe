import Foundation
import Security
import CryptoKit
import Combine
#if !os(tvOS)
import LocalAuthentication
#endif

@MainActor
final class AuthService: ObservableObject {
    enum State: Equatable {
        case unconfigured
        case locked
        case unlocked
    }

    @Published private(set) var state: State
    @Published var biometricsEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricsEnabled, forKey: Self.kBiometricsEnabled) }
    }

    private static let kBiometricsEnabled = "MapMe.biometricsEnabled"
    private static let keychainAccount = "MapMe.passcode"
    private static let keychainService = "com.mapme.app.auth"

    init() {
        self.biometricsEnabled = UserDefaults.standard.bool(forKey: Self.kBiometricsEnabled)
        if Self.loadCredential() == nil {
            self.state = .unconfigured
        } else {
            self.state = .locked
        }
    }

    var isConfigured: Bool { state != .unconfigured }
    var isLocked: Bool { state == .locked }

    func setPasscode(_ passcode: String) throws {
        let salt = Self.randomBytes(count: 16)
        let hash = Self.derive(passcode: passcode, salt: salt)
        var data = Data()
        data.append(salt)
        data.append(hash)
        try Self.saveCredential(data)
        state = .unlocked
    }

    func unlock(with passcode: String) -> Bool {
        guard let blob = Self.loadCredential(), blob.count == 48 else { return false }
        let salt = blob.prefix(16)
        let stored = blob.suffix(32)
        let candidate = Self.derive(passcode: passcode, salt: Data(salt))
        let ok = constantTimeEquals(Data(stored), candidate)
        if ok { state = .unlocked }
        return ok
    }

    func lock() {
        if state == .unlocked { state = .locked }
    }

    /// Unlocks without checking the local passcode. Reserved for cases where
    /// authentication has already been delegated to a trusted peer — e.g.
    /// the watchOS app trusting a "phone is unlocked" reply over
    /// `WatchConnectivity`. Caller is responsible for verifying trust before
    /// calling this. Only available on watchOS to keep the API surface tight.
    #if os(watchOS)
    func unlockFromTrustedPeer() {
        guard isConfigured else { return }
        state = .unlocked
    }
    #endif

    func reset() {
        Self.deleteCredential()
        biometricsEnabled = false
        state = .unconfigured
    }

    /// On tvOS the LocalAuthentication framework is unavailable (no Face ID,
    /// Touch ID, or device passcode at the system level), so this method is
    /// always a no-op there. Callers can still invoke it freely.
    func tryBiometricUnlock() async -> Bool {
        #if os(tvOS)
        return false
        #else
        guard biometricsEnabled, isConfigured else { return false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock MapMe to view your location history."
            )
            if ok { state = .unlocked }
            return ok
        } catch {
            return false
        }
        #endif
    }

    /// True when biometrics can actually be offered to the user. tvOS lacks
    /// LocalAuthentication entirely, so the toggle and "Use Face ID" button
    /// should be hidden there.
    var biometricsAvailable: Bool {
        #if os(tvOS)
        return false
        #else
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        #endif
    }

    // MARK: - Crypto

    private static func derive(passcode: String, salt: Data) -> Data {
        let key = SymmetricKey(data: Data(passcode.utf8))
        var hasher = HMAC<SHA256>(key: key)
        hasher.update(data: salt)
        for _ in 0..<10_000 {
            hasher.update(data: salt)
        }
        return Data(hasher.finalize())
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: - Keychain

    private static func saveCredential(_ data: Data) throws {
        deleteCredential()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "MapMe.Auth", code: Int(status))
        }
    }

    private static func loadCredential() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    private static func deleteCredential() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

#if os(iOS)
import Foundation
import Combine
import WatchConnectivity

/// iPhone‑side `WCSession` delegate.
///
/// Two responsibilities:
/// - Reply to the paired Apple Watch when it asks whether the phone is
///   currently unlocked, so the watch can adopt that authentication for a
///   few minutes instead of asking for its own PIN.
/// - Receive a CKShare URL from the watch (`"presentShareURL"`) and
///   surface it via `@Published var pendingShareItem`. `MapMeApp` observes
///   this and presents a `UIActivityViewController` so the user can pick
///   Messages / AirDrop / Mail with the iPhone's full keyboard and
///   contact picker — a more reliable path than watchOS's `ShareLink`,
///   which often no-ops on iCloud share URLs.
@MainActor
final class PhoneConnectivityResponder: NSObject, ObservableObject {
    static let shared = PhoneConnectivityResponder()

    /// Set by the WC delegate when the watch asks the iPhone to present
    /// a share sheet for a CKShare URL. Cleared when the sheet dismisses.
    @Published var pendingShareItem: ShareItem?

    private weak var auth: AuthService?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Wire the live `AuthService` instance so we can answer reliably.
    func attach(auth: AuthService) {
        self.auth = auth
    }
}

extension PhoneConnectivityResponder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Per Apple guidance, reactivate after deactivation so a new device
        // pair can take over.
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // Use DispatchQueue.main.async (rather than Task @MainActor) so
        // Combine's @Published validator sees `Thread.isMainThread == true`
        // when we mutate `pendingShareItem`.
        DispatchQueue.main.async { [weak self] in
            guard let self else { replyHandler([:]); return }

            // Watch handing us a CKShare URL to present from the iPhone.
            if let action = message["action"] as? String,
               action == "presentShareURL",
               let urlString = message["url"] as? String,
               let url = URL(string: urlString) {
                self.pendingShareItem = ShareItem(url: url)
                replyHandler(["received": true])
                return
            }

            // Watch asking whether the phone is currently unlocked.
            if let request = message["request"] as? String, request == "unlocked" {
                replyHandler(["unlocked": self.auth?.state == .unlocked])
                return
            }

            replyHandler([:])
        }
    }
}
#endif

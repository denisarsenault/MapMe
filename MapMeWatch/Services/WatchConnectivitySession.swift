import Foundation
import Combine
import WatchConnectivity

/// Watch‑side WatchConnectivity wrapper. Used to ask the paired iPhone
/// whether it's currently unlocked, so the watch can skip its local PIN
/// when the user has just authenticated on the phone.
@MainActor
final class WatchConnectivitySession: NSObject, ObservableObject {
    static let shared = WatchConnectivitySession()

    @Published var isReachable: Bool = false
    @Published var isPaired: Bool = false

    private override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            // `isCompanionAppInstalled` and `isReachable` are only valid
            // after activation completes — reading them synchronously here
            // produces "WCSession has not been activated" warnings. The
            // values are populated in the activationDidComplete delegate.
        }
    }

    /// Hands a CKShare URL off to the paired iPhone so the iPhone can
    /// present a real `UIActivityViewController` (Messages, Mail, AirDrop).
    /// watchOS's `ShareLink` is unreliable with iCloud share URLs — this
    /// path uses the iPhone's full keyboard and contact list instead.
    /// Returns true if the phone replied "received".
    func sendShareURL(_ url: URL, timeout: TimeInterval = 4) async -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.isReachable else { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let resume: @Sendable (Bool) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            session.sendMessage(
                ["action": "presentShareURL", "url": url.absoluteString],
                replyHandler: { reply in
                    resume((reply["received"] as? Bool) ?? false)
                },
                errorHandler: { _ in resume(false) }
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                resume(false)
            }
        }
    }

    /// Asks the paired iPhone whether it's currently unlocked. Returns false
    /// if the phone is unreachable, the request times out, or the phone
    /// reports locked.
    func requestPhoneUnlockState(timeout: TimeInterval = 4) async -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.isReachable else { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let resume: @Sendable (Bool) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            session.sendMessage(
                ["request": "unlocked"],
                replyHandler: { reply in
                    resume((reply["unlocked"] as? Bool) ?? false)
                },
                errorHandler: { _ in resume(false) }
            )
            // Hard timeout in case the phone is slow.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                resume(false)
            }
        }
    }
}

extension WatchConnectivitySession: WCSessionDelegate {
    // Same Combine consideration as WatchLocationService: WCSession invokes
    // these on a background queue, so we must hop to main before touching
    // any @Published. Using `DispatchQueue.main.async` (rather than
    // `Task { @MainActor in … }`) to avoid the rare window where Combine's
    // `Thread.isMainThread` check fires "Publishing changes from background
    // threads" warnings under minimal strict-concurrency.
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reach = session.isReachable
        let paired = session.isCompanionAppInstalled
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = reach
            self?.isPaired = paired
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reach = session.isReachable
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = reach
        }
    }
}

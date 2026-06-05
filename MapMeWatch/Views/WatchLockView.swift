        import SwiftUI

struct WatchLockView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var connectivity: WatchConnectivitySession
    @State private var digits: [Int] = Array(repeating: 0, count: 4)
    @State private var error: String?
    @State private var isCheckingPhone = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("MapMe locked").font(.headline)

                if isCheckingPhone {
                    ProgressView("Asking iPhone…")
                        .font(.caption2)
                }

                WatchPINEntry(digits: $digits)

                Button("Unlock", action: submit)
                    .buttonStyle(.borderedProminent)

                if connectivity.isReachable {
                    Button {
                        Task { await tryPhoneUnlock() }
                    } label: {
                        Label("Use iPhone", systemImage: "iphone")
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                }

                if let error {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func submit() {
        let pin = WatchPINEntry.string(from: digits)
        if auth.unlock(with: pin) {
            error = nil
            digits = Array(repeating: 0, count: 4)
        } else {
            error = "Wrong PIN"
            digits = Array(repeating: 0, count: 4)
        }
    }

    private func tryPhoneUnlock() async {
        isCheckingPhone = true
        defer { isCheckingPhone = false }
        let phoneUnlocked = await connectivity.requestPhoneUnlockState()
        if phoneUnlocked {
            auth.unlockFromTrustedPeer()
            error = nil
        } else {
            error = "iPhone is locked"
        }
    }
}

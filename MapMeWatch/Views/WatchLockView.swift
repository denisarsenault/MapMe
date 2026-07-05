        import SwiftUI

struct WatchLockView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var connectivity: WatchConnectivitySession
    @State private var digits: [Int] = Array(repeating: 0, count: 4)
    @State private var error: String?
    @State private var isCheckingPhone = false

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                // Brand wordmark at the top. Sized small enough that a
                // 38/40/41 mm watch face still fits the lock icon,
                // headline, PIN entry, and Unlock button in one visual
                // unit without the user having to scroll to find the
                // PIN. 88 pt is the empirical "still legible at 1 ft
                // viewing distance, doesn't dominate" floor on a 38 mm
                // Series 3 face.
                Image("MMLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88)
                    .accessibilityLabel("MapMe")
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text("MapMe locked")
                    .font(.subheadline.weight(.semibold))

                if isCheckingPhone {
                    ProgressView("Asking iPhone…")
                        .font(.caption2)
                }

                WatchPINEntry(digits: $digits)

                Button("Unlock", action: submit)
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                    .controlSize(.small)

                if connectivity.isReachable {
                    Button {
                        Task { await tryPhoneUnlock() }
                    } label: {
                        Label("Use iPhone", systemImage: "iphone")
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let error {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.vertical, 2)
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

import SwiftUI
import WatchKit

struct WatchLockView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var connectivity: WatchConnectivitySession
    @State private var digits: [Int] = Array(repeating: 0, count: 4)
    @State private var error: String?
    @State private var isCheckingPhone = false

    var body: some View {
        // Fixed-layout top (no ScrollView above the pickers) so
        // WatchPINEntry's 4 wheel Pickers don't read a parent
        // ScrollView's contentOffset — that's what caused four
        // "contentOffset binding has been read — grossly inefficient"
        // warnings per launch. The pickers use the Digital Crown to
        // spin, and Apple's Picker implementation arbitrates against
        // any enclosing scroll view by watching its offset, which
        // fires the warning on every layout pass.
        //
        // Overflow content (secondary button, error, copyright) still
        // needs to scroll on 38 mm faces where it clips, so THAT half
        // is wrapped in its own ScrollView below the pickers. Pickers
        // are outside that ScrollView so no crown-arbitration conflict.
        VStack(spacing: 3) {
            // Compact brand mark. 56 pt is the empirical "readable
            // on a 41 mm Series 8 face without pushing the keypad
            // below the fold" size.
            Image("MMLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 56)
                .accessibilityLabel("MapMe")

            // Unlock button placed ABOVE the PIN entry so it's
            // always in the top half of the screen, unaffected
            // by how far the picker wheels push the layout down.
            Button("Unlock", action: submit)
                .buttonStyle(.borderedProminent)
                .font(.caption)
                .controlSize(.small)

            if isCheckingPhone {
                ProgressView("Asking iPhone…")
                    .font(.caption2)
            }

            WatchPINEntry(digits: $digits)

            ScrollView {
                VStack(spacing: 3) {
                    if connectivity.isReachable {
                        Button {
                            WKInterfaceDevice.current().play(.click)
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

                    // Copyright — inlined here (not shared with iOS'
                    // CopyrightFooter) because the watch target doesn't
                    // pull in `MapMe/Views/ViewModifiers.swift` (that
                    // file references iOS-only toolbar APIs).
                    let year = Calendar.current.component(.year, from: Date())
                    Text("© \(String(year)) Hawksnest Software LLC")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.top, 0)
        .padding(.bottom, 2)
    }

    private func submit() {
        // Tap acknowledgement — `.click` is the tactile "you pressed
        // something" haptic. Without it the borderedProminent button
        // gives no confirmation on watchOS beyond the very brief
        // press-in animation, which many users on 38/40 mm faces
        // reported feeling like the button didn't register.
        WKInterfaceDevice.current().play(.click)

        let pin = WatchPINEntry.string(from: digits)
        if auth.unlock(with: pin) {
            // `.success` is a distinct up-and-away buzz — separates
            // "PIN accepted" from the plain tap haptic above.
            WKInterfaceDevice.current().play(.success)
            error = nil
            digits = Array(repeating: 0, count: 4)
        } else {
            // `.failure` is a double-buzz that reads as "no" without
            // needing to look at the screen.
            WKInterfaceDevice.current().play(.failure)
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

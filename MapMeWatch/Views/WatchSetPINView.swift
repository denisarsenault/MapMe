import SwiftUI

struct WatchSetPINView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var step: Step = .first
    @State private var digits: [Int] = Array(repeating: 0, count: 4)
    @State private var firstPIN: String = ""
    @State private var error: String?

    enum Step { case first, confirm }

    var body: some View {
        // Pickers outside the outer ScrollView — see WatchLockView
        // for the "contentOffset binding has been read" rationale.
        VStack(spacing: 8) {
            // MMLogo instead of a generic lock SF Symbol — anchors
            // this screen to MapMe at a glance so the wearer knows
            // which app is asking for a PIN. Small (24 pt) so the
            // picker row still fits above the fold on 38 mm faces.
            Image("MMLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 24)
                .accessibilityLabel("MapMe")
            Text(step == .first ? "Set 4‑digit PIN" : "Confirm PIN")
                .font(.headline)
                .multilineTextAlignment(.center)

            WatchPINEntry(digits: $digits)

            Button(step == .first ? "Next" : "Save", action: advance)
                .buttonStyle(.borderedProminent)

            ScrollView {
                if let error {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func advance() {
        let pin = WatchPINEntry.string(from: digits)
        switch step {
        case .first:
            firstPIN = pin
            digits = Array(repeating: 0, count: 4)
            step = .confirm
            error = nil
        case .confirm:
            guard pin == firstPIN else {
                error = "PINs don't match"
                digits = Array(repeating: 0, count: 4)
                step = .first
                return
            }
            do {
                try auth.setPasscode(pin)
            } catch {
                self.error = "Save failed"
            }
        }
    }
}

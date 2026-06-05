import SwiftUI

struct WatchSetPINView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var step: Step = .first
    @State private var digits: [Int] = Array(repeating: 0, count: 4)
    @State private var firstPIN: String = ""
    @State private var error: String?

    enum Step { case first, confirm }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "lock.rectangle.stack")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(step == .first ? "Set 4‑digit PIN" : "Confirm PIN")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                WatchPINEntry(digits: $digits)

                Button(step == .first ? "Next" : "Save", action: advance)
                    .buttonStyle(.borderedProminent)

                if let error {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        }
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

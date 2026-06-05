import SwiftUI

/// Four 0–9 wheel pickers, each driven by Digital Crown rotation. Used on
/// watchOS where a real keyboard isn't viable and the kid needs to enter a
/// 4‑digit PIN.
struct WatchPINEntry: View {
    @Binding var digits: [Int]

    init(digits: Binding<[Int]>) {
        self._digits = digits
        // Defensive: make sure binding is exactly 4 long.
        if digits.wrappedValue.count != 4 {
            digits.wrappedValue = Array(repeating: 0, count: 4)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { i in
                Picker("", selection: Binding(
                    get: { digits[i] },
                    set: { digits[i] = $0 }
                )) {
                    ForEach(0..<10, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 90)
    }

    /// Returns the current PIN as a String (e.g. "0492").
    static func string(from digits: [Int]) -> String {
        digits.map { String($0) }.joined()
    }
}

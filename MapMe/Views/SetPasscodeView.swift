import SwiftUI

struct SetPasscodeView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var first: String = ""
    @State private var second: String = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: Self.vStackSpacing) {
            // Brand mark at top centre, same pattern as `LockView`.
            // tvOS gets the pin-only `MMBrandMark` at TV-readable size;
            // other platforms get the wordmark `MMLogo` at a phone /
            // window-friendly size.
            // Same per-platform brand mark choice as `LockView`:
            // pin-only (MMBrandMark) on tvOS + macOS where windows are
            // large; wordmark (MMLogo) on iOS where the column is
            // phone-sized.
            #if os(tvOS)
            Image("MMBrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 130, height: 130)
            #elseif os(macOS)
            Image("MMBrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
            #else
            Image("MMLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.15), radius: 6, y: 3)
            #endif

            Image(systemName: "lock.rectangle.stack")
                .font(.system(size: Self.lockBadgeSize))
                .foregroundStyle(.tint)
            Text("Set your security code")
                .font(Self.headlineFont)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("This code unlocks MapMe on this device. Use 6 or more characters.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // `.oneTimeCode` keeps iOS/macOS from offering Keychain
            // AutoFill for what is actually a local-only passcode hash.
            SecureField("New code", text: $first)
                .textContentType(.oneTimeCode)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 32)
            SecureField("Confirm code", text: $second)
                .textContentType(.oneTimeCode)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 32)

            if let error { Text(error).font(.footnote).foregroundStyle(.red) }

            Button("Save") {
                guard first.count >= 6 else { error = "Use at least 6 characters."; return }
                guard first == second else { error = "Codes do not match."; return }
                do {
                    try auth.setPasscode(first)
                } catch {
                    self.error = "Could not save: \(error.localizedDescription)"
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(first.isEmpty || second.isEmpty)
        }
        .padding()
        // tvOS top inset, same pattern as `LockView` — keeps the brand
        // mark clear of the top system chrome.
        #if os(tvOS)
        .padding(.top, 120)
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #else
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        #endif
    }

    // MARK: - Platform sizing
    //
    // Same rationale as `LockView` — phone-sized defaults look like
    // crumbs on a TV. Kept the constants local to each view rather
    // than shared in a helper so each screen can tune its own values
    // (e.g. SetPasscode has two SecureFields, so the column width
    // could differ from LockView in the future without coupling).

    private static let maxContentWidth: CGFloat = {
        #if os(tvOS)
        return 760
        #elseif os(macOS)
        return 560
        #else
        return 420
        #endif
    }()

    private static let vStackSpacing: CGFloat = {
        #if os(tvOS)
        return 24
        #elseif os(macOS)
        return 20
        #else
        return 14
        #endif
    }()

    private static let lockBadgeSize: CGFloat = {
        #if os(tvOS)
        return 52
        #elseif os(macOS)
        return 48
        #else
        return 44
        #endif
    }()

    private static var headlineFont: Font {
        #if os(tvOS)
        return .title.weight(.semibold)
        #elseif os(macOS)
        return .title.weight(.semibold)
        #else
        return .title2.weight(.semibold)
        #endif
    }
}

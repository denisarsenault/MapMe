import SwiftUI

struct LockView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var entry: String = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Self.vStackSpacing) {
            // Brand mark at top centre. On iOS/macOS this is the wordmark
            // `MMLogo`; on tvOS we use `MMBrandMark` (the pin-only square)
            // to match the dashboard's branding. Sized large enough to be
            // legible at the platform's typical viewing distance — 64 pt
            // works for a phone in hand, but on a TV across the room it
            // reads as a tiny crumb. Bumped to 180 pt + 56 pt SF Symbol on
            // tvOS so the screen looks deliberate.
            // Brand mark choice per platform:
            //   - tvOS:  MMBrandMark (pin only) at 130 pt
            //   - macOS: MMBrandMark (pin only) at 120 pt — windows have
            //            lots of room and the wordmark would duplicate
            //            "MapMe" against the headline below
            //   - iOS:   MMLogo (wordmark) at 64 pt — phone-sized
            //            window, the wordmark reads as a compact brand
            //            badge above the lock state
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

            Image(systemName: "lock.shield")
                .font(.system(size: Self.lockBadgeSize))
                .foregroundStyle(.tint)
            Text("MapMe is locked")
                .font(Self.headlineFont)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("Enter your security code to view your location history.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            SecureField("Security code", text: $entry)
                // `.oneTimeCode` rather than `.password` so iOS / macOS
                // don't try to AutoFill from iCloud Keychain — our passcode
                // is a local hash, not a Keychain credential. On macOS this
                // also stops the system Passwords launcher button from
                // floating over the window.
                .textContentType(.oneTimeCode)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focused)
                .onSubmit(submit)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 32)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Button("Unlock", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(entry.isEmpty)

            if auth.biometricsEnabled {
                Button {
                    Task { _ = await auth.tryBiometricUnlock() }
                } label: {
                    Label("Use Face ID / Touch ID", systemImage: "faceid")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        // tvOS-only top inset. The default centred alignment puts the
        // 130 pt brand mark close to the top edge of the safe area,
        // which on a TV reads as "tucked under the system chrome".
        // Push the whole column down a fixed amount and top-align it
        // instead. iOS / macOS keep the centred layout — the column
        // there fits a phone / window comfortably without an inset.
        #if os(tvOS)
        .padding(.top, 120)
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #else
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        #endif
        .onAppear { focused = true }
    }

    // MARK: - Platform sizing

    /// Width of the centred sign-in column. 420 pt is right for a
    /// phone-in-hand view but cramps both the headline and the brand
    /// mark on a TV; the tvOS value gives the title room to render
    /// "MapMe is locked" on one line at the larger TV font sizes
    /// without hitting `minimumScaleFactor`.
    private static let maxContentWidth: CGFloat = {
        #if os(tvOS)
        return 760
        #elseif os(macOS)
        // macOS windows are way wider than a phone, so the 420 pt
        // iPhone column made the brand mark + text look stranded in
        // the middle. 560 pt gives the column visual presence without
        // stretching across an entire desktop window.
        return 560
        #else
        return 420
        #endif
    }()

    /// Vertical spacing between the brand mark, lock badge, title,
    /// subtitle, code field, etc. tvOS gets a bit more so the larger
    /// elements have breathing room.
    private static let vStackSpacing: CGFloat = {
        #if os(tvOS)
        return 28
        #elseif os(macOS)
        return 24
        #else
        return 20
        #endif
    }()

    private static let lockBadgeSize: CGFloat = {
        #if os(tvOS)
        return 56
        #elseif os(macOS)
        return 52
        #else
        return 48
        #endif
    }()

    /// `.title2` is fine on iOS/macOS but tvOS resolves it noticeably
    /// larger; combined with the 420 pt max width that's where the
    /// "MapMe is locked" text was getting cut off mid-word. Use
    /// `.title` on tvOS so the headline visually anchors the screen
    /// while still fitting the wider column.
    private static var headlineFont: Font {
        #if os(tvOS)
        return .title.weight(.semibold)
        #elseif os(macOS)
        return .title.weight(.semibold)
        #else
        return .title2.weight(.semibold)
        #endif
    }

    private func submit() {
        if auth.unlock(with: entry) {
            entry = ""
            error = nil
        } else {
            error = "Incorrect code."
            entry = ""
        }
    }
}

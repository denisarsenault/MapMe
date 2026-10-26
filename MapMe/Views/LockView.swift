import SwiftUI
#if os(macOS)
import AppKit
#endif

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
            // Full wordmark on tvOS so "MapMe" reads clearly across
            // the room — the pin-only MMBrandMark used to leave the
            // brand name off the TV entirely. Forced dark variant
            // (white text) because the tvOS lock background is
            // always dark regardless of the user's system theme.
            MapMeBrandImage(forced: .dark)
                .frame(width: 480)
            #elseif os(macOS)
            // macOS: full wordmark, adaptive light/dark.
            MapMeBrandImage()
                .frame(width: 280)
            #else
            // iOS: full wordmark, adaptive light/dark. Width-only
            // frame keeps the natural 10:3 aspect — never width +
            // height, which would squash it.
            MapMeBrandImage()
                .frame(width: 240)
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
        // Top-aligned across every non-watch platform. Centred
        // alignment used to leave the logo + headline hovering in
        // dead space and the PIN field roughly at thumb-rest on a
        // phone, but on landing the user is looking at the TOP of
        // the screen — that's where the brand and the PIN entry
        // should be. tvOS keeps a fixed inset so the column clears
        // the system chrome; iOS / macOS use safe-area padding
        // alone since their chrome is much thinner.
        #if os(tvOS)
        .padding(.top, 120)
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #else
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
        .onAppear { focused = true }
        // Copyright pinned to the bottom of the screen via a wrapping
        // ZStack. `forceLight` on tvOS because the lock background is
        // deliberately dark there; adaptive on iOS/macOS.
        .overlay(alignment: .bottom) {
            #if os(tvOS)
            CopyrightFooter(style: .forceLight)
            #else
            CopyrightFooter()
            #endif
        }
        #if os(macOS)
        // The 900 × 720 main-app window is way too much real estate
        // for a sign-in column. Resize the host NSWindow down to a
        // compact sheet-style size while LockView is on screen, then
        // expand back to the main-app default once the user unlocks.
        .onAppear { Self.resizeWindow(to: Self.macLockSize) }
        .onDisappear { Self.resizeWindow(to: Self.macMainSize) }
        #endif
    }

    #if os(macOS)
    private static let macLockSize  = NSSize(width: 460, height: 560)
    private static let macMainSize  = NSSize(width: 900, height: 720)

    /// Resizes the key window in place, anchoring its top-left so the
    /// resize doesn't visually slide the window across the screen.
    private static func resizeWindow(to target: NSSize) {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.styleMask.contains(.titled)
        }) else { return }
        var frame = window.frame
        let topY = frame.maxY
        frame.size = target
        frame.origin.y = topY - target.height
        window.setFrame(frame, display: true, animate: true)
    }
    #endif

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

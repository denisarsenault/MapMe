#if os(iOS) || os(macOS) || os(tvOS)
import SwiftUI
import AppIntents

/// Shared wrapper around `SiriTipView` so every main screen shows
/// the tip with the same visual weight and the same persistence
/// behaviour. Each surface passes a unique `storageKey` (via
/// `@AppStorage`) so a dismiss on one screen doesn't hide the tip
/// on a different one, and a dismissal sticks across app launches.
///
/// The tip auto-hides once the user has invoked the intent through
/// Siri or Shortcuts (that's `SiriTipView`'s built-in behaviour via
/// the AppIntents runtime); the explicit dismiss button covers
/// "please stop showing me hints" without waiting for a first
/// successful invocation.
///
/// tvOS note: `SiriTipView` on tvOS renders but its dismiss button
/// grabs focus and pulls the user off the map/card row that owns
/// the screen. We suppress the dismiss button there and let the tip
/// linger — the wearer isn't going to dismiss a tip on a TV they
/// aren't holding.
struct MapMeSiriTip<I: AppIntent>: View {
    let intent: I
    /// Unique per screen so dismissals don't leak across surfaces.
    /// Prefix all keys with "MapMe.siriTip." so grepping shows the
    /// full set.
    let storageKey: String

    @AppStorage private var dismissed: Bool

    init(intent: I, storageKey: String) {
        self.intent = intent
        self.storageKey = storageKey
        self._dismissed = AppStorage(wrappedValue: false, storageKey)
    }

    var body: some View {
        if !dismissed {
            #if os(macOS)
            // `SiriTipView` isn't available on native macOS (only
            // iOS/iPadOS/tvOS/watchOS + Mac Catalyst). Render a
            // hand-rolled chip with the same content — the intent
            // title becomes the label, and clicking the X persists
            // the dismissal identically to the SiriTipView path.
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.tint)
                Text("Try: \"Hey Siri, \(String(localized: I.title))\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            #else
            SiriTipView(
                intent: intent,
                isVisible: Binding(
                    get: { !dismissed },
                    set: { newValue in
                        // SiriTipView flips `isVisible` to false when
                        // the user taps its X button. Persist that so
                        // the tip stays dismissed across relaunches.
                        if !newValue { dismissed = true }
                    }
                )
            )
            #if os(tvOS)
            // Focus-engine friendly: keep the tip on screen but
            // don't let its dismiss button steal focus from the
            // dashboard's cards / map. The tip still educates
            // (Siri Remote users can invoke the phrase anyway).
            .focusable(false)
            #endif
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            #endif
        }
    }
}
#endif

#if os(watchOS)
import SwiftUI
import AppIntents

/// watchOS twin of `MapMeSiriTip`. `SiriTipView` is available on
/// watchOS 9+ and renders as a compact chip suitable for the
/// small watch face. Dismissal is persisted per `storageKey` in
/// `UserDefaults` so once the wearer taps X the tip stays hidden
/// across launches.
struct WatchSiriTip<I: AppIntent>: View {
    let intent: I
    let storageKey: String

    @AppStorage private var dismissed: Bool

    init(intent: I, storageKey: String) {
        self.intent = intent
        self.storageKey = storageKey
        self._dismissed = AppStorage(wrappedValue: false, storageKey)
    }

    var body: some View {
        if !dismissed {
            SiriTipView(
                intent: intent,
                isVisible: Binding(
                    get: { !dismissed },
                    set: { newValue in
                        if !newValue { dismissed = true }
                    }
                )
            )
            .padding(.vertical, 2)
        }
    }
}
#endif

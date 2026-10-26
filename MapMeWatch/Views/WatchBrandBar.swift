#if os(watchOS)
import SwiftUI

/// Stamps a small MMLogo header at the top of a watch screen's
/// content so every main screen reads as "MapMe" at a glance.
///
/// Why not use `ToolbarItem(placement: .principal)` the way iOS/mac
/// does. That placement is unavailable on watchOS, and the
/// `.topBarLeading` / `.topBarTrailing` slots that *are* available
/// clip badly on 38-41 mm faces where the status row already eats
/// half the top chrome. Inlining the logo as the first row of
/// scrollable content keeps it visible on every face size without
/// fighting the system title.
///
/// We also drop the system nav title (via `.toolbar(.hidden, …)`)
/// so the brand mark isn't stacked under a redundant "Live" /
/// "Settings" string — the inline label we draw ourselves below
/// the logo is the user-visible title.
///
/// Keep `.navigationTitle(...)` on the screen BEFORE calling this
/// modifier anyway — it's still read by VoiceOver and used by
/// watchOS's internal screen hierarchy for Handoff / Siri intents.
/// The visible toolbar override only hides it from the screen
/// chrome.
struct WatchBrandBar: ViewModifier {
    /// Optional small label drawn next to the pin. Pass nil to
    /// show just the mark; pass a short string ("Live", "Settings")
    /// to replace the system nav title in a tighter inline form.
    let label: String?

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image("MMLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 14)
                    .accessibilityLabel("MapMe")
                if let label {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 2)
            content
        }
        // Hide the system nav title bar so we don't stack the brand
        // mark under a redundant default title.
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension View {
    /// Replaces the default navigation title with an inline MMLogo
    /// header. Pass a short `label` to also show the screen name
    /// next to the mark (e.g. `.mapMeWatchBrand("Live")`); omit
    /// for just the brand mark.
    func mapMeWatchBrand(_ label: String? = nil) -> some View {
        modifier(WatchBrandBar(label: label))
    }
}
#endif

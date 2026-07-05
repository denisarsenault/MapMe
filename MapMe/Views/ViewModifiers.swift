import SwiftUI

extension View {
    /// Caps a Form/List/text view so it doesn't stretch absurdly wide on
    /// macOS and iPad landscape, and centers it in the parent. On compact
    /// iPhone widths the cap has no effect because the screen is narrower
    /// than the cap.
    func centeredContent(maxWidth: CGFloat = 640) -> some View {
        self
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Wraps a Form so it gets the grouped style on every platform and a
    /// centered, capped width on Mac/iPad. Apply at the top of a view's
    /// `body` instead of writing the form modifier ladder by hand.
    func centeredForm(maxWidth: CGFloat = 640) -> some View {
        self
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .centeredContent(maxWidth: maxWidth)
    }

    /// Drops the full MapMe wordmark into the centred slot of the
    /// navigation bar so every top-level screen leads with the brand.
    /// `.principal` placement REPLACES the screen's own
    /// `.navigationTitle`; that's a deliberate tradeoff — on iOS the
    /// tab bar's label already tells the user which screen they're on
    /// (Live / History / Guardian / Settings), so the title slot is
    /// redundant and is a better home for the brand mark.
    ///
    /// No-op on tvOS (custom top chrome) and watchOS (doesn't share
    /// these screens).
    func mapMeBrandToolbar() -> some View {
        #if os(tvOS) || os(watchOS)
        return self
        #else
        return self.toolbar {
            ToolbarItem(placement: .principal) {
                // 132 × ~40 reads clearly on a 390 pt-wide iPhone nav
                // bar without crowding the back chevron or trailing
                // toolbar items.
                MapMeBrandImage()
                    .frame(width: 132, height: 40)
            }
        }
        #endif
    }
}

/// MapMe wordmark that switches between the white-text variant
/// (`MMLogo` — for splash, dark mode nav bars, dark material
/// overlays) and the black-text variant (`MMLogoLight` — for
/// light-mode nav bars, white forms, light material) based on the
/// current `colorScheme`.
///
/// Both assets render at 10:3 aspect; apply a `.frame(width:)` or
/// `.frame(height:)` at the call site to size — never both axes,
/// since that would squash the wordmark.
struct MapMeBrandImage: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Set to `.dark` or `.light` to force one variant regardless of
    /// the surrounding colour scheme. Useful for overlays whose
    /// background is fixed (e.g. the dark navy splash, or a light
    /// thinMaterial pill on top of a dark map). Default `nil`
    /// follows the environment.
    var forced: ColorScheme?

    var body: some View {
        let scheme = forced ?? colorScheme
        Image(scheme == .dark ? "MMLogo" : "MMLogoLight")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("MapMe")
    }
}

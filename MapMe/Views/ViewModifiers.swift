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
}

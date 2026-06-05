#if os(iOS)
import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIActivityViewController` so the iPhone can
/// present a regular share sheet on demand. Used by `MapMeApp` when the
/// paired Apple Watch hands a CKShare URL over via `WatchConnectivity`,
/// since watchOS's `ShareLink` is unreliable with iCloud share URLs.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so `.sheet(item:)` can present `ShareSheet`.
struct ShareItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}
#endif

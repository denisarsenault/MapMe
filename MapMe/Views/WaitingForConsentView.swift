import SwiftUI
import CoreData

struct WaitingForConsentView: View {
    let profile: MinorProfile

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.clock")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Waiting for Guardian approval")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Tracking is paused until your Guardian grants consent for this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Display name", value: profile.displayName ?? "—")
                LabeledContent("Created", value: profile.createdAt.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? "—")
            }
            .padding()
            .frame(maxWidth: 360)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            ProgressView().controlSize(.regular)
        }
        .padding()
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

import SwiftUI

struct RoleChooserView: View {
    @EnvironmentObject private var roleStore: AppRoleStore

    var body: some View {
        VStack(spacing: 24) {
            // Brand mark. Replaces the generic SF Symbol placeholder
            // we shipped during early prototyping — first-run feels
            // properly branded and reinforces the app identity before
            // the user has even chosen Guardian vs tracked-device.
            Image("MMLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.black.opacity(0.15), radius: 8, y: 4)
            Text("Set up MapMe")
                .font(.title2.weight(.semibold))
            Text("Pick how this device will be used.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button {
                    roleStore.role = .minor
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("This device will be tracked").font(.headline)
                            Text("Records and shares its location with a Guardian.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "location")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    roleStore.role = .guardian
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("This is a Guardian device").font(.headline)
                            Text("Receives location data from minors who have invited you.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "shield")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
        }
        .padding()
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

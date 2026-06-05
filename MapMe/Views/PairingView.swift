import SwiftUI
import CloudKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct PairingView: View {
    @StateObject private var sharing = SharingService()
    @State private var pendingShare: ShareWrapper?
    @State private var inviteURL: URL?
    @State private var error: String?
    @State private var profileName: String = ""
    @State private var isGenerating = false

    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $profileName)
                    .textContentType(.nickname)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            } header: {
                Text("Your name on the Guardian device")
            } footer: {
                Text("This is the label your Guardian will see for this device.")
            }

            Section {
                Button {
                    Task { await generateInvite() }
                } label: {
                    if isGenerating {
                        ProgressView()
                    } else {
                        Label("Generate invite", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)

                #if os(macOS)
                if let url = inviteURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send this link to your Guardian:")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(url.absoluteString)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        HStack {
                            ShareLink(item: url) {
                                Label("Share invite…", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                copyToClipboard(url.absoluteString)
                            } label: {
                                Label("Copy link", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                #endif

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Invite a Guardian")
            } footer: {
                Text("Send the link via Messages, Mail, or AirDrop. The Guardian taps the link in MapMe on their device to accept.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .navigationTitle("Guardian")
        .onAppear {
            if profileName.isEmpty {
                #if os(iOS) || os(tvOS)
                profileName = UIDevice.current.name
                #elseif os(macOS)
                profileName = Host.current().localizedName ?? ""
                #endif
            }
        }
        #if os(iOS)
        .sheet(item: $pendingShare) { wrapper in
            CloudShareSheet(share: wrapper.share, container: wrapper.container, title: wrapper.title)
        }
        #endif
    }

    @MainActor
    private func generateInvite() async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let trimmed = profileName.trimmingCharacters(in: .whitespaces)
            let profile = sharing.ensureMinorProfile(displayName: trimmed)
            if profile.displayName != trimmed {
                profile.displayName = trimmed
                try? profile.managedObjectContext?.save()
            }
            let (share, container) = try await sharing.makeShare(for: profile)
            #if os(iOS)
            pendingShare = ShareWrapper(share: share, container: container, title: trimmed)
            #elseif os(macOS)
            // The share's `url` is populated after CloudKit saves the share.
            // NSPersistentCloudKitContainer.share(_:to:) saves it for us.
            inviteURL = share.url
            if share.url == nil {
                self.error = "Share was created but iCloud has not yet returned a URL. Try again in a moment."
            }
            #endif
        } catch {
            self.error = error.localizedDescription
        }
    }

    #if os(macOS)
    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    #endif
}

private struct ShareWrapper: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
    let title: String
}

#if os(iOS)
private struct CloudShareSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let title: String

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let vc = UICloudSharingController(share: share, container: container)
        // Read-write so the Guardian can write `consentGrantedAt` back into
        // the share. Private so only invited participants can join.
        vc.availablePermissions = [.allowReadWrite, .allowPrivate]
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(title: title) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let title: String
        init(title: String) { self.title = title }

        func itemTitle(for csc: UICloudSharingController) -> String? { title }

        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            #if DEBUG
            print("CKShare save failed: \(error)")
            #endif
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {}
    }
}
#endif

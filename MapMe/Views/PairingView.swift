import SwiftUI
import CloudKit
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Filter Console.app to subsystem `com.mybrightzone.app` + category
/// `pairing` to see just this flow. Used to diagnose the "tap
/// Generate invite → nothing happens" case (usually a hung CloudKit
/// share call or a silent error swallowed by the previous inline
/// Text display).
private let pairingLog = Logger(subsystem: "com.mybrightzone.app", category: "pairing")

struct PairingView: View {
    @StateObject private var sharing = SharingService()
    @State private var pendingShare: ShareWrapper?
    @State private var inviteURL: URL?
    @State private var error: String?
    @State private var profileName: String = ""
    @State private var isGenerating = false
    /// Sub-status shown next to the spinner while a share is being
    /// created. Gives the user something to read instead of a bare
    /// spinner during the sometimes-long `CKShare` create wait.
    @State private var generationStatus: String = ""
    /// Handle for the active generation Task so the Cancel button
    /// can tear it down. `nil` when nothing's in flight.
    @State private var generationTask: Task<Void, Never>?

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
                    generationTask = Task { await generateInvite() }
                } label: {
                    if isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(generationStatus.isEmpty
                                 ? "Preparing…"
                                 : generationStatus)
                                .font(.callout)
                        }
                    } else {
                        Label("Generate invite", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)

                // Cancel button visible only during a running
                // generation. Lets the user bail out of a stuck
                // CloudKit call without force-quitting the app —
                // `container.share([profile], to: nil)` can hang for
                // 30+ s on first-time shared-zone provisioning.
                if isGenerating {
                    Button(role: .cancel) {
                        generationTask?.cancel()
                        generationTask = nil
                        isGenerating = false
                        generationStatus = ""
                        pairingLog.notice("generateInvite cancelled by user")
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }

                // Inline URL block — shown on every platform once
                // we have a share URL. Serves as an escape hatch when
                // the platform-native share sheet fails to send
                // (`UICloudSharingController` sometimes wedges when
                // handed a pre-existing CKShare from `fetchShares`).
                // The Copy Link + ShareLink buttons work
                // independently of the sheet.
                #if os(iOS) || os(macOS)
                if let url = inviteURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send this link to your Guardian:")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(url.absoluteString)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
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
        .mapMeBrandToolbar()
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
        // Alert takes precedence over the inline red Text so an error
        // can't be missed by scrolling past it in the Form.
        .alert(
            "Couldn't create invite",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            ),
            presenting: error
        ) { _ in
            Button("OK", role: .cancel) { error = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @MainActor
    private func generateInvite() async {
        pairingLog.notice("generateInvite tapped")
        isGenerating = true
        generationStatus = "Ensuring profile…"
        defer {
            isGenerating = false
            generationStatus = ""
        }
        do {
            let trimmed = profileName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                pairingLog.error("generateInvite aborted: display name is empty")
                self.error = "Enter a display name first."
                return
            }
            let profile = sharing.ensureMinorProfile(displayName: trimmed)
            if profile.displayName != trimmed {
                profile.displayName = trimmed
                try? profile.managedObjectContext?.save()
            }
            pairingLog.notice("Profile ready; calling makeShare")
            generationStatus = "Creating share (network)…"

            // Progressive status ticker. On first-time shared-zone
            // provisioning the CK call can legitimately take 30-60 s;
            // updating the status every 5 s tells the user "still
            // working" instead of a spinner that looks frozen.
            // Local ticker inside a Task — self is a SwiftUI struct
            // and can't be weak-captured, but the closure captures
            // the `@State` bindings by value which write through to
            // the view's storage. Task.isCancelled short-circuits
            // once we `defer`-cancel below.
            let statusTicker = Task { @MainActor in
                var elapsed = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    elapsed += 5
                    if Task.isCancelled { return }
                    generationStatus = "Still creating share (\(elapsed)s)…"
                }
            }
            defer { statusTicker.cancel() }

            // 90 s watchdog. First-time shared-zone provisioning on
            // a device that's never shared before can legitimately
            // take up to a minute — 45 s was too tight for the
            // macOS-first-share case.
            let result = try await withThrowingTaskGroup(of: (CKShare, CKContainer).self) { group -> (CKShare, CKContainer) in
                group.addTask { try await sharing.makeShare(for: profile) }
                group.addTask {
                    try await Task.sleep(for: .seconds(90))
                    throw NSError(
                        domain: "MapMe.Pairing",
                        code: 300,
                        userInfo: [NSLocalizedDescriptionKey:
                            "CloudKit didn't return an invite within 90 seconds. Check your iCloud connection and try again."]
                    )
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            let (share, container) = result

            pairingLog.notice("makeShare returned")
            // Always populate `inviteURL` so the inline URL + Copy/
            // Share buttons are visible as a fallback in case the
            // platform-native share sheet won't fire. `share.url`
            // is nil until CloudKit finishes saving the share; a
            // just-fetched existing share usually has it, but a
            // brand-new one may not, in which case we set it later
            // when a fresh evaluation finds it populated.
            inviteURL = share.url
            #if os(iOS)
            pendingShare = ShareWrapper(share: share, container: container, title: trimmed)
            pairingLog.notice("pendingShare set — sheet should present (share.url = \(share.url?.absoluteString ?? "nil", privacy: .public))")
            #elseif os(macOS)
            // The share's `url` is populated after CloudKit saves the share.
            // NSPersistentCloudKitContainer.share(_:to:) saves it for us.
            inviteURL = share.url
            if share.url == nil {
                self.error = "Share was created but iCloud has not yet returned a URL. Try again in a moment."
                pairingLog.error("share.url is nil after makeShare returned")
            } else {
                pairingLog.notice("share.url populated on macOS")
            }
            #endif
        } catch is CancellationError {
            pairingLog.notice("generateInvite cancelled")
        } catch {
            pairingLog.error("generateInvite FAILED: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
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
        // Pin read-write so the Guardian can write `consentGrantedAt` back
        // into the share — omitting `.allowReadOnly` removes the "View only"
        // toggle entirely, so the Minor can't accidentally send a read-only
        // invite that leaves "Grant consent" dead on the Guardian's device.
        // `.allowPrivate` keeps it invite-only (no public toggle).
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

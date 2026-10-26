#if os(iOS) || os(macOS)
import SwiftUI
import CoreData

/// Minimal creation sheet for a third-party tracker (pet or device).
///
/// Distinct from `PairingView` — that starts the CKShare / consent
/// dance that a real Minor's device needs. A pet or a Garmin has
/// nothing to consent to; we just want a labelled row that the
/// `LogTrackerLocationIntent` Shortcut can target. So the whole
/// creation flow is: name + kind + save.
///
/// The new profile lands in the private CloudKit store and gets
/// `consentGrantedAt` stamped immediately so it bypasses the
/// "waiting for consent" screen every existing surface uses.
/// 
struct AddTrackerView: View {
    @Environment(\.managedObjectContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var kind: TrackerKind = .pet
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown on the map and in your tracker list — e.g. \"Luna\", \"Dad's Garmin\", \"Backpack\".")
                }

                Section("Kind") {
                    Picker("Kind", selection: $kind) {
                        ForEach([TrackerKind.pet, .device], id: \.self) { k in
                            Label(k.label, systemImage: k.systemImage)
                                .tag(k)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Text("After saving, open Shortcuts and add the “Log tracker location” action. Point it at this tracker, then wire your device's app to fill in the coordinates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Next step")
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add tracker")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let profile = MinorProfile(context: ctx)
        // Pin to private store — third-party trackers don't
        // participate in the CKShare Minor-consent flow.
        if let privateStore = PersistenceController.shared.privateStore {
            ctx.assign(profile, to: privateStore)
        }
        profile.id = UUID()
        profile.createdAt = Date()
        profile.displayName = trimmed
        profile.kind = kind
        // Bypass the consent screen — pets/devices can't consent.
        profile.consentGrantedAt = Date()
        // Stable id for the LogTrackerLocationIntent so the Shortcuts
        // picker can round-trip identity across app relaunches.
        profile.deviceIdentifier = "tracker-\(UUID().uuidString)"

        do {
            try ctx.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    AddTrackerView()
        .environment(\.managedObjectContext,
                     PersistenceController.shared.container.viewContext)
}
#endif

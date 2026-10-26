#if os(iOS) || os(macOS) || os(tvOS)
import SwiftUI

/// Shows every device that has ever launched MapMe under this
/// iCloud account. Guardian can revoke a device to force it back
/// through the (build-11) approval flow; a mis-tap restore is one
/// click away since revoke is a soft-delete.
///
/// Same view compiles on iOS, macOS, and tvOS — the platform gate
/// only excludes watchOS, which surfaces the list in a smaller
/// panel later if the user asks.
struct TrustedDevicesView: View {
    @StateObject private var service = TrustedDeviceService.shared
    @State private var pendingRevoke: TrustedDevice?

    var body: some View {
        List {
            Section {
                if service.trustedDevices.isEmpty {
                    ContentUnavailableView(
                        "No devices yet",
                        systemImage: "iphone.slash",
                        description: Text("Open MapMe on another device that shares this iCloud to see it register here.")
                    )
                } else {
                    ForEach(service.trustedDevices, id: \.objectID) { device in
                        row(for: device)
                    }
                }
            } header: {
                Text("Devices signed into this iCloud")
            } footer: {
                Text("A revoked device stops writing to shared zones and needs the approval flow to rejoin. Revoke is soft — the row stays visible so you can restore it if you tapped by accident.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Trusted Devices")
        .onAppear { service.reload() }
        .confirmationDialog(
            "Revoke this device?",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            ),
            presenting: pendingRevoke
        ) { device in
            Button("Revoke", role: .destructive) {
                service.revoke(device)
                pendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: { device in
            Text("\(device.displayName ?? "This device") will stop appearing in the family and will need to be re-approved before it can share location again.")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for device: TrustedDevice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(for: device.platform))
                .font(.title3)
                .foregroundStyle(device.revokedAt == nil ? Color.accentColor : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName ?? "Unknown device")
                    .font(.callout.weight(.medium))
                    .strikethrough(device.revokedAt != nil, color: .secondary)
                Text(subtitle(for: device))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if device.deviceIdentifier == DeviceID.current {
                Text("This device")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            } else if device.revokedAt == nil {
                Button("Revoke", role: .destructive) {
                    pendingRevoke = device
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Restore") {
                    service.restore(device)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func symbol(for platform: String?) -> String {
        switch platform {
        case "iPhone": return "iphone"
        case "iPad": return "ipad"
        case "Mac": return "macbook"
        case "Apple TV": return "appletv"
        case "Apple Watch": return "applewatch"
        default: return "questionmark.circle"
        }
    }

    private func subtitle(for device: TrustedDevice) -> String {
        var parts: [String] = []
        if let platform = device.platform, !platform.isEmpty {
            parts.append(platform)
        }
        if let first = device.firstSeenAt {
            parts.append("added \(relative(first))")
        }
        if let revoked = device.revokedAt {
            parts.append("revoked \(relative(revoked))")
        } else if let last = device.lastActiveAt {
            parts.append("active \(relative(last))")
        }
        return parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }
}
#endif

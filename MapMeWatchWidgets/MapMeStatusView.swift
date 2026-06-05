import WidgetKit
import SwiftUI

struct MapMeStatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MapMeStatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:    circular
        case .accessoryCorner:      corner
        case .accessoryInline:      inline
        case .accessoryRectangular: rectangular
        default:                    inline
        }
    }

    // MARK: - Family layouts

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.title3)
                Text(shortLabel)
                    .font(.caption2.weight(.semibold))
            }
        }
    }

    private var corner: some View {
        Image(systemName: icon)
            .widgetLabel { Text(richLine) }
    }

    private var inline: some View {
        Label(richLine, systemImage: icon)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(headlineText, systemImage: icon)
                .font(.headline)
            if let ts = entry.lastTimestamp {
                Text("Last fix \(ts, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if entry.profileExists, entry.consentGranted {
                Text("Awaiting first fix")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Derived copy

    private var icon: String {
        if !entry.profileExists { return "iphone.gen3.badge.play" }
        if !entry.consentGranted { return "exclamationmark.shield" }
        return entry.isLive ? "location.fill" : "location"
    }

    private var shortLabel: String {
        if !entry.profileExists { return "Setup" }
        if !entry.consentGranted { return "Wait" }
        return entry.isLive ? "Live" : "Idle"
    }

    private var headlineText: String {
        if !entry.profileExists { return "Set up on iPhone" }
        if !entry.consentGranted { return "Awaiting consent" }
        return entry.isLive ? "Live tracking" : "Idle"
    }

    private var richLine: String {
        if !entry.profileExists { return "Set up on iPhone" }
        if !entry.consentGranted { return "Awaiting consent" }
        if let ts = entry.lastTimestamp {
            let mins = max(0, Int(Date().timeIntervalSince(ts) / 60))
            let suffix = mins == 0 ? "now" : "\(mins)m"
            return entry.isLive ? "Live · \(suffix)" : "Idle · \(suffix)"
        }
        return entry.isLive ? "Live" : "Idle"
    }
}

#Preview(as: .accessoryRectangular) {
    MapMeStatusWidget()
} timeline: {
    MapMeStatusEntry(
        date: .now,
        isLive: true,
        consentGranted: true,
        profileExists: true,
        lastTimestamp: .now
    )
}

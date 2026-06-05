import WidgetKit
import SwiftUI

struct MapMeStatusWidget: Widget {
    static let kind = "com.mapme.app.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: MapMeStatusProvider()
        ) { entry in
            MapMeStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("MapMe")
        .description("Tracking state and time since the last fix.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

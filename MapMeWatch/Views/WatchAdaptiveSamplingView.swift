import SwiftUI

/// Dedicated watch screen for speed-band adaptive sampling.
///
/// **Why a separate view?** When the sliders lived in a `Section` of
/// `WatchSettingsView`'s main `List`, each `Slider` read its parent
/// `ScrollView`'s `contentOffset` (so its drag gesture could
/// coordinate with list scrolling). That fires SwiftUI's
/// "contentOffset binding has been read — grossly inefficient" log
/// warning once per Slider, on every layout pass — for the seven
/// sliders here, that's a constant warning storm.
///
/// Moving the sliders behind a `NavigationLink` into their own
/// dedicated `ScrollView` confines the warning to this single
/// view's render (where it's actually fine — there's nothing
/// outside to be inefficient about). The main Settings list stays
/// clean.
struct WatchAdaptiveSamplingView: View {
    @EnvironmentObject private var location: WatchLocationService
    @ObservedObject private var adaptive = AdaptiveSamplingConfig.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $adaptive.isEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Enable").font(.caption)
                        Text("Cadence varies by motion speed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if adaptive.isEnabled {
                    diagnostic
                    Divider()
                    thresholds
                    Divider()
                    intervals
                    Button("Reset defaults", role: .destructive) {
                        adaptive.resetToDefaults()
                    }
                    .font(.caption2)
                }

                Text("Off → Power profile interval. On → cadence depends on speed band, per this watch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Adaptive")
    }

    // MARK: - Subsections

    /// Live readout of the device's current speed → band → write
    /// interval. Lets the user watch their actual band as they drag
    /// the threshold sliders below.
    private var diagnostic: some View {
        let speedKmh = max(0, location.lastLocation?.speed ?? -1) * 3.6
        let band = adaptive.band(forSpeedKmh: speedKmh)
        let interval = adaptive.interval(forSpeedKmh: speedKmh)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Now: \(speedKmh, specifier: "%.1f") km/h → \(band)")
                .font(.caption2.monospacedDigit())
            Text("Writing every \(Int(interval)) s")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Thresholds (km/h). Open-bottom / closed-top bucketing matches
    /// `AdaptiveSamplingConfig.interval(forSpeedKmh:)`, so we don't
    /// enforce ordering across the three knobs — the band logic
    /// falls through cleanly if the user drags walking below
    /// stationary.
    private var thresholds: some View {
        VStack(alignment: .leading, spacing: 6) {
            slider(title: "Stationary <",
                   value: $adaptive.stationaryThresholdKmh,
                   range: 0.1...5,
                   step: 0.1,
                   unit: "km/h",
                   format: "%.1f")
            slider(title: "Walking <",
                   value: $adaptive.walkingThresholdKmh,
                   range: 2...20,
                   step: 0.5,
                   unit: "km/h",
                   format: "%.1f")
            slider(title: "Running <",
                   value: $adaptive.runningThresholdKmh,
                   range: 5...40,
                   step: 0.5,
                   unit: "km/h",
                   format: "%.1f")
        }
    }

    /// Per-band write intervals (seconds).
    private var intervals: some View {
        VStack(alignment: .leading, spacing: 6) {
            intervalSlider(title: "Stationary",
                           value: $adaptive.stationaryInterval,
                           range: 30...600,
                           step: 10)
            intervalSlider(title: "Walking",
                           value: $adaptive.walkingInterval,
                           range: 15...300,
                           step: 5)
            intervalSlider(title: "Running",
                           value: $adaptive.runningInterval,
                           range: 10...180,
                           step: 5)
            intervalSlider(title: "Vehicle",
                           value: $adaptive.vehicleInterval,
                           range: 5...120,
                           step: 5)
        }
    }

    // MARK: - Slider helpers

    @ViewBuilder
    private func slider(title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double,
                        unit: String,
                        format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(String(format: format, value.wrappedValue)) \(unit)")
                .font(.caption2.monospacedDigit())
            Slider(value: value, in: range, step: step)
        }
    }

    @ViewBuilder
    private func intervalSlider(title: String,
                                value: Binding<TimeInterval>,
                                range: ClosedRange<Double>,
                                step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) every \(Int(value.wrappedValue)) s")
                .font(.caption2.monospacedDigit())
            Slider(value: value, in: range, step: step)
        }
    }
}

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct ChargeLiveActivity: Widget {
    private static let islandInset: CGFloat = 8

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            ChargeActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            // The Dynamic Island is always dark.
            let palette = WidgetPalette(.dark)
            let state = context.state
            let reading = state.reading
            let tint = palette.tint(for: state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(verbatim: reading.percentText)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: reading.symbolName)
                            .foregroundStyle(palette.tint(for: reading))
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(reading.statusTitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        // The island's corners cut into the outer few points of the
                        // top and bottom rows: the last letter here, and the End
                        // button below, were clipped.
                        .padding(.trailing, Self.islandInset)
                }
                DynamicIslandExpandedRegion(.center) {
                    PrimaryMetricView(state: state,
                                      palette: palette,
                                      size: 28,
                                      isStale: (context.isStale || context.state.isPaused == true))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        if let traffic = state.traffic {
                            Text(verbatim: traffic.summary)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(palette.network)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else if let temperature = reading.batteryTemperature {
                            Text(verbatim: String(format: "%.1f °C", temperature))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(palette.muted)
                        }
                        ActivityFootnote(context: context, palette: palette)
                    }
                    .padding(.horizontal, Self.islandInset)
                }
            } compactLeading: {
                Image(systemName: symbol(for: state.selectedMetric))
                    .foregroundStyle((context.isStale || context.state.isPaused == true) ? palette.muted : tint)
            } compactTrailing: {
                CompactMetricValue(state: state)
                    .foregroundStyle((context.isStale || context.state.isPaused == true) ? palette.muted : tint)
            } minimal: {
                Text(verbatim: minimalValue(for: state))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(label(for: state.selectedMetric))
                    .accessibilityValue(Text(verbatim: formattedValue(for: state.selectedMetric, state: state)))
                    .foregroundStyle((context.isStale || context.state.isPaused == true) ? palette.muted : tint)
            }
            .keylineTint(tint)
        }
    }
}

struct ChargeActivityLockScreenView: View {
    @Environment(\.colorScheme) private var scheme
    let context: ActivityViewContext<ChargeActivityAttributes>

    var body: some View {
        let palette = WidgetPalette(scheme)
        let state = context.state
        let reading = state.reading
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PrimaryMetricView(state: state,
                                  palette: palette,
                                  size: 34,
                                  isStale: (context.isStale || context.state.isPaused == true))
                Spacer(minLength: 8)
                Text(verbatim: reading.percentText)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            if let traffic = state.traffic {
                Text(verbatim: traffic.summary)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(palette.network)
                    .lineLimit(1)
            } else if let temperature = reading.batteryTemperature {
                Text(verbatim: String(format: "%.1f °C", temperature))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(palette.muted)
            }
            ActivityFootnote(context: context, palette: palette)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .activitySystemActionForegroundColor(palette.tint(for: state))
    }
}

/// The selected reading with a short source or sensor caption.
private struct PrimaryMetricView: View {
    let state: ChargeActivityContentState
    let palette: WidgetPalette
    let size: CGFloat
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: symbol(for: state.selectedMetric))
                    .font(.system(size: size * 0.5, weight: .bold))
                Text(verbatim: primaryValue)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(verbatim: primaryUnit)
                    .font(.system(size: max(11, size * 0.42),
                                  weight: .medium,
                                  design: .rounded))
            }
            .foregroundStyle(isStale ? palette.muted : palette.tint(for: state))
            .lineLimit(1)
            .layoutPriority(1)

            caption
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(for: state.selectedMetric))
        .accessibilityValue(isStale ? Text("Paused")
                            : Text(verbatim: formattedValue(for: state.selectedMetric, state: state)))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var primaryValue: String {
        if state.selectedMetric.isNetwork {
            return NetworkRateText(numericValue(for: state.selectedMetric, state: state)).value
        }
        return numericValue(for: state.selectedMetric, state: state).map(oneDecimal) ?? "—"
    }

    private var primaryUnit: String {
        if state.selectedMetric.isNetwork {
            return NetworkRateText(numericValue(for: state.selectedMetric, state: state)).unit
        }
        return unit(for: state.selectedMetric)
    }

    @ViewBuilder
    private var caption: some View {
        switch state.selectedMetric {
        case .chargingPower:
            if let source = state.reading.source {
                Text(source.caption)
            }
        case .hottestTemperature:
            if let name = state.hottestSensorName {
                Text(verbatim: name)
                    .fontDesign(.monospaced)
            } else {
                Text(label(for: .hottestTemperature))
            }
        case .socTemperature, .batteryTemperature, .downloadRate, .uploadRate:
            Text(label(for: state.selectedMetric))
        }
    }
}

private struct CompactMetricValue: View {
    let state: ChargeActivityContentState

    var body: some View {
        Text(verbatim: shortValue(for: state.selectedMetric, state: state))
            .font(.system(size: state.selectedMetric.isNetwork ? 12 : 14, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// A timestamp and two small actions, with a paused marker when data stops.
struct ActivityFootnote: View {
    let context: ActivityViewContext<ChargeActivityAttributes>
    let palette: WidgetPalette

    var body: some View {
        HStack(spacing: 6) {
            if (context.isStale || context.state.isPaused == true) {
                Label("Paused", systemImage: "pause.circle")
                    .foregroundStyle(palette.loss)
            }
            Spacer(minLength: 6)
            Text(verbatim: context.state.date.formatted(date: .omitted, time: .standard))
            Button(intent: RefreshChargeActivityIntent()) {
                Image(systemName: "arrow.clockwise")
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(palette.track))
            }
            .accessibilityLabel("Refresh readings")
            .buttonStyle(.plain)
            if context.state.traffic != nil {
                Button(intent: StopTrafficActivityIntent()) {
                    Image(systemName: "stop.fill")
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(palette.track))
                }
                .accessibilityLabel("Stop download")
                .buttonStyle(.plain)
            } else {
                Button(intent: EndChargeActivityIntent()) {
                    Image(systemName: "xmark")
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(palette.track))
                }
                .accessibilityLabel("End Live Activity")
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private func numericValue(
    for metric: LiveActivityMetric,
    state: ChargeActivityContentState
) -> Double? {
    switch metric {
    case .chargingPower: state.reading.watts
    case .socTemperature: state.socTemperature
    case .batteryTemperature: state.batteryTemperature
    case .hottestTemperature: state.hottestTemperature
    case .downloadRate: state.network?.downloadBytesPerSecond
    case .uploadRate: state.network?.uploadBytesPerSecond
    }
}

private func label(for metric: LiveActivityMetric) -> LocalizedStringKey {
    switch metric {
    case .chargingPower: "Charging power"
    case .socTemperature: "SoC temperature"
    case .batteryTemperature: "Battery temperature"
    case .hottestTemperature: "Hottest component"
    case .downloadRate: "Download speed"
    case .uploadRate: "Upload speed"
    }
}

private func symbol(for metric: LiveActivityMetric) -> String {
    switch metric {
    case .chargingPower: "bolt.fill"
    case .socTemperature: "cpu"
    case .batteryTemperature: "battery.75percent"
    case .hottestTemperature: "thermometer.high"
    case .downloadRate: "arrow.down"
    case .uploadRate: "arrow.up"
    }
}

private func unit(for metric: LiveActivityMetric) -> String {
    metric == .chargingPower ? "W" : "°"
}

private func oneDecimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

private func shortValue(
    for metric: LiveActivityMetric,
    state: ChargeActivityContentState
) -> String {
    guard let value = numericValue(for: metric, state: state) else { return "—" }
    if metric.isNetwork { return NetworkRateText(value).combined }
    return oneDecimal(value) + unit(for: metric)
}

private func formattedValue(
    for metric: LiveActivityMetric,
    state: ChargeActivityContentState
) -> String {
    guard numericValue(for: metric, state: state) != nil else {
        return String(localized: "No reading")
    }
    return shortValue(for: metric, state: state)
}

private func minimalValue(for state: ChargeActivityContentState) -> String {
    let metric = state.selectedMetric
    guard metric.isNetwork else { return shortValue(for: metric, state: state) }
    let formatted = NetworkRateText(numericValue(for: metric, state: state))
    guard !formatted.unit.isEmpty else { return "—" }
    let arrow = metric == .downloadRate ? "↓" : "↑"
    return arrow + formatted.value + formatted.unit.prefix(1)
}

#Preview("Lock Screen", as: .content,
         using: ChargeActivityAttributes(startedAt: .now.addingTimeInterval(-1_800),
                                         startPercent: 41)) {
    ChargeLiveActivity()
} contentStates: {
    ChargeActivityContentState(
        reading: ChargeReading(date: .now,
                               percent: 72,
                               externalConnected: true,
                               isCharging: true,
                               watts: 18.4,
                               source: .charger,
                               batteryTemperature: 33.6),
        socTemperature: 39.2,
        hottestTemperature: 41.3,
        hottestSensorName: "PMU tdie1",
        selectedMetric: .chargingPower,
        network: NetworkReading(connection: .wifi,
                                downloadBytesPerSecond: 3_240_000,
                                uploadBytesPerSecond: 128_000),
        isPaused: false
    )
}

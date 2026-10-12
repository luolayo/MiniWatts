import SwiftUI

struct ThermalView: View {
    var isDetail = false
    @Environment(PowerMonitor.self) private var monitor
    private var snapshot: PowerSnapshot { monitor.snapshot }

    var body: some View {
        PageScaffold("Temperature details", isDetail: isDetail) {
            Panel("System thermal state", systemImage: "cpu") {
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text(monitor.thermal.state.title) } icon: { Image(systemName: monitor.thermal.state.symbol) }
                        .font(.headline)
                        .foregroundStyle(monitor.thermal.state.isThrottling ? Color.mwDanger : .mwAccent)
                    Text(monitor.thermal.state.chargingEffect)
                        .font(.subheadline)
                        .foregroundStyle(Color.mwMuted)
                }
            }
            summaryPanel
            Panel("Hottest sensor, last 3 minutes", systemImage: "chart.line.uptrend.xyaxis") {
                LiveTemperatureChart(samples: monitor.live)
            }
            if snapshot.temperatures.isEmpty {
                Panel("Sensors", systemImage: "sensor") {
                    EmptyNote(text: "No temperature sensors found.")
                }
            } else {
                ForEach(snapshot.temperaturesByZone) { group in
                    zonePanel(group)
                }
            }
        }
    }

    private var summaryPanel: some View {
        Panel("Component temperatures", systemImage: "thermometer.medium") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 18) {
                temperature("Battery", value: snapshot.batteryTemperature)
                temperature("SoC", value: snapshot.socTemperature)
                temperature("Charge IC", value: snapshot.chargerTemperature)
                temperature("Hottest", value: snapshot.hottestSensor?.value,
                            source: snapshot.hottestSensor?.name)
            }
        }
    }

    private func temperature(_ title: LocalizedStringResource,
                             value: Double?, source: String? = nil) -> some View {
        Metric(caption: title,
               value: value.map { String(format: "%.1f", $0) } ?? "—",
               unit: "°C",
               tint: value.map { Color.mwTemperature($0) } ?? .primary,
               footnote: source.map { Text(verbatim: $0) }, size: 24)
    }

    private func zonePanel(_ group: ZoneTemperatures) -> some View {
        Panel {
            DisclosureGroup {
                VStack(spacing: 14) {
                    ForEach(group.readings) { reading in
                        let label = SensorCatalog.label(for: reading.name)
                        BarRow(title: label.map { Text($0) } ?? Text(verbatim: reading.name),
                               detail: String(format: "%.1f °C", reading.value),
                               fraction: (reading.value - 20) / 30,
                               tint: .mwTemperature(reading.value),
                               subtitle: label == nil ? nil : Text(verbatim: reading.name))
                    }
                }
                .padding(.top, 14)
            } label: {
                HStack {
                    Label { Text(group.zone.title) } icon: { Image(systemName: group.zone.symbol) }
                    Spacer()
                    if let hottest = group.hottest {
                        Text(verbatim: String(format: "%.1f °C", hottest))
                            .monospacedDigit()
                            .foregroundStyle(Color.mwMuted)
                    }
                }
                .font(.subheadline)
            }
        }
    }
}

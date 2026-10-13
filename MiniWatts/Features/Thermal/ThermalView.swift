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
                    EmptyNote(text: snapshot.temperatureWarnings.isEmpty
                              ? "No temperature sensors were found. The simulator has none; on a device they appear as soon as the app has read the HID service list."
                              : "Temperature sensors answered, but every value was excluded from derived readings. See the filter details below.",
                              systemImage: "exclamationmark.triangle")
                }
                if !snapshot.temperatureWarnings.isEmpty {
                    temperatureWarningsPanel
                }
            } else {
                if !snapshot.temperatureWarnings.isEmpty {
                    temperatureWarningsPanel
                }
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
                temperature("Battery", value: snapshot.batteryTemperature,
                            source: batteryTemperatureSource)
                temperature("SoC", value: snapshot.socTemperature)
                temperature("Charge IC", value: snapshot.chargerTemperature,
                            source: snapshot.hottestSensor(in: .charger).map(sensorSource))
                temperature("Hottest", value: snapshot.hottestSensor?.value,
                            source: snapshot.hottestSensor.map(sensorSource))
            }
        }
    }

    private var temperatureWarningsPanel: some View {
        Panel("Excluded from derived temperatures", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.temperatureWarnings, id: \.self) { warning in
                    Text(verbatim: warning)
                        .mwMono(size: 11)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Where the battery figure came from. Usually a HID sensor; on the simulator —
    /// and anywhere else the registry is not filtered — it is the registry itself,
    /// which is a different provenance and worth saying so.
    private var batteryTemperatureSource: Text? {
        if snapshot.registryTemperature != nil { return Text(verbatim: "IOPMPowerSource") }
        if snapshot.batteryTemperatureReadings.count > 1 {
            return Text(verbatim: "median of \(snapshot.batteryTemperatureReadings.count) battery sensors")
        }
        return snapshot.hottestSensor(in: .battery).map(sensorSource)
    }

    // MARK: Zones

    /// How one sensor is labelled: the translated name when we recognise it, with
    /// the hardware name kept underneath, and the bare hardware name when we do not.
    private func sensorSource(_ reading: HIDSensors.Reading) -> Text {
        Text(verbatim: "\(reading.name) · #\(reading.index)")
    }

    private func temperature(_ title: LocalizedStringResource,
                             value: Double?, source: Text? = nil) -> some View {
        Metric(caption: title,
               value: value.map { String(format: "%.1f", $0) } ?? "—",
               unit: "°C",
               tint: value.map { Color.mwTemperature($0) } ?? .primary,
               footnote: source, size: 24)
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
                               subtitle: sensorSource(reading))
                    }
                }
                .padding(.top, 14)
            } label: {
                HStack {
                    Label { Text(group.zone.title) } icon: { Image(systemName: group.zone.symbol) }
                    Spacer()
                    if let representative = group.representative {
                        Text(verbatim: String(format: "%.1f °C", representative))
                            .monospacedDigit()
                            .foregroundStyle(Color.mwMuted)
                    }
                }
                .font(.subheadline)
            }
        }
    }
}

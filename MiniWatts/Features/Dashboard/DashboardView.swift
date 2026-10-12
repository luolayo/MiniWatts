import SwiftUI

struct DashboardView: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(TrafficConsumer.self) private var trafficConsumer
    @State private var showingActivitySettings = false

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var plugged: Bool { snapshot.externalConnected }

    var body: some View {
        PageScaffold("MiniWatts", toolbar: AnyView(toolbarButtons)) {
            heroPanel
            if monitor.thermal.state.isThrottling { throttleBanner }
            networkPanel
            batteryPanel
            breakdownPanel
            temperaturePanel
            livePanel
            if monitor.currentSession != nil { sessionPanel }
            if !monitor.sensorsAvailable { sensorNote }
        }
        .sheet(isPresented: $showingActivitySettings) { LiveActivitySettingsView() }
    }

    private var statusColor: Color {
        if monitor.thermal.state.isThrottling { return .mwDanger }
        if snapshot.isWirelessInput { return .mwWireless }
        return plugged ? .mwAccent : .mwLoss
    }

    private var toolbarButtons: some View {
        Button { showingActivitySettings = true } label: {
            Label("Dynamic Island", systemImage: "wave.3.right")
                .font(.subheadline)
        }
        .tint(.mwAccent)
    }

    private var heroPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if let caption = monitor.headline?.caption {
                        Text(caption).mwCaption()
                    } else {
                        Text("Charging power").mwCaption()
                    }
                    Spacer(minLength: 8)
                    Text(snapshot.statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(monitor.headline.map { Formatting.watts($0.watts) } ?? "—")
                        .mwReadout(size: 60, weight: .medium)
                    Text(verbatim: "W")
                        .font(.title3)
                        .foregroundStyle(Color.mwMuted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                if plugged, let voltage = snapshot.usbInputVoltage,
                   let current = snapshot.usbInputCurrent, !snapshot.isWirelessInput {
                    Text(verbatim: String(format: "USB-C · %.2f V × %.2f A", voltage, current))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.mwMuted)
                }
                FlowRow(spacing: 6) {
                    if snapshot.isWirelessInput {
                        Pill(text: Text("MagSafe"), systemImage: "wave.3.right", tint: .mwWireless)
                    }
                    if snapshot.holdIsInferred {
                        Pill(text: Text("inferred"), systemImage: "questionmark.circle", tint: .mwLoss)
                    }
                    if snapshot.holdIsUnknown {
                        Pill(text: Text("hold status unknown"), systemImage: "questionmark.circle", tint: .mwLoss)
                    }
                    if monitor.thermal.lowPowerMode || snapshot.lowPowerMode {
                        Pill(text: Text("Low Power"), systemImage: "battery.25", tint: .mwLoss)
                    }
                }
            }
        }
    }

    private var wirelessInputUnmeasurable: Bool {
        plugged && snapshot.inputWatts == nil && snapshot.isWirelessInput
    }

    private var networkPanel: some View {
        let network = monitor.network.reading
        let download = NetworkRateText(network.downloadBytesPerSecond)
        let upload = NetworkRateText(network.uploadBytesPerSecond)
        return Panel("Network speed", systemImage: "arrow.up.arrow.down",
                     trailing: Text(network.connection.title)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Metric(caption: "Download", value: download.value, unit: download.unit,
                           tint: .mwNetwork, size: 30)
                    Metric(caption: "Upload", value: upload.value, unit: upload.unit,
                           tint: .mwNetwork, size: 30)
                }
                Divider()
                HStack {
                    NavigationLink {
                        TrafficConsumerView()
                    } label: {
                        detailLinkLabel("Traffic consumer")
                    }
                    .buttonStyle(.plain)
                    if trafficConsumer.isRunning {
                        Button("Stop", role: .destructive) { trafficConsumer.stop() }
                            .disabled(trafficConsumer.isStopping)
                    }
                }
                if trafficConsumer.isRunning {
                    Text("Downloading: \(TrafficByteText.format(trafficConsumer.progress.receivedBytes))")
                        .font(.caption)
                        .foregroundStyle(Color.mwNetwork)
                }
            }
        }
    }

    private var temperaturePanel: some View {
        Panel("Thermal", systemImage: "thermometer.medium",
              trailing: Text(monitor.thermal.state.title)) {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    temperatureMetric("SoC", value: snapshot.socTemperature)
                    temperatureMetric("Charge IC", value: snapshot.chargerTemperature)
                    temperatureMetric("Hottest", value: snapshot.hottestSensor?.value)
                }
                Divider()
                NavigationLink {
                    ThermalView(isDetail: true)
                } label: {
                    detailLinkLabel("Temperature details")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func temperatureMetric(_ title: LocalizedStringResource, value: Double?) -> some View {
        Metric(caption: title,
               value: value.map { String(format: "%.1f", $0) } ?? "—",
               unit: "°C", tint: .primary, size: 20)
    }

    private func detailLinkLabel(_ title: LocalizedStringResource) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
        }
        .foregroundStyle(Color.mwAccent)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }

    private var throttleBanner: some View {
        Panel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "thermometer.high")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mwDanger)
                VStack(alignment: .leading, spacing: 3) {
                    Text("High system thermal pressure")
                        .font(.system(size: 14, weight: .semibold))
                    Text(monitor.thermal.state.chargingEffect)
                        .font(.caption)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(Text(monitor.thermal.state.title)) for \(Formatting.duration(Date.now.timeIntervalSince(monitor.thermal.stateSince)))")
                        .mwMono(size: 10)
                        .foregroundStyle(Color.mwMuted)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwDanger.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: Battery

    private var batteryPanel: some View {
        Panel("Battery", systemImage: "battery.100") {
            VStack(spacing: 12) {
                if let percent = snapshot.percent {
                    BarRow(title: Text("Charge level"),
                           detail: "\(percent)%",
                           fraction: Double(percent) / 100,
                           tint: percent <= 20 ? .mwDanger : .mwBattery,
                           subtitle: snapshot.timeRemainingMinutes.map { minutes in
                               // Two whole sentences rather than a fragment glued to a
                               // number: word order around the duration is not the same
                               // in every language.
                               let remaining = Formatting.minutesRemaining(minutes)
                               return snapshot.isCharging ? Text("full in \(remaining)")
                                                          : Text("empty in \(remaining)")
                           })
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Cell voltage",
                           value: snapshot.batteryVoltage.map { String(format: "%.2f", $0) } ?? "—",
                           unit: "V", size: 20)
                    Metric(caption: "Cell current",
                           value: snapshot.batteryCurrent.map { String(format: "%.2f", $0) } ?? "—",
                           unit: "A",
                           tint: (snapshot.batteryCurrent ?? 0) > 0 ? .mwBattery : .primary,
                           size: 20)
                    Metric(caption: "Cell temp",
                           value: snapshot.batteryTemperature.map { String(format: "%.1f", $0) } ?? "—",
                           unit: "°C",
                           tint: snapshot.batteryTemperature.map { Color.mwTemperature($0) } ?? .primary,
                           size: 20)
                }
            }
        }
    }

    // MARK: Breakdown

    private var breakdownPanel: some View {
        Panel("Power path", systemImage: "arrow.triangle.branch",
              trailing: snapshot.adapterUtilisation.map { Text("\(Int($0 * 100))% of adapter") }) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "From charger",
                           value: snapshot.inputWatts.map(Formatting.watts) ?? "—",
                           unit: "W", tint: .mwAccent, size: 22)
                    Metric(caption: "Into cell",
                           value: snapshot.batteryWatts.map { Formatting.watts(max($0, 0)) } ?? "—",
                           unit: "W", tint: .mwBattery, size: 22)
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Load + loss",
                           value: snapshot.unaccountedPowerWatts.map(Formatting.watts) ?? "—",
                           unit: "W", tint: .mwLoss, size: 22)
                    Metric(caption: "Cell share",
                           value: snapshot.chargePathEfficiency.map { String(format: "%.0f", $0) } ?? "—",
                           unit: "%",
                           tint: efficiencyTint,
                           footnote: Text("cell watts ÷ measured input watts"),
                           size: 22)
                }
                if let input = snapshot.inputWatts, input > 0.2, let battery = snapshot.batteryWatts, battery > 0 {
                    PowerFlowBar(input: input, toBattery: battery)
                }
                NavigationLink {
                    AdapterView(isDetail: true)
                } label: {
                    detailLinkLabel("Charger details")
                }
                .buttonStyle(.plain)
                if wirelessInputUnmeasurable {
                    EmptyNote(text: "Wireless input power is unavailable; cell power is shown.",
                              systemImage: "wave.3.right")
                }
            }
        }
    }

    private var efficiencyTint: Color {
        guard let efficiency = snapshot.chargePathEfficiency else { return .primary }
        return efficiency >= 85 ? .mwBattery : (efficiency >= 70 ? .mwLoss : .mwDanger)
    }

    // MARK: Live

    private var livePanel: some View {
        Panel("Power trend", systemImage: "waveform.path.ecg",
              trailing: Text("Last 3 minutes")) {
            VStack(alignment: .leading, spacing: 8) {
                LivePowerChart(samples: monitor.live)
                HStack(spacing: 14) {
                    LegendDot(color: .mwAccent, text: "From charger")
                    LegendDot(color: .mwBattery, text: "Into battery", dashed: true)
                }
            }
        }
    }

    // MARK: Session

    private var sessionPanel: some View {
        Panel("This charge", systemImage: "sum",
              trailing: monitor.currentSession.map { Text(verbatim: Formatting.duration($0.duration)) } ?? Text("idle")) {
            if monitor.currentSession != nil {
                let totals = monitor.sessionTotals
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Delivered",
                               value: totals.measuredInputWattHours.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "Wh", tint: .mwAccent, size: 20)
                        Metric(caption: "Stored",
                               value: String(format: "%.2f", totals.batteryWattHours),
                               unit: "Wh", tint: .mwBattery, size: 20)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Into cell",
                               value: String(format: "%.0f", totals.batteryMilliAmpHours),
                               unit: "mAh", size: 20)
                        Metric(caption: "Cell share",
                               value: totals.chargePathEfficiencyPercent.map { String(format: "%.0f", $0) } ?? "—",
                               unit: "%", tint: .mwLoss, size: 20)
                    }
                }
            } else {
                EmptyNote(text: "Plug in to start measuring.",
                          systemImage: "powerplug")
            }
        }
    }

    private var sensorNote: some View {
        Panel("Sensors", systemImage: "sensor") {
            EmptyNote(text: "No power sensors found.",
                      systemImage: "exclamationmark.triangle")
        }
    }
}

/// The input-versus-stored split, drawn as one bar so unaccounted power has a size.
struct PowerFlowBar: View {
    let input: Double
    let toBattery: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let stored = CGFloat(min(toBattery / input, 1))
                HStack(spacing: 2) {
                    Capsule()
                        .fill(Theme.gradient(.mwBattery))
                        .frame(width: max(2, geometry.size.width * stored - 1))
                    Capsule()
                        .fill(Theme.gradient(.mwLoss).opacity(0.7))
                }
            }
            .frame(height: 8)
            HStack {
                Text("stored in cell").font(.caption2).foregroundStyle(Color.mwBattery)
                Spacer()
                Text("system load + losses").font(.caption2).foregroundStyle(Color.mwLoss)
            }
        }
    }
}

struct LegendDot: View {
    let color: Color
    let text: LocalizedStringResource
    var dashed: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            // One stroked line with a dash pattern, rather than two capsules —
            // the second capsule used to be offset out of its own frame and
            // landed on top of the label.
            LegendLine()
                .stroke(color, style: StrokeStyle(lineWidth: 2.5,
                                                  lineCap: .round,
                                                  dash: dashed ? [3.5, 3.5] : []))
                .frame(width: 16, height: 2.5)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.mwMuted)
        }
    }
}

nonisolated private struct LegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A wrapping row of pills. `LazyVGrid` cannot do variable-width items on iOS 17,
/// so the layout is done by hand.
nonisolated struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: width, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

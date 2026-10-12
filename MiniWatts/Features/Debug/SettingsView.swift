import SwiftUI

struct SettingsView: View {
    @Environment(PowerMonitor.self) private var monitor

    var body: some View {
        PageScaffold("Settings") {
            LiveActivitySettingsPanel()
            recordingPanel
            DisclosureGroup("Advanced") {
                VStack(spacing: 14) {
                    capacityPanel(capacity: Binding(get: { monitor.configuredBatteryWattHours },
                                                   set: { monitor.configuredBatteryWattHours = $0 }))
                    devicePanel
                    rawDataLink
                }
                .padding(.top, 12)
            }
            .padding(Theme.cardPadding)
            .background(Color.mwCard, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            aboutPanel
        }
    }

    private var recordingPanel: some View {
        @Bindable var monitor = monitor
        return Panel("Recording", systemImage: "record.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Keep the screen on while charging", isOn: $monitor.keepScreenAwakeWhileCharging)
                    .tint(.mwAccent)
            }
        }
    }

    private func capacityPanel(capacity: Binding<Double>) -> some View {
        Panel("Battery energy", systemImage: "battery.100.bolt") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(format: "%.1f Wh", capacity.wrappedValue))
                        .mwReadout(size: 26)
                        .foregroundStyle(Color.mwAccent)
                    Spacer()
                    Stepper("", value: capacity, in: 5...40, step: 0.1)
                        .labelsHidden()
                }
                if let designCapacity = monitor.snapshot.designCapacity, designCapacity > 0 {
                    EmptyNote(text: "Using device capacity: \(designCapacity) mAh",
                              systemImage: "checkmark.circle")
                }
            }
        }
    }

    private var devicePanel: some View {
        Panel("Device", systemImage: "iphone") {
            VStack(spacing: 0) {
                DetailRow(label: "Model identifier", value: monitor.deviceModelIdentifier)
                DetailRow(label: "System", value: "iOS \(UIDevice.current.systemVersion)")
                DetailRow(label: "HID sensors",
                          value: monitor.sensorsAvailable
                              ? String(localized: "available") : String(localized: "unavailable"))
                DetailRow(label: "Cycle count", value: monitor.snapshot.cycleCount.map(String.init))
                DetailRow(label: "Battery health",
                          value: monitor.snapshot.healthPercent.map { String(format: "%.0f%%", $0) })
            }
        }
    }

    /// In the distributed ipa too, not just Debug builds. It used to be `#if DEBUG`
    /// on the grounds that a raw dump is a development tool — but the probes it runs
    /// answer questions that can only be answered on hardware this project does not
    /// have, and every one of those answers has arrived as a dump pasted by someone
    /// running the release build. Kept at the bottom of Settings, behind a link that
    /// says what it is, so nobody meets it by accident.
    private var rawDataLink: some View {
        NavigationLink {
            DebugView()
        } label: {
            Panel {
                HStack(spacing: 10) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mwMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raw data")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mwMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Where the source lives. Kept as a constant rather than built inline: a typo in
    /// a string literal would only show up as a force-unwrap crash on this screen.
    private static let repository = URL(string: "https://github.com/ResistanceTo/MiniWatts")!

    private var aboutPanel: some View {
        Panel("About", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mwAccent)
                        .frame(width: 22)
                    Text("Free and open source")
                        .font(.system(size: 14, weight: .semibold))
                }
                Link(destination: Self.repository) {
                    HStack(spacing: 8) {
                        Text(verbatim: "github.com/ResistanceTo/MiniWatts")
                            .mwMono(size: 12, weight: .medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.mwAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.mwAccent.opacity(0.1))
                    )
                }
                .padding(.bottom, 4)
                Text("Uses private iOS sensors; sideload only.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
            }
        }
    }
}


struct LiveActivitySettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LiveActivitySettingsPanel()
                    .padding(16)
            }
            .background(Color.mwCanvas)
            .navigationTitle("Dynamic Island")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct LiveActivitySettingsPanel: View {
    @Environment(PowerMonitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        VStack(spacing: 14) {
            Panel("Dynamic Island and Lock Screen", systemImage: "wave.3.right") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Show while charging", isOn: $monitor.showsLiveActivity)
                    .tint(.mwAccent)
                Picker("Primary readout", selection: $monitor.liveActivityMetric) {
                    ForEach(LiveActivityMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                Text("For closed-app starts, add Show Charging Activity to a Charger Connected automation in Shortcuts. Add End Charging Activity for disconnection.")
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
            }
        }
            BackgroundMonitoringPanel()
        }
    }
}

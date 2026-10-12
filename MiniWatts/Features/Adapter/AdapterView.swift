import SwiftUI

struct AdapterView: View {
    var isDetail = false
    @Environment(PowerMonitor.self) private var monitor

    private var snapshot: PowerSnapshot { monitor.snapshot }

    var body: some View {
        PageScaffold("Adapter", isDetail: isDetail) {
            if snapshot.externalConnected {
                headlinePanel
                protocolPanel
                identityPanel
                profilesPanel
                railsPanel
                connectionPanel
            } else {
                Panel("Not connected", systemImage: "powerplug") {
                    EmptyNote(text: "Plug in a charger to see its details.",
                              systemImage: "cable.connector")
                }
                railsPanel
            }
        }
    }

    // MARK: Headline

    private var headlinePanel: some View {
        Panel("Draw vs rating", systemImage: "gauge.with.dots.needle.67percent",
              trailing: snapshot.adapterSource.map { Text(verbatim: $0) }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.inputWatts.map(Formatting.watts) ?? "—")
                        .mwReadout(size: snapshot.inputWatts == nil ? 30 : 44)
                        .foregroundStyle(snapshot.inputWatts == nil ? Color.mwMuted.opacity(0.55) : Color.mwAccent)
                    Text(verbatim: "W")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mwMuted)
                    Text("of")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.mwMuted)
                        .padding(.horizontal, 2)
                    Text(snapshot.adapterRatedWatts.map { String(format: "%.0f", $0) } ?? "—")
                        .mwReadout(size: 26)
                    Text("W rated")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mwMuted)
                }

                if let utilisation = snapshot.adapterUtilisation {
                    BarRow(title: Text("Adapter utilisation"),
                           detail: "\(Int(utilisation * 100))%",
                           fraction: utilisation,
                           tint: utilisation > 0.75 ? .mwBattery : .mwLoss)
                }

                if snapshot.inputWatts == nil, snapshot.adapterIsWireless {
                    EmptyNote(text: "Wireless input power is unavailable.",
                              systemImage: "wave.3.right")
                }
            }
        }
    }

    // MARK: Identity

    private var protocolPanel: some View {
        Panel("Charging protocol", systemImage: "bolt.horizontal") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if snapshot.chargingProtocol == .usbPDInferred {
                        Text(verbatim: "USB-PD")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.mwAccent)
                        Pill(text: Text("inferred"), tint: .mwMuted)
                    } else {
                        Text("Unidentified")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.mwMuted)
                    }
                }
                DetailRow(label: "Negotiated max", value: snapshot.negotiatedProfile?.label)
                Text(protocolExplanation)
                    .font(.caption)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var protocolExplanation: LocalizedStringResource {
        switch snapshot.chargingProtocol {
        case .usbPDInferred:
            "Inferred from the selected power profile. PD version and PPS use cannot be determined."
        case .unidentifiedWireless:
            "Wireless charging detected. Qi, Qi2 and MagSafe cannot be distinguished from this reading."
        case .unidentifiedWired:
            if snapshot.adapterProfiles.isEmpty {
                "iOS did not report enough information to identify the charging protocol."
            } else {
                "PD profiles are reported, but the active charging protocol is unidentified."
            }
        case .notConnected:
            "Plug in a charger to see its details."
        }
    }

    private var identityPanel: some View {
        Panel("Handshake", systemImage: "person.text.rectangle") {
            VStack(spacing: 0) {
                DetailRow(label: "Name", value: snapshot.adapterName)
                DetailRow(label: "Manufacturer", value: snapshot.adapterManufacturer)
                DetailRow(label: "Model", value: snapshot.adapterModel)
                DetailRow(label: "Serial", value: snapshot.adapterSerial)
                DetailRow(label: "Source", value: snapshot.adapterSource)
                DetailRow(label: "Power tier", value: snapshot.adapterPowerTier.map(String.init))
                DetailRow(label: "Transport", value: DetailRow.transportName(wireless: snapshot.adapterIsWireless))
            }
        }
    }

    // MARK: Profiles

    private var profilesPanel: some View {
        Panel("Advertised profiles", systemImage: "list.bullet.rectangle",
              trailing: snapshot.adapterProfiles.isEmpty ? nil : Text(verbatim: "\(snapshot.adapterProfiles.count)")) {
            if snapshot.adapterProfiles.isEmpty {
                EmptyNote(text: "No PD profiles reported.")
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.adapterProfiles) { profile in
                        ProfileRow(profile: profile,
                                   isActive: profile.index == snapshot.negotiatedProfile?.index)
                    }
                }
            }
        }
    }

    // MARK: Rails

    /// The raw voltage and current sensors, grouped by which side of the charge IC
    /// they sit on. This is the ground truth behind every derived number above.
    private var railsPanel: some View {
        Panel("Live rails", systemImage: "bolt.horizontal") {
            let rails: [RailRow] = [
                RailRow(id: "usb", name: "USB-C input",
                        voltage: snapshot.usbInputVoltage, current: snapshot.usbInputCurrent, tint: .mwAccent),
                RailRow(id: "wireless", name: "Wireless input",
                        voltage: snapshot.wirelessInputVoltage, current: snapshot.wirelessInputCurrent, tint: .mwWireless),
                RailRow(id: "battery", name: "Battery rail",
                        voltage: snapshot.batteryRailVoltage, current: snapshot.batteryRailCurrent, tint: .mwBattery),
            ]
            VStack(spacing: 10) {
                ForEach(rails) { rail in
                    let (voltage, current, tint) = (rail.voltage, rail.current, rail.tint)
                    HStack {
                        Text(rail.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(voltage.map { String(format: "%.2f V", $0) } ?? "—")
                            .mwMono(size: 12)
                            .foregroundStyle(voltage == nil ? Color.mwMuted : .primary)
                        Text(verbatim: "×").font(.caption2).foregroundStyle(Color.mwMuted)
                        Text(current.map { String(format: "%.2f A", $0) } ?? "—")
                            .mwMono(size: 12)
                            .foregroundStyle(current == nil ? Color.mwMuted : .primary)
                        Text(watts(voltage, current).map { String(format: "%.1f W", $0) } ?? "—")
                            .mwMono(size: 12, weight: .semibold)
                            .foregroundStyle(tint)
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func watts(_ voltage: Double?, _ current: Double?) -> Double? {
        guard let voltage, let current else { return nil }
        return voltage * current
    }

    // MARK: Connection

    /// What the cable and the two plugs are costing.
    ///
    /// The cable itself cannot be identified from the phone: while charging the
    /// phone is the sink, so it is the charger that reads the cable's e-marker, and
    /// none of that reaches iOS — `IOPortTransportComponentCCUSBPDSOPp` does not even
    /// exist there. What is measurable is the consequence, and there are two ways to
    /// get at it, which fail in opposite conditions:
    ///
    /// - `PathResistanceMeter` fits the port voltage against the current and needs no
    ///   reference voltage, but needs the current to have moved.
    /// - `PowerSnapshot.inputPathMilliohms` divides the drop from the negotiated
    ///   voltage by the current, which answers immediately but trusts a contract
    ///   figure that is a ceiling rather than a reading.
    ///
    /// The bad-cable case is exactly where the fit goes quiet: a collapsed rail pins
    /// the current, so there is nothing to fit a slope to. Hence both, with the panel
    /// saying which one it is showing.
    private var connectionPanel: some View {
        Panel("Cable and connection", systemImage: "cable.connector.horizontal",
              trailing: monitor.pathResistance.map { Text("\($0.sampleCount) samples") }) {
            if let resistance {
                VStack(alignment: .leading, spacing: 12) {
                    if isSagging { sagBanner }
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Path resistance",
                               value: String(format: "%.0f", resistance.milliohms),
                               unit: "mΩ",
                               tint: resistanceTint(resistance.milliohms),
                               footnote: resistance.fitted
                                   ? Text("fitted over the whole contract")
                                   : Text("from one sample"),
                               size: 22)
                        Metric(caption: "Voltage drop",
                               value: snapshot.inputVoltageDropVolts.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "V",
                               tint: isSagging ? .mwDanger : .primary,
                               // Copy with a measurement inside it, so the sentence
                               // is extracted and the number is not.
                               footnote: snapshot.usbInputVoltage.map { Text("\(String(format: "%.2f V", $0)) at the port") },
                               size: 22)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Lost in the path",
                               value: snapshot.usbInputCurrent.map {
                                   Formatting.watts(resistance.milliohms / 1000 * $0 * $0)
                               } ?? "—",
                               unit: "W",
                               tint: .mwLoss,
                               footnote: Text("at the current draw"),
                               size: 22)
                        Metric(caption: "Taking",
                               value: snapshot.inputCurrentUtilisation.map { String(format: "%.0f", $0 * 100) } ?? "—",
                               unit: "%",
                               tint: (snapshot.inputCurrentUtilisation ?? 1) < 0.6 ? .mwLoss : .primary,
                               footnote: Text("of the current on offer"),
                               size: 22)
                    }
                    Text(resistanceVerdict(resistance.milliohms))
                        .font(.caption)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if snapshot.isWirelessInput || snapshot.adapterIsWireless {
                EmptyNote(text: "Cable resistance is unavailable for wireless charging.",
                          systemImage: "wave.3.right")
            } else {
                EmptyNote(text: "Waiting for enough current to measure voltage drop.",
                          systemImage: "chart.xyaxis.line")
            }
        }
    }

    /// The resistance to show, and whether it came from the fit or from one sample.
    /// The fit wins when it exists: it needs no reference voltage, so it is the
    /// better number whenever the current has moved enough to produce one.
    private var resistance: (milliohms: Double, fitted: Bool)? {
        if let estimate = monitor.pathResistance { return (estimate.milliohms, true) }
        if let single = snapshot.inputPathMilliohms { return (single, false) }
        return nil
    }

    /// The snapshot knows the electrical signature; heat, a hold and a nearly-full
    /// battery are the innocent explanations for the same low draw, and only the
    /// monitor knows about those.
    private var isSagging: Bool {
        guard snapshot.isInputSagging, !monitor.thermal.state.isThrottling,
              !snapshot.isChargingOnHold else { return false }
        return (snapshot.percent ?? 0) <= 90
    }

    private var sagBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.mwDanger)
            Text("Voltage drop detected. Try another cable.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mwDanger.opacity(0.12))
        )
    }

    /// Deliberately coarse bands. The number includes the charger's output impedance
    /// and both sets of contacts, so a precise threshold would be false precision —
    /// what is being separated here is "unremarkable" from "worth swapping the cable".
    private func resistanceTint(_ milliohms: Double) -> Color {
        switch milliohms {
        case ..<200: .mwBattery
        case ..<400: .primary
        default: .mwLoss
        }
    }

    private func resistanceVerdict(_ milliohms: Double) -> LocalizedStringResource {
        switch milliohms {
        case ..<200:
            "Low resistance"
        case ..<400:
            "Moderate resistance"
        default:
            "High resistance; try another cable"
        }
    }
}

/// One row of the live-rails table. A named type rather than a tuple so the label
/// can be a `LocalizedStringResource` and the row can carry its own identity.
private struct RailRow: Identifiable {
    let id: String
    let name: LocalizedStringResource
    let voltage: Double?
    let current: Double?
    let tint: Color
}

struct ProfileRow: View {
    let profile: PDProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Color.mwAccent : Color.mwMuted.opacity(0.5))
            Text(verbatim: profile.label)
                .mwMono(size: 13, weight: isActive ? .semibold : .regular)
            Spacer()
            Text(String(format: "%.0f W", profile.watts))
                .mwReadout(size: 14, weight: .semibold)
                .foregroundStyle(isActive ? Color.mwAccent : Color.mwMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.mwAccent.opacity(0.12) : Color.mwMuted.opacity(0.06))
        )
    }
}

/// Label on the left, value on the right, hidden entirely when there is no value.
///
/// The label is a `Text` for the same reason `Panel.trailing` is: a detail row shows
/// copy on the Adapter page ("Manufacturer") and a raw IOKit key on the Raw data page
/// (`AppleRawAdapterDetails`), and only one of those may reach the string catalog.
/// Which it is, is knowable at the call site and nowhere else — hence two initialisers
/// rather than one `String` that silently took the non-localising `Text` overload and
/// opted every label out of translation.
struct DetailRow: View {
    private let label: Text
    /// Always a measured or reported value — a serial number, a wattage, a
    /// timestamp — so never translated.
    let value: String?

    /// A translated label.
    init(label: LocalizedStringResource, value: String?) {
        self.label = Text(label)
        self.value = value
    }

    /// A hardware name or dictionary key, shown exactly as the system reported it.
    init(rawLabel: String, value: String?) {
        self.label = Text(verbatim: rawLabel)
        self.value = value
    }

    /// The transport a charge arrived over. Copy, but it is a *value* rather than a
    /// label, so it is resolved to a `String` here. Two separate `String(localized:)`
    /// calls rather than one wrapped around a ternary: the extractor reads literals
    /// at the call site, not through a branch.
    static func transportName(wireless: Bool) -> String {
        wireless ? String(localized: "Wireless") : String(localized: "USB-C")
    }

    /// Nested IOKit dictionaries arrive as long multi-line strings; those get their
    /// own left-aligned block instead of being crushed into the right column.
    private var isLong: Bool {
        guard let value else { return false }
        return value.count > 34 || value.contains("\n")
    }

    var body: some View {
        if let value, !value.isEmpty {
            Group {
                if isLong {
                    VStack(alignment: .leading, spacing: 3) {
                        label
                            .font(.system(size: 13))
                            .foregroundStyle(Color.mwMuted)
                        Text(verbatim: value)
                            .mwMono(size: 11)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        label
                            .font(.system(size: 13))
                            .foregroundStyle(Color.mwMuted)
                        Spacer(minLength: 12)
                        Text(verbatim: value)
                            .mwMono(size: 12)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.mwCardStroke).frame(height: 0.5)
            }
        }
    }
}

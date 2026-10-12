import Foundation

@main
struct ChargingProtocolChecks {
    private static var checks = 0
    private struct Failure: Error { let message: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }

    private static func snapshot(_ adapter: [String: Any]?, connected: Bool = true,
                                 sensors: [HIDSensors.Reading] = []) -> PowerSnapshot {
        PowerSnapshot(registry: ["ExternalConnected": connected],
                      adapterDetails: adapter, sensors: sensors)
    }

    private static func profile(_ index: Int, _ voltage: Int, _ current: Int) -> [String: Any] {
        ["Index": index, "MaxVoltage": voltage, "MaxCurrent": current]
    }

    // The ordinary 20 W PD menu shape reported by powerd. No protocol-name,
    // PD-revision or APDO/PPS field is available in this description.
    private static var pdAdapter: [String: Any] {
        ["IsWireless": false, "Watts": 20, "Voltage": 9000, "Current": 2220,
         "UsbHvcHvcIndex": 1,
         "UsbHvcMenu": [profile(0, 5000, 3000), profile(1, 9000, 2220)]]
    }

    static func main() throws {
        let pd = snapshot(pdAdapter)
        try expect(pd.chargingProtocol == .usbPDInferred, "An explicit valid PD menu selection can be inferred")
        try expect(pd.selectedAdapterProfile?.index == 1, "Use the active index, not the largest wattage")
        try expect(pd.negotiatedProfile?.voltageMillivolts == 9000, "Keep the selected contract visible")
        try expect(snapshot(pdAdapter, connected: false).chargingProtocol == .notConnected,
                   "Unplugging suppresses a cached adapter description")
        try expect(PowerSnapshot().chargingProtocol == .notConnected, "No source is not an identified protocol")

        var adapter = pdAdapter
        adapter["UsbHvcHvcIndex"] = 0
        try expect(snapshot(adapter).chargingProtocol == .usbPDInferred, "PD can negotiate 5 V too")
        try expect(snapshot(adapter).negotiatedProfile?.voltageMillivolts == 5000, "Honor a 5 V selection")

        adapter = pdAdapter
        adapter["UsbHvcHvcIndex"] = nil
        let menuOnly = snapshot(adapter)
        try expect(menuOnly.chargingProtocol == .unidentifiedWired, "Advertised capabilities do not establish current use")
        try expect(menuOnly.adapterProfiles.count == 2, "Unselected profiles remain visible")
        try expect(menuOnly.negotiatedProfile?.index == -1, "A voltage/current ceiling still works as a fallback")
        try expect(menuOnly.selectedAdapterProfile == nil, "The fallback is never evidence of protocol use")

        for active: Any in [255, -1, 7, true, 1.5, "1", UInt64.max, Double.infinity] {
            adapter = pdAdapter
            adapter["UsbHvcHvcIndex"] = active
            try expect(snapshot(adapter).chargingProtocol == .unidentifiedWired,
                       "Invalid, missing or sentinel selections must not identify PD: \(active)")
        }

        for voltage in [5000, 9000, 12000, 20000] {
            let electricalOnly = snapshot(["Voltage": voltage, "Current": 3000, "Watts": 60,
                                           "Source": 1, "Name": "USB-PD PPS QC charger"])
            try expect(electricalOnly.chargingProtocol == .unidentifiedWired,
                       "Voltage, watts, names and undocumented Source values do not identify a protocol")
        }
        try expect(snapshot(nil).chargingProtocol == .unidentifiedWired, "Connected without adapter data remains unknown")
        try expect(snapshot(["UsbHvcMenu": "unavailable"]).adapterProfiles.isEmpty, "Malformed menus are unavailable")

        adapter = pdAdapter
        adapter["IsWireless"] = true
        try expect(snapshot(adapter).chargingProtocol == .unidentifiedWireless,
                   "A pad's upstream PD adapter must not identify the wireless link as PD")
        let coil = HIDSensors.Reading(name: "Charger VQ1u", kind: .voltage, value: 6.8, index: 0)
        try expect(snapshot(pdAdapter, sensors: [coil]).chargingProtocol == .unidentifiedWireless,
                   "A wireless input rail also takes precedence over PD information")
        try expect(snapshot(["IsWireless": true, "Name": "MagSafe", "Watts": 25]).chargingProtocol == .unidentifiedWireless,
                   "A marketing name and power tier cannot establish the wireless standard")

        let badProfiles: [[String: Any]] = [
            ["MaxVoltage": 5000, "MaxCurrent": 3000],
            ["Index": true, "MaxVoltage": 5000, "MaxCurrent": 3000],
            ["Index": 0.5, "MaxVoltage": 5000, "MaxCurrent": 3000],
            profile(255, 5000, 3000), profile(-1, 5000, 3000),
            profile(0, 0, 3000), profile(0, -5000, 3000), profile(0, 5000, 0),
            ["Index": 0, "MaxVoltage": true, "MaxCurrent": 3000],
            ["Index": 0, "MaxVoltage": 5000.5, "MaxCurrent": 3000],
            ["Index": 0, "MaxVoltage": UInt64.max, "MaxCurrent": 3000]
        ]
        for bad in badProfiles {
            let invalid = snapshot(["UsbHvcHvcIndex": 0, "UsbHvcMenu": [bad]])
            try expect(invalid.adapterProfiles.isEmpty, "Incomplete or invalid entries are not power profiles")
            try expect(invalid.chargingProtocol == .unidentifiedWired, "Invalid entries cannot prove PD")
        }
        let ambiguous = snapshot(["UsbHvcHvcIndex": 0,
                                  "UsbHvcMenu": [profile(0, 5000, 3000), profile(0, 9000, 2220),
                                                 profile(1, 12000, 1500)]])
        try expect(ambiguous.adapterProfiles.map(\.index) == [1], "Discard ambiguous duplicate IDs, keep independent valid entries")
        try expect(ambiguous.chargingProtocol == .unidentifiedWired, "An ambiguous active index cannot identify PD")

        let registryPD = PowerSnapshot(registry: ["ExternalConnected": true, "AdapterDetails": pdAdapter])
        try expect(registryPD.chargingProtocol == .usbPDInferred, "Registry and powerd adapter sources follow the same rules")
        let powerdPD = PowerSnapshot(powerSource: ["Power Source State": "AC Power"], adapterDetails: pdAdapter)
        try expect(powerdPD.chargingProtocol == .usbPDInferred, "Powerd connectivity works when the registry is filtered")
        print("PASS: \(checks) charging protocol checks.")
    }
}

import Foundation

@main
struct SensorReadingChecks {
    private static var checks = 0
    private struct Failure: Error { let message: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }

    private static func temperature(_ name: String, _ value: Double, _ index: Int) -> HIDSensors.Reading {
        HIDSensors.Reading(name: name, kind: .temperature, value: value, index: index)
    }

    private static func power(at time: TimeInterval, cellAmps: Double) -> PowerSnapshot {
        PowerSnapshot(date: Date(timeIntervalSince1970: time),
                      registry: ["ExternalConnected": true, "Voltage": 4000,
                                 "InstantAmperage": Int(cellAmps * 1000)],
                      adapterDetails: ["Voltage": 9000, "Current": 2000, "Watts": 18],
                      sensors: [HIDSensors.Reading(name: "Charger VQ0u", kind: .voltage, value: 8, index: 0),
                                HIDSensors.Reading(name: "Charger IQ0u", kind: .current, value: 1, index: 1)])
    }

    static func main() throws {
        let batteries = [30.0, 32, 70, 31].enumerated().map {
            temperature("gas gauge battery", $0.element, $0.offset)
        }
        let battery = PowerSnapshot(sensors: batteries)
        try expect(battery.batteryTemperature == 31.5, "A high duplicate sensor must not dominate battery temperature")
        try expect(battery.temperaturesByZone.first { $0.zone == .battery }?.representative == 31.5,
                   "The battery summary and zone header must agree")
        try expect(battery.hottestSensor?.value == 70, "The high source remains visible as its own hottest reading")
        try expect(battery.batteryTemperatureReadings.count == 4, "Keep every indexed source for inspection")
        try expect(Set(battery.batteryTemperatureReadings.map(\.id)).count == 4, "Duplicate names retain unique IDs")
        try expect(PowerSnapshot(sensors: Array(batteries.prefix(3))).batteryTemperature == 32,
                   "Odd-count median rejects a high outlier")
        try expect(PowerSnapshot(registry: ["Temperature": 2800], sensors: batteries).batteryTemperature == 28,
                   "A valid registry temperature keeps precedence")
        try expect(PowerSnapshot().batteryTemperature == nil, "Missing temperature stays unavailable")

        let raw = [temperature("Charger TQ0d", 97.5, 0), temperature("Charger TQ0j", 29, 1),
                   temperature("Charger TQ2d", 98, 2), temperature("Charger TQ2j", 30, 3),
                   temperature("SoC tdev", -20, 4), temperature("camera die", 0, 5),
                   temperature("gas gauge battery", 31, 6), temperature("TV1s", -9199, 7)]
        let filtered = PowerSnapshot(registry: ["ExternalConnected": true], sensors: raw)
        try expect(filtered.sensors.count == 8, "Excluded readings remain in raw data")
        try expect(filtered.temperatureWarnings.count == 5, "Every rejected source has a diagnostic")
        try expect(filtered.temperatures.count == 3, "Only plausible live readings feed derived temperatures")
        try expect(filtered.hottestSensor?.value == 31, "Sentinels cannot become the hottest component")
        try expect(filtered.chargerTemperature == 30, "Charge IC falls back to the valid junction")

        let hotRail = [temperature("Charger TQ2d", 95, 0), temperature("Charger TQ2j", 65, 1)]
        let hot = PowerSnapshot(registry: ["ExternalConnected": true], sensors: hotRail)
        try expect(hot.chargerTemperature == 95, "A matching warm junction preserves a genuinely hot die")
        try expect(hot.temperatureWarnings.isEmpty, "Corroborated heat is not excluded")
        let wrongRail = PowerSnapshot(registry: ["ExternalConnected": true], sensors: [
            hotRail[0], temperature("Charger TQ0j", 65, 1)])
        try expect(wrongRail.chargerTemperature == 65, "Another rail's junction cannot validate a high die")
        try expect(PowerSnapshot(sensors: hotRail).chargerTemperature == 65, "A high unplugged die remains excluded")
        try expect(PowerSnapshot(sensors: [temperature("camera die", 0.1, 0)]).hottestSensor?.value == 0.1,
                   "The zero sentinel rule must not suppress nearby real temperatures")

        let partial = power(at: 0, cellAmps: 4)
        try expect(partial.inputWatts == nil && partial.partialInputWatts == 8, "Partial input must not be reported as total power")
        try expect(partial.batteryWatts == 16, "The independently measured cell power remains available")
        try expect(partial.chargePathEfficiency == nil && partial.unaccountedPowerWatts == nil,
                   "Partial input cannot produce efficiency or loss")
        try expect(partial.adapterUtilisation == nil && partial.inputCurrentUtilisation == nil,
                   "Partial input cannot produce adapter utilisation")
        try expect(partial.inputPathMilliohms == nil && PathResistanceMeter.Fingerprint(partial) == nil,
                   "Both path-resistance calculations reject incomplete input")
        try expect(ChargeReading(partial).source == .intoBattery && ChargeReading(partial).watts == 16,
                   "Widgets and activities fall back to cell power")

        let energy = EnergyAccumulator()
        energy.add(partial)
        energy.add(power(at: 1, cellAmps: 4))
        try expect(energy.totals.inputMeasuredSeconds == 0 && energy.totals.measuredInputWattHours == nil,
                   "Partial input contributes no delivered energy")
        try expect(abs(energy.totals.batteryWattHours - 16.0 / 3600) < 0.000001,
                   "Valid cell readings still integrate normally")
        let valid = power(at: 2, cellAmps: 1.5)
        try expect(valid.inputWatts == 8 && valid.partialInputWatts == nil, "Ordinary readings stay available")
        try expect(valid.chargePathEfficiency == 75 && PathResistanceMeter.Fingerprint(valid) != nil,
                   "Ordinary readings retain derived calculations")
        try expect(power(at: 3, cellAmps: 2.25).inputWatts == 8,
                   "A small difference between sensors does not invalidate input")
        print("PASS: \(checks) sensor reading checks; synthetic sensor data only.")
    }
}

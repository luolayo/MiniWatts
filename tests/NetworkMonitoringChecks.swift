import Foundation

@main
struct NetworkMonitoringChecks {
    private static var checks = 0

    static func main() throws {
        try baselineAndElapsedTime()
        try interfaceAndLifecycleChanges()
        try resetsAndUnavailableReadings()
        try formattingAndInterfaceSelection()
        try activityPayloadCompatibility()
        let interfaces = NetworkMonitor.interfaceCounters()?.count ?? 0
        print("PASS: \(checks) network/activity checks; local probe returned \(interfaces) physical interfaces.")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }

    private static func counter(_ received: UInt64, _ sent: UInt64) -> NetworkInterfaceCounter {
        NetworkInterfaceCounter(received: received, sent: sent)
    }

    private static func baselineAndElapsedTime() throws {
        var meter = NetworkRateAccumulator()
        try expect(meter.sample(["en0": counter(1_000, 500)], at: 10) == nil,
                   "First sample must be a baseline, not a burst since boot")
        let sample = meter.sample(["en0": counter(7_000, 3_500)], at: 12)
        try expect(sample?.download == 3_000, "Use actual elapsed time for download")
        try expect(sample?.upload == 1_500, "Keep upload independent of download")
        let idle = meter.sample(["en0": counter(7_000, 3_500)], at: 13)
        try expect(idle?.download == 0 && idle?.upload == 0, "Measured inactivity is zero")
    }

    private static func interfaceAndLifecycleChanges() throws {
        var meter = NetworkRateAccumulator()
        _ = meter.sample(["en0": counter(500, 100)], at: 1)
        try expect(meter.sample(["pdp_ip0": counter(900_000, 900)], at: 2) == nil,
                   "A Wi-Fi/cellular switch must not mix counters")
        let cellular = meter.sample(["pdp_ip0": counter(902_000, 1_900)], at: 3)
        try expect(cellular?.download == 2_000 && cellular?.upload == 1_000, "New interface recovers")
        try expect(meter.sample(["pdp_ip0": counter(903_000, 2_000), "en0": counter(20_000, 100)], at: 4) == nil,
                   "An additional physical interface needs a new baseline")
        let combined = meter.sample(["pdp_ip0": counter(904_000, 2_100), "en0": counter(23_000, 400)], at: 5)
        try expect(combined?.download == 4_000 && combined?.upload == 400, "Aggregate physical interfaces once")
        meter.reset()
        try expect(meter.sample(["en0": counter(2_000_000, 80_000)], at: 50) == nil, "Resume needs a baseline")
        _ = meter.sample(["en0": counter(2_001_000, 81_000)], at: 51)
        try expect(meter.sample(["en0": counter(8_000_000, 90_000)], at: 100) == nil,
                   "Long gaps are not presented as instantaneous rates")
    }

    private static func resetsAndUnavailableReadings() throws {
        var meter = NetworkRateAccumulator()
        _ = meter.sample(["en0": counter(UInt64(UInt32.max) - 100, 10_000)], at: 1)
        try expect(meter.sample(["en0": counter(500, 10_100)], at: 2) == nil, "Counter wrap never becomes a spike")
        try expect(meter.sample(["en0": counter(1_500, 10_200)], at: 3)?.download == 1_000, "Recover after wrap")
        try expect(meter.sample(["en0": counter(1_600, 5)], at: 4) == nil, "Reset of only the upload counter is detected")
        try expect(meter.sample(nil, at: 5) == nil, "Read failure is unavailable, not zero")
        try expect(meter.sample(["en0": counter(9_000, 100)], at: 6) == nil, "Read failure discards the old baseline")
        try expect(meter.sample([:], at: 7) == nil, "Missing interfaces discard the baseline")
        _ = meter.sample(["en0": counter(10_000, 200)], at: 8)
        try expect(meter.sample(["en0": counter(10_100, 300)], at: 8) == nil, "Zero interval cannot divide by zero")
        try expect(meter.sample(["en0": counter(10_200, 400)], at: 7) == nil, "Time cannot run backwards")
        try expect(meter.sample(["en0": counter(10_300, 500)], at: .nan) == nil, "Invalid clock resets the baseline")
    }

    private static func formattingAndInterfaceSelection() throws {
        try expect(NetworkRateText(nil).combined == "—", "Missing rates have no unit or fake zero")
        try expect(NetworkRateText(.infinity).combined == "—", "Nonfinite rate is not displayed")
        try expect(NetworkRateText(-1).combined == "—", "Negative rate is not displayed")
        try expect(NetworkRateText(0).combined == "0 B/s", "Idle rate is still a real reading")
        try expect(NetworkRateText(999).unit == "B/s", "Bytes threshold")
        try expect(NetworkRateText(1_000).unit == "KB/s", "Decimal KB threshold")
        try expect(NetworkRateText(1_000_000).unit == "MB/s", "Decimal MB threshold")
        try expect(NetworkRateText(1_000_000_000).unit == "GB/s", "Large rates remain compact")
        for name in ["en0", "en7", "pdp_ip0", "pdp_ip12"] {
            try expect(NetworkMonitor.isTrafficInterface(name), "Include physical interface \(name)")
        }
        for name in ["lo0", "utun0", "ipsec0", "awdl0", "llw0", "bridge0", "en", "pdp_ip", "en0:1"] {
            try expect(!NetworkMonitor.isTrafficInterface(name), "Exclude duplicate/virtual interface \(name)")
        }
    }

    private static func activityPayloadCompatibility() throws {
        let state = ChargeActivityContentState(
            reading: ChargeReading(date: Date(timeIntervalSince1970: 1_000), percent: 65,
                                   externalConnected: true, isCharging: true,
                                   watts: 18.6, source: .charger, batteryTemperature: 36.2),
            socTemperature: 42.1, hottestTemperature: 42.1, hottestSensorName: "test sensor",
            selectedMetric: .downloadRate,
            network: NetworkReading(connection: .wifi, downloadBytesPerSecond: 3_240_000,
                                    uploadBytesPerSecond: 128_000), isPaused: false,
            isSnapshot: true,
            traffic: TrafficActivityReading(receivedBytes: 50_000_000, targetBytes: 100_000_000,
                                            bytesPerSecond: 3_240_000, activeDownloads: 64,
                                            downloadLimit: 64))
        let data = try JSONEncoder().encode(state)
        try expect(data.count < 3_500, "Activity state leaves room for attributes under the 4 KB limit")
        let decoded = try JSONDecoder().decode(ChargeActivityContentState.self, from: data)
        try expect(decoded == state, "Network rates survive cross-process Codable transport")
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "network")
        old.removeValue(forKey: "isPaused")
        old.removeValue(forKey: "isSnapshot")
        old.removeValue(forKey: "traffic")
        old["selectedMetric"] = "chargingPower"
        let oldData = try JSONSerialization.data(withJSONObject: old)
        let legacy = try JSONDecoder().decode(ChargeActivityContentState.self, from: oldData)
        try expect(legacy.network == nil && legacy.isPaused == nil, "Existing activities still decode after upgrade")
        try expect(legacy.reading.percent == 65, "Existing battery data is preserved")
        try expect(legacy.traffic == nil && legacy.isSnapshot == nil, "Older activities decode without task progress or snapshot flags")
        try expect(decoded.traffic?.fraction == 0.5 && decoded.isSnapshot == true, "Progress and one-time readings cross the process boundary")
        var paused = state
        paused.isPaused = true
        try expect(paused != state, "Pause is an explicit activity state change")
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

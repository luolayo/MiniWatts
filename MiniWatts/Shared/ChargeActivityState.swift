import Foundation

nonisolated enum LiveActivityMetric: String, Codable, Hashable, CaseIterable, Identifiable {
    case chargingPower
    case socTemperature
    case batteryTemperature
    case hottestTemperature
    case downloadRate
    case uploadRate

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .chargingPower: "Charging power"
        case .socTemperature: "SoC temperature"
        case .batteryTemperature: "Battery temperature"
        case .hottestTemperature: "Hottest component"
        case .downloadRate: "Download speed"
        case .uploadRate: "Upload speed"
        }
    }

    var isNetwork: Bool { self == .downloadRate || self == .uploadRate }
}

/// Shared, Codable state for the app and extension. Optional additions preserve
/// decoding of activities that were created before network monitoring was added.
nonisolated struct ChargeActivityContentState: Codable, Hashable {
    var reading: ChargeReading
    var socTemperature: Double?
    var hottestTemperature: Double?
    var hottestSensorName: String?
    var selectedMetric: LiveActivityMetric
    // Optional fields let activities created by earlier app versions decode.
    var network: NetworkReading? = nil
    var isPaused: Bool? = nil
    var isSnapshot: Bool? = nil
    var traffic: TrafficActivityReading? = nil

    var date: Date { reading.date }
    var batteryTemperature: Double? { reading.batteryTemperature }
}

nonisolated struct TrafficActivityReading: Codable, Hashable, Sendable {
    var receivedBytes: Int64
    var targetBytes: Int64
    var bytesPerSecond: Double
    var activeDownloads: Int
    var downloadLimit: Int

    var fraction: Double {
        guard targetBytes > 0 else { return 0 }
        return min(max(Double(receivedBytes) / Double(targetBytes), 0), 1)
    }

    var summary: String {
        let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .decimal)
        let target = ByteCountFormatter.string(fromByteCount: targetBytes, countStyle: .decimal)
        return "\(received) / \(target)"
    }
}

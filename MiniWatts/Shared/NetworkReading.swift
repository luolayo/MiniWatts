import Foundation

nonisolated enum NetworkConnection: String, Codable, Hashable, Sendable {
    case unknown, offline, wifi, cellular, wired, other

    var title: LocalizedStringResource {
        switch self {
        case .unknown: "Detecting network"
        case .offline: "Offline"
        case .wifi: "Wi-Fi"
        case .cellular: "Cellular"
        case .wired: "Ethernet"
        case .other: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .unknown, .other: "network"
        case .offline: "wifi.slash"
        case .wifi: "wifi"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .wired: "cable.connector"
        }
    }
}

/// Interface traffic, not a bandwidth test or a per-app traffic breakdown.
/// Optional rates distinguish a missing baseline/probe from a measured zero.
nonisolated struct NetworkReading: Codable, Hashable, Sendable {
    var connection: NetworkConnection = .unknown
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?

    var hasRates: Bool {
        downloadBytesPerSecond != nil && uploadBytesPerSecond != nil
    }
}

nonisolated struct NetworkRateText: Equatable {
    let value: String
    let unit: String

    init(_ bytesPerSecond: Double?) {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
            value = "—"
            unit = ""
            return
        }
        // Decimal units: 1 MB/s = 1,000,000 bytes per second.
        let divisor: Double
        if bytesPerSecond >= 1_000_000_000 {
            divisor = 1_000_000_000
            unit = "GB/s"
        } else if bytesPerSecond >= 1_000_000 {
            divisor = 1_000_000
            unit = "MB/s"
        } else if bytesPerSecond >= 1_000 {
            divisor = 1_000
            unit = "KB/s"
        } else {
            divisor = 1
            unit = "B/s"
        }
        let scaled = bytesPerSecond / divisor
        let precision = divisor == 1 || scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
        value = scaled.formatted(.number.precision(.fractionLength(precision)))
    }

    var combined: String { unit.isEmpty ? value : "\(value) \(unit)" }
}

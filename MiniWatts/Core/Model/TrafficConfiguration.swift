import Foundation

nonisolated enum TrafficDataUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case mb = "MB", gb = "GB"
    var id: Self { self }
    var bytes: Int64 { self == .mb ? 1_000_000 : 1_000_000_000 }
}

nonisolated struct TrafficConfiguration: Codable, Equatable, Sendable {
    var link = ""
    var amount = "100"
    var unit: TrafficDataUnit = .mb
    var durationMinutes = 0
    var concurrentDownloads = 4
    var redirectPolicy: TrafficRedirectPolicy = .sameOrigin
    var allowsBackground = true

    func byteCount() throws -> Int64 {
        let text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty, text.allSatisfy({ "0123456789.".contains($0) }),
              text.filter({ $0 == "." }).count <= 1,
              let quantity = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              quantity > 0 else { throw TrafficFailure.invalidLimit }
        var bytes = quantity * Decimal(unit.bytes)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &bytes, 0, .down)
        guard bytes == rounded, bytes >= 1, bytes <= Decimal(Int64.max) else {
            throw TrafficFailure.invalidLimit
        }
        return NSDecimalNumber(decimal: bytes).int64Value
    }

    func plan(remainingBytes: Int64? = nil, concurrentDownloads: Int? = nil) throws -> TrafficDownloadPlan {
        guard durationMinutes >= 0 else { throw TrafficFailure.invalidLimit }
        return try TrafficDownloadPlan(link: link, targetBytes: remainingBytes ?? byteCount(),
                                       durationLimit: durationMinutes == 0 ? nil : Double(durationMinutes) * 60,
                                       concurrentDownloads: concurrentDownloads ?? self.concurrentDownloads,
                                       redirectPolicy: redirectPolicy)
    }
}

nonisolated struct SavedTrafficConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var configuration: TrafficConfiguration
}

nonisolated struct TrafficCheckpoint: Codable, Sendable {
    var configuration: TrafficConfiguration
    var receivedBytes: Int64
    var targetBytes: Int64
}

nonisolated struct TrafficSavedSettings: Codable, Sendable {
    var profiles: [SavedTrafficConfiguration] = []
    var selectedID: UUID?
    var checkpoint: TrafficCheckpoint?
}

@MainActor
protocol TrafficSettingsPersistence {
    func load() throws -> TrafficSavedSettings
    func save(_ settings: TrafficSavedSettings) throws
}

/// Explicitly saved profiles remain in the app's private preferences container.
/// No URLs or query tokens are included in logs or shared widget data.
@MainActor
final class TrafficSettingsStore: TrafficSettingsPersistence {
    private let defaults: UserDefaults
    private let key = "traffic.saved-settings.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> TrafficSavedSettings {
        guard let data = defaults.data(forKey: key) else { return TrafficSavedSettings() }
        return try JSONDecoder().decode(TrafficSavedSettings.self, from: data)
    }
    func save(_ settings: TrafficSavedSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(settings)
        guard defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
    }
}

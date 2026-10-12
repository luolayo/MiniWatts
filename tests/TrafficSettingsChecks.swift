import Foundation

@MainActor
private final class ForegroundOnly: TrafficBackgroundExecution {
    var isSupported: Bool { false }
    func request(kind: BackgroundWorkKind, totalUnits: Int64, onReady: @escaping (Bool) -> Void, onExpiration: @escaping () -> Void) { onReady(false) }
    func update(completedUnits: Int64, subtitle: String) {}
    func finish(success: Bool) {}
}
nonisolated private final class SettingsDownload: TrafficDownloading, @unchecked Sendable {
    let observe: @Sendable (TrafficProgress) -> Void
    init(observe: @escaping @Sendable (TrafficProgress) -> Void) { self.observe = observe }
    func start() {}
    func cancel(reason: TrafficStopReason) {}
}
@MainActor
private final class SettingsFactory {
    var plans: [TrafficDownloadPlan] = []
    var downloads: [SettingsDownload] = []
    func create(_ plan: TrafficDownloadPlan, _ observe: @escaping @Sendable (TrafficProgress) -> Void) -> any TrafficDownloading {
        plans.append(plan)
        let item = SettingsDownload(observe: observe)
        downloads.append(item)
        return item
    }
}
@MainActor
private final class CountingSettingsStore: TrafficSettingsPersistence {
    var document = TrafficSavedSettings()
    var saves = 0
    var time: TimeInterval = 100
    func load() throws -> TrafficSavedSettings { document }
    func save(_ settings: TrafficSavedSettings) throws { document = settings; saves += 1 }
}
@main
struct TrafficSettingsChecks {
    private static var checks = 0
    private struct Failure: Error { var message: String }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if !(try condition()) { throw Failure(message: message) }
    }
    static func main() async throws {
        var config = TrafficConfiguration(link: "https://example.invalid/file?token=private-test", amount: "400", unit: .gb)
        let large = try config.plan()
        try expect(large.targetBytes == 400_000_000_000, "400 GB is accepted without the previous 10 GB cap")
        try expect(large.durationLimit == nil, "Large downloads do not inherit a ten-minute cutoff")
        config.amount = "400000"; config.unit = .mb
        try expect(try config.byteCount() == large.targetBytes, "MB and GB conversions agree")
        config.amount = "1.5"; config.unit = .gb
        try expect(try config.byteCount() == 1_500_000_000, "Fractional GB stays precise")
        config.amount = "0.125"; config.unit = .mb
        try expect(try config.byteCount() == 125_000, "Fractional MB stays precise")
        config.unit = .gb; config.amount = "9223372036.854775807"
        try expect(try config.byteCount() == Int64.max, "Conversion preserves the Int64 boundary without floating-point rounding")
        for text in ["0", "-1", "NaN", "1e99", "1.2.3", "9223372036.854775808"] {
            config.amount = text
            do { _ = try config.byteCount(); throw Failure(message: "Invalid amount accepted: \(text)") }
            catch is TrafficFailure { checks += 1 }
        }
        let domain = "MiniWatts.TrafficSettingsChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let factory = SettingsFactory()
        let consumer = TrafficConsumer(background: ForegroundOnly(), settingsStore: TrafficSettingsStore(defaults: defaults), engineFactory: factory.create)
        try expect(consumer.profiles.isEmpty, "No built-in provider profiles")
        consumer.profileName = "My 400 GB task"
        consumer.configuration = TrafficConfiguration(link: "https://example.invalid/file?token=private-test", amount: "400", unit: .gb, concurrentDownloads: 64, allowsBackground: false)
        consumer.saveProfile()
        let firstID = consumer.selectedProfileID
        try expect(consumer.profiles.count == 1 && firstID != nil, "Save creates a selectable named profile")
        consumer.profileName = "Renamed task"; consumer.saveProfile()
        try expect(consumer.profiles.count == 1 && consumer.selectedProfileID == firstID, "Saving edits updates the profile rather than duplicating it")
        consumer.newConfiguration(); consumer.profileName = "Small task"
        consumer.link = "https://example.invalid/small"; consumer.configuration.amount = "5"; consumer.saveProfile()
        try expect(consumer.profiles.count == 2, "Multiple custom profiles can be stored")
        consumer.selectProfile(firstID)
        let reloadFactory = SettingsFactory()
        let restored = TrafficConsumer(background: ForegroundOnly(), settingsStore: TrafficSettingsStore(defaults: UserDefaults(suiteName: domain)!), engineFactory: reloadFactory.create)
        try expect(restored.profiles.count == 2 && restored.selectedProfileID == firstID, "Profiles and selection survive a new controller/store")
        try expect(restored.configuration.amount == "400" && restored.configuration.unit == .gb && restored.configuration.concurrentDownloads == 64, "Restore the complete download settings")
        try expect(restored.link.contains("token=private-test"), "Saved direct links are restored without losing query parameters")
        restored.start()
        reloadFactory.downloads[0].observe(TrafficProgress(sequence: 1, receivedBytes: 125_000_000_000, stopReason: .user))
        try await Task.sleep(for: .milliseconds(20))
        let resumeFactory = SettingsFactory()
        let resumed = TrafficConsumer(background: ForegroundOnly(), settingsStore: TrafficSettingsStore(defaults: UserDefaults(suiteName: domain)!), engineFactory: resumeFactory.create)
        try expect(resumed.remainingSavedBytes == 275_000_000_000, "Saved progress survives restart")
        resumed.start(resuming: true)
        try expect(resumeFactory.plans[0].targetBytes == 275_000_000_000, "Resume requests only the remaining amount")
        resumeFactory.downloads[0].observe(TrafficProgress(sequence: 1, receivedBytes: 2_000_000_000, stopReason: .user))
        try await Task.sleep(for: .milliseconds(20))
        try expect(resumed.progress.receivedBytes == 127_000_000_000 && resumed.activeTargetBytes == 400_000_000_000, "Resume totals include the saved offset")
        resumed.deleteSelectedProfile()
        let afterDelete = try TrafficSettingsStore(defaults: UserDefaults(suiteName: domain)!).load()
        try expect(afterDelete.profiles.count == 1 && afterDelete.checkpoint == nil, "Deleting the saved task also removes its checkpoint")
        let counting = CountingSettingsStore()
        let countingFactory = SettingsFactory()
        let lowWrites = TrafficConsumer(background: ForegroundOnly(), settingsStore: counting,
                                        uptime: { counting.time }, engineFactory: countingFactory.create)
        lowWrites.configuration = TrafficConfiguration(link: "https://example.invalid/data", amount: "10", unit: .gb, allowsBackground: false)
        lowWrites.saveProfile()
        lowWrites.start()
        let initialSaves = counting.saves
        for tick in 1...59 {
            counting.time = 100 + Double(tick)
            countingFactory.downloads[0].observe(TrafficProgress(sequence: tick, receivedBytes: Int64(tick) * 1_000_000))
            try await Task.sleep(for: .milliseconds(2))
        }
        try expect(counting.saves == initialSaves, "No per-second or five-second checkpoint writes")
        counting.time = 160
        countingFactory.downloads[0].observe(TrafficProgress(sequence: 60, receivedBytes: 3_000_000_000))
        try await Task.sleep(for: .milliseconds(20))
        try expect(counting.saves == initialSaves + 1 && counting.document.checkpoint?.receivedBytes == 3_000_000_000,
                   "Only a small checkpoint is saved after one minute, preserving Int64 totals past 2 GB")
        counting.time = 161
        countingFactory.downloads[0].observe(TrafficProgress(sequence: 61, receivedBytes: 3_500_000_000,
                                                             stopReason: .failed(.networkCode(-1005))))
        try await Task.sleep(for: .milliseconds(20))
        try expect(counting.saves == initialSaves + 2 && counting.document.checkpoint?.receivedBytes == 3_500_000_000,
                   "Stopping saves the latest progress without waiting for the minute")
        let afterFailure = TrafficConsumer(background: ForegroundOnly(), settingsStore: counting, engineFactory: countingFactory.create)
        try expect(afterFailure.remainingSavedBytes == 6_500_000_000 && !afterFailure.isRunning,
                   "A failed large run can resume after relaunch without automatically starting")
        let maximumFactory = SettingsFactory()
        let maximum = TrafficConsumer(background: ForegroundOnly(), settingsStore: CountingSettingsStore(),
                                      engineFactory: maximumFactory.create)
        maximum.configuration = TrafficConfiguration(link: "https://example.invalid/large-file",
                                                      amount: "100", concurrentDownloads: 0,
                                                      allowsBackground: false)
        maximum.start(maximumSpeed: true)
        try expect(maximumFactory.plans.count == 1 && maximumFactory.plans[0].concurrentDownloads == 64,
                   "One-click maximum uses the full pool without requiring a valid manual thread count")
        try expect(maximum.activeDownloadLimit == 64 && maximum.configuration.concurrentDownloads == 0,
                   "Maximum mode reports its active limit without changing saved manual settings")
        maximumFactory.downloads[0].observe(TrafficProgress(sequence: 1, stopReason: .user))
        try await Task.sleep(for: .milliseconds(20))
        try expect(!maximum.isRunning, "Maximum mode follows the normal completion lifecycle")
        print("PASS: \(checks) saved settings and large-target checks; no external downloads.")
    }
}

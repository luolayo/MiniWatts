import Foundation

@MainActor
private final class BackgroundStub: TrafficBackgroundExecution {
    var isSupported = true
    var ready: [(Bool) -> Void] = []
    var expired: [() -> Void] = []
    var kinds: [BackgroundWorkKind] = []
    var completions: [Bool] = []
    var updates: [(units: Int64, subtitle: String)] = []
    func request(kind: BackgroundWorkKind, totalUnits: Int64, onReady: @escaping (Bool) -> Void, onExpiration: @escaping () -> Void) {
        kinds.append(kind); ready.append(onReady); expired.append(onExpiration)
    }
    func update(completedUnits: Int64, subtitle: String) { updates.append((completedUnits, subtitle)) }
    func finish(success: Bool) { completions.append(success) }
}

nonisolated private final class DownloadStub: TrafficDownloading, @unchecked Sendable {
    let observer: @Sendable (TrafficProgress) -> Void
    private let lock = NSLock()
    private var starts = 0
    private var cancellations: [TrafficStopReason] = []
    init(observer: @escaping @Sendable (TrafficProgress) -> Void) { self.observer = observer }
    func start() { lock.lock(); defer { lock.unlock() }; starts += 1 }
    func cancel(reason: TrafficStopReason) { lock.lock(); defer { lock.unlock() }; cancellations.append(reason) }
    func canceled() -> [TrafficStopReason] { lock.lock(); defer { lock.unlock() }; return cancellations }
    func startCount() -> Int { lock.lock(); defer { lock.unlock() }; return starts }
    func emit(sequence: Int, reason: TrafficStopReason? = nil) {
        observer(TrafficProgress(sequence: sequence,
                                 receivedBytes: reason == .targetReached ? 100_000_000 : 1_000,
                                 bytesPerSecond: 500,
                                 stopReason: reason))
    }
}

@MainActor
private final class DownloadFactory {
    var engines: [DownloadStub] = []
    func create(_ plan: TrafficDownloadPlan, observer: @escaping @Sendable (TrafficProgress) -> Void) -> any TrafficDownloading {
        let engine = DownloadStub(observer: observer)
        engines.append(engine)
        return engine
    }
}

@MainActor
private final class MemoryTrafficSettings: TrafficSettingsPersistence {
    var value = TrafficSavedSettings()
    func load() throws -> TrafficSavedSettings { value }
    func save(_ settings: TrafficSavedSettings) throws { value = settings }
}

@main
struct BackgroundLifecycleChecks {
    private static var checks = 0
    private struct Failure: Error { let message: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw Failure(message: message) }
    }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(10)) }
    private static func setup(supported: Bool = true) -> (TrafficConsumer, BackgroundStub, DownloadFactory) {
        let background = BackgroundStub()
        background.isSupported = supported
        let factory = DownloadFactory()
        let consumer = TrafficConsumer(background: background, settingsStore: MemoryTrafficSettings(), engineFactory: factory.create)
        consumer.link = "https://example.invalid/file"
        return (consumer, background, factory)
    }

    static func main() async throws {
        do {
            let (consumer, background, factory) = setup()
            var changes = 0
            consumer.onExecutionChange = { changes += 1 }
            consumer.start()
            consumer.start()
            try expect(background.ready.count == 1, "Repeated Start does not submit twice")
            try expect(factory.engines.isEmpty && consumer.backgroundState == .requesting,
                       "Do not download before the permission decision")
            try expect(!consumer.canContinueInBackground, "A pending request is not a grant")
            background.ready[0](true)
            try expect(factory.engines.count == 1 && factory.engines[0].startCount() == 1, "Grant starts exactly one pool")
            try expect(consumer.canContinueInBackground, "Only active grant permits background work")
            consumer.setForeground(false)
            try expect(factory.engines[0].canceled().isEmpty, "Approved download survives backgrounding")
            background.ready[0](false)
            try expect(consumer.backgroundState == .active, "Ignore duplicate/late permission decisions")
            factory.engines[0].emit(sequence: 2)
            await settle()
            try expect(background.updates.count == 1 && background.updates[0].units == 1_000, "Report actual bytes to system progress")
            try expect(consumer.activityReading?.receivedBytes == 1_000, "Live Activity receives current task totals")
            factory.engines[0].emit(sequence: 1)
            await settle()
            try expect(consumer.progress.sequence == 2, "Do not regress after a reordered callback")
            consumer.stop()
            try expect(factory.engines[0].canceled() == [.user], "Stop cancels the pool")
            factory.engines[0].emit(sequence: 3, reason: .user)
            await settle()
            try expect(!consumer.isRunning && !consumer.canContinueInBackground, "Stop releases background eligibility")
            try expect(background.completions.last == false && consumer.activityReading == nil, "Stop ends the system task and clears live download data")
            try expect(changes >= 3, "Runtime is notified without needing SwiftUI changes")
            factory.engines[0].emit(sequence: 4)
            await settle()
            try expect(consumer.progress.stopReason == .user, "Late progress cannot overwrite the terminal state")
        }
        do {
            let (consumer, background, factory) = setup()
            consumer.start(); background.ready[0](true); consumer.setForeground(false)
            background.expired[0]()
            try expect(!consumer.canContinueInBackground && consumer.backgroundState == .ended, "Expiration revokes runtime immediately")
            try expect(factory.engines[0].canceled() == [.backgroundEnded], "System expiration stops all network work")
            factory.engines[0].emit(sequence: 1, reason: .backgroundEnded)
            await settle()
            try expect(!consumer.isRunning && background.completions.last == false, "Expiration completes the task unsuccessfully")
        }
        do {
            let (consumer, background, factory) = setup()
            consumer.start(); background.ready[0](false)
            try expect(consumer.backgroundState == .unavailable && factory.engines.count == 1, "Denial explicitly falls back to foreground")
            background.expired[0]()
            try expect(factory.engines[0].canceled().isEmpty, "An ungranted task cannot expire a foreground fallback")
            consumer.setForeground(false)
            try expect(factory.engines[0].canceled() == [.background], "Foreground fallback stops when leaving")
        }
        do {
            let (consumer, background, factory) = setup()
            consumer.start(); consumer.setForeground(false)
            try expect(!consumer.isRunning && !consumer.isStopping && factory.engines.isEmpty, "Leaving before approval cancels a pending start")
            background.ready[0](true)
            try expect(factory.engines.isEmpty, "Late grant cannot start an abandoned download")
            consumer.setForeground(true); consumer.start()
            background.ready[0](true); background.expired[0]()
            try expect(factory.engines.isEmpty && consumer.backgroundState == .requesting, "Old callbacks cannot affect a new run")
            background.ready[1](true)
            try expect(factory.engines.count == 1 && consumer.canContinueInBackground, "New run accepts only its own grant")
        }
        do {
            let (consumer, background, factory) = setup()
            consumer.start(); consumer.stop()
            try expect(!consumer.isRunning && !consumer.isStopping, "Stop while preparing does not get stuck")
            background.ready[0](true)
            try expect(factory.engines.isEmpty, "Stopped preparation never starts networking")
        }
        do {
            let (consumer, background, factory) = setup(supported: false)
            consumer.start()
            try expect(!consumer.allowsBackground && background.ready.isEmpty && factory.engines.count == 1, "Older systems use foreground mode")
            consumer.setForeground(false)
            try expect(factory.engines[0].canceled() == [.background], "Unsupported systems stop on background")
        }
        do {
            let (consumer, background, factory) = setup()
            consumer.allowsBackground = false; consumer.start()
            try expect(background.ready.isEmpty && factory.engines.count == 1, "Explicit foreground mode never asks for runtime")
        }
        do {
            let (consumer, background, factory) = setup()
            consumer.start(); background.ready[0](true)
            factory.engines[0].emit(sequence: 1, reason: .targetReached)
            await settle()
            try expect(background.completions.last == true && !consumer.isRunning, "Only a reached target reports success")
        }
        try monitoringChecks()
        print("PASS: \(checks) background lifecycle checks; no system jobs or network requests started.")
    }
    private static func monitoringChecks() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let background = BackgroundStub()
        let session = BackgroundMonitoringSession(background: background)
        session.durationHours = 1
        var notifications = 0
        session.onExecutionChange = { notifications += 1 }
        session.start(now: base)
        try expect(background.kinds == [.monitoring], "Monitoring asks for its own runtime without a download")
        background.ready[0](true)
        session.setForeground(false)
        try expect(session.canContinueInBackground, "Standalone monitoring survives leaving the foreground")
        session.recordSample(at: base.addingTimeInterval(1), subtitle: "18 W")
        try expect(session.sampleCount == 1 && background.updates.last?.units == 1, "Real samples advance monitoring progress")
        session.recordSample(at: base.addingTimeInterval(1), subtitle: "duplicate")
        try expect(session.sampleCount == 1, "A repeated sample cannot manufacture progress")
        session.recordSample(at: base.addingTimeInterval(3_600), subtitle: "12 W")
        try expect(!session.isRunning && background.completions.last == true, "Monitoring window completes without needing a download")
        try expect(notifications >= 3, "Sampling lifecycle notifications do not need a visible SwiftUI view")
        session.setForeground(true)
        session.start(now: base)
        background.ready[1](true)
        background.expired[0]()
        try expect(session.canContinueInBackground, "Expired callbacks from a prior monitoring window are ignored")
        background.expired[1]()
        try expect(!session.canContinueInBackground && session.issue != nil, "Actual expiration stops monitoring and explains the stop")
        session.start(now: base)
        background.ready[2](false)
        try expect(!session.isRunning && session.state == .unavailable, "Denied monitoring is never advertised as live")
        session.start(now: base)
        session.setForeground(false)
        background.ready[3](true)
        try expect(!session.isRunning, "Leaving before approval cannot start a delayed monitoring session")
    }

}

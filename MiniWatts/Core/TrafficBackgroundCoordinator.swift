import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Requests runtime for one explicit, bounded download. No queued or automatic jobs.
@MainActor
final class TrafficBackgroundCoordinator: TrafficBackgroundExecution {
    var isSupported: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    private(set) var failureReason: LocalizedStringResource?
    #if os(iOS)
    private var kind: BackgroundWorkKind = .traffic
    private var identifier: String?
    private var task: BGTask?
    private var targetBytes: Int64 = 0
    private var ready: ((Bool) -> Void)?
    private var expired: (() -> Void)?
    private var timeout: Task<Void, Never>?
    private var lastTitleUpdate: TimeInterval = 0
    #endif

    func request(kind: BackgroundWorkKind, totalUnits: Int64, onReady: @escaping (Bool) -> Void,
                 onExpiration: @escaping () -> Void) {
        failureReason = nil
        #if os(iOS)
        guard #available(iOS 26.0, *), let bundleID = Bundle.main.bundleIdentifier else {
            failureReason = "Background execution requires iOS 26 or later."
            onReady(false)
            return
        }
        finish(success: false)
        let pattern = bundleID + "." + kind.rawValue + ".*"
        // Re-signing tools may change the bundle ID without updating the permitted
        // identifiers. Fall back explicitly instead of claiming background support.
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains(pattern) else {
            failureReason = "Background identifiers do not match the signed app. Preserve the bundle identifier when signing, or update the permitted background identifiers."
            onReady(false)
            return
        }
        let identifier = bundleID + "." + kind.rawValue + "." + UUID().uuidString
        self.identifier = identifier
        self.targetBytes = totalUnits
        self.kind = kind
        ready = onReady
        expired = onExpiration
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            // Registration explicitly supplies the main queue, so no BGTask object
            // is sent across an actor boundary.
            MainActor.assumeIsolated {
                guard let self else { task.setTaskCompleted(success: false); return }
                self.accept(task, identifier: identifier)
            }
        }
        guard registered else {
            failureReason = "The system refused background registration."
            unavailable(identifier); return
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.failureReason = "The system did not start background execution. Keep the app open and retry."
            self?.unavailable(identifier)
        }
        Task { [weak self] in
            do {
                try await Self.submit(identifier: identifier,
                                      title: String(localized: kind.title),
                                      subtitle: String(localized: "Requesting background execution"))
            } catch {
                if self?.identifier == identifier, self?.task == nil {
                    self?.failureReason = "The system denied background execution. Check Background App Refresh or try again later."
                }
                self?.unavailable(identifier)
            }
        }
        #else
        onReady(false)
        #endif
    }

    func update(completedUnits: Int64, subtitle: String) {
        #if os(iOS)
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = min(completedUnits, targetBytes)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTitleUpdate >= 1 else { return }
        lastTitleUpdate = now
        task.updateTitle(String(localized: kind.title), subtitle: subtitle)
        #endif
    }

    func finish(success: Bool) {
        #if os(iOS)
        timeout?.cancel()
        timeout = nil
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
        ready = nil
        expired = nil
        if let task {
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
        task = nil
        #endif
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    private func accept(_ candidate: BGTask, identifier: String) {
        guard self.identifier == identifier, let task = candidate as? BGContinuedProcessingTask,
              let ready else {
            candidate.setTaskCompleted(success: false)
            return
        }
        self.task = task
        self.ready = nil
        timeout?.cancel()
        timeout = nil
        lastTitleUpdate = 0
        task.progress.totalUnitCount = targetBytes
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.identifier == identifier else { return }
                let expired = self.expired
                self.finish(success: false)
                expired?()
            }
        }
        ready(true)
    }

    private func unavailable(_ identifier: String) {
        guard self.identifier == identifier, task == nil, let ready else { return }
        finish(success: false)
        ready(false)
    }

    @available(iOS 26.0, *)
    @concurrent
    nonisolated private static func submit(identifier: String, title: String, subtitle: String) async throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        // The iOS 27 API reports asynchronous submission errors; construct the
        // request here so it never crosses out of a main-actor-owned object.
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
            return
        }
        #endif
        try BGTaskScheduler.shared.submit(request)
    }
    #endif
}

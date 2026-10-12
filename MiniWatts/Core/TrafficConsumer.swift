import Foundation
import Observation

@Observable
final class TrafficConsumer {
    typealias EngineFactory = (TrafficDownloadPlan, @escaping @Sendable (TrafficProgress) -> Void) -> any TrafficDownloading

    var configuration = TrafficConfiguration()
    var profileName = ""
    private(set) var profiles: [SavedTrafficConfiguration] = []
    private(set) var selectedProfileID: UUID?
    private(set) var settingsMessage: LocalizedStringResource?
    private(set) var backgroundIssue: LocalizedStringResource?
    var allowsBackground: Bool {
        get { configuration.allowsBackground }
        set { configuration.allowsBackground = newValue }
    }
    let supportsBackground: Bool
    private(set) var backgroundState: TrafficBackgroundState = .foregroundOnly
    private(set) var progress = TrafficProgress()
    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var activeTargetBytes: Int64 = 0
    private(set) var activeDownloadLimit = 0
    private(set) var validationFailure: TrafficFailure?
    @ObservationIgnored var onExecutionChange: (() -> Void)?
    @ObservationIgnored private let background: any TrafficBackgroundExecution
    @ObservationIgnored private let engineFactory: EngineFactory
    @ObservationIgnored private var engine: (any TrafficDownloading)?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private let settingsStore: any TrafficSettingsPersistence
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private var checkpoint: TrafficCheckpoint?
    @ObservationIgnored private var activeConfiguration: TrafficConfiguration?
    @ObservationIgnored private var startingOffset: Int64 = 0
    @ObservationIgnored private var lastCheckpointSave: TimeInterval = 0

    init(background: any TrafficBackgroundExecution = TrafficBackgroundCoordinator(),
         settingsStore: any TrafficSettingsPersistence = TrafficSettingsStore(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         engineFactory: @escaping EngineFactory = { plan, observer in
             TrafficDownloadEngine(plan: plan, onProgress: observer)
         }) {
        self.background = background
        self.settingsStore = settingsStore
        self.uptime = uptime
        self.engineFactory = engineFactory
        supportsBackground = background.isSupported
        allowsBackground = background.isSupported
        do {
            let saved = try settingsStore.load()
            profiles = saved.profiles
            checkpoint = saved.checkpoint
            if let selected = profiles.first(where: { $0.id == saved.selectedID }) ?? profiles.first {
                selectedProfileID = selected.id
                profileName = selected.name
                configuration = selected.configuration
            }
        } catch {
            settingsMessage = "Saved settings could not be read. Existing storage was not changed."
        }
    }

    var link: String {
        get { configuration.link }
        set { configuration.link = newValue; validationFailure = nil }
    }

    var origin: TrafficOrigin? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? TrafficOrigin(url: url)
    }

    var fractionCompleted: Double {
        guard activeTargetBytes > 0 else { return 0 }
        return min(Double(progress.receivedBytes) / Double(activeTargetBytes), 1)
    }

    var hasUnsavedChanges: Bool {
        guard let saved = profiles.first(where: { $0.id == selectedProfileID }) else { return !link.isEmpty }
        return saved.configuration != configuration || saved.name != profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canContinueInBackground: Bool { isRunning && backgroundState == .active }

    var activityReading: TrafficActivityReading? {
        guard isRunning else { return nil }
        return TrafficActivityReading(receivedBytes: progress.receivedBytes,
                                      targetBytes: activeTargetBytes,
                                      bytesPerSecond: progress.bytesPerSecond,
                                      activeDownloads: progress.activeDownloads,
                                      downloadLimit: activeDownloadLimit)
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground && !canContinueInBackground { stop(reason: .background) }
    }

    var remainingSavedBytes: Int64? {
        guard let checkpoint, checkpoint.configuration == configuration,
              let target = try? configuration.byteCount(), checkpoint.targetBytes == target,
              checkpoint.receivedBytes > 0, checkpoint.receivedBytes < target else { return nil }
        return target - checkpoint.receivedBytes
    }

    func start(resuming: Bool = false, maximumSpeed: Bool = false) {
        guard !isRunning, isForeground else { return }
        do {
            let total = try configuration.byteCount()
            startingOffset = resuming && remainingSavedBytes != nil ? checkpoint!.receivedBytes : 0
            let plan = try configuration.plan(remainingBytes: total - startingOffset,
                                              concurrentDownloads: maximumSpeed ? TrafficDownloadPlan.maximumConcurrentDownloads : nil)
            activeConfiguration = configuration
            runID = UUID()
            let runID = runID
            activeTargetBytes = total
            activeDownloadLimit = plan.concurrentDownloads
            progress = TrafficProgress(receivedBytes: startingOffset, currentOrigin: plan.origin.displayName)
            validationFailure = nil
            isRunning = true
            isStopping = false
            backgroundIssue = nil
            saveCheckpoint(force: true)
            if allowsBackground && supportsBackground {
                backgroundState = .requesting
                onExecutionChange?()
                background.request(kind: .traffic, totalUnits: activeTargetBytes) { [weak self] granted in
                    guard let self, self.runID == runID, self.isRunning, !self.isStopping,
                          self.backgroundState == .requesting else { return }
                    self.backgroundState = granted ? .active : .unavailable
                    self.backgroundIssue = granted ? nil : self.background.failureReason
                    guard granted || self.isForeground else { self.stop(reason: .background); return }
                    self.launch(plan, runID: runID)
                } onExpiration: { [weak self] in
                    guard let self, self.runID == runID, self.isRunning,
                          self.backgroundState == .active else { return }
                    self.backgroundState = .ended
                    self.stop(reason: .backgroundEnded)
                    self.onExecutionChange?()
                }
            } else {
                backgroundState = .foregroundOnly
                launch(plan, runID: runID)
            }
        } catch {
            validationFailure = error as? TrafficFailure ?? .invalidURL
        }
    }

    private func launch(_ plan: TrafficDownloadPlan, runID: UUID) {
        // A scheduler callback must not start the same user request twice.
        guard engine == nil else { return }
        let engine = engineFactory(plan) { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.runID == runID, self.isRunning,
                      update.sequence > self.progress.sequence else { return }
                var combined = update
                let total = self.startingOffset.addingReportingOverflow(update.receivedBytes)
                combined.receivedBytes = total.overflow ? Int64.max : total.partialValue
                self.progress = combined
                let received = TrafficByteText.format(combined.receivedBytes)
                let target = TrafficByteText.format(self.activeTargetBytes)
                let speed = NetworkRateText(combined.bytesPerSecond).combined
                self.background.update(completedUnits: combined.receivedBytes,
                                       subtitle: "\(received) / \(target) · \(speed)")
                self.saveCheckpoint(force: update.stopReason != nil)
                if let reason = update.stopReason { self.complete(reason) }
            }
        }
        self.engine = engine
        engine.start()
        onExecutionChange?()
    }

    func stop(reason: TrafficStopReason = .user) {
        guard isRunning, !isStopping else { return }
        isStopping = true
        if let engine {
            engine.cancel(reason: reason)
        } else {
            // Stop also works while the system is deciding whether to grant runtime.
            progress.sequence += 1
            progress.stopReason = reason
            complete(reason)
        }
    }

    private func complete(_ reason: TrafficStopReason) {
        isRunning = false
        isStopping = false
        engine = nil
        background.finish(success: reason == .targetReached)
        if backgroundState == .active || backgroundState == .requesting { backgroundState = .ended }
        onExecutionChange?()
    }

    func newConfiguration() {
        guard !isRunning else { return }
        selectedProfileID = nil
        profileName = ""
        configuration = TrafficConfiguration(allowsBackground: supportsBackground)
        settingsMessage = nil
        validationFailure = nil
    }

    func selectProfile(_ id: UUID?) {
        guard !isRunning else { return }
        guard let profile = profiles.first(where: { $0.id == id }) else { newConfiguration(); return }
        selectedProfileID = profile.id
        profileName = profile.name
        configuration = profile.configuration
        validationFailure = nil
        persistSettings()
    }

    func saveProfile() {
        guard !isRunning else { return }
        settingsMessage = nil
        do {
            let plan = try configuration.plan()
            configuration.link = configuration.link.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = SavedTrafficConfiguration(id: selectedProfileID ?? UUID(),
                                                     name: name.isEmpty ? plan.origin.displayName : name,
                                                     configuration: configuration)
            var updated = profiles
            if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
            else { updated.append(profile) }
            try settingsStore.save(TrafficSavedSettings(profiles: updated, selectedID: profile.id, checkpoint: persistableCheckpoint(in: updated)))
            profiles = updated
            selectedProfileID = profile.id
            profileName = profile.name
            validationFailure = nil
            settingsMessage = "Settings saved. This configuration will be available next time."
        } catch let failure as TrafficFailure {
            validationFailure = failure
            settingsMessage = failure.message
        } catch {
            settingsMessage = "Settings could not be saved. Try again."
        }
    }

    func deleteSelectedProfile() {
        guard !isRunning, let id = selectedProfileID else { return }
        let updated = profiles.filter { $0.id != id }
        do {
            let remainingCheckpoint = checkpoint.flatMap { saved in
                updated.contains(where: { $0.configuration == saved.configuration }) ? saved : nil
            }
            try settingsStore.save(TrafficSavedSettings(profiles: updated, selectedID: updated.first?.id,
                                                        checkpoint: remainingCheckpoint))
            profiles = updated
            checkpoint = remainingCheckpoint
            newConfiguration()
            if let first = profiles.first { selectProfile(first.id) }
        } catch { settingsMessage = "Settings could not be saved. Try again." }
    }

    private func saveCheckpoint(force: Bool) {
        guard let activeConfiguration else { return }
        checkpoint = TrafficCheckpoint(configuration: activeConfiguration,
                                       receivedBytes: min(progress.receivedBytes, activeTargetBytes),
                                       targetBytes: activeTargetBytes)
        let now = uptime()
        // Payload bytes never reach storage. Only this small resume record is
        // saved, at most once a minute during a run and again when it stops.
        guard force || now - lastCheckpointSave >= 60 else { return }
        // Only explicitly saved links are persisted. Unsaved runs may resume in memory.
        guard profiles.contains(where: { $0.configuration == activeConfiguration }) else { return }
        lastCheckpointSave = now
        persistSettings()
    }

    private func persistableCheckpoint(in profiles: [SavedTrafficConfiguration]) -> TrafficCheckpoint? {
        guard let checkpoint, profiles.contains(where: { $0.configuration == checkpoint.configuration }) else { return nil }
        return checkpoint
    }

    private func persistSettings() {
        do {
            try settingsStore.save(TrafficSavedSettings(profiles: profiles, selectedID: selectedProfileID,
                                                        checkpoint: persistableCheckpoint(in: profiles)))
        } catch { settingsMessage = "Settings could not be saved. Try again." }
    }

}

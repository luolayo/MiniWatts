import Foundation
import Observation

/// A user-started monitoring window, independent of network downloads. Progress
/// advances only when a real sensor snapshot arrives, never from a keepalive timer.
@Observable
final class BackgroundMonitoringSession {
    var durationHours = 8
    let isSupported: Bool
    private(set) var isRunning = false
    private(set) var state: TrafficBackgroundState = .foregroundOnly
    private(set) var issue: LocalizedStringResource?
    private(set) var sampleCount: Int64 = 0
    private(set) var lastSampleAt: Date?
    private(set) var endsAt: Date?
    @ObservationIgnored var onExecutionChange: (() -> Void)?
    @ObservationIgnored private let background: any TrafficBackgroundExecution
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var isForeground = true

    init(background: any TrafficBackgroundExecution = TrafficBackgroundCoordinator()) {
        self.background = background
        isSupported = background.isSupported
    }

    var canContinueInBackground: Bool { isRunning && state == .active }

    func start(now: Date = .now) {
        guard !isRunning, isForeground else { return }
        guard isSupported else {
            state = .unavailable
            issue = "Background monitoring requires iOS 26 or later."
            return
        }
        guard (1...8).contains(durationHours) else { return }
        runID = UUID()
        let runID = runID
        isRunning = true
        state = .requesting
        issue = nil
        sampleCount = 0
        lastSampleAt = nil
        startedAt = now
        endsAt = now.addingTimeInterval(Double(durationHours) * 3_600)
        onExecutionChange?()
        background.request(kind: .monitoring, totalUnits: Int64(durationHours) * 3_600) { [weak self] granted in
            guard let self, self.runID == runID, self.isRunning, self.state == .requesting else { return }
            if granted {
                self.state = .active
            } else {
                self.state = .unavailable
                self.isRunning = false
                self.issue = self.background.failureReason ?? "Background monitoring was not approved. Keep the app open or retry."
            }
            self.onExecutionChange?()
        } onExpiration: { [weak self] in
            guard let self, self.runID == runID, self.canContinueInBackground else { return }
            self.issue = "The system ended background monitoring. Start a new monitoring session to resume."
            self.stop()
        }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground && isRunning && !canContinueInBackground {
            issue = "Background monitoring was not ready before leaving the app."
            stop()
        }
    }

    func recordSample(at date: Date, subtitle: String) {
        guard canContinueInBackground, let startedAt, let endsAt else { return }
        if let lastSampleAt, date <= lastSampleAt { return }
        lastSampleAt = date
        sampleCount += 1
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        background.update(completedUnits: Int64(min(elapsed, endsAt.timeIntervalSince(startedAt))),
                          subtitle: subtitle)
        if date >= endsAt { stop(completed: true) }
    }

    func stop(completed: Bool = false) {
        guard isRunning else { return }
        isRunning = false
        state = .ended
        background.finish(success: completed)
        onExecutionChange?()
    }
}

import Foundation
import Observation

/// Owns process-lifetime work, including cold App Intent launches. Background
/// expiration must never rely on a SwiftUI onChange firing while off screen.
@Observable
final class MonitoringRuntime {
    let monitor = PowerMonitor()
    let traffic = TrafficConsumer()
    let monitoring = BackgroundMonitoringSession()
    @ObservationIgnored private let activity = ChargeActivityController()
    @ObservationIgnored private let widgets = WidgetPublisher()
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        monitor.onTick = { [weak self] snapshot in
            guard let self else { return }
            if !snapshot.externalConnected && self.monitoring.isRunning {
                self.monitoring.stop()
            }
            let power = self.monitor.headline.map { Formatting.watts($0.watts) } ?? "—"
            let percent = snapshot.percent.map { "\($0)%" } ?? "—"
            self.monitoring.recordSample(at: snapshot.date,
                                         subtitle: "\(power) W · \(percent)")
            self.syncActivity(snapshot)
            self.widgets.publish(ChargeReading(snapshot), lastSession: self.monitor.sessions.first)
        }
        traffic.onExecutionChange = { [weak self] in
            guard let self else { return }
            if self.traffic.isRunning && self.monitoring.isRunning {
                self.monitoring.stop()
            }
            self.reconcileSampling()
            self.syncActivity()
        }
        monitoring.onExecutionChange = { [weak self] in
            self?.reconcileSampling()
            self?.syncActivity()
        }
    }

    private var shouldSample: Bool {
        isForeground || traffic.canContinueInBackground || monitoring.canContinueInBackground
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        traffic.setForeground(foreground)
        monitoring.setForeground(foreground)
        reconcileSampling()
        if !foreground {
            widgets.flush(ChargeReading(monitor.snapshot), lastSession: monitor.sessions.first)
        }
    }

    private func reconcileSampling() {
        if shouldSample {
            monitor.start()
        } else {
            monitor.pause()
            activity.pause()
        }
    }

    func syncActivity() {
        if !monitor.showsLiveActivity { monitoring.stop() }
        syncActivity(monitor.snapshot)
    }

    func startMonitoring() {
        guard monitor.snapshot.externalConnected else { return }
        monitor.showsLiveActivity = true
        activity.prepareForExplicitStart()
        monitoring.start()
    }

    func stopMonitoring() async {
        monitoring.stop()
        await activity.waitForUpdates()
    }

    private func syncActivity(_ snapshot: PowerSnapshot) {
        // Continued-processing tasks display their own Live Activity. Showing our
        // custom activity beside one produces two cards for one piece of work.
        let systemActivityVisible =
            (monitoring.isRunning && (monitoring.state == .requesting || monitoring.state == .active))
            || (traffic.isRunning && (traffic.backgroundState == .requesting || traffic.backgroundState == .active))
        activity.sync(snapshot,
                      network: monitor.network.reading,
                      selectedMetric: monitor.liveActivityMetric,
                      enabled: monitor.showsLiveActivity,
                      isForeground: isForeground,
                      systemActivityVisible: systemActivityVisible,
                      traffic: traffic.activityReading)
    }

    /// A discoverable LiveActivityIntent can wake the process when a charger
    /// automation runs, even though there is no foreground scene.
    func startChargingFromIntent() async {
        guard monitor.showsLiveActivity else { return }
        let snapshot = await monitor.readNow()
        guard snapshot.externalConnected else { return }
        activity.prepareForExplicitStart()
        activity.sync(snapshot,
                      network: monitor.network.reading,
                      selectedMetric: monitor.liveActivityMetric,
                      enabled: true,
                      isForeground: isForeground,
                      systemActivityVisible: monitoring.canContinueInBackground || traffic.canContinueInBackground,
                      allowBackgroundStart: true)
        await activity.waitForUpdates()
        widgets.publish(ChargeReading(snapshot), lastSession: monitor.sessions.first)
    }

    func stopChargingFromIntent() async {
        monitoring.stop()
        activity.endCurrent()
        await activity.waitForUpdates()
    }

    func refreshOnce() async {
        if let refreshTask { await refreshTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.takeFreshReading()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func takeFreshReading() async {
        defer { if !shouldSample { monitor.network.pause() } }
        let network: NetworkReading
        if shouldSample {
            network = monitor.network.reading
        } else {
            do { network = try await monitor.network.readFresh() }
            catch { return }
        }
        let snapshot = await monitor.readNow()
        await activity.refresh(snapshot, network: network,
                               selectedMetric: monitor.liveActivityMetric,
                               enabled: monitor.showsLiveActivity,
                               isSnapshot: !shouldSample,
                               traffic: traffic.activityReading)
        widgets.publish(ChargeReading(snapshot), lastSession: monitor.sessions.first)
    }

    func stopDownload() async {
        traffic.stop()
        // Give cancellation and the final activity update time to finish before
        // returning control to a LiveActivityIntent's short execution window.
        for _ in 0..<40 {
            if !traffic.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await activity.waitForUpdates()
    }
}

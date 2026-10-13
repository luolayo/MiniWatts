import ActivityKit
import Foundation

/// Owns the single custom charging activity. A continued background task has its
/// own system activity, so the custom one is ended while that task is visible.
final class ChargeActivityController {
    private var activity: Activity<ChargeActivityAttributes>?
    private var adopted = false
    private var lastSent: ChargeActivityContentState?
    private var lastSentAt: Date = .distantPast
    private var lastStartAttempt: Date = .distantPast
    private var pendingUpdate: Task<Void, Never>?
    private var dismissed = false
    private var wasEnabled = false

    /// How long past an update its reading still counts as current. Updates go out
    /// every few seconds; this tolerates a couple of missed ones and no more.
    private static let staleAfter: TimeInterval = 12
    /// Minimum spacing between updates.
    private static let minimumInterval: TimeInterval = 1
    /// The monitor samples once a second; send every sample while it is running.
    private static let maximumInterval: TimeInterval = 1
    /// After a refused start — too many activities, the user switched them off —
    /// wait this long before trying again rather than asking every second.
    private static let retryInterval: TimeInterval = 30

    func prepareForExplicitStart() {
        dismissed = false
        wasEnabled = false
        lastStartAttempt = .distantPast
        if let activity, activity.activityState == .ended || activity.activityState == .dismissed {
            self.activity = nil
            lastSent = nil
        }
    }

    func sync(_ snapshot: PowerSnapshot,
              network: NetworkReading,
              selectedMetric: LiveActivityMetric,
              enabled: Bool,
              isForeground: Bool,
              systemActivityVisible: Bool = false,
              allowBackgroundStart: Bool = false,
              traffic: TrafficActivityReading? = nil) {
        adoptExistingActivities()
        let state = Self.contentState(from: snapshot, network: network,
                                      selectedMetric: selectedMetric, traffic: traffic)
        if enabled && !wasEnabled {
            dismissed = false
            lastStartAttempt = .distantPast
        }
        wasEnabled = enabled
        guard enabled && snapshot.externalConnected && !systemActivityVisible else {
            end(with: state, dismissal: .immediate)
            if !snapshot.externalConnected { dismissed = false }
            return
        }
        if let activity, activity.activityState == .dismissed || activity.activityState == .ended {
            // Respect End and system dismissal. An explicit off/on restarts it.
            self.activity = nil
            dismissed = true
        }
        guard !dismissed else { return }
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            update(activity, with: state)
        } else if isForeground || allowBackgroundStart {
            start(with: state)
        }
    }

    func endCurrent() {
        adoptExistingActivities()
        dismissed = true
        wasEnabled = true
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        lastSentAt = .distantPast
        let id = activity.id
        let previous = pendingUpdate
        pendingUpdate = Task {
            await previous?.value
            await Self.end(id, nil, dismissal: .immediate)
        }
    }

    func pause() {
        guard let activity, var state = lastSent, state.isPaused != true else { return }
        state.isPaused = true
        state.isSnapshot = false
        state.traffic = nil
        lastSent = state
        enqueueUpdate(activity.id, content(for: state))
    }

    func refresh(_ snapshot: PowerSnapshot, network: NetworkReading,
                 selectedMetric: LiveActivityMetric, enabled: Bool,
                 isSnapshot: Bool, traffic: TrafficActivityReading?) async {
        guard enabled else { return }
        adoptExistingActivities()
        guard snapshot.externalConnected,
              let activity, activity.activityState == .active || activity.activityState == .stale else { return }
        var state = Self.contentState(from: snapshot, network: network,
                                      selectedMetric: selectedMetric, traffic: traffic)
        state.isSnapshot = isSnapshot
        lastSent = state
        lastSentAt = state.date
        enqueueUpdate(activity.id, content(for: state))
        await waitForUpdates()
    }

    func waitForUpdates() async { await pendingUpdate?.value }

    /// An activity outlives the app being killed. The first sync after launch picks up
    /// one left behind and ends any others, rather than starting a duplicate.
    private func adoptExistingActivities() {
        guard !adopted else { return }
        adopted = true
        let existing = Activity<ChargeActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        activity = existing.first
        for id in existing.dropFirst().map(\.id) {
            Task { await Self.end(id, nil, dismissal: .immediate) }
        }
    }

    private func start(with state: ChargeActivityContentState) {
        guard state.date.timeIntervalSince(lastStartAttempt) >= Self.retryInterval,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        lastStartAttempt = state.date
        do {
            activity = try Activity.request(
                attributes: ChargeActivityAttributes(startedAt: state.date,
                                                     startPercent: state.reading.percent),
                content: content(for: state),
                pushType: nil)
            lastSent = state
            lastSentAt = state.date
        } catch {
            // Refused: not frontmost after all, activities disabled, or the system
            // limit reached. Tried again after `retryInterval`.
        }
    }

    private func update(_ activity: Activity<ChargeActivityAttributes>,
                        with state: ChargeActivityContentState) {
        let elapsed = state.date.timeIntervalSince(lastSentAt)
        let forced = lastSent?.isPaused == true || lastSent?.isSnapshot == true
            || lastSent?.selectedMetric != state.selectedMetric
            || (lastSent?.traffic != nil) != (state.traffic != nil)
        guard forced || elapsed >= Self.minimumInterval else { return }
        if elapsed < Self.maximumInterval, let lastSent, !Self.differs(lastSent, state) { return }
        lastSent = state
        lastSentAt = state.date
        let content = content(for: state)
        let id = activity.id
        enqueueUpdate(id, content)
    }

    private func end(with state: ChargeActivityContentState,
                     dismissal: ActivityUIDismissalPolicy) {
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        lastSentAt = .distantPast
        lastStartAttempt = .distantPast
        let final = ActivityContent(state: state, staleDate: nil)
        let id = activity.id
        let previous = pendingUpdate
        pendingUpdate = Task {
            await previous?.value
            await Self.end(id, final, dismissal: dismissal)
        }
    }

    /// Keep a delayed foreground update from overwriting the paused state.
    private func enqueueUpdate(_ id: String,
                               _ content: ActivityContent<ChargeActivityContentState>) {
        let previous = pendingUpdate
        pendingUpdate = Task {
            await previous?.value
            await Self.update(id, content)
        }
    }

    // `Activity` is not `Sendable`, and its `update` and `end` are nonisolated async.
    // Calling them on an instance that lives on the main actor — held in a property, or
    // just looked up from main-actor code — sends it off the actor, and Swift 6 refuses
    // to compile that. So the lookup and the call happen together off the actor: only an
    // id and the content, which are both `Sendable`, cross over.

    @concurrent
    nonisolated private static func update(_ id: String,
                                           _ content: ActivityContent<ChargeActivityContentState>) async {
        await activity(id)?.update(content)
    }

    @concurrent
    nonisolated private static func end(_ id: String,
                                        _ content: ActivityContent<ChargeActivityContentState>?,
                                        dismissal: ActivityUIDismissalPolicy) async {
        await activity(id)?.end(content, dismissalPolicy: dismissal)
    }

    nonisolated private static func activity(_ id: String) -> Activity<ChargeActivityAttributes>? {
        Activity<ChargeActivityAttributes>.activities.first { $0.id == id }
    }

    private func content(
        for state: ChargeActivityContentState
    ) -> ActivityContent<ChargeActivityContentState> {
        ActivityContent(state: state,
                        staleDate: state.isPaused == true ? .now
                            : state.date.addingTimeInterval(Self.staleAfter),
                        relevanceScore: 100)
    }

    /// Whether a reading has moved enough to be worth an update on its own.
    private static func differs(
        _ old: ChargeActivityContentState,
        _ new: ChargeActivityContentState
    ) -> Bool {
        // Match the activity's one-decimal display when comparing readings.
        let oldReading = old.reading
        let newReading = new.reading
        return old.selectedMetric != new.selectedMetric
            || old.isPaused != new.isPaused
            || old.isSnapshot != new.isSnapshot
            || old.traffic != new.traffic
            || old.network != new.network
            || oldReading.percent != newReading.percent
            || oldReading.source != newReading.source
            || oldReading.isCharging != newReading.isCharging
            || oldReading.isOnHold != newReading.isOnHold
            || oldReading.isFull != newReading.isFull
            || abs((oldReading.watts ?? -1) - (newReading.watts ?? -1)) >= 0.05
            || abs((oldReading.batteryTemperature ?? 0)
                   - (newReading.batteryTemperature ?? 0)) >= 0.05
            || abs((old.socTemperature ?? 0) - (new.socTemperature ?? 0)) >= 0.05
            || abs((old.hottestTemperature ?? 0) - (new.hottestTemperature ?? 0)) >= 0.05
            || old.hottestSensorName != new.hottestSensorName
    }

    private static func contentState(
        from snapshot: PowerSnapshot,
        network: NetworkReading,
        selectedMetric: LiveActivityMetric,
        traffic: TrafficActivityReading? = nil
    ) -> ChargeActivityContentState {
        ChargeActivityContentState(
            reading: ChargeReading(snapshot),
            socTemperature: snapshot.socTemperature,
            hottestTemperature: snapshot.hottestSensor?.value,
            hottestSensorName: snapshot.hottestSensor?.name,
            selectedMetric: selectedMetric,
            network: network,
            isPaused: false,
            isSnapshot: false,
            traffic: traffic
        )
    }
}

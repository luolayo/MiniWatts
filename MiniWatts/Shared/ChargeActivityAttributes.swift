import ActivityKit
import AppIntents
import Foundation

/// The live activity shown on the Lock Screen, in the Dynamic Island and in StandBy
/// while power and network monitoring is enabled.
///
/// Compiled into both targets: the app starts and updates the activity, the widget
/// extension renders it. ActivityKit matches the two by this type.
///
/// It is only ever updated by the app, while the app is running. Nothing pushes to
/// it from outside — push updates need an APNs server and a certificate tied to a
/// developer team, and a sideloaded copy re-signed with someone else's Apple ID
/// would never receive them. So every update carries a stale date, and the
/// extension says the reading is out of date rather than showing an old number as
/// if it were current.
nonisolated struct ChargeActivityAttributes: ActivityAttributes {
    typealias ContentState = ChargeActivityContentState

    /// When monitoring began (which may be while unplugged).
    var startedAt: Date
    var startPercent: Int?
}

/// The End button on the activity.
///
/// Only the app can end an activity, and only while it runs. Unplug while MiniWatts is
/// suspended, or kill it, and the activity stays — paused, but on screen — until the
/// app runs again or iOS drops it hours later. A `LiveActivityIntent` is performed in
/// the app's process, which iOS wakes for it, so the button closes the activity
/// without opening MiniWatts. Compiled into both targets: the extension needs the type
/// to draw the button, the app performs it.
struct EndChargeActivityIntent: LiveActivityIntent {
    nonisolated static var title: LocalizedStringResource { "End Live Activity" }
    nonisolated static var isDiscoverable: Bool { false }
    @Dependency private var actions: LiveActivityActionHandlers

    nonisolated func perform() async throws -> some IntentResult {
        await actions.stopMonitoring()
        for activity in Activity<ChargeActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

/// Registered at app initialization, including a cold launch from a Live Activity.
/// Keeping only closures here avoids compiling the app's monitors into the extension.
nonisolated struct LiveActivityActionHandlers: Sendable {
    let refresh: @Sendable () async -> Void
    let stopDownload: @Sendable () async -> Void
    let stopMonitoring: @Sendable () async -> Void
    let startCharging: @Sendable () async -> Void
    let stopCharging: @Sendable () async -> Void
}

/// Add this action to a Shortcuts "Charger Is Connected" automation to wake the
/// app process and show a charging activity without opening its interface.
struct StartChargingActivityIntent: LiveActivityIntent {
    nonisolated static var title: LocalizedStringResource { "Show Charging Activity" }
    nonisolated static var description: IntentDescription? {
        IntentDescription("Show charging readings in the Dynamic Island.")
    }
    @Dependency private var actions: LiveActivityActionHandlers

    nonisolated func perform() async throws -> some IntentResult {
        await actions.startCharging()
        return .result()
    }
}

struct StopChargingActivityIntent: LiveActivityIntent {
    nonisolated static var title: LocalizedStringResource { "End Charging Activity" }
    @Dependency private var actions: LiveActivityActionHandlers

    nonisolated func perform() async throws -> some IntentResult {
        await actions.stopCharging()
        return .result()
    }
}

struct RefreshChargeActivityIntent: LiveActivityIntent {
    nonisolated static var title: LocalizedStringResource { "Refresh readings" }
    nonisolated static var isDiscoverable: Bool { false }
    @Dependency private var actions: LiveActivityActionHandlers

    nonisolated func perform() async throws -> some IntentResult {
        let actions = actions
        await actions.refresh()
        return .result()
    }
}

struct StopTrafficActivityIntent: LiveActivityIntent {
    nonisolated static var title: LocalizedStringResource { "Stop download" }
    nonisolated static var isDiscoverable: Bool { false }
    @Dependency private var actions: LiveActivityActionHandlers

    nonisolated func perform() async throws -> some IntentResult {
        let actions = actions
        await actions.stopDownload()
        return .result()
    }
}

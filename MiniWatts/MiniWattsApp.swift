import AppIntents
import SwiftUI

@main
struct MiniWattsApp: App {
    @State private var runtime: MonitoringRuntime

    init() {
        let runtime = MonitoringRuntime()
        _runtime = State(initialValue: runtime)
        // Intent actions also cold-launch this process without creating a scene.
        // Both the shared sensor client and action handlers must exist at launch.
        AppDependencyManager.shared.add(dependency: runtime.monitor)
        AppDependencyManager.shared.add(dependency: LiveActivityActionHandlers(
            refresh: { await runtime.refreshOnce() },
            stopDownload: { await runtime.stopDownload() },
            stopMonitoring: { await runtime.stopMonitoring() },
            startCharging: { await runtime.startChargingFromIntent() },
            stopCharging: { await runtime.stopChargingFromIntent() }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(runtime)
                .environment(runtime.monitor)
                .environment(runtime.traffic)
        }
    }
}

import SwiftUI

struct BackgroundMonitoringPanel: View {
    @Environment(MonitoringRuntime.self) private var runtime

    var body: some View {
        @Bindable var session = runtime.monitoring
        Panel("Background monitoring", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.state.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(session.canContinueInBackground ? Color.mwAccent : .mwMuted)
                if let issue = session.issue {
                    Text(issue).font(.caption).foregroundStyle(Color.mwLoss)
                }
                if session.isRunning {
                    Button(role: .destructive) {
                        Task { await runtime.stopMonitoring() }
                    } label: {
                        Label("Stop monitoring", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Picker("Monitoring duration", selection: $session.durationHours) {
                        Text("1 hour").tag(1)
                        Text("4 hours").tag(4)
                        Text("8 hours").tag(8)
                    }
                    .pickerStyle(.menu)
                    Button { runtime.startMonitoring() } label: {
                        Label("Start background monitoring", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mwAccent)
                    .disabled(!session.isSupported || !runtime.monitor.snapshot.externalConnected)
                }
            }
        }
    }
}

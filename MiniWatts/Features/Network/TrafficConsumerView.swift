import SwiftUI

struct TrafficConsumerView: View {
    @Environment(TrafficConsumer.self) private var consumer
    nonisolated private enum Field: Hashable { case name, link, target, concurrency }
    @FocusState private var focusedField: Field?
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var consumer = consumer
        PageScaffold("Traffic consumer", isDetail: true) {
            Panel("Download link", systemImage: "link") {
                VStack(alignment: .leading, spacing: 14) {
                    if !consumer.profiles.isEmpty {
                        Picker("Saved configurations", selection: Binding(
                            get: { consumer.selectedProfileID }, set: { consumer.selectProfile($0) }
                        )) {
                            Text("New configuration").tag(Optional<UUID>.none)
                            ForEach(consumer.profiles) { profile in
                                Text(verbatim: profile.name).tag(Optional(profile.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    TextField("Configuration name (optional)", text: $consumer.profileName)
                        .focused($focusedField, equals: .name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Paste an HTTPS file link", text: $consumer.link, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                        .focused($focusedField, equals: .link)
                        .padding(12)
                        .background(Color.mwCanvas, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Download link")
                    if let origin = consumer.origin {
                        Label { Text(verbatim: origin.displayName) } icon: { Image(systemName: "lock.shield") }
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.mwNetwork)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Save settings") { focusedField = nil; consumer.saveProfile() }
                            .buttonStyle(.borderedProminent)
                            .tint(.mwAccent)
                        Button("New configuration") { consumer.newConfiguration() }
                            .buttonStyle(.bordered)
                        if consumer.selectedProfileID != nil {
                            Button(role: .destructive) { confirmingDelete = true } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete configuration")
                        }
                    }
                    if let message = consumer.settingsMessage {
                        Text(message).font(.caption).foregroundStyle(Color.mwMuted)
                    }
                    if consumer.hasUnsavedChanges {
                        Text("Unsaved changes").font(.caption).foregroundStyle(Color.mwLoss)
                    }
                }
                .disabled(consumer.isRunning)
            }
            Panel("Download limits", systemImage: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Target data")
                        Spacer()
                        TextField("100", text: $consumer.configuration.amount)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .target)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .accessibilityLabel("Target data")
                        Picker("Data unit", selection: $consumer.configuration.unit) {
                            ForEach(TrafficDataUnit.allCases) { unit in Text(verbatim: unit.rawValue).tag(unit) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    HStack {
                        Text("Download threads")
                        Spacer()
                        TextField("4", value: $consumer.configuration.concurrentDownloads, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .concurrency)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 48)
                            .accessibilityLabel("Download threads")
                        Stepper("Download threads", value: $consumer.configuration.concurrentDownloads, in: 1...64)
                            .labelsHidden()
                    }
                    Picker("Time limit", selection: $consumer.configuration.durationMinutes) {
                        Text("No time limit").tag(0)
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                    }
                    Toggle("Continue in background", isOn: $consumer.allowsBackground)
                        .disabled(!consumer.supportsBackground)
                        .tint(.mwNetwork)
                    Picker("Redirect rule", selection: $consumer.configuration.redirectPolicy) {
                        ForEach(TrafficRedirectPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .disabled(consumer.isRunning)
            }
            progressPanel
        }
        .confirmationDialog("Delete this saved configuration?", isPresented: $confirmingDelete) {
            Button("Delete configuration", role: .destructive) { consumer.deleteSelectedProfile() }
            Button("Cancel", role: .cancel) {}
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    private var progressPanel: some View {
        Panel("This download", systemImage: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 16) {
                Text(consumer.backgroundState.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(consumer.canContinueInBackground ? Color.mwAccent : .mwMuted)
                if let issue = consumer.backgroundIssue {
                    Text(issue).font(.caption).foregroundStyle(Color.mwLoss)
                }
                if consumer.backgroundState == .requesting {
                    Text("Wait for background approval before leaving the app.")
                        .font(.caption)
                        .foregroundStyle(Color.mwMuted)
                }
                HStack(alignment: .top, spacing: 16) {
                    Metric(caption: "Downloaded", value: TrafficByteText.format(consumer.progress.receivedBytes), size: 25)
                    let speed = NetworkRateText(consumer.progress.bytesPerSecond)
                    Metric(caption: "Download speed", value: speed.value, unit: speed.unit, tint: .mwNetwork, size: 25)
                }
                if consumer.activeTargetBytes > 0 {
                    HStack {
                        Text("Active downloads")
                        Spacer()
                        Text(verbatim: "\(consumer.progress.activeDownloads) / \(consumer.activeDownloadLimit)")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    ProgressView(value: consumer.fractionCompleted)
                        .tint(.mwNetwork)
                        .accessibilityLabel("Download progress")
                    HStack {
                        Text(verbatim: TrafficByteText.format(consumer.activeTargetBytes))
                        Spacer()
                        Text(verbatim: Formatting.duration(consumer.progress.elapsed))
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.mwMuted)
                }
                if !consumer.progress.currentOrigin.isEmpty {
                    Text(verbatim: consumer.progress.currentOrigin)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.mwMuted)
                        .textSelection(.enabled)
                }
                if consumer.progress.retryCount > 0 {
                    Text("Automatic retries: \(consumer.progress.retryCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.mwMuted)
                }
                if consumer.progress.retryingDownloads > 0 {
                    Label("Reconnecting \(consumer.progress.retryingDownloads) download threads…", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundStyle(Color.mwLoss)
                    if let failure = consumer.progress.lastRetryFailure {
                        Text(failure.message).font(.caption).foregroundStyle(Color.mwMuted)
                    }
                }
                if let failure = consumer.validationFailure {
                    Text(failure.message).foregroundStyle(Color.mwDanger)
                } else if let reason = consumer.progress.stopReason {
                    if case .failed(let failure) = reason {
                        Text(failure.message).foregroundStyle(Color.mwDanger)
                    } else {
                        Text(reason.title).foregroundStyle(Color.mwMuted)
                    }
                }
                if consumer.isRunning {
                    Button(role: .destructive) { consumer.stop() } label: {
                        Label {
                            if consumer.isStopping { Text("Stopping…") } else { Text("Stop download") }
                        } icon: {
                            Image(systemName: "stop.fill")
                        }
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(consumer.isStopping)
                } else {
                    Button {
                        focusedField = nil
                        consumer.start(maximumSpeed: true)
                    } label: {
                        Label("Max speed", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mwNetwork)
                    .disabled(consumer.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let remaining = consumer.remainingSavedBytes {
                        Button {
                            focusedField = nil
                            consumer.start(resuming: true)
                        } label: {
                            Text("Resume remaining \(TrafficByteText.format(remaining))")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.mwAccent)
                    }
                    Button {
                        focusedField = nil
                        consumer.start()
                    } label: {
                        Label("Start download", systemImage: "arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(consumer.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

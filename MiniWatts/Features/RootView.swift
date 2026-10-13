import SwiftUI
import UIKit

struct RootView: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(MonitoringRuntime.self) private var runtime
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            TabPage { DashboardView() }
                .tabItem { Label("Overview", systemImage: "waveform.path.ecg") }
            TabPage { SessionsView() }
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            TabPage { SettingsView() }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .tint(.mwAccent)
        .background { ScreenAwakeHolder() }
        .onChange(of: monitor.showsLiveActivity) { _, _ in runtime.syncActivity() }
        .onChange(of: monitor.liveActivityMetric) { _, _ in runtime.syncActivity() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                runtime.setForeground(true)
            case .background:
                runtime.setForeground(false)
            default:
                // `.inactive` is transient and the app is still on screen for most
                // of it: a pulled-down Control Center, the app switcher, an
                // incoming call. Nothing to do.
                break
            }
        }
    }


}

/// A tab's page, built only while the tab is on screen.
///
/// A `TabView` keeps every tab that has been visited alive, and keeps updating it:
/// each page reads the monitor, so each one was re-evaluated on every tick, on
/// screen or not. With every tab visited, all pages were rebuilt once a second,
/// and scrolling the one in front hitched at exactly that rhythm. The price is that
/// a tab comes back scrolled to the top.
///
/// The switch has to live inside the tab. Deciding it in `RootView` from the
/// selection does not work: a tab that is not showing never receives its parent's
/// update, so it kept the page it had and went on updating it.
private struct TabPage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isOnScreen = true

    var body: some View {
        ZStack {
            if isOnScreen {
                content()
            } else {
                Color.clear
            }
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }
}

/// Keeps the foreground app awake during an explicit traffic download, or while
/// charging if that recording preference is enabled. Stops holding it on at the
/// end of a download or when the app leaves the foreground.
///
/// A view of its own because deciding needs the snapshot, which changes every
/// second. Read in `RootView`'s body, it re-ran that body — and the tab view under
/// it — on every tick; here it re-runs an empty view.
private struct ScreenAwakeHolder: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(TrafficConsumer.self) private var trafficConsumer
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .onChange(of: shouldStayAwake, initial: true) { _, awake in
                UIApplication.shared.isIdleTimerDisabled = awake
            }
    }

    private var shouldStayAwake: Bool {
        scenePhase == .active
            && (trafficConsumer.isRunning
                || (monitor.keepScreenAwakeWhileCharging && monitor.snapshot.externalConnected))
    }
}

/// Shared scrolling chrome. Keep snapshot reads inside `PageContent` so the
/// navigation stack and toolbar are not rebuilt on every sample. Detail screens
/// reuse their parent's navigation stack and retain its back button.
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringResource
    var toolbar: AnyView?
    var isDetail: Bool
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringResource,
         toolbar: AnyView? = nil,
         isDetail: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.toolbar = toolbar
        self.isDetail = isDetail
        self.content = content
    }

    var body: some View {
        if isDetail {
            page
        } else {
            NavigationStack { page }
        }
    }

    private var page: some View {
        ZStack {
            Backdrop()
            ScrollView {
                // Lazy, not a plain `VStack`. History puts up to sixty session
                // panels in here, each with its own sparkline, and an eager stack
                // builds and measures every one of them — while charging, once a
                // second, because the page reads the live session.
                LazyVStack(spacing: 14) {
                    PageContent(content: content)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                // Pinned to the container's width so nothing inside can widen the
                // scroll content. A paragraph inside an HStack reports an enormous
                // ideal width — the text unwrapped onto one line — and
                // `.frame(maxWidth: .infinity)` only expands, it does not clamp, so
                // that width propagates up and the page starts scrolling sideways.
                // Include the iPad width cap in the fixed container frame.
                .containerRelativeFrame(.horizontal) { width, _ in min(width, 760) }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let toolbar {
                ToolbarItem(placement: .topBarTrailing) { toolbar }
            }
        }
    }
}

/// Calls a page's content closure, so that the monitor reads inside it are this
/// view's dependencies and not `PageScaffold`'s. A custom view's body is flattened
/// into the enclosing list, so the stack stays lazy panel by panel.
private struct PageContent<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
    }
}

/// Used wherever a probe legitimately has nothing to report.
/// Shown where the input figure would be, when the input sensors answered but more
/// power is reaching the cell than they account for. See `PowerSnapshot.partialInputWatts`.
struct PartialInputNote: View {
    let sensedWatts: Double
    let cellWatts: Double

    var body: some View {
        EmptyNote(text: "The input sensors read \(Formatting.watts(sensedWatts)) W while \(Formatting.watts(cellWatts)) W is reaching the cell, so on this model they see only part of what comes in. That figure is not shown as the input, and nothing is worked out from it.",
                  systemImage: "exclamationmark.triangle")
    }
}

struct EmptyNote: View {
    let text: LocalizedStringResource
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mwMuted)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.mwMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

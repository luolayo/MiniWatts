import Foundation

nonisolated enum BackgroundWorkKind: String, Sendable {
    case traffic, monitoring
    var title: LocalizedStringResource {
        switch self {
        case .traffic: "Traffic download"
        case .monitoring: "Live power monitoring"
        }
    }
}

@MainActor
protocol TrafficBackgroundExecution: AnyObject {
    var isSupported: Bool { get }
    var failureReason: LocalizedStringResource? { get }
    func request(kind: BackgroundWorkKind, totalUnits: Int64, onReady: @escaping (Bool) -> Void,
                 onExpiration: @escaping () -> Void)
    func update(completedUnits: Int64, subtitle: String)
    func finish(success: Bool)
}

extension TrafficBackgroundExecution {
    var failureReason: LocalizedStringResource? { nil }
}

nonisolated enum TrafficBackgroundState: Equatable {
    case foregroundOnly, requesting, active, unavailable, ended

    var title: LocalizedStringResource {
        switch self {
        case .foregroundOnly: "Foreground only"
        case .requesting: "Requesting background execution"
        case .active: "Background execution approved"
        case .unavailable: "Background unavailable — foreground only"
        case .ended: "Background execution ended"
        }
    }
}

protocol TrafficDownloading: AnyObject, Sendable {
    nonisolated func start()
    nonisolated func cancel(reason: TrafficStopReason)
}

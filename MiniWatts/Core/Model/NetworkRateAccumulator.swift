import Foundation

nonisolated struct NetworkInterfaceCounter: Equatable, Sendable {
    let received: UInt64
    let sent: UInt64
}

/// A fresh baseline is required after suspension, interface changes, read failures,
/// or a reset/wrap of Darwin's counters. Never turn a gap into an apparent burst.
nonisolated struct NetworkRateAccumulator {
    private var previous: [String: NetworkInterfaceCounter]?
    private var previousTime: TimeInterval?

    mutating func reset() {
        previous = nil
        previousTime = nil
    }

    mutating func sample(
        _ counters: [String: NetworkInterfaceCounter]?,
        at uptime: TimeInterval
    ) -> (download: Double, upload: Double)? {
        guard let counters, !counters.isEmpty, uptime.isFinite else {
            reset()
            return nil
        }
        defer {
            previous = counters
            previousTime = uptime
        }
        guard let previous, let previousTime,
              previous.keys.sorted() == counters.keys.sorted() else { return nil }
        let elapsed = uptime - previousTime
        guard elapsed > 0, elapsed <= 5 else { return nil }
        var received = 0.0
        var sent = 0.0
        for (name, current) in counters {
            guard let old = previous[name],
                  current.received >= old.received, current.sent >= old.sent else { return nil }
            received += Double(current.received - old.received)
            sent += Double(current.sent - old.sent)
        }
        return (received / elapsed, sent / elapsed)
    }
}

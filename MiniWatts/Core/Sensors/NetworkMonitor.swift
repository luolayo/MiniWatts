import Darwin
import Foundation
import Network
import Observation

/// Uses the existing power tick. No requests, speed-test downloads, or extra timer.
@Observable
final class NetworkMonitor {
    private(set) var reading = NetworkReading()
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var accumulator = NetworkRateAccumulator()
    @ObservationIgnored private var generation = UUID()

    func start() {
        guard pathMonitor == nil else { return }
        accumulator.reset()
        reading = NetworkReading()
        generation = UUID()
        let generation = generation
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let connection = Self.connection(for: path)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                if self.reading.connection != connection {
                    self.accumulator.reset()
                    self.reading = NetworkReading(connection: connection)
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "MiniWatts.network-path"))
    }

    func pause() {
        generation = UUID()
        pathMonitor?.cancel()
        pathMonitor = nil
        accumulator.reset()
    }

    func sample() {
        guard pathMonitor != nil else { return }
        guard reading.connection != .offline, reading.connection != .unknown else {
            accumulator.reset()
            reading.downloadBytesPerSecond = nil
            reading.uploadBytesPerSecond = nil
            return
        }
        let rates = accumulator.sample(Self.interfaceCounters(),
                                       at: ProcessInfo.processInfo.systemUptime)
        reading.downloadBytesPerSecond = rates?.download
        reading.uploadBytesPerSecond = rates?.upload
    }

    /// A separate baseline for an explicit refresh intent. It never reuses an
    /// old speed or disturbs the accumulator used by continuous sampling. The
    /// runtime releases the path monitor afterwards unless continuous work began.
    func readFresh() async throws -> NetworkReading {
        start()
        var accumulator = NetworkRateAccumulator()
        _ = accumulator.sample(Self.interfaceCounters(), at: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(for: .seconds(1))
        let rates = accumulator.sample(Self.interfaceCounters(), at: ProcessInfo.processInfo.systemUptime)
        guard reading.connection != .offline, reading.connection != .unknown else {
            return NetworkReading(connection: reading.connection)
        }
        return NetworkReading(connection: reading.connection,
                              downloadBytesPerSecond: rates?.download,
                              uploadBytesPerSecond: rates?.upload)
    }

    nonisolated private static func connection(for path: NWPath) -> NetworkConnection {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }

    /// Count each physical interface once. Exclude loopback, peer-to-peer links
    /// (awdl/llw), and VPN tunnels (utun/ipsec) so tunneled bytes aren't counted twice.
    nonisolated static func isTrafficInterface(_ name: String) -> Bool {
        let suffix: Substring
        if name.hasPrefix("pdp_ip") {
            suffix = name.dropFirst(6)
        } else if name.hasPrefix("en") {
            suffix = name.dropFirst(2)
        } else {
            return false
        }
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    nonisolated static func interfaceCounters() -> [String: NetworkInterfaceCounter]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var result: [String: NetworkInterfaceCounter] = [:]
        var node = head
        while let current = node {
            defer { node = current.pointee.ifa_next }
            let interface = current.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  let data = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard isTrafficInterface(name) else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = NetworkInterfaceCounter(received: UInt64(counters.ifi_ibytes),
                                                   sent: UInt64(counters.ifi_obytes))
        }
        return result.isEmpty ? nil : result
    }
}

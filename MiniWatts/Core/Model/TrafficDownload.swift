import Foundation

nonisolated struct TrafficOrigin: Equatable, Sendable {
    let host: String
    let port: Int

    init(url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              (1...65_535).contains(url.port ?? 443) else { throw TrafficFailure.invalidURL }
        self.host = host
        self.port = url.port ?? 443
    }

    var displayName: String { port == 443 ? host : "\(host):\(port)" }
}

nonisolated enum TrafficRedirectPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case sameOrigin, anyHTTPS
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .sameOrigin: "Same origin only"
        case .anyHTTPS: "Allow HTTPS redirects"
        }
    }

    func allows(_ destination: URL, from origin: TrafficOrigin) -> Bool {
        guard let target = try? TrafficOrigin(url: destination) else { return false }
        return self == .anyHTTPS || target == origin
    }
}

nonisolated struct TrafficDownloadPlan: Sendable {
    static let maximumConcurrentDownloads = 64
    let url: URL
    let origin: TrafficOrigin
    let targetBytes: Int64
    let durationLimit: TimeInterval?
    let redirectPolicy: TrafficRedirectPolicy
    let concurrentDownloads: Int

    init(link: String, targetBytes: Int64, durationLimit: TimeInterval? = nil,
         concurrentDownloads: Int = 1,
         redirectPolicy: TrafficRedirectPolicy) throws {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: trimmed) else { throw TrafficFailure.invalidURL }
        origin = try TrafficOrigin(url: url)
        guard targetBytes > 0 else { throw TrafficFailure.invalidLimit }
        if let durationLimit {
            guard durationLimit.isFinite, durationLimit > 0 else { throw TrafficFailure.invalidLimit }
        }
        guard (1...Self.maximumConcurrentDownloads).contains(concurrentDownloads) else { throw TrafficFailure.invalidConcurrency }
        self.url = url
        self.targetBytes = targetBytes
        self.durationLimit = durationLimit
        self.redirectPolicy = redirectPolicy
        self.concurrentDownloads = concurrentDownloads
    }

    /// Rebuild redirected requests rather than forwarding cookies, credentials,
    /// Referer or any other headers supplied by a previous origin.
    func request(for url: URL? = nil, remainingBytes: Int64) -> URLRequest {
        var request = URLRequest(url: url ?? self.url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 60)
        request.httpMethod = "GET"
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-\(max(remainingBytes - 1, 0))", forHTTPHeaderField: "Range")
        return request
    }
}

nonisolated enum TrafficFailure: Error, Equatable, Sendable {
    case invalidURL, invalidLimit, invalidConcurrency, blockedRedirect, tooManyRedirects
    case invalidResponse, webpage, emptyResponse, network, authentication
    case httpStatus(Int)
    case networkCode(Int)

    var message: LocalizedStringResource {
        switch self {
        case .invalidURL: "Enter a valid HTTPS download link without a username or password."
        case .invalidLimit: "Enter a positive data amount in MB or GB."
        case .invalidConcurrency: "Choose between 1 and 64 concurrent downloads."
        case .blockedRedirect: "Stopped: the redirect is outside the permitted origin."
        case .tooManyRedirects: "Stopped: the link redirected too many times."
        case .invalidResponse: "The server did not return a downloadable response."
        case .webpage: "This is a webpage or playlist. Enter a direct file link."
        case .emptyResponse: "The server returned no data. Check the download link."
        case .network: "Download failed. Check your connection and link, then try again."
        case .authentication: "This link requires authentication. Use an accessible direct download link."
        case .httpStatus(let code): "The server returned HTTP \(code)."
        case .networkCode(let code): "Connection failed (URL error \(code))."
        }
    }
}

nonisolated enum TrafficStopReason: Equatable, Sendable {
    case targetReached, user, background, backgroundEnded, timeLimit, failed(TrafficFailure)

    var title: LocalizedStringResource {
        switch self {
        case .targetReached: "Target reached"
        case .user: "Download stopped"
        case .background: "Stopped in background"
        case .backgroundEnded: "Background execution ended"
        case .timeLimit: "Time limit reached"
        case .failed: "Download failed"
        }
    }
}

nonisolated struct TrafficProgress: Sendable {
    var sequence: Int = 0
    var receivedBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var elapsed: TimeInterval = 0
    var completedRequests: Int = 0
    var activeDownloads: Int = 0
    var retryCount: Int = 0
    var retryingDownloads: Int = 0
    var lastRetryFailure: TrafficFailure?
    var currentOrigin: String = ""
    var stopReason: TrafficStopReason?
}

/// Limits apply to individual requests, never to the user's total data goal.
nonisolated struct TrafficTransferPolicy: Sendable {
    var requestByteLimit: Int64 = 32 * 1_024 * 1_024
    var retryDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    static func retries(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: error.code) {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    static func retries(status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(status)
    }

    static func failure(for error: Error) -> TrafficFailure {
        let error = error as NSError
        // Never display localizedDescription/userInfo: these may contain private URLs.
        return error.domain == NSURLErrorDomain ? .networkCode(error.code) : .network
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

nonisolated enum TrafficByteText {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}

import Foundation

/// URLProtocol handles every request; these tests never contact an external server.
nonisolated final class DownloadFixture: @unchecked Sendable {
    static let shared = DownloadFixture()
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var runID = UUID().uuidString
    private var active: Set<ObjectIdentifier> = []
    private var peak = 0
    private var parked: [DownloadProtocol] = []
    private var updates: [TrafficProgress] = []
    private var activeAtCompletion: [Int] = []
    private var partialFailure: (client: DownloadProtocol, code: URLError.Code, bytes: Int64)?

    func record(_ request: URLRequest, from client: DownloadProtocol) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard request.value(forHTTPHeaderField: "X-Fixture-Run") == runID else { return false }
        requests.append(request)
        active.insert(ObjectIdentifier(client))
        peak = max(peak, active.count)
        return true
    }
    func finished(_ client: DownloadProtocol) {
        lock.lock(); defer { lock.unlock() }
        guard client.request.value(forHTTPHeaderField: "X-Fixture-Run") == runID else { return }
        active.remove(ObjectIdentifier(client))
        parked.removeAll { $0 === client }
    }
    func park(_ client: DownloadProtocol, until count: Int) -> [DownloadProtocol] {
        lock.lock(); defer { lock.unlock() }
        guard client.request.value(forHTTPHeaderField: "X-Fixture-Run") == runID else { return [] }
        parked.append(client)
        guard parked.count == count else { return [] }
        let ready = parked
        parked.removeAll()
        return ready
    }
    func update(_ progress: TrafficProgress) {
        lock.lock()
        updates.append(progress)
        if progress.stopReason != nil { activeAtCompletion.append(active.count) }
        let failure = partialFailure.flatMap { progress.receivedBytes >= $0.bytes ? $0 : nil }
        if failure != nil { partialFailure = nil }
        lock.unlock()
        // Model loss after a chunk was actually delivered to the delegate.
        // Failing immediately after didReceive can make URLSession discard the
        // fixture's data before the asynchronous response disposition returns.
        if let failure { failure.client.fail(failure.code) }
    }
    func failAfterReceiving(_ client: DownloadProtocol, code: URLError.Code, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        partialFailure = (client, code, bytes)
    }
    func reset() -> String {
        lock.lock(); defer { lock.unlock() }
        runID = UUID().uuidString
        requests.removeAll(); active.removeAll(); parked.removeAll(); updates.removeAll(); activeAtCompletion.removeAll(); peak = 0
        partialFailure = nil
        return runID
    }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func peakActive() -> Int { lock.lock(); defer { lock.unlock() }; return peak }
    func activeCount() -> Int { lock.lock(); defer { lock.unlock() }; return active.count }
    func progressUpdates() -> [TrafficProgress] { lock.lock(); defer { lock.unlock() }; return updates }
    func completionTransports() -> [Int] { lock.lock(); defer { lock.unlock() }; return activeAtCompletion }
}

nonisolated final class DownloadProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        lock.lock(); stopped = true; lock.unlock()
        DownloadFixture.shared.finished(self)
    }
    override func startLoading() {
        guard DownloadFixture.shared.record(request, from: self) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        guard let url = request.url else { return }
        let path = url.path
        let attempt = DownloadFixture.shared.snapshot().count
        if path == "/flaky", attempt == 1 { fail(.networkConnectionLost, bytes: 768); return }
        if path == "/repeated-flaky", attempt % 2 == 1 { fail(.networkConnectionLost); return }
        if path == "/offline" { fail(.timedOut); return }
        if path == "/untrusted" { fail(.serverCertificateUntrusted); return }
        if path == "/throttled", attempt == 1 { reply(code: 429, bytes: 0, retryAfter: "0.05"); return }
        if path == "/unavailable", attempt == 1 { reply(code: 503, bytes: 0); return }
        if path == "/busy" { reply(code: 503, bytes: 0); return }
        if path == "/long-wait" { reply(code: 429, bytes: 0, retryAfter: "3600"); return }
        if path == "/chunk" {
            // Ignores Range and leaves the response open after sending a chunk.
            // Only the engine's bounded-request cancellation releases this slot.
            reply(bytes: 2_048, finish: false)
            return
        }
        if path == "/short-wave" {
            // First wave finishes with a file smaller than each reservation;
            // the next wave remains open so refill timing can be inspected.
            let count = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "4") ?? 4
            guard attempt <= count else { return }
            let ready = DownloadFixture.shared.park(self, until: count)
            guard !ready.isEmpty else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
                for worker in ready { worker.reply(bytes: 2_048) }
            }
            return
        }
        if path == "/wait" { return }
        if path == "/barrier" || path == "/parallel-error" || path == "/parallel-recovery" {
            let count = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "64") ?? 64
            if path == "/parallel-recovery", attempt > count { reply(bytes: 1_024); return }
            let ready = DownloadFixture.shared.park(self, until: count)
            guard !ready.isEmpty else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
                if path == "/parallel-error" {
                    // One worker fails while every other worker is still waiting.
                    ready[0].reply(code: 403, bytes: 0)
                } else {
                    for (index, worker) in ready.enumerated() {
                        if path == "/parallel-recovery" && index == 0 {
                            worker.fail(.networkConnectionLost)
                            continue
                        }
                        let lastByte = worker.request.value(forHTTPHeaderField: "Range")?.split(separator: "-").last
                        let bytes = Int(lastByte ?? "1023")! + 1
                        worker.reply(bytes: bytes)
                    }
                }
            }
            return
        }
        let redirect: String?
        switch path {
        case "/same": redirect = "https://origin.example/file"
        case "/parallel-same": redirect = "https://origin.example/barrier?n=64"
        case "/cross": redirect = "https://elsewhere.example/file"
        case "/downgrade": redirect = "http://origin.example/file"
        case "/loop": redirect = "https://origin.example/loop"
        default: redirect = nil
        }
        if let redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": redirect])!
            DownloadFixture.shared.finished(self)
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: redirect)!), redirectResponse: response)
            return
        }
        reply(code: path == "/error" ? 403 : (path == "/empty" ? 204 : 200),
              bytes: path == "/zero" ? 0 : 2_048,
              mime: path == "/html" ? "text/html" : "application/octet-stream")
    }

    func fail(_ code: URLError.Code, bytes: Int = 0) {
        if bytes > 0 {
            DownloadFixture.shared.failAfterReceiving(self, code: code, bytes: Int64(bytes))
            reply(bytes: bytes, finish: false)
            return
        }
        DownloadFixture.shared.finished(self)
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }

    func reply(code: Int = 200, bytes: Int, mime: String = "application/octet-stream",
               retryAfter: String? = nil, finish: Bool = true) {
        lock.lock(); let stopped = stopped; lock.unlock()
        guard !stopped, let url = request.url else { return }
        var headers = ["Content-Type": mime, "Cache-Control": "max-age=3600"]
        headers["Retry-After"] = retryAfter
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        if bytes > 0 { client?.urlProtocol(self, didLoad: Data(repeating: 7, count: bytes)) }
        if finish {
            DownloadFixture.shared.finished(self)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@main
struct TrafficDownloadChecks {
    private static var checks = 0
    private struct Failure: Error { let message: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw Failure(message: message) }
    }

    static func main() async throws {
        try policyChecks()
        let target = try await run("file", target: 1_000)
        try expect(target.stopReason == .targetReached, "Target automatically stops the task")
        try expect(target.receivedBytes == 2_048, "Count the actual chunk, including in-flight excess")
        try expect(target.bytesPerSecond == 0, "Finished transfer does not show an old live speed")
        try expect(DownloadFixture.shared.snapshot().count == 1, "No new request after reaching the target")
        let request = DownloadFixture.shared.snapshot().first!
        try expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-999", "Request only the remaining target when supported")
        try expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData, "Do not consume from local cache")

        let repeated = try await run("file", target: 5_000)
        try expect(repeated.stopReason == .targetReached && repeated.receivedBytes == 6_144, "Repeat a short file sequentially")
        try expect(DownloadFixture.shared.snapshot().count == 3, "Stop repeated downloads at the goal")
        try expect(repeated.completedRequests == 2, "Only fully finished requests count as completed")

        let same = try await run("same")
        try expect(same.stopReason == .targetReached, "Allow same-origin redirects")
        try expect(DownloadFixture.shared.snapshot().count == 2, "Follow only the permitted redirect")
        let cross = try await run("cross")
        try expect(cross.stopReason == .failed(.blockedRedirect), "Block cross-origin redirects before fetching")
        try expect(DownloadFixture.shared.snapshot().allSatisfy { $0.url?.host == "origin.example" }, "Blocked host receives no request")
        let allowed = try await run("cross", policy: .anyHTTPS)
        try expect(allowed.stopReason == .targetReached && allowed.currentOrigin == "elsewhere.example", "Optional cross-origin mode exposes the actual destination")
        let downgrade = try await run("downgrade", policy: .anyHTTPS)
        try expect(downgrade.stopReason == .failed(.blockedRedirect), "Never downgrade to cleartext")
        let loop = try await run("loop")
        try expect(loop.stopReason == .failed(.tooManyRedirects), "Stop redirect loops")
        try expect(DownloadFixture.shared.snapshot().count == 6, "Redirect bound is enforced")

        let forbidden = try await run("error")
        try expect(forbidden.stopReason == .failed(.httpStatus(403)), "HTTP errors stop without retrying")
        try expect(forbidden.receivedBytes == 0, "Do not count an HTTP error body as a download")
        let html = try await run("html")
        try expect(html.stopReason == .failed(.webpage), "Reject share/login pages and never load their resources")
        let zero = try await run("zero")
        try expect(zero.stopReason == .failed(.emptyResponse), "Empty downloads do not loop")
        let timeout = try await run("wait", duration: 0.2)
        try expect(timeout.stopReason == .timeLimit, "Total deadline stops a stalled request")
        let stopped = try await run("wait", cancel: .user)
        try expect(stopped.stopReason == .user, "Stop button cancels a pending request")
        let background = try await run("wait", cancel: .background)
        try expect(background.stopReason == .background, "Backgrounding cancels a pending request")
        try await concurrencyChecks()
        try await recoveryChecks()
        print("PASS: \(checks) traffic-consumer checks; all requests intercepted locally.")
    }

    private static func concurrencyChecks() async throws {
        for count in [0, 65, -1] {
            do {
                _ = try TrafficDownloadPlan(link: "https://origin.example/file", targetBytes: 1_000,
                                           concurrentDownloads: count, redirectPolicy: .sameOrigin)
                throw Failure(message: "Invalid concurrency accepted")
            } catch let failure as TrafficFailure {
                try expect(failure == .invalidConcurrency, "Reject out-of-range thread count")
            }
        }
        let parallel = try await run("barrier?n=64", target: 65_536, concurrency: 64)
        try expect(parallel.stopReason == .targetReached, "64 workers can reach their shared goal")
        try expect(parallel.receivedBytes == 65_536, "Aggregate concurrent bytes without multiplying the goal")
        try expect(DownloadFixture.shared.peakActive() == 64, "All 64 requests overlap before any response is released")
        let requests = DownloadFixture.shared.snapshot()
        try expect(requests.count == 64, "Bound the active request count")
        let allocated = requests.reduce(0) { total, request in
            total + Int(request.value(forHTTPHeaderField: "Range")!.split(separator: "-").last!)! + 1
        }
        try expect(allocated == 65_536, "Distribute the target across workers")
        let updates = DownloadFixture.shared.progressUpdates()
        try expect(updates.allSatisfy { $0.activeDownloads <= 64 }, "Never report more than 64 active tasks")
        try expect(zip(updates, updates.dropFirst()).allSatisfy { $0.receivedBytes <= $1.receivedBytes && $0.sequence < $1.sequence }, "Concurrent progress remains monotonic")
        try expect(parallel.activeDownloads == 0, "No active task after target completion")

        let redirects = try await run("parallel-same", target: 65_536, concurrency: 64)
        try expect(redirects.stopReason == .targetReached, "Redirect limits belong to each worker, not the entire pool")
        try expect(DownloadFixture.shared.snapshot().count == 128, "Every worker follows its own valid redirect")
        let cross = try await run("cross", target: 65_536, concurrency: 64)
        try expect(cross.stopReason == .failed(.blockedRedirect), "Cross-origin failure stops the entire pool")
        try expect(DownloadFixture.shared.snapshot().allSatisfy { $0.url?.host == "origin.example" }, "No worker follows a blocked host")

        let failure = try await run("parallel-error?n=64", target: 65_536, concurrency: 64)
        try expect(failure.stopReason == .failed(.httpStatus(403)), "One HTTP error cancels every worker")
        try expect(DownloadFixture.shared.peakActive() == 64 && DownloadFixture.shared.activeCount() == 0,
                   "All pending transports are canceled on a worker error")
        let timeout = try await run("wait", target: 65_536, concurrency: 64, duration: 0.3)
        try expect(timeout.stopReason == .timeLimit && DownloadFixture.shared.activeCount() == 0,
                   "Deadline cancels the entire pool")
        let canceled = try await run("wait", target: 65_536, concurrency: 64, cancel: .user)
        try expect(canceled.stopReason == .user && canceled.activeDownloads == 0 && DownloadFixture.shared.activeCount() == 0,
                   "Manual stop cancels every worker")
        let background = try await run("wait", target: 65_536, concurrency: 64, cancel: .background)
        try expect(background.stopReason == .background && DownloadFixture.shared.activeCount() == 0,
                   "Backgrounding cancels every worker")

        for goal: Int64 in [400_000_000_000, Int64.max] {
            let stopped = try await run("parallel-error?n=64", target: goal, concurrency: 64)
            try expect(stopped.stopReason == .failed(.httpStatus(403)), "Large goals reach request scheduling without a size cap")
            let reservations = DownloadFixture.shared.snapshot().reduce(Int64(0)) { total, request in
                total + Int64(request.value(forHTTPHeaderField: "Range")!.split(separator: "-").last!)! + 1
            }
            try expect(reservations == 64 * TrafficTransferPolicy().requestByteLimit && reservations < goal,
                       "Large goals reserve only bounded chunks without arithmetic overflow")
        }

        let small = try await run("file", target: 1, concurrency: 64)
        try expect(small.stopReason == .targetReached && DownloadFixture.shared.snapshot().count == 1,
                   "A tiny remaining goal does not launch 64 full downloads")
        let repeated = try await run("file", target: 20_000, concurrency: 4, duration: 10)
        try expect(repeated.stopReason == .targetReached && repeated.receivedBytes >= 20_000,
                   "Short files refill workers without stalling the shared goal")
        try expect(DownloadFixture.shared.progressUpdates().allSatisfy { $0.activeDownloads <= 4 },
                   "Refills obey the configured concurrency")
        let shortWave = try await run("short-wave?n=4", target: 4 * 1_000_000,
                                      concurrency: 4, cancel: .user)
        try expect(shortWave.stopReason == .user && DownloadFixture.shared.snapshot().count == 8,
                   "Refill every worker immediately after a short file completes")
        try expect(DownloadFixture.shared.peakActive() == 4,
                   "Short-file refills keep all four transport slots in use")
        let countAtStop = DownloadFixture.shared.snapshot().count
        try await Task.sleep(for: .milliseconds(100))
        try expect(DownloadFixture.shared.snapshot().count == countAtStop,
                   "Stopping the short-file pool prevents further requests")
    }

    private static func recoveryChecks() async throws {
        let quick = TrafficTransferPolicy(retryDelays: [0.02, 0.04])
        let recovered = try await run("flaky", target: 2_000, transferPolicy: quick)
        try expect(recovered.stopReason == .targetReached && recovered.receivedBytes == 2_816,
                   "Connection loss after partial data preserves every received byte (actual: \(recovered.receivedBytes), reason: \(String(describing: recovered.stopReason)))")
        try expect(recovered.retryCount == 1 && DownloadFixture.shared.snapshot().count == 2,
                   "Recover a worker without restarting the goal")
        try expect(DownloadFixture.shared.snapshot().last?.value(forHTTPHeaderField: "Range") == "bytes=0-1231",
                   "A retried request reserves only the remaining target")
        try expect(DownloadFixture.shared.progressUpdates().contains { $0.retryingDownloads == 1 },
                   "Expose reconnection state while backing off")
        let exhausted = try await run("offline", transferPolicy: quick)
        try expect(exhausted.stopReason == .failed(.networkCode(URLError.timedOut.rawValue)),
                   "Preserve a useful error code after retry exhaustion")
        try expect(exhausted.retryCount == 2 && DownloadFixture.shared.snapshot().count == 3,
                   "Repeated timeouts have a finite retry budget")
        let stopped = try await run("offline", cancel: .user)
        let attempts = DownloadFixture.shared.snapshot().count
        try await Task.sleep(for: .milliseconds(1_100))
        try expect(stopped.stopReason == .user && DownloadFixture.shared.snapshot().count == attempts,
                   "Stopping during backoff cancels scheduled retries")
        let timedOut = try await run("offline", duration: 0.1)
        try expect(timedOut.stopReason == .timeLimit && timedOut.retryCount == 1,
                   "A user deadline also ends pending retries")
        let untrusted = try await run("untrusted", transferPolicy: quick)
        try expect(untrusted.stopReason == .failed(.networkCode(URLError.serverCertificateUntrusted.rawValue)) && untrusted.retryCount == 0,
                   "Certificate errors are not bypassed or retried")
        let forbidden = try await run("error", transferPolicy: quick)
        try expect(forbidden.stopReason == .failed(.httpStatus(403)) && forbidden.retryCount == 0,
                   "Expired or forbidden links still require user action")
        for path in ["throttled", "unavailable"] {
            let recovered = try await run(path, transferPolicy: quick)
            try expect(recovered.stopReason == .targetReached && recovered.retryCount == 1,
                       "Retry recoverable HTTP response: \(path)")
            if path == "throttled" { try expect(recovered.elapsed >= 0.05, "Honor Retry-After") }
        }
        let busy = try await run("busy", transferPolicy: quick)
        try expect(busy.stopReason == .failed(.httpStatus(503)) && busy.retryCount == 2,
                   "Persistent HTTP failure exhausts the same finite retry budget")
        let longWait = try await run("long-wait", transferPolicy: quick)
        try expect(longWait.stopReason == .failed(.httpStatus(429)) && DownloadFixture.shared.snapshot().count == 1,
                   "Do not ignore long server retry delays or silently hang")
        let repeated = try await run("repeated-flaky", target: 5_000,
                                    transferPolicy: TrafficTransferPolicy(retryDelays: [0.02]))
        try expect(repeated.stopReason == .targetReached && repeated.retryCount == 3,
                   "Successful requests reset consecutive failures during a long run")
        let chunked = try await run("chunk", target: 5_000,
                                   transferPolicy: TrafficTransferPolicy(requestByteLimit: 1_024))
        try expect(chunked.stopReason == .targetReached && chunked.receivedBytes == 6_144 && chunked.retryCount == 0,
                   "Recycle a server that ignores Range without treating cancellation as a failure")
        try expect(DownloadFixture.shared.snapshot().count == 3 && DownloadFixture.shared.peakActive() == 1,
                   "Drain a chunk cancellation before reusing its slot")
        let parallel = try await run("parallel-recovery?n=64", target: 65_536, concurrency: 64, transferPolicy: quick)
        try expect(parallel.stopReason == .targetReached && parallel.retryCount == 1,
                   "A transient worker error does not fail 63 healthy workers")
        try expect(DownloadFixture.shared.peakActive() <= 64 && parallel.activeDownloads == 0 && parallel.retryingDownloads == 0,
                   "Recovery keeps concurrency bounded and cleans up all retries")
        let now = Date(timeIntervalSince1970: 1_000)
        try expect(TrafficTransferPolicy.retryAfter("Thu, 01 Jan 1970 00:17:10 GMT", now: now) == 30,
                   "Parse HTTP-date Retry-After")
        try expect(TrafficTransferPolicy.retryAfter("invalid") == nil && TrafficTransferPolicy.retryAfter("NaN") == nil,
                   "Malformed retry delays do not become timers")
        try expect(!TrafficTransferPolicy.retries(URLError(.cancelled)) && !TrafficTransferPolicy.retries(status: 401),
                   "Cancellation and authorization errors are terminal")
    }

    private static func policyChecks() throws {
        let origin = try TrafficOrigin(url: URL(string: "https://Origin.Example/a?token=private")!)
        try expect(origin.displayName == "origin.example", "Display only the domain, never query tokens")
        for link in ["https://origin.example/b", "https://ORIGIN.example:443/file"] {
            try expect(TrafficRedirectPolicy.sameOrigin.allows(URL(string: link)!, from: origin), "Canonical same-origin URL")
        }
        for link in ["https://cdn.origin.example/file", "https://example/file", "https://origin.example:444/file", "http://origin.example/file", "https://origin.example.evil.test/file", "https://name:pass@origin.example/file"] {
            try expect(!TrafficRedirectPolicy.sameOrigin.allows(URL(string: link)!, from: origin), "No origin escape: \(link)")
        }
        for link in ["file:///tmp/test", "http://origin.example/file", "https://name:pass@origin.example/file", "https://origin.example/file\nInjected: x"] {
            do {
                _ = try TrafficDownloadPlan(link: link, targetBytes: 1_000, redirectPolicy: .sameOrigin)
                throw Failure(message: "Invalid link accepted")
            } catch is TrafficFailure { checks += 1 }
        }
        do {
            _ = try TrafficDownloadPlan(link: "https://origin.example/file", targetBytes: 0, redirectPolicy: .sameOrigin)
            throw Failure(message: "Invalid limit accepted")
        } catch is TrafficFailure { checks += 1 }
        let plan = try TrafficDownloadPlan(link: "https://origin.example/file?token=x", targetBytes: 1_000, redirectPolicy: .anyHTTPS)
        let redirected = plan.request(for: URL(string: "https://other.example/file")!, remainingBytes: 500)
        try expect(redirected.url?.query == nil, "Do not copy the initial URL's query to another domain")
        try expect(redirected.value(forHTTPHeaderField: "Authorization") == nil && redirected.value(forHTTPHeaderField: "Cookie") == nil && redirected.value(forHTTPHeaderField: "Referer") == nil, "Redirected requests have no inherited credentials or referrer")
    }

    private static func run(_ path: String, target: Int64 = 1_000,
                            policy: TrafficRedirectPolicy = .sameOrigin,
                            concurrency: Int = 1,
                            duration: TimeInterval = 5,
                            cancel: TrafficStopReason? = nil,
                            transferPolicy: TrafficTransferPolicy = TrafficTransferPolicy()) async throws -> TrafficProgress {
        let fixtureID = DownloadFixture.shared.reset()
        let plan = try TrafficDownloadPlan(link: "https://origin.example/\(path)", targetBytes: target,
                                           durationLimit: duration, concurrentDownloads: concurrency, redirectPolicy: policy)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-Run": fixtureID]
        let result: TrafficProgress = await withCheckedContinuation { continuation in
            let engine = TrafficDownloadEngine(plan: plan, configuration: configuration, policy: transferPolicy) { progress in
                DownloadFixture.shared.update(progress)
                if progress.stopReason != nil { continuation.resume(returning: progress) }
            }
            engine.start()
            if let cancel {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { engine.cancel(reason: cancel) }
            }
        }
        for _ in 0..<100 {
            if DownloadFixture.shared.activeCount() == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Foundation can deliver session invalidation before the custom protocol's
        // stopLoading cleanup returns. Check eventual fixture cleanup, not callback
        // simultaneity, and isolate each run from late protocol callbacks.
        try expect(DownloadFixture.shared.completionTransports().count == 1 && DownloadFixture.shared.activeCount() == 0,
                   "One completion and eventual cancellation cleanup for \(path)")
        return result
    }
}

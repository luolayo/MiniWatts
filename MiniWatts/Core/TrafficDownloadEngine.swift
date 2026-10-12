import Foundation

/// All mutable state, including URLSession delegate callbacks, is confined to
/// `queue`. Public start/cancel enqueue work; the UI only receives value snapshots.
/// The delegate is Sendable because this serial queue protects its state.
nonisolated final class TrafficDownloadEngine: NSObject, URLSessionDataDelegate, TrafficDownloading, @unchecked Sendable {
    private let plan: TrafficDownloadPlan
    private let configuration: URLSessionConfiguration
    private let policy: TrafficTransferPolicy
    private let onProgress: @Sendable (TrafficProgress) -> Void
    private let queue = DispatchQueue(label: "MiniWatts.traffic-download")
    private let delegateQueue = OperationQueue()
    private var session: URLSession?
    private struct RequestState {
        let task: URLSessionDataTask
        let slot: Int
        let budget: Int64
        var receivedBytes: Int64 = 0
        var redirects: Int = 0
        var origin: String
        var completedChunk = false
        var retryFailure: TrafficFailure?
        var retryAfter: TimeInterval?

        var reservedBytes: Int64 { max(0, budget - receivedBytes) }
    }
    private var requests: [Int: RequestState] = [:]
    private var cooldowns: [Int: DispatchWorkItem] = [:]
    private var consecutiveFailures: [Int: Int] = [:]
    private var retryingSlots: Set<Int> = []
    private var started = false
    private var finished = false
    private var completionReported = false
    private var progress = TrafficProgress()
    private var startedAt: TimeInterval = 0
    private var previousReportAt: TimeInterval = 0
    private var previousReportBytes: Int64 = 0
    private var deadline: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?

    init(plan: TrafficDownloadPlan,
         configuration: URLSessionConfiguration = .ephemeral,
         policy: TrafficTransferPolicy = TrafficTransferPolicy(),
         onProgress: @escaping @Sendable (TrafficProgress) -> Void) {
        self.plan = plan
        self.configuration = configuration
        self.policy = policy
        self.onProgress = onProgress
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
    }

    func start() {
        queue.async { [self] in
            guard !started, !finished else { return }
            started = true
            startedAt = ProcessInfo.processInfo.systemUptime
            previousReportAt = startedAt
            progress.currentOrigin = plan.origin.displayName
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpMaximumConnectionsPerHost = plan.concurrentDownloads
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = min(plan.durationLimit ?? 300, 300)
            configuration.allowsCellularAccess = true
            configuration.waitsForConnectivity = false
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            if let limit = plan.durationLimit {
                let deadline = DispatchWorkItem { [weak self] in self?.finish(.timeLimit) }
                self.deadline = deadline
                queue.asyncAfter(wallDeadline: .now() + limit, execute: deadline)
            }
            let heartbeat = DispatchSource.makeTimerSource(queue: queue)
            heartbeat.schedule(deadline: .now() + 1, repeating: 1)
            heartbeat.setEventHandler { [weak self] in self?.report(force: true) }
            self.heartbeat = heartbeat
            heartbeat.resume()
            fillAvailableSlots()
            report(force: true)
        }
    }

    func cancel(reason: TrafficStopReason = .user) {
        queue.async { [self] in finish(reason) }
    }

    /// Reserve a share of the remaining goal for each request instead of giving
    /// every worker the entire goal. Short files return unused budget on completion.
    /// Network transfers run concurrently; only accounting callbacks are serialized.
    private func fillAvailableSlots() {
        guard !finished, let session else { return }
        let remaining = plan.targetBytes - progress.receivedBytes
        guard remaining > 0 else { finish(.targetReached); return }
        var availableBytes = remaining - requests.values.reduce(0) { $0 + $1.reservedBytes }
        guard availableBytes > 0 else { return }
        let occupiedSlots = Set(requests.values.map(\.slot))
        let freeSlots = (0..<plan.concurrentDownloads).filter {
            !occupiedSlots.contains($0) && cooldowns[$0] == nil
        }
        let workers = Int64(plan.concurrentDownloads)
        let maximumRequestBytes = min(policy.requestByteLimit,
            plan.targetBytes / workers + (plan.targetBytes % workers == 0 ? 0 : 1))
        for (index, slot) in freeSlots.enumerated() {
            guard availableBytes > 0 else { break }
            let divisor = Int64(freeSlots.count - index)
            // A worker whose cooldown expires first must not reserve the entire
            // remainder while other workers are about to become available.
            let budget = min(maximumRequestBytes, availableBytes / divisor + (availableBytes % divisor == 0 ? 0 : 1))
            let task = session.dataTask(with: plan.request(remainingBytes: budget))
            requests[task.taskIdentifier] = RequestState(task: task, slot: slot, budget: budget,
                                                       origin: plan.origin.displayName)
            availableBytes -= budget
            task.resume()
        }
        report()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard !finished, var state = requests[task.taskIdentifier] else { completionHandler(nil); return }
        guard let url = request.url, plan.redirectPolicy.allows(url, from: plan.origin) else {
            completionHandler(nil)
            finish(.failed(.blockedRedirect))
            return
        }
        state.redirects += 1
        guard state.redirects <= 5 else {
            completionHandler(nil)
            finish(.failed(.tooManyRedirects))
            return
        }
        state.origin = (try? TrafficOrigin(url: url).displayName) ?? ""
        requests[task.taskIdentifier] = state
        report(force: true)
        completionHandler(plan.request(for: url, remainingBytes: state.reservedBytes))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !finished, var state = requests[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, let url = response.url,
              plan.redirectPolicy.allows(url, from: plan.origin) else {
            completionHandler(.cancel)
            finish(.failed(.invalidResponse))
            return
        }
        guard response.statusCode == 200 || response.statusCode == 206 else {
            if TrafficTransferPolicy.retries(status: response.statusCode) {
                state.retryFailure = .httpStatus(response.statusCode)
                state.retryAfter = TrafficTransferPolicy.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
                requests[dataTask.taskIdentifier] = state
                // Wait for didComplete before releasing this slot. Never consume
                // an error page or count it toward the download goal.
                completionHandler(.cancel)
                return
            }
            completionHandler(.cancel)
            finish(.failed(.httpStatus(response.statusCode)))
            return
        }
        let mime = response.mimeType?.lowercased() ?? ""
        if ["text/html", "application/xhtml+xml", "application/vnd.apple.mpegurl",
            "application/x-mpegurl", "application/dash+xml"].contains(mime) {
            completionHandler(.cancel)
            finish(.failed(.webpage))
            return
        }
        state.origin = (try? TrafficOrigin(url: url).displayName) ?? ""
        requests[dataTask.taskIdentifier] = state
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, var state = requests[dataTask.taskIdentifier], state.retryFailure == nil else { return }
        // Keep only the count. No accumulation, decoding, media playback or disk writes.
        let count = Int64(data.count)
        let total = progress.receivedBytes.addingReportingOverflow(count)
        let perRequest = state.receivedBytes.addingReportingOverflow(count)
        progress.receivedBytes = total.overflow ? Int64.max : total.partialValue
        state.receivedBytes = perRequest.overflow ? Int64.max : perRequest.partialValue
        requests[dataTask.taskIdentifier] = state
        if progress.receivedBytes >= plan.targetBytes {
            finish(.targetReached)
        } else {
            if state.receivedBytes >= state.budget && !state.completedChunk {
                // Some servers ignore Range and stream the entire file. Recycle
                // this data task at the chunk boundary without creating a file.
                state.completedChunk = true
                requests[dataTask.taskIdentifier] = state
                dataTask.cancel()
            }
            report()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished, let state = requests.removeValue(forKey: task.taskIdentifier) else { return }
        if let failure = state.retryFailure {
            retry(state, failure: failure, retryAfter: state.retryAfter)
            return
        }
        if let error, !state.completedChunk {
            let failure = TrafficTransferPolicy.failure(for: error)
            if TrafficTransferPolicy.retries(error) { retry(state, failure: failure) }
            else { finish(.failed(failure)) }
            return
        }
        guard state.receivedBytes > 0 else { finish(.failed(.emptyResponse)); return }
        consecutiveFailures[state.slot] = nil
        progress.completedRequests += 1
        // A successful short response is still useful data. Refill its slot as
        // soon as the transport completes so small files do not leave workers
        // idle for a second between requests. Failures alone use backoff.
        fillAvailableSlots()
    }

    private func retry(_ state: RequestState, failure: TrafficFailure, retryAfter: TimeInterval? = nil) {
        let attempt = consecutiveFailures[state.slot, default: 0]
        guard attempt < policy.retryDelays.count else { finish(.failed(failure)); return }
        // Do not retry earlier than the server asks. Excessive delays end with
        // the HTTP status rather than leaving an apparently stuck task for hours.
        guard (retryAfter ?? 0) <= 300 else { finish(.failed(failure)); return }
        consecutiveFailures[state.slot] = attempt + 1
        progress.retryCount += 1
        progress.lastRetryFailure = failure
        retryingSlots.insert(state.slot)
        schedule(state.slot, after: max(policy.retryDelays[attempt], retryAfter ?? 0))
    }

    private func schedule(_ slot: Int, after delay: TimeInterval) {
        // Each slot waits independently; healthy workers continue. Already
        // received bytes stay counted and only the remaining target is reserved.
        let next = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.cooldowns.removeValue(forKey: slot)
            self.retryingSlots.remove(slot)
            self.fillAvailableSlots()
        }
        cooldowns[slot] = next
        queue.asyncAfter(deadline: .now() + delay, execute: next)
        fillAvailableSlots()
        report(force: retryingSlots.contains(slot))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !finished, requests[task.taskIdentifier] != nil else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Preserve standard certificate and hostname validation.
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failed(.authentication))
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        self.session = nil
        if !finished {
            finish(.failed(error.map { TrafficTransferPolicy.failure(for: $0) } ?? .network))
        } else {
            reportCompletion()
        }
    }

    private func finish(_ reason: TrafficStopReason) {
        guard !finished else { return }
        finished = true
        for pending in cooldowns.values { pending.cancel() }
        cooldowns.removeAll()
        retryingSlots.removeAll()
        deadline?.cancel()
        heartbeat?.cancel()
        heartbeat = nil
        for state in requests.values { state.task.cancel() }
        requests.removeAll()
        progress.stopReason = reason
        if let session {
            // Keep the background lease until URLSession has actually drained its
            // cancellations. Reporting completion earlier can suspend the process
            // while transports and their delegate callbacks are still alive.
            session.invalidateAndCancel()
        } else {
            reportCompletion()
        }
    }

    private func reportCompletion() {
        guard !completionReported else { return }
        completionReported = true
        report(force: true, terminal: true)
    }

    private func report(force: Bool = false, terminal: Bool = false) {
        guard !finished || terminal else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - previousReportAt
        guard force || elapsed >= 0.35 else { return }
        progress.elapsed = started ? max(0, now - startedAt) : 0
        progress.activeDownloads = requests.count
        progress.retryingDownloads = retryingSlots.count
        let origins = Set(requests.values.map(\.origin)).sorted()
        if !origins.isEmpty { progress.currentOrigin = origins.joined(separator: ", ") }
        if finished {
            progress.bytesPerSecond = 0
        } else if elapsed >= 0.35 {
            // Status events can occur only microseconds apart. Do not turn a
            // reconnect/redirect notification into a zero-speed sample or spike.
            progress.bytesPerSecond = Double(progress.receivedBytes - previousReportBytes) / elapsed
            previousReportAt = now
            previousReportBytes = progress.receivedBytes
        }
        progress.sequence += 1
        onProgress(progress)
    }
}

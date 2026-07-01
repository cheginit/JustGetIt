import Foundation

/// Wraps a non-Sendable `URLSessionDataTask` so it can be stored on the actor
/// purely to call the thread-safe `cancel()`.
private struct DataTaskBox: @unchecked Sendable {
    let task: URLSessionDataTask
}

/// Drives one file download across several concurrent byte-range connections,
/// writing each segment to its own offset in a single pre-allocated `.download`
/// file. Network and disk work happen off the actor (nonisolated); only the
/// shared progress counters are actor-isolated.
actor DownloadCoordinator {
    enum Outcome: Sendable { case completed, paused, canceled }

    let id: UUID
    private let url: URL
    private let partURL: URL
    private let info: RemoteFileInfo
    private let session: URLSession
    private let delegate: SegmentDataDelegate
    private let gate: ConnectionGate
    private let maxWorkers: Int
    private let emit: @Sendable (DownloadEvent) -> Void

    private var segments: [SegmentState]
    private var pending: [Int] = []          // indices of chunks not yet claimed by a worker
    private var totalReceived: Int64
    private var urlTasks: [Int: DataTaskBox] = [:]   // keyed by chunk index (one attempt at a time)
    private var lastActivity: [Int: Date] = [:]      // chunk index → time of last received byte
    private var isPausing = false
    private var isCanceling = false

    // Stall detection / retry.
    private let stallTimeout: TimeInterval = 30
    private let maxAttempts = 5

    // Speed sampling (throttled emission).
    private var lastEmit = Date.distantPast
    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime = Date()

    init(id: UUID,
         url: URL,
         partURL: URL,
         info: RemoteFileInfo,
         segments: [SegmentState],
         session: URLSession,
         delegate: SegmentDataDelegate,
         gate: ConnectionGate,
         maxWorkers: Int,
         emit: @escaping @Sendable (DownloadEvent) -> Void) {
        self.id = id
        self.url = url
        self.partURL = partURL
        self.info = info
        self.segments = segments
        self.session = session
        self.delegate = delegate
        self.gate = gate
        self.maxWorkers = max(1, maxWorkers)
        self.emit = emit
        self.totalReceived = segments.reduce(0) { $0 + $1.received }
        self.lastSampleBytes = totalReceived
    }

    var currentSegments: [SegmentState] { segments }

    func requestPause() {
        isPausing = true
        cancelAllTasks()
    }

    func requestCancel() {
        isCanceling = true
        cancelAllTasks()
    }

    private func cancelAllTasks() {
        for box in urlTasks.values { box.task.cancel() }
    }

    func run() async throws -> Outcome {
        pending = segments.indices.filter { !segments[$0].isComplete }
        let workerCount = min(maxWorkers, max(1, pending.count))

        // Watchdog: cancel any connection that hasn't delivered a byte within
        // `stallTimeout`; its worker then retries the chunk from where it stopped.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.checkForStalls()
            }
        }
        defer { watchdog.cancel() }

        return try await withThrowingTaskGroup(of: Void.self) { group -> Outcome in
            for _ in 0..<workerCount {
                group.addTask { try await self.worker() }
            }
            do {
                for try await _ in group {}
            } catch {
                cancelAllTasks()
                group.cancelAll()
                if isCanceling { return .canceled }
                if isPausing { return .paused }
                throw error
            }
            if isCanceling { return .canceled }
            if isPausing { return .paused }
            return .completed
        }
    }

    /// Hand the next pending chunk to a free worker. Returning `nil` means
    /// "no more work" — the worker then exits. This is the work-stealing point:
    /// a fast connection comes back here and grabs another chunk while slow
    /// connections are still busy.
    private func claimNextChunk() -> SegmentState? {
        guard !isPausing, !isCanceling, !pending.isEmpty else { return nil }
        let index = pending.removeFirst()
        return segments[index]
    }

    // MARK: - Off-actor worker loop

    private nonisolated func worker() async throws {
        while let chunk = await claimNextChunk() {
            await gate.acquire()
            if await isStopping() { await gate.release(); return }   // paused/canceled while queued on the gate
            do {
                try await performSegment(index: chunk.id)
                await gate.release()
            } catch {
                await gate.release()
                throw error
            }
        }
    }

    /// Download one chunk, retrying on stalls, transient network errors, and transient
    /// server statuses (429/503/…) while preserving bytes already written. A true 4xx
    /// (404/403/…) is fatal — no point hammering the server.
    private nonisolated func performSegment(index: Int) async throws {
        var attempt = 0
        while true {
            let segment = await currentSegment(index)
            do {
                try await downloadChunk(index: index, segment: segment)
                await unregister(index: index)
                return
            } catch let error as DownloadError {
                await unregister(index: index)
                guard case .serverBusy(_, let retryAfter) = error else {
                    throw error                                   // permanent (4xx etc.) — don't retry
                }
                attempt += 1                                      // server asked us to back off — retry
                if attempt >= maxAttempts { throw error }
                try? await Task.sleep(for: retryAfter.map { .seconds($0) } ?? Self.backoffDelay(attempt))
            } catch let error as URLError where error.code == .cancelled {
                await unregister(index: index)
                if await isStopping() { return }                  // user paused/canceled
                attempt += 1                                      // stalled connection — retry
                if attempt >= maxAttempts { throw error }
                try? await Task.sleep(for: Self.backoffDelay(attempt))
            } catch {
                await unregister(index: index)
                if Self.isOutOfSpace(error) {                      // disk full — retrying won't help
                    throw DownloadError.insufficientSpace(required: -1, available: 0)
                }
                attempt += 1                                      // transient network error — retry
                if attempt >= maxAttempts { throw error }
                try? await Task.sleep(for: Self.backoffDelay(attempt))
            }
        }
    }

    /// Is this write error an out-of-space condition (ENOSPC)? Then aborting beats retrying.
    private static func isOutOfSpace(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace { return true }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) { return true }
        return false
    }

    /// Full-jitter exponential backoff: a random delay in `0 ... min(cap, base·2^(attempt-1))`.
    /// Randomizing spreads concurrent chunk retries so they don't hit the server in lockstep.
    private static func backoffDelay(_ attempt: Int) -> Duration {
        let ceiling = min(20.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        return .seconds(Double.random(in: 0...ceiling))
    }

    private nonisolated func downloadChunk(index: Int, segment: SegmentState) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if info.supportsRanges, segment.end >= 0 {
            request.setValue("bytes=\(segment.currentOffset)-\(segment.end)",
                             forHTTPHeaderField: "Range")
            if let validator = info.validator {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }

        let handle = try FileHandle(forWritingTo: partURL)
        try handle.seek(toOffset: UInt64(segment.currentOffset))
        defer { try? handle.close() }

        let task = session.dataTask(with: request)
        let stream = delegate.makeStream(for: task.taskIdentifier)
        await register(DataTaskBox(task: task), index: index)
        task.resume()

        for try await chunk in stream {
            try handle.write(contentsOf: chunk)
            await advance(index: index, by: chunk.count)
        }
    }

    // MARK: - Actor-isolated state updates

    private func register(_ box: DataTaskBox, index: Int) {
        urlTasks[index] = box
        lastActivity[index] = Date()
    }

    private func unregister(index: Int) {
        urlTasks[index] = nil
        lastActivity[index] = nil
    }

    private func currentSegment(_ index: Int) -> SegmentState { segments[index] }

    private func isStopping() -> Bool { isPausing || isCanceling }

    private func checkForStalls() {
        guard !isPausing, !isCanceling else { return }
        let now = Date()
        for (index, box) in urlTasks where now.timeIntervalSince(lastActivity[index] ?? now) > stallTimeout {
            box.task.cancel()   // worker catches .cancelled and retries this chunk
        }
    }

    private func advance(index: Int, by byteCount: Int) {
        segments[index].received += Int64(byteCount)
        totalReceived += Int64(byteCount)
        lastActivity[index] = Date()

        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.25 else { return }
        let elapsed = now.timeIntervalSince(lastSampleTime)
        let speed = elapsed > 0 ? Double(totalReceived - lastSampleBytes) / elapsed : 0
        lastEmit = now
        lastSampleTime = now
        lastSampleBytes = totalReceived

        emit(.progress(id: id,
                       received: totalReceived,
                       total: info.totalBytes,
                       speed: speed,
                       segments: segments))
    }
}

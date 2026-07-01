import Foundation

/// Owns the shared `URLSession`, the connection budget, and every active
/// `DownloadCoordinator`. Publishes progress through an `AsyncStream` the UI
/// consumes on the main actor.
actor DownloadEngine {
    private let session: URLSession
    private let delegate: SegmentDataDelegate
    private let gate: ConnectionGate
    private let prober = RemoteProbe()
    private var coordinators: [UUID: DownloadCoordinator] = [:]
    private enum StopIntent { case pause, cancel }
    private var stopIntents: [UUID: StopIntent] = [:]   // pause/cancel arriving before the coordinator exists

    let events: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation

    init(maxConnections: Int = 8) {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = maxConnections
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true

        let delegate = SegmentDataDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.gate = ConnectionGate(limit: maxConnections)
        (self.events, self.continuation) = AsyncStream.makeStream()
    }

    /// Begin (or resume) a download. Probing is skipped when `info`/`existing`
    /// are supplied from a persisted record.
    func start(id: UUID,
               url: URL,
               finalURL: URL,
               partURL: URL,
               connections: Int,
               existing: [SegmentState]?,
               info: RemoteFileInfo?) {
        Task {
            await self.execute(id: id, url: url, finalURL: finalURL, partURL: partURL,
                               connections: connections, existing: existing, info: info)
        }
    }

    func pause(id: UUID) async {
        if let coordinator = coordinators[id] {
            await coordinator.requestPause()
        } else {
            stopIntents[id] = .pause   // applied once the coordinator is built
        }
    }

    func cancel(id: UUID) async {
        if let coordinator = coordinators[id] {
            await coordinator.requestCancel()
        } else {
            stopIntents[id] = .cancel
        }
    }

    // MARK: - Private

    private func execute(id: UUID,
                         url: URL,
                         finalURL: URL,
                         partURL: URL,
                         connections: Int,
                         existing: [SegmentState]?,
                         info knownInfo: RemoteFileInfo?) async {
        do {
            let info: RemoteFileInfo
            if let knownInfo {
                info = knownInfo
            } else {
                continuation.yield(.statusChanged(id: id, status: .probing))
                info = try await prober.probe(url: url)
                continuation.yield(.info(id: id,
                                         total: info.totalBytes,
                                         fileName: info.suggestedFileName,
                                         supportsRanges: info.supportsRanges,
                                         validator: info.validator))
            }

            let segments = existing ?? planSegments(
                total: info.totalBytes,
                connections: info.supportsRanges ? connections : 1
            )
            try Self.makeDirectory(for: partURL)
            if info.totalBytes > 0 {
                try Self.ensureSpace(for: partURL, required: info.totalBytes)
            }
            try preallocate(partURL: partURL, total: info.totalBytes)

            let coordinator = DownloadCoordinator(
                id: id, url: url, partURL: partURL, info: info, segments: segments,
                session: session, delegate: delegate, gate: gate,
                maxWorkers: info.supportsRanges ? connections : 1,
                emit: { [continuation] event in continuation.yield(event) }
            )
            coordinators[id] = coordinator
            // Apply any pause/cancel that arrived while we were probing.
            switch stopIntents.removeValue(forKey: id) {
            case .pause: await coordinator.requestPause()
            case .cancel: await coordinator.requestCancel()
            case nil: break
            }
            continuation.yield(.statusChanged(id: id, status: .downloading))

            let outcome = try await coordinator.run()
            let finalSegments = await coordinator.currentSegments
            coordinators[id] = nil

            switch outcome {
            case .completed:
                try finalize(partURL: partURL, finalURL: finalURL)
                continuation.yield(.finished(id: id, status: .completed, segments: finalSegments, error: nil))
            case .paused:
                continuation.yield(.finished(id: id, status: .paused, segments: finalSegments, error: nil))
            case .canceled:
                try? FileManager.default.removeItem(at: partURL)
                continuation.yield(.finished(id: id, status: .canceled, segments: finalSegments, error: nil))
            }
        } catch {
            coordinators[id] = nil
            stopIntents[id] = nil   // discard intent that never reached a coordinator
            continuation.yield(.finished(id: id, status: .failed, segments: [], error: error.localizedDescription))
        }
    }

    /// Create the destination directory (and parents) if missing.
    private static func makeDirectory(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.cannotCreateFolder(dir.path)
        }
    }

    /// Pre-flight free-space check when the total size is known. (Unknown sizes can't be
    /// checked up front; a full disk then surfaces as a write error mid-download.)
    private static func ensureSpace(for fileURL: URL, required: Int64) throws {
        let dir = fileURL.deletingLastPathComponent()
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < required {
            throw DownloadError.insufficientSpace(required: required, available: available)
        }
    }

    private func preallocate(partURL: URL, total: Int64) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: partURL.path) {
            manager.createFile(atPath: partURL.path, contents: nil)
        }
        guard total > 0 else { return }
        let handle = try FileHandle(forWritingTo: partURL)
        try handle.truncate(atOffset: UInt64(total))
        try handle.close()
    }

    private func finalize(partURL: URL, finalURL: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: finalURL.path) {
            try manager.removeItem(at: finalURL)
        }
        try manager.moveItem(at: partURL, to: finalURL)
    }
}

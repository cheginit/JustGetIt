import Foundation

/// Bridges `URLSession` delegate callbacks into per-task async streams of `Data`
/// chunks. One delegate is shared by the whole session; chunks are routed by
/// `taskIdentifier`. Per-task delivery is ordered, so writes stay sequential.
final class SegmentDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    /// Register a stream for a task *before* calling `resume()`.
    func makeStream(for taskID: Int) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        lock.withLock { sinks[taskID] = continuation }
        return stream
    }

    private func finish(_ taskID: Int, error: Error?) {
        let continuation = lock.withLock { sinks.removeValue(forKey: taskID) }
        continuation?.finish(throwing: error)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        let continuation = lock.withLock { sinks[dataTask.taskIdentifier] }
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let code = http.statusCode
            let error: DownloadError = DownloadError.retryableStatuses.contains(code)
                ? .serverBusy(code, retryAfter: Self.retryAfter(http))
                : .badStatus(code)
            finish(dataTask.taskIdentifier, error: error)
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    /// Parse a `Retry-After` header (delta-seconds form; HTTP-date form is ignored).
    private static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let value = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(seconds, 120)   // cap so a hostile header can't park a chunk forever
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        finish(task.taskIdentifier, error: error)
    }
}

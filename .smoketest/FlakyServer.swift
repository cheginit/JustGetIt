import Foundation
import Network

/// Minimal localhost HTTP/1.1 server for the retry smoke test. Serves `payload` over
/// byte-range GETs, but answers the first `failuresToInject` range requests with
/// 503 + Retry-After to exercise the engine's transient-error retry path.
final class FlakyServer: @unchecked Sendable {
    private let payload: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "flaky-server")
    private let lock = NSLock()
    private var failuresRemaining: Int
    private var issued = 0
    private var didResume = false

    /// How many 503s the server actually handed out (read after the download completes).
    var failuresIssued: Int { lock.lock(); defer { lock.unlock() }; return issued }

    init(payload: Data, failuresToInject: Int) throws {
        self.payload = payload
        self.failuresRemaining = failuresToInject
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
    }

    /// Start listening on an ephemeral port; returns the assigned port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port?.rawValue, self.claimResume() {
                        cont.resume(returning: port)
                    }
                case .failed(let error):
                    if self.claimResume() { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func claimResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if didResume { return false }
        didResume = true
        return true
    }

    func stop() { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// Accumulate bytes until the end of the HTTP header block, then respond.
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(conn, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ conn: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? "GET"
        let rangeLine = lines.first { $0.lowercased().hasPrefix("range:") }

        let response: Data
        if method == "HEAD" {
            response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\n"
                + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n", using: .utf8)
        } else if let rangeLine, let (start, end) = Self.parseRange(rangeLine, total: payload.count) {
            if shouldFail() {
                response = Data("HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\n"
                    + "Content-Length: 0\r\nConnection: close\r\n\r\n", using: .utf8)
            } else {
                let slice = payload[start...end]
                var out = Data("HTTP/1.1 206 Partial Content\r\nContent-Length: \(slice.count)\r\n"
                    + "Content-Range: bytes \(start)-\(end)/\(payload.count)\r\n"
                    + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n", using: .utf8)
                out.append(slice)
                response = out
            }
        } else {
            var out = Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n", using: .utf8)
            out.append(payload)
            response = out
        }
        // isComplete: true flushes a clean FIN after the body, so the client reads the
        // full response before the socket closes (a bare cancel() would RST-truncate it).
        conn.send(content: response, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func shouldFail() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failuresRemaining > 0 else { return false }
        failuresRemaining -= 1; issued += 1
        return true
    }

    /// Parse "Range: bytes=START-END" (END optional) into absolute offsets.
    private static func parseRange(_ header: String, total: Int) -> (Int, Int)? {
        guard let eq = header.firstIndex(of: "=") else { return nil }
        let spec = header[header.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(parts.first ?? "") else { return nil }
        let end = (parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1)
        guard start <= end, end < total else { return nil }
        return (start, end)
    }
}

private extension Data {
    init(_ string: String, using encoding: String.Encoding) { self = string.data(using: encoding)! }
}

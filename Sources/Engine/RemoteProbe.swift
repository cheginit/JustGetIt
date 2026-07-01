import Foundation

/// Discovers file size, range support, and a validator so the engine can decide
/// how many connections to open.
struct RemoteProbe: Sendable {
    func probe(url: URL) async throws -> RemoteFileInfo {
        // 1. Try a cheap HEAD request first.
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 30
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse,
           (200...299).contains(http.statusCode) {
            let length = response.expectedContentLength
            let acceptsRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?
                .lowercased()
                .contains("bytes") ?? false
            return RemoteFileInfo(
                totalBytes: length,
                supportsRanges: acceptsRanges && length > 0,
                validator: validator(from: http),
                suggestedFileName: response.suggestedFilename ?? url.lastPathComponent
            )
        }

        // 2. Fall back to a single-byte ranged GET (some servers reject HEAD).
        var ranged = URLRequest(url: url)
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        ranged.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: ranged)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.probeFailed }

        if http.statusCode == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let totalText = contentRange.split(separator: "/").last,
           let total = Int64(totalText) {
            return RemoteFileInfo(
                totalBytes: total,
                supportsRanges: true,
                validator: validator(from: http),
                suggestedFileName: response.suggestedFilename ?? url.lastPathComponent
            )
        }

        // 3. No range support — single connection, size may be unknown.
        return RemoteFileInfo(
            totalBytes: response.expectedContentLength,
            supportsRanges: false,
            validator: nil,
            suggestedFileName: response.suggestedFilename ?? url.lastPathComponent
        )
    }

    private func validator(from http: HTTPURLResponse) -> String? {
        http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
    }
}

/// Splits a known total size into many contiguous chunks — more than there are
/// connections — so idle workers can steal the next pending chunk and keep every
/// connection busy until the file is done. Target ~4 MB per chunk, with at least
/// `connections` chunks and a hard cap to avoid pathological counts.
func planSegments(total: Int64, connections: Int) -> [SegmentState] {
    guard total > 0 else {
        return [SegmentState(id: 0, start: 0, end: -1, received: 0)]
    }
    let targetChunkSize: Int64 = 4 * 1024 * 1024
    let byTargetSize = Int((total + targetChunkSize - 1) / targetChunkSize)
    let chunkCount = min(256, max(connections, byTargetSize))
    let size = total / Int64(chunkCount)

    var chunks: [SegmentState] = []
    var start: Int64 = 0
    for index in 0..<chunkCount {
        let end = (index == chunkCount - 1) ? total - 1 : start + size - 1
        chunks.append(SegmentState(id: index, start: start, end: end, received: 0))
        start = end + 1
    }
    return chunks
}

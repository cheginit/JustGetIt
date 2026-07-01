import Foundation
import SwiftData

// MARK: - Status

enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    case queued, probing, downloading, paused, completed, failed, canceled

    var label: String {
        switch self {
        case .queued: "Queued"
        case .probing: "Probing"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .canceled: "Canceled"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .probing: "magnifyingglass"
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle"
        }
    }

    var isTerminal: Bool { self == .completed || self == .failed || self == .canceled }
}

// MARK: - Segment

/// One byte-range of a file that downloads on its own connection.
struct SegmentState: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let start: Int64        // absolute first byte offset
    let end: Int64          // absolute last byte (inclusive); -1 when total size is unknown
    var received: Int64     // bytes already written for this segment

    var length: Int64 { end >= 0 ? end - start + 1 : -1 }
    var currentOffset: Int64 { start + received }
    var isComplete: Bool { end >= 0 && received >= length }
    var fraction: Double { length > 0 ? min(1, Double(received) / Double(length)) : 0 }
}

// MARK: - Remote probe result

struct RemoteFileInfo: Sendable {
    var totalBytes: Int64       // -1 when unknown
    var supportsRanges: Bool
    var validator: String?      // ETag or Last-Modified, used for If-Range on resume
    var suggestedFileName: String
}

// MARK: - Engine events

enum DownloadEvent: Sendable {
    case statusChanged(id: UUID, status: DownloadStatus)
    case info(id: UUID, total: Int64, fileName: String, supportsRanges: Bool, validator: String?)
    case progress(id: UUID, received: Int64, total: Int64, speed: Double, segments: [SegmentState])
    case finished(id: UUID, status: DownloadStatus, segments: [SegmentState], error: String?)
}

// MARK: - Errors

enum DownloadError: LocalizedError {
    case badStatus(Int)
    case serverBusy(Int, retryAfter: TimeInterval?)   // transient: 429/503/… — retry, honoring Retry-After
    case probeFailed
    case invalidURL
    case cannotCreateFolder(String)
    case insufficientSpace(required: Int64, available: Int64)   // required < 0 ⇒ size unknown, disk hit full

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "Server returned HTTP \(code)."
        case .serverBusy(let code, _): "Server busy (HTTP \(code))."
        case .probeFailed: "Could not read file information from the server."
        case .invalidURL: "The URL is not valid."
        case .cannotCreateFolder(let path): "Couldn't create the download folder at \(path)."
        case .insufficientSpace(let required, let available):
            required > 0
                ? "Not enough disk space — needs \(required.fileSizeText), only \(available.fileSizeText) free."
                : "The disk is full."
        }
    }

    /// HTTP statuses worth retrying rather than failing the download.
    static let retryableStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
}

// MARK: - Persistence

@Model
final class DownloadRecord {
    @Attribute(.unique) var id: UUID
    var urlString: String
    var destinationPath: String
    var fileName: String
    var totalBytes: Int64
    var statusRaw: String
    var supportsRanges: Bool
    var validator: String?
    var connectionCount: Int
    var segmentsData: Data?
    var createdAt: Date
    var completedAt: Date?

    init(id: UUID, urlString: String, destinationPath: String, fileName: String, connectionCount: Int) {
        self.id = id
        self.urlString = urlString
        self.destinationPath = destinationPath
        self.fileName = fileName
        self.totalBytes = 0
        self.statusRaw = DownloadStatus.queued.rawValue
        self.supportsRanges = false
        self.connectionCount = connectionCount
        self.segmentsData = nil
        self.createdAt = Date()
    }

    var status: DownloadStatus {
        get { DownloadStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var segments: [SegmentState] {
        get {
            guard let data = segmentsData else { return [] }
            return (try? JSONDecoder().decode([SegmentState].self, from: data)) ?? []
        }
        set { segmentsData = try? JSONEncoder().encode(newValue) }
    }

    var receivedBytes: Int64 { segments.reduce(0) { $0 + $1.received } }
    var finalURL: URL { URL(fileURLWithPath: destinationPath) }
    var partURL: URL { URL(fileURLWithPath: destinationPath + ".download") }

    var cachedInfo: RemoteFileInfo? {
        guard totalBytes > 0 else { return nil }
        return RemoteFileInfo(totalBytes: totalBytes,
                              supportsRanges: supportsRanges,
                              validator: validator,
                              suggestedFileName: fileName)
    }
}

// MARK: - UI filter

enum DownloadFilter: String, CaseIterable, Identifiable, Hashable {
    case all, active, completed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .completed: "Completed"
        }
    }
    var icon: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .completed: "checkmark.circle"
        }
    }
}

// MARK: - Formatting helpers

extension Int64 {
    var fileSizeText: String {
        self <= 0 ? "—" : ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Double {
    var speedText: String {
        self <= 0 ? "—" : ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) + "/s"
    }
}

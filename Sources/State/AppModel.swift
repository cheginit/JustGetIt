import Foundation
import SwiftData
import Observation
import AppKit
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for completion/failure alerts.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Live, observable view of one download for the UI. Updated from engine events;
/// the durable copy lives in `DownloadRecord` (SwiftData).
@MainActor
@Observable
final class DownloadRow: Identifiable {
    let id: UUID
    var fileName: String
    var urlString: String
    var totalBytes: Int64
    var receivedBytes: Int64
    var status: DownloadStatus
    var speed: Double = 0
    var segments: [SegmentState] = []
    var errorMessage: String?

    var fraction: Double {
        if status == .completed { return 1 }   // completion is authoritative; byte counter lags (throttled final emit)
        return totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
    }
    var connectionCount: Int { max(segments.count, 1) }

    /// Estimated time remaining at the current speed; "—" when not measurable.
    var etaText: String {
        guard status == .downloading, speed > 0, totalBytes > 0 else { return "—" }
        let seconds = Int(Double(totalBytes - receivedBytes) / speed)
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(max(0, seconds))s"
    }

    init(record: DownloadRecord) {
        id = record.id
        fileName = record.fileName
        urlString = record.urlString
        totalBytes = record.totalBytes
        receivedBytes = record.receivedBytes
        status = record.status
    }
}

/// Snapshot of one download's details for the Get Info panel.
/// ponytail: static snapshot — reopen to refresh; live binding isn't worth it for an info dialog.
struct DownloadDetails: Identifiable {
    let id: UUID
    let fileName, urlString, path, status: String
    let total, received: Int64
    let connections: Int
    let createdAt: Date
    let completedAt: Date?
    let error: String?
}

/// A URL staged in the pre-download review pane before the user confirms.
struct StagedDownload: Identifiable, Hashable {
    let id = UUID()
    var urlString: String

    var isValid: Bool { AppModel.normalizedURL(urlString) != nil }
}

@MainActor
@Observable
final class AppModel {
    var rows: [DownloadRow] = []
    var selection = Set<UUID>()
    var filter: DownloadFilter? = .all
    var searchText = ""

    // Pre-download review pane.
    var stagedURLs: [StagedDownload] = []
    var showingReview = false
    var reviewConnections = AppModel.defaultConnections

    // Get Info panel target (nil = hidden).
    var infoTarget: DownloadDetails?

    private let engine = DownloadEngine(maxConnections: 8)
    private var context: ModelContext?
    private var records: [UUID: DownloadRecord] = [:]
    private var listenTask: Task<Void, Never>?
    private var lastSegmentPersist: [UUID: Date] = [:]
    private var hotKey: GlobalHotKey?

    // Concurrency queue: only `maxConcurrent` downloads run at once; the rest wait.
    private var running: Set<UUID> = []
    private var waiting: [UUID] = []

    // MARK: - Settings (stored in UserDefaults; edited in SettingsView)
    static var defaultConnections: Int {
        UserDefaults.standard.object(forKey: "defaultConnections") as? Int ?? 8
    }
    static var maxConcurrent: Int {
        max(1, UserDefaults.standard.object(forKey: "maxConcurrentDownloads") as? Int ?? 3)
    }
    static var downloadFolder: URL {
        let path = UserDefaults.standard.string(forKey: "downloadFolderPath") ?? ""
        if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }
    static var dotFilenames: Bool {
        UserDefaults.standard.object(forKey: "dotFilenames") as? Bool ?? true
    }

    var filteredRows: [DownloadRow] {
        let base: [DownloadRow]
        switch filter ?? .all {
        case .all: base = rows
        case .active: base = rows.filter { !$0.status.isTerminal }
        case .completed: base = rows.filter { $0.status == .completed }
        }
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.fileName.localizedCaseInsensitiveContains(searchText) }
    }

    /// Row count per sidebar filter (for the badges).
    func count(for filter: DownloadFilter) -> Int {
        switch filter {
        case .all: rows.count
        case .active: rows.filter { !$0.status.isTerminal }.count
        case .completed: rows.filter { $0.status == .completed }.count
        }
    }

    var activeCount: Int { rows.filter { $0.status == .downloading }.count }
    var totalSpeed: Double { rows.filter { $0.status == .downloading }.reduce(0) { $0 + $1.speed } }

    func bootstrap(_ context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        Notifier.requestAuthorization()
        reloadHotKey()
        loadRecords()
        listenTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                self?.apply(event)
            }
        }
    }

    // MARK: - Commands

    func addDownload(urlString: String, connections: Int) {
        guard let normalized = AppModel.normalizedURL(urlString),
              let url = URL(string: normalized), let context else { return }
        let id = UUID()
        let dots = AppModel.dotFilenames
        let baseName = AppModel.displayName(from: url.lastPathComponent, dots: dots)
        let finalURL = uniqueURL(in: AppModel.downloadFolder, name: baseName, dots: dots)

        let record = DownloadRecord(id: id, urlString: normalized,
                                    destinationPath: finalURL.path,
                                    fileName: finalURL.lastPathComponent,
                                    connectionCount: connections)
        context.insert(record)
        try? context.save()
        records[id] = record

        let row = DownloadRow(record: record)
        rows.insert(row, at: 0)
        requestStart(id)
    }

    // MARK: - Bulk commands

    func pauseAll() {
        for row in rows where !row.status.isTerminal { pause(row.id) }
    }

    func resumeAll() {
        for row in rows where row.status == .paused || row.status == .failed { resume(row.id) }
    }

    /// Drop every completed download from the list (the files stay on disk).
    func clearCompleted() {
        rows.filter { $0.status == .completed }.map(\.id).forEach(remove)
    }

    // MARK: - Pre-download review

    func presentEmptyReview() {
        reviewConnections = AppModel.defaultConnections
        showingReview = true
    }

    func presentReviewFromClipboard() {
        reviewConnections = AppModel.defaultConnections
        mergeStaged(Self.clipboardURLs())
        showingReview = true
    }

    func appendURLsFromClipboard() {
        mergeStaged(Self.clipboardURLs())
    }

    func addStagedURL(_ urlString: String) {
        mergeStaged([urlString])
    }

    /// (Re)register the global download-from-clipboard hotkey from the saved combo.
    /// Defaults to ⌘⌥⇧D (key code 2, Carbon modifiers cmd|opt|shift = 2816).
    func reloadHotKey() {
        let code = UserDefaults.standard.object(forKey: "hotKeyCode") as? Int ?? 2
        let modifiers = UserDefaults.standard.object(forKey: "hotKeyModifiers") as? Int ?? 2816
        hotKey = nil   // release the old registration first
        hotKey = GlobalHotKey(keyCode: UInt32(code), modifiers: UInt32(modifiers)) { [weak self] in
            Task { @MainActor in self?.downloadFromClipboard() }
        }
    }

    /// Global-hotkey action: start every http(s) URL on the clipboard right away,
    /// straight to the default folder — no review pane.
    func downloadFromClipboard() {
        let urls = Self.clipboardURLs()
        guard !urls.isEmpty else { return }
        for url in urls { addDownload(urlString: url, connections: AppModel.defaultConnections) }
        Notifier.post(title: "JustGetIt",
                      body: urls.count == 1 ? "Started 1 download" : "Started \(urls.count) downloads")
    }

    func removeStaged(_ id: UUID) {
        stagedURLs.removeAll { $0.id == id }
    }

    func confirmStaged() {
        for staged in stagedURLs where staged.isValid {
            addDownload(urlString: staged.urlString, connections: reviewConnections)
        }
        stagedURLs.removeAll()
        showingReview = false
    }

    func cancelReview() {
        stagedURLs.removeAll()
        showingReview = false
    }

    private func mergeStaged(_ urls: [String]) {
        let existing = Set(stagedURLs.map(\.urlString))
        for url in urls where !existing.contains(url) {
            stagedURLs.append(StagedDownload(urlString: url))
        }
    }

    /// Extract http(s) URLs from the clipboard — handles a single URL, URL
    /// objects, or many links separated by whitespace/newlines; de-duplicated.
    static func clipboardURLs() -> [String] {
        let pasteboard = NSPasteboard.general
        var candidates: [String] = []

        if let objects = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            candidates += objects.map(\.absoluteString)
        }
        if let text = pasteboard.string(forType: .string) {
            // One URL per line — a URL may itself contain spaces, so don't split on them.
            candidates += text.split(whereSeparator: \.isNewline).map(String.init)
        }

        var seen = Set<String>()
        return candidates.compactMap(normalizedURL).filter { seen.insert($0).inserted }
    }

    /// A normalized http(s) URL string with illegal characters (spaces, etc.) percent-encoded,
    /// or nil if it isn't a valid web URL.
    nonisolated static func normalizedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, encodingInvalidCharacters: true),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url.absoluteString
    }

    /// Clean a filename derived from a URL: always trim and drop leading dots (no hidden
    /// files); when `dots` is on, collapse internal whitespace runs into single dots.
    nonisolated static func displayName(from raw: String, dots: Bool) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if dots {
            name = name.split(whereSeparator: \.isWhitespace).joined(separator: ".")
        }
        name = String(name.drop(while: { $0 == "." }))   // a leading dot hides the file on macOS
        return name.isEmpty ? "download" : name
    }

    func pause(_ id: UUID) {
        // Still waiting for a slot — just drop it from the queue, no engine involved.
        if let index = waiting.firstIndex(of: id) {
            waiting.remove(at: index)
            row(id)?.status = .paused
            records[id]?.status = .paused
            saveSoon()
            return
        }
        row(id)?.status = .paused          // optimistic; engine confirms via .finished(.paused)
        Task { await engine.pause(id: id) }
    }

    func resume(_ id: UUID) {
        requestStart(id)
    }

    func remove(_ id: UUID) {
        waiting.removeAll { $0 == id }              // if only queued, it held no slot
        Task { await engine.cancel(id: id) }        // if running, .finished(.canceled) frees its slot
        if let record = records[id] {
            context?.delete(record)
            records[id] = nil
        }
        rows.removeAll { $0.id == id }
        try? context?.save()
    }

    /// Reveal the finished file or the in-progress `.download` in Finder. If neither exists
    /// (moved or deleted outside the app), tell the user instead of opening the folder.
    func revealInFinder(_ id: UUID) {
        guard let record = records[id] else { return }
        if let url = existingFile(for: record) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            reportFileMissing(record)
        }
    }

    /// Open the finished file with its default app, or report it missing.
    func openFile(_ id: UUID) {
        guard let record = records[id] else { return }
        if FileManager.default.fileExists(atPath: record.finalURL.path) {
            NSWorkspace.shared.open(record.finalURL)
        } else {
            reportFileMissing(record)
        }
    }

    /// The on-disk file for a download — finished file or its `.download` part — if present.
    private func existingFile(for record: DownloadRecord) -> URL? {
        let manager = FileManager.default
        for url in [record.finalURL, record.partURL] where manager.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private func reportFileMissing(_ record: DownloadRecord) {
        let alert = NSAlert()
        alert.messageText = "File Not Found"
        alert.informativeText = "“\(record.fileName)” has been moved or deleted."
        alert.alertStyle = .warning
        alert.runModal()
    }

    func copySourceURL(_ id: UUID) {
        guard let record = records[id] else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.urlString, forType: .string)
    }

    /// Cancel, send the file (and any `.download` part) to the Trash, drop the record.
    func moveToTrash(_ id: UUID) {
        guard let record = records[id] else { return }
        let finalURL = record.finalURL, partURL = record.partURL
        waiting.removeAll { $0 == id }              // if running, .finished(.canceled) frees its slot
        Task {
            await engine.cancel(id: id)
            let manager = FileManager.default
            try? manager.trashItem(at: finalURL, resultingItemURL: nil)
            try? manager.trashItem(at: partURL, resultingItemURL: nil)
            context?.delete(record)
            records[id] = nil
            rows.removeAll { $0.id == id }
            selection.remove(id)
            try? context?.save()
        }
    }

    func showInfo(_ id: UUID) {
        guard let record = records[id], let row = row(id) else { return }
        infoTarget = DownloadDetails(
            id: id, fileName: row.fileName, urlString: record.urlString,
            path: record.destinationPath, status: row.status.label,
            total: row.totalBytes, received: row.receivedBytes,
            connections: record.connectionCount, createdAt: record.createdAt,
            completedAt: record.completedAt, error: row.errorMessage)
    }

    // MARK: - Queue scheduling

    /// Mark a download as wanting to run; it starts now if a slot is free, else waits.
    private func requestStart(_ id: UUID) {
        guard records[id] != nil, !running.contains(id) else { return }   // already active → leave it
        if !waiting.contains(id) { waiting.append(id) }
        row(id)?.status = .queued
        records[id]?.status = .queued
        saveSoon()
        pumpQueue()
    }

    /// Start waiting downloads until `maxConcurrent` are running.
    private func pumpQueue() {
        while running.count < AppModel.maxConcurrent, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let record = records[id] else { continue }
            running.insert(id)
            startEngine(for: record,
                        connections: record.connectionCount,
                        existing: record.segments.isEmpty ? nil : record.segments,
                        info: record.cachedInfo)
        }
    }

    // MARK: - Private

    private func startEngine(for record: DownloadRecord, connections: Int,
                             existing: [SegmentState]?, info: RemoteFileInfo?) {
        let id = record.id
        let url = URL(string: record.urlString)!
        let finalURL = record.finalURL
        let partURL = record.partURL
        Task {
            await engine.start(id: id, url: url, finalURL: finalURL, partURL: partURL,
                               connections: connections, existing: existing, info: info)
        }
    }

    private func loadRecords() {
        guard let context else { return }
        let descriptor = FetchDescriptor<DownloadRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        for record in fetched {
            // Anything mid-flight when we last quit is now paused.
            if record.status == .downloading || record.status == .probing || record.status == .queued {
                record.status = .paused
            }
            records[record.id] = record
            rows.append(DownloadRow(record: record))
        }
        try? context.save()
    }

    private func apply(_ event: DownloadEvent) {
        switch event {
        case .statusChanged(let id, let status):
            row(id)?.status = status
            records[id]?.status = status
            saveSoon()

        case .info(let id, let total, let fileName, let supportsRanges, let validator):
            if let row = row(id) {
                row.totalBytes = total
                if row.fileName == "download" { row.fileName = fileName }
            }
            if let record = records[id] {
                record.totalBytes = total
                record.supportsRanges = supportsRanges
                record.validator = validator
            }
            saveSoon()

        case .progress(let id, let received, let total, let speed, let segments):
            if let row = row(id) {
                row.receivedBytes = received
                if total > 0 { row.totalBytes = total }
                row.speed = speed
                row.segments = segments
            }
            checkpoint(id: id, segments: segments)

        case .finished(let id, let status, let segments, let error):
            let fileName = row(id)?.fileName ?? "Download"
            if let row = row(id) {
                row.status = status
                row.speed = 0
                row.errorMessage = error
                if status == .completed, row.totalBytes > 0 { row.receivedBytes = row.totalBytes }
            }
            if let record = records[id] {
                record.status = status
                if !segments.isEmpty { record.segments = segments }
                if status == .completed { record.completedAt = Date() }
            }
            lastSegmentPersist[id] = nil
            try? context?.save()
            if running.remove(id) != nil { pumpQueue() }   // free the slot, start the next queued
            notifyFinish(status: status, fileName: fileName, error: error)
        }
    }

    private func row(_ id: UUID) -> DownloadRow? { rows.first { $0.id == id } }

    private func saveSoon() { try? context?.save() }

    /// Persist per-chunk offsets at most every 2s so an unexpected quit/crash can
    /// resume from near where it left off rather than restarting in-flight chunks.
    private func checkpoint(id: UUID, segments: [SegmentState]) {
        let now = Date()
        if let last = lastSegmentPersist[id], now.timeIntervalSince(last) < 2 { return }
        lastSegmentPersist[id] = now
        records[id]?.segments = segments
        try? context?.save()
    }

    private func notifyFinish(status: DownloadStatus, fileName: String, error: String?) {
        switch status {
        case .completed:
            Notifier.post(title: "Download Complete", body: fileName)
        case .failed:
            Notifier.post(title: "Download Failed", body: "\(fileName) — \(error ?? "unknown error")")
        default:
            break
        }
    }

    /// A destination not already taken by an on-disk file, its `.download` sidecar,
    /// or another in-flight record — so two same-named downloads never share a file.
    private func uniqueURL(in directory: URL, name: String, dots: Bool) -> URL {
        let manager = FileManager.default
        let taken = Set(records.values.map(\.destinationPath))
        func isFree(_ url: URL) -> Bool {
            !taken.contains(url.path)
                && !manager.fileExists(atPath: url.path)
                && !manager.fileExists(atPath: url.path + ".download")
        }
        let candidate = directory.appendingPathComponent(name)
        if isFree(candidate) { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 1
        while true {
            // Match the naming style so the de-dup marker doesn't reintroduce a space.
            let stem = dots ? "\(base).\(index)" : "\(base) (\(index))"
            let suffix = ext.isEmpty ? stem : "\(stem).\(ext)"
            let next = directory.appendingPathComponent(suffix)
            if isFree(next) { return next }
            index += 1
        }
    }
}

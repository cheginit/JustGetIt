import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension DownloadStatus {
    /// Semantic color for this state — drives the status label and progress tint.
    var color: Color {
        switch self {
        case .completed: .green
        case .failed: .red
        case .paused: .orange
        case .downloading: .accentColor
        case .queued, .probing, .canceled: .gray
        }
    }
}

/// The system (Finder) icon for a filename, chosen by its extension.
func fileTypeIcon(for fileName: String) -> Image {
    let ext = (fileName as NSString).pathExtension
    let type = UTType(filenameExtension: ext) ?? .data
    return Image(nsImage: NSWorkspace.shared.icon(for: type))
}

import SwiftUI
import AppKit

/// Preferences (⌘,). Values live in UserDefaults; AppModel reads the same keys.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @AppStorage("defaultConnections") private var defaultConnections = 8
    @AppStorage("maxConcurrentDownloads") private var maxConcurrent = 3
    @AppStorage("downloadFolderPath") private var downloadFolderPath = ""
    @AppStorage("dotFilenames") private var dotFilenames = true
    @AppStorage("hotKeyCode") private var hotKeyCode = 2
    @AppStorage("hotKeyModifiers") private var hotKeyModifiers = 2816
    @AppStorage("hotKeyLabel") private var hotKeyLabel = "⌘⌥⇧D"

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Stepper("Connections per download: \(defaultConnections)",
                    value: $defaultConnections, in: 1...32)
            Stepper("Maximum concurrent downloads: \(maxConcurrent)",
                    value: $maxConcurrent, in: 1...10)
            LabeledContent("Save downloads to") {
                HStack {
                    Text(folderDisplay)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Toggle("Replace spaces with dots in filenames", isOn: $dotFilenames)
            LabeledContent("Download-clipboard shortcut") {
                Button(isRecording ? "Press keys…" : hotKeyLabel) {
                    isRecording ? stopRecording() : startRecording()
                }
                .frame(minWidth: 130)
                .help("Press a key combo with at least one modifier. Esc cancels.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 290)
        .onDisappear(perform: stopRecording)
    }

    private var folderDisplay: String {
        downloadFolderPath.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
            : downloadFolderPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            downloadFolderPath = url.path
        }
    }

    // MARK: - Shortcut recorder

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
            return nil   // consume the key so it isn't typed anywhere
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); return }   // Esc cancels

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon = 0
        var glyphs = ""
        if flags.contains(.control) { carbon |= 0x1000; glyphs += "⌃" }
        if flags.contains(.option) { carbon |= 0x800; glyphs += "⌥" }
        if flags.contains(.shift) { carbon |= 0x200; glyphs += "⇧" }
        if flags.contains(.command) { carbon |= 0x100; glyphs += "⌘" }
        guard carbon != 0 else { return }   // require a modifier; ignore bare keys, keep listening

        hotKeyCode = Int(event.keyCode)
        hotKeyModifiers = carbon
        hotKeyLabel = glyphs + (event.charactersIgnoringModifiers ?? "").uppercased()
        stopRecording()
        model.reloadHotKey()
    }
}

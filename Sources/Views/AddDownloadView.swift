import SwiftUI
import UniformTypeIdentifiers

/// Pre-download review pane: lists the URLs captured (typed, added, or pasted via
/// ⌘V) so they can be reviewed, edited, and pruned before downloading. Supports
/// one URL or many at once.
struct ReviewDownloadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var newURL = ""

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add Downloads").font(.title2.bold())
                Spacer()
                Text("\(validCount) ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Paste or type a URL…", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .buttonStyle(.glass)
                    .disabled(!isValid(newURL))
                Button {
                    model.appendURLsFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
                .help("Paste one or more URLs from the clipboard")
            }

            if model.stagedURLs.isEmpty {
                ContentUnavailableView {
                    Label("No URLs yet", systemImage: "link")
                } description: {
                    Text("Paste links (one per line) or type a URL above.")
                }
                .frame(height: 160)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($model.stagedURLs) { $staged in
                            HStack(spacing: 8) {
                                Image(systemName: staged.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(staged.isValid ? .green : .orange)
                                TextField("URL", text: $staged.urlString)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(1)
                                Button {
                                    model.removeStaged(staged.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Stepper("Connections per download: \(model.reviewConnections)",
                    value: $model.reviewConnections, in: 1...16)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelReview()
                    dismiss()
                }
                .buttonStyle(.glass)

                Button(downloadLabel) {
                    model.confirmStaged()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validCount == 0)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onPasteCommand(of: [.url, .plainText]) { _ in
            model.appendURLsFromClipboard()
        }
    }

    private var validCount: Int { model.stagedURLs.filter(\.isValid).count }

    private var downloadLabel: String {
        validCount > 1 ? "Download \(validCount)" : "Download"
    }

    private func isValid(_ string: String) -> Bool {
        AppModel.normalizedURL(string) != nil
    }

    private func addTyped() {
        guard isValid(newURL) else { return }
        model.addStagedURL(newURL)
        newURL = ""
    }
}

import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if model.totalSpeed > 0 {
                    Text(model.totalSpeed.speedText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if model.rows.isEmpty {
                Text("No downloads yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.rows.prefix(6)) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            fileTypeIcon(for: row.fileName)
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(row.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if row.status == .downloading {
                                Text(row.speed.speedText)
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: row.status.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(row.status.color)
                            }
                        }
                        ProgressView(value: row.fraction)
                            .progressViewStyle(.linear)
                            .tint(row.status.color)
                    }
                }
            }

            Divider()

            Button("Quit JustGetIt") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .frame(width: 320)
    }
}

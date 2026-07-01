import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.filter) {
                Section("Library") {
                    ForEach(DownloadFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.icon)
                            .badge(model.count(for: filter) == 0 ? nil : Text(model.count(for: filter).formatted()))
                            .tag(filter)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .navigationTitle("JustGetIt")
        } detail: {
            DownloadListView()
        }
        .sheet(isPresented: $model.showingReview) {
            ReviewDownloadsView()
        }
        .onPasteCommand(of: [.url, .plainText]) { _ in
            if !model.showingReview { model.presentReviewFromClipboard() }
        }
        .onAppear { model.bootstrap(modelContext) }
    }
}

struct DownloadListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .bottomTrailing) {
            Group {
                if model.filteredRows.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Add a URL to start downloading with multiple connections.")
                    )
                } else {
                    Table(model.filteredRows, selection: $model.selection) {
                        TableColumn("Name") { row in
                            NameCell(row: row)
                        }
                        .width(min: 240, ideal: 360)

                        TableColumn("Size") { row in
                            Text(row.totalBytes.fileSizeText)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .width(90)

                        TableColumn("Speed") { row in
                            Text(row.status == .downloading ? row.speed.speedText : "—")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .width(100)

                        TableColumn("Time Left") { row in
                            Text(row.etaText)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .width(90)

                        TableColumn("Status") { row in
                            Label(row.status.label, systemImage: row.status.systemImage)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(row.status.color)
                        }
                        .width(140)
                    }
                    .contextMenu(forSelectionType: DownloadRow.ID.self) { ids in
                        rowContextMenu(ids)
                    } primaryAction: { ids in
                        if let id = ids.first, rows(for: ids).first?.status == .completed {
                            model.openFile(id)
                        }
                    }
                }
            }

            if !model.filteredRows.isEmpty {
                StatsBar()
                    .padding()
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle("Downloads")
        .searchable(text: $model.searchText, prompt: "Filter by name")
        .dropDestination(for: URL.self) { urls, _ in
            let staged = urls.map(\.absoluteString).filter {
                let scheme = URL(string: $0)?.scheme?.lowercased()
                return scheme == "http" || scheme == "https"
            }
            guard !staged.isEmpty else { return false }
            staged.forEach(model.addStagedURL)
            model.reviewConnections = AppModel.defaultConnections
            model.showingReview = true
            return true
        }
        .sheet(item: $model.infoTarget) { details in
            PropertiesView(details: details)
        }
    }

    private func rows(for ids: Set<UUID>) -> [DownloadRow] {
        model.filteredRows.filter { ids.contains($0.id) }
    }

    /// Right-click menu: contextual single-row actions, then bulk pause/resume/remove.
    @ViewBuilder
    private func rowContextMenu(_ ids: Set<UUID>) -> some View {
        let selected = rows(for: ids)
        let single = selected.count == 1 ? selected.first : nil

        if let row = single {
            if row.status == .completed {
                Button("Open", systemImage: "arrow.up.forward.app") { model.openFile(row.id) }
            }
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(row.id) }
            Button("Copy Source URL", systemImage: "link") { model.copySourceURL(row.id) }
            Divider()
        }

        if selected.contains(where: { !$0.status.isTerminal && $0.status != .paused }) {
            Button("Pause", systemImage: "pause") { ids.forEach(model.pause) }
        }
        if selected.contains(where: { $0.status == .paused || $0.status == .failed }) {
            Button("Resume", systemImage: "play") { ids.forEach(model.resume) }
        }

        if let row = single {
            Divider()
            Button("Get Info", systemImage: "info.circle") { model.showInfo(row.id) }
        }

        Divider()
        Button("Remove from List", systemImage: "minus.circle") {
            model.selection.subtract(ids)
            ids.forEach(model.remove)
        }
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            model.selection.subtract(ids)
            ids.forEach(model.moveToTrash)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                pauseSelected()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(model.selection.isEmpty)

            Button {
                resumeSelected()
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .disabled(model.selection.isEmpty)

            Button(role: .destructive) {
                removeSelected()
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Pause All", systemImage: "pause.fill") { model.pauseAll() }
                Button("Resume All", systemImage: "play.fill") { model.resumeAll() }
                Divider()
                Button("Clear Completed", systemImage: "checkmark.circle") { model.clearCompleted() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.presentEmptyReview()
            } label: {
                Label("Add Download", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private func pauseSelected() { model.selection.forEach(model.pause) }
    private func resumeSelected() { model.selection.forEach(model.resume) }
    private func removeSelected() {
        let ids = model.selection
        model.selection.removeAll()
        ids.forEach(model.remove)
    }
}

private struct NameCell: View {
    let row: DownloadRow

    var body: some View {
        HStack(spacing: 10) {
            fileTypeIcon(for: row.fileName)
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    ProgressView(value: row.fraction)
                        .progressViewStyle(.linear)
                        .tint(row.status.color)
                    Text("\(Int(row.fraction * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if row.connectionCount > 1, row.status == .downloading {
                    SegmentBar(segments: row.segments)
                        .frame(height: 4)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Tiny per-chunk progress visualization — the multi-connection signature.
private struct SegmentBar: View {
    let segments: [SegmentState]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Capsule()
                        .fill(.tint.opacity(0.25))
                        .overlay(alignment: .leading) {
                            GeometryReader { cell in
                                Capsule()
                                    .fill(.tint)
                                    .frame(width: cell.size.width * segment.fraction)
                            }
                        }
                }
            }
            .frame(width: geometry.size.width)
        }
    }
}

/// Get Info panel — static snapshot of one download's metadata.
private struct PropertiesView: View {
    let details: DownloadDetails
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Get Info", systemImage: "info.circle").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            Form {
                LabeledContent("Name", value: details.fileName)
                LabeledContent("Status", value: details.status)
                LabeledContent("Size", value: details.total.fileSizeText)
                LabeledContent("Downloaded", value: details.received.fileSizeText)
                LabeledContent("Connections", value: "\(details.connections)")
                LabeledContent("Source") {
                    Text(details.urlString).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
                LabeledContent("Location") {
                    Text(details.path).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
                LabeledContent("Added", value: details.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let completed = details.completedAt {
                    LabeledContent("Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = details.error {
                    LabeledContent("Error") { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 440)
    }
}

struct StatsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            Text("\(model.activeCount) active")
            if model.totalSpeed > 0 {
                Divider().frame(height: 16)
                Image(systemName: "speedometer")
                    .foregroundStyle(.secondary)
                Text(model.totalSpeed.speedText)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

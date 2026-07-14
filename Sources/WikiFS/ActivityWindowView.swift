import SwiftUI
import WikiFSCore
import WikiFSEngine

/// The unified Activity window — replaces the menu-bar popover. A real
/// `NSWindow` (not transient) that shows all queue items across all wikis,
/// grouped by kind, with expandable agent transcripts.
///
/// **Sidebar (left):** Active + recent items grouped by kind (extraction,
/// ingestion), with state badges, wiki names, cancel/retry controls. Ingestion
/// items that are lints (payload has `lintPageIDs`) are distinguished by
/// icon/label.
///
/// **Detail (right):** The selected item's transcript — rendered via
/// `ChatWebView` fed from `activityTracker.transcripts[itemID]`. For extraction
/// items (which produce progress strings, not typed `AgentEvent`s), falls back
/// to the accumulated progress text.
///
/// **Toolbar:** Per-queue pause/resume/halt controls (like the popover had).
/// Since lint is on `.ingestion`, pause/resume/halt of `.ingestion` covers
/// lint too.
struct ActivityWindowView: View {
    let queueEngine: QueueEngine
    @Bindable var activityTracker: QueueActivityTracker
    weak var sessionManager: SessionManager?

    @State private var viewModel = QueueViewModel()
    @State private var selectedItemID: QueueItem.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { viewModel.attach(engine: queueEngine) }
        .onDisappear { viewModel.detach() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                if activityTracker.isExtracting || activityTracker.isIngesting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.snapshot.activeItems.isEmpty
                        && viewModel.snapshot.recentItems.isEmpty {
                        emptyState
                    } else {
                        activeSection
                        if !viewModel.snapshot.recentItems.isEmpty {
                            recentSection
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(minWidth: 240)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No activity")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Active section

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Active")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if viewModel.snapshot.activeItems.isEmpty {
                Text("Nothing active")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                let extraction = viewModel.snapshot.activeItems.filter { $0.queue == .extraction }
                let ingestion = viewModel.snapshot.activeItems.filter { $0.queue == .ingestion }

                if !extraction.isEmpty {
                    queueHeader(.extraction, items: extraction)
                }
                ForEach(extraction) { item in
                    itemRow(item)
                }
                if !ingestion.isEmpty {
                    queueHeader(.ingestion, items: ingestion)
                }
                ForEach(ingestion) { item in
                    itemRow(item)
                }
            }
        }
    }

    // MARK: - Recent section

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

                ForEach(Array(viewModel.snapshot.recentItems.prefix(15))) { item in
                    recentRow(item)
                }
        }
    }

    // MARK: - Row views

    @ViewBuilder
    private func queueHeader(_ queue: QueueKind, items: [QueueItem]) -> some View {
        HStack {
            Image(systemName: queue == .extraction ? "doc.text.magnifyingglass" : "tray.full")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(queue == .extraction ? "Extraction" : "Ingestion")
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
            pauseResumeButton(queue)
            haltButton(queue)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func itemRow(_ item: QueueItem) -> some View {
        let isLint = item.payload.lintPageIDs != nil
        HStack(spacing: 8) {
            Image(systemName: item.state == .running
                ? "arrow.triangle.2.circlepath"
                : "clock")
                .foregroundStyle(item.state == .running ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if isLint {
                        Image(systemName: "checkmark.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(wikiDisplayName(for: item.wikiID))
                        .font(.caption)
                        .fontWeight(.medium)
                }
                Text(label(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.state == .running || item.state == .queued {
                Button {
                    Task { await queueEngine.cancelItem(item.id) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedItemID = item.id
        }
        .background(selectedItemID == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    @ViewBuilder
    private func recentRow(_ item: QueueItem) -> some View {
        let isLint = item.payload.lintPageIDs != nil
        HStack(spacing: 8) {
            Image(systemName: statusIcon(for: item.state))
                .foregroundStyle(statusColor(for: item.state))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if isLint {
                        Image(systemName: "checkmark.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(wikiDisplayName(for: item.wikiID))
                        .font(.caption)
                        .fontWeight(.medium)
                }
                if let error = item.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            Spacer()
            if item.state == .failed {
                Button("Retry") {
                    Task { try? await queueEngine.retryItem(item.id) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedItemID = item.id
        }
        .background(selectedItemID == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let itemID = selectedItemID {
            detailContent(for: itemID)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.left")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Select an item to view its transcript")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detailContent(for itemID: QueueItem.ID) -> some View {
        let events = activityTracker.transcript(for: itemID)
        let progressText = activityTracker.progressLog(for: itemID)

        if !events.isEmpty {
            ChatWebView(events: events, style: .activityFeed, showsInternals: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !progressText.isEmpty {
            ScrollView {
                Text(progressText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(8)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("No transcript yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func pauseResumeButton(_ queue: QueueKind) -> some View {
        let state = viewModel.snapshot.runStates[queue] ?? .running
        if state == .running {
            Button {
                Task { await queueEngine.pause(queue) }
            } label: {
                Image(systemName: "pause")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Pause \(queue.rawValue)")
        } else {
            Button {
                Task { await queueEngine.resume(queue) }
            } label: {
                Image(systemName: "play")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Resume \(queue.rawValue)")
        }
    }

    @ViewBuilder
    private func haltButton(_ queue: QueueKind) -> some View {
        Button {
            Task { await queueEngine.halt(queue) }
        } label: {
            Image(systemName: "stop")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Halt \(queue.rawValue)")
    }

    // MARK: - Helpers

    private func wikiDisplayName(for id: String) -> String {
        sessionManager?.sessions[id]?.descriptor.displayName ?? String(id.prefix(8))
    }

    private func label(for item: QueueItem) -> String {
        if item.payload.lintPageIDs != nil {
            return item.state == .running ? "Linting" : "Queued lint"
        }
        switch item.queue {
        case .extraction:
            return item.state == .running ? "Extracting" : "Queued"
        case .ingestion:
            return item.state == .running ? "Ingesting" : "Queued"
        }
    }

    private func statusIcon(for state: QueueItemState) -> String {
        switch state {
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        }
    }

    private func statusColor(for state: QueueItemState) -> Color {
        switch state {
        case .completed: .secondary
        case .failed: .red
        case .cancelled: .secondary
        case .queued: .secondary
        case .running: .accentColor
        }
    }
}

import SwiftUI
import WikiFSCore
import WikiFSEngine

/// A view-model for the queue popover. Fetches snapshots from the engine
/// and updates on every queue event.
@MainActor
@Observable
final class QueueViewModel {
    var snapshot: QueueSnapshot = QueueSnapshot()
    private var streamTask: Task<Void, Never>?

    private weak var queueEngine: QueueEngine?

    func attach(engine: QueueEngine) {
        queueEngine = engine
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            // Initial snapshot.
            await self?.refresh()
            // Listen for updates.
            guard let self else { return }
            for await _ in engine.events {
                await self.refresh()
            }
        }
    }

    func detach() {
        streamTask?.cancel()
        streamTask = nil
        queueEngine = nil
    }

    func refresh() async {
        guard let engine = queueEngine else { return }
        snapshot = await engine.snapshot()
    }
}

/// The popover content showing queue state across all wikis.
///
/// Lists active and recent items grouped by queue kind, with per-queue
/// pause/resume/halt controls and per-row cancel/retry. Clicking a row
/// opens/focuses that wiki's window.
struct QueuePopoverView: View {
    let queueEngine: QueueEngine
    let activityTracker: QueueActivityTracker
    weak var sessionManager: SessionManager?
    var onClose: () -> Void

    @State private var viewModel = QueueViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
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
                .padding(12)
            }

            Divider()

            // Footer
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.attach(engine: queueEngine) }
        .onDisappear { viewModel.detach() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Queue")
                .font(.headline)
            Spacer()
            if activityTracker.isExtracting || activityTracker.isIngesting {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text("Processing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No queued work")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Active section

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                // Group by queue kind.
                let extraction = viewModel.snapshot.activeItems.filter { $0.queue == .extraction }
                let ingestion = viewModel.snapshot.activeItems.filter { $0.queue == .ingestion }

                if !extraction.isEmpty {
                    queueHeader(.extraction, items: extraction)
                }
                ForEach(extraction) { item in
                    rowView(item)
                }
                if !ingestion.isEmpty {
                    queueHeader(.ingestion, items: ingestion)
                }
                ForEach(ingestion) { item in
                    rowView(item)
                }
            }
        }
    }

    // MARK: - Recent section

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(Array(viewModel.snapshot.recentItems.prefix(10))) { item in
                HStack(spacing: 8) {
                    Image(systemName: statusIcon(for: item.state))
                        .foregroundStyle(statusColor(for: item.state))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.queue == .extraction ? "Extraction" : "Ingestion")
                            .font(.caption)
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
    private func rowView(_ item: QueueItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.state == .running
                ? "arrow.triangle.2.circlepath"
                : "clock")
                .foregroundStyle(item.state == .running ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(wikiDisplayName(for: item.wikiID))
                    .font(.caption)
                    .fontWeight(.medium)
                Text(item.state == .running ? "Running" : "Queued")
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
            openWikiWindow(item.wikiID)
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let sessionManager, !sessionManager.sessions.isEmpty {
                Text("\(sessionManager.sessions.count) wiki\(sessionManager.sessions.count == 1 ? "" : "s") open")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { onClose() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func wikiDisplayName(for id: String) -> String {
        sessionManager?.sessions[id]?.descriptor.displayName ?? id
    }

    private func openWikiWindow(_ wikiID: String) {
        onClose()
        // Use the environment's openWindow action to focus the wiki's window.
        // If the wiki already has a window, it's brought to front; if not,
        // a new window is opened.
        NSApplication.shared.activate(ignoringOtherApps: true)
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

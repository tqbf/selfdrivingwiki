import SwiftUI
import WikiFSCore
import WikiFSEngine

/// The unified Activity window — replaces the menu-bar popover. A real
/// `NSWindow` (not transient) that shows all queue items across all wikis,
/// with expandable agent transcripts.
///
/// **Sidebar (left):** A native `List` (keyboard navigation, real selection)
/// with Active + Recent sections. Rows show the item kind, wiki, state, and a
/// relative timestamp; running/queued rows get an inline Cancel, failed rows
/// an inline Retry, and every row a context menu.
///
/// **Detail (right):** A header (kind, wiki, state, error, primary action)
/// over the selected item's transcript — rendered via `ChatWebView` fed from
/// `activityTracker.transcripts[itemID]`. For extraction items (which produce
/// progress strings, not typed `AgentEvent`s), falls back to the accumulated
/// progress text.
///
/// **Toolbar:** Per-queue pause/resume/halt menus (global actions live in the
/// top bar, per the macOS layout formula). Since lint runs on `.ingestion`,
/// the Ingestion menu covers lint too.
struct ActivityWindowView: View {
    let queueEngine: QueueEngine
    @Bindable var activityTracker: QueueActivityTracker
    weak var sessionManager: SessionManager?

    @State private var viewModel = QueueViewModel()
    @State private var selectedItemID: QueueItem.ID?
    @State private var loadedEvents: [AgentEvent] = []
    @State private var didAutoSelect = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detailPane
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle("Activity")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                queueControlMenu(.extraction)
                queueControlMenu(.ingestion)
            }
        }
        .onAppear { viewModel.attach(engine: queueEngine) }
        .onDisappear { viewModel.detach() }
        // Auto-select the most interesting item once, when the first snapshot
        // lands — a window opened from "1 running" should show that run.
        .onChange(of: viewModel.snapshot.activeItems.map(\.id)) { _, _ in
            autoSelectIfNeeded()
        }
        .onChange(of: viewModel.snapshot.recentItems.map(\.id)) { _, _ in
            autoSelectIfNeeded()
        }
    }

    private var subtitle: String {
        let active = viewModel.snapshot.activeItems.count
        let recent = viewModel.snapshot.recentItems.count
        if active == 0 && recent == 0 { return "" }
        if active == 0 { return "\(recent) recent" }
        return "\(active) active — \(recent) recent"
    }

    private func autoSelectIfNeeded() {
        guard !didAutoSelect, selectedItemID == nil else { return }
        if let first = viewModel.snapshot.activeItems.first
            ?? viewModel.snapshot.recentItems.first {
            selectedItemID = first.id
            didAutoSelect = true
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        let active = viewModel.snapshot.activeItems
        let recent = Array(viewModel.snapshot.recentItems.prefix(30))

        if active.isEmpty && recent.isEmpty {
            ContentUnavailableView {
                Label("No Activity", systemImage: "checkmark.circle")
            } description: {
                Text("Extraction and ingestion tasks appear here.")
            }
        } else {
            List(selection: $selectedItemID) {
                if !active.isEmpty {
                    Section("Active") {
                        ForEach(active) { item in
                            itemRow(item)
                                .tag(item.id)
                        }
                    }
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { item in
                            itemRow(item)
                                .tag(item.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: QueueItem) -> some View {
        HStack(spacing: 8) {
            statusView(for: item)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(kindLabel(for: item))
                    .lineLimit(1)
                Text(rowSubtitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = item.error, item.state == .failed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(error)
                }
            }
            Spacer(minLength: 4)
            rowAction(for: item)
        }
        .padding(.vertical, 1)
        .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func statusView(for item: QueueItem) -> some View {
        switch item.state {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    /// Trailing inline action: Cancel while pending/running, Retry when
    /// failed. Borderless so rows stay quiet until needed.
    @ViewBuilder
    private func rowAction(for item: QueueItem) -> some View {
        switch item.state {
        case .running, .queued:
            Button {
                Task { await queueEngine.cancelItem(item.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        case .failed:
            Button {
                Task { try? await queueEngine.retryItem(item.id) }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Retry")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func contextMenu(for item: QueueItem) -> some View {
        switch item.state {
        case .running, .queued:
            Button("Cancel") {
                Task { await queueEngine.cancelItem(item.id) }
            }
        case .failed:
            Button("Retry") {
                Task { try? await queueEngine.retryItem(item.id) }
            }
            if let error = item.error {
                Button("Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                }
            }
        case .cancelled:
            Button("Retry") {
                Task { try? await queueEngine.retryItem(item.id) }
            }
        case .completed:
            EmptyView()
        }
    }

    // MARK: - Toolbar

    /// Per-queue pause/resume/halt as a toolbar menu — global queue controls
    /// belong in the top bar, not buried in list section headers.
    @ViewBuilder
    private func queueControlMenu(_ queue: QueueKind) -> some View {
        let state = viewModel.snapshot.runStates[queue] ?? .running
        let title = queue == .extraction ? "Extraction" : "Ingestion"
        let icon = queue == .extraction ? "doc.text.magnifyingglass" : "tray.full"
        Menu {
            if state == .running {
                Button("Pause \(title)", systemImage: "pause.fill") {
                    Task { await queueEngine.pause(queue) }
                }
            } else {
                Button("Resume \(title)", systemImage: "play.fill") {
                    Task { await queueEngine.resume(queue) }
                }
            }
            Divider()
            Button("Stop All \(title)", systemImage: "stop.fill", role: .destructive) {
                Task { await queueEngine.halt(queue) }
            }
        } label: {
            Label(title, systemImage: state == .paused ? "pause.circle.fill" : icon)
        }
        // The unified toolbar shows icon-only labels, and VoiceOver falls
        // back to the SF Symbol's name ("Inbox Full") without this.
        .accessibilityLabel("\(title) Queue")
        .help(state == .paused
            ? "\(title) queue is paused"
            : "\(title) queue controls")
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let itemID = selectedItemID, let item = item(for: itemID) {
            VStack(spacing: 0) {
                detailHeader(for: item)
                Divider()
                transcriptContent(for: item)
            }
            .task(id: itemID) {
                // If the tracker has no in-memory events for this item,
                // try loading persisted events from the DB.
                if activityTracker.transcript(for: itemID).isEmpty {
                    loadedEvents = await queueEngine.loadTranscript(for: itemID)
                } else {
                    loadedEvents = []
                }
            }
        } else if viewModel.snapshot.activeItems.isEmpty
            && viewModel.snapshot.recentItems.isEmpty {
            ContentUnavailableView {
                Label("No Activity", systemImage: "checkmark.circle")
            } description: {
                Text("Extraction and ingestion tasks appear here as they run.")
            }
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "sidebar.left")
            } description: {
                Text("Select an item to view its transcript.")
            }
        }
    }

    @ViewBuilder
    private func detailHeader(for item: QueueItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kindLabel(for: item)) — \(wikiDisplayName(for: item.wikiID))")
                    .font(.headline)
                Text(stateDescription(for: item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let error = item.error, item.state == .failed {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            Spacer()
            switch item.state {
            case .running, .queued:
                Button("Cancel") {
                    Task { await queueEngine.cancelItem(item.id) }
                }
            case .failed, .cancelled:
                Button("Retry") {
                    Task { try? await queueEngine.retryItem(item.id) }
                }
            case .completed:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func transcriptContent(for item: QueueItem) -> some View {
        // Prefer in-memory events (live); fall back to persisted (rehydrated).
        let inMemoryEvents = activityTracker.transcript(for: item.id)
        let events = inMemoryEvents.isEmpty ? loadedEvents : inMemoryEvents
        let progressText = activityTracker.progressLog(for: item.id)

        if !events.isEmpty {
            ChatWebView(events: events, style: .activityFeed, showsInternals: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !progressText.isEmpty {
            ScrollView {
                Text(progressText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
        } else {
            switch item.state {
            case .running:
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for output…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .queued:
                ContentUnavailableView {
                    Label("Queued", systemImage: "clock")
                } description: {
                    Text("Output will appear when this item starts.")
                }
            default:
                ContentUnavailableView {
                    Label("No Transcript", systemImage: "doc.plaintext")
                } description: {
                    Text("No output was recorded for this item.")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Look up the selected item in the current snapshot (active first).
    private func item(for id: QueueItem.ID) -> QueueItem? {
        viewModel.snapshot.activeItems.first { $0.id == id }
            ?? viewModel.snapshot.recentItems.first { $0.id == id }
    }

    private func wikiDisplayName(for id: String) -> String {
        sessionManager?.sessions[id]?.descriptor.displayName ?? String(id.prefix(8))
    }

    private func kindLabel(for item: QueueItem) -> String {
        if item.payload.lintPageIDs != nil { return "Lint" }
        switch item.queue {
        case .extraction: return "Extraction"
        case .ingestion: return "Ingestion"
        }
    }

    private func rowSubtitle(for item: QueueItem) -> String {
        let wiki = wikiDisplayName(for: item.wikiID)
        if let time = relativeTime(for: item) {
            return "\(wiki) · \(time)"
        }
        return wiki
    }

    private func stateDescription(for item: QueueItem) -> String {
        switch item.state {
        case .running:
            if let started = date(fromMillis: item.startedAt) {
                return "Running — started \(started.formatted(date: .omitted, time: .shortened))"
            }
            return "Running"
        case .queued:
            let added = Date(timeIntervalSince1970: Double(item.createdAt) / 1000)
            return "Queued — added \(added.formatted(date: .omitted, time: .shortened))"
        case .completed:
            if let finished = date(fromMillis: item.finishedAt) {
                return "Completed \(finished.formatted(.relative(presentation: .named)))"
            }
            return "Completed"
        case .failed:
            if let finished = date(fromMillis: item.finishedAt) {
                return "Failed \(finished.formatted(.relative(presentation: .named)))"
            }
            return "Failed"
        case .cancelled:
            if let finished = date(fromMillis: item.finishedAt) {
                return "Cancelled \(finished.formatted(.relative(presentation: .named)))"
            }
            return "Cancelled"
        }
    }

    /// Short relative time for sidebar rows ("2 min. ago"), from the most
    /// meaningful timestamp for the item's state.
    private func relativeTime(for item: QueueItem) -> String? {
        let millis: Int64? = switch item.state {
        case .running: item.startedAt
        case .queued: item.createdAt
        default: item.finishedAt ?? item.startedAt
        }
        guard let date = date(fromMillis: millis) else { return nil }
        return date.formatted(.relative(presentation: .named))
    }

    private func date(fromMillis millis: Int64?) -> Date? {
        guard let millis else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

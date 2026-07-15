import SwiftUI
import WikiFSCore
import WikiFSEngine

/// A per-queue activity window — one instance shows the Ingestion queue, the
/// other the Extraction queue, so the two pipelines read as the separate
/// systems they are. A real `NSWindow` (not transient) listing this queue's
/// items across all wikis, with expandable agent transcripts.
///
/// **Sidebar (left):** A native `List` (keyboard navigation, real selection)
/// with Active + Recent sections. Rows lead with the source filenames being
/// processed (the thing the user recognizes), with wiki + relative time
/// below; running/queued rows get an inline Cancel, failed rows an inline
/// Retry, and every row a context menu.
///
/// **Detail (right):** A header (sources, wiki, state, error, primary action)
/// over the selected item's transcript — rendered via `ChatWebView` fed from
/// `activityTracker.transcripts[itemID]`. For extraction items (which produce
/// progress strings, not typed `AgentEvent`s), falls back to the accumulated
/// progress text.
///
/// **Toolbar:** This queue's pause/resume/halt menu (global actions live in
/// the top bar, per the macOS layout formula). Since lint runs on
/// `.ingestion`, the Ingestion window covers lint too.
struct ActivityWindowView: View {
    /// Which queue this window shows. Items from the other queue are
    /// filtered out of every snapshot read.
    let queue: QueueKind
    let queueEngine: QueueEngine
    @Bindable var activityTracker: QueueActivityTracker
    weak var sessionManager: SessionManager?

    @State private var viewModel = QueueViewModel()
    @State private var selectedItemID: QueueItem.ID?
    @State private var loadedEvents: [AgentEvent] = []
    @State private var didAutoSelect = false

    private var queueTitle: String {
        queue == .extraction ? "Extraction" : "Ingestion"
    }

    private var activeItems: [QueueItem] {
        viewModel.snapshot.activeItems.filter { $0.queue == queue }
    }

    private var recentItems: [QueueItem] {
        viewModel.snapshot.recentItems.filter { $0.queue == queue }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detailPane
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(queueTitle)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                queueControlMenu
            }
        }
        .onAppear { viewModel.attach(engine: queueEngine) }
        .onDisappear { viewModel.detach() }
        // Auto-select the most interesting item once, when the first snapshot
        // lands — a window opened from "1 running" should show that run.
        .onChange(of: activeItems.map(\.id)) { _, _ in
            autoSelectIfNeeded()
        }
        .onChange(of: recentItems.map(\.id)) { _, _ in
            autoSelectIfNeeded()
        }
    }

    private var subtitle: String {
        let active = activeItems.count
        let recent = recentItems.count
        if active == 0 && recent == 0 { return "" }
        if active == 0 { return "\(recent) recent" }
        return "\(active) active — \(recent) recent"
    }

    private func autoSelectIfNeeded() {
        guard !didAutoSelect, selectedItemID == nil else { return }
        if let first = activeItems.first ?? recentItems.first {
            selectedItemID = first.id
            didAutoSelect = true
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        let active = activeItems
        let recent = Array(recentItems.prefix(30))

        if active.isEmpty && recent.isEmpty {
            emptyState
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No \(queueTitle) Activity", systemImage: "checkmark.circle")
        } description: {
            Text(queue == .extraction
                ? "PDF extraction tasks appear here as they run."
                : "Ingestion and lint tasks appear here as they run.")
        }
    }

    @ViewBuilder
    private func itemRow(_ item: QueueItem) -> some View {
        HStack(spacing: 8) {
            statusView(for: item)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle(for: item))
                    .lineLimit(1)
                    .help(targetNames(for: item).joined(separator: "\n"))
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

    /// This queue's pause/resume/halt as a toolbar menu — global queue
    /// controls belong in the top bar, not buried in list section headers.
    @ViewBuilder
    private var queueControlMenu: some View {
        let state = viewModel.snapshot.runStates[queue] ?? .running
        let icon = queue == .extraction ? "doc.text.magnifyingglass" : "tray.full"
        Menu {
            if state == .running {
                Button("Pause \(queueTitle)", systemImage: "pause.fill") {
                    Task { await queueEngine.pause(queue) }
                }
            } else {
                Button("Resume \(queueTitle)", systemImage: "play.fill") {
                    Task { await queueEngine.resume(queue) }
                }
            }
            Divider()
            Button("Stop All \(queueTitle)", systemImage: "stop.fill", role: .destructive) {
                Task { await queueEngine.halt(queue) }
            }
        } label: {
            Label(queueTitle, systemImage: state == .paused ? "pause.circle.fill" : icon)
        }
        // The unified toolbar shows icon-only labels, and VoiceOver falls
        // back to the SF Symbol's name ("Inbox Full") without this.
        .accessibilityLabel("\(queueTitle) Queue")
        .help(state == .paused
            ? "\(queueTitle) queue is paused"
            : "\(queueTitle) queue controls")
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
        } else if activeItems.isEmpty && recentItems.isEmpty {
            emptyState
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
        let targets = targetNames(for: item)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kindLabel(for: item)) — \(wikiDisplayName(for: item.wikiID))")
                    .font(.headline)
                Text(stateDescription(for: item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !targets.isEmpty {
                    Text(targetSummary(for: item, names: targets))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(targets.joined(separator: "\n"))
                }
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
        activeItems.first { $0.id == id }
            ?? recentItems.first { $0.id == id }
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

    /// Row title: lead with what's being processed (source filenames, lint
    /// targets) rather than the queue kind — inside a per-queue window, the
    /// kind is already the window title.
    private func rowTitle(for item: QueueItem) -> String {
        if let pageIDs = item.payload.lintPageIDs {
            if pageIDs.isEmpty { return "Lint \(wikiDisplayName(for: item.wikiID))" }
            let titles = lintPageTitles(for: item)
            guard let first = titles.first else { return "Lint \(pageIDs.count) pages" }
            return titles.count > 1 ? "Lint: \(first) +\(titles.count - 1)" : "Lint: \(first)"
        }
        let names = sourceNames(for: item)
        guard let first = names.first else {
            let count = item.payload.sourceIDs.count
            return count > 1 ? "\(count) sources" : kindLabel(for: item)
        }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    /// Resolve the item's source IDs to display filenames via the wiki's
    /// store. Sources deleted since enqueue (or wikis without a live session)
    /// resolve to nothing and are dropped.
    private func sourceNames(for item: QueueItem) -> [String] {
        guard let store = sessionManager?.sessions[item.wikiID]?.store else { return [] }
        return item.payload.sourceIDs.compactMap { id in
            store.sources.first { $0.id == id }?.filename
        }
    }

    /// Resolve a lint item's page IDs to page titles via the wiki's store.
    private func lintPageTitles(for item: QueueItem) -> [String] {
        guard let pageIDs = item.payload.lintPageIDs,
              let store = sessionManager?.sessions[item.wikiID]?.store else { return [] }
        return pageIDs.compactMap { id in
            store.summaries.first { $0.id == id }?.title
        }
    }

    /// What this item operates on, for the detail header: lint targets
    /// ("Entire wiki" / page titles) or source filenames.
    private func targetNames(for item: QueueItem) -> [String] {
        if let pageIDs = item.payload.lintPageIDs {
            return pageIDs.isEmpty ? ["Entire wiki"] : lintPageTitles(for: item)
        }
        return sourceNames(for: item)
    }

    /// "3 sources: a.pdf, b.md, c.txt" / "2 pages: A, B" — capped so a
    /// 50-item batch doesn't flood the header (full list in the tooltip).
    private func targetSummary(for item: QueueItem, names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        let suffix = names.count > 5 ? ", …" : ""
        if names.count == 1 { return shown }
        let noun = item.payload.lintPageIDs != nil ? "pages" : "sources"
        return "\(names.count) \(noun): \(shown)\(suffix)"
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

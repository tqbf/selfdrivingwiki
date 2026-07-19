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
    /// Bridges the SwiftUI environment's `openSettings` action so the
    /// "Configure…" CTA buttons can open Settings on the relevant tab
    /// (#440). Set by `MenuBarItemController` when creating the window.
    var openWindowBridge: OpenWindowBridge?

    @State private var viewModel = QueueViewModel()
    @State private var selectedItemID: QueueItem.ID?
    @State private var loadedEvents: [AgentEvent] = []
    @State private var didAutoSelect = false

    private var queueTitle: String {
        queue == .extraction ? "Extraction Queue" : "Agent Queue"
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

    // MARK: - Reorder

    /// Handle a drag-to-reorder in the Active section. Translates the
    /// SwiftUI `onMove` indices into a `queueEngine.reorderItem` call.
    /// Only `.queued` items can be moved — `.running` items are silently
    /// ignored (the engine's `reorderItem` guard rejects them).
    private func handleMove(
        in active: [QueueItem],
        from sources: IndexSet,
        to destination: Int
    ) {
        guard let movedIndex = sources.first,
              movedIndex < active.count else { return }
        let movedItem = active[movedIndex]

        // Compute the item that will follow the moved item after the drop.
        // SwiftUI's `destination` is the target index in the list *after*
        // the source is removed, so we adjust accordingly.
        let adjustedDest: Int
        if movedIndex < destination {
            adjustedDest = destination - 1
        } else {
            adjustedDest = destination
        }

        let beforeItemID: QueueItem.ID?
        if adjustedDest >= active.count {
            // Moved to end — no item before it.
            beforeItemID = nil
        } else {
            beforeItemID = active[adjustedDest].id
        }

        Task {
            await queueEngine.reorderItem(id: movedItem.id, beforeItemID: beforeItemID)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        let active = activeItems
        let recent = Array(recentItems.prefix(30))
        // Precompute all @Observable-derived display data ONCE, so the
        // ForEach row body reads only plain values. This eliminates the
        // per-row swift_task_isMainExecutorImpl isolation checks that
        // triggered a use-after-free crash (EXC_BAD_ACCESS in
        // swift_getObjectType during ObservationCenter._withObservation)
        // when observable state changed concurrently with row evaluation —
        // e.g. cancelling a lint job. See swiftlang/swift#89197.
        let displayData = buildRowDisplayData(for: active + recent)

        if active.isEmpty && recent.isEmpty {
            emptyState
        } else {
            List(selection: $selectedItemID) {
                if !active.isEmpty {
                    Section("Active") {
                        ForEach(active) { item in
                            itemRow(item, displayData: displayData[item.id])
                                .tag(item.id)
                        }
                        .onMove { sources, destination in
                            handleMove(in: active, from: sources, to: destination)
                        }
                    }
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { item in
                            itemRow(item, displayData: displayData[item.id])
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
    private func itemRow(_ item: QueueItem, displayData: RowDisplayData?) -> some View {
        let data = displayData ?? RowDisplayData(
            title: kindLabel(for: item),
            subtitle: String(item.wikiID.prefix(8)),
            targetNames: [],
            usage: nil,
            liveUsage: nil,
            pendingPermission: nil)
        HStack(spacing: 8) {
            statusView(for: item)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(data.title)
                    .lineLimit(1)
                    .help(data.targetNames.joined(separator: "\n"))
                Text(data.subtitle)
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
                // #528 spike: show per-run token/cost usage on completed rows.
                if item.state == .completed, let usage = data.usage {
                    Text(UsageFormatter.fullSummary(
                        usage: usage,
                        startedAt: item.startedAt,
                        finishedAt: item.finishedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // #544 live progress: show running token counts + model during
                // the run. Cleared on terminal state by the tracker. Elapsed
                // time ticks here via TimelineView (per-second) so the line
                // updates even between usage_updates. Not shown for queued
                // items (no live data yet).
                if item.state == .running, let usage = data.liveUsage {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = elapsedString(item.startedAt, now: context.date)
                        let line = UsageFormatter.liveSummary(usage: usage)
                        Text(line.isEmpty ? elapsed : "\(line) · \(elapsed)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                // #608: surface a pending always-ask permission stall as a
                // yellow "Permission pending: <cmd>" row. Mirrors how streamed
                // `AgentEvent`s + live usage flow into the row — the tracker's
                // `.pendingPermission` event sets/clears this. Reuses the
                // `exclamationmark.triangle.fill` + `.orange` pattern from the
                // Agents-settings model-warning (PR #605). ACP agents gate one
                // write at a time, so at most one pending row per item.
                if let permission = data.pendingPermission {
                    PermissionPendingRow(
                        permission: permission,
                        font: .caption,
                        lineLimit: 2)
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
                retry(item: item)
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
        if copyableText(for: item) != nil {
            Button("Copy Transcript", systemImage: "doc.on.doc") {
                copyTranscript(for: item)
            }
        }
        let logURL = activityTracker.logURL(for: item.id)
        let debugURL = activityTracker.debugURL(for: item.id)
        if logURL != nil || debugURL != nil {
            Divider()
            if let logURL {
                Button("Reveal Log", systemImage: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
            }
            if let debugURL {
                Button("Reveal Debug Folder", systemImage: "folder.badge.gearshape") {
                    NSWorkspace.shared.activateFileViewerSelecting([debugURL])
                }
            }
        }
        switch item.state {
        case .running, .queued:
            Button("Cancel") {
                Task { await queueEngine.cancelItem(item.id) }
            }
        case .failed:
            Button("Retry") {
                retry(item: item)
            }
            if let error = item.error {
                Button("Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                }
            }
        case .cancelled:
            Button("Retry") {
                retry(item: item)
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
                if item.payload.lintPageIDs != nil {
                    lintedPagesSection(for: item)
                    Divider()
                }
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
                    // #440: when the failure is a "not configured" error (the
                    // provider binary wasn't found, no API key, etc.), show a
                    // call-to-action button that opens Settings on the relevant
                    // tab so the user can fix it without guessing.
                    if isConfigurationError(error), openWindowBridge != nil {
                        Button(action: {
                            let tab = queue == .extraction ? "extraction" : "agents"
                            openWindowBridge?.openSettings(tab: tab)
                        }) {
                            Label(
                                queue == .extraction ? "Configure Extraction…" : "Configure Agents…",
                                systemImage: "gearshape"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                // #608: surface a pending always-ask permission stall in the
                // detail header too (mirrors how liveUsage + usage appear on
                // both the sidebar row and the detail header). Same yellow
                // `exclamationmark.triangle.fill` pattern as the sidebar row +
                // the Agents-settings model-warning. Reads `pendingPermission`
                // directly — the detail pane isn't driven by `RowDisplayData`,
                // and the `@Observable` read here is safe (we're outside the
                // sidebar's crash-prone `ForEachChild.updateValue` path that
                // motivated the precompute in the first place).
                if let permission = activityTracker.pendingPermission(for: item.id) {
                    PermissionPendingRow(
                        permission: permission,
                        font: .callout,
                        lineLimit: 3,
                        textSelection: true)
                }
                // #544 live progress: show running token counts + model + elapsed
                // during the run. Elapsed time ticks via TimelineView per second.
                // Cleared on completion; the #528 full summary takes over below.
                if item.state == .running, let usage = activityTracker.liveUsage(for: item.id) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = elapsedString(item.startedAt, now: context.date)
                        let line = UsageFormatter.liveSummary(usage: usage)
                        Text(line.isEmpty ? elapsed : "\(line) · \(elapsed)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                // #528 spike: show per-run usage in the detail header too.
                if let usage = activityTracker.usage(for: item.id) {
                    Text(UsageFormatter.fullSummary(
                        usage: usage,
                        startedAt: item.startedAt,
                        finishedAt: item.finishedAt))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                // #583: per-model breakdown for this run. Today most runs
                // merge their phases into a single snapshot, so the breakdown
                // has one entry and reads as a slightly-redundant second line —
                // but the structure is here for when phases start emitting
                // individual usage events (planner vs executor vs finalizer
                // using different models). Only shown when there's a model id
                // in the breakdown (otherwise the aggregate line above
                // already covered everything).
                let byModel = activityTracker.usageBreakdown(for: item.id)
                if byModel.count > 1 {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(byModelSorted(byModel), id: \.modelId) { entry in
                            Text(UsageFormatter.itemModelBreakdownLine(
                                modelId: entry.modelId,
                                breakdown: entry.breakdown,
                                usage: activityTracker.usage(for: item.id)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.leading, 6)
                }
            }
            Spacer()
            if copyableText(for: item) != nil {
                Button("Copy Transcript", systemImage: "doc.on.doc") {
                    copyTranscript(for: item)
                }
                .help("Copy transcript as plain text")
            }
            revealMenu(for: item)
            switch item.state {
            case .running, .queued:
                Button("Cancel") {
                    Task { await queueEngine.cancelItem(item.id) }
                }
            case .failed, .cancelled:
                Button("Retry") {
                    retry(item: item)
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
            ChatWebView(
                events: events,
                style: .activityFeed,
                showsInternals: false,
                onWikiLink: wikiLinkHandler(for: item.wikiID),
                // Resolve ghost-link coloring + blob serving from THIS item's
                // wiki store (the transcript's `[[wiki-links]]` point into the
                // wiki the agent ran against, not a different one). nil when
                // the wiki window is closed — links still render but without
                // resolution-based styling (the same degradation the in-wiki
                // feed tolerates when a store is mid-swap).
                renderContext: renderContextProvider(for: item.wikiID),
                blobStore: store(for: item.wikiID)
            )
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ContentUnavailableView {
                    Label("No Transcript", systemImage: "doc.plaintext")
                } description: {
                    Text("No output was recorded for this item.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Lint page navigation

    /// Lint jobs carry `lintPageIDs` in their payload. For a page-level lint we
    /// list every linted page with an "Open" action that opens it in the wiki's
    /// main window (the shared `WikiStoreModel`); for a whole-wiki lint
    /// (`lintPageIDs == []`) we show "All pages linted" with a "Browse Pages"
    /// button that focuses the wiki window on its Pages sidebar.
    @ViewBuilder
    private func lintedPagesSection(for item: QueueItem) -> some View {
        let pageIDs = item.payload.lintPageIDs ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text(pageIDs.isEmpty ? "Lint Scope" : "Linted Pages")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if pageIDs.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.secondary)
                    Text("All pages linted")
                        .font(.callout)
                    Spacer(minLength: 4)
                    Button("Browse Pages", systemImage: "sidebar.left") {
                        browsePages(in: item.wikiID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Switch to the Pages list in the wiki window")
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(pageIDs, id: \.self) { pageID in
                        lintPageRow(pageID: pageID, wikiID: item.wikiID)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// A single linted page: title (resolved from the wiki's store) with an
    /// "Open" button. Pages deleted since the lint ran resolve to a placeholder.
    @ViewBuilder
    private func lintPageRow(pageID: PageID, wikiID: String) -> some View {
        let title = pageTitle(pageID, wikiID: wikiID) ?? "Deleted page"
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            Spacer(minLength: 4)
            Button("Open", systemImage: "arrow.up.forward.app") {
                openPage(pageID, in: wikiID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open this page in the wiki window")
        }
    }

    /// Resolve a page ID to its current title via the wiki's store, or `nil`
    /// if the page no longer exists / the session isn't live.
    private func pageTitle(_ pageID: PageID, wikiID: String) -> String? {
        sessionManager?.sessions[wikiID]?.store
            .summaries.first { $0.id == pageID }?.title
    }

    /// Open a linted page in its wiki's main window. The `WikiStoreModel` is
    /// shared across windows (one session per wiki), so `openTab` mutates the
    /// same model the main window observes; `openWiki` then focuses that window
    /// — mirroring the bookmark "Go to Original" navigation (#570).
    private func openPage(_ pageID: PageID, in wikiID: String) {
        guard let store = sessionManager?.sessions[wikiID]?.store else {
            DebugLog.tabs("Lint Open Page: no live session for wiki \(wikiID.prefix(8)); cannot open page")
            return
        }
        store.openTab(.page(pageID))
        openWindowBridge?.openWiki?(wikiID)
        DebugLog.tabs("Lint Open Page: opened page \(pageID) in wiki \(wikiID.prefix(8))")
    }

    /// Whole-wiki lint "Browse Pages": reveal the wiki's home page (switches the
    /// shared model's sidebar to the Pages section via the same
    /// `requestSidebarReveal` mechanism the bookmark "Go to Original" action
    /// uses, #570), then focus the wiki window. Falls back to the first page if
    /// there's no home page, and to focusing the window only if the wiki has no
    /// pages / no live session.
    private func browsePages(in wikiID: String) {
        let session = sessionManager?.sessions[wikiID]
        let store = session?.store
        if store != nil, let homeID = session?.descriptor.homePageID {
            store?.requestSidebarReveal(.page(homeID))
            DebugLog.tabs("Lint Browse Pages: revealed home page in wiki \(wikiID.prefix(8))")
        } else if let firstID = store?.summaries.first?.id {
            store?.requestSidebarReveal(.page(firstID))
            DebugLog.tabs("Lint Browse Pages: revealed first page in wiki \(wikiID.prefix(8))")
        } else {
            DebugLog.tabs("Lint Browse Pages: no pages to reveal in wiki \(wikiID.prefix(8)); focusing window only")
        }
        openWindowBridge?.openWiki?(wikiID)
    }

    // MARK: - Reveal log / debug folder

    /// A compact menu offering "Reveal Log" and "Reveal Debug Folder" for the
    /// selected item. Only shown when at least one path is available — items
    /// that never spawned an agent (preflight failure, cancelled before run)
    /// won't have either. Mirrors the ChatView's activity menu.
    @ViewBuilder
    private func revealMenu(for item: QueueItem) -> some View {
        let logURL = activityTracker.logURL(for: item.id)
        let debugURL = activityTracker.debugURL(for: item.id)
        if logURL != nil || debugURL != nil {
            Menu {
                if let logURL {
                    Button("Reveal Log", systemImage: "doc.text.magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                    .help("Reveal the lightweight run.jsonl log in Finder")
                }
                if let debugURL {
                    Button("Reveal Debug Folder", systemImage: "folder.badge.gearshape") {
                        NSWorkspace.shared.activateFileViewerSelecting([debugURL])
                    }
                    .help("Open the complete debug trace folder (ACP messages, permissions, usage)")
                }
            } label: {
                Label("Reveal", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .help("Reveal log files in Finder")
        }
    }

    // MARK: - Copy

    /// The plain-text content available to copy for this item, or `nil` if
    /// there's nothing to copy. Uses the same event/progress-fallback logic as
    /// `transcriptContent(for:)` so Copy always reflects what's on screen.
    private func copyableText(for item: QueueItem) -> String? {
        let inMemoryEvents = activityTracker.transcript(for: item.id)
        let events = inMemoryEvents.isEmpty ? loadedEvents : inMemoryEvents

        if !events.isEmpty {
            let lines = events.map(\.plainText).filter { !$0.isEmpty }
            if lines.isEmpty { return nil }
            return lines.joined(separator: "\n\n")
        }

        let progressText = activityTracker.progressLog(for: item.id)
        return progressText.isEmpty ? nil : progressText
    }

    /// Copy the selected item's transcript to the pasteboard as plain text.
    private func copyTranscript(for item: QueueItem) {
        guard let text = copyableText(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// #635: retry the given queue item WITHOUT swallowing the throw. The
    /// previous `try?` form silently no-op'd on invalid-state transitions
    /// (e.g. the row reshuffled between the button render and the click), so
    /// the user clicked Retry and nothing happened — no log, no feedback.
    /// This form surfaces the failure to Console.app via `DebugLog.ingest`
    /// (house rule: never bare `try?`).
    ///
    /// The actual run-time failure path (agent disabled / process dead /
    /// spawn dead-ends with "Agent process is not running") is surfaced
    /// separately: `QueueEngine.runWorker` → `handleWorkerFinished` calls
    /// `store.markFailed(error:)`, which emits a `.failed` queue event the
    /// snapshot loop renders with the actionable error + CTA via
    /// ``isConfigurationError``.
    private func retry(item: QueueItem) {
        Task {
            do {
                try await queueEngine.retryItem(item.id)
            } catch {
                DebugLog.ingest("ActivityWindow: retry failed for item \(item.id.prefix(8)) (state=\(item.state.rawValue)) — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    /// Look up the selected item in the current snapshot (active first).
    private func item(for id: QueueItem.ID) -> QueueItem? {
        activeItems.first { $0.id == id }
            ?? recentItems.first { $0.id == id }
    }

    // MARK: - Wiki-link navigation (cross-window)

    /// The store for `wikiID` if that wiki's window is open, else nil. Used
    /// for `blobStore` + the `renderContext` provider on the transcript's
    /// `ChatWebView` — a closed wiki degrades gracefully (links render, no
    /// ghost coloring / blob serving), since the agent's transcript text is
    /// self-contained HTML.
    private func store(for wikiID: String) -> WikiStoreModel? {
        sessionManager?.sessions[wikiID]?.store
    }

    /// A `WikiRenderContext` provider bound to `wikiID`'s store, or nil when
    /// the wiki window is closed. `nil` preserves the historical constant-
    /// `true` resolution in `ChatWebView` (links render as resolved — the
    /// best we can do without a live store to query).
    private func renderContextProvider(for wikiID: String) -> (() -> WikiRenderContext?)? {
        guard let store = store(for: wikiID) else { return nil }
        return { [weak store] in store?.renderContext() }
    }

    /// Build the `onWikiLink` closure for a transcript whose `[[wiki-links]]`
    /// point into `wikiID`. This is the Activity window's core gap: until now
    /// `ChatWebView` was constructed with a `nil` handler, so clicks were
    /// inert. The handler follows the same routing as the in-wiki chat
    /// transcript (`WikiReaderView.onWikiLinkHandler(for:)`) but must cross
    /// window boundaries:
    ///
    /// 1. If `wikiID`'s window is open → the live store is ready; route the
    ///    click directly through `WikiReaderView.onWikiLinkHandler(for:)` —
    ///    the exact handler the in-wiki chat transcript uses. `⌘-click`
    ///    (`openInNewTab`) carries through to `selectPage`/`selectSource`.
    /// 2. If `wikiID`'s window is closed → stash the deferred link on the
    ///    session manager, then `openWindowBridge.openWiki(wikiID)` opens (or
    ///    focuses) the window. `RootScene.resolveSession` creates the session,
    ///    transfers the stash onto it, and `RootView.onAppear` delivers it to
    ///    the store via the same `onWikiLinkHandler`.
    private func wikiLinkHandler(for wikiID: String) -> (URL, Bool) -> Void {
        { url, openInNewTab in
            if let store = self.sessionManager?.sessions[wikiID]?.store {
                // Window open → route directly (same path as the in-wiki chat).
                WikiReaderView.onWikiLinkHandler(for: store)(url, openInNewTab)
            } else {
                // Window closed → stash + open. The stash is consumed when the
                // session resolves and `RootView` appears.
                self.sessionManager?.stashPendingWikiLink(
                    wikiID, url: url, openInNewTab: openInNewTab
                )
                self.openWindowBridge?.openWiki?(wikiID)
            }
        }
    }

    /// Detects whether a failed item's error message is a "not configured"
    /// error (binary not on PATH, no API key, no endpoint, agent disabled,
    /// or the warm ACP subprocess died) rather than a generic runtime error
    /// (e.g. convert failed, network blip mid-page). Used to decide whether
    /// to show the "Configure…" call-to-action button (#440, extended #635).
    ///
    /// Matches the wording from `QueueIngestionError.notReady`,
    /// `QueueExtractionError.notReady`, the `ExtractionReadiness`
    /// `.needsSetup`/`.notInstalled` cases, and the dead-process / agent-
    /// disabled class surfaced by `AppQueueIngestionProvider.readiness` and
    /// `ACPBackend.send`'s "Agent process is not running" failure (#635).
    /// Conservative: only surfaces the CTA when the error clearly points at
    /// configuration or a fixable agent-availability issue, so a generic
    /// "convert failed" doesn't show a misleading gear button.
    private func isConfigurationError(_ message: String) -> Bool {
        Self.isConfigurationErrorMarker(message)
    }

    /// #635: pure marker matcher for ``isConfigurationError``. Extracted to a
    /// static function so the regressions for the new "agent is not available" /
    /// "agent process is not running" markers (and the existing readiness
    /// markers) can be unit-tested directly without instantiating the SwiftUI
    /// view — see `RetryStuckRegressionTests`. PURE + `nonisolated` so tests
    /// can call without a main-actor hop (the matcher reads no AppKit /
    /// observable state — just String matching).
    nonisolated static func isConfigurationErrorMarker(_ message: String) -> Bool {
        let lower = message.lowercased()
        // Markers from the readiness messages:
        // - "was not found on your PATH"
        // - "has no command configured"
        // - "Open Settings → Agents" / "Open Settings → Extraction"
        // - "no api key" / "add your … api key"
        // - "set a docling serve endpoint"
        // - "dependencies aren't installed" (local pdf2md)
        // - "fix it in settings → agents"
        //
        // #635 markers — the retry-after-kill dead-end class. When the agent
        // was disabled (or its warm subprocess was torn down on cancel), the
        // readiness probe surfaces "agent is not available" / "re-enable the
        // agent"; the older dead-process path surfaces "agent process is not
        // running" from the swift-acp SDK through `ACPBackend.send`. Both
        // are fixable from Settings → Agents, so both should surface the CTA
        // rather than leaving the row showing a stuck, generic error.
        let markers = [
            "was not found on your path",
            "has no command configured",
            "open settings → agents",
            "open settings → extraction",
            "add your anthropic api key",
            "add your google ai studio api key",
            "set a docling serve endpoint",
            "dependencies aren't installed",
            "fix it in settings → agents",
            // #635 — agent-disabled / dead-process class:
            "agent is not available",
            "re-enable the agent",
            "agent is disabled",
            "agent process is not running",
            "acp agent subprocess died",
            "no enabled agent provider"
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    private func wikiDisplayName(for id: String) -> String {
        sessionManager?.sessions[id]?.descriptor.displayName ?? String(id.prefix(8))
    }

    /// #583: Sort a per-item per-model breakdown for display — largest total
    /// tokens first, unknown-model bucket last. Mirrors
    /// `DailyUsageByModel.sortedForDisplay` so the menu bar and the Activity
    /// window render in the same order.
    private func byModelSorted(
        _ byModel: [String: ModelUsageBreakdown]
    ) -> [(modelId: String, breakdown: ModelUsageBreakdown)] {
        byModel
            .filter { $0.value.hasData }
            .sorted { lhs, rhs in
                let lhsUnknown = lhs.key == ModelUsageBreakdown.unknownModelKey
                let rhsUnknown = rhs.key == ModelUsageBreakdown.unknownModelKey
                if lhsUnknown != rhsUnknown { return rhsUnknown }
                return lhs.value.totalTokens > rhs.value.totalTokens
            }
            .map { (modelId: $0.key, breakdown: $0.value) }
    }

    private func kindLabel(for item: QueueItem) -> String {
        if item.payload.lintPageIDs != nil { return "Lint" }
        switch item.queue {
        case .extraction: return "Extraction"
        case .ingestion: return "Ingestion"
        }
    }

    // MARK: - Row display data (precomputed to avoid @Observable reads in ForEach)

    /// Plain value type holding everything `itemRow` needs to render. Precomputed
    /// in the sidebar getter so the `ForEach` row body reads only values — zero
    /// `@MainActor @Observable` property accesses inside the row body.
    ///
    /// This eliminates the per-row `swift_task_isMainExecutorImpl` isolation
    /// checks that triggered a use-after-free crash (EXC_BAD_ACCESS in
    /// `swift_getObjectType` during `ObservationCenter._withObservation`) when
    /// observable state changed concurrently with row re-evaluation — e.g.
    /// cancelling a lint job from the Activity window. See crash report
    /// 0C5B28C2 and swiftlang/swift#89197.
    private struct RowDisplayData {
        let title: String
        let subtitle: String
        let targetNames: [String]
        let usage: SessionUsage?
        let liveUsage: SessionUsage?
        /// #608: pending always-ask permission for this item, or `nil` when
        /// the run isn't blocked. Surfaces a yellow "Permission pending:
        /// <cmd>" row below the status row in the sidebar — same pattern as
        /// the Agents-settings model-warning (`exclamationmark.triangle.fill`
        /// + `.orange`).
        let pendingPermission: PendingPermission?
    }

    /// Snapshot all `@Observable`-derived display data for the given items into
    /// plain values. Called ONCE from the sidebar getter; the result is passed
    /// to each `itemRow` so the row body has no observable accesses. Each read
    /// here is tracked by `ObservationCenter` at the sidebar level (correct — the
    /// sidebar re-renders when sessions/sources/usage change) rather than per-row
    /// inside `ForEachChild.updateValue` (where the runtime bug fires).
    private func buildRowDisplayData(for items: [QueueItem]) -> [QueueItem.ID: RowDisplayData] {
        // Snapshot the observable dictionaries once.
        let sessions = sessionManager?.sessions ?? [:]
        let itemUsage = activityTracker.itemUsage
        let liveUsage = activityTracker.liveUsage
        let pendingPermissions = activityTracker.pendingPermissions

        var result: [QueueItem.ID: RowDisplayData] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            let session = sessions[item.wikiID]
            let wikiName = session?.descriptor.displayName ?? String(item.wikiID.prefix(8))
            let store = session?.store

            // Resolve source/page names (observable reads on WikiStoreModel).
            // Same lookups as `sourceNames(for:)` and `lintPageTitles(for:)`,
            // just batched into one pass per item rather than per row render.
            let names: [String]
            let targets: [String]
            if let pageIDs = item.payload.lintPageIDs {
                let titles = pageIDs.compactMap { id in
                    store?.summaries.first { $0.id == id }?.title
                }
                names = titles
                targets = pageIDs.isEmpty ? ["Entire wiki"] : titles
            } else {
                let resolved = item.payload.sourceIDs.compactMap { id in
                    store?.sources.first { $0.id == id }?.effectiveName
                }
                names = resolved
                targets = resolved
            }

            result[item.id] = RowDisplayData(
                title: computeRowTitle(for: item, wikiName: wikiName, names: names),
                subtitle: computeRowSubtitle(for: item, wikiName: wikiName),
                targetNames: targets,
                usage: itemUsage[item.id],
                liveUsage: liveUsage[item.id],
                pendingPermission: pendingPermissions[item.id])
        }
        return result
    }

    /// Pure computation of the row title from pre-resolved data (no
    /// `@Observable` reads). Shared between `buildRowDisplayData` (precompute
    /// path) and `rowTitle(for:)` (detail pane).
    private func computeRowTitle(for item: QueueItem, wikiName: String, names: [String]) -> String {
        if let pageIDs = item.payload.lintPageIDs {
            if pageIDs.isEmpty { return "Lint \(wikiName)" }
            guard let first = names.first else { return "Lint \(pageIDs.count) pages" }
            return names.count > 1 ? "Lint: \(first) +\(names.count - 1)" : "Lint: \(first)"
        }
        guard let first = names.first else {
            let count = item.payload.sourceIDs.count
            return count > 1 ? "\(count) sources" : kindLabel(for: item)
        }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    /// Pure computation of the row subtitle from pre-resolved data.
    private func computeRowSubtitle(for item: QueueItem, wikiName: String) -> String {
        if let time = relativeTime(for: item) {
            return "\(wikiName) · \(time)"
        }
        return wikiName
    }

    /// Row title for the detail pane (the sidebar precomputes via
    /// `buildRowDisplayData`). Reads `@Observable` properties — only safe
    /// outside `ForEachChild.updateValue`.
    private func rowTitle(for item: QueueItem) -> String {
        let wikiName = wikiDisplayName(for: item.wikiID)
        let names: [String]
        if item.payload.lintPageIDs != nil {
            names = lintPageTitles(for: item)
        } else {
            names = sourceNames(for: item)
        }
        return computeRowTitle(for: item, wikiName: wikiName, names: names)
    }

    /// Row subtitle for the detail pane. Reads `@Observable` — same caveat as
    /// ``rowTitle(for:)``.
    private func rowSubtitle(for item: QueueItem) -> String {
        computeRowSubtitle(for: item, wikiName: wikiDisplayName(for: item.wikiID))
    }

    /// Resolve the item's source IDs to display filenames via the wiki's
    /// store. Sources deleted since enqueue (or wikis without a live session)
    /// resolve to nothing and are dropped.
    private func sourceNames(for item: QueueItem) -> [String] {
        guard let store = sessionManager?.sessions[item.wikiID]?.store else { return [] }
        return item.payload.sourceIDs.compactMap { id in
            store.sources.first { $0.id == id }?.effectiveName
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

    /// Compact elapsed-time string from an epoch-ms start timestamp to `now`.
    /// Used by the live-usage row line (#544) so it ticks independently of
    /// usage_updates. Mirrors `AgentRunStatusView.durationString`'s format:
    /// "42s", "3m 12s", "1h 5m". Returns "—" when no start timestamp.
    private func elapsedString(_ startedAtMs: Int64?, now: Date) -> String {
        guard let startedAtMs, startedAtMs > 0 else { return "—" }
        let start = Date(timeIntervalSince1970: Double(startedAtMs) / 1000)
        let seconds = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
        if seconds < 60 { return "\(seconds)s elapsed" }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)m elapsed" : "\(minutes)m \(remainingSeconds)s elapsed"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h elapsed" : "\(hours)h \(remainingMinutes)m elapsed"
    }
}

// MARK: - PermissionPendingRow (#608)

/// A yellow "Permission pending: <cmd>" row shown inside the Activity window's
/// sidebar row + detail header while a run is parked on an always-ask prompt.
///
/// Extracted as its own leaf so:
/// - the sidebar + detail call sites stay DRY (rule 4.4: one Row, parameterized
///   by data), and
/// - render tests can host this view in isolation and assert the yellow row
///   appears when a `permission` is set and disappears when cleared (the issue
///   #608 verification spec).
///
/// The visual treatment mirrors `AgentsSettingsView.modelWarning`:
/// `exclamationmark.triangle.fill` + `.orange` (PR #605). Pass `nil` to render
/// nothing (the conditional `if let permission` at the call site already guards
/// this, but the leaf is safe under both paths so the call site reads cleanly).
struct PermissionPendingRow: View {
    let permission: PendingPermission
    var font: Font = .caption
    var lineLimit: Int? = 2
    var textSelection: Bool = false

    var body: some View {
        Label {
            Text(ActivityWindowView.permissionPendingLabel(for: permission))
                .lineLimit(lineLimit)
                .if(textSelection) { view in view.textSelection(.enabled) }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(font)
        .foregroundStyle(.orange)
        .help(permission.inputSummary ?? permission.title ?? "Permission pending")
    }
}

private extension View {
    /// Apply `transform` only when `condition` is true. Used to opt the row's
    /// text into `.textSelection(.enabled)` only at the callout (detail
    /// header) scale — at caption scale (sidebar row) text selection clutters
    /// the row's hover affordances and isn't useful.
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

extension ActivityWindowView {
    /// #608: the caption shown on the yellow "Permission pending" row. Prefers
    /// the tool name (e.g. "Edit file"); falls back to the input summary (the
    /// path being edited) when the tool name is unavailable; final fallback is
    /// the literal "Permission pending" so the row is informative even when
    /// the backend's pending snapshot is sparse.
    ///
    /// `internal` (not `private`) + an `extension ActivityWindowView` so the
    /// `@testable import WikiFS` render test can call it directly to assert
    /// the format — without rendering the SwiftUI tree, which is brittle.
    static func permissionPendingLabel(for permission: PendingPermission) -> String {
        let cmd: String
        if let toolName = permission.toolName, !toolName.isEmpty {
            cmd = toolName
        } else if let summary = permission.inputSummary, !summary.isEmpty {
            cmd = summary
        } else if let title = permission.title, !title.isEmpty {
            cmd = title
        } else {
            return "Permission pending"
        }
        return "Permission pending: \(cmd)"
    }
}

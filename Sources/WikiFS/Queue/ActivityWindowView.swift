import SwiftUI
import WikiFSCore
import WikiFSEngine

/// Value-only input for the Activity window's typed transcript surface. It
/// keeps canonical merge, copy text, transcript identity, and renderer
/// dependencies together so the hosted window and its tests use one seam.
@MainActor
struct ActivityTranscriptPresentation {
    let items: [ChatTranscriptItem]
    let progressText: String
    let transcriptID: TranscriptID
    let isStreaming: Bool
    let onIntent: (ChatTranscriptIntent) -> Void
    let renderContext: (() -> WikiRenderContext?)?
    let blobStore: WikiStoreModel?

    static func canonicalItems(
        persisted: [ChatTranscriptItem],
        live: [ChatTranscriptItem]
    ) -> [ChatTranscriptItem] {
        QueueTranscriptCanonicalMerge.merging(persisted: persisted, live: live)
    }

    var usesProgressFallback: Bool {
        items.isEmpty && progressText.isEmpty == false
    }

    var copyText: String? {
        if items.isEmpty == false {
            let lines = items.map(Self.plainText).filter { $0.isEmpty == false }
            return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
        }
        return progressText.isEmpty ? nil : progressText
    }

    func transcriptView() -> ChatTranscriptView {
        ChatTranscriptView(
            rendering: .init(transcript: ChatDisplayProjection.project(
                items: items,
                activeContentBlock: nil
            ).transcript),
            transcriptID: transcriptID,
            emptyStateMessage: "No activity yet.",
            isStreaming: isStreaming,
            onIntent: onIntent,
            renderContext: renderContext,
            blobStore: blobStore
        )
    }

    private static func plainText(_ item: ChatTranscriptItem) -> String {
        switch item {
        case .message(let message): return message.text
        case .toolCall(let tool): return [tool.toolName, tool.detail, tool.output].compactMap { $0 }.joined(separator: "\n")
        case .systemNotice(let notice): return [notice.title, notice.message].compactMap { $0 }.joined(separator: "\n")
        case .turnFailure(let failure): return failure.message
        }
    }
}

/// A per-queue activity window — one instance shows the Ingestion queue, the
/// other the Extraction queue, so the two pipelines read as the separate
/// systems they are. A real `NSWindow` (not transient) listing this queue's
/// items across all wikis, with the selected job's Overview inventory and
/// Activity transcript.
///
/// **Sidebar (left):** A native `List` (keyboard navigation, real selection)
/// with Active + Recent sections. Rows lead with the source filenames being
/// processed (the thing the user recognizes), with wiki + relative time
/// below; running/queued rows get an inline Cancel, failed rows an inline
/// Retry, and every row a context menu.
///
/// **Detail (right):** A header (sources, wiki, state, error, primary action)
/// over the selected job's workspace — the Overview inventory or the Activity
/// transcript, chosen by the Overview/Activity selector. Activity renders via
/// `ChatWebView` fed from `activityTracker.transcripts[itemID]`. For
/// extraction items (which produce progress strings, not transcript rows), it
/// falls back to the accumulated progress text. Run Details lives in an
/// OPTIONAL trailing inspector panel (never a permanently visible third
/// column), opened by the toolbar's "Run Details" toggle — it is not part of
/// the Overview.
///
/// **Toolbar:** a leading job-search control, then — right-aligned after a
/// flexible spacer, icon-only per design change 7 — this queue's "Queue
/// Actions" menu (pause/resume with inline guidance + Stop All… with its
/// explicit confirmation) and the Run Details inspector toggle (global
/// actions live in the top bar, per the macOS layout formula). Since lint
/// runs on `.ingestion`, the Ingestion window covers lint too.
struct ActivityWindowView: View {
    /// Which queue this window shows. Items from the other queue are
    /// filtered out of every snapshot read.
    let queue: QueueKind
    let queueEngine: any QueueEngineClient
    @Bindable var activityTracker: QueueActivityTracker
    weak var sessionManager: SessionManager?
    /// Bridges the SwiftUI environment's `openSettings` action so the
    /// "Configure…" CTA buttons can open Settings on the relevant tab
    /// (#440). Set by `MenuBarItemController` when creating the window.
    var openWindowBridge: OpenWindowBridge?
    /// Where a closed wiki's database lives, for the read-only name
    /// fallback (closed-wiki name resolution). Production resolves the App
    /// Group container location; hosted tests inject a nil provider (or a
    /// fixture path) to stay hermetic.
    var closedWikiDatabaseURLProvider: @Sendable (WikiID) -> URL? = ActivityWindowView.productionClosedWikiDatabaseURL

    @State private var viewModel = QueueViewModel()
    @State private var selectedItemID: QueueItem.ID?
    @State private var loadedTranscriptItems: [ChatTranscriptItem] = []
    @State private var didAutoSelect = false
    @State private var jobFilter = QueueJobFilter()
    @State private var isCommandPending = false
    @State private var commandError: String?
    @State private var confirmsStopAll = false
    /// Overview ↔ Activity selector for the selected job's workspace (plan §1).
    /// Every new selection resets to Overview; both surfaces stay mounted so
    /// switching never drops streaming data or the transcript scroll position.
    @State private var workspaceSurface: QueueWorkspaceSurface = .overview
    /// Whether the optional Run Details inspector panel is open. Toggled by
    /// the window toolbar's icon-only "Run Details" control; closing it
    /// never touches selection or queue state — the panel is
    /// presentation-only.
    @State private var showsRunDetailsInspector = false
    /// The split view's measured content width (design change 6): drives the
    /// toolbar search's expand/collapse decision
    /// (``QueueSearchToolbarForm/decision``). `nil` until the first layout
    /// measurement; `nil` assumes enough space (expanded).
    @State private var splitViewWidth: CGFloat?
    /// Whether the user explicitly expanded the collapsed search button while
    /// the window is narrower than the expansion threshold. Reset when the
    /// query empties or editing ends empty, so a narrow window collapses the
    /// control back to the button (NSSearchToolbarItem behavior).
    @State private var searchExpandedByUser = false

    /// The selected job's two workspace surfaces. Activity is the only
    /// transcript surface (plan §1); Overview is the complete inventory +
    /// Run Details.
    enum QueueWorkspaceSurface: Hashable {
        case overview
        case activity
    }

    private var queueTitle: String {
        switch queue {
        case .extraction, .transcription: return "Extraction Queue"
        case .ingestion: return "Agent Queue"
        }
    }

    /// The toolbar/menu icon for this queue's window.
    private var queueControlIcon: String {
        switch queue {
        case .extraction, .transcription: return "doc.text.magnifyingglass"
        case .ingestion: return "tray.full"
        }
    }

    /// The "Configure…" call-to-action shown on configuration errors, or `nil`
    /// when this queue has no relevant Settings tab.
    private var configureCTA: (tab: String, label: String)? {
        switch queue {
        case .extraction, .transcription:
            return (tab: "extraction", label: "Configure Extraction…")
        case .ingestion:
            return (tab: "agents", label: "Configure Agents…")
        }
    }

    /// Strict window-scope filter: the Agent Queue (`.ingestion`) lists only
    /// ingestion and lint jobs; the Extraction Queue lists only extraction
    /// jobs. The item's own `queue` is the single authority — an extraction
    /// job never leaks into the Agent list (or vice versa) even though one
    /// snapshot serves both windows. PURE + `nonisolated` (same reason as
    /// ``isConfigurationErrorMarker``): the integration tests assert it from
    /// nonisolated `#expect` contexts without a main-actor hop.
    nonisolated static func windowContains(_ item: QueueItem, queue: QueueKind) -> Bool {
        item.queue == queue
    }

    private var activeItems: [QueueItem] {
        viewModel.snapshot.activeItems.filter { Self.windowContains($0, queue: queue) }
    }

    private var recentItems: [QueueItem] {
        viewModel.snapshot.recentItems.filter { Self.windowContains($0, queue: queue) }
    }

    /// Everything the navigator displays: active jobs plus the bounded recent
    /// history (the existing 200-item display limit).
    private var displayedItems: [QueueItem] {
        Array(activeItems + recentItems.prefix(200))
    }

    private var displayedItemIDs: [QueueItem.ID] {
        displayedItems.map(\.id)
    }

    /// `.task` identity for the batched summary load: the displayed item set.
    /// New or replaced items trigger a refresh; cached items are skipped by
    /// the tracker so repeated keys only pay for what changed.
    private var displayedItemSummariesKey: String {
        displayedItemIDs.map(\.rawValue).joined(separator: ",")
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: QueueWorkspaceMetrics.Navigator.minWidth,
                    ideal: QueueWorkspaceMetrics.Navigator.idealWidth,
                    max: QueueWorkspaceMetrics.Navigator.maxWidth)
        } detail: {
            detailPane
        }
        // Measure the split view's width for the toolbar search's
        // expand/collapse decision (design change 6). Same pattern as the
        // main window's detail-width measurement: measuring at the split-view
        // root is reliable in every state the toolbar item's own frame is
        // not, and the write lands through the layout-driven @State update,
        // not a view-update-pass write.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { splitViewWidth = $0 }
        .frame(
            minWidth: QueueWorkspaceMetrics.Window.minWidth,
            minHeight: QueueWorkspaceMetrics.Window.minHeight)
        .navigationTitle(queueTitle)
        .navigationSubtitle(subtitle)
        .confirmationDialog(
            Self.stopAllConfirmationTitle(for: queueTitle),
            isPresented: $confirmsStopAll) {
            Button(Self.stopAllButtonLabel, role: .destructive) {
                runQueueCommand("stop queue") { try await queueEngine.halt(queue) }
            }
        } message: {
            Text(Self.stopAllConfirmationMessage)
        }
        .toolbar {
            // Design change 6 (2026-09-09): the job search is an explicit
            // toolbar item declared FIRST. `.searchable` rendered the field
            // on the Queue Actions menu's right, with no width
            // responsiveness; this control collapses to a magnifying-glass
            // button in narrow windows instead.
            //
            // Design change 7 (2026-09-09): the main window's toolbar
            // geometry (ContentView) — a leading search control, a flexible
            // spacer that eats the middle, and an icon-only control group
            // pinned to the trailing edge. Everything after
            // `ToolbarSpacer(.flexible)` forms the right-aligned section, so
            // Queue Actions and Run Details always show on the right. The
            // icons keep the group compact enough to stay out of the »
            // overflow at the 640×400 minimum — this window keeps its
            // navigationTitle/subtitle (they identify Agent Queue vs
            // Extraction Queue), so unlike the main window it cannot also
            // reclaim the title slot; small controls are the whole budget.
            ToolbarItem(placement: .primaryAction) {
                queueSearchControl
            }
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .automatic) {
                queueControlMenu
                runDetailsInspectorToggle
            }
        }
        // #835: pin the unified window-toolbar background so SwiftUI reserves
        // the toolbar region (non-floating) and insets the sidebar content below
        // it. With the default `.automatic` background (transparent when idle)
        // the sidebar List gets no top safe-area inset, so the first rows render
        // up under the red/yellow/green traffic-light buttons. `.listStyle(
        // .sidebar)` above only sets the sidebar appearance; the toolbar must be
        // visibly established for the inset to apply (the main wiki window gets
        // this implicitly via its `.navigation` + `.principal` toolbar items).
        .toolbarBackground(.visible, for: .windowToolbar)
        .onAppear {
            viewModel.attach(engine: queueEngine)
            consumePendingSelectionIfNeeded()
        }
        .onDisappear { viewModel.detach() }
        // Design change 6: once the query empties — by Escape, the field's
        // native clear button, Clear Filters, or any other reset — the
        // explicit expansion request is spent, so a narrow window collapses
        // the control back to the magnifying-glass button. A wide window
        // stays expanded via the width branch regardless. (Editing that
        // ends on an ALREADY-empty field — expanded, then abandoned without
        // typing, so the query never changes — is the delegate's
        // `controlTextDidEndEditing` seam inside the search control; this
        // observer covers every path that changes the query.)
        .onChange(of: jobFilter.search) { _, newSearch in
            if newSearch.isEmpty { searchExpandedByUser = false }
        }
        // #837: when a specific item selection is requested from outside the
        // Activity window (e.g. PageDetailView's "View Lint" button), consume
        // it immediately so an already-open window switches selection without
        // needing an onAppear (which only fires once per window lifecycle).
        .onChange(of: activityTracker.pendingSelectionItemID) { _, _ in
            consumePendingSelectionIfNeeded()
        }
        // Plan §1: "Every new selection opens Overview." A deep link, an
        // auto-select, or a user click all land here.
        .onChange(of: selectedItemID) { _, _ in
            workspaceSurface = .overview
        }
        // Auto-select the most interesting item once, when the first snapshot
        // lands — a window opened from "1 running" should show that run.
        // Also a safety net for #837: if the pending selection was consumed
        // in onAppear before the snapshot arrived, the item is already
        // selected; autoSelectIfNeeded is a no-op when selectedItemID != nil.
        .onChange(of: activeItems.map(\.id)) { _, _ in
            autoSelectIfNeeded()
        }
        .onChange(of: recentItems.map(\.id)) { _, _ in
            autoSelectIfNeeded()
        }
        // Summaries load asynchronously after attach (plan §"How summaries
        // load"): lifecycle-only rows render immediately, and this batched
        // load fills row progress + report-backed search when the engine
        // answers. Re-runs when the displayed set changes.
        .task(id: displayedItemSummariesKey) {
            await activityTracker.refreshReportSummaries(itemIDs: displayedItemIDs)
        }
        // Closed-wiki name resolution: for the displayed jobs whose wiki is
        // closed, resolve the target IDs that neither the live index (no
        // session) nor the payload's recorded names (legacy jobs) can
        // answer through a bounded read-only read of that wiki's database,
        // cached per wiki in the tracker. Re-runs when the displayed set's
        // (wiki, targets) composition changes AND when the open-wiki set
        // changes (review F2): closing a wiki's window moves its targets
        // from "the live session answers" to "the read-only load must run",
        // so the key must change even when the displayed set does not.
        .task(id: closedWikiNamesKey) {
            await activityTracker.refreshClosedWikiNames(
                for: displayedItems,
                sessions: sessionManager?.sessions ?? [:],
                databaseURL: closedWikiDatabaseURLProvider)
        }
    }

    /// `.task` identity for the closed-wiki name loads: the displayed
    /// items' wiki + target-ID composition AND the open-wiki set. New or
    /// replaced jobs re-trigger; unrelated queue churn does not — and a
    /// wiki window closing (or opening) changes the key even when the
    /// displayed set is unchanged, because it flips which layer answers
    /// the rows. Without the session set in the identity, a window closing
    /// never re-ran this task and its rows stayed "Resolving…" forever.
    private var closedWikiNamesKey: String {
        Self.closedWikiNamesKey(
            for: displayedItems,
            openWikiIDs: Set((sessionManager?.sessions ?? [:]).keys))
    }

    /// Pure `.task`-identity computation (value-level suite seam): the
    /// displayed items' `(wiki, targets)` composition prefixed by the
    /// sorted open-wiki ID set.
    nonisolated static func closedWikiNamesKey(
        for items: [QueueItem],
        openWikiIDs: Set<WikiID>
    ) -> String {
        let openWikiPart = openWikiIDs.map(\.rawValue).sorted().joined(separator: ",")
        let targetsPart = items.map { item -> String in
            let targets = item.payload.lintPageIDs?.map(\.rawValue)
                ?? item.payload.sourceIDs.map(\.rawValue)
            return "\(item.wikiID.rawValue)=\(targets.joined(separator: "+"))"
        }
        .joined(separator: "|")
        return "\(openWikiPart)#\(targetsPart)"
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

    /// Consume a pending item selection requested from outside the Activity
    /// window (#837, #842 PR2 C4). Set on `activityTracker.pendingSelectionItemID`
    /// (and `pendingSelectionQueue`) before the window-opening closure fires;
    /// read here and cleared. The `pendingSelectionQueue` guard ensures the
    /// item belongs to THIS window's queue — prevents a cross-window race when
    /// both `.transcription` and `.ingestion` windows exist (a lint pending-
    /// selection must not be consumed by the transcription window, and vice
    /// versa). Overrides the current selection — the user explicitly asked to
    /// see this item. Marks `didAutoSelect` so `autoSelectIfNeeded` won't
    /// override it back when the first snapshot lands.
    private func consumePendingSelectionIfNeeded() {
        guard let pending = activityTracker.pendingSelectionItemID else { return }
        // C4: verify the pending item belongs to this window's queue. When
        // the guard is nil (backward-compat), skip the check.
        if let guardQueue = activityTracker.pendingSelectionQueue,
           guardQueue != queue {
            return
        }
        activityTracker.pendingSelectionItemID = nil
        activityTracker.pendingSelectionQueue = nil
        jobFilter = QueueJobFilter()
        selectedItemID = pending
        didAutoSelect = true
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
        guard jobFilter.allowsReordering,
              let movedIndex = sources.first,
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

        runQueueCommand("reorder item") {
            try await queueEngine.reorderItem(id: movedItem.id, beforeItemID: beforeItemID)
        }
    }

    private func runQueueCommand(
        _ name: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isCommandPending else { return }
        isCommandPending = true
        commandError = nil
        Task { @MainActor in
            defer { isCommandPending = false }
            do {
                try await operation()
            } catch {
                commandError = "Could not \(name): \(error.localizedDescription)"
                DebugLog.store("ActivityWindow: \(name) failed: \(error)")
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        let allActive = activeItems
        let allRecent = Array(recentItems.prefix(200))
        // One read of the summary-state dictionary per sidebar render — the
        // footer and the search label read it, the rows read merged summaries.
        let summaryStates = activityTracker.reportSummaryStates
        let data = buildRowDisplayData(for: allActive + allRecent)
        let matches: (QueueItem) -> Bool = { item in
            jobFilter.includes(
                item, searchText: navigatorSearchText(item: item, row: data[item.id]))
        }
        let active = allActive.filter(matches)
        let recent = allRecent.filter(matches)
        // Precompute all @Observable-derived display data ONCE, so the
        // ForEach row body reads only plain values. This eliminates the
        // per-row swift_task_isMainExecutorImpl isolation checks that
        // triggered a use-after-free crash (EXC_BAD_ACCESS in
        // swift_getObjectType during ObservationCenter._withObservation)
        // when observable state changed concurrently with row evaluation —
        // e.g. cancelling a lint job. See swiftlang/swift#89197.
        let displayData = data

        VStack(spacing: 0) {
            jobFilterMenu
            if allActive.isEmpty && allRecent.isEmpty {
                emptyState
            } else if active.isEmpty && recent.isEmpty {
                ContentUnavailableView.search(text: jobFilter.search)
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
                        // L1/plan: reordering is DISABLED (not just
                        // neutralized) while filters or search are active —
                        // a drop target computed against a filtered list
                        // would reorder against the wrong neighbors. The
                        // footer carries the visible explanation
                        // ("Clear filters to reorder queued jobs.").
                        .moveDisabled(!jobFilter.allowsReordering)
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
            Text(navigatorFooter(summaryStates: summaryStates))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    /// The navigator footer: scope truth plus the summary-load labels (plan:
    /// "While loading, result search is labeled incomplete"; on failure
    /// "report-backed search is labeled unavailable" — never an error banner).
    private func navigatorFooter(
        summaryStates: [QueueItem.ID: QueueActivityTracker.ReportSummaryState]
    ) -> String {
        let displayed = displayedItemIDs
        guard !displayed.isEmpty else {
            return jobFilter.isActive ? "Clear filters to reorder queued jobs." : "Active jobs and up to 200 recent jobs"
        }
        let states = displayed.map { summaryStates[$0] ?? .loading }
        if states.contains(.loading) {
            return "Loading job summaries — result search is incomplete."
        }
        if states.contains(.unavailable) {
            return "Report-backed search is unavailable for some jobs."
        }
        return jobFilter.isActive ? "Clear filters to reorder queued jobs." : "Active jobs and up to 200 recent jobs"
    }

    /// The navigator's search haystack for one item: its precomputed row
    /// title, wiki name, and target names, the kind label, the item error,
    /// and the summary's recorded search text (report-backed search — while
    /// the batch summary load is in flight that field is empty and the footer
    /// labels the search incomplete). One implementation shared by the
    /// sidebar's filter pass and the outside-filter notice decision so the
    /// navigator and the notice can never disagree. PURE + `nonisolated`
    /// (same reason as ``isConfigurationErrorMarker``): the value-level
    /// suite pins the exact composition without a main-actor hop.
    nonisolated static func navigatorSearchText(
        item: QueueItem,
        kindLabel: String,
        rowTitle: String?,
        wikiName: String?,
        targetNames: [String],
        summarySearchText: String?
    ) -> String {
        [rowTitle ?? "", wikiName ?? "", kindLabel,
         targetNames.joined(separator: " "), item.error ?? "",
         summarySearchText ?? ""].joined(separator: " ")
    }

    /// Instance convenience over the pure haystack: feeds it the item's
    /// kind label and its precomputed row display data.
    private func navigatorSearchText(item: QueueItem, row: RowDisplayData?) -> String {
        Self.navigatorSearchText(
            item: item,
            kindLabel: Self.kindLabel(for: item),
            rowTitle: row?.title,
            wikiName: row?.wikiName,
            targetNames: row?.targetNames ?? [],
            summarySearchText: row?.summarySearchText)
    }

    /// Whether `filter`/search hides `item` from the navigator (plan
    /// §"Selection, filters, and deep links"). `false` when no filter is
    /// active. This decision is the outside-filter notice's show condition,
    /// computed over the same haystack the navigator rows match against.
    /// PURE + `nonisolated` so the value-level suite asserts it directly.
    nonisolated static func isHiddenByFilter(
        _ item: QueueItem,
        filter: QueueJobFilter,
        rowTitle: String?,
        wikiName: String?,
        targetNames: [String],
        summarySearchText: String?
    ) -> Bool {
        guard filter.isActive else { return false }
        return !filter.includes(
            item,
            searchText: navigatorSearchText(
                item: item,
                kindLabel: kindLabel(for: item),
                rowTitle: rowTitle,
                wikiName: wikiName,
                targetNames: targetNames,
                summarySearchText: summarySearchText))
    }

    /// Whether the current filter/search hides `item` from the navigator.
    /// Delegates to the pure decision with this window's filter and the
    /// item's precomputed row data (plan §"Selection, filters, and deep
    /// links"). Drives the workspace's outside-filter notice.
    private func isHiddenByFilter(_ item: QueueItem) -> Bool {
        guard jobFilter.isActive else { return false }
        let row = buildRowDisplayData(for: [item])[item.id]
        return Self.isHiddenByFilter(
            item,
            filter: jobFilter,
            rowTitle: row?.title,
            wikiName: row?.wikiName,
            targetNames: row?.targetNames ?? [],
            summarySearchText: row?.summarySearchText)
    }

    /// Plan §"Selection, filters, and deep links": when filters hide the
    /// selected job, its workspace stays, topped by a short notice with a
    /// Clear Filters action. Quiet by design — the workspace below is the
    /// content; the notice only explains why the navigator looks empty.
    /// Copy lives in these named constants (in this extension) so the
    /// value-level suite pins the exact strings.
    private var filteredSelectionNotice: some View {
        HStack(spacing: QueueWorkspaceMetrics.Spacing.xs) {
            Label(Self.filteredSelectionNoticeText, systemImage: "line.3.horizontal.decrease")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: QueueWorkspaceMetrics.Spacing.xs)
            Button(Self.clearFiltersButtonLabel) {
                jobFilter = QueueJobFilter()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Show this job in the navigator again")
        }
        .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
        .padding(.vertical, QueueWorkspaceMetrics.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.filteredSelectionNoticeText)
    }

    private var jobFilterMenu: some View {
        HStack {
            Text(jobFilter.isActive ? "Filtered Jobs" : "All Jobs")
                .font(.headline)
            Spacer()
            Menu("Filter", systemImage: "line.3.horizontal.decrease") {
                Picker("State", selection: $jobFilter.state) {
                    Text("All States").tag(QueueItemState?.none)
                    ForEach([QueueItemState.queued, .running, .completed, .failed, .cancelled], id: \.self) { state in
                        Text(state.rawValue.capitalized).tag(Optional(state))
                    }
                }
                Picker("Wiki", selection: $jobFilter.wikiID) {
                    Text("All Wikis").tag(WikiID?.none)
                    ForEach(Array(Set((activeItems + recentItems).map(\.wikiID))).sorted { $0.rawValue < $1.rawValue }, id: \.self) { wikiID in
                        Text(wikiDisplayName(for: wikiID)).tag(Optional(wikiID))
                    }
                }
                if queue == .ingestion {
                    Picker("Operation", selection: $jobFilter.operation) {
                        Text("All Operations").tag(QueueJobFilter.Operation?.none)
                        Text("Ingestion").tag(Optional(QueueJobFilter.Operation.ingestion))
                        Text("Lint").tag(Optional(QueueJobFilter.Operation.lint))
                    }
                }
                if jobFilter.isActive {
                    Divider()
                    Button("Clear Filters") { jobFilter = QueueJobFilter() }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
    }

    private var emptyState: some View {
        let description: String
        switch queue {
        case .extraction, .transcription:
            description = "PDF extraction and transcription tasks appear here as they run."
        case .ingestion:
            description = "Ingestion and lint tasks appear here as they run."
        }
        return ContentUnavailableView {
            Label("No \(queueTitle) Activity", systemImage: "checkmark.circle")
        } description: {
            Text(description)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: QueueItem, displayData: RowDisplayData?) -> some View {
        let data = displayData ?? RowDisplayData(
            title: Self.kindLabel(for: item),
            jobID: item.id,
            relativeTime: nil,
            wikiName: String(item.wikiID.rawValue.prefix(8)),
            targetNames: [],
            usage: nil,
            liveUsage: nil,
            pendingPermission: nil,
            summarySearchText: "",
            progressLine: nil)
        HStack(spacing: 8) {
            statusView(for: item)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(data.title)
                    .lineLimit(1)
                    .help(data.targetNames.joined(separator: "\n"))
                // Lead with the strongly typed queue-item ID. Running rows
                // update their elapsed suffix inside a per-second TimelineView;
                // terminal and queued rows use the precomputed relative time.
                if item.state == .running, item.startedAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        rowMetadata(
                            jobID: data.jobID,
                            suffix: "running · \(elapsedString(item.startedAt, now: context.date))")
                    }
                } else {
                    rowMetadata(jobID: data.jobID, suffix: data.relativeTime)
                }
                // Report-backed phase progress on running rows ("Staging
                // sources · 8 of 12"), from the item's cached summary —
                // precomputed above so the row body reads plain values only.
                // Plan truth rule 5: only a known total with an observed
                // numerator produces this line; unknown counts stay absent.
                if let progressLine = data.progressLine {
                    Text(progressLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
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
                // updates even between usage_updates. Extraction rows show
                // their ticking elapsed in the subtitle above instead.
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
                // Typed transcript updates + live usage flow into the row — the tracker's
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

    /// The sidebar metadata line. Keep the queue ID typed until this rendering
    /// boundary, where its raw ULID is displayed beside optional timing text.
    private func rowMetadata(jobID: QueueItem.ID, suffix: String?) -> some View {
        Text(Self.rowMetadataText(jobID: jobID, suffix: suffix))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(jobID.rawValue)
    }

    /// Pure formatting seam for sidebar metadata. The typed parameter prevents
    /// a WikiID, PageID, or SourceID from being substituted for the job ID.
    nonisolated static func rowMetadataText(jobID: QueueItem.ID, suffix: String?) -> String {
        guard let suffix else { return jobID.rawValue }
        return "\(jobID.rawValue) · \(suffix)"
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
    /// failed. Borderless so rows stay quiet until needed. Icon-only, so
    /// each carries an explicit accessibility label — the icon alone says
    /// nothing to VoiceOver.
    @ViewBuilder
    private func rowAction(for item: QueueItem) -> some View {
        switch item.state {
        case .running, .queued:
            Button {
                runQueueCommand("cancel item") { try await queueEngine.cancelItem(item.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel job")
            .help("Cancel")
        case .failed:
            Button {
                retry(item: item)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Retry job")
            .help("Retry")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func contextMenu(for item: QueueItem) -> some View {
        // The job ID stays strongly typed until this pasteboard boundary.
        Button("Copy Job ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.id.rawValue, forType: .string)
        }
        // #598: extraction jobs carry sourceIDs — offer a "Reveal Source"
        // action that navigates to the source in the wiki's Sources outline,
        // mirroring #583's "Open Page" for lint jobs. Only shown for
        // extraction jobs with at least one source ID in the payload.
        if item.queue == .extraction, let sourceID = item.payload.sourceIDs.first {
            Divider()
            Button("Reveal Source", systemImage: "arrow.up.forward.app") {
                revealSource(
                    sourceID,
                    title: makeNameIndex(for: item).sourceName(sourceID),
                    in: item.wikiID)
            }
            .help("Reveal this source in the wiki's Sources outline")
        }
        let debugURL = activityTracker.debugURL(for: item.id)
        if let debugURL {
            Divider()
            Button("Reveal Debug Folder", systemImage: "folder.badge.gearshape") {
                NSWorkspace.shared.activateFileViewerSelecting([debugURL])
            }
        }
        switch item.state {
        case .running, .queued:
            Button("Cancel") {
                runQueueCommand("cancel item") { try await queueEngine.cancelItem(item.id) }
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

    /// The toolbar job-search control (design change 6, 2026-09-09), declared
    /// LEFT of the Queue Actions menu in the toolbar. Wide windows (or an
    /// active query, or an explicit expansion request) show the expanded
    /// `NSSearchField`; narrow empty windows show the magnifying-glass
    /// button. One persistent AppKit control hosts both forms (see
    /// ``QueueSearchToolbarControl``) — only visibility and width flip. The
    /// query binding is the same `jobFilter` the navigator filter, the
    /// outside-filter notice, and the reorder guards read — the control is
    /// presentation only. Expansion ends two ways: the query empties (the
    /// `.onChange` reset below) or editing ends on an already-empty field
    /// (the control's `onEditEndedEmpty`), either of which collapses a
    /// narrow window back to the button.
    private var queueSearchControl: some View {
        let expanded = QueueSearchToolbarForm.decision(
            splitViewWidth: splitViewWidth,
            queryIsEmpty: jobFilter.search.isEmpty,
            userRequestedExpansion: searchExpandedByUser) == .expandedField
        return QueueSearchToolbarControl(
            text: $jobFilter.search,
            isExpanded: expanded,
            onExpandRequested: { searchExpandedByUser = true },
            // Only the click-requested expansion may take keyboard focus;
            // a width-driven flip (window resize) never does.
            focusOnExpand: searchExpandedByUser,
            onEditEndedEmpty: { searchExpandedByUser = false },
            prompt: Self.searchPrompt)
            .frame(width: expanded
                ? QueueWorkspaceMetrics.Search.expandedFieldWidth
                : QueueWorkspaceMetrics.Search.collapsedButtonSide)
    }

    /// This queue's controls as one toolbar menu — global queue
    /// controls belong in the top bar, not buried in list section headers
    /// (and Pause Queue is not a separate top-level button). Pause/Resume
    /// and Stop All… live inside "Queue Actions", each section headed by
    /// concise native menu guidance so the two pausing verbs stay distinct:
    /// Pause stops new starts and lets running jobs finish; Stop All also
    /// cancels running jobs (queued jobs remain, restated by the explicit
    /// destructive confirmation).
    ///
    /// Design change 7 (2026-09-09): the button renders icon-only — the
    /// main window's toolbar idiom. The visible title is gone, but the
    /// identity stays: the title still names the toolbar item for the
    /// customization palette, `.help` shows "Queue Actions" on hover, and
    /// the accessibility label remains "Queue Actions" for VoiceOver.
    @ViewBuilder
    private var queueControlMenu: some View {
        let state = viewModel.snapshot.runStates[queue] ?? .running
        Menu("Queue Actions", systemImage: "ellipsis.circle") {
            Section {
                if state == .running {
                    Button("Pause Queue", systemImage: "pause.fill") {
                        runQueueCommand("pause queue") { try await queueEngine.pause(queue) }
                    }
                    .help("Stop new starts. Running jobs continue.")
                } else {
                    Button("Resume Queue", systemImage: "play.fill") {
                        runQueueCommand("resume queue") { try await queueEngine.resume(queue) }
                    }
                }
            } header: {
                Text(state == .running
                     ? "Pause Queue — do not start new jobs, let running jobs finish"
                     : "Resume Queue — allow queued jobs to start")
            }
            Section {
                Button("Stop All…", systemImage: "stop.fill", role: .destructive) {
                    confirmsStopAll = true
                }
            } header: {
                Text("Stop All — pause queue and cancel running jobs, queued jobs remain")
            }
        }
        .labelStyle(.iconOnly)
        .help("Queue Actions")
        .accessibilityLabel("Queue Actions")
        .disabled(isCommandPending)
    }

    /// The toolbar control that opens/closes the optional Run Details
    /// inspector — a plain SwiftUI toolbar `Button` mirroring the main
    /// window's inspector toggle (ContentView): the bare "sidebar.right"
    /// system image, `.help` tooltip, no visible title. Design change 12
    /// (2026-09-10, icon parity): this replaces the former
    /// `RunDetailsToolbarToggle` NSViewRepresentable. The state seam is
    /// unchanged — the button action toggles the same
    /// `showsRunDetailsInspector` @State (a user event, never a view-update
    /// write), the tooltip text flips with it ("Show Run Details" / "Hide
    /// Run Details"), and the accessibility label stays "Run Details" for
    /// VoiceOver. Toggling touches only panel presentation: selection,
    /// filters, and queue state are untouched.
    ///
    /// Geometry parity is enforced, not assumed: measured in the hosted
    /// window, this window's bridged toolbar `Button` collapses to the bare
    /// glyph footprint (23.5×18.5) — the main taskbar's standard toolbar
    /// icon button is the ``QueueWorkspaceMetrics/Toolbar/iconButtonSide``
    /// square — so the image carries the shared square as its frame and the
    /// bridged control measures 28×28 like the main window's.
    ///
    /// Palette-label loss (documented like the toolbar search item): a
    /// SwiftUI `Button` labeled with only an `Image` has no title for
    /// SwiftUI to lift into the `NSToolbarItem` label, so the customization
    /// palette shows this item unlabeled (verified in the hosted harness:
    /// `item.label == ""`). The in-window tooltip and the "Run Details"
    /// accessibility label carry the identity.
    private var runDetailsInspectorToggle: some View {
        Button {
            showsRunDetailsInspector.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .frame(width: QueueWorkspaceMetrics.Toolbar.iconButtonSide,
                       height: QueueWorkspaceMetrics.Toolbar.iconButtonSide)
                .contentShape(Rectangle())
        }
        .help(showsRunDetailsInspector ? "Hide Run Details" : "Show Run Details")
        .accessibilityLabel("Run Details")
    }

    // MARK: - Detail pane

    /// The detail column: the selected job's workspace plus the OPTIONAL Run
    /// Details inspector as a conditional trailing region — never a
    /// permanently visible third split-view column. The inspector exists in
    /// the tree only while open; closing it removes the region and changes
    /// nothing else (selection, filters, and queue state are untouched).
    private var detailPane: some View {
        HStack(spacing: 0) {
            workspaceDetailPane
            if showsRunDetailsInspector {
                Divider()
                QueueRunDetailsView(selectedRunDetailsFacts)
                    .frame(width: QueueWorkspaceMetrics.Inspector.width)
            }
        }
    }

    /// The selected job's Run Details facts for the inspector panel —
    /// item timestamps + the report header's provider/model + recorded
    /// usage, fed from the loaded durable report when it matches this
    /// selection and attempt.
    private var selectedRunDetailsFacts: QueueRunDetailsFacts? {
        guard let itemID = selectedItemID, let item = item(for: itemID) else {
            return nil
        }
        var report: QueueAttemptReport?
        if case .loaded(let loaded) = viewModel.selectedReport,
           Self.loadedReportMatches(report: loaded, item: item) {
            report = loaded
        }
        return runDetailsFacts(for: item, report: report)
    }

    /// The selected job's workspace (plan §1 "Selected job workspace"): the
    /// responsive header, the Overview/Activity selector, then the two
    /// surfaces. Both surfaces stay mounted — the Overview keeps its local
    /// search state and the Activity transcript keeps its scroll
    /// position and streaming data across selector toggles.
    @ViewBuilder
    private var workspaceDetailPane: some View {
        if let itemID = selectedItemID, let item = item(for: itemID) {
            VStack(spacing: 0) {
                // M3/plan: filters that hide the selected job keep the
                // workspace (never another job's content) and explain
                // themselves with a Clear Filters action.
                if isHiddenByFilter(item) {
                    filteredSelectionNotice
                    Divider()
                }
                QueueJobHeaderView(
                    headerPresentation(for: item),
                    onCancel: { cancel(item: item) },
                    onRetry: { retry(item: item) },
                    configure: configureAction,
                    additionalActions: additionalHeaderActions(for: item))
                Divider()
                surfaceSelector
                Divider()
                workspaceContent(for: item)
            }
            .task(id: itemID) {
                // Prevent the previous selection's durable rows from briefly
                // merging into this item's live transcript while its load is
                // in flight.
                loadedTranscriptItems = []
                do {
                    loadedTranscriptItems = try await queueEngine.loadTranscript(for: itemID)
                } catch {
                    DebugLog.store("ActivityWindow: load transcript failed: \(error)")
                }
            }
            .task(id: reportLoadKey(for: item)) {
                // Load the selected job's durable report for the Overview.
                // Keyed on attempt + lifecycle state + the item's cached
                // summary revision, so the Overview tracks committed report
                // updates (plan: reload on terminal transitions; revisions
                // arrive as `.reportUpdated` events → summary cache → here).
                // The view model guards against stale selection writes.
                await viewModel.loadReport(
                    for: item.id,
                    attempt: item.attempt)
            }
        } else if activeItems.isEmpty && recentItems.isEmpty {
            emptyState
        } else if selectedItemID != nil {
            // A selection that left loaded history (pruned): an explicit
            // unavailable state — never another job's content (plan §
            // "Selection, filters, and deep links").
            ContentUnavailableView {
                Label("Job Unavailable", systemImage: "tray")
            } description: {
                Text("This job is no longer in the loaded history.")
            }
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "sidebar.left")
            } description: {
                Text("Select an item to view its workspace.")
            }
        }
    }

    /// Overview ↔ Activity selector (plan §1 layout order: errors, selector,
    /// then the selected surface).
    private var surfaceSelector: some View {
        HStack(spacing: 0) {
            Picker("Workspace Surface", selection: $workspaceSurface) {
                Text("Overview").tag(QueueWorkspaceSurface.overview)
                Text("Activity").tag(QueueWorkspaceSurface.activity)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
        .padding(.vertical, QueueWorkspaceMetrics.Spacing.xs)
    }

    /// Both workspace surfaces, kept mounted so toggling the selector never
    /// drops streaming transcript data or scroll positions (plan §1). The
    /// hidden surface stops hit-testing; a hosted WKWebView that merely fades
    /// out keeps its session alive, which is exactly the fidelity the plan
    /// asks for.
    @ViewBuilder
    private func workspaceContent(for item: QueueItem) -> some View {
        ZStack {
            QueueJobOverviewView(overviewPresentation(for: item))
                .opacity(workspaceSurface == .overview ? 1 : 0)
                .allowsHitTesting(workspaceSurface == .overview)
                .accessibilityHidden(workspaceSurface != .overview)
            transcriptContent(for: item)
                .opacity(workspaceSurface == .activity ? 1 : 0)
                .allowsHitTesting(workspaceSurface == .activity)
                .accessibilityHidden(workspaceSurface != .activity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Per-job identity: a new selection resets the workspace surfaces'
        // local state (the Overview's inventory search) instead of leaking
        // the previous job's. Toggling the Overview/Activity selector never
        // changes this identity, so both surfaces stay mounted and switching
        // never drops streaming data or the transcript scroll position.
        .id(item.id)
    }

    /// Task identity for the selected report load: attempt + lifecycle state
    /// + the summary revision the tracker last saw for this item. A retry
    /// (attempt bump), a terminal transition, or a committed report update
    /// re-runs the load; identity changes that don't affect the report don't.
    private func reportLoadKey(for item: QueueItem) -> String {
        let revision = activityTracker.reportSummaries[item.id]?.revision.rawValue ?? -1
        return "\(item.id.rawValue)|\(item.attempt)|\(item.state.rawValue)|\(revision)"
    }

    /// The header's Configure… action for configuration failures (#440). The
    /// header view only shows it when `isConfigurationError` is set.
    private var configureAction: QueueWorkspaceAction? {
        guard openWindowBridge != nil, let cta = configureCTA else { return nil }
        return QueueWorkspaceAction(label: cta.label, systemImage: "gearshape") {
            openWindowBridge?.openSettings(tab: cta.tab)
        }
    }

    /// Quiet header icon actions: Reveal Source (extraction jobs, #598) and
    /// Reveal Debug Folder (runs that produced a debug trace). Per-target
    /// navigation lives in the Overview rows.
    private func additionalHeaderActions(for item: QueueItem) -> [QueueWorkspaceAction] {
        var actions: [QueueWorkspaceAction] = []
        if item.queue == .extraction, let sourceID = item.payload.sourceIDs.first {
            actions.append(QueueWorkspaceAction(
                label: "Reveal Source", systemImage: "arrow.up.forward.app") {
                revealSource(
                    sourceID,
                    title: makeNameIndex(for: item).sourceName(sourceID),
                    in: item.wikiID)
            })
        }
        if let debugURL = activityTracker.debugURL(for: item.id) {
            actions.append(QueueWorkspaceAction(
                label: "Reveal Debug Folder", systemImage: "folder.badge.gearshape") {
                NSWorkspace.shared.activateFileViewerSelecting([debugURL])
            })
        }
        return actions
    }

    /// Map the item + report data onto the header presentation. Derived from
    /// immutable inputs before body evaluation — plain values only.
    private func headerPresentation(for item: QueueItem) -> QueueJobHeaderPresentation {
        let startedAt = date(fromMillis: item.startedAt)
        let finishedAt = date(fromMillis: item.finishedAt)
        let isTerminal = item.state == .completed || item.state == .failed
            || item.state == .cancelled
        let errorText: String? = item.state == .failed ? item.error : nil
        return QueueJobHeaderPresentation(
            title: QueueWorkspaceMapper.headerTitle(
                operation: QueueWorkspaceMapper.reportOperation(for: item),
                jobTitle: Self.headerJobCountPhrase(
                    for: item,
                    wikiName: wikiDisplayName(for: item.wikiID))),
            operationLabel: QueueWorkspaceMapper.operationLabel(for: item),
            jobID: item.id,
            lifecycle: QueueWorkspaceMapper.lifecycle(for: item.state),
            progress: QueueWorkspaceMapper.headerProgress(
                from: activityTracker.reportSummary(for: item.id),
                operation: QueueWorkspaceMapper.reportOperation(for: item),
                payloadTargetCount: item.payload.lintPageIDs?.count
                    ?? item.payload.sourceIDs.count,
                jobLifecycle: QueueWorkspaceMapper.lifecycle(for: item.state)),
            startedAt: startedAt,
            durationText: isTerminal
                ? QueueWorkspaceFormat.duration(from: startedAt, to: finishedAt)
                : nil,
            errorText: errorText,
            isConfigurationError: errorText.map(isConfigurationError) ?? false,
            pendingPermissionText: activityTracker.pendingPermission(for: item.id)
                .map(Self.permissionPendingLabel(for:)),
            isCommandPending: isCommandPending)
    }

    // MARK: - Overview mapping

    /// Map the selected job's durable report — or its payload, when no report
    /// is recorded (legacy jobs, still loading) — onto the Overview
    /// presentation. Everything is derived here, before the list iterates the
    /// rows, so the inventory body reads plain values only.
    private func overviewPresentation(for item: QueueItem) -> QueueJobOverviewPresentation {
        let operation = QueueWorkspaceMapper.reportOperation(for: item)
        // M2: one index for the whole selected-job mapping — the report-backed
        // rows, the legacy rows, and their navigation actions all resolve
        // membership + names through it instead of re-scanning the store per
        // target. The index is the closed-wiki-aware effective index (live →
        // recorded → read-only), so closed-wiki jobs keep names AND actions.
        let nameIndex = makeNameIndex(for: item)
        // The action gate needs the LIVE index too (review F1): the effective
        // index's recorded/read-only entries can outlive their store rows, so
        // on an open wiki actions additionally require live-store membership.
        // Built once per selected-job mapping — same M2 one-pass discipline.
        let liveIndex = makeNameIndex(wikiID: item.wikiID)
        let isSessionOpen = (sessionManager?.sessions ?? [:])[item.wikiID] != nil
        if case .loaded(let report) = viewModel.selectedReport,
           Self.loadedReportMatches(report: report, item: item) {
            return overview(
                from: report, item: item, operation: operation, nameIndex: nameIndex,
                liveIndex: liveIndex, isSessionOpen: isSessionOpen)
        }
        let outputState: QueueOutputsLoadState
        switch viewModel.selectedReport {
        case .idle, .loading:
            outputState = .loading
        case .unavailable:
            outputState = .unavailable
        case .notReported, .loaded:
            outputState = .notRecorded
        }
        return legacyOverview(
            for: item, operation: operation, outputState: outputState,
            nameIndex: nameIndex, liveIndex: liveIndex, isSessionOpen: isSessionOpen)
    }

    /// True when the view model's loaded report describes THIS selection:
    /// same item AND same attempt. A retry bumps the item's attempt while the
    /// cached report still describes the previous attempt (the reload is
    /// async, keyed on `reportLoadKey`); rendering it would show the old
    /// attempt's inventory until the reload lands, so the attempt must match
    /// before the report-backed presentation is used.
    static func loadedReportMatches(report: QueueAttemptReport, item: QueueItem) -> Bool {
        report.attemptID.itemID == item.id && report.attemptID.attempt == item.attempt
    }

    /// Report-backed Overview: the recorded inventory in payload order, the
    /// availability-aware result statement, and Run Details from the report
    /// header + item timestamps.
    private func overview(
        from report: QueueAttemptReport,
        item: QueueItem,
        operation: QueueReportOperation,
        nameIndex: QueueTargetNameIndex,
        liveIndex: QueueTargetNameIndex,
        isSessionOpen: Bool
    ) -> QueueJobOverviewPresentation {
        let isWholeWiki: Bool = {
            if case .wholeWiki = report.scope { return true }
            return false
        }()
        let rows: [QueueTargetRowValue]
        switch report.scope {
        case .wholeWiki:
            rows = [wholeWikiScopeRow(for: item)]
        case .targets(let records):
            rows = records.map {
                targetRow(
                    record: $0, item: item, nameIndex: nameIndex,
                    liveIndex: liveIndex, isSessionOpen: isSessionOpen)
            }
        }
        return QueueJobOverviewPresentation(
            sectionTitle: QueueWorkspaceMapper.sectionTitle(
                for: operation, isWholeWiki: isWholeWiki),
            // Known counts only: an empty recorded inventory shows the empty
            // state, never a fabricated "0".
            countText: report.targets.isEmpty ? nil : String(report.targets.count),
            rows: rows,
            resultStatement: Self.resultStatement(for: report),
            emptyStateText: emptyStateText(for: operation, isWholeWiki: isWholeWiki),
            outputs: outputsSectionValue(
                for: item,
                operation: operation,
                state: report.outputs.map(QueueOutputsLoadState.loaded) ?? .notRecorded,
                nameIndex: nameIndex))
    }

    /// One recorded target → one inventory row. Titles use the FULL name
    /// precedence: the effective index (live → payload recordedNames →
    /// read-only cache) first — it carries the enqueue-time name and keeps
    /// resolving after later renames or a closed wiki — then the report
    /// record's own displayName when the index cannot answer (a report
    /// recorded after a rename may know a name the payload never did), and
    /// the honest fallback text only when neither can. The record's
    /// displayName therefore only wins when the effective index MISSES, and
    /// an empty record displayName can never mask a resolvable name.
    private func targetRow(
        record: QueueReportTargetRecord,
        item: QueueItem,
        nameIndex: QueueTargetNameIndex,
        liveIndex: QueueTargetNameIndex,
        isSessionOpen: Bool
    ) -> QueueTargetRowValue {
        let identity: QueueWorkspaceTargetIdentity
        switch record.target {
        case .source(let id):
            identity = .source(id)
        case .page(let id):
            identity = .page(id)
        }
        return QueueTargetRowValue(
            identity: identity,
            title: Self.targetRowTitle(record: record, nameIndex: nameIndex),
            status: QueueWorkspaceMapper.targetStatus(
                for: record.state, result: record.result),
            reason: QueueWorkspaceMapper.targetReason(for: record),
            actions: rowActions(
                for: identity, wikiID: item.wikiID, nameIndex: nameIndex,
                liveIndex: liveIndex, isSessionOpen: isSessionOpen))
    }

    /// Pure computation of one recorded target row's title (value-level
    /// suite seam, same pattern as ``targetRowActions``). FULL name
    /// precedence: the effective index (live → payload recordedNames →
    /// read-only cache) first; the report record's own displayName only
    /// when the index cannot answer and its name is non-empty; the honest
    /// fallback text last. An empty record displayName is absence — it can
    /// never mask a name another layer resolves.
    nonisolated static func targetRowTitle(
        record: QueueReportTargetRecord,
        nameIndex: QueueTargetNameIndex
    ) -> String {
        let recordedName: String? = record.displayName.isEmpty ? nil : record.displayName
        switch record.target {
        case .source(let id):
            return nameIndex.sourceName(id) ?? recordedName ?? "Source unavailable"
        case .page(let id):
            return nameIndex.pageTitle(id) ?? recordedName ?? "Page unavailable"
        }
    }

    /// Legacy / loading Overview: rows derived from the item's payload. Jobs
    /// recorded before reports exist show truthful unavailable states and
    /// keep their payload-derived navigation (Open Page / Reveal Source /
    /// whole-wiki Browse Pages). Titles resolve through the effective index
    /// (live → recorded → read-only); an ID nothing resolves shows the
    /// neutral resolving placeholder while the wiki's closed-wiki read is
    /// pending, and the honest fallback text only after the read answered.
    private func legacyOverview(
        for item: QueueItem,
        operation: QueueReportOperation,
        outputState: QueueOutputsLoadState,
        nameIndex: QueueTargetNameIndex,
        liveIndex: QueueTargetNameIndex,
        isSessionOpen: Bool
    ) -> QueueJobOverviewPresentation {
        let isWholeWiki = item.payload.lintPageIDs?.isEmpty == true
        let rows: [QueueTargetRowValue]
        if let pageIDs = item.payload.lintPageIDs {
            if pageIDs.isEmpty {
                rows = [wholeWikiScopeRow(for: item)]
            } else {
                rows = pageIDs.map { pageID in
                    QueueTargetRowValue(
                        identity: .page(pageID),
                        title: nameIndex.pageTitle(pageID)
                            ?? unresolvedTargetTitle(.page(pageID), in: item.wikiID, loadedFallback: "Deleted page"),
                        // Legacy rows never ran: no recorded evidence →
                        // name-only (operator decision, 2026-09-09).
                        status: nil,
                        actions: rowActions(
                            for: .page(pageID), wikiID: item.wikiID, nameIndex: nameIndex,
                            liveIndex: liveIndex, isSessionOpen: isSessionOpen))
                }
            }
        } else {
            rows = item.payload.sourceIDs.map { sourceID in
                QueueTargetRowValue(
                    identity: .source(sourceID),
                    title: nameIndex.sourceName(sourceID)
                        ?? unresolvedTargetTitle(.source(sourceID), in: item.wikiID, loadedFallback: "Source unavailable"),
                    // Legacy rows never ran: no recorded evidence →
                    // name-only (operator decision, 2026-09-09).
                    status: nil,
                    actions: rowActions(
                        for: .source(sourceID), wikiID: item.wikiID, nameIndex: nameIndex,
                        liveIndex: liveIndex, isSessionOpen: isSessionOpen))
            }
        }
        let count = item.payload.lintPageIDs?.count ?? item.payload.sourceIDs.count
        return QueueJobOverviewPresentation(
            sectionTitle: QueueWorkspaceMapper.sectionTitle(
                for: operation, isWholeWiki: isWholeWiki),
            countText: count > 0 ? String(count) : nil,
            rows: rows,
            resultStatement: nil,
            emptyStateText: emptyStateText(for: operation, isWholeWiki: isWholeWiki),
            outputs: outputsSectionValue(
                for: item,
                operation: operation,
                state: outputState,
                nameIndex: nameIndex))
    }

    /// The ingestion-only Outputs section, read directly from the durable
    /// attempt report. A nil snapshot is legacy/unrecorded, never zero.
    private func outputsSectionValue(
        for item: QueueItem,
        operation: QueueReportOperation,
        state: QueueOutputsLoadState,
        nameIndex: QueueTargetNameIndex
    ) -> QueueOutputsSectionValue? {
        guard operation == .ingest else { return nil }
        return QueueWorkspaceMapper.outputsSection(
            state: state,
            nameIndex: nameIndex,
            openPage: { pageID in
                self.openPage(
                    pageID,
                    title: nameIndex.pageTitle(pageID),
                    in: item.wikiID)
            })
    }

    /// Whole-wiki scope marker — exactly one row, never a wiki enumeration,
    /// before/during/after execution (plan §1). "Browse Pages" preserves the
    /// pre-workspace navigation into the wiki's Pages sidebar.
    private func wholeWikiScopeRow(for item: QueueItem) -> QueueTargetRowValue {
        QueueTargetRowValue(
            id: "scope:whole-wiki",
            identity: nil,
            title: "Whole wiki",
            status: QueueWorkspaceMapper.lifecycle(for: item.state).status,
            actions: [QueueWorkspaceAction(
                label: "Browse Pages", systemImage: "sidebar.left") {
                self.browsePages(in: item.wikiID)
            }])
    }

    /// Navigation actions for one target row. "Extraction output actions
    /// appear only when a recorded output reference stays resolvable" — the
    /// persisted markdown belongs to its source, so the action is Reveal
    /// Source, offered only while the source still resolves in the live
    /// store.
    ///
    /// **The action gate:** the effective index answers "what is this target
    /// called", never "does the target still exist" — its recorded and
    /// read-only entries can outlive the store rows they were captured from
    /// (a target can be deleted after enqueue, and a read-only snapshot can
    /// age), so effective-index membership does NOT guarantee a store row.
    /// The gate is on the LIVE index exactly when a live session exists: on
    /// an OPEN wiki, a target the live store no longer lists keeps its
    /// recorded title but gets NO action — clicking would navigate a store
    /// that cannot answer (dead-end navigation). On a CLOSED wiki, a known
    /// target (recorded name or read-only cache) keeps its click-through
    /// action — the stash+open route resolves at click time, when the deep
    /// link navigates the freshly opened session (and degrades honestly if
    /// the target is truly gone). Titles always come from the effective
    /// index regardless of the gate.
    ///
    /// Both memberships resolve through precomputed name indexes (M2): the
    /// live index answers "still in the store", the effective index answers
    /// "what is it called" — O(1) lookups, no re-scanning per row. The
    /// action routes through ``routeTarget(_:title:in:)``, which opens the
    /// window first.
    private func rowActions(
        for identity: QueueWorkspaceTargetIdentity,
        wikiID: WikiID,
        nameIndex: QueueTargetNameIndex,
        liveIndex: QueueTargetNameIndex,
        isSessionOpen: Bool
    ) -> [QueueWorkspaceAction] {
        Self.targetRowActions(
            for: identity,
            wikiID: wikiID,
            nameIndex: nameIndex,
            liveIndex: liveIndex,
            isSessionOpen: isSessionOpen) { target, title in
            self.routeTarget(target, title: title, in: wikiID)
        }
    }

    /// Pure computation of one target row's navigation actions (value-level
    /// suite seam, same pattern as ``computeRowTitle``). `nameIndex` is the
    /// closed-wiki-aware effective index (titles); `liveIndex` is the live
    /// session's store index (the membership gate — see ``rowActions`` for
    /// the open/closed contract). `route` receives the target identity and
    /// the title the click-through hands to the router.
    nonisolated static func targetRowActions(
        for identity: QueueWorkspaceTargetIdentity,
        wikiID: WikiID,
        nameIndex: QueueTargetNameIndex,
        liveIndex: QueueTargetNameIndex,
        isSessionOpen: Bool,
        route: @escaping (QueueWorkspaceTargetIdentity, String) -> Void
    ) -> [QueueWorkspaceAction] {
        // An open session demands live-store membership; a closed one keeps
        // the click-through (resolved at click time).
        func liveStoreConfirms(_ liveResolves: Bool) -> Bool {
            !isSessionOpen || liveResolves
        }
        switch identity {
        case .page(let pageID):
            guard let title = nameIndex.pageTitle(pageID),
                  liveStoreConfirms(liveIndex.pageTitle(pageID) != nil)
            else { return [] }
            return [QueueWorkspaceAction(
                label: "Open Page", systemImage: "arrow.up.forward.app") {
                route(.page(pageID), title)
            }]
        case .source(let sourceID):
            guard let name = nameIndex.sourceName(sourceID),
                  liveStoreConfirms(liveIndex.sourceName(sourceID) != nil)
            else { return [] }
            return [QueueWorkspaceAction(
                label: "Reveal Source", systemImage: "arrow.up.forward.app") {
                route(.source(sourceID), name)
            }]
        }
    }

    /// The neutral placeholder for a target row whose ID nothing resolves
    /// YET — its wiki is closed and the read-only name read is still
    /// pending. Deliberately transient-sounding: "Deleted page" would
    /// misrepresent a page that exists but simply hasn't been looked up.
    static let resolvingTargetPlaceholder = "Resolving…"

    /// The inventory row title for a payload-derived target the effective
    /// index cannot resolve. While the target's wiki is closed and its
    /// read-only name load is pending (never attempted, or in flight), the
    /// neutral placeholder; once the load answered — or failed, degrading
    /// per plan — the honest fallback text stands. An OPEN wiki needs no
    /// placeholder: the live index already answered, so the fallback is
    /// truthful.
    private func unresolvedTargetTitle(
        _ identity: QueueWorkspaceTargetIdentity,
        in wikiID: WikiID,
        loadedFallback: String
    ) -> String {
        if sessionManager?.sessions[wikiID] == nil {
            switch activityTracker.closedWikiNameLoadStates[wikiID] {
            case .loading, nil:
                return Self.resolvingTargetPlaceholder
            case .loaded, .unavailable:
                break
            }
        }
        return loadedFallback
    }

    /// Availability-aware result statement (plan report truth rules 8–9):
    /// reported summaries pass through; a persistence failure says so instead
    /// of presenting uncommitted outcomes as durable. Design change 10
    /// (2026-09-10): a `.notReported` report renders NO statement line — the
    /// producer summary sentences say only that per-target outcomes were not
    /// reported, which the inventory rows already show state by state, so the
    /// line communicated nothing and read as a result. The engine-side
    /// producer summaries in `QueueIngestionReporting` stay (they remain
    /// durable report data and back the report truth rules); only the
    /// Overview rendering drops them. Pure + `nonisolated` static so the
    /// value suite pins the mapping without hosting the window.
    nonisolated static func resultStatement(for report: QueueAttemptReport) -> String? {
        switch report.availability {
        case .available:
            return report.resultSummary
        case .notReported:
            return nil
        case .reportingUnavailable:
            return "Reporting unavailable for this run — recorded outcomes may be incomplete."
        }
    }

    /// Run Details facts: the job's queue item id, item timestamps, and the
    /// report header's provider/model — falling back to the usage snapshot's
    /// provider/model while a run is in flight (the report header is only
    /// written at completion, so a running job would otherwise show "Not
    /// Reported" next to a navigator that already shows the live model).
    /// Usage is the state-aware resolution from `runDetailsUsage` — the
    /// durable report-header totals for terminal states, the tracker's
    /// recorded-or-live snapshot mid-run (running prefers live) — so a
    /// retried run doesn't show the previous attempt's frozen totals, and
    /// `entries` maps it to one labeled row per present field; a snapshot
    /// with nothing reportable produces no usage rows rather than zeros.
    private func runDetailsFacts(
        for item: QueueItem,
        report: QueueAttemptReport?
    ) -> QueueRunDetailsFacts {
        let startedAt = date(fromMillis: item.startedAt)
        let finishedAt = date(fromMillis: item.finishedAt)
        let usage = Self.runDetailsUsage(
            itemState: item.state,
            report: report?.usage,
            recorded: activityTracker.usage(for: item.id),
            live: activityTracker.liveUsage(for: item.id))
        let providerModel = Self.runDetailsProviderModel(
            reportProvider: report?.provider.map { $0.rawValue },
            reportModel: report?.model.map { $0.rawValue },
            usage: usage)
        return QueueRunDetailsFacts(
            jobID: item.id.rawValue,
            enqueuedAt: date(fromMillis: item.createdAt),
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationText: QueueWorkspaceFormat.duration(from: startedAt, to: finishedAt),
            attempt: report?.attemptID.attempt ?? item.attempt,
            providerText: providerModel.provider,
            modelText: providerModel.model,
            usage: usage)
    }

    /// The Run Details usage-snapshot resolution over the durable report
    /// header and the tracker's recorded and live sources. Design change 11
    /// (2026-09-10): the completion mutation now commits final usage into the
    /// report header, so terminal states read THAT first — it is the durable
    /// truth that survives completion/reload, and it wins over a possibly
    /// stale tracker snapshot. The tracker's recorded-or-live snapshot stays
    /// as the mid-run fallback (the report header carries no usage until
    /// completion): while the item is `.running` the live snapshot wins — a
    /// RETRIED run keeps its item id while the previous attempt's recorded
    /// snapshot survives `.started` (the tracker clears `liveUsage` at
    /// terminal state, never `itemUsage`), and showing the prior attempt's
    /// frozen totals next to a running clock would misrepresent the run. A
    /// running item with no live snapshot yet (before the first
    /// `usage_update`) falls back to the recorded one. Legacy reports with
    /// NULL usage columns contribute nothing (`report == nil`) — absence is
    /// absence, never zeros. Pure + `nonisolated` static so the value suite
    /// pins the precedence without hosting the window.
    nonisolated static func runDetailsUsage(
        itemState: QueueItemState,
        report: QueueReportUsage?,
        recorded: SessionUsage?,
        live: SessionUsage?
    ) -> SessionUsage? {
        switch itemState {
        case .running:
            return live ?? recorded
        case .queued, .completed, .failed, .cancelled:
            return report.map(SessionUsage.init(reportUsage:)) ?? recorded
        }
    }

    /// The Run Details provider/model resolution. Report header values
    /// always win when present — non-nil AND non-blank, matching
    /// `entries`' blank-means-absent rule. Otherwise the usage snapshot's
    /// point-in-time provider label and model stand in: the human-readable
    /// model name when the agent advertised one, else the raw model id —
    /// the same vocabulary `fullSummary` renders for completed rows. The
    /// fallback is the live session's OWN snapshot, so a running job shows
    /// what is actually running; nothing is invented. Pure + `nonisolated`
    /// static so the value suite pins it without hosting the window.
    nonisolated static func runDetailsProviderModel(
        reportProvider: String?,
        reportModel: String?,
        usage: SessionUsage?
    ) -> (provider: String?, model: String?) {
        func present(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespaces),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        return (
            provider: present(reportProvider) ?? present(usage?.providerLabel),
            model: present(reportModel)
                ?? (present(usage?.modelName) ?? present(usage?.modelId)))
    }

    private func emptyStateText(
        for operation: QueueReportOperation,
        isWholeWiki: Bool
    ) -> String {
        switch operation {
        case .ingest, .extract:
            return "No sources recorded for this job."
        case .lint:
            return isWholeWiki ? "No scope recorded for this job." : "No pages recorded for this job."
        }
    }

    /// Resolve a source ID to its display filename via the wiki's store, or
    /// `nil` when the source no longer exists / the session isn't live.
    /// Single-lookup convenience for call sites without a precomputed index;
    /// batch call sites use ``makeNameIndex(wikiID:)``.
    private func sourceTitle(_ sourceID: SourceID, wikiID: WikiID) -> String? {
        makeNameIndex(wikiID: wikiID).sourceName(sourceID)
    }

    @ViewBuilder
    private func transcriptContent(for item: QueueItem) -> some View {
        let presentation = transcriptPresentation(for: item)

        if !presentation.items.isEmpty {
            presentation.transcriptView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Match the workspace header's 16pt inset. ChatWebView's CSS sets
                // body left-padding to 0 by design (PR #457) — the left margin
                // is the host's responsibility, so provide it here.
                .padding(.horizontal, 16)
        } else if presentation.usesProgressFallback {
            ScrollView {
                Text(presentation.progressText)
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

    // MARK: - Target navigation

    // (Open Page / Reveal Source / Browse Pages live here — used by the
    // Overview rows and the header actions. The former linted-pages section
    // was folded into the Overview inventory: report-backed rows when a
    // report exists, payload rows otherwise.)

    /// Resolve a page ID to its current title via the wiki's store, or `nil`
    /// if the page no longer exists / the session isn't live.
    /// Single-lookup convenience for call sites without a precomputed index;
    /// batch call sites use ``makeNameIndex(wikiID:)``.
    private func pageTitle(_ pageID: PageID, wikiID: WikiID) -> String? {
        makeNameIndex(wikiID: wikiID).pageTitle(pageID)
    }

    /// Open a linted page in its wiki's main window — the closed-wiki
    /// click-through seam. Routes through ``QueueTargetRouter``: an open
    /// session navigates the shared model directly (`openTab` mutates the
    /// same model the main window observes — #583); a closed window stashes
    /// the `wiki://page` deep link (#635 seam) and opens the window, where
    /// `RootView` delivers it once the session exists.
    private func openPage(_ pageID: PageID, title: String?, in wikiID: WikiID) {
        routeTarget(.page(pageID), title: title, in: wikiID)
    }

    /// Reveal an extraction job's source in the wiki's Sources outline
    /// (#598) — the closed-wiki click-through seam. Same
    /// ``QueueTargetRouter`` split as ``openPage(_:title:in:)``: sidebar
    /// reveal when the session is live (sources are file-backed toms, not
    /// tabable documents), stashed `wiki://source` deep link + window open
    /// when not.
    private func revealSource(_ sourceID: SourceID, title: String?, in wikiID: WikiID) {
        routeTarget(.source(sourceID), title: title, in: wikiID)
    }

    /// Route a known target's click into its wiki window through the
    /// ``QueueTargetRouter`` built from this window's session manager and
    /// window-opening bridge.
    private func routeTarget(
        _ target: QueueWorkspaceTargetIdentity,
        title: String?,
        in wikiID: WikiID
    ) {
        let sessions = sessionManager
        let bridge = openWindowBridge
        let router = QueueTargetRouter(
            liveStore: { wikiID in sessions?.sessions[wikiID]?.store },
            navigateInSession: { store, target in
                switch target {
                case .page(let pageID):
                    store.openTab(.page(pageID))
                    DebugLog.tabs("Queue Open Page: opened page \(pageID.rawValue) in wiki \(wikiID.rawValue.prefix(8))")
                case .source(let sourceID):
                    store.requestSidebarReveal(.source(sourceID))
                    DebugLog.tabs("Queue Reveal Source: revealed source \(sourceID.rawValue) in wiki \(wikiID.rawValue.prefix(8))")
                }
            },
            stashDeepLink: { wikiID, url in
                sessions?.stashPendingWikiLink(wikiID, url: url, openInNewTab: false)
                DebugLog.tabs("Queue click-through: stashed \(url.absoluteString) for wiki \(wikiID.rawValue.prefix(8))")
            },
            openWiki: { wikiID in bridge?.openWiki?(wikiID) })
        router.route(target, title: title, in: wikiID)
    }

    /// Whole-wiki lint "Browse Pages": reveal the wiki's home page (switches the
    /// shared model's sidebar to the Pages section via the same
    /// `requestSidebarReveal` mechanism the bookmark "Go to Original" action
    /// uses, #570), then focus the wiki window. Falls back to the first page if
    /// there's no home page, and to focusing the window only if the wiki has no
    /// pages / no live session.
    private func browsePages(in wikiID: WikiID) {
        let session = sessionManager?.sessions[wikiID]
        let store = session?.store
        if store != nil, let homeID = session?.descriptor.homePageID {
            store?.requestSidebarReveal(.page(homeID))
            DebugLog.tabs("Lint Browse Pages: revealed home page in wiki \(wikiID.rawValue.prefix(8))")
        } else if let firstID = store?.summaries.first?.id {
            store?.requestSidebarReveal(.page(firstID))
            DebugLog.tabs("Lint Browse Pages: revealed first page in wiki \(wikiID.rawValue.prefix(8))")
        } else {
            DebugLog.tabs("Lint Browse Pages: no pages to reveal in wiki \(wikiID.rawValue.prefix(8)); focusing window only")
        }
        openWindowBridge?.openWiki?(wikiID)
    }

    // MARK: - Copy

    /// The copy path uses the same canonical typed rows as the renderer.
    private func copyableText(for item: QueueItem) -> String? {
        transcriptPresentation(for: item).copyText
    }

    private func transcriptPresentation(for item: QueueItem) -> ActivityTranscriptPresentation {
        ActivityTranscriptPresentation(
            items: ActivityTranscriptPresentation.canonicalItems(
            persisted: loadedTranscriptItems,
            live: activityTracker.transcript(for: item.id)),
            progressText: activityTracker.progressLog(for: item.id),
            transcriptID: TranscriptID.queueItem(item.id),
            isStreaming: item.state == .running,
            onIntent: { intent in
                if case .openWikiLink(let url, let inNewTab) = intent {
                    wikiLinkHandler(for: item.wikiID)(url, inNewTab)
                }
            },
            renderContext: renderContextProvider(for: item.wikiID),
            blobStore: store(for: item.wikiID)
        )
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
        runQueueCommand("retry job") { try await queueEngine.retryItem(item.id) }
    }

    /// Cancel a queued/running job — one implementation shared by the header
    /// button, the row inline action, and the context menu.
    private func cancel(item: QueueItem) {
        runQueueCommand("cancel item") { try await queueEngine.cancelItem(item.id) }
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
    private func store(for wikiID: WikiID) -> WikiStoreModel? {
        sessionManager?.sessions[wikiID]?.store
    }

    /// A `WikiRenderContext` provider bound to `wikiID`'s store, or nil when
    /// the wiki window is closed. `nil` preserves the historical constant-
    /// `true` resolution in `ChatWebView` (links render as resolved — the
    /// best we can do without a live store to query).
    private func renderContextProvider(for wikiID: WikiID) -> (() -> WikiRenderContext?)? {
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
    private func wikiLinkHandler(for wikiID: WikiID) -> (URL, Bool) -> Void {
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
        // - "Open Settings → Providers" / "Open Settings → Extraction"
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
        // are fixable from Settings → Providers, so both should surface the CTA
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

    private func wikiDisplayName(for id: WikiID) -> String {
        sessionManager?.sessions[id]?.descriptor.displayName ?? String(id.rawValue.prefix(8))
    }

    /// The kind word the navigator search matches for `item` ("Lint",
    /// "Extraction", "Ingestion"). PURE + `nonisolated`: an input to the
    /// pure navigator haystack.
    nonisolated static func kindLabel(for item: QueueItem) -> String {
        if item.payload.lintPageIDs != nil { return "Lint" }
        switch item.queue {
        case .extraction, .transcription: return "Extraction"
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
        /// Strongly typed queue identity rendered as the row's leading
        /// metadata. Raw text is produced only by `rowMetadata(jobID:suffix:)`.
        let jobID: QueueItem.ID
        /// Frozen relative time for non-running rows. Running rows derive a
        /// live elapsed suffix in their `TimelineView` instead.
        let relativeTime: String?
        /// Wiki display name retained for filtering; it is not row metadata.
        let wikiName: String
        let targetNames: [String]
        let usage: SessionUsage?
        let liveUsage: SessionUsage?
        /// #608: pending always-ask permission for this item, or `nil` when
        /// the run isn't blocked. Surfaces a yellow "Permission pending:
        /// <cmd>" row below the status row in the sidebar — same pattern as
        /// the Agents-settings model-warning (`exclamationmark.triangle.fill`
        /// + `.orange`).
        let pendingPermission: PendingPermission?
        /// Report-backed search text from the item's cached summary (plan:
        /// "outcome search use batched job summaries"). Empty while loading.
        let summarySearchText: String
        /// Phase progress line from the cached summary ("Staging sources ·
        /// 8 of 12"), or `nil` when nothing countable is recorded.
        let progressLine: String?
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
        let reportSummaries = activityTracker.reportSummaries

        // M2: one name index per live wiki session, built once per render.
        // Replaces the per-item linear scans over `sources`/`summaries`
        // (O(items × targets × pages) per queue event) with one
        // O(sources + pages) pass per wiki plus O(1) lookups per target.
        // Built HERE, at the sidebar level, so the observable reads stay
        // tracked outside row bodies — the observation-crash workaround holds.
        var nameIndexes: [WikiID: QueueTargetNameIndex] = [:]
        func nameIndex(for wikiID: WikiID) -> QueueTargetNameIndex {
            if let cached = nameIndexes[wikiID] { return cached }
            let built = Self.makeNameIndex(
                sessions: sessions, wikiID: wikiID)
            nameIndexes[wikiID] = built
            return built
        }

        var result: [QueueItem.ID: RowDisplayData] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            let session = sessions[item.wikiID]
            let wikiName = session?.descriptor.displayName ?? String(item.wikiID.rawValue.prefix(8))

            // Resolve source/page names through the closed-wiki-aware
            // effective index (live → recorded → read-only; observable reads
            // happen once, above, inside makeNameIndex — not per target).
            // Names feed the row TOOLTIP and the navigator search haystack
            // only — row titles are operation + count only (operator
            // request), so a closed-wiki job whose names are still resolving
            // or missing degrades to the count wording, never a raw ID.
            let effectiveIndex = QueueTargetNameIndex.effective(
                live: nameIndex(for: item.wikiID),
                readOnlyCache: activityTracker.closedWikiNameIndexes[item.wikiID],
                payload: item.payload)
            let resolved = effectiveIndex.displayNames(for: item)

            result[item.id] = RowDisplayData(
                title: Self.computeRowTitle(for: item, wikiName: wikiName),
                jobID: item.id,
                relativeTime: relativeTime(for: item),
                wikiName: wikiName,
                targetNames: resolved.targets,
                usage: itemUsage[item.id],
                liveUsage: liveUsage[item.id],
                pendingPermission: pendingPermissions[item.id],
                summarySearchText: reportSummaries[item.id]?.searchText ?? "",
                progressLine: Self.progressLine(
                    summary: reportSummaries[item.id],
                    item: item))
        }
        return result
    }

    /// Build the name index for one wiki from a snapshot of the live sessions
    /// (`buildRowDisplayData`) or the session manager itself (single-item
    /// callers). Static so both entry points share one implementation; pure
    /// relative to the passed snapshot.
    private static func makeNameIndex(
        sessions: [WikiID: any WikiSessionProtocol],
        wikiID: WikiID
    ) -> QueueTargetNameIndex {
        guard let store = sessions[wikiID]?.store else { return QueueTargetNameIndex() }
        var index = QueueTargetNameIndex()
        for source in store.sources {
            index.recordSource(source.id, name: source.effectiveName)
        }
        for summary in store.summaries {
            index.recordPage(summary.id, title: summary.title)
        }
        return index
    }

    /// Single-item variant of the name index (selected-job detail pane).
    private func makeNameIndex(wikiID: WikiID) -> QueueTargetNameIndex {
        Self.makeNameIndex(sessions: sessionManager?.sessions ?? [:], wikiID: wikiID)
    }

    /// The production closed-wiki database URL provider: the wiki's App
    /// Group container database, read-only. `nil` (logged) when the
    /// location cannot be resolved.
    nonisolated private static func productionClosedWikiDatabaseURL(
        for wikiID: WikiID
    ) -> URL? {
        do {
            return try DatabaseLocation.appGroupContainerURL(forWikiID: wikiID.rawValue)
        } catch {
            DebugLog.store(
                "Closed-wiki name resolution: cannot resolve database URL for wiki \(wikiID.rawValue.prefix(8)): \(error)")
            return nil
        }
    }

    /// The effective name index for ONE item (closed-wiki name resolution):
    /// the live session index overlaid with the payload's recorded names,
    /// then the read-only cache for the item's closed wiki. The overlay's
    /// layering IS the rendering precedence — live → recorded → read-only.
    private func makeNameIndex(for item: QueueItem) -> QueueTargetNameIndex {
        QueueTargetNameIndex.effective(
            live: makeNameIndex(wikiID: item.wikiID),
            readOnlyCache: activityTracker.closedWikiNameIndexes[item.wikiID],
            payload: item.payload)
    }

    /// Plain progress line ("Staging sources · 8 of 12") from a cached
    /// summary. Static so it can be precomputed per sidebar render — the
    /// observation workaround means row bodies never read the tracker.
    nonisolated static func progressLine(
        summary: QueueReportSummary?,
        item: QueueItem
    ) -> String? {
        let progress = QueueWorkspaceMapper.headerProgress(
            from: summary,
            operation: QueueWorkspaceMapper.reportOperation(for: item),
            payloadTargetCount: item.payload.lintPageIDs?.count ?? item.payload.sourceIDs.count,
            jobLifecycle: QueueWorkspaceMapper.lifecycle(for: item.state))
        guard let progress else { return nil }
        return [progress.phaseText, progress.countsText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Pure computation of the navigator row title from the payload and the
    /// wiki display name (no `@Observable` reads). PURE + `nonisolated` (same
    /// reason as ``navigatorSearchText``): the value-level suite pins the
    /// exact wordings without a main-actor hop.
    ///
    /// Titles are OPERATION + COUNT ONLY (operator request, 2026-09-09: the
    /// first target's name left every row title and the header title, because
    /// a closed wiki could surface a raw ID where a name was expected):
    /// "Ingest 12 sources" / "1 source", "Lint 3 pages", and the unchanged
    /// whole-wiki "Lint <wiki>". Extraction keeps its existing count wording
    /// ("12 sources" / the kind label). No target name and no raw target ID
    /// can reach a row title; resolved names still feed the row tooltip and
    /// the navigator search haystack (``navigatorSearchText``).
    nonisolated static func computeRowTitle(
        for item: QueueItem,
        wikiName: String
    ) -> String {
        if let pageIDs = item.payload.lintPageIDs {
            if pageIDs.isEmpty { return "Lint \(wikiName)" }
            return pageIDs.count == 1 ? "Lint 1 page" : "Lint \(pageIDs.count) pages"
        }
        let count = item.payload.sourceIDs.count
        switch item.queue {
        case .ingestion:
            // Zero targets cannot be spoken as a count — the kind label is
            // the same fallback the old count path used.
            guard count > 0 else { return Self.kindLabel(for: item) }
            return count > 1 ? "Ingest \(count) sources" : "1 source"
        case .extraction, .transcription:
            return count > 1 ? "\(count) sources" : Self.kindLabel(for: item)
        }
    }

    /// The count-only "<Job Details>" phrase the header title prefixes —
    /// "Ingestion: 12 sources", "Extraction: 1 source", "Lint: 3 pages",
    /// whole-wiki "Lint: <wiki>" via ``QueueWorkspaceMapper.headerTitle``.
    /// Same no-names/no-ID rule as ``computeRowTitle(for:wikiName:)``; PURE +
    /// `nonisolated` for the same suite-pinning reason.
    nonisolated static func headerJobCountPhrase(
        for item: QueueItem,
        wikiName: String
    ) -> String {
        if let pageIDs = item.payload.lintPageIDs {
            if pageIDs.isEmpty { return wikiName }
            return pageIDs.count == 1 ? "1 page" : "\(pageIDs.count) pages"
        }
        let count = item.payload.sourceIDs.count
        guard count > 0 else { return Self.kindLabel(for: item) }
        return count > 1 ? "\(count) sources" : "1 source"
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

// MARK: - Toolbar job-search control (design change 6, 2026-09-09)

/// The toolbar job-search control: one persistent `NSStackView` hosting BOTH
/// forms — the expanded `NSSearchField`
/// and the collapsed magnifying-glass button — with visibility toggled by the
/// expand/collapse decision. The field never leaves the hierarchy across
/// state changes, so expansion can re-focus it without remounting. It lives
/// in the toolbar LEFT of the Queue Actions menu, replacing the former
/// `.searchable` field, and binds the same `jobFilter.search` query. Using a
/// real `NSSearchField` gives the window AppKit's native search affordances
/// for free — the in-field magnifying glass, the clear button, and
/// Escape-to-clear.
///
/// State discipline (the NSViewRepresentable state-write rule): `makeNSView` /
/// `updateNSView` never write SwiftUI state. The query write happens in the
/// delegate callbacks (user edits only). The expansion write happens in the
/// button's action (a user event), and the empty-editing-end write happens in
/// `controlTextDidEndEditing` — also a delegate callback, so also a user-event
/// context. The re-focus — an AppKit first-responder change, not a SwiftUI
/// state write — runs ONLY for a click-requested expansion: the view passes
/// ``focusOnExpand``, which `updateNSView` checks once the expanded layout
/// has landed. A resize-driven collapsed→expanded flip (the window crossing
/// the expansion threshold) never takes keyboard focus. The inverse —
/// collapsing while the field editor is live — resigns first responder on
/// the same deferred pattern, so keystrokes cannot continue into an
/// invisible field.
struct QueueSearchToolbarControl: NSViewRepresentable {
    @Binding var text: String
    /// The expand/collapse decision
    /// (``QueueSearchToolbarForm/decision``) already applied by the view.
    let isExpanded: Bool
    /// Called from the collapsed button's action (a user event): asks the
    /// view to expand (``ActivityWindowView/searchExpandedByUser``).
    let onExpandRequested: () -> Void
    /// Whether the current expansion was requested by the magnifying-glass
    /// click (``ActivityWindowView/searchExpandedByUser``) rather than by
    /// the width decision. Only a click-requested expansion focuses the
    /// field; a resize-driven flip never takes keyboard focus.
    let focusOnExpand: Bool
    /// Called from the delegate's editing-end (also a user-event context)
    /// when the field is empty at that moment: asks the view to spend the
    /// explicit expansion request (``ActivityWindowView/searchExpandedByUser``)
    /// so a narrow window collapses the control.
    let onEditEndedEmpty: () -> Void
    /// Placeholder + accessibility label (``ActivityWindowView/searchPrompt``).
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSStackView {
        let coordinator = context.coordinator
        let field = NSSearchField(frame: .zero)
        field.placeholderString = prompt
        field.sendsWholeSearchString = false
        field.target = coordinator
        field.action = #selector(Coordinator.searchAction(_:))
        field.delegate = coordinator
        field.setAccessibilityLabel(prompt)

        let button = NSButton(
            title: "",
            image: NSImage(systemSymbolName: "magnifyingglass",
                           accessibilityDescription: prompt) ?? NSImage(),
            target: coordinator,
            action: #selector(Coordinator.expandClicked))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(prompt)
        button.toolTip = prompt

        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        coordinator.field = field
        coordinator.expandButton = button
        apply(isExpanded: isExpanded, text: text, to: stack, coordinator: coordinator)
        coordinator.reassertToolbarItemLabel(for: stack)
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        let coordinator = context.coordinator
        let wasCollapsed = coordinator.isShowingCollapsed
        coordinator.onExpandRequested = onExpandRequested
        coordinator.onEditEndedEmpty = onEditEndedEmpty
        apply(isExpanded: isExpanded, text: text, to: stack, coordinator: coordinator)
        coordinator.reassertToolbarItemLabel(for: stack)
        // Focus ONLY a click-requested expansion (``focusOnExpand``): a
        // resize-driven collapsed→expanded flip (the window crossing the
        // expansion threshold) leaves it unset, so resizing never steals
        // keyboard focus. The focus itself is deferred — a first-responder
        // change must not run inside SwiftUI's update pass (re-entrant
        // updates) — and the field is persistent across forms, so the
        // deferred focus targets the same view the user just revealed.
        if wasCollapsed && isExpanded && focusOnExpand {
            Task { @MainActor [coordinator] in
                guard coordinator.isShowingCollapsed == false else { return }
                coordinator.focusField()
            }
        }
    }

    /// The single place the two forms are made visible/hidden and the
    /// binding is pushed into the field — called from `makeNSView` and every
    /// `updateNSView`, so no caller duplicates the sync.
    private func apply(
        isExpanded: Bool,
        text: String,
        to stack: NSStackView,
        coordinator: Coordinator
    ) {
        // Both controls are mounted before this runs: `apply` is called only
        // from `makeNSView` and `updateNSView`, which assign them first
        // (makeNSView) or run after it (updateNSView), so the unwraps are an
        // invariant rather than an error path.
        guard let field = coordinator.field,
              let expandButton = coordinator.expandButton else { return }
        let wasExpanded = !coordinator.isShowingCollapsed
        // Read the live-editor state BEFORE hiding the field: hiding ends
        // editing as a side effect, so a post-hide check would never see the
        // editor even when it was live one statement earlier.
        var resignWhenCollapsed = false
        if wasExpanded && !isExpanded {
            resignWhenCollapsed = field.currentEditor() != nil
                || field.window?.firstResponder === field
        }
        field.isHidden = !isExpanded
        expandButton.isHidden = isExpanded
        coordinator.isShowingCollapsed = !isExpanded
        coordinator.sync(text: text, into: field)
        // Collapsing while the field editor is live would leave the
        // keystrokes' target invisible. Resign first responder — on the same
        // deferred pattern as the focus write, never inside the update pass,
        // and re-checked in the task so a fast re-expansion cancels the
        // resign.
        if resignWhenCollapsed {
            Task { @MainActor [coordinator] in
                guard coordinator.isShowingCollapsed,
                      let field = coordinator.field,
                      let window = field.window,
                      window.firstResponder === field
                        || window.firstResponder === field.currentEditor() else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        /// The `NSToolbarItem` label for this control — what the
        /// customization palette shows. SwiftUI derives "" for representable
        /// items (it only lifts titles from SwiftUI-side control text), so
        /// the coordinator asserts this label itself.
        static let itemLabel = "Search"

        private let text: Binding<String>
        /// The mounted controls. Nil only before `makeNSView`: every read
        /// site (`apply`, the deferred focus/resign tasks) runs after mount,
        /// so each unwrap below documents an invariant rather than an error
        /// path.
        var field: NSSearchField?
        var expandButton: NSButton?
        var onExpandRequested: (() -> Void)?
        var onEditEndedEmpty: (() -> Void)?
        /// The form the stack last displayed. Drives the collapse-side
        /// resign (``QueueSearchToolbarControl/apply``) and guards the
        /// deferred focus; the re-focus itself keys off the view's
        /// ``QueueSearchToolbarControl/focusOnExpand``, not this flip.
        var isShowingCollapsed = true
        /// Set while the Escape handler clears the field editor: the
        /// synchronous editor clear fires `controlTextDidChange` (via the
        /// editor's own did-change chain), and letting that write the
        /// binding would drive a SwiftUI update re-entrantly inside the
        /// text view's command dispatch. The binding write is deferred to
        /// the next tick instead.
        var isClearingQueryFromEscape = false

        init(text: Binding<String>) {
            self.text = text
        }

        /// Find the toolbar item hosting this control and keep its label for
        /// the customization palette. Runs on the NEXT runloop tick: SwiftUI
        /// re-derives toolbar item labels during its own update (and a
        /// representable has no SwiftUI title to lift, so it derives ""),
        /// then we assert ours — so ours is the last write before the
        /// toolbar is observed.
        func reassertToolbarItemLabel(for control: NSView) {
            guard control.window?.toolbar != nil else { return }
            DispatchQueue.main.async { [weak control] in
                guard let control, let toolbar = control.window?.toolbar else { return }
                for item in toolbar.items {
                    guard let view = item.view, control.isDescendant(of: view) else { continue }
                    if item.label != Self.itemLabel {
                        item.label = Self.itemLabel
                    }
                    return
                }
            }
        }

        /// Push the binding into the field. Self-originated edits already
        /// made the two equal (the delegate wrote the binding from this
        /// field), so this is a no-op during typing and never moves the
        /// insertion point; only external writes (Clear Filters, a deep
        /// link's filter reset) differ and land.
        func sync(text: String, into field: NSSearchField) {
            guard field.stringValue != text else { return }
            field.stringValue = text
        }

        /// Only reachable via the deferred task in `updateNSView`, i.e. after
        /// `makeNSView` has mounted the field, so the unwrap is an invariant.
        func focusField() {
            guard let field else { return }
            if let window = field.window, window.firstResponder !== field {
                window.makeFirstResponder(field)
            }
        }

        // MARK: User-edit paths (the only places SwiftUI state is written)

        /// The collapsed button's click — a user event: request expansion.
        /// The view records the request (``ActivityWindowView/searchExpandedByUser``)
        /// and passes it back as ``QueueSearchToolbarControl/focusOnExpand``;
        /// the focus itself lands on the next `updateNSView`.
        @objc func expandClicked() {
            onExpandRequested?()
        }

        /// Live-as-you-type query updates, plus the clear button's edit.
        /// The binding write is DEFERRED by one runloop tick: writing it
        /// synchronously inside the field editor's did-change callback makes
        /// SwiftUI re-render the navigator (an NSTableView) re-entrantly in
        /// the middle of AppKit's text machinery — fatal to the test-runner
        /// session and hostile to real event processing alike. One tick is
        /// imperceptible and keeps the update on the outside of the text
        /// stack. Suppressed while the Escape handler clears the editor
        /// (``isClearingQueryFromEscape``); that path defers its own write.
        func controlTextDidChange(_ notification: Notification) {
            guard !isClearingQueryFromEscape else { return }
            guard let field = notification.object as? NSSearchField else { return }
            let value = field.stringValue
            Task { @MainActor [weak self] in
                self?.text.wrappedValue = value
            }
        }

        /// NSSearchField's native Escape: the first press clears a non-empty
        /// query (the view's `onChange(of:)` then collapses a narrow window's
        /// control); an already-empty field lets the cancel propagate so
        /// editing ends normally (second press dismisses focus). The visible
        /// text lives in the LIVE field editor this callback receives — clear
        /// `textView` itself, not `field.stringValue`, whose write the open
        /// editor would overwrite on the next edit sync. The editor clear is
        /// synchronous, but the binding write must NOT run inside the text
        /// view's command dispatch: it would drive a SwiftUI re-render
        /// re-entrantly through the editor's text-change callback (Observed
        /// as a runner-fatal reentrant NSTableView operation in the hosted
        /// tests). So the change callback is gated while the editor is
        /// cleared, and the binding write lands on the next runloop tick.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            guard let field = control as? NSSearchField,
                  field.stringValue.isEmpty == false else { return false }
            isClearingQueryFromEscape = true
            defer { isClearingQueryFromEscape = false }
            textView.string = ""
            Task { @MainActor [weak self] in
                self?.text.wrappedValue = ""
            }
            return true
        }

        /// Editing ended (Enter, focus moving away, or the second Escape on
        /// an already-empty field): when the field is EMPTY at that moment,
        /// spend the explicit expansion request so a narrow window collapses
        /// the control back to the button — an abandoned empty search should
        /// not hold the field open (`NSSearchToolbarItem` behavior). The
        /// delegate callback is a user-event context, so this SwiftUI state
        /// write is legal here. A non-empty field keeps the expansion; the
        /// query itself holds the field open via the decision's non-empty
        /// branch.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField,
                  field.stringValue.isEmpty else { return }
            onEditEndedEmpty?()
        }

        /// Enter / the search button: AppKit's target/action passes the
        /// field as sender. Typing already kept the binding in sync; this
        /// write is idempotent and covers the paths the field editor's
        /// change notifications don't reach.
        @objc func searchAction(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
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
    /// Stop All confirmation copy (plan §"Stop All"), as named constants so
    /// the hosted scenarios and the user-guide parity test pin the exact
    /// semantics: the confirmation states that Stop All pauses this queue and
    /// cancels its running work. It does not delete queued work, and the
    /// confirmation does not imply that it does.
    static func stopAllConfirmationTitle(for queueTitle: String) -> String {
        "Stop all running work in \(queueTitle)?"
    }

    static let stopAllButtonLabel = "Stop All"
    static let stopAllConfirmationMessage =
        "This pauses the queue and cancels its running jobs. Queued jobs remain queued."

    /// The toolbar job-search prompt + accessibility label, carried over from
    /// the former `.searchable` field unchanged (design change 6): the
    /// expanded field's placeholder and the collapsed button's accessibility
    /// label are the same string so the control announces itself identically
    /// in both forms. The value-level suite pins it. `nonisolated` so the
    /// nonisolated test suites can read it without a main-actor hop.
    nonisolated static let searchPrompt = "Search loaded jobs"

    /// The selected-job workspace's outside-filter notice (plan §"Selection,
    /// filters, and deep links"). The notice renders these constants; the
    /// value-level suite (`QueueWorkspaceIntegrationTests`) pins the exact
    /// strings and the shared show condition
    /// (``isHiddenByFilter(_:filter:rowTitle:wikiName:targetNames:summarySearchText:)``).
    static let filteredSelectionNoticeText = "Selected job is outside this filter"
    static let clearFiltersButtonLabel = "Clear Filters"

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

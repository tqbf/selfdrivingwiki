import Foundation
import Observation

/// The app's single source of truth for wiki state and the in-flight editing
/// session. `@MainActor @Observable` (uses `Observation`, NOT SwiftUI — this
/// type is UI-framework-agnostic so it can be unit-tested directly).
///
/// Design notes mapped to SWIFTUI-RULES:
/// - `summaries` is ALWAYS rebuilt from `store.listPages()` after a mutation,
///   never incrementally patched (§3.1 / §3.2).
/// - The live editing buffers `draftTitle` / `draftBody` live HERE, not in view
///   `@State`, so a page switch or app-background flush can read the CURRENT
///   text at the latest possible moment (§3.5 "read state at save time").
@MainActor
@Observable
public final class WikiStoreModel {
    public private(set) var summaries: [WikiPageSummary] = []
    /// Sort order for the sidebar pages list. Changing this triggers a reload.
    public var pageSortOrder: PageSortOrder = .lastUpdated {
        didSet {
            guard pageSortOrder != oldValue else { return }
            reloadSummaries()
        }
    }
    /// Live search query from the sidebar search bar. Debounced 300ms.
    public var searchQuery: String = "" {
        didSet { scheduleSearch() }
    }
    /// Results of the last search (empty when searchQuery is empty).
    public private(set) var searchResults: [WikiPageSummary] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The sidebar selection: a page, the system-prompt document, or nothing.
    public var selection: WikiSelection?
    public private(set) var backStack: [WikiSelection] = []
    public private(set) var forwardStack: [WikiSelection] = []

    public var canNavigateBack: Bool { !backStack.isEmpty }
    public var canNavigateForward: Bool { !forwardStack.isEmpty }

    // MARK: - Tab management

    /// All open editor tabs, in display order (left to right).
    public private(set) var tabs: [EditorTab] = []
    /// The active tab's stable identity — the single source of truth for "which
    /// tab is focused." `nil` in the empty state (no tabs). All tab operations
    /// find the active tab by this ID; indices are computed at the view layer
    /// only (for `ForEach` / keyboard-shortcut numbering).
    public var activeTabID: UUID?
    /// Stack of recently-closed tabs for Cmd+Shift+T reopen. Max 10.
    public private(set) var recentlyClosedTabs: [EditorTab] = []

    /// View-layer convenience: the active tab's position. Computed from
    /// `activeTabID`, never stored — so it can't go stale on a close/reorder.
    /// Falls back to 0 in the empty state.
    public var activeTabIndex: Int {
        activeTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
    }
    /// The active tab value, or `nil` in the empty state.
    public var activeTab: EditorTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// The removable list of ingested files (Phase 5). Like `summaries`, this is
    /// ALWAYS rebuilt from `store.listSources()` after a change, never
    /// incrementally patched (§3.1). Most-recent-first.
    public private(set) var sources: [SourceSummary] = []
    /// Best-effort UI status for whether a raw source has already been processed
    /// by an agent Ingest run. The source of truth is the append-only log; agents
    /// can choose their log title, so matching accepts the filename, id, by-id
    /// projection leaf, or path in either the log title or note.
    private var sourceIngestedStatus: [PageID: Bool] = [:]

    /// Invoked on the main actor after any successful persisted mutation
    /// (save / new / rename / delete). The app wires this to the File Provider
    /// `signalChange()` so Terminal reads see edits without relaunch (INITIAL
    /// §6/§10). Nil-safe: tests leave it unset, and `WikiFSCore` never imports
    /// `FileProvider` — the closure is injected from the app layer.
    @ObservationIgnored public var onPageDidChange: (@MainActor () -> Void)?

    /// Live editing buffers — the single source of in-flight text.
    public var draftTitle: String = "" {
        didSet { if draftTitle != oldValue { isDraftDirty = true } }
    }
    public var draftBody: String = "" {
        didSet { if draftBody != oldValue { isDraftDirty = true } }
    }

    /// Live editing buffer for the system-prompt document (the singleton
    /// `CLAUDE.md`/`AGENTS.md`). Separate track from the page drafts above so the
    /// well-tested page autosave path is untouched.
    public var draftSystemPrompt: String = "" {
        didSet { if draftSystemPrompt != oldValue { isSystemPromptDirty = true } }
    }

    /// True while a `claude -p` operation is running against THIS wiki (Phase C /
    /// decision #6). The editor binds this to go read-only with a banner, and
    /// autosave is paused — so in-app edits can't clobber the agent's `wikictl`
    /// writes (last-writer-wins race). Set via `beginAgentRun` / `endAgentRun`.
    public private(set) var isAgentRunning = false

    private let store: WikiStore
    private var autosaveTask: Task<Void, Never>?
    private var systemPromptAutosaveTask: Task<Void, Never>?
    /// The page whose text currently lives in the draft buffers.
    private var loadedPage: PageID?
    /// What the drafts currently hold, so a flush saves the RIGHT document even
    /// after `selection` has advanced (§3.5 read-state-at-save-time).
    private var loadedSelection: WikiSelection?
    private var isApplyingHistorySelection = false
    /// True when the page drafts differ from the last persisted state. Cleared on
    /// save and on load. Prevents `flushPendingSaves()` from bumping `updated_at`
    /// on a tab switch when the user only viewed a page without editing.
    private var isDraftDirty = false
    /// Same for the system prompt draft (separate track).
    private var isSystemPromptDirty = false
    /// Suppresses double-processing in `handleSelectionChange` while a tab switch
    /// is mid-flight (`setActiveTab` assigns `selection`, which fires the view's
    /// `onChange(of: selection)` bridge). Set in exactly one place —
    /// `setActiveTab(_:)`. Follows the same pattern as `isApplyingHistorySelection`.
    @ObservationIgnored private var isApplyingTabSelection = false
    private static let navigationHistoryLimit = 100
    private static let maxRecentlyClosedTabs = 10

    public init(store: WikiStore) {
        self.store = store
        reloadSummaries()
        reloadSources()
        // Preload the system-prompt draft so its editor has content immediately;
        // selecting it later reloads fresh from the store.
        draftSystemPrompt = (try? store.getSystemPrompt())?.body ?? SystemPrompt.defaultBody
    }

    // MARK: - Selection / loading

    /// Switch the selection programmatically. Flushes any pending save
    /// SYNCHRONOUSLY first (§3.5 immediate-on-switch) so the outgoing document
    /// can't lose buffered edits, then loads the new selection's text.
    /// Updates the active tab's metadata to stay in sync.
    public func select(_ newValue: WikiSelection?) {
        guard newValue != selection else { return }
        flushPendingSaves()
        recordHistoryTransition(from: loadedSelection, to: newValue)
        selection = newValue
        loadDrafts(for: newValue)
        syncActiveTabMetadata(to: newValue)
    }

    /// Bridge for SwiftUI's `List(selection:)`, which writes `selection`
    /// DIRECTLY (bypassing `select(_:)`). The view observes the property with
    /// `.onChange(of:)` and calls this. Flushing reads the drafts, which still
    /// belong to `loadedSelection`, so the outgoing document's edits are
    /// persisted before we load the incoming one (§3.5).
    public func handleSelectionChange(to newValue: WikiSelection?) {
        // Skip if triggered programmatically by a tab switch.
        guard !isApplyingTabSelection, newValue != loadedSelection else { return }
        flushPendingSaves()     // persists drafts to loadedSelection
        recordHistoryTransition(from: loadedSelection, to: newValue)
        loadDrafts(for: newValue)

        // Keep the active tab's metadata in sync after a sidebar-driven change
        // (in-tab navigation). If no tabs exist yet, create the initial tab.
        if tabs.isEmpty, let newValue {
            let tab = EditorTab(selection: newValue, title: tabTitle(for: newValue))
            tabs.append(tab)
            activeTabID = tab.id
        } else {
            syncActiveTabMetadata(to: newValue)
        }
    }

    public func navigateBack() {
        guard let destination = backStack.popLast() else { return }
        if let current = loadedSelection {
            forwardStack.append(current)
        }
        applyHistorySelection(destination)
    }

    public func navigateForward() {
        guard let destination = forwardStack.popLast() else { return }
        if let current = loadedSelection {
            backStack.append(current)
        }
        trimBackStackIfNeeded()
        applyHistorySelection(destination)
    }

    /// True if `title` resolves to an existing page. Drives the in-app preview's
    /// resolved-vs-unresolved `[[wiki-link]]` styling (a missing target renders
    /// dimmed + inert). Duplicate titles resolve to the lowest-ULID page, same as
    /// the link graph (`replaceLinks`).
    public func pageExists(title: String) -> Bool {
        (try? store.resolveTitleToID(title)) != nil
    }

    /// Navigate to the page with `title` from a clicked `[[wiki-link]]` in the
    /// preview. Resolves title → id (lowest-ULID on a duplicate-title collision,
    /// matching the link graph) and opens its tab — REUSING an already-open tab
    /// for that page rather than spawning a duplicate. Records the jump in
    /// navigation history first (so back/forward works), then routes through
    /// `openTab`, whose `setActiveTab` flushes the outgoing page's pending edits
    /// before loading the target (§3.5). Returns whether navigation happened, so
    /// the click handler can report `.handled`. A no-op (`false`) if the title has
    /// no page.
    ///
    /// - Parameter anchor: optional `#fragment` from a `[[Page#Section]]` link;
    ///   the destination `WikiReaderView` scrolls to it after load.
    @discardableResult
    public func selectPage(byTitle title: String, anchor: String? = nil) -> Bool {
        guard let id = (try? store.resolveTitleToID(title)) ?? nil else { return false }
        let target = WikiSelection.page(id)
        // Stash the anchor so the destination WikiReaderView can scroll to it
        // after render. Tagged with the target selection so a stale anchor can't
        // misfire on the wrong page.
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        pendingScrollAnchorVersion += 1
        // Record history while `loadedSelection` still points at the outgoing
        // page (openTab/setActiveTab don't record history themselves).
        recordHistoryTransition(from: loadedSelection, to: target)
        openTab(target)
        return true
    }

    // MARK: - Source link resolution

    /// Existence check for `[[source:…]]` linkification: returns `true` when a
    /// source with the given display name (or filename fallback) exists.
    public func sourceExists(displayName: String) -> Bool {
        (try? store.resolveSourceByName(displayName)) != nil
    }

    /// Semantic search for pages matching `query` (sqlite-vec + NLEmbedding, with
    /// a `LIKE` fallback). Powers the right-click link context menu's "Suggest…"
    /// (missing links) and "Find Similar…" (any wiki link). Best-effort: returns
    /// `[]` on any error so the menu never throws.
    public func searchSimilar(query: String, limit: Int = 8) -> [WikiPageSummary] {
        (try? store.searchSimilar(query: query, limit: limit)) ?? []
    }

    /// Resolve a page title to its id (lowest-ULID on a duplicate-title
    /// collision, matching the link graph). Best-effort: `nil` on any error or
    /// when no page matches. Used by "Copy File Path" to build the mount path.
    public func pageID(forTitle title: String) -> PageID? {
        do { return try store.resolveTitleToID(title) } catch { return nil }
    }

    /// Resolve a source display name (or filename fallback) to its id
    /// (most-recently-updated on collision). Best-effort: `nil` on any error or
    /// no match. Used by "Copy File Path" to build the source's mount path.
    public func sourceID(forDisplayName displayName: String) -> PageID? {
        do { return try store.resolveSourceByName(displayName) } catch { return nil }
    }

    /// Navigate to the source with `displayName` from a clicked
    /// `[[source:display-name]]` link in the preview. Resolves display name → id
    /// (most-recently-updated on collision), records navigation history, and opens
    /// the source's tab. Returns whether navigation happened.
    ///
    /// - Parameter anchor: optional `#fragment` from a `[[source:Name#"quote"]]`
    ///   link; the destination `WikiReaderView` scrolls to it after load.
    @discardableResult
    public func selectSource(byDisplayName displayName: String, anchor: String? = nil) -> Bool {
        guard let id = (try? store.resolveSourceByName(displayName)) ?? nil else { return false }
        let target = WikiSelection.source(id)
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        pendingScrollAnchorVersion += 1
        recordHistoryTransition(from: loadedSelection, to: target)
        openTab(target)
        return true
    }

    /// The pending scroll/highlight target set by `selectPage`/`selectSource` and
    /// consumed by the destination reader's `Coordinator` (see
    /// `WikiReaderView.consumeAndApplyPendingAnchor`). Tagged with the target
    /// `WikiSelection` so a stale anchor can't misfire on the wrong page.
    public private(set) var pendingScrollAnchor: (selection: WikiSelection, fragment: String)?

    /// Monotonic counter bumped each time `pendingScrollAnchor` is assigned. The
    /// reader's `Coordinator` keys its "have I applied this anchor yet?" check off
    /// this value (not off view `@State`), so re-clicking a quote link to an
    /// already-open document re-fires scroll + highlight even though the view
    /// itself may be re-created mid-navigation.
    public private(set) var pendingScrollAnchorVersion: Int = 0

    /// Atomically consume the pending scroll anchor if `selection` matches.
    /// Returns the fragment to resolve and clears the anchor; nil if the
    /// selection doesn't match or there is no pending anchor. Only the reader
    /// `Coordinator` consumes — and only once the page has painted (see
    /// `WikiReaderView.ConsumeAndApplyPendingAnchor`) — so a view that is
    /// discarded before painting never clears an anchor it never applied.
    public func consumePendingScrollAnchor(for selection: WikiSelection?) -> String? {
        guard let pending = pendingScrollAnchor,
              let sel = selection,
              pending.selection == sel else { return nil }
        pendingScrollAnchor = nil
        return pending.fragment
    }

    // MARK: - Tab operations

    /// The single seam every tab switch routes through: flush the outgoing tab's
    /// drafts, set the active ID, mirror the tab's selection into `selection`, and
    /// load the incoming drafts — all under one re-entrancy guard so the view's
    /// `onChange(of: selection)` bridge no-ops while the switch is mid-flight.
    /// Pass `nil` to enter the empty state.
    private func setActiveTab(_ id: UUID?) {
        flushPendingSaves()
        isApplyingTabSelection = true
        activeTabID = id
        let sel = tabs.first { $0.id == id }?.selection
        selection = sel
        loadDrafts(for: sel)
        isApplyingTabSelection = false
    }

    /// Keep the active tab's metadata in sync with an in-tab navigation (sidebar
    /// single-click within the active tab, `[[wiki-link]]` click, history). A
    /// no-op in the empty state or when `newValue` is `nil`.
    private func syncActiveTabMetadata(to newValue: WikiSelection?) {
        guard let activeID = activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeID }),
              let newValue else { return }
        tabs[i].selection = newValue
        tabs[i].title = tabTitle(for: newValue)
    }

    /// Open the tab for `selection`: if one is already open, focus it (reuse,
    /// never duplicate); otherwise create a new tab and focus it. This holds for
    /// every selection type — pages and files reuse just like the singletons
    /// (.query, .systemPrompt, .changeLog) — so clicking a page or a
    /// `[[wiki-link]]` that's already open returns to its tab instead of spawning
    /// a copy.
    public func openTab(_ selection: WikiSelection, title: String? = nil) {
        if let existing = tabs.first(where: { $0.selection == selection }) {
            DebugLog.store("[tabs] openTab: focus existing tab for \(selection) (id=\(existing.id))")
            setActiveTab(existing.id)
            return
        }
        let tab = EditorTab(selection: selection, title: title ?? tabTitle(for: selection))
        tabs.append(tab)
        DebugLog.store("[tabs] openTab: new tab for \(selection) (id=\(tab.id)), \(tabs.count) tabs total")
        setActiveTab(tab.id)
    }

    /// Switch the active tab by ID. No-op if the ID is unknown or already active.
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }), id != activeTabID else { return }
        setActiveTab(id)
    }

    /// Close one tab by ID. Preserves it in `recentlyClosedTabs` for Cmd+Shift+T.
    /// If the closed tab was active, activates the tab now at the same position
    /// (right neighbor), or the last tab. Closing the final tab → empty state.
    /// Closing a non-active tab leaves the active tab untouched.
    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)
        pushRecentlyClosed(closed)
        if tabs.isEmpty {
            setActiveTab(nil)
        } else if closed.id == activeTabID {
            let neighborIndex = min(index, tabs.count - 1)
            setActiveTab(tabs[neighborIndex].id)
        }
        // else: active tab unchanged (it wasn't the closed one).
    }

    /// Close every tab except the one with `id`, which becomes active.
    public func closeOtherTabs(id: UUID) {
        guard let kept = tabs.first(where: { $0.id == id }) else { return }
        let toClose = tabs.filter { $0.id != id }
        guard !toClose.isEmpty else { return }
        toClose.reversed().forEach { pushRecentlyClosed($0) }
        tabs = [kept]
        setActiveTab(kept.id)
    }

    /// Close every tab to the right of `id`. The anchor and tabs to its left
    /// remain. If the active tab was among those closed, activates the anchor.
    public func closeTabsAfter(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let toClose = Array(tabs.dropFirst(index + 1))
        guard !toClose.isEmpty else { return }
        toClose.reversed().forEach { pushRecentlyClosed($0) }
        tabs = Array(tabs.prefix(index + 1))
        if let active = activeTabID, !tabs.contains(where: { $0.id == active }) {
            setActiveTab(tabs[index].id)
        }
    }

    /// Close all tabs and enter the empty state.
    public func closeAllTabs() {
        guard !tabs.isEmpty else { return }
        tabs.reversed().forEach { pushRecentlyClosed($0) }
        tabs = []
        setActiveTab(nil)
    }

    /// Reopen the last closed tab.
    public func reopenLastClosedTab() {
        guard let lastClosed = recentlyClosedTabs.popLast() else { return }
        openTab(lastClosed.selection, title: lastClosed.title)
    }

    /// Push a closed tab onto the reopen stack, capping at `maxRecentlyClosedTabs`.
    private func pushRecentlyClosed(_ tab: EditorTab) {
        recentlyClosedTabs.append(tab)
        if recentlyClosedTabs.count > Self.maxRecentlyClosedTabs {
            recentlyClosedTabs.removeFirst()
        }
    }

    /// Create a new page and open it in a new tab.
    public func newPageInNewTab(title: String = "Untitled") {
        flushPendingSaves()
        do {
            let page = try store.createPage(title: title)
            try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(page.bodyMarkdown))
            reloadSummaries()
            openTab(.page(page.id), title: title)
            onPageDidChange?()
        } catch {
            DebugLog.store("WikiStoreModel.newPageInNewTab failed: \(error)")
        }
    }

    private func loadDrafts(for newValue: WikiSelection?) {
        loadedSelection = newValue
        // A page switch invalidates the prior page's mermaid warning so a stale
        // banner doesn't bleed onto an unrelated page (it's recomputed on save).
        mermaidSaveWarning = nil
        switch newValue {
        case .query, .lint:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
        case .page(let id):
            guard let page = try? store.getPage(id: id) else {
                draftTitle = ""
                draftBody = ""
                loadedPage = nil
                loadedSelection = nil
                return
            }
            draftTitle = page.title
            draftBody = page.bodyMarkdown
            loadedPage = id
        case .systemPrompt:
            draftSystemPrompt = (try? store.getSystemPrompt())?.body ?? SystemPrompt.defaultBody
            loadedPage = nil
        case .changeLog:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
        case .source:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
        case nil:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
        }
        isDraftDirty = false
        isSystemPromptDirty = false
    }

    private func recordHistoryTransition(from oldValue: WikiSelection?, to newValue: WikiSelection?) {
        guard !isApplyingHistorySelection, oldValue != newValue else { return }
        if let oldValue {
            backStack.append(oldValue)
            trimBackStackIfNeeded()
        }
        forwardStack.removeAll()
    }

    private func applyHistorySelection(_ newValue: WikiSelection) {
        guard newValue != selection else { return }
        flushPendingSaves()
        isApplyingHistorySelection = true
        selection = newValue
        loadDrafts(for: newValue)
        isApplyingHistorySelection = false
        // Update the active tab's metadata so the tab bar stays in sync.
        syncActiveTabMetadata(to: newValue)
    }

    private func trimBackStackIfNeeded() {
        let overflow = backStack.count - Self.navigationHistoryLimit
        if overflow > 0 {
            backStack.removeFirst(overflow)
        }
    }

    private func removeFromHistory(_ value: WikiSelection) {
        backStack.removeAll { $0 == value }
        forwardStack.removeAll { $0 == value }
    }

    // MARK: - Editing / autosave

    /// Called on each keystroke in the title or body. Cancels and restarts a
    /// 500ms debounce; when it fires it reads the live drafts and saves.
    public func bodyChanged() { isDraftDirty = true; scheduleAutosave() }
    public func titleChanged() { isDraftDirty = true; scheduleAutosave() }

    private func scheduleAutosave() {
        // Paused while an agent runs (decision #6): an in-app autosave must never
        // clobber the agent's concurrent `wikictl` writes.
        guard !isAgentRunning else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Persist the current drafts. Reads `loadedPage` (the page the drafts
    /// belong to) + `draftTitle` + `draftBody` AT CALL TIME (§3.5 live read) so
    /// a debounce that fires after further typing — or a flush triggered once
    /// `selection` has already advanced to the next page — still writes the
    /// freshest text to the RIGHT page. No-op when nothing is loaded.
    /// Always rebuilds `summaries` from source on success.
    public func save() {
        guard let id = loadedPage else { return }
        do {
            // The shared upsert+reparse seam (Phase A): persist the body AND
            // re-resolve this page's `[[wiki-links]]` in one operation. `wikictl`
            // calls the SAME `PageUpsert.upsert`, so an in-app edit and a CLI
            // edit leave byte-identical `page_links` rows (no drift). v0
            // limitation: a *rename* does NOT re-walk the whole graph, so links
            // that targeted the old title go stale until the linking page is next
            // saved (they self-heal then).
            try PageUpsert.upsert(in: store, id: id, title: draftTitle, body: draftBody)
            isDraftDirty = false
            reloadSummaries()
            onPageDidChange?()
            // Non-blocking mermaid lint: the in-app save still succeeds (the
            // editor is the human escape from wikictl's hard block), but a broken
            // diagram is flagged so the author can fix it.
            updateMermaidWarning(for: draftBody)
            // Non-blocking markdown lint: same pattern — save succeeds with the
            // original text, cosmetic issues are flagged as informational.
            updateMarkdownWarning(for: draftBody)
        } catch {
            // Phase 1: log to console; a save-error surface lands later.
            DebugLog.store("WikiStoreModel.save failed: \(error)")
        }
    }

    /// The last mermaid validation warning for the saved draft, or `nil`. Surfaced
    /// in the page editor as a non-blocking hint. Set on save (debounced), so it
    /// refreshes shortly after the author stops typing and re-saves.
    public var mermaidSaveWarning: String?

    /// The Mermaid validator used for the non-blocking save warning. Defaults to
    /// the process-wide bundled validator; injectable (e.g. from a repo bundle)
    /// so the warning path is testable without a bundle. `@ObservationIgnored` —
    /// it's plumbing, not UI state.
    @ObservationIgnored var mermaidValidator: MermaidValidator? = MermaidValidator.shared

    /// Validate ```mermaid blocks in `body` and set `mermaidSaveWarning`. Uses
    /// the extractor as the source of truth (so it agrees with `wikictl`'s
    /// hard block on `~~~mermaid`/any case, not just ```mermaid). Non-mermaid
    /// pages pay only a cheap line scan.
    private func updateMermaidWarning(for body: String) {
        guard let validator = mermaidValidator else {
            mermaidSaveWarning = nil
            return
        }
        let bad = validator.invalidBlocks(markdown: body)
        mermaidSaveWarning = bad.isEmpty ? nil : MermaidValidator.describe(bad)
    }

    /// The last markdown lint warning for the saved draft, or `nil`. Surfaced in
    /// the page editor as a non-blocking informational hint (the save still
    /// succeeds with the original text — the editor is the human escape hatch).
    public var markdownSaveWarning: String?

    /// The Markdown linter used for the non-blocking save warning. Defaults to the
    /// process-wide bundled linter; injectable so the warning path is testable
    /// without a bundle. `@ObservationIgnored` — it's plumbing, not UI state.
    @ObservationIgnored var markdownLinter: MarkdownLinter? = MarkdownLinter.shared

    /// The in-flight markdown warning Task (if any). Cancelled before starting a
    /// new one, so rapid re-saves don't complete out of order and leave a stale
    /// `markdownSaveWarning` that doesn't match the just-saved body.
    @ObservationIgnored private var markdownWarningTask: Task<Void, Never>?

    /// Lint `body` for cosmetic markdown issues and set `markdownSaveWarning`.
    /// Unlike the mermaid scan (a cheap fence line-scan), markdownlint runs all
    /// ~20 cosmetic rules over the whole body — so the computation runs on a
    /// background `Task` (the linter's `NSLock` makes it thread-safe) and the
    /// result is set via a `@MainActor` hop to avoid UI jank on large pages.
    /// Non-blocking: the save already succeeded with the original text.
    private func updateMarkdownWarning(for body: String) {
        guard let linter = markdownLinter else {
            markdownWarningTask?.cancel()
            markdownWarningTask = nil
            markdownSaveWarning = nil
            return
        }
        markdownWarningTask?.cancel()
        markdownWarningTask = Task.detached { [linter, weak self] in
            let findings = linter.lint(markdown: body)
            // Bail if a newer save superseded this task.
            guard !Task.isCancelled else { return }
            let warning = findings.isEmpty ? nil : MarkdownLinter.describe(findings)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.markdownSaveWarning = warning
            }
        }
    }

    /// Cancel any pending debounce and save synchronously. Called on page
    /// switch and on app backgrounding (§3.5 immediate-on-background).
    /// No-op when the draft hasn't been modified since the last load/save
    /// (prevents bumping `updated_at` on a tab switch for a view-only page).
    public func flushPendingSave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDraftDirty else { return }
        save()
    }

    // MARK: - System prompt editing (singleton document)

    /// Called on each keystroke in the system-prompt editor; debounced like the
    /// page editor (separate task so the two tracks don't cancel each other).
    public func systemPromptChanged() {
        // Paused while an agent runs (decision #6), same as the page autosave.
        guard !isAgentRunning else { return }
        isSystemPromptDirty = true
        systemPromptAutosaveTask?.cancel()
        systemPromptAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveSystemPrompt()
        }
    }

    /// Persist the system-prompt draft. Guarded on `loadedSelection` so a flush
    /// triggered once selection has moved off the prompt doesn't clobber it with
    /// stale text (mirrors `save()`'s `loadedPage` guard). No-op when the draft
    /// hasn't been modified (prevents bumping the row version on a tab switch
    /// when the user only viewed the Instructions page).
    public func saveSystemPrompt() {
        guard loadedSelection == .systemPrompt else { return }
        do {
            try store.updateSystemPrompt(body: draftSystemPrompt)
            isSystemPromptDirty = false
            onPageDidChange?()
        } catch {
            DebugLog.store("WikiStoreModel.saveSystemPrompt failed: \(error)")
        }
    }

    /// Cancel the system-prompt debounce and save synchronously.
    /// No-op when the draft hasn't been modified (prevents bumping the row
    /// version on a tab switch when the user only viewed the Instructions page).
    public func flushPendingSystemPromptSave() {
        systemPromptAutosaveTask?.cancel()
        systemPromptAutosaveTask = nil
        guard isSystemPromptDirty else { return }
        saveSystemPrompt()
    }

    /// Flush BOTH editing tracks. Used on selection switch and app backgrounding
    /// so neither a page edit nor a system-prompt edit is lost.
    public func flushPendingSaves() {
        flushPendingSave()
        flushPendingSystemPromptSave()
    }

    // MARK: - Agent run lock (Phase C, decision #6)

    /// The SINGLE mutation point for `isAgentRunning`. Every public entry point
    /// below routes through here so the lock invariant lives in exactly one place:
    /// pending drafts are flushed on ACQUIRE (so an in-flight edit isn't lost to a
    /// concurrent agent write), and the `reload` flag governs the from-source
    /// rebuild on RELEASE. The full session teardown (`endAgentRun`) reloads so the
    /// sidebar reflects the agent's writes; the per-turn release
    /// (`setAgentRunning(false)`) does not, because the session is still alive and
    /// `endAgentRun()` will do the full reload when it actually ends.
    private func mutateAgentRunning(_ running: Bool, reload: Bool) {
        if running {
            flushPendingSaves()
        }
        isAgentRunning = running
        if reload {
            reloadFromStore()
            loadDrafts(for: loadedSelection)
        }
    }

    /// Enter the edit-locked state for the duration of a `claude -p` run: flush any
    /// pending edits FIRST (so nothing in-flight is lost), then mark the model
    /// running so the editor goes read-only and autosave is paused. Pausing
    /// autosave is what prevents the in-app save from clobbering the agent's
    /// `wikictl` writes. The live change-bridge `reloadFromStore()` is unaffected —
    /// the sidebar still fills in as the agent's writes land.
    public func beginAgentRun() {
        mutateAgentRunning(true, reload: false)
    }

    /// Exit the edit-locked state (from the spawn's `terminationHandler`, so a
    /// killed agent still re-enables editing). Rebuilds the lists from the store so
    /// the sidebar reflects everything the agent wrote, and reloads the open
    /// document's draft from the (possibly agent-rewritten) source.
    public func endAgentRun() {
        mutateAgentRunning(false, reload: true)
    }

    /// Lightweight toggle for per-turn query edit-lock: flush on acquire, no
    /// reload on release (the session is still alive; `endAgentRun()` handles the
    /// full reload when the session actually ends).
    public func setAgentRunning(_ running: Bool) {
        mutateAgentRunning(running, reload: false)
    }

    // MARK: - Mutations

    public func newPage(title: String = "Untitled") {
        flushPendingSaves()
        do {
            let page = try store.createPage(title: title)
            // A fresh page has an empty body, so this resolves to no links — but
            // run it for uniformity with the save() path (and so a future
            // create-with-body wouldn't silently skip link indexing).
            try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(page.bodyMarkdown))
            reloadSummaries()
            let newSelection = WikiSelection.page(page.id)
            recordHistoryTransition(from: loadedSelection, to: newSelection)
            openTab(newSelection, title: title)
            onPageDidChange?()
        } catch {
            DebugLog.store("WikiStoreModel.newPage failed: \(error)")
        }
    }

    public func rename(_ id: PageID, to newTitle: String) {
        // Persist any pending edits to whatever's open first, then rename.
        flushPendingSave()
        do {
            let page = try store.getPage(id: id)
            try store.updatePage(id: id, title: newTitle, body: page.bodyMarkdown)
            reloadSummaries()
            if selection == .page(id) { draftTitle = newTitle }
            // Update any tab showing this renamed page.
            for i in tabs.indices where tabs[i].selection == .page(id) {
                tabs[i].title = newTitle
            }
            onPageDidChange?()
        } catch {
            DebugLog.store("WikiStoreModel.rename failed: \(error)")
        }
    }

    /// Rename a source's display name. Rewrites `[[source:<old>…]]` links in
    /// every page that references it (fragment + alias preserved), then refreshes
    /// the sidebar, open tabs, and File Provider mount.
    public func renameSource(id: PageID, to newDisplayName: String) {
        do {
            try store.renameSource(id: id, to: newDisplayName)
            reloadSummaries()
            for i in tabs.indices where tabs[i].selection == .source(id) {
                tabs[i].title = newDisplayName
            }
            onPageDidChange?()
        } catch {
            DebugLog.store("WikiStoreModel.renameSource failed: \(error)")
        }
    }

    public func delete(_ id: PageID) {
        do {
            try store.deletePage(id: id)
            removeFromHistory(.page(id))
            // Close any tab showing this deleted page.
            if let tab = tabs.first(where: { $0.selection == .page(id) }) {
                closeTab(id: tab.id)
            }
            reloadSummaries()
            onPageDidChange?()
        } catch {
            DebugLog.store("WikiStoreModel.delete failed: \(error)")
        }
    }

    // MARK: - File ingestion (Phase 5)

    /// Ingest dropped files. For each URL: reject directories (a recursive
    /// directory ingest is out of scope), read the bytes OFF the main thread
    /// (big files shouldn't stall the UI), then hop back to the main actor to
    /// store + reload. Per-file failures are logged and skipped so one bad drop
    /// doesn't abort the batch. `onPageDidChange?()` fires ONCE at the end so the
    /// daemon re-enumerates the `sources/` tree exactly once for the whole batch.
    public func ingest(fileURLs: [URL]) async {
        var lastSourceID: PageID?
        for url in fileURLs {
            // Skip directories — only flat files are ingested.
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                DebugLog.store("WikiStoreModel.ingest skipping directory: \(url.lastPathComponent)")
                continue
            }
            let filename = url.lastPathComponent
            let data: Data
            do {
                // Read off the main actor; `Data(contentsOf:)` is blocking I/O.
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
            } catch {
                DebugLog.store("WikiStoreModel.ingest read failed for \(filename): \(error)")
                continue
            }
            do {
                let summary = try store.addSource(
                    filename: filename, data: data, zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil)
                lastSourceID = summary.id
            } catch {
                DebugLog.store("WikiStoreModel.ingest store failed for \(filename): \(error)")
            }
        }
        reloadSources()
        if let sourceID = lastSourceID {
            openTab(.source(sourceID))
            onPageDidChange?()
        }
    }

    /// Ingest a resource by URL: fetch it, convert HTML→Markdown (or store a PDF /
    /// text / binary verbatim), and land it as an ingested file — exactly like a
    /// drag-dropped file, so the existing "Ingest into wiki" `claude -p` operation
    /// can summarize it afterward. Lands through the SAME `store.ingestFile` path as
    /// drag-ingest, so it appears under Sources + `sources/by-{id,name}` immediately and
    /// is pickable in Operations → Ingest. Returns the outcome on success; throws a
    /// user-readable `URLIngestService.IngestError` on a bad URL, non-2xx, empty
    /// body, or store failure (the caller surfaces it in the sheet). The store write
    /// hops to the main actor (this type is `@MainActor`); the fetch runs off it.
    @discardableResult
    public func ingestURL(
        _ rawInput: String,
        fetcher: any URLIngestService.URLResourceFetcher = URLSessionFetcher()
    ) async throws -> URLIngestService.IngestOutcome {
        // Validate + fetch OFF the main actor (the GET shouldn't stall the UI);
        // `fetch` is `Sendable` and the service is stateless. Then store the result
        // back HERE on the main actor, where we own `store`. Splitting fetch (async,
        // off-actor) from store (main-actor) keeps the @Sendable boundary honest —
        // no `assumeIsolated` gamble on which thread a continuation resumes.
        guard let url = URLIngestService.normalizeURL(rawInput) else {
            throw URLIngestService.IngestError.invalidURL(
                rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let response = try await fetcher.fetch(url)
        guard !response.data.isEmpty else { throw URLIngestService.IngestError.empty }

        // Pure dispatch decides the filename + bytes; we store directly on the main
        // actor (no @Sendable store closure crossing the actor boundary).
        let plan = URLIngestService.plan(for: response)
        let summary = try store.addSource(
            filename: plan.filename, data: plan.data, zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil)
        reloadSources()
        openTab(.source(summary.id))
        onPageDidChange?()
        return URLIngestService.IngestOutcome(
            filename: plan.filename, byteSize: plan.data.count, kind: plan.kind)
    }

    /// Synchronous ingest seam used by tests/verifiers (no drag gesture). Stores
    /// the bytes, rebuilds the list, and signals the daemon.
    public func addSource(filename: String, data: Data) {
        do {
            _ = try store.addSource(
                filename: filename, data: data, zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil)
            reloadSources()
            onPageDidChange?()
        } catch {
            DebugLog.store("WikiStoreModel.addSource failed: \(error)")
        }
    }

    /// Ingest one Zotero attachment by reading its local file and storing the
    /// verbatim bytes — exactly like a drag-dropped file, but threading the
    /// parent item's key + title into the row as provenance so the detail view
    /// can show "From Zotero" and link back. We already know the filename and
    /// bytes from Zotero's metadata, so this goes straight to the
    /// `addSource(filename:data:)` seam rather than `URLIngestService`'s
    /// content-type dispatch (that dispatch exists for the unknown-bytes-from-a-
    /// URL case, which doesn't apply here). No network fallback in v1: an
    /// attachment that isn't synced to `~/Zotero/storage` yet throws
    /// `ZoteroIngestError.unavailable` rather than downloading it.
    public func ingestFromZotero(
        _ attachment: ZoteroAttachment,
        parentItem: ZoteroItem,
        zoteroDir: URL
    ) async throws {
        switch ZoteroLocalStorage.resolve(attachment, zoteroDir: zoteroDir) {
        case .local(let path):
            // Read off the main actor — same rationale as `ingest(fileURLs:)`:
            // `Data(contentsOf:)` is blocking I/O and shouldn't stall the UI.
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: path)
            }.value
            do {
                let summary = try store.addSource(
                    filename: path.lastPathComponent, data: data,
                    zoteroItemKey: parentItem.key, zoteroItemTitle: parentItem.title,
                    mimeType: nil)
                reloadSources()
                openTab(.source(summary.id))
                onPageDidChange?()
            } catch {
                DebugLog.store("WikiStoreModel.ingestFromZotero failed: \(error)")
                throw error
            }
        case .unavailable(let reason):
            throw ZoteroIngestError.unavailable(reason)
        }
    }

    /// Import every `.md` / `.markdown` file in `directory` (recursively) as an
    /// ingested file — a one-shot migration of an Obsidian vault, LogSeq graph, or
    /// any folder of Markdown notes. Hidden files/directories are skipped.
    /// Duplicate filenames get a disambiguating suffix (`Note.md`, `Note-1.md`, …).
    ///
    /// All files land via the shared `store.addSource(filename:data:)` seam —
    /// exactly the same path as drag-drop, URL fetch, and Zotero ingest.
    ///
    /// - Returns: `(imported: count, errors: [localized messages])`.
    public func importFromMarkdownFolder(directory: URL) async -> (imported: Int, errors: [String]) {
        let result = await Task.detached(priority: .userInitiated) {
            MarkdownFolderReader.walk(
                directory: directory,
                fileOps: MarkdownFolderReader.FileManagerFileOperations()
            )
        }.value

        var imported = 0
        var errorMessages: [String] = []

        var firstSourceID: PageID?
        for file in result.files {
            do {
                let summary = try store.addSource(
                    filename: file.filename, data: file.data, zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: nil)
                if firstSourceID == nil { firstSourceID = summary.id }
                imported += 1
            } catch {
                errorMessages.append("\(file.filename): \(error.localizedDescription)")
            }
        }
        for walkError in result.errors {
            errorMessages.append(walkError.errorDescription
                ?? "\(walkError.path): unknown error")
        }

        reloadSources()
        if let sourceID = firstSourceID {
            openTab(.source(sourceID))
        }
        onPageDidChange?()
        return (imported: imported, errors: errorMessages)
    }

    /// Remove an ingested file from the list and the store, then signal so the
    /// `sources/` tree drops it.
    public func deleteSource(_ id: PageID) {
        do {
            try store.deleteSource(id: id)
            removeFromHistory(.source(id))
            // Close any tab showing this deleted file.
            if let tab = tabs.first(where: { $0.selection == .source(id) }) {
                closeTab(id: tab.id)
            }
            reloadSources()
            onPageDidChange?()
        } catch {
            DebugLog.store("WikiStoreModel.deleteSource failed: \(error)")
        }
    }

    /// The current `system_prompt` singleton body from the store (the seeded
    /// default if absent) — the agent run passes this verbatim via
    /// `--append-system-prompt`. Read fresh from the store, not from the draft, so
    /// it reflects the last persisted edit even if the prompt editor isn't open.
    public func currentSystemPromptBody() -> String {
        (try? store.getSystemPrompt())?.body ?? SystemPrompt.defaultBody
    }

    /// A LIVE snapshot of THIS wiki's current state — page titles, the `index.md`
    /// body, and a recent-log tail — gathered fresh from the store at agent-run
    /// click time (§3.5 read-state-at-the-latest-moment). Injected into the
    /// operation `-p` prompt's `CURRENT WIKI STATE` block so the agent skips the
    /// orientation turns (`page list`, re-reading `index.md`/`log.md`, pulling a
    /// sample page) it would otherwise spend rediscovering what the app already
    /// knows. Read directly from the store (not the cached `summaries`) so it can't
    /// lag a concurrent external write. All reads are `try?`-guarded so a transient
    /// read failure degrades to an emptier-but-valid snapshot rather than blocking
    /// the run.
    public func currentStateSnapshot() -> WikiStateSnapshot {
        let titles = ((try? store.listPages(sortBy: .lastUpdated)) ?? []).map(\.title)
        let indexBody = (try? store.getWikiIndex())?.body ?? WikiIndex.defaultBody
        let logEntries = (try? store.recentLogEntries(limit: WikiStateSnapshot.maxLogEntries)) ?? []
        // Render each tail entry with the SAME formatter the `log.md` projection
        // uses, so the snapshot lines are byte-identical to what `tail log.md`
        // shows (no second, drifting log format).
        let logLines = logEntries.map { LogRenderer.line(for: $0) }
        return WikiStateSnapshot.make(allTitles: titles, indexBody: indexBody, logLines: logLines)
    }

    /// Render the operation log exactly as the File Provider's `log.md` does, so
    /// the in-app document and filesystem projection show the same query/ingest/
    /// lint history. Bounded generously for UI responsiveness; entries remain in
    /// chronological order so newest activity sits at the bottom.
    public func currentLogMarkdown(limit: Int = 10_000) -> String {
        let entries = (try? store.recentLogEntries(limit: limit)) ?? []
        return LogRenderer.render(entries)
    }

    /// The verbatim bytes of one ingested source, read from SQLite at click time so
    /// the agent run can STAGE it onto reliable local disk (`source.<ext>`) rather
    /// than reading from the ~5s-laggy read-only mount. `nil` if the read fails;
    /// the caller surfaces that as a preflight error instead of launching a run that
    /// would fall back to probing the mount.
    public func sourceBytes(id: PageID) -> Data? {
        try? store.sourceContent(id: id)
    }

    public func isSourceIngested(_ file: SourceSummary) -> Bool {
        sourceIngestedStatus[file.id] ?? false
    }

    // MARK: - Processed markdown versions (v8)

    /// The latest (HEAD) processed markdown version for a file. Every source has a
    /// chain: PDFs are seeded from extraction, markdown-native sources self-seed
    /// v1 from their verbatim bytes (origin `"source"`). After seeding, new
    /// versions are appended by edits (`"user"`) or re-extraction (`"extraction"`).
    public func processedMarkdownHead(for file: SourceSummary) -> SourceMarkdownVersion? {
        if let head = try? store.processedMarkdownHead(sourceID: file.id) {
            return head
        }
        // Seed v1 from verbatim bytes for markdown-native sources (MIME-keyed).
        guard let mime = file.mimeType, mime.hasPrefix("text/") else { return nil }
        guard let bytes = try? store.sourceContent(id: file.id),
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        return try? store.appendProcessedMarkdown(
            sourceID: file.id, content: text, origin: "source", note: nil)
    }

    /// True when at least one processed-markdown version exists for this source.
    public func hasProcessedMarkdown(for sourceID: PageID) -> Bool {
        (try? store.hasProcessedMarkdown(sourceID: sourceID)) ?? false
    }

    /// Save an edit as a new version in the chain. Only called when the text
    /// genuinely differs from the current head — meaningful history, not
    /// keystroke spam.
    @discardableResult
    public func saveProcessedMarkdown(for sourceID: PageID, content: String) -> SourceMarkdownVersion? {
        try? store.appendProcessedMarkdown(
            sourceID: sourceID, content: content, origin: "user", note: nil)
    }

    /// Seed the first processed-markdown version for a PDF from extraction
    /// output. Double-seed guard: if a head already exists, returns it instead.
    @discardableResult
    public func seedPdfMarkdown(for sourceID: PageID, content: String) -> SourceMarkdownVersion? {
        if let head = try? store.processedMarkdownHead(sourceID: sourceID) {
            return head
        }
        return try? store.appendProcessedMarkdown(
            sourceID: sourceID, content: content, origin: "extraction", note: nil)
    }

    // MARK: - Source-of-truth rebuild

    /// Rebuild the sidebar lists from the store — used by the Phase A change
    /// bridge after an EXTERNAL write (a `wikictl` call) lands in this wiki's DB,
    /// so the on-screen sidebar reflects pages/files the CLI wrote. Always a full
    /// rebuild from source, never an incremental patch (§3.1 / §3.2). The active
    /// editing draft is untouched — only the list projections refresh.
    public func reloadFromStore() {
        reloadSummaries()
        reloadSources()
        pruneHistoryToCurrentStore()
    }

    /// Rebuild the sidebar page list from the store using the current sort order.
    /// Public so `SidebarView` can trigger a reload when the sort picker changes
    /// (via the `pageSortOrder` didSet), and so the Phase A change bridge can
    /// refresh after an external write.
    public func reloadSummaries() {
        summaries = (try? store.listPages(sortBy: pageSortOrder)) ?? []
    }

    // MARK: - Search

    /// Recompute embeddings for all pages that are missing one, so semantic
    /// search covers pre‑v7 pages. Returns the count of newly‑embedded pages.
    public func recomputeMissingEmbeddings() -> Int {
        store.recomputeMissingEmbeddings()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard !searchQuery.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let results = (try? self.store.searchSimilar(
                query: self.searchQuery, limit: 20
            )) ?? []
            guard !Task.isCancelled else { return }
            self.searchResults = results
        }
    }

    private func reloadSources() {
        sources = (try? store.listSources()) ?? []
        // Authoritative source: the flag the agent stamps via
        // `wikictl log append --kind ingest --source <id>` on success.
        let markedIDs = (try? store.markedSourceIDs()) ?? []
        // Legacy fallback: wikis ingested before the flag existed only have the
        // free-text log entry, so keep the old best-effort title/path match too.
        let entries = (try? store.recentLogEntries(limit: 10_000)) ?? []
        let ingestTexts = entries
            .filter { $0.kind == .ingest }
            .map { "\($0.title) \($0.note ?? "")".lowercased() }

        sourceIngestedStatus = Dictionary(uniqueKeysWithValues: sources.map { file in
            if markedIDs.contains(file.id.rawValue) {
                return (file.id, true)
            }
            let filename = file.filename.lowercased()
            let byIDLeaf = FilenameEscaping
                .byIDSourceFilename(sourceID: file.id.rawValue, ext: file.ext)
                .lowercased()
            let path = "sources/by-id/\(byIDLeaf)"
            let matchers = [filename, file.id.rawValue.lowercased(), byIDLeaf, path]
                .filter { !$0.isEmpty }
            let hasLogEntry = ingestTexts.contains { text in
                matchers.contains { text.contains($0) }
            }
            return (file.id, hasLogEntry)
        })
    }

    private func pruneHistoryToCurrentStore() {
        let pageIDs = Set(summaries.map(\.id))
        let sourceIDs = Set(sources.map(\.id))
        backStack.removeAll { !isAvailableHistorySelection($0, pageIDs: pageIDs, sourceIDs: sourceIDs) }
        forwardStack.removeAll { !isAvailableHistorySelection($0, pageIDs: pageIDs, sourceIDs: sourceIDs) }
    }

    private func isAvailableHistorySelection(
        _ value: WikiSelection,
        pageIDs: Set<PageID>,
        sourceIDs: Set<PageID>
    ) -> Bool {
        switch value {
        case .page(let id):
            pageIDs.contains(id)
        case .source(let id):
            sourceIDs.contains(id)
        case .query, .systemPrompt, .changeLog, .lint:
            true
        }
    }
}

/// Thrown by `WikiStoreModel.ingestFromZotero` when an attachment can't be
/// ingested — currently just the "not synced locally yet" case, since v1 has no
/// network-download fallback (see `ZoteroLocalStorage`).
public enum ZoteroIngestError: LocalizedError, Equatable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}

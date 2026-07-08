import Foundation
import Observation
import UniformTypeIdentifiers

/// Progress of the blocking search-index upgrade (see
/// `WikiStoreModel.searchUpgrade`). Shown in a non-dismissible sheet while the
/// upgrade runs; `nil`-ing `searchUpgrade` dismisses it.
public struct SearchUpgradeState: Identifiable {
    public let id = UUID()
    public let total: Int
    public var done: Int
    public var phase: Phase
    public enum Phase { case pages, sources }

    public init(total: Int, done: Int, phase: Phase) {
        self.total = total; self.done = done; self.phase = phase
    }
}

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

    /// Progress of the one-time, blocking search-index upgrade (nil when idle).
    /// When non-nil the app shows a non-dismissible sheet that blocks all UX:
    /// the upgrade is the SOLE owner of the store while it runs (SQLite is never
    /// touched off-main), so there can be no concurrent-statement race. It only
    /// runs when MiniLM is the selected embedder AND there is missing content
    /// (first run, an NLEmbedding→MiniLM cutover, or `wikictl`-written content);
    /// the common launch is an instant no-op and shows nothing.
    /// A user-facing error from a store mutation (e.g. a delete that violated a
    /// foreign-key constraint, or files skipped as duplicates during ingest).
    /// Surfaced via an alert in `ContentView`, titled per-site so a duplicate
    /// skip doesn't read as a failed delete; `nil`-ing it dismisses the alert.
    public struct StoreError: Identifiable {
        public let id = UUID()
        public let title: String
        public let message: String
    }
    public private(set) var storeError: StoreError?

    public private(set) var searchUpgrade: SearchUpgradeState?
    /// Synchronous single-flight guard for ``upgradeSearchIndex``. Set BEFORE any
    /// `await` (unlike `searchUpgrade`, which is only set after `configure()`),
    /// so a second trigger that fires during the configure() suspension window
    /// sees it true and bails. The check-and-set is main-actor and contains no
    /// suspension, so it is atomic against the scenePhase/activeWikiID hooks.
    @ObservationIgnored private var isUpgrading = false
    @ObservationIgnored private var didReconcileLinks = false

    /// Live SOURCES search query from the Sources search bar. Debounced 300ms.
    /// Mirrors the page `searchQuery` (semantic cosine, LIKE fallback).
    public var sourceSearchQuery: String = "" {
        didSet { scheduleSourceSearch() }
    }
    /// Results of the last sources search (empty when sourceSearchQuery is empty).
    public private(set) var sourceSearchResults: [SourceSummary] = []
    @ObservationIgnored private var sourceSearchTask: Task<Void, Never>?

    /// Memoized `WikiRenderContext` (Phase A.1, D1). Lazily rebuilt; invalidated
    /// by bumping ``renderContextGeneration`` whenever pages or sources change.
    /// Per-delta renders therefore reuse the snapshot and never touch SQLite.
    /// `@ObservationIgnored` — the context is consumed off-main by detached
    /// render tasks, not observed by SwiftUI.
    @ObservationIgnored private var cachedRenderContext: WikiRenderContext?
    /// Bumped by `reloadSummaries()` / `reloadSources()` (every page/source
    /// mutation, local AND external — `reloadFromStore()` calls both). A change
    /// here means the next `renderContext()` call rebuilds the snapshot. This is
    /// the `WikiEventBus`-driven invalidation the plan calls for: local writes
    /// self-manage through these reloads (slice 2a), and `.external` bus events
    /// route through `reloadFromStore()` → the same reloads. Either way the
    /// generation bumps.
    @ObservationIgnored private var renderContextGeneration: UInt64 = 0
    /// The snapshot captured at ``cachedRenderContext`` build time, so a reload
    /// that leaves the generation unchanged (e.g. a bookmark-only change) doesn't
    /// spuriously rebuild. Compared against ``renderContextGeneration``.
    @ObservationIgnored private var renderContextBuiltAtGeneration: UInt64 = .max

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
    /// Non-nil when a tab close was deferred because the tab is in edit mode.
    /// The view shows a confirmation alert, then calls `confirmCloseTab()` or
    /// `cancelCloseTab()`.
    public private(set) var pendingCloseTabID: UUID? = nil

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

    // MARK: - Bookmark nodes (v16 — Bookmarks sidebar tree)

    /// Flat bookmark nodes, rebuilt from store after mutation (§3.1 pattern).
    public private(set) var bookmarkNodes: [BookmarkNode] = []

    /// Persisted chat summaries (issue #119), most-recently-updated first —
    /// rebuilt from `store.listChats()` after every mutation (§3.1 pattern),
    /// like `bookmarkNodes`.
    public private(set) var chats: [ChatSummary] = []

    /// Rebuild `chats` from the store. Best-effort (`try?`) — the history list
    /// degrading to empty on a store hiccup must never crash the sidebar.
    public func reloadChats() {
        chats = (try? store.listChats()) ?? []
    }

    /// Computed tree for the Bookmarks section.
    public var bookmarkTree: [BookmarkTreeItem] {
        let t0 = DispatchTime.now()
        let tree = buildBookmarkTree(nodes: bookmarkNodes)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        if ms > 5 {
            DebugLog.tabs("bookmarkTree: built in \(String(format: "%.1f", ms)) ms (\(bookmarkNodes.count) nodes)")
        }
        return tree
    }

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
    /// Read-only snapshot connections for OFF-MAIN reads (debounced search).
    /// Injected by `WikiManager.openActive` for file-backed wikis; `nil` for
    /// in-memory stores (a separate connection to `:memory:` would see a
    /// different, empty database) and in tests — callers fall back to the
    /// main-actor store. See `WikiReadPool` for the safety argument.
    @ObservationIgnored public var readPool: WikiReadPool?
    private var autosaveTask: Task<Void, Never>?
    private var systemPromptAutosaveTask: Task<Void, Never>?
    /// The page whose text currently lives in the draft buffers.
    private var loadedPage: PageID?
    /// What the drafts currently hold, so a flush saves the RIGHT document even
    /// after `selection` has advanced (§3.5 read-state-at-save-time).
    private var loadedSelection: WikiSelection?
    private var isApplyingHistorySelection = false
    /// Debug timing: when the latest user-initiated navigation began (set in
    /// `openTab`). The reader's `Coordinator` reads this to log the synchronous
    /// click→startLoad window and the full click→painted latency. `internal` so
    /// the app module can read it; `nil` until the first navigation.
    public var clickStartedAt: DispatchTime?
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
        reloadBookmarkNodes()
        reloadChats()
        // Preload the system-prompt draft so its editor has content immediately;
        // selecting it later reloads fresh from the store.
        draftSystemPrompt = (try? store.getSystemPrompt())?.body ?? SystemPrompt.defaultBody
        subscribeToChanges()
    }

    /// The per-wiki resource-change bus of the backing store (exposed so the app
    /// layer — the File Provider signaler and the change bridge — can subscribe
    /// to the same mechanism the store emits into).
    public var eventBus: WikiEventBus? { store.eventBus }

    /// Subscribe to the store's bus for **all** changes — both in-app writes
    /// (the model's own saves, agent runs) and cross-process writes (`wikictl`
    /// surfaced by the Darwin-notification bridge) — and rebuild the list
    /// projections via `reloadFromStore()`. Phase E: the model is a pure
    /// reload subscriber; the per-call `reload*()` sites are removed and the
    /// `origin` field is gone. The reload only refreshes list projections
    /// (sidebar, sources, chats, bookmarks) — it never touches the editor
    /// draft or selection, so there is no focus/flicker risk.
    @ObservationIgnored private var changeToken: SubscriptionToken?
    private func subscribeToChanges() {
        changeToken = store.eventBus?.subscribe(nil) { [weak self] _ in
            self?.reloadFromStore()
        }
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
    /// matching the link graph) and records the jump in navigation history first
    /// (so back/forward works). Returns whether navigation happened, so the click
    /// handler can report `.handled`. A no-op (`false`) if the title has no page.
    ///
    /// Navigation target depends on the click's modifier (browser convention):
    /// - **Plain click** (`openInNewTab: false`, the default) → navigate the
    ///   active tab in place (`navigateCurrentTab`): focus an already-open tab
    ///   for the target if one exists, otherwise replace the active tab's
    ///   selection. Never spawns a duplicate tab.
    /// - **⌘-click** (`openInNewTab: true`) → `openTab`, which focuses an
    ///   existing tab for the target or appends a new one (current behavior).
    ///
    /// - Parameter anchor: optional `#fragment` from a `[[Page#Section]]` link;
    ///   the destination `WikiReaderView` scrolls to it after load.
    @discardableResult
    public func selectPage(byTitle title: String, anchor: String? = nil, openInNewTab: Bool = false) -> Bool {
        guard let id = (try? store.resolveTitleToID(title)) ?? nil else { return false }
        let target = WikiSelection.page(id)
        // Stash the anchor so the destination WikiReaderView can scroll to it
        // after render. Tagged with the target selection so a stale anchor can't
        // misfire on the wrong page.
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        pendingScrollAnchorVersion += 1
        // Record history while `loadedSelection` still points at the outgoing
        // page (openTab/setActiveTab/navigateCurrentTab don't record history
        // themselves).
        recordHistoryTransition(from: loadedSelection, to: target)
        if openInNewTab {
            openTab(target)
        } else {
            navigateCurrentTab(to: target)
        }
        return true
    }

    /// Navigate to the page with `id` from a clicked canonical
    /// `wiki://page?id=<ULID>` link (Phase 5). A direct selection — no title
    /// resolution, so it is stable across renames (the §6.5 click-time row
    /// fetch). Returns `false` when the id names no loaded page (a deleted
    /// target), so the caller can fall back to title-based selection.
    @discardableResult
    public func selectPage(byID id: PageID, anchor: String? = nil, openInNewTab: Bool = false) -> Bool {
        guard summaries.contains(where: { $0.id == id }) else { return false }
        let target = WikiSelection.page(id)
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        pendingScrollAnchorVersion += 1
        recordHistoryTransition(from: loadedSelection, to: target)
        if openInNewTab {
            openTab(target)
        } else {
            navigateCurrentTab(to: target)
        }
        return true
    }

    // MARK: - Source link resolution

    /// Existence check for `[[source:…]]` linkification: returns `true` when a
    /// source with the given display name (or filename fallback) exists.
    public func sourceExists(displayName: String) -> Bool {
        (try? store.resolveSourceByName(displayName)) != nil
    }

    /// `(bytes, mimeType)` for the blob scheme handler (`wiki-blob://`). `nil` =
    /// unknown id (→ 404); empty `Data` = byteless source (→ 200 empty body);
    /// else the blob bytes + MIME. Used by `BlobSchemeHandler` to serve source
    /// content to the WKWebView for `![[source:…]]` embeds. Looks up the MIME
    /// type from the loaded `sources` list (which mirrors `store.listSources()`)
    /// rather than calling the store directly, since `getSource(id:)` is concrete
    /// on `SQLiteWikiStore`, not on the `WikiStore` protocol.
    @MainActor public func sourceContentAndMIME(id: PageID) -> (data: Data, mimeType: String?)? {
        guard let summary = sources.first(where: { $0.id == id }) else { return nil }
        let data = (try? store.sourceContent(id: id)) ?? Data()
        return (data, summary.mimeType)
    }

    /// Semantic search for pages matching `query`. Delegates to the store's
    /// hybrid search (FTS5 bm25 always; +MiniLM cosine fused via RRF when the
    /// model is available). Runs the query embedding + SQLite on the main actor
    /// — fine for the one-shot callers (the "Find Similar…" link menu builds its
    /// submenu once per right-click, not per render). The old per-row sidebar
    /// caller that froze the UI was removed; MiniLM inference is now ms, not the
    /// ~5 s/100k chars NLEmbedding cliff that motivated disabling this.
    public func searchSimilar(query: String, limit: Int = 8) -> [WikiPageSummary] {
        (try? store.searchSimilar(query: query, limit: limit)) ?? []
    }

    /// Semantic source search wrapper — same hybrid store search as
    /// `searchSimilar`, over sources.
    public func searchSimilarSources(query: String, limit: Int = 20) -> [SourceSummary] {
        (try? store.searchSimilarSources(query: query, limit: limit)) ?? []
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
    /// (most-recently-updated on collision) and records navigation history. A
    /// plain click (`openInNewTab: false`) navigates the active tab in place
    /// (`navigateCurrentTab`); a ⌘-click (`openInNewTab: true`) opens a new tab
    /// via `openTab`. Returns whether navigation happened.
    ///
    /// - Parameter anchor: optional `#fragment` from a `[[source:Name#"quote"]]`
    ///   link; the destination `WikiReaderView` scrolls to it after load.
    @discardableResult
    public func selectSource(byDisplayName displayName: String, anchor: String? = nil, openInNewTab: Bool = false) -> Bool {
        guard let id = (try? store.resolveSourceByName(displayName)) ?? nil else { return false }
        let target = WikiSelection.source(id)
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        pendingScrollAnchorVersion += 1
        recordHistoryTransition(from: loadedSelection, to: target)
        if openInNewTab {
            openTab(target)
        } else {
            navigateCurrentTab(to: target)
        }
        return true
    }

    /// Navigate to the source with `id` from a clicked canonical
    /// `wiki://source?id=<ULID>` link (Phase 5). A direct selection — no
    /// display-name resolution, so it is stable across renames. Returns `false`
    /// when the id names no loaded source (a deleted target), so the caller can
    /// fall back to display-name-based selection.
    ///
    /// - Parameter pinnedExtractionID: Phase 6 — when non-nil (a pinned quote
    ///   link carrying `&pin=<smvID>`), the destination `SourceDetailView` loads
    ///   *that* extraction so the quote is present in the rendered DOM. Nil
    ///   (no pin, or a non-quote pin) opens HEAD.
    @discardableResult
    public func selectSource(byID id: PageID, anchor: String? = nil,
                             openInNewTab: Bool = false,
                             pinnedExtractionID: PageID? = nil) -> Bool {
        guard sources.contains(where: { $0.id == id }) else { return false }
        let target = WikiSelection.source(id)
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        // Phase 6: stash the pinned-extraction id alongside the anchor (same
        // counter — the pin travels with its anchor). Set-once/consume-once.
        pendingPinnedExtraction = pinnedExtractionID.map { (selection: target, versionID: $0) }
        pendingScrollAnchorVersion += 1
        recordHistoryTransition(from: loadedSelection, to: target)
        if openInNewTab {
            openTab(target)
        } else {
            navigateCurrentTab(to: target)
        }
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

    /// Sets an anchor to scroll to within the currently selected page or source.
    public func jumpToAnchorInCurrentSelection(_ anchor: String) {
        guard let current = selection else { return }
        pendingScrollAnchor = (selection: current, fragment: anchor)
        pendingScrollAnchorVersion += 1
    }

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

    /// Phase 6: the pending pinned-extraction id set by
    /// `selectSource(byID:pinnedExtractionID:)` and consumed by the destination
    /// `SourceDetailView` so it loads the pinned extraction the quote was written
    /// against. Tagged with the target `WikiSelection` and set-once/consume-once
    /// — mirrors `pendingScrollAnchor`.
    public private(set) var pendingPinnedExtraction: (selection: WikiSelection, versionID: PageID)?

    /// Atomically consume the pending pinned-extraction id if `selection`
    /// matches. Returns the smv id once and clears the state; nil if the
    /// selection doesn't match or there is no pending pin. Mirrors
    /// `consumePendingScrollAnchor`.
    public func consumePendingPinnedExtraction(for selection: WikiSelection?) -> PageID? {
        guard let pending = pendingPinnedExtraction,
              let sel = selection,
              pending.selection == sel else { return nil }
        pendingPinnedExtraction = nil
        return pending.versionID
    }

    // MARK: - Sidebar reveal ("Show In List")

    /// The pending "Show In List" reveal target set by a detail view's button
    /// (`requestSidebarReveal(_:)`) and consumed by the sidebar list view once it
    /// has scrolled to + selected the row. Follows the same "set once, consume
    /// once" producer/consumer discipline as `pendingScrollAnchor` (issue #183).
    public private(set) var pendingSidebarReveal: WikiSelection?

    /// Monotonic counter bumped each time `pendingSidebarReveal` is assigned. The
    /// sidebar host (`SidebarView`) and `ContentView` observe it via `.onChange`
    /// so a repeat request for an already-mounted section still fires the switch
    /// / un-collapse / scroll path (the value itself may be identical to the
    /// previous one).
    public private(set) var pendingSidebarRevealVersion: Int = 0

    /// Request that the sidebar reveal `selection` in its list: open the sidebar
    /// if collapsed, switch to the matching section (Pages vs. Sources), clear any
    /// active search that would hide the target, then scroll to + select the row.
    public func requestSidebarReveal(_ selection: WikiSelection) {
        pendingSidebarReveal = selection
        pendingSidebarRevealVersion += 1
    }

    /// Called by the sidebar list view AFTER it has scrolled to + selected the
    /// target row, so the reveal fires exactly once. Clears the pending target.
    public func consumePendingSidebarReveal() {
        pendingSidebarReveal = nil
    }

    // MARK: - Tab operations

    /// The single seam every tab switch routes through: flush the outgoing tab's
    /// drafts, set the active ID, mirror the tab's selection into `selection`, and
    /// load the incoming drafts — all under one re-entrancy guard so the view's
    /// `onChange(of: selection)` bridge no-ops while the switch is mid-flight.
    /// Pass `nil` to enter the empty state.
    private func setActiveTab(_ id: UUID?) {
        // Stash the outgoing tab's draft rather than auto-saving to DB.
        if let outgoingID = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == outgoingID }),
           tabs[i].isEditing {
            tabs[i].pendingDraftTitle = draftTitle
            tabs[i].pendingDraftBody = draftBody
        }
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

    /// Navigate the **active tab in place** to `target` — the plain-click
    /// (`[[wiki-link]]`) path, matching the macOS browser convention where a
    /// plain click navigates the current tab rather than spawning a new one.
    ///
    /// Resolution order (history is recorded by the caller):
    /// 1. A tab for `target` is already open → focus it (reuse, never duplicate),
    ///    via `setActiveTab` (same as `openTab`'s reuse branch).
    /// 2. No active tab (empty state) → fall back to `openTab` so the first tab
    ///    is created and focused.
    /// 3. Otherwise → mutate the active tab's selection/title in place: flush the
    ///    outgoing selection's pending edits (so nothing in-flight is lost — the
    ///    reader is read-only in practice, but this keeps the edit path safe),
    ///    swap the tab's selection, mirror it into `selection`, and reload drafts.
    ///    The `isApplyingTabSelection` guard mirrors `setActiveTab` so the view's
    ///    `onChange(of: selection)` bridge no-ops mid-swap.
    private func navigateCurrentTab(to target: WikiSelection) {
        if let existing = tabs.first(where: { $0.selection == target }) {
            setActiveTab(existing.id)
            return
        }
        guard let activeID = activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeID }) else {
            openTab(target)
            return
        }
        flushPendingSaves()
        isApplyingTabSelection = true
        tabs[i].selection = target
        tabs[i].title = tabTitle(for: target)
        selection = target
        loadDrafts(for: target)
        isApplyingTabSelection = false
        DebugLog.store("[tabs] navigateCurrentTab: in-place to \(target) (id=\(activeID)), \(tabs.count) tabs total")
    }

    /// Open the tab for `selection`: if one is already open, focus it (reuse,
    /// never duplicate); otherwise create a new tab and focus it. This holds for
    /// every selection type — pages and files reuse just like the singletons
    /// (.ask, .edit, .systemPrompt, .changeLog) — so clicking a page or a
    /// `[[wiki-link]]` that's already open returns to its tab instead of spawning
    /// a copy.
    public func openTab(_ selection: WikiSelection, title: String? = nil) {
        clickStartedAt = DispatchTime.now()
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

    /// Open a tab for `selection` without switching focus to it. If a tab for
    /// `selection` is already open, this is a no-op (avoid duplicates). The
    /// active tab remains unchanged; the new tab appears at the end of the bar.
    ///
    /// When the tab bar is empty there is nothing to keep focused, so "background"
    /// would leave the user on a dead surface with no signal the action fired.
    /// Fall back to the foreground path (`openTab`) so the first tab is opened
    /// and focused like a normal Open.
    public func openTabInBackground(_ selection: WikiSelection, title: String? = nil) {
        if tabs.isEmpty {
            openTab(selection, title: title)
            return
        }
        guard !tabs.contains(where: { $0.selection == selection }) else { return }
        let tab = EditorTab(selection: selection, title: title ?? tabTitle(for: selection))
        tabs.append(tab)
        DebugLog.store("[tabs] openTabInBackground: new background tab for \(selection) (id=\(tab.id)), \(tabs.count) tabs total")
    }

    /// Retarget an open tab IN PLACE to a new selection, preserving the tab's
    /// UUID — so tab order, drag/drop position, and per-tab history survive (D2).
    /// Used for the draft-state morph (.ask/.edit → .chat(id) on first send) and
    /// the startNewConversation retarget-back (.chat(id) → .ask/.edit). If no tab
    /// with `id` exists, this is a no-op. If a DIFFERENT tab already shows `to`,
    /// that tab is focused instead (tab-reuse, same as `openTab`).
    public func retargetTab(id: UUID, to selection: WikiSelection) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            DebugLog.tabs("[tabs] retargetTab: tab \(id) not found — no-op")
            return
        }
        // If another tab already displays this selection, reuse it (focus, don't
        // duplicate) — mirrors openTab's dedup. This handles e.g. re-clicking a
        // chat that's already open in another tab.
        if let existing = tabs.first(where: { $0.selection == selection }), existing.id != id {
            selectTab(id: existing.id)
            return
        }
        tabs[index].selection = selection
        tabs[index].title = tabTitle(for: selection)
        // If this is the active tab, sync selection + drafts so the view updates.
        if activeTabID == id {
            isApplyingTabSelection = true
            self.selection = selection
            loadDrafts(for: selection)
            isApplyingTabSelection = false
        }
        DebugLog.tabs("[tabs] retargetTab: tab \(id) → \(selection)")
    }

    /// Convenience: retarget the ACTIVE tab to `.chat(chatID)`. Used by the
    /// draft-state morph on first send (the active tab is .ask/.edit → .chat).
    /// No-op if there is no active tab.
    public func retargetActiveTabToChat(chatID: PageID) {
        guard let activeID = activeTabID else { return }
        retargetTab(id: activeID, to: .chat(chatID))
    }

    /// Switch the active tab by ID. No-op if the ID is unknown or already active.
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }), id != activeTabID else { return }
        setActiveTab(id)
    }

    /// Persist the editor's edit-mode state to the given tab so that
    /// switching back to it can restore the mode.
    public func setTabEditing(tabID: UUID, isEditing: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].isEditing = isEditing
    }

    /// Close one tab by ID. Preserves it in `recentlyClosedTabs` for Cmd+Shift+T.
    /// If the closed tab is the active tab AND is in edit mode, the close is
    /// deferred: `pendingCloseTabID` is set and the view shows a confirmation
    /// alert before calling `confirmCloseTab()` or `cancelCloseTab()`.
    /// If the closed tab was active (and confirmed), activates the tab now at
    /// the same position (right neighbor), or the last tab. Closing the final
    /// tab → empty state. Closing a non-active tab leaves the active tab untouched.
    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].isEditing {
            pendingCloseTabID = id
            return
        }
        applyCloseTab(id: id, at: index)
    }

    /// Apply the deferred tab close after the user confirms. Unsaved drafts are
    /// discarded — the user chose "Close & Discard."
    public func confirmCloseTab() {
        guard let id = pendingCloseTabID,
              let index = tabs.firstIndex(where: { $0.id == id }) else {
            pendingCloseTabID = nil
            return
        }
        // Discard any stashed draft (user chose to close without saving).
        tabs[index].pendingDraftTitle = nil
        tabs[index].pendingDraftBody = nil
        pendingCloseTabID = nil
        applyCloseTab(id: id, at: index)
    }

    /// Cancel the deferred close — user chose to keep editing.
    public func cancelCloseTab() {
        pendingCloseTabID = nil
    }

    /// Discard the stashed draft for `tabID` and reload the page from the
    /// database. Called when the user cancels an in-progress edit.
    public func discardPendingDraft(tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].pendingDraftTitle = nil
        tabs[i].pendingDraftBody = nil
        loadDrafts(for: selection)
    }

    private func applyCloseTab(id: UUID, at index: Int) {
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
        } catch {
            DebugLog.store("WikiStoreModel.newPageInNewTab failed: \(error)")
        }
    }

    private func loadDrafts(for newValue: WikiSelection?) {
        loadedSelection = newValue
        // A page switch invalidates the prior page's mermaid warning so a stale
        // banner doesn't bleed onto an unrelated page (it's recomputed on save).
        mermaidSaveWarning = nil
        var restoredFromPendingDraft = false
        switch newValue {
        case .ask, .edit, .lint, .bookmark, .chat:
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
            draftBody = PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
            loadedPage = id
            // Restore stashed draft when returning to an editing tab.
            if let tabID = activeTabID,
               let i = tabs.firstIndex(where: { $0.id == tabID }),
               let pendingTitle = tabs[i].pendingDraftTitle,
               let pendingBody = tabs[i].pendingDraftBody {
                draftTitle = pendingTitle
                draftBody = pendingBody
                restoredFromPendingDraft = true
            }
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
        isDraftDirty = restoredFromPendingDraft
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
    public func bodyChanged() { isDraftDirty = true }
    public func titleChanged() { isDraftDirty = true }

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

    /// Apply the markdown linter's auto-fix to the current draft body and save.
    /// Replaces cosmetic issues (trailing whitespace, blank-line spacing, etc.)
    /// in-place — the same normalization `wikictl page upsert` applies, but
    /// triggered manually from the in-app editor. No-op when the linter is
    /// unavailable or the body is already clean.
    public func fixMarkdownInDraft() {
        guard let linter = markdownLinter else { return }
        let outcome = linter.fix(markdown: draftBody)
        guard outcome.fixed != draftBody else { return }
        draftBody = outcome.fixed
        save()
    }

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
            DebugLog.store("MarkdownLinter: linter unavailable (bundle not loaded) — skipping markdown warning")
            markdownWarningTask?.cancel()
            markdownWarningTask = nil
            markdownSaveWarning = nil
            return
        }
        markdownWarningTask?.cancel()
        // The outer Task inherits @MainActor isolation (WikiStoreModel is
        // @MainActor), so self access stays on the main actor. Only the lint
        // computation runs detached (background) — it captures only `linter`
        // (Sendable) and `body` (String), never `self`.
        markdownWarningTask = Task { [linter, weak self] in
            let findings = await Task.detached(priority: .utility) {
                linter.lint(markdown: body)
            }.value
            guard !Task.isCancelled else { return }
            let warning = findings.isEmpty ? nil : MarkdownLinter.describe(findings)
            if warning != nil {
                DebugLog.store("MarkdownLinter: \(findings.count) finding(s) for saved body")
            }
            self?.markdownSaveWarning = warning
        }
    }

    /// Pre-flight checks run before an LLM page-lint: apply `WikiLinkFixer` fixes and
    /// detect broken `[[page links]]`. Reads fresh from the store so it works for any
    /// page, not just the loaded draft. If the current page is loaded, also syncs the
    /// draft (without marking it dirty). Returns `nil` when the page cannot be read.
    public struct LintPreflight: Sendable {
        /// `true` when `WikiLinkFixer.applyFixes` rewrote one or more `\]]` brackets.
        public let didFixLinks: Bool
        /// Page titles referenced by `[[wiki links]]` in the page that do not resolve
        /// to an existing page. Source links (`[[source:X]]`) are excluded.
        public let brokenPageLinks: [String]
    }

    public func preflightLint(pageID: PageID) -> LintPreflight? {
        guard let page = try? store.getPage(id: pageID) else { return nil }

        // Apply WikiLinkFixer and persist if anything changed.
        let original = page.bodyMarkdown
        let fixedBody = WikiLinkFixer.applyFixes(to: original)
        let didFix = fixedBody != original
        if didFix {
            do {
                try PageUpsert.upsert(in: store, id: pageID, title: page.title, body: fixedBody)
                reloadSummaries()
                if loadedPage == pageID {
                    draftBody = fixedBody
                    isDraftDirty = false
                }
            } catch {
                DebugLog.store("WikiStoreModel.preflightLint fix failed: \(error)")
            }
        }

        // Detect broken page links (source links are intentionally excluded).
        let body = didFix ? fixedBody : original
        let links = WikiLinkParser.parse(body)
        let knownTitles = Set(summaries.map { $0.title })
        // Mirror replaceLinks: a link is broken only when NO candidate reading
        // of its raw target (per WikiLinkResolver — handles `#` in titles)
        // names an existing page. Unique the output — two parsed links can
        // share a base since parse() de-dupes by raw target.
        var seenBroken = Set<String>()
        let broken = links
            .filter { $0.linkType == .page }
            .compactMap { link -> String? in
                let raw = link.fragment.map { "\(link.target)#\($0)" } ?? link.target
                guard WikiLinkResolver.resolvedSplit(of: raw, isKnown: { knownTitles.contains($0) }) == nil
                else { return nil }
                return seenBroken.insert(link.target).inserted ? link.target : nil
            }

        return LintPreflight(didFixLinks: didFix, brokenPageLinks: broken)
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
        // Clear the per-tab stash — content is now committed to the database.
        if let tabID = activeTabID, let i = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[i].pendingDraftTitle = nil
            tabs[i].pendingDraftBody = nil
        }
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
        } catch {
            DebugLog.store("WikiStoreModel.newPage failed: \(error)")
        }
    }

    public func rename(_ id: PageID, to newTitle: String) {
        // Persist any pending edits to whatever's open first, then rename.
        flushPendingSave()
        do {
            let page = try store.getPage(id: id)
            let cleanBody = PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
            try store.updatePage(id: id, title: newTitle, body: cleanBody)
            reloadSummaries()
            if selection == .page(id) { draftTitle = newTitle }
            // Update any tab showing this renamed page.
            for i in tabs.indices where tabs[i].selection == .page(id) {
                tabs[i].title = newTitle
            }
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
            // Refresh BOTH lists: `sources` so the renamed source's display name
            // updates in the sidebar + detail view (without this the rename commits
            // to the DB but the live UI snaps back to the old name), and
            // `summaries` because the rename rewrites inbound `[[source:…]]` links
            // in the pages that reference it.
            reloadSources()
            reloadSummaries()
            for i in tabs.indices where tabs[i].selection == .source(id) {
                tabs[i].title = newDisplayName
            }
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
        } catch {
            DebugLog.store("WikiStoreModel.delete failed: \(error)")
            storeError = StoreError(
                title: "Couldn't Delete Page",
                message: "Could not delete the page: \(error.localizedDescription)")
        }
    }

    /// Dismiss the current store error (called when the user taps OK on the alert).
    public func dismissStoreError() {
        storeError = nil
    }

    // MARK: - File ingestion (Phase 5)

    /// Route dropped URLs to the correct **add-source** path (#163). (This adds
    /// a source — fetches/stores bytes so it appears under Sources — it does *not*
    /// run the agent "ingestion" that reads a source and generates pages; that is
    /// a separate `AgentLauncher` phase.)
    /// - An `http(s)` URL (a link dragged from a browser) **or** a `.webloc`
    ///   shortcut that resolves to one → `addURL` — the fetch + HTML→Markdown
    ///   "Add from URL" path. This avoids reading a `.webloc` plist's raw bytes,
    ///   which would capture the wrapper XML rather than the linked page.
    /// - Any other `file://` URL → `addFiles` (raw bytes, as before).
    ///
    /// Several links / `.webloc` files dropped together are each added as their
    /// own source. A `.webloc` whose `URL` key can't be parsed is skipped (its
    /// bytes aren't useful as a source). `fetcher` is injectable for tests; the
    /// default performs a real network GET.
    public func addDroppedURLs(
        _ droppedURLs: [URL],
        fetcher: any URLFetchService.URLResourceFetcher = URLSessionFetcher()
    ) async {
        var remoteInputs: [String] = []
        var localFiles: [URL] = []
        for url in droppedURLs {
            if let scheme = url.scheme, scheme == "http" || scheme == "https" {
                remoteInputs.append(url.absoluteString)
            } else if url.isFileURL, url.pathExtension.lowercased() == "webloc" {
                if let resolved = await Self.resolveWeblocURL(url) {
                    remoteInputs.append(resolved)
                } else {
                    DebugLog.store("WikiStoreModel.addDroppedURLs could not resolve .webloc: \(url.lastPathComponent)")
                }
            } else {
                localFiles.append(url)
            }
        }
        for input in remoteInputs {
            do {
                _ = try await addURL(input, fetcher: fetcher)
            } catch {
                DebugLog.store("WikiStoreModel.addDroppedURLs URL ingest failed for \(input): \(error)")
            }
        }
        if !localFiles.isEmpty {
            await addFiles(localFiles)
        }
    }

    /// Read a `.webloc` property list (XML or binary) off the main actor and
    /// return its `URL` string, or `nil` if the file isn't a valid webloc. (#163)
    private static func resolveWeblocURL(_ fileURL: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: fileURL),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil),
                  let urlString = (plist as? [String: Any])?["URL"] as? String,
                  !urlString.isEmpty
            else { return nil }
            return urlString
        }.value
    }

    // MARK: - Provider-backed ingest seam (Phase 3a)

    /// The single store-write seam every provider-backed ingest flows through.
    /// Materialization (bytes + provenance) happens off-main inside the provider;
    /// this does the main-actor `store.addSource` write, threading the
    /// `MaterializedSource`'s provenance + retained Zotero columns through. Each
    /// caller wraps its OWN duplicate/error handling around this throw.
    @discardableResult
    private func storeMaterialized(_ m: MaterializedSource) throws -> SourceSummary {
        try store.addSource(
            filename: m.filename, data: m.data,
            zoteroItemKey: m.zoteroItemKey, zoteroItemTitle: m.zoteroItemTitle,
            mimeType: m.mimeType, provenance: m.provenance, role: .primary,
            originalPath: nil, activityID: nil)
    }

    /// Ingest dropped files. For each URL: reject directories (a recursive
    /// directory ingest is out of scope), read the bytes OFF the main thread
    /// (big files shouldn't stall the UI), then hop back to the main actor to
    /// store + reload. Per-file failures are logged and skipped so one bad drop
    /// doesn't abort the batch. Each stored source emits a `source` change event
    /// at the store seam; the File Provider subscriber debounces the whole batch
    /// into one signal so the daemon re-enumerates `sources/` exactly once.
    ///
    /// Named `addFiles` (not `ingest`) because it only adds sources — it does NOT
    /// run the agent "Ingest into wiki" phase (see `AgentLauncher` /
    /// `ingestingSourceIDs`). Issue #178.
    public func addFiles(_ fileURLs: [URL]) async {
        var lastSourceID: PageID?
        var duplicateNames: [String] = []
        for url in fileURLs {
            // Skip directories — only flat files are ingested.
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                DebugLog.store("WikiStoreModel.addFiles skipping directory: \(url.lastPathComponent)")
                continue
            }
            // Materialize off-main (read + dispatch), store on the main actor.
            let provider = LocalFileProvider(fileURL: url)
            let materialized: MaterializedSource
            do {
                materialized = try await provider.materialize()
            } catch {
                DebugLog.store("WikiStoreModel.addFiles read failed for \(url.lastPathComponent): \(error)")
                continue
            }

            do {
                let summary = try storeMaterialized(materialized)
                lastSourceID = summary.id
            } catch WikiStoreError.duplicateContent(let existing) {
                // Byte-identical to an already-stored source — skip rather than
                // abort the rest of the drop batch; report it so the user isn't
                // left wondering why the file didn't show up.
                duplicateNames.append("\(url.lastPathComponent) (already added as \(existing.effectiveName))")
            } catch {
                DebugLog.store("WikiStoreModel.addFiles store failed for \(url.lastPathComponent): \(error)")
            }
        }
        reloadSources()
        if let sourceID = lastSourceID {
            openTab(.source(sourceID))
        }
        if !duplicateNames.isEmpty {
            storeError = StoreError(
                title: duplicateNames.count == 1 ? "Duplicate File Skipped" : "Duplicate Files Skipped",
                message: "These files have the exact same content as a source you already added, "
                    + "so they weren't added again:\n"
                    + duplicateNames.map { "• \($0)" }.joined(separator: "\n"))
        }
    }

    /// Add a resource by URL as a source: fetch it, convert HTML→Markdown (or
    /// store a PDF / text / binary verbatim), and land it as a source file —
    /// exactly like a drag-dropped file, so the existing **"Ingest into wiki"**
    /// `claude -p` operation can summarize it afterward. Lands through the SAME
    /// `store.addSource` path as `addFiles`, so it appears under Sources +
    /// `sources/by-{id,name}` immediately and is pickable in Operations → Ingest.
    /// Returns the outcome on success; throws a user-readable
    /// `URLFetchService.FetchError` on a bad URL, non-2xx, empty body, or store
    /// failure (the caller surfaces it in the sheet). The store write hops to the
    /// main actor (this type is `@MainActor`); the fetch runs off it.
    ///
    /// Named `addURL` (not `ingestURL`) because it only adds a source — the agent
    /// "Ingest into wiki" phase is a separate, later step. Issue #178.
    @discardableResult
    public func addURL(
        _ rawInput: String,
        fetcher: any URLFetchService.URLResourceFetcher = URLSessionFetcher()
    ) async throws -> URLFetchService.FetchOutcome {
        #if PODCAST_TRANSCRIPTS
        // Delegate to the podcast-aware overload so routing is in one place.
        return try await addURL(rawInput, fetcher: fetcher, podcastFetcher: ApplePodcastTranscriptService.bundled())
        #else
        // Phase 4b: byteless external-embed media works without the podcast
        // helper too (it needs no network — pure URL parsing).
        if let outcome = try bytelessMediaOutcome(rawInput) {
            return outcome
        }
        return try await addURLViaWebsite(rawInput, fetcher: fetcher)
        #endif
    }

    #if PODCAST_TRANSCRIPTS
    /// The podcast-aware `addURL`: recognizes an Apple Podcasts episode link and
    /// routes to the transcript pipeline instead of the HTML fetcher. The
    /// `podcastFetcher` seam lets CI inject a fake `PodcastTranscriptFetching`
    /// (the bundled service returns nil without the signing helper).
    @discardableResult
    public func addURL(
        _ rawInput: String,
        fetcher: any URLFetchService.URLResourceFetcher,
        podcastFetcher: (any PodcastTranscriptFetching)?
    ) async throws -> URLFetchService.FetchOutcome {
        // An Apple Podcasts EPISODE link is recognized before the generic web
        // fetch: its HTML is the useless player page, so we route to the
        // transcript pipeline instead. The pageURL is re-normalized from the raw
        // input so the Origin row surfaces the canonical `podcasts.apple.com` URL
        // the user pasted (the episode ID alone isn't a clickable link).
        if let episode = PodcastEpisodeURL.parse(rawInput) {
            guard let svc = podcastFetcher else {
                throw PodcastTranscriptError.signatureUnavailable(
                    "Apple Podcasts transcripts need the signing helper, which isn't available in this build.")
            }
            let pageURL = URLFetchService.normalizeURL(rawInput)
                ?? URL(string: "https://podcasts.apple.com")!
            let provider = ApplePodcastProvider(episode: episode, pageURL: pageURL, fetcher: svc)
            let transcript = try await provider.materialize()
            // §11 byteless model: the source is byteless (a pointer to the
            // external episode), and the transcript markdown is stored as the
            // derived alternative — NOT as content bytes (Option-A). The
            // provider is unchanged; only the storage path repoints.
            guard let prov = transcript.provenance else {
                throw URLFetchService.FetchError.invalidURL("podcast transcript missing provenance")
            }
            let summary = try store.addBytelessSource(
                filename: transcript.filename, mimeType: transcript.mimeType,
                provenance: prov, role: .primary)
            let markdown = String(data: transcript.data, encoding: .utf8) ?? ""
            try store.appendProcessedMarkdown(
                sourceID: summary.id, content: markdown, origin: "transcript", note: nil)
            reloadSources()
            openTab(.source(summary.id))
            return URLFetchService.FetchOutcome(
                filename: transcript.filename,
                byteSize: transcript.data.count,
                kind: .podcastTranscript)
        }
        // Phase 4b: byteless external-embed media (provider iframes + direct-
        // remote). Recognized by pure URL parsing, after apple-podcast and
        // before the website fetch. Creates a byteless source (no bytes fetched).
        if let outcome = try bytelessMediaOutcome(rawInput) {
            return outcome
        }
        return try await addURLViaWebsite(rawInput, fetcher: fetcher)
    }
    #endif

    /// Phase 4b: try the byteless external-embed recognizers in fixed precedence
    /// order — provider iframes (YouTube → Vimeo → Spotify → SoundCloud) then
    /// direct-remote media. On a match, create a **byteless** source (no bytes
    /// fetched) and return its outcome; on no match, return `nil` so the caller
    /// falls through to the website fetch. Pure URL parsing — no network. Throws
    /// only on a store failure (e.g. `.duplicateContent` for a re-paste).
    ///
    /// `role: .primary` (not `.media`): these are first-class, user-created,
    /// referenceable sources — visible, searchable, and citable in the Sources
    /// list — matching the byteless-podcast precedent.
    private func bytelessMediaOutcome(_ rawInput: String) throws -> URLFetchService.FetchOutcome? {
        let match: MediaEmbedMatch
        let kind: URLFetchService.FetchOutcome.Kind
        if let m = MediaEmbedURL.youtube(rawInput) { match = m; kind = .videoEmbed }
        else if let m = MediaEmbedURL.vimeo(rawInput) { match = m; kind = .videoEmbed }
        else if let m = MediaEmbedURL.spotify(rawInput) { match = m; kind = .audioEmbed }
        else if let m = MediaEmbedURL.soundcloud(rawInput) { match = m; kind = .audioEmbed }
        else if let m = MediaEmbedURL.remoteMedia(rawInput) { match = m; kind = .remoteMedia }
        else { return nil }

        let summary = try store.addBytelessSource(
            filename: match.filename,
            mimeType: match.mimeType,
            provenance: SourceProvenance(
                agentName: match.agentName,
                activityKind: match.activityKind,
                plan: match.planURL,
                externalRef: match.planURL,
                externalIdentity: match.externalIdentity),
            role: .primary)
        reloadSources()
        openTab(.source(summary.id))
        return URLFetchService.FetchOutcome(
            filename: match.filename, byteSize: 0, kind: kind)
    }

    /// The web-fetch ingest path (HTML→md / PDF / text / binary), shared by both
    /// the feature-on and feature-off `addURL` overloads. Validate + fetch OFF the
    /// main actor (the GET shouldn't stall the UI); the WebsiteProvider owns
    /// normalize→fetch→dispatch (materialization). Then store the result HERE on
    /// the main actor, where we own `store`.
    ///
    /// Phase 4: HTML pages with images are stored as a **website snapshot** —
    /// the page plus its image siblings under one shared fetch activity. Non-HTML
    /// and image-less HTML stay single-source.
    private func addURLViaWebsite(
        _ rawInput: String,
        fetcher: any URLFetchService.URLResourceFetcher
    ) async throws -> URLFetchService.FetchOutcome {
        let provider = WebsiteProvider(rawInput: rawInput, fetcher: fetcher)
        let snapshot = try await provider.materializeSnapshot()
        var summary: SourceSummary
        if snapshot.plan.kind == .htmlConverted && !snapshot.images.isEmpty {
            summary = try storeSnapshot(snapshot)
        } else {
            summary = try storeMaterialized(snapshot.page)
        }
        // HTML-converted sources have ".md" appended to the storage filename;
        // set a clean display name (the page title without the extension) so
        // the UI shows "How to Do Thing" instead of "How to Do Thing.md".
        if snapshot.plan.kind == .htmlConverted {
            let cleanTitle = (snapshot.page.filename as NSString).deletingPathExtension
            try? store.setSourceDisplayName(id: summary.id, displayName: cleanTitle)
        }
        reloadSources()
        openTab(.source(summary.id))
        return URLFetchService.FetchOutcome(
            filename: snapshot.plan.filename, byteSize: snapshot.plan.data.count, kind: snapshot.plan.kind)
    }

    /// Phase 4 — store a website snapshot: one shared fetch activity (committed
    /// FIRST so the version FK is satisfied), then the page source via `addSource`
    /// (with source-level content-hash dedup intact), then each image as a
    /// per-snapshot `.media` source via `addSnapshotImage` (no source dedup; blob
    /// still deduped). Three independent method-atomic commits (§8: the model has
    /// no `withTransaction` access and needs none).
    ///
    /// The snapshot is intentionally non-atomic across siblings: a mid-snapshot
    /// failure leaves the page + already-stored images committed and degrades
    /// gracefully (un-stored images simply don't resolve at render). The page's
    /// own `.duplicateContent` (a re-paste of the same page) propagates as today.
    private func storeSnapshot(_ snapshot: WebsiteSnapshot) throws -> SourceSummary {
        guard let prov = snapshot.page.provenance else {
            return try storeMaterialized(snapshot.page)
        }
        // 1. Commit the shared activity FIRST so source_versions.activity_id FK
        //    is satisfied before any version is written.
        let activityID = try store.ensureFetchActivity(provenance: prov)
        // 2. Store the page (source-level dedup intact; shares the activity).
        let pageSummary = try store.addSource(
            filename: snapshot.page.filename, data: snapshot.page.data,
            zoteroItemKey: nil, zoteroItemTitle: nil,
            mimeType: snapshot.page.mimeType, provenance: prov, role: .primary,
            originalPath: nil, activityID: activityID)
        // 3. Store each image as a per-snapshot .media source.
        for image in snapshot.images {
            _ = try? store.addSnapshotImage(
                filename: image.filename, data: image.data, mimeType: image.mimeType,
                originalPath: image.originalPath, sourceURL: image.sourceURL,
                activityID: activityID, role: .media)
        }
        return pageSummary
    }

    // MARK: - Source refresh (Phase 3b)

    /// Refresh a source: re-fetch it via its provider (reconstructed from the
    /// stored origin), appending a new version instead of overwriting. Website
    /// sources append a content version; podcast (byteless) sources append a
    /// derived markdown version. Import-only sources (local-file, Zotero,
    /// folder) throw `.notRefreshable`. Materialization runs off-main (the
    /// provider's network fetch); the store write happens HERE on the main
    /// actor, exactly like `addURL`.
    ///
    /// Returns a human-readable description for UI surfacing.
    #if PODCAST_TRANSCRIPTS
    @discardableResult
    public func refreshSource(
        _ id: PageID,
        fetcher: any URLFetchService.URLResourceFetcher = URLSessionFetcher(),
        podcastFetcher: (any PodcastTranscriptFetching)? = ApplePodcastTranscriptService.bundled()
    ) async throws -> String {
        let service = SourceRefreshService(
            fetcher: fetcher, podcastFetcher: podcastFetcher)
        return try await performRefresh(id: id, service: service)
    }
    #else
    @discardableResult
    public func refreshSource(
        _ id: PageID,
        fetcher: any URLFetchService.URLResourceFetcher = URLSessionFetcher()
    ) async throws -> String {
        let service = SourceRefreshService(fetcher: fetcher)
        return try await performRefresh(id: id, service: service)
    }
    #endif

    /// Shared refresh body: materialize off-main, append the version on-main,
    /// reload. Split out so the `#if PODCAST_TRANSCRIPTS` gated inits don't
    /// duplicate the store-write logic.
    private func performRefresh(
        id: PageID, service: SourceRefreshService
    ) async throws -> String {
        guard let origin = try store.sourceOrigin(sourceID: id) else {
            throw SourceRefreshService.RefreshError.notRefreshable("unknown")
        }
        // Phase 4 refresh guard (D3): a snapshot source with image siblings
        // cannot be refreshed by the single-source path — a new activity would
        // orphan its images (the resolver joins on the active activity). Guard
        // BEFORE materialize so no version is appended. Snapshot-aware refresh
        // (re-snapshotting images) is a named follow-on.
        if try store.hasImageSiblings(sourceID: id) {
            throw SourceRefreshService.RefreshError.snapshotWithImages
        }
        let material = try await service.materialize(origin: origin)
        switch material {
        case .contentVersion(let data, let prov):
            _ = try store.appendContentVersion(
                sourceID: id, data: data, mimeType: nil, provenance: prov)
        case .derivedMarkdown(let content):
            try store.appendProcessedMarkdown(
                sourceID: id, content: content, origin: "transcript", note: nil)
        }
        reloadSources()
        return "Refreshed \(origin.displayLabel) source."
    }

    /// Synchronous ingest seam used by tests/verifiers (no drag gesture). Stores
    /// the bytes, rebuilds the list, and signals the daemon.
    public func addSource(filename: String, data: Data) {
        do {
            _ = try store.addSource(
                filename: filename, data: data, zoteroItemKey: nil, zoteroItemTitle: nil,
                mimeType: nil, provenance: nil, role: .primary,
                originalPath: nil, activityID: nil)
            reloadSources()
        } catch WikiStoreError.duplicateContent(let existing) {
            storeError = StoreError(
                title: "Duplicate File Skipped",
                message: "\(filename) has the exact same content as \(existing.effectiveName), so it wasn't added again.")
        } catch {
            DebugLog.store("WikiStoreModel.addSource failed: \(error)")
        }
    }

    /// Ingest one Zotero attachment by reading its local file and storing the
    /// verbatim bytes — exactly like a drag-dropped file, but threading the
    /// parent item's key + title into the row as provenance so the detail view
    /// can show "From Zotero" and link back. We already know the filename and
    /// bytes from Zotero's metadata, so this goes straight to the
    /// `addSource(filename:data:)` seam rather than `URLFetchService`'s
    /// content-type dispatch (that dispatch exists for the unknown-bytes-from-a-
    /// URL case, which doesn't apply here). No network fallback in v1: an
    /// attachment that isn't synced to `~/Zotero/storage` yet throws
    /// `ZoteroFetchError.unavailable` rather than downloading it.
    public func ingestFromZotero(
        _ attachment: ZoteroAttachment,
        parentItem: ZoteroItem,
        zoteroDir: URL
    ) async throws {
        let provider = ZoteroProvider(
            attachment: attachment, parentItem: parentItem, zoteroDir: zoteroDir)
        // Resolve + read off the main actor (the provider materializes, throwing
        // ZoteroFetchError.unavailable when the attachment isn't local).
        let materialized = try await provider.materialize()
        do {
            let summary = try storeMaterialized(materialized)
            reloadSources()
            openTab(.source(summary.id))
        } catch {
            DebugLog.store("WikiStoreModel.ingestFromZotero failed: \(error)")
            throw error
        }
    }

    /// Import every `.md` / `.markdown` file in `directory` (recursively) as an
    /// ingested file — a one-shot migration of an Obsidian vault, LogSeq graph, or
    /// any folder of Markdown notes. Hidden files/directories are skipped.
    /// Duplicate FILENAMES get a disambiguating suffix (`Note.md`, `Note-1.md`, …);
    /// duplicate CONTENT (byte-identical to a file already in the store, from this
    /// import or an earlier one) is skipped and folded into `errors` rather than
    /// blocking the rest of the batch — a folder import is often large, so a
    /// modal-per-duplicate would be disruptive (issue #126).
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
            let ext = (file.filename as NSString).pathExtension.lowercased()
            let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType
            let provider = MarkdownFolderProvider(
                filename: file.filename, data: file.data, mimeType: mimeType)
            do {
                let materialized = try await provider.materialize()
                let summary = try storeMaterialized(materialized)
                if firstSourceID == nil { firstSourceID = summary.id }
                imported += 1
            } catch WikiStoreError.duplicateContent(let existing) {
                errorMessages.append("\(file.filename): duplicate of \(existing.effectiveName), skipped")
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

    /// The origin provenance of a source (provider agent + the activity that
    /// fetched/imported it). `nil` when the read fails or no version exists.
    /// Drives the "Origin" row in `SourceDetailView`.
    public func sourceOrigin(for id: PageID) -> SourceOrigin? {
        try? store.sourceOrigin(sourceID: id)
    }

    /// `true` iff `refreshSource(_:)` would actually succeed for this source —
    /// the single source of truth the detail view gates the Refresh button on.
    /// Mirrors `SourceRefreshService.materialize` + the `performRefresh` snapshot
    /// guard so the UI only offers Refresh when it can work:
    /// - `"website"` → refreshable, unless it's a snapshot with image siblings
    ///   (the single-source refresh guard, D3, would orphan them).
    /// - `"apple-podcast"` → refreshable only when this build compiled podcast
    ///   support AND the `podcast-token-helper` binary is present at runtime.
    /// - Everything else (local-file, Zotero, folder, unknown, missing origin)
    ///   is import-only and not refreshable.
    public func isSourceRefreshable(for id: PageID) -> Bool {
        guard let origin = sourceOrigin(for: id), origin.plan != nil else { return false }
        switch origin.agentName {
        case "website":
            return !((try? store.hasImageSiblings(sourceID: id)) ?? false)
        case "apple-podcast":
            #if PODCAST_TRANSCRIPTS
            return ApplePodcastTranscriptService.bundled() != nil
            #else
            return false
            #endif
        default:
            return false
        }
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

    /// All versions for a source, newest first. Empty if none.
    public func processedMarkdownHistory(for sourceID: PageID) -> [SourceMarkdownVersion] {
        (try? store.processedMarkdownHistory(sourceID: sourceID)) ?? []
    }

    /// Read a single resolved-markdown version by its smv id (Phase 6). Returns
    /// the blob-decoded version, or `nil` when no row matches. Used by the
    /// pinned-extraction viewer to load the exact extraction a quote was written
    /// against.
    public func processedMarkdownVersion(for id: PageID) -> SourceMarkdownVersion? {
        (try? store.processedMarkdownVersion(id: id)) ?? nil
    }

    /// Every source's derived-markdown chain as `[sourceID: [smvID]]`, ULID-asc
    /// per source. Phase 6: the render precompute builds the `sourceID → [smvID]`
    /// map so `linkified` can resolve `@vN` per occurrence.
    public func sourceDerivedChains() -> [PageID: [PageID]] {
        (try? store.sourceDerivedChains()) ?? [:]
    }

    /// The embed descriptors for every byteless source, batched in one query.
    /// Phase 4b: the render precompute builds this once (main-actor read) and
    /// feeds `ExternalEmbed.target(for:)` to widen `![[source:…]]` embeds to
    /// external media. Returns `{}` on any query failure.
    public func embedDescriptors() -> [PageID: SourceEmbedDescriptor] {
        (try? store.embedDescriptors()) ?? [:]
    }

    /// Phase 4: batched sibling-image resolver maps for the render precompute.
    /// Per source, `[original_path → sibling sourceID]`. Returns `{}` on
    /// failure (images simply won't resolve — degraded, not fatal).
    public func siblingImageResolvers() -> [PageID: [String: PageID]] {
        (try? store.siblingImageResolvers()) ?? [:]
    }

    /// A memoized ``WikiRenderContext`` (Phase A.1, D1) — the pure-data snapshot
    /// of everything a markdown render needs from the store (existence/display/
    /// loose-match sets, `embedMap` incl. external `EmbedTarget`s,
    /// `sourceDerivedChain`, `siblingMaps`).
    ///
    /// Built lazily on first access and rebuilt only when pages or sources
    /// change — `reloadSummaries()` / `reloadSources()` bump
    /// ``renderContextGeneration`` (every local mutation routes through them, and
    /// `.external` `WikiEventBus` events route through `reloadFromStore()` → the
    /// same reloads). So per-delta renders reuse the snapshot and never touch
    /// SQLite. The returned value is `Sendable` and safe to hand to a detached
    /// render task; its closures are pure (no store access at render time).
    public func renderContext() -> WikiRenderContext {
        if let cached = cachedRenderContext,
           renderContextBuiltAtGeneration == renderContextGeneration {
            return cached
        }
        let built = WikiRenderContext.build(from: self)
        cachedRenderContext = built
        renderContextBuiltAtGeneration = renderContextGeneration
        return built
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
    /// output, recording full provenance (backend agent + extract activity). The
    /// `source_version_id` is resolved from the source's active content version.
    /// Double-seed guard: if a head already exists, returns it instead.
    @discardableResult
    public func seedPdfMarkdown(
        for sourceID: PageID, content: String,
        backend: ExtractionBackend, modelVersion: String? = nil
    ) -> SourceMarkdownVersion? {
        if let head = try? store.processedMarkdownHead(sourceID: sourceID) {
            return head
        }
        return try? store.recordMarkdownExtraction(
            sourceID: sourceID, content: content, backend: backend,
            sourceVersionID: nil, note: nil, modelVersion: modelVersion)
    }

    /// Re-extract a source's content with a given extractor + backend, appending
    /// a COEXISTING alternative (never clobbers the existing head). Resolves the
    /// source bytes + active content version from the store, runs the extractor,
    /// then records the provenance-carrying extraction. Returns the new
    /// alternative, or nil if the bytes can't be read or conversion fails.
    @discardableResult
    public func reExtractMarkdown(
        for sourceID: PageID, filename: String,
        using extractor: any MarkdownExtractor,
        backend: ExtractionBackend, modelVersion: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> SourceMarkdownVersion? {
        guard let data = try? store.sourceContent(id: sourceID) else { return nil }
        guard let markdown = try? await extractor.convert(
            pdfData: data, filename: filename, onProgress: onProgress) else {
            return nil
        }
        return try? store.recordMarkdownExtraction(
            sourceID: sourceID, content: markdown, backend: backend,
            sourceVersionID: nil, note: "re-extract via \(backend.agentName)",
            modelVersion: modelVersion)
    }

    /// Nominate an existing processed-markdown row as the active HEAD for a
    /// source (UPSERT the `source-derived` ref). Thin wrapper over the store.
    public func setActiveMarkdown(for sourceID: PageID, to versionID: PageID) {
        try? store.setActiveMarkdown(sourceID: sourceID, to: versionID)
    }

    /// The producing agent name for each of a source's markdown versions
    /// (smv.id → agents.name), for the alternatives UI labels.
    public func processedMarkdownAgentNames(for sourceID: PageID) -> [String: String] {
        (try? store.processedMarkdownAgentNames(sourceID: sourceID)) ?? [:]
    }

    /// All extraction alternatives for a source with provenance + active flag,
    /// for the compare/nominate sheet (track C). Empty if none.
    public func processedMarkdownAlternatives(for sourceID: PageID) -> [ExtractionAlternative] {
        (try? store.processedMarkdownAlternatives(sourceID: sourceID)) ?? []
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
        reloadChats()
        pruneHistoryToCurrentStore()
    }

    /// Rebuild the sidebar page list from the store using the current sort order.
    /// Public so `SidebarView` can trigger a reload when the sort picker changes
    /// (via the `pageSortOrder` didSet), and so the Phase A change bridge can
    /// refresh after an external write.
    public func reloadSummaries() {
        summaries = (try? store.listPages(sortBy: pageSortOrder)) ?? []
        // Phase A.1: any page mutation invalidates the memoized render context.
        renderContextGeneration &+= 1
    }

    // MARK: - Search

    /// One-time, blocking search-index upgrade. Replaces the old detached
    /// background backfill, which raced the main thread on the store's cached,
    /// non-thread-safe prepared statements (the launch `EXC_BREAKPOINT` in
    /// `String(cString:)`).
    ///
    /// Invariant: **SQLite is never touched off-main.** All store reads/writes
    /// happen here on the main actor; only the MLX/Metal inference hops to a
    /// detached task (pure compute, no SQLite). While `searchUpgrade != nil` the
    /// UI shows a non-dismissible sheet, so the upgrade is the sole owner of the
    /// store — there is no second thread and no race.
    ///
    /// Only runs when MiniLM is the selected embedder (fast, ~ms/sentence) AND
    /// there is missing content. On builds without the bundled model
    /// (`selectedEmbedderIdentifier()` ≠ MiniLM) it is a no-op so we never block
    /// launch on the slow NLEmbedder path; search falls back to FTS. The common
    /// warm-DB launch has no missing work → no sheet, instant.
    public func upgradeSearchIndex() async {
        // Single-flight: set BEFORE any `await`. The scenePhase `.active` and
        // `activeWikiID` hooks can both fire at launch; without this synchronous
        // guard a second call enters during the configure() suspension and the
        // upgrade runs twice (harmless to data, wasteful, and it confuses the
        // progress counter). `searchUpgrade` itself is set too late to gate on.
        guard !isUpgrading else { return }
        isUpgrading = true
        defer { isUpgrading = false }

        // Link-graph self-heal, once per model lifetime, BEFORE the embedder
        // gates below (it must run even on FTS-only builds). Main-actor SQLite
        // like everything else here; re-resolves every page's `[[links]]` so
        // citations that only resolve under newer rules (lookup-driven `#`
        // splitting, lenient source-name matching) — or whose target was
        // ingested after the page was last saved — get their link rows without
        // waiting for the page's next edit.
        if !didReconcileLinks {
            didReconcileLinks = true
            let start = DispatchTime.now()
            let count = (try? await LinkReconciler.reconcileAll(in: store)) ?? 0
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            DebugLog.store("LinkReconciler: re-resolved links for \(count) page(s) in \(Int(ms))ms")
        }

        guard EmbeddingService.selectedEmbedderIdentifier() == EmbeddingService.miniLMIdentifier else {
            return                                            // no MiniLM model → FTS-only
        }
        await EmbeddingService.configure()
        guard EmbeddingService.isAvailable else { return }

        let pageWork   = store.missingPageEmbeddingWork()     // main-thread SQLite read
        let sourceWork = store.missingSourceEmbeddingWork()   // main-thread SQLite read
        let total = pageWork.count + sourceWork.count
        guard total > 0 else { return }                       // nothing missing → no sheet

        searchUpgrade = SearchUpgradeState(total: total, done: 0, phase: .pages)
        DebugLog.store("searchUpgrade: begin — \(pageWork.count) page(s), \(sourceWork.count) source(s)")

        var done = 0
        done = await embedAndStore(pageWork, into: { try? store.storePageChunks(id: $0, chunks: $1) }, running: done)
        searchUpgrade?.phase = .sources
        done = await embedAndStore(sourceWork, into: { try? store.storeSourceChunks(id: $0, chunks: $1) }, running: done)

        DebugLog.store("searchUpgrade: complete — \(done) of \(total)")
        searchUpgrade = nil                                   // dismisses the sheet
    }

    /// Shared body of the page + source embed loops. **Stays on `@MainActor`**:
    /// only the `await embedChunksOffMain` suspension hops off-main (pure MLX,
    /// no SQLite); the `store` closure runs the SQLite write on the main actor.
    /// Do NOT parallelize this — two threads on the store's cached statements is
    /// the race that crashed launch (`docs/skills/sqlite-concurrency/SKILL.md`).
    /// Returns the updated running count (for `searchUpgrade.done`).
    private func embedAndStore(
        _ work: [(id: PageID, text: String)],
        into store: (PageID, [Data]) throws -> Void,
        running done: Int
    ) async -> Int {
        var done = done
        for (id, text) in work {
            let blobs = await embedChunksOffMain(text)
            if !blobs.isEmpty { try? store(id, blobs) }       // main-thread SQLite write
            done += 1
            searchUpgrade?.done = done
            await Task.yield()                                // keep the sheet's spinner animating
        }
        return done
    }

    /// Chunk + embed a document's text on a background thread (MLX/Metal is
    /// safe off-main and is pure compute — it touches NO SQLite). Returns one
    /// Float32 BLOB per chunk. The surrounding `upgradeSearchIndex` does all
    /// SQLite I/O on the main actor.
    private nonisolated func embedChunksOffMain(_ text: String) async -> [Data] {
        await Task.detached(priority: .utility) {
            EmbeddingService.chunkedEmbeddings(for: text)
        }.value
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
            // Prefer an off-main snapshot read (Phase 0 reader pool) so typing
            // never contends with the main-actor write store; fall back to the
            // main store when no pool exists (in-memory wiki, tests).
            let query = self.searchQuery
            let results: [WikiPageSummary]
            if let pool = self.readPool {
                results = (try? await pool.asyncRead { reader in
                    try reader.searchSimilar(query: query, limit: 20)
                }) ?? []
            } else {
                results = (try? self.store.searchSimilar(query: query, limit: 20)) ?? []
            }
            guard !Task.isCancelled else { return }
            self.searchResults = results
        }
    }

    private func scheduleSourceSearch() {
        sourceSearchTask?.cancel()
        guard !sourceSearchQuery.isEmpty else {
            sourceSearchResults = []
            return
        }
        sourceSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let query = self.sourceSearchQuery
            let results: [SourceSummary]
            if let pool = self.readPool {
                results = (try? await pool.asyncRead { reader in
                    try reader.searchSimilarSources(query: query, limit: 20)
                }) ?? []
            } else {
                results = (try? self.store.searchSimilarSources(query: query, limit: 20)) ?? []
            }
            guard !Task.isCancelled else { return }
            self.sourceSearchResults = results
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
        // Phase A.1: any source mutation invalidates the memoized render context.
        renderContextGeneration &+= 1
    }

    // MARK: - Bookmark nodes (v16)

    /// Reload all bookmark nodes from the store.
    /// Called on init and after every bookmark-node mutation (§3.1 rebuild-from-source).
    public func reloadBookmarkNodes() {
        bookmarkNodes = (try? store.listBookmarkNodes()) ?? []
    }

    // MARK: - Bookmark node mutations

    /// Create a folder at root or inside another folder. Returns the new node id,
    /// or `nil` on failure.
    @discardableResult
    public func createFolder(parentID: String?, name: String) -> String? {
        // Determine the position (append at end of siblings).
        let position = bookmarkNodes.filter { $0.parentID == parentID }.count
        do {
            let node = try store.createBookmarkNode(
                parentID: parentID, position: position, kind: .folder,
                label: name, targetID: nil)
            reloadBookmarkNodes()
            return node.id
        } catch {
            DebugLog.store("WikiStoreModel.createFolder failed: \(error)")
            return nil
        }
    }

    /// Add a page reference to a folder. Pass `position` to insert at a specific
    /// sibling index (the store shifts later siblings down); omit it to append.
    public func addPageRef(parentID: String?, pageID: PageID, position: Int? = nil) {
        let t0 = DispatchTime.now()
        let pos = position ?? bookmarkNodes.filter { $0.parentID == parentID }.count
        do {
            _ = try store.createBookmarkNode(
                parentID: parentID, position: pos, kind: .pageRef,
                label: nil, targetID: pageID)
            reloadBookmarkNodes()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            DebugLog.tabs("addPageRef: done in \(String(format: "%.1f", ms)) ms")
        } catch {
            DebugLog.store("WikiStoreModel.addPageRef failed: \(error)")
        }
    }

    /// Add a source reference to a folder. Pass `position` to insert at a specific
    /// sibling index (the store shifts later siblings down); omit it to append.
    public func addSourceRef(parentID: String?, sourceID: PageID, position: Int? = nil) {
        let pos = position ?? bookmarkNodes.filter { $0.parentID == parentID }.count
        do {
            _ = try store.createBookmarkNode(
                parentID: parentID, position: pos, kind: .sourceRef,
                label: nil, targetID: sourceID)
            reloadBookmarkNodes()
        } catch {
            DebugLog.store("WikiStoreModel.addSourceRef failed: \(error)")
        }
    }

    /// Rename a folder.
    public func renameBookmarkNode(id: String, to label: String) {
        do {
            try store.updateBookmarkNode(id: id, label: label)
            reloadBookmarkNodes()
        } catch {
            DebugLog.store("WikiStoreModel.renameBookmarkNode failed: \(error)")
        }
    }

    /// Delete a bookmark node (cascade-deletes children for folders).
    public func deleteBookmarkNode(id: String) {
        do {
            try store.deleteBookmarkNode(id: id)
            reloadBookmarkNodes()
        } catch {
            DebugLog.store("WikiStoreModel.deleteBookmarkNode failed: \(error)")
        }
    }

    /// Move a node to a new parent and/or position. Returns `false` (and logs)
    /// if the store rejects the move — e.g. it would create a parent cycle.
    @discardableResult
    public func moveBookmarkNode(id: String, toParentID: String?, position: Int) -> Bool {
        do {
            try store.moveBookmarkNode(id: id, toParentID: toParentID, position: position)
            reloadBookmarkNodes()
            return true
        } catch {
            DebugLog.store("WikiStoreModel.moveBookmarkNode failed: \(error)")
            return false
        }
    }

    private func pruneHistoryToCurrentStore() {
        let pageIDs = Set(summaries.map(\.id))
        let sourceIDs = Set(sources.map(\.id))
        let chatIDs = Set(chats.map(\.id))
        backStack.removeAll { !isAvailableHistorySelection($0, pageIDs: pageIDs, sourceIDs: sourceIDs, chatIDs: chatIDs) }
        forwardStack.removeAll { !isAvailableHistorySelection($0, pageIDs: pageIDs, sourceIDs: sourceIDs, chatIDs: chatIDs) }
    }

    private func isAvailableHistorySelection(
        _ value: WikiSelection,
        pageIDs: Set<PageID>,
        sourceIDs: Set<PageID>,
        chatIDs: Set<PageID>
    ) -> Bool {
        switch value {
        case .page(let id):
            pageIDs.contains(id)
        case .source(let id):
            sourceIDs.contains(id)
        case .chat(let id):
            chatIDs.contains(id)
        case .ask, .edit, .systemPrompt, .changeLog, .lint, .bookmark:
            true
        }
    }

    // MARK: - Persisted chats (issue #119)

    /// Create a persisted chat, titled from the first user message. Returns nil
    /// (logging via DebugLog.store) on store failure — persistence must never
    /// block a conversation from starting.
    @discardableResult
    public func startChat(kind: ChatKind, firstMessage: String) -> ChatSummary? {
        do {
            let title = ChatSummary.title(fromFirstMessage: firstMessage)
            let chat = try store.createChat(kind: kind, title: title)
            reloadChats()
            return chat
        } catch {
            DebugLog.store("WikiStoreModel.startChat failed: \(error)")
            return nil
        }
    }

    /// Append the persistable subset of `events` to a chat. Non-persistable
    /// events (deltas, messageStop, raw) are filtered here as defense in depth.
    public func appendChatEvents(chatID: PageID, events: [AgentEvent]) {
        let persistable = events.filter(\.isPersistable)
        guard !persistable.isEmpty else { return }
        do {
            try store.appendChatMessages(chatID: chatID, events: persistable)
            reloadChats()  // cheap — keeps updated_at ordering + counts live.
        } catch {
            DebugLog.store("WikiStoreModel.appendChatEvents failed: \(error)")
        }
    }

    public func chatMessages(chatID: PageID) -> [ChatMessage] {
        (try? store.chatMessages(chatID: chatID)) ?? []
    }

    public func renameChat(id: PageID, to title: String) {
        do {
            try store.renameChat(id: id, to: title)
            reloadChats()
        } catch {
            DebugLog.store("WikiStoreModel.renameChat failed: \(error)")
            storeError = StoreError(
                title: "Couldn't Rename Conversation",
                message: "Could not rename the conversation: \(error.localizedDescription)")
        }
    }

    public func deleteChat(id: PageID) {
        do {
            try store.deleteChat(id: id)
            removeFromHistory(.chat(id))
            // Close any tab showing this deleted chat.
            if let tab = tabs.first(where: { $0.selection == .chat(id) }) {
                closeTab(id: tab.id)
            }
            reloadChats()
        } catch {
            DebugLog.store("WikiStoreModel.deleteChat failed: \(error)")
            storeError = StoreError(
                title: "Couldn't Delete Conversation",
                message: "Could not delete the conversation: \(error.localizedDescription)")
        }
    }
}

/// Thrown by `WikiStoreModel.ingestFromZotero` when an attachment can't be
/// ingested — currently just the "not synced locally yet" case, since v1 has no
/// network-download fallback (see `ZoteroLocalStorage`).
public enum ZoteroFetchError: LocalizedError, Equatable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}

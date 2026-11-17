import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import WikiFSSearch

/// Progress of the blocking search-index upgrade (see
/// `WikiStoreModel.searchUpgrade`). Shown in a non-dismissible sheet while the
/// upgrade runs; `nil`-ing `searchUpgrade` dismisses it.
public struct SearchUpgradeState: Identifiable {
    public let id = UUID()
    public let total: Int
    public var done: Int
    public var phase: Phase
    public enum Phase: String, Sendable { case pages, sources, chats }

    public init(total: Int, done: Int, phase: Phase) {
        self.total = total; self.done = done; self.phase = phase
    }
}

/// One daemon progress step for the search-index upgrade (plan 5.2). The
/// daemon-side backfill reports phase/done/total while it runs and exactly
/// one terminal state at the end; the model's sheet state machine is a
/// direct projection. Module-neutral: the session wiring projects the wire
/// event (`DaemonSearchUpgradeEvent`, WikiDaemonContract) into this value,
/// because WikiFSCore does not import the daemon contract.
public struct SearchUpgradeProgress: Equatable, Sendable {
    public enum Terminal: Equatable, Sendable { case none, complete, failed }
    public let phase: SearchUpgradeState.Phase
    public let done: Int
    public let total: Int
    public let terminal: Terminal

    public init(
        phase: SearchUpgradeState.Phase, done: Int, total: Int,
        terminal: Terminal
    ) {
        self.phase = phase
        self.done = done
        self.total = total
        self.terminal = terminal
    }
}

public enum ChatResolution: Equatable, Sendable {
    case available(ChatSummary)
    case notFound
    case failed(String)
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
    /// Monotone invalidation for machine-scoped renderer availability. It is
    /// intentionally separate from resource projections: machine settings do
    /// not create pages, sources, provenance, File Provider work, or Tantivy
    /// indexing. Phase 5 will consume this to build an unavailable-only
    /// renderer availability projection; this slice does not activate records.
    public private(set) var rendererMachineAvailabilityRevision: UInt64 = 0
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

    /// Progress of the one-time, blocking search-index upgrade (nil when
    /// idle). When non-nil the app shows a non-dismissible sheet that blocks
    /// all UX. P5: the upgrade RUNS IN THE DAEMON (plan 5.2) — this state is
    /// a projection of the daemon's `wikid.search-upgrade-event.v1` progress
    /// envelopes, applied through ``applySearchUpgradeProgress``. It only
    /// appears when the daemon's embedder is loaded AND its missing-work
    /// scan found content; the common launch is an instant no-op.
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
    /// `await`, so a second trigger that fires during the daemon-start
    /// suspension sees it true and bails.
    @ObservationIgnored private var isUpgrading = false

    /// P5: the daemon-only backfill trigger. The session wiring injects ONE
    /// closure that starts the daemon-side embedding backfill
    /// (`RemoteWikiStore.startSearchUpgrade`) and answers whether a run
    /// actually started (the sheet appears from the daemon's first progress
    /// event, not from this answer). `nil` — local/test compositions — makes
    /// ``upgradeSearchIndex`` a link-reconcile-only no-op. The closure is
    /// main-actor-safe and returns false when the daemon cannot start a run
    /// (unavailable, embedder missing, or nothing missing).
    @ObservationIgnored public var startSearchUpgradeBackfill: (() async -> Bool)?
    @ObservationIgnored private var didReconcileLinksInThisSession = false

    /// Live SOURCES search query from the Sources search bar. Debounced 300ms.
    /// Mirrors the page `searchQuery` (semantic cosine, LIKE fallback).
    public var sourceSearchQuery: String = "" {
        didSet { scheduleSourceSearch() }
    }
    /// Results of the last sources search (empty when sourceSearchQuery is empty).
    public private(set) var sourceSearchResults: [SourceSummary] = []
    @ObservationIgnored private var sourceSearchTask: Task<Void, Never>?

    /// Live search query from the Chats sidebar search bar. Debounced 300ms.
    /// Mirrors `searchQuery`/`sourceSearchQuery` (hybrid RRF, FTS fallback).
    public var chatSearchQuery: String = "" {
        didSet { scheduleChatSearch() }
    }
    /// Results of the last chats search (empty when chatSearchQuery is empty).
    public private(set) var chatSearchResults: [ChatSummary] = []
    @ObservationIgnored private var chatSearchTask: Task<Void, Never>?

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
    ///
    /// `private(set)` (module-internal read) so `WikiRenderContext.build(from:)`
    /// can stamp it into the snapshot — consumers compare a context's
    /// `generation` to detect stale link resolution without touching the model.
    @ObservationIgnored private(set) var renderContextGeneration: UInt64 = 0
    /// The snapshot captured at ``cachedRenderContext`` build time, so a reload
    /// that leaves the generation unchanged (e.g. a bookmark-only change) doesn't
    /// spuriously rebuild. Compared against ``renderContextGeneration``.
    @ObservationIgnored private var renderContextBuiltAtGeneration: UInt64 = .max
    /// The machine availability revision captured at ``cachedRenderContext``
    /// build time. A renderer-registry refresh bumps
    /// ``rendererMachineAvailabilityRevision``; the next `renderContext()` call
    /// rebuilds so new/removed fence claims apply with no restart.
    @ObservationIgnored private var renderContextBuiltAtAvailabilityRevision: UInt64 = 0

    /// Built-in renderer descriptors, injected once by the app wiring where the
    /// installed-renderer host lives (the trusted table is app-layer data; this
    /// module cannot define it). Until injection, rich fences degrade to typed
    /// raw code — the same fail-closed posture as an unavailable claimant.
    @ObservationIgnored public var rendererBuiltInDescriptors: [RendererDescriptor] = [] {
        didSet {
            guard rendererBuiltInDescriptors != oldValue else { return }
            rendererMachineAvailabilityRevision &+= 1
        }
    }

    /// Available installed renderer descriptors from the app-scoped
    /// ``InstalledRendererHost`` snapshot, threaded in by the app wiring.
    /// Superseded and safe-mode-suppressed packages drop out here, so their
    /// fence claims drop out of every render context. A change bumps the
    /// renderer availability revision and invalidates the memoized context.
    @ObservationIgnored public var rendererAvailableDescriptors: [RendererDescriptor] = [] {
        didSet {
            guard rendererAvailableDescriptors != oldValue else { return }
            rendererMachineAvailabilityRevision &+= 1
        }
    }

    /// Aliases every render-context build has seen claimed, available or not.
    /// Memory is deliberately per-session: it lets a removed or suppressed
    /// claimant's fences explain their fallback ("renderer not available
    /// here") while fences nobody ever claimed stay silent plain code.
    /// Internal: the render-context build reads and updates it.
    @ObservationIgnored var resolvedFenceAliases: Set<RendererFenceAlias> = []

    func noteResolvedFenceAliases(_ aliases: Set<RendererFenceAlias>) {
        resolvedFenceAliases.formUnion(aliases)
    }

    /// The sidebar selection: a page, the system-prompt document, or nothing.
    public var selection: WikiSelection?

    /// Whether the trailing change-log sidebar (`log.md`) is shown in this
    /// wiki's window. Hidden by default; toggled from the window toolbar.
    /// Lives on the store (not view `@State`) so the sidebar's own close
    /// button and the toolbar toggle share one source of truth.
    public var isChangeLogSidebarVisible = false
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

    /// `true` when the active tab is showing the markdown editor — a
    /// `PageDetailView` or `SourceDetailView` in edit mode (the two surfaces
    /// backed by `DropLinkTextView`; see `Sources/WikiFS/Editor/DropLinkTextView.swift`).
    /// Both views sync their local `@State isEditing` into `EditorTab.isEditing`
    /// via `setTabEditing(tabID:isEditing:)`, so reading the tab here is the
    /// single source of truth.
    ///
    /// Used by `WikiDetailView.body` to gate its parent-level `.dropDestination`
    /// on `wikiSidebarItem`: while editing, the destination is removed so a
    /// sidebar drag inserts a `[[wikilink]]` at the editor's drop point (issue #616)
    /// instead of opening a new tab. Other surfaces (`SystemPromptDetailView`,
    /// `ChatDetailView`, welcome screen, reader mode) never set `isEditing`, so they
    /// keep the tab-opening drop behavior — matching the original semantics.
    public var isActiveTabEditing: Bool {
        activeTab?.isEditing ?? false
    }

    /// The removable list of ingested files (Phase 5). Like `summaries`, this is
    /// ALWAYS rebuilt from `store.listSources()` after a change, never
    /// incrementally patched (§3.1). Most-recent-first.
    public private(set) var sources: [SourceSummary] = []
    /// UI status for whether the source's current content has completed an
    /// agent Ingest run. The store's `ingested_at` marker is cleared whenever
    /// source content changes; free-text logs are not completion evidence.
    private var sourceIngestedStatus: [SourceID: Bool] = [:]

    /// Monotonic counter bumped on every `reloadSources()`. Extraction and
    /// transcript writes (`appendDerivedMarkdown`) never touch the `sources`
    /// row, so a rebuild can produce an `==` `sources` array and
    /// `.onChange(of: sources)` never fires — leaving the reader on a stale
    /// `headVersion` after import auto-extraction (#1179). This counter always
    /// changes, so views observe it via `.onChange(of: sourcesVersion)` to
    /// reload per-source derived state after any store mutation (local writes
    /// self-manage through `reloadSources()`; external writes arrive via the
    /// `WikiEventBus` → `reloadFromStore()` → `reloadSources()`).
    public private(set) var sourcesVersion: Int = 0

    // MARK: - Bookmark nodes (v16 — Bookmarks sidebar tree)

    /// Flat bookmark nodes, rebuilt from store after mutation (§3.1 pattern).
    public private(set) var bookmarkNodes: [BookmarkNode] = []

    /// Persisted chat summaries (issue #119), most-recently-updated first —
    /// rebuilt from `store.listChats()` after every mutation (§3.1 pattern),
    /// like `bookmarkNodes`.
    public private(set) var chats: [ChatSummary] = []

    /// Monotonic counter bumped on every `reloadChats()`. `ChatSummary` (the
    /// chat-list model) doesn't carry per-message fields, so a
    /// `chat_messages.summary` write produces an `==` `chats` array and
    /// `.onChange(of: chats)` never fires — leaving the outline on a stale nil
    /// summary (#858). This counter always changes, so views observe it via
    /// `.onChange(of: messageVersion)` to reload per-message state after any
    /// store mutation (local writes self-manage through `reloadChats()`;
    /// external writes arrive via the `WikiEventBus` → `reloadFromStore()` →
    /// `reloadChats()`).
    public private(set) var messageVersion: Int = 0

    /// A pending question to pre-fill the chat composer, set by the omnibox
    /// "Ask" action (#288). Consumed by `ChatDetailView` on first appearance, then
    /// cleared. `nil` means no pre-fill is waiting.
    public var pendingChatQuestion: String?

    /// The chat created by the most recent ``beginNewChat(prefill:)`` whose
    /// composer still needs keyboard focus. `beginNewChat` opens a DURABLE
    /// `.chat(id)` tab, so `ChatDetailView`'s legacy `chatID == nil` autofocus
    /// never fires for it — this marker is how the new chat's detail view
    /// knows it was just created and should focus its composer once. Consumed
    /// (cleared) by ``consumeComposerFocusRequest(for:)`` the moment the
    /// focus actually lands, so navigating away and back to the same tab
    /// doesn't steal focus again.
    public private(set) var pendingComposerFocusChatID: ChatID?

    /// Rebuild `chats` from the store. Best-effort (`try?`) — the history list
    /// degrading to empty on a store hiccup must never crash the sidebar.
    ///
    /// Every visible row lives in SQLite (new chats are persisted by
    /// ``beginNewChat()`` before their tab opens), so this is a plain
    /// rebuild — no overlay merging.
    ///
    /// Chat tabs store their title as a SNAPSHOT, re-derived only on tab
    /// operations — so a daemon-side title write (first-send provisional, or
    /// the summarizer's model-refined title) must re-derive the open chat
    /// tabs' titles HERE. Otherwise the sidebar recovers after a reload while
    /// the tab bar keeps a stale "New Chat".
    public func reloadChats() {
        enqueueCoalescedReload()
    }

    private func reloadChatsAsync() async {
        await chats = DebugLog.trying("listChats", operation: { try await store.listChats() }) ?? []
        messageVersion &+= 1
        for index in tabs.indices {
            guard case .chat = tabs[index].selection else { continue }
            let title = tabTitle(for: tabs[index].selection)
            if tabs[index].title != title {
                tabs[index].title = title
            }
        }
    }

    /// Create a durable empty chat AND open its tab (#1223 successor). The
    /// `chats` row is written through ``WikiStore.createChat`` FIRST — an
    /// empty-title `.edit` chat — so the tab, the sidebar row, the first
    /// send, and later navigation all share one `ChatID` from the first
    /// frame. ACP startup stays lazy: the daemon creates its controller on
    /// the first send, and the local outgoing echo covers that latency.
    ///
    /// `prefill` (the omnibox "Ask" question) is installed only AFTER the
    /// store write succeeds, so a failed creation never leaks the question
    /// into an unrelated chat later. `attachments` rides the same composed
    /// store write: the chats row and the `chat_attachments` rows persist in
    /// ONE transaction, so a failure leaves nothing behind and a success
    /// means the chips are already durable (the composer restores them from
    /// SQLite at mount).
    ///
    /// The new `ChatSummary` is inserted into the local array before the tab
    /// opens (same synchronous-cache pattern as `startChat`): the event bus
    /// fires `reloadFromStore()` async after the store write, but the
    /// immediate caller (openTab → tabTitle) reads `chats` synchronously, so
    /// the row must be present NOW.
    ///
    /// Empty chats are durable resources: they survive tab closure until the
    /// user deletes them. On a store failure, no tab, sidebar row, reveal,
    /// selection, prefill, or attachment rows happen — the existing
    /// `storeError` alert surfaces the failure instead.
    public func beginNewChat(prefill: String? = nil,
                             attachments: [ChatAttachmentTarget] = []) async {
        let chat: ChatSummary
        do {
            chat = try await store.createChat(
                kind: .edit, title: "", attachments: attachments)
        } catch {
            DebugLog.store("WikiStoreModel.beginNewChat failed: \(error)")
            storeError = StoreError(
                title: "Could Not Create Chat",
                message: "The chat could not be created: \(error.localizedDescription)")
            return
        }
        if let prefill {
            pendingChatQuestion = prefill
        }
        chats.insert(chat, at: 0)
        // One-shot composer-focus request: the new chat's detail view is built
        // with `chatID != nil`, so the legacy draft autofocus doesn't apply —
        // without this, creating a chat leaves keyboard focus wherever it was
        // and the user has to click into the composer before typing.
        pendingComposerFocusChatID = chat.id
        openTab(.chat(chat.id))
        // The persisted row becomes visible and selected in the Chats sidebar.
        requestSidebarReveal(.chat(chat.id))
        await refreshProjectionsAfterOwnWrite()
    }

    /// One-shot consumption of ``pendingComposerFocusChatID``: clears it when
    /// (and only when) it still points at `chatID`. Called by the chat
    /// detail view after its composer actually became first responder, so the
    /// request survives until focus lands but never re-fires on later
    /// navigation to the same tab. A `nil` chatID (the legacy draft surface)
    /// never consumes the request.
    public func consumeComposerFocusRequest(for chatID: ChatID?) {
        guard let chatID, pendingComposerFocusChatID == chatID else { return }
        pendingComposerFocusChatID = nil
    }

    /// Write the provisional first-line title for a chat the app just sent
    /// to, and reflect it in the local cache immediately (synchronous cache
    /// pattern, same as ``beginNewChat()``). The daemon derives the identical
    /// text at submit, so the two writes converge; this one makes the title
    /// visible the moment the user sends, without waiting on cross-process
    /// change delivery. No-op when the row already has a title (a rename or a
    /// prior send), the derivation yields nothing usable (#1265 — the row
    /// stays genuinely untitled and the next send retries), or the write
    /// fails.
    public func applyProvisionalChatTitle(chatID: ChatID, userText: String) async {
        guard let row = chats.first(where: { $0.id == chatID }),
              row.title.isEmpty,
              let title = ChatSummary.title(fromFirstMessage: userText) else { return }
        do {
            try await internalStore.setChatTitleIfEmpty(chatID: chatID, title: title)
            // Write-acknowledgment: the caller reads `chats` right after this
            // returns, so the projection must be current NOW (same invariant
            // as the model's other store-write methods; the bus drain is
            // async and would race the read).
            await refreshProjectionsAfterOwnWrite()
        } catch {
            DebugLog.store("WikiStoreModel.applyProvisionalChatTitle failed: \(error)")
        }
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

    /// Live chat composer buffer — the single source of in-flight chat text.
    /// Stashed per-tab via `EditorTab.pendingChatDraft` (like draftTitle/draftBody
    /// for pages) so switching tabs and back preserves unsent composer text
    /// (issue #430). ChatDetailView binds ComposerTextView to `$store.draftChatMessage`
    /// instead of local @State, which would be lost on view recreation.
    public var draftChatMessage: String = ""

    /// Number of concurrent agent runs (interactive sessions or one-shot
    /// one-shot agent operations) currently writing to THIS wiki. When the LAST
    /// run ends, the model reloads from the store so the sidebar reflects the
    /// agent's writes. No longer a mutex — CAS (page versions, W0) prevents
    /// data races so concurrent edits are fine; `save()` catches
    /// `PageConflictError` and surfaces a "Page Was Updated" dialog.
    public private(set) var agentRunCount = 0

    /// True while an ingest is in progress — covers BOTH the pdf2md extraction
    /// phase AND the agent run. Set at the top of `runMultiIngest` BEFORE
    /// extraction begins, so the Edit preflight blocks during the extraction
    /// window too (issue #235). The ingest's own `run()` preflight does NOT
    /// check this flag, so there is no self-deadlock. Cleared on early exit or
    /// process termination.
    public private(set) var isIngestInProgress = false

    /// Phase 7: capability flag for workspace-isolated ingestion. When true,
    /// `AgentOperationRunner.runMultiIngest` creates a workspace, passes the
    /// workspace ID to the launcher (which injects `WIKI_WORKSPACE` into the
    /// child process's per-spawn environment — NOT process-global `setenv`),
    /// and auto-merges on completion. Defaults to `false` — existing behavior
    /// is unchanged when the flag is off.
    public var workspacesEnabled: Bool = false

    // MARK: - Workspace facades (Phase 7)

    /// Create a workspace (delegates to the store). Used by
    /// `AgentOperationRunner` when `workspacesEnabled` is on.
    @discardableResult
    public func createWorkspace(name: String?, activityID: String?) async throws -> WorkspaceID {
        let workspaceID = try await store.createWorkspace(name: name, activityID: activityID)
        await refreshProjectionsAfterOwnWrite()
        return workspaceID
    }

    /// Merge a workspace into main (delegates to the store). Used by
    /// `AgentOperationRunner` to auto-merge after an isolated ingest.
    @discardableResult
    public func workspaceMerge(workspaceID: WorkspaceID) async throws -> [String] {
        let mergedTargets = try await store.workspaceMerge(workspaceID: workspaceID)
        await refreshProjectionsAfterOwnWrite()
        return mergedTargets
    }

    /// Reap stale open workspaces (delegates to the store).
    @discardableResult
    public func reapStaleWorkspaces(ttl: TimeInterval) async throws -> Int {
        let reapedCount = try await store.reapStaleWorkspaces(ttl: ttl)
        await refreshProjectionsAfterOwnWrite()
        return reapedCount
    }

    private let store: WikiStore

    /// The underlying concrete `WikiStore` (concretely `RemoteWikiStore` in
    /// the app, `GRDBWikiStore` in local/test compositions). Exposed for the
    /// session wiring (remote composition + the daemon-only search-upgrade
    /// trigger) and the explicit in-memory reader fallback.
    public var internalStore: WikiStore { store }

    /// Stable Tantivy BM25 facade. It starts unavailable and is installed only
    /// after the per-wiki runtime finishes rebuild and buffered-event catch-up.
    /// Typed failures map to a missing BM25 leg; semantic search remains usable.
    /// P5: the app injects the DAEMON-backed facade (`DaemonSearchServices`)
    /// — autocomplete and the UI search-provider seams only; the sidebar
    /// hybrid search itself is a single store-family round trip (the daemon
    /// fuses BM25 + semantic and replies with final results).
    @ObservationIgnored public var searchServices: any SearchServices = UnavailableSearchServices()

    /// The configured HTML extraction backend (issue #799 PR2). Set at app
    /// wiring time from `ExtractionConfig.htmlSelectionLabel` — the canonical
    /// HTML route selection, which is where the retired `ExtractionConfig
    /// .htmlBackend` field used to feed in before #1178 removed it — so the
    /// Extract button and the "Re-extract with" menu have a default to use
    /// when the user taps Extract without picking a backend explicitly.
    /// `nil` = no default chosen (a fresh install, or no HTML route record)
    /// — the menu then lists `HtmlExtractionBackend.allCases` so the
    /// user picks one. The process extraction facade resolves the selected
    /// adapter when extraction starts.
    @ObservationIgnored public var htmlBackend: HtmlExtractionBackend?

    /// The active extractor registrations' declared input surface, set at app
    /// wiring time from `ExtractionBackendRegistry.registeredExtractionInputs()`
    /// and pushed straight to the store. Registration-driven recognition: a
    /// generic archive container an ACTIVE registration declares as its input
    /// (a `.docx` IS a zip) classifies and stores as the registered type at
    /// ingestion — the package's registration is the declaration that this
    /// content has an extraction path. `.none` (the default) keeps sniff-only
    /// behavior for hosts that do not wire it (CLI, daemon, tests).
    @ObservationIgnored public var registeredExtractionInputs: RegisteredExtractionInputs = .none {
        didSet { store.registeredExtractionInputs = registeredExtractionInputs }
    }

    /// Source-format claims from the active, validated renderer catalog. This
    /// remains separate from extractor registration and only propagates the
    /// composition snapshot to the underlying store.
    @ObservationIgnored public var registeredRendererSourceTypes: RegisteredRendererSourceTypes = .none {
        didSet { store.registeredRendererSourceTypes = registeredRendererSourceTypes }
    }

    /// Import-time auto-extraction, wired at session boot. WHICH kinds
    /// convert at import comes from package data, not host branches: the
    /// wiring derives the kinds set from the active registration claims
    /// minus the host catalog's built-in routes (package-only kinds), and
    /// the claimed kind selects the conversion. The model never names a
    /// kind — and never converts one: the claimed source is enqueued as a
    /// durable format job through the session's queue-engine client, the
    /// daemon executes the conversion, and progress/status arrive over the
    /// queue event stream.
    @ObservationIgnored public var importAutoExtractionKinds: Set<ExtractorKind> = []
    /// The import format-job enqueue seam, set at session boot from the
    /// session's queue-engine client (the hot-swap daemon client). The
    /// enqueue is durable — `queue.sqlite` — so a conversion survives app
    /// closure; `nil` for hosts without a queue (plain fixtures).
    @ObservationIgnored public var enqueueImportFormatJob:
        (@Sendable (SourceID) async throws -> Void)?
    /// Sources whose import-time auto-extraction is currently running.
    /// Observable so the source detail can show the same "Extracting…"
    /// state the queue tracker drives, and disable the manual Extract
    /// button for the duration — a fresh import otherwise shows its raw
    /// state with no indication that a conversion is already in flight.
    public private(set) var importExtractingSourceIDs: Set<SourceID> = []
    private var autosaveTask: Task<Void, Never>?

    deinit {
        // Cancel pending debounced search tasks so they don't fire after the
        // model is deallocated — a leaked Task's dbQueue.read would crash with
        // "Database methods are not reentrant" if a subsequent test's write
        // is in progress on the same DatabaseQueue.
        MainActor.assumeIsolated {
            searchTask?.cancel()
            sourceSearchTask?.cancel()
            chatSearchTask?.cancel()
            autosaveTask?.cancel()
        }
    }
    /// The page whose text currently lives in the draft buffers.
    private var loadedPage: PageID?
    /// Bumped whenever a clean reload assigns draft content from the store
    /// (`reloadCurrentDraftIfCleanAsync`). A selection-transition load that
    /// read the page BEFORE the bump knows its store-seeded draft is staler
    /// than what a clean reload already placed, and skips that assignment
    /// instead of clobbering fresher content with its earlier read.
    private var draftContentStamp = 0
    /// The page-content version id captured when the page was loaded into the
    /// editor. Used as the CAS expectation when saving (W0, PR #312): if another
    /// writer committed a new version after the editor loaded, the save throws
    /// `PageConflictError` instead of silently clobbering.
    private var loadedPageHeadVersionID: PageVersionID?
    /// What the drafts currently hold, so a flush saves the RIGHT document even
    /// after `selection` has advanced (§3.5 read-state-at-save-time).
    private var loadedSelection: WikiSelection?
    /// Plan P1.3: the last selection a transition was REQUESTED for, set
    /// synchronously at every `selection` write site (beginSelectionTransition,
    /// setActiveTab, navigateCurrentTab, retargetTab). `loadedSelection` only
    /// updates when the async load lands and must not gate user-facing
    /// decisions (history recording, echo suppression) that used to be
    /// synchronous pre-flip.
    @ObservationIgnored private var requestedSelection: WikiSelection?
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
    /// Suppresses double-processing in `handleSelectionChange` while a tab switch
    /// is mid-flight (`setActiveTab` assigns `selection`, which fires the view's
    /// `onChange(of: selection)` bridge). Set in exactly one place —
    /// `setActiveTab(_:)`. Follows the same pattern as `isApplyingHistorySelection`.
    @ObservationIgnored private var isApplyingTabSelection = false
    private static let navigationHistoryLimit = 100
    private static let maxRecentlyClosedTabs = 10
    /// Technique label for synthetic byteless-source markdown written from oEmbed
    /// metadata + URL (no transcript). Issue #646.
    private static let bytelessMetadataTechnique = "byteless-oembed-synthetic"
    /// Technique label for synthetic byteless-source markdown written from oEmbed
    /// metadata + URL + a transcript (e.g. YouTube captions). Issue #646.
    private static let bytelessTranscriptTechnique = "byteless-oembed-transcript"
    /// Technique label for the Apple Podcasts TTML-derived transcript markdown
    /// written by `transcribePodcast(sourceID:origin:fetcher:)` (issue #799 PR4).
    /// Stamped on the `source_markdown_versions` row so the provenance chip's
    /// alternatives UI surfaces the producer alongside `byteless-oembed-synthetic`
    /// (for the byteless-media sources) and `defuddle` / `html-to-markdown` /
    /// `pdf2md` / etc. (for the PDF/HTML sources).
    private static let podcastTtmlTechnique = "apple-ttml"
    /// Technique label for the YouTube caption-derived transcript markdown
    /// that older builds wrote through the direct fetch path (issue #799 PR5).
    /// Mirrors the `podcastTtmlTechnique` shape: stamped on the
    /// `source_markdown_versions` row so the provenance chip reports the
    /// producer. New YouTube transcripts are written by the extraction queue
    /// with installed-package provenance; this constant remains as the
    /// historical label for rows written before the youtube-transcript
    /// package route (the literal string is byte-identical to the one the
    /// pre-PR5 ingest-time auto-fetch wrote).
    private static let youtubeCaptionsTechnique = "youtube-captions"
    /// Technique label for the generic RSS-feed podcast transcript markdown
    /// written by the pre-package inline path. New RSS podcast transcripts
    /// carry the installed-package producer instead; this label survives only
    /// as the legacy-row mapping in `transcriptTool(for:)`.
    private static let rssPodcastTranscriptTechnique = "rss-podcast-transcript"

    private static func transcriptTool(for technique: String) -> ExtractionTool {
        switch technique {
        case youtubeCaptionsTechnique: return .youtubeCaptions
        case rssPodcastTranscriptTechnique: return .rssPodcastTranscript
        case podcastTtmlTechnique: return .appleTTML
        case ExtractionTool.vimeoTranscript.rawValue: return .vimeoTranscript
        default: return .transcript
        }
    }
    /// The synthetic MIME for a byteless Apple Podcasts embed source (issue
    /// #799 PR4). `ExternalEmbed.target(for:)` dispatches on the provider's
    /// `agentName == "apple-podcast"` (NOT the MIME — see the dispatch table
    /// in `ExternalEmbed.swift`), so this label is near-cosmetic: it persists
    /// the source's content-type taxonomy alongside the byteless-media
    /// convention (`video/youtube`, `audio/spotify`, …) and keeps
    /// `isMarkdownNative` from misclassifying a byteless podcast source as
    /// text-native (which would skip the embed-player render path).
    private static let podcastEmbedMIME = "audio/apple-podcast"

    public init(store: WikiStore) {
        self.store = store
        subscribeToChanges()
    }

    /// Plan P1.3 — async bootstrap. Session construction performs NO store
    /// work; the session loader (`AppProcessProfileOwner.bootWikiSession` /
    /// `SessionManager`) awaits this once before handing the session to the
    /// UI, so views never observe a half-booted model. Idempotent: the
    /// coalesced-reload queue serializes it against later event-driven
    /// reloads.
    public func bootstrapFromStore() async {
        await reloadSummariesAsync()
        await reloadSourcesAsync()
        await reloadBookmarkNodesAsync()
        await reloadChatsAsync()
        await preloadRenderContextInputs()
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

    /// Plan P1.3 — generation-checked loads. Bumped at every selection
    /// transition; an async load whose captured generation is stale is
    /// discarded, so rapid A→B→C navigation lands only C's data.
    @ObservationIgnored private var loadGeneration = 0

    /// Plan P1.3 — coalesced, serialized event reloads. Bus callbacks enqueue
    /// instead of reloading inline: while a reload is in flight further events
    /// set `reloadPending`, and the in-flight task drains the coalesced flag
    /// in a loop — overlapping events produce ONE reload, never interleaved
    /// half-reloads. (Serialization is by MainActor isolation; the loop below
    /// owns the flag.)
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadPending = false

    /// Plan P1.3 test/harness seam support: the newest in-flight selection
    /// transition task (`beginSelectionTransition`) or draft-load task
    /// (`loadDrafts`), tagged with the generation that spawned it so a
    /// superseded task finishing late cannot clear a newer task's slot.
    /// `quiesceSelectionTransitions()` drains this and `reloadTask`.
    @ObservationIgnored private var selectionTransitionTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTransitionTaskGeneration = 0

    /// Plan P1.3: the newest fire-and-forget save/flush task
    /// (`fixMarkdownInDraft`, `navigateCurrentTab`'s captured-draft flush),
    /// tagged with a sequence so a superseded task finishing late cannot clear
    /// a newer task's slot. `quiesceSelectionTransitions()` drains it alongside
    /// the transition and reload tasks so settled-state readers observe
    /// committed store state.
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveTaskSequence = 0

    /// Clear the tracked transition task when the task tagged `generation`
    /// finishes — only if no newer transition has already claimed the slot.
    private func clearSelectionTransitionTask(generation: Int) {
        if selectionTransitionTaskGeneration == generation {
            selectionTransitionTask = nil
        }
    }

    /// Clear the tracked save task when the task tagged `sequence` finishes —
    /// only if no newer save has already claimed the slot.
    private func clearPendingSaveTask(sequence: Int) {
        if pendingSaveTaskSequence == sequence {
            pendingSaveTask = nil
        }
    }

    private func subscribeToChanges() {
        changeToken = store.eventBus?.subscribe(nil) { [weak self] _ in
            self?.enqueueCoalescedReload()
        }
    }

    /// Bus-driven entry point: coalesces overlapping events into one reload.
    private func enqueueCoalescedReload() {
        if reloadTask != nil {
            reloadPending = true
            return
        }
        reloadTask = Task { [weak self] in
            await self?.drainCoalescedReloads()
        }
    }

    private func drainCoalescedReloads() async {
        await reloadFromStoreAsync()
        while reloadPending {
            reloadPending = false
            await reloadFromStoreAsync()
        }
        reloadTask = nil
    }

    // MARK: - Selection / loading

    /// Plan P1.3 — one captured outgoing document state, taken synchronously
    /// at the START of a selection transition so the switch-away cannot lose
    /// or mix drafts when the flush runs inside the serialized task.
    private struct PendingDraftSnapshot {
        let selection: WikiSelection?
        let title: String
        let body: String
        let dirty: Bool
        /// The outgoing page's head-version id at capture time — the flush's
        /// CAS expectation (H5, same seam as `save()`). `nil` when the
        /// outgoing selection wasn't a loaded page (no expectation to match).
        let headVersionID: PageVersionID?
    }

    /// Bounded retry count for the consistent head+page pair read in
    /// `loadDraftsAsync` (H8: head → page → head; a moved head retries the
    /// whole pair).
    @ObservationIgnored private static let maxConsistentPageReadAttempts = 3

    /// H6 — snapshots of failed transition flushes, keyed by page. A flush
    /// that could not persist the outgoing draft (store error or page
    /// conflict) retains its captured text here so the next load of that page
    /// can restore it into the editor (dirty, ready to re-save) instead of
    /// silently dropping the user's unsaved work. Cleared when the page's
    /// draft is restored on load or a save for the page succeeds.
    ///
    /// F5: bounded at ``maxFailedFlushSnapshots`` entries. Insertion order is
    /// tracked in ``failedFlushSnapshotOrder``; inserting into a full
    /// dictionary evicts the oldest-inserted entry (a re-retain of an
    /// existing key counts as a fresh insertion). All mutation goes through
    /// ``retainFailedFlushSnapshot`` / ``takeFailedFlushSnapshot`` /
    /// ``retireFailedFlushSnapshot`` so the dict and the order array cannot
    /// drift apart.
    @ObservationIgnored private var failedFlushSnapshots: [PageID: PendingDraftSnapshot] = [:]

    /// F5: insertion order of `failedFlushSnapshots` keys, oldest first.
    @ObservationIgnored private var failedFlushSnapshotOrder: [PageID] = []

    /// F5: the failed-flush retention bound (entries across ALL pages).
    @ObservationIgnored private static let maxFailedFlushSnapshots = 32

    /// H6/F5: retain a failed-flush snapshot for `id`, evicting the
    /// oldest-inserted entry when at the bound.
    private func retainFailedFlushSnapshot(_ snapshot: PendingDraftSnapshot, for id: PageID) {
        if let existing = failedFlushSnapshotOrder.firstIndex(of: id) {
            // Re-retain of an existing key counts as a fresh insertion: move
            // it to the newest slot.
            failedFlushSnapshotOrder.remove(at: existing)
        }
        failedFlushSnapshotOrder.append(id)
        failedFlushSnapshots[id] = snapshot
        if failedFlushSnapshotOrder.count > Self.maxFailedFlushSnapshots {
            let evictedID = failedFlushSnapshotOrder.removeFirst()
            failedFlushSnapshots.removeValue(forKey: evictedID)
            DebugLog.store("WikiStoreModel: failed-flush retention full (\(Self.maxFailedFlushSnapshots)) — evicted the oldest snapshot (page \(evictedID.rawValue))")
        }
    }

    /// H6: consume the page's retained snapshot for restore, or `nil`.
    private func takeFailedFlushSnapshot(for id: PageID) -> PendingDraftSnapshot? {
        guard let snapshot = failedFlushSnapshots.removeValue(forKey: id) else { return nil }
        failedFlushSnapshotOrder.removeAll { $0 == id }
        return snapshot
    }

    /// H6: retire the page's snapshot without consuming it (its draft is
    /// durably written now).
    private func retireFailedFlushSnapshot(for id: PageID) {
        guard failedFlushSnapshots.removeValue(forKey: id) != nil else { return }
        failedFlushSnapshotOrder.removeAll { $0 == id }
    }

    /// Switch the selection programmatically. Plan P1.3 — the transition is
    /// SERIALIZED and generation-checked: the outgoing draft state is
    /// captured synchronously (before any suspension), the editor clears
    /// eagerly so the outgoing draft never flashes onto the incoming
    /// selection, and one task performs flush→load in order. A rapid
    /// A→B→C navigation bumps the generation three times; only C's load
    /// lands (stale completions are discarded).
    public func select(_ newValue: WikiSelection?) {
        guard newValue != selection else { return }
        beginSelectionTransition(to: newValue)
    }

    /// Bridge for SwiftUI's `List(selection:)`, which writes `selection`
    /// DIRECTLY (bypassing `select(_:)`). The view observes the property with
    /// `.onChange(of:)` and calls this. Plan P1.3 — same serialized,
    /// generation-checked transition as `select(_:)`: the outgoing document's
    /// edits are persisted before the incoming one loads (§3.5), with the
    /// outgoing state captured before any suspension.
    public func handleSelectionChange(to newValue: WikiSelection?) {
        // Skip if triggered programmatically by a tab switch, or if the view's
        // `onChange` bridge is echoing back a selection this model already
        // requested (Plan P1.3: compare against `requestedSelection`, which is
        // set synchronously at every selection write — `loadedSelection` lags
        // until the async load lands, so it can no longer suppress echoes).
        guard !isApplyingTabSelection, newValue != requestedSelection else { return }
        beginSelectionTransition(to: newValue)

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

    /// Plan P1.3 — the synchronous entry of every selection transition:
    /// capture outgoing state, bump the generation, clear the editor, and
    /// spawn the serialized flush→load task. In-memory bookkeeping only; the
    /// store work happens inside the transition task.
    private func beginSelectionTransition(to newValue: WikiSelection?) {
        let outgoing = PendingDraftSnapshot(
            selection: loadedSelection,
            title: draftTitle,
            body: draftBody,
            dirty: isDraftDirty,
            headVersionID: loadedPageHeadVersionID)
        loadGeneration &+= 1
        let generation = loadGeneration
        // Plan P1.3: history keys off the REQUESTED selection — the selection
        // the user is navigating FROM — not `loadedSelection`, which only
        // updates when the async load lands and is stale/nil mid-flight (a
        // rapid A→B used to record nothing, leaving the back stack empty).
        // Read BEFORE `requestedSelection` is advanced below.
        recordHistoryTransition(from: requestedSelection, to: newValue)
        selection = newValue
        requestedSelection = newValue
        // Eager clear: while the incoming load is in flight the editor shows
        // an empty draft, never the outgoing page's text (the old synchronous
        // path never had this window; the generation check keeps a rapid
        // switch sequence from mixing pages).
        draftTitle = ""
        draftBody = ""
        isDraftDirty = false
        loadedPage = nil
        loadedPageHeadVersionID = nil
        fenceSaveWarning = nil
        markdownSaveWarning = nil
        markdownWarningTask?.cancel()
        markdownWarningTask = nil
        // H4 — transitions are SERIALIZED, not merely newest-tracked: capture
        // the predecessor slot before spawning and chain the new task onto
        // it. Predecessor completion implies its flush finished AND its stale
        // load aborted (the generation check), so two transitions can never
        // flush or load interleaved. The newest slot still tracks only the
        // latest task; quiesce awaits it, which transitively awaits the chain.
        let predecessor = selectionTransitionTask
        let task = Task { [weak self] in
            await predecessor?.value
            await self?.performSelectionTransition(
                outgoing: outgoing,
                to: newValue,
                generation: generation)
            self?.clearSelectionTransitionTask(generation: generation)
        }
        selectionTransitionTask = task
        selectionTransitionTaskGeneration = generation
    }

    /// The serialized transition body: flush the OUTGOING draft (captured
    /// values — not the live properties, which now belong to the incoming
    /// selection), then load the incoming selection. A stale generation
    /// aborts between the two halves so a rapid switch never commits a save
    /// derived from mixed state.
    private func performSelectionTransition(
        outgoing: PendingDraftSnapshot,
        to newValue: WikiSelection?,
        generation: Int
    ) async {
        await flushCapturedDraft(outgoing)
        guard generation == loadGeneration else { return }
        await loadDraftsAsync(for: newValue, generation: generation)
    }

    /// Plan P1.3 test/harness seam: awaits until every in-flight selection
    /// transition task and the coalesced reload queue have drained, so callers
    /// that need the SETTLED model state (hosted tests, golden-master export)
    /// can await it. Fire-and-forget UI callers must NOT need this — production
    /// views observe the model via @Observable and never read-then-assert.
    ///
    /// The loop re-checks after each await: completing one task can spawn or
    /// coalesce more work (a reload event arriving mid-drain, a newer
    /// transition requested while an older one was finishing).
    public func quiesceSelectionTransitions() async {
        while true {
            let transition = selectionTransitionTask
            let reload = reloadTask
            let pendingSave = pendingSaveTask
            if let transition {
                await transition.value
            }
            if let reload {
                await reload.value
            }
            if let pendingSave {
                await pendingSave.value
            }
            // Re-check: completing one can spawn or coalesce more work (a
            // reload event arriving mid-drain, a newer transition requested
            // while an older one was finishing).
            if selectionTransitionTask == nil, reloadTask == nil,
               pendingSaveTask == nil { break }
        }
    }

    /// Persist one captured draft snapshot to its selection. Extracted from
    /// the save path so the transition task can flush the OUTGOING document
    /// with the values captured before the switch (plan P1.3 — replaces the
    /// synchronous flush-before-switch ordering). Same seam as `save()`:
    /// the shared `PageUpsert.upsert` write with the CAS head expectation.
    private func flushCapturedDraft(_ snapshot: PendingDraftSnapshot) async {
        guard snapshot.dirty, let selection = snapshot.selection else { return }
        switch selection {
        case .page(let id):
            do {
                try await PageUpsert.upsert(
                    in: store, id: id, title: snapshot.title, body: snapshot.body,
                    expectedHeadVersionID: snapshot.headVersionID, author: PageAuthor.user.rawValue)
                // H6: the outgoing draft is durable now — retire any
                // failed-flush retention for this page.
                retireFailedFlushSnapshot(for: id)
                // M9: write-acknowledgment — the transition continues into the
                // incoming page's load right after this flush, so the list
                // projections must reflect the flush's write before it runs.
                await refreshProjectionsAfterOwnWrite()
            } catch {
                DebugLog.store("WikiStoreModel.flushCapturedDraft failed (page \(id.rawValue)): \(error)")
                // H6: retain the captured draft so the next load of this page
                // restores the user's unsaved text into the editor (dirty,
                // ready to re-save) instead of dropping it.
                retainFailedFlushSnapshot(snapshot, for: id)
                // P1.4: surface the failure through the same non-fatal alert
                // as `save()`. The editor was already cleared at transition
                // start, so a swallowed flush silently lost the outgoing
                // draft with no UI signal; `storeError` is the model's
                // failure projection. A `PageConflictError` (H5: the flush
                // now CAS-expects the captured head) surfaces here too —
                // never retried unrestricted.
                storeError = StoreError(
                    title: "Page Not Saved",
                    message: "The edit to “\(snapshot.title)” could not be saved before leaving the page: \(error.localizedDescription)")
            }
        case .chat, .newChat, .bookmark, .strategy, .source, .changeLog:
            break // non-page selections carry no editable page draft
        }
    }

    public func navigateBack() {
        guard let destination = backStack.popLast() else { return }
        // Plan P1.3: push the REQUESTED selection (where the user is), not
        // `loadedSelection` — the latter lags until the async load lands and
        // would drop the forward entry on a mid-flight back-navigation.
        if let current = requestedSelection {
            forwardStack.append(current)
        }
        applyHistorySelection(destination)
    }

    public func navigateForward() {
        guard let destination = forwardStack.popLast() else { return }
        if let current = requestedSelection {
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
        pageID(forTitle: title) != nil
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
        guard let id = pageID(forTitle: title) else { return false }
        let target = WikiSelection.page(id)
        // Stash the anchor so the destination WikiReaderView can scroll to it
        // after render. Tagged with the target selection so a stale anchor can't
        // misfire on the wrong page.
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        pendingScrollAnchorVersion += 1
        // Record history against the REQUESTED selection — the last selection
        // a transition was requested for, tracked synchronously — so a
        // mid-flight async load cannot drop the outgoing entry
        // (openTab/setActiveTab/navigateCurrentTab don't record history
        // themselves).
        recordHistoryTransition(from: requestedSelection, to: target)
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
        recordHistoryTransition(from: requestedSelection, to: target)
        if openInNewTab {
            openTab(target)
        } else {
            navigateCurrentTab(to: target)
        }
        return true
    }

    /// Opens the configured home page when it still exists in this wiki.
    /// Returns `false` for an unset or stale home-page ID.
    @discardableResult
    public func openHomePageIfConfigured(homePageID: PageID?) -> Bool {
        guard let homePageID else { return false }
        return selectPage(byID: homePageID)
    }

    // MARK: - Source link resolution

    /// Existence check for `[[source:…]]` linkification: returns `true` when a
    /// source with the given display name (or filename fallback) exists.
    public func sourceExists(displayName: String) -> Bool {
        sourceID(forDisplayName: displayName) != nil
    }

    /// `(bytes, mimeType)` for the blob scheme handler (`wiki-blob://`). `nil` =
    /// unknown id (→ 404); empty `Data` = byteless source (→ 200 empty body);
    /// else the blob bytes + MIME. Used by `BlobSchemeHandler` to serve source
    /// content to the WKWebView for `![[source:…]]` embeds. Looks up the MIME
    /// type from the loaded `sources` list (which mirrors `store.listSources()`)
    /// rather than calling the store directly, since `getSource(id:)` is concrete
    /// on `GRDBWikiStore`, not on the `WikiStore` protocol.
    @MainActor public func sourceContentAndMIME(id: SourceID) async -> (data: Data, mimeType: String?)? {
        guard let summary = sources.first(where: { $0.id == id }) else { return nil }
        let data = await DebugLog.trying("sourceContent", operation: { try await store.sourceContent(id: id) }) ?? Data()
        return (data, summary.mimeType)
    }

    /// Semantic search for pages matching `query`. Delegates to the store's
    /// hybrid search (FTS5 bm25 always; +MiniLM cosine fused via RRF when the
    /// model is available). Runs the query embedding + SQLite on the main actor
    /// — fine for the one-shot callers (the "Find Similar…" link menu builds its
    /// submenu once per right-click, not per render). The old per-row sidebar caller that froze the UI was removed.
    ///
    /// One-shot hybrid page search (the "Find Similar…" right-click menu via
    /// `WikiLinkMenuNSItems`, one submenu per right-click). P5: the DAEMON
    /// resolves the Tantivy BM25 leg (#637) and fuses it with the semantic
    /// cosine leg server-side, so this is a single store round trip that
    /// lands the full fused ordering — the menu still surfaces fuzzy
    /// (edit-distance 1) matches post-#634 (no FTS5). Cosine-only results
    /// when the daemon's index is unavailable — the documented degradation.
    public func searchSimilar(query: String, limit: Int = 8) async -> [WikiPageSummary] {
        guard !query.isEmpty else { return [] }
        return await DebugLog.trying("searchSimilar", operation: { try await store.searchSimilar(query: query, limit: limit, bm25Leg: nil) }) ?? []
    }

    /// Semantic source search wrapper — same hybrid store search as
    /// `searchSimilar`, over sources.
    public func searchSimilarSources(query: String, limit: Int = 20) async -> [SourceSummary] {
        await DebugLog.trying("searchSimilarSources", operation: { try await store.searchSimilarSources(query: query, limit: limit, bm25Leg: nil) }) ?? []
    }

    /// Hybrid chat search wrapper — same hybrid store search as
    /// `searchSimilar`, over chats. Used by the Chats sidebar search field.
    public func searchSimilarChats(query: String, limit: Int = 20) async -> [ChatSummary] {
        await DebugLog.trying("searchSimilarChats", operation: { try await store.searchSimilarChats(query: query, limit: limit, bm25Leg: nil) }) ?? []
    }

    /// Unified omnibox search across all resource types (#288). Returns a
    /// ranked, deduplicated `[OmniboxResult]` that mixes pages, sources, chats,
    /// and bookmark nodes. The result always starts with an `.ask(question:)`
    /// action row (so the user can send the query straight to chat), followed by
    /// up to 3 pages, 2 sources, 2 chats, and 3 bookmark matches.
    public func searchOmnibox(query: String) async -> [OmniboxResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [OmniboxResult] = []

        // 1. The "Ask" action row — always first, so Enter sends to chat.
        results.append(.ask(question: trimmed))

        // 2. Pages (daemon-fused BM25 + semantic).
        let pages = (await DebugLog.trying("searchOmniboxPages", operation: {
            try await store.searchSimilar(query: trimmed, limit: 3, bm25Leg: nil)
        }) ?? [])
        results.append(contentsOf: pages.map { .page($0) })

        // 3. Sources (daemon-fused BM25 + semantic).
        let sources = (await DebugLog.trying("searchOmniboxSources", operation: {
            try await store.searchSimilarSources(query: trimmed, limit: 2, bm25Leg: nil)
        }) ?? [])
        results.append(contentsOf: sources.map { .source($0) })

        // 4. Chats (daemon-fused BM25 + semantic).
        let chats = (await DebugLog.trying("searchOmniboxChats", operation: {
            try await store.searchSimilarChats(query: trimmed, limit: 2, bm25Leg: nil)
        }) ?? [])
        results.append(contentsOf: chats.map { .chat($0) })

        // 5. Bookmarks (plain substring over folder labels + resolved ref titles).
        let matchingBookmarks = searchBookmarks(query: trimmed).prefix(3).map { node in
            OmniboxResult.bookmark(node: node, resolvedTitle: resolveBookmarkTitle(node))
        }
        results.append(contentsOf: matchingBookmarks)

        return results
    }

    /// Substring search over bookmark nodes — matches folder labels and the
    /// resolved title of page/source/chat refs. Returns matching nodes plus
    /// their ancestor folders (so a hit inside a collapsed folder is visible).
    /// Inlined here (in WikiFSCore) so the omnibox search can use it without
    /// crossing into the WikiFS UI module (#288, mirrors #240's logic).
    private func searchBookmarks(query: String) -> [BookmarkNode] {
        guard !query.isEmpty else { return bookmarkNodes }
        let byID = Dictionary(uniqueKeysWithValues: bookmarkNodes.map { ($0.id, $0) })

        var matchingIDs = Set<BookmarkID>()
        for node in bookmarkNodes {
            let title = resolveBookmarkTitle(node)
            if title.localizedCaseInsensitiveContains(query) {
                matchingIDs.insert(node.id)
            }
        }

        var visibleIDs = Set<BookmarkID>()
        for id in matchingIDs {
            var current: BookmarkID? = id
            while let cid = current, let node = byID[cid] {
                visibleIDs.insert(cid)
                current = node.parentID
            }
        }
        return bookmarkNodes.filter { visibleIDs.contains($0.id) }
    }

    /// Resolves the display title for a bookmark node: folder label, or for
    /// refs, the title/name of the target page/source/chat (#240 / #288).
    private func resolveBookmarkTitle(_ node: BookmarkNode) -> String {
        switch node.content {
        case .folder(let label): return label
        case .page(let id): return summaries.first { $0.id == id }?.title ?? ""
        case .source(let id): return sources.first { $0.id == id }?.effectiveName ?? ""
        case .chat(let id): return chats.first { $0.id == id }?.title ?? ""
        }
    }

    /// Resolve a sidebar drag payload to a human-readable name for display
    /// in the chat attachment chips (issue #385). Mirrors the bookmark title
    /// resolution, but works off `SidebarDragPayload` directly.
    public func resolveAttachmentName(for payload: SidebarDragPayload) -> String? {
        let pageID = PageID(rawValue: payload.id)
        switch payload.kind {
        case .page:
            return summaries.first { $0.id == pageID }?.title
        case .source:
            return sources.first { $0.id.rawValue == pageID.rawValue }?.effectiveName
        case .chat:
            return chats.first { $0.id.rawValue == pageID.rawValue }?.title
        }
    }

    /// Replaces a chat's persisted attachment targets (the composer's chips).
    /// Failures surface through the same non-fatal `storeError` alert the
    /// composed-create failure path uses — a chip write that did not persist
    /// means the chips would silently vanish at restart, so the user must
    /// see it. The in-memory chips stay authoritative either way; the next
    /// mutation retries the write.
    public func setChatAttachments(chatID: ChatID, targets: [ChatAttachmentTarget]) async {
        do {
            try await store.setChatAttachments(chatID: chatID, targets: targets)
        } catch {
            DebugLog.store(
                "WikiStoreModel.setChatAttachments failed for \(chatID.rawValue): \(error)")
            storeError = StoreError(
                title: "Couldn't Save Chat Attachments",
                message: "The attachments could not be saved: \(error.localizedDescription)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// A chat's ordered attachment targets. Empty on any read failure: the
    /// composer then restores to nothing rather than failing the mount.
    public func chatAttachments(chatID: ChatID) async -> [ChatAttachmentTarget] {
        do {
            return try await store.chatAttachments(chatID: chatID)
        } catch {
            DebugLog.store(
                "WikiStoreModel.chatAttachments failed for \(chatID.rawValue): \(error)")
            return []
        }
    }

    /// Resolve a page title to its id (lowest-ULID on a duplicate-title
    /// collision, matching the link graph). Best-effort: `nil` on any error or
    /// when no page matches. Used by "Copy File Path" to build the mount path.
    public func pageID(forTitle title: String) -> PageID? {
        // Loaded-state resolver (plan P1.3): the bootstrapped summaries
        // mirror the store rows, so navigation resolution never round-trips
        // the store. Lowest ULID wins on a duplicate-title collision — the
        // same rule as the store's resolveTitleToID.
        summaries.filter { $0.title == title }
            .map(\.id)
            .min(by: { $0.rawValue < $1.rawValue })
    }

    /// Resolve a source display name (or filename fallback) to its id
    /// (most-recently-updated on collision). Best-effort: `nil` on any error or
    /// no match. Used by "Copy File Path" to build the source's mount path.
    public func sourceID(forDisplayName displayName: String) -> SourceID? {
        // Loaded-state resolver (plan P1.3): display name first, filename
        // fallback, most-recently-updated on collision — mirroring
        // resolveSourceByName over the bootstrapped `sources` projection.
        sources.filter { $0.displayName == displayName || $0.filename == displayName }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .id
    }

    /// Resolve a chat title to its id (lowest-ULID on a duplicate-title
    /// collision). Best-effort: `nil` on any error or when no chat matches.
    public func chatID(forTitle title: String) -> ChatID? {
        // Loaded-state resolver (plan P1.3): lowest ULID on a duplicate-title
        // collision, over the bootstrapped `chats` projection.
        chats.filter { $0.title == title }
            .map(\.id)
            .min(by: { $0.rawValue < $1.rawValue })
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
    public func selectSource(byDisplayName displayName: String, anchor: String? = nil, openInNewTab: Bool = false) async -> Bool {
        guard let id = sourceID(forDisplayName: displayName) else { return false }
        let target = WikiSelection.source(id)
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        pendingScrollAnchorVersion += 1
        recordHistoryTransition(from: requestedSelection, to: target)
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
    public func selectSource(byID id: SourceID, anchor: String? = nil,
                             openInNewTab: Bool = false,
                             pinnedExtractionID: SourceMarkdownVersionID? = nil) async -> Bool {
        guard sources.contains(where: { $0.id == id }) else { return false }
        let target = WikiSelection.source(id)
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        // Phase 6: stash the pinned-extraction id alongside the anchor (same
        // counter — the pin travels with its anchor). Set-once/consume-once.
        pendingPinnedExtraction = pinnedExtractionID.map { (selection: target, versionID: $0) }
        pendingScrollAnchorVersion += 1
        recordHistoryTransition(from: requestedSelection, to: target)
        if openInNewTab {
            openTab(target)
        } else {
            navigateCurrentTab(to: target)
        }
        return true
    }

    // MARK: - Chat link resolution

    /// Clears the active chat tab's composer draft — both the live
    /// `draftChatMessage` buffer and the stashed `pendingChatDraft`. Called by
    /// `ChatDetailView.sendMessage` after a message is sent so the text doesn't
    /// reappear on tab switch-back (issue #430).
    public func clearActiveChatDraft() {
        draftChatMessage = ""
        if let tabID = activeTabID, let i = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[i].pendingChatDraft = nil
        }
    }

    /// Navigate to the chat with `id` from a clicked canonical
    /// `wiki://chat?id=<ULID>` link. A direct selection — no title resolution,
    /// so it is stable across renames. Returns `false` when the id names no
    /// loaded chat (a deleted target), so the caller can fall back to
    /// title-based selection.
    ///
    /// - Parameter anchor: optional `#"quote"` fragment from a
    ///   `[[chat:Title#"quote"]]` link (issue #281); the destination `ChatDetailView`
    ///   resolves it to a message, scrolls it into view, and highlights the
    ///   passage — the chat analogue of `selectSource(anchor:)`. Mirrors the
    ///   page/source anchor seam: tagged with `.chat(id)` + versioned.
    @discardableResult
    public func selectChat(byID id: ChatID, anchor: String? = nil, openInNewTab: Bool = false) -> Bool {
        guard chats.contains(where: { $0.id == id }) else { return false }
        let target = WikiSelection.chat(id)
        pendingScrollAnchor = anchor.map { (selection: target, fragment: $0) }
        pendingScrollAnchorVersion += 1
        recordHistoryTransition(from: requestedSelection, to: target)
        if openInNewTab {
            openTab(target)
        } else {
            navigateCurrentTab(to: target)
        }
        return true
    }

    /// Navigate to the chat with `title` from a clicked `[[chat:Title]]` link.
    /// Resolves title → id via `resolveChatByTitle` (lowest-ULID on a duplicate-
    /// title collision) and records navigation history. Returns whether
    /// navigation happened. `anchor` carries an optional `#"quote"` fragment
    /// (issue #281); see `selectChat(byID:anchor:)`.
    @discardableResult
    public func selectChat(byTitle title: String, anchor: String? = nil, openInNewTab: Bool = false) -> Bool {
        guard let id = chatID(forTitle: title) else { return false }
        return selectChat(byID: id, anchor: anchor, openInNewTab: openInNewTab)
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
    public private(set) var pendingPinnedExtraction: (selection: WikiSelection, versionID: SourceMarkdownVersionID)?

    /// Atomically consume the pending pinned-extraction id if `selection`
    /// matches. Returns the smv id once and clears the state; nil if the
    /// selection doesn't match or there is no pending pin. Mirrors
    /// `consumePendingScrollAnchor`.
    public func consumePendingPinnedExtraction(for selection: WikiSelection?) -> SourceMarkdownVersionID? {
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
        // Stash the outgoing chat tab's composer draft so it survives the
        // switch-back (issue #430). Unconditional — the composer is always
        // "drafting"; there's no edit-mode gate like the page editor.
        if let outgoingID = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == outgoingID }) {
            switch tabs[i].selection {
            case .newChat, .chat:
                tabs[i].pendingChatDraft = draftChatMessage
            default:
                break
            }
        }
        isApplyingTabSelection = true
        activeTabID = id
        let sel = tabs.first { $0.id == id }?.selection
        selection = sel
        // Plan P1.3: keep the requested selection in lockstep with every
        // synchronous `selection` write, or the view's async `onChange` echo
        // would pass the `handleSelectionChange` guard and re-enter a
        // transition for a selection the model already owns.
        requestedSelection = sel
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
        if tabs[i].isPinned {
            openTab(target)
            return
        }
        // Plan P1.3: capture the outgoing draft synchronously, clear the
        // editor, then flush the CAPTURED state from a task — the same
        // serialized pattern as beginSelectionTransition (§3.5: the
        // switch-away cannot lose buffered edits).
        let outgoing = PendingDraftSnapshot(
            selection: loadedSelection,
            title: draftTitle,
            body: draftBody,
            dirty: isDraftDirty,
            headVersionID: loadedPageHeadVersionID)
        autosaveTask?.cancel()
        autosaveTask = nil
        isApplyingTabSelection = true
        tabs[i].selection = target
        tabs[i].title = tabTitle(for: target)
        selection = target
        requestedSelection = target // Plan P1.3: sync write sites stay in lockstep
        draftTitle = ""
        draftBody = ""
        isDraftDirty = false
        loadedPage = nil
        loadedPageHeadVersionID = nil
        loadDrafts(for: target)
        isApplyingTabSelection = false
        // Plan P1.3: the in-place flush rides the tracked pending-save slot
        // (same seam as fixMarkdownInDraft) so quiesce settles it too. Slot
        // split is deliberate (review F8): this flush rides `pendingSaveTask`
        // while the incoming load chains on `selectionTransitionTask` —
        // cross-slot, different pages, no editor contamination. Residual:
        // the two slots are not ordered against each other, so a summary
        // read can be momentarily stale until the bus-driven reload lands.
        pendingSaveTaskSequence += 1
        let flushSequence = pendingSaveTaskSequence
        let flushTask = Task { [weak self] in
            await self?.flushCapturedDraft(outgoing)
            self?.clearPendingSaveTask(sequence: flushSequence)
        }
        pendingSaveTask = flushTask
        DebugLog.store("[tabs] navigateCurrentTab: in-place to \(target) (id=\(activeID)), \(tabs.count) tabs total")
    }

    /// Open the tab for `selection`: if one is already open, focus it (reuse,
    /// never duplicate); otherwise create a new tab and focus it. This holds for
    /// every selection type — pages and files reuse just like the singletons
    /// (.newChat, .changeLog) — so clicking a page or a
    /// `[[wiki-link]]` that's already open returns to its tab instead of spawning
    /// a copy.
    public func openTab(_ selection: WikiSelection, title: String? = nil) {
        clickStartedAt = DispatchTime.now()
        // Don't reuse draft-state tabs (.newChat) — multiple drafts are valid (#348).
        if selection != .newChat, let existing = tabs.first(where: { $0.selection == selection }) {
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
        // Don't dedup draft-state tabs (.newChat) — multiple drafts are valid (#348).
        if selection != .newChat, tabs.contains(where: { $0.selection == selection }) { return }
        let tab = EditorTab(selection: selection, title: title ?? tabTitle(for: selection))
        tabs.append(tab)
        DebugLog.store("[tabs] openTabInBackground: new background tab for \(selection) (id=\(tab.id)), \(tabs.count) tabs total")
    }

    /// Retarget an open tab IN PLACE to a new selection, preserving the tab's
    /// UUID — so tab order, drag/drop position, and per-tab history survive (D2).
    /// Kept for the legacy `AgentOperationRunner` chat path (start + rollback);
    /// the app's New Chat flow persists the chat first and never retargets.
    /// If no tab
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
        // Exception: .newChat is a compatibility draft state, not a unique
        // resource — don't reuse an existing draft tab when retargeting to
        // .newChat (#348).
        if selection != .newChat, let existing = tabs.first(where: { $0.selection == selection }), existing.id != id {
            selectTab(id: existing.id)
            return
        }
        tabs[index].selection = selection
        tabs[index].title = tabTitle(for: selection)
        // If this is the active tab, sync selection + drafts so the view updates.
        if activeTabID == id {
            isApplyingTabSelection = true
            self.selection = selection
            requestedSelection = selection // Plan P1.3: sync write sites stay in lockstep
            loadDrafts(for: selection)
            isApplyingTabSelection = false
        }
        DebugLog.tabs("[tabs] retargetTab: tab \(id) → \(selection)")
    }

    /// Convenience: retarget the ACTIVE tab to `.chat(chatID)`. Used by the
    /// legacy `AgentOperationRunner.startChat` path, which persists the chat
    /// row itself and morphs the active draft tab in place (the app's New
    /// Chat flow persists first and opens `.chat(id)` directly instead).
    /// No-op if there is no active tab. Reloads the chats list and requests a
    /// sidebar reveal so the committed row is selected and scrolled into view.
    public func retargetActiveTabToChat(chatID: ChatID) {
        guard let activeID = activeTabID else { return }
        retargetTab(id: activeID, to: .chat(chatID))
        reloadChats()
        requestSidebarReveal(.chat(chatID))
    }

    /// Switch the active tab by ID. No-op if the ID is unknown or already active.
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }), id != activeTabID else { return }
        setActiveTab(id)
    }

    /// Move a tab to a new position in the bar (drag-to-reorder, #1388).
    /// `newIndex` is the FINAL index in the array after the move (clamped to
    /// bounds). The active tab is tracked by ID, so it stays active through the
    /// move; per-tab state (pin, edit mode, drafts) travels with the tab.
    /// Unknown IDs and no-op moves are ignored.
    public func moveTab(id: UUID, to newIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(newIndex, 0), tabs.count - 1)
        guard from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        DebugLog.tabs("[tabs] moveTab: tab \(id) moved \(from) → \(to)")
    }

    /// Persist the editor's edit-mode state to the given tab so that
    /// switching back to it can restore the mode.
    public func setTabEditing(tabID: UUID, isEditing: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].isEditing = isEditing
    }

    /// Toggle whether a tab keeps its current selection during ordinary
    /// navigation. Unknown tab IDs are ignored so context-menu actions remain
    /// safe if the tab closes before the action is delivered.
    public func toggleTabPin(id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].isPinned.toggle()
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
        tabs[index].pendingChatDraft = nil
        // A closing strategy tab takes its model-held draft with it — the
        // user just confirmed the discard (pendingCloseTabID pattern).
        if case .strategy = tabs[index].selection {
            discardStrategyDraftForClosedTab()
        }
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
        tabs[i].pendingChatDraft = nil
        loadDrafts(for: selection)
    }

    private func applyCloseTab(id: UUID, at index: Int) {
        let closed = tabs.remove(at: index)
        pushRecentlyClosed(closed)
        // Chats are durable: closing a chat tab never deletes its row.
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
        if lastClosed.selection != .newChat,
           let existing = tabs.first(where: { $0.selection == lastClosed.selection }) {
            setActiveTab(existing.id)
            return
        }
        tabs.append(lastClosed)
        setActiveTab(lastClosed.id)
    }

    /// Push a closed tab onto the reopen stack, capping at `maxRecentlyClosedTabs`.
    private func pushRecentlyClosed(_ tab: EditorTab) {
        recentlyClosedTabs.append(tab)
        if recentlyClosedTabs.count > Self.maxRecentlyClosedTabs {
            recentlyClosedTabs.removeFirst()
        }
    }

    /// Date formatter for default untitled page titles, so rapid page
    /// creation doesn't collide or look identical in the sidebar.
    private static let untitledDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// The default title for a new page: "Untitled" + a timestamp so multiple
    /// new pages are distinguishable and unlikely to collide.
    public static func defaultUntitledTitle() -> String {
        "Untitled \(untitledDateFormatter.string(from: Date()))"
    }

    /// Create a new page and open it in a new tab.
    public func newPageInNewTab(title: String = WikiStoreModel.defaultUntitledTitle()) async {
        await flushPendingSaves()
        do {
            let page = try await store.createPage(title: title, createdBy: "user")
            try await store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(page.bodyMarkdown))
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write. The title is passed to openTab explicitly, so tabTitle
            // (which reads `summaries`) is never called and needs no synchronous freshness.
            openTab(.page(page.id), title: title)
            // New pages start in the editor so the user lands on the source view,
            // not an empty rendered page. Per-tab (not global): navigation-opened
            // pages keep their own mode. `PageDetailView.onAppear` seeds from this
            // and its `.onChange(of: isEditing)` expands the header for free.
            if let id = activeTabID {
                setTabEditing(tabID: id, isEditing: true)
            }
        } catch {
            DebugLog.store("WikiStoreModel.newPageInNewTab failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// SYNC fire-and-forget entry for callers outside a selection transition
    /// (history navigation, agent-run end, tab retarget): bumps the generation
    /// (invalidating any in-flight stale load) and spawns the generation-
    /// checked async load. Plan P1.3.
    private func loadDrafts(for newValue: WikiSelection?) {
        loadGeneration &+= 1
        let generation = loadGeneration
        // Plan P1.3: this spawned load feeds the same tracking slot as a
        // full transition (tab switches ride setActiveTab → loadDrafts), so
        // `quiesceSelectionTransitions()` settles openTab/selectTab too.
        // H4: it rides the SAME serialization — chained onto the predecessor
        // slot — so a tab switch's load can never interleave with an
        // in-flight transition's flush/load.
        let predecessor = selectionTransitionTask
        let task = Task { [weak self] in
            await predecessor?.value
            await self?.loadDraftsAsync(for: newValue, generation: generation)
            self?.clearSelectionTransitionTask(generation: generation)
        }
        selectionTransitionTask = task
        selectionTransitionTaskGeneration = generation
    }

    /// Plan P1.3 — the async draft load with a generation check. The
    /// transition task calls this after flushing the outgoing draft; a load
    /// whose generation has been superseded by a newer selection transition
    /// discards its results (rapid A→B→C navigation lands only C).
    /// Same body as the pre-P1 synchronous `loadDrafts(for:)`; the tab
    /// pending-draft stashes are read here, on the main actor, as before.
    private func loadDraftsAsync(for newValue: WikiSelection?, generation: Int) async {
        // Generation gate BEFORE the reads: a newer transition owns the
        // editor state now.
        guard generation == loadGeneration else { return }
        loadedSelection = newValue
        // A page switch invalidates the prior page's lint warnings so a stale
        // banner doesn't bleed onto an unrelated page (they're recomputed on
        // save). The markdown lint is computed on a background Task, so also
        // cancel the in-flight lint — otherwise page A's findings can land
        // after the switch and write the stale banner onto page B.
        fenceSaveWarning = nil
        markdownSaveWarning = nil
        markdownWarningTask?.cancel()
        markdownWarningTask = nil
        var restoredFromPendingDraft = false
        var restoredFromFailedFlush = false
        switch newValue {
        case .newChat, .bookmark, .chat, .strategy:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
            loadedPageHeadVersionID = nil
        case .page(let id):
            let stampBeforeRead = draftContentStamp
            // H8 — the body and its head-version id must be read as a
            // CONSISTENT PAIR: reading them across separate awaits lets an
            // intervening writer pair a stale body with a newer head, and a
            // later edit would then pass CAS against that head and clobber
            // the writer's version. Read head → page → head; a changed head
            // means a writer landed mid-read, so retry the pair (bounded).
            // F2/H8: after the bound, the expectation falls back to the head
            // read BEFORE the body (`readPreBodyHeadVersionID`) — the
            // expectation the loaded content was actually read against. The
            // final `headAfter` may postdate the body (writer committed
            // between the last getPage and the last head read), and saving a
            // pre-commit body against that post-commit head passes CAS and
            // silently clobbers the writer. The pre-body head is stale
            // whenever a writer landed, so the next save surfaces a visible
            // `PageConflictError` instead.
            var readPage: WikiPage?
            var readHeadVersionID: PageVersionID?
            var readPreBodyHeadVersionID: PageVersionID?
            var attempts = 0
            var pairStable = false
            while attempts < Self.maxConsistentPageReadAttempts {
                attempts += 1
                let headBefore = await DebugLog.trying("pageHeadVersionID", operation: { try await store.pageHeadVersionID(pageID: id) })
                let candidate = await DebugLog.trying("getPage", operation: { try await store.getPage(id: id) })
                guard let candidate else { break }
                let headAfter = await DebugLog.trying("pageHeadVersionID", operation: { try await store.pageHeadVersionID(pageID: id) })
                readPage = candidate
                readHeadVersionID = headAfter
                readPreBodyHeadVersionID = headBefore
                if headBefore == headAfter {
                    pairStable = true
                    break
                }
            }
            guard let page = readPage else {
                // Stale completion: a newer transition owns the editor state.
                guard generation == loadGeneration else { return }
                draftTitle = ""
                draftBody = ""
                loadedPage = nil
                loadedPageHeadVersionID = nil
                loadedSelection = nil
                return
            }
            if !pairStable {
                DebugLog.store("WikiStoreModel.loadDraftsAsync: head/page pair unstable for page \(id.rawValue) after \(attempts) attempt(s) — CAS expectation falls back to the pre-body head so the next save surfaces PageConflictError instead of clobbering a concurrent writer")
            }
            // Stale completion check AFTER the awaits: a newer transition
            // (A→B→C) must not have C's load overwritten by B's completion.
            guard generation == loadGeneration else { return }
            // A clean reload (external-write refresh) that assigned draft
            // content while this read was in flight owns the fresher text:
            // keep its content, but still adopt this load's bookkeeping
            // (loadedPage + head version) so the editor targets the right
            // page. A stale head-version expectation stays W0-safe: the next
            // save surfaces PageConflictError instead of silently clobbering.
            let cleanReloadSupersededRead = draftContentStamp != stampBeforeRead
            if !cleanReloadSupersededRead {
                draftTitle = page.title
                draftBody = PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
            }
            loadedPage = id
            // Capture the head version id for CAS on save (W0, PR #312): the
            // re-read head on the stable path, the pre-body head on the F2
            // unstable path (never `headAfter`, which can postdate the body).
            loadedPageHeadVersionID = pairStable ? readHeadVersionID : readPreBodyHeadVersionID
            // H6 — a flush for this page failed earlier (store error or page
            // conflict): restore its retained draft into the editor instead
            // of the store's last-committed text, so the user's unsaved work
            // reappears dirty and the next save persists it. F4b: the CAS
            // expectation stays the freshly-read head (assigned above) — the
            // snapshot's own headVersionID predates the current head, and
            // re-arming it would conflict immediately and lose anyway.
            var retainedFailedFlush: PendingDraftSnapshot?
            if let retained = takeFailedFlushSnapshot(for: id) {
                draftTitle = retained.title
                draftBody = retained.body
                restoredFromFailedFlush = true
                retainedFailedFlush = retained
            }
            // F4a: single owner. When a failed-flush snapshot was restored it
            // IS the user's text — the tab stash must not overwrite it after
            // the snapshot was consumed (the old order let the stash win and
            // silently drop the snapshot's text).
            if !restoredFromFailedFlush {
                // Restore stashed draft when returning to an editing tab.
                if let tabID = activeTabID,
                   let i = tabs.firstIndex(where: { $0.id == tabID }),
                   let pendingTitle = tabs[i].pendingDraftTitle,
                    let pendingBody = tabs[i].pendingDraftBody {
                    draftTitle = pendingTitle
                    draftBody = pendingBody
                    restoredFromPendingDraft = true
                }
            } else if let retained = retainedFailedFlush {
                // F4b: surface the failed flush on the restore path. The
                // snapshot also exists when the flush failed with a
                // PageConflictError — the restored body predates the current
                // head, so the next save dead-ends in a conflict alert unless
                // the user knows WHY the text came back dirty. Distinct,
                // actionable copy: the edit is preserved in the editor, the
                // page changed since, review and re-save.
                storeError = StoreError(
                    title: "Edit Not Saved",
                    message: "Your edit to “\(retained.title)” was preserved in the editor, but the page changed since the edit was written. Review the text, then save to keep it.")
            }
        case .changeLog:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
            loadedPageHeadVersionID = nil
        case .source:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
            loadedPageHeadVersionID = nil
        case nil:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
            loadedPageHeadVersionID = nil
        }
        // Restore the incoming tab's stashed chat composer draft (issue #430).
        // For chat tabs (.newChat/.chat) this restores unsent text; for all
        // other tab types pendingChatDraft is nil, so the composer is cleared.
        if let tabID = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == tabID }),
           let pending = tabs[i].pendingChatDraft {
            draftChatMessage = pending
        } else {
            draftChatMessage = ""
        }
        // A failed-flush restore (H6) must stay dirty even when no tab stash
        // was restored — the restored text is unsaved work awaiting re-save.
        isDraftDirty = restoredFromPendingDraft || restoredFromFailedFlush
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
        // Plan P1.3: history navigation rides the SAME serialized,
        // generation-checked transition as every other selection change
        // (recordHistoryTransition is suppressed by the guard flag below).
        isApplyingHistorySelection = true
        beginSelectionTransition(to: newValue)
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
        // No edit-lock pause — CAS (page versions, W0) prevents data races. If
        // another writer committed a new version, `save()` throws
        // `PageConflictError` and surfaces a "Page Was Updated" dialog.
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            // Task.sleep only throws CancellationError — expected, not actionable.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Persist the current drafts. Reads `loadedPage` (the page the drafts
    /// belong to) + `draftTitle` + `draftBody` AT CALL TIME (§3.5 live read) so
    /// a debounce that fires after further typing — or a flush triggered once
    /// `selection` has already advanced to the next page — still writes the
    /// freshest text to the RIGHT page. No-op when nothing is loaded.
    /// Always rebuilds `summaries` from source on success.
    public func save() async {
        guard let id = loadedPage else { return }
        // H3: the post-write editor bookkeeping must land on the page this
        // save was made FOR. Capture the load generation now; a navigation
        // that lands during the write bumps both `loadedPage` and the
        // generation, and the stale save must then leave the new page's
        // editor state alone.
        let capturedGeneration = loadGeneration
        do {
            // The shared upsert+reparse seam (Phase A): persist the body AND
            // re-resolve this page's `[[wiki-links]]` in one operation. `wikictl`
            // calls the SAME `PageUpsert.upsert`, so an in-app edit and a CLI
            // edit leave byte-identical `page_links` rows (no drift). v0
            // limitation: a *rename* does NOT re-walk the whole graph, so links
            // that targeted the old title go stale until the linking page is next
            // saved (they self-heal then).
            //
            // W0 (PR #312): the CAS expectation (`loadedPageHeadVersionID`) makes
            // conflicts visible — if another writer committed a new version after
            // the editor loaded, this throws `PageConflictError` instead of
            // silently clobbering.
            let savedTitle = draftTitle
            let savedBody = draftBody
            try await PageUpsert.upsert(in: store, id: id, title: savedTitle, body: savedBody,
                                  expectedHeadVersionID: loadedPageHeadVersionID,
                                  author: "user")
            // H3: apply the write's editor bookkeeping ONLY while the editor
            // still holds this page and no newer transition has begun — a
            // mid-write A→B switch must not stamp B's editor with A's dirty
            // clear or head-version expectation.
            if loadedPage == id, loadGeneration == capturedGeneration {
                // P1.4: clear the dirty flag only when the draft still matches
                // what this save wrote — a keystroke landing while the write is
                // in flight must keep the draft dirty (and its text), so a
                // follow-up save persists the newer content instead of the
                // reload treating the editor as clean and reverting it.
                if draftTitle == savedTitle, draftBody == savedBody {
                    isDraftDirty = false
                }
                // F3: the head re-read below AWAITS — the entry guard above is
                // stale by the time it returns if a navigation landed mid-read
                // (a new generation owns `loadedPage`/`loadedPageHeadVersionID`
                // then). Re-capture immediately after the await and gate the
                // head assignment plus the warning/retention mutations on it.
                let freshHead = await DebugLog.trying("pageHeadVersionID", operation: { try await store.pageHeadVersionID(pageID: id) })
                let generationStillCurrent = loadGeneration == capturedGeneration && loadedPage == id
                if generationStillCurrent {
                    // After a successful versioned save, refresh the head version
                    // id so the next save CAS-expects the version we just wrote.
                    loadedPageHeadVersionID = freshHead
                    // No manual reload — the bus fires reloadFromStore() async after the upsert.
                    // Non-blocking fence lint: the in-app save still succeeds (the
                    // editor is the human escape from wikictl's hard block), but a
                    // broken claimed fence is flagged so the author can fix it.
                    updateFenceWarning(for: draftBody)
                    // Non-blocking markdown lint: same pattern — save succeeds with the
                    // original text, cosmetic issues are flagged as informational.
                    updateMarkdownWarning(for: draftBody)
                    // H6: this page's draft is durable now — retire any
                    // failed-flush retention for it.
                    retireFailedFlushSnapshot(for: id)
                }
            }
            // M9: write-acknowledgment invariant — every model method that
            // performs a store write returns with the list projections current.
            await refreshProjectionsAfterOwnWrite()
        } catch let error as PageConflictError {
            // W0 (PR #312): a concurrent writer committed a new version. Surface
            // it so the user knows to re-load and merge their changes.
            DebugLog.store("WikiStoreModel.save: PageConflictError — pageID=\(error.pageID.rawValue) expected=\(error.expectedVersionID) actual=\(error.actualVersionID?.rawValue ?? "nil")")
            storeError = StoreError(
                title: "Page Was Updated",
                message: "Another writer updated this page since you started editing. Re-load the page and merge your changes.")
        } catch {
            // Phase 1: log to console; a save-error surface lands later.
            DebugLog.store("WikiStoreModel.save failed: \(error)")
        }
    }

    /// The last fence-syntax validation warning for the saved draft, or `nil`.
    /// Surfaced in the page editor as a non-blocking hint. Set on save
    /// (debounced), so it refreshes shortly after the author stops typing and
    /// re-saves.
    public var fenceSaveWarning: String?

    /// The package-driven fence-syntax validation used for the non-blocking
    /// save warning. Defaults to nil: the service depends on the machine
    /// renderer package store, which the app layer owns, so the app wiring
    /// injects a live-resolving service at composition time. Nil means
    /// "no claiming package installed" — validation skips, exactly like the
    /// old nil-validator contract. `@ObservationIgnored` — it's plumbing, not
    /// UI state.
    @ObservationIgnored
    public var fenceSyntaxValidator: (any FenceSyntaxValidating)? = nil

    /// Validate every claimed fence block in `body` and set
    /// `fenceSaveWarning`. The validator is package-driven: the claimed
    /// aliases and validation contracts come from installed renderer package
    /// manifests, not host format knowledge. Pages without a claimed fence
    /// pay only a cheap line scan.
    private func updateFenceWarning(for body: String) {
        guard let validator = fenceSyntaxValidator else {
            fenceSaveWarning = nil
            return
        }
        fenceSaveWarning = validator.fenceSaveWarning(for: body)
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
    /// in-place — the same normalization `wikictl page add` applies, but
    /// triggered manually from the in-app editor. No-op when the linter is
    /// unavailable or the body is already clean.
    public func fixMarkdownInDraft() async {
        guard let linter = markdownLinter else { return }
        let outcome = linter.fix(markdown: draftBody)
        guard outcome.fixed != draftBody else { return }
        draftBody = outcome.fixed
        // Plan P1.3: keep the fire-and-forget save, but track it so
        // `quiesceSelectionTransitions()` can settle the store write for
        // callers that read committed state (hosted tests, golden master).
        pendingSaveTaskSequence += 1
        let sequence = pendingSaveTaskSequence
        let task = Task { [weak self] in
            await self?.save()
            self?.clearPendingSaveTask(sequence: sequence)
        }
        pendingSaveTask = task
    }

    /// The in-flight markdown warning Task (if any). Cancelled before starting a
    /// new one, so rapid re-saves don't complete out of order and leave a stale
    /// `markdownSaveWarning` that doesn't match the just-saved body.
    @ObservationIgnored private var markdownWarningTask: Task<Void, Never>?

    /// Lint `body` for cosmetic markdown issues and set `markdownSaveWarning`.
    /// Unlike the fence validation (a cheap line scan), markdownlint runs all
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
    /// detect broken `[[wiki links]]`. Reads fresh from the store so it works for any
    /// page, not just the loaded draft. If the current page is loaded, also syncs the
    /// draft (without marking it dirty). Returns `nil` when the page cannot be read.
    public struct LintPreflight: Sendable {
        /// `true` when `WikiLinkFixer.applyFixes` rewrote one or more `\]]` brackets.
        public let didFixLinks: Bool
        /// Page titles referenced by `[[wiki links]]` in the page that do not resolve
        /// to an existing page.
        public let brokenPageLinks: [String]
        /// Source display names referenced by `[[source:…]]` in the page that do not
        /// resolve to an existing source.
        public let brokenSourceLinks: [String]
        /// Chat titles referenced by `[[chat:…]]` in the page that do not resolve
        /// to an existing chat.
        public let brokenChatLinks: [String]
    }

    public func preflightLint(pageID: PageID) async -> LintPreflight? {
        guard let page = await DebugLog.trying("getPage", operation: { try await store.getPage(id: pageID) }) else { return nil }

        // Apply WikiLinkFixer and persist if anything changed.
        let original = page.bodyMarkdown
        let fixedBody = WikiLinkFixer.applyFixes(to: original)
        let didFix = fixedBody != original
        if didFix {
            do {
                // #797: pre-fix this passed no `author:`, defaulting to nil,
                // which mapped to the shared `legacy-import` agent and erased
                // the prior `chat:<id>` / `agent:<kind>` provenance on the
                // HEAD row. The lint auto-fix is an explicit action by the
                // "lint" one-shot executor, NOT an unknown editor — stamp
                // `agent:lint` so the activity carries the real identity.
                try await PageUpsert.upsert(in: store, id: pageID, title: page.title, body: fixedBody,
                                      author: PageAuthor.agent("lint").rawValue)
                // M9: write-acknowledgment — this method reads fresh store
                // state on entry, so its own fix write must leave the list
                // projections current before it returns.
                await refreshProjectionsAfterOwnWrite()
                // No manual reload — the bus fires reloadFromStore() async after the upsert.
                if loadedPage == pageID {
                    draftBody = fixedBody
                    isDraftDirty = false
                }
            } catch {
                DebugLog.store("WikiStoreModel.preflightLint fix failed: \(error)")
            }
        }

        // Detect broken wiki links across all three namespaces.
        let body = didFix ? fixedBody : original
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = WikiLinkSpan.matches(in: body)
        let knownTitles = Set(summaries.map { $0.title })
        let knownPageIDs = Set(summaries.map { $0.id.rawValue.uppercased() })
        let allChats = await DebugLog.trying("listAllChatsOrderedByID", operation: { try await store.listAllChatsOrderedByID() }) ?? []
        let knownChatTitles = Set(allChats.map { $0.title })
        let knownChatIDs = Set(allChats.map { $0.id.rawValue.uppercased() })
        // Mirror replaceLinks: a link is broken only when NO candidate reading
        // of its raw target (per WikiLinkResolver — handles `#` in titles)
        // names an existing resource. Unique the output — two parsed links can
        // share a base since parse() de-dupes by raw target.
        var seenBroken = Set<String>()
        var brokenPages: [String] = []
        var brokenSources: [String] = []
        var brokenChats: [String] = []
        for match in matches {
            let fullRange = match.range
            // Skip links inside code spans / fenced blocks — `[[Like This]]`
            // in backticks is example text, not a real link.
            guard !WikiLinkSpan.isProtected(fullRange, by: codeRanges) else { continue }

            let rawTarget = ns.substring(with: match.range(at: 1))
            let aliasRange = match.range(at: 2)
            let rawAlias = aliasRange.location != NSNotFound ? ns.substring(with: aliasRange) : nil
            let fixed = WikiLinkFixer.fix(target: rawTarget, alias: rawAlias)
            let collapsed = WikiText.normalized(fixed.target)
            guard !collapsed.isEmpty else { continue }

            let (base, fragment) = WikiLinkParser.splitFragment(collapsed)
            guard !base.isEmpty else { continue }
            let (bareBase, _) = WikiLinkParser.splitVersionPin(base)
            let (kind, bareTarget) = WikiLinkParser.classify(bareBase)
            guard !bareTarget.isEmpty, !WikiLinkParser.isEmptyPrefix(bareBase) else { continue }

            let raw = fragment.map { "\(bareTarget)#\($0)" } ?? bareTarget

            let known: (String) -> Bool
            let knownIDs: Set<String>
            switch kind {
            case .page:
                known = { knownTitles.contains($0) }
                knownIDs = knownPageIDs
            case .source:
                // For source links, also check looseMatchKey so a name with a
                // dash variant still counts as resolved (mirrors the store's
                // resolveSourceByName pass 3 and the projection's LinkMaps).
                let sourceIDs = Set(sources.map { $0.id.rawValue.uppercased() })
                known = { [self, sourceIDs] name in
                    if let sourceID = WikiLinkResolver.legacySourceProjectionID(from: name),
                       sourceIDs.contains(sourceID.rawValue.uppercased()) {
                        return true
                    }
                    return self.sources.contains { $0.effectiveName == name }
                        || self.sources.contains { WikiNameRules.looseMatchKey($0.effectiveName) == WikiNameRules.looseMatchKey(name) }
                }
                knownIDs = sourceIDs
            case .chat:
                known = { knownChatTitles.contains($0) }
                knownIDs = knownChatIDs
            }

            // Canonical ULID links (resolved at save time) are never broken —
            // the ULID is a stable id, not a title to look up by name.
            if WikiLinkParser.isCanonicalULID(bareTarget) {
                guard !knownIDs.contains(bareTarget.uppercased()) else { continue }
            } else {
                guard WikiLinkResolver.resolvedSplit(of: raw, isKnown: known) == nil else { continue }
            }

            let label = fixed.alias.map { WikiText.normalized($0) } ?? bareTarget
            let dedupLabel = label.isEmpty ? bareTarget : label
            guard seenBroken.insert("\(kind.rawValue):\(dedupLabel)").inserted else { continue }
            switch kind {
            case .page:   brokenPages.append(dedupLabel)
            case .source: brokenSources.append(dedupLabel)
            case .chat:   brokenChats.append(dedupLabel)
            }
        }

        return LintPreflight(didFixLinks: didFix,
                             brokenPageLinks: brokenPages,
                             brokenSourceLinks: brokenSources,
                             brokenChatLinks: brokenChats)
    }

    /// Cancel any pending debounce and save synchronously. Called on page
    /// switch and on app backgrounding (§3.5 immediate-on-background).
    /// No-op when the draft hasn't been modified since the last load/save
    /// (prevents bumping `updated_at` on a tab switch for a view-only page).
    public func flushPendingSave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDraftDirty else { return }
        // H3: capture the saved page BEFORE the await — a concurrent switch
        // can move `loadedPage` while `save()` is in flight.
        let savedPage = loadedPage
        await save()
        // Clear the SAVED tab's stash — the tab whose selection matches the
        // page this flush persisted — not whatever tab is active by the time
        // the await resumes (H3: the active tab may have changed mid-write,
        // and clearing its stash would drop an unrelated tab's unsaved text).
        guard let savedPage,
              let i = tabs.firstIndex(where: { $0.selection == .page(savedPage) }) else { return }
        tabs[i].pendingDraftTitle = nil
        tabs[i].pendingDraftBody = nil
    }

    /// Flush pending page edits. Used on app backgrounding and before
    /// agent runs (plan P1.3: async — the flush must COMPLETE before the
    /// dependent action runs, so this is awaited, never fire-and-forget).
    public func flushPendingSaves() async {
        await flushPendingSave()
    }

    // MARK: - Blob GC (#253)

    /// Run a blob-GC pass against the underlying store. `dryRun` true previews
    /// (read-only count + bytes); false deletes the orphans in one transaction.
    /// Routes through the @MainActor model per the SQLite write discipline.
    /// Returns nil only if the store call throws.
    @discardableResult
    public func performBlobVacuum(dryRun: Bool) async -> BlobVacuumReport? {
        await DebugLog.trying("vacuumBlobs", operation: { try await store.vacuumBlobs(dryRun: dryRun) })
    }

    /// Run the activity-GC sweep against the active store (issue #257).
    /// Returns nil only if the store call throws.
    @discardableResult
    public func performActivityVacuum(dryRun: Bool) async -> ActivityVacuumReport? {
        await DebugLog.trying("vacuumActivities", operation: { try await store.vacuumActivities(dryRun: dryRun) })
    }

    /// Run the page-version-GC sweep against the active store (Phase 4).
    /// Returns nil only if the store call throws.
    @discardableResult
    public func performPageVersionVacuum(dryRun: Bool) async -> PageVersionVacuumReport? {
        await DebugLog.trying("vacuumPageVersions", operation: { try await store.vacuumPageVersions(dryRun: dryRun) })
    }

    /// Run all GC sweeps (blobs + activities + page versions) in one call. Each
    /// runs in its own transaction — they are independent and idempotent, so a
    /// partial failure is safe to retry. Returns nil only if all throw.
    public func performVacuumAll(dryRun: Bool) async -> VacuumReport? {
        let blobs = await performBlobVacuum(dryRun: dryRun)
        let activities = await performActivityVacuum(dryRun: dryRun)
        let pageVersions = await performPageVersionVacuum(dryRun: dryRun)
        guard let blobs, let activities, let pageVersions else { return nil }
        return VacuumReport(blobs: blobs, activities: activities, pageVersions: pageVersions)
    }

    // MARK: - Agent run lock (Phase C, decision #6)

    // MARK: - Agent run lifecycle (ref-counted, no edit lock)

    /// Increment the agent-run counter. Called at spawn commit (spawn success).
    /// Flushes pending drafts first so an in-flight edit lands in the store
    /// before the agent starts its own writes.
    public func agentRunStarted() async {
        await flushPendingSaves()
        agentRunCount += 1
    }

    /// Decrement the agent-run counter. Called from the process's
    /// `terminationHandler`. When the last run ends, rebuilds the lists from
    /// the store so the sidebar reflects everything the agent wrote, and
    /// reloads the open document's draft from the (possibly agent-rewritten)
    /// source.
    public func agentRunEnded() {
        guard agentRunCount > 0 else { return }
        agentRunCount -= 1
        if agentRunCount == 0 {
            reloadFromStore()
            // Plan P1.3: reload the REQUESTED (user-facing) selection —
            // pre-flip `loadedSelection` always equalled `selection` here;
            // reloading a mid-flight stale value would fight the pending
            // transition and leave the editor pointing at the old page.
            loadDrafts(for: requestedSelection)
        }
    }

    // MARK: - Ingest progress flag (issue #235)

    /// Mark an ingest as in progress. Called at the top of `runMultiIngest`
    /// BEFORE extraction begins, so the Edit preflight (`isIngestInProgress`)
    /// blocks during the extraction window too.
    public func beginIngest() {
        isIngestInProgress = true
    }

    /// Clear the ingest-in-progress flag. Called on every early exit from
    /// `runMultiIngest` (extraction cancel, no valid sources, spawn failure) and
    /// from the ingest run's `onUnlock` when the agent process terminates.
    public func endIngest() {
        isIngestInProgress = false
    }

    // MARK: - Mutations

    @discardableResult
    public func newPage(title: String = WikiStoreModel.defaultUntitledTitle()) async -> PageID? {
        await flushPendingSaves()
        do {
            let page = try await store.createPage(title: title, createdBy: "user")
            // A fresh page has an empty body, so this resolves to no links — but
            // run it for uniformity with the save() path (and so a future
            // create-with-body wouldn't silently skip link indexing).
            try await store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(page.bodyMarkdown))
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write. The title is passed to openTab explicitly, so tabTitle
            // (which reads `summaries`) is never called and needs no synchronous freshness.
            let newSelection = WikiSelection.page(page.id)
            // Plan P1.3: history keys off the requested (user-facing)
            // selection, not the lagging `loadedSelection`.
            recordHistoryTransition(from: requestedSelection, to: newSelection)
            openTab(newSelection, title: title)
            await refreshProjectionsAfterOwnWrite()
            return page.id
        } catch {
            DebugLog.store("WikiStoreModel.newPage failed: \(error)")
            return nil
        }
    }

    /// When non-nil, the last rename was blocked because another page already
    /// has that title. Views observe this to show an alert, then call
    /// `clearRenameConflict()` to dismiss.
    public private(set) var renameConflictingTitle: String?

    public func clearRenameConflict() {
        renameConflictingTitle = nil
    }

    public func rename(_ id: PageID, to newTitle: String) async {
        // Persist any pending edits to whatever's open first, then rename.
        await flushPendingSave()
        renameConflictingTitle = nil
        let sanitizedTitle = WikiNameRules.sanitized(newTitle)
        do {
            // Block rename if another page already has this title (case-
            // insensitive, matching wiki-link resolution). The user gets an
            // alert via `renameConflictingTitle` instead of a silent revert.
            if let existingID = try await store.resolveTitleToID(sanitizedTitle),
               existingID != id {
                renameConflictingTitle = sanitizedTitle
                DebugLog.store("WikiStoreModel.rename blocked: '\(sanitizedTitle)' already exists (page \(existingID.rawValue))")
                return
            }
            let page = try await store.getPage(id: id)
            let cleanBody = PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
            // #797: route through `PageAuthor.user` instead of `nil`. The
            // pre-fix nil passed into `ensurePageAuthorAgent` mapped to the
            // shared `legacy-import` agent, which silently erased the prior
            // `chat:<id>` / `agent:<kind>` provenance on the HEAD row (a page
            // a chat wrote, once renamed in-app, would have flipped its author
            // identity to `legacy-import`). A rename is an explicit user
            // action — stamp `user`.
            try await store.updatePage(id: id, title: sanitizedTitle, body: cleanBody,
                                 lastEditedBy: PageAuthor.user.rawValue)
            // No manual reload — the bus fires reloadFromStore() async after the update.
            if selection == .page(id) { draftTitle = sanitizedTitle }
            // Update any tab showing this renamed page.
            for i in tabs.indices where tabs[i].selection == .page(id) {
                tabs[i].title = sanitizedTitle
            }
        } catch {
            DebugLog.store("WikiStoreModel.rename failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Rename a source's display name. Rewrites `[[source:<old>…]]` links in
    /// every page that references it (fragment + alias preserved), then refreshes
    /// the sidebar, open tabs, and File Provider mount.
    public func renameSource(id: SourceID, to newDisplayName: String) async {
        do {
            try await store.renameSource(id: id, to: newDisplayName)
            // No manual reload — the bus fires reloadFromStore() async after the
            // rename, which reloads BOTH `sources` (display name in sidebar/detail)
            // and `summaries` (the rename rewrites inbound `[[source:…]]` links).
            for i in tabs.indices where tabs[i].selection == .source(id) {
                tabs[i].title = newDisplayName
            }
        } catch {
            DebugLog.store("WikiStoreModel.renameSource failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// What references `id` right now — pages that link to it and bookmarks
    /// that point at it (issue #219). Throwing: a failed impact read surfaces
    /// as an error (the UI shows a failure and never offers deletion) instead
    /// of an empty impact that would read as "nothing references this".
    public func deletionImpact(forPage id: PageID) async throws -> DeletionImpact {
        try await store.deletionImpact(for: [.page(id)])
    }

    /// Delete pages through the store's protected contract (issue #219
    /// hardening). The WHOLE selection goes to the store in ONE
    /// `deleteResources` transaction: bookmarks targeting them are ALWAYS
    /// removed, `unlinkIncomingLinks` picks the link policy, a provenance
    /// blocker or write failure rolls back everything, and each linking page
    /// rewrites at most once. History and tab cleanup run only for targets
    /// the store reports as actually deleted, and only after the operation
    /// succeeds. Returns the committed result so callers can react to the
    /// exact deleted set (e.g. home-page cleanup).
    @discardableResult
    public func delete(
        _ ids: [PageID], unlinkIncomingLinks: Bool
    ) async throws -> ResourceDeletionResult {
        let result = try await store.deleteResources(ResourceDeletionRequest(
            targets: ids.map { .page($0) },
            linkPolicy: unlinkIncomingLinks ? .unlink : .preserve))
        for target in result.deletedTargets {
            guard case .page(let id) = target else { continue }
            removeFromHistory(.page(id))
            // Close any tab showing this deleted page.
            if let tab = tabs.first(where: { $0.selection == .page(id) }) {
                closeTab(id: tab.id)
            }
        }
        // No manual reload — the bus fires reloadFromStore() async after
        // the committed event batch.
        await refreshProjectionsAfterOwnWrite()
        return result
    }

    /// Single-page spelling of ``delete(_:unlinkIncomingLinks:)``.
    @discardableResult
    public func delete(
        _ id: PageID, unlinkIncomingLinks: Bool
    ) async throws -> ResourceDeletionResult {
        try await delete([id], unlinkIncomingLinks: unlinkIncomingLinks)
    }

    /// UI entry point for the pages containers: deletes the selection in ONE
    /// protected transaction and surfaces any failure through `storeError`.
    /// Returns the committed result, or `nil` when the deletion did not
    /// happen (nothing was changed in that case).
    public func performPageDeletion(
        _ ids: [PageID], unlinkIncomingLinks: Bool
    ) async -> ResourceDeletionResult? {
        do {
            return try await delete(ids, unlinkIncomingLinks: unlinkIncomingLinks)
        } catch {
            DebugLog.store("WikiStoreModel.delete failed: \(error)")
            storeError = StoreError(
                title: "Couldn't Delete Page",
                message: "Could not delete the page: \(error.localizedDescription)")
            return nil
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
            guard let data = DebugLog.trying("weblocData", operation: { try Data(contentsOf: fileURL) }),
                  let plist = DebugLog.trying("weblocPlist", operation: { try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }),
                  let urlString = (plist as? [String: Any])?["URL"] as? String,
                  !urlString.isEmpty
            else { return nil }
            return urlString
        }.value
    }

    // MARK: - Provider-backed ingest seam (Phase 3a)

    /// Pre-resolve a source's display name off the main actor. Only PDFs
    /// trigger the expensive PDFKit whole-file parse, so this is a no-op
    /// (returns `nil` → ``GRDBWikiStore/addSource`` resolves inline) for all
    /// other types whose metadata parsing is fast. For PDFs, the result is
    /// computed on a detached task and handed to ``storeMaterialized`` via
    /// ``resolvedDisplayName``, keeping the PDFKit work off the main actor and
    /// out of the store's locked write path (issue #229).
    ///
    /// Returns `String??`:
    /// - `nil` → "resolve in-method" (non-PDF or caller chose not to pre-resolve)
    /// - `.some(result)` → use `result` as the ``DisplayNameResolver`` output
    private func preResolveDisplayName(
        filename: String, data: Data, mimeType: String?, externalItemTitle: String?
    ) async -> String?? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let isPDF = ext == "pdf" || MimeType.isPDF(mimeType)
        guard isPDF else { return nil }
        return await Task.detached(priority: .userInitiated) {
            DisplayNameResolver.resolve(
                filename: filename, data: data, mimeType: mimeType,
                externalItemTitle: externalItemTitle)
        }.value
    }

    /// The single store-write seam every provider-backed ingest flows through.
    /// Materialization (bytes + provenance) happens off-main inside the provider;
    /// this does the main-actor `store.addSource` write, threading the
    /// `MaterializedSource`'s provenance + retained Zotero columns through. Each
    /// caller wraps its OWN duplicate/error handling around this throw.
    ///
    /// Issue #599: when `m.extractedMarkdown` is non-nil (HTML sources), the
    /// markdown is stored as a `SourceMarkdownOrigin.extraction` processed-markdown
    /// version — mirroring PDF → pdf2md extraction. The original bytes live as the
    /// source blob; the markdown is the derived artifact. Best-effort: a write
    /// failure is logged, never thrown (the source itself already landed).
    @discardableResult
    func storeMaterialized(
        _ m: MaterializedSource,
        resolvedDisplayName: String?? = nil
    ) async throws -> SourceSummary {
        let summary = try await store.addSource(
            filename: m.filename,
            data: m.data,
            detectionHints: m.detectionHints,
            ingestMetadata: m.ingestMetadata,
            provenance: m.provenance,
            role: .primary,
            originalPath: nil,
            activityID: nil,
            resolvedDisplayName: resolvedDisplayName)
        await appendExtractedMarkdown(to: summary, from: m)
        await refreshProjectionsAfterOwnWrite()
        return summary
    }

    /// Writes a materializer's `extractedMarkdown` sidecar (if present and
    /// non-empty) as a `.extraction`-origin processed-markdown version. Mirrors
    /// `seedPdfMarkdown`'s typed derived-markdown path so an HTML source's
    /// derived markdown lands on the same chain as a PDF's extracted markdown
    /// (issue #599 — HTML sources are treated like PDF sources). Best-effort:
    /// the source itself already committed; an extraction-write failure is
    /// logged via `DebugLog.store`, never thrown.
    private func appendExtractedMarkdown(to summary: SourceSummary, from m: MaterializedSource) async {
        guard let markdown = m.extractedMarkdown,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        do {
            try await store.appendDerivedMarkdown(
                sourceID: summary.id, content: markdown, origin: .extraction,
                producer: .tool(.materializerSidecar), providerID: nil, modelID: nil,
                toolVersion: nil, sourceVersionID: nil, note: m.extractionTechnique)
        } catch {
            DebugLog.store("WikiStoreModel.appendExtractedMarkdown failed (source=\(summary.id.rawValue)): \(error)")
        }
    }

    /// Best-effort: if the materialized source is HTML (has an extracted-markdown
    /// sidecar from `FormatMaterializer.dispatch`), run the defuddle extractor to
    /// obtain site-specific markdown + metadata. On any failure, keep the
    /// tag-based markdown. Sets `extractionTechnique` on the returned source so
    /// `appendExtractedMarkdown` stamps the right technique column.
    ///
    /// Does NOT run for website snapshots (those use `WebsiteSnapshotExtractor`
    /// which does image-aware extraction — defuddle can't replace that without
    /// losing image src rewriting).
    ///
    /// Issue #799 PR3: the three ingest callers (`addFiles`,
    /// `addURLViaWebsite` no-images branch, `ingestFromZotero`) NO LONGER call
    /// this — non-snapshot HTML stops auto-extracting at ingest; the user
    /// triggers extraction via the Extract button (PR2). Retained as a private
    /// building block for any future ingest-side defuddle enrichment. HTML
    /// conversion itself is the daemon queue's format route (P4.3).
    private func enrichWithDefuddle(_ m: MaterializedSource) async -> MaterializedSource {
        // Only HTML sources have a non-nil extractedMarkdown sidecar (issue #599
        // two-layer model). Non-HTML sources skip enrichment entirely.
        guard m.extractedMarkdown != nil else { return m }
        // Reconstruct a FormatPlan to reuse the shared enrich helper.
        let plan = FormatPlan(
            filename: m.filename, data: m.data, format: .html,
            extractedMarkdown: m.extractedMarkdown)
        let (enriched, technique) = await FormatMaterializer.enrich(
            plan, using: nil)
        return MaterializedSource(
            filename: enriched.filename,
            data: enriched.data,
            detectionHints: m.detectionHints,
            detectionResult: enriched.detectionResult,
            ingestMetadata: m.ingestMetadata,
            provenance: m.provenance,
            extractedMarkdown: enriched.extractedMarkdown,
            extractionTechnique: technique)
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
        var lastSourceID: SourceID?
        var lastSourceName: String?
        var duplicateNames: [String] = []
        for url in fileURLs {
            // Skip directories — only flat files are ingested.
            let isDir = DebugLog.trying("resourceValues", operation: { try url.resourceValues(forKeys: [.isDirectoryKey]) })?.isDirectory ?? false
            if isDir {
                DebugLog.store("WikiStoreModel.addFiles skipping directory: \(url.lastPathComponent)")
                continue
            }
            // Materialize off-main (read + dispatch), store on the main actor.
            var materializer = LocalFileMaterializer(fileURL: url)
            // Registration-driven recognition: the dispatch consults the
            // active registrations' declared inputs so a registered
            // zip-container input (a `.docx`) keeps its Word format and
            // filename, matching what the store records.
            materializer.registeredInputs = registeredExtractionInputs
            let materialized: MaterializedSource
            do {
                materialized = try await materializer.materialize()
            } catch {
                DebugLog.store("WikiStoreModel.addFiles read failed for \(url.lastPathComponent): \(error)")
                continue
            }

            // Issue #799 PR3: HTML no longer auto-extracts at ingest — store
            // the raw bytes only; the user triggers extraction via the Extract
            // button (PR2). The `FormatMaterializer.dispatch` HTML branch returns
            // `extractedMarkdown: nil`, so `appendExtractedMarkdown` (called by
            // `storeMaterialized`) writes no markdown version for HTML sources.

            // Pre-resolve display name off-main for PDFs (issue #229).
            let resolvedDisplayName = await preResolveDisplayName(
                filename: materialized.filename, data: materialized.data,
                mimeType: materialized.mimeType,
                externalItemTitle: materialized.ingestMetadata?.externalItemTitle)

            do {
                let summary = try await storeMaterialized(materialized, resolvedDisplayName: resolvedDisplayName)
                lastSourceID = summary.id
                lastSourceName = summary.effectiveName
                // A registered DOCX extraction converts on import (the
                // registration is what makes the content extractable). DOCX
                // deliberately differs from the PR3 HTML posture: raw docx
                // bytes are a binary zip with no fallback text path, so
                // waiting for a manual tap leaves the source unusable.
                autoExtractIfRegistered(summary)
            } catch WikiStoreError.duplicateContent(let existing) {
                // Byte-identical to an already-stored source — skip rather than
                // abort the rest of the drop batch; report it so the user isn't
                // left wondering why the file didn't show up.
                duplicateNames.append("\(url.lastPathComponent) (already added as \(existing.effectiveName))")
            } catch {
                DebugLog.store("WikiStoreModel.addFiles store failed for \(url.lastPathComponent): \(error)")
            }
        }
        // No manual reload — the bus fires reloadFromStore() async after the
        // store writes. The tab title is passed explicitly to openTab so it
        // doesn't read the stale `sources` array via tabTitle.
        if let sourceID = lastSourceID, let name = lastSourceName {
            openTab(.source(sourceID), title: name)
        } else if let sourceID = lastSourceID {
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
    /// agent operation can summarize it afterward. Lands through the SAME
    /// `store.addSource` path as `addFiles`, so it appears under Sources +
    /// `sources/by-{id,name}` immediately and is pickable in Operations → Ingest.
    /// Returns the outcome on success; throws a user-readable
    /// `URLFetchService.FetchError` on a bad URL, non-2xx, empty body, or store
    /// failure (the caller surfaces it in the sheet). The store write hops to the
    /// main actor (this type is `@MainActor`); the fetch runs off it.
    ///
    /// Named `addURL` (not `ingestURL`) because it only adds a source — the agent
    /// "Ingest into wiki" phase is a separate, later step. Issue #178.
    ///
    /// Issue #799 PR5: YouTube ingestion creates a byteless embed source +
    /// synthetic metadata page with NO transcript at ingest; the user clicks
    /// Transcribe in `SourceDetailView` to enqueue the caption fetch through
    /// the reviewed youtube-transcript package route. The same holds for
    /// Apple Podcasts episodes and RSS feeds: ingest creates the byteless
    /// source only; transcripts enqueue through the extraction queue.
    @discardableResult
    public func addURL(
        _ rawInput: String,
        fetcher: any URLFetchService.URLResourceFetcher = URLSessionFetcher(),
        allowDuplicateURL: Bool = false
    ) async throws -> URLFetchService.FetchOutcome {
        try await rejectExistingURL(rawInput, allowDuplicateURL: allowDuplicateURL)
        // An Apple Podcasts EPISODE link is recognized before the generic web
        // fetch: its HTML is the useless player page, so we route to the
        // byteless-embed pipeline instead. The pageURL is re-normalized from
        // the raw input so the Origin row surfaces the canonical
        // `podcasts.apple.com` URL the user pasted (the episode ID alone
        // isn't a clickable link).
        if let episode = PodcastEpisodeURL.parse(rawInput) {
            // Issue #799 PR4: no auto-transcription at ingest. The episode
            // URL creates a byteless embed source (like YouTube/Vimeo/Spotify/
            // SoundCloud/remote-media) with NO transcript. The user clicks
            // "Transcribe" in `SourceDetailView` to enqueue the fetch through
            // the reviewed apple-podcast-transcript package route. Same
            // provenance shape as before (agentName = apple-podcast,
            // plan/externalRef = pasted page URL, externalIdentity = the
            // numeric episode ID) so ExternalEmbed continues to host-swap
            // planURL → embed.podcasts.apple.com.
            let pageURL = URLFetchService.normalizeURL(rawInput)
                ?? URL(string: "https://podcasts.apple.com")!
            let summary = try await store.addBytelessSource(
                filename: Self.podcastEmbedFilename(for: episode),
                mimeType: Self.podcastEmbedMIME,
                provenance: SourceProvenance(
                    agentName: SourceProvider.applePodcast.rawValue,
                    activityKind: "fetch",
                    plan: pageURL.absoluteString,
                    externalRef: pageURL.absoluteString,
                    externalIdentity: episode.id),
                role: .primary)
            // Issue #621: resolve a human-readable display name from the
            // episode slug so the source list shows the episode title instead
            // of the slugified filename. Mirrors the byteless oEmbed title
            // step (YouTube/Vimeo/Spotify/SoundCloud) — does NOT block ingest;
            // a nil title leaves the synthetic filename display name in place.
            // The slug is the episode title as Apple generates it for an
            // episode link, so un-sluggifying is offline and dependency-free.
            let resolvedTitle = PodcastEpisodeURL.displayTitle(from: episode.slug)
                .map { WikiNameRules.sanitized($0) }
            if let title = resolvedTitle {
                do {
                    try await store.setSourceDisplayName(id: summary.id, displayName: title)
                } catch {
                    DebugLog.store("apple-podcast slug title setSourceDisplayName failed (source=\(summary.id.rawValue)): \(error)")
                }
            }
            // No transcript markdown is written — the source's
            // `source_markdown_versions` stays empty until the extraction
            // queue item lands. The reader shows the embed player (the
            // source has an `embedTarget`). No manual reload — the bus fires
            // reloadFromStore() async after the store writes. The tab title
            // is passed explicitly so tabTitle (which reads `sources`) needs
            // no synchronous freshness.
            openTab(.source(summary.id), title: resolvedTitle ?? summary.effectiveName)
            // Issue #1379: report "transcript extraction wanted" when an
            // installed registration claims the created source's MIME —
            // kind-free, registration-derived. The UI layer that called
            // addURL enqueues the standard `.extraction` queue item.
            let transcriptExtractionWanted = transcriptExtractionWanted(
                mimeType: Self.podcastEmbedMIME)
            await refreshProjectionsAfterOwnWrite()
            return URLFetchService.FetchOutcome(
                filename: summary.filename,
                byteSize: 0,
                kind: .audioEmbed,
                transcriptExtractionWanted: transcriptExtractionWanted,
                sourceID: summary.id)
        }
        // Phase 5b: byteless external-embed media (provider iframes + direct-
        // remote). YouTube routes uniformly through `bytelessMediaOutcome`
        // (creates the byteless embed source + synthetic metadata page, NO
        // transcript at ingest). The user clicks Transcribe in
        // `SourceDetailView` to enqueue the fetch explicitly via the queue
        // (the reviewed youtube-transcript package route).
        if let outcome = try await bytelessMediaOutcome(rawInput, urlFetcher: fetcher) {
            await refreshProjectionsAfterOwnWrite()
            return outcome
        }
        let websiteOutcome = try await addURLViaWebsite(rawInput, fetcher: fetcher)
        await refreshProjectionsAfterOwnWrite()
        return websiteOutcome
    }

    /// Guard URL intake before any provider routing or network work. Invalid
    /// input remains the fetch service's responsibility so callers retain its
    /// existing user-facing validation error.
    private func rejectExistingURL(_ rawInput: String, allowDuplicateURL: Bool) async throws {
        guard !allowDuplicateURL,
              let identity = URLFetchService.urlIdentity(rawInput),
              let existing = try await store.sourceMatchingURLIdentity(identity)
        else { return }
        throw WikiStoreError.duplicateURL(existing: existing)
    }

    /// **Generic RSS-feed podcast intake** (podcast-generalize, M3): a dedicated
    /// entry point for pasting a direct RSS feed URL. Bypasses the generic
    /// website/byteless-embed fetch chain (the "ambiguity problem" — a feed URL
    /// can't be distinguished from a webpage by URL sniffing alone). The caller
    /// invokes this explicitly from an "Add podcast feed" affordance, declaring
    /// intent, so routing is by caller intent, not content sniffing.
    ///
    /// Creates a byteless `.podcast` source (no bytes fetched) with
    /// `agentName = "podcast"`, `plan` = feed URL. No transcript is written at
    /// ingest — the user clicks Transcribe in `SourceDetailView` to trigger the
    /// `podcast-transcript` script fetch (mirrors the Apple PR4 + YouTube PR5
    /// contract). Always compiled (no `#if PODCAST_TRANSCRIPTS` guard) — the
    /// generic `.podcast` path needs no FairPlay signing helper.
    ///
    /// - Parameter rawInput: the raw RSS feed URL (e.g.
    ///   `https://feeds.example.com/show.xml`).
    /// - Returns: the `FetchOutcome` for the created byteless source.
    /// - Throws: `WikiStoreError` on a store failure (e.g. `.duplicateContent`
    ///   for a re-paste of the same feed URL).
    @discardableResult
    public func addPodcastFeedURL(_ rawInput: String) async throws -> URLFetchService.FetchOutcome {
        guard let ref = RSSFeedEpisodeURL.parse(rawInput) else {
            throw WikiStoreError.unexpected("Not a valid podcast feed URL: \(rawInput)")
        }
        let feedURLString = ref.feedURL.absoluteString
        let summary = try await store.addBytelessSource(
            filename: Self.rssPodcastEmbedFilename(for: ref),
            mimeType: Self.rssPodcastEmbedMIME,
            provenance: SourceProvenance(
                agentName: SourceProvider.podcast.rawValue,
                activityKind: "fetch",
                plan: feedURLString,
                externalRef: feedURLString,
                externalIdentity: ref.episodeGUID ?? feedURLString),
            role: .primary)
        // No transcript markdown is written — the source's
        // `source_markdown_versions` stays empty until the user transcribes.
        // Mirrors the Apple PR4 + YouTube PR5 byteless-only ingest contract.
        openTab(.source(summary.id), title: summary.effectiveName)
        // Issue #1379 consistency: same claim + route-policy signal as the
        // addURL byteless branches — the PodcastTranscript package claims
        // `audio/podcast` AND the bundled import-transcription policy covers
        // the podcast-transcript route, so the caller can auto-enqueue the
        // extraction.
        let outcome = URLFetchService.FetchOutcome(
            filename: summary.filename,
            byteSize: 0,
            kind: .audioEmbed,
            transcriptExtractionWanted: transcriptExtractionWanted(
                mimeType: Self.rssPodcastEmbedMIME),
            sourceID: summary.id)
        await refreshProjectionsAfterOwnWrite()
        return outcome
    }

    /// Build the byteless-source filename for a generic RSS podcast feed
    /// (podcast-generalize). Derives a readable stem from the feed URL's host +
    /// last path component, prefixed with `podcast-`. Mirrors the YouTube/Vimeo
    /// `youtube-<id>` / `vimeo-<id>` byteless-source filename convention.
    private static func rssPodcastEmbedFilename(for ref: RSSFeedEpisodeRef) -> String {
        let host = (ref.feedURL.host ?? "feed").replacingOccurrences(of: "www.", with: "")
        let last = ref.feedURL.lastPathComponent.isEmpty
            ? "feed"
            : (ref.feedURL.lastPathComponent as NSString).deletingPathExtension
        let stem = "\(host)-\(last)"
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .repeatingHyphensCollapsed()
        return FilenameEscaping.escapeTitle("podcast-\(stem)")
    }

    /// The synthetic MIME for a byteless generic RSS podcast feed source
    /// (podcast-generalize). `ExternalEmbed.target(for:)` dispatches on
    /// `agentName == "podcast"` is NOT wired (there's no universal podcast web
    /// player), so this source is byteless with no embed target — the Transcribe
    /// button is the sole affordance. The `audio/*` prefix keeps the MIME
    /// taxonomy consistent with the other byteless audio providers.
    private static let rssPodcastEmbedMIME = "audio/podcast"

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
    private func bytelessMediaOutcome(
        _ rawInput: String,
        urlFetcher: any URLFetchService.URLResourceFetcher
    ) async throws -> URLFetchService.FetchOutcome? {
        let match: MediaEmbedMatch
        let kind: URLFetchService.FetchOutcome.Kind
        if let m = MediaEmbedURL.youtube(rawInput) { match = m; kind = .videoEmbed }
        else if let m = MediaEmbedURL.vimeo(rawInput) { match = m; kind = .videoEmbed }
        else if let m = MediaEmbedURL.spotify(rawInput) { match = m; kind = .audioEmbed }
        else if let m = MediaEmbedURL.soundcloud(rawInput) { match = m; kind = .audioEmbed }
        else if let m = MediaEmbedURL.remoteMedia(rawInput) { match = m; kind = .remoteMedia }
        else { return nil }

        let summary = try await store.addBytelessSource(
            filename: match.filename,
            mimeType: match.mimeType,
            provenance: SourceProvenance(
                agentName: match.agentName,
                activityKind: match.activityKind,
                plan: match.planURL,
                externalRef: match.planURL,
                externalIdentity: match.externalIdentity),
            role: .primary)
        // Best-effort provider oEmbed metadata (YouTube/Vimeo/Spotify/
        // SoundCloud). Runs off-main, never blocks the embed; a nil blob
        // leaves the synthetic `youtube-<id>` name + a minimal markdown page
        // in place. Issue #572 (display title); #646 extends to full metadata.
        let metadata = await fetchMediaMetadata(for: match, urlFetcher: urlFetcher)
        if let title = metadata?.title {
            do {
                try await store.setSourceDisplayName(id: summary.id, displayName: title)
            } catch {
                DebugLog.store("byteless oEmbed title setSourceDisplayName failed (source=\(summary.id.rawValue)): \(error)")
            }
        }
        // Issue #646: synthesize a readable markdown page from the URL + oEmbed
        // metadata so the reader, File Provider `.md` sibling, and Tantivy all
        // see real content for this byteless source. Best-effort: a write
        // failure is logged, not thrown (the embed itself already landed).
        await writeSyntheticBytelessMarkdown(
            sourceID: summary.id,
            url: match.planURL,
            metadata: metadata,
            fallbackTitle: summary.effectiveName,
            transcript: nil,
            technique: Self.bytelessMetadataTechnique)
        // No manual reload — the bus fires reloadFromStore() async after each
        // store write (addBytelessSource + setSourceDisplayName +
        // appendDerivedMarkdown). The tab title is passed explicitly (the
        // resolved title when available) so it needs no synchronous freshness.
        openTab(.source(summary.id), title: metadata?.title ?? summary.effectiveName)
        // Issue #1379, revised: report "transcript extraction wanted" only
        // when an installed registration claims the created source's MIME
        // AND the claimed route is in the bundled import-transcription
        // policy. Caption routes are covered (podcast, Apple Podcasts,
        // YouTube); speech-to-text never is. The UI layer that called
        // addURL enqueues the standard `.extraction` queue item for the
        // covered routes — the same request the manual Transcribe button
        // builds.
        let transcriptExtractionWanted = transcriptExtractionWanted(
            mimeType: match.mimeType)
        return URLFetchService.FetchOutcome(
            filename: match.filename, byteSize: 0, kind: kind,
            transcriptExtractionWanted: transcriptExtractionWanted,
            sourceID: summary.id)
    }

    /// Registration-derived, route-policy-gated "should this source's
    /// transcript be fetched automatically at import?" — `true` only when
    /// BOTH hold: an active installed registration claims the MIME (an
    /// unambiguous claim, matching `autoExtractIfRegistered`'s gate
    /// philosophy) AND the claimed route appears in the bundled
    /// import-transcription policy. Names no extractor kind; claims data
    /// and bundled route policy decide. Caption routes (podcast, Apple
    /// Podcasts, YouTube) are covered; speech-to-text is not in the table
    /// and runs only on an explicit user action. Issue #1379.
    private func transcriptExtractionWanted(mimeType: String) -> Bool {
        guard let claim = registeredExtractionInputs
            .registeredMIME(forNormalizedMIME: mimeType),
            // Claims are normalized registration data, so this reparse
            // always succeeds in practice; a failure means the route
            // cannot be named and the import stays manual (deliberately
            // inert, not swallowed).
            // swiftlint:disable:next silent_try_optional
            let claimedMIME = try? ExtractorMIMEType(validating: claim.mimeType)
        else { return false }
        return ExtractorRouteDefaults.bundled.importTranscriptionWanted(
            for: ExtractorRouteID(kind: claim.kind, mimeType: claimedMIME))
    }

    /// Off-main oEmbed metadata fetch for a byteless media match. The GET
    /// itself runs in a detached `Task` so it can't stall the `@MainActor`
    /// model; a `nil` leaves the synthetic name + minimal synthetic markdown
    /// in place. Used by `bytelessMediaOutcome` for every byteless provider
    /// (YouTube / Vimeo / Spotify / SoundCloud / remote-media). Issue #572;
    /// extended by #646 to surface the full metadata blob (author / provider /
    /// description / duration).
    private func fetchMediaMetadata(
        for match: MediaEmbedMatch,
        urlFetcher: any URLFetchService.URLResourceFetcher
    ) async -> MediaTitleFetcher.MediaOEmbedMetadata? {
        let matchCopy = match
        let fetcherCopy = urlFetcher
        return await Task.detached(priority: .userInitiated) {
            await MediaTitleFetcher.metadata(for: matchCopy, fetcher: fetcherCopy)
        }.value
    }

    /// Best-effort synthetic markdown write for a byteless source. Renders via
    /// `MediaMarkdownSynthesizer` and stores through `appendDerivedMarkdown`
    /// so the reader + File Provider `.md` sibling + Tantivy all see it. Never
    /// throws — the embed has already landed; a markdown failure is a partial-
    /// failure log, not a throw (#475 discipline). Issue #646.
    private func writeSyntheticBytelessMarkdown(
        sourceID: SourceID,
        url: String,
        metadata: MediaTitleFetcher.MediaOEmbedMetadata?,
        fallbackTitle: String,
        transcript: String?,
        technique: String
    ) async {
        let markdown = MediaMarkdownSynthesizer.synthesize(
            url: url, metadata: metadata,
            fallbackTitle: fallbackTitle, transcript: transcript)
        do {
            try await store.appendDerivedMarkdown(
                sourceID: sourceID, content: markdown, origin: .transcript,
                producer: .tool(Self.syntheticMarkdownTool(for: technique)), providerID: nil,
                modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
        } catch {
            // #475: never silently swallow — log to Console.app so a partial
            // failure is traceable. The source itself was already saved.
            DebugLog.store("synthetic byteless markdown write failed (source=\(sourceID.rawValue), technique=\(technique)): \(error)")
        }
    }

    private static func syntheticMarkdownTool(for technique: String) -> ExtractionTool {
        switch technique {
        case bytelessMetadataTechnique: return .bytelessOEmbedSynthetic
        default: return transcriptTool(for: technique)
        }
    }

    /// The web-fetch ingest path (HTML→md / PDF / text / binary), shared by both
    /// the feature-on and feature-off `addURL` overloads. Validate + fetch OFF the
    /// main actor (the GET shouldn't stall the UI); the WebsiteMaterializer owns
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
        let provider = WebsiteMaterializer(rawInput: rawInput, fetcher: fetcher)
        let snapshot = try await provider.materializeSnapshot()
        // Issue #799 PR3: non-snapshot HTML no longer auto-extracts at ingest —
        // the no-images branch below passes `snapshot.page` straight through
        // (its `extractedMarkdown` sidecar is `nil` post-PR3 because
        // `FormatMaterializer.dispatch` no longer computes it for HTML). The
        // snapshot-with-images path is a SEPARATE code path: `storeSnapshot`
        // runs `WebsiteSnapshotExtractor`'s image-aware extraction (image-src
        // rewriting is inseparable from extraction) and writes the result via
        // `appendExtractedMarkdown(to:from:)`. That path STAYS auto-extracting
        // — see AC.12 in `plans/extraction-framework-pr3.md`.
        let page = snapshot.page
        // Pre-resolve the page's display name off the main actor so a PDF
        // source's PDFKit parse doesn't block the UI or delay the store write
        // (issue #229). Non-PDFs are unaffected (helper returns nil → inline).
        let resolvedDisplayName = await preResolveDisplayName(
            filename: page.filename, data: page.data,
            mimeType: page.mimeType,
            externalItemTitle: page.ingestMetadata?.externalItemTitle)
        var summary: SourceSummary
        if snapshot.plan.format == .html && !snapshot.images.isEmpty {
            summary = try await storeSnapshot(snapshot)
        } else {
            summary = try await storeMaterialized(page, resolvedDisplayName: resolvedDisplayName)
        }
        // HTML sources have ".html" appended to the storage filename (issue #599:
        // the original HTML bytes are now the source blob, not the converted
        // markdown). Set a clean display name (the page title without the
        // extension) so the UI shows "How to Do Thing" instead of
        // "How to Do Thing.html".
        if snapshot.plan.format == .html {
            let cleanTitle = (snapshot.page.filename as NSString).deletingPathExtension
            do {
                try await store.setSourceDisplayName(id: summary.id, displayName: cleanTitle)
            } catch {
                // #475/#492: don't silently swallow — the display name would silently
                // revert to "Foo.html" with no Console.app trace of why.
                DebugLog.store("WikiStoreModel.importURLSource setSourceDisplayName failed (source=\(summary.id.rawValue)): \(error)")
            }
        }
        // No manual reload — the bus fires reloadFromStore() async after the
        // store write. The tab title is passed explicitly so tabTitle (which
        // reads `sources`) needs no synchronous freshness.
        openTab(.source(summary.id), title: summary.effectiveName)
        return URLFetchService.FetchOutcome(
            filename: snapshot.plan.filename, byteSize: snapshot.plan.data.count,
            kind: URLFetchService.mapFormat(snapshot.plan.format))
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
    private func storeSnapshot(_ snapshot: WebsiteSnapshot) async throws -> SourceSummary {
        guard let prov = snapshot.page.provenance else {
            return try await storeMaterialized(snapshot.page)
        }
        // 1. Commit the shared activity FIRST so source_versions.activity_id FK
        //    is satisfied before any version is written.
        let activityID = try await store.ensureFetchActivity(provenance: prov)
        // 2. Store the page (source-level dedup intact; shares the activity).
        let pageSummary = try await store.addSource(
            filename: snapshot.page.filename,
            data: snapshot.page.data,
            detectionHints: snapshot.page.detectionHints,
            ingestMetadata: snapshot.page.ingestMetadata,
            provenance: prov,
            role: .primary,
            originalPath: nil,
            activityID: activityID,
            resolvedDisplayName: nil)
        // 3. Store each image as a per-snapshot .media source.
        for image in snapshot.images {
            await DebugLog.trying("addSnapshotImage", operation: {
                try await store.addSnapshotImage(
                    filename: image.filename,
                    data: image.data,
                    detectionHints: image.detectionHints,
                    originalPath: image.originalPath, sourceURL: image.sourceURL,
                    activityID: activityID, role: .media)
            })
        }
        // 4. Issue #599: write the snapshot markdown (image srcs rewritten to
        //    stored siblings) as a `.extraction`-origin processed-markdown
        //    version, so the reader tab shows rendered content with inlined
        //    images alongside the original-HTML HTML tab.
        await appendExtractedMarkdown(to: pageSummary, from: snapshot.page)
        // 5. Issue #1380: the snapshot sidecar is the ingest-time FALLBACK
        //    (image-rewritten tag-based text). The gated import extraction
        //    still runs for snapshot sources, so the route-selected package
        //    (Defuddle) lands and is nominated active when available. The
        //    gate closes without a live claiming package and the sidecar
        //    stays the active readable version — the pre-#1380 behavior.
        autoExtractIfRegistered(pageSummary)
        return pageSummary
    }

    // MARK: - Source refresh (Phase 3b → P4.3)

    /// The refresh WRITE no longer lives here: the daemon re-fetches the
    /// source's recorded URL (the `.refreshSource` workload intent) and
    /// appends the content version daemon-side; the app's runRefresh
    /// enqueues the durable job and projects status over the queue events.
    /// `isSourceRefreshable(for:)` below stays the client-side gate.

    /// Synchronous ingest seam used by tests/verifiers (no drag gesture). Stores
    /// the bytes, rebuilds the list, and signals the daemon.
    public func addSource(filename: String, data: Data) async {
        do {
            _ = try await store.addSource(
                filename: filename,
                data: data,
                detectionHints: ContentTypeDetectionHints(filename: filename),
                ingestMetadata: nil,
                provenance: nil,
                role: .primary,
                originalPath: nil,
                activityID: nil,
                resolvedDisplayName: nil)
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write.
        } catch WikiStoreError.duplicateContent(let existing) {
            storeError = StoreError(
                title: "Duplicate File Skipped",
                message: "\(filename) has the exact same content as \(existing.effectiveName), so it wasn't added again.")
        } catch {
            DebugLog.store("WikiStoreModel.addSource failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
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

        var firstSourceID: SourceID?
        var firstSourceName: String?
        for file in result.files {
            let ext = (file.filename as NSString).pathExtension.lowercased()
            #if canImport(UniformTypeIdentifiers)
            let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType
            #else
            let mimeType: String? = nil
            #endif
            let provider = MarkdownFolderMaterializer(
                filename: file.filename, data: file.data, mimeType: mimeType,
                directoryURL: directory)
            do {
                let materialized = try await provider.materialize()
                let summary = try await storeMaterialized(materialized)
                if firstSourceID == nil { firstSourceID = summary.id; firstSourceName = summary.effectiveName }
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

        // No manual reload — the bus fires reloadFromStore() async after the
        // store writes. The tab title is passed explicitly so tabTitle (which
        // reads `sources`) needs no synchronous freshness.
        if let sourceID = firstSourceID, let name = firstSourceName {
            openTab(.source(sourceID), title: name)
        } else if let sourceID = firstSourceID {
            openTab(.source(sourceID))
        }
        return (imported: imported, errors: errorMessages)
    }

    /// What references `id` right now — pages that cite it and bookmarks that
    /// point at it (issue #219). Throwing, same contract as
    /// `deletionImpact(forPage:)`.
    public func deletionImpact(forSource id: SourceID) async throws -> DeletionImpact {
        try await store.deletionImpact(for: [.source(id)])
    }

    /// Delete sources through the store's protected contract (issue #219
    /// hardening). The WHOLE selection goes to the store in ONE
    /// `deleteResources` transaction: bookmarks targeting them are ALWAYS
    /// removed, `unlinkIncomingLinks` picks the link policy, and a provenance
    /// blocker on ANY source stops the complete batch before the first
    /// mutation. History and tab cleanup run only for targets the store
    /// reports as actually deleted. Returns the committed result.
    @discardableResult
    public func deleteSources(
        _ ids: [SourceID], unlinkIncomingLinks: Bool
    ) async throws -> ResourceDeletionResult {
        let result = try await store.deleteResources(ResourceDeletionRequest(
            targets: ids.map { .source($0) },
            linkPolicy: unlinkIncomingLinks ? .unlink : .preserve))
        for target in result.deletedTargets {
            guard case .source(let id) = target else { continue }
            removeFromHistory(.source(id))
            // Close any tab showing this deleted file.
            if let tab = tabs.first(where: { $0.selection == .source(id) }) {
                closeTab(id: tab.id)
            }
        }
        // No manual reload — the bus fires reloadFromStore() async after
        // the committed event batch.
        await refreshProjectionsAfterOwnWrite()
        return result
    }

    /// Single-source spelling of ``deleteSources(_:unlinkIncomingLinks:)``.
    /// A provenance blocker stops the store before ANY write and surfaces in
    /// the typed catch; use the throwing batch spelling for full control.
    @discardableResult
    public func deleteSource(_ id: SourceID, unlinkIncomingLinks: Bool) async throws -> ResourceDeletionResult {
        try await deleteSources([id], unlinkIncomingLinks: unlinkIncomingLinks)
    }

    /// UI entry point for the sources containers: deletes the selection in
    /// ONE protected transaction and surfaces any failure — including the
    /// provenance restriction's friendly "Can't Delete Source" alert —
    /// through `storeError`. Returns the committed result, or `nil` when the
    /// deletion did not happen (nothing was changed in that case).
    public func performSourceDeletion(
        _ ids: [SourceID], unlinkIncomingLinks: Bool
    ) async -> ResourceDeletionResult? {
        do {
            return try await deleteSources(ids, unlinkIncomingLinks: unlinkIncomingLinks)
        } catch WikiStoreError.deletionRestricted(.provenance(let blockers)) {
            // The store stopped before the first mutation — nothing was
            // unlinked and no bookmark was removed.
            let titles = Set(blockers.values.map(\.pageID)).compactMap { pid in
                summaries.first { $0.id == pid }?.title
            }.sorted()
            let noun = blockers.values.count == 1 ? "page version" : "page versions"
            var message = "This source is referenced as evidence by \(blockers.values.count) \(noun)"
            if !titles.isEmpty {
                message += " (\(titles.joined(separator: ", ")))"
            }
            message += ". Remove those references first."
            storeError = StoreError(title: "Can't Delete Source", message: message)
            return nil
        } catch {
            DebugLog.store("WikiStoreModel.deleteSource failed: \(error)")
            storeError = StoreError(
                title: "Couldn't Delete Source",
                message: "Could not delete the source: \(error.localizedDescription)")
            return nil
        }
    }

    /// The current `system_prompt` singleton body — the agent run passes this
    /// verbatim via `--append-system-prompt`. The system prompt is now read-only,
    /// always sourced from the compiled `SystemPrompt.defaultBody`.
    public func currentSystemPromptBody() -> String {
        SystemPrompt.defaultBody
    }

    /// A LIVE snapshot of THIS wiki's current state — page titles, the `index.md`
    /// body, and a recent-log tail — gathered fresh from the store at agent-run
    /// click time (§3.5 read-state-at-the-latest-moment). Injected into the
    /// operation `-p` prompt's `CURRENT WIKI STATE` block so the agent skips the
    /// orientation turns (`page list`, re-reading `index.md`/`log.md`, pulling a
    /// sample page) it would otherwise spend rediscovering what the app already
    /// knows. Read directly from the store (not the cached `summaries`) so it can't
    /// lag a concurrent external write. Inventory reads (titles, index, log tail,
    /// bookmarks) are `try?`-guarded so a transient read failure degrades to an
    /// emptier-but-valid snapshot rather than blocking the run.
    ///
    /// The committed editorial strategy is captured here with the rest of the
    /// state, at execution-request construction: every snapshot-bearing path
    /// (ingest, query, lint, page-lint, chat session start) carries it through
    /// the rendered `WIKI_STATE.md`. `nil` (the Default strategy) captures as
    /// absence, so a Default wiki renders byte-identically to before strategies
    /// existed. A strategy READ failure throws
    /// `WikiStateSnapshotError.strategyReadFailed` instead: callers must fail
    /// visibly and build no request, never launch a run that silently invented
    /// the Default instructions.
    public func currentStateSnapshot() async throws -> WikiStateSnapshot {
        let titles = (await DebugLog.trying("listPages", operation: { try await store.listPages(sortBy: .lastUpdated) }) ?? []).map(\.title)
        let indexBody = await DebugLog.trying("getWikiIndex", operation: { try await store.getWikiIndex() })?.body ?? WikiIndex.defaultBody
        let logEntries = await DebugLog.trying("recentLogEntries", operation: { try await store.recentLogEntries(limit: WikiStateSnapshot.maxLogEntries) }) ?? []
        // Render each tail entry with the SAME formatter the `log.md` projection
        // uses, so the snapshot lines are byte-identical to what `tail log.md`
        // shows (no second, drifting log format).
        let logLines = logEntries.map { LogRenderer.line(for: $0) }
        // Include the bookmark tree so the agent can see the user's organization (#239).
        let bookmarks = await DebugLog.trying("listBookmarkNodes", operation: { try await store.listBookmarkNodes() }) ?? []
        // Capture the committed strategy with the rest of the state. Unlike the
        // inventory reads above, a failure here THROWS: authoritative editorial
        // instructions cannot be invented from a store error, so a failed read
        // fails the request instead of degrading to the Default strategy.
        let strategy: WikiStrategy?
        do {
            strategy = try await store.getWikiStrategy()
        } catch {
            throw WikiStateSnapshotError.strategyReadFailed("\(error)")
        }
        return WikiStateSnapshot.make(
            allTitles: titles, indexBody: indexBody, logLines: logLines,
            bookmarkNodes: bookmarks,
            strategy: strategy
        )
    }

    /// Render the operation log exactly as the File Provider's `log.md` does, so
    /// the in-app document and filesystem projection show the same query/ingest/
    /// lint history. Bounded generously for UI responsiveness; entries remain in
    /// chronological order so newest activity sits at the bottom.
    public func currentLogMarkdown(limit: Int = 10_000) async -> String {
        let entries = await DebugLog.trying("recentLogEntries", operation: { try await store.recentLogEntries(limit: limit) }) ?? []
        return LogRenderer.render(entries)
    }

    /// The verbatim bytes of one ingested source, read from SQLite at click time so
    /// the agent run can STAGE it onto reliable local disk (`source.<ext>`) rather
    /// than reading from the ~5s-laggy read-only mount. `nil` if the read fails;
    /// the caller surfaces that as a preflight error instead of launching a run that
    /// would fall back to probing the mount.
    public func sourceBytes(id: SourceID) async -> Data? {
        await DebugLog.trying("sourceContent", operation: { try await store.sourceContent(id: id) })
    }

    /// Creates a renderer reader for the current immutable source version.
    /// The reader retains that version ID, so a mounted renderer never follows
    /// later edits through the live source reference.
    public func rendererAuthorizedInputReader(for sourceID: SourceID) async -> RendererAuthorizedInputReader? {
        guard let version = await DebugLog.trying(
            "activeContentVersion",
            operation: { try await store.activeContentVersion(sourceID: sourceID) }
        ) else { return nil }
        return RendererAuthorizedInputReader(store: store, authorizedInput: .source(versionID: version.id))
    }

    /// Renderer preferences are a wiki-store concern. Keeping this write at the
    /// main-actor model seam preserves the store's method-atomic mutation path.
    public func setRendererSourcePreference(sourceID: SourceID, preference: RendererPreferenceReference) async {
        do {
            try await store.setRendererSourcePreference(sourceID: sourceID, preference: preference)
        } catch {
            DebugLog.store("WikiStoreModel.setRendererSourcePreference failed: \(error)")
        }
    }

    public func rendererSourcePreference(for sourceID: SourceID) async -> RendererPreferenceReference? {
        await DebugLog.trying("rendererSourcePreference", operation: {
            try await store.rendererSourcePreference(sourceID: sourceID)?.preference
        })
    }

    public func setRendererSourcePresentation(sourceID: SourceID, presentation: RendererSourcePresentationMode) async {
        do {
            try await store.setRendererSourcePresentation(sourceID: sourceID, presentation: presentation)
        } catch {
            DebugLog.store("WikiStoreModel.setRendererSourcePresentation failed: \(error)")
        }
    }

    public func removeRendererSourcePresentation(sourceID: SourceID) async {
        do {
            try await store.removeRendererSourcePresentation(sourceID: sourceID)
        } catch {
            DebugLog.store("WikiStoreModel.removeRendererSourcePresentation failed: \(error)")
        }
    }

    public func rendererSourcePresentation(for sourceID: SourceID) async -> RendererSourcePresentationMode? {
        await DebugLog.trying("rendererSourcePresentation", operation: {
            try await store.rendererSourcePresentation(sourceID: sourceID)?.presentation
        })
    }

    public func isSourceIngested(_ file: SourceSummary) -> Bool {
        sourceIngestedStatus[file.id] ?? false
    }

    /// #1344: stamp one source Ingested (`sources.ingested_at`). Called by
    /// the app queue ingestion host when a pipeline ingestion job completes
    /// successfully; the first stamp wins, so a later agent
    /// `wikictl log append --source` ritual cannot rewrite it. No manual
    /// reload: the store's `mutate()` emits `sourceUpdated`, and
    /// `subscribeToChanges()` reloads on every event, refreshing
    /// `sourceIngestedStatus`.
    public func markSourceIngested(id: SourceID) async {
        do {
            try await store.markSourceIngested(id: id)
        } catch {
            DebugLog.store("WikiStoreModel.markSourceIngested[\(id.rawValue)] failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// The origin provenance of a source (provider agent + the activity that
    /// fetched/imported it). `nil` when the read fails or no version exists.
    /// Drives the "Origin" row in `SourceDetailView`.
    public func sourceOrigin(for id: SourceID) async -> SourceOrigin? {
        await DebugLog.trying("sourceOrigin", operation: { try await store.sourceOrigin(sourceID: id) })
    }

    /// The full edit history for a source — every `source_versions` row joined
    /// to its activity + agent, newest-first. `nil`/empty when the read fails
    /// or the source has no versions. Drives the History tab in
    /// `SourceDetailView`'s inspector (the source-side mirror of
    /// `pageEditHistory`).
    public func sourceEditHistory(for id: SourceID) async -> [SourceOrigin] {
        await DebugLog.trying("sourceEditHistory", operation: { try await store.sourceEditHistory(sourceID: id) }) ?? []
    }

    /// The origin provenance of a page's HEAD — the agent + activity that last
    /// created/edited it (page provenance, #page-provenance). `nil` when the
    /// read fails (unknown id, no version rows). Drives the "Provenance" row
    /// in `PageDetailView`. Off-main-safe when the read service is configured
    /// (the call routes through `WikiStore.pageOrigin`'s `dbWriter.read`); on
    /// the main actor for the simple in-memory case. Threads via the public
    /// `WikiStore` protocol so the model's `store: WikiStore` indirection
    /// doesn't need a downcast.
    public func pageOrigin(for id: PageID) async -> PageOrigin? {
        await DebugLog.trying("pageOrigin", operation: { try await store.pageOrigin(pageID: id) })
    }

    /// The distinct pages whose recorded provenance cites any of `sourceIDs`
    /// — the ingestion Overview's "Outputs" evidence, bounded by `limit`.
    /// Read-only (emits nothing). THROWS, unlike most read wrappers here: the
    /// caller must distinguish "no pages recorded" (a resolved zero) from
    /// "the read failed" and degrade each honestly — logging happens at the
    /// call seam that catches.
    public func pagesCitingSources(sourceIDs: [SourceID], limit: Int) async throws -> [CitedPage] {
        try await store.pagesCitingSources(sourceIDs: sourceIDs, limit: limit)
    }

    /// The page version that the active page editor loaded for `pageID`.
    /// Readers use this to bind render identity to the exact version state the
    /// view already owns, instead of re-querying HEAD during conversion.
    public func loadedPageHeadVersionID(for pageID: PageID) -> PageVersionID? {
        guard loadedPage == pageID else { return nil }
        return loadedPageHeadVersionID
    }

    /// The full edit history for a page — every `page_versions` row joined to
    /// its activity + agent, oldest-first. `nil`/empty when the read fails or
    /// the page has no versions. Drives the expandable "Edit history" list in
    /// `PageDetailView`.
    public func pageEditHistory(for id: PageID) async -> [PageOrigin] {
        await DebugLog.trying("pageEditHistory", operation: { try await store.pageEditHistory(pageID: id) }) ?? []
    }

    /// The full blob-decoded body of an arbitrary page version by id, or `nil`
    /// when no version matches (or the read fails). READ-ONLY — emits nothing.
    /// Used by the Versions window to view/diff a historical version without
    /// restoring it (the read-side counterpart of the `revertPage` body join).
    public func pageVersionBody(for versionID: PageVersionID) async -> String? {
        await DebugLog.trying("pageVersionBody", operation: { try await store.pageVersionBody(versionID: versionID) })
    }

    /// Restore a page to a previous version (append-only, #817). Wraps
    /// `store.restorePage`: appends a NEW `page_versions` node reusing the
    /// target's blob, records a `'restore'` PROV activity (auditable in
    /// history), and repoints HEAD to the new node. History is never mutated.
    /// The store routes the write through `mutate()` so a `.page .updated`
    /// `ResourceChangeEvent` fires (File Provider + this model's `.external`
    /// reload subscribe). Throws are swallowed (the Versions UI calls this from
    /// a button; a failure is non-fatal) — matches the `setActiveMarkdown`
    /// wrapper posture. Returns the new version id, or `nil` on failure.
    @discardableResult
    public func restorePage(for id: PageID, to versionID: PageVersionID) async -> PageVersionID? {
        guard let restored = await DebugLog.trying("restorePage", operation: { try await store.restorePage(pageID: id, to: versionID) }) else { return nil }
        await refreshProjectionsAfterOwnWrite()
        return restored
    }

    /// `true` iff `refreshSource(_:)` would actually succeed for this source —
    /// the single source of truth the detail view gates the Refresh button on.
    /// Mirrors `SourceRefreshService.materialize` + the `performRefresh` snapshot
    /// guard so the UI only offers Refresh when it can work:
    /// - `"website"` → refreshable, unless it's a snapshot with image siblings
    ///   (the single-source refresh guard, D3, would orphan them).
    /// - `"apple-podcast"` → refreshable only when this build compiled podcast
    ///   support AND the `podcast-token-helper` binary is present at runtime.
    /// - `"podcast"` (generic RSS) → refreshable on every build: the app's
    ///   refresh action enqueues the durable extraction job (RSS podcast
    ///   transcripts run through the extractor-package route in the queue —
    ///   the refresh service itself throws `.transcriptQueueRequired`, which the
    ///   app's `runRefresh` handles by enqueueing).
    /// - Everything else (local-file, Zotero, folder, unknown, missing origin)
    ///   is import-only and not refreshable.
    public func isSourceRefreshable(for id: SourceID) async -> Bool {
        guard let origin = await sourceOrigin(for: id), origin.plan != nil else { return false }
        // Delegate the baseline to `provider.supportsRefresh`, then layer the
        // runtime guards on top (snapshot image siblings for websites; the
        // bundled signing helper for podcasts). See `plans/source-provider-enum.md`
        // §supportsRefresh — this is the full predicate; the enum property is
        // baseline-only.
        guard let provider = origin.provider, provider.supportsRefresh else { return false }
        switch provider {
        case .website:
            return !(await DebugLog.trying("hasImageSiblings", operation: { try await store.hasImageSiblings(sourceID: id) }) ?? false)
        case .applePodcast:
            // Apple Podcasts transcripts run through the reviewed extractor
            // package route (Apple TTML workflow, or the package's RSS
            // fallback when no helper is staged). Refresh availability comes
            // from the route, not from helper presence — the enqueue path
            // reports a typed failure when the route is disabled.
            return true
        case .podcast:
            // Generic RSS-feed podcast: always refreshable on every build —
            // the `podcast-transcript` script needs only `uv` (no signing
            // helper). Mirrors YouTube's "no runtime guard" shape but unlike
            // YouTube the refresh DOES re-fetch a fresh transcript.
            return true
        // Exhaustive over the non-refreshable providers — `supportsRefresh`
        // returned false above, so these are unreachable; the compiler still
        // enforces exhaustiveness if a new provider is ever added (it has to
        // be added here, to `supportsRefresh`, or the build fails).
        case .localFile, .zotero, .markdownFolder,
             .youtube, .vimeo, .spotify, .soundcloud, .remoteMedia, .legacyImport:
            return false
        }
    }

    // MARK: - Processed markdown versions (v8)

    /// The latest (HEAD) processed markdown version for a file. Every source has a
    /// chain: PDFs are seeded from extraction, markdown-native sources self-seed
    /// v1 from their verbatim bytes (origin `"source"`). After seeding, new
    /// versions are appended by edits (`"user"`) or re-extraction (`"extraction"`).
    public func processedMarkdownHead(for file: SourceSummary) async -> SourceMarkdownVersion? {
        if let head = await DebugLog.trying("processedMarkdownHead", operation: { try await store.processedMarkdownHead(sourceID: file.id) }) {
            return head
        }
        // Seed v1 from verbatim bytes for markdown-native sources (MIME-keyed).
        guard MimeType.isText(file.mimeType) else { return nil }
        guard let bytes = await DebugLog.trying("sourceContent", operation: { try await store.sourceContent(id: file.id) }),
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        do {
            let seeded = try await store.appendProcessedMarkdown(
                sourceID: file.id, content: text, origin: .source, note: nil, technique: nil)
            await refreshProjectionsAfterOwnWrite()
            return seeded
        } catch {
            // #475/#492: seeding v1 from verbatim bytes is a persistence write;
            // swallowing the throw silently drops the first version with no trace.
            DebugLog.store("WikiStoreModel.processedMarkdownHead appendProcessedMarkdown (seed v1) failed (source=\(file.id.rawValue)): \(error)")
            return nil
        }
    }

    /// True when at least one processed-markdown version exists for this source.
    /// Plan P1.3 sync projection: markdown presence from the preloaded
    /// derived chains (chain non-empty <=> at least one markdown version).
    public func hasProcessedMarkdownSync(for sourceID: SourceID) -> Bool {
        !(preloadDerivedChains[sourceID]?.isEmpty ?? true)
    }

    public func hasProcessedMarkdown(for sourceID: SourceID) async -> Bool {
        await DebugLog.trying("hasProcessedMarkdown", operation: { try await store.hasProcessedMarkdown(sourceID: sourceID) }) ?? false
    }

    /// The single predicate naming the "can this source be ingested?" rule.
    /// A source is ingestible iff it has content the staging path can hand the
    /// agent — either a processed-markdown version (extracted PDF, transcript,
    /// edited text) that `processedMarkdownHead` resolves, **or** raw bytes
    /// (`byteSize > 0`) that the staging reads directly for native markdown /
    /// images / PDFs / … A **byteless** source with no processed markdown —
    /// e.g. a YouTube video whose transcript never arrived — has neither and
    /// returns `false`: there is nothing to stage, so ingestion must not run.
    /// Enforcement of the drop lives in `enqueueIngestion`; the UI gates
    /// (`SourceDetailView`, `SourcesListView`) consult this so the affordance
    /// reflects the truth.
    public func canIngest(_ source: SourceSummary) async -> Bool {
        await hasProcessedMarkdown(for: source.id) || source.byteSize > 0
    }

    /// Whether this source's content TYPE has ANY path to markdown — the
    /// **auto-ingest eligibility** gate. Distinct from `canIngest(_:)`:
    /// `canIngest` asks "is there content to stage?" (bytes or processed
    /// markdown); `shouldAutoIngest` asks "is the content TYPE one we can
    /// summarize / extract / transcribe into markdown at all?".
    ///
    /// A PNG (`image/png` → `.image`) and an XML (`application/xml` →
    /// `.binary`) return `false` here — they have bytes (so `canIngest` is
    /// `true`) but no markdown-extraction path, so the continuous-ingest
    /// coordinator must NOT enqueue them. The bug (PR1): the coordinator
    /// previously consulted `canIngest` alone, so PNG/XML sources passed
    /// and got enqueued for wasted agent runs.
    ///
    /// # Provider-aware (PR2 chokepoint-safe)
    ///
    /// Resolves via `ContentKind.resolve(mimeType:provider:ext:)` — the
    /// origin lookup is done internally so byteless `.youtube` / `.podcast`
    /// sources WITH transcripts return `true` (their synthetic MIME
    /// `video/youtube` would otherwise classify as `.binary`). The PR2
    /// chokepoint migration (`QueueIngestionHelper.enqueueIngestion`) can
    /// safely call this without re-introducing the §11-C1 YouTube/podcast
    /// regression the original §5.2 `fromMIME`-only wrapper had.
    ///
    /// # Coordinator use
    ///
    /// The coordinator's `scanWiki` does NOT call this directly — it
    /// consults `BackgroundIngestCoordinator.ingestionDecision(for:store:)`
    /// (the testable seam), which calls `ContentKind.resolve` directly so
    /// the per-source decision returns the resolved `ContentKind` (for
    /// logging / tests) without re-wrapping into a `Bool`. This wrapper is
    /// future infrastructure for the PR2 chokepoint + (optionally) the UI
    /// gates — see `plans/content-type-registry.md` §5.2.
    public func shouldAutoIngest(_ source: SourceSummary) async -> Bool {
        let origin = await sourceOrigin(for: source.id)
        let kind = ContentKind.resolve(
            mimeType: source.mimeType,
            provider: origin?.provider,
            ext: source.ext,
            registeredInputs: registeredExtractionInputs)
        return kind.capabilities.shouldAutoIngest
    }

    /// Ingestion eligibility: the content TYPE has a markdown path, OR the
    /// source already has processed markdown to stage. A `.docx` type is
    /// deliberately not auto-ingested (raw docx bytes are a binary zip with
    /// no value as staged agent context), but its import auto-extraction
    /// produces a Markdown head — and that head is exactly what ingestion
    /// stages, so a head-bearing docx is ingestable. Without this disjunction
    /// the manual Ingest chokepoint and the background coordinator would
    /// drop every extracted docx on the type predicate alone.
    public func isIngestible(_ source: SourceSummary) async -> Bool {
        let auto = await shouldAutoIngest(source)
        if auto { return true }
        return await hasProcessedMarkdown(for: source.id)
    }

    /// All versions for a source, newest first. Empty if none.
    public func processedMarkdownHistory(for sourceID: SourceID) async -> [SourceMarkdownVersion] {
        await DebugLog.trying("processedMarkdownHistory", operation: { try await store.processedMarkdownHistory(sourceID: sourceID) }) ?? []
    }

    /// Read a single resolved-markdown version by its smv id (Phase 6). Returns
    /// the blob-decoded version, or `nil` when no row matches. Used by the
    /// pinned-extraction viewer to load the exact extraction a quote was written
    /// against.
    public func processedMarkdownVersion(for id: SourceMarkdownVersionID) async -> SourceMarkdownVersion? {
        await DebugLog.trying("processedMarkdownVersion", operation: { try await store.processedMarkdownVersion(id: id) }) ?? nil
    }

    /// Every source's derived-markdown chain as `[sourceID: [smvID]]`, ULID-asc
    /// per source. Phase 6: the render precompute builds the `sourceID → [smvID]`
    /// map so `linkified` can resolve `@vN` per occurrence.
    /// Plan P1.3 — render-context inputs are PRELOADED on the async
    /// bootstrap/reload path and read synchronously by
    /// `WikiRenderContext.build(from:)`, so the memoized `renderContext()`
    /// accessor keeps its sync shape (views build closures over it).
    @ObservationIgnored private var cachedOriginsBySource: [SourceID: SourceOrigin] = [:]
    @ObservationIgnored private var preloadDerivedChains: [SourceID: [SourceMarkdownVersionID]] = [:]
    @ObservationIgnored private var preloadEmbedDescriptors: [SourceID: SourceEmbedDescriptor] = [:]
    @ObservationIgnored private var preloadSiblingMaps: [SourceID: [String: SourceID]] = [:]

    /// Fetches the three derived maps from the store. Awaited from the
    /// bootstrap and the coalesced reload drain; never call inline from a
    /// sync path.
    func preloadRenderContextInputs() async {
        preloadDerivedChains = await DebugLog.trying(
            "sourceDerivedChains",
            operation: { try await store.sourceDerivedChains() }) ?? [:]
        cachedOriginsBySource = await DebugLog.trying(
            "sourceOriginsBySource",
            operation: { try await store.sourceOriginsBySource() }) ?? [:]
        preloadEmbedDescriptors = await DebugLog.trying(
            "embedDescriptors",
            operation: { try await store.embedDescriptors() }) ?? [:]
        preloadSiblingMaps = await DebugLog.trying(
            "siblingImageResolvers",
            operation: { try await store.siblingImageResolvers() }) ?? [:]
    }

    /// SYNC projection (plan P1.3): the preloaded derived-markdown chains.
    public func sourceDerivedChains() -> [SourceID: [SourceMarkdownVersionID]] {
        preloadDerivedChains
    }

    /// SYNC projection (plan P1.3): the preloaded embed descriptors.
    public func embedDescriptors() -> [SourceID: SourceEmbedDescriptor] {
        preloadEmbedDescriptors
    }

    /// SYNC projection (plan P1.3): the preloaded sibling-image resolvers.
    public func siblingImageResolvers() -> [SourceID: [String: SourceID]] {
        preloadSiblingMaps
    }

    public func renderContext() -> WikiRenderContext {
        if let cached = cachedRenderContext,
           renderContextBuiltAtGeneration == renderContextGeneration,
           renderContextBuiltAtAvailabilityRevision == rendererMachineAvailabilityRevision {
            return cached
        }
        let built = WikiRenderContext.build(from: self)
        cachedRenderContext = built
        renderContextBuiltAtGeneration = renderContextGeneration
        renderContextBuiltAtAvailabilityRevision = rendererMachineAvailabilityRevision
        return built
    }

    /// Save an edit as a new version in the chain. Only called when the text
    /// genuinely differs from the current head — meaningful history, not
    /// keystroke spam.
    @discardableResult
    public func saveProcessedMarkdown(for sourceID: SourceID, content: String) async -> SourceMarkdownVersion? {
        do {
            let version = try await store.appendProcessedMarkdown(
                sourceID: sourceID, content: content, origin: .user, note: nil, technique: nil)
            await refreshProjectionsAfterOwnWrite()
            return version
        } catch {
            // #475/#492: the user's source-markdown edit is lost if this write
            // throws; log so it's visible in Console.app instead of vanishing.
            DebugLog.store("WikiStoreModel.saveProcessedMarkdown failed (source=\(sourceID.rawValue)): \(error)")
            return nil
        }
    }

    /// Seed the first processed-markdown version for a PDF from extraction
    /// output, recording full provenance (backend agent + extract activity). The
    /// `source_version_id` is resolved from the source's active content version.
    /// Double-seed guard: if a head already exists, returns it instead.
    ///
    /// M9 exemption (applies to this method and its siblings
    /// `appendTranscriptMarkdown` overloads, `reExtractMarkdown`, `extractHtml`,
    /// `extractDocx`): these append DERIVED markdown versions to a source's
    /// version chain and do NOT mutate the page/source list projections, so
    /// they skip `refreshProjectionsAfterOwnWrite()`. Views refresh their
    /// per-source derived state via the `WikiEventBus` drain these writes'
    /// own `ResourceChangeEvent`s trigger (`sourcesVersion` bumps on the
    /// resulting `reloadSources()`).
    @discardableResult
    public func seedPdfMarkdown(
        for sourceID: SourceID, content: String,
        backend: ExtractionBackend, modelVersion: String? = nil
    ) async -> SourceMarkdownVersion? {
        if let head = await DebugLog.trying("processedMarkdownHead", operation: { try await store.processedMarkdownHead(sourceID: sourceID) }) {
            return head
        }
        do {
            return try await store.recordMarkdownExtraction(
                sourceID: sourceID, content: content, backend: backend,
                sourceVersionID: nil, note: nil, modelVersion: modelVersion)
        } catch {
            // #475/#492: PDF extraction output (expensive) is lost if this write
            // throws; log so it's visible in Console.app instead of vanishing.
            DebugLog.store("WikiStoreModel.seedPdfMarkdown recordMarkdownExtraction failed (source=\(sourceID.rawValue)): \(error)")
            return nil
        }
    }

    /// Append a transcript markdown version (origin `.transcript`) to the
    /// processed-markdown chain for `sourceID`. Used by the queued transcription
    /// worker's `persistTranscription` path (#842). Thin pass-through to
    /// `store.appendDerivedMarkdown` — the store-level `mutate()` emission +
    /// `ResourceChangeEvent` fire inside the store, so no model-level work is
    /// needed. Mirrors `seedPdfMarkdown`'s shape for extraction.
    @discardableResult
    public func appendTranscriptMarkdown(
        for sourceID: SourceID, content: String, technique: String
    ) async -> SourceMarkdownVersion? {
        do {
            return try await store.appendDerivedMarkdown(
                sourceID: sourceID, content: content, origin: .transcript,
                producer: .tool(Self.transcriptTool(for: technique)), providerID: nil, modelID: nil,
                toolVersion: nil, sourceVersionID: nil, note: nil)
        } catch {
            DebugLog.store("WikiStoreModel.appendTranscriptMarkdown failed (source=\(sourceID.rawValue)): \(error)")
            return nil
        }
    }

    /// Typed transcript append: the producer is an `ExtractionTool`, not a
    /// raw technique string. Queue persistence uses this variant; the
    /// technique-string variant above stays for the model transcription
    /// entry point.
    @discardableResult
    public func appendTranscriptMarkdown(
        for sourceID: SourceID, content: String, tool: ExtractionTool
    ) async -> SourceMarkdownVersion? {
        do {
            return try await store.appendDerivedMarkdown(
                sourceID: sourceID, content: content, origin: .transcript,
                producer: .tool(tool), providerID: nil, modelID: nil,
                toolVersion: nil, sourceVersionID: nil, note: nil)
        } catch {
            DebugLog.store("WikiStoreModel.appendTranscriptMarkdown(tool) failed (source=\(sourceID.rawValue)): \(error)")
            return nil
        }
    }

    /// The source's immutable initial content version — the link target a
    /// package transcript requires.
    public func initialContentVersion(for sourceID: SourceID) async -> SourceVersion? {
        await DebugLog.trying("initialContentVersion", operation: {
            try await store.initialContentVersion(sourceID: sourceID)
        })
    }

    /// Re-extract a source's content with a given extractor + backend, appending
    /// a COEXISTING alternative (never clobbers the existing head). Resolves the
    /// source bytes + active content version from the store, runs the extractor,
    /// then records the provenance-carrying extraction. Returns the new
    /// alternative, or nil if the bytes can't be read or conversion fails.
    @discardableResult
    public func reExtractMarkdown(
        for sourceID: SourceID, filename: String,
        using extractor: any MarkdownExtractor,
        backend: ExtractionBackend, modelVersion: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> SourceMarkdownVersion? {
        guard let data = await DebugLog.trying("sourceContent", operation: { try await store.sourceContent(id: sourceID) }) else { return nil }
        guard let markdown = await DebugLog.trying("extractorConvert", operation: { try await extractor.convert(pdfData: data, filename: filename, onProgress: onProgress) }) else {
            return nil
        }
        do {
            return try await store.recordMarkdownExtraction(
                sourceID: sourceID, content: markdown, backend: backend,
                sourceVersionID: nil, note: "re-extract via \(backend.agentName)",
                modelVersion: modelVersion)
        } catch {
            // #475/#492: re-extraction is seconds-minutes of MLX/PDF compute;
            // swallowing the throw silently discards it with no trace.
            DebugLog.store("WikiStoreModel.reExtractMarkdown recordMarkdownExtraction failed (source=\(sourceID.rawValue)): \(error)")
            return nil
        }
    }

    /// Registration-driven auto-extraction: when an active package
    /// registration's claims recognize this source at import (an unambiguous
    /// claim on its stored MIME type or filename extension) and the wiring's
    /// derived kinds set includes the claimed kind, the conversion is
    /// ENQUEUED as a durable daemon format job immediately after the source
    /// commits. Recognition and selection both come from the registration
    /// data; this gate names no kind. The gate is synchronous and cheap; the
    /// enqueue is a detached main-actor task so the drop itself never blocks
    /// on it — best-effort at import, with the manual Extract button as the
    /// retry when the enqueue fails (a daemon down leaves the source
    /// verbatim, never a silent local conversion).
    ///
    /// Public as the import-gate test seam (the fire-and-forget task itself
    /// cannot be awaited from a test).
    public func autoExtractIfRegistered(_ summary: SourceSummary) {
        guard enqueueImportFormatJob != nil else { return }
        let claimedKind = registeredExtractionInputs
            .registeredMIME(forNormalizedMIME: summary.mimeType ?? "")?.kind
            ?? registeredExtractionInputs
                .registeredInput(forNormalizedExtension: summary.ext)?.kind
        guard let claimedKind,
              importAutoExtractionKinds.contains(claimedKind) else { return }
        let sourceID = summary.id
        // Mark in flight synchronously with the commit so the just-opened
        // source view shows the converting state immediately, not only
        // after the detached task starts. The marker clears once the enqueue
        // is acknowledged — from then on the job is durably queued and the
        // queue activity tracker owns the converting state.
        importExtractingSourceIDs.insert(sourceID)
        let enqueue = enqueueImportFormatJob
        Task { @MainActor in
            do {
                try await enqueue?(sourceID)
            } catch {
                // Import-time extraction is deliberately log-only: the
                // manual Extract button is the retry that surfaces failures
                // to the user (a daemon down leaves the source verbatim).
                DebugLog.extraction(
                    "Import auto-extraction enqueue failed (source=\(sourceID.rawValue), kind=\(claimedKind.rawValue)): \(error)")
            }
            importExtractingSourceIDs.remove(sourceID)
        }
    }

    /// **On-demand transcript dispatch** (issue #799 PR5): the unified entry
    /// point for the byteless-embed transcript pipeline. Routes by
    /// `origin.provider` to the extraction queue; the user clicks Transcribe
    /// in `SourceDetailView` to trigger this explicitly (no auto-transcription
    /// at ingest — mirrors the podcast PR4 contract, generalized to YouTube).
    ///
    /// Every transcript-capable provider — `.applePodcast`, `.podcast`, and
    /// `.youtube` — runs through the app's durable extraction queue: the
    /// model has no direct fetch path (WikiFSCore cannot reach the queue
    /// engine), and the queue's package adapters carry exact installed-package
    /// provenance for all three source classes. Throws
    /// `.transcriptQueueRequired`; callers enqueue the durable extraction job.
    ///
    /// Every other provider throws `.notRefreshable` (no transcript pipeline
    /// today; Vimeo is a future extension that needs OAuth — #564 Phase 4).
    ///
    /// Throws `.notRefreshable("unknown")` when the source has no origin or
    /// the provider is missing (e.g. a legacy / nil-origin row), and
    /// `.notRefreshable(origin.agentName)` for unsupported providers.
    @discardableResult
    public func transcribe(
        sourceID: SourceID
    ) async throws -> SourceMarkdownVersion? {
        guard let origin = await sourceOrigin(for: sourceID),
              let provider = origin.provider else {
            throw SourceRefreshService.RefreshError.notRefreshable("unknown")
        }
        switch provider {
        case .applePodcast, .podcast, .youtube:
            // All three transcript arms run through the app's extraction
            // queue (the extractor-package routes). The queue's package
            // adapters carry exact provenance for each source class, and
            // re-transcription appends an alternative without clobbering.
            throw SourceRefreshService.RefreshError.transcriptQueueRequired
        case .vimeo, .spotify, .soundcloud, .remoteMedia,
             .localFile, .website, .zotero, .markdownFolder, .legacyImport:
            throw SourceRefreshService.RefreshError.notRefreshable(origin.agentName)
        }
    }

    /// Build the byteless-source filename for an Apple Podcasts episode
    /// (issue #799 PR4): `<slug>-<id>` when the URL carried a slug, else
    /// `podcast-<id>`. Mirrors the YouTube/Vimeo `youtube-<id>` /
    /// `vimeo-<id>` byteless-source filename convention. The `-transcript.md`
    /// suffix is deliberately NOT used. The queue package writes the transcript
    /// markdown version, while this ingest path writes the source filename.
    /// The episode ID segment alone would not survive
    /// `FilenameEscaping.escapeTitle`'s spaces-as-underscores rule applied to
    /// a slug, so we escape the joined stem.
    private static func podcastEmbedFilename(for episode: PodcastEpisodeURL.EpisodeRef) -> String {
        let stem = episode.slug.map { "\($0)-\(episode.id)" } ?? "podcast-\(episode.id)"
        return FilenameEscaping.escapeTitle(stem)
    }

    /// Nominate an existing processed-markdown row as the active HEAD for a
    /// source (UPSERT the `source-derived` ref). Thin wrapper over the store.
    public func setActiveMarkdown(for sourceID: SourceID, to versionID: SourceMarkdownVersionID) async {
        await DebugLog.trying("setActiveMarkdown", operation: { try await store.setActiveMarkdown(sourceID: sourceID, to: versionID) })
        await refreshProjectionsAfterOwnWrite()
    }

    /// The producing agent name for each of a source's markdown versions
    /// (smv.id → agents.name), for the alternatives UI labels.
    public func processedMarkdownAgentNames(for sourceID: SourceID) async -> [SourceMarkdownVersionID: String] {
        await DebugLog.trying("processedMarkdownAgentNames", operation: { try await store.processedMarkdownAgentNames(sourceID: sourceID) }) ?? [:]
    }

    /// All extraction alternatives for a source with provenance + active flag,
    /// for the compare/nominate sheet (track C). Empty if none.
    public func processedMarkdownAlternatives(for sourceID: SourceID) async -> [ExtractionAlternative] {
        await DebugLog.trying("processedMarkdownAlternatives", operation: { try await store.processedMarkdownAlternatives(sourceID: sourceID) }) ?? []
    }

    // MARK: - Source-of-truth rebuild

    /// Rebuild the sidebar lists from the store — used by the Phase A change
    /// bridge after an EXTERNAL write (a `wikictl` call) lands in this wiki's DB,
    /// so the on-screen sidebar reflects pages/files the CLI wrote. Always a full
    /// rebuild from source, never an incremental patch (§3.1 / §3.2).
    ///
    /// Also refreshes the currently-displayed page's draft when the draft is
    /// clean (no unsaved user edits) so content written by the agent — which
    /// goes through the store directly, bypassing the model's draft system —
    /// appears in the reader/editor immediately (issue: stale UI after agent
    /// page write). When the draft IS dirty, the user's in-flight edits win.
    /// Plan P1.3 — sync fire-and-forget entry for existing sync callers
    /// (views, the change bridge): enqueues a coalesced reload. The async
    /// variant carries the real store reads; overlapping calls coalesce.
    public func reloadFromStore() {
        enqueueCoalescedReload()
    }

    /// Plan P1.3 — the async reload body. Runs on the main actor (SQLite is
    /// never touched off-main); awaited only from the coalesced-reload drain
    /// and `bootstrapFromStore()`.
    private func reloadFromStoreAsync() async {
        await reloadSummariesAsync()
        await reloadSourcesAsync()
        await reloadChatsAsync()
        await reloadBookmarkNodesAsync()
        pruneHistoryToCurrentStore()
        await preloadRenderContextInputs()
        await reloadCurrentDraftIfCleanAsync()
    }

    /// Plan P1.3 write-acknowledgment invariant: a model method that performs a
    /// store write returns with the list projections current (summaries,
    /// sources, chats, bookmarks), exactly as the pre-flip synchronous bus
    /// reload guaranteed. The bus may still coalesce a second drain from this
    /// write's own event; the reads are idempotent and the coalesced queue
    /// serializes them against external events.
    ///
    /// Deliberately lighter than ``reloadFromStoreAsync()``: the draft reload
    /// and render-context preloads are NOT part of the write-acknowledgment
    /// invariant, and the coalesced drain every write's bus event triggers
    /// already carries them — keeping them off the hot write path avoids
    /// doubling main-actor read volume on every mutation.
    private func refreshProjectionsAfterOwnWrite() async {
        await reloadSummariesAsync()
        await reloadSourcesAsync()
        await reloadChatsAsync()
        await reloadBookmarkNodesAsync()
        pruneHistoryToCurrentStore()
    }

    /// Incorporate the authoritative machine renderer index after a durable
    /// machine-event delivery. Active renderer pins and all resource state are
    /// deliberately untouched; installed records remain unavailable until the
    /// future activation phase.
    public func reloadRendererMachineAvailability() {
        rendererMachineAvailabilityRevision &+= 1
    }

    /// Re-read the current page's draft (title + body) from the store when the
    /// draft is clean (`!isDraftDirty`). This lets external writes (agent runs,
    /// `wikictl`) refresh the on-screen content. When the user has unsaved
    /// edits, those are preserved — the guard skips the reload entirely.
    private func reloadCurrentDraftIfCleanAsync() async {
        guard !isDraftDirty else { return }
        guard case .page(let id) = selection, loadedPage == nil || loadedPage == id else { return }
        guard let page = await DebugLog.trying("getPage", operation: { try await store.getPage(id: id) }) else { return }
        // H2: the read may have outlived its selection — a navigation A→B
        // while it was in flight would publish A's page into B's editor.
        // Re-validate the same guards the pre-await check enforced.
        guard case .page(let currentID) = selection, currentID == id,
              loadedPage == nil || loadedPage == id else { return }
        // The user may have started typing while the read was in flight; their
        // in-flight edit wins (P1.4: typing during a pending reload).
        guard !isDraftDirty else { return }
        // A pending selection-transition load that read EARLIER store state
        // must not clobber this fresher assignment when it resumes (its stamp
        // check in loadDraftsAsync sees the bump and skips its store-seeded
        // assignment).
        draftContentStamp &+= 1
        draftTitle = page.title
        draftBody = PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
        // The didSets on draftTitle/draftBody set isDraftDirty = true when
        // the value changes; reset since this is a clean reload from the
        // store (the draft now matches persisted state again).
        isDraftDirty = false
    }

    /// Rebuild the sidebar page list from the store using the current sort
    /// order. SYNC fire-and-forget wrapper — enqueues the coalesced reload so
    /// `SidebarView`'s sort-picker changes and the Phase A change bridge keep
    /// their sync call shape; the store read happens on the serialized reload
    /// path (plan P1.3).
    public func reloadSummaries() {
        enqueueCoalescedReload()
    }

    private func reloadSummariesAsync() async {
        await summaries = DebugLog.trying("listPages", operation: { try await store.listPages(sortBy: pageSortOrder) }) ?? []
        // Phase A.1: any page mutation invalidates the memoized render context.
        renderContextGeneration &+= 1
    }

    // MARK: - Search

    /// One-time, blocking search-index upgrade (plan 5.2: DAEMON-SIDE). The
    /// embedding backfill runs in the daemon — its store does the scan and
    /// the chunk writes, and its MLX embedder (loaded through the
    /// WikiFSMLX bootstrap) does the inference. This model method only:
    /// 1. runs the once-per-model-lifetime link-graph self-heal (below — it
    ///    must run even without an embedder), then
    /// 2. fires the injected daemon trigger (``startSearchUpgradeBackfill``).
    /// The non-dismissible sheet is driven ENTIRELY by the daemon's progress
    /// envelopes (``applySearchUpgradeProgress``): it appears on the first
    /// `running` event and dismisses on the terminal `complete`/`failed`
    /// state. With no injected trigger (local/test compositions) or an
    /// unstartable daemon run (no model / nothing missing) this is a no-op —
    /// the app's local MiniLM upgrade code is deleted with P5.
    public func upgradeSearchIndex() async {
        // Single-flight: set BEFORE any `await`. The scenePhase `.active` and
        // `activeWikiID` hooks can both fire at launch; without this synchronous
        // guard a second call enters during the trigger's suspension and
        // double-fires (the daemon dedupes runs, but the reconcile counter
        // below must stay once-per-model).
        guard !isUpgrading else { return }
        isUpgrading = true
        defer { isUpgrading = false }

        // Link-graph self-heal, once per model lifetime, BEFORE the trigger
        // (it must run even on model-less daemons). Store-mediated reads and
        // writes over the session's store (remote in the app — the daemon
        // executes them; local in tests) — re-resolves every page's
        // `[[links]]` so citations that only resolve under newer rules
        // (lookup-driven `#` splitting, lenient source-name matching) — or
        // whose target was ingested after the page was last saved — get
        // their link rows without waiting for the page's next edit.
        if !didReconcileLinksInThisSession {
            didReconcileLinksInThisSession = true

            // Persist the flag in `wiki_metadata` (v37, issue #477) so it
            // survives model recreation between launches. Previously an
            // in-memory boolean that reset every open, causing 600+ SQLite
            // ops on every launch for 300+ page wikis.
            let reconcileKey = "link_reconcile_version"
            let currentReconcileVersion = "1"
            let alreadyReconciled = await DebugLog.trying("getMetadata", operation: { try await store.getMetadata(reconcileKey) }) ?? ""
            if alreadyReconciled != currentReconcileVersion {
                let start = DispatchTime.now()
                let count = await DebugLog.trying("reconcileAllLinks", operation: { try await LinkReconciler.reconcileAll(in: store) }) ?? 0
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                DebugLog.store("LinkReconciler: re-resolved links for \(count) page(s) in \(Int(ms))ms")
                await DebugLog.trying("setMetadata", operation: { try await store.setMetadata(reconcileKey, value: currentReconcileVersion) })
                // The reconcile committed link-row + metadata writes; keep the
                // projections current before the early exits below.
                await refreshProjectionsAfterOwnWrite()
            }
        }

        // Fire the daemon-side backfill. The answer only logs; the sheet
        // state comes from the daemon's progress envelopes.
        guard let trigger = startSearchUpgradeBackfill else { return }
        let started = await trigger()
        if !started {
            DebugLog.store(
                "searchUpgrade: daemon did not start a backfill "
                    + "(embedder unavailable or nothing missing)")
        }
    }

    /// P5: apply one daemon progress step to ``searchUpgrade`` (the
    /// non-dismissible sheet). The session wiring hops to the main actor
    /// before calling this. A `running` step creates the sheet state on
    /// first sight and keeps it current; the terminal `complete`/`failed`
    /// steps dismiss it (a `failed` run is logged, never silent — the
    /// daemon already logged the underlying error).
    public func applySearchUpgradeProgress(_ progress: SearchUpgradeProgress) {
        switch progress.terminal {
        case .complete:
            DebugLog.store(
                "searchUpgrade: complete — daemon backfill finished "
                    + "(\(progress.total) item(s))")
            searchUpgrade = nil
        case .failed:
            DebugLog.store(
                "searchUpgrade: daemon backfill FAILED — sheet dismissed")
            searchUpgrade = nil
        case .none:
            if searchUpgrade == nil {
                searchUpgrade = SearchUpgradeState(
                    total: progress.total, done: 0, phase: progress.phase)
            }
            searchUpgrade?.done = progress.done
            searchUpgrade?.phase = progress.phase
        }
    }

    // MARK: - Search (P5: fully daemon-fused)
    //
    // Every hybrid search is ONE store-family round trip: the daemon's
    // executor resolves the Tantivy BM25 leg from its own index runtime,
    // its store computes the semantic cosine leg (the daemon loads MiniLM
    // through the WikiFSMLX bootstrap), and the store's `RankFusion.rrf`
    // fuses the legs. The app consumes the fused reply only — the client-side
    // leg resolver, the shadow-comparison log, and the read-pool search
    // branch are deleted with this phase.

    private func scheduleSearch() {
        searchTask?.cancel()
        guard !searchQuery.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task { [weak self] in
            // Task.sleep only throws CancellationError — expected, not actionable.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let query = self.searchQuery
            let results: [WikiPageSummary] = await DebugLog.trying(
                "searchSimilarPages",
                operation: {
                    try await self.store.searchSimilar(
                        query: query, limit: 20, bm25Leg: nil)
                }) ?? []
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
            // Task.sleep only throws CancellationError — expected, not actionable.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let query = self.sourceSearchQuery
            let results: [SourceSummary] = await DebugLog.trying(
                "searchSimilarSources",
                operation: {
                    try await self.store.searchSimilarSources(
                        query: query, limit: 20, bm25Leg: nil)
                }) ?? []
            guard !Task.isCancelled else { return }
            self.sourceSearchResults = results
        }
    }

    private func scheduleChatSearch() {
        chatSearchTask?.cancel()
        guard !chatSearchQuery.isEmpty else {
            chatSearchResults = []
            return
        }
        chatSearchTask = Task { [weak self] in
            // Task.sleep only throws CancellationError — expected, not actionable.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let query = self.chatSearchQuery
            // The chat sidebar search is the same daemon-side execution the
            // CLI's `chat.search` op performs: the daemon executor resolves
            // the Tantivy leg and its store fuses with the semantic leg.
            let results: [ChatSummary] = await DebugLog.trying(
                "searchSimilarChats",
                operation: {
                    try await self.store.searchSimilarChats(
                        query: query, limit: 20, bm25Leg: nil)
                }) ?? []
            guard !Task.isCancelled else { return }
            self.chatSearchResults = results
        }
    }

    private func reloadSourcesAsync() async {
        // Bump FIRST and unconditionally: extraction/transcript writes leave the
        // `sources` array `==`, and views key their derived-state refresh on this
        // counter (#1179), so the bump must not depend on the array changing.
        sourcesVersion &+= 1
        await sources = DebugLog.trying("listSources", operation: { try await store.listSources() }) ?? []
        // The explicit completion marker is written only after a validated
        // successful pipeline run. Log text is not completion evidence: an
        // agent can append a log before its run is canceled or fails.
        let markedIDs = await DebugLog.trying("markedSourceIDs", operation: { try await store.markedSourceIDs() }) ?? []

        sourceIngestedStatus = Dictionary(uniqueKeysWithValues: sources.map { file in
            (file.id, markedIDs.contains(file.id.rawValue))
        })
        // Phase A.1: any source mutation invalidates the memoized render context.
        renderContextGeneration &+= 1
    }

    // MARK: - Bookmark nodes (v16)

    /// Reload all bookmark nodes from the store. SYNC fire-and-forget wrapper
    /// (plan P1.3): enqueues the coalesced reload; the store read happens on
    /// the serialized reload path. Called by bookmark mutations via the bus.
    public func reloadBookmarkNodes() {
        enqueueCoalescedReload()
    }

    private func reloadBookmarkNodesAsync() async {
        await bookmarkNodes = DebugLog.trying("listBookmarkNodes", operation: { try await store.listBookmarkNodes() }) ?? []
    }

    // MARK: - Bookmark node mutations

    /// Create a folder at root or inside another folder. Returns the new node id,
    /// or `nil` on failure.
    @discardableResult
    public func createFolder(parentID: BookmarkID?, name: String) async -> BookmarkID? {
        // Determine the position (append at end of siblings).
        let position = bookmarkNodes.filter { $0.parentID == parentID }.count
        do {
            let node = try await store.createBookmarkNode(
                parentID: parentID, position: position, content: .folder(label: name))
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write.
            await refreshProjectionsAfterOwnWrite()
            return node.id
        } catch {
            DebugLog.store("WikiStoreModel.createFolder failed: \(error)")
            return nil
        }
    }

    /// Add a page reference to a folder. Pass `position` to insert at a specific
    /// sibling index (the store shifts later siblings down); omit it to append.
    public func addPageRef(parentID: BookmarkID?, pageID: PageID, position: Int? = nil) async {
        let t0 = DispatchTime.now()
        let pos = position ?? bookmarkNodes.filter { $0.parentID == parentID }.count
        do {
            _ = try await store.createBookmarkNode(
                parentID: parentID, position: pos, content: .page(pageID))
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            DebugLog.tabs("addPageRef: done in \(String(format: "%.1f", ms)) ms")
        } catch {
            DebugLog.store("WikiStoreModel.addPageRef failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Add a source reference to a folder. Pass `position` to insert at a specific
    /// sibling index (the store shifts later siblings down); omit it to append.
    public func addSourceRef(parentID: BookmarkID?, sourceID: SourceID, position: Int? = nil) async {
        let pos = position ?? bookmarkNodes.filter { $0.parentID == parentID }.count
        do {
            _ = try await store.createBookmarkNode(
                parentID: parentID, position: pos, content: .source(sourceID))
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write.
        } catch {
            DebugLog.store("WikiStoreModel.addSourceRef failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Add a chat reference to a folder. Pass `position` to insert at a specific
    /// sibling index (the store shifts later siblings down); omit it to append.
    public func addChatRef(parentID: BookmarkID?, chatID: ChatID, position: Int? = nil) async {
        let pos = position ?? bookmarkNodes.filter { $0.parentID == parentID }.count
        do {
            _ = try await store.createBookmarkNode(
                parentID: parentID, position: pos, content: .chat(chatID))
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write.
        } catch {
            DebugLog.store("WikiStoreModel.addChatRef failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Rename a folder.
    public func renameBookmarkNode(id: BookmarkID, to label: String) async throws {
        try await store.renameBookmarkFolder(id: id, to: label)
        await refreshProjectionsAfterOwnWrite()
        // No manual reload — the bus fires reloadFromStore() async after the
        // store write.
    }

    /// Retarget a bookmark reference to a new page/source/chat target.
    public func retargetBookmarkNode(id: BookmarkID, to content: BookmarkNode.Content) async throws {
        try await store.retargetBookmarkNode(id: id, to: content)
        await refreshProjectionsAfterOwnWrite()
        // No manual reload — the bus fires reloadFromStore() async after the
        // store write.
    }

    /// Delete a bookmark node (cascade-deletes children for folders).
    public func deleteBookmarkNode(id: BookmarkID) async {
        do {
            try await store.deleteBookmarkNode(id: id)
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write.
        } catch {
            DebugLog.store("WikiStoreModel.deleteBookmarkNode failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Move a node to a new parent and/or position. Returns `false` (and logs)
    /// if the store rejects the move — e.g. it would create a parent cycle.
    @discardableResult
    public func moveBookmarkNode(id: BookmarkID, toParentID: BookmarkID?, position: Int) async -> Bool {
        do {
            try await store.moveBookmarkNode(id: id, toParentID: toParentID, position: position)
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write.
            await refreshProjectionsAfterOwnWrite()
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
        sourceIDs: Set<SourceID>,
        chatIDs: Set<ChatID>
    ) -> Bool {
        switch value {
        case .page(let id):
            pageIDs.contains(id)
        case .source(let id):
            sourceIDs.contains(id)
        case .chat(let id):
            chatIDs.contains(id)
        case .newChat, .changeLog, .bookmark, .strategy:
            true
        }
    }

    // MARK: - Wiki strategy editor (wiki strategies plan, phase 3)

    /// The committed editorial strategy as last read from the store. `nil`
    /// means this wiki uses the Default strategy. This is the editor's
    /// display + cancel/reload base — never a live store handle.
    public private(set) var committedStrategy: WikiStrategy?
    /// The revision the last strategy read captured, **including tombstones**
    /// (`WikiStore.wikiStrategyRevision()`): `nil` when no strategy row has
    /// ever been written, otherwise the row's revision whether it holds a
    /// live strategy or a Default tombstone. Every editor save passes this as
    /// its compare-and-swap expectation.
    public private(set) var strategyExpectedRevision: WikiStrategyRevision?
    /// `true` once the first strategy read completed — distinguishes "Default"
    /// (loaded, `committedStrategy == nil`) from "not read yet".
    public private(set) var strategyDidLoad = false
    /// `true` when the last strategy read failed — the editor shows a
    /// retryable unavailable state instead of an endless spinner.
    /// Cleared by the next successful read.
    public private(set) var strategyLoadFailed = false
    /// The editor's local draft. Written directly by the view (the §3.5
    /// draftTitle/draftBody pattern: drafts live on the model so they survive
    /// view identity changes and are read at save time).
    public var strategyDraftName: String = ""
    public var strategyDraftInstructions: String = ""
    /// `true` while a draft session is open (seeded from the committed
    /// strategy). The draft persists across navigation within this wiki
    /// session — moving to another tab and back loses nothing.
    public private(set) var strategyDraftActive = false
    /// Non-nil after a save collided with another editor's commit. Carries
    /// the committed winner so the editor can offer Reload. **The draft is
    /// preserved** — the conflict never overwrites it. The pair
    /// (``strategyConflict``, ``isStrategyConflictDismissed``) stays
    /// "unresolved" until an explicit adoption clears it.
    public private(set) var strategyConflict: WikiStrategyConflictError?
    /// `true` while the user dismissed the conflict banner with "Keep Draft".
    /// The conflict itself is still unresolved: the compare-and-swap
    /// expectation stays stale, so a re-mounted editor cannot silently
    /// re-authorize an overwrite by re-reading. A new conflict (or an
    /// adoption: Reload / Cancel / successful save) resets this.
    public private(set) var isStrategyConflictDismissed = false
    /// Non-nil while an in-place wiki switch waits on the draft-protection
    /// confirmation. The view shows the banner, then calls
    /// ``applyPendingStrategyWikiSwitch()`` or
    /// ``cancelPendingStrategyWikiSwitch()`` (the `pendingCloseTabID`
    /// pattern applied to the session-swap boundary).
    public private(set) var pendingStrategyWikiSwitch: WikiID?

    /// `true` when the draft differs from the committed strategy (or from
    /// empty, when the wiki is Default). Drives Save/Cancel enabling, the
    /// tab's edit marker, and both protection confirms.
    public var isStrategyDraftDirty: Bool {
        guard strategyDraftActive else { return false }
        return strategyDraftName != strategyDraftBaseName
            || strategyDraftInstructions != strategyDraftBaseInstructions
    }

    private var strategyDraftBaseName: String { committedStrategy?.name ?? "" }
    private var strategyDraftBaseInstructions: String { committedStrategy?.instructions ?? "" }

    /// Read the committed strategy + revision from the store. Seeds the draft
    /// from the committed value when no draft session is open, so a fresh
    /// editor mount starts non-dirty. A read failure surfaces as a visible
    /// store error (and `strategyLoadFailed`, which the editor turns into a
    /// retryable state) and leaves the previous state alone.
    ///
    /// Coherence: one ``WikiStore.getWikiStrategyState()`` read returns the
    /// strategy and its revision from the same committed row, and
    /// `saveExpectation` derives the exact compare-and-swap value. Two
    /// separate reads could straddle a concurrent write and pair a stale
    /// body with a fresh revision — an expectation too HIGH, which would let
    /// a later save silently overwrite a commit the editor never saw.
    ///
    /// While a conflict is UNRESOLVED the stale expectation is preserved
    /// (see the conflict branch of ``saveStrategyDraft()``): only an explicit
    /// adoption — Reload, Cancel, or a successful save — advances it.
    public func loadWikiStrategy() async {
        do {
            let state = try await store.getWikiStrategyState()
            committedStrategy = state.strategy
            if strategyConflict == nil {
                strategyExpectedRevision = state.saveExpectation
            }
        } catch {
            DebugLog.store("loadWikiStrategy failed: \(error)")
            strategyLoadFailed = true
            storeError = StoreError(
                title: "Strategy Load Failed",
                message: "The saved strategy could not be read. Try again.")
            return
        }
        strategyLoadFailed = false
        strategyDidLoad = true
        if !strategyDraftActive {
            seedStrategyDraft()
        }
    }

    /// Replace the draft's contents with the committed strategy (or empty for
    /// Default). Used on load, save, cancel, and reload — never while the
    /// user is mid-edit unless they asked for it (Cancel / Reload).
    private func seedStrategyDraft() {
        strategyDraftName = strategyDraftBaseName
        strategyDraftInstructions = strategyDraftBaseInstructions
        strategyDraftActive = true
    }

    /// Save the draft through the store's compare-and-swap boundary.
    ///
    /// On success the committed value and CAS expectation advance, the draft
    /// reseeds from the new committed value (clean state), and any stale
    /// conflict clears. On a revision conflict the draft is **preserved** and
    /// ``strategyConflict`` holds the committed winner. Oversized or blank
    /// input surfaces as a visible store error (``storeError``); nothing is
    /// truncated. Blank instructions reset the wiki to the Default strategy
    /// (tombstone) — that is the same store-side rule, not a second one here.
    ///
    /// Strategy saves never enqueue ingestion and never rewrite pages.
    public func saveStrategyDraft() async {
        do {
            let input = try WikiStrategy.validatedInput(
                name: strategyDraftName,
                instructions: strategyDraftInstructions)
            let outcome = try await store.saveWikiStrategy(
                name: input.name,
                instructions: input.instructions ?? "",
                expectedRevision: strategyExpectedRevision)
            switch outcome {
            case .saved(let revision, let strategy):
                strategyExpectedRevision = revision
                committedStrategy = strategy
            case .unchanged:
                break
            }
            strategyConflict = nil
            isStrategyConflictDismissed = false
            seedStrategyDraft()
            await refreshProjectionsAfterOwnWrite()
        } catch let conflict as WikiStrategyConflictError {
            // Someone else committed first. Keep the draft exactly as it is;
            // the banner offers Reload against the committed winner. The
            // display value adopts the winner so status/Reload show the real
            // committed content, but the compare-and-swap expectation stays
            // at the STALE revision the user read: a later "keep editing"
            // save must conflict AGAIN (not overwrite the unseen commit)
            // until the user adopts the winner through Reload or Cancel.
            strategyConflict = conflict
            isStrategyConflictDismissed = false
            committedStrategy = conflict.currentStrategy
        } catch let textError as WikiStrategyTextError {
            storeError = StoreError(title: "Strategy Not Saved", message: textError.description)
        } catch {
            DebugLog.store("saveStrategyDraft failed: \(error)")
            storeError = StoreError(
                title: "Strategy Not Saved",
                message: "The strategy could not be saved. Try again.")
        }
    }

    /// Discard the draft and reseed it from the committed strategy. The view
    /// confirms first when the draft is dirty. After a conflict this is an
    /// explicit ADOPTION of the winner: the draft shows the committed
    /// content, so the expectation advances to the winner's revision and
    /// future saves are authorized against what the user is looking at.
    public func cancelStrategyDraft() {
        if let conflict = strategyConflict {
            strategyExpectedRevision = conflict.currentRevision
        }
        strategyConflict = nil
        seedStrategyDraft()
    }

    /// Reset the wiki to the Default strategy. Implemented as a save of blank
    /// instructions — the store's own whitespace-reset rule — so the CAS
    /// expectation, the tombstone revision, and the change event all flow
    /// through one write boundary. The view confirms first.
    public func resetStrategyToDefault() async {
        strategyDraftName = ""
        strategyDraftInstructions = ""
        await saveStrategyDraft()
    }

    /// Copy a starter template's name and instructions into the draft. This
    /// is a value copy into the local draft only: it does not save, does not
    /// link the wiki to the template, and never touches pages. The view
    /// confirms first when the draft already holds text.
    public func applyStrategyTemplate(_ template: WikiStrategyTemplate) {
        strategyDraftName = template.name
        strategyDraftInstructions = template.markdown
        strategyDraftActive = true
    }

    /// Resolve a conflict by adopting the committed winner: reseed the draft
    /// from the committed strategy, advance the compare-and-swap expectation
    /// to the winner's revision (the user is now editing the content they
    /// see), and clear the banner. The view confirms that this replaces the
    /// unsaved draft.
    public func discardStrategyDraftAndReload() {
        if let conflict = strategyConflict {
            strategyExpectedRevision = conflict.currentRevision
        }
        strategyConflict = nil
        isStrategyConflictDismissed = false
        seedStrategyDraft()
    }

    /// Dismiss the conflict banner and keep editing the untouched draft.
    /// The conflict stays UNRESOLVED: the expectation stays at the STALE
    /// revision (so the user's next save conflicts again — safe), and a
    /// later editor re-mount cannot re-read its way past it. Keeping a draft
    /// never authorizes overwriting a commit the user has not adopted.
    public func dismissStrategyConflict() {
        isStrategyConflictDismissed = true
    }

    /// Defer an in-place wiki switch when a dirty strategy draft would be
    /// lost with the session. Returns `true` when deferred (the caller must
    /// NOT switch yet — the confirmation alert owns the switch); `false` when
    /// there is nothing to protect and the caller may switch immediately.
    /// Opening a wiki in a NEW window never passes through here: the session
    /// (and the draft with it) survives, so no protection is needed.
    @discardableResult
    public func deferInPlaceWikiSwitchIfNeeded(to target: WikiID) -> Bool {
        guard isStrategyDraftDirty else { return false }
        pendingStrategyWikiSwitch = target
        return true
    }

    /// Apply the deferred switch after the user chose to discard the draft:
    /// clear the draft + pending state and return the target so the HOSTING
    /// SCENE can perform the actual session swap. The registry's active id
    /// already changed when the guard deferred, so the scene cannot wait for
    /// another change notification — the confirmation drives the swap.
    @discardableResult
    public func applyPendingStrategyWikiSwitch() -> WikiID? {
        guard let target = pendingStrategyWikiSwitch else { return nil }
        pendingStrategyWikiSwitch = nil
        strategyConflict = nil
        isStrategyConflictDismissed = false
        strategyDraftActive = false
        strategyDraftName = ""
        strategyDraftInstructions = ""
        return target
    }

    /// Keep the draft: cancel the deferred switch. The user stays on this
    /// wiki with the draft intact.
    public func cancelPendingStrategyWikiSwitch() {
        pendingStrategyWikiSwitch = nil
    }

    /// Drop all editor state for a closing strategy tab. Called from the tab
    /// close confirmation (the user chose to discard); there is no tab left
    /// to reseed, so the draft simply ends.
    public func discardStrategyDraftForClosedTab() {
        strategyConflict = nil
        strategyDraftActive = false
        strategyDraftName = ""
        strategyDraftInstructions = ""
        pendingStrategyWikiSwitch = nil
    }

    // MARK: - Persisted chats (issue #119)

    /// Create a persisted chat, titled from the first user message. Returns nil
    /// (logging via DebugLog.store) on store failure — persistence must never
    /// block a chat from starting. A message that derives no usable title
    /// (#1265) creates the row genuinely untitled; first-send titling and the
    /// post-turn title upgrade can still name it later.
    @discardableResult
    public func startChat(kind: ChatKind, firstMessage: String) async -> ChatSummary? {
        do {
            let title = ChatSummary.title(fromFirstMessage: firstMessage) ?? ""
            let chat = try await store.createChat(kind: kind, title: title)
            // Seed the first user message immediately (seq 0) so a chat is never
            // titled-but-empty — even if the agent session dies before its first
            // turn produces any events (the orphan-chat bug: a `chats` row with a
            // title but zero `chat_messages`). The launcher is told the message is
            // already persisted (firstMessagePrePersisted) so it marks the event as
            // flushed and does NOT double-insert it on the first transcript flush.
            try await store.appendChatMessages(chatID: chat.id, events: [.userText(firstMessage)])
            // Insert the single new chat into the local array instead of a full
            // reloadChats(). The bus fires reloadFromStore() async after the store
            // write, but the immediate caller (retargetActiveTabToChat →
            // retargetTab → tabTitle) reads `chats` synchronously, so the row
            // must be present NOW.
            chats.insert(chat, at: 0)
            await refreshProjectionsAfterOwnWrite()
            return chat
        } catch {
            DebugLog.store("WikiStoreModel.startChat failed: \(error)")
            return nil
        }
    }

    /// Roll back a chat created by `startChat` when its session never started
    /// (preflight/spawn failure in `startChat`). Deletes the row
    /// (and its seeded first message, via `ON DELETE CASCADE`) and reverts the
    /// tab that was retargeted to it back to the draft composer — so the user
    /// isn't left on a dead `.chat` selection. Best-effort: a store failure is
    /// logged, never thrown.
    public func rollbackChatCreation(id: ChatID, toDraft draft: WikiSelection) async {
        do {
            try await store.deleteChat(id: id)
        } catch {
            DebugLog.store("WikiStoreModel.rollbackChatCreation failed: \(error)")
        }
        // No manual reloadChats — the bus fires reloadFromStore() async after the
        // delete. The tab retarget below doesn't depend on the chats array.
        // Revert the tab we retargeted to `.chat(id)` back to the draft composer.
        if let tab = tabs.first(where: { $0.selection == .chat(id) }) {
            retargetTab(id: tab.id, to: draft)
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Append the persistable subset of `events` to a chat. Non-persistable
    /// events (deltas, messageStop, raw) are filtered here as defense in depth.
    public func appendChatEvents(chatID: ChatID, events: [AgentEvent]) async {
        let persistable = events.filter(\.isPersistable)
        guard !persistable.isEmpty else { return }
        do {
            try await store.appendChatMessages(chatID: chatID, events: persistable)
            // No manual reload — the bus fires reloadFromStore() async after the
            // store write (keeps updated_at ordering + counts live).
        } catch {
            DebugLog.store("WikiStoreModel.appendChatEvents failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Checkpoint a streaming assistant row to the store via the draft-handle
    /// upsert (#826, C2). Returns `true` on success so the launcher can advance
    /// its cursor only when the row was actually persisted — on failure the
    /// dirty flag stays set so the next checkpoint retries (no silent data
    /// loss). Routes through the store's `mutate()` + emits (C6: draft
    /// checkpoints skip `updated_at`; only finalize bumps it).
    @discardableResult
    public func checkpointStreamingMessage(
        chatID: ChatID, handle: String, event: AgentEvent, isDraft: Bool
    ) async -> Bool {
        do {
            try await store.checkpointStreamingMessage(
                chatID: chatID, handle: handle, event: event, isDraft: isDraft)
            await refreshProjectionsAfterOwnWrite()
            return true
        } catch {
            DebugLog.store("WikiStoreModel.checkpointStreamingMessage failed: \(error)")
            return false
        }
    }

    /// Finalize stale drafts for a chat on reopen (C8). Cheap single UPDATE.
    public func finalizeStaleDrafts(forChat chatID: ChatID) async {
        do {
            try await store.finalizeStaleDrafts(forChat: chatID)
        } catch {
            DebugLog.store("WikiStoreModel.finalizeStaleDrafts failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    public func chatMessages(chatID: ChatID) async -> [ChatMessage] {
        await DebugLog.trying("chatMessages", operation: { try await store.chatMessages(chatID: chatID) }) ?? []
    }

    public func readChatTranscriptPage(
        chatID: ChatID,
        after cursor: ChatTranscriptCursor?,
        limit: Int
    ) async -> ChatTranscriptPage {
        await DebugLog.trying("readChatTranscriptPage", operation: {
            try await store.readChatTranscriptPage(chatID: chatID, after: cursor, limit: limit)
        }) ?? ChatTranscriptPage(
            items: [],
            checkpoint: cursor ?? .zero,
            nextCursor: nil
        )
    }

    public func chatTranscriptCheckpoint(chatID: ChatID) async -> ChatTranscriptCursor {
        await DebugLog.trying("chatTranscriptCheckpoint", operation: {
            try await store.chatTranscriptCheckpoint(chatID: chatID)
        }) ?? .zero
    }

    public func renameChat(id: ChatID, to title: String) async {
        do {
            try await store.renameChat(id: id, to: title)
            // No manual reload — the bus fires reloadFromStore() async after the
            // rename.
        } catch {
            DebugLog.store("WikiStoreModel.renameChat failed: \(error)")
            storeError = StoreError(
                title: "Couldn't Rename Chat",
                message: "Could not rename the chat: \(error.localizedDescription)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// `@MainActor` wrapper for the ACP session ID write/clear (#830). Written
    /// at spawn time (persist) and on resume failure (clear). No manual reload
    /// — the bus fires `reloadFromStore()` async after the store write.
    public func updateChatAcpSessionId(chatID: ChatID, acpSessionId: AcpSessionID?) async {
        do {
            try await store.updateChatAcpSessionId(chatID: chatID, acpSessionId: acpSessionId)
        } catch {
            DebugLog.store("WikiStoreModel.updateChatAcpSessionId failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Resolves one chat authoritatively instead of inferring existence from
    /// the cached `chats` projection. Only `.chatNotFound` means the chat was
    /// deleted; database failures remain retryable errors.
    public func resolveChat(id: ChatID) async -> ChatResolution {
        do {
            return .available(try await store.getChat(id: id))
        } catch WikiStoreError.chatNotFound {
            return .notFound
        } catch {
            DebugLog.store("WikiStoreModel.resolveChat failed for \(id.rawValue): \(error)")
            return .failed(error.localizedDescription)
        }
    }

    /// Compatibility wrapper for callers that only need an optional summary.
    public func getChat(id: ChatID) async -> ChatSummary? {
        guard case .available(let summary) = await resolveChat(id: id) else { return nil }
        return summary
    }

    /// `@MainActor` wrapper for the per-chat model override write/clear (the
    /// composer's `ProviderSelector` picking a model for THIS chat). No
    /// manual reload — the bus fires `reloadFromStore()` async after the
    /// `.chat .updated` emit, same as `renameChat`.
    public func updateChatModelOverride(id: ChatID, providerId: ProviderID?, modelId: ModelID?) async {
        do {
            try await store.updateChatModelOverride(id: id, providerId: providerId, modelId: modelId)
        } catch {
            DebugLog.store("WikiStoreModel.updateChatModelOverride failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// Atomically updates every durable chat selection field so observers never
    /// see a new provider/model paired with an old effective thinking value.
    public func updateChatModelAndThinkingSelection(
        chatID: ChatID,
        providerID: ProviderID?,
        modelID: ModelID?,
        configuredThinkingID: ChatConfigurationValueID?,
        effectiveThinkingID: ChatConfigurationValueID?
    ) async {
        do {
            try await store.updateChatModelAndThinkingSelection(
                chatID: chatID,
                providerID: providerID,
                modelID: modelID,
                configuredThinkingID: configuredThinkingID,
                effectiveThinkingID: effectiveThinkingID)
            // Synchronous cache refresh, same principle as startChat's
            // immediate insert: the composer selectors derive the NEXT
            // selection from `chats`, and a back-to-back pick (provider then
            // thinking, or the reverse) must read the row just written — not
            // a stale projection awaiting the async bus reload. The bus
            // reload still lands afterwards and is harmless.
            reloadChats()
        } catch {
            DebugLog.store("WikiStoreModel.updateChatModelAndThinkingSelection failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    /// `@MainActor` wrapper for the per-message summary write (chat-summary
    /// plan §3.5). The summarizer's off-main compute marshals back here for the
    /// DB write (no inference inside a transaction). No manual reload — the bus
    /// fires `reloadFromStore()` async after the `.chat .updated` emit.
    public func updateMessageSummary(
        chatID: ChatID, cursor: ChatTranscriptCursor, summary: String, kind: ChatMessageSummaryKind
    ) async {
        do {
            try await store.updateMessageSummary(
                chatID: chatID, cursor: cursor, summary: summary, kind: kind)
        } catch {
            DebugLog.store("WikiStoreModel.updateMessageSummary failed: \(error)")
        }
        await refreshProjectionsAfterOwnWrite()
    }

    public func deleteChat(id: ChatID) async {
        do {
            try await store.deleteChat(id: id)
            removeFromHistory(.chat(id))
            // Close any tab showing this deleted chat.
            if let tab = tabs.first(where: { $0.selection == .chat(id) }) {
                closeTab(id: tab.id)
            }
            // No manual reload — the bus fires reloadFromStore() async after the
            // delete. History and tab cleanup happen explicitly above.
        } catch {
            DebugLog.store("WikiStoreModel.deleteChat failed: \(error)")
            storeError = StoreError(
                title: "Couldn't Delete Chat",
                message: "Could not delete the chat: \(error.localizedDescription)")
        }
        await refreshProjectionsAfterOwnWrite()
    }
}

extension WikiStoreModel: RendererAuthorizedInputResolving {}

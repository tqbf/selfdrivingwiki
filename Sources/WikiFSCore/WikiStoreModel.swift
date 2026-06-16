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
    /// The sidebar selection: a page, the system-prompt document, or nothing.
    public var selection: WikiSelection?

    /// The removable list of ingested files (Phase 5). Like `summaries`, this is
    /// ALWAYS rebuilt from `store.listIngestedFiles()` after a change, never
    /// incrementally patched (§3.1). Most-recent-first.
    public private(set) var ingestedFiles: [IngestedFileSummary] = []

    /// Invoked on the main actor after any successful persisted mutation
    /// (save / new / rename / delete). The app wires this to the File Provider
    /// `signalChange()` so Terminal reads see edits without relaunch (INITIAL
    /// §6/§10). Nil-safe: tests leave it unset, and `WikiFSCore` never imports
    /// `FileProvider` — the closure is injected from the app layer.
    @ObservationIgnored public var onPageDidChange: (@MainActor () -> Void)?

    /// Live editing buffers — the single source of in-flight text.
    public var draftTitle: String = ""
    public var draftBody: String = ""

    /// Live editing buffer for the system-prompt document (the singleton
    /// `CLAUDE.md`/`AGENTS.md`). Separate track from the page drafts above so the
    /// well-tested page autosave path is untouched.
    public var draftSystemPrompt: String = ""

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

    public init(store: WikiStore) {
        self.store = store
        reloadSummaries()
        reloadIngestedFiles()
        // Preload the system-prompt draft so its editor has content immediately;
        // selecting it later reloads fresh from the store.
        draftSystemPrompt = (try? store.getSystemPrompt())?.body ?? SystemPrompt.defaultBody
    }

    // MARK: - Selection / loading

    /// Switch the selection programmatically. Flushes any pending save
    /// SYNCHRONOUSLY first (§3.5 immediate-on-switch) so the outgoing document
    /// can't lose buffered edits, then loads the new selection's text.
    public func select(_ newValue: WikiSelection?) {
        guard newValue != selection else { return }
        flushPendingSaves()
        selection = newValue
        loadDrafts(for: newValue)
    }

    /// Bridge for SwiftUI's `List(selection:)`, which writes `selection`
    /// DIRECTLY (bypassing `select(_:)`). The view observes the property with
    /// `.onChange(of:)` and calls this. Flushing reads the drafts, which still
    /// belong to `loadedSelection`, so the outgoing document's edits are
    /// persisted before we load the incoming one (§3.5).
    public func handleSelectionChange(to newValue: WikiSelection?) {
        guard newValue != loadedSelection else { return }
        flushPendingSaves()     // persists drafts to loadedSelection
        loadDrafts(for: newValue)
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
    /// matching the link graph) and selects it through the SAME `select(_:)` seam
    /// the sidebar uses — so the outgoing page's pending edits flush first and the
    /// incoming draft loads (§3.5). Returns whether navigation happened, so the
    /// click handler can report `.handled`. A no-op (returns `false`) if the title
    /// has no page.
    @discardableResult
    public func selectPage(byTitle title: String) -> Bool {
        guard let id = (try? store.resolveTitleToID(title)) ?? nil else { return false }
        select(.page(id))
        return true
    }

    private func loadDrafts(for newValue: WikiSelection?) {
        loadedSelection = newValue
        switch newValue {
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
        case nil:
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
        }
    }

    // MARK: - Editing / autosave

    /// Called on each keystroke in the title or body. Cancels and restarts a
    /// 500ms debounce; when it fires it reads the live drafts and saves.
    public func bodyChanged() { scheduleAutosave() }
    public func titleChanged() { scheduleAutosave() }

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
    /// freshest text to the RIGHT page. No-op when nothing is loaded. Always
    /// rebuilds `summaries` from source on success.
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
            reloadSummaries()
            onPageDidChange?()
        } catch {
            // Phase 1: log to console; a save-error surface lands later.
            print("WikiStoreModel.save failed: \(error)")
        }
    }

    /// Cancel any pending debounce and save synchronously. Called on page
    /// switch and on app backgrounding (§3.5 immediate-on-background).
    public func flushPendingSave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        save()
    }

    // MARK: - System prompt editing (singleton document)

    /// Called on each keystroke in the system-prompt editor; debounced like the
    /// page editor (separate task so the two tracks don't cancel each other).
    public func systemPromptChanged() {
        // Paused while an agent runs (decision #6), same as the page autosave.
        guard !isAgentRunning else { return }
        systemPromptAutosaveTask?.cancel()
        systemPromptAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveSystemPrompt()
        }
    }

    /// Persist the system-prompt draft. Guarded on `loadedSelection` so a flush
    /// triggered once selection has moved off the prompt doesn't clobber it with
    /// stale text (mirrors `save()`'s `loadedPage` guard). Bumps the row version,
    /// which advances `changeToken()` so `CLAUDE.md`/`AGENTS.md` refresh.
    public func saveSystemPrompt() {
        guard loadedSelection == .systemPrompt else { return }
        do {
            try store.updateSystemPrompt(body: draftSystemPrompt)
            onPageDidChange?()
        } catch {
            print("WikiStoreModel.saveSystemPrompt failed: \(error)")
        }
    }

    /// Cancel the system-prompt debounce and save synchronously.
    public func flushPendingSystemPromptSave() {
        systemPromptAutosaveTask?.cancel()
        systemPromptAutosaveTask = nil
        saveSystemPrompt()
    }

    /// Flush BOTH editing tracks. Used on selection switch and app backgrounding
    /// so neither a page edit nor a system-prompt edit is lost.
    public func flushPendingSaves() {
        flushPendingSave()
        flushPendingSystemPromptSave()
    }

    // MARK: - Agent run lock (Phase C, decision #6)

    /// Enter the edit-locked state for the duration of a `claude -p` run: flush any
    /// pending edits FIRST (so nothing in-flight is lost), then mark the model
    /// running so the editor goes read-only and autosave is paused. Pausing
    /// autosave is what prevents the in-app save from clobbering the agent's
    /// `wikictl` writes. The live change-bridge `reloadFromStore()` is unaffected —
    /// the sidebar still fills in as the agent's writes land.
    public func beginAgentRun() {
        flushPendingSaves()
        isAgentRunning = true
    }

    /// Exit the edit-locked state (from the spawn's `terminationHandler`, so a
    /// killed agent still re-enables editing). Rebuilds the lists from the store so
    /// the sidebar reflects everything the agent wrote, and reloads the open
    /// document's draft from the (possibly agent-rewritten) source.
    public func endAgentRun() {
        isAgentRunning = false
        reloadFromStore()
        loadDrafts(for: loadedSelection)
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
            selection = .page(page.id)
            loadDrafts(for: .page(page.id))
            onPageDidChange?()
        } catch {
            print("WikiStoreModel.newPage failed: \(error)")
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
            onPageDidChange?()
        } catch {
            print("WikiStoreModel.rename failed: \(error)")
        }
    }

    public func delete(_ id: PageID) {
        do {
            try store.deletePage(id: id)
            if selection == .page(id) {
                autosaveTask?.cancel()
                autosaveTask = nil
                selection = nil
                loadDrafts(for: nil)
            }
            reloadSummaries()
            onPageDidChange?()
        } catch {
            print("WikiStoreModel.delete failed: \(error)")
        }
    }

    // MARK: - File ingestion (Phase 5)

    /// Ingest dropped files. For each URL: reject directories (a recursive
    /// directory ingest is out of scope), read the bytes OFF the main thread
    /// (big files shouldn't stall the UI), then hop back to the main actor to
    /// store + reload. Per-file failures are logged and skipped so one bad drop
    /// doesn't abort the batch. `onPageDidChange?()` fires ONCE at the end so the
    /// daemon re-enumerates the `files/` tree exactly once for the whole batch.
    public func ingest(fileURLs: [URL]) async {
        var didIngestAny = false
        for url in fileURLs {
            // Skip directories — only flat files are ingested.
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                print("WikiStoreModel.ingest skipping directory: \(url.lastPathComponent)")
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
                print("WikiStoreModel.ingest read failed for \(filename): \(error)")
                continue
            }
            do {
                _ = try store.ingestFile(filename: filename, data: data)
                didIngestAny = true
            } catch {
                print("WikiStoreModel.ingest store failed for \(filename): \(error)")
            }
        }
        reloadIngestedFiles()
        if didIngestAny { onPageDidChange?() }
    }

    /// Ingest a resource by URL: fetch it, convert HTML→Markdown (or store a PDF /
    /// text / binary verbatim), and land it as an ingested file — exactly like a
    /// drag-dropped file, so the existing "Ingest into wiki" `claude -p` operation
    /// can summarize it afterward. Lands through the SAME `store.ingestFile` path as
    /// drag-ingest, so it appears under Files + `files/by-{id,name}` immediately and
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
        _ = try store.ingestFile(filename: plan.filename, data: plan.data)
        reloadIngestedFiles()
        onPageDidChange?()
        return URLIngestService.IngestOutcome(
            filename: plan.filename, byteSize: plan.data.count, kind: plan.kind)
    }

    /// Synchronous ingest seam used by tests/verifiers (no drag gesture). Stores
    /// the bytes, rebuilds the list, and signals the daemon.
    public func ingestFile(filename: String, data: Data) {
        do {
            _ = try store.ingestFile(filename: filename, data: data)
            reloadIngestedFiles()
            onPageDidChange?()
        } catch {
            print("WikiStoreModel.ingestFile failed: \(error)")
        }
    }

    /// Remove an ingested file from the list and the store, then signal so the
    /// `files/` tree drops it.
    public func deleteIngestedFile(_ id: PageID) {
        do {
            try store.deleteIngestedFile(id: id)
            reloadIngestedFiles()
            onPageDidChange?()
        } catch {
            print("WikiStoreModel.deleteIngestedFile failed: \(error)")
        }
    }

    /// The current `system_prompt` singleton body from the store (the seeded
    /// default if absent) — the agent run passes this verbatim via
    /// `--append-system-prompt`. Read fresh from the store, not from the draft, so
    /// it reflects the last persisted edit even if the prompt editor isn't open.
    public func currentSystemPromptBody() -> String {
        (try? store.getSystemPrompt())?.body ?? SystemPrompt.defaultBody
    }

    // MARK: - Source-of-truth rebuild

    /// Rebuild the sidebar lists from the store — used by the Phase A change
    /// bridge after an EXTERNAL write (a `wikictl` call) lands in this wiki's DB,
    /// so the on-screen sidebar reflects pages/files the CLI wrote. Always a full
    /// rebuild from source, never an incremental patch (§3.1 / §3.2). The active
    /// editing draft is untouched — only the list projections refresh.
    public func reloadFromStore() {
        reloadSummaries()
        reloadIngestedFiles()
    }

    private func reloadSummaries() {
        summaries = (try? store.listPages()) ?? []
    }

    private func reloadIngestedFiles() {
        ingestedFiles = (try? store.listIngestedFiles()) ?? []
    }
}

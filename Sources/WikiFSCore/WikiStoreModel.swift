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
    public var selection: PageID?

    /// Invoked on the main actor after any successful persisted mutation
    /// (save / new / rename / delete). The app wires this to the File Provider
    /// `signalChange()` so Terminal reads see edits without relaunch (INITIAL
    /// §6/§10). Nil-safe: tests leave it unset, and `WikiFSCore` never imports
    /// `FileProvider` — the closure is injected from the app layer.
    @ObservationIgnored public var onPageDidChange: (@MainActor () -> Void)?

    /// Live editing buffers — the single source of in-flight text.
    public var draftTitle: String = ""
    public var draftBody: String = ""

    private let store: WikiStore
    private var autosaveTask: Task<Void, Never>?
    /// The page whose text currently lives in the draft buffers.
    private var loadedPage: PageID?

    public init(store: WikiStore) {
        self.store = store
        reloadSummaries()
    }

    // MARK: - Selection / loading

    /// Switch to a page programmatically. Flushes any pending save
    /// SYNCHRONOUSLY first (§3.5 immediate-on-switch) so the outgoing page
    /// can't lose buffered edits, then loads the new page's text.
    public func select(_ id: PageID?) {
        guard id != selection else { return }
        flushPendingSave()
        selection = id
        loadDrafts(for: id)
    }

    /// Bridge for SwiftUI's `List(selection:)`, which writes `selection`
    /// DIRECTLY (bypassing `select(_:)`). The view observes the property with
    /// `.onChange(of:)` and calls this. Flushing reads the drafts, which still
    /// belong to `loadedPage`, so the outgoing page's edits are persisted
    /// before we load the incoming page (§3.5).
    public func handleSelectionChange(to newValue: PageID?) {
        guard newValue != loadedPage else { return }
        flushPendingSave()      // persists drafts to loadedPage
        loadDrafts(for: newValue)
    }

    private func loadDrafts(for id: PageID?) {
        guard let id, let page = try? store.getPage(id: id) else {
            draftTitle = ""
            draftBody = ""
            loadedPage = nil
            return
        }
        draftTitle = page.title
        draftBody = page.bodyMarkdown
        loadedPage = id
    }

    // MARK: - Editing / autosave

    /// Called on each keystroke in the title or body. Cancels and restarts a
    /// 500ms debounce; when it fires it reads the live drafts and saves.
    public func bodyChanged() { scheduleAutosave() }
    public func titleChanged() { scheduleAutosave() }

    private func scheduleAutosave() {
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
            try store.updatePage(id: id, title: draftTitle, body: draftBody)
            // Re-resolve this page's [[wiki-links]] against the current title
            // graph (Phase 4). Parsing is pure; the store resolves targets and
            // rewrites `page_links`. v0 limitation: a *rename* does NOT re-walk
            // the whole graph, so links that targeted the old title go stale
            // until the linking page is next saved (they self-heal then).
            try store.replaceLinks(from: id, parsedLinks: WikiLinkParser.parse(draftBody))
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

    // MARK: - Mutations

    public func newPage(title: String = "Untitled") {
        flushPendingSave()
        do {
            let page = try store.createPage(title: title)
            // A fresh page has an empty body, so this resolves to no links — but
            // run it for uniformity with the save() path (and so a future
            // create-with-body wouldn't silently skip link indexing).
            try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(page.bodyMarkdown))
            reloadSummaries()
            selection = page.id
            loadDrafts(for: page.id)
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
            if selection == id { draftTitle = newTitle }
            onPageDidChange?()
        } catch {
            print("WikiStoreModel.rename failed: \(error)")
        }
    }

    public func delete(_ id: PageID) {
        do {
            try store.deletePage(id: id)
            if selection == id {
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

    // MARK: - Source-of-truth rebuild

    private func reloadSummaries() {
        summaries = (try? store.listPages()) ?? []
    }
}

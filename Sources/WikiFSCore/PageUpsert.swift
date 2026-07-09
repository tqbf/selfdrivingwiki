import Foundation

/// The one shared "write a page + keep its link graph consistent" operation
/// (`plans/llm-wiki.md` — "Shared link-reparse refactor").
///
/// Before Phase A the sequence "persist the body, then re-parse `[[links]]` and
/// rewrite `page_links`" lived inline in `WikiStoreModel.save()` /
/// `newPage()`. Phase A adds a SECOND writer — the `wikictl` CLI — and the doc
/// is explicit that the link graph must stay consistent **identically** from
/// both, with "no second drifting implementation in the CLI". So that sequence
/// is lifted here, and BOTH the app model and `wikictl` call it.
///
/// Pure orchestration over the `WikiStore` protocol: it does the create-or-find,
/// the body write, the parse (via `WikiLinkParser`), and the `replaceLinks` — in
/// the order the store expects. It owns no I/O of its own and imports nothing
/// beyond Foundation, so it is trivially unit-testable against a temp DB.
public enum PageUpsert {

    /// The result of an upsert: the resolved page id and whether it was created
    /// vs. updated (so callers — and the CLI's output — can report which).
    public struct Outcome: Equatable, Sendable {
        public let id: PageID
        public let didCreate: Bool

        public init(id: PageID, didCreate: Bool) {
            self.id = id
            self.didCreate = didCreate
        }
    }

    /// Create-or-update a page, then re-resolve its `[[wiki-links]]` against the
    /// current title graph — the single seam the app model and `wikictl` share.
    ///
    /// Resolution order, matching the doc's `wikictl page upsert` contract:
    /// 1. If `id` is given, update THAT page (an explicit-id update; the title
    ///    is rewritten too, mirroring the in-app rename+edit path).
    /// 2. Otherwise resolve `title` → an existing page id via
    ///    `resolveTitleToID` (lowest ULID on a duplicate-title collision, the
    ///    same rule the link resolver uses) and update it.
    /// 3. If neither yields a page, create a new one and write its body.
    ///
    /// After the write, the body's links are parsed (pure) and `replaceLinks`
    /// rewrites `page_links` in one transaction — so a CLI write and an in-app
    /// write leave byte-identical link rows. A *rename* still does not re-walk
    /// the whole graph (the v0 limitation): links that targeted the old title
    /// self-heal on the linking page's next upsert.
    @discardableResult
    public static func upsert(
        in store: WikiStore,
        id: PageID?,
        title: String,
        body: String
    ) throws -> Outcome {
        // Sanitize BEFORE the title→id resolve, not just in the store's
        // create/update (which sanitizes again as a backstop): resolving the
        // raw title against sanitized stored titles would always miss, and
        // every upsert of the same unlinkable title would create a new page.
        let title = WikiNameRules.sanitized(title)
        // Canonicalize the body's `[[…]]` links to ULID-stable form BEFORE the
        // write (Phase 5): every resolvable link becomes `[[kind:ULID|alias]]`,
        // so renames self-heal at render instead of dropping link rows. The raw
        // body is passed through so both the app and `wikictl` canonicalize
        // identically (the single shared write seam). Unresolved (forward) links
        // are left byte-identical. `nil` = nothing changed → write the body as-is.
        let canonicalBody = (try WikiLinkRewriter.canonicalize(
            in: body, resolvePage: store.resolveTitleToID,
            resolveSource: store.resolveSourceByName,
            resolveChat: store.resolveChatByTitle)) ?? body
        let outcome = try writePage(in: store, id: id, title: title, body: canonicalBody)
        // Parse the CANONICAL body so link rows match the stored bytes exactly.
        try store.replaceLinks(from: outcome.id, parsedLinks: WikiLinkParser.parse(canonicalBody))
        // Compute + store chunk embeddings for the page body. Non-fatal: a
        // failure (or the model being unavailable, e.g. under `wikictl`) never
        // breaks the save — the background backfill embeds it later.
        let text = body.isEmpty ? title : "\(title)\n\n\(body)"
        let chunks = EmbeddingService.chunkedEmbeddings(for: text)
        if !chunks.isEmpty {
            try? store.storePageChunks(id: outcome.id, chunks: chunks)
        }
        return outcome
    }

    /// Persist the page row (create or update) WITHOUT touching links, returning
    /// the resolved id + create/update flag. Split out so the link reparse in
    /// `upsert(in:id:title:body:)` reads as one statement.
    private static func writePage(
        in store: WikiStore,
        id: PageID?,
        title: String,
        body: String
    ) throws -> Outcome {
        if let id {
            try store.updatePage(id: id, title: title, body: body)
            return Outcome(id: id, didCreate: false)
        }
        if let existing = try store.resolveTitleToID(title) {
            try store.updatePage(id: existing, title: title, body: body)
            return Outcome(id: existing, didCreate: false)
        }
        let page = try store.createPage(title: title)
        try store.updatePage(id: page.id, title: title, body: body)
        return Outcome(id: page.id, didCreate: true)
    }
}

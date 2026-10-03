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
/// Cumulative ingestion (plan phase 4 §9) routes the whole sequence through
/// the store's composed ``WikiStore/upsertPage(id:title:rawBody:expectation:author:provenance:)``
/// method: title resolution, expectation check, body canonicalization, the
/// version/provenance write, and link replacement happen in ONE transaction on
/// `GRDBWikiStore` — one `ResourceChangeEvent` on a changed commit, none on
/// rollback. Chunk embeddings stay OUTSIDE that transaction (derived,
/// nonfatal; the background backfill covers a failure).
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
    /// Legacy entry point preserved for existing callers: `expectedHeadVersionID`
    /// maps onto ``PageWriteExpectation`` (`nil` → `.unrestricted`, a value →
    /// `.expectedHead`). New callers (notably `wikictl --create-only`) pass the
    /// expectation overload directly.
    @discardableResult
    public static func upsert(
        in store: WikiStore,
        id: PageID?,
        title: String,
        body: String,
        expectedHeadVersionID: PageVersionID? = nil,
        author: String? = nil,
        provenance: [PageVersionSourceInput] = []
    ) throws -> Outcome {
        let expectation: PageWriteExpectation = expectedHeadVersionID.map(PageWriteExpectation.expectedHead) ?? .unrestricted
        return try upsert(
            in: store, id: id, title: title, body: body,
            expectation: expectation, author: author, provenance: provenance)
    }

    /// Create-or-update a page under an explicit expected-state contract
    /// (unrestricted / expected head / expected absence), in ONE store
    /// transaction on `GRDBWikiStore`, then derive chunk embeddings outside it.
    ///
    /// Resolution order, matching the doc's `wikictl page add` contract:
    /// 1. If `id` is given, update THAT page (an explicit-id update; the title
    ///    is rewritten too, mirroring the in-app rename+edit path).
    /// 2. Otherwise resolve `title` → an existing page id via the store's
    ///    title resolution (lowest ULID on a duplicate-title collision, the
    ///    same rule the link resolver uses) and update it.
    /// 3. If neither yields a page, create a new one and write its body.
    ///
    /// The expectation is checked against that resolution INSIDE the same
    /// transaction: `.expectedAbsence` conflicts if the title resolved,
    /// `.expectedHead` conflicts if the resolved page's head moved — or if
    /// the expected target no longer exists at all (deleted/renamed since
    /// the read).
    ///
    /// After the content write, the canonical body's links are parsed (pure)
    /// and the outgoing link rows replaced — inside the same transaction on
    /// `GRDBWikiStore`, so a link failure rolls back the content write. A
    /// *rename* still does not re-walk the whole graph (the v0 limitation):
    /// links that targeted the old title self-heal on the linking page's next
    /// upsert.
    @discardableResult
    public static func upsert(
        in store: WikiStore,
        id: PageID?,
        title: String,
        body: String,
        expectation: PageWriteExpectation,
        author: String? = nil,
        provenance: [PageVersionSourceInput] = []
    ) throws -> Outcome {
        let outcome = try store.upsertPage(
            id: id, title: title, rawBody: body, expectation: expectation,
            author: author, provenance: provenance)
        // Compute + store chunk embeddings for the page body — AFTER the
        // composed write, never inside its transaction (plan phase 4 §9:
        // derived work stays outside). Non-fatal: a failure (or the model
        // being unavailable, e.g. under `wikictl`) never breaks the save —
        // the background backfill embeds it later.
        let text = body.isEmpty ? title : "\(title)\n\n\(body)"
        let chunks = EmbeddingService.chunkedEmbeddings(for: text)
        if !chunks.isEmpty {
            DebugLog.trying("upsert store chunks", operation: { try store.storePageChunks(id: outcome.id, chunks: chunks) })
        }
        return outcome
    }

    /// The store-sequential fallback for ``WikiStore/upsertPage(id:title:rawBody:expectation:author:provenance:)``
    /// used by non-GRDB conformers (test doubles). NOT atomic — each step is
    /// its own store call — and kept here (not in the protocol extension) so
    /// the resolution/canonicalization rules stay next to the composed
    /// method's contract. Atomicity is tested against `GRDBWikiStore`, never
    /// against this path.
    static func upsertSequential(
        in store: WikiStore,
        id: PageID?,
        title: String,
        rawBody: String,
        expectation: PageWriteExpectation,
        author: String?,
        provenance: [PageVersionSourceInput]
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
            in: rawBody, resolvePage: store.resolveTitleToID,
            resolveSource: store.resolveSourceByName,
            resolveChat: { title in
                try store.resolveChatByTitle(title)
            })) ?? rawBody
        let outcome = try writePage(
            in: store, id: id, title: title, body: canonicalBody,
            expectation: expectation, author: author,
            provenance: provenance)
        // Parse the CANONICAL body so link rows match the stored bytes exactly.
        try store.replaceLinks(from: outcome.id, parsedLinks: WikiLinkParser.parse(canonicalBody))
        return outcome
    }

    /// Persist the page row (create or update) WITHOUT touching links, returning
    /// the resolved id + create/update flag. Split out so the link reparse in
    /// `upsert` reads as one statement.
    private static func writePage(
        in store: WikiStore,
        id: PageID?,
        title: String,
        body: String,
        expectation: PageWriteExpectation,
        author: String? = nil,
        provenance: [PageVersionSourceInput]
    ) throws -> Outcome {
        // An expectation of absence with an explicit id is contradictory — the
        // id IS a target. GRDB rejects this inside its composed method; the
        // sequential path rejects it here so both seams fail the same way.
        if case .expectedAbsence = expectation, let id {
            throw WikiStoreError.unexpected(
                "create-only write (expectedAbsence) cannot target an explicit page id: \(id.rawValue)")
        }
        if let id {
            // When CAS is active, route through appendPageVersion (versioned
            // save with conflict detection). Otherwise blind write (the
            // backward-compatible path — wikictl, legacy callers). An
            // expected-head write whose page is GONE is an expected-state
            // conflict (deleted since the read) — never a notFound cascade
            // and never a silent create, matching the composed seam.
            switch expectation {
            case .expectedHead(let expected):
                do {
                    _ = try store.getPage(id: id)
                } catch WikiStoreError.notFound {
                    throw PageExpectedTargetMissingError(
                        pageID: id, expectedHead: expected, title: title)
                }
                _ = try store.appendPageVersion(
                    pageID: id, title: title, body: body,
                    expectedHeadVersionID: expected, lastEditedBy: author, provenance: provenance)
            case .unrestricted:
                try store.updatePage(id: id, title: title, body: body, lastEditedBy: author, provenance: provenance)
            case .expectedAbsence:
                break // unreachable — rejected above
            }
            return Outcome(id: id, didCreate: false)
        }
        if let existing = try store.resolveTitleToID(title) {
            switch expectation {
            case .expectedAbsence:
                // The create-only race lost: a page appeared under this title
                // since the caller's missing-page read. Report the conflict
                // with the existing page's current head so the caller can
                // re-read and reconcile; write nothing.
                let head = try store.pageHeadVersionID(pageID: existing)
                throw PageCreateConflictError(pageID: existing, title: title, actualVersionID: head)
            case .expectedHead(let expected):
                _ = try store.appendPageVersion(
                    pageID: existing, title: title, body: body,
                    expectedHeadVersionID: expected, lastEditedBy: author, provenance: provenance)
            case .unrestricted:
                try store.updatePage(id: existing, title: title, body: body, lastEditedBy: author, provenance: provenance)
            }
            return Outcome(id: existing, didCreate: false)
        }
        if case .expectedHead(let expected) = expectation {
            // The title the caller read no longer resolves to ANY page —
            // deleted or renamed away since the read. Conflict, never a
            // silent create; only `.unrestricted` keeps the legacy
            // create-if-missing behavior.
            throw PageExpectedTargetMissingError(
                pageID: nil, expectedHead: expected, title: title)
        }
        // A new upsert creates its first immutable version atomically. Its
        // source inputs belong on that content-bearing root, not on a second
        // follow-up version after an empty placeholder root.
        let page = try store.createPage(
            title: title, body: body, createdBy: author, provenance: provenance)
        return Outcome(id: page.id, didCreate: true)
    }
}

# Phase 6 — Version pinning (`@vN`)

> Design authority: [`plans/graph-model-and-versioning.md`](../graph-model-and-versioning.md)
> §4.4 (edges — roles and pins), §6 (ULID-canonical links → pinning composes with `@vN`),
> §3 (the bug: "reprocessing a source silently kills existing highlights"), §12 Phase 6 gate.
> Successor to Phase 5 (`plans/phase-5-link-canonicalization.md`, v23, shipped — 1617 tests green).

## Goal

Let a wiki link pin a specific derived-markdown version so that a **quote highlight
survives re-extraction**. The Phase 12 gate is literal:
`[[source:X@v3#"quote"]]` highlights after X is reprocessed. Today quotes match the HEAD
extraction, which moves on every re-extract — so the highlight silently dies. Pinning the
version the quote was written against fixes that.

**Scope chosen by the operator (this chunk): quote-focused, minimal render surface.**
`@vN` resolves and is stored for any pinned source link, but the *pinned-extraction viewer*
engages **only for pinned quote links** (extracted/markdown sources). Non-quote pins store
the id (graph index correct) but open HEAD. Byte-embed / content-version pinning (§7) and
PDF-only-source quote pinning are deferred to a later phase.

## Implementation Summary

`@vN` is an **ordinal into the derived-markdown chain** (`source_markdown_versions`),
1-based, oldest (lowest ULID) = `v1`. It is human-writable and **stays in the body** —
`[[source:01J…@v3#"quote"|Name]]`. At save time the ordinal is resolved to an smv id and
landed in `source_links.pinned_version_id` (the graph index). At render time the page reader
re-resolves the body's `@vN` to an smv id (the body is the per-occurrence source of truth —
two quote links pinning the same version are one edge but two body occurrences, §6) and emits
it in the click URL; the destination source view loads *that* version's content so the quote
is present in the rendered DOM and the existing highlighter finds it.

**No schema change.** `pinned_version_id TEXT` already exists on `source_links` (shipped v22)
and is never written or read today. **No `user_version` bump, no migration, no body sweep**
(the feature is new — there are no existing `@vN` bodies to rewrite). **No changeToken change**
(`source_links` is not in the 11-field fold; pins only mutate via page save, which already
moves the token through the page `version` sum). Phase 6 is **code-only**.

### Touch points

- `Sources/WikiFSCore/WikiLinkParser.swift` — `ParsedLink.versionPin` (new, defaulted nil);
  `splitVersionPin` helper; pin-aware `classify`/`isCanonicalULID` ordering; dedup key.
- `Sources/WikiFSCore/WikiLinkRewriter.swift` — `canonicalize` becomes pin-aware (split before
  the ULID fast-path, reattach in the canonical target). Preserves `@vN` verbatim.
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — `replaceLinks` writes `pinned_version_id`
  (resolved ordinal→id) for both cite and embed source inserts; new
  `derivedVersionIDs(sourceID:)` (ULID-asc) resolver, `processedMarkdownVersion(id:)` reader,
  and `sourceDerivedChains() -> [PageID: [PageID]]` (one bulk ULID-asc query for the render
  precompute).
- `Sources/WikiFSCore/WikiStore.swift` / `WikiStoreModel.swift` — protocol + wrapper for
  `processedMarkdownVersion(id:)` and `sourceDerivedChains()`; `selectSource(byID:anchor:
  pinnedExtractionID:)` + a parallel `pendingPinnedExtraction` producer/consumer (mirrors
  `pendingScrollAnchor`).
- `Sources/WikiFSCore/WikiLinkMarkdown.swift` — `linkified` resolves `@vN`→id and emits
  `&pin=<id>` **only alongside a fragment** (quote); a `pinnedExtractionID` closure joins the
  existing `displayName`/`embedInfo` precompute closures.
- `Sources/WikiFS/SourceDetailView.swift` — when a pending pinned extraction (always with a
  quote) is consumed for the current source, load that smv and feed its `.content` to
  `WikiReaderView` instead of `headVersion?.content`; clear on navigation away.
- `Sources/WikiFS/WikiReaderView.swift` — build the `sourceID → [smvID]` (ULID-asc) precompute
  map and expose `pinnedExtractionID` to `linkified`. The highlight path (`highlightJS`,
  Coordinator anchor consume) is unchanged — it just runs against the pinned DOM.

### Non-goals (deferred)

- §7 content-version pinning for byte embeds (`![[source:X@v3]]` showing pinned image/video
  bytes via `wiki-blob://`).
- PDF-only-source (un-extracted) pinned quotes (`PDFViewWrapper.highlightQuote` searches the
  content bytes — a content-version pin).
- Forward-link pins (unresolved targets still vanish from the graph; open question #2).
- A "viewing pinned version v3 — show latest" banner/affordance (the pinned view is transient
  and clears on navigation; the existing Extractions menu already reaches every version).

## Implementation Plan

### Phase 6.1 — Parse `@vN` (pure)

`WikiLinkParser`:

1. Add `splitVersionPin(_ base: String) -> (bare: String, pin: String?)` — strips a trailing
   `@v<one-or-more digits>` from the base. Regex `^(.*?)@v(\d+)$` (case-insensitive `v`).
   No-pin → `(base, nil)`. Invalid forms (`@v`, `@x3`, `@v3x`, `@@v3`) → no match, left literal.
   (A title that literally ends in `@v3` is ambiguous and treated as a pin — documented,
   acceptable; rare.)
2. `ParsedLink` gains `public let versionPin: String?` (the digits only, e.g. `"3"`),
   defaulted `nil` so every existing call site compiles and equality holds.
3. In `parse()` (L139+): after `splitFragment` (L159) yields `(base, fragment)`, run
   `splitVersionPin(base)` → `(bareBase, pin)`; classify `bareBase`; store `versionPin: pin`.
   The bare target used for ULID/name resolution is now pin-free.
4. Dedup key (L182) becomes `"\(kind):\(raw):\(isEmbed ? "embed" : "cite"):\(pin ?? "")"` so
   `[[source:X@v3]]` and `[[source:X@v5]]` are distinct occurrences (matches `source_links_edge`
   pin-distinct semantics, §4.4).

### Phase 6.2 — Canonicalize preserves `@vN` (pure)

`WikiLinkRewriter.canonicalize` (L31-101):

1. After `splitFragment` (L55), run `splitVersionPin(base)` → `(bareBase, pin)`. Operate on
   `bareBase` for `classify`/`isEmptyPrefix`/resolution.
2. **ULID fast-path (L62):** test `isCanonicalULID(bareBase)`, not the pinned base — else
   `ULID@v3` (29 chars) fails the check and the link is mis-classified as an unresolved name.
3. Canonical target reassembly (L79-96): reattach `@v<digits>` and `#fragment`:
   `prefix + resolvedID + (pin.map { "@v\($0)" } ?? "") + (fragment.map { "#\($0)" } ?? "")`.
   The ordinal is **not** resolved here — it is preserved as written. Idempotent (a second
   canonicalize pass sees `bareBase` = ULID, hits the fast-path, leaves it).
4. Out-of-range / unresolvable base: unchanged forward-link behavior (byte-identical), pin and
   all.

### Phase 6.3 — Resolve + write the pin (store)

`SQLiteWikiStore`:

1. `private func derivedVersionIDs(sourceID: PageID) throws -> [PageID]` —
   `SELECT id FROM source_markdown_versions WHERE file_id = ?1 ORDER BY id ASC;` decoded to
   `[PageID]`. ULID-asc = chronological; index 0 = `v1`.
2. `public func processedMarkdownVersion(id: PageID) throws -> SourceMarkdownVersion?` — single
   resolved row (`smvSelectColumns` + `smvBlobJoin` + `WHERE smv.id = ?1`), decoded by
   `sourceMarkdownVersion(from:)`. Add to `WikiStore` protocol + `WikiStoreModel` wrapper
   (`processedMarkdownVersion(for id:)`).
3. `replaceLinks` (L1988-2063): extend `insSource` and `insSourceEmbed` to write
   `pinned_version_id` (add the column to both INSERTs). For each resolved source link carrying
   a `versionPin`, resolve the ordinal: `let ids = try derivedVersionIDs(sourceID: resolved);
   let pinID = (Int(pin).map { $0 - 1 }).flatMap { idx in idx < ids.count ? ids[idx] : nil }`.
   Bind `pinID?.rawValue` (NULL when out of range → follows the active ref). The
   `source_links_edge` unique index already makes the pin part of edge identity, so cite/embed
   and distinct pins coexist as distinct rows. This keeps `replaceLinks` the sole writer of
   `source_links.pinned_version_id`, preserving the single-writer integrity story for the
   un-FK'd polymorphic column (cf. the §4.3 `refs.version_id` precedent; §4.4 declares
   `pinned_version_id` un-FK'd precisely so it can later hold `source_versions` ids for §7
   content-version pins — which is why the plan does NOT add an FK).

### Phase 6.4 — Render linkification (page reader)

`WikiReaderView` precompute (main-actor, same pass that builds `pageIDToName`/
`sourceIDToName`/`embedInfo`):

1. Build `sourceDerivedChain: [PageID: [PageID]]` via the new model accessor
   `store.sourceDerivedChains()` (backed by one store query
   `SELECT file_id, id FROM source_markdown_versions ORDER BY file_id, id ASC`, served over
   the read pool / @MainActor model — `WikiReaderView` issues no raw SQL). ULID-asc per source.
2. Expose `pinnedExtractionID: (PageID, Int) -> PageID?` to `linkified` (source id + ordinal →
   smv id, 1-based; out-of-range → nil).

`WikiLinkMarkdown.linkified` (L144-168 canonical-ULID branch):

3. Split the pin from `bareTarget` (`splitVersionPin`). For a **pinned source link WITH a
   fragment (quote)**, resolve `pinnedExtractionID(id, Int(pin)!)`; if non-nil, append
   `&pin=<smvID>` to the emitted `wiki://source?id=…` URL (quote URL-encoded as the fragment,
   as today). **No `&pin=` when there is no fragment** — non-quote pinned links linkify to the
   plain `?id=` URL and open HEAD (the chosen scope).
4. `WikiLinkMarkdown.id(from:)` is extended to also recover `pin=` (or a dedicated parser) so
   the click router reads both `id` and `pin`.

### Phase 6.5 — Click routing + pinned-extraction viewer (UI plumbing)

`WikiStoreModel`:

1. `selectSource(byID id:anchor:openInNewTab:pinnedExtractionID:)` — new defaulted param. When
   non-nil, set a parallel `pendingPinnedExtraction: (selection: WikiSelection, versionID: PageID)?`
   and bump `pendingScrollAnchorVersion` (same counter — the pin travels with its anchor).
2. `consumePendingPinnedExtraction(for selection:) -> PageID?` mirrors
   `consumePendingScrollAnchor` (set-once/consume-once, tagged by selection).
3. `WikiReaderView` link-click handler (L~131) reads `pin=` and forwards it to
   `selectSource(byID:anchor:pinnedExtractionID:)`.

`SourceDetailView`:

4. `@State pinnedExtraction: SourceMarkdownVersion?`. In the `.task(id: file.id)` / `.onAppear`
   head-load (L160/L186) and on a `pendingScrollAnchorVersion` change, consume the pending pin
   for `store.selection`: if present, `pinnedExtraction = store.processedMarkdownVersion(for:
   id)`. **Consume synchronously before the view body first evaluates** so the pinned DOM is
   what the Coordinator's highlight pass runs against (the Coordinator keys off
   `pendingScrollAnchorVersion`, so a pin set after first paint would miss the highlight).
   Clear `pinnedExtraction = nil` in the `onChange(of: file.id)` reset block (L164-184), next to
   `headVersion = nil` — navigating away/back returns to HEAD.
5. Render site (L592-600): inside the existing `else if let head = headVersion` branch, swap to
   `WikiReaderView(markdown: pinnedExtraction?.content ?? head.content, …)`. A pinned quote link
   always targets an extracted source (else no v3 exists to pin), so `headVersion` is non-nil
   whenever `pinnedExtraction` is set — reaching this branch is guaranteed. The pending
   quote/anchor then flows through `WikiReaderView`'s existing Coordinator (L946-948) and
   `highlightJS` (L1117) highlights against the **pinned** DOM.

> **Producer/consumer contract (testable on the @MainActor model, no WKWebView).** The
> `selectSource(byID:anchor:pinnedExtractionID:)` → `pendingPinnedExtraction` →
> `consumePendingPinnedExtraction(for:)` flow is pure model state, so it gets a unit test (not
> just the manual AC.7). Contract: setting a pin tags it to the destination `WikiSelection` and
> bumps `pendingScrollAnchorVersion`; `consumePendingPinnedExtraction(for:)` returns the id once
> for a matching selection and `nil` thereafter / for a mismatched selection; a `nil` pin is a
> no-op (no pending state set). Mirrors the `pendingScrollAnchor` set-once/consume-once
> discipline — and unlike that field (which has no model-level test today), this one is covered.

> Why this meets the gate: the quote lives in v3's extraction. Reprocessing appends a newer
> extraction (HEAD moves), but `pinned_version_id` / the body's `@v3` still point at v3, so the
> destination renders v3 — where the quote is present — and the highlighter finds it.

### Phase 6.6 — Docs

- `prompts/system-prompt-default.md`: a short "Version pins" note — authoring stays
  `[[source:Name@v3#"quote"]]`; `@vN` pins the Nth extraction (oldest = v1) so a quote survives
  re-extraction. Run `make prompts` → regenerate `GeneratedPrompts.swift` (CI `check-prompts`
  fails on drift).
- `plans/graph-model-and-versioning.md` §12 Phase 6 row: footnote "implemented".
- `PLAN.md` status + doc-index row; `PROGRESS.md` entry.

## Acceptance Criteria

- **AC.1 — `@vN` parses.** `WikiLinkParser.splitVersionPin` strips a trailing `@v<digits>`;
  `ParsedLink.versionPin` is populated for `[[source:X@v3]]`, `[[source:X@v3#"q"]]`, and
  `![[source:X@v3]]`; invalid forms (`@v`, `@x3`) yield `nil` and stay literal; the dedup key
  treats `@v3` and `@v5` as distinct. *→ `WikiLinkParserTests`.*
- **AC.2 — canonicalize preserves `@vN`.** A `[[source:ULID@v3#"q"|Name]]` body is idempotent
  (second pass unchanged); a name-form `[[source:Video@v3#"q"]]` canonicalizes to
  `[[source:<ULID>@v3#"q"|Video]]`; the `#fragment` and `|alias` survive; an out-of-range
  ordinal is preserved as-written. *→ `WikiLinkCanonicalizerTests` (extend the Phase-5
  canonicalize suite).*
- **AC.3 — `replaceLinks` writes the pin.** A source link with `@v3` over a ≥3-version chain
  writes `pinned_version_id = <v3 smv id>`; an out-of-range `@v9` writes NULL (follows active
  ref); cite+embed+distinct pins to one source coexist as distinct `source_links` rows. *→
  `SQLiteWikiStoreTests`.*
- **AC.4 — ordinal is chronological.** Over a 3-version chain, `@v1` resolves to the
  lowest-ULID (oldest) smv and `@v3` to the newest; resolution is stable across an appended
  4th version (v1–v3 ids unchanged). *→ `SQLiteWikiStoreTests`.*
- **AC.5 — linkify emits the pin for quote links only.** `linkified` emits
  `wiki://source?id=<ULID>&pin=<smvID>…#<encoded quote>` for a pinned **quote** link; a pinned
  link **without** a quote emits the plain `wiki://source?id=<ULID>` (no `&pin=`). *→
  `WikiLinkMarkdownTests` (or the existing linkified test home).*
- **AC.6 — pinned-version reader.** `processedMarkdownVersion(id:)` returns the correct
  `SourceMarkdownVersion` (resolved blob body) for a given smv id; `nil` for an unknown id. *→
  `SQLiteWikiStoreTests` / `ProcessedMarkdownTests`.*
- **AC.7 — pin producer/consumer (model plumbing).** `selectSource(byID:anchor:pinnedExtractionID:)`
  with a non-nil pin sets `pendingPinnedExtraction` tagged to the destination `WikiSelection`
  and bumps `pendingScrollAnchorVersion`; `consumePendingPinnedExtraction(for:)` returns the id
  once for a matching selection and `nil` thereafter / for a mismatched selection; a `nil` pin
  is a no-op (no pending state set). This is pure @MainActor model state — testable without a
  WKWebView. *→ the `WikiStoreModel*Tests` family (new `WikiStoreModelPinTests`, or extend an
  existing one).*
- **AC.8 — quote survives reprocess (the gate; manual live check).** In the running app: a page
  with `[[source:X@v3#"some quote"]]`; re-extract X (append a newer extraction); click the link
  → source opens showing v3's content with the quote highlighted. **Precondition asserted in
  CI:** the store resolves the pin to v3's id (AC.3), v3's content contains the quote text
  (AC.6), and the model hands the pinned id to the destination (AC.7). *→ manual; CI
  precondition covered by AC.3+AC.6+AC.7.*
- **AC.9 — regression.** Full suite green; pin defaults to `nil` everywhere so existing parser /
  canonicalize / `replaceLinks` / linkify behavior is byte-identical for non-pinned links. *→
  `swift test` (1617 baseline + new).*
- **AC.10 — no schema/token drift.** `user_version` unchanged; the 11-field `changeToken()`
  literal in `SQLiteWikiStoreTests`/`LogIndexTests`/`SystemPromptTests` is unchanged;
  `freshFastPathMatchesStepwiseLadder` green. *→ `swift test`.*

## Test Strategy

| AC | Test | Layer |
|----|------|-------|
| AC.1 | `WikiLinkParserTests` — `splitVersionPin`, `versionPin`, pin-distinct dedup, invalid forms | unit (pure) |
| AC.2 | `WikiLinkCanonicalizerTests` — idempotent ULID pin, name→ULID pin, fragment/alias survival, out-of-range preserved | unit (pure) |
| AC.3 | `SQLiteWikiStoreTests` — `replaceLinks` writes resolved/NULL pin; cite+embed+pin coexistence | integration (store) |
| AC.4 | `SQLiteWikiStoreTests` — ordinal→id over multi-version chain; stable under append | integration (store) |
| AC.5 | `WikiLinkMarkdownTests` — `&pin=` emitted for quote links, omitted for non-quote pins | unit (pure) |
| AC.6 | `ProcessedMarkdownTests` / `SQLiteWikiStoreTests` — `processedMarkdownVersion(id:)` | integration (store) |
| AC.7 | `WikiStoreModel*Tests` (new `WikiStoreModelPinTests`) — pin producer/consumer: tagged set, consume-once, mismatch→nil, nil-pin no-op | unit (@MainActor model) |
| AC.8 | **manual live** (WKWebView paint) + CI precondition (AC.3+AC.6+AC.7: pinned content loaded & contains quote & handed to destination) | manual + integration |
| AC.9 | full `swift test` suite | regression |
| AC.10 | `FreshSchemaParityTests` + changeToken literal suites | regression |

**Test infrastructure: present, no new harness needed.** The project uses Swift Testing
(preferred; see `docs/skills/swift-testing-pro/SKILL.md`). All of AC.1–AC.6, AC.8, AC.9 are
automatable with the existing store/parser/rewriter/markdown test patterns.

**Manual-only gap (AC.8):** the WKWebView quote-highlight *paint* cannot be asserted in a
headless unit test — the highlight is a JS DOM mutation (`highlightJS`, `WikiReaderView.swift:1117`).
This is the same limitation as Phase 4a's AC.6 (live WKWebView paint, manual-only). The CI
preconditions are now asserted at every non-paint layer: storage/resolution (AC.3), the pinned
reader (AC.6), *and* the model plumbing that hands the pinned id to the destination (AC.7) — so
a regression in resolution, storage, or the producer/consumer fails CI; only a regression in the
JS highlight itself would slip to manual. Flagged in Risks.

## Review Strategy

- **Plan-mode:** run the `plan-reviewer` subagent on this plan before `handoff_plan`; fix or
  rebut all critical/high findings, re-review until clean.
- **Implementation:** after `swift test` is green, dispatch a `general-purpose` subagent to
  review the diff against §4.4/§6 and the `swiftui-pro` / `swift-concurrency-pro` skills
  (the pin threads through `@MainActor` model state + a detached convert task — confirm no
  connection state crosses the boundary, per the sqlite-concurrency invariant). Fix or rebut
  all findings; re-review on critical findings.

## Documentation Strategy

- Agent-facing: `prompts/system-prompt-default.md` "Version pins" note + `make prompts`
  regen (CI `check-prompts` gate).
- Design of record: `graph-model-and-versioning.md` §12 Phase 6 footnote; new
  `plans/phase-6-pinning.md` (this doc) indexed in `PLAN.md`; `PROGRESS.md` entry.
- No user-facing docs surface beyond the app (the feature is transparent: authoring is
  unchanged; the pin is a `@vN` an agent or user may write).

## Risks, Blockers, and Required Decisions

- **`@vN` vs a title literally ending in `@v3`.** Ambiguous; treated as a pin. Rare; documented.
  No decision needed (acceptable), but noted.
- **AC.8 highlight paint is manual-only.** CI asserts the preconditions (pinned content loaded,
  contains quote, and the id handed to the destination — AC.3+AC.6+AC.7), not the JS highlight
  itself. Consistent with the Phase 4a precedent. If a future regression hides in the JS, it
  won't fail CI — mitigated by keeping `highlightJS` untouched (Phase 6 only changes *which
  content* is rendered, not the highlighter).
- **Ordinal stability under delete.** Append-only keeps `v1..vN` stable; a *delete* (source
  delete cascades the whole chain anyway) is the only shift. No per-version delete exists
  today. Acceptable; noted.
- **Scope boundary (intentional).** A pinned cite link *without* a quote opens HEAD (per the
  operator's chosen scope), so `[[source:X@v3|Name]]` and `[[source:X@v3#"q"]]` behave
  differently at click time. Both write the pin to the graph index. The inconsistency is
  deliberate minimalism; full edge pinning (§4.4/§7) is the fast-follow. Recorded so a future
  agent doesn't "fix" it as a bug.
- **PDF-only-source pinned quotes are out of scope** (content-version pin, deferred with §7).
  Pinned quotes on *extracted* sources (incl. PDFs-with-extraction, rendered via
  `WikiReaderView`) are in scope.

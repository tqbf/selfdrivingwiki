# Phase 5 — Link canonicalization (ULID-canonical link targets)

**Status: shipped (v23, 2026-07-06).** Design of record: `graph-model-and-
versioning.md` §6, §9 step 6, §12 Phase 5. This doc is the shipped companion.

## What shipped

Wiki-link targets are **ULID-canonical at rest** while authoring stays
human-friendly:

- **Authoring is unchanged.** Agents and users keep writing `[[Some Title]]` /
  `[[source:Display Name]]`. Nothing about `wikictl` prompts or human habits
  changed.
- **Save-time normalization.** `WikiLinkRewriter.canonicalize` (new, in
  `WikiLinkRewriter.swift`) rewrites each resolvable `[[…]]` span to
  `[[page:<ULID>|alias]]` / `[[source:<ULID>|alias]]`, preserving the `|alias`,
  the `#fragment`, and the `!` embed prefix; code-fence-safe; idempotent. It
  runs in the one shared write seam, `PageUpsert.upsert`, so both the app model
  and `wikictl` canonicalize identically. Unresolved (forward) links are left
  byte-identical.
- **Render-time display-at-render.** `WikiLinkMarkdown.linkified` resolves a
  canonical ULID → the *current* title/name (a new `displayName` closure), so a
  stale alias self-heals visually without touching any bytes.
- **`?id=` URL contract + id-based routing.** Canonical links emit
  `wiki://page?id=<ULID>&title=…`; click routing resolves by id (a direct row
  fetch) with `title=` retained as a transition fallback.
- **`replaceLinks` validate-by-id.** Canonical targets validate by id first
  (`getPage(id:)` / `getSource(id:)`), with a name-resolution fallback so a
  ULID-shaped title never silently loses its edge.
- **One-time body migration (v23).** A guarded, idempotent data-only sweep
  rewrites every page body. `user_version=23` is a run-once guard (the v18
  name-sanitization precedent — no schema change). The change token advances and
  every touched page's `version`+`updated_at` bump so the File Provider re-syncs.
- **Rename collapse.** `renameSource`'s body-rewrite loop is deleted; rename is
  now a one-row metadata update (stored aliases self-heal at render).
  `WikiLinkRewriter.rewriteSourceBase` and its 28-test suite were removed (the
  "no second drifting implementation" convention).

## Phase gate (§12)

*Rename a page with 50 inbound links: zero bodies rewritten, zero ghosts.* — met.
Verified by `Phase5StoreCanonicalizationTests.pageRenameSelfHealsAtRenderWithNoBodyRewrite`
(50 inbound links, render shows the new title, every linking page's
`version`+`updated_at` unchanged).

## Acceptance criteria → tests

| AC | Test |
|----|------|
| AC.1 save canonicalizes (app + CLI seam) | `Phase5StoreCanonicalizationTests.upsertCanonicalizesPageAndSourceLinks` |
| AC.2 alias/fragment/embed/code-fence preservation | `WikiLinkCanonicalizerTests` (preservesExistingAlias, preservesQuoteFragment, preservesEmbedPrefix, leavesCodeFenceUntouched) |
| AC.3 forward link stored verbatim | `Phase5StoreCanonicalizationTests.unresolvedForwardLinkStoredVerbatim` |
| AC.4 idempotency | `WikiLinkCanonicalizerTests.canonicalizingAlreadyCanonicalIsNoOp` |
| AC.5 display-at-render self-heals stale alias | `WikiLinkMarkdownCanonicalTests.canonicalPageLinkShowsCurrentName` |
| AC.6 rename self-heals at render (gate) | `Phase5StoreCanonicalizationTests.pageRenameSelfHealsAtRenderWithNoBodyRewrite` |
| AC.7 `?id=` URL contract + routing | `WikiLinkMarkdownCanonicalTests.canonicalPageLinkEmitsIdQuery` + `WikiReaderRoutingTests` (canonical*CarriesId) |
| AC.8 v23 migration moves token | `Phase5StoreCanonicalizationTests.migrateV22ToV23CanonicalizesBodiesAndAdvancesToken` + idempotent |
| AC.9 renameSource no body rewrite | `Phase5StoreCanonicalizationTests.sourceRenameSelfHealsAtRenderNoBodyRewrite` |
| (5.1.4) ULID-shaped title collision fallback | `Phase5StoreCanonicalizationTests.ulidShapedTitleResolvesByNameFallback` |

## Non-goals (deferred)

- `@vN` version pinning → Phase 6 (depends on this phase). The normalizer
  preserves `@`/`#` text verbatim so Phase 6 composes.
- Editor pretty-display over `[[page:ULID|Title]]` → open question #3.
- `pending_links` table for forward/unresolved links → open question #2.
- `wikictl page canonicalize --dry-run` CLI verb → deferred (the migration is
  guarded on `user_version < 23`; the in-process idempotency test is the safety
  mechanism).

## Manual-only (no automated harness)

Live WKWebView paint of a canonical link resolving to the current title, and a
clicked `?id=` link navigating to the right tab. The pure `linkified` + routing
tests cover the logic; this mirrors Phase 4a's manual-only AC.6.

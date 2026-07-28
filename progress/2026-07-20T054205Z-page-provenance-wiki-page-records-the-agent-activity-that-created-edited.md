---
timestamp: 2026-07-20T054205Z
title: "2026-07-19 — Page provenance: wiki page records the agent + activity that created/edited it (branch `page-provenance`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Page provenance: wiki page records the agent + activity that created/edited it (branch `page-provenance`)

## Progress


**Problem.** Each wiki page recorded only a flat `last_edited_by` TEXT string
(#131/#397) — the `chat:<id>` / `agent:<kind>` / `user` / model-id of the
last writer. On the CAS path only it also appended a `page_versions` row
whose `activity_id` pointed at a **shared anonymous `legacy-import` agent**,
and the CAS-off path (`wikictl` default, no `--expect-head`) recorded NO
history at all. There was no read-side accessor for the PROV graph and no
UI surface. The plan (`plans/page-provenance.md`) is the design doc; this
entry is the Phase A + B implementation.

**Approach.** Reuse the existing PROV-DM substrate (`agents` +
`activities` + `page_versions`, the same graph sources use) — NOT a new
table. The fix is the writer swap (`legacyImportAgentID →
ensurePageAuthorAgent`) + the CAS-off path routing through a shared
`appendPageVersionLocked(on db:)` helper + two new read accessors.

### `Sources/WikiFSCore/Core/PageOrigin.swift` (NEW)

- `PageOrigin` struct — `versionID` / `title` / `blobHash` / `agentName` /
  `agentKind` / `activityKind` / `plan` / `externalRef` / `savedAt`. The
  read-side mirror of `SourceOrigin` for sources (Phase 3a).

### `Sources/WikiFSCore/Store/WikiStore.swift` (protocol surface)

- Two new protocol requirements (NO default-impl extension — mirrors
  `sourceOrigin` and `pageVersionHistory`):
  - `pageOrigin(pageID:) throws -> PageOrigin?` — joins
    `refs → page_versions → activities → agents` for the HEAD.
  - `pageEditHistory(pageID:) throws -> [PageOrigin]` — full version chain
    joined to activity + agent, oldest-first.
- `GRDBWikiStore` is the sole conformer (single site) — no test mock
  breaks.

### `Sources/WikiFSCore/Store/GRDBWikiStore.swift` (the writer swap)

- **Schema bumped v38 → v39.** New explicit `if version < 39 … PRAGMA
  user_version = 39 …` step inserted BEFORE the catch-all fallback at the
  end of `migrate(from:in:)` — the fallback's guard is keyed on
  `currentSchemaVersion` and short-circuits past any new step once that
  constant is bumped. Forward-only: no backfill — pre-v39 rows degrade to
  `legacy-import` agent (same as today).
- **Authored `authorKind(_:)`** (NEW, not in the prior art) — `chat:…` →
  `"chat"`, `agent:…` → `"agent"`, `"user"` → `"human"`, anything else →
  `"model"`, `nil`/empty → `"software"` (the legacy-import kind).
- **`ensurePageAuthorAgent(_:on:)`** — the writer-side swap. Get-or-creates
  a REAL named agent on `(name, kind)` via `ensureAgent` when the author
  string carries a chat/agent/user/model identity; falls back to
  `legacyImportAgentID` when nil/empty (degraded, no data loss).
- **`createPage` + `appendPageVersion` + `updatePage`** all route their
  activity's agent through `ensurePageAuthorAgent` instead of
  `legacyImportAgentID`. Single edit site (`ensurePageAuthorAgent`).
- **Extracted `appendPageVersionLocked(on db:)`** (NEW private helper — the
  HIGH-hazard fix). Holds the body shared by `appendPageVersion` (CAS path)
  + `updatePage` (CAS-off path). NOT a `mutate` wrapper — does NOT emit;
  the public callers wrap their own `mutate` body and emit `.page .updated`
  ONCE there (Approach-A composition pattern per `mutate`'s doc; a public
  mutator that re-calls `mutate` would deadlock). `updatePage` deliberately
  calls this helper, NOT public `appendPageVersion` (would double-emit AND
  re-enter).
  - Includes a no-op guard: identical body hash + identical title =
    pure content no-op → skip the version-append (just bumps `updated_at`
    + `last_edited_by` on the mirror). The plan's risk-table mention of
    "`wikictl` re-write bloat" — this is the gate.
  - The `tryAmendPageVersion` autosave coalescer ALSO runs on the CAS-off
    path now (per §5.3 LOW note) — a rapid same-author save within the 5s
    window amends the head version in place instead of appending. AC.3
    uses a DISTINCT author to keep the amend short-circuit from
    suppressing the new version row.
- **`updatePage` existence check** — added `guard exists … else { throw
  WikiStoreError.notFound(id) }` at the start. The pre-refactor contract
  threw `.notFound` when the page was gone via `guard db.changesCount > 0
  else { throw notFound }` AFTER the UPDATE; the refactor INSERTs into
  `page_versions` before the UPDATE so the existence check moved first
  (otherwise a FK violation from `page_versions.page_id` would surface as
  a raw `DatabaseError`, breaking `StoreEmissionReentrancyTests
  .throwingMutationEmitsNothing`).

### `Sources/WikiFSCore/Store/WikiStoreModel.swift` (read accessors)

- `pageOrigin(for:)` / `pageEditHistory(for:)` — `try?` wrappers around
  the protocol methods. Used by `PageDetailView`.

### `Sources/WikiFS/Pages/PageDetailView.swift` (UI surface)

- New collapsible "Provenance" `DisclosureGroup` in the header expansion,
  between the date row and the action buttons. Defaults collapsed — the
  origin + edit-history reads are gated on expansion (per the plan's risk
  table — keep the provenance read out of the hot `body` re-render).
- `ProvenancePanel` (new view struct) renders the HEAD origin row + the
  edit history list. `chat:<id>` agents render with the chat bubble icon
  (the `chat:<id>` provenance value shape from #397); `agent:<kind>` with
  the cpu icon; `user` with the person icon; `legacy-import` with the tray
  icon (pre-v39 rows degrade distinctly).
- `@State provenanceOrigin` / `provenanceHistory` cleared on
  `store.selection` change (in-tab navigation), so a stale panel from the
  previous page doesn't flicker before the `.task(id:)` reloads. The `.task
  (id: ProvenanceTaskKey(pageID:expanded:))` fires both on selection change
  AND on expansion so the read only runs when there's something to show.

### `Sources/WikiCtlCore/PageCommand.swift` + `ArgumentParser.swift` (CLI surface)

- New `page info (--title X | --id Y)` subcommand — mirrors `source info`
  (Phase 3a). Prints identity (id/title/slug/created/updated/version_count)
  + HEAD origin (activity/agent/agent_kind/plan/external_ref/saved_at/
  blob_hash) + editable history (oldest-first; seq/activity/agent/
  agent_kind/date/title/version_id/blob_hash/parent).

### Tests

- NEW `Tests/WikiFSTests/PageVersionTests.swift` additions — 8 tests:
  - `pageOriginReflectsChatAuthorOnCreate` (AC.1) — `chat:<id>` create
    surfaces in `pageOrigin` as `agentName == chat:<id>`,
    `agentKind == "chat"`, `activityKind == "import"`.
  - `pageOriginReflectsAgentKindOnCreate` (AC.1 variant) — `agent:<kind>`.
  - `pageOriginDegradesToLegacyImportWhenNoAuthor` (AC.1 degraded) — nil
    author degrades to `legacy-import` / `"software"`.
  - `pageEditHistoryCountsCreateAndEdit` (AC.2) — exactly 2 entries on
    fresh create+edit (DISTINCT authors so the amend coalescer can't
    suppress the new row); entry[1] pinned to chat agent + edited body.
  - `updatePageCASOffAppendsVersionAndActivity` (AC.3) — row-count before/
    after the CAS-off update.
  - `pageEditActivityPointsAtRealNamedAgent` (AC.4) — HEAD activity's
    `agent_id` joins to `chat:<id>` agent row, NOT `legacy-import`.
  - `pageEditNilAuthorDegradesToLegacyImport` (AC.4 degraded).
  - `v39SchemaVersionAfterMigration` (AC.8) — schema version reports 39.
- EXTENDED `Tests/WikiFSTests/StoreEmissionTests.swift`:
  - `test_updatePage_after_versioning_refactor_emits_single_page_updated`
    (NEW, AC.6) — asserts EXACTLY ONE `.page .updated` event after
    `updatePage`, catching the double-emit regression from naive
    delegation to public `appendPageVersion`.
- NEW `Tests/WikiFSTests/StoreEmissionReentrancyTests.swift`:
  - `updatePageAfterVersioningRefactorEmitsOnceNoDeadlock` (AC.7) — mirrors
    `withTransactionMutationEmitsOnceNoDeadlock`; asserts single-emit +
    no deadlock now that `updatePage` composes via `appendPageVersionLocked`.
- NEW `Tests/WikiFSTests/WikiCtlCommandTests.swift` additions — 5 tests:
  - `pageInfoPrintsChatOrigin` — round-trip create-with-author → `page info`
    prints identity + HEAD origin.
  - `pageInfoAfterEditShowsEditOrigin` — post-edit HEAD reflects the chat
    agent + 'edit' activity.
  - `parsesPageInfoByID` / `parsesPageInfoByTitle` — argparser coverage.
  - `pageInfoOnMissingPageThrows`.

### Verification

- `make check` ✓ (compiles debug, 0 errors / 0 warnings)
- `make test` ✓ — **3120 tests / 263 suites pass** (~30 s; in-memory SQLite
  fixtures since #658). One earlier run had a flaky snapshot-test failure
  (unrelated); re-ran clean.

### Out of scope (deferred per §10 phasing)

- **Phase C** (optional): backfill historical `activity.agent_id` from
  `last_edited_by` behind a `wiki_metadata` flag (irreversible — guarded
  rollout). + thread `WIKI_RUN_REF` → `activities.external_ref` for
  structured run identity.
- **Phase D** (hygiene): build a real reflection-based
  `WikiStoreEmissionExhaustivenessTests` (the phantom test the loaded
  context references); delete the stale phantom references in
  `ChangeTokenContributorTests.swift:18` and `GRDBWikiStore.swift:2614`.

## Verification

Historical verification remains in the progress record above.

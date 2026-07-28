---
timestamp: 2026-07-22T024111Z
title: "#797 — Typed Page-Author Provenance (Phase 1)"
branch: null
status: historical
timestamp_source: git-commit
---

# #797 — Typed Page-Author Provenance (Phase 1)

## Progress


**Why:** the page-version author string (`agents.name`: `"user"`, `"chat:<id>"`,
`"agent:<kind>"`, `"legacy-import"`) was enforced by string discipline scattered
across the codebase with no single source of truth. Three nil-author callers
(the in-app rename, the preflight lint auto-fix, and the daemon Home-seed
bootstrap) silently degraded chat/agent provenance to `legacy-import` — a page
a chat wrote, once renamed or lint-fixed in-app, lost its `chat:` HEAD provenance.

**What:**
- Added `PageAuthor` + `AgentKind` enums in `WikiFSTypes` (`Sources/WikiFSTypes/`)
  as the single source of truth for the `agents.name` / `agents.kind` convention.
  Round-trippable, with `init(rawValue: String?)` (nil/""/unknown → `.legacyImport`
  / `.software`), `agentKind` cross-mapping, and a `chatID` accessor that replaces
  the SQL `substr(a.name, 6)` strip at the Swift layer.
- Routed every construction and parse site through them:
  `AgentLauncher.authorForRun(kind:chatID:)` + inline `chat:<id>` hint writer,
  `GRDBWikiStore.authorKind(_:)` (rewritten as a thin shim), and both parse
  sites in `ProvenancePanel` (`handleProvenanceTap` + `agentLabel`).
- Fixed the three nil-author leaks: rename now stamps `PageAuthor.user.rawValue`,
  preflight lint stamps `PageAuthor.agent("lint").rawValue` via the existing
  `PageUpsert.upsert` author parameter (no signature change), and the daemon
  bootstrap stamps `PageAuthor.user.rawValue`.
- Documented the four SQL `substr(a.name, 6)` + `LIKE 'chat:%'` strip sites
  (`pageOrigin`/`pageEditHistory`/`sourceOrigin`/`sourceEditHistory`) with a
  comment pointing to `PageAuthor.chat(_:).rawValue` as the prefix owner —
  those stay raw SQL because SQLite can't call Swift.

**No DB migration** — `agents.name` / `agents.kind` values are byte-identical
before and after. Only how Swift builds and reads them changes. The four SQL
subqueries are byte-identical too (the `chat:` prefix literal is the same
whether owned by `ResourceKind.chat.linkPrefix` or by SQL).

**Tests:** new `Tests/WikiFSTests/PageAuthorTests.swift` covers AC.1–AC.7
(round-trip identity, edge cases, `agentKind` mapping, `chatID`, `AgentKind`
round-trip + unknown fallback, + three store-integration tests for the leak
fixes on a real in-memory `GRDBWikiStore`). Full `swift test` suite green
(3355 tests / 280 suites).

**Build:** `make version prompts && swift build`.

**Plan:** [`plans/page-author-typing.md`](plans/page-author-typing.md).
Phase 2 (`SourceProvider` enum — routes `SourceDetailView`'s `legacy-import`
comparison through a typed enum) and Phase 3 (`SourceContentType`) deferred.

**Re-merge note (PR #798):** rebased onto PR #796's History inspector redesign.
#796 deleted `ProvenancePanel.agentLabel` + `friendlyRunLabel` (the new
single-timeline row shows only date + badge + current-checkmark — no agent
column), so the `agentLabel` → `PageAuthor` routing that was in the original
plan is no longer a parse site: that surface is gone. The context-menu parse
site #796 added (`navigableSource`, which builds the "Go to Chat" / "Go to
Ingestion Job" labels via `hasPrefix`) is now the second `ProvenancePanel`
parse site routed through `PageAuthor` (alongside `handleProvenanceTap`).
`swift test` re-green post-merge (3355 tests / 280 suites).

---

## Verification

Historical verification remains in the progress record above.

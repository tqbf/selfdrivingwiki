---
timestamp: 2026-07-22T163932Z
title: "refactor: remove system_prompt table (v42)"
branch: null
status: historical
timestamp_source: git-commit
---

# refactor: remove system_prompt table (v42)

## Progress


**Goal:** Remove the user-editable `system_prompt` SQLite table entirely. The
system prompt is now **compiled-only** — always sourced from
`SystemPrompt.defaultBody` (`GeneratedPrompts.systemPromptDefault`). The prompt
is no longer user-editable in-app.

**Changes:**
- **Migration v41→v42:** `DROP TABLE IF EXISTS system_prompt` added to the
  migration ladder. `currentSchemaVersion` bumped from 41 to 42.
- **Fresh-schema path:** removed `CREATE TABLE IF NOT EXISTS system_prompt` and
  the `INSERT OR IGNORE INTO system_prompt` seed.
- **GRDBWikiStore.getSystemPrompt():** returns `SystemPrompt(body:
  SystemPrompt.defaultBody, ...)` with version = stable hash of the body.
- **GRDBWikiStore.updateSystemPrompt():** now a no-op (kept for protocol compat
  but removed from the protocol).
- **systemPromptVersion(on:):** returns `Int64(defaultBody.hashValue &
  0x7FFFFFFF)` — a stable hash so the changeToken advances on recompile.
- **WikiStore protocol:** removed `getSystemPrompt()` and
  `updateSystemPrompt(body:)` from the protocol (they remain as concrete
  methods on `GRDBWikiStore`).
- **WikiStoreModel:** `currentSystemPromptBody()` returns
  `SystemPrompt.defaultBody` directly. Removed `draftSystemPrompt`,
  `isSystemPromptDirty`, `systemPromptAutosaveTask`, `saveSystemPrompt()`,
  `systemPromptChanged()`, `flushPendingSystemPromptSave()`.
- **Projection:** `systemPromptDocument()` returns the compiled default with a
  hash-based version so the File Provider refreshes CLAUDE.md/AGENTS.md on
  recompile.
- **UI:** Deleted `SystemPromptDetailView.swift`. Removed `.systemPrompt` from
  `WikiSelection`, `EditorTab`, `WikiDetailView`, `AddressBarView`,
  `MenuBarItemController`.
- **Tests:** Updated `SystemPromptTests`, `ChangeTokenContributorTests`,
  `LogIndexTests`, `MessageSummaryTests`, `PageVersionTests`,
  `StoreEmissionTests`, `EditorTabTests` for the new compiled-default behavior.

**What stays unchanged:**
- The `ACPBackend.deliverSystemPrompt`/`injectSystemPrompt` delivery mechanism
  takes a `String` and is unchanged — only the source changed from DB to
  compiled constant.
- The `ChangeTokenFold.systemPrompt` case and `SystemPromptTokenContributor`
  remain (Option A from the plan) to preserve the byte-layout contract.
- `ResourceKind.systemPrompt` stays for the contributor + search-skip.
- Old migrations (v2→3 CREATE+seed, v41 $WIKICTL→wikictl) are left in place;
  existing DBs must ladder through them before the v42 DROP removes the table.

## Verification

Historical verification remains in the progress record above.

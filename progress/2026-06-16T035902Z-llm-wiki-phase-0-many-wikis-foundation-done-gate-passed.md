---
timestamp: 2026-06-16T035902Z
title: "2026-06-15 — LLM Wiki Phase 0: Many wikis (foundation) — DONE ✅ (gate passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — LLM Wiki Phase 0: Many wikis (foundation) — DONE ✅ (gate passed)

## Progress


Branch `llmwiki/phase-0-many-wikis` (stacked on the post-v0 line). Implements
`plans/llm-wiki.md` Phase 0: one SQLite DB + one File Provider domain **per
wiki**, a registry, an in-app switcher, and migration of the single v0 wiki as
wiki #1. Independent live-mount gate (computer-use + Bash) PASSED after one
fix round (the migration duplication loop below).

**Added / changed**
- **Registry (`WikiFSCore`).** New `WikiDescriptor` (id ULID, displayName,
  createdAt, lastUsedAt) — `dbFileName` (`<ulid>.sqlite`) and `domainIdentifier`
  (the bare ULID) BOTH derive from the ULID, **never the display name**, so a
  rename can't orphan the DB or the mount (the doc's explicit open-risk). New
  `WikiRegistry` (Codable) persisted as `wikis.json` in the App Group container:
  MRU-ordered list, add/rename/touch/remove, atomic save, corrupt/missing →
  empty (no launch crash).
- **`DatabaseLocation` generalized.** Split into `appGroupContainerDirectory()`
  (literal home path, app) + `extensionContainerDirectory()` (security API,
  extension), each with a per-wiki `…URL(forWikiID:)` → `<ulid>.sqlite`. The
  literal-vs-`containerURL` app/extension split is preserved; the legacy
  `WikiFS.sqlite` constant + Application-Support migration are kept for the v0
  adoption.
- **Extension maps domain → DB (the crux).** `Projection` went from a static
  `enum` to a `struct Projection { let wikiID }`; `init(domain:)` builds
  `Projection(wikiID: domain.identifier.rawValue)` and threads it through
  `WikiFSEnumerator`. `openReadStore()` resolves
  `extensionContainerURL(forWikiID:)` — same projection logic, different DB per
  domain, **no registry read** in the extension. The token-keyed index cache is
  now keyed by `(wikiID, identifier)` so two domains in one process can't collide.
- **`WikiManager` (`WikiFSCore`, `@MainActor @Observable`).** Owns the registry,
  the active `WikiStoreModel`, and create/select/rename/delete. File-Provider
  side effects (`registerDomain`/`removeDomain`) + `onActiveStoreDidChange` are
  injected CLOSURES, so the whole switcher logic is unit-testable without
  importing `FileProvider` (same pattern as `onPageDidChange`). Resolves per-wiki
  DB paths under an injected `containerDirectory` (hermetic tests).
- **One domain per wiki.** `FileProviderSpike` rewritten from a single static
  domain to per-wiki `registerDomain`/`removeDomain`/`activate`/`signalChange`,
  each keyed by the wiki ULID; mounts at `~/Library/CloudStorage/WikiFS-<name>`.
  The v0 `WIKIFS_REENUMERATE` one-shot hatch is preserved, scoped per domain.
  Obsolete single-domain `WelcomeView` spike removed.
- **Switcher UI.** `WikiSwitcher` — a sidebar-header `Menu` (`.headline`, native
  "account header" idiom) listing wikis to select, with New Wiki…/Rename/Delete;
  a `NewWikiSheet` for naming; a destructive-confirm delete alert. `RootView`
  hosts the active wiki's `ContentView` keyed by `.id(activeWikiID)` so no
  draft/selection leaks across a switch. `WikiFSApp` builds the manager, wires
  the FP closures, bootstraps, and registers all domains on launch.
- **v0 migration.** On first launch `WikiManager.bootstrap()` renames the legacy
  `WikiFS.sqlite` (+ `-wal`/`-shm`) to `<ulid>.sqlite` and registers it as wiki
  #1 named "WikiFS" — all pages/files/system_prompt ride along untouched (same
  file). **Strictly one-time, idempotent across any number of launches:** the
  whole legacy-import chain is gated on an EMPTY registry. The first gate run
  found this was broken — two un-coordinated migration layers (`WikiManager`
  renames the container file away; `DatabaseLocation.migrateFromApplicationSupportIfNeeded`
  re-copies it from Application Support) formed a duplication loop, spawning a new
  "WikiFS" wiki on every launch. Fixed by gating BOTH layers on the registry
  being empty: `WikiFSApp.init` only runs the Application-Support copy when the
  registry is empty, and `bootstrap()` only calls `migrateLegacyWikiIfNeeded`
  when the registry is empty. Net invariant: a v0 user's first launch → exactly
  one wiki #1; every subsequent launch adds zero wikis and keeps it active; a
  non-empty registry + a stray legacy file never creates a new wiki.
- Tests: 69 → **86** (+17). New `WikiRegistryTests` (round-trip, MRU,
  rename-keeps-identity, ULID-derived paths) + `WikiManagerTests` (fresh-seed,
  per-wiki DB isolation, distinct files on disk, delete removes DB, MRU
  launch-pick, rename doesn't move the file, v0 migration preserves content +
  doesn't re-run, **legacy file reappearing after first launch doesn't
  duplicate**, **stray legacy file + non-empty registry creates no wiki**).
  `make test` → **86/86**; `make check` clean; real `make` app-bundle build +
  codesign (app + appex) clean.

**Verified (independent live gate, real `make clean && make install`, real-signed, computer-use + Bash)**
- **Create + isolation + independent DBs:** created a second wiki **"GateBeta"**
  in-app via the sidebar switcher → it mounted at its own
  `~/Library/CloudStorage/WikiFS-GateBeta` with its own `<ulid>.sqlite` (3
  distinct ULID DB files in the container at peak). Added a sentinel page
  `BetaSentinelZ9` in GateBeta → it appeared ONLY in GateBeta's DB (`count(*)=1`;
  `0` in both other DBs) and ONLY in GateBeta's mount; the v0 wiki's unique
  `Target` page never appeared in GateBeta's mount, and `BetaSentinelZ9` never
  appeared in the v0 wiki's mount (`WikiFS-WikiFS`). Isolation proven both ways.
- **Delete removes domain + DB:** deleted GateBeta via the switcher (destructive
  confirm dialog) → its registry entry, `<ulid>.sqlite` + `-wal`/`-shm` sidecars,
  Finder mount, AND File Provider domain (`fileproviderctl`) were all gone.
- **v0 preserved + migration idempotent (the fix):** from a v0 starting point
  (Application Support `WikiFS.sqlite` present, empty registry), the FIRST launch
  migrated to **exactly one** wiki #1 "WikiFS" carrying the full v0 content —
  original `Home` (`01KV6EAH…`) + `Target` (`01KV6KS0…`) + the ingested
  `[MS-NRPC] (1).pdf` — served read-only on the mount. Repeated relaunches **with
  the Application Support source still present** kept the registry at exactly one
  wiki (same id) and one ULID DB — zero duplicates (the pre-fix code spawned a new
  "WikiFS" every launch). Read-only still enforced (`echo >` rejected with
  "operation not permitted"; SQLite untouched).

**Notes / carry-forward**
- **macOS-26 TCC gate re-fires on a re-signed install:** "WikiFS would like to
  access data from other apps" appears (UserNotificationCenter) in `App.init()`
  and holds the app hostage until "Allow" — migration/bootstrap don't run until
  it's dismissed. Consent persists across launches within an install. Already
  documented in `progress/`/`ISSUES.md`; surfaced again here driving the gate.
- **Mount labels:** each wiki mounts at `~/Library/CloudStorage/WikiFS-<display>`;
  two wikis with the same display name collide on the Finder label (not the DB —
  identity is the ULID). With the migration fixed there are no spurious
  same-named duplicates; deliberate same-name wikis remain out of scope to dedupe.
- **Stale domains** from prior manual file-archiving aren't reaped by the app
  (it registers add-if-absent; `NSFileProviderManager.removeAllDomains` needs the
  provider-app context, so an ad-hoc CLI can't reap them). Cosmetic only.

A user-editable singleton "system prompt" document — the instructions the
managing agent reads each run — projected **read-only at the wiki root under TWO
names with identical bytes: `CLAUDE.md` and `AGENTS.md`** (the filenames CLI
agents look for). Edited in-app like a page; read-only on the mount like
everything else. Branch work stacked on the v0 + Phase-5 line.

**User-chosen scope (locked):** in-app editing via a **pinned sidebar item**
(above Pages) that opens the document in the main editor pane — i.e. a
first-class document, not a sheet/settings window.

**Added / changed**
- **New singleton `system_prompt` table** (`id INTEGER PRIMARY KEY CHECK(id=1)`,
  `body_markdown`, `updated_at`, `version`). `bootstrapSchema()` gains a stepwise
  **v2→3 migration** that creates AND **seeds** the row with
  `SystemPrompt.defaultBody`; existing v1/v2 DBs migrate forward with pages +
  ingested files preserved (test-proven). `SystemPrompt` value type +
  `defaultBody` live in `WikiFSCore` (shared by the migration seed and the
  projection fallback).
- **Store API** (`SQLiteWikiStore` + `WikiStore` protocol): `getSystemPrompt()`
  (returns the seeded default if absent) and `updateSystemPrompt(body:)`
  (**UPSERT**, `version = version + 1`).
- **⚠️ `changeToken()` now folds in the system-prompt version** →
  `"pCount:pSum:fCount:fSum:spVersion"`. Editing ONLY the prompt (no page/file
  change) must still advance the sync anchor or the projected files would never
  refresh. Resilient to the table being absent on a pre-v3 read connection
  (→ `0`). All `changeToken` test literals gained the trailing `:1`.
- **Projection**: `CLAUDE.md` + `AGENTS.md` as root-level files (new
  `claude-md`/`agents-md` identities), both serving the SAME live body (read like
  a page in both `node` and `contents`); item version = the row `version`. Added
  to root children, the working set, and `contents(for:)`; README updated.
  `systemPromptDocument()` falls back to `SystemPrompt.defaultBody` so the two
  files ALWAYS exist even pre-migration. **No new signal container needed** — both
  are root children, so the existing `.rootContainer` + `.workingSet` signals
  refresh them (same path as `manifest.json`).
- **Model/UI**: sidebar selection generalized from `PageID?` to a new
  `WikiSelection` enum (`.page` / `.systemPrompt`); the autosave tests reference
  selection opaquely so the load-bearing §3.5 logic is untouched. New
  `draftSystemPrompt` track with its own debounce + `flushPendingSystemPromptSave`
  (combined `flushPendingSaves()` used on switch + backgrounding). `SidebarView`
  pins a **"System Prompt"** item above Pages; `ContentView` switches the detail
  pane; new `SystemPromptDetailView` (header explaining the projection + editor +
  live preview, semantic Dynamic-Type styles).
- Tests: 63 → **69** (new `SystemPromptTests`: seed default, update bumps
  version + persists across reopen, repeated edits, token advances on a
  prompt-only edit, UPSERT recreates a deleted row, v2→3 migration preserving
  pages + files). Updated `SQLiteWikiStoreTests` (user_version 3, `system_prompt`
  table, `:1` token suffix) and the `IngestedFilesTests` migration assertion (→3).

**Verified (live signed mount, real `make install`, computer-use + Bash)**
- **Byte-identity:** `CLAUDE.md` and `AGENTS.md` byte-identical to each other AND
  to the seeded DB body (`writefile` raw compare; sha `17e74587…`, 770 bytes —
  762 *chars*, the gap is UTF-8 em-dashes). 69/69 tests; real Apple Development
  signing chain.
- **Refresh on edit (no relaunch):** edited the prompt **in-app** (appended a
  sentinel to the heading via the pinned "System Prompt" item), switched pages to
  flush → `system_prompt.version` bumped (1→3 across autosave+flush), sentinel
  persisted to SQLite. Within ~6 s the mount's `CLAUDE.md` AND `AGENTS.md` showed
  the new bytes (sha `f7021881…`), **app pid unchanged** (no relaunch). Reverted
  the sentinel in-app → both files returned to the clean default (sha
  `17e74587…`). The change-token's `spVersion` fold drives this end to end.
- **Read-only enforced:** append/overwrite of both files rejected (`operation not
  permitted`); SQLite row untouched; projected bytes still matched the DB (no
  client-side staging leak).
- **One-shot re-enumerate needed** on the already-materialized (phase-5) domain to
  surface the two new root files — launched once with `WIKIFS_REENUMERATE=1`, as
  predicted; fresh installs wouldn't need it.

**Notes / known gaps**
- The ~5 s read-after-write window (replicated-File-Provider replica invalidation,
  NOT a stale SQLite read) is documented in `ISSUES.md` — two items signaled
  together (`CLAUDE.md` + `AGENTS.md`) can also refresh a few seconds apart.
- Same `files/`-style caveat: on an already-materialized (upgraded) domain the
  two new root files may need the one-shot `WIKIFS_REENUMERATE=1` launch to
  appear; fresh installs are fine.
- Pre-existing flaky test `resolvesDuplicateTitleToLowestULID` (same-millisecond
  ULID ordering) is unrelated to this change — flagged separately.

## Verification

Historical verification remains in the progress record above.

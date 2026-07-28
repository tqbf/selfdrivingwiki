---
timestamp: 2026-06-15T201231Z
title: "2026-06-15 — Phase 1 (M0+M1): Local SQLite wiki — DONE ✅ (gate passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — Phase 1 (M0+M1): Local SQLite wiki — DONE ✅ (gate passed)

## Progress


A usable standalone Markdown wiki, persisted in SQLite, verified on the running
app (not just a green build). Branch `phase-1-local-wiki` (stacked off `main`,
unmerged — review locally; the pipeline keeps `main` pristine and stacks each
phase branch on the prior).

**Added**
- `Sources/WikiFSCore/` — new **library** target (so the store is unit-testable
  now and the read surface is reusable by the Phase-2 extension):
  - `SQLiteWikiStore.swift` — hand-wrapped system `SQLite3` (no third-party
    dep). `READWRITE|CREATE|FULLMUTEX`; pragmas `journal_mode=WAL` (return row
    asserted == `wal`) / `foreign_keys=ON` / `busy_timeout=5000`;
    `user_version`-guarded idempotent bootstrap of `pages`+`attachments`+
    `page_links` + unique slug index; statement cache; **`SQLITE_TRANSIENT`**
    text binding (not STATIC); slug collision suffix `-<first6 of ULID>`.
  - `ULID.swift` (48-bit ms ‖ 80 random bits, Crockford base32 — lexical sort
    == creation order, for cheap Phase-4 by-date views), `PageID`, `WikiPage`,
    `WikiPageSummary`, `WikiStore`(+`WikiStoreError`), `DatabaseLocation`,
    `WikiStoreModel`.
  - `WikiStoreModel.swift` — `@MainActor @Observable`. `summaries` always
    rebuilt from `store.listPages()` (never patched — SWIFTUI-RULES §3.1); live
    `draftTitle`/`draftBody` buffers (drafts live in the model so flush can read
    them — §3.5); 500 ms debounced autosave; `save()` reads live values at fire
    time and writes to the *loaded* page (correct even after selection advances);
    `flushPendingSave()` on page-switch and on app backgrounding.
- `Sources/WikiFS/` UI: `SidebarView` (List, +New, rename, delete via
  contextMenu **and** swipeActions), `PageDetailView` (title + `TextEditor` +
  live preview), `MarkdownPreview` (`AttributedString(markdown:)`, inline-only
  per INITIAL §4), `PageEditorMetrics`; `ContentView` rewired to
  `NavigationSplitView` + `ContentUnavailableView` empty state; `WikiFSApp`
  flushes autosave on `scenePhase != .active`. Spike files kept (Phase-2 ref),
  unhosted.
- `Tests/WikiFSTests/` — 10 tests incl. the §3.5/§9.4 stale-snapshot autosave
  regression and persistence-across-reopen.

**Decisions**
- **DB at `~/Library/Application Support/WikiFS/WikiFS.sqlite` for Phase 1**
  (option c), path injected via `DatabaseLocation`. The App Group container API
  (`containerURL(forSecurityApplicationGroupIdentifier:)`) returns `nil`
  without the sandbox + app-groups entitlement, and enabling the sandbox now
  would front-load the Phase-4 `Process`/agent-spawn restriction for zero
  Phase-1 benefit. **Phase 2 must repoint to the App Group container + run a
  one-time `migrate(from:to:)`** (hook noted in `DatabaseLocation.swift`). No
  entitlement/sandbox change this phase.
- Split `WikiFSCore` library (vs. `@testable import` of an executable) — clean
  testability + a shared store surface for the Phase-2 reader.
- Hand-wrapped SQLite3, no GRDB (dependency-free default honored).

**Verified (independent computer-use gate, fresh `make clean && make`)**
- Live preview: unique sentinel `VERIFY-7Q4Z` typed → preview rendered bold/
  italic live (screenshot read back, not just asserted).
- Persistence: clean-DB start → create `Home` → quit → relaunch → `Home` + body
  reload from disk. Running binary confirmed to be the fresh `build/` copy
  (`lsof`), alive 4 s past launch (no constraint crash).
- Data layer: `sqlite3 … "select … from pages"` → exactly one `Home` row with
  the exact sentinel body; DB at the literal Application Support path (no
  sandbox redirect). `make test` → 10/10 pass.

**Notes / caveats**
- Synthetic keystrokes don't reach SwiftUI `TextEditor`; the gate drove text via
  the AX `value` API (fires `.onChange` → autosave). Real user typing is
  unaffected. A bug found *by* the live gate — sidebar `List(selection:)` wrote
  the property directly, bypassing the load path — was fixed (`.onChange(of:
  selection)` → `handleSelectionChange`) with a regression test.
- Context-menu Rename / swipe-Delete are implemented + unit-tested but not
  visually gate-confirmed (outside the acceptance bar).
- DB state for Phase 2: fresh DB holds one clean `Home`; the pre-gate DB is
  preserved as `WikiFS.sqlite.verifier-bak` in the same dir.

## Verification

Historical verification remains in the progress record above.

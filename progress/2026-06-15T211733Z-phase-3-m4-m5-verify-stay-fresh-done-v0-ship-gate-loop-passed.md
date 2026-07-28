---
timestamp: 2026-06-15T211733Z
title: "2026-06-15 — Phase 3 (M4+M5): Verify & stay fresh — DONE ✅ (v0 ship-gate loop passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — Phase 3 (M4+M5): Verify & stay fresh — DONE ✅ (v0 ship-gate loop passed)

## Progress


**This closes the v0 definition of done (INITIAL §12):** copy a Unix path → read
it in Terminal → edit in the app → re-read sees the update, no relaunch. Branch
`phase-3-verify-fresh` (stacked on `phase-2-file-provider`, unmerged). Phase 4
(agent-facing wiki) is the extension on top; the core v0 loop is now proven.

**Added / changed**
- **M4 — path button.** `Sources/WikiFS/VerificationPopover.swift` (NEW) +
  `ContentView.swift`: a `Copy Unix Path` toolbar button (⌘⇧U) opening a popover
  that resolves the mount URL **at click time** via
  `NSFileProviderManager.getUserVisibleURL(for: .rootContainer)` (NEVER
  hardcoded), copies `url.path` to the pasteboard, shows it (monospaced,
  selectable), and offers a copyable `cd … && find . && cat pages/by-title/Home--*.md`
  block + Reveal in Finder. (Open Terminal Here skipped — Process hop is Phase 4.)
- **M5 — change-signaling (defeats read-after-write staleness).**
  - `WikiFSCore/SQLiteWikiStore.swift` — `changeToken()` = `"count:sum(version)"`.
    **NOT `MAX(version)`:** `version` is per-page, so `MAX` wouldn't advance when
    a non-max page is edited (would stay stale); `count:sum` advances on every
    create/update/delete. Locked by `changeTokenAdvancesOnEveryMutation`.
  - `WikiFSFileProvider/WikiFSEnumerator.swift` — `currentSyncAnchor` returns the
    live token; `enumerateChanges` re-emits page items (carrying higher
    `contentVersion`) when the token advanced → daemon invalidates the
    materialized copy → next read re-fetches from SQLite. Legacy/unparseable
    anchors (the Phase-2 `"v2-sqlite"`) treated as expired → clean full
    re-enumerate.
  - `WikiFSCore/WikiStoreModel.swift` — `@ObservationIgnored onPageDidChange`
    hook fired on save/new/rename/delete success (NO FileProvider import in core).
  - `WikiFS/FileProviderSpike.swift` — `signalChange()` signals **three**
    containers: `pages-by-title`, `pages-by-id`, and `.workingSet` (signaling root
    alone wouldn't refresh the page lists). `registerIfNeeded()` rewritten
    **add-if-absent** — the Phase-2 `remove(.removeAll)` relaunch hack is GONE.
  - `WikiFSCore/WikiFSContainerID.swift` (NEW) — shared plain-`String` container-id
    constants used by BOTH the extension and the app, so the signaled ids can't
    drift from the projection's ids.
  - `WikiFSApp.swift` — wires `store.onPageDidChange = { fileProvider.signalChange() }`.
- Tests: 23 → **24** (+`changeTokenAdvancesOnEveryMutation`).

**Verified (independent computer-use gate, fresh `make clean && make install`, real-signed)**
- Copy Unix Path → clipboard held `/Users/tqbf/Library/CloudStorage/WikiFS-WikiFS`
  (overwrote a pre-seeded sentinel → the app wrote it); path matches the live
  mount `fileproviderctl dump` reports.
- `cat` original Home (`VERIFY-7Q4Z`) → edit through the app to `FRESH-D7F04E00`
  → change token advanced **`1:5 → 1:6`**, row now `version 6` (proves the edit
  went through the app's real save pipeline, not a DB poke) → re-`cat` the SAME
  files (by-title AND by-id) showed the NEW bytes, **app never relaunched** (pid
  stayed up). Read-only not regressed (writes rejected / staged-then-reverted;
  SQLite untouched). 24/24 tests; real Apple Development signing chain.

**Caveat (carry into Phase 4)**
- **Refresh is eventually-consistent (~5 s):** `signalEnumerator` →
  `enumerateChanges` → re-fetch is async, so a `cat` within ~1 s of saving can
  briefly show stale bytes before refreshing on its own (no relaunch needed). A
  tightly-polling agent (Phase 4) may want a short settle or an explicit sync
  step before reading just-written content.

## Verification

Historical verification remains in the progress record above.

---
timestamp: 2026-06-15T205523Z
title: "2026-06-15 — Phase 2 (M2+M3): File Provider projection from SQLite — DONE ✅ (gate passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — Phase 2 (M2+M3): File Provider projection from SQLite — DONE ✅ (gate passed)

## Progress


The File Provider extension now serves a **read-only filesystem projection of the
SQLite wiki**, shared with the app via the App Group container. Branch
`phase-2-file-provider` (stacked on `phase-1-local-wiki`, unmerged). A swap of
the spike's static `Catalog` for a live SQLite projection — the appex plumbing,
entry-point flag, inside-out signing, and domain registration all carried over.

**Added / changed**
- `Sources/WikiFSFileProvider/Projection.swift` (NEW; `Catalog.swift` deleted) —
  identity↔row mapping, static `README.md`, filename escaping, and
  `node(for:)`/`children(of:)`/`contents(for:)`, each opening a **short-lived
  read connection** to the App Group DB via `extensionContainerURL()`.
  Virtual ids carry the **full ULID, never the filename** (paths are
  presentation — INITIAL §6).
- `WikiFSCore/SQLiteWikiStore.swift` — `init(readOnlyURL:)` opens a read-WRITE
  handle then `PRAGMA query_only=ON` (NOT `SQLITE_OPEN_READONLY`): robustly
  attaches the WAL `-shm` even when no writer is running (matters for Phase-4
  agents reading with the app closed) while still rejecting writes.
- `WikiFSCore/DatabaseLocation.swift` — `appGroupContainerURL()` (literal path,
  used by the un-sandboxed app, no entitlement needed), `extensionContainerURL()`
  (`containerURL(forSecurityApplicationGroupIdentifier:)`, sandboxed extension;
  same inode), `migrateFromApplicationSupportIfNeeded()` (checkpoint-TRUNCATE +
  copy the single `.sqlite`).
- `WikiFSFileProvider/WikiFSItem.swift` — real `documentSize` (=`utf8.count`,
  never nil → no truncated `cat`), `contentType`, creation/mod dates, and
  content/metadata `itemVersion` from the row. Read-only capabilities.
- `WikiFSFileProvider/WikiFSEnumerator.swift` — queries `Projection`,
  offset-paginated (256/page), sync anchor bumped to `"v2-sqlite"` so any cached
  spike enumeration expires.
- `WikiFS/WikiFSApp.swift` + `FileProviderSpike.swift` — open the App Group DB
  (after migration); `registerIfNeeded()` does `remove(_, mode: .removeAll)` then
  `add` on launch so the daemon re-enumerates from the SQLite extension.
- `Package.swift` — extension target depends on `WikiFSCore`; `-e
  _NSExtensionMain` flag + `FileProvider` framework preserved. `build.sh`
  unchanged.
- Tests: +13 (FilenameEscaping, ReadOnlyStore) → **23 total, all pass**.

**Decision — Option B: app stays UN-sandboxed**
Both processes share the literal `~/Library/Group Containers/group.org.sockpuppet.wiki/WikiFS.sqlite`
(app writes the literal path; sandboxed extension resolves the same inode via
`containerURL`). Rejected sandboxing the app (Option A) because it would (1)
redirect `Application Support` and orphan the Phase-1 DB, and (2) front-load the
Phase-4 `Process`/agent-spawn restriction (`signing.md`) for zero Phase-2
benefit. The container dir is user-owned and writable by a non-sandboxed
process. Phase-1's `Home` row **migrated** intact (same ULID
`01KV6EAH410NWC9K9ZM44DNMXT`).

**Verified (independent gate, fresh `make clean && make install`, real-signed)**
- `find .` → `README.md` + `pages/by-id/<ULID>.md` + `pages/by-title/Home--<id8>.md`
  (the SQLite ULID, not the static spike tree).
- `cat` of by-title AND by-id → byte-identical Home body (`VERIFY-7Q4Z` sentinel,
  62 bytes, `shasum b6ef887f…`), exactly matching the SQLite row.
- Read-only: `createItem` → FP -2010; shell writes stage client-side then revert;
  SQLite source of truth never altered. Extension `+`-enabled, fresh appex
  (Timestamp 20:44:24) serving.

**Notes / caveats (carry into Phase 3)**
- **macOS 26 TCC gate:** first App Group access raises *"WikiFS would like to
  access data from other apps"* (Allow/Don't-Allow, NOT Touch ID). It fires
  synchronously in SwiftUI `App.init()`, so the window is hostage to it, and a
  re-signed `make install` re-prompts. Consent persisted across the gate launch.
  *Cleanup idea:* move the DB open off `App.init()` so the window renders while
  the prompt is pending.
- **Read-after-write staleness on EDITS is still present — that's Phase 3's job.**
  The blunt `remove(.removeAll)` refresh on launch is replaced in Phase 3 by
  per-item version bumps + `signalEnumerator`.
- Read-only root: a shell `echo > f` stages then reverts (File Provider client
  framework behavior); never reaches SQLite. Optional polish: disallow
  adding-sub-items on the root capabilities for up-front shell rejection.
- All 5 File Provider gotchas intact (entry-point flag, entitlements⊆profile,
  user-enabled, /Applications via `make install`, real codesign).
- **Operational:** the Mac went to the **lock screen** during the Phase-2 run;
  the gate's load-bearing evidence was read directly from the live mount
  (identical regardless of GUI lock), but the GUI-driven Phase-3 gate (edit in
  app → re-read in Terminal) needs the screen unlocked + kept awake.

## Verification

Historical verification remains in the progress record above.

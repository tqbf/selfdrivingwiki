---
timestamp: 2026-07-08T160251Z
title: "2026-07-08 — #129 Phase E: model subscribes to ALL events; `origin` removed"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — #129 Phase E: model subscribes to ALL events; `origin` removed

## Progress


**Shipped (on `feature/129-phase-e-reload-on-self-write`; tests green).** The
core Phase E change: the model is now a **pure reload subscriber** on the bus —
it reloads on **every** event (both in-app writes and cross-process `wikictl`
writes), not just `.external` ones. The transitional `origin` field
(`.local`/`.external`) is fully removed from `ResourceChangeEvent`, `EventOrigin`,
the store's `localEvent`, the bridge's emit, and all tests. The event shape now
matches §3 decision 2's `(wiki, seq, kind, id, change)` exactly.

**What shipped:**
- **`EventOrigin` + `origin` field deleted** from `WikiEventBus.swift`. The
  `ResourceChangeEvent` is now `(wikiID, kind, id, change, seq)` — no origin
  distinction. Updated `emit` to stop threading `origin` through.
- **`SQLiteWikiStore.localEvent`** — `origin: .local` removed.
- **`WikiChangeBridge.flush`** — `origin: .external` removed; the bridge now
  emits a plain coarse event (the model reloads on it like any other).
- **`WikiStoreModel.subscribeToChanges`** (renamed from
  `subscribeToExternalChanges`) — the `.external` guard is gone; the model
  reloads on ALL events via `reloadFromStore()`.
- **Tests updated** — `WikiEventBusTests` (11 event constructions), 
  `WikiChangeBridgeBusTests` (3 event constructions + 2 test rewrites:
  `localEventReloadsModel` replaces `localEventDoesNotReloadModel`;
  `coarseBusEventReloadsModel` replaces `externalEventReloadsModel`),
  `StoreEmissionTests` (1 `.origin` property assertion removed).

**Deferred (follow-up):** the ~28 per-call `reload*()` sites in the model's
write methods (e.g., `reloadSummaries()` after `save()`, `reloadSources()`
after `addSource`). They are now **redundant** — the bus-triggered
`reloadFromStore()` handles every write — but removing them is a code-cleanup
PR (not an architectural change): each removal risks tests that synchronously
check model list state after a write. The reload methods only touch list
projections (sidebar, sources, chats, bookmarks) — never the editor draft or
selection — so there is **no editor focus/flicker risk** either way.

**Gate:** `origin` fully removed ✅; model subscribes to all events ✅ (proven
by `localEventReloadsModel`); no editor focus/flicker regression ✅ (reload
only refreshes list projections). **1914 tests green** (156 suites).

## Verification

Historical verification remains in the progress record above.

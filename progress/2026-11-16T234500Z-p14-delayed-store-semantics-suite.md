---
timestamp: 2026-11-16T234500Z
title: P1.4 delayed-store semantics suite pins model async semantics
branch: feature/daemon-only-p1-async-store
status: active
---

# P1.4 delayed-store semantics suite pins model async semantics

## Progress

Implemented the P1.4 delayed-store suite (`plans/daemon-only-access.md`
Phase 1 item 4, designed in `tmp/p1-delayed-store-design.md`).

- `Tests/WikiFSTests/ModelDelayedWikiStore.swift` — a generated proxy
  (generator: `tmp/generate_delayed_store.py`, one-off; output committed)
  wrapping an in-memory `GRDBWikiStore`. It forwards all 175 `WikiStore`
  function requirements plus 3 `{ get set }` properties through an
  `any WikiStore` existential, and intercepts `getPage`, `listPages`, and
  `upsertPage` (the model's shared save seam) through a lock-guarded
  `TestStoreController` with `DelayedStoreGate` latches whose waits race a
  timeout, call/entry counters, recorded upserts, and error providers.
- `Tests/WikiFSTests/ModelDelayedStoreTests.swift` — six Swift Testing
  scenarios (`@Suite(.serialized, .timeLimit(.minutes(5)))`): rapid A→B→C
  navigation lands only C; a stale load completion released LAST is
  discarded; typing during a pending save keeps the draft and saves once; a
  failed save on switch surfaces the error and preserves the store;
  overlapping event reloads coalesce into ONE follow-up reload; bootstrap
  readiness gates first render and pre-bootstrap selection does not resolve.
  Negative sanity: disabling the post-await generation check turns the first
  two scenarios red; removing the flush `storeError` surface turns the
  failed-save scenario red; removing the save dirty-guard turns the
  typing-during-save scenario red; removing the reload coalescing branch
  turns the coalescing scenario red. All model edits restored afterward.
- Two genuine model defects found and fixed in `WikiStoreModel.swift`:
  the transition flush (`flushCapturedDraft`) swallowed write failures with
  only a debug log — it now surfaces `storeError` like `save()` does; and
  `save()` cleared `isDraftDirty` unconditionally, so a keystroke landing
  while the write was in flight was flagged clean and an event reload then
  reverted it — the flag now clears only when the draft still matches the
  saved text.
- Repaired `progress/2026-11-16T232000Z-daemon-only-p1-async-store-green.md`
  to carry the `---` front-matter delimiters the documentation contract
  enforces (the missing delimiters failed `progressEntriesFollowTemplate`
  at the clean commit).

## Verification

- `swift build --build-tests` green; `make lint` 0 violations in 758 files.
- `swift test --filter ModelDelayedStoreTests` green: 6 tests, ~0.23 s.
- Negative sanity demonstrated one-at-a-time with the model restored after
  each: 4 model mutations, each turning exactly the pinned scenarios red.
- `make test` full suite green with the new suite included.

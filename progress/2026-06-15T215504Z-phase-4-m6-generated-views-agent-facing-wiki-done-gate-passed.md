---
timestamp: 2026-06-15T215504Z
title: "2026-06-15 — Phase 4 (M6 + generated views): Agent-facing wiki — DONE ✅ (gate passed)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — Phase 4 (M6 + generated views): Agent-facing wiki — DONE ✅ (gate passed)

## Progress


Branch `phase-4-agent-wiki` (stacked on `phase-3-verify-fresh`, unmerged).
Layers the agent surface on top of the v0 loop.

**Added / changed**
- **Wiki-links (INITIAL §4).** `WikiFSCore/WikiLinkParser.swift` (pure, tested):
  `[[Title]]` + `[[Target|alias]]`, whitespace-collapse, dedupe, skip empty.
  `SQLiteWikiStore` gains `resolveTitleToID` (lowest ULID on duplicate titles),
  `replaceLinks` (one txn: delete-then-`INSERT OR IGNORE` the resolved subset;
  **unresolved links omitted** — `page_links.to_page_id` is NOT NULL/FK; self-
  links allowed), `listAllLinks`. `WikiStoreModel.save()`/`newPage()` re-parse +
  rewrite that page's links. **`deletePage` now clears `page_links` rows
  referencing the page (source OR target) first** — required under
  `foreign_keys=ON` or deleting a linked page throws (orchestrator-caught;
  regression-tested).
- **Generated indexes (INITIAL §5).** `WikiFSCore/IndexGenerators.swift` (pure,
  deterministic, tested): `manifest.json` (`name/version/generated_at/
  page_count/paths`), `indexes/pages.jsonl` (one line/page, by id), `indexes/
  links.jsonl` (one line/link from `page_links`). `Projection` adds the four
  identities + a **token-keyed (`count:sum(version)`) byte cache** so a node's
  `documentSize` and its `contents` bytes always come from the same snapshot
  (a mismatch truncates `cat`). `signalChange()` now also signals `.rootContainer`
  + `indexes` so edits invalidate the generated files.
- **Agent launcher (INITIAL §8 / M6).** `WikiFS/AgentLauncher.swift`
  (`@MainActor @Observable`) spawns `/bin/zsh -lc <command>` with `WIKI_ROOT` =
  the live mount (resolved via `getUserVisibleURL` at click time, never
  hardcoded), streaming stdout+stderr into the UI via pipe `readabilityHandler`s
  (non-blocking; `terminationHandler` for exit status). `AgentLauncherView.swift`
  is the sheet (editable command, Run/Stop, scrolling output). Works because the
  app is **un-sandboxed** (the Phase-2 Option-B call) — a sandboxed app couldn't
  `Process`-spawn. Before spawning, `await signalChange()` so the agent sees
  current content (no fixed-sleep correctness dependency).
- Tests: 24 → **47** (WikiLinkParser, replaceLinks/resolve/listAllLinks,
  deletePage-with-links FK regression, index generators).

**Verified (Bash by the orchestrator + user-confirmed GUI)**
- `manifest.json` valid, `page_count: 2` == `select count(*) from pages`.
- `indexes/pages.jsonl`: 2 valid JSON lines == 2 pages. `indexes/links.jsonl`:
  the **cross-page link** `Home→Target` (`{"from","to","link_text":"Target"}`),
  valid, == the one `page_links` row — `[[Target]]` in Home's body parsed through
  to the index end to end.
- Read-only: `manifest.json` overwrite → "operation not permitted"; SQLite
  untouched. Phase-3 freshness intact (Home body served fresh, no relaunch).
- 47/47 tests; real-signed `make install`.
- **Agent launcher: user confirmed** the in-app output panel populated with the
  `find` tree + manifest + both JSONL files when clicking Run Agent (WIKI_ROOT =
  the live `~/Library/CloudStorage/WikiFS-WikiFS` mount).

## Verification

Historical verification remains in the progress record above.

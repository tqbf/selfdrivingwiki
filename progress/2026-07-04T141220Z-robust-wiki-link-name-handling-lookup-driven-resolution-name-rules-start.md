---
timestamp: 2026-07-04T141220Z
title: "2026-07-04 — Robust `[[wiki-link]]` name handling: lookup-driven resolution, name rules, startup self-heal (v18)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-04 — Robust `[[wiki-link]]` name handling: lookup-driven resolution, name rules, startup self-heal (v18)

## Progress


A source/page NAME containing `#` (e.g. "Agentic Static Analysis for C#
Security Auditing") broke every citation to it — the parser split targets on
the FIRST `#`, truncating labels and orphaning links. Fixed structurally, plus
the adjacent robustness gaps:

- **`WikiLinkResolver`** (new, pure): a raw target like `C# Guide#Methods` is
  ambiguous syntactically but not against the real namespace — resolution now
  tries every `(name, fragment)` reading, longest name first (exact full-target
  match wins), taking the first that names an existing page/source. Wired into
  `SQLiteWikiStore.replaceLinks` (link graph), `WikiLinkMarkdown.linkified`
  (reader links + ghost styling), and `WikiStoreModel.preflightLint`.
  `WikiLinkParser.splitFragment` prefers the `#"` quote-anchor delimiter for
  unresolved (ghost) display; `parse` de-dupes by RAW target so two `#`-titles
  sharing a mis-split base both survive.
- **`WikiLinkRewriter`**: rename rewriting matches the old name by direct
  string comparison after `source:` (candidate slices, longest first) instead
  of delimiter guessing; an `isNameKnown` closure from `renameSource` keeps
  longest-name-wins (renaming source "C" can't corrupt a citation of
  "C# Notes").
- **`WikiNameRules`** (new): names that can NEVER be linked are sanitized at
  every write boundary (`|` → `-`, `[`/`]` → `(`/`)`, leading `#` dropped) —
  `createPage`, `updatePage`, `renameSource`, `addSource` (unlinkable FILENAME
  falls back into `display_name`; the filename stays verbatim), and
  `PageUpsert` (before the title→id resolve, so repeated upserts of a dirty
  title can't duplicate pages). `#` inside a name stays legal.
- **Migration v17→18** (`sanitizeStoredNames`): one-time, data-only sweep of
  existing titles/display names that violate the rules (slug recomputed,
  version bumped). Fresh-schema fast path stamps 18.
- **Lenient source resolution** (`resolveSourceByName` pass 3): unique-only
  match on `WikiNameRules.looseMatchKey` (one trailing extension + one trailing
  "(…)" suffix stripped), so a citation of `Some Paper (2026)` finds
  "Some Paper.pdf"; two candidates → no guess. Mirrored in the reader's
  ghost-styling sets.
- **`LinkReconciler`** (new, pure orchestration like `PageUpsert`): re-parses
  every page and rewrites link rows under current rules; run once per model
  lifetime from the top of `upgradeSearchIndex()` (scenePhase-`.active` hook,
  before the MiniLM gates). Heals rows written before a resolution improvement
  or before their target was ingested — page bodies untouched.
- Tests: new resolver/name-rules/sanitization suites (incl. a raw-SQL v17
  tamper/reopen migration test); residual edges (reserved characters inside
  quoted passages; inherent `#` ambiguity when both readings exist) documented
  in `ISSUES.md`.

## Verification

Historical verification remains in the progress record above.

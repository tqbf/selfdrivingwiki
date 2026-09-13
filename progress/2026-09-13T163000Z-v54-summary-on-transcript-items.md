---
timestamp: 2026-09-13T163000Z
title: v54 — per-message summary on chat_transcript_items; legacy preamble compensations bounded (#1266)
branch: feature/v54-summary-on-transcript-items
status: complete
---

# v54 — per-message summary on chat_transcript_items; legacy preamble compensations bounded (#1266)

## Progress

Issue #1266 recorded two v54-scale cleanups. Both shipped in one schema pass.

**The per-message summary moved onto the durable transcript row.** The
summary belonged to `chat_transcript_items`: the outline consumes transcript
pages, but the summary lived on the compatibility `chat_messages` projection,
keyed by an unrelated `PageID`. The old read joined the two tables by the
`seq = cursor - 1` ordinal mapping, and a lockstep guard existed only to keep
that join honest.

Schema v54 adds `summary` / `summary_kind` / `summary_at` to
`chat_transcript_items`, backfills them from `chat_messages` through the
documented mapping, and drops the `chat_messages` columns. The compatibility
projection now holds no app-owned state.

**Follow-on changes:**

- `updateMessageSummary` takes a `ChatTranscriptCursor`.
- `readChatTranscriptPage` selects `chat_transcript_items.summary`; the join
  and the lockstep guard's reason for existence are gone (the guard stays —
  the durable append still needs it to catch a legacy-only write).
- `PersistedChatTranscriptItem.cachedResponseSummary` is now `summary`.
- The summarizer scans transcript pages. `MessageSummarizer.pendingSummaryTargets`
  extracts the pending set; both hosts write by cursor.
- `ChatMessage` lost its summary fields; `chatMessages()` is export-only.

**The legacy preamble compensations are bounded.** Two display-time strips
existed only for rows written before the derivation/summarizer seams stripped
the skills-budget warning themselves (`7937b383` titles, `bb3e7884`
summaries). They had no expiry. The v54 migration rewrites the tainted data
once:

- A content-bearing `chats.title` keeps its cleaned remainder.
- A warning-only title is rewritten to the provisional question title, or
  "New Chat" when no question is recoverable.
- The `chat_search` sidecar title copy is rewritten in the same pass.
- A warning-only summary returns to unsummarized, so the summarizer
  recomputes it clean.

After the backfill, the display-time strips in `ChatsCellView.rowTitle` and
`ChatDetailPresentation.buildOutlineEntries`, and their tests, deleted.

**Decisions:**

- **Guarded ALTERs, guarded backfill.** Fresh databases stamp the current
  version and never run the ladder, so the fresh-path creator
  (`createChatTranscriptItemsV54`) carries the trio directly, and the ladder
  step guards every ALTER. The backfill also requires the full source trio
  on `chat_messages`, so a synthetic partial schema (or a v52-era DB) passes
  through instead of failing on a missing column.
- **Warning-only titles recover the question, not a placeholder.** The
  rewrite mirrors first-send titling: `ChatSummary.title(fromFirstMessage:)`
  on the first `userText` row. That restores the user's question, which the
  warning had displaced. "New Chat" is the fallback, matching what those
  rows rendered before.
- **A missing cursor row in `updateMessageSummary` stays a silent no-op**,
  matching the old messageID-keyed behavior: the caller's pending snapshot
  was stale.
- **`visibleText` returns nil, not an empty string, for warning-only text.**
  The first sanitizer draft treated nil as "leave untouched" and the tests
  caught it: warning-only rows must rewrite (titles) or unsummarize
  (summaries), not survive.

## Verification

- `SchemaMigrationLadderTests.v53DBMovesPerMessageSummaryAndRewritesTaintedRows`:
  backfill through the seq↔cursor mapping, tainted/clean/warning-only
  summaries, content-bearing/warning-only/clean titles, sidecar rewrite,
  column drops.
- Fresh-schema assertions pin the trio on `chat_transcript_items` and its
  absence on `chat_messages`.
- `ChatIDPersistenceTests` pins the migrated `chat_transcript_items` shape.
- `MessageSummaryTests`, `StoreEmissionTests`, `DaemonChatHostTests` round
  trips move to the cursor-keyed API and durable-transcript seeding.
- The strip-behavior tests (`staleCachedWarningCannotReappearInOutline`,
  the rowTitle warning test) are deleted with the strips.
- `ChatAPISignatureManifestTests` manifest updated to the cursor-keyed
  `updateMessageSummary` signature (the reviewed chat API boundary moved
  with the change).

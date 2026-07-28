---
timestamp: 2026-07-25T151656Z
title: "fix: Chat summary abbreviated even when a summarizer model was pinned"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: Chat summary abbreviated even when a summarizer model was pinned

## Progress


**Goal:** the chats-list row subtitle was always a truncated first sentence
ending in `…`, even with a summarizer model pinned. Eliding is only correct for
the Default "text shortener"; a summary the model already wrote should be stored
as-is.

**Root cause:** two summary surfaces had diverged. `chat_messages.summary` (the
per-turn outline entries, chat-summary plan) dispatches on
`stageProviderIds["summarizer"]` and stores model output verbatim — that path was
fine. `chats.summary` (issue #411, the row subtitle) was written by a *separate*,
older path: `AgentLauncher.generateChatSummary()` → `firstSummaryText(from:)` →
`ChatSummary.summaryExtract(from:maxLength: 60)`, unconditionally, with no
knowledge of the summarizer mode. The chat-summary plan had flagged this
explicitly as out of scope ("a separate, already-shipped truncation; leave it
unless the operator wants to unify" — `plans/chat-summary.md:116`). Worth naming:
`chats.summary` is *not* a summary of the conversation — it is the gist of the
opening answer only, since `firstSummaryText` stops at the first assistant event
and a resumed run seeds `events = historySeed`, pinning it to the original
response forever.

**What changed:** unified the two — `chats.summary` now MIRRORS the first
summarizable message's `chat_messages.summary`, so it inherits that summarizer's
mode (Default ⇒ truncated extract, Model ⇒ the model's sentence verbatim) and
costs zero extra model calls. New pure `MessageSummarizer.chatSummaryMessageID(in:)`
picks the source message; both hosts write the chat row alongside the message row.
The launcher's rival path is **removed**, not bypassed — `generateChatSummary()`,
`firstSummaryText`, `summarySink`, `summaryGenerated`, and the `onSummary`
parameter are gone. Leaving it alive would have raced: the launcher fires each
run and would overwrite a model summary with a truncated one on the next turn.

**Behavior note:** in Default mode the subtitle now comes from the per-message
extract (`maxLength: 200`) instead of 60. The only consumer is the chats-list
subtitle, a single-line `NSTextField` with `lineBreakMode = .byTruncatingTail`,
so it clips to row width at draw time either way. Existing chats keep their old
truncated summary until their next turn, when the first message is summarized and
mirrors over it.

**Files:** `Sources/WikiFSEngine/{MessageSummarizer,AgentLauncher,AgentOperationRunner}.swift`,
`Sources/wikid/DaemonChatHost.swift`; `Tests/WikiFSTests/ChatSummaryTests.swift`.

## Verification

Historical verification remains in the progress record above.

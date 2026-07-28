---
timestamp: 2026-07-25T181956Z
title: "fix: Chat transcript froze mid-stream and bled messages between chats"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: Chat transcript froze mid-stream and bled messages between chats

## Progress


**Goal:** three reported symptoms — a live chat's responses never appeared as
they streamed; switching to another pane and back made them all appear at once;
and messages from one chat showed up inside another just by clicking between
them.

**Root cause:** one bug, in view identity. `WikiDetailView.detailContent`
renders every chat from the same `switch` branch (`case .chat(let id)`), and a
differing associated value does **not** change SwiftUI structural identity — so
chat A → chat B reused a single `ChatDetailView` instance and, under it, a
single `ChatWebView` `WKWebView` + `Coordinator`. That coordinator renders
*incrementally* (it appends only `events[renderedCount...]` so an in-progress
text selection survives streaming), and its anchors — `renderedCount`,
`renderedEvents`, `renderedLastEvent` — described whichever chat was rendered
last. What you saw depended entirely on how the two chats' event counts
compared: B larger ⇒ B's tail spliced onto A's DOM; B equal ⇒ A's transcript
with one row swapped; B smaller ⇒ a full reload, which looked correct. Landing
on a chat with a stale-high `renderedCount` also froze streaming outright —
`count > renderedCount` never became true, so `appendRows` never fired even
though events were reaching the model. Switching to a *page* tab is a different
`_ConditionalContent` branch, which tore the view down and rebuilt it — the
"click another pane and come back" workaround.

**What changed:** `ChatWebView` gained a `transcriptID` input and rebuilds when
it changes. The three rebuild triggers (identity change, `showsInternals`
toggle, count decrease) are now one pure `nonisolated static needsFullReload`,
testable without a WebKit view tree. The identity check runs *before* the
`isLoaded` guard so a switch landing mid-load also replaces `pendingEvents` —
otherwise `didFinish` would render the previous transcript and seed
`renderedCount` from it. `ActivityWindowView` was the same bug class (selecting
a different queue item reused the coordinator) and passes `.queueItem(item.id)`.
`WikiDetailView` also puts `.id(chatID)` on the chat surface: the transcript fix
alone left the `@State` leak, where `persistedMessages` rendered under the wrong
chat's title and `attachments`/`queuedMessages` would fire on the *next* chat's
turn.

**`TranscriptID` is a namespaced enum**, not a `String` — chat rows and queue
items are both ULIDs, so a raw-string key would let a collision read as "same
transcript", the exact failure the field exists to prevent. Pinned by a test.

**Ruled out:** the `ChatRunState` FSM (#912) was the initial suspect, since it
converted five stored run flags into computed shims and computed properties are
a classic observation trap. It is not implicated — `withObservationTracking`
around `activeChatID`/`isRunning` fires correctly, because the `@Observable`
macro tracks the stored `runState` the getters read.

## Verification

Historical verification remains in the progress record above.

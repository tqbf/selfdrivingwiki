---
timestamp: 2026-07-09T060600Z
title: "2026-07-08 — #275: Conversation view layout parity with PageDetailView"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — #275: Conversation view layout parity with PageDetailView

## Progress


PR #275 (`conversation-zoom-header-fix`) brings the conversation surface's
header, outline, and content layout in line with `PageDetailView` so the two
detail surfaces read as siblings.

**What shipped (7 commits on top of the branch):**
- **Zoom fix** — `ConversationView`'s zoom consumer wiring was dropped in an
  earlier change; re-added `@AppStorage("conversation.zoom")` +
  `.zoomShortcuts`/`.zoomScroll`, `zoom:` flows to both transcript web views,
  and the composer font scales too.
- **Title + date header for live chats** — live conversations had no header
  (only persisted chats did). Added the shared `header(for:)` + divider to the
  live view. Title restyled to `.largeTitle` to match page/source detail.
- **Left margin** — left-aligned transcript + composer at
  `PageEditorMetrics.contentInset` (12pt) instead of a centered 900pt column.
  Removed dead `conversationHorizontalInset`.
- **Header restructured to VStack** — the outline toggle was floating at the
  top-right corner (`HStack(.top)` + `Spacer`). Restructured to a `VStack`
  matching `PageDetailView`: title → metadata row → button row.
- **Show in List button** — added `sidebar.left` button calling
  `store.requestSidebarReveal(.chat(chatID))`; shown only for persisted/live
  chats (hidden in the draft `.ask`/`.edit` state).
- **Draggable outline** — `ChatOutlineView` now mirrors `PageOutlineView`:
  draggable divider with resize cursor, dynamic width via
  `@AppStorage("chatOutlineWidth")`, `.windowBackgroundColor`.
  `withChatOutline` stretches content to `.infinity` so the outline sits flush
  against the right window edge.
- **Full-width content** — removed the 900pt `chatColumnWidth` cap (live +
  persisted transcript, composer, editing banner). All now fill available
  width like `PageDetailView`.
- **Transcript CSS cleanup** — `body { padding: 10px }` → `padding: 10px 0`
  (vertical only) to stop double-stacking horizontal padding with the SwiftUI
  `.padding(.horizontal, 12pt)`.
- **Full-width agent bubbles** — changed `.chat-row .bubble` max-width
  selector to `.chat-user .bubble` so only user messages are capped at
  `min(760px, 86%)`. Agent responses fill the width, eliminating the
  perceived right-margin gap when reading agent text.

**Files touched:** `Sources/WikiFS/ConversationView.swift`,
`Sources/WikiFS/AgentTranscriptWebView.swift`.

## Verification

Historical verification remains in the progress record above.

---
timestamp: 2026-07-10T060009Z
title: "2026-07-10 — Remove read-only Ask/Plan chat mode"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-10 — Remove read-only Ask/Plan chat mode

## Progress


**Change:** the dual Ask (read-only) / Edit (write-capable) chat product
surface collapsed to a single always-write-capable chat. The read-only "Ask"
seatbelt is no longer wired to the chat path.

- `ChatKind.ask` removed — only `.edit` remains (vestigial enum + `chats.kind`
  column retained for a future always-ask/yolo distinction).
- v28→v29 data-only migration: `UPDATE chats SET kind = 'edit' WHERE kind =
  'ask'`. Fresh DBs are unaffected (no chat rows). `user_version` head is now 29.
- `WikiSelection.ask` / `.edit` → single `.newChat` draft case.
- Dual launchers (`askLauncher` / `editLauncher`) collapsed to one
  `chatLauncher` across `WikiFSApp`, `RootView`, `ContentView`,
  `WikiDetailView`, `SidebarView`, `AgentToolsView`.
- `QueryMode` enum deleted; `ChatView` takes `chatID: PageID?` only.
- `AgentLauncher.startInteractiveQuery` no longer takes `allowWikiEdits` —
  always uses the write sandbox (`resolveSandboxInvocation`), `isReadOnly:
  false`.
- `selectQuerySandbox` + the `allowWikiEdits == false` read-only branch in
  `queryChatPrompt` removed from the call path (the prompt always includes
  `IngestWriteRule.writes`).
- `AgentOperationRunner.startChat` / `continueChat` always create `.edit`
  chats and always take the edit lock; `shouldBlockEditStart` no longer takes
  `allowWikiEdits`.
- `SandboxProfile.generateReadOnly` / `readOnlyInvocation` retained in-tree
  deliberately (unwired, not deprecated) — the read-only seatbelt code stays
  for reference.
- `WikiOperation.queryChat` keeps `allowWikiEdits: Bool = true` for signature
  stability; the chat path always constructs it with `true`.

**Tests:** `QuerySandboxSelectionTests` + `QueryModeTests` deleted (functions
gone). `OperationCommandTests`, `Issue235IngestExtractionLockTests`,
`EditorTabTests`, `ChatViewD2Tests`, `ChatTranscriptRendererTests`, and
schema-version assertions across ~12 suites updated. New
`migrateV28ToV29RewritesAskChatsToEdit` test added.

## Verification

Historical verification remains in the progress record above.

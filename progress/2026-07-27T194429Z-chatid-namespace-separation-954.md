---
timestamp: 2026-07-27T194429Z
title: "2026-07-27 — ChatID namespace separation (#954)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-27 — ChatID namespace separation (#954)

## Progress


**Scope.** This branch introduces a public `ChatID` namespace for persisted
chat entities and migrates internal chat APIs away from chat-valued `PageID`.
The raw ULID text, SQLite schema, JSON/XPC payloads, File Provider outputs,
wiki links, provenance strings, paths, and CLI behavior must stay unchanged.

**What landed.**
- Added `Sources/WikiFSTypes/ChatID.swift` as the public persisted-chat
  namespace. It matches the legacy raw `String` storage and primitive-string
  Codable shape previously carried by chat-valued `PageID`.
- Converted persisted chat identity surfaces to `ChatID`, including
  `ChatSummary.id`, `ChatMessage.chatID`, `WikiSelection.chat`,
  `BookmarkNode.Content.chat`, `TranscriptID.chat`, `ChatSessionKey.chat`,
  chat store protocols, GRDB row decoding/binding, daemon request/reply
  payloads, app coordinator/session routing, File Provider chat lookups, CLI
  chat selectors, and chat wiki-link canonicalization.
- Preserved the deferred message namespace exactly as planned:
  `ChatMessage.id` stays `PageID`, and summary/update APIs that target a chat
  message still use `messageID: PageID`.
- Preserved compatibility boundaries exactly: SQLite table layout and stored
  ULID text did not change; XPC/daemon JSON keys stayed the same; File Provider
  item identifiers and `chats/` projection paths stayed raw-string-compatible;
  `[[chat:<ULID>|...]]`, provenance `chat:<ULID>`, CLI syntax/output, and
  agent-facing raw IDs stayed unchanged.
- Added enforcement suites:
  `ChatIDTests`, `ChatXPCRequestCompatibilityTests`,
  `ChatAPISignatureManifestTests`, and extended
  `IdentifierBoundaryTypecheckTests` with page/source/chat pairwise rejection
  fixtures.

**Implementation review.**
- Review pass 1 found three concrete follow-ups and they were fixed on-branch:
  `DaemonQueueEventSink` still used an IUO continuation init pattern
  (`make lint` failure), `WikiLinkRewriter` / GRDB's locked chat-title resolver
  still carried chat IDs as `PageID`, and the downstream fuzz/canonicalizer
  fixtures still reused page resolvers for chat links.
- Review pass 2 re-ran the verification gates after those fixes. No further
  findings remained.
- Review follow-up 3 added the last two HIGH coverage fixes before merge:
  `ChatIDPersistenceTests` now build a literal pre-#957 SQLite fixture at
  `PRAGMA user_version = 45` before opening `GRDBWikiStore`, and the chat API
  manifest/typecheck coverage now pins public launcher signatures plus typed
  handoff seams in `AgentOperationRunner`, `DaemonChatHost`, and
  `AgentToolsView`.

**Final `PageID` / raw-string audit.**
- Retained message identity by design:
  `ChatMessage.id: PageID`, `MessageSummarizer.chatSummaryMessageID(in:)`,
  `chatSummaryMessageID` plumbing in `AgentOperationRunner` and
  `DaemonChatHost`, and `messageID: PageID` parameters on chat-summary update
  paths.
- Raw compatibility boundaries by design:
  `WikiDaemonProtocol` string chat arguments, `wikid/main.swift` string XPC
  entry points, `wikictl/main.swift` daemon chat subcommand args, raw
  `AgentLauncher.activeChatID` / run-folder helpers / `WIKI_AUTHOR` plumbing,
  and `PageAuthor.chat(String)`.
- Legacy characterization fixtures by design:
  `PageIDLegacyCodableCharacterizationTests` still models pre-refactor chat
  payloads with `PageID`.
- No remaining persisted-chat entity API was left typed as `PageID`, and no
  untagged internal `String` remained except the documented raw boundaries
  above.

**Verification.**
- `make prompts` — passed.
- Focused chat boundary suite:
  `swift test --filter 'IdentifierBoundaryTypecheckTests|ChatAPISignatureManifestTests|ChatXPCRequestCompatibilityTests'`
  — 12 tests in 3 suites passed.
- Focused ChatID follow-up core verification:
  `swift test --filter 'ChatIDPersistenceTests|ChatAPISignatureManifestTests|IdentifierBoundaryTypecheckTests'`
  — 14 tests in 3 suites passed.
- `WIKIFS_APP_TESTS=1 swift test --filter 'AgentToolsD4Tests|ChatViewD2Tests|ACPChatResumeTests'`
  remains blocked by pre-existing unrelated app-test compile drift in the
  opt-in `WikiFSAppTests` target. That target is not part of the standard CI
  gate for this repository, so this follow-up branch does not broaden into
  app-test harness repair.
- `swift build --build-tests` — passed on the final tree.
- First `swift test` run hit three timeout-only failures in
  `AsyncProcessRunnerTests`
  (`cancellationEscalatesWhenChildIgnoresTermination`,
  `cancellationDuringOutputCleansUpOnce`,
  `cancellationReturnsWhenDescendantKeepsPipeOpen`).
- Focused flake check:
  `swift test --filter AsyncProcessRunnerTests` — 10 tests in 1 suite passed.
- Second `swift test` run — 2,530 tests in 197 suites passed on the final
  tree.
- `make lint` — 0 violations in 379 files; no new bare `try?`.
- `git diff --check` — clean.

## Verification

Historical verification remains in the progress record above.

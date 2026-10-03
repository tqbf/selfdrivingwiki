---
timestamp: 2026-10-03T220708Z
title: Chat-driven external writes now refresh the open wiki
branch: feature/wiki-strategies-cumulative-ingestion
status: complete
---

# Chat-driven external writes now refresh the open wiki

## Progress

A live chat (id `01M41RK6BT9VKFASJEA314EKSQ`, wiki `01M41BV9H7N34EAW18R7G9SQEP`)
ran `wikictl source add --url` and `wikictl source edit-markdown` through shell
tool calls. All writes landed in SQLite — sources
`01M41RP20QN06G4YRWGF4PS90D`, `01M41RPQ84H41HYR7PSWS7PTTK`,
`01M41RQ42ZZ59JJMDQ3NJE3NAY`, `01M41RQFY3QSXTTEKRAK45T254`, each with derived
markdown versions (origin `source`) plus agent-edited heads (origin `user`) and
blobs. The import did not fail.

What failed was the refresh. The app keeps `WikiStoreModel.sources` and the
memoized `WikiRenderContext` in memory and reloads them only from in-process
events. The chat's writes came from a CLI subprocess, so the app heard nothing:
the sources sidebar stayed without the new chapters, and the chat message's
`[[source:…]]` links rendered as unresolved ghosts. The citation spellings were
correct — `resolveSourceByName` pass 2 (extension-stripped) resolves them once
the store reloads, because the sanitized display name keeps the `.html`
extension while the citation drops it.

The app's designed cross-process channel (per-wiki Darwin notification →
`WikiChangeBridge` → coalesced bus poke) never delivered: the unified log shows
the bridge observing 7 wikis at launch (13:37:35 PDT) and zero receipts for the
whole retained window (Sep 26 – Oct 4), although the daemon posts a change
notification on every committed mutation (`WikiDaemon.wireEventBus`) and the
chat appended ~100 rows in that window. **Root cause inside that channel is not
proven.** Local probes of both sides passed: the installed `wikictl` posts
(caught with `notifyutil`), and a CF observer registered from a `@MainActor`
task inside an `NSApplication` run loop receives. The failure could sit in the
daemon-context post, in delivery, or in something not reproduced by the probes;
isolating it needs a live daemon-side write, which this investigation was not
allowed to run. Probes and fixture wikis are in `tmp/darwin-probe/`.

The fix does not depend on that channel. When a chat update carries a tool call
that reaches a terminal state (`completed`, `failed`, or `cancelled` — a shell
that fails or is stopped can still have committed part of its work), the
`ChatDaemonCoordinator` fires a hint through the same coalesced flush a Darwin
receipt would take (`WikiChangeBridge.noteSuspectedExternalWrite`), which pokes
the matching session's bus and reloads the on-screen model. Terminal-state
detection is once per tool call; ids are namespaced per chat and the set is
bounded (512 per chat) and cleared when the chat's mirror is discarded or the
coordinator stops. Live recorded transcripts confirm the shape: durable
tool-call rows carry `$.toolCall._0.status` with 103 `completed`, 1 `failed`,
and 2 `running` items in this wiki, so terminal items do persist in the
overlay-shaped vocabulary.

Recovery for the affected session needs no data repair — relaunch the app. The
sidebar reloads from SQLite at launch and the chat links then resolve and
navigate. Optionally, marking the four sources ingested (`wikictl log append
--kind ingest --source <id>`) would set their `ingested_at` flag, which the
chat never set; that flag affects only the ingested-status display, not
visibility or links.

Changed files: `ChatDaemonCoordinator.swift` (hint + per-chat bounded dedup),
`ChatDaemonCoordinatorHolder.swift` (re-wire the hint on every coordinator the
transport publishes), `WikiChangeBridge.swift` (`noteSuspectedExternalWrite`),
`WikiFSApp.swift` (wiring), `ChatConversationTypes.swift`
(`ChatToolCallStatus.isTerminal`), plus tests in
`ChatDaemonCoordinatorTests.swift`, `WikiChangeBridgeTests.swift`,
`WikiLinkStoreTests.swift`, and new `ChatExternalWriteRefreshTests.swift`.

## Verification

- `make build` — passed.
- Targeted, `WIKIFS_APP_TESTS=1 swift test --filter 'ChatDaemonCoordinatorTests|WikiChangeBridgeTests'`
  — 28 tests in 2 suites passed. New cases: terminal-status matrix
  (pending/running never fire; completed/failed/cancelled each fire once),
  per-chat id namespacing with a shared id, discard re-arms the hint, a
  recorded-shape wire JSON item decoded through the real `ChatTranscriptItem`
  Codable + versioned `ChatSyncUpdateEnvelope` + XPC envelope JSON roundtrip,
  and two hints coalescing into one flush.
- Targeted, `swift test --filter 'ChatExternalWriteRefreshTests|chatCitationWithoutExtensionResolves'`
  — 2 tests in 2 suites passed: extension-keeping display names resolve
  extension-less citations (pass 2), and a second store connection's write
  leaves the model stale until the bus poke, then the source list, render
  context, and click-time resolution all heal.
- Full suite, `caffeinate -i make test` — 4,368 tests in 452 suites passed
  (0 issues). One earlier run showed a single failure in
  `ReviewedExtractorOverlayTests.installedRevisionWinsOverTheBundledCopy`
  (extractor-package overlay, temp-directory fixture) which passes in
  isolation and is unrelated to this change; the re-run above was clean.
- Log evidence (reproducible queries):
  `log show --start "2026-10-03 13:37:00" --end "2026-10-03 23:59:00" --predicate 'subsystem == "com.selfdrivingwiki.debug"'`
  — "WikiChangeBridge: observing 7 wiki(s)" at 13:37:35.090 from the app
  (pid 50195); no "Darwin change notification →" receipts anywhere in the
  retained window.
- Live data was read read-only (`sqlite3 file:…?mode=ro`) against
  `~/Library/Group Containers/group.com.willsargent.wiki/01M41BV9H7N34EAW18R7G9SQEP.sqlite`.
  No writes were made to live wikis, and nothing was committed.

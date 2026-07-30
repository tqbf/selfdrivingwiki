---
timestamp: 2026-07-30T13:56:49Z
title: Chat presentation Phase 3 typed app projection
branch: chat-presentation-diagnostics-phase3
status: complete
---

# Chat presentation Phase 3 typed app projection

## Progress

Added app-only typed display rows, sections, turns, unattributed sections, and
namespaced row identities. `ChatDisplayProjection` consumes reconciled typed
transcript items and validated active-block metadata. It preserves input order
and row identities, keeps paged turns promptless, reports duplicate and
noncontiguous-turn anomalies, and rejects malformed or orphaned active blocks.

Migrated the app chat surface from `AgentEvent` and parallel timestamps to the
typed display transcript. The WebKit renderer is now an adapter from typed rows
at the final rendering boundary. Queue/activity-feed compatibility remains
separate from chat presentation.

Replaced RemoteChatSession launcher-era presentation booleans with
`ChatRunState` at app call sites. Outline entries now use durable turn and row
identities. Permission callbacks carry `ChatPermissionResolutionIntent` and
`PermissionOptionID`; raw option text and approval Boolean are constructed only
for the XPC request.

## Verification

Passed `WIKIFS_APP_TESTS=1 swift test --filter
'ChatDisplayProjectionTests|ChatPresentationAPIManifestTests|ChatDetailPresentationTests|RemoteChatSessionTests|ChatDaemonCoordinatorTests|Issue235IngestExtractionLockTests|ChatViewD2Tests'`:
71 tests in 7 suites.

Passed `make test`: 2,712 tests in 218 suites.

Passed `make build` after the final source edits; it produced a signed local
`Self Driving Wiki.app` with the File Provider enabled.

Passed `git diff --check` after the final source edits.

The hosted AppKit/WebKit gate did not run. This slice changes the typed
presentation contract and the renderer input adapter, not hosted interaction or
visual behavior; the applicable app target compiled and the projection/adapter
contracts are covered by the focused app-target suites.

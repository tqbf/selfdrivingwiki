# Daemon Phase A+B — Move the ENTIRE queue to `wikid` (extraction + ingestion + transcription)

**Status:** plan of record, ready to dispatch.
**Scope:** move the ENTIRE queue (extraction + ingestion + transcription) out of
the app process and into the launchd-managed `wikid` daemon. The app becomes a
pure XPC client. This MERGES Phase A (extraction) and Phase B (ingestion) per
**§12 Architecture Revision** (authoritative, supersedes the original Phase A-only
scope).
**Prerequisite:** Daemon Phase 0 (#831, merged) — XPC plumbing +
`QueueEngineClient` seam.
**Constraint:** every architectural claim cites `file:line`. `swift build` +
`swift test` clean. No tracked files modified except source + tests. Work on a
feature branch, never push to `main`.

**Tracks:** #846

---

## 0. Executive summary

Today the app constructs its own in-process `QueueEngine`
(`Sources/WikiFS/Window/WikiFSApp.swift:204`). Per §12, the daemon owns GRDB and
the ingestion queue. The daemon owns one `queue.sqlite` with the full
`QueueEngine` (extraction + ingestion + transcription workers). The app's
`XPCQueueEngineProxy` is a PURE PASS-THROUGH — all 13 `QueueEngineClient` methods
proxy to the daemon. No local engine, no snapshot merging, no split DBs.

This eliminates: RC1 (split databases — not needed, one owner), RC3 (proxy
dispatch rules with merge — not needed, pure pass-through), and the entire
extraction→ingestion cross-process coordination problem.

---

## §12. Architecture Revision (AUTHORITATIVE)

### ARCHITECTURE CHANGE: daemon owns the ENTIRE queue (extraction + ingestion)

**Operator directive:** the daemon should own GRDB and the ingestion queue. The
UI should be just sending commands back to the daemon for logic.

### RC1 [critical] — R6 RESOLVED: single owner, no split

The daemon owns `queue.sqlite` exclusively. The app does NOT construct a local
`QueueEngine`. `XPCQueueEngineProxy` proxies ALL methods to the daemon. One DB,
one engine, one owner — no `SQLITE_BUSY` races, no duplicate dispatch, no snapshot
merge.

### RC2 [critical] — AC.1/AC.2 MUST have automated integration tests

AC.1 and AC.2 get concrete integration tests using the existing XPC harness
(`WikiDaemonWorkloadHostTests.swift`):

- AC.1 → `testExtractionSurvivesClientDisconnect`: enqueue extraction via XPC,
  drop the client connection, assert the daemon's engine completes the item and
  writes markdown via `GRDBWikiStore`.
- AC.2 → `testSnapshotRehydratesAfterReconnect`: connect, enqueue, disconnect,
  reconnect, assert `queueSnapshot` shows the completed item.

### RC3 [superseded] — XPCQueueEngineProxy is now pure pass-through

ALL 13 `QueueEngineClient` methods proxy to the daemon. No dispatch rules, no
merge logic — every call goes to the daemon's `QueueEngine`. This is simpler
than the original plan.

### RC4 [high] — XPC error handling: add timeout + error envelope

All new XPC methods must:
1. **Always call `reply()`** — the daemon catches all throws inside the method
   body and calls `reply()` with a JSON `{id: String?, error: String?}` envelope
   (nil id = failure).
2. **Add a timeout** to `DaemonWorkloadClient` async wrappers (30s default).
3. **Serialize errors to strings** — the async wrapper decodes the envelope and
   throws a typed error (e.g., `DaemonXPCError.failure(String)`).

Add a test that verifies the async wrapper returns within a timeout when the
daemon throws.

### RC6 [medium] — Fix TOCTOU in DaemonQueueExtractionProvider

Read `current()` and `config` in a SINGLE `MainActor.run` block and return a
tuple.

### RC7 [medium] — DaemonQueueEventSink: use own AsyncStream

`QueueEventBroadcaster` does NOT exist as a reusable type — use its own
`AsyncStream<QueueEvent>` + continuation.

### RC8 [medium] — .acp backend: handled by daemon's own AgentLauncher

Since the daemon now owns ingestion too, it constructs its own `AgentLauncher`
with ACP backends (keychain sharing is resolved via #850). ACP extraction is no
longer deferred — the daemon can resolve `.acp` providers natively.

### RC9 [low] — localExtractorFactory RESOLVED: Option A (extract to WikiFSEngine)

`LocalPdf2MarkdownExtractor` imports ONLY `Foundation` + `WikiFSCore` — no
AppKit/PDFKit. Move the struct to `Sources/WikiFSEngine/` so the daemon can use
it.

### NEW: Daemon-side ingestion provider

The daemon needs its own `DaemonQueueIngestionProvider` (replacing
`AppQueueIngestionProvider`) that:
1. Talks to `GRDBWikiStore` directly (no `@MainActor WikiStoreModel`).
2. Constructs its own `AgentLauncher` with ACP backends (keychain resolved via
   #850). Provider resolution: `AgentProvidersConfig.loadOrSeed(from:)` from the
   app group container.
3. Uses `DarwinNotifier.postChange` for File Provider signaling (moved to
   WikiFSCore).
4. Does NOT use `SessionLookupBox` or `FileProviderBox`.

### NEW: App-side simplification

`WikiFSApp.swift:204` — delete the `QueueEngine` construction entirely. Replace
`session.queueEngine` with an `XPCQueueEngineProxy`. The app no longer needs
`AppQueueExtractionProvider`, `AppQueueIngestionProvider`, `SessionLookupBox`,
`FileProviderBox` for queue purposes.

### NEW: Transcription queue

Since the daemon owns the whole `QueueEngine`, transcription items also go to the
daemon. The daemon's `QueueEngine` handles all three QueueKinds (extraction,
ingestion, transcription) with real workers for each.

---

## Implementation order (suggested PR sequence)

1. **Move `DarwinNotifier` to `WikiFSCore`** (RC5). Small, isolated. Update
   `WikiCtlCore` import.
2. **RC9: Move `LocalPdf2MarkdownExtractor` to `WikiFSEngine`.** It only imports
   `Foundation` + `WikiFSCore`.
3. **Add `QueueEvent` / `ExtractionEventEnvelope` Codable.** Portable test.
4. **Add daemon-native `DaemonQueueExtractionProvider`** (RC6: single MainActor.run).
5. **Add daemon-native `DaemonQueueIngestionProvider`.**
6. **Add daemon-native `DaemonQueueTranscriptionProvider`.**
7. **Wire the real `CompositeWorkerFactory` into `WikiDaemon.ensureQueueEngine()`**,
   with real workers for ALL three QueueKinds. Add `pushQueueEvent`.
8. **Extend `WikiDaemonProtocol` + exporter + `DaemonWorkloadClient`** (RC4: reply
   always, 30s timeout, error envelope). XPC round-trip tests.
9. **Add `DaemonQueueEventSink`** (RC7: own AsyncStream) + `XPCQueueEngineProxy`
   (pure pass-through, all 13 methods).
10. **Flip `WikiFSApp.init`** to construct the proxy. Delete local `QueueEngine`.
11. **Integration tests** (RC2: AC.1/AC.2). Timeout test (RC4).

Each step should leave `swift build` + `swift test` green.

---

## Acceptance criteria

| AC | Description | Verification |
|----|-------------|-------------|
| **AC.1** | Extraction survives client disconnect. | `testExtractionSurvivesClientDisconnect` — automated. |
| **AC.2** | Snapshot rehydrates after reconnect. | `testSnapshotRehydratesAfterReconnect` — automated. |
| **AC.3** | `swift build` clean; `swift test` green. | From repo root. |
| **AC.4** | No tracked non-source/non-test files modified. | `git status`. |

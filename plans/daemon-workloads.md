# Daemon Workloads — Move Ingestion, ACP Execution, and Extraction into `wikid`

**Status:** findings + phased plan (architect). Phase 0 implementing.
**Goal:** make background ingestion, ACP agent execution, and extraction survive both
window-close *and* full app quit (`⌘Q`) by moving them out of the app process and into the
launchd-managed `wikid` daemon. This is the "keep the helper alive" pattern.
**Constraint:** this doc cites `file:line` for every architectural claim.

---

## 0. Executive summary

`wikid` is a launchd-managed `SMAppService.agent` that today exposes **registry + store
lifecycle** XPC only. The whole agent **engine** (`AgentLauncher`, `ACPBackend`,
`QueueEngine`, `ExtractionCoordinator`, …) is already extracted into the `WikiFSEngine`
library target, so the daemon *can* link and host it — it just doesn't yet. The app runs
everything **in-process** today.

The decisive facts that make this migration tractable:

1. **Store-write signaling does NOT need new XPC plumbing.** The store emits
   `ResourceChangeEvent` on a `WikiEventBus`, but that bus is **in-process only**.
   Cross-process signaling is already solved by a *different*, proven path: the writer calls
   `DarwinNotifier.postChange(forWikiID:)`, and the app's `WikiChangeBridge` re-emits a coarse
   `ResourceChangeEvent` onto the matching live session's bus. `wikictl` is already a second
   writer process that uses exactly this path. The daemon becomes a third writer. **No new
   store-event transport is required.**

2. **Fine-grained *live* events DO need a streaming channel** — chat `AgentEvent`s, queue
   `progress`/`transcript`/`liveUsage`. These are high-frequency and currently flow through an
   in-process `AsyncStream` (`QueueEventBroadcaster`). The solution is the standard
   **bidirectional XPC** pattern: a second `@objc` "event sink" protocol the app implements
   and registers as the connection's remote object, so the daemon pushes JSON-encoded events
   back. `AgentEvent` is already `Equatable, Sendable, Codable`, so it serializes cleanly.

3. **Quit currently *kills* the work.** `appDelegate.cancelInFlightForQuit = { await
   queueEngine?.cancelAllInFlight() }`. So the *current* `⌘Q` behavior is to cancel all
   in-flight ingestion/extraction. The daemon migration is what changes this: once the
   `QueueEngine` lives in the daemon, app quit no longer cancels its `Task`s.

The phasing is risk-ordered: **A = extraction** (subprocess-only, single store write, no live
`AgentEvent` streaming, no warm-session resume), **B = background ingestion** (agent spawn +
transcript streaming + `acpSessionId` resume), **C = interactive chat** (warm ACP session +
live reconnect + permission round-trip). Each phase is independently shippable.

---

## 7. Phasing

### Phase 0 — Foundation: XPC event sink + daemon workload host + proxy seam

**Scope (no behavior change; the app still runs in-process):**
1. Add `WikiDaemonEventSink` `@objc` protocol + `registerEventSink` to `WikiDaemonProtocol`.
2. In `listener(_:shouldAcceptNewConnection:)`, capture the connection's `exportedObject`
   (the app's sink) and store it per-connection on the daemon.
3. Add a daemon-side "workload host" scaffold: `WikiDaemon` gains the ability to construct a
   `QueueEngine` over the container's `queue.sqlite`. Don't wire callers yet.
4. Introduce a `QueueEngineClient` protocol in `WikiFSEngine` capturing the surface the app
   uses. Make the concrete `QueueEngine` conform. The app's `session.queueEngine` type widens
   to `any QueueEngineClient`.
5. `DaemonWorkloadClient` in `WikiCtlCore`: async wrappers over the XPC protocol, decoding
   JSON.

**Gate:** `swift build` clean; existing tests green; the daemon can construct a `QueueEngine`
and serve a no-op `queueSnapshot` over XPC. App behavior unchanged.

### Phase A — Extraction moves to the daemon (lowest risk)
### Phase B — Background ingestion moves to the daemon (medium risk)
### Phase C — Interactive ACP chat execution moves to the daemon (highest risk)

(Details for A/B/C in the original directive; not implemented in Phase 0.)

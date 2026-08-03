# Plan: Turn-Completion Recovery for a Hung `sendPrompt` (#615)

> **Status:** Implementation-ready (revised after plan-reviewer BLOCK). A Paseo
> agent should be able to implement from this document + the cited repo files
> alone. Every reviewer finding is addressed inline; a checklist of fixes is in
> §11.
> **Branch:** `feature/turn-completion-recovery` — never merge to `main` directly.
> **Issue:** https://github.com/tqbf/selfdrivingwiki/issues/615
> **Base commit:** `0a11416` (acp-perms, PR #614, just merged) — the plan is
> against current `main`.

---

## 1. Problem statement + root cause

### Symptom (from issue #615)

An interactive Claude (ACP) turn can hang **forever** (until the 1800s
`TurnLivenessPolicy` ceiling fires — ~30× longer than this turn's 3m14s) with
the chat UI stuck "generating": spinner running, send disabled, **no error
surfaced**, no `turn-N-response.json` written, no `summary.json` (the run is
abandoned, not completed).

The agent produces a **full, correct, costly answer** (in the repro, 3043 chars,
$1.36, ending on a final cost `usage_update`), but the `session/prompt` RPC
*result* never returns. The stream simply stops after the last `usage_update`.

### Root cause (file:line — all citations against `0a11416`)

Turn completion in `ACPBackend.send(_turn:into:)`
(`Sources/WikiFSEngine/ACPBackend.swift:614–789`) is gated **solely** on
`client.sendPrompt(...)` either returning or throwing:

- **Success path** (`:745–763`): `guard !completionFlag.isDone` →
  `completionFlag.markDone()` → `logPromptResponse(response, turn:)` (writes
  `turn-N-response.json`) → `turnEndEvents(error: nil)` → (falls through to)
  `continuation.finish()` at `:784`.
- **Catch path** (`:765–783`): `guard !completionFlag.isDone` →
  `completionFlag.markDone()` → `processHealth.markDied()` (`:775`) →
  `DebugLog.agent(...)` (`:776`) → `logPromptError(error, turn:)` (`:778`,
  writes error `turn-N-response.json`) → `turnEndEvents(error: error)` →
  (falls through to) `continuation.finish()` at `:784`.

**The gap:** when the `claude-agent-acp` subprocess exits / closes the transport
**after streaming a complete response but before the `session/prompt` `result`
returns**, the ACP SDK's `sendPrompt` **neither returns nor throws** — so
`promptTask` hangs forever. Consequences (all observed in the #615 repro):

- Neither `logPromptResponse` nor `logPromptError` runs → **no
  `turn-N-response.json`** (the bug is invisible in `debug/`).
- `continuation.finish()` (`:784`) never runs → the launcher's
  `for await event in stream` (`AgentLauncher.swift:2449`) blocks forever →
  `setGenerating(false)` (`:2453`, inside the `endsGeneration` branch) never
  fires → chat stays stuck "generating".
- `flushTranscript()` (`:2454`), `releaseGenerationSlot()` (`:2464`),
  `generateChatSummary()`, and the run's `finish()`/`summary.json` never run.

**Why the existing guards don't catch it:**

| Guard | Location | Why it misses this case |
|---|---|---|
| `sendPrompt` catch (process death) | `:765–783` | `sendPrompt` doesn't *throw* here — it just never resumes. |
| `onExit` callback | `:571–580` (bound), `permissionDelegate.bindOnExit` `:575` | Telemetry-only — "does NOT call `finish()` — the orchestrator owns `finish()`" (`:571–574`). Doesn't fail the turn. |
| Watchdog ceiling | `:645–675` (polls `TurnLivenessPolicy.evaluate`) | 1800s default (`TurnLivenessPolicy.swift:62`) is ~30× the turn's 3m14s, so it didn't fire in the repro. #551 removed idle/stall detection, leaving the ceiling as the *only* out. |

> **The drain loop** — there are **two** drain loops; this is load-bearing for the
> fix (reviewer's CRITICAL subtlety):
>
> 1. **Process-lifetime drain** (`:404–417`): iterates `client.notifications`
>    (the SDK's single-consumer stream) and calls `fanout.finish()` when that
>    stream ends (subprocess exit / transport close). This is the *source* of
>    the fanout's termination.
> 2. **Per-turn drain** (`:689–734`): iterates `fanout.subscribe()` — a per-turn
>    subscription onto the process-lifetime fanout. This is the `drainTask` that
>    lives inside `promptTask` (`:690`) and is cancelled by `defer { drainTask.cancel() }` (`:735`).
>
> **The per-turn drain loop ends in two distinct cases:**
> - **Cancelled** (`Task.isCancelled == true` after the `for await`): the normal
>   path. `sendPrompt` returned → success/catch ran `markDone()` → `defer {
>   drainTask.cancel() }` fired (`:735`). The `for await` exits because the task
>   was cancelled, NOT because the stream finished.
> - **Fanout finished** (`Task.isCancelled == false` after the `for await`): the
>   failure path. The process-lifetime drain (`:416`) called `fanout.finish()`
>   because `client.notifications` ended (transport closed / process died), so the
>   per-turn subscription's `for await` completes naturally. `sendPrompt` is still
>   suspended — this is the #615 hang.
>
> **The grace timer must arm ONLY in the fanout-finished case, never the
> cancelled case.** `Task.isCancelled` after the per-turn drain loop is the
> concrete disambiguator (see §3). In the normal case the per-turn subscription
> does NOT finish until process death/cancel, so drain-loop-end-via-fanout-finish
> only occurs in the failure case.

### Relationship to prior work

- **Reproduces/regresses #334** (closed via #335/#337 Phase 1/3 watchdog
  escalation; #551 then removed the idle/stall recovery). The class is *not*
  actually fixed — the #615 trace reproduces after all of those landed.
- **Distinct** from the in-flight empty-response investigation
  (opencode / no-model empty stream): here the agent produced a *full* response.
- Upstream context: `agentclientprotocol/claude-agent-acp` #338
  ("Claude CLI subprocess death leaves session permanently broken").

---

## 2. Scope

**In scope:** Add a **drain-end grace timeout + `markDied()` recovery** so a
hung `sendPrompt` (subprocess exited/closed transport after streaming but before
the `session/prompt` result) gets failed cleanly:

1. Detect: after the per-turn drain loop ends via **fanout-finish** (NOT via
   cancellation) with `completionFlag.isDone == false`, arm a short grace timer.
   The fanout-finish-via-cancel distinction is `Task.isCancelled` (§3).
2. Recover (if the timer wins the race): `processHealth.markDied()`,
   `logPromptError(.processDiedBeforeResult, turn:)` so a `turn-N-response.json`
   (error variant) is always written, yield `turnEndEvents(error:)`, and
   `continuation.finish()` so `AgentLauncher.swift:2452`'s `endsGeneration`
   fires → `setGenerating(false)` (`:2453`), `flushTranscript()`, slot release.
3. New `ACPBackendError.processDiedBeforeResult` case, distinct from
   `.processDied`, with an actionable operator-facing message.

**NOT in scope:**
- ⛔ Lowering the 1800s ceiling (#609 is a follow-up — do **not** change
  `TurnLivenessPolicy.defaultCeilingTimeout` or the watchdog path).
- ⛔ Live-process-exit detection beyond the drain loop (no new `Process`
  termination-handler wiring, no `kill(pid,0)` polling).
- ⛔ Re-adding #551's removed idle/stall detection.
- ⛔ No SQLite / store changes. No `StoreEmissionExhaustivenessTests` impact (the backend is
  not a `SQLiteWikiStore` mutator; it does not route through `mutate(event:_:)`).
- ⛔ No changes to `AgentLauncher` (the recovery flows entirely through the
  existing `endsGeneration` contract the launcher already keys off).
- ⛔ No protocol extraction over the SDK `Client` — it is a concrete `public
  actor` from the external `swift-acp` package; abstracting it is a major
  refactor out of scope here (see §7 test-infrastructure gap).

---

## 3. Concurrency invariant + wiring (the hard part)

> **Addresses reviewer CRITICAL** (grace timer armed at turn start) and
> **MEDIUM** (mirrors-#614 framing was loose).

### The rule

**Exactly ONE resume (here: exactly one `continuation.finish()`) per turn.**
`AsyncStream.Continuation` tolerates a second `finish()`, but the load-bearing
risk is that the *grace timer fires and yields error events + finishes* **while
`sendPrompt` is concurrently returning** (success at `:745–763`) or **throwing**
(catch at `:765–783`). A double-completion would either:
- yield a spurious `.turnFailed` after a real `.messageStop`
  (→ launcher shows a ghost error), or
- yield a duplicate `setGenerating(false)` path / orphaned events.

The existing code already defends the success-vs-catch-vs-watchdog race with a
single `completionFlag` (`TurnCompletionFlag`, `:630`, `:1832–1844`): every
terminal path does `guard !completionFlag.isDone else { return }` →
`completionFlag.markDone()` → then yields. **The grace timer must join this exact
discipline** — it is a fourth racer alongside the three already in `send`.

### The committed approach: detached timer that mirrors #614's *discipline* (not its storage)

PR #614 (`ACPPermissions.swift:447–495`) shipped a **detached `Task` timer** with
the race-safety pattern: `removeValue`-under-the-lock-then-resume-after-unlock.
`resolve`/`cancelAllPending`/`timeOut` cancel the stored timer on the winning
side, and the timer is **stored on shared mutable state** in a
`Pending(timer:)` struct (`:476–483`).

**This plan intentionally diverges from #614's storage shape** and the
divergence is explicit (not an oversight):

- The grace timer is a **local `graceTimer: Task`** in `promptTask`, NOT stored in
  a shared-lock holder. It is cancelled in **three** places:
  1. `defer { graceTimer.cancel() }` — fires on `promptTask` return (covers the
     normal success/catch path).
  2. **Explicit `graceTimer.cancel()` immediately after `completionFlag.markDone()`**
     in BOTH the success path (`:757`) and the catch path (`:769`). **This is the
     DEFAULT, not an optional "if worried"** — it ensures the timer is cancelled
     promptly the moment a real winner is known, rather than waiting for the
     `defer` to run at `promptTask` exit (which is after `continuation.finish()`
     at `:784`).
  3. `graceTimer.cancel()` in `continuation.onTermination` (`:789–798`) — the
     consumer-cancel bridge (stopAgent), alongside `promptTask.cancel()`/
     `watchdogTask.cancel()`.
- **Why local + explicit cancel is safe (and sufficient) here, unlike #614's
  shared-storage requirement:** #614 guards a **`CheckedContinuation`**, where a
  double-resume traps the process — so the timer MUST be pulled out of shared
  state under the same lock that guards resumption, to make double-resume
  structurally impossible. Here the continuation is an
  **`AsyncStream.Continuation`**, which tolerates a second `finish()`; the
  invariant is enforced by the `completionFlag` (`NSLock`-atomic check-then-mark),
  not by storage shape. So a local timer + the `completionFlag` guard + explicit
  cancellation is the correct, minimal design. The belt-and-suspenders is the
  `guard !completionFlag.isDone` inside the timer body (if it wakes racing a
  cancel, it no-ops).

### Skill cross-check

`docs/skills/swift-concurrency-pro/references/bug-patterns.md` §"Continuation
resumed twice" (>Fix): *"Restructure the callback wiring so only one path can
reach the continuation. If that isn't possible, guard with a `Bool` flag or use
an `actor` to serialize access. Always default to `CheckedContinuation` so
double resumes surface immediately."*

Here the "callback wiring" is the four terminal paths in `send`; the existing
`completionFlag` (`NSLock`-guarded `Bool`) is exactly that guard. The grace
timer reuses it. `AsyncStream.Continuation` differs from `CheckedContinuation`
(it tolerates a second `finish()`), but the *invariant* — only the first
winner yields events + finishes — is what prevents the spurious-error/duplicate
symptom. Treat it as a hard correctness property, not a nicety.

### Concrete wiring (sketch — not final code)

> **The grace timer is armed AFTER the per-turn drain loop ends via fanout-finish,
> NOT at turn start.** The timer body does NOT do `await drainTask.value` as its
> first action (that would still arm at drain-task-start). Instead, the arming is
> structurally placed **inside the drain task's post-`for-await` exit path**,
> gated by `!Task.isCancelled`. This is the concrete mechanism that ensures the
> timer NEVER fires while notifications are still flowing (reviewer CRITICAL
> fix). §3 sketch is authoritative for all cancel-bridge wiring; if `§5a` reads
> as abridged, §3 wins.

```swift
// Inside promptTask, captured: completionFlag, processHealth, debugLogger,
// debugTurn, client, sessionId, continuation, drainGraceTimeout (new), fanout.
let liveUsageCB = self.liveUsageCallback
let updates = fanout.subscribe()    // :689

let drainTask = Task {
    for await notification in updates {           // :691 — per-turn subscription
        if Task.isCancelled { return }            // :692
        // ... :694-732 unchanged (logUpdate, translate, yield, usage capture) ...
    }
    // ── Drain loop exited. Distinguish WHY (reviewer CRITICAL subtlety): ──
    if Task.isCancelled { return }   // CANCELLED = normal turn end
        // (sendPrompt returned → success/catch marked done → defer cancelled us).
        // Do NOT arm the grace timer — notifications were still flowing fine.
    // NOT cancelled = FANOUT FINISHED naturally (process-lifetime drain :416
    // called fanout.finish() because client.notifications ended = transport
    // closed / process died). sendPrompt is STILL suspended → #615 failure case.
    // Arm the grace timer ONLY here (inside the post-loop path, after we've
    // confirmed fanout-finished-not-cancelled).
    let recovery = TurnRecoveryGrace(              // §3a: concrete seam type
        completionFlag: completionFlag,
        continuation: continuation,
        processHealth: processHealth,
        drainGraceTimeout: drainGraceTimeout,
        debugLogger: debugLogger,
        debugTurn: debugTurn)
    await recovery.arm()    // sleeps drainGraceTimeout, then recovers IFF still
                            // pending. Returns early on cancellation (success/
                            // catch/stopAgent cancelled the timer first).
}
defer { drainTask.cancel() }   // :735 — unchanged

// The grace timer is a STRUCTURAL CHILD of the drain task (armed from inside
// its post-loop path), so `defer { drainTask.cancel() }` transitively cancels
// `recovery`'s internal Task.sleep on the normal path. But for promptness we
// ALSO cancel explicitly at the win sites (below).

do {
    DebugLog.agent("ACPBackend: sending session/prompt (\(promptText.count) chars)")
    let response = try await client.sendPrompt(/* :739-742 unchanged */)
    // :746-753 usage capture unchanged
    guard !completionFlag.isDone else { return }   // :756
    completionFlag.markDone()                       // :757
    graceTimerHolder?.cancel()   // ★ explicit cancel — DEFAULT, not optional
    DebugLog.agent("ACPBackend: prompt completed stopReason=\(response.stopReason.rawValue)")
    if let debugTurn { debugLogger?.logPromptResponse(response, turn: debugTurn) }  // :759-761
    for event in Self.turnEndEvents(error: nil) { continuation.yield(event) }         // :762-764
} catch {
    guard !completionFlag.isDone else { return }   // :768
    completionFlag.markDone()                       // :769
    graceTimerHolder?.cancel()   // ★ explicit cancel — DEFAULT, not optional
    processHealth.markDied()                        // :775
    DebugLog.agent("ACPBackend: prompt failed: \(error.localizedDescription)")       // :776
    if let debugTurn { debugLogger?.logPromptError(error, turn: debugTurn) }          // :777-778
    for event in Self.turnEndEvents(error: error) { continuation.yield(event) }       // :780-782
}
continuation.finish()   // :784 — unchanged
```

> **Note on the `graceTimerHolder` reference in the do/catch:** because the timer
> is created *inside* the drain task (post-loop), it is not in scope at the
> `do/catch` site. Two clean options for the explicit cancel-from-win-site:
> - **(i)** Store the `Task<Void, Never>` in a small `@unchecked Sendable`
>   holder (e.g. `final class TaskRef<T>: @unchecked Sendable { var task: T? }`)
>   captured by both the drain task (sets it when it arms) and the do/catch
>   (cancels it). This mirrors #614's `Pending(timer:)` storage-on-shared-state
>   most closely.
> - **(ii)** Rely on `drainTask.cancel()` (from `defer` + `onTermination`)
>   transitively cancelling the recovery's internal `Task.sleep`, and drop the
>   explicit `graceTimerHolder?.cancel()` lines. The `guard !completionFlag.isDone`
>   inside `recovery.arm()` makes this *correct* (double-finish is tolerated +
>   the guard no-ops), but it leaves the timer sleeping up to `drainGraceTimeout`
>   after success — acceptable at 3s but less crisp.
>
> **Commit to (i)** — the small holder — so the timer is cancelled *promptly* at
> the win sites, matching #614's "cancel the stored timer in `resolve`" most
> faithfully and avoiding a lingering 3s timer after every successful turn. The
> holder is constructed before the drain task and captured by it; the drain task
> sets `holder.task = Task { … }` when it arms, and the do/catch + onTermination
> call `holder.cancel()`.

**Full sketch with the holder (authoritative):**

```swift
// holder for the recovery timer — set by the drain task's post-loop path,
// cancelled by the success/catch/onTermination paths (mirrors #614 Pending.timer).
final class RecoveryTimerRef: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Never>?
    func set(_ task: Task<Void, Never>) { lock.lock(); _task = task; lock.unlock() }
    func cancel() { lock.lock(); _task?.cancel(); _task = nil; lock.unlock() }
}
let recoveryRef = RecoveryTimerRef()

let drainTask = Task {
    for await notification in updates {
        if Task.isCancelled { return }
        // ... :694-732 unchanged ...
    }
    if Task.isCancelled { return }   // normal turn end — DON'T arm
    // fanout finished, prompt still pending → #615 failure. Arm recovery:
    let recovery = TurnRecoveryGrace(
        completionFlag: completionFlag, continuation: continuation,
        processHealth: processHealth, drainGraceTimeout: drainGraceTimeout,
        debugLogger: debugLogger, debugTurn: debugTurn)
    let t = Task { await recovery.arm() }
    recoveryRef.set(t)
    await t.value   // let the recovery run (it returns early on cancel)
    // Mirror the watchdog ceiling path (ACPBackend.swift:671): send cancelSession
    // so the SDK unblocks the suspended sendPrompt. Without this, the catch path
    // never runs (sendPrompt never returns), promptTask leaks holding strong refs
    // (client, sessionId, fanout, etc.) — a resource leak. If cancelSession
    // unblocks sendPrompt (even on a dead transport), the catch path's
    // `guard !completionFlag.isDone` no-ops (recovery already marked done) and
    // promptTask exits cleanly.
    try? await client.cancelSession(sessionId: sessionId)
}
defer {
    drainTask.cancel()
    recoveryRef.cancel()   // belt-and-suspenders teardown of the timer
}

do {
    let response = try await client.sendPrompt(/* :739-742 */)
    // ... :746-753 usage ...
    guard !completionFlag.isDone else { return }
    completionFlag.markDone()
    recoveryRef.cancel()                     // ★ explicit cancel at win site
    // ... :758-764 log + turnEndEvents + yield ...
} catch {
    guard !completionFlag.isDone else { return }
    completionFlag.markDone()
    recoveryRef.cancel()                     // ★ explicit cancel at win site
    // ... :775-782 markDied + log + turnEndEvents + yield ...
}
continuation.finish()   // :784
```

And in the **`continuation.onTermination`** cancellation bridge (`:789–798`),
add `recoveryRef.cancel()` alongside the existing cancels:

```swift
continuation.onTermination = { @Sendable reason in
    if case .cancelled = reason {
        promptTask.cancel()
        watchdogTask.cancel()
        recoveryRef.cancel()   // ★ new — tear down the grace timer on stopAgent
        Task { [client, sessionId] in
            try? await client.cancelSession(sessionId: sessionId)   // :794 — existing
        }
    }
}
```

**Key race-safe properties of this wiring:**

1. **Timer NEVER arms while the drain loop is active (notifications flowing).**
   Arming is structurally inside the drain task's post-`for-await` path, gated by
   `!Task.isCancelled`. On a normal streaming turn that takes >3s, the drain loop
   is still iterating (the process is alive, fanout unfinished) — the post-loop
   code is unreachable, so the 3s timer is never even created. This directly
   fixes the reviewer's CRITICAL regression (the previous sketch armed at turn
   start and would have killed every >3s turn with a spurious
   `.processDiedBeforeResult`).
2. **Single source of truth:** `completionFlag.markDone()` is the atomic "I won"
   token. Every terminal path (success, catch, watchdog ceiling, grace timer)
   does `guard !completionFlag.isDone else { return }` *first*, then `markDone()`.
   The `NSLock` inside `TurnCompletionFlag` serializes the check-then-mark, so
   exactly one path sees `isDone == false` and proceeds.
3. **Never resolve under a lock:** the grace timer reads the flag, marks done,
   and only *then* (after the lock is released) yields + finishes — matching
   #614's "removeValue under the lock, resume after."
4. **Cancellation on the winning side:** success and catch do
   `recoveryRef.cancel()` immediately after `markDone()` (this plan's DEFAULT);
   `defer` and `onTermination` also cancel. Even if the timer wakes racing a
   cancel, the `guard !completionFlag.isDone` catches it — belt-and-suspenders.
5. **Watchdog ceiling is also safe:** it does `completionFlag.markDone()` at
   `:666` before yielding. If the ceiling fires first, the grace timer's later
   `guard` no-ops. If the grace timer fires first, the watchdog's next poll sees
   `completionFlag.isDone == true` via `TurnLivenessPolicy.evaluate` → `.healthy`
   → continue, which is fine (it just spins down). The watchdog is cancelled by
   `continuation.onTermination` (`:789–798`), same as today.

### §3a. The `TurnRecoveryGrace` seam (concrete — addresses reviewer MEDIUM)

> The previous plan referenced an underspecified `TurnRecoverySeam` with
> `arm()`/`cancel()`/`processHealth` that didn't exist. This section commits to
> the concrete type. **Strategy (A) is committed** — no "(A)/(B) pick at
> implementation time" ambiguity.

**Name:** `TurnRecoveryGrace`

**Where it lives:** `private` (file-scope) `struct` in `ACPBackend.swift`, next to
`TurnCompletionFlag` (`:1832`) and `ProcessHealthFlag` (`:1852`). It mirrors the
"pure logic extracted as a static/standalone type" shape of
`ACPBackend.turnEndEvents(error:)` (`:1521`).

**Inputs (all `Sendable`):**
- `completionFlag: TurnCompletionFlag` — the per-turn atomic win token.
- `continuation: AsyncStream<AgentEvent>.Continuation` — the stream to finish.
- `processHealth: ProcessHealthFlag` — set `.markDied()` on recovery.
- `drainGraceTimeout: Duration` — the grace buffer (default `.seconds(3)`).
- `debugLogger: DebugRunLogger?` — for `logPromptError` (writes error
  `turn-N-response.json`). `nil` when debug logging is off (optional chaining
  no-ops, same as the catch path at `:777`).
- `debugTurn: Int?` — the 1-based turn index from `debugLogger?.nextTurn()`
  (`:620`); `nil` matches the "debug disabled" case.

**Single method:** `func arm() async` — sleeps `drainGraceTimeout`; on wake (if
not cancelled via `Task.sleep`'s `CancellationError`) does the
`guard !completionFlag.isDone` → `markDone` → `markDied` → log → yield → finish
dance. Returns when recovered OR when cancelled (cooperative lifecycle). Returns
early on cancellation (the success/catch/`onTermination`/`defer` paths cancelled
the timer first).

```swift
/// #615: drain-end grace recovery. Armed ONLY when the per-turn drain loop
/// finished via fanout-finish (`!Task.isCancelled`) with the prompt still
/// pending — i.e. the transport closed/process died before the session/prompt
/// result arrived. Sleeps `drainGraceTimeout` (a buffer for the ACP SDK to
/// surface the broken transport as a thrown error, which the catch path would
/// handle normally; see §4) then, if no winner ran, synthesizes the recovery
/// events + finishes the continuation.
///
/// Pure / testable: takes only `Sendable` primitives + the existing flag +
/// continuation types. No SDK `Client` dependency — that's why the
/// *integration* of this seam into `send` is validated manually (§7 gap).
struct TurnRecoveryGrace: Sendable {   // `internal` (default) — NOT `private`; @testable exposes internal, not private
    let completionFlag: TurnCompletionFlag
    let continuation: AsyncStream<AgentEvent>.Continuation
    let processHealth: ProcessHealthFlag
    let drainGraceTimeout: Duration
    let debugLogger: DebugRunLogger?
    let debugTurn: Int?

    func arm() async {
        var didRecover = false   // test-visible (via the holder pattern, §7 Test b)
        do {
            try await Task.sleep(for: drainGraceTimeout)
        } catch {
            // CancellationError — success/catch/onTermination cancelled us.
            // Cooperative lifecycle event, not a hidden failure (§3 house-rule
            // carve-out from plans/acp-permissions.md; do NOT use bare try?).
            return
        }
        guard !completionFlag.isDone else { return }   // a winner already ran
        didRecover = true
        completionFlag.markDone()
        processHealth.markDied()
        DebugLog.agent("ACPBackend: drain ended with prompt still pending — process exited before result (turn \(debugTurn.map(String.init) ?? "?"))")
        if let debugTurn {
            debugLogger?.logPromptError(ACPBackendError.processDiedBeforeResult, turn: debugTurn)
        }
        for event in Self.turnEndEvents(error: ACPBackendError.processDiedBeforeResult) {
            continuation.yield(event)
        }
        continuation.finish()
        _ = didRecover   // surfaced via the RecoveryTimerRef holder in tests
    }
}
```

> **Testability note:** `TurnCompletionFlag` and `ProcessHealthFlag` are currently
> `private` (file-scope) in `ACPBackend.swift`. Tests use
> `@testable import WikiFSEngine` (see `ACPBackendTests.swift:7`,
> `ACPStallRecoveryTests.swift:6`), so `internal` types ARE accessible. To make
> `TurnRecoveryGrace` directly testable, bump `TurnCompletionFlag` and
> `ProcessHealthFlag` from `private` to `internal` (no behavior change — just
> visibility). **`TurnRecoveryGrace` itself MUST be `internal` (the default —
> declare it as `struct TurnRecoveryGrace: Sendable` with no `private`
> modifier), NOT `private`.** `@testable import` exposes `internal` members
> as if `public`, but does NOT change the visibility of `private`/`fileprivate`
> declarations — `private` types remain inaccessible from the test module and
> the Tier 1 tests (a/a2/b) would fail to compile. This mirrors
> `turnEndEvents(error:)` (`:1521`) which is already `internal` (no access
> modifier). Do NOT use the `static func` alternative unless the struct form
> proves unworkable — the struct is preferred because it exercises the real
> `NSLock`-atomic flag (the load-bearing race-safety primitive).

---

## 4. Grace timeout value + rationale

> **Addresses reviewer LOW** (3s rationale conflates normal-case RPC latency with
> failure-case drain-end) and **LOW** (`Duration` vs `TimeInterval` units).

### Value: 3 seconds (`Duration.seconds(3)`)

**The grace timer exists ONLY in the failure case** (transport closed before the
`session/prompt` result). In that case, the result can **never** arrive on the
broken transport — `sendPrompt` will never return normally. The ONLY reason for a
grace timeout (rather than immediate recovery) is to give the ACP SDK a short
buffer to surface the closed transport as a **thrown error**, which the existing
catch path (`:765–783`) already handles completely (it does `markDied` +
`logPromptError` + `turnEndEvents` + finishes). 3s is that buffer.

**The normal streaming case never arms the timer** (§3: arming is gated by
fanout-finish, which only happens on transport close / process death). So the
3s value is not competing with normal RPC-result latency at all — it is purely
the "how long do we wait for the SDK to convert a broken transport into a throw"
window. 3s is generous for that (SDK transport-close detection is
near-instant); it remains a reasonable buffer.

If the SDK throws within the grace window (transport close → `sendPrompt` throws
before 3s elapses), the catch path wins (`completionFlag.markDone()` at `:769` +
`recoveryRef.cancel()`), and the grace timer no-ops — the turn is failed via the
existing, well-tested catch path, not the recovery path. The recovery path only
fires if the SDK *also* fails to throw within the buffer (the exact #615 symptom:
neither return nor throw).

### Unit: `Duration` (justified)

`ACPBackend.init` currently takes `turnCeilingTimeout: TimeInterval` and
`watchdogPollInterval: TimeInterval` (both `Double` seconds). Those use
`TimeInterval` because they feed `TurnLivenessPolicy.evaluate`, which does
`Date()` arithmetic (subtracting timestamps → `TimeInterval`). The grace timer
does **no `Date` arithmetic** — it calls `Task.sleep(for:)`, whose idiomatic and
direct argument is `Duration`. Using `Duration` here:
- matches #614's `budget: Duration?` (the sibling timer pattern this plan mirrors).
- reads cleaner in tests (`.milliseconds(150)` for fast, deterministic suites,
  mirroring how `ACPPermissionTimeoutTests` uses `.milliseconds(200)`).
- avoids a `TimeInterval → Duration` conversion at the call site (`.seconds(x)`).

**Decision:** `drainGraceTimeout: Duration` (default `.seconds(3)`), injected via
`ACPBackend.init`. This is an intentional, justified divergence from the
`TimeInterval` siblings, not an oversight.

---

## 5. Changes by file

### 5a. `Sources/WikiFSEngine/ACPBackend.swift`

1. **New stored property** `drainGraceTimeout: Duration` (default
   `.seconds(3)`), added next to `turnCeilingTimeout` (`:243`) and
   `watchdogPollInterval` (`:246`). Thread it into `init` (`:257–271`).
2. **Capture** `drainGraceTimeout` in `send` (read once off `self` next to where
   `ceilingTimeout`/`pollInterval` are captured at `:610–611`) — these are
   actor-isolated reads before the `@Sendable` continuation closure.
3. **New `RecoveryTimerRef`** (`@unchecked Sendable` holder with an internal
   `NSLock` + `Task<Void, Never>?`) — constructed before the drain task,
   captured by it (sets the timer when arming) and by the do/catch +
   `onTermination` (cancels). Mirrors #614's `Pending(timer:)` storage shape.
4. **Re-arch the per-turn drain task** (`:690–734`): after the `for await` loop
   exits, add the `if Task.isCancelled { return }` guard (normal path → bail,
   don't arm), then arm `TurnRecoveryGrace` via the holder (see §3 sketch). The
   existing loop body (`:691–733`) is unchanged.
5. **Success path** (`:745–763`): add `recoveryRef.cancel()` immediately after
   `completionFlag.markDone()` (`:757`). This is the DEFAULT, non-optional.
6. **Catch path** (`:765–783`): add `recoveryRef.cancel()` immediately after
   `completionFlag.markDone()` (`:769`). DEFAULT.
7. **`defer { drainTask.cancel() }`** (`:735`): add `recoveryRef.cancel()` (belt-
   and-suspenders teardown).
8. **`continuation.onTermination`** (`:789–798`): add `recoveryRef.cancel()` to
   the cancellation bridge (alongside `promptTask.cancel()`/`watchdogTask.cancel()`),
   shown in the §3 sketch.

> **§3 sketch vs §5a:** §3's sketch (with the `RecoveryTimerRef` holder +
> `onTermination` cancel) is authoritative for cancel-bridge wiring. If §5a
> reads as abridged on cancel placement, §3 wins.

### 5b. `Sources/WikiFSEngine/ACPBackend.swift` — `ACPBackendError`

Add a new case (`:1868–1882`):

```swift
/// #615: the agent subprocess exited / closed the transport after streaming a
/// complete response but BEFORE the `session/prompt` result returned. The
/// turn's answer was likely already shown; the result confirmation never came.
/// Distinct from `.processDied` (where sendPrompt threw); here sendPrompt
/// never resumed. The caller can send the next message (resume may be available
/// if the agent supports it). Surfaced as a user-visible, actionable error
/// rather than a silent freeze.
case processDiedBeforeResult
```

**Exhaustive switches that MUST be updated** (addresses reviewer LOW). There are
**exactly two** `switch` sites over `ACPBackendError` in the whole tree
(confirmed by `rg 'switch.*ACPBackendError|case \.processDied|case \.turnCeiling'`):

| # | Site | Location | Has `default`? | Action for new case |
|---|---|---|---|---|
| 1 | `turnEndEvents(error:)` | `ACPBackend.swift:1524–1532` (`switch acpError`) | **Yes** (`default → .agentError`) | Add an explicit `case .processDiedBeforeResult:` → `reason = .agentError(error.localizedDescription)` (for exhaustiveness + future differentiation; the `default` would otherwise silently catch it). Existing `case .turnCeilingExceeded` (`:1526`) and `case .processDied` (`:1528`) set the pattern. |
| 2 | `errorDescription` | `ACPBackend.swift:1884` (`switch self`) | **No** (fully exhaustive) | **Must add** `case .processDiedBeforeResult:` with the actionable message (below). This is the load-bearing one — adding the enum case without this produces a compiler error. |

And the `errorDescription` message (`:1883–1910`):

```swift
case .processDiedBeforeResult:
    return """
    Claude finished but the connection dropped before the result arrived. \
    Your answer was shown; you can send the next message.
    """
```

> **Exact-message wording:** the issue suggests "Claude finished but the
> connection dropped before the result arrived — your answer was shown; you can
> send the next message." Use that (trimmed to fit `.errorDescription`).

No other `switch ACPBackendError` sites exist. `ACPStallRecoveryTests` /
`ACPBackendTests` use `==` comparisons (`.turnCeilingExceeded(…)` at
`ACPStallRecoveryTests.swift:91`/`:99`, `.missingAPIKey` at
`ACPSmokeTests.swift:95`) — `==` is synthesized for enums without associated
value mismatches, so adding `.processDiedBeforeResult` (no associated value) is
safe for those. The compiler will catch any miss regardless, but listing the two
switch sites avoids a surprise compile failure mid-implementation.

### 5c. Visibility bump (test enabler)

Bump `TurnCompletionFlag` (`:1832`) and `ProcessHealthFlag` (`:1852`) from
`private` to `internal` (file-scope `final class`, no behavior change). This
lets `TurnRecoveryGrace` be driven directly in `@testable` tests (§7). If the
implementer prefers, an alternative is to expose `TurnRecoveryGrace` as a
`static func` on `ACPBackend` taking primitive flags — but the struct form is
preferred (it exercises the real `NSLock`-atomic flag).

---

## 6. Cross-cutting concerns

### Actor / Sendable / AsyncStream flags

- **Do NOT add `@MainActor` to `ACPBackend`.** It is a `public actor`
  (`:47`); the grace timer runs as a `Task` inside `send`'s `@Sendable`
  continuation closure, touching only `Sendable` captures
  (`completionFlag`, `processHealth`, `debugLogger`, `continuation`,
  `drainGraceTimeout`) — the same set the existing drain/watchdog/prompt
  tasks already capture safely. No new isolation boundary.
- **`Task.sleep(for:)` cancellation:** use the #614 form
  (`ACPPermissions.swift:460–468`):
  ```swift
  do { try await Task.sleep(for: drainGraceTimeout) }
  catch { return }   // CancellationError — cooperative, not a failure
  ```
  This is the **§3 house-rule carve-out from `plans/acp-permissions.md`**: a
  bare `try?` is forbidden repo-wide (it hides failures — see the write rules),
  but `Task.sleep`'s `CancellationError` is an expected lifecycle event. Catch
  it explicitly and `return` (do **not** re-handle as an error / do **not**
  use bare `try?`).
- **AsyncStream:** the existing `AsyncStream<AgentEvent>(bufferingPolicy: .unbounded)`
  (`:625`) is unchanged. The grace timer yields into the same continuation the
  drain/prompt tasks use — `AsyncStream.Continuation` is thread-safe for
  `yield`/`finish` (the docstring at `:623–624` notes the `.unbounded` invariant
  is preserved; the launcher drains promptly).
- **`DebugLog`, not `print`:** the recovery log line goes through
  `DebugLog.agent(...)` (os_log → Console.app, subsystem
  `com.selfdrivingwiki.debug`), consistent with the catch path (`:776`).
- **No SQLite:** the backend writes no DB rows. No `mutate(event:_:)` /
  `ResourceChangeEvent` involved. `StoreEmissionExhaustivenessTests` is
  untouched (it parses `SQLiteWikiStore` mutators, not the engine).

### `onExit` remains telemetry-only

The plan does **not** rewire `onExit` (`:571–580`) to fail turns — that would
double-resume against the grace timer / success / catch. `onExit` stays
telemetry-only. The per-turn drain-loop completion via fanout-finish is the
*sole* new trigger, gated by `completionFlag` + `Task.isCancelled`.

---

## 7. Test strategy (Swift Testing)

> **Addresses reviewer HIGH** (core recovery has no executable test; seam tests
> would pass while real send path is broken) and **HIGH** (ACs lack mapped tests).

### The test-infrastructure gap (committed, not deferred)

**There is no fake/protocol `Client` for ACP.** The SDK's `Client` is a concrete
`public actor` (`swift-acp` package, `Sources/ACP/Client.swift:30`), not a
protocol. `ACPBackend` holds `let client: Client` in `WarmProcess`/`send` and
calls `client.sendPrompt`, `client.cancelSession`, `await client.notifications`,
`client.authenticate`, `client.stderrLines()`. Abstracting all of that behind a
protocol would be a **major refactor** (touching session lifecycle, fanout
acquisition, error paths) — out of scope for this fix.

**Two testing tiers, committed:**

- **Tier 1 — pure seam tests (automated, fast tier `swift` CI job):** drive
  `TurnRecoveryGrace` directly with real `TurnCompletionFlag` +
  `AsyncStream.Continuation` + `ProcessHealthFlag` + an injected
  `drainGraceTimeout` (e.g. `.milliseconds(150)`). This exercises the
  recovery *decision* + the `completionFlag` race-safety primitive (the
  load-bearing correctness property). **It does NOT exercise the integration of
  the seam into `send`** (the fanout-finish-detection wiring, the `Task.isCancelled`
  disambiguation, the `recoveryRef.cancel()` placement). That integration is
  validated manually (Tier 2).
- **Tier 2 — manual validation (documented procedure, not in CI):** the
  integrating wiring (does the timer arm ONLY on fanout-finish, never on a normal
  >3s streaming turn?) cannot be automated without a fake `Client`. It is
  validated by hand against the #615 repro + a normal-turn smoke test. See the
  manual-validation procedure (§7c) and the **Risks** section (§8) where this is
  flagged as a test-infrastructure gap.

New file: `Tests/WikiFSTests/ACPTurnRecoveryTests.swift`. Mirrors the
`ACPBackendTests` / `ACPStallRecoveryTests` harness style (`@testable import
WikiFSEngine`, `@Test`/`#expect`). Pure-seam tests are fast → run in the **`swift`**
(fast) CI tier, NOT the `swift-integration` skip-list.

### Test (a): grace timeout fires → recovery path [Tier 1, automated]

```swift
@Test func drainEndGraceTimeoutFiresRecovery() async throws {
    // Given: a TurnRecoveryGrace with completionFlag fresh, a real
    // AsyncStream.Continuation, and drainGraceTimeout = .milliseconds(150).
    let flag = TurnCompletionFlag()
    let health = ProcessHealthFlag()
    let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self,
                                                        bufferingPolicy: .unbounded)
    var seen: [AgentEvent] = []
    let consumer = Task { for await e in stream { seen.append(e) } }

    // When: arm recovery; do NOT mark done from any other path (simulates
    // sendPrompt never returning — the #615 failure case).
    let recovery = TurnRecoveryGrace(
        completionFlag: flag, continuation: continuation,
        processHealth: health, drainGraceTimeout: .milliseconds(150),
        debugLogger: nil, debugTurn: nil)
    await recovery.arm()    // sleeps 150ms, then recovers (no one beat it)

    // Then: stream finished (consumer's for-await exited) + recovery events.
    _ = await consumer.value   // would hang if finish() never ran
    #expect(seen.count == 2)   // [turnFailed(.agentError(msg)), .messageStop]
    #expect(seen.last == .messageStop)
    if case .turnFailed(let reason) = seen.first {
        // assert the message is the actionable processDiedBeforeResult one
    } else { Issue.record("expected .turnFailed first") }
    #expect(health.died == true)       // markDied() ran
    #expect(flag.isDone == true)
}
```

### Test (a2): `turn-N-response.json` error variant written [Tier 1, automated]

```swift
@Test func recoveryWritesErrorResponseJson() async throws {
    // Point a real DebugRunLogger at a temp dir; arm recovery with a debugTurn;
    // assert the error variant turn-N-response.json exists + contains the error.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let logger = DebugRunLogger(directory: tmp)   // confirm init signature at impl time
    let turnIdx = logger.nextTurn()
    let flag = TurnCompletionFlag()
    let health = ProcessHealthFlag()
    let (stream, cont) = AsyncStream.makeStream(of: AgentEvent.self)
    let recovery = TurnRecoveryGrace(
        completionFlag: flag, continuation: cont, processHealth: health,
        drainGraceTimeout: .milliseconds(100),
        debugLogger: logger, debugTurn: turnIdx)
    await recovery.arm()
    let resp = tmp.appendingPathComponent("turn-\(turnIdx)-response.json")
    #expect(FileManager.default.fileExists(atPath: resp.path))
    let body = try String(contentsOf: resp, encoding: .utf8)
    #expect(body.contains("error") || body.contains("processDiedBeforeResult"))
}
```

### Test (b): legitimate completion wins → grace timer no-op'd [Tier 1, automated]

> **Addresses reviewer MEDIUM** (Test b verified event cleanliness, not that the
> timer actually no-op'd). Strengthened: assert the grace timer did NOT reach
> `markDone()` / `markDied()` — i.e. the recovery path's `guard
> !completionFlag.isDone` no-op'd because success won first.

```swift
@Test func promptSuccessBeatsGraceTimeout() async throws {
    let flag = TurnCompletionFlag()
    let health = ProcessHealthFlag()
    let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self,
                                                        bufferingPolicy: .unbounded)
    var seen: [AgentEvent] = []
    let consumer = Task { for await e in stream { seen.append(e) } }

    // Arm the timer (long budget) via the holder, but BEFORE it fires, the
    // success path wins: markDone + cancel the timer.
    let ref = RecoveryTimerRef()   // the holder from §3
    let recovery = TurnRecoveryGrace(
        completionFlag: flag, continuation: continuation, processHealth: health,
        drainGraceTimeout: .milliseconds(500),
        debugLogger: nil, debugTurn: nil)
    let t = Task { await recovery.arm() }
    ref.set(t)
    try await Task.sleep(nanoseconds: 50_000_000)  // let it register the sleep
    // Simulate sendPrompt returning successfully FIRST:
    flag.markDone()                                 // success wins
    ref.cancel()                                    // explicit cancel at win site
    for e in ACPBackend.turnEndEvents(error: nil) { continuation.yield(e) }

    // Wait PAST the 500ms budget so the timer would have fired + done its guard.
    try await Task.sleep(nanoseconds: 600_000_000)

    // Then: exactly the success events (.messageStop), NO spurious .turnFailed.
    _ = await consumer.value
    #expect(seen == [.messageStop])
    #expect(health.died == false)    // markDied() did NOT run — recovery no-op'd
    #expect(flag.isDone == true)     // success is the (only) winner
    // The timer task is cancelled; awaiting it returns (CancellationError path).
}
```

> **Test-tier limitation (explicit, per reviewer MEDIUM):** this asserts the grace
> timer did not reach `markDone()`/`markDied()` (observable via `health.died ==
> false` + `seen` cleanliness). It does **not** assert `continuation.finish()`
> was called exactly once — `AsyncStream.Continuation` tolerates a double
> `finish()` (unlike `CheckedContinuation`), so a double-finish wouldn't crash
> and can't be directly observed at this tier. The `completionFlag` guard makes a
> double-finish structurally impossible (only the first `markDone()` winner
> proceeds to finish), but that invariant is enforced by code review of §3, not
> by this test. State this limitation in the test's doc comment.

### Test (c): recovery events include `.messageStop` (contract pin) [Tier 1, automated]

```swift
@Test func recoveryEventsEndGeneration() {
    let events = ACPBackend.turnEndEvents(error: ACPBackendError.processDiedBeforeResult)
    #expect(events.contains { AgentEvent.endsGeneration($0) })
    #expect(events.last == .messageStop)
}
```

> This is the **contract pin** that the downstream `setGenerating(false)`
> (`AgentLauncher.swift:2453`) will fire — it asserts the recovery events include
> `.messageStop`, which `AgentEvent.endsGeneration` returns `true` for
> (`AgentEvent.swift:196`), so the launcher's `endsGeneration` branch is
> guaranteed to fire. It is **not** a behavioral test that `setGenerating(false)`
> actually runs in `AgentLauncher` — that is launcher-tier behavior with no
> engine-tier harness; see §7c manual validation + the AC test mapping (§9).

### Test (d): `ACPBackendError.processDiedBeforeResult` message [Tier 1, automated]

```swift
@Test func processDiedBeforeResultMessageIsActionable() {
    let msg = ACPBackendError.processDiedBeforeResult.localizedDescription
    #expect(msg.contains("answer was shown") || msg.contains("send the next message"))
    // Distinct from .processDied (which blames subprocess death + resume).
    let diedMsg = ACPBackendError.processDied.errorDescription ?? ""
    #expect(msg != diedMsg)
}
```

### Test (e): normal path does NOT yield `.processDiedBeforeResult` [Tier 1, automated, REGRESSION GUARD]

> **Addresses reviewer HIGH** ("No behaviour change on the normal path" had no
> test; given the CRITICAL wiring bug this would actually regress). This is the
> minimum normal-path regression guard at the engine tier.

```swift
@Test func normalTurnEndDoesNotProduceProcessDiedBeforeResult() {
    // A turn where sendPrompt returns normally → turnEndEvents(error: nil).
    // Assert it does NOT contain a .turnFailed with .processDiedBeforeResult.
    let events = ACPBackend.turnEndEvents(error: nil)
    #expect(events == [.messageStop])
    #expect(!events.contains { event in
        if case .turnFailed(let reason) = event {
            return reason.localizedDescription.contains("connection dropped") ||
                   reason.localizedDescription.contains("before the result")
        }
        return false
    })
}
```

> **What this guards (and what it can't):** this asserts the *event synthesis*
> for a normal (non-hung) turn yields no `.processDiedBeforeResult` events. It
> does **not** exercise the real `send` path (no fake `Client`) — i.e. it can't
> catch the CRITICAL wiring bug where the timer is armed at turn start. The
> arm-only-on-fanout-finish wiring is validated manually (§7c). This test
> guards the *event-contract* layer (that a successful turn's events are clean),
> which is what the engine tier CAN assert.

### §7c. Manual validation procedure (Tier 2 — documented, not in CI)

**Why manual:** the integration of `TurnRecoveryGrace` into `send` (the
fanout-finish detection via `!Task.isCancelled`, the `recoveryRef.cancel()`
placement, the arming-only-in-the-failure-case) cannot be driven by an automated
test without a controllable `Client` (which requires a major protocol extraction,
out of scope). CI-green would NOT catch a CRITICAL wiring regression (e.g. timer
armed at turn start → every >3s turn killed). So the wiring is validated by hand:

**MV-1 — Normal turn (REGRESSION — the CRITICAL-wiring guard):**
1. Build + launch the app (`make build && open …`, or via XcodeBuildMCP).
2. Send an interactive Claude turn that takes >3s to stream (e.g. a multi-paragraph
   answer or a tool-using turn). Confirm the answer streams normally + the turn
   completes with NO `.processDiedBeforeResult` error + ChatView exits
   "generating" + send re-enables.
3. **Pass criterion:** the turn completes normally; no spurious error; the
   `debug/turn-N-response.json` is the success variant (contains `stopReason`),
   not the error variant. **If a >3s turn fails with "connection dropped before
   the result arrived", the CRITICAL wiring bug is present — STOP and re-examine
   the `Task.isCancelled` gate.**

**MV-2 — #615 repro (the fix itself):**
1. Reproduce the #615 symptom: send a turn that triggers the agent to exit/close
   the transport after streaming a complete response but before the result
   (issue #615 repro: agent session `D13D222C-…`, turn 2 "create stub pages.").
2. **Pass criterion:** the turn resolves within ~3s (grace timeout) of the last
   `usage_update` with a `.turnFailed(.agentError)` + `.messageStop` pair; the
   chat surfaces "Claude finished but the connection dropped before the result
   arrived — your answer was shown; you can send the next message."; a
   `turn-N-response.json` (error variant) is written to `debug/`; `summary.json`
   is written (run not abandoned); ChatView exits "generating" + re-enables send.

**MV-3 — stopAgent cancels:**
1. Mid-stream, hit stop. Confirm the grace timer is cancelled (no lingering
   `.processDiedBeforeResult` after stop) and the turn ends via the cancel path.

**Limitations (flagged in Risks §8):** MV-2 depends on reproducing the transport
close timing, which is not deterministic. MV-1 is the most important guard
against the CRITICAL regression. Record the MV-1 result in the PR description.

---

## 8. Risks

| # | Risk | Mitigation | Tier |
|---|---|---|---|
| R1 | **CRITICAL wiring bug repeats** — timer armed at turn start (or while notifications flow) → kills every >3s turn. | (1) §3 sketch arms ONLY inside the drain task's post-`for-await` path gated by `!Task.isCancelled`. (2) Test (e) guards the event-contract layer. (3) **MV-1 manual validation is the hard guard** — explicitly verify a >3s streaming turn completes normally. Flag in PR description. | HIGH (test-infrastructure gap) |
| R2 | **No automated test for the real `send` path** — a fake `Client` requires a major protocol extraction (SDK `Client` is a concrete `public actor`). Seam tests (Tier 1) pass green while `send` could still be mis-wired. | Committed to Tier 1 (pure seam) + Tier 2 (manual validation §7c). The integration gap is explicitly documented, not hidden behind "pinned by contract." Follow-up: extract an `ACPClientProtocol` for future e2e `send` tests (§10). | HIGH |
| R3 | **`setGenerating(false)` / `finish()` / `summary.json` are launcher-tier behaviors** — no engine-tier harness drives `AgentLauncher` end-to-end. | Test (c) pins the *contract* (events include `.messageStop` → `endsGeneration`), but the behavioral assertion that `setGenerating(false)` fires is manual (MV-1/MV-2). Flagged as a test-infrastructure gap, not "pinned by contract." | HIGH |
| R4 | Double `continuation.finish()` not detectable at the seam tier (`AsyncStream` tolerates it). | Test (b) strengthens to assert the timer no-op'd (`health.died == false`), not just event cleanliness. Single-finish invariant enforced by the `completionFlag` lock + code review of §3, not by a test (stated as a test-tier limitation in Test b's doc comment). | MEDIUM |
| R5 | Grace timer lingers after a normal success (if explicit cancel is omitted). | `recoveryRef.cancel()` after `markDone()` is the DEFAULT (§5a.5/.6), not optional. Plus `defer` + `onTermination`. | LOW |
| R6 | `Task.isCancelled` true-but-fanout-also-finished race (transport closes exactly as the turn cancels). | `completionFlag` guard makes either path safe: if success/catch already marked done, the timer no-ops; if the timer won, the success/catch `guard !completionFlag.isDone` no-ops. No correctness issue, only a possible edge ordering. | LOW |

---

## 9. Acceptance criteria → test mapping

> **Addresses reviewer HIGH** (ACs lacked mapped executable tests). Every AC is
> mapped to a concrete test OR an explicit manual-validation step. ACs that
> genuinely can't be tested at the engine tier are flagged as test-infrastructure
> gaps (R2/R3), not "pinned by contract."

| AC | Test / validation | Tier | Notes |
|---|---|---|---|
| CI green on both Swift jobs (`swift` fast + `swift-integration`) | (all Tier 1 tests pass in `swift` job; none tagged `.integration`) | Automated | Pure-seam tests are fast; no DB/integration. If any turns out slow, tag `.integration` + add to the fast-tier `--skip` regex in `.github/workflows/ci.yml`. |
| #615 repro fails cleanly within the grace timeout (3s), not 1800s | **MV-2** (manual, §7c) | Manual | No fake `Client` → can't drive the real `send` with never-returning `sendPrompt` + finished fanout (R2). Test (a) asserts the *recovery decision* fires in the pure-seam tier, but not the `send` integration. |
| `turn-N-response.json` (error variant) written | **Test (a2)** + **MV-2** | Automated + Manual | Test (a2) asserts the file via `DebugRunLogger` → temp dir at the seam tier; MV-2 confirms the real `debug/` file in the repro. |
| `ChatView` exits "generating" (recovery events include `.messageStop`) + user-visible error surfaced | **Test (c)** (contract pin) + **MV-1/MV-2** (behavioral) | Automated + Manual | Test (c) pins `turnEndEvents(…).last == .messageStop` + `endsGeneration`. The behavioral assertion that `setGenerating(false)` fires in `AgentLauncher` is launcher-tier with no engine harness → manual (R3). |
| `finish()`/`summary.json` runs (run not abandoned) | **MV-2** | Manual | No engine-tier test drives the launcher's run-completion path. `summary.json` presence checked by hand in the repro. |
| `ACPBackendError.processDiedBeforeResult` exists, distinct from `.processDied`, actionable message | **Test (d)** | Automated | Pure contract: `localizedDescription` contains actionable text + `!= .processDied`'s message. |
| Race-safety regression test: success-path-wins → no double-resume, no spurious `.turnFailed`, no crash | **Test (b)** | Automated | Strengthened: asserts `health.died == false` (timer no-op'd), not just `seen == [.messageStop]`. Double-finish not directly observable at this tier (R4, limitation stated in Test b doc comment). |
| No behaviour change on the normal path | **Test (e)** + **MV-1** | Automated + Manual | Test (e): `turnEndEvents(error: nil) == [.messageStop]`, no `.processDiedBeforeResult`. MV-1: a real >3s streaming turn completes normally (the CRITICAL-wiring hard guard, R1). |
| `main` stays pristine — feature branch + PR, never self-merged | (process) | — | Branch `feature/turn-completion-recovery`; PR opened; never merged to `main` directly. |

---

## 10. House rules (explicit checklist for the implementer)

- ✅ Feature branch `feature/turn-completion-recovery` — never commit/push to
  `main`, never self-merge (open a PR).
- ✅ `DebugLog` for all diagnostics, never `print`
  (os_log → Console.app, subsystem `com.selfdrivingwiki.debug`).
- ✅ No bare `try?` — the `Task.sleep` `CancellationError` is the documented
  carve-out (`plans/acp-permissions.md` §3 / the repo write rules): catch it
  explicitly with `do { try await Task.sleep(…) } catch { return }`, do **not**
  swallow it via `try?`.
- ✅ Swift Testing (the `@Test` / `#expect` form), per `swift-testing-pro` and
  the existing `ACPBackendTests`/`ACPStallRecoveryTests` style — not XCTest.
- ✅ Consult `docs/skills/swift-concurrency-pro/SKILL.md`
  (`references/bug-patterns.md` §"Continuation resumed twice",
  `references/async-streams.md` §"Continuation lifecycle") before finalizing the
  race. The `completionFlag`-guarded, lock-atomic, resume-after-unlock
  discipline is the validated fix.
- ✅ Do NOT add `@MainActor` to `ACPBackend` (it's a `public actor`); the timer
  touches only `Sendable` captures through the existing locking discipline.
- ✅ Do NOT change the 1800s ceiling (`TurnLivenessPolicy.swift:62`) — #609 is a
  separate follow-up. Do NOT re-add #551's idle/stall detection. Do NOT add
  live-process-exit detection beyond the drain loop.
- ✅ No SQLite / `StoreEmissionExhaustivenessTests` impact.
- ✅ Run `swift test` locally before merging for fast iteration; the
  `swift-integration` job gates the full suite. Tag new slow tests `.integration`
  AND append to the fast-tier `--skip` regex in `.github/workflows/ci.yml`.

---

## 11. Reviewer-findings checklist (all addressed)

| # | Finding (severity) | Where addressed |
|---|---|---|
| 1 | Grace timer armed at turn start, not after drain-loop end (CRITICAL) | §3 sketch: arming is inside the drain task's post-`for-await` path, gated by `!Task.isCancelled`. Fanout-finished vs cancelled distinction made explicit (§1 + §3). Timer NEVER fires while notifications flow. |
| 2 | Core recovery has no executable test; seam tests pass while real send broken (HIGH) | §7: committed to Tier 1 (pure seam, automated) + Tier 2 (manual validation §7c). The SDK `Client` is a concrete actor → fake requires major refactor (out of scope). Gap flagged in Risks R1/R2. |
| 3 | Several ACs lack mapped executable tests (HIGH) | §9: every AC mapped to a concrete test OR an explicit manual-validation step. "Pinned by contract" replaced with honest "manual validation" / test-infrastructure-gap flags. Test (e) added as the minimum normal-path regression guard. |
| 4 | "Mirrors PR #614" framing was loose (MEDIUM) | §3: the divergence from #614's storage shape is made explicit (local timer + `RecoveryTimerRef` holder, NOT stored on the `ACPPermissionDelegate`-style shared state). Justified by `AsyncStream.Continuation` tolerating double-finish (unlike `CheckedContinuation`). Explicit `recoveryRef.cancel()` after `markDone()` is the DEFAULT (§5a.5/.6), not optional. |
| 5 | Test (b) didn't verify single-resume at the continuation level (MEDIUM) | Test (b) strengthened: asserts `health.died == false` (the timer no-op'd). Single-finish can't be asserted at this tier (`AsyncStream` tolerates double-finish) — stated as an explicit test-tier limitation in Test (b)'s doc comment + R4. |
| 6 | `TurnRecoverySeam` underspecified (MEDIUM) | §3a: concrete `TurnRecoveryGrace` — name, inputs (`completionFlag`, `continuation`, `processHealth`, `drainGraceTimeout`, `debugLogger`, `debugTurn`), single method `arm()`, ownership (`internal struct` in `ACPBackend.swift` next to the flag types — NOT `private`, so `@testable` tests can instantiate it). Strategy (A) committed; "(A)/(B) pick at impl time" removed. |
| 7 | 3s rationale conflates normal-case RPC latency with failure-case drain-end (LOW) | §4: clarified the grace exists ONLY in the failure case (transport closed before result) + is a buffer for the SDK to throw; the normal streaming case never arms the timer. 3s is the "wait for SDK to convert broken transport into a throw" buffer. |
| 8 | `drainGraceTimeout` uses `Duration` while siblings use `TimeInterval` (LOW) | §4: committed to `Duration` (justified — `Task.sleep(for:)` takes `Duration` directly, no `Date` arithmetic, matches #614's `budget: Duration?`, reads cleaner in tests). Single decision, justified. |
| 9 | Adding `.processDiedBeforeResult` requires updating exhaustive switches (LOW) | §5b: enumerated the exactly two sites — `turnEndEvents(error:)` (`:1524`, has `default`) + `errorDescription` (`:1884`, NO default — the load-bearing one). Compiler-enforced but listed to avoid a surprise compile failure. |
| 10 | `onTermination` cancellation of `graceTimer` not in the §3 sketch (LOW) | §3 sketch shows `recoveryRef.cancel()` in the `continuation.onTermination` bridge alongside `promptTask.cancel()`/`watchdogTask.cancel()`. §5a.8 restates it; §3 noted authoritative for cancel-bridge wiring. |
| 11 | Markdown typo (stray bold markers) (LOW) | Fixed — the `removeValue**-under-the-lock-then-resume-after-unlock****` typo is gone; §3 uses clean prose ("removeValue-under-the-lock-then-resume-after-unlock" without stray markers). |

---

## 12. Out-of-scope follow-ups (recorded, not done here)

- **#609:** lower the 1800s ceiling (esp. for interactive turns). Separate issue.
- **Extract an `ACPClientProtocol`** so a fake `Client` can drive the real `send`
  in automated tests (would close the R1/R2 test-infrastructure gap). Major
  refactor; track separately.
- **Recording ceiling-kill events in the debug trace** (today the watchdog path
  writes nothing to debug, `:653–661`). Noted in #615; out of scope here.
- **Upstream:** `agentclientprotocol/claude-agent-acp` #338 (subprocess death
  leaves session permanently broken). Track separately.

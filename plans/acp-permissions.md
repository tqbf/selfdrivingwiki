# Plan: ACP permission auto-reject timeout (#606) + per-operation policy split (#607)

> **Status:** Implementation-ready. Author: investigator/planner subagent.
> **Scope:** Combined fix for GitHub issues **#606** (`bug,correctness`) and
> **#607** (`bug`) — confirmed to be a **symptom + systemic-fix** pair, NOT
> independent. See §"Scope decision" for the justification.
> **Branch:** `feature/acp-permissions` (per CLAUDE.md — never commit to `main`).
> **References:** `plans/acp-backend-and-permissions.md`, `plans/sandbox-always-on.md`,
> `plans/sandbox-and-chat-modes.md`, `plans/event-bus.md`.
> (Optional background: `tmp/ingestion-stall-diagnosis.md` reproduces the
> root cause #1 + #2 — but §1 reproduces the root cause inline with
> file:line citations, so the diagnosis file is NOT required for a Paseo
> worktree that doesn't have it.)

---

## 1. Problem statement + root cause

### 1.1 What stops working (#606)

A single pending `alwaysAsk` (or `acceptEdits` non-edit) permission request
**blocks an agent turn indefinitely**. In the 2026-07-18 ingestion stall,
this burned ~48 of ~60 lost minutes: two back-to-back turns each stalled on
an unapproved permission until the 1800s (30 min) `TurnLivenessPolicy`
ceiling ceiling-killed them. Ingestion is unattended — nobody is watching
the transcript to click Approve/Reject.

### 1.2 Root cause (code)

`Sources/WikiFSEngine/ACPPermissions.swift`:

- **`deferPermission` (lines 385–403)** suspends on
  `withCheckedContinuation` with **no timeout, no escalation, no
  auto-reject**. The continuation only ever resumes via:
  - `resolve(optionId:)` (line 458) — the UI's Approve/Reject click, or
  - `cancelAllPending()` (line 498) — full session teardown in
    `ACPBackend.cancel()`.
- That's it. There is **no** time-bounded release for a *live* turn. The
  only backstop is the 1800s turn ceiling.
- Called from BOTH deferring policies: `.alwaysAsk` (line 374) AND
  `.acceptEdits` non-edit tools (line 362).

The ceiling-kill itself (`ACPBackend.send`, watchdog task at line 634,
`case .ceilingExceeded` at line 653) does:
`completionFlag.markDone()` → yield turn-end events → `continuation.finish()`
→ `client.cancelSession(...)` (line 660). It does **not** call
`cancelAllPending()`. The stuck `deferPermission` continuation is resumed
indirectly when `cancelSession` tears down the prompt — but only after the
full 1800s burned. The diagnosis's `permissions.jsonl` timestamps (21:45 and
22:15, exactly 30 min apart) confirm the permission's `cancelled` outcome
is written at the moment of ceiling-kill, not before.

`Sources/WikiFSEngine/TurnLivenessPolicy.swift:62`:
`defaultCeilingTimeout = 1800` (30 min) — **way too generous** for an
unattended ingest whose only stall is a stuck permission. Even with a 60s
permission budget, the ceiling is the structural backstop, so it must be
lowered for queued/ingest operations (tracked separately as #609 — see §6).

### 1.3 Why the wrong policy applied (#607 — the amplifier)

`Sources/WikiFSEngine/AgentLauncher.swift`:

- **`resolvePermissionMode` (lines 197–200)** reads a single shared key:
  `UserDefaults.standard.string(forKey: AgentLauncher.permissionModeKey)`
  where `permissionModeKey = "agentPermissionMode"` (line 458). Default
  `.bypass`.
- This one closure feeds **three unrelated operation kinds** at three call
  sites, all of which construct the backend via
  `resolveBackend(policy)` → `AgentBackendFactory.makeBackend(policy:)`
  → `ACPBackend(permissionPolicy:)` → installed on the delegate at
  `ACPBackend.startProcess` line 319:
  1. **Interactive chat** — `startInteractiveQuery`, line 2020 (also the
     `.ingest`/`.lint`/`.lintPage` single-session path at line 879 in
     `run()`).
  2. **Multi-phase ingest** — `runACPIngestPlannerExecutors`, line 1178
     (planner + executors + finalizer all share the one `policy`).
  3. **PDF/text extraction** — `ACPExtractionClient` line 151
     (`AgentBackendFactory.makeBackend(policy: permissionPolicy)`), whose
     `permissionPolicy` defaults to `.bypass` but is passed through from
     the launcher context.
- **Lint** routes through `AgentOperationRunner.runLint`/`runLintPages`
  → `run()` → line 879. Same shared key.

So a user who correctly chose "Always Ask" for **interactive chat** got
`alwaysAsk` applied to a 4-page batch **ingestion** and to **lint**, where
nobody is watching — guaranteeing a stall on the first prompt needing a
permission. The sandbox profile (`plans/sandbox-always-on.md`) already
confines writes to the scratch dir + active wiki DB; bash subprocess writes
outside that allowlist are blocked by the OS regardless. `alwaysAsk` only
has *structural* value in interactive chats where the user is reading the
transcript in real time.

### 1.4 The relationship — why this is ONE combined fix

#607 is the **trigger** (wrong policy reaches an unattended pipeline) and
#606 is the **consequence** (a pending permission then has no bounded
release). The diagnosis ranks them as root cause #2 (policy mismatch) and
root cause #1 (no timeout) of the *same* stall. Fixing only #606 leaves an
unattended ingest still able to stall for the full 60s budget on every
prompt — tolerable but wasteful, and a user who *intentionally* sets ingest
to `alwaysAsk` would still hit it. Fixing only #607 removes the common case
but leaves the core defect: *any* deferring policy (alwaysAsk, or
acceptEdits on a non-edit tool) can hang a turn until the ceiling. **Both
are needed.** See §6 for why the timeout is the belt-and-suspenders
backstop that makes the policy split safe to ship.

---

## 2. Scope decision: COMBINED #606 + #607

**Chosen:** Implement both in one PR on `feature/acp-permissions`.

Rationale:
- They are the #1 + #2 root causes of a single diagnosed incident. Shipping
  them together retires the stall end-to-end and lets the PR description
  tell one coherent story (issue cluster #606/#607).
- The timeout (#606) is the load-bearing correctness fix and is small and
  self-contained (one function + tests). The policy split (#607) is
  config + one call-site each + a Settings UI change.
- The two touch overlapping files (`ACPPermissions.swift`, the launcher,
  Settings UI) minimally; doing them separately would churn the same lines
  twice.

**In scope:**
- A bounded auto-reject budget on `deferPermission` (#606).
- Per-operation permission keys: `chat` / `ingest` / `lint` (and
  `extraction`) with sensible defaults (#607), plus a one-time migration
  of the legacy `agentPermissionMode` value into `chatPermissionMode`.
- Settings UI: replace the single Permission Mode picker with per-operation
  pickers (or keep chat as the primary picker + explicit ingest/lint/extract
  pickers — see §5.3 for the UI decision).
- Diagnostics: log the timeout (DebugLog) so the failure is visible in
  Console.app (never bare `try?` / never `print`).

**NOT in scope** (separate issues — see §6):
- #608 Activity-window surfacing of *pending* permissions (yellow row).
- #609 lowering the queued-ingest turn ceiling (1800s → ~600s).
- #610 ceiling-kill retry running blind into the same pending-permission
  pattern.
- Any prompt changes (`prompts/ingest-executor.md` scope drift — diagnosis
  root cause #3/#4).
- The stale `sandbox-config.json` orphan (already documented in
  `plans/sandbox-always-on.md`).

---

## 3. House rules (Non-negotiable for the implementer)

- **Branch:** `feature/acp-permissions`. Push the branch, open a PR. **Never
  merge to `main` yourself** — merging happens after review + CI green.
- **Diagnostics:** route ALL logging through `DebugLog` (os_log, subsystem
  `com.selfdrivingwiki.debug`). **Never bare `try?`** to swallow errors —
  use `do { try … } catch { DebugLog.agent(…) }` (see CLAUDE.md — bare
  `try?` has already caused lost transcripts). **Never `print`** for
  diagnostics (except real CLI stdout in `wikictl`).
- **Read first:** `CLAUDE.md`, `SWIFTUI-RULES.md` (this touches Settings
  UI). Load and follow the design skills before writing SwiftUI:
  - `docs/skills/swiftui-pro/SKILL.md` (filter version-gated guidance to
    macOS 15 / Swift 6.0 — it targets iOS 26 / Swift 6.2).
  - `docs/skills/macos-design/SKILL.md` (translate CSS/web terms to SwiftUI;
    `.regularMaterial`, points, system faces).
  - `docs/skills/typography-designer/SKILL.md` (consistent type scales,
    visual hierarchy — see the existing Settings picker style and match it).
- **Tests:** prefer **Swift Testing** (`@Test func`) over XCTest for new
  tests. Follow `docs/skills/swift-testing-pro/SKILL.md` (core-rules,
  async-tests). Slow/new real-DB suites: tag `.integration` AND append to
  the fast-tier `--skip` regex in `.github/workflows/ci.yml`.
- **Concurrency:** this fix spans an `AsyncStream` (the turn stream in
  `ACPBackend.send`) and `@unchecked Sendable` lock-protected state in
  `ACPPermissionDelegate`. Consult
  `docs/skills/swift-concurrency-pro/SKILL.md` (`actors`,
  `unstructured`, `cancellation`, `bug-patterns`) before touching the
  continuation/timer. See §7.
- **SQLite:** this fix does **not** touch the store. The timeout is purely
  in-process (`ACPPermissionDelegate`); the policy split is in UserDefaults
  + the launcher. If for some reason a store write is introduced, EVERY new
  public mutator on `SQLiteWikiStore` MUST route through `mutate()` and emit
  a `ResourceChangeEvent` — see `plans/event-bus.md` and the
  `StoreEmissionExhaustivenessTests` guard.

---

## 4. Implementation — #606: bounded auto-reject on `deferPermission`

### 4.1 The timeout

Replace the indefinite `withCheckedContinuation` in `deferPermission`
(`Sources/WikiFSEngine/ACPPermissions.swift:385-403`) with a race between
the user-resolution continuation and a budget timer. When the budget
elapses first, auto-reject: remove the pending entry from the map and
return a `cancelled` outcome (the agent treats `cancelled` as denied and
adapts — it already does for denied tools).

**Primary approach: detached-timer form (do NOT use a `TaskGroup`).**

A `withTaskGroup` sketch was considered and **rejected** — awaiting
`group.next()` from inside one of the group's own child tasks is a
data race (the group is non-`Sendable` and `next()` is mutating) and will
not compile cleanly under Swift 6.0 strict concurrency. The detached-timer
form below is the path of least resistance because it preserves the
existing `removeValue`-then-resume discipline verbatim.

Sketch (refine at implementation):

```swift
private static func deferPermission(
    request: RequestPermissionRequest,
    lock: OSAllocatedUnfairLock<LockedState>,
    budget: Duration? = .seconds(60)   // NEW default; nil = unbounded (interactive chat)
) async -> RequestPermissionResponse {
    // Single continuation — same shape as today, just with an armed timer.
    return await withCheckedContinuation { (cont: CheckedContinuation<RequestPermissionResponse, Never>) in
        let timer: Task<Void, Never>? = budget.map { b in
            Task { [toolCallId = request.toolCall.toolCallId] in
                do {
                    try await Task.sleep(for: b)
                } catch {
                    // CancellationError — expected when resolve() / cancelAllPending()
                    // cancelled the timer first. Cooperative lifecycle event, not a
                    // hidden failure (see §3 house rule carve-out).
                    return
                }
                // Budget elapsed before the user resolved → auto-reject.
                // timeOut mirrors resolve: removeValue under the lock, then resume.
                Self.timeOut(toolCallId: toolCallId, lock: lock)
            }
        }
        lock.withLock { state in
            state.pending[request.toolCall.toolCallId] = Pending(
                options: request.options,
                toolName: /* unchanged */ nil,
                inputSummary: /* unchanged */ nil,
                continuation: cont,
                timer: timer)   // NEW field on Pending; store so resolve/cancel can cancel it
        }
    }
}

// NEW — mirror of resolve(optionId:) but resolving as `cancelled`.
// Called from the detached-timer task when the budget elapses first.
private static func timeOut(
    toolCallId: String,
    lock: OSAllocatedUnfairLock<LockedState>
) {
    let drained = lock.withLock { state -> (CheckedContinuation<RequestPermissionResponse, Never>, Task<Void, Never>?)? in
        guard let pending = state.pending.removeValue(forKey: toolCallId) else { return nil }
        return (pending.continuation, pending.timer)
    }
    guard let (cont, _) = drained else {
        // resolve() or cancelAllPending() already won the race — nothing to do.
        return
    }
    DebugLog.agent("ACPBackend: permission budget exceeded — auto-reject toolCallId=\(toolCallId)")
    cont.resume(returning: RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true)))
}
```

**Wire the timer cancellation into `resolve` and `cancelAllPending`.**
Both already do `removeValue` / `removeAll` under the lock before resuming
(line ~462-466 resolve, ~498-509 cancelAllPending). Extend them to also
cancel the stored timer on the removed `Pending`, so no stray timer fires
after the user resolved first or after teardown:

```swift
// In resolve(optionId:) — inside the lock, after removeValue:
if let timer = removedPending.timer { timer.cancel() }
// … then resume removedPending.continuation as today.

// In cancelAllPending() — inside the lock, after removeAll:
for (_, pending) in removed { pending.timer?.cancel() }
// … then resume each continuation as today.
```

> **Implementation note — the load-bearing invariants:**
> 1. **Exactly one** `resume` per `CheckedContinuation` (a double-resume
>    traps; a missed resume warns/traps at task end). The `removeValue`-
>    then-resume discipline in `resolve` (line ~462-466), `cancelAllPending`
>    (line ~498-509), AND the new `timeOut(toolCallId:)` is what guarantees
>    this: whichever wins the race pulls the entry out of the map under the
>    lock, so the others find nothing to resume. See
>    `docs/skills/swift-concurrency-pro/SKILL.md` (`bug-patterns`:
>    "Continuation resumed twice → restructure so only one path reaches the
>    continuation").
> 2. **Store the timer on `Pending`** so `resolve`/`cancelAllPending` can
>    cancel it. Without this, a timer fires after teardown, hits the empty
>    map look-up (the `guard let drained` no-op), and is harmless but
>    wasteful — storing + cancelling is the cleaner lifecycle.
> 3. `Pending` gains one field: `let timer: Task<Void, Never>?`. Existing
>    call sites that construct `Pending` without a timer (if any outside
>    `deferPermission`) pass `nil`.
> 4. The `permissionTimedOut(toolCallId:)` signal (#608 surface) should be
>    emitted from the `timeOut` branch so a future subscriber can show it —
>    but the Activity-window rendering itself is #608 (out of scope). For
>    now, the `DebugLog.agent` line in `timeOut` suffices.
> 5. **TaskGroup approach: do NOT use.** A `withTaskGroup` sketch where a
>    child task awaits `group.next()` on the same group does not compile
>    under Swift 6.0 strict concurrency (non-Sendable + mutating access).
>    The detached-timer form above is the committed approach.

**§3 house-rule carve-out for `Task.sleep`:** `Task.sleep` only throws
`CancellationError` (cooperative cancellation — expected when `resolve` or
`cancelAllPending` cancels the timer). Writing `do { try await Task.sleep… }
catch { return }` with the comment above is the idiomatic, letter-of-rule
form (`docs/skills/swift-concurrency-pro/SKILL.md` `bug-patterns`:
"Ignoring CancellationError in catch blocks"). Do **not** write bare
`try? await Task.sleep(...)` — it contradicts §3's no-bare-`try?` rule even
though the spirit holds.

### 4.2 Propagating the timeout to the turn

Today, on `cancelled`, the agent gets a denied-permission outcome and
continues its turn (it adapts to denied tools). That is the desired
behavior for #606 — the turn continues instead of burning the ceiling. No
new error type strictly needs to propagate to `sendPrompt`; the `cancelled`
outcome IS the auto-reject. (Issue #606's sketch mentioned a
`PermissionTimedOut` error, but the existing `cancelled` path achieves the
same agent recovery and avoids a new error case threading through the SDK.
If the reviewer wants an explicit signal, add a `DebugLog` line + an
optional callback hook `onPermissionTimeout: ((String) -> Void)?` on the
delegate, wired to the launcher for #608's future use — but do not change
the `RequestPermissionResponse` shape.)

### 4.3 Where the budget is set

Make `budget` a parameter with a sensible default, threaded from
`ACPPermissionDelegate.init(policy:debugLogger:budget:)` so an interactive
chat can pass a larger budget (or none → unbounded, preserving current
behavior for the interactive case) while ingest/lint/extraction pass the
default 60s. Concretely:
- `ACPPermissionDelegate.init(policy:debugLogger:budget:)` — new
  `budget: Duration?` (nil ⇒ no timer = current behavior; non-nil ⇒ auto-reject).
- `ACPBackend.start` / `startProcess` (line 319) passes `permissionBudget`
  (a new stored property on `ACPBackend`, set from `init`) into the delegate.
- `ACPBackend.init(permissionPolicy:budget:)` gains a `budget: Duration?`.
- `AgentBackendFactory.makeBackend(policy:budget:)` gains `budget:
  Duration? = nil`.
- The three launcher call sites pass the operation-appropriate budget (see
  §5.4).

> **Important:** `withCheckedContinuation`/`Task.sleep` run on a background
> task and **do not** hop to the main actor — the delegate is deliberately
> `@unchecked Sendable` with lock-protected state (see the class doc,
> lines 306-311). Keep it that way. Do not introduce `@MainActor` isolation
> on the delegate.

---

## 5. Implementation — #607: per-operation permission policy

### 5.1 New keys

Replace the single `agentPermissionMode` key with operation-scoped keys:

```swift
// AgentLauncher.swift — replace `permissionModeKey` (line 458)
public enum PermissionModeKey {
    public static let chat       = "chatPermissionMode"
    public static let ingest      = "ingestPermissionMode"
    public static let lint        = "lintPermissionMode"
}
```

> **`extractionPermissionMode` is intentionally NOT added in this PR.**
> `ACPExtractionClient.init` defaults its policy to `.bypass`
> (`Sources/WikiFSEngine/ACPExtractionClient.swift:86`) and may be
> constructed outside the launcher (e.g. from the queue path — exact call
> sites not enumerated). Rather than ship a half-wired `extraction` key
> whose callers haven't been confirmed to thread
> `resolvePermissionMode(for: .extraction)`, leave extraction on its
> existing `.bypass` default and drop the key from `PermissionModeKey`
> until a caller actually needs it. This keeps the split strictly
> chat/ingest/lint — three keys, three pickers, all verified end-to-end.
> If enumeration later finds every `ACPExtractionClient()` construction
> passes the extraction key, a follow-up PR can add it. Extraction is
> read-heavy; `.bypass` is the correct default anyway.

Defaults (per #607's rationale + sandbox-always-on):
- `chat` → whatever the user set (default `.bypass`).
- `ingest`  → `.bypass` (sandbox already confines writes; unattended pipeline).
- `lint`    → `.bypass` (same).
- `extraction` → `.bypass` (a one-shot read+convert; reads are ungated anyway).

### 5.2 Split `resolvePermissionMode`

Rename to `resolvePermissionMode(for operation: OperationKind) ->
PermissionPolicy` (or three small closures, one per kind — match the
existing injectable-closure style at lines 190-200 so tests can stub each).
`OperationKind` = an enum `{ chat, ingest, lint, extraction }` (do NOT
reuse `WikiOperation.Kind` — that's the *run* kind; the permission kind is
a policy-domain concept; keep them separate to avoid coupling).

Each branch reads its own UserDefaults key with its own default:
```swift
@ObservationIgnored var resolvePermissionMode:
    (OperationKind) -> PermissionPolicy = { op in
        let key: String
        let fallback: PermissionPolicy
        switch op {
        case .chat:   key = PermissionModeKey.chat;   fallback = .bypass
        case .ingest: key = PermissionModeKey.ingest; fallback = .bypass
        case .lint:   key = PermissionModeKey.lint;   fallback = .bypass
        }
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return PermissionPolicy(rawValue: raw) ?? fallback
    }
```

> **`OperationKind` = `{ chat, ingest, lint }` only** (no `.extraction`
> case — extraction stays on its existing `.bypass` `ACPExtractionClient`
> default; see §5.1). Do NOT reuse `WikiOperation.Kind` (that's the *run*
> kind; the permission kind is a policy-domain concept; keep them separate
> to avoid coupling).

### 5.3 One-time migration of the legacy key

On first launch after this change, if `chatPermissionMode` is unset AND the
legacy `agentPermissionMode` has a value, copy it into
`chatPermissionMode` and leave `agentPermissionMode` in place (don't delete
— avoids surprises; it's just orphaned, like `sandbox-config.json`). Do this
in a small `PermissionModeMigration.migrateOnce()` called from app startup
(launcher init or `WikiFSApp`), guarded so it's idempotent. Log via
`DebugLog.agent` when it migrates.

```swift
enum PermissionModeMigration {
    static func migrateOnce() {
        // Only migrate if the new chat key has NEVER been written (object == nil).
        if UserDefaults.standard.object(forKey: PermissionModeKey.chat) == nil,
           let legacy = UserDefaults.standard.string(forKey: "agentPermissionMode"),
           !legacy.isEmpty,
           let policy = PermissionPolicy(rawValue: legacy) {
            UserDefaults.standard.set(policy.rawValue, forKey: PermissionModeKey.chat)
            DebugLog.agent("PermissionModeMigration: copied legacy agentPermissionMode=\(policy.rawValue) -> chatPermissionMode")
        }
    }
}
```

This is idempotent: after the first run, `object(forKey: PermissionModeKey.chat)`
is non-nil (we just wrote it), so the guard fails on subsequent launches.

The guard predicate (`object(forKey:) == nil`, NOT `string(forKey:) == nil`)
matters because `string(forKey:)` cannot distinguish "key absent" from
"key present but empty string" — `object(forKey:) == nil` is the only
correct key-presence check. Test §8.2 #9 asserts this idempotency, so the
implementation predicate must match.

### 5.4 Wire the call sites

Update the three call sites to request the right kind + budget:

| Call site (AgentLauncher.swift)                  | Operation | Policy kind | Budget |
|--------------------------------------------------|-----------|-------------|--------|
| `startInteractiveQuery` line ~2020               | chat      | `.chat`     | nil (interactive — unbounded, current behavior) |
| `run()` single-session path line ~879            | ingest/lint | derived from `operation` kind | `.seconds(60)` |
| `runACPIngestPlannerExecutors` line ~1178        | ingest    | `.ingest`   | `.seconds(60)` |

For `run()` (line 879), the operation kind is known from the `operation:
WikiOperation` in scope — map `.lint`/`.lintPage` → `.lint`, `.ingest` →
`.ingest`, else `.chat`. Pass the resolved budget into `resolveBackend`.

> **`ACPExtractionClient` is NOT touched in this PR.** It keeps its existing
> `permissionPolicy: .bypass` default (`ACPExtractionClient.swift:86`) and
> its existing caller — extraction is read-heavy, `.bypass` is correct, and
> the call sites weren't fully enumerated (see §5.1 note). A follow-up can
> thread the extraction key if a caller needs configurable extraction policy.

### 5.5 Settings UI

- **File:** `Sources/WikiFS/Settings/AgentsSettingsView.swift` (currently a
  single `@AppStorage(AgentLauncher.permissionModeKey)` picker at line 364).
- Replace the single "Permission Mode" picker with per-operation pickers in
  **Settings → Agents → Permissions**:
  - "Chat Permission Mode" → `PermissionModeKey.chat`
  - "Ingest Permission Mode" → `PermissionModeKey.ingest`
  - "Lint Permission Mode" → `PermissionModeKey.lint`
  - (No extraction picker — extraction has no user-facing key in this PR; see §5.1.)
- Each picker reuses the existing `Picker(... ForEach(PermissionPolicy.allCases))`
  pattern (line 364-366). Keep the help text (`PermissionPolicy.help`) per
  picker.
- **Each new `@AppStorage(PermissionModeKey.<x>)` binding MUST declare its
  raw-value default exactly as the existing single picker does** — the
  current code is
  `@AppStorage(AgentLauncher.permissionModeKey) private var permissionModeRaw = PermissionPolicy.bypass.rawValue`
  (`Sources/WikiFS/Chats/ChatView.swift:53`; same shape at
  `Sources/WikiFS/Settings/AgentsSettingsView.swift:364`). That default
  (`= PermissionPolicy.bypass.rawValue`) is load-bearing — without it the
  picker's initial selection is undefined. For the split, declare one such
  binding per key:
  ```swift
  @AppStorage(PermissionModeKey.chat)     private var chatModeRaw     = PermissionPolicy.bypass.rawValue
  @AppStorage(PermissionModeKey.ingest)   private var ingestModeRaw   = PermissionPolicy.bypass.rawValue
  @AppStorage(PermissionModeKey.lint)     private var lintModeRaw     = PermissionPolicy.bypass.rawValue
  ```
- Also update `Sources/WikiFS/Chats/ChatView.swift:53` — its
  `@AppStorage(AgentLauncher.permissionModeKey)` chip (line 435
  `PermissionModeSelector`) should point at `PermissionModeKey.chat` (the
  in-chat composer only governs the chat policy now). Preserve the
  `= PermissionPolicy.bypass.rawValue` default on the renamed binding.

> **UI house rule:** follow `macos-design` + `typography-designer` + the
> existing Settings visual language. A small grouped section with a header
> explaining "These control how the app responds to the agent's permission
> requests for each operation. Ingest and Lint run unattended — Bypass is
> recommended." Keep type scale consistent with nearby pickers.

---

## 6. Cluster of issues — what this retires, what stays

| Issue | Title | Status w/ this fix |
|-------|-------|--------------------|
| #606 | `alwaysAsk` blocks forever — auto-reject timeout | ** FIXED in scope** (§4). |
| #607 | Permission policy shared chat/ingest/lint — split | ** FIXED in scope** (§5). |
| #608 | Activity window silent on permission stalls | **OUT of scope** — the plumbing (a `DebugLog` line + an optional `onPermissionTimeout` hook on the delegate) is laid, but the `QueueActivityTracker.pendingPermission(for:)` + `ActivityWindowView` yellow row is its own PR. Leave #608 open with a comment noting the hook is present. |
| #609 | Queued-ingest turn ceiling 1800s → ~600s | **OUT of scope** (separate issue). Even with the 60s permission budget, lowering the ceiling is a separate, independently-reviewable change to `TurnLivenessPolicy.defaultCeilingTimeout` (or a per-operation ceiling). Flag as the next follow-up. Do NOT change the ceiling here. |
| #610 | Ceiling-kill retry runs blind into same pattern | **OUT of scope** — depends on #608 (pending-permission history surfaced to the retry). Leave open. |

### In-scope vs. follow-up summary

- **In scope:** #606 (timeout) + #607 (policy split). One PR.
- **Follow-up #1:** #608 (pending-permission Activity surfacing) — build on
  the `onPermissionTimeout` hook + `pendingSnapshot()` added here.
- **Follow-up #2:** #609 (lower ingest ceiling).
- **Follow-up #3:** #610 (retry awareness of pending-permission history).

---

## 7. Cross-cutting concerns

### 7.1 Concurrency / Sendable / AsyncStream

- **`ACPPermissionDelegate`** is `final class … @unchecked Sendable`
  (lines 306-311). It holds all mutable state behind an
  `OSAllocatedUnfairLock<LockedState>`. The timeout's `Task.sleep` runs on a
  detached/background task and must only touch the delegate via the lock —
  same discipline as `resolve`/`cancelAllPending`. Do NOT add `@MainActor`.
- The timeout races inside `handlePermissionRequest`, which is called from
  the SDK's `ClientDelegate` channel — NOT from the turn's `AsyncStream`
  continuation directly. The turn stream (`ACPBackend.send`, line 614)
  yields events; the permission suspend happens *inside* `sendPrompt`
  (line 667+, the prompt task) which blocks on the delegate. So the timeout
  releasing the continuation *unblocks the prompt task*, which then drives
  the stream normally. No direct `AsyncStream` plumbing change.
- **Continuation safety:** the single `resume` invariant (§4.1 note) is the
  critical correctness property. A leaked or double-resumed
  `CheckedContinuation` traps at task end. The `StoreEmissionTests`-
  style exhaustiveness guard doesn't apply here (no store), but the test
  plan (§8) covers the race explicitly.
- Consult `docs/skills/swift-concurrency-pro/SKILL.md` (`unstructured`
  tasks, `cancellation` for `Task.sleep`, and `bug-patterns` for
  continuation pitfalls) before finalizing §4.1. The committed approach
  is the detached-timer form (see §4.1) — do NOT use a `TaskGroup`.

### 7.2 SQLite

- **No store changes.** The permission policy + timeout live entirely in
  UserDefaults + the in-process `ACPPermissionDelegate`. No new
  `SQLiteWikiStore` public mutator. If an implementer is tempted to persist
  permission history for #610 — that's #610's scope, not here, and would
  require the full `mutate()` + `ResourceChangeEvent` discipline
  (`plans/event-bus.md`).

### 7.3 Retry / ceiling interaction

- The 60s budget is **per permission request**, not per turn. A turn with
  several deferred permissions could still accumulate, but each auto-rejects
  at 60s, so the worst case is bounded per-request. The 1800s ceiling
  remains the turn-level backstop (unchanged here — #609 lowers it).
- On a ceiling-kill, the existing `cancelSession` (line 660) + the eventual
  `ACPBackend.cancel()` → `cancelAllPending()` (line 975) still drain any
  in-flight continuations — so the timeout doesn't change teardown safety.

---

## 8. Test plan

### 8.1 Existing coverage to keep green (do NOT break)

- `Tests/WikiFSTests/ACPBackendTests.swift` — the `@Test func alwaysAsk*` /
  `yolo*` / `resolveUnknownOption*` family (lines ~202-346) constructs a
  delegate + `RequestPermissionRequest`, suspends on a `Task`, and asserts
  `pendingSnapshot()`/`resolve`. The timeout must not break these:
  - `alwaysAskDefersUntilResolved` (256) — resolves before any budget
    elapses; with a 60s default budget this still passes (no timeout fires).
  - `alwaysAskResolvesDeny` (300), `resolveUnknownOptionReturnsFalse` (328)
    — same.
  - The new budget default MUST be large enough (or the tests must pass an
    explicit `budget: nil`) so existing tests don't flake. Prefer: tests
    construct the delegate with an explicit budget so they're deterministic.
- `Tests/WikiFSTests/ACPWiringTests.swift`, `AgentProviderModelTests.swift`
  — wiring; ensure the new `makeBackend(policy:budget:)` signature / key
  changes don't break them (update call sites).
- `AgentCASests.swift`, `ACPStallRecoveryTests.swift`,
  `GenerationGate*Tests.swift`, `AgentOperationRunnerTests.swift` — run the
  fast tier (`swift test --skip '...'` per CLAUDE.md) and ensure green.

### 8.2 NEW tests (Swift Testing, `@Test func`)

Add to a new `Tests/WikiFSTests/ACPPermissionTimeoutTests.swift` (fast-tier,
no `.integration`):

1. **`deferPermissionAutoRejectsAfterBudget`** — construct a delegate with
   `policy: .alwaysAsk` and `budget: .milliseconds(200)`; call
   `handlePermissionRequest`; never call `resolve`; assert the response
   comes back with `outcome.cancelled == true` within ~250ms. (Mirror the
   `alwaysAskDefersUntilResolved` harness — suspend on a `Task`, await with a
   short timeout.) This is the #606 repro-becomes-test.
2. **`deferPermissionUserResolveBeatsBudget`** — same delegate
   (`budget: .milliseconds(200)`); call `resolve(optionId: "opt-allow")`
   after ~50ms; assert the response is the ALLOW outcome (not cancelled)
   — the budget timer lost the race.
3. **`deferPermissionUserResolveThenBudgetDoesNotDoubleFire`** — resolve
   fast; then wait past the budget; assert no crash / no second resume
   (the continuation-safety invariant, §4.1 note 1). This is the regression
   guard for the subtle race.
4. **`budgetNilMeansUnboundedInteractiveBehaviorPreserved`** — delegate
   with `budget: nil` + `.alwaysAsk`; assert it suspends indefinitely (as
   before) — i.e. the interactive chat path is unchanged.
5. **`acceptEditsNonEditToolAlsoAutoRejects`** — `.acceptEdits` policy on a
   non-edit tool (so it defers, line 362) with a small budget; assert
   auto-reject (covers the second deferring callsite).
6. **`cancelAllPendingStillDrainsAfterTimeout`** — a timed-out request +
   a still-pending one; `cancelAllPending()` drains the survivor without
   double-resuming the already-timed-out one.

Add to `Tests/WikiFSTests/AgentLauncherPermissionModeTests.swift` (fast-tier):

7. **`ingestReadsOwnKeyNotChat`** — set
   `chatPermissionMode = .alwaysAsk`, `ingestPermissionMode = .bypass`;
   assert `resolvePermissionMode(for: .ingest) == .bypass`. (This is the
   exact diagnosed-bug state from #607, now fixed.)
8. **`chatPolicyIndependentOfIngest`** — set chat=`alwaysAsk`,
   ingest=`bypass`; assert `resolvePermissionMode(for: .chat) ==
   .alwaysAsk`.
9. **`legacyKeyMigratesIntoChatOnce`** — set legacy
   `agentPermissionMode = "alwaysAsk"`; run `PermissionModeMigration.migrateOnce()`;
   assert `chatPermissionMode == "alwaysAsk"` and a second `migrateOnce()`
   is a no-op (idempotent).
10. **`defaultsWhenUnset`** — clear all keys; assert each kind resolves to
    `.bypass`.

### 8.3 What NOT to add

- No live-agent integration test (needs a real ACP agent subprocess + creds —
  the spike can't validate this end-to-end; the diagnosis already did the
  empirical validation). Keep all new tests pure/unit.

### 8.4 CI

- `swift build` clean.
- Fast tier: `swift test --skip 'EnumeratorDeletionTests|SQLiteWikiStoreTests|StoreEmissionTests|FreshSchemaParityTests|SQLiteStatementLifecycleIntegrationTests|BlobVacuumTests|AgentCASTests|GenerationGateLaneTests|WorkspaceStagingTests|WorkspaceMergeCompletenessTests|IngestIsolationTests|ChatSummaryTests|ProjectionTreeTests'`
  — green. If a new slow suite is introduced, tag `.integration` AND append
  its name to the `--skip` regex in `.github/workflows/ci.yml` (both Swift
  jobs run; the integration job is the gating one).
- Full `swift test` locally before opening the PR (both jobs must be green
  in CI).

---

## 9. Acceptance criteria (the PR must satisfy all)

1. **#606 repro no longer hangs:** a deferred permission request that is
   never resolved returns `cancelled` within `budget + ε` (≤ ~65s at the
   default 60s budget), instead of blocking until the 1800s ceiling. Proven
   by test #1 (§8.2).
2. **No continuation leak / double-resume:** the race is safe — proven by
   tests #2, #3, #6.
3. **Interactive chat unchanged:** with `budget: nil`, `alwaysAsk`
   suspends indefinitely (current behavior). Proven by test #4.
4. **#607 policy split:** `resolvePermissionMode(for: .ingest)` reads
   `ingestPermissionMode`, independent of chat. Proven by tests #7, #8.
   Default for ingest/lint/extraction is `.bypass`.
5. **Migration:** legacy `agentPermissionMode` migrates to
   `chatPermissionMode` once, idempotently. Proven by test #9.
6. **Settings UI:** three (or four) per-operation pickers replace the
   single Permission Mode picker; the chat composer chip governs chat only.
7. **Diagnostics:** the timeout logs via `DebugLog.agent` (visible in
   Console.app). No bare `try?`, no `print`.
8. **CI green** on BOTH Swift jobs (`swift` fast tier +
   `swift-integration`).
9. **No tree pollution:** the implementer works on `feature/acp-permissions`;
   `main` stays pristine. No scratch files (`pr-body.md`, etc.) committed.
10. **No regression** to existing `ACPBackendTests` permission family.

---

## 10. Risks / unknowns / things to verify at implementation time

- **The continuation race (§4.1) is the hard part.** The committed
  detached-timer form has correctness implications (single resume). The
  existing `removeValue`-then-resume discipline in
  `resolve`/`cancelAllPending` is the model; the new `timeOut(toolCallId:)`
  mirrors it. Do NOT switch to a `TaskGroup` form — awaiting `group.next()`
  from a child task of the same group does not compile under Swift 6.0
  strict concurrency (see §4.1 note #5). If unsure, consult
  `docs/skills/swift-concurrency-pro/SKILL.md` `bug-patterns`.
- **Budget value.** 60s is the issue's proposed default. For *interactive*
  chat, `nil` (unbounded) preserves current behavior — but consider whether
  an interactive stall should ALSO get a generous interactive budget (e.g.
  5 min) as a safety net. Out of strict scope but worth a flag for the
  reviewer. Default to `nil` for chat to avoid behavior change unless
  asked.
- **`ACPExtractionClient` policy** currently defaults to `.bypass` (line
  86) and may be constructed outside the launcher (e.g. from the queue).
  Extraction is **intentionally NOT touched in this PR** (see §5.1 note) —
  the call sites weren't fully enumerated, and `.bypass` is the correct
  default for read-heavy extraction anyway. A follow-up PR can thread a
  configurable `extractionPermissionMode` key if a caller needs it.
- **`OperationKind` naming** — don't collide with `WikiOperation.Kind`.
  Keep the permission-domain enum separate.
- **Settings UI clutter** — three pickers (chat/ingest/lint) may be noisy.
  The reviewer may prefer chat as primary + an "Advanced: per-operation"
  disclosure. Implement the straightforward grouped version first; defer
  the disclosure refactor if it reads as clutter.
- **`onPermissionTimeout` hook** (optional, for #608) — adding it now is
  cheap and sets up #608, but it's strictly plumbing. If the reviewer wants
  to keep the PR minimal, drop the hook and rely on `DebugLog` alone;
  #608 can add the hook when it builds the Activity row.
- **Does the budget need to be cancellable on session teardown?** Yes — a
  stray budget timer firing after `cancelAllPending()` is benign (it
  `removeValue`s, finds nothing, no-ops) but should be cancelled for
  cleanliness. The detached-timer form stores the `Task` on `Pending` and
  cancels it in both `cancelAllPending` and `resolve` (see §4.1 "Wire the
  timer cancellation"). This is specified, not an open question.
- **No live end-to-end validation possible** in this environment (no ACP
  agent + creds). The unit tests + the diagnosis's empirical trace are the
  evidence. The implementer should not block on a live repro.

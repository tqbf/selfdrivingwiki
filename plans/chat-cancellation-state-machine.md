# Chat cancellation and dispatch ownership

## Behavior

Cancel stops the current turn. The daemon retains other queued turns and continues them in durable FIFO order.
Full daemon shutdown is separate. Shutdown retains queued followers but does not promote or dispatch them.
The app keeps drafts editable during cancellation. It does not send a draft automatically.

The reverse-order report in issue #1382 remains unconfirmed. FIFO tests protect queue order, but do not establish that cancellation fixes that report.

## State authority

`ChatRuntimeSnapshot` owns session lifecycle, active-turn state, and queued turns.
`ChatSessionMachine` applies typed transitions. `DaemonChatController` owns persistence and runtime effects.
Compatibility booleans provide metadata only. They do not determine lifecycle.
A queued turn means pending work. It does not prove that another chat holds an admission slot.

| Current active state | Event | Result |
| --- | --- | --- |
| queued, submitting, responding, permission-waiting | matching cancellation request | cancelling |
| cancelling | repeated cancellation request | no second runtime effect |
| terminal, or another turn identity | cancellation request | reject without effects |
| cancelling | committed cancellation settlement | terminal cancelled, then oldest follower |
| nonterminal | shutdown terminal settlement | terminal outcome, retain followers without promotion |
| cancelling | cancellation persistence failure | nonterminal turn with retry attention |
| any | stale generation or duplicate terminal event | reject without effects |

Cancellation success follows the durable write. A store event must not advertise an uncommitted outcome.
The controller synchronously publishes the authoritative sync projection after each accepted transition.

## Effect ownership

The controller uses one internal `DispatchOwnership` value. Public turn state describes behavior. Internal ownership determines who may perform effects.

| Ownership | Work |
| --- | --- |
| idle | no dispatch or teardown owner |
| preparing | prepare one target turn, retain task and operation identity |
| dispatching | retain generation, turn, claim, and dispatch task |
| active | retain the current claim |
| settling | gather usage, write the terminal outcome, await close, or retain a persistence failure |
| closing | close one settled runtime and rotate its generation |
| idleEviction | close a quiescent runtime, then honor any deferred drain request |
| shutdown | retain superseded work and settle without follower dispatch |

Each effect has a typed operation identity. Every completion compares its identity and generation after suspension.
Other callbacks can request a drain or close. They cannot replace a settlement owner.
Task cancellation is a request, not proof that provider work stopped.
Late preparation results must release their provider tokens, even when the provider ignores cancellation.

An unclaimed queued cancellation needs no runtime teardown or generation rotation.
A claimed cancellation must settle its durable row before runtime cleanup clears its claim.
Followers wait for cleanup and use the new generation after destructive launcher stop.
A cancellation with no live runtime still advances the generation and records it on the snapshot, so the terminal outcome is never rejected as stale.
Persistence failure retains the row and claim. Retry repeats settlement, not the cancelled prompt.
Cleanup failure retains close ownership. Followers remain blocked until cleanup succeeds.
An explicit request that names a follower is rejected. Only the active turn is a cancellation target.

## Runtime boundaries

Each host chat has a separate launcher, backend, callbacks, and task ownership.
Launchers from one host share the host admission gate and provider services only.
A cancellation must not stop another chat or release another chat's gate ownership.

## Client and wire contract

Chat sync wire version remains 1. The app and daemon must ship together in the same bundle.
The added event cases do not provide compatibility with older daemon binaries.
Existing encoded cases, identifiers, database formats, and Stop request shapes remain compatibility contracts.
The client validates generation and sequence, then accepts the server projection.
It derives cancellation from the projected active-turn state. It does not maintain another chat state machine.

The app drains its local queue only after daemon work and cancellation recovery finish.
A terminal active row permits drain readiness. A promoted daemon follower does not.
The local send retains its identity until submission acknowledgment, which prevents duplicate drains.

## Validation

Automated coverage must include transition identities, atomic store emission, FIFO continuation, actual gate contention, and cancellation races.
Coverage must also include every dispatch suspension, shutdown, persistence retry, sync replay, and isolated host launchers.
An NSWindow-hosted scenario must verify labels, controls, draft retention, local row order, and recorded transport submissions.
Focused tests precede full macOS Make and bare SwiftPM gates. Async test waits must be bounded and release suspended work during cleanup.

Implementation and validation results are recorded in `progress/`.

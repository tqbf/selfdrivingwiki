# The resource-change event bus (#129 slice 2a)

**Status: shipped.** This is the design-of-record for slice 2a of the #129
access layer — a single **per-wiki resource-change event bus**. Roadmap
authority: [`architecture-roadmap.md`](architecture-roadmap.md) §2.2 (2a) and
§3 (the event bus — one signal, four hosts). This doc records what shipped; the
roadmap records the layered motivation.

## What it is

`WikiEventBus` (`Sources/WikiFSCore/WikiEventBus.swift`) is a per-wiki,
thread-safe fan-out for `ResourceChangeEvent` — a thin `(wikiID, kind, id,
change, origin, seq)` hint. Emission moved from ~17 hand-wired
`WikiStoreModel.onPageDidChange?()` fire-sites to the **method-atomic store
write seam**, so every mutation — regardless of caller (model, direct UI view,
future background job) — emits exactly one event. The File Provider signaler and
the cross-process `WikiChangeBridge` both became **subscribers/adapters** on one
mechanism. This collapses the three ad-hoc mechanisms (`onPageDidChange`, the
bridge's direct reload+signal, `ChangeCoalescer`'s FP-only debounce) into one
bus, with coalescing moved to the subscriber edge.

## The event vocabulary

```swift
enum ResourceKind: String, Sendable { case page, source, systemPrompt, wikiIndex, log, bookmark }
enum ChangeKind:   String, Sendable { case created, updated, deleted }
enum EventOrigin:  String, Sendable { case local, external }

struct ResourceChangeEvent: Sendable, Equatable {
    let wikiID: String        // stamped by the per-wiki bus
    let kind: ResourceKind?   // nil = coarse, whole-wiki change (the bridge's external reload)
    let id: String            // resource id; "" for coarse events
    let change: ChangeKind
    let origin: EventOrigin
    let seq: UInt64           // bus-stamped, monotone per emit
}
```

- **`kind` is optional.** A concrete kind matches its own kind-filtered
  subscribers plus all-events subscribers. A `nil` kind (the bridge's coarse
  external reload — the Darwin notification carries no per-resource detail)
  reaches **only** all-events (nil-filtered) subscribers.
- **`origin` is a transitional field.** It exists only because 2a keeps the
  model self-managing on its own writes: the model subscribes `.external`→reload
  and ignores `.local`; the FP subscribes to both. Once the model becomes a pure
  reload subscriber on ALL events (slice 2b), `origin` is removed and the shape
  matches §3 decision 2's `(wiki, seq, kind, id, change)` exactly.
- **`seq` is bus-stamped and present but unconsumed** in 2a (reserved for the
  future daemon resync handshake). `changeToken()` is **unchanged** — events are
  hints; the token stays ground truth (this sidesteps the §5 token conflict).
- **Embeddings do not emit** (derived data, not in the token).

## How emission works (the `mutate()` seam)

Every public mutating method on `SQLiteWikiStore` routes its body through a
private `mutate(event:_:)` helper — the single lock/flush seam:

1. It acquires the recursive `lock`, runs the body (the body may call
   `withTransaction`, which re-enters the recursive lock, and may compose other
   public methods that themselves route through `mutate`).
2. It computes the event from the result **while still locked** (reads
   committed, in-transaction state).
3. It tracks **its own** nesting depth (distinct from the store's
   `transactionDepth`) and flushes the event to `eventBus` **only when its depth
   returns to 0** — the outermost `mutate()` — and strictly **after** its
   `lock.unlock()` has released the outermost acquisition.

This makes the §3 guarantees **structural, not conventional**:

- **(a) No handler runs under the lock** → no deadlock under recursive
  composition or nested `withTransaction`.
- **(b) Subscribers read committed state** — the flush is post-commit
  (the bus dispatches handlers via `Task { @MainActor in … }`, which run only
  after `emit`, which fires after the depth-0 unlock).
- **(c) Nested public-calls-public emits exactly once** at the outermost exit
  (the inner event is computed but never flushed).
- **On throw, no event is flushed** — a rolled-back mutation emits nothing.

The flush depth is keyed off `mutate`'s **own** counter, **not**
`transactionDepth`: that counter decrements to 0 *inside* `withTransaction`'s
`defer`, *before* the lock is released, so keying off it would emit under the
lock — the exact deadlock (a) prevents.

## Who emits, who subscribes

**Emitters:**
- `SQLiteWikiStore` — one `.local` event per public mutating method (23 methods;
  see the Appendix of the shipped plan / `StoreEmissionExhaustivenessTests`).
- `WikiChangeBridge.flush` — one coarse `.external` event into the active
  store's bus (active wiki), or a direct FP signal (non-active wiki).
- `wikictl` (separate process) is **untouched**: it opens its own store with a
  `nil` bus (emit is a no-op) and keeps posting the Darwin notification.

**Subscribers:**
- `FileProviderSpike` — subscribes a **debounced** `signalChange(forWikiID:)` to
  the active store's bus (all kinds, both origins). Debounce reuses the pure
  `ChangeCoalescer`, now at the subscriber edge (§3 decision 4). The old token
  is unsubscribed on each store swap (no leak).
- `WikiStoreModel` — subscribes filtered to `.external` → `reloadFromStore()`
  (preserving the pre-2a "model reloads only on external writes" behavior).
  **Local events are ignored** — the model keeps self-managing via
  `reloadSummaries()`/`reloadSources()` (the lowest-risk cut; reload-on-self-write
  is deferred to slice 2b).

## The load-bearing invariant (for future work)

> **Every new public mutating method on `SQLiteWikiStore` MUST route through
> `mutate()` and emit a `ResourceChangeEvent`, or be explicitly annotated
> no-emit with a reason (derived embeddings, search index, migrations).**

`StoreEmissionExhaustivenessTests` enforces this: it parses every `public func`,
asserts each is in exactly one of {EMIT, READ, NO-EMIT} (no gaps/overlap), and
that every EMIT member's source contains a `mutate(` call. A newly added
unclassified mutator — or an EMIT method that stops routing through `mutate()` —
fails the test. Graph-model Phase 1+ adds ref-repoint/version-append methods;
without this rule the File Provider would silently go stale on exactly the
served-bytes-change-while-the-`sources`-row-is-untouched case the bus exists to
catch (§3 decision 5).

## Tests

| AC | Test |
| --- | --- |
| AC.1 bus unit | `WikiEventBusTests` |
| AC.2 per-method emission + exhaustiveness guard | `StoreEmissionTests` + `StoreEmissionExhaustivenessTests` |
| AC.3 reentrancy safety | `StoreEmissionReentrancyTests` |
| AC.4/AC.7 FP debounce seam (burst → one signal) | `FPIfSubscriberDebounceTests` |
| AC.5 `.external` → model reload (Core seam) | `WikiChangeBridgeBusTests` |
| AC.6 no `onPageDidChange` in `Sources/` | `NoOnPageDidChangeTests` |
| AC.8 bookmark events | `StoreEmissionTests` |
| AC.9 full suite regression | `swift test` |

**Test-infrastructure note:** the project has no live File-Provider/Darwin
harness, so AC.4/AC.5 are tested at the *seam* (the bus subscriber and the
bridge's flush effect) using fakes + `ChangeCoalescer`'s fake-clock pattern, not
against a real extension — matching how `ChangeCoalescer` is already tested.
The Darwin ingress itself remains untestable, as today.

## Non-goals (deferred)

- The `Resource` protocol + generic per-kind `changeToken` (slice **2b**).
- Making the model a pure reload subscriber on ALL events (drop self-management)
  → then `origin` is removed.
- Consuming `seq` (the daemon resync handshake), granular external events, and
  bookmark File Provider projection (#125).
- `changeToken()` is unchanged in this slice.

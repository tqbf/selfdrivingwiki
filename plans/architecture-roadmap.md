# Architecture roadmap — how the large efforts relate and sequence

**Status:** organizing doc (analysis of record). Captures how four big
architectural changes relate, the recommended order to build them, the one
open sequencing decision (§4), and the one cross-cutting component that must
be designed once because it outlives every host: the event bus (§3). Not
itself a build plan — each effort keeps its own design doc / issue; this is
the map that sits above them. Re-read whenever a new "large" change is
proposed, to check whether it lands at an existing layer or adds a new one.

**The four efforts on the plate:**

| Effort | Where | What it is |
|---|---|---|
| **Graph model & versioning** | [`plans/graph-model-and-versioning.md`](graph-model-and-versioning.md) | Storage truth: git's objects-vs-refs discipline in SQLite — content-addressed `blobs`, append-only `source_versions`/`activities`, mutable `refs`, PROV provenance, ULID-canonical links, version pinning. Phase 0 (concurrency substrate) done; Phases 1–7 ahead. |
| **#129 — Resource abstraction** | [issue #129](https://github.com/tqbf/selfdrivingwiki/issues/129) | Access layer: one `Resource` protocol so a new kind (page/source/bookmark/chat) gets File Provider projection + MCP + future exposure "for free," plus the resource-change **event bus** (§3) fanning one change signal to all surfaces. |
| **#162 — Multi-window** | [issue #162](https://github.com/tqbf/selfdrivingwiki/issues/162) | Client UX: tear-off tabs, Shift-click→new window (giving the binding [#161](https://github.com/tqbf/selfdrivingwiki/issues/161) deliberately reserved its target), a second browsing window, and **different wiki per window**. Hardest part is splitting window-local state out of the singular `WikiStoreModel` — needed for *every* window model, and it survives the daemon (§2.3). |
| **#187 — gRPC daemon** | [issue #187](https://github.com/tqbf/selfdrivingwiki/issues/187) | Distribution layer: extract the engine (ingest / PDF extraction / Ask-Edit / SQLite stores) out of the GUI app into a standalone, headless daemon — **owner of the wiki registry and sole owner of every wiki's store** — fronted by gRPC (REST/MCP as adapters). Solves headless + multi-Mac concurrency. |

Related efforts this roadmap places (see §6 for where each lands):
[#124](https://github.com/tqbf/selfdrivingwiki/issues/124) (MCP server),
[#125](https://github.com/tqbf/selfdrivingwiki/issues/125) (bookmarks projection),
[#119](https://github.com/tqbf/selfdrivingwiki/issues/119) (agent conversations),
[#130](https://github.com/tqbf/selfdrivingwiki/issues/130) (extraction backends),
[#165](https://github.com/tqbf/selfdrivingwiki/issues/165) (closed — the
cross-process divergence bug class the daemon structurally forecloses).

---

## 1. The three-layer model — plus the signal that crosses it

The four efforts are not peers. They sit at three different layers, and each
layer's truth should settle before the one above builds on it. One component
— the event bus — is not a layer at all: it crosses all three.

```
  ┌───────────────────────────────────────────────────────┐   ┌──────────────┐
  │ DISTRIBUTION   #187 daemon (gRPC), multi-wiki         │   │              │
  │                absorbs #124 MCP, hosts #130           │ ← │ streams it   │
  ├───────────────────────────────────────────────────────┤   │              │
  │ ACCESS         #129 Resource abstraction              │   │  EVENT BUS   │
  │                one way to enumerate/read/notify       │ ← │  (§3)        │
  ├───────────────────────────────────────────────────────┤   │  fans it out │
  │ STORAGE        graph-model (Phases 1–7)               │   │              │
  │                [Phase 0 done]  refs / blobs / PROV    │ → │ emits it     │
  └───────────────────────────────────────────────────────┘   └──────────────┘

   #162 multi-window straddles ACCESS + client: its per-window state
   split survives the daemon; its multi-wiki bookkeeping is dissolved
   into daemon sessions (§2.3, §4).
```

- **Storage** is what the bytes *mean*. Everything reads/writes through it.
  One SQLite file per wiki; one method-atomic store per file.
- **Access** is how surfaces *see* storage — enumerate, read on demand, get
  told it changed. One generic shape instead of N per-kind copies.
- **Distribution** is how *other processes* reach the engine — the boundary
  drawn around a stable storage + access core. Explicitly **multi-wiki** (the
  daemon owns the registry of wikis and one store per wiki; every RPC is
  wiki-scoped) and explicitly an **active engine** — it writes on its own
  schedule, not only in response to client RPCs (§2.4).
- **The event bus** is the change signal that crosses all three: storage
  *emits* it (at the write seam), access *shapes* it (wiki + resource kind +
  id), distribution *streams* it (gRPC / SSE / MCP). It is the least-defined
  piece today and the one every other effort touches — §3 defines it.

---

## 2. Recommended sequence

**graph-model → #129 (bus first, then Resource) → (partial) #162 → #187.**
The bus slice of #129 is storage-independent and can start any time, in
parallel with graph-model phases.

### 2.1 graph-model first (storage truth)

Already started (Phase 0 done). Continue Phases 1–7. Rationale:

- It fixes **real correctness bugs** (no dedup, lost URL/extraction provenance,
  the rename-drops-links class, divergent resolution tiebreaks).
- It **changes what "source content" means**: `sourceContent(id:)` becomes
  ref→version→blob resolution, and byteless sources (`blob_hash IS NULL`)
  appear. Both #129 and #187 model content on top of that resolution — so
  settle it first.
- Its 3 new `changeToken` folds (graph-model §10) want to land **concretely**
  before #129 generalizes the token (§5 below).

**Gate to clear before moving on:** Phase 1 (objects & versions) — drops
`sources.content`, settles the ref→version→blob resolution + byteless support.
That is the storage truth the access layer is built over.

### 2.2 #129 second (access layer) — best done in two decoupled slices

- **(2a) The event bus — SHIPPED.** One resource-change event fanned to every
  subscriber, replacing today's three ad-hoc mechanisms (the ~17 hand-wired
  `onPageDidChange` sites, the `WikiChangeBridge` Darwin ingress, the
  `ChangeCoalescer` debounce). Storage-independent — it landed early / in
  parallel with later graph-model phases — and is a **prerequisite for the thin
  #162 slice** (two windows on one wiki need cross-window invalidation, which
  is just a second subscriber). It is also the direct precursor to the
  daemon's multi-client streaming: gRPC server-stream, REST SSE, and MCP
  `notifications/resources/list_changed` all multicast the *same* event.
  Designed once, per §3 — it becomes the thing the daemon later serializes.
  See [`plans/event-bus.md`](event-bus.md); full test gate in `PROGRESS.md`.
- **(2b) Resource protocol + projection dedup + generic changeToken.** Do this
  **after graph-model Phase 1**, so it models refs/blobs/byteless from the
  start instead of over the flat `sources.content` it would have to rewrite.
  The generic changeToken here is the natural home for graph-model's 3 folds.

### 2.3 #162 partial, in-process (client UX)

The daemon-independent slice is worth doing now — but its cost should be
stated honestly, because it is larger than "thin":

- Tear off a tab into a new window.
- Shift-click a `wiki://` link → new window (giving
  [#161](https://github.com/tqbf/selfdrivingwiki/issues/161)'s
  deliberately-reserved Shift binding its target; #161 itself is closed — it
  shipped plain-click / ⌘-click).
- File → New Window: a second independent browser on the **same** wiki.

**All three require the per-window model split.** Window-local state —
`tabs`, `activeTabID`, `selection`, drafts, navigation history,
`pendingScrollAnchor` — is single-valued on the one `WikiStoreModel` (#162
scope decision 3); two windows on one wiki means two models over one store,
plus cross-window write invalidation (a bus subscriber — 2a is a
prerequisite). That split is most of #162's engineering, and it is **not
throwaway**: under the daemon each window still needs its own client-side
view model over its own session. It survives both worlds unchanged.

**What genuinely defers** is `WikiManager`'s multi-wiki bookkeeping — an
ordered set of open (wiki, model) pairs plus a focused-window notion for
app-global concerns — which #187 dissolves into per-session state. So the
accurate cut is not "thin UX slice vs. heavy refactor" but **per-window model
split now (survives the daemon) vs. multi-store manager bookkeeping later
(dissolved by it)**. §4 records the open decision this leaves.

### 2.4 #187 last (distribution / the stable boundary)

The daemon is the biggest, most speculative change (issue itself says
"starting point for design, not final"), with real open questions: auth beyond
localhost, gRPC library choice on Apple, process management (launchd agent),
thin-client-vs-standalone. Draw that boundary **around a now-stable engine**
(post graph-model Phases 1–N + #129 access layer), not across one still being
reshaped by graph-model Phases 1–7 — otherwise you either freeze the engine
early or churn the proto schema.

**The daemon is multi-wiki, explicitly.** "Sole owner of the store" is
underspecified — the app manages N wikis (that is `WikiManager`'s whole job
today), so the daemon owns the **wiki registry** (create / delete / rename /
enumerate wikis) plus **one method-atomic store per open wiki**, with a
per-wiki open/close lifecycle (and, eventually, idle eviction). Consequences
worth locking early because they shape the proto schema:

- **Every RPC is wiki-scoped** — a wiki id on each request, or a session
  bound to a wiki at open. Sessions-bound-to-wikis is what makes #162's
  different-wiki-per-window a thin client concern: window → session → wiki.
- **`WikiManager` splits along this line**: its registry role (the wiki list,
  MRU, create/delete) migrates into the daemon; its binding role (which wiki
  a given window shows) becomes per-session client state. Nothing of it
  survives as a singleton.
- **The bus is per-wiki** (§3): events carry the wiki scope, subscribers
  subscribe per wiki, and the registry itself is a change source (wiki
  created/deleted/renamed) with its own small vocabulary.
- **changeToken stays per-wiki** — it is a fold over one store's tables; the
  daemon exposes it per wiki for the resync handshake (§3).

**The daemon is an active writer, not a passive endpoint.** Client RPCs are
not the only mutation source: the engine runs its own work — scheduled
provider refreshes, queued extraction/conversion (#130), agent ingests
running headless — and each of these writes a store and emits events with no
client involved. graph-model's `activities` are exactly the unit of this
background work: a scheduled conversion is an extract activity like any
other, provenance included. Two consequences worth locking early:

- **Server-push is first-class in the proto, not an afterthought.** The gRPC
  surface leads with the per-session event stream (§3), because a client
  that only hears about its own writes is now wrong by default — the app is
  one client among several, continually updated.
- **The app UI must absorb unsolicited change as the steady state.** Today
  external writes are the edge case (`wikictl` via the Darwin bridge); under
  the daemon they are constant. The per-window models (§2.3) are bus
  subscribers first, write-initiators second — and a draft being edited
  while a background activity touches the same resource is the
  agent-vs-human conflict graph-model §14 already anticipates (divergent
  versions, not clobbers).

**The boundary makes the daemon's language a choice, not a given.** Once the
contract is proto, no client cares what implements it — which also softens
#187's "gRPC library choice on Apple" question (grpc-swift maturity stops
being load-bearing) and opens non-macOS deployment. But the option is not
free: the engine the daemon extracts *is* `WikiFSCore` in Swift — the store,
the migration ladder, link parse/rewrite — and graph-model Phases 1–7 deepen
that investment. A non-Swift daemon is a **rewrite, not an extraction**,
contradicting this section's own draw-the-boundary-around-a-stable-engine
rationale. Decision of record:

- **Default: a Swift daemon reusing `WikiFSCore`** (an SPM executable target,
  the `wikictl` precedent) — the only shape that is an extraction.
- **The proto keeps the rewrite option permanently open**, on two conditions
  of discipline: the proto is the spec (no Swift types or `WikiFSCore`
  conventions leaking into it — anyone should be able to implement it from
  the `.proto` files alone), and Apple-only dependencies stay behind seams at
  the edges (NLEmbedder / the CoreML embedder, Keychain credential storage,
  the PodcastsFoundation path — the pieces a Linux or non-Swift
  implementation would swap, not port).

**Convergence with graph-model — stated precisely.** The daemon does *not*
fall out of graph-model's assumptions; it **retires one of them**. graph-model
§1 and §8 assume the opposite of single ownership — *three processes on one
file* (app writer, `wikictl` writer, FP reader) served by plain WAL; the
CozoDB rejection partly leaned on that ("wikictl and the extension can open
the DB and read meaningful rows"). Under the daemon, both come off direct
SQLite and become gRPC clients — by graph-model's own "don't relitigate
without new facts" discipline, the daemon *is* new facts for its §1 (the
conclusion stands — CozoDB stays rejected — but the multi-process-WAL reason
converts into a single-owner reason). What genuinely carries over unreworked
is the **schema**: immutable blobs and append-only version rows shrink what
the RPC boundary must coordinate — clients may cache blob content by hash
forever — and `refs` gives the daemon one tiny mutation surface to serialize
per wiki. One question this surfaces that #187 does not yet list: **the File
Provider extension as a network client** (appex lifecycle, sandbox/network
entitlements, enumeration latency) — recorded in §7.

Why not first (the "do the hard thing once" argument), rejected for *this*
project:

1. The engine internals are still moving (graph-model Phases 1–7 reshape
   ingest/extract/content). A stable RPC boundary across a moving engine is
   premature.
2. The daemon has major unresolved design questions — it is not ready to be a
   foundation.
3. Pre-launch, single-machine: the multi-process need is aspirational, not
   blocking. graph-model §8 already solved the *in-process* concurrency
   (method-atomic store + `WikiReadPool`), which is what's needed today.

Several efforts ride along when it lands:

- [#124](https://github.com/tqbf/selfdrivingwiki/issues/124) (MCP server)
  rehosts as one of the daemon's external adapters and gains **actions**, not
  just read-only resources — but it need not *wait* for the daemon (§6).
- [#130](https://github.com/tqbf/selfdrivingwiki/issues/130) (extraction
  backends) get a natural async home independent of the app lifecycle.
- [#162](https://github.com/tqbf/selfdrivingwiki/issues/162)'s per-window-
  different-wiki becomes a thin per-session gRPC concern (§2.4 bullet 1).
- [#165](https://github.com/tqbf/selfdrivingwiki/issues/165)-class
  cross-process divergence bugs (app and `wikictl` each stamping a different
  embedder identifier into one file; #165 itself is closed, fixed in-process):
  the bar is "one owner serializes all writers," which the daemon is,
  structurally — per wiki.

---

## 3. The event bus — one signal, four hosts

#129 scopes the change-propagation slice in one sentence ("kind + id +
created/updated/deleted"). The daemon future makes it a first-class design
problem: under #187 **every client is remote**, and change notification *is*
the product — a GUI that doesn't hear about another writer is broken in a way
single-process code never exposed. And "another writer" is not mainly other
*clients*: it is the **engine itself** — scheduled conversions, provider
refreshes, agent ingests running with no client attached (§2.4). The bus must
therefore never assume the GUI is the primary producer; the app is a
subscriber that happens to also write. Define the model once, now, so the
in-process version and the gRPC version are the same thing with different
transports.

**What exists today — three ad-hoc mechanisms, each solving one edge:**

- `WikiStoreModel.onPageDidChange` — a single closure, fired by hand at ~15
  write sites *in the model*, wired by `WikiFSApp` to the File Provider's
  `signalChange()`. Emission at the model layer is *why* the sites are
  hand-wired: any write that bypasses the model must remember to fire it.
- `WikiChangeBridge` — Darwin notifications, the cross-process ingress for
  `wikictl` writes → `reloadFromStore()`.
- `ChangeCoalescer` — debouncing, hard-coded to the FP signaling path.

**The model (decisions of record):**

1. **Emission moves to the store write seam.** Every mutation already flows
   through `SQLiteWikiStore`'s method-atomic public surface; that is the one
   place an event can be emitted *without* per-call-site wiring. The UI model
   becomes subscriber #1 (it reloads instead of self-firing) and the ~15
   sites collapse. Pre-daemon, `wikictl` remains a second process: its own
   store emits into its own (subscriber-less) bus, and the Darwin bridge
   survives as an *adapter feeding the app's bus* an equivalent
   external-change event — one mechanism, two inputs. Post-daemon there is
   one process; the bridge retires with the WAL accommodation.
2. **Thin events, notify-then-pull.** The event is
   `(wiki, seq, kind, id, change ∈ created|updated|deleted)` — a notification
   that something about resource X changed, never a delta or payload.
   Subscribers re-read through the normal read path. Every target surface
   already imposes exactly this shape — FP `signalEnumerator` (notify;
   enumerator pulls), MCP `list_changed` (notify; client re-lists), SSE
   change pings — so a delta schema would be a versioned payload contract no
   consumer wants.
3. **The changeToken stays the ground truth; events are hints.** `seq` is a
   per-wiki monotone stamped under that store's lock — ephemeral, never
   persisted. Stream (re)connection handshake: the session binds a wiki, the
   server sends that wiki's current changeToken, a stale client re-enumerates,
   then consumes events. **No durable event log, no replay** — deliberate:
   the resync primitive (token compare + re-enumerate) already exists, and
   graph-model's immutable blobs make resync cheap to verify (content is
   hash-stable). Revisit trigger: a client for whom full re-enumeration is
   prohibitive (very large wiki over a WAN link).
4. **Coalescing at the subscriber edge, not at emission.** FP wants a
   debounce (today's `ChangeCoalescer`, generalized to per-subscriber
   policy); the UI wants immediacy; network streams want small batches. A
   global debounce would impose the slowest consumer's policy on everyone.
5. **The vocabulary must cover graph-model's mutations.** A ref repoint or a
   version append changes the bytes a source serves *without touching the
   `sources` row* — both must surface as `(source, id, updated)`. The
   wiki-scoped changes the changeToken already folds (system prompt, log,
   wiki index) need kinds too (or one `wiki` kind; decide in the 2a design).
   The **registry** is its own change source (wiki created/deleted/renamed) —
   in-process that is `WikiManager` news, under the daemon a registry-level
   event stream alongside the per-wiki ones. Future kinds — `chat` (#119),
   `bookmark` (#125) — are vocabulary rows, not new mechanisms.

**Producers and subscribers, now and later** — the test of the design is
that both lists grow without the bus changing shape. Producers (all funnel
through the store write seam, so none needs bespoke wiring): today the UI
model's writes and `wikictl` (via the bridge adapter); with graph-model
Phase 3+, provider refreshes and extraction runs; under the daemon,
scheduled/queued background activities and every gRPC client's writes — at
which point the app originates a *minority* of events.

| When | Subscriber | Consumes as |
|---|---|---|
| now | File Provider `signalChange()` | debounced signal |
| now | the active `WikiStoreModel` | immediate reload |
| #162 thin slice | every window's model on the same wiki | cross-window invalidation |
| daemon | per-session gRPC server-streams | serialized events, wiki-scoped |
| daemon | MCP adapter | `notifications/resources/list_changed` |
| daemon | REST adapter | SSE pings |

---

## 4. The one open sequencing decision: #162

Everything above is fairly robust *except* the #162 call — and the roadmap
must be explicit that its recommendation **amends a recorded operator
decision**: issue #162 states that different-wiki-per-window "is expected to
be a common workflow … a **first-class MVP goal**, not an edge case."
Deferring it is not a default to slide into; it needs the operator's explicit
sign-off, recorded here.

- **(Recommended) Ship the per-window slice now; defer multi-wiki windows to
  the daemon.** The per-window model split + same-wiki windows (tear-off,
  second window, Shift-click) land now and survive the daemon unchanged
  (§2.3); the `WikiManager` multi-store bookkeeping — needed *only* for
  different-wiki-per-window — waits and arrives as per-session state under
  #187 (§2.4). **This amends #162's recorded MVP scope.** Choose it if the
  daemon is the real multi-wiki answer and near-term demand is tolerably met
  by switching wikis serially.
- **(Alternative) Full in-process #162, honoring the issue's MVP as
  recorded.** Add the ordered-set `WikiManager` refactor now. The rework risk
  is contained — the per-window split survives either way; only the manager
  bookkeeping converts to daemon sessions when #187 lands — so this is less
  wasteful than it first appears. Choose it if different-wiki-per-window is a
  near-term must-have *and* the daemon is far off.

Record the chosen branch here when decided.

---

## 5. Conflicts to mind — same files, so sequence, don't parallelize

- **`changeToken()`** — touched by both graph-model (3 new folds, §10) and #129
  (generic per-kind folding). Let graph-model land concretely first; then #129
  generalizes the whole token so each Resource kind declares its own fold
  (graph-model's source/source-version/ref folds become the *source* resource
  contribution). This is a clean evolution, not a conflict — but it must be
  ordered.
- **`changeToken()` vs the bus's `seq`** — two monotone counters with
  different jobs: the token is the durable, per-wiki ground truth (a fold
  over one store's tables); `seq` is an ephemeral in-process ordering stamp
  (§3 decision 3). Do not merge them — persisting `seq` recreates the
  event-log problem §3 deliberately avoids.
- **Change-signal wiring** — the bus (2a, shipped) rewired the ~17 `onPageDidChange`
  sites and subsumed `WikiChangeBridge` / `ChangeCoalescer` into subscribers on
  one per-wiki `WikiEventBus`; #162's thin slice then subscribes per-window
  models to it. The store now emits at the `mutate()` seam; the FP and the
  model's `.external`→reload path subscribe. See [`plans/event-bus.md`](event-bus.md).
- **`Projection.swift`** — touched by both graph-model and #129. graph-model's
  near phases mostly *punt* the projection overhaul (its §9/§10 defer it to
  late phases), so the clash is smaller than it looks — but keep #129's
  projection dedup after graph-model Phase 1's content-resolution change so
  the generic "project this resource" helper models ref→version→blob and
  byteless from the start.
- **`WikiManager` / `WikiStoreModel`** — touched by #162 (per-window models)
  and by #187 (registry → daemon, binding → sessions, §2.4). The §4 fork
  governs the timing.

---

## 6. Where the related efforts land

- **#124 (MCP server) — does not wait for the daemon.** As scoped (read-only
  resources, localhost) it ships in-app right after #129: a thin adapter over
  the Resource layer, plus a bus subscription for `list_changed`. When #187
  lands it rehosts inside the daemon (and gains actions) — cheap precisely
  because #129 is the layer both hosts share. Sequence it by MCP demand, not
  by daemon readiness.
- **#125 (bookmarks projection) — the first test case of #129 (2b).** Its
  nested-folder + symlink-leaf shape is *more* than the flat by-id/by-name
  pattern; the Resource protocol must accommodate nested containers from the
  start, or #125 becomes the very hand-rolled copy it was filed to prevent.
- **#119 (agent conversations) — one storage decision + one resource kind.**
  Persistence is a storage-layer call: conversation + message tables should
  follow graph-model discipline (ULID identity, append-only messages; no
  blobs needed — transcripts are authored text, closer to pages than
  sources). Exposure is exactly a #129 kind (`chats/by-id`, `by-title`, a
  `[[chat:…]]` link kind) plus a bus vocabulary row. Sequence after #129
  (2b); daemon-independent.
- **#130 (extraction backends) — leaf additions now**, against the existing
  `MarkdownExtractor` seam; the daemon later gives long-running extractions a
  home independent of the app lifecycle (§2.4).
- **#165 — closed** (fixed in-process). It remains the type specimen for the
  cross-process divergence class the daemon structurally forecloses (§2.4).

---

## 7. Explicitly deferred / out of scope here

- Page versioning and wiki-level snapshots → [#258](https://github.com/tqbf/selfdrivingwiki/issues/258) / [#259](https://github.com/tqbf/selfdrivingwiki/issues/259).
- Editor ergonomics for canonical `[[page:ULID|Title]]` links → [#255](https://github.com/tqbf/selfdrivingwiki/issues/255).
- File Provider projection overhaul → [#260](https://github.com/tqbf/selfdrivingwiki/issues/260).
- Non-localhost auth for the daemon (#187 open question) — anything beyond
  `127.0.0.1` needs an auth story; gated on the daemon, not before.
- **FP extension ↔ daemon transport** — the extension currently reads SQLite
  directly; under #187 it must become a network client (appex lifecycle,
  sandbox/network entitlements, enumeration latency). Must be answered inside
  #187's design; listed here so it isn't discovered mid-build.
- **Durable event log / replay for the bus** — deliberately absent (§3
  decision 3); the revisit trigger is recorded there.
- **Daemon store lifecycle policy** (idle eviction, open-wiki limits) — a
  #187 design detail; only the *existence* of a per-wiki open/close lifecycle
  is locked here (§2.4).
- **Background-work scheduling** — graph-model Phase 3 designs the refresh
  *verb* and #130 the conversion backends, but nothing yet designs the
  *scheduler* (what re-fetches/re-converts, when, with what queueing and
  backoff). It is a daemon-hosted concern (§2.4 "active writer"); design it
  inside #187, not before — the bus and `activities` provenance are the
  substrate it will sit on.

## 8. When to revisit this doc

- When a **new** large change is proposed → does it land at an existing layer
  (storage / access / distribution / client), or add a fifth? If it cuts
  across layers, record the dependency here before starting. (#119 was the
  first test case; §6 places it.)
- When the **#162 fork** (§4) is decided → record the chosen branch — and if
  the recommended branch is taken, amend #162's MVP scope in the issue.
- When the **bus** (#129 2a) lands → its event vocabulary becomes the
  contract every distribution surface serializes; record vocabulary changes
  here alongside the layer map.
- When the **daemon** (#187) moves from "design" to "build" → this doc becomes
  the sequencing contract for the migration of app/wikictl/FP off direct
  store access onto gRPC, and for the registry's move out of `WikiManager`.

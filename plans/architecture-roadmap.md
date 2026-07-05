# Architecture roadmap — how the large efforts relate and sequence

**Status:** organizing doc (analysis of record). Captures how four big
architectural changes relate, the recommended order to build them, and the one
open sequencing decision. Not itself a build plan — each effort keeps its own
design doc / issue; this is the map that sits above them. Re-read whenever a new
"large" change is proposed, to check whether it lands at an existing layer or
adds a new one.

**The four efforts on the plate:**

| Effort | Where | What it is |
|---|---|---|
| **Graph model & versioning** | [`plans/graph-model-and-versioning.md`](graph-model-and-versioning.md) | Storage truth: git's objects-vs-refs discipline in SQLite — content-addressed `blobs`, append-only `source_versions`/`activities`, mutable `refs`, PROV provenance, ULID-canonical links, version pinning. Phase 0 (concurrency substrate) done; Phases 1–7 ahead. |
| **#129 — Resource abstraction** | [issue #129](https://github.com/tqbf/selfdrivingwiki/issues/129) | Access layer: one `Resource` protocol so a new kind (page/source/bookmark/chat) gets File Provider projection + MCP + future exposure "for free," plus a single resource-change event fanning to all surfaces (replacing ~15 hand-wired `onPageDidChange` sites). |
| **#162 — Multi-window** | [issue #162](https://github.com/tqbf/selfdrivingwiki/issues/162) | Client UX: tear-off tabs, Shift-click→new window (closes [#161](https://github.com/tqbf/selfdrivingwiki/issues/161)), a second browsing window, and **different wiki per window**. Hardest part is refactoring the singular `WikiManager.activeStore` into per-window models. |
| **#187 — gRPC daemon** | [issue #187](https://github.com/tqbf/selfdrivingwiki/issues/187) | Distribution layer: extract the engine (ingest / PDF extraction / Ask-Edit / SQLite store) out of the GUI app into a standalone, headless daemon — sole owner of the store — fronted by gRPC (REST/MCP as adapters). Solves headless + multi-Mac concurrency. |

Related efforts this roadmap absorbs or references (not on the plate directly):
[#124](https://github.com/tqbf/selfdrivingwiki/issues/124) (MCP server),
[#125](https://github.com/tqbf/selfdrivingwiki/issues/125) (bookmarks projection),
[#119](https://github.com/tqbf/selfdrivingwiki/issues/119) (agent conversations),
[#130](https://github.com/tqbf/selfdrivingwiki/issues/130) (extraction backends),
[#165](https://github.com/tqbf/selfdrivingwiki/issues/165) (store concurrency bug).

---

## 1. The three-layer model

These four are not peers. They sit at three different layers, and each layer's
truth should settle before the one above builds on it:

```
  ┌──────────────────────────────────────────────────┐
  │ DISTRIBUTION   #187 daemon (gRPC)              │  ← multi-process / multi-Mac
  │                absorbs #124 MCP, hosts #130  │     (the engine's stable boundary)
  ├──────────────────────────────────────────────────┤
  │ ACCESS         #129 Resource abstraction       │  ← one way to enumerate/read/notify
  │                + change-propagation bus          │     (kills per-kind duplication)
  ├──────────────────────────────────────────────────┤
  │ STORAGE        graph-model (Phases 1–7)          │  ← the truth model
  │                [Phase 0 done]                    │     (refs / blobs / PROV)
  └──────────────────────────────────────────────────┘

   #162 multi-window straddles ACCESS + client, and is
   mostly *dissolved* by the DISTRIBUTION layer.
```

- **Storage** is what the bytes *mean*. Everything reads/writes through it.
- **Access** is how surfaces *see* storage — enumerate, read on demand, get
  told it changed. One generic shape instead of N per-kind copies.
- **Distribution** is how *other processes* reach the engine — the boundary
  drawn around a stable storage + access core.

---

## 2. Recommended sequence

**graph-model → #129 → (partial) #162 → #187.**

### 2.1 graph-model first (storage truth)

Already started (Phase 0 done). Continue Phases 1–7. Rationale:

- It fixes **real correctness bugs** (no dedup, lost URL/extraction provenance,
  the rename-drops-links class, divergent resolution tiebreaks).
- It **changes what "source content" means**: `sourceContent(id:)` becomes
  ref→version→blob resolution, and byteless sources (`blob_hash IS NULL`)
  appear. Both #129 and #187 model content on top of that resolution — so
  settle it first.
- Its 3 new `changeToken` folds (graph-model §10) want to land **concretely**
  before #129 generalizes the token (§4 below).

**Gate to clear before moving on:** Phase 1 (objects & versions) — drops
`sources.content`, settles the ref→version→blob resolution + byteless support.
That is the storage truth the access layer is built over.

### 2.2 #129 second (access layer) — best done in two decoupled slices

- **(2a) Change-propagation bus.** One resource-change event
  (kind + id + created/updated/deleted) fanned to File Provider + UI (+ later
  MCP) subscribers, replacing the ~15 hand-wired `onPageDidChange` call sites.
  This is **storage-independent** — it can even land early / in parallel with
  later graph-model phases. It is also the **direct precursor to the daemon's
  multi-client streaming**: gRPC server-stream, REST SSE, and MCP
  `notifications/resources/list_changed` all multicast the *same* event. Design
  it once, well — it becomes the thing the daemon later serializes and
  multicrosses.
- **(2b) Resource protocol + projection dedup + generic changeToken.** Do this
  **after graph-model Phase 1**, so it models refs/blobs/byteless from the
  start instead of over the flat `sources.content` it would have to rewrite.
  The generic changeToken here is the natural home for graph-model's 3 folds.

### 2.3 #162 partial, in-process (client UX)

The genuinely UX-valuable, daemon-independent slice is worth doing now:

- Tear off a tab into a new window.
- Shift-click a `wiki://` link → new window (closes
  [#161](https://github.com/tqbf/selfdrivingwiki/issues/161)).
- File → New Window: a second independent browser on the **same** wiki.

**Defer** the heavy part — the `WikiManager.activeStore`→ordered-set refactor
and per-window-**different**-wiki — because #187 dissolves those into
per-window gRPC sessions (§2.4). See §3 for the open decision.

### 2.4 #187 last (distribution / the stable boundary)

The daemon is the biggest, most speculative change (issue itself says
"starting point for design, not final"), with real open questions: auth beyond
localhost, gRPC library choice on Apple, process management (launchd agent),
thin-client-vs-standalone. Draw that boundary **around a now-stable engine**
(post graph-model Phases 1–N + #129 access layer), not across one still being
reshaped by graph-model Phases 1–7 — otherwise you either freeze the engine
early or churn the proto schema.

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

**Nice convergence:** graph-model's single-process-owns-the-file assumption
(§1, §8) is fully consistent with the daemon being sole owner later — so
nothing is reworked. The WAL cross-process accommodation (app/wikictl/FP
sharing one file) is simply **retired** by the daemon, and several efforts
ride along:

- [#124](https://github.com/tqbf/selfdrivingwiki/issues/124) (MCP server)
  becomes one of the daemon's external adapters (and gains **actions**, not
  just read-only resources).
- [#130](https://github.com/tqbf/selfdrivingwiki/issues/130) (extraction
  backends) get a natural async home independent of the app lifecycle.
- [#162](https://github.com/tqbf/selfdrivingwiki/issues/162)'s per-window-
  different-wiki becomes a thin per-session gRPC concern.
- [#165](https://github.com/tqbf/selfdrivingwiki/issues/165)-class store
  concurrency bugs: the bar is "one owner serializes all writers," which the
  daemon is, structurally.

---

## 3. The one open sequencing decision: #162

Everything above is fairly robust *except* the #162 call, where reasonable
sequencing genuinely depends on operator priorities:

- **(Recommended) Ship the thin #162 slice now; defer per-window-different-wiki
  to the daemon.** The thin slice (tear-off, same-wiki second window,
  Shift-click) is high UX value under both the in-process and daemon models.
  The heavy `WikiManager` refactor risks being reworked when the daemon lands.
  Choose this unless different-wiki-per-window is an urgent, near-term need.
- **(Alternative) Full in-process #162 now.** Choose this only if
  different-wiki-per-window is a near-term must-have *and* the daemon is far
  off — accept that the `WikiManager` ordered-set refactor gets partly reworked
  into per-window gRPC sessions when #187 lands.

Record the chosen branch here when decided.

---

## 4. Conflicts to mind — same files, so sequence, don't parallelize

- **`changeToken()`** — touched by both graph-model (3 new folds, §10) and #129
  (generic per-kind folding). Let graph-model land concretely first; then #129
  generalizes the whole token so each Resource kind declares its own fold
  (graph-model's source/source-version/ref folds become the *source* resource
  contribution). This is a clean evolution, not a conflict — but it must be
  ordered.
- **`Projection.swift`** — touched by both. graph-model's near phases mostly
  *punt* the projection overhaul (graph-model §9/§10 defer it to late phases),
  so the clash is smaller than it looks — but keep #129's projection dedup
  after graph-model Phase 1's content-resolution change so the generic
  "project this resource" helper models ref→version→blob and byteless from the
  start.
- **`WikiManager` / `WikiStoreModel`** — touched by #162 (per-window models)
  and dissolved by #187 (per-window gRPC sessions). The §3 fork governs this.

---

## 5. Explicitly deferred / out of scope here

- Page versioning and wiki-level snapshots (graph-model §14) — the model makes
  them nearly free when wanted; not imminent.
- Editor ergonomics for canonical `[[page:ULID|Title]]` links (graph-model §13
  open question #3) — deferred until Phase 5 feedback.
- Non-localhost auth for the daemon (#187 open question) — anything beyond
  `127.0.0.1` needs an auth story; gated on the daemon, not before.

## 6. When to revisit this doc

- When a **new** large change is proposed → does it land at an existing layer
  (storage / access / distribution / client), or add a fifth? If it cuts
  across layers, record the dependency here before starting.
- When the **#162 fork** (§3) is decided → record the chosen branch.
- When the **daemon** (#187) moves from "design" to "build" → this doc becomes
  the sequencing contract for the migration of app/wikictl/FP off direct store
  access onto gRPC.

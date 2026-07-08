# #129 slice 2b — the Resource abstraction (access layer)

**Status:** plan / design of record for the second slice of the #129 access
layer. Slice 2a (the per-wiki resource-change event bus) shipped — see
[`event-bus.md`](event-bus.md). Roadmap authority:
[`architecture-roadmap.md`](architecture-roadmap.md) §2.2 (2b), §5
(`changeToken` conflict), §6 (#125 as the first test case), §3 (the bus this
sits beneath). This doc records the goal, the grounded state, the design
decisions, the phased build, and the open questions. It is *not* a per-PR
spec; each phase keeps its own short acceptance criteria here.

**One-line goal:** introduce a `Resource` abstraction (protocol + projection
descriptors + a composed `changeToken`) so a new resource kind gets File
Provider projection + (future) MCP (#124) + (future) REST "for free," and the
per-kind duplication in `Projection.swift` collapses to generic,
descriptor-driven code.

**Why now:** the gate that held 2b back — graph-model Phase 1 settling the
ref→version→blob content resolution — cleared long ago (Phases 0–6 are all
shipped). The bus (2a) is in place. 2b is the next structural step and the
layer the daemon (#187) and MCP (#124) both build on.

---

## What exists today (grounded)

- **`Projection.swift`** (748 lines, `WikiFSFileProvider`) hard-codes the
  whole mount tree. Three repetition patterns live in it:
  - **Flat leaf kinds** — `pages` (`by-id`/`by-title`) and `sources`
    (`by-id`/`by-name`, plus a `.md` markdown sibling). Each has its own
    `Identity` prefix, its own `*Node` builder (`pageFileNode`,
    `sourceNode`, `sourceMarkdownNode`), its own `pageNodes(byTitle:)` /
    `sourceNodes(byName:)` enumerator, and its own arms in the `node(for:)`
    and `children(of:)` switches. The two are structurally identical except
    for which store method they call and how the filename/version is built.
  - **Singleton doc kinds** — system prompt (`CLAUDE.md`/`AGENTS.md`),
    `index.md`, `log.md`, `WIKI-STRUCTURE.md`/`TREE.md`. Each has a bespoke
    `*Document()`/`*Node()` builder, all versioned by either a row `version`
    or the whole-DB change token.
  - **Generated index kinds** — `manifest.json`, `pages.jsonl`, `links.jsonl`,
    `sources.jsonl`. These already share a token-keyed `IndexCache` +
    `indexFileNode` (the one place the dedup pattern already exists).
- **`changeToken()`** (`SQLiteWikiStore.swift:1762`) is one hardcoded 11-field
  fold: `pages(count:sum) : sources(count:sum) : systemPrompt : log : wikiIndex
  : smvCount : svCount : refsGenSum : actCount`. Each field is a private
  `*Count()`/`*Version()` helper. Adding a kind means editing this string,
  adding a helper, and bumping every test that hardcodes the literal.
- **`WikiStore` protocol** has per-kind read methods (`listAllPagesOrderedByID`,
  `getPage(id:)`, `listAllSourcesOrderedByID`, `getSource(id:)`, …). The read
  path is already clean and uniform in *shape*; the duplication is in the
  *projection*, not the store.
- **Resource kinds NOT yet projected:** bookmarks (nested — `bookmark_nodes`
  table, folders + page/source refs) and chats (append-only — `chats`/​
  `chat_messages`, shipped #119).
- **The bus vocabulary already partly exists:** `ResourceKind { page, source,
  systemPrompt, wikiIndex, log, bookmark }` (`WikiEventBus.swift`). Note
  `bookmark` is already a kind that emits events but projects nothing.

---

## Design decisions (of record)

### D1 — `Resource` covers the *leaf* concept; tree *shape* is a separate projection descriptor

Per #129 open question ("Where bookmarks and chats don't fit the mold"). A
`Resource` is a thing with **identity + name + content + version** that can be
listed/read/change-detected. Nesting is **not** part of `Resource` itself;
bookmarks' folder structure is a projection-shape concern layered on top. So
the abstraction is two-layered:

- `Resource` (the leaf: id, name, content/version, the store read seam) — the
  thing MCP `ReadResource` and a future REST `GET` consume.
- A **projection descriptor** (the tree shape) — what the File Provider
  consumes. Descriptors: `FlatResourceProjection` (by-id + by-name), `SingletonDoc`,
  `GeneratedIndex`, and (Phase D) `NestedResourceProjection` (bookmarks).

This keeps the leaf abstraction MCP/REST-friendly (flat id→content) while
letting the mount represent hierarchy where it exists.

### D2 — Genericize `Projection`, NOT the `WikiStore` protocol

Per #129 open question #3. The duplication is overwhelmingly in
`Projection.swift`; the store's per-kind read methods are already the clean
read path with ~100 call sites. So: **the store protocol stays per-kind.** The
descriptors are value-typed structs holding closures + container ids (not a
protocol-with-associated-types — the store methods differ in signature, and
PATs would fight that for no gain). A descriptor captures (container ids,
prefix(es), list-closure, node-builder-closure, content/version-source). This
contains the blast radius to `Projection.swift`, where the duplication actually
is.

### D3 — `changeToken` becomes a composition of per-kind fold contributors

One whole-DB token stays (the File Provider sync anchor is single; §3 decision
3 of the bus). But instead of one hardcoded 11-field string built from private
helpers, a registry of **`ChangeTokenContributor`s** composes it: each kind
declares the folds it owns. Per roadmap §5, graph-model's source folds
(`svCount`/`refsGenSum`/`actCount`) become the **source** resource's
contribution; pages owns its count+sum; the singletons own their version folds;
bookmarks (Phase D) add their own.

- The **token string is format-extended in place** (append fields), exactly as
  every graph-model migration did — consumers compare opaquely, so the
  extension is safe. Phase A is *format-compatible* with today's 11 fields
  (tests unchanged); later phases append.
- **One token, not per-kind tokens.** Per-kind tokens are explicitly out of
  scope (§5: do not merge the token with the bus's ephemeral `seq`; the token
  is the durable per-wiki ground truth).
- **The contributor registry is the win:** adding a kind = registering a
  contributor, not editing a monolithic method.

### D4 — Bookmarks projection (#125) is the capstone of 2b, via `NestedResourceProjection`

Per roadmap §6 ("#125 is the first test case of 2b"). Bookmarks prove the
descriptor model handles nesting (folders + leaf refs), which the flat pages/
sources retrofit cannot validate alone. Structured as the **final phase** so the
protocol + flat retrofit ship first (proving the dedup on real, working code),
then bookmarks prove the harder shape against a settled abstraction. If the
operator prefers #125 as its own effort, Phase D cleanly detaches (it is
self-contained and adds no dependency the earlier phases need).

### D5 — `Resource` is the name; no collision is load-bearing

Per #129 open question (naming). "Resource" matches the MCP spec's own term
(#124 `resources/list_changed`) and the bus's existing vocabulary — which is
the *point*: one word across MCP, REST, the bus, and the mount. `NSFileProviderItem`
uses "item," not "resource," so there is no AppKit collision. Settle on
`Resource` / `ResourceKind` and align the bus enum to live next to the protocol.

### D6 — Model reload-on-self-write (drop `origin`) is separable and deferred to its own slice

The 2a doc lists "model becomes a pure reload subscriber on ALL events →
`origin` removed" under 2b. It is **orthogonal** to the Resource protocol and
is the riskiest *behavioral* change (a self-write reloading the model risks
editor focus/flicker regressions). It is **deferred to its own slice** (operator-confirmed, D6): 2b is Phases
A–D only, and the 2a transitional `origin` field stays in place until Phase E
lands separately. The protocol work does not depend on it.

---

## The protocol shape (sketch)

Exact API is left to implementation; the shape the phases build toward:

```swift
// The leaf concept (MCP/REST/FP all consume this).
protocol Resource {
    var id: String { get }            // ULID
    var name: String { get }          // display name
    var kind: ResourceKind { get }    // aligns with the bus vocabulary
}

// A kind declares its changeToken contribution (D3).
protocol ChangeTokenContributor {
    static var kind: ResourceKind { get }
    func contribution(in store: SQLiteWikiStore) throws -> String  // one fold fragment
}

// Projection descriptors (D1/D2) — value types, not PATs.
struct FlatResourceProjection {       // pages, sources (+ .md sibling)
    let byIDContainer, byNameContainer, parent: NSFileProviderItemIdentifier
    let byIDPrefix, byNamePrefix: String
    let list: (SQLiteWikiStore) throws -> [any Resource]
    let node: (any Resource, ProjectionView) -> ProjectedNode
}
struct SingletonDoc { … }             // system prompt, index, log, wiki-structure
struct GeneratedIndex { … }           // manifest, jsonl (already mostly deduped)
struct NestedResourceProjection { … } // bookmarks (Phase D)
```

The `Projection` type then holds a **registry** of descriptors and drives
`node(for:)` / `children(of:)` / the working set generically, instead of the
current per-kind switch.

---

## Phases

Ordered by dependency; each gate is a green suite + a byte-identical
projection (the dedup must not change served bytes). Each phase is one PR.

### Phase A — Protocol + `changeToken` contributor registry (storage seam)

- Define `Resource`, `ResourceKind` (re-homed next to the protocol; the bus
  keeps using it), and `ChangeTokenContributor`.
- Rebuild `changeToken()` as a composition of registered contributors.
  **Format-compatible with today's 11 fields** — the produced string is
  byte-identical, so `ProjectionTests`/`SQLiteWikiStoreTests`/`LogIndexTests`/
  `SystemPromptTests` pass unchanged.
- A test asserts the registry is exhaustive (every projected kind contributes)
  and that adding a kind = adding a contributor (mirrors the 2a
  `StoreEmissionExhaustivenessTests` discipline).
- **No projection change.**
- **Gate:** full suite green; token byte-identical; contributor-exhaustiveness
  test green.

### Phase B — Generic flat projection; retrofit pages + sources (+ `.md` sibling)

- Extract `FlatResourceProjection`. Port `pages` (by-id/by-title) and `sources`
  (by-id/by-name + the markdown sibling) onto it.
- Collapse `pageFileNode`/`sourceNode`/`sourceMarkdownNode`/`pageNodes`/
  `sourceNodes` into descriptor-driven generic code; the flat arms of
  `node(for:)`/`children(of:)`/the working set become registry-driven.
- **Gate:** `ProjectionTests` byte-identical (served bytes + sizes + versions
  unchanged); a structural test shows a new flat kind is declarable without
  touching the generic code.

### Phase C — Singleton-doc + generated-index descriptors

- Extract `SingletonDoc` (system prompt, index, log, wiki-structure) and
  `GeneratedIndex` (manifest, jsonl — consolidating the already-shared
  `IndexCache`/`indexFileNode`).
- **Gate:** `ProjectionTests` byte-identical; the root + `indexes/` trees
  unchanged.
- ↳ *Phase C shipped (2026-07-08).* `SingletonDoc` (5 instances: readme,
  systemPrompt dual-alias, wikiIndex, log, wikiStructure dual-alias) +
  `GeneratedIndex` (4 instances: manifest root-level + 3 jsonl under `indexes/`)
  descriptors drive every dispatch site. `generateIndexData` deleted;
  `indexFileNode` takes a descriptor. 12 new `ProjectionTreeTests`. Gate met
  (1906 tests green; byte-identical).

### Phase D — Bookmarks File Provider projection (#125) via `NestedResourceProjection`

- Project `bookmarks/` as a nested tree: folders from `bookmark_nodes`, leaf
  refs as alias/symlink-style nodes pointing at the page/source they reference
  (reuse existing leaf identifiers — no new identity scheme).
- New `ChangeTokenContributor` for bookmarks (count/version fold) — Phase A's
  registry absorbs it with no `changeToken()` rewrite.
- Wires up the `bookmark` `ResourceKind` the bus already emits.
- **Gate:** a bookmark folder with nested children + a ref leaf enumerates and
  reads in the mount; create/rename/move/delete re-fetches via the bus.

### Phase E — DEFERRED to its own slice (not in 2b)

- Model subscribes to **all** events (not just `.external`); remove `origin`
  from `ResourceChangeEvent`; the model stops self-managing via the per-call
  `reload*()` sites (the lowest-risk 2a cut is reversed).
- **Gate:** edit a page → the model reflects it through the bus, not a direct
  reload; no editor focus loss / flicker regression; `origin` fully removed.

---

## Conflicts / sequencing notes

- **`changeToken()` literal tests** — Phase A keeps the format identical so
  they don't move; later phases append fields and update the literals (the
  established graph-model pattern).
- **`Projection.swift`** — graph-model's late "projection overhaul" (§9/§10)
  is deferred and mostly orthogonal; 2b is the earlier, scoped dedup. Sequence
  2b first; graph-model's overhaul lands against a now-generic projection.
- **Bus `ResourceKind`** — already has `bookmark`; Phase D makes it real. Chats
  (#119) would add a `chat` kind later (not in 2b).
- **`WikiStore` protocol** — deliberately *not* genericized (D2); no churn to
  its ~100 call sites.
- **Do not merge the token with the bus `seq`** (§5): the token is durable
  ground truth; `seq` is an ephemeral ordering stamp. The contributor registry
  is for the token only.

## Non-goals (deferred)

- **MCP server (#124)** — separate effort that *builds on* 2b's `Resource`
  (iterate a kind registry for `ListResources`/`ReadResource`). Roadmap §6: it
  need not wait for the daemon, but it waits for this.
- **Chats projection (#119 follow-on)** — chats are append-only; a future
  flat/append kind, not in 2b. Sketched here so its shape is anticipated.
- **Per-kind changeTokens** — one whole-DB token stays; only construction is
  genericized (D3).
- **Consuming `seq`** (the daemon resync handshake, #187).
- **Genericizing the `WikiStore` read protocol** (D2).

## Resolved decisions (operator-confirmed)

1. **Bookmarks scope — in-slice as capstone (Phase D).** #125 lands inside 2b;
   the nested `bookmarks/` projection is the test case that proves the
   descriptor model handles hierarchy (matches roadmap §6). 2b is a 4-phase
   effort: A → B → C → D.
2. **Phase E (model reload-on-self-write) — deferred to its own slice.** It is
   orthogonal to the Resource protocol and is the riskiest behavioral change
   (editor focus/flicker). 2b carries no UX-regression risk; the 2a
   transitional `origin` field stays until Phase E lands separately.
3. **Retrofit-first.** The abstraction is proven by porting the two existing
   flat kinds (pages+sources, Phase B) onto the generic helper *before* proving
   nesting on bookmarks (Phase D) — working code is the better test of the
   dedup than designing against one greenfield shape.

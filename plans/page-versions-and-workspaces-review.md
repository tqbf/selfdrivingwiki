# Adversarial review: `page-versions-and-workspaces.md`

**Reviewed:** `plans/page-versions-and-workspaces.md` (proposed, 2026-07-09)
**Review date:** 2026-07-09
**Method:** §2 grounded facts verified against the live v28 tree; substrate
claims cross-checked against `graph-model-and-versioning.md` and
`extraction-vs-ingestion-lock.md`; design stress-tested for constraint
violations, race conditions, and unhandled cases.

## Headline

The thesis is sound and the prior-art framing is genuinely strong, but **three
blocking schema/concurrency holes contradict enforced constraints the plan
treats as nonexistent**, and one merge-protocol step violates a documented
invariant in the plan's own codebase. The "workspace invisible until merge"
model — the plan's central payoff — is the thing most at risk.

---

## Severity key

- 🔴 **Blocking** — contradicts enforced DB constraints / load-bearing
  invariants; not buildable as written.
- 🟠 **High** — design holes that will bite during implementation.
- 🟡 **Medium** — real work / underspecified, not fatal.
- ⚪ **Low / accepted-risk** — noted for completeness, not defects.

---

## 🔴 Blocking

### B1. `refs.owner_id` is FK-locked to `sources(id)`. Adding `page-content` to `refs` is not "additive."

The plan (D1, §4.1) adds a `page-content` ref *kind* to the existing `refs`
table, with `owner_id = pages.id`. But the live schema is:

```sql
-- SQLiteWikiStore.swift:587
owner_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
```

and `PRAGMA foreign_keys=ON` is set at open (`:177`). With FKs enforced,
**every `page-content` ref insert fails** — a page id is not in `sources`. The
plan presents v29 as *additive* and the migration as "seeds one root version per
existing page and writes no refs." It never mentions that the `refs` table
itself must be rebuilt to drop the polymorphic FK.

This compounds twice:

- **It's not cheap.** Dropping the `owner_id` FK requires a SQLite table rebuild
  (create-new / copy / drop / rename), not an `ALTER`.
- **Dropping the FK loses `ON DELETE CASCADE`.** Today, deleting a source
  auto-removes its refs. Lose that, and orphaned `source-content` /
  `source-derived` refs accumulate — which silently drifts the very
  `COALESCE(SUM(generation),0) FROM refs` fold (`:2038`) the plan swears must
  stay byte-identical (§5).

**D6 is internally inconsistent.** It claims to "honor graph-model §4.3's
polymorphism tripwire: the third ref kind arrives *without* widening the
polymorphic table." But §4.3's tripwire *explicitly* says the third kind is the
trigger to "evaluate splitting `refs` per-kind into typed tables **or** adding a
discriminator + CHECK." The CHECK option does **not** fix the FK — and the plan
picks the shared-table option (the riskier of the two the ancestor named) purely
to keep the `SUM(generation)` fold unchanged. So there's a genuine tension the
plan hasn't resolved:

- page-content **in `refs`** → FK problem (this finding);
- page-content **in a separate `page_refs` table** → the token fold stops moving
  on page saves and needs a new contributor (which §5 wants to avoid).

Pick one and say so.

### B2. `page_versions.page_id REFERENCES pages(id)`. Workspace-created pages can't exist without a `pages` row.

§4.2 claims "Workspace-created pages hold real `page_versions` rows (append-only
tables are namespace-free; only *refs* are namespaced)" and the workspace-write
protocol (§4.3) does "No `pages`-row change, no token movement, no FP
visibility." But §4.1's own schema is:

```sql
page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
```

You cannot insert a `page_versions` row for a page that doesn't exist in `pages`.
So a workspace that creates a *new* page must create a `pages` row — and that
row simultaneously:

1. breaks the "no `pages`-row change" invariant,
2. moves the token (`PagesTokenContributor` counts all `pages` rows),
3. makes the draft File-Provider-visible,
4. hits `pages_slug_unique` **at write time, before merge** — which defeats D13,
   whose entire premise is that slug unification happens *at merge*.

If both workspaces create "Elixir," the second insert throws a UNIQUE constraint
error during ingestion, not a reviewable merge conflict.

This is the symmetric twin of B1, and it strikes the plan's keystone invariant
("the token reflects main only; workspace activity is invisible to the FP until
merged"). The plan needs an explicit answer: either workspaces stage new pages
in a separate table (then the "namespace-free append-only tables" claim is
false), or new-page creation lands a `pages` row immediately (then accept the
token/visibility/slug consequences and rewrite D13).

### B3. The merge protocol regenerates embeddings *inside* the write transaction — a documented invariant violation.

§4.3's merge pseudocode runs "regenerate links/FTS/embeddings for touched pages
(D10)" inside the single `withTransaction`. The codebase explicitly forbids
this. The comment at `SQLiteWikiStore.swift:3822`:

> The embedding + FTS side effects run AFTER the commit (best-effort, and **MLX
> inference must never run under an open write transaction — it would stall
> `wikictl`**).

`reembedSource` and `reembedChatMessages` both execute post-commit today — this
is an established, load-bearing pattern (the system prompt repeats it: "Never run
inference/network inside a transaction"). For a 50-page merge, holding the write
lock across per-page embedding inference will:

1. violate the rule, and
2. blow the 5s `busy_timeout` for any concurrent `wikictl` writer or human save,
   producing `SQLITE_BUSY` mid-merge.

**Fix:** pre-compute embeddings for touched pages *before* the merge transaction,
persist only the vectors inside it — exactly mirroring `renameSource`'s shape.

---

## 🟠 High

### H1. D14 amend silently rewrites a workspace's merge base.

Autosave amend ("replaces the head version's blob pointer") mutates a
`page_versions` row in place. But `workspace_refs.base_version_id` references a
`page_versions.id`. If the app amends a version that an open workspace uses as
its three-way-merge base, **the merge base content changes underneath the
in-flight workspace** with no notification.

D14 restricts amend to "parent is current head, same actor, within debounce
window" — it does *not* add the necessary guard: **amend only if no
`workspace_refs.base_version_id` points at the target version** (or if the
version has no children). Otherwise history rewriting corrupts a live merge.

### H2. All-or-nothing merge: one conflicting page parks the whole workspace.

§4.3: any per-page conflict → `abort transaction, park 'conflicted'`. A 50-page
ingestion with a single conflict on page 7 parks all 50 pages — the 43 clean
fast-forwards can't land until the conflict resolves. "Rebase-don't-abort" is
deferred to W4, but the consequence isn't named: **large ingestions have merge
latency gated by their worst page.**

Consider landing clean pages incrementally (each its own sub-transaction) and
parking only the conflicting subset — or accept the all-or-nothing semantics
explicitly and say why (ingestion-internal consistency may demand it).

### H3. D13 slug-unification is underspecified and has an ordering trap.

Two workspaces create same-titled pages → different ULIDs. At merge, "the second
workspace's body is three-way-merged in and its ULID references rewritten." But
bodies are content-addressed immutable blobs, so rewriting
`[[page:<loser-ULID>|…]]` → `[[page:<winner-ULID>|…]]` means minting a *new*
blob. And the rewrite **must happen before diff3** — otherwise diff3 sees
phantom conflicts on every link line (loser-ULID ≠ winner-ULID).

The plan treats this as a parenthetical; it's actually a transformation with a
hard ordering constraint against the merge base.

---

## 🟡 Medium

- **M1. Token byte-identity is fragile, not free.** §5 claims "Phase 0 changes
  no fold." Precisely: it adds *movement* to the existing `refs` fold (page
  saves now repoint a `page-content` ref → `generation+1`). The 21 hardcoded
  byte-for-byte assertions (verified: 5 in `LogIndexTests`, 14 in
  `SQLiteWikiStoreTests`, 2 in `SystemPromptTests`) will change for any fixture
  that saves a page post-migration. The migration's refs-table rebuild (B1)
  itself risks the fold. "Verify byte-identity" is real work, not a checkbox.
- **M2. Merge-queue executor is unspecified, and `wikictl` is a separate
  process.** Who drives the serialized merge? For W1–W3 (in-app only) this is
  fine, but W4 "concurrency unleashed" needs the executor's home nailed down —
  especially whether a `wikictl`-triggered merge can coordinate with the app's
  queue.
- **M3. Abandonment GC is underspecified and interacts with B2.** "Orphaned
  versions/blobs fall to the existing lazy-GC" assumes a clean orphan shape. If
  new pages do/don't get `pages` rows (B2), `vacuum-pages` must find pages with
  no main ref *and* no active workspace — more complex than "join
  `vacuum-blobs`." The plan should specify the reachable-set query.

---

## ⚪ Low / accepted-risk

- **D3 write-skew** is a defensible judgment call for prose. The one real
  cross-page invariant is `wiki_index`, and D12's line-set union is
  well-reasoned — but "same-line conflict → park" still bites on
  topic-overlapping ingestions (two PDFs about Elixir editing the same index
  line). Acceptable; just don't claim it eliminates index conflicts.
- **D7 overlay reads are a moving target.** Mid-ingestion, an agent reads main's
  latest for untouched pages, so its reasoning can be stale by merge time — a
  *semantic* conflict diff3 structurally cannot see. The plan consciously
  rejected snapshot-at-start; the consequence deserves a sentence.
- **§4.1 vs graph-model §4.6.** The plan routes page bodies through `blobs` and
  claims "D14's coalescing rule is what makes this honest." graph-model §4.6
  warned page bodies through blobs "would mint a new SHA-256 on every
  keystroke-save — the destruction of dedup." D14 *partially* addresses this,
  but combined with H1 (amend safety), the honesty claim rests on an amend guard
  that isn't specified. Earn it.

---

## Accuracy notes

### Grounded facts in §2 — verified, essentially all correct

`pages`/`pages_slug_unique` (`:221/:231`), blind `updatePage` (`:2223`),
`isAgentRunning` lock + single mutation point (`:204/:1281`), reload guards
(`:997/:1197`), `refs.SUM(generation)` fold (`:2038`), `changeToken`
contributors (`:1933`), `wiki_index` singleton (`:348`), `wikictl` as a genuine
second writer (`wikictl/main.swift:79`), the spawn slot (`GenerationGate`
serializes across all `AgentLauncher`s). Solid grounding.

### Two "mischaracterizations" that aren't

A researcher flagged "v28 head" and "v24 reserved" as contradictions of
graph-model — they are not. graph-model was *written* when v23 was head and is
simply stale; the code is at `user_version=28` (`:519/:1282`), so page-versions
is correctly current. The v24 hole is real (the ladder jumps `23→25` with no
`24`), so "precedent for holes" is accurate. These are cases where page-versions
is *more* accurate than its ancestor, not less.

### One framing IS overstated

Confirmed against `extraction-vs-ingestion-lock.md`: "completes the arc that doc
started" and "the extraction slot is already separate" are overstated. The
extraction-vs-ingestion plan is a narrow UI-state split
(`extractingFileIDs`/`ingestingFileIDs`) and a *planned, not implemented*
extraction lock; it explicitly leaves `isAgentRunning` intact and says nothing
about versioning or workspaces. This plan builds a new layer on top — it doesn't
complete that one.

(D15's attribution — *this* plan retires the lock — is correct.)

---

## Verdict & recommendation

The conceptual design — MVCC-as-durable-branches, retire-the-app-lock,
dumb-fast merge queue that never waits on the LLM — is the right shape and
well-argued. But **B1, B2, and B3 must be resolved before W0/W1 are buildable as
written**, because each contradicts an enforced constraint (`foreign_keys=ON`,
the `page_versions.page_id` FK, the no-inference-in-transaction rule).

Cheapest fixes:

- **B1/B2:** Decide the new-table vs. shared-table question explicitly. Cleanest
  is probably per-kind typed pointer tables (`page_refs` mirroring
  `workspace_refs`), accepting a new page-refs token contributor — this is
  exactly what graph-model §4.3's tripwire recommended and dissolves both FK
  problems at once. The "byte-identical token" goal isn't worth a
  polymorphic-FK landmine.
- **B3:** Pre-compute embeddings pre-transaction; persist vectors inside it
  (mirror `renameSource`).
- **H1:** Add the no-base-points-here guard to D14.

---

## Scope judgment — is the full architecture warranted *today*?

The findings above are about whether the plan is **buildable as written**. This
section is a separate, higher-level judgment: whether the full scope is
**proportionate to the problem this system actually has now**.

### What's unambiguously worth doing

- **W0 (page versions + CAS + history + revert).** Executes #258, extends a
  substrate that already exists, and is independently valuable even if nothing
  else follows. The plan says "W0 stands alone" — treat that as a candidate
  *stopping point*, not a waypoint.
- **Retiring the *global* edit lock.** Its one stated reason (last-writer-wins
  clobber) is removed by per-page CAS. Correct diagnosis.

### Where the proportionality breaks

The actual pain is narrow: *the editor freezes during a minutes-long ingestion.*
But the conflict rate that justifies the workspaces/merge machinery is low. The
human edits one page at a time; the agent ingests one file at a time (serialized
today); they touch overlapping pages only when the human edits a page the agent
is *also* rewriting (rare — the human usually knows), or when *two concurrent
ingestions* collide — which is **W4, a stretch goal at the very end**. So the
entire LLM-conflict-resolution subsystem (W2–W3) is built for a case that's
uncommon now and only becomes load-bearing in a phase that may never ship.

And it is the *riskiest, least-validated* component — the plan admits "only the
last part is novel." Trusting an LLM to three-way-merge wiki prose, with no
fallback if quality disappoints (Bayou op-log is "filed as refinement"), is a
real bet. Combined with B1–B3 (the design already straining against the
substrate's constraints), the complexity-to-payoff ratio is uncomfortable for a
single-user local wiki.

### Pragmatic alternative

1. **Ship W0** — page versioning, CAS, history, revert. Pure win.
2. **Swap the global edit lock for a per-page lock** — only lock the pages the
   agent is actively rewriting, not the whole editor. The agent already knows
   which pages it's touching; `wiki_index` is agent-maintained so locking it is
   invisible to the human. This captures most of the "editor frozen during
   ingestion" UX pain at a fraction of the complexity, and W0's per-page CAS
   handles the genuine race.
3. **Defer durable workspaces + LLM merge until there's evidence** — build the
   expensive machinery when concurrent ingestions (W4) are real and the simpler
   scheme is provably insufficient, not preemptively.

### The one counterweight

Workspaces give **reviewable ingestions** (D5 — "a diff against main inspectable
before it lands," PR-review for the wiki), and that is valuable *independent* of
concurrency. But review-before-land is achievable with a staging area, not a
full MVCC substrate. If reviewable ingestions are the real goal, build that
directly rather than inheriting it as a side effect of the merge architecture.

### Bottom line

Good diagnosis, right instincts ("never block the queue on the LLM"), excellent
prior-art grounding — but **more than this system needs yet.** Ship W0 + a
per-page lock; earn the workspaces/merge superstructure with evidence of real
overlapping-write conflict rather than building it preemptively.

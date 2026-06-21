# Extraction vs. Ingestion: separating the two phases in state + UI

**Status:** proposed (2026-06-20). Branch `fix-ingest-button-greyout`.

## The principle

Markdown **extraction** (pdf2md converting a PDF to markdown) and **agent
ingestion** (the `claude -p` run that writes wiki pages, index, and log) are two
different things. Extraction must never lock the user out of:

- running **queries**,
- editing **pages** (or processed-markdown versions),
- starting another file's ingest.

Only the agent ingestion run should carry those costs, because only it writes the
wiki and contends for the single serialized claude spawn slot.

## What the mechanism already gets right

The spawn-slot + edit-lock work on `fix-ingest-button-greyout` already encodes the
principle at the *mechanism* layer:

- **Edit lock** (`store.isAgentRunning`, `beginAgentRun`/`endAgentRun`) fires only
  around a claude spawn: `onLock` before `process.run()`, `onUnlock` in the
  `terminationHandler` (`AgentOperationRunner.swift:229-231`, `AgentLauncher.swift:298`,
  `:333`). Neither extraction path calls them. → **pages/processed markdown stay
  editable during extraction.**
- **Spawn slot** serializes *only* claude spawns. Neither the standalone
  `runExtraction()` (`IngestedFileDetailView.swift:349`) nor the ingest-path pdf2md
  step (`AgentOperationRunner.swift:58-101`) calls `awaitSpawnSlot()`. → **a query
  can start and run while extraction is in flight.**
- **`AgentRunBanner`** (`isVisible: store.isAgentRunning`) is false during extraction.
- **Standalone "Extract Markdown" button** disables only on `isExtracting ||
  isThisFileExtracting` — never on a query/ingest agent run
  (`IngestedFileDetailView.swift:161`).
- **Save Changes / Edit** buttons key off `isRunning`/`store.isAgentRunning`, both
  false during extraction.

So at the mechanism level, extraction is already non-blocking. The problem is
purely in the *UI state that labels and gates things*.

## The gap: one flag fuses the two phases in the UI

`AgentOperationRunner.runMultiIngest` sets
`launcher.ingestingFileIDs = Set(fileIDs)` at the very top
(`AgentOperationRunner.swift:41`) — **before** pdf2md runs — and that set stays
populated across *both* the extraction phase and the agent run. One set drives two
UI behaviors that semantically belong to the agent phase, not the extraction phase:

1. **Row mislabel.** `IngestedFileRow.isIngesting` (`= ingestingFileIDs.contains(file.id)`)
   shows a `ProgressView` with `.help("Ingesting…")` (`IngestedFileRow.swift:31-34`).
   During a pure-extraction phase this is a lie: nothing is being ingested into the
   wiki yet — the PDF is merely being converted to markdown. The agent that will
   write pages has not spawned.

2. **Cross-file greyout.** `isAnyFileIngesting = !ingestingFileIDs.isEmpty`
   (`WikiDetailView.swift:71`) disables *every other file's* "Ingest into Wiki"
   button (`IngestedFileDetailView.swift:155`). So while file A is merely
   extracting, the user cannot start ingesting file B — even though the spawn slot
   is free and A's extraction does not conflict with B's extraction or B's agent
   run. Extraction has leaked into a lock it was never supposed to hold.

## The fix: split one set into two

Replace the overloaded `ingestingFileIDs` with two orthogonal sets, named by the
phase they describe:

- **`extractingFileIDs: Set<PageID>`** — `true` only while a pdf2md conversion for
  that file is in flight. Populated by **both** extraction paths:
  - the ingest-path conversion in `runMultiIngest` (`AgentOperationRunner.swift:58-101`), and
  - the standalone `runExtraction()` (`IngestedFileDetailView.swift:349`).
  Drives an **"Extracting…"** row label and disables the *standalone Extract
  button for that file only*. Never touches the cross-file Ingest greyout.

- **`ingestingFileIDs: Set<PageID>`** — `true` only once the agent spawn is
  actually committed (slot acquired / `onLock` about to fire), cleared in
  `finish()`. Drives the **"Ingesting…"** row label and the cross-file
  `isAnyFileIngesting` greyout.

Net effect: a pure extraction on file A no longer mislabels A's row as
"Ingesting…" and no longer greys out B's Ingest button. Queries and edits remain
unaffected throughout (they already are). The asymmetry the principle asks for —
extraction never blocks the user, only the claude run does — becomes visible and
consistent in the UI.

### Why put `extractingFileIDs` on the launcher

The standalone `runExtraction()` in `IngestedFileDetailView` currently tracks its
own local `@State isExtracting` and `extractionLog` (`IngestedFileDetailView.swift:28-29`).
That local flag is invisible to the file *row* and to other files' detail views.
For the row to label A as "Extracting…" while the user has B open, the
extraction-in-flight state must live on the shared `AgentLauncher` alongside
`ingestingFileIDs` and `isExtracting`. The launcher already owns the per-run
process bookkeeping (`isExtracting`, `extractionPID`, `extractionLog`), so this is
its natural home — no new owner introduced.

## The decision: concurrent vs. serialized extractions

Once B's Ingest is no longer greyed during A's extraction, B will start its *own*
pdf2md conversion and then queue for the spawn slot. Two concurrent pdf2md runs are
heavy — the VLM pipeline pulls a ~2 GB model and runs on GPU/CPU. Options:

- **(A) Allow concurrent extractions.** Fully decoupled; matches the principle
  most directly. The model is likely already resident after the first conversion,
  so the second is cheaper than it looks. Risk: two VLM processes competing for
  memory/GPU on a large PDF pair, possible OOM or slowdown.

- **(B) Serialize extractions on a *separate* extraction lock**, distinct from the
  claude spawn slot. Keeps "one heavy conversion at a time" safety **without**
  re-coupling extraction to the agent lock — the extraction lock never touches
  query/edit locking or the spawn slot. A second extract request awaits it; a
  query starting during an extraction still runs immediately (query takes the
  spawn slot, which extraction does not hold).

**Recommended: (B).** It preserves pdf2md's one-at-a-time safety while keeping
extraction's relationship to queries/edits exactly as the principle demands. The
extraction lock is a thin FIFO mutex (shape mirrors `awaitSpawnSlot`, but separate
state — `awaitExtractionSlot` / `releaseExtractionSlot`). If pdf2md turns out to
tolerate concurrency well in practice, dropping the lock later is a one-spot
change.

### Standalone extraction interaction

The standalone "Extract Markdown" button (`IngestedFileDetailView`) calls pdf2md
directly, not through `runMultiIngest`. It must take the **extraction** lock too —
so a standalone extract and an ingest-path extract serialize against each other —
but it must *not* take the spawn slot (unchanged). Its current local
`isExtracting` becomes the file-scoped view of the shared `extractingFileIDs`
membership.

## Scope of changes

- `AgentLauncher`:
  - add `extractingFileIDs: Set<PageID>`;
  - (option B) add `awaitExtractionSlot()` / `releaseExtractionSlot()` mirroring
    the spawn-slot shape;
  - `ingestingFileIDs` is now set only at agent-spawn-commit and cleared in
    `finish()` (already is) — the runner stops pre-setting it for the extraction
    phase.
- `AgentOperationRunner.runMultiIngest`:
  - stop setting `ingestingFileIDs` up front;
  - set `extractingFileIDs` around the pdf2md block, clear it when the conversion
    ends (success or failure);
  - set `ingestingFileIDs` only once the agent spawn is committed (i.e. just before
    `await run(...)` that we know will acquire the slot, or — cleaner — let
    `AgentLauncher.run` set it from `onLock`-adjacent commit). The cancel-while-
    queued cleanup (`AgentOperationRunner.swift:127-134`) stays, clearing whatever
    phase flags are set.
- `IngestedFileDetailView.runExtraction`: take the extraction slot; reflect
  `extractingFileIDs.contains(file.id)` for the button state (keep the local
  `isExtracting` for the in-view progress log, or source it from the shared set).
- `IngestedFileRow`: show **"Extracting…"** when in `extractingFileIDs`,
  **"Ingesting…"** when in `ingestingFileIDs`. Needs both sets plumbed
  (`SidebarView` → row), replacing the single `isIngesting`.
- `WikiDetailView`: `isAnyFileIngesting` stays `!ingestingFileIDs.isEmpty`
  (unchanged semantics, now correctly *extraction-free*); plumb `extractingFileIDs`
  into the detail view for the per-file Extract button state and any banner.
- Tests:
  - extend `AgentSpawnSlotTests` (or a sibling) to assert extraction sets
    `extractingFileIDs` (not `ingestingFileIDs`), the agent phase sets
    `ingestingFileIDs` only after spawn commit, and a query started during
    extraction runs without waiting on extraction;
  - (option B) extraction-slot FIFO + cancellation tests mirroring the spawn-slot
    ones;
  - a pure predicate test for the row's Extracting-vs-Ingesting label, like the
    existing `showsQueryDebugControls` seam.

## Non-goals

- Not changing the edit lock's meaning (claude-run-only) — that's already correct.
- Not changing the spawn slot's meaning (claude-only) — already correct.
- Not re-architecting pdf2md concurrency beyond option A/B above.
- Not touching the `hasBeenIngested` derivation (agent's `wikictl log append
  --kind ingest`), which is unaffected by which phase owns which flag.

## Out of scope but noted

- The standalone "Extract Markdown" button only appears for `isPDF && !hasMarkdown`
  (`IngestedFileDetailView.swift:156`). After extraction seeds a head version the
  button disappears — so the only extraction re-entry path is a fresh re-extract
  of a re-added file. The extraction lock still matters because the *ingest*-path
  extract can run concurrently with a *standalone* extract of a different file.
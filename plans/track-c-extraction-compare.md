# Track C — Extraction compare & nominate UI

**Status:** implemented on branch `feature/extraction-compare-ui`. Completes
Phase 2 of [`graph-model-and-versioning.md`](graph-model-and-versioning.md)
§4.5 / §12, which shipped tracks A+B (v21). Design authority: §4.5 ("keep both,
compare, nominate"), §4.7 (PROV provenance already recoverable), §4.3
(`source-derived` ref + `setActiveMarkdown`, already implemented). No schema
change — reuses the A+B storage verbatim.

## Goal

Tracks A+B made extraction **alternatives coexist** (CAS'd, provenance-carrying)
and gave them a flat `Menu` switcher. But you still can't *see* two extractions
against each other — the menu lists labels only. Track C closes the "compare"
half of the loop: a focused modal sheet that renders any two alternatives
**side-by-side in the real reader** (`WikiReaderView`), shows each one's
provenance (backend, model, date, size), and lets you **nominate the active one**
("Set Active") without leaving the comparison.

**Operator-approved scope (this plan):**
- Surface = **modal sheet** (matches the existing picker-sheet idiom;
  `BookmarkTargetPickerSheet` / `ItemPickerSheet`).
- Representation = **rendered side-by-side** (two `WikiReaderView`s). A raw
  text diff is a documented **fast-follow**, explicitly out of scope for the
  gate.

## Background (what already exists — grounded)

- `recordMarkdownExtraction` writes an `agents` row (name = backend
  `agentName`, `version` = model id) + an `activities` row (`kind='extract'`,
  `plan` JSON `{"backend","model"}`) + a CAS'd smv row, in one transaction
  (`SQLiteWikiStore.swift:4011`).
- `processedMarkdownHistory(sourceID:)` returns `[SourceMarkdownVersion]`
  (newest-first), each `.content` already the fully-resolved body (blob-decoded).
- `processedMarkdownAgentNames(sourceID:)` returns `smvID → agents.name`.
- `setActiveMarkdown(sourceID:to:)` UPSERTs the `source-derived` ref and moves
  the changeToken. The detail view's `headVersion` reloads via `.task(id:)`.
- `WikiReaderView(markdown:store:...)` is the single reader everywhere and takes
  plain `markdown: String`; reusing it for a compare pane needs no new rendering.
- The header's flat `extractionsMenu` (`SourceDetailView.swift:620`) lists
  alternatives + "Re-extract with…". This **stays** as the quick switcher; the
  sheet is the deliberate comparison surface.

## Design

### Surface: a self-contained `.sheet` on `SourceDetailView`

`SourceDetailView` currently hosts no sheet of its own (sheets live on the
containers). A per-source `.sheet(item:)` here needs no cross-container
plumbing and matches the picker-sheet idiom. Triggered by a new header button
**"Compare Extractions…"**, shown for PDFs with markdown, **disabled when fewer
than 2 alternatives exist** (compare is meaningless otherwise). Re-extract
stays in the existing menu (you run a second backend, then open compare).

### Representation: rendered side-by-side

```
┌ Compare Extractions — <filename>                       [Done] ┐
├──────────────┬──────────────────────┬────────────────────────┤
│ Alternatives │ A · Claude · 6/05    │ B · Local pdf2md · 6/05│
│              │ claude-opus-… 8,421c │ on-device    7,990c    │
│ ●  ○  claude │ [✓ Set Active]       │ [  Set Active  ]       │
│ ○  ●  pdf2md │ ┌──────────────────┐ │ ┌────────────────────┐ │
│ ○  ○  gemini │ │ WikiReaderView   │ │ │ WikiReaderView     │ │
│              │ │ (rendered)       │ │ │ (rendered)         │ │
│ ▣ Active     │ └──────────────────┘ │ └────────────────────┘ │
└──────────────┴──────────────────────┴────────────────────────┘
```

**Alternatives list (left):** each row is an `ExtractionAlternative`. Each row
carries two **assign targets** — a left (A) and right (B) circular control — the
standard diff-tool "pick A / pick B" idiom (Kaleidoscope/Beyond Compare). The
assigned pane is filled. An "Active" badge marks the current HEAD row
(read-only; nominate via a pane's "Set Active"). Tooltips: "Set as left pane" /
"Set as right pane".

**Compare panes (A / B):** each shows the assigned alternative's provenance
header (backend display name, model version, date, char count) + a
`WikiReaderView` rendering its `.content`. A **"Set Active"** button calls
`store.setActiveMarkdown(for:to:)`; after it, the sheet re-queries the HEAD and
the "Active" badge moves to that row (the detail view's reader refreshes on
dismiss via the existing `.task(id: file.id)`). "Set Active" does **not** dismiss
the sheet — you may compare further or close manually.

**Default assignment on open:** A = current HEAD; B = the most recent *other*
alternative. If only one alternative exists the button is disabled, so B is
always fillable when the sheet is reachable.

### Provenance value type + consolidated query

Introduce one value type that bundles a version with its recoverable provenance,
and one query that replaces the current two-call pattern (`history` +
`agentNames`) for the sheet:

```swift
public struct ExtractionAlternative: Identifiable, Hashable, Sendable {
    public let version: SourceMarkdownVersion   // .content is the resolved body
    public let backendDisplayName: String       // "Claude (Anthropic API)" / "Legacy"
    public let agentName: String                // raw agents.name ("claude", "pdf2md"…)
    public let modelVersion: String?            // agents.version (model id)
    public let charCount: Int                   // version.content.count
    public let isActive: Bool                   // == current HEAD id
    public var id: PageID { version.id }
}
```

`processedMarkdownAlternatives(sourceID:) -> [ExtractionAlternative]` (store +
protocol + model wrapper): one query joining `smv → activities → agents`
(reusing `smvSelectColumns`/`smvBlobJoin` for the body), resolving
`backendDisplayName` via a new reverse map `ExtractionBackend.from(agentName:)`
(nil for `"legacy-extraction"`/unknown → display "Legacy"/raw name), and
`isActive` via the existing ref→else-MAX HEAD id.

## Touch points

- **`Sources/WikiFSCore/ExtractionAlternative.swift`** (new) — the value type
  above. Kept separate from `SourceMarkdownVersion.swift` for clarity (it's a
  presentation-layer bundle over the storage value type).
- **`Sources/WikiFSCore/SQLiteWikiStore.swift`** — `processedMarkdownAlternatives
  (sourceID:)` (one joined query; HEAD-id compare for `isActive`). Mirror the
  method-atomic lock + the smv column/blob-join helpers already in use.
- **`Sources/WikiFSCore/WikiStore.swift`** — protocol method.
- **`Sources/WikiFSCore/MarkdownExtractor.swift`** — add
  `ExtractionBackend.from(agentName:) -> ExtractionBackend?` (reverse of
  `agentName`). Keep `displayName`/`helpText` unchanged.
- **`Sources/WikiFSCore/WikiStoreModel.swift`** —
  `processedMarkdownAlternatives(for:)` thin wrapper (mirrors
  `processedMarkdownHistory(for:)`).
- **`Sources/WikiFS/ExtractionCompareSheet.swift`** (new) — the sheet: list +
  assign-A/B + two `WikiReaderView` panes + per-pane "Set Active" + Done. Owns
  `@State leftID`/`rightID` and refreshes HEAD after a nominate.
- **`Sources/WikiFS/SourceDetailView.swift`** — `@State compareSourceID`, the
  "Compare Extractions…" header button (near `extractionsMenu`, ~line 321),
  `.sheet(item:)`, and a `headVersion` refresh on dismiss. Keep the existing
  quick-switch menu.

No schema change, no migration, no changeToken change, no `wikictl` change
(`source set-active` already covers the scriptable switch).

## Acceptance criteria

- **AC.1** — The sheet lists every alternative with backend display name, model
  version, date, and char count; the active HEAD is badged.
- **AC.2** — Assigning alternatives to panes A and B renders both side-by-side
  via `WikiReaderView`, each showing the correct body.
- **AC.3** — "Set Active" on a pane calls `setActiveMarkdown` and the Active
  badge moves within the sheet; the detail reader reflects the new HEAD on
  dismiss.
- **AC.4** — Provenance labels resolve correctly: a Claude extraction shows
  "Claude (Anthropic API)" + its model id; a pdf2md row shows "Local pdf2md";
  a legacy row shows "Legacy" with no model.
- **AC.5** — No new markdown-rendering code: both panes are `WikiReaderView`;
  zoom/find inherit unchanged.
- **AC.6** — The "Compare Extractions…" button appears for PDFs with markdown
  and is disabled when fewer than 2 alternatives exist.

## Test strategy

The sheet UI is observable mainly manually (track C has no prior render-test
infra, consistent with the A+B plan's note). The model/query layer is unit-tested:

| AC | Test | Layer |
|----|------|-------|
| AC.1/AC.4 | `processedMarkdownAlternatives` returns correct count + backend display name + model version + char count + isActive for a two-backend source | unit (`ProcessedMarkdownTests`) |
| AC.4 | `ExtractionBackend.from(agentName:)` round-trip: each backend's agentName → backend; `"legacy-extraction"`/unknown → nil | unit (pure) |
| AC.2/AC.3/AC.5/AC.6 | open sheet, assign A/B, see renders, Set Active, dismiss → detail updates | **manual** (functional store path covered by unit; visible sheet validated manually, as with A+B) |

Run: `swift test --filter ProcessedMarkdownTests`, then full `swift test`.

## Review strategy

- **Plan review:** `plan-reviewer` on this plan; fix/rebut all critical/high.
- **Impl review:** `general-purpose` subagent on the store query (method-atomic
  lock, smv join reuse, HEAD-id compare) and the sheet (two-WikiReaderView
  correctness, `@State` assignment lifecycle, HEAD refresh after nominate).
- **Design cross-check:** `swiftui-pro` + `macos-design` (assign-A/B idiom
  clarity, list/pane layout, "Set Active" placement) and `typography-designer`
  (provenance header hierarchy).

## Risks / decisions

- **Two WKWebViews in a sheet.** Memory/perf — but the app already runs many
  `WikiReaderView`s across tabs; two in a modal is fine. Mitigation: each pane
  loads async with the existing spinner; note as a fast-follow if a very large
  pair strains memory.
- **Assign-A/B discoverability.** Two target dots per row may be obscure.
  Mitigation: tooltips, sensible defaults on open, and Set Active is the obvious
  nominate path.
- **Diff shipped in v1** (operator-approved): a unified line-diff
  (`MarkdownDiff`, LCS) with a Rendered ↔ Diff toolbar toggle. The DP table is
  capped (`maxCells`) with a degraded fallback so oversized bodies stay
  responsive; the rendered side-by-side remains the default and primary surface.
- **Single-alternative source.** Button disabled (<2), so the sheet is never
  opened into a degenerate state.

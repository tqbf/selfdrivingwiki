# Plan: Source History Tab — DRY with PageDetail's Inspector + ProvenancePanel

## Goal
Add a History tab to `SourceDetailView`'s inspector panel (matching the one
in `PageDetailView`). DRY the shared components so both detail views use the
same `DetailInspectorView` and a generic `ProvenancePanel`.

## Current state

### PageDetailView (has the inspector)
- `DetailInspectorView` (PageDetailView.swift:695) — the tabbed inspector.
  Hardcodes `PageOutlineView` (Outline tab) + `ProvenancePanel` (History tab).
- `InspectorTab` enum (PageDetailView.swift:681) — `.outline` / `.history`.
- `ProvenancePanel` (PageDetailView.swift:799) — takes `pageID`,
  `origin: PageOrigin?`, `history: [PageOrigin]`, `store: WikiStoreModel?`.
- `PageOrigin` (Core/PageOrigin.swift:19) — the provenance struct. Fields:
  versionID, title, blobHash, agentName, agentKind, activityKind, plan,
  externalRef, runTitle, savedAt.
- `pageOrigin(pageID:)` + `pageEditHistory(pageID:)` — store accessors
  (GRDBWikiStore.swift:4447/4502).

### SourceDetailView (doesn't have a history tab)
- Has an outline pane (`contentAndOutline` at line 887) but NOT the tabbed
  inspector.
- `SourceOrigin` (SourceMaterializer.swift:132) — different struct. Fields:
  agentName, activityKind, plan, externalRef, externalIdentity, fetchedAt.
  Missing: versionID, agentKind, runTitle.
- `sourceOrigin(sourceID:)` (GRDBWikiStore.swift:3440) — returns HEAD origin
  only. **No `sourceEditHistory` exists.**
- `source_versions` table exists (append-only ULID chain, same as
  `page_versions`) — the data is there, just no read accessor.

## Implementation

### 1. Add `sourceEditHistory(sourceID:)` to the store
Mirror `pageEditHistory(pageID:)` but for sources. In `GRDBWikiStore.swift`,
after `sourceOrigin(sourceID:)`. Read-only (`dbWriter.read`), no `mutate()`.

Add to `WikiStore.swift` protocol + `WikiStoreModel.swift` wrapper (same
pattern as `pageEditHistory`).

### 2. Extend `SourceOrigin` with fields needed for the history display
Add: `versionID`, `agentKind`, `runTitle` so the generic ProvenancePanel can
render it. Update `sourceOrigin(sourceID:)` query + `originFromSource(row:)`
to select `a.kind` agent kind + `sv.id` versionID + the chat-title subquery
(same as pageOrigin's).

### 3. Create a generic `ProvenancePanel` via shared `ProvenanceEntry` struct
```swift
public struct ProvenanceEntry: Sendable, Equatable {
    public let versionID: String
    public let agentName: String
    public let agentKind: String
    public let activityKind: String
    public let plan: String?
    public let externalRef: String?
    public let runTitle: String?
    public let savedAt: Date
}
```
Add `var provenanceEntry: ProvenanceEntry { ... }` to both `PageOrigin` and
`SourceOrigin`. Rewrite `ProvenancePanel` to take
`origin: ProvenanceEntry?` + `history: [ProvenanceEntry]`.

### 4. Make `DetailInspectorView` generic
Move `DetailInspectorView` + `InspectorTab` out of `PageDetailView.swift`
into `Sources/WikiFS/Detail/DetailInspectorView.swift`. Accept:
- `outlineView` as a `@ViewBuilder` closure
- `origin`/`history` as `ProvenanceEntry` types + `store`

```swift
struct DetailInspectorView<Outline: View>: View {
    @Binding var inspectorTab: InspectorTab
    @ViewBuilder let outline: () -> Outline
    let origin: ProvenanceEntry?
    let history: [ProvenanceEntry]
    var store: WikiStoreModel?
}
```

### 5. Wire up SourceDetailView
- `@State` for `sourceOrigin`/`sourceEditHistory` + a `.task(id:)` to load.
- Replace `contentAndOutline` with the new `DetailInspectorView`.
- Use source-specific `@AppStorage` keys (`sourceInspectorTab`,
  `isSourceOutlineExpanded`, `sourceOutlineWidth`).

### 6. Update PageDetailView to use the shared DetailInspectorView
Replace the inline inspector with the shared component. The outline view
closure passes `PageOutlineView(markdown:caretCharIndex:onSelect:)`.

## Files to modify
| File | Change |
|---|---|
| `Sources/WikiFS/Pages/PageDetailView.swift` | Extract `DetailInspectorView` + `InspectorTab` out; rewrite `ProvenancePanel` to use `ProvenanceEntry`; update to use shared components |
| `Sources/WikiFS/Sources/SourceDetailView.swift` | Add provenance state + `.task`; replace `contentAndOutline` with `DetailInspectorView`; pass source outline |
| `Sources/WikiFSCore/Sources/SourceMaterializer.swift` | Extend `SourceOrigin` with `versionID`, `agentKind`, `runTitle` |
| `Sources/WikiFSCore/Store/GRDBWikiStore.swift` | Add `sourceEditHistory(sourceID:)`; update `sourceOrigin` query to include `agentKind`/`versionID`/`runTitle` |
| `Sources/WikiFSCore/Store/WikiStore.swift` | Add `sourceEditHistory` to the protocol |
| `Sources/WikiFSCore/Store/WikiStoreModel.swift` | Add `sourceEditHistory(for:)` wrapper |
| `Sources/WikiFS/Detail/ProvenanceEntry.swift` *(new)* | Shared `ProvenanceEntry` struct |
| `Sources/WikiFS/Detail/DetailInspectorView.swift` *(new)* | Shared inspector + `InspectorTab` enum |
| `Sources/WikiFS/Detail/ProvenancePanel.swift` *(new)* | Shared provenance panel using `ProvenanceEntry` |

## Acceptance criteria
- [ ] `SourceDetailView` has a tabbed inspector with Outline + History tabs.
- [ ] The History tab shows source version history (date-first, newest-first,
      operation badges) — same as PageDetailView.
- [ ] `ProvenancePanel` is shared (DRY) — used by both detail views.
- [ ] `DetailInspectorView` is shared — used by both detail views.
- [ ] Source history rows are clickable (#745 behavior).
- [ ] `sourceEditHistory` is added to the store protocol + GRDBWikiStore +
      WikiStoreModel.
- [ ] `SourceOrigin` is extended with the fields needed for provenance.
- [ ] PageDetailView's inspector still works exactly as before.
- [ ] `make build && make test` passes.
- [ ] No `print`; no bare `try?`.

## Reviewer caveats (addressed)
1. **@AppStorage key collisions**: SourceDetailView uses its own keys
   (`sourceInspectorTab`, `isSourceOutlineExpanded`, `sourceOutlineWidth`).
2. **SourceOrigin call sites**: only `originFrom(row:)` in GRDBWikiStore
   constructs `SourceOrigin` — no test fixtures construct it directly.
3. **sourceEditHistory query**: mirrors `sourceOrigin`'s join shape, walks
   ALL `source_versions` rows (not just the active ref), `ORDER BY sv.id DESC`.
4. **ProvenanceEntry**: plain struct, no protocols.
5. **DetailInspectorView generic**: `@ViewBuilder` for outline closure; the
   History tab is always `ProvenancePanel` (not generic).
6. **File extraction**: `Sources/WikiFS/Detail/` directory for the shared
   components.

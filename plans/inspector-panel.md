# Plan: Xcode-style Inspector Panel for PageDetailView

## Goal
Replace the simple outline toggle + header-buried provenance panel with an Xcode-style inspector panel on the right side of PageDetailView. The panel has tabs — one for the document Outline, one for Version History (provenance). This moves the provenance/edit-history out of the collapsible header section and into the right inspector where it belongs as a vertical version list.

## Design

### Inspector panel structure
Replace the `contentAndOutline` HStack's right pane with a new `DetailInspectorView`:

```
HStack {
    mainContent (editor/reader)
    if isInspectorExpanded {
        DetailInspectorView(
            pageID: ...,
            markdown: ...,
            caretCharIndex: ...,
            onSelectHeading: { ... },
            store: store
        )
    }
}
```

### `DetailInspectorView` (new view)
An Xcode-style inspector with a toolbar of tab icons at the top and the selected content below:

```
┌─────────────────────────────┐
│ [≡ Outline] [🕘 History]    │  ← segmented Picker
├─────────────────────────────┤
│                             │
│  (selected tab content)     │
│  - Outline tab: PageOutlineView
│  - History tab: ProvenancePanel │
│                             │
└─────────────────────────────┘
```

Uses a segmented `Picker` (`.pickerStyle(.segmented)`) for the tab bar — NOT a `TabView`.

### `InspectorTab` enum
```swift
enum InspectorTab: String, CaseIterable {
    case outline
    case history
}
```
Store selection in `@AppStorage("pageInspectorTab")` so it persists across sessions.

### Width management
The `@AppStorage("outlineWidth")` key and drag gesture move from `PageOutlineView` up to `DetailInspectorView` so both tabs share the same resizable width.

### Provenance `.task(id:)`
Re-attached to `DetailInspectorView` itself, keyed on `pageID`. Provenance state (`provenanceOrigin`, `provenanceHistory`) moves into `DetailInspectorView`.

## Reviewer findings (addressed)

1. **HIGH** — `.task(id:)` re-attached to `DetailInspectorView` (was on `provenanceSection` which is deleted).
2. **MEDIUM** — `isProvenanceExpanded` + `toggleProvenance()` deleted entirely (dead code).
3. **MEDIUM** — `store: WikiStoreModel?` threaded through to `ProvenancePanel` inside the History tab.
4. **MEDIUM** — `@AppStorage("outlineWidth")` kept (same key), moved to inspector level.
5. **LOW** — `.help("Toggle Outline")` → `.help("Toggle Inspector")` + DebugLog messages updated.

## Acceptance criteria
- [ ] Right-side toggle opens a tabbed inspector panel
- [ ] Tab 1 = "Outline" showing `PageOutlineView` with heading list + caret tracking
- [ ] Tab 2 = "History" showing `ProvenancePanel` (origin + edit history rows)
- [ ] Provenance removed from header collapsible section
- [ ] Inspector tab selection persists (`@AppStorage`)
- [ ] Inspector width resizable (shared draggable divider)
- [ ] History rows clickable (#745 behavior preserved)
- [ ] Toggle button label reflects "Inspector"
- [ ] `make build && make test` passes
- [ ] No `print`; no bare `try?`

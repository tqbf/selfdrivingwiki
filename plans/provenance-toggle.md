# Plan: Provenance row single-tap toggle (#726)

## Goal
A single click/tap on the provenance `DisclosureGroup` row (the `.hoverRowBackground()` "bubble" pill) toggles `isProvenanceExpanded` — expanding to show `ProvenancePanel` (origin + edit history) — exactly like the title bar expands/collapses the detail header on a single tap (#717/#722). Today the row does nothing on click.

## Current state (merged code)
File: `Sources/WikiFS/Pages/PageDetailView.swift:418-444` — `provenanceSection`:
```swift
DisclosureGroup(isExpanded: $isProvenanceExpanded) {
    ProvenancePanel(pageID: pageID, origin: provenanceOrigin, history: provenanceHistory)
        .padding(.top, 4)
} label: {
    HStack { Label("Provenance", systemImage:"clock.arrow.circlepath").font(.callout).foregroundStyle(.secondary); Spacer(minLength:0) }
        .frame(maxWidth:.infinity, alignment:.leading)
        .contentShape(Rectangle())
        .hoverRowBackground()
}
.task(id: ProvenanceTaskKey(pageID: pageID, expanded: isProvenanceExpanded)) {
    guard isProvenanceExpanded else { return }
    provenanceOrigin = store.pageOrigin(for: pageID)
    provenanceHistory = store.pageEditHistory(for: pageID)
}
```
The native `DisclosureGroup` toggle is NOT firing on tap in this nested/expanded-content context — the same class of issue #722 fixed for the title bar (which uses an EXPLICIT tap).

The title-bar idiom to mirror (`Sources/WikiFS/Editor/CollapsibleDetailHeader.swift`):
- `EditableTitle(onSingleTap: toggleExpanded …)` (L65) + `.onTapGesture { toggleExpanded() }` (L75)
- `toggleExpanded()` (L79): `withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }`

## Fix
Add an explicit tap on the provenance label that toggles `isProvenanceExpanded` with the same animation, mirroring the title bar. **Watch for a double-toggle:** the native `DisclosureGroup` may ALSO toggle on its chevron/label. Verify in the running app; if it double-toggles, either:
(a) keep the `DisclosureGroup` for chevron visuals but drive `isProvenanceExpanded` solely from the explicit tap and make the label non-interactive to the native gesture, OR
(b) replace the `DisclosureGroup` with a manual chevron + `VStack` (like `CollapsibleDetailHeader` does for the header).
Prefer the smallest change that yields correct single-toggle behavior.

Keep the lazy `.task(id:)` load unchanged (origin/history load only on first expand — no eager read).

## Files
- `Sources/WikiFS/Pages/PageDetailView.swift` (`provenanceSection`, ~L418-444): add the explicit tap; adjust `DisclosureGroup` interactivity only if double-toggle occurs.

## Acceptance
- Single click on the provenance row expands it (shows `ProvenancePanel`: "Last saved by … · activity · relative time" + edit history); click again collapses. Animates like the header.
- No double-toggle (one click = one toggle).
- Lazy load still fires only on first expand.
- No regression to the header's own title-bar toggle (#717/#722).
- Hover affordance (`hoverRowBackground`) stays; click target is the full row (`contentShape(Rectangle())`).

## Testing / validation
This is a tap/gesture behavior — NOT unit-testable. Validate in the running app (`make build && make run`): open a page, expand the detail header, click the Provenance row → expands; click again → collapses. Route any diagnostics through `DebugLog` (never `print`).

## Build/test
`make build && make test`. Push the branch, open a PR with `Closes #726`. **Do NOT merge to main.**

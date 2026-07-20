# Plan: "Add Page" opens in the editor with the title pane expanded

Status: **Investigation complete — ready to implement.**
Investigator notes are inline; this doc is the authoritative spec for the implementer.

---

## 1. Goal

When the user clicks **"Add Page"** — from **either** the welcome screen **or** the
sidebar (the `+` button) — the app must:

1. Open the new page **in the editor** (the source/editing view), not the rendered
   markdown preview (which today shows an empty rendered page).
2. Have the **collapsible title (header) pane expanded** by default for that page.

**Scope guard:** existing / navigation-opened pages must keep their current
behavior. New-page-default must NOT force every opened page into edit mode.

---

## 2. Current-state summary (verified, with file paths + line numbers)

### 2.1 Both "Add Page" entry points share ONE action

There is **one shared entry point** — no ad-hoc logic per button:

| Entry point | File | Line | What it calls |
|---|---|---|---|
| Welcome-screen **"Add Page"** button | `Sources/WikiFS/Window/WikiDetailView.swift` | `117` (button) → `248-250` (`addPage()`) | `store.newPageInNewTab()` |
| Sidebar **"+" (New Page)** button | `Sources/WikiFS/Pages/PagesContainerView.swift` | `83-86` (button) → closure `onNewPage()` | `onNewPage()` |
| `onNewPage` is provided by… | `Sources/WikiFS/Window/ContentView.swift` | `149` | `{ store.newPageInNewTab() }` |

`onNewPage` is threaded `SidebarView` (`Sources/WikiFS/Window/SidebarView.swift:32,168`)
→ `PagesContainerView` (`Sources/WikiFS/Pages/PagesContainerView.swift:17,83`). So
**both buttons route to `WikiStoreModel.newPageInNewTab()`** — a single method.
There is also a window-toolbar "New Page" command; confirm it also calls
`newPageInNewTab()` (search `Sources/WikiFS/Window/` for `newPageInNewTab`).

### 2.2 What `newPageInNewTab()` does today

`Sources/WikiFSCore/Store/WikiStoreModel.swift:1176-1188`:

```swift
public func newPageInNewTab(title: String = WikiStoreModel.defaultUntitledTitle()) {
    flushPendingSaves()
    do {
        let page = try store.createPage(title: title, createdBy: "user")
        try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(page.bodyMarkdown))
        openTab(.page(page.id), title: title)   // ← creates a NEW EditorTab
    } catch {
        DebugLog.store("WikiStoreModel.newPageInNewTab failed: \(error)")
    }
}
```

- **Store write:** `store.createPage(title:createdBy:)` —
  `Sources/WikiFSCore/Store/GRDBWikiStore.swift:2845` (and the no-`createdBy`
  overload at `:2906`). This is a public mutating store method → it routes
  through `mutate(event:_:)` and emits a `ResourceChangeEvent` on the
  `WikiEventBus` (#129 change-signaling invariant). **No new store mutator is
  added by this feature, so no new emission obligation.** The model's bus-driven
  `reloadFromStore()` fires after the write; `openTab` passes the title
  explicitly so it does not depend on synchronous `summaries` freshness.
- **Presentation:** `openTab(.page(page.id), title:)` —
  `Sources/WikiFSCore/Store/WikiStoreModel.swift:970-982`. It appends a fresh
  `EditorTab(selection:title:)` and calls `setActiveTab(id)`.

### 2.3 The new `EditorTab` defaults `isEditing = false`

`Sources/WikiFSCore/Core/EditorTab.swift:15`:

```swift
public struct EditorTab: Hashable, Sendable, Identifiable {
    public var selection: WikiSelection
    public var title: String
    public var isEditing: Bool = false   // ← default
    ...
}
```

So the new page's tab is created **not editing** → the detail view renders the
**rendered/preview** branch (empty page). **This confirms the reported bug.**

### 2.4 How `PageDetailView` decides edit vs. rendered

`Sources/WikiFS/Pages/PageDetailView.swift`:

- `@State private var isEditing = false` — **line 15**. Per-view local state,
  default `false`. NOT `@AppStorage` — it is **per `PageDetailView` instance**.
- The body switches on `isEditing`: the `else` branch (rendered reader + "Edit"
  button) is at lines `107-163`; the `if isEditing` branch (Save/Cancel +
  editor) at lines `79-106`.
- Edit mode is **synced to the tab** via `.onChange(of: isEditing)` at
  **line 208-214**: `store.setTabEditing(tabID:isEditing:)`
  (`Sources/WikiFSCore/Store/WikiStoreModel.swift:1052-1055`).
- Edit mode is **restored from the tab** via `.onChange(of: store.activeTabID)`
  at **lines 203-207**: `isEditing = tab?.isEditing ?? false`.
- ⚠️ **`.onAppear` (line 189) does NOT seed `isEditing` from the tab** — it only
  records `lastKnownActiveTabID`. So the *first* time `PageDetailView` mounts,
  `isEditing` is `false` regardless of the tab's `isEditing`. Tab restore only
  happens on *subsequent* tab switches (`.onChange`).

### 2.5 The collapsible title (header) pane

- `@State private var isHeaderExpanded = false` — `PageDetailView.swift:30`.
  Per-view local state, default **collapsed**. **Not** persisted to the tab and
  **not** `@AppStorage`.
- Rendered by `CollapsibleDetailHeader(isExpanded: $isHeaderExpanded, …)` —
  `Sources/WikiFS/Editor/CollapsibleDetailHeader.swift`, called at
  `PageDetailView.swift:61-66`. `CollapsibleDetailHeader` just binds to
  `@Binding var isExpanded` (`CollapsibleDetailHeader.swift:26`) — it owns no
  state of its own. Its doc comment (`:8-11`) states: "every fresh detail starts
  collapsed."
- **Coupling:** `.onChange(of: isEditing)` at **line 212** already does
  `if newValue { isHeaderExpanded = true }` (to reveal Save/Cancel). So **entering
  edit mode expands the header for free** — as long as `isEditing` actually
  becomes `true`.

### 2.6 `PageDetailView` view identity (critical for state lifecycle)

`PageDetailView` is mounted **once** inside `WikiDetailView.detailContent`
(`Sources/WikiFS/Window/WikiDetailView.swift:170-175`) under `case .page:` of a
`switch store.selection`. There is **no `.id(…)`** on it, so SwiftUI keeps the
**same view instance alive** across page switches and same-type tab switches —
its `@State` (`isEditing`, `isHeaderExpanded`) persists and is updated only via
the `.onChange` bridges. This is intentional (see the comment at
`WikiDetailView.swift:34-41` warning against tearing the view down, which would
lose `@State isEditing`).

---

## 3. Target behavior

- **New page (via Add Page, either entry point):** opens with `isEditing == true`
  AND `isHeaderExpanded == true`.
- **Navigation-opened page (sidebar click, `[[wiki-link]]`, history back/forward,
  tab switch-back):** keeps current behavior — edit mode is whatever that tab
  last had (restored from `EditorTab.isEditing`), header defaults collapsed
  (unless the page enters edit mode, which expands it per the existing coupling).
- **Global `@AppStorage` defaults are untouched.** There is no "default view
  mode" `@AppStorage` today; we are not introducing one. The new-page-default is
  expressed purely as a **per-tab, creation-time** value.

---

## 4. The change seam — and WHY

**Chosen seam: set `EditorTab.isEditing = true` on the newly-created page's tab
in `newPageInNewTab()`, and make `PageDetailView` honor it on first mount.**

### Why this seam (and not the alternatives)

| Option | Verdict |
|---|---|
| **(A) `@AppStorage("defaultEditMode")` global default** | ❌ Rejects scope. Would force EVERY page open into edit mode; violates "respect last mode for navigation." Also there's no global mode concept today. |
| **(B) Pass a navigation-intent enum / `isNewPage` flag into `PageDetailView`** | ❌ Over-engineered. Would require a new param threaded through `WikiDetailView` → `PageDetailView`; `PageDetailView` is constructed with no per-call args today. Adds surface area for one bit. |
| **(C) `EditorTab.isEditing = true` at creation + honor on mount** (chosen) | ✅ Minimal, per-tab, persisted, composes with existing machinery. The tab already carries `isEditing` as the authoritative per-tab edit-mode store. Header expansion follows for free via the existing `.onChange(of: isEditing)` coupling (line 212). |

**Rationale:** `EditorTab.isEditing` is *already* the persisted per-tab source
of truth that tab-switching restores from. Setting it `true` at creation makes
"new pages start editing" a natural property of the tab, not a special UI
channel. Navigation-created tabs keep `isEditing = false` (their default), so
nothing else changes. The only missing piece is the **first-mount seeding gap**
(§2.4 / §7 gotcha), which must be closed in `PageDetailView.onAppear`.

### Why header expansion is free (do NOT add separate state)

`isHeaderExpanded` is already forced `true` whenever `isEditing` becomes `true`
(`PageDetailView.swift:212`). Since we make the new page enter edit mode, the
header expands automatically on the same `.onChange(of: isEditing)` fire. **Do
not** add a parallel `EditorTab.isHeaderExpanded` or `@AppStorage` for the
header — that would duplicate state and risk divergence. The header is a
*consequence* of edit mode here.

---

## 5. Exact files to modify

### 5.1 `Sources/WikiFSCore/Store/WikiStoreModel.swift`

**Change `newPageInNewTab` (lines 1176-1188)** to mark the created tab editing.

Current:
```swift
openTab(.page(page.id), title: title)
```

Proposed (set edit mode on the freshly-created active tab):
```swift
openTab(.page(page.id), title: title)
// New pages start in the editor so the user lands on the source view, not an
// empty rendered page. Per-tab (not global): navigation-opened pages keep
// their own mode. The view's .onChange(of: isEditing) expands the header.
if let id = activeTabID {
    setTabEditing(tabID: id, isEditing: true)
}
```

Notes for the implementer:
- `openTab` ends by calling `setActiveTab(id)`, which leaves `activeTabID`
  pointing at the new tab, so `activeTabID` is non-nil here. Defensive `if let`
  is still correct.
- `setTabEditing` already exists (`:1052`) and is the sanctioned write path.
- This is a model-only change; no store/schema change; no new mutator on
  `SQLiteWikiStore`/`GRDBWikiStore` → **no #129 emission obligation.**

### 5.2 `Sources/WikiFS/Pages/PageDetailView.swift`

**Close the first-mount seeding gap (line 189).** Today `.onAppear` only records
`lastKnownActiveTabID`; it must ALSO seed `isEditing` from the active tab so a
tab created with `isEditing == true` is honored on the very first display.

Current (line 189):
```swift
.onAppear { lastKnownActiveTabID = store.activeTabID }
```

Proposed:
```swift
.onAppear {
    lastKnownActiveTabID = store.activeTabID
    // Seed edit mode from the active tab on first mount. `.onChange(of:
    // store.activeTabID)` (below) only fires on *subsequent* tab switches, so
    // without this a freshly-created "start in editor" tab would render the
    // preview branch on first paint.
    isEditing = store.activeTab?.isEditing ?? false
}
```

This is **safe for navigation-opened pages**: a page opened by clicking a sidebar
row gets a tab with `isEditing == false` (default), so `.onAppear` seeds `false`
— unchanged behavior. Only tabs explicitly created with `isEditing == true`
(namely `newPageInNewTab`) now start editing.

**Verify** the existing `.onChange(of: isEditing)` (line 208-214) still fires
when `.onAppear` sets `isEditing = true`. SwiftUI's `.onChange` does **not** fire
during `.onAppear` synchronously in all cases — but because `isEditing` defaults
to `false` and we set it to `true`, the change *will* propagate and the
`if newValue { isHeaderExpanded = true }` branch runs. **However, to be robust,
also set `isHeaderExpanded = true` directly in `.onAppear` when seeding edit
mode** (defense in depth), since `.onAppear` runs before the first body render
for the editor and the header must be expanded in that same first paint:

```swift
.onAppear {
    lastKnownActiveTabID = store.activeTabID
    let editing = store.activeTab?.isEditing ?? false
    isEditing = editing
    if editing { isHeaderExpanded = true }   // ensure header open in first paint
}
```

(If `.onChange(of: isEditing)` is confirmed to fire for the `.onAppear` write in
a hosted test, the explicit `isHeaderExpanded` line is belt-and-suspenders and
harmless.)

### 5.3 NO changes needed

- `CollapsibleDetailHeader.swift` — owns no state; just a binding consumer.
- `EditorTab.swift` — `isEditing` field already exists.
- `ContentView.swift`, `SidebarView.swift`, `PagesContainerView.swift`,
  `WikiDetailView.swift` — already route to `newPageInNewTab()`; no signature
  change.
- `SQLiteWikiStore` / `GRDBWikiStore` — no new store mutator; no emission work.

---

## 6. State that must persist

- **Edit mode** persists via the existing `EditorTab.isEditing` field (per-tab,
  survives tab close/reopen within the session; cleared when the tab is closed).
  No new persisted field is introduced. There is no `@AppStorage` for view mode,
  so there is **nothing to avoid clobbering** — the new-page default lives only
  on the freshly-created tab.
- **Header expansion** does NOT persist to the tab; it is a transient per-view
  `@State`. For a new page it is `true` because edit mode is `true` (the coupling
  at line 212 / the explicit `.onAppear` set). This matches existing behavior:
  the header has always been transient view state.

---

## 7. Gotchas (read before implementing)

### 7.1 First-mount seeding gap (THE core subtlety)
`PageDetailView.onAppear` historically did NOT read `EditorTab.isEditing`.
Setting the tab's `isEditing = true` in the model is **necessary but not
sufficient** — without the §5.2 `.onAppear` change, the new page still renders
the preview branch on first paint, because `.onChange(of: store.activeTabID)`
only fires on a *change*, and the first mount is not a change. The implementer
MUST add the `.onAppear` seeding or the feature silently does nothing.

### 7.2 Selection-change vs. tab-change interplay
`.onChange(of: store.selection)` (line 190-202) sets `isEditing = false` when
`store.activeTabID == lastKnownActiveTabID` (i.e., in-tab navigation like a
wiki-link click within the same tab). This is correct and must be preserved:
navigating *away* from a page inside the same tab exits edit mode. The new-page
case goes through `setActiveTab` (a real `activeTabID` change), so it triggers
`.onChange(of: store.activeTabID)` (line 203), which restores from the tab —
`true` for our new page. The two `.onChange` bridges must not be reordered or
merged.

### 7.3 PageDetailView view identity
`PageDetailView` is mounted once (no `.id()`), so its `@State` survives
same-type tab switches. This is why per-tab restore works at all. Do NOT add an
`.id(…)` keyed to page ID/tab ID to "fix" anything — that would tear down the
view on every page switch and lose `@State isEditing` (explicitly warned against
at `WikiDetailView.swift:34-41`).

### 7.4 Does the detail view mount before or after the page row exists?
`newPageInNewTab` writes the page to the store **first** (`createPage`), then
calls `openTab`. By the time `PageDetailView` reads drafts (`loadDrafts(for:)`,
`WikiStoreModel.swift:1190-1240` → `store.getPage(id:)`), the row exists. The
bus-driven `reloadFromStore()` is async but `openTab` passes the title
explicitly, so the tab bar label and header title are correct immediately. No
race for the editor-mode feature (which only depends on `EditorTab.isEditing`).

### 7.5 Header and editor are the SAME view subtree
Both `isEditing` and `isHeaderExpanded` live in `PageDetailView`; the header
(`CollapsibleDetailHeader`) is the first child in the `VStack` (line 61) and the
editor/reader content is `contentAndOutline` (line 180). They are not separate
windows/sheets. So one `.onAppear` governs both.

### 7.6 `newPage(title:)` (the OTHER method) is different
`Sources/WikiFSCore/Store/WikiStoreModel.swift:1709` — `newPage(title:)` returns
a `PageID?` and is used by `WikiRegistryClient.createDatabaseIfNeeded`
(`Sources/WikiFSCore/Core/WikiRegistryClient.swift:318`) to seed a "Home" page
on first wiki creation. **Do not change `newPage(title:)`.** It does not open a
tab and is not part of the Add-Page UX. Only `newPageInNewTab` is in scope.

### 7.7 House rules (from AGENTS.md)
- **No `print`** — use `DebugLog` (e.g. `DebugLog.tabs(…)`), subsystem
  `com.selfdrivingwiki.debug`. The existing `PageDetailView` logging already uses
  `DebugLog.tabs`; follow that.
- **No bare `try?`** to swallow errors. `newPageInNewTab` already uses
  `do/catch { DebugLog.store(…) }` — keep that pattern.
- **Swift Testing preferred** over XCTest for new/updated tests
  (`docs/skills/swift-testing-pro`).
- **macOS 15 / Swift 6.0** — filter any iOS 26-only API from skill guidance.
- **Never push/merge to `main`.** Work on a feature branch; open a PR; do not
  merge it yourself.
- **Build/test:** `make build` / `make test` (or `swift build` / `swift test`
  with `make prompts` first). `swift test` is ~1.5 min.
- **#129 change-signaling:** no new store mutator is added, so no new
  `ResourceChangeEvent` obligation. The existing `createPage` already emits.

---

## 8. Testing plan (Swift Testing — name, do NOT write)

Add/extend in **`Tests/WikiFSTests/EditorTabTests.swift`** (it already has the
`newPageInNewTab_createsPageAndOpensTab` test at line 692 and the
`isActiveTabEditing_*` family at 874+):

1. **`newPageInNewTab_setsActiveTabEditingTrue`** (new) — after
   `model.newPageInNewTab(title:)`, assert `model.activeTab?.isEditing == true`
   and `model.isActiveTabEditing == true`. This pins the §5.1 model change.
2. **`newPageInNewTab_doesNotAffectOtherTabs`** (new) — create page A (normal
   `openTab(.page(a))`), assert `tabs[0].isEditing == false`; then
   `newPageInNewTab`, assert the new tab is editing and the old one is still
   `false`. Guards the scope ("only new pages").
3. **Update `newPageInNewTab_createsPageAndOpensTab`** (existing, line 692) —
   add an assertion that `model.tabs[0].isEditing == true` (currently it would
   be `false`). Keep the existing page-creation + tab assertions.

Note: the §5.2 view-layer seeding (`.onAppear`) is **not** unit-testable without
hosting `PageDetailView` in an `NSWindow` (see
`docs/skills/reproducing-live-ui-bugs` for the hosted-view test pattern).
Recommend a hosted SwiftUI test if feasible; otherwise verify manually per the
acceptance criteria. Name it e.g.
**`PageDetailViewHostedTests.opensNewPageTabInEditMode`** if added under
`Tests/WikiFSTests/`.

Run: `swift test --filter EditorTabTests` then `swift test` (full suite).

---

## 9. Acceptance criteria

- [ ] `swift build` succeeds (`make build`).
- [ ] `swift test` passes (full suite, ~1.5 min), incl. the new/updated
      `EditorTabTests`.
- [ ] **Welcome screen → "Add Page":** new page opens with the **editor**
      (source view) visible and the **title/header pane expanded** (date + Save
      Changes / Cancel buttons visible, not just the title row).
- [ ] **Sidebar → "+" (New Page):** same as above (both route through
      `newPageInNewTab`).
- [ ] **Sidebar single-click on an existing page:** opens in **rendered/preview**
      mode (NOT forced into edit mode), header **collapsed** — i.e., behavior
      unchanged.
- [ ] **`[[wiki-link]]` click within a tab:** exits edit mode (unchanged).
- [ ] **Tab switch away and back to a *new* page:** returns to edit mode
      (restored from `EditorTab.isEditing == true`).
- [ ] **Tab switch away and back to a *navigation-opened* page:** stays in the
      mode that tab had (rendered by default).
- [ ] No new `print` calls; no bare `try?`; no `@AppStorage` added for view mode.
- [ ] No changes to `newPage(title:)`, `CollapsibleDetailHeader`, or
      `EditorTab` struct fields.

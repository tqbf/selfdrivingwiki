# Plan: Global Keyboard Shortcuts for the Five "Add" Actions

**Status:** Investigation complete, ready to implement
**Target:** macOS 15 / Swift 6.0 · SwiftUI App Lifecycle
**Scope:** Add Page, Add URL, Add File, Add Folder, Add Chat — each reachable via a global keyboard shortcut from anywhere in the app (no view-specific focus required).

---

## 1. Goal

Every "Add" button currently surfaced in the sidebar headers and the welcome/empty-state screen must also be triggerable by a **global keyboard shortcut** that fires regardless of which view has keyboard focus. The shortcut must invoke the **same handler** the on-screen button uses — no duplicated logic.

---

## 2. Current-state map (the five Add actions)

The five actions have **no common dispatcher**. Each is wired ad-hoc, per view, but they all funnel to a small set of handlers on the per-wiki `WikiStoreModel` (or to a `@State` sheet toggle on `ContentView`). The model is the natural single chokepoint.

| # | Action | UI entry points (file:line) | Final handler (file:line) |
|---|--------|------------------------------|----------------------------|
| 1 | **Add Page** | Sidebar Pages header `+` — `PagesContainerView.swift:83-85` (`onNewPage`) · Welcome screen — `WikiDetailView.swift:117-119` (`addPage`) · `ContentView.swift:149` passes `onNewPage: { store.newPageInNewTab() }` | `WikiStoreModel.newPageInNewTab(title:)` — `WikiFSCore/Store/WikiStoreModel.swift:1176` |
| 2 | **Add URL** | Sidebar Sources header — `SourcesContainerView.swift:126-128` (`onAddFromURL`) · Welcome screen — `WikiDetailView.swift:122-124` (`addURLHandler?("")`) | Presents the `AddFromURLSheet` via `@State pendingAddURL` on `ContentView.swift:22,59-61`. The actual ingest is `WikiStoreModel.addURL(...)` — `WikiStoreModel.swift:2029` / `2065` (the fetch path). |
| 3 | **Add File** | Sidebar Sources header — `SourcesContainerView.swift:129-131` (`addFile`) · Welcome screen — `WikiDetailView.swift:125` (`addFile`) | `WikiDetailView.addFile()` — `WikiDetailView.swift:258-264` → `store.addFiles([url])`. The button calls an open panel then the model. |
| 4 | **Add Folder** | Sidebar Sources header — `SourcesContainerView.swift:132-134` (toggles `showingImportMarkdown`) · Welcome screen — `WikiDetailView.swift:126-128` | Presents `ImportMarkdownSheet` via `@State showingImportMarkdown` on `ContentView.swift:31,69` (a directory picker that recursively imports `.md`/`.pdf`). |
| 5 | **Add Chat** | Chats sidebar header `+` — `AgentToolsView.swift:77-86` · Welcome screen — `WikiDetailView.swift:141-143` (`addChat`) · Address bar — `AddressBarView.swift:360` | `WikiStoreModel.openTab(.newChat)` — `WikiStoreModel.swift:970`. Three call sites all use the same call. |

### Notes
- **Add Chat and Add Page are pure model calls** (`store.openTab(.newChat)` / `store.newPageInNewTab()`) — trivially reusable.
- **Add URL and Add Folder are sheet presentations** gated by `@State` on `ContentView` (`pendingAddURL`, `showingImportMarkdown`). The sheet state is local to `ContentView`; a global trigger must live on (or reach) `ContentView`.
- **Add File opens an `NSOpenPanel` then calls the model** (`WikiFilePanels.chooseFile` → `store.addFiles([url])`).
- The sidebar headers (`PagesContainerView`, `SourcesContainerView`, `AgentToolsView`) and the welcome screen (`WikiDetailView`) are all descendants of `ContentView` and all receive the same `store: WikiStoreModel`.

---

## 3. The app's existing keybinding idiom

The app uses **two** mechanisms for global-ish shortcuts. Neither uses `@FocusedValue`/`@FocusedObject` (confirmed: zero usages in the whole tree).

### 3a. Hidden `.keyboardShortcut` buttons on `ContentView` (PRIMARY global mechanism)
File: `Sources/WikiFS/Window/ContentView.swift:344-376` — the private `keyboardShortcutButtons` view, placed in the detail column's `.background { ... }` (line 258) so it is **always in the responder chain** for the active wiki window. Each shortcut is an invisible button:

```swift
private var keyboardShortcutButtons: some View {
    Button("") { if let id = store.activeTabID { store.closeTab(id: id) } }
        .keyboardShortcut("w", modifiers: .command)
        .opacity(0).allowsHitTesting(false)
        .disabled(store.tabs.isEmpty)
    // ... Cmd+Shift+T, Cmd+L, Cmd+1..9
}
```

This is the **established, in-tree pattern for app-global shortcuts bound to a per-wiki model**. It is exactly the right home for the five Add actions: it already has `store` in scope, and the buttons are window-global.

### 3b. SwiftUI `.commands { }` menu commands (for app-lifetime, model-independent items)
File: `Sources/WikiFS/Window/WikiFSApp.swift:450-461`. Currently three groups:
- `CommandGroup(replacing: .newItem) { }` — suppresses the default File ▸ New Window (Cmd+N) — **deliberately empty** (issue #396: single-window-per-wiki).
- `VacuumCommands(sessionManager:)` — a maintenance command group after `.help`.
- `WindowMenuCommands(...)` — the Window menu's open-windows list + tab cycling (⇧⌘[ / ⇧⌘], `WindowMenuCommands.swift:112-115`).

These commands live on the `App`, which does **not** directly hold a per-wiki `WikiStoreModel` (it holds `sessionManager`, `registry`, `windowTracker`). Reaching the frontmost wiki's store from a menu command would require going through `sessionManager.frontmostSession?.store` (the same indirection `WindowMenuCommands.cycleTab` uses at `WindowMenuCommands.swift:135`).

### 3c. `NSEvent.addLocalMonitorForEvents` (scoped, not global)
Used only for narrow, view-local behavior: autocomplete key handling (`WikiLinkAutocompleteController.swift:434`), scroll-wheel swipe nav (`SwipeNavigation.swift:71`). **Not appropriate** for global Add shortcuts.

### Decision: which mechanism?
**Use 3a (hidden `.keyboardShortcut` buttons on `ContentView`).** Reasons:
1. It is the existing in-tree idiom for exactly this case (global shortcuts tied to the active wiki's model).
2. `ContentView` already owns the sheet state (`pendingAddURL`, `showingImportMarkdown`) that Add URL and Add Folder need, and has `store` in scope for the other three.
3. It avoids the `frontmostSession` indirection and keeps the handlers identical to the on-screen buttons — zero duplicated logic, zero new `@FocusedValue` plumbing.
4. It is **rebase-safe** with any in-flight Add Page work: Add Page's button handler is `store.newPageInNewTab()`; the new global button calls the same one-liner. No shared edited lines.

A menu command (`CommandGroup`) is a reasonable *secondary* surface for discoverability (File ▸ New ▸ …), but it is **not required** for the shortcuts to work globally, and adding one would need `frontmostSession` plumbing. Recommend deferring the menu group unless discoverability is explicitly wanted; the shortcuts themselves go on `ContentView`.

---

## 4. Existing shortcut collisions (table)

All `.keyboardShortcut` usages in `Sources/WikiFS`, audited for global (non-sheet, non-view-local) conflicts:

| Shortcut | Where | Scope | Conflicts with our plan? |
|----------|-------|-------|--------------------------|
| ⌘W | `ContentView.swift:352` | Global (close tab) | ✅ taken — avoid |
| ⇧⌘T | `ContentView.swift:358` | Global (reopen closed tab) | ✅ taken — avoid |
| ⌘L | `ContentView.swift:367` | Global (focus address bar) | ✅ taken — avoid |
| ⌘1 … ⌘9 | `ContentView.swift:373` | Global (switch tab by index) | ✅ taken — avoid ⌘N for single-digit combos |
| ⇧⌘[ / ⇧⌘] | `WindowMenuCommands.swift:113/115` | Global (cycle tabs) | ✅ taken — avoid |
| ⌘[ / ⌘] | `AddressBarView.swift:97/102` | Address-bar menu (back/forward) | ⚠️ view-local; avoid to prevent confusion |
| ⌘F | `ContentView.swift:371` area / `SourceDetailView.swift:1549` | Find | ✅ taken — avoid |
| ⌘S | `SourceDetailView.swift:574`, `SystemPromptDetailView.swift:33` | Save (in detail views) | ✅ taken — avoid |
| ⌘E | `SourceDetailView.swift:665` | Export | ✅ taken — avoid |
| ⌘↩ | `SourceDetailView.swift:1493`, `ChatView.swift:965` | Send/run (in detail) | ✅ taken — avoid |
| ⎋ | various sheets / find bar | Cancel | n/a |
| ⏎ / .defaultAction, .cancelAction | sheet buttons | sheet-scoped | n/a |

### macOS-reserved / conventional (must not hijack)
⌘N (New — **intentionally suppressed**, see §3b; do **not** reclaim), ⌘O (Open), ⌘W (close), ⌘M (minimize), ⌘T (new tab — note: ⇧⌘T is taken for reopen), ⌘Q (quit), ⌘, (settings), ⌘H (hide), ⌘Space (Spotlight — system), ⌘⇧N (Finder "New Folder" — avoid for muscle-memory confusion even though not reserved here).

### Free / safe space
⌘N is suppressed-and-free but semantically loaded — **not recommended** (it was disabled on purpose, issue #396). Cleanest available families: **⌘⇧ + letter**, or **⌃⌘ + letter**. Given the app already uses ⇧⌘ for tabs (⇧⌘[, ⇧⌘], ⇧⌘T), a consistent **⌘⇧ &lt;letter&gt;** family is the most idiomatic.

---

## 5. Proposed bindings

A single, consistent family: **⌘⇧ + mnemonic letter**. All verified free against §4 and macOS conventions.

| Action | Shortcut | Mnemonic | Collision check |
|--------|----------|----------|-----------------|
| **Add Page** | ⌘⇧P | **P**age | Free. (Not ⇧⌘[ / ] / T; ⌘P is system Print but **not** used app-wide — adding ⇧⌘P is unambiguous and avoids the deliberately-suppressed ⌘N.) |
| **Add URL** | ⌘⇧U | **U**RL | Free. |
| **Add File** | ⌘⇧F | **F**ile | ⚠️ ⌘F (Find) is in use, but **⌘⇧F** specifically is free. Acceptable; the shift disambiguates. Alternative if confusion is a concern: ⌘⇧O (**O**pen file) — also free. **Recommend ⌘⇧F** for mnemonic parity with the on-screen "Add File" label. |
| **Add Folder** | ⌘⇧D | **D**irectory/Folder | Free. (⌘⇧D avoids clashing with ⌘⇧F used by Add File.) |
| **Add Chat** | ⌘⇧C | **C**hat | Free. (⌘C copy is system; ⌘⇧C "Copy Style" is not used here.) |

**Justification summary:** the ⌘⇧ family is already established in-app for "new/special" actions (reopen tab ⇧⌘T, cycle tabs ⇧⌘[/]). Every proposed binding is mnemonic (first letter of the noun) and verified unclaimed. No ⌘N reclaim (respect issue #396).

---

## 6. Exact files to modify

### Primary (the only edit needed for functionality)
**`Sources/WikiFS/Window/ContentView.swift`** — extend the existing `keyboardShortcutButtons` view (lines 344–376) with five new invisible buttons. All five handlers are already reachable from `ContentView`'s scope:

```swift
// ⌘⇧P — Add Page (same handler as sidebar + / welcome addPage)
Button("") { store.newPageInNewTab() }
    .keyboardShortcut("p", modifiers: [.command, .shift])
    .opacity(0).allowsHitTesting(false)

// ⌘⇧U — Add from URL (present the sheet, same as onAddFromURL)
Button("") { pendingAddURL = PendingAddURL(url: "") }
    .keyboardShortcut("u", modifiers: [.command, .shift])
    .opacity(0).allowsHitTesting(false)

// ⌘⇧F — Add File (open panel → store.addFiles; mirrors WikiDetailView.addFile)
Button("") {
    if let url = WikiFilePanels.chooseFile(title: "Add File", prompt: "Add File") {
        Task { await store.addFiles([url]) }
    }
}
.keyboardShortcut("f", modifiers: [.command, .shift])
.opacity(0).allowsHitTesting(false)

// ⌘⇧D — Add Folder (present ImportMarkdownSheet, same as showingImportMarkdown)
Button("") { showingImportMarkdown = true }
    .keyboardShortcut("d", modifiers: [.command, .shift])
    .opacity(0).allowsHitTesting(false)

// ⌘⇧C — Add Chat (same handler as chats sidebar + / welcome addChat)
Button("") { store.openTab(.newChat) }
    .keyboardShortcut("c", modifiers: [.command, .shift])
    .opacity(0).allowsHitTesting(false)
```

`ContentView` already has `pendingAddURL` (line 22), `showingImportMarkdown` (line 31), and `store` (line 11) in scope — no new `@State`, no new plumbing. `WikiFilePanels` is already imported/used by `WikiDetailView.addFile`.

### Optional (discoverability only — defer unless wanted)
**`Sources/WikiFS/Window/WikiFSApp.swift`** `.commands { }` block (line 450) — could add a `CommandGroup(after: .newItem)` or replace the empty `newItem` group with a "New" submenu surfacing the five actions. Each menu `Button` would route through `sessionManager.frontmostSession?.store` (the `WindowMenuCommands.cycleTab` pattern at `WindowMenuCommands.swift:135`) and call the same model methods, with `.keyboardShortcut` mirroring §5. **This is additive and independent** — the hidden-button mechanism on `ContentView` is sufficient for the shortcuts to work globally, so the menu group is purely a discoverability nicety.

### Rebase safety vs. in-flight Add Page work
The five new buttons are a **pure addition** inside an existing `@ViewBuilder` computed property. They touch no lines the on-screen Add Page button or its handler own. The Add Page shortcut calls `store.newPageInNewTab()` — the identical call already at `ContentView.swift:149` — so there is no logic to duplicate or merge. If the in-flight work changes `newPageInNewTab`'s signature, only this one-liner needs updating (same as the existing on-screen button).

---

## 7. Testing plan

### Unit / logic tests (Swift Testing)
The shortcut wiring itself is UI glue (not unit-testable without UI tests), but the **handlers it invokes** already have coverage paths. Add focused tests only for any new pure dispatch logic introduced. Concretely:
- If the optional menu-command path is added, add a tiny test that the command's action closure calls the expected model method — but since it routes through `sessionManager.frontmostSession?.store`, this is best left to manual validation.
- **No new unit tests required for the hidden-button approach** (it reuses existing handlers verbatim).

### Manual validation matrix (required)
Build with `make build`, launch, and verify each shortcut fires from **different focus contexts** (this is the whole point of "global"):

| Focus context | ⌘⇧P (Page) | ⌘⇧U (URL) | ⌘⇧F (File) | ⌘⇧D (Folder) | ⌘⇧C (Chat) |
|---------------|:---:|:---:|:---:|:---:|:---:|
| Sidebar — Pages section | ✓ | ✓ | ✓ | ✓ | ✓ |
| Sidebar — Sources section | ✓ | ✓ | ✓ | ✓ | ✓ |
| Sidebar — Chats section | ✓ | ✓ | ✓ | ✓ | ✓ |
| Page editor (text caret in editor) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Chat composer (text caret) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Address bar focused (after ⌘L) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Welcome / empty state | ✓ | ✓ | ✓ | ✓ | ✓ |
| Settings window open (does it fire? — expected: no, separate window) | — | — | — | — | — |

Run `make test` before the PR (full Swift suite, ~1.5 min, in-memory SQLite fixtures).

---

## 8. Acceptance criteria
1. All five Add actions are triggerable by their shortcut from every in-app focus context listed in §7 (sidebar, editor, chat composer, address bar, welcome state).
2. Each shortcut invokes the **same handler** as its on-screen button (no divergent code path): Add Page → `newPageInNewTab`; Add URL → `AddFromURLSheet` (empty URL); Add File → open panel → `addFiles`; Add Folder → `ImportMarkdownSheet`; Add Chat → `openTab(.newChat)`.
3. No collision with any existing shortcut in §4 or with macOS-reserved bindings; ⌘N remains suppressed (issue #396 respected).
4. `make build` and `make test` pass.
5. Shortcuts do **not** fire when the Settings window (or any non-wiki window) is key — they are scoped to the wiki `ContentView`'s responder chain by construction.

---

## 9. Gotchas
- **`pendingAddURL` / `showingImportMarkdown` are `@State` on `ContentView`.** The hidden buttons are defined inside `ContentView`, so they close over that state directly — correct. Do **not** try to present these sheets from a menu command on the `App` (it has no access to that state); the hidden-button approach sidesteps this entirely.
- **Add File opens a modal `NSOpenPanel`.** `WikiFilePanels.chooseFile` must run on the main actor; the `Button` action closure is already main-actor, and `store.addFiles` is `async`, so wrap it in `Task { await ... }` exactly as `WikiDetailView.addFile` does (`WikiDetailView.swift:260-262`).
- **`.opacity(0).allowsHitTesting(false)` is mandatory** on every hidden button — without it they render as phantom tappable blanks in the detail background. Copy the existing entries verbatim.
- **`.disabled(...)` gating is optional.** The existing entries disable themselves when N/A (e.g. close-tab when `tabs.isEmpty`). The Add actions are always valid in a wiki window, so no `.disabled` is needed — but Add Chat's `openTab(.newChat)` is a no-op-safe call regardless.
- **Do not reclaim ⌘N.** It is deliberately suppressed (`WikiFSApp.swift:454`, issue #396). Use ⌘⇧P for Add Page instead.
- **`@FocusedValue` is not needed.** The handlers are reachable directly from `ContentView`'s scope (it owns `store` and the sheet state). Introducing `@FocusedValue` here would add complexity for no benefit and diverge from the established `keyboardShortcutButtons` idiom.
- **Verify after implementation** that the shortcuts still fire when a sheet (e.g. AddFromURLSheet) is *not* open — they live on `ContentView`, which stays mounted, so this should hold. If any shortcut is swallowed while a particular detail view is focused, fall back to also adding a `CommandGroup` (§6 optional) which is unconditionally global.

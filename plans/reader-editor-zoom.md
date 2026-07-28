# Plan: Reader & Editor Zoom (⌘+ / ⌘− / ⌘0)

Give the page **reader** and **editor** Safari-style text zoom driven by keyboard
shortcuts. Continuous scale, independent zoom per mode, keyboard-only (no menu,
no on-screen widget), persisted globally.

## Decisions (locked with user)

- **Mechanism:** continuous multiplier (not discrete Dynamic Type).
- **Scope:** reader and editor keep **separate** zoom levels.
- **Surface:** keyboard only — ⌘+ / ⌘= zoom in, ⌘− out, ⌘0 reset. No menu item,
  no visible control.
- **Persistence:** global, via `@AppStorage` (the first such keys in the app).
  Two keys: `reader.zoom`, `editor.zoom`, both default `1.0`.
- Use a branch off main called `feature/page-zoom`

## Context inventory (verified)

- Reader renders via `MarkdownPreview` → `StructuredText` with **no font set**
  (`MarkdownPreview.swift:37`); base size = SwiftUI `.body` (`FontScaled.swift:35`).
  Textual exposes a public `.textual.fontScale(_:)` view modifier
  (`View+Textual.swift:136`) that scales body **and** proportional headings/spacing.
- Editor uses fixed `.font(.system(.body, design: .monospaced))`
  (`PageDetailView.swift:72`); reader vs. editor mode are mutually exclusive in
  `PageDetailView`.
- Commands today: `CommandGroup` structs in `WikiFSApp.swift:105`. Not used here —
  user wants no menu. No `AppStorage`/`UserDefaults` exists yet.

## Approach

A pure, testable `ZoomScale` value in `WikiFSCore` owns clamping/stepping. Each
surface reads its `@AppStorage` key and applies the multiplier. Keyboard input
comes from **hidden `Button`s carrying `.keyboardShortcut(...)`** placed inside
each mode's subtree — they handle the chord while that mode is on screen and
mutate only that mode's key. No menu, no app-level command, no focused-value
plumbing.

```
ZoomScale (pure):   clamp(0.5...3.0); zoomIn = ×1.1; zoomOut = ÷1.1; reset = 1.0
reader subtree:     hidden ⌘+ ⌘= ⌘- ⌘0 buttons → reader.zoom
                    StructuredText(...).textual.fontScale(reader.zoom)
editor subtree:     hidden ⌘+ ⌘= ⌘- ⌘0 buttons → editor.zoom
                    TextEditor(...).font(.system(size: 13 * editor.zoom,
                                                 design: .monospaced))
```

(`13` mirrors the macOS semantic `.body` default; `1.0` ⇒ today's size exactly.)

## Steps

### 1. Pure `ZoomScale` model + tests
Add `Sources/WikiFSCore/ZoomScale.swift`: a small value type / namespace with
bounds (`0.5...3.0`), `zoomedIn()`, `zoomedOut()` (×/÷ 1.1, clamped), and
`reset = 1.0`. Add `Tests/WikiFSTests/ZoomScaleTests.swift` covering clamping at
both bounds, in/out symmetry, and reset. No UI yet.

### 2. Apply continuous zoom to reader and editor
Read the keys and apply the multiplier. The reader change lives in the shared
`MarkdownPreview`, so **both** the page reader and the ingested-file viewer scale
from one edit; the editor change is applied to each monospace `TextEditor`.
- `MarkdownPreview.swift`: `@AppStorage("reader.zoom")`; add
  `.textual.fontScale(readerZoom)` to `StructuredText` (`:37`).
- `PageDetailView.swift`: `@AppStorage("editor.zoom")`; change the editor font
  (`:72`) to `.system(size: 13 * editorZoom, design: .monospaced)`.
- `IngestedFileDetailView.swift`: same `@AppStorage("editor.zoom")` font change
  on its `TextEditor` (`:327`). (Its reader already scales via `MarkdownPreview`.)
No shortcuts yet — verify by hand-editing the stored defaults (or a temporary
stepper) that text scales and `1.0` is unchanged from today.

### 3. Wire keyboard-only shortcuts per mode
In **both** `PageDetailView` and `IngestedFileDetailView`, attach hidden shortcut
buttons to each mode's subtree: reader-mode buttons mutate `reader.zoom`,
editor-mode buttons mutate `editor.zoom`, each via the `ZoomScale` helper. Bind
⌘+ **and** ⌘= to zoom-in (Safari parity), ⌘− to zoom-out, ⌘0 to reset. Buttons
are `.hidden()` so they never render but still service the chord while their mode
is shown. Because the keys are global, zoom set in one view carries into the other.

## Acceptance criteria

**Step 1** — `swift test --filter ZoomScaleTests` passes; stepping past a bound
clamps; `zoomedIn` then `zoomedOut` returns to start; `reset` ⇒ `1.0`.

**Step 2** — With `reader.zoom`/`editor.zoom` = `1.0`, reader and editor look
identical to `main` (no visual regression). Setting a key to `2.0` visibly
doubles that surface's text, headings and spacing scaling together in the reader;
the other surface is unaffected. `swift build` clean.

**Step 3** — In reader mode, ⌘+ / ⌘= enlarge and ⌘− shrinks the rendered page;
⌘0 returns to default. In editor mode the same chords scale the monospace source
independently of the reader. The chords work in **both** the page detail view and
the ingested-file viewer, and a zoom set in one carries into the other (shared
keys). The chords change **only** the on-screen mode. No new menu items appear.
Zoom survives app relaunch (persisted). Existing tests unchanged and green.

## Definition of done

All three steps' criteria met; `swift build` and `swift test` green with no
regressions; reader and editor zoom independently via keyboard only, persist
across launches, and `1.0` reproduces current appearance exactly. `progress/`
updated and `PLAN.md` index references this plan per `CLAUDE.md`.

## Out of scope / notes

- No View-menu item or on-screen control (per decision).
- Zoom is shared (global keys) across the page reader/editor and the
  ingested-file viewer's reader/editor; shortcuts are wired in both views.
- If hidden-button shortcuts prove unreliable on the target macOS, fall back to
  `.onKeyPress` within each focused mode — same per-mode mutation, still no menu.

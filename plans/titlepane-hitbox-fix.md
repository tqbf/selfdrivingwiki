# Title-Pane Hit-Box / Gesture Fix

> Re-investigation of the chat title-pane click bug. PR #717 (changed the row
> from `onTapGesture(count: 2)` to a single `onTapGesture`) was **insufficient**:
> clicking the **chat** title row still does not toggle the pane.
> macOS 15 / Swift 6.0. This is **live-UI gesture behavior — NOT unit-testable.**

## 1. Goal

A **single click anywhere on the full title row** (including directly on the title
text) must toggle (expand/collapse) the `CollapsibleDetailHeader` pane — for the
chat header in particular, whose title is long and fills the row. A
**double-click on the title text** must still enter rename mode. There must be
**no toggle-flicker** when double-clicking to rename.

## 2. Root cause (confirmed)

Two gestures, one on the parent row and one on the child title text, with the
child **occluding** the parent over the text region.

### The parent row — `Sources/WikiFS/Editor/CollapsibleDetailHeader.swift`
`titleRow` (lines 42–81). After the row's children, the modifiers are:

```swift
// CollapsibleDetailHeader.swift:72-80
.frame(maxWidth: .infinity, alignment: .leading)   // :72  row spans full width
.contentShape(Rectangle())                         // :73  hit area = whole row
.onTapGesture {                                    // :74  SINGLE tap (post-#717)
    DebugLog.tabs("…header tapped…")
    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
}
.hoverRowBackground()                              // :80
```

### The child title text — `Sources/WikiFS/Editor/EditableTitle.swift`
Display branch (lines 50–64). The `Text` carries its **own** hit shape and a
**double-tap** rename gesture, applied to the `Text` **before** the outer
`.frame(maxWidth: .infinity)`:

```swift
// EditableTitle.swift:50-66
Text(display)
    .font(font).fontWeight(.bold).lineLimit(lineLimit)
    .contentShape(Rectangle())          // :54  hit area = TEXT GLYPH BOUNDS
    .onTapGesture(count: 2) { begin() } // :55  DOUBLE tap -> rename
    .contextMenu { Button("Rename")… ; Button("Copy")… }
}
…                                   // (end of Group if/else)
.frame(maxWidth: .infinity, alignment: .leading)  // :66  EXPANDS frame; contentShape
                                                  //      was set on the Text, so the
                                                  //      trailing area has NO child hit
```

### Why the parent single-tap is unreachable on chat

1. **Child gesture wins by default.** SwiftUI always triggers the recognizer on
   the child before the parent when both views have a gesture recognizer over the
   same point (documented behavior; confirmed by Hacking with Swift's
   `highPriorityGesture` article). So over the title text the `EditableTitle`
   recognizer "owns" the hit — the parent's `.onTapGesture` never fires there.
2. **`count: 2` still occludes `count: 1`.** Even though a single click can never
   satisfy a double-tap, the child's recognizer still **claims the text region**
   and does **not** fall through to the parent. (This is exactly the symptom the
   operator sees: single-click on the chat title text → no toggle.)
3. **The parent's single-tap only reaches empty space.** The parent's
   `contentShape` only "fills the holes" — regions of the row **not** covered by
   an interactive child (the chevron `Button` and the `EditableTitle` text both
   claim their own areas). So the parent fires only in the icon area + the empty
   space to the right of the title text.
4. **Chat leaves no empty space.** The chat caller passes `titleLineLimit: 1`
   (`Sources/WikiFS/Chats/ChatView.swift:544`) and chat titles are typically long,
   so the single-line glyph run fills (nearly) the whole `readableContentWidth`
   (760 pt, `PageEditorMetrics.swift:9`) row. → No empty space → **the parent
   single-tap is unreachable** → click does nothing.
   - **Page "works"** only because page titles are short / wrap
     (`PageDetailView.swift:61`, no `titleLineLimit`) and leave empty space to
     the right of the glyphs that falls through to the parent.
   - **Source** uses `titleLineLimit: 2` (`SourceDetailView.swift:509`) — same
     latent bug for long single-line source names.

5. **Non-interfering (ruled out):** `hoverRowBackground`
   (`Sources/WikiFS/Editor/HoverRowBackground.swift:11-19`) is only a
   `.background` + `.onHover` + `.animation` — no gesture, no `contentShape`, so
   it does not affect hit-testing. The chevron `Button`
   (`CollapsibleDetailHeader.swift:44-57`) only claims its own 12×12 frame.

### Why #717 didn't help

#717 changed the **parent** gesture from `count: 2` → `count: 1` but did **not**
change **who wins the hit-test**. The child `EditableTitle` still occludes the
text region, so on chat the parent's single-tap is still unreachable. Changing
the count fixed nothing because the parent gesture was never firing over the text
in the first place.

## 3. The fix

Put **both** tap recognizers on the **same** `Text` so SwiftUI's built-in
single-vs-double disambiguation resolves them cleanly, and route the single tap
back to the row's toggle via a new optional closure. Keep the row's own
single-tap for the non-text regions (icon + empty space).

### 3a. `EditableTitle.swift` — add a single-tap hook

Add an optional closure property (next to the other config, ~line 24):

```swift
// NEW (e.g. after `var isDisabled: Bool = false`, ~line 23)
/// Single-tap on the title text. The detail header uses this to toggle
/// expand/collapse, so a click anywhere on the row toggles — not just the
/// empty space beside the title. Defaults to nil so other callers are unaffected.
var onSingleTap: (() -> Void)? = nil
```

In the display branch, attach a `count: 1` recognizer **after** the existing
`count: 2` (canonical order — double first, then single — so SwiftUI delays the
single tap by the double-click interval and suppresses it when a rename
double-tap is recognized):

```swift
// EditableTitle.swift:50-55  (BEFORE)
Text(display)
    .font(font)
    .fontWeight(.bold)
    .lineLimit(lineLimit)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { begin() }
    .contextMenu { … }

// (AFTER)
Text(display)
    .font(font)
    .fontWeight(.bold)
    .lineLimit(lineLimit)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { begin() }                 // rename (unchanged)
    .onTapGesture(count: 1) { onSingleTap?() }          // NEW: row toggle
    .contextMenu { … }
```

Notes:
- `onSingleTap` defaults to `nil` → every existing `EditableTitle` call site
  that doesn't pass it is unaffected (text still renames on double-click, still
  has its context menu; nothing else changes).
- `begin()` stays private and unchanged; rename logic is untouched.

### 3b. `CollapsibleDetailHeader.swift` — pass the toggle into the title

Wire the row's toggle through the new hook, and extract a tiny helper so the row
and the text share one toggle implementation:

```swift
// CollapsibleDetailHeader.swift  (new private helper)
private func toggleExpanded() {
    DebugLog.tabs("CollapsibleDetailHeader: header tapped — wasExpanded=\(isExpanded)")
    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
}

// titleRow HStack, EditableTitle initializer (≈ lines 60-66) — pass onSingleTap:
EditableTitle(
    title: title,
    placeholder: placeholder,
    lineLimit: titleLineLimit,
    isDisabled: isTitleDisabled,
    onSingleTap: toggleExpanded,        // NEW
    onCommit: onTitleCommit
)

// row gesture (≈ lines 73-79) now calls the helper (unchanged behavior, DRY):
.contentShape(Rectangle())
.onTapGesture { toggleExpanded() }      // covers icon + empty space
.hoverRowBackground()
```

### 3c. Resulting hit-test map

| Region of the row                       | Who owns the hit                | Single click          | Double click                          |
|-----------------------------------------|---------------------------------|-----------------------|---------------------------------------|
| Chevron (12×12)                         | chevron `Button`                | toggle (Button)       | toggle twice (no-op)                  |
| Resource icon                           | row `.contentShape` / `count:1` | **toggle**            | toggle twice (no-op); no rename here  |
| **Title text (glyph bounds)**           | `EditableTitle` `count:1`+`2`   | **toggle** (delayed*) | **rename** (count:1 suppressed)       |
| Empty space right of title              | row `.contentShape` / `count:1` | **toggle**            | toggle twice (no-op)                  |

\* The single tap on the text is delayed by the system double-click interval
(~0.25–0.35 s) while SwiftUI waits to see if it becomes a rename double-tap; if
not, it fires the toggle. This is the standard macOS "single-click opens /
double-click renames" timing (e.g. Finder) and is expected/acceptable. Clicks on
the icon or empty space toggle immediately (no competing double-tap there).

## 4. Why the alternatives were rejected

- **`.highPriorityGesture(TapGesture())` on the row (count:1).** High priority
  makes the row win over the child — but then on a double-click the row's
  count:1 fires on the **first** tap and steals the sequence, so the child's
  `count:2` rename **never fires**. Rename would break. ✗
- **`.simultaneousGesture` for the row toggle.** A single click toggles (good),
  but a double-click would fire the row count:1 on **each** of the two taps
  (toggle → toggle = flicker) **and** fire rename → visible expand/collapse
  flicker while the rename field mounts. Violates the "no flicker" requirement. ✗
- **Move rename entirely off the text** (rename only via context menu). Satisfies
  the toggle but removes the discoverable double-click-to-rename interaction,
  which the task requires preserving. ✗
- **Shrink `EditableTitle`'s contentShape.** Doesn't help — even without an
  explicit `contentShape` the `Text`'s default hit shape is its glyphs, which for
  a long single-line chat title still fill the row. The child recognizer still
  occludes the parent. ✗
- **Transparent full-row overlay above the text carrying count:1.** The overlay
  would sit above the text in z-order and occlude the text's `count:2` rename, so
  you'd have to re-add disambiguation on the overlay anyway — strictly more
  moving parts than putting both recognizers on the text. ✗

The chosen approach is the **minimal** change: one optional closure + one extra
`.onTapGesture(count: 1)` line, leveraging SwiftUI's own single/double
disambiguation rather than fighting the priority system.

## 5. Files to modify

1. `Sources/WikiFS/Editor/EditableTitle.swift`
   - Add `var onSingleTap: (() -> Void)? = nil` (~line 24).
   - Add `.onTapGesture(count: 1) { onSingleTap?() }` after line 55.
2. `Sources/WikiFS/Editor/CollapsibleDetailHeader.swift`
   - Add `private func toggleExpanded()` helper.
   - Pass `onSingleTap: toggleExpanded` to `EditableTitle` (~line 60-66).
   - Route the row `.onTapGesture` (line 74) through `toggleExpanded()`.

No other call sites of `EditableTitle` need changes (`onSingleTap` defaults nil).
No new dependencies, no store/schema/event-bus changes.

## 6. Testing (manual live validation — NOT unit-testable)

This is gesture/hit-test wiring over the real view tree; it cannot be asserted in
a unit test. Follow the `reproducing-live-ui-bugs` skill: instrument the toggle
seam via `DebugLog.tabs(...)` (already present at `CollapsibleDetailHeader.swift`
lines 45 & 75) and read it back from Console.app.

**Build:** `make build` (regenerates prompts/version), run the app, open a chat
with a **long** title (fills the 760 pt row).

Capture the trace:
```bash
log show --predicate 'subsystem == "com.selfdrivingwiki.debug" AND category == "tabs"' \
         --last 2m --style compact
```

**Acceptance checks (all must pass):**
1. **Single-click on the long chat title TEXT** → `CollapsibleDetailHeader: header
   tapped…` appears in the log AND the pane expands/collapses. (This is the
   regression that #717 failed.)
2. **Single-click on empty space** beside a short title (Page) → toggles
   immediately (unchanged).
3. **Single-click on the resource icon** → toggles.
4. **Double-click on the title text** → rename `TextField` appears, focused; the
   pane does **not** toggle (no expand/collapse flicker). Type a new name →
   Enter / click-away commits (`onCommit` fires); Escape cancels.
5. **Double-click on empty space** → no rename (correct); toggle is a no-op (two
   toggles). Acceptable.
6. Rename still works via right-click → **Rename** (context menu unchanged).

## 7. Acceptance criteria

- Single click anywhere on the chat title row (text included) toggles the pane.
- Double-click on the title text renames; no toggle side-effect / flicker.
- Page and Source headers still toggle on row click and rename on double-click.
- No console warnings about gesture conflicts; `make build` and `make test`
  (full suite) pass.

## 8. Gotchas / risks

- **Modifier order matters.** The `count: 1` recognizer must be added **after**
  `count: 2` on the same `Text`. If added before, the single tap can fire on the
  first click of a double-click and cancel the rename. Verify live (check 4).
- **`onTapGesture` convenience form vs `TapGesture().onEnded`.** Prefer the
  convenience `.onTapGesture(count:)` so SwiftUI applies its built-in tap-count
  disambiguation; mixing `.highPriorityGesture`/`.simultaneousGesture` here
  defeats the disambiguation. Do **not** wrap the toggle in
  `highPriorityGesture` (breaks rename) or `simultaneousGesture` (flicker).
- **`contentShape` scope is unchanged.** Keep `EditableTitle`'s
  `.contentShape(Rectangle())` on the `Text` (lines 54) so the count:1/count:2
  hit area is the glyph bounds (this is what makes a long chat title's whole text
  toggle). Do **not** move the `contentShape` outside the `.frame` or the hit
  area would shrink to nothing.
- **Editing branch is unaffected.** While `isEditing`, the `TextField` consumes
  taps for focus; `onSingleTap`/`onTapGesture` are only on the display `Text`.
  Confirm commit-on-blur and Escape-cancel still behave (checks 4).
- **Multi-window / per-view state.** `isExpanded` is per-detail-view `@State`
  (see header doc comment); the fix only adds a call path to the same toggle, so
  each window's collapse state stays independent. No new shared state.
- **Source header latent case.** `SourceDetailView` uses `titleLineLimit: 2` and
  `isTitleDisabled` when edit-locked; the fix applies uniformly — single-click on
  a long single-line source name now toggles too, and double-click renames when
  not locked. Confirm during validation.
- **Live-only.** Do not add a unit test asserting the toggle fires on text click
  — gesture recognition needs a real host/window. If an automated guard is later
  wanted, use the hosted-`NSWindow` + `NSHostingController` pattern from the
  `reproducing-live-ui-bugs` skill (drive the real view, simulate NSEvents), not
  a pure view-init test.

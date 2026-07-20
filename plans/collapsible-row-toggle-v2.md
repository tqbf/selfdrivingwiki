# Collapsible Row Toggle — Plan v2 (single-click + full-row + hover)

> Supersedes `collapsible-double-click.md` (v1, double-click — **obsolete**).
> Pivot: double-click is dropped. Single-click toggles, full row is the hit area,
> a hover "bubble" gives the click affordance, and the **chat title-pane toggle
> bug is fixed.** Per operator steer, the fix lives in the **shared
> `CollapsibleDetailHeader`** (behind all three title panes), not per call site.

Target: macOS 15 / Swift 6.0. Repo stays pristine (no commits). Build via
`make build` / `make test`. No `print` (DebugLog). No bare `try?`.

---

## 1. Goal

1. **Single-click toggles** every SwiftUI collapsible title-pane section (Page /
   Chat / Source). Double-click toggle is removed entirely.
2. **Full-row hit area** — clicking anywhere on the row (title text, chevron, or
   the empty space around them) toggles.
3. **Hover "bubble"** — a subtle rounded-rect row background on mouse-over, as a
   click affordance, matching macOS idioms and working in light + dark mode.
4. **Fix the chat title-pane bug** — clicking the chat title row (incl. empty
   space) must toggle expand/collapse; today it does not.

All four are delivered primarily by editing the shared `CollapsibleDetailHeader`
once (fixes + unifies Page / Chat / Source together), plus a reusable hover
modifier. Provenance + settings disclosures are separate per-site decisions.

---

## 2. Chat title-pane bug — ROOT CAUSE + FIX

### 2.1 The chat detail view + its header
- File: `Sources/WikiFS/Chats/ChatView.swift`.
- Header builder: `private func header(for chat: ChatSummary)` — `CollapsibleDetailHeader`
  instance at **lines 540–553**, binding `isExpanded: $isHeaderExpanded`
  (state declared `ChatView.swift:44`). A trailing closure renders the date
  `Text` (expanded content).
- The chat action toolbar (`chatActionBar`) is a **sibling** of the header inside
  `header(for:)`'s own `VStack` (lines 539–560), gated on `isHeaderExpanded`. It
  sits *below* the title row and does **not** overlap it — it is not the
  interceptor.

### 2.2 Why only the text responds (root cause)

This is a **gesture-competition + reachable-empty-space** problem, not a
container-interception problem. Two competing `count: 2` tap gestures coexist on
the same row:

| Gesture | Where | Count | Action |
|---|---|---|---|
| Row toggle | `CollapsibleDetailHeader.titleRow` — `.onTapGesture(count: 2)` (`CollapsibleDetailHeader.swift:74`) | **2** | toggle expand/collapse |
| Rename | `EditableTitle` `Text` — `.onTapGesture(count: 2) { begin() }` (`EditableTitle.swift:55`) | **2** | enter rename mode |

Because both are `count: 2` and the rename gesture sits on a **child** (the title
text), SwiftUI resolves a double-click *on the text* to the child → **rename**.
The row toggle is therefore reachable **only by double-clicking empty space to
the right of the title** (the area covered by `titleRow.contentShape(Rectangle())`
at `CollapsibleDetailHeader.swift:73`, added in #696).

Now the chat-specific failure:

- Chat titles are rendered **`titleLineLimit: 1`** (`ChatView.swift:544`) and are
  typically long (question summaries / auto-titles). A long, single-line title's
  text extends across most or all of the row.
- `EditableTitle` applies `.contentShape(Rectangle())` to its `Text`
  (`EditableTitle.swift:54`) **before** its outer `.frame(maxWidth: .infinity)`
  (`EditableTitle.swift:66`) — so the text's hit area tracks the **title glyph
  width**, which for a long chat title consumes the row.
- The whole header is capped at `readableContentWidth` (**760pt**,
  `PageEditorMetrics.readableContentWidth`) at every call site (Page
  `PageDetailView.swift:167`, Chat `ChatView.swift:554`, Source
  `SourceDetailView.swift:747`) — applied to the `CollapsibleDetailHeader`
  itself, identically in all three.
- Net: on chat there is **no reachable empty space** within the 760pt row (the
  title fills it), and the area beyond 760pt is outside the header (dead). So a
  double-click lands on the title → rename, or on dead space → nothing. **Only
  the text responds.** The page *appears* to work only because page titles are
  short enough to leave reachable empty space within the capped row.

> Note: `SourceDetailView` has the **identical** structure (`SourceDetailView.swift:505–748`)
> and very likely has the **same latent bug**; the shared-component fix covers it.

### 2.3 The fix (single-click pivot)

Switching the row toggle from `count: 2` to a **single tap** (count: 1) — on the
full-row `contentShape` — makes a single click toggle **regardless of whether
there is empty space and regardless of title length**, because a single tap is
recognized by the row's count:1 gesture and does not depend on the empty space
the old double-click-on-empty-space design relied on. `EditableTitle`'s rename
stays on `count: 2`, so an **actual** double-click of the text still renames;
single-click anywhere toggles.

Implemented **once in `CollapsibleDetailHeader`** (the shared header behind Page /
Chat / Source), this fixes the chat title pane and unifies all three.

> ⚠️ **Validate live (per `reproducing-live-ui-bugs`):** gesture/hit-test
> behavior is not unit-testable. The #1 validation item is whether a single click
> **on the title text** toggles given `EditableTitle`'s child `count: 2`. If
> SwiftUI does not let the parent count:1 fire over the child's count:2 region,
> use `.simultaneousGesture(TapGesture().onEnded { … })` on the row instead of
> `.onTapGesture` (see §4 + Gotchas).

---

## 3. Design — ONE shared mechanism (in `CollapsibleDetailHeader`)

### 3.1 Title pane gesture: single-click, full row
In `CollapsibleDetailHeader.titleRow`:

- **Keep** `.frame(maxWidth: .infinity, alignment: .leading)` (`:72`) and
  `.contentShape(Rectangle())` (`:73`) — these give the full-row hit area
  (added by #696; must be preserved).
- **Change** `.onTapGesture(count: 2) { … }` (`:74`) → `.onTapGesture { … }`
  (single tap). Keep the `withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }`
  body. Update the `DebugLog.tabs(...)` message from "header double-tapped" →
  "header tapped".
- **Add** the hover modifier (§3.3) to the same `titleRow`.

### 3.2 Chevron Button — keep (recommendation)
Keep the chevron `Button` (`:44–57`). It is **complementary, not redundant**:
- It is the strongest macOS "this is collapsible" affordance (matches Finder /
  Settings disclosure triangles) and carries `.help`.
- As a real `Button` it consumes its own tap, so clicking the chevron toggles
  exactly once and does not double-fire the row gesture.
- It remains useful even after the whole row becomes single-click (discoverability
  for users who don't yet know the row is clickable).

### 3.3 Hover "bubble" — reusable modifier (macOS idiom)
New file `Sources/WikiFS/Editor/HoverRowBackground.swift`:

```swift
import SwiftUI

/// Subtle rounded-rect row background shown on hover, as a click affordance.
/// Uses `Color.primary` so the tint adapts to light/dark automatically
/// (darkens in light mode, lightens in dark mode) — no manual appearance branch.
struct HoverRowBackground: ViewModifier {
    var cornerRadius: CGFloat = 6
    var opacity: Double = 0.07
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? opacity : 0))
            )
            .onHover { isHovered = $0 }
            // swiftui-pro: always animate against an explicit value.
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

extension View {
    /// Hover-driven subtle row highlight. Apply to the full row (after its
    /// `.contentShape`/frame) so the bubble spans the whole hit area.
    func hoverRowBackground(cornerRadius: CGFloat = 6, opacity: Double = 0.07) -> some View {
        modifier(HoverRowBackground(cornerRadius: cornerRadius, opacity: opacity))
    }
}
```

Rationale (skills):
- **macOS idiom:** a quiet hover wash (not a fill or border) is the native
  "this row is live" cue. `Color.primary` + low opacity adapts to both
  appearances without a hard-coded color (swiftui-pro `design.md`: prefer system
  hierarchical/adaptive values over manual opacity / fixed colors).
- `RoundedRectangle(cornerRadius:style: .continuous)` — default continuous style
  (swiftui-pro: no need to state it, but explicit here for clarity).
- `.animation(_:value:)` form only — never bare `.animation(_:)` (swiftui-pro).

Apply in `CollapsibleDetailHeader.titleRow`, after `.contentShape`/`.onTapGesture`,
so the bubble sits behind content and spans the whole hit area.

---

## 4. Per-site before → after

### A. Title panes (Page / Chat / Source) — via the shared component ✅ primary
All three use `CollapsibleDetailHeader`; **editing it once changes all three.**

| Site | File:lines | Before | After |
|---|---|---|---|
| Shared header | `Editor/CollapsibleDetailHeader.swift:42–80` | `onTapGesture(count: 2)` toggle; no hover | `.onTapGesture` (single) toggle; `.hoverRowBackground()` on titleRow; chevron kept; log msg updated |
| Page call site | `Pages/PageDetailView.swift:61–167` | uses shared header (double-click) | **no change required** — inherits single-click + hover |
| Chat call site | `Chats/ChatView.swift:540–554` | uses shared header (double-click); **BUG: empty space unreachable** | **no change required for the bug fix** — inherits single-click + hover. (See §6 optional widening.) |
| Source call site | `Sources/SourceDetailView.swift:505–747` | uses shared header (double-click); latent same bug | **no change required** — inherits single-click + hover |

> **Chat bug fix is delivered by the shared-component change** (single-click
> works without empty space). No chat container/gesture adjustment is needed —
> the chat's outer container (`header(for:)` VStack + `chatActionBar` sibling)
> was verified clean (no overlay, no hit interception).

### B. Provenance — native `DisclosureGroup` (per-site decision) ⚠️ optional / lower priority
Site: `Pages/PageDetailView.swift:418–438` — stock `DisclosureGroup(isExpanded:
$isProvenanceExpanded)` with a `Label` label. It already single-click-toggles on
its label natively; the gap is **full-row hit area + hover**.

**Recommended (minimal): keep native `DisclosureGroup`, extend the label's hit
area + add hover.** Wrap the label content in a full-width layout and apply the
hover modifier:

```swift
DisclosureGroup(isExpanded: $isProvenanceExpanded) {
    ProvenancePanel(...)
} label: {
    HStack {
        Label("Provenance", systemImage: "clock.arrow.circlepath")
            .font(.callout)
            .foregroundStyle(.secondary)
        Spacer(minLength: 0)          // extend to full row width
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())        // make the whole row hit-testable
    .hoverRowBackground()             // shared hover affordance
}
```

Justification: keeps `DisclosureGroup`'s semantics/accessibility/VoiceOver and
its `.task(id:)` lazy-load gating (`:431`); only adds the row hit area + hover.
**Fallback** if the native label's tap region doesn't extend across the
`Spacer` (validate live): reskin provenance to the title-pane-style custom
header. Prefer the minimal approach first.

### C. Settings disclosures (per-site decision) ⚠️ low value
- `Settings/AddProviderSheet.swift:207`, `Settings/AgentsSettingsView.swift:751`
  — stock `DisclosureGroup`s inside `Form`. These already single-click-toggle on
  their labels natively and live in a `Form` (which manages row backgrounds).
- **Recommendation: leave as-is** unless product wants the hover bubble there
  too. Form rows already get system hover/selection styling; a custom bubble
  would fight it. Out of scope for this change.

---

## 5. Files to modify

| File | Change | Priority |
|---|---|---|
| `Sources/WikiFS/Editor/HoverRowBackground.swift` | **NEW** — reusable hover modifier | required |
| `Sources/WikiFS/Editor/CollapsibleDetailHeader.swift` | `count:2`→single tap (`:74`); add `.hoverRowBackground()` to titleRow; update DebugLog msg; keep chevron + contentShape + frame | required |
| `Sources/WikiFS/Pages/PageDetailView.swift` | provenance label full-row + hover (`:418–438`) | optional (per-site) |
| `Settings/AddProviderSheet.swift`, `Settings/AgentsSettingsView.swift` | (leave as-is) | out of scope |

No change required at the Page / Chat / Source call sites for the bug fix.

---

## 6. Optional: widen the title row past 760pt
All three title panes cap the header at `readableContentWidth` (760pt). With
single-click toggle, "click anywhere on the row" is satisfied *within* the 760pt
column — the bug is fixed without touching the cap. If product later wants the
clickable/hover row to span the **full window width** (not just the readable
column), move the `.frame(maxWidth: readableContentWidth)` from the
`CollapsibleDetailHeader` onto its **expanded-content closure** at each call site
(so the title row spans the parent while expanded content stays readable). This
is a layout-preference follow-up, **not** part of the bug fix, and would need to
keep the chat's full-width `chatActionBar` sibling layout (#693) intact.

---

## 7. Testing plan

### Pure logic (Swift Testing)
No new pure logic is introduced (toggle is local `@State`; hover is a modifier).
`EditableTitle.committedValue` rename logic is already tested. **No new unit
test warranted** — add one only if a testable helper is extracted.

### Manual gesture / hit-test validation (per `reproducing-live-ui-bugs`)
Gesture/hit-test behavior is **not** unit-testable — validate by running the app
and clicking. Checklist to exercise on **each** of Page / Chat / Source:

1. **Single-click on the title text** → section toggles. *(Highest priority —
   confirms count:1 wins over EditableTitle's child count:2; if it does NOT
   toggle, switch the row to `.simultaneousGesture` — see Gotchas.)*
2. Single-click on empty space within the row → toggles.
3. Single-click on a **long** chat title (fills the row) → toggles (the original
   bug).
4. **Double-click on the title text** → still enters rename (`EditableTitle`
   unaffected). Note whether it *also* toggles on the first tap (decide if
   acceptable — see Gotchas).
5. Chevron button click → toggles exactly once; row gesture does not double-fire.
6. Hover over the row → subtle rounded-rect background appears; disappears on
   leave. Check in **light mode AND dark mode**.
7. Rename text field still focuses / commits / cancels (Escape) correctly.
8. Expanded content (date / actions / provenance) still shows/hides animated.

### Build
- `make build` (also regenerates prompts/version).
- `make test` (full suite ~1.5 min) — ensure no regressions.

---

## 8. Acceptance criteria

- [ ] Single-click anywhere on the **chat** title-pane row (including the title
      text and long titles) toggles expand/collapse.
- [ ] **Clicking empty space on the chat title pane toggles it** (original bug).
- [ ] Single-click anywhere on the **page** title-pane row toggles.
- [ ] Single-click anywhere on the **source** title-pane row toggles.
- [ ] Double-click on a title still enters **rename** mode (`EditableTitle`
      behavior preserved).
- [ ] Chevron button still toggles on all three panes (single fire).
- [ ] Hovering any title row shows a subtle rounded-rect background in **light
      and dark** mode.
- [ ] No `count: 2` toggle gesture remains in `CollapsibleDetailHeader`.
- [ ] `make build` passes; `make test` passes.
- [ ] (If done) Provenance row: single-click on full row toggles + hover shows.

---

## 9. Review Strategy

- **swiftui-pro** review of `CollapsibleDetailHeader` + `HoverRowBackground`:
  gesture usage (count, `.simultaneousGesture` if needed), `.animation(_:value:)`
  form, `contentShape` ordering after `.frame`, `foregroundStyle`/`Color.primary`
  adaptive styling, no deprecated API, view-struct extraction (the modifier is a
  `ViewModifier` in its own file — compliant).
- **macos-design** check on the hover affordance: quiet wash, not a fill/border;
  consistent with native row hover; light/dark parity.
- **Concurrency:** none — the toggle is pure local `@State`; no store / main-actor
  / `Sendable` boundary touched. Keep existing `DebugLog.tabs` lines (update text
  only); no new `print`, no bare `try?`.

---

## 10. Gotchas

1. **Gesture disambiguation (count:1 row vs count:2 rename).** A single click on
   the title text must toggle. If SwiftUI keeps the child `count: 2` from letting
   the parent `count: 1` fire over the text, use
   `.simultaneousGesture(TapGesture().onEnded { toggle })` on the row instead of
   `.onTapGesture`. **Validate live first** (testing item #1).
2. **Double-click may toggle-then-rename.** A double-click on the text can fire
   the row's count:1 on the first tap (toggle) *and* `EditableTitle`'s count:2
   (rename). If that double-effect is undesirable, exclude the title-text region
   from the row toggle (e.g. apply the row gesture to the empty-space area only,
   or accept it — single-click is the primary path). Product decision; validate.
3. **Modifier order in `titleRow`.** `.frame(maxWidth: .infinity, …)` (72) →
   `.contentShape(Rectangle())` (73) → tap → `.hoverRowBackground()`. Keep the
   frame *before* contentShape (so the hit area is full width). The hover
   background goes last (behind content, spanning the hit area).
4. **Hover background must not steal focus** from the rename `TextField`. The
   background is a `.background(...)` fill (non-interactive) and `.onHover` does
   not consume taps, so editing is unaffected — but verify the field still
   focuses on click while hovered.
5. **Chat `chatActionBar` sibling layout (#693).** It is a sibling below the
   header, not overlapping; the component change does not touch it. If §6
   (widen row) is ever done, preserve the action bar's full-width `Spacer` layout.
6. **`SourceDetailView` shares the bug** (identical structure). The shared fix
   covers it — but include Source in manual validation, not just Chat.
7. **No call-site edit needed for the bug.** Resist editing `ChatView`'s frame;
   the cap is identical across all three panes and is not the cause. Only touch
   call sites for §6 (optional widening) or provenance (per-site).

---

## 11. Overlap / sequencing with in-flight work

- **Paseo worktree — "new page opens with title pane expanded":** touches
  `PageDetailView` (`isHeaderExpanded` default/init) and `CollapsibleDetailHeader`.
  This plan edits `CollapsibleDetailHeader.titleRow`'s **gesture + hover** and
  `PageDetailView`'s **provenance** label — **disjoint symbols** from
  `isHeaderExpanded`. Shared files: `CollapsibleDetailHeader.swift`,
  `PageDetailView.swift`. Rebase direction is flexible (no symbol overlap).
- **`![[embed]]` feature:** adds HTML `<details>` collapsibles via the WebView
  (`Chats/ChatWebView.swift`). **Out of scope** — different rendering tech; no
  SwiftUI collision with this plan.

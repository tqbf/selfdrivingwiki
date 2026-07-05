# SwiftUI Rules

Hard-won rules from building Moves and other SwiftUI apps. Each rule is
**imperative** ("do this", "never that") followed by the failure mode
that taught us. Skim the imperatives; read the failure modes when
something inexplicable breaks.

Apply these up front when building a new view. Use them as a checklist
when reviewing or hardening existing code.

> **A meta-rule.** SwiftUI's compile-time guarantees are weaker than they
> look. Tests catch logic; they miss layout, constraint, animation, and
> hosting bugs. **A passing test suite is not a passing app.** Every
> non-trivial view change needs a live run on the lowest-spec macOS
> version you support.

---

## 1. Animation & transitions — the silent constraint-engine crashes

### 1.1 Never insert/remove a view with a transition inside hosted SwiftUI.

```swift
// BAD — `_postWindowNeedsUpdateConstraintsUnlessPostingDisabled` crash
if isVisible {
    SomeView()
        .transition(.move(edge: .trailing).combined(with: .opacity))
}

// GOOD — always-mounted, dimension-animated
SomeView()
    .frame(width: isVisible ? targetWidth : 0)
    .clipped()
    .accessibilityHidden(!isVisible)
```

**Why.** When a SwiftUI view is hosted inside an
`_NSConstraintBasedLayoutHostingView` chain — which happens whenever a
`Window` scene is nested in `NavigationSplitView`, or whenever a sheet
or popover hosts a Swift­UI tree — the constraint engine processes
layout in passes. A transition that **inserts or removes a view**
inside an active pass calls `setNeedsUpdateConstraints` from inside the
update, which `NSWindow` guards with an
`NSInternalInconsistencyException`. The pattern works on some Macs and
not others. The constraint engine's strictness varies by hardware and
OS minor version; you cannot rely on "it works on my machine."

**The fix is always the same.** Keep the view in the tree permanently;
animate a *dimension* (width, height, opacity) instead of the view's
*presence*. Use `.clipped()` to hide content while collapsed.

### 1.2 `withAnimation { stateBool.toggle() }` is fine — as long as the resulting view tree change is dimensional, not structural.

If the state change flips `if visible {...}`, you're back to rule 1.1.
If it flips `.frame(width: visible ? W : 0)`, you're safe.

### 1.3 Scope `TimelineView` to the smallest leaf that actually needs it.

```swift
// BAD — every tick redraws the whole row
TimelineView(.periodic(from: .now, by: 1)) { ctx in
    HStack {
        Image(...)
        Text(elapsedFor(ctx.date))
        Spacer()
        ContextMenu(...)
    }
}

// GOOD — only the digits redraw
HStack {
    Image(...)
    TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
        Text(elapsedFor(ctx.date))
    }
    Spacer()
    ContextMenu(...)
}
```

**Why.** Every tick re-evaluates the body of whatever's inside the
TimelineView. Pulling it tight keeps redraws cheap. Same lesson applies
to `Timer.publish` and `onReceive`.

### 1.4 For "next event at X" displays, prefer `TimelineView(.periodic(from: .now, by: 60))` over Timer.

It auto-pauses when the view is off-screen and runs on the right
scheduler. Use 60s ticks for clock-time displays; 1s for elapsed
counters; never sub-second unless you have a real reason.

---

## 2. Layout — frames, priorities, and the row-width wars

### 2.1 Don't combine `.frame(maxWidth: .infinity)` with `.layoutPriority(N)`.

The pair has surprising semantics: priority N requests *ideal* size
first, and `maxWidth: .infinity` makes "ideal" effectively infinite.
Siblings end up with 0pt. If you need a row that gives the title space
first, use one of:

- A trailing `Spacer(minLength: ...)` so the title sizes to content.
- A `maxWidth` cap on the *other* sibling (e.g. the chip).
- Both, paired explicitly.

### 2.2 `.fixedSize(horizontal: true, vertical: false)` makes a view INflexible — it claims its ideal width regardless of context.

Use it deliberately for things that should never compress (a numeric
counter, a fixed-width chip). Don't sprinkle it on text that *could*
truncate — it'll overflow the row when the parent shrinks.

### 2.3 Every `Text` in a row needs `.lineLimit(1).truncationMode(.tail)`.

Without `.lineLimit`, Text wraps to multiple lines. Without
`.truncationMode`, the leading-truncation default surprises users
("…long thread title" instead of "long thread tit…"). On narrow rows,
this is the difference between "fits with ellipsis" and "wraps and
makes the capsule background a tall vertical pill that eats sibling
space" — see the moves UI glow-up batch 6 for the live example.

### 2.4 Centralize layout metrics in a single `enum` of static constants.

```swift
enum PaneMetrics {
    static let horizontalInset: CGFloat = 24
    static let topInset: CGFloat = 16
    static let rowMinHeight: CGFloat = 60
    static let secondaryText = Color.primary.opacity(0.72)
}
```

Don't sprinkle magic numbers across files. When you find yourself
typing `12` for the fifth time, it's a metric. When alignment drifts
between panes because of an off-by-2 in one file, this is why.

### 2.5 Prefer `Spacer` to push, over `frame(maxWidth: .infinity, alignment: ...)` to grow.

Pushing is local and predictable. Growing-with-alignment composes
weirdly with priority and parent proposals. When in doubt, use a
Spacer.

---

## 3. State, observation, and frozen snapshots

### 3.1 If a cache embeds a snapshot of an `@Observable` object, mutating the source does NOT update the cache. Rebuild it explicitly.

```swift
// Domain
struct AvailableThread {
    var thread: Thread   // ← frozen snapshot!
    var move: ResolvedMove
}

// Store
private(set) var availableThreads: [AvailableThread] = []  // cache

func setVisibility(_ thread: Thread, to v: ThreadVisibility) {
    threads[idx].visibility = v        // ← mutates the source
    persist(threads[idx])
    Task { await rebuildAvailable() }  // ← REQUIRED, or the cache lies
}
```

**Why.** `@Observable` propagates "this property changed" through the
direct observation graph. It does *not* chase down embedded copies in
other observable properties. Caches built from a snapshot must be
explicitly invalidated.

The bug that taught us: marking a thread "de-emphasize during work" in
Moves only worked for the first thread the user changed — every
subsequent change looked like a no-op until something else
incidentally rebuilt the cache (capture, start, etc.). The fix was one
line: rebuild after every setter.

### 3.2 Don't build "smart" caches that try to incrementally patch themselves.

A rebuild from source is correct by construction. An incremental patch
that has to mirror every setter's side effects will eventually skip one.

### 3.3 `@SceneStorage` defaults only apply on first scene initialization.

Flipping a default from `true` to `false` does **not** migrate existing
users. Their cached value sticks. If you're changing the default for a
visibility/UX reason, add a migration step that writes the new value
into the storage explicitly. Better: bind the value to a per-window
state that's deliberately ephemeral, or to user-preferences with a
versioned migration path.

### 3.4 `@Observable` makes `Equatable`/`Hashable` work weirdly with reference identity.

If you put an `@Observable` class in a SwiftUI `id:` or `ForEach`
binding, identify by an immutable property (UUID), never by the
instance itself. Don't rely on `==` to mean "value-equal."

### 3.5 Read state at the latest possible moment.

Don't capture `store.preferences` into a `let` at view init and then
save it 600ms later — a concurrent change clobbers it on save. Read
fresh at the click handler, mutate, write. This is the "stale-snapshot
autosave" lesson from Moves' Phase-5 gate.

### 3.6 `NSViewRepresentable` / `NSViewControllerRepresentable` that read `@Observable` model state must receive that data as an explicit parameter from the parent view's body — never read it only inside `updateNSView` / `updateNSViewController`.

```swift
// BAD — observation gap: the parent never accesses bookmarkNodes,
// so SwiftUI never re-renders, so updateNSViewController is never
// called when bookmarks change. The outline silently goes stale.
struct BookmarksOutlineView: NSViewControllerRepresentable {
    let store: WikiStoreModel          // ← passed but not observed
    func updateNSViewController(_ vc: ...) {
        let nodes = store.bookmarkNodes // ← read here, but this method
        // isn't called unless the parent re-renders!
    }
}
// Parent: BookmarksContainerView.body passes `store` but never reads
// store.bookmarkNodes → no @Observable tracking → no re-render.

// GOOD — data passed through the parent's body establishes tracking
struct BookmarksOutlineView: NSViewControllerRepresentable {
    let store: WikiStoreModel
    let nodes: [BookmarkNode]          // ← explicit data parameter
    func updateNSViewController(_ vc: ...) {
        let needs = vc.needsReload(nodes: nodes) // ← uses the parameter
    }
}
// Parent: BookmarksContainerView.body reads store.bookmarkNodes to
// build the nodes parameter → @Observable tracking established →
// re-renders when bookmarkNodes changes → updateNSViewController fires.
```

**Why.** SwiftUI's `@Observable` tracking registers dependencies only
for properties accessed *during a view's `body` evaluation*. An
`NSViewControllerRepresentable` has no `body` — its
`updateNSViewController` is called only when the *parent* SwiftUI view
re-renders. If the parent passes the model object but never reads the
specific property in its body, no tracking is registered, and the
representable silently stops receiving updates. The data is correct in
the database; the UI just never refreshes.

**The fix is always the same.** Pass the observable data as an explicit
`let` parameter from the parent's body. This forces the parent to
access the property during body evaluation, establishing the tracking.
The bug that taught us: the omnibox "Add Bookmark" "+" created a
bookmark in SQLite, but the `BookmarksOutlineView` never refreshed
because `BookmarksContainerView` passed `store` without reading
`store.bookmarkNodes` in its body.

---

## 4. Lists, scrolling, and rows

### 4.1 `.swipeActions(...)` only works inside `List`/`Form`. Use `.contextMenu(...)` as the fallback for cards in a `ScrollView`.

Build with both up front; users discover one or the other, and the
overlap is fine.

### 4.2 `.listStyle(.inset) + .scrollContentBackground(.hidden)` is the modern macOS list look.

Default `List` styling looks like a ported Qt dashboard. The pair above
matches Mail / Reminders / Notes. Pick one and apply everywhere.

### 4.3 For row content, always `.listRowSeparator(.hidden) + .listRowInsets(EdgeInsets(...))`.

The system separator is too heavy for productivity apps; cards or
spacing carry the visual rhythm better. Use insets to give rows the
breathing room the system default doesn't.

### 4.4 Don't fork row code per pane.

Build one `Row` view parameterized by data:

```swift
struct TaskRow<HoverActions: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var deadline: Date?
    var isSelected: Bool = false
    @ViewBuilder var hoverActions: () -> HoverActions
    @ViewBuilder var trailing: () -> Trailing
    // ...
}
```

Generic-with-EmptyView-default-overloads keeps the call shape simple
at the call site. The eye moves between panes without retraining.

### 4.5 Hover-revealed action icons: opacity-fade, never insert-on-hover.

```swift
hoverActions()
    .opacity(isHovered ? 1 : 0)
    .allowsHitTesting(isHovered)
    .animation(.easeOut(duration: 0.12), value: isHovered)
```

Inserting on hover reflows row width as the cursor crosses the
boundary — feels broken. Opacity-fade keeps the row stable.

### 4.6 On macOS, use `.onHover { isHovered = $0 }`. Not `.hoverEffect()` (iOS).

`.hoverEffect()` is a no-op on macOS. Build your own background tint
priority (selected > next > hovered > clear) with a `RoundedRectangle`
behind the row content.

---

## 5. Text, typography, and dates

### 5.1 Use semantic font styles, not hardcoded sizes.

```swift
// BAD — fights Dynamic Type and OS metric updates
.font(.system(size: 11, weight: .medium))

// GOOD — respects Dynamic Type, matches platform conventions
.font(.caption)
.fontWeight(.medium)
```

If a control supplies its own typography (`Button` style,
`Toggle(.button)`, `LabeledContent`), don't override — you'll fight
the system metric.

### 5.2 Cache DateFormatters as `static let`.

```swift
private static let relativeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    return f
}()
```

Building a DateFormatter in `body` allocates one per render. On a
TimelineView-driven row, that's 60+ allocations per minute per row.

### 5.3 For row subtitles, sanitize the source string.

Strip trailing `.`, `…`, or whitespace runs at the data layer.
Combining a `.truncationMode(.tail)` with a string that already ends in
`...` gives you `...` *and* `…` in the same row. The bug looks like a
SwiftUI rendering glitch but is actually a data-layer hygiene issue.

### 5.4 Reuse one chip vocabulary across surfaces.

When the same concept (a deadline, a status) renders in three views,
build *one* component. The capture overlay's parsed-deadline chip and
the task row's deadline chip and the Current card's deadline chip
should be the same SwiftUI struct, parameterized only by the data.
Future urgency or accessibility changes then land once.

### 5.5 Compute time-pressure state at the leaf, not the call site.

```swift
struct DeadlineChip: View {
    let dueAt: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            // derive .overdue / .dueToday / .dueFuture from (dueAt, ctx.date)
            // and tint accordingly
        }
    }
}
```

Callers pass the raw `Date`. The chip self-ticks and flips its tint at
the right moment. Every consumer benefits without a "should I make
this view tick?" decision at every call site.

---

## 6. Settings, windows, toolbars

### 6.1 Prefer `@Environment(\.openSettings)` over `SettingsLink` in nested containers.

`SettingsLink` brings its own NSHostingView shim that triggers
constraint invalidation when nested inside `safeAreaInset`, `List`
inset, or other hosted contexts on macOS 14.x. Plain `Button { openSettings() }`
reaches the same `Settings { }` scene without the hazard.

**Tradeoff.** `openSettings()` can't pre-select a tab; `SettingsLink`
can. If pre-selection matters, host `SettingsLink` at the
`NavigationSplitView` root or in a toolbar, not inside a `safeAreaInset`.

### 6.2 In `ToolbarItemGroup(placement: .primaryAction)`, don't lead with `Spacer()`.

The placement already trails items. A leading Spacer is redundant
*and* confuses the toolbar's intrinsic-content-size computation — on
macOS 14.4 we observed a launch crash from this. Just list the items.

### 6.3 Toolbar items reading observable state — keep the read shallow.

A toolbar item that reads `store.someComputedProperty` re-evaluates on
every redraw. Either keep the property cheap (cached), or push it
through a small dedicated `View` so SwiftUI's dependency tracking
scopes the redraw.

### 6.4 For programmatic Settings open, the macOS-14 idiom is `@Environment(\.openSettings)`.

For earlier macOS versions, you'd send `Selector("showSettingsWindow:")`
to nil — but that selector only works for AppKit-defined Settings,
not SwiftUI's `Settings { }` scene. Always use `openSettings()` on
macOS 14+.

### 6.5 Window scenes don't auto-dismiss when state goes away.

If you open a sheet/window via `pendingFlow != nil`, the window scene
might be restored by SwiftUI later (cold launch) without the flag set
— at which point your "context not found" branch leaves a ghost
window. Make the host self-dismiss when its expected state is absent.

---

## 7. Empty states, hover, selection — the resting-state polish

### 7.1 Every selectable destination needs a designed empty state.

`ContentUnavailableView(title, systemImage:, description:) { actionButton }`
is the macOS-native idiom. One systemImage + one obvious action. Don't
ship blank canvas.

### 7.2 Background tint priority on a row should be explicit.

```swift
private var backgroundStyle: AnyShapeStyle {
    if isSelected { return AnyShapeStyle(.accent.opacity(0.12)) }
    if isNext     { return AnyShapeStyle(.accent.opacity(0.06)) }
    if isHovered  { return AnyShapeStyle(Color.gray.opacity(0.08)) }
    return AnyShapeStyle(Color.clear)
}
```

The order is the priority. Document it in a comment. The "next" hint
and the "selected" highlight should be visually distinct — same hue,
different intensity, so the user reads "this is what I should do"
versus "this is what I clicked."

### 7.3 Keyboard focus ring is handled by AppKit. Don't suppress it.

Don't call `.focusEffectDisabled()` unless you have a real reason. The
default focus ring on a focused row IS the correct affordance for
keyboard users.

### 7.4 Right-click context menus on every actionable row.

macOS users expect them. Build the menu items wired to the same
AppStore methods the buttons use. Skip items whose target method
doesn't exist — never stub a menu item to do nothing.

---

## 8. Capture / live parsing / live preview

These rules apply to any UI that shows a live-parsed preview of user
input (capture palettes, search bars with structured query parsing,
form fields with date detection).

### 8.1 Never present a parse result as read-only.

Users need an escape hatch. Make the chip clickable (opens an
editor) and clearable (X button removes it). Natural-language parsing
fails too often to be a one-way door.

### 8.2 Surface confidence visually.

If your parser can return a `lowConfidence: Bool` flag, propagate it
to the UI. Tint the chip yellow (instead of orange/red) and swap the
icon to a question mark. A low-confidence chip says "I think this is
what you meant — verify before saving."

### 8.3 Strip the matched phrase from the title preview.

If the parser matched "tomorrow at 3pm" out of the input "test API
tomorrow at 3pm", the preview title should read "test API". Showing
the raw input alongside the chip is confusing — the user sees both
"tomorrow" and the chip and wonders if it'll save the literal word.

### 8.4 Tooltip the chip with the absolute date.

Relative dates ("Tomorrow at 3:00 PM") are scannable but ambiguous
across timezones / week boundaries. `.help(absoluteFormatter.string(from: date))`
gives the user a verification path without cluttering the chip.

### 8.5 Gate dependent UI on the parse outcome.

If your overlay shows alert-offset chips only when a deadline was
parsed, gate them on `if dueAt != nil`. Don't render them always and
make the user wonder why their selection is being ignored.

### 8.6 Surface Esc and Return explicitly.

The standard macOS chord for "dismiss" is Esc, for "commit" is Return.
Render small keycap glyphs in the overlay footer ("esc to dismiss") so
new users see the affordance. Don't rely on muscle memory.

---

## 9. Testing strategy

### 9.1 The compile gate is necessary but not sufficient.

`swift build` proves your code parses. `swift test` proves your model
logic works. Neither proves the app launches, lays out correctly, or
survives a `make clean`. **Add a "launch + 30-second alive check" to
the gate.** Run the resulting `.app`, dismiss the window, do one user
action, confirm the process is still alive. Most constraint crashes
fire within the first display cycle.

### 9.2 Test on the lowest-spec macOS version you support.

Constraint-engine strictness varies. A SwiftUI pattern that works on
macOS 15 may throw on 14.4 (we hit this). If your floor is 14, build a
14 machine into your gate — VM, CI runner, or a colleague's older Mac
they're willing to lend.

### 9.3 Visual gates beat unit tests for layout.

If you changed a row's anatomy, a chip's tint policy, or a pane's
empty state, the gate is a screenshot. Don't try to express it as a
unit test — SwiftUI snapshot tests are brittle and the cost-to-value
ratio rarely pencils out.

### 9.4 Write a regression test for every fix, even the obvious ones.

The "frozen snapshot" bug in Moves was a one-line fix
(`Task { await rebuildAvailable() }`). The regression test that locks
it in is 15 lines of "insert 3 threads, mutate visibility on each,
read back the cached snapshot." Worth every line — next refactor
might forget the rebuild.

### 9.5 When a crash report names a private AppKit symbol, your guess is provisional.

`_postWindowNeedsUpdateConstraintsUnlessPostingDisabled` doesn't tell
you which view caused it. Reason from the stack pattern (recursive
`_informContainerThatSubviewsNeedUpdateConstraints` is "view modified
during update"), enumerate the suspects in your recent diff, fix the
most-likely one, ship, and ask the reporter to retest. Two-shot fixes
are normal for these.

---

## 10. Process

### 10.1 Keep a running log.

Whatever you call it — `PROGRESS.md`, `CHANGELOG.md`, a dated
journal — append every meaningful change with what you did, what you
learned, and what surprised you. Future-you reads this when the next
bug looks familiar. Future-them reads this when you're not around.

### 10.2 Keep a "things that bit us" file.

A separate `PROBLEMS.md` (or equivalent) for hard-won pattern lessons:
the SwiftUI constraint pattern, the bundle-loading workaround, the
date-parser gotcha. One entry per pattern; resist the temptation to
fold them into commits where they get lost.

### 10.3 Commit messages should explain the *why*, not the *what*.

The diff shows what changed. The reader (six months from now) needs
the failure mode that motivated the change, the alternatives
considered, and the constraints that pushed you toward this answer.

### 10.4 Small, themed batches beat one giant PR.

Eight focused commits ("trust bugs", "row anatomy", "current card",
"command overlay", …) read clearer than one 4000-line diff. Each
batch fits in one reviewer's head and rolls back cleanly if a
specific theme breaks.

### 10.5 Live-gate before pushing.

After every batch lands locally, run the app and click the surface
you touched. The compile gate misses the bugs that matter most in
SwiftUI; the live gate catches them before the commit hits remote.

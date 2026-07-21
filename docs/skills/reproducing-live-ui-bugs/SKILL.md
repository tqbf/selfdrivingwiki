---
description: Steps for debugging a live UI bug that passes all unit tests but fails in the running app, when you cannot see the screen. Also covers SwiftUI runtime issues that only Xcode displays — "Modifying state during view update", purple runtime warnings, Hang Risk — including how to capture them from the CLI via `log stream` and bisect a view body to find the real source.
---

# Debugging a live UI bug that passes tests

A playbook for the hardest class of bug: a feature is **green in every unit and
integration test, but broken when a human actually uses the running app** — and
you have no screen / computer-use access to watch it happen.

## The mental model: leaves vs. wiring

Unit tests prove the **leaves** work: pure functions, the store API, the emitted
JS string. A live-only failure is almost always in the **wiring** between leaves
— SwiftUI view lifecycle, view re-creation losing `@State`, delegate/timing
ordering, or the **real data** differing from test fixtures. You can't construct
an `NSViewRepresentable.Context` in a unit test, so most of the wiring is
unreachable by a direct test. The job is to narrow *which* layer, without ever
seeing the live UI.

> If leaves test green but live is red, attack the wiring.

## Procedure (in order)

### 1. Get ground truth from the REAL data — never assume content

The most common false lead: test fixtures that don't match production data. Read
the actual store before theorizing.

```sh
# Wiki stores are SQLite, one per wiki, named <ULID>.sqlite in the App Group container:
ls ~/Library/Group\ Containers/group.*/  *.sqlite
sqlite3 "<db>" ".tables"
sqlite3 "<db>" "SELECT id, filename FROM sources WHERE filename LIKE '%…%';"
# For a "text isn't found / not highlighted" bug, grep the real row for the exact
# phrase and LOOK at how it's stored — e.g. part of the phrase wrapped in a
# markdown link or bold, so it spans several DOM text nodes after render.
sqlite3 "<db>" "SELECT content FROM source_markdown_versions WHERE file_id='…';" | grep -n -i "the phrase"
```

That single fact (the phrase spans an inline element) can be the whole root cause.

### 2. Build a hosted integration test that renders the REAL view

Direct unit tests can't reach the SwiftUI lifecycle. Render the actual view in a
real `NSWindow` via `NSHostingController` and drive the **same public seam** the
live click uses (e.g. `store.selectSource(byDisplayName:anchor:)` — not a private
coordinator method). This is the only way to exercise
`.task` / `updateNSView` / `didFinish` / view re-creation.

```swift
@MainActor struct FooWebViewTests {
    // A SwiftUI/WKWebView view in `swift test` has no host app, so the view + JS
    // never run. Create the app once so WebKit + the run loop exist.
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @Test func hostedLifecycleDrivesTheRealSeam() async throws {
        let store = WikiStoreModel(store: try SQLiteWikiStore(databaseURL: /*tmp*/))
        // seed real data; then call the REAL navigation seam the click uses:
        store.selectSource(byDisplayName: "Paper", anchor: "\"the quote\"")
        let view = WikiReaderView(markdown: markdown, currentSelection: store.selection, store: store)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil); defer { window.orderOut(nil) }
        let webView = try await waitForWebView(in: window)   // walk the view tree
        // …assert on the live DOM / state…
    }
}
```

**If the hosted test passes but live still fails**, the bug is purely in the
click→seam wiring or view re-creation → go to step 3.

### 3. Instrument EVERY seam of the trigger flow — via `os_log`, never `print`

Add a temporary `DebugLog.<category>(...)` call at each step so the operator can
reproduce and you can read the trace back. Minimally log: the click handler, the
routing classifier, the store mutation that sets pending state (+ the version it
bumps), the consume (who consumes, with what selection, whether it matched /
cleared), the view `.task`, and the final apply gate with all its inputs
(`pageLoaded`, the pending value, the version counters).

- **Always route through `os_log`** (`DebugLog`), never `print`. `print` only
  shows with stdout captured (Terminal/Xcode); `os_log` lands in Console.app and
  is readable after the fact no matter how the app was launched.
- One `subsystem` + per-concern `category`; log values `.public` so they aren't
  redacted as `<private>`.
- `#expect` can't host `try await` — assign the async result to a `let` first,
  then assert.

### 4. Operator reproduces; you read the trace

```sh
log show --predicate 'subsystem == "com.selfdrivingwiki.debug" AND category == "<cat>"' \
         --last 5m --style compact
```

Read the ordered trace and answer: did the click route? was the pending state
set (+ version bumped)? who consumed it, and did that consumer **clear** it? did
the state reach the coordinator / apply site — or did a *different instance*
swallow it? did the apply gate fire or short-circuit?

### 5. Fix the layer the trace implicates

Two wiring failures this playbook has actually surfaced:

- **View re-creation losing `@State`.** The `.task` sets state on instance A, but
  `apply` runs on instance B (a fresh coordinator) that sees `nil`; the `.task`
  fires twice (once with the value, once `nil`). Fix by preventing the
  re-creation, or by moving the pending state onto the long-lived coordinator
  keyed on the store's monotonic version (a fresh coordinator re-derives it), and
  clearing only after a confirmed apply.
- **Cross-node text.** A highlighted/quoted phrase spans an inline element
  (link/bold), so it lives in several text nodes; a single-text-node search (or
  flaky `window.find`) misses it → no match, no scroll. Search the whole document
  with a `TreeWalker` index map and wrap each intersecting text segment.

## WKWebView-in-test gotchas

- **No host app → JS/view never run.** Create `NSApplication.shared` in the test.
- **`evaluateJavaScript` results:** prefer the completion-handler form and coerce
  to `String?` **inside** the completion before resuming the continuation — only
  the `String?` (Sendable) crosses, which dodges Swift 6 "sending risks data
  race" on the `Any?`. The async `evaluateJavaScript(_:in:in:)` overload can
  return `nil` for everything in a headless context.
- Numbers come back as `NSNumber`; if your helper only casts to `String`, return
  `String(...)` from the JS.
- Assert after polling — `apply`-style calls are fire-and-forget
  `evaluateJavaScript`, so the effect lands asynchronously.

## SwiftUI runtime issues ("Modifying state during view update")

A separate invisible-failure class: SwiftUI emits **runtime issues**, not compile
warnings. They appear in **no build log**, and `swift test` does not display
them — a clean build plus a green CLI test run is *not* evidence they're absent.
Xcode shows them; everything else looks fine.

**Capture them from the CLI.** They are `os_log` faults to a system subsystem:

```sh
/usr/bin/log stream --predicate \
  'subsystem == "com.apple.runtime-issues" and category == "SwiftUI"' \
  --style compact
```

Run that alongside the tests (start the stream, `sleep 2`, run, `sleep 3`, kill)
and count `Modifying state`. That turns an Xcode-only symptom into a scriptable
pass/fail you can bisect against. Drop the `category` clause to also see
`Hang Risk` (priority inversions) and other categories.

**Choose the runner deliberately.** `swift test` mounts hosted views *without a
window server*, so some suites never lay out and stay silent; `xcodebuild`
renders for real and exposes strictly more. One real case: xcodebuild surfaced 8
occurrences where `swift test` showed 2. **Verify UI fixes under xcodebuild.**

**Distrust the reported location.** The warning names whichever view body was
mid-evaluation when the graph committed — *not* the code that wrote the state.
A real case pointed at `PageDetailView.editorContent`; the write was in
`WikiReaderView`, a different file two layers down, and `PageDetailView` needed
no change at all. Treat the location as a starting point, never a conclusion.

**Bisect the body — don't theorize.** With the capture loop above as the oracle:

1. Establish a baseline count on the smallest failing test (aim for a sub-second
   incremental run).
2. Wrap subtrees of the suspect `body` in `if false { … }`, re-run, re-count.
3. Narrow until the count drops to 0; the last subtree removed owns the write.
4. Read the representable that subtree mounts, and check its Coordinator for
   `@State`/`@Binding` writes reachable from `makeNSView`/`updateNSView`.
5. `diff` the file against a backup afterwards to prove the scaffolding is gone.

Watch for a branch rendering that you didn't expect: state seeded in `.onAppear`
means the *other* branch renders on first paint, so a view can warn from code the
test looks like it never exercises. That detail is usually what makes the counts
across tests look inexplicable.

The underlying invariant, and the defer/suppress fix patterns, are in AGENTS.md
("Never write SwiftUI state synchronously from an `NSViewRepresentable`…").

## Anti-patterns to avoid

- Theorizing about content without reading the real DB row.
- String-assertion tests for JS/HTML that "looks right" — they can't catch logic
  that emits correct text but doesn't actually take effect. **Execute** it in a
  real `WKWebView`.
- Rendering the leaf view directly when the bug is in the wrapping container —
  host the **real** container so the lifecycle is exercised.
- `print`-based logging that vanishes when the app isn't launched from a
  terminal.
- Treating "the build is clean" or "`swift test` passed" as proof a SwiftUI
  runtime issue is fixed — neither runner reports them. Re-measure with the
  `log stream` capture above, under `xcodebuild`, and show the count going to 0.
- Trusting the file/method the runtime issue names without confirming a state
  write actually lives there.

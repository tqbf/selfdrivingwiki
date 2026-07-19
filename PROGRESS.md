# Progress log

Newest first. To get up to speed: read `PLAN.md` then this file.

## 2026-07-19 — Issue #680: wiki-link autocomplete in the page/source editor (branch `editor-autocomplete`)

**Problem:** When editing a page or source in markdown edit mode, the user
could drag-drop a sidebar item to insert a canonical wikilink (#616, #623)
but had no fuzzy-completion path while typing `[[page:Erl…` directly into the
editor. The chat composer had just shipped fuzzy autocomplete (#436, #638,
#650) and #684 generalized the panel's `present()` API to take a caret rect +
placement (`Placement.above` / `.below` / `.auto`) — explicitly in preparation
for editor reuse. #680 wires that reuse.

**Solution:** Extract the chat composer's autocomplete pipeline into a
reusable controller, then host the controller in `ScrollableTextEditor` (the
NSTextView-backed editor for both `PageDetailView` and `SourceDetailView`).

- `Sources/WikiFS/Editor/WikiLinkAutocompleteController.swift` (new, ~500
  lines) — `@MainActor final class` owning the dropdown panel, the debounced
  Tantivy fetch, the local ↑/↓/Escape `NSEvent` monitor, and the
  canonical-link insertion. Takes (hooksProvider, debounceProvider,
  scheduleDebounceProvider, placement, widthProvider) closures so the host
  (`ComposerTextView.Coordinator` for chat, `ScrollableTextEditor.Coordinator`
  for the editor) supplies the AppKit-specific bits and a placement
  preference (chat → `.above`, editor → `.below`). The chat composer's
  `AutocompleteHooks` is now a `typealias` to the new top-level
  `WikiLinkAutocompleteHooks` so the existing tests compile unchanged; same
  for `DebounceHandle` → `WikiLinkAutocompleteDebounceHandle`. Includes two
  pure kind-mapping helpers (`tantivyKind(for:)`,
  `parsedLinkType(from:)`) named to avoid colliding with the existing
  `SidebarDropBuilder.linkType(for: SidebarDragPayload.Kind)` overload (both
  enums share `.page` / `.source` / `.chat` cases, so a call like `linkType(for:
  .source)` would be ambiguous if both overloads existed under the same name).
  Also includes a `textBinding: (@MainActor (String) -> Void)?` hook the host
  sets so the canonical inserted form syncs to the SwiftUI `@Binding`
  synchronously (don't wait for the next `textDidChange` notification).
- `Sources/WikiFS/Editor/ComposerTextView.swift` — the chat composer's
  `Coordinator` deleted ~270 lines of inlined autocomplete state and
  pipeline code, replaced with `autocompleteController: WikiLinkAutocompleteController?`
  built lazily from the parent's hooks in `ensureAutocompleteController()`.
  `textDidChange` and `textView(_:doCommandBy:)` delegate to the controller.
  Behavior is unchanged (chat composer tests pass without modification). The
  composer-specific `ComposerTextView.keyAction(for:modifiers:autocompleteOpen:)`
  static helper and `.send`/`.insertAutocomplete`/`.insertNewline`/`.unhandled`
  enum all stay on `ComposerTextView` — the composer needs the `.send`
  branch (plain Return → send message) that the editor doesn't.
- `Sources/WikiFS/Editor/ScrollableTextEditor.swift` — added the
  `autocomplete: WikiLinkAutocompleteHooks?`, `autocompletePlacement:
  ChatAutocompletePanel.Placement = .below`, `autocompleteDebounce: UInt64`,
  `autocompleteScheduleDebounce: ((...) -> WikiLinkAutocompleteDebounceHandle)?`
  parameters and a new `dismantleNSView` that calls
  `coordinator.teardownAutocomplete()` (mirrors the chat composer's teardown
  so a stale SwiftUI hosting view can't leak). The coordinator's
  `textDidChange` routes to the controller; `textView(_:doCommandBy:)` is
  new and consumes plain Return when the dropdown is open (otherwise falls
  through — the editor doesn't have a `.send` path).
- `Sources/WikiFS/Editor/SidebarDropBuilder.swift` — new
  `wikiLinkAutocompleteHooks(store: WikiStoreModel) -> WikiLinkAutocompleteHooks?`
  factory that builds the fetch + format closures from `store.tantivySearch`
  (mirrors `ChatView.chatAutocompleteHooks` at
  `Sources/WikiFS/Chats/ChatView.swift:736`). Same Tantivy fuzzy
  `search.autocomplete(partial:kinds:distance:2,limit:8)` query path and
  same `DroppedLinkFormatter.link(...)` canonical-form builder. Returns `nil`
  when no Tantivy service is attached (wiki closed) — the editor behaves
  exactly as before autocomplete was added.
- `Sources/WikiFS/Pages/PageDetailView.swift` — passes the autocomplete
  hooks from `store` into `ScrollableTextEditor` in `editorContent`.
- `Sources/WikiFS/Sources/SourceDetailView.swift` — same wiring in
  `markdownContent`.

**Panel reuse (#684):** The chat composer's `ChatAutocompletePanel` already
had (a) `enum Placement { case above, below, auto }`, (b)
`present(caretRect:in:placement:...)` — caret-rect + placement-aware, (c)
`static caretRect(in: NSTextView) -> NSRect?` mapped from the live layoutManager
to screen coordinates, (d) the pure `origin(caretRect:panelSize:windowFrame:placement:...)`
helper. #680 reuses all four via the new controller — no panel changes were
required. The chat composer keeps `.above` (composer lives at the bottom of the
chat window); the editor uses `.below` (a tall NSTextView mid-window has more
room below the caret than above). `ChatAutocompletePanelPlacementTests` (8
tests, from #684) already cover the placement math for both directions.

**Tests:** `Tests/WikiFSTests/EditorAutocompleteHostedTests.swift` (new, 12
tests) mirrors `ComposerAutocompleteHostedTests`: trigger detection, debounce
+ cancel stale in-flight partials, no-trigger / closed brackets / newline /
overlong-paste guards, source/chat kind routing, nil hooks (no wiki), and
editor-specific `shouldConsumeReturn` cases (editor doesn't have `.send` —
plain Return with dropdown closed falls through to insert a newline;
Shift/Option/Cmd + Return never consume; plain Return with dropdown open
commits the selected row and replaces the trigger span with the canonical
`[[page:ULID|Title]]` form). The existing chat composer's 8 hosted tests +
4 `ChatAutocompleteSelectionTests` + 8 `ChatAutocompletePanelPlacementTests`
+ `TantivyAutocompleteTests` all pass unchanged — the controller extraction is
behavior-preserving for the chat path.

**Build/Tests:** `make version prompts` ✓; `swift build` ✓; full `swift
test` ✓ — **3043 tests / 259 suites pass**, no regressions (was 3033; +10
net new tests in the new editor suite — the 2 non-controller tests in the
new file were ported from parallel chat-suite ones).

**Status:** PR open (branch `editor-autocomplete`), not merged. Closes #680.

## 2026-07-19 — Issue #670: Embed mermaid diagrams inline in pages (branch `diagram-embeds`)

**Problem.** A wiki page that wanted to inline a Mermaid diagram from a `.mmd`
source (`![[source:flow.mmd]]`) fell through to a cite link — the existing
embed pipeline only knew how to render byteful media blobs (image / audio /
video / PDF) and byteless external media (provider iframes / direct-remote /
Apple Podcasts). Diagram sources (`.mmd` / `text/mermaid`) are byteful but
none of those kinds, so they rendered as nothing useful.

**Fix.** Add a fourth `EmbedTarget.Kind` — `.diagram` — that carries the raw
Mermaid source text in a new `content: String?` field on `EmbedTarget`. The
page renderer emits `<div class='mermaid'>ESCAPED_CONTENT</div>`, and the
already-bundled `mermaid.min.js` (v11) renders it inline as SVG — no
per-embed JS, no new vendored library.

**Resolution chain (3 layers, one PR):**

1. **`EmbedTarget` (`Sources/WikiFSTypes/EmbedTarget.swift`)** — `Kind` gains
   `case diagram`; `EmbedTarget` gains `public let content: String?` (nil for
   the three media kinds, the diagram source text for `.diagram`). `init`
   defaults `content` to nil so existing call sites stay clean.

2. **`WikiRenderContext.build(from:)` (`Sources/WikiFSCore/Core/WikiRenderContext.swift`)**
   — the per-source embed-map loop now tries the Mermaid resolution path
   first, before the byteless-external descriptor path. Uses
   `MermaidSourceDetector.isMermaidSource(mimeType:filename:content:nil)`
   (the cheap mime + filename arms — no content scan, since reading every
   source's bytes during render-context build would be wasteful) and, when
   true, reads `store.sourceBytes(id:)` and decodes UTF-8. The result:
   `EmbedTarget(kind: .diagram, url: source.id.rawValue, content: text)`.
   Falls through to the descriptor path on non-mermaid sources or on
   un-decodable bytes (no half-rendered empty div).
   - **Why `WikiRenderContext` and not `ExternalEmbed`:** `ExternalEmbed`
     operates on `SourceEmbedDescriptor`, which the `embedDescriptors()`
     query filters to byteless sources only (`WHERE sv.blob_hash IS NULL`).
     A `.mmd` source is byteful, so it never reaches `ExternalEmbed`.
     The render-context loop iterates all `store.sources` and is the right
     seam for byteful-as-embed (matches how MediaEmbedPlayerView reads
     source bytes via the same store handle).

3. **`WikiLinkMarkdown.embedHTML` (`Sources/WikiFSLinks/WikiLinkMarkdown.swift`)**
   — the switch on `target.kind` gains `case .diagram`, emitting
   `<div class="mermaid">ESCAPED_CONTENT</div>`. Content is HTML-escaped via
   the existing `embedEscape` helper (the same set used for alt text:
   `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`) so the parser
   can't misread a `<` inside a Mermaid label as the start of a tag. The
   reader's existing `mermaidBootstrapJS` reads `div.textContent` (which
   un-escapes back to the raw diagram source) before rendering — that's
   the same mechanism the ` ```mermaid ` code-block path uses, so the
   reader doesn't need a new bootstrap.

**Reader change (one line):** `WikiReaderView.documentHTML`'s mermaid-lib
injection condition now triggers on either `class="language-mermaid"` (the
existing ` ```mermaid ` code-block form) OR `class="mermaid"` (the new div
form emitted by `.diagram` embeds). The bootstrap script does
`mermaid.run({ querySelector: '.mermaid' })` regardless of how the div got
there, so the rest is unchanged.

**Scope.**

- `Sources/WikiFSTypes/EmbedTarget.swift` — added `case diagram` to `Kind`
  and `public let content: String?` field; default-nil `init` param for
  backward compat with media-kind constructors.
- `Sources/WikiFSCore/Core/WikiRenderContext.swift` — per-source embed-map
  loop now tries Mermaid resolution first (cheap detection + lazy byte read)
  before falling through to the byteless-external descriptor path.
- `Sources/WikiFSLinks/WikiLinkMarkdown.swift` — `embedHTML` switch gains
  `case .diagram` returning `<div class="mermaid">ESCAPED</div>`; doc on
  `SourceEmbedInfo` updated to mention diagrams.
- `Sources/WikiFS/Reader/WikiReaderView.swift` — lib-injection condition
  extended to also match the div form (one extra `||` clause).
- `Sources/WikiFS/Sources/MediaEmbedPlayerView.swift` — `element(for:)`
  switch gains `case .diagram` returning empty string (defensive — diagrams
  never reach this media-player view; `SourceDetailView` shows no Media tab
  for `.mmd` sources so no embed target is constructed that way).
- `Tests/WikiFSTests/DiagramEmbedTests.swift` — NEW (11 tests):
  - `EmbedTarget.Kind.diagram` + `content` field (#670 §1): existence,
    backward-compat nil default, kind-equality.
  - `WikiRenderContext.build(from:)` (#670 §2): `.mmd` source → `.diagram`
    target carrying the raw text (resolved by filename, ext-stripped, and
    canonical id); `text/mermaid` mime source → same; non-mermaid `.md`
    source → `target == nil` (falls through to blob/cite); un-decodable
    bytes → `target == nil` (no garbled div).
  - `WikiLinkMarkdown.embedHTML` (#670 §3): `.diagram` target →
    `<div class="mermaid">…</div>` containing the (HTML-escaped) source;
    dangerous chars (`<` `>` `&`) escaped; missing target → cite link
    fallback (no half-rendered div); media embeds (iframe / audio / video)
    still render through the same switch now that `.diagram` is a fourth
    arm (#670 non-regression guard).

**Verification.**

- `make version prompts && swift build` — clean, 0 errors / 0 warnings.
- `swift test --filter DiagramEmbedTests` — 11/11 pass (~0.05 s).
- `swift test` (full suite) — **3026 tests / 258 suites pass** (~32 s).
  No regressions.

**Closes #670.** NOT merged — branch `diagram-embeds` left open for review;
PR title: "Embed mermaid diagrams inline in pages (#670)".
## 2026-07-19 — Fix chat autocomplete panel positioning (branch `fix-autocomplete-pos`)

**Problem.** The chat composer's `[[kind:partial` autocomplete dropdown
(`ChatAutocompletePanel`) appeared several lines above the caret instead of
just above the current line. Two compounding bugs in `present(above:)` at
`Sources/WikiFS/Chats/ChatAutocompletePanel.swift:80`:

1. The panel anchored to the **entire NSTextView's bounds**
   (`anchor.convert(anchor.bounds, to: nil)`) rather than the caret line —
   for a 3-line default composer, the anchor's top is 3 lines above the
   caret, so the panel was 3 lines too high before even counting the panel
   gap math.
2. The above-placement math added `frame.height` to the origin Y
   (`rectOnScreen.maxY + frame.height + 4`), leaving a panel-height-plus-4pt
   gap between the anchor's top and the panel's bottom — visually "a panel
   too high". The below-fallback math in the same method matched the omnibox's
   correct below-placement math, so only the above path was wrong.

**Scope.**

- `Sources/WikiFS/Chats/ChatAutocompletePanel.swift` — replaced
  `present(above: NSView)` with caret-relative positioning, generalized so
  the editor autocomplete (#680, not yet implemented) can reuse the same
  panel with different placement heuristics. New API:
  - `enum Placement { case above, below, auto }` — preferred direction.
    `.above` is the chat composer convention (composer is near the bottom
    of the chat window, so below-caret is clipped); `.below` will be the
    editor convention (the editor is tall, more room below the caret);
    `.auto` picks whichever side has more room tie-broken to `.above`.
  - `nonisolated static func origin(caretRect:panelSize:windowFrame:placement:gap:horizontalOffset:)`
    — pure, testable origin computation. No AppKit state access (only
    `NSRect`/`NSPoint`/`NSSize`/`CGFloat` arithmetic on value types). The
    "room above/below" math is measured against the caret rect, not the
    window — so `.auto` is genuinely caret-relative, not window-relative.
  - `func present(caretRect:in:placement:gap:horizontalOffset:)` — instance
    method: computes the origin via the static helper, sets the frame,
    attaches as a child window (`addChildWindow(_:ordered:)`) so it tracks
    window moves, keeps the parent-window attachment idempotent via the
    `parent == nil` guard.
  - `@MainActor static func caretRect(in textView: NSTextView) -> NSRect?`
    — canonical AppKit recipe for the screen-coordinate caret-line rect:
    `ensureLayout(for:)` → `glyphRange(forCharacterRange:length:0)` →
    `lineFragmentRect(forGlyphAt:effectiveRange:)` (gets the line's full
    height, important so "above vs below" measures against the full line,
    not a 0-height point) → `textContainerOrigin` offset →
    `convert(_:to: nil)` → `convertToScreen(_:)`. Handles the empty-document
    case (no glyphs → fall back to `textContainerOrigin`) and the
    end-of-document caret case (`glyphRange.location == glyphCount` →
    clamp to `glyphCount - 1`).
- `Sources/WikiFS/Editor/ComposerTextView.swift` — `Coordinator.presentPanel()`
  now calls `ChatAutocompletePanel.caretRect(in: anchor)` and passes the
  result to `panel.present(caretRect:in:placement:)`. Defensive fallback:
  if `caretRect(in:)` returns nil (no `layoutManager`, `textContainer`, or
  `window` — shouldn't happen in practice but defensive), falls back to the
  text view's bounds converted to screen coordinates; the new positioning
  math is still applied, so the fallback gives the correct "4pt gap above
  the view's top" behavior even without a caret rect. Adds an explicit
  `guard let window` early-return so a `nil` window doesn't try to attach
  the panel (matches the original silent return semantics).
- `Tests/WikiFSTests/ChatAutocompletePanelPlacementTests.swift` — NEW;
  10 pure tests for `ChatAutocompletePanel.origin(...)`, covering `.above`
  / `.below` placement + their no-room fallbacks, `.auto` picking the
  roomier side (with tie → above), default gap (4pt, matches historical),
  custom gap, and horizontal offset.

**Why didn't I write a live-NSWindow integration test for `caretRect(in:)`?**
The existing `ComposerAutocompleteHostedTests` already exercises
`presentPanel()` end-to-end (via `applyResults` → `presentPanel()` →
`caretRect(in:)` → `present(caretRect:in:)`), so the integration path is
covered. A focused test asserting the exact line-fragment rect / screen
coordinate would be brittle under font-dependent line metrics; the pure
`origin(...)` tests cover the policy decisions (above/below/auto/fallback)
exhaustively, which is where the bug was.

**Build/test.** `make version prompts && swift build` clean;
`swift test` — 3021 tests in 258 suites all pass (including the 10 new
`ChatAutocompletePanelPlacementTests`). Run time ~30s.

**No new logs.** No `DebugLog` calls added — the panel's existing
silent-return-on-nil-window convention was preserved, and no error paths
were introduced (the new fallback to view-bounds positioning is a
defensive measure for state that is technically possible but doesn't fire
in practice; `caretRect(in:)` succeeds whenever the composer has a
window, which is `presentPanel()`'s only caller's precondition).

## 2026-07-19 — Issue #669: Replace merval with mermaid.min.js for v11 syntax validation (branch `feature/mermaid-validator-v11`)

**Problem.** `MermaidValidator` validated mermaid blocks via the vendored
`merval.bundle.js`, a third-party validator pinned to an older Mermaid grammar.
It rejected valid Mermaid v11 syntax like `A@{ shape: delay }` (the form the
official v11 docs use), so users couldn't save pages containing v11 diagrams —
even though the reader (upgraded to mermaid v11.16.0 in PR #648) renders them
fine. Classic version skew: one library renders, another validates.

**Fix.** Use the SAME vendored `mermaid.min.js` (v11.16.0) for validation that
the reader uses for rendering. Call `mermaid.parse(text)` in a `JSContext`;
if the returned Promise rejects, the diagram is invalid. Now anything that
renders also validates, and vice versa — no version skew possible.

**Key technical discoveries** (full write-up in `plans/669-mermaid-validator-v11.md`):

1. `mermaid.parse()` ALWAYS returns a Promise and never throws synchronously.
   The validator attaches `.then`/`.catch` to a holder object, then flushes the
   JSC microtask queue before reading the result.
2. Swift's JavaScriptCore overlay does NOT expose `JSPerformMicrotaskCheckpoint()`;
   we `dlsym` it from the system framework. ~1.5–2 ms per validation.
3. mermaid.min.js bundles DOMPurify, whose factory returns `undefined` without a
   DOM → `Zs.addHook is not a function`. A minimal DOM/timer/window polyfill is
   installed BEFORE evaluating the mermaid bundle. The polyfill source is
   documented in `MermaidValidator.domPolyfillJS` and the working scratch test
   `tmp/mermaid-test/test_polyfill.swift`.
4. The CORRECT v11 shape syntax is `A@{ shape: delay }` — NO square brackets.
   The bug report's literal `A[@{ shape: delay }]` (inside brackets) is actually
   INVALID mermaid syntax and is (correctly) rejected. merval rejected both
   forms; mermaid v11.16.0's own parser accepts the correct form.
5. mermaid is more lenient than merval: `flowchart LR\n  A B` is now VALID (the
   existing `MISSING_ARROW` test cases had to change). All genuine syntax errors
   come back with `code: "PARSE_ERROR"` (no more `MISSING_ARROW` etc.).

**Scope.**

- `Sources/WikiFSMarkdown/MermaidValidator.swift` — rewrote the JSContext
  setup: DOM polyfill → mermaid bundle → `mermaid.initialize()` →
  `globalThis.__merval.validateMermaid` wrapper (kept the `__merval` global name
  for call-site stability). `validateSingle` now calls the wrapper, flushes
  microtasks, reads the holder. `loadDefault()` resolves `mermaid.js` (was
  `merval.js`). Public API unchanged — callers in `PageCommand.swift` and
  `WikiStoreModel.swift` untouched.
- `build.sh` — removed the `MERVAL_JS` copy block. The existing `MERMAID_JS`
  block now produces the single `mermaid.js` used for BOTH rendering and
  validation. `Resources/merval.bundle.js` is left in the repo (deferred
  deletion).
- `Tests/WikiFSTests/MermaidValidatorTests.swift` — bundle loader switched to
  `mermaid.min.js`; "invalid" test bodies changed from `A B` to `A[unclosed`
  (mermaid accepts `A B`); `MISSING_ARROW` assertions replaced with
  `PARSE_ERROR`. New tests: `validV11ShapeSyntaxPasses`,
  `validV11ShapeRectPasses`, `invalidBracketAtSyntaxIsCaught`,
  `validV11ShapeSavesEndToEnd`.
- `Tests/WikiFSTests/MermaidEditorWarningTests.swift` — same bundle +
  invalid-body migration as above (was loading merval directly and asserting
  `MISSING_ARROW`).
- `Tests/WikiFSTests/WikiCtlCommandTests.swift` — `repoMermaidValidator()`
  switched to `mermaid.min.js`.
- `plans/669-mermaid-validator-v11.md` — NEW; full investigation + plan.

**Verification.** `swift build` passes; `swift test` passes (all 3046 tests in
260 suites, ~36 s). MermaidValidatorTests: 23/23 pass (including the new v11
cases). Per-validation latency ~2 ms; one-time JSContext + polyfill setup
~50–200 ms (amortized via `MermaidValidator.shared`).

**Open follow-ups.**

- Delete `Resources/merval.bundle.js` once the build is confirmed green in CI
  (deferred per the task spec).
- If a future mermaid bundle adds new DOM dependencies, extend
  `MermaidValidator.domPolyfillJS` (and re-verify via the scratch tests under
  `tmp/mermaid-test/`).
## 2026-07-19 — Issue #674: Double-click to toggle collapsed/expanded headers + chat blocks (branch `feature/double-click-expand`)

**Problem.** Collapsible headers and chat collapsible blocks only toggled
on a single click of the disclosure chevron / `<summary>`. There was no
double-click affordance, so users expecting macOS-typical double-click to
toggle had no shortcut.

**Scope.**

- `Sources/WikiFS/Editor/CollapsibleDetailHeader.swift` — added
  `.onTapGesture(count: 2)` on the `titleRow` HStack that flips `isExpanded`
  with the same `.easeInOut(duration: 0.2)` animation as the chevron
  Button. SwiftUI's gesture arbitrator preserves the chevron Button's
  single-click (its own gesture wins single taps) and EditableTitle's
  rename `onTapGesture(count: 2)` (innermost wins inside the title bounds);
  double-taps on the rest of the header (icon, padding) now toggle. Used
  by `PageDetailView`, `SourceDetailView`, `ChatView` — three sites, one
  fix.
- `Sources/WikiFS/Chats/ChatWebView.swift` — added a `dblclick` listener
  to the `document` in `shellHTML`'s `<script>` that finds the closest
  `<summary>` ancestor and flips its parent `<details>` `open` attribute.
  Covers every `<details>` in the transcript (thinking blocks via
  `.row-thinking.collapsible`, feed tool blocks via
  `.row-tool.collapsible`, chat tool blocks via `.chat-tool`). The
  browser's native single-click toggle continues to fire for each click
  of the pair; the trailing `dblclick` flips `open` once more so a
  double-click nets to a single flip from the starting state.

**No new tests.** Both surfaces are gesture/JS-handler additions to
view-layer code; the project has no SwiftUI gesture test harness and the
JS runs inside `WKWebView` (no JS test infra). `swift test` (~1.5 min)
run cleanly on `feature/double-click-expand`.

## 2026-07-19 — Issue #665: Fetch official ACP registry for provider catalog (branch `feature/acp-registry`)

**Problem.** The provider catalog (`ACPProviderCatalog.agents`) was a
hardcoded 12-entry list maintained by hand. The official ACP agent registry
(38 agents at `cdn.agentclientprotocol.com/registry/v1/latest/registry.json`)
exists and is the canonical source — every agent the protocol tracks should
show up in *Add Provider* automatically.

**Scope.**

- `Resources/acp-registry.json` — NEW; the official registry snapshot
  (47 KB, 38 agents) shipped as a bundled resource so the catalog is
  non-empty even on first launch, offline. The build script copies it to
  `Contents/Resources/acp-registry.json`.
- `Sources/WikiFSCore/Integrations/ACPRegistry.swift` — NEW (~260 lines).
  - `ACPRegistryResponse` / `ACPRegistryAgent` / `ACPRegistryDistribution`
    (`Codable` + `Sendable`). `ACPRegistryDistribution` is a custom-decoded
    enum (`.npx` / `.binary([String:])` / `.uvx`) — the registry tags each
    agent with at most one; decoded by inspecting which key is present
    (forward-compatible if the schema ever adds a second distribution per
    agent).
  - `ACPRegistryClient` — the registry client. `loadAgents()` (async) is
    always best-effort: fresh cache → live fetch → stale cache → bundled
    snapshot → hardcoded `fallbackCatalog`. Never throws, never crashes,
    never blocks the UI. Cache TTL is 24h; fetch timeout is 10s. All errors
    route through `DebugLog.agent`.
  - `mapRegistryToCatalog(_:)` (pure, internal) — the distribution→argv
    mapping:
    - `npx` → `["npx", package] + args`, `detectExecutable = "npx"`.
    - `uvx` → `["uvx", package] + args`, `detectExecutable = "uvx"`.
    - `binary (darwin-aarch64)` → strips leading `./` from `cmd`,
      `command = [cmd] + args`; falls back to `darwin-x86_64` (Rosetta).
    - Skips entries whose distribution is nil or has no darwin platform.
- `Sources/WikiFSCore/Integrations/ACPProviderCatalog.swift` — the public
  surface changes:
  - `agents` (static let, 12 hardcoded entries) → renamed
    `fallbackCatalog` (still 12; used as the last-resort floor).
  - `agents` (NEW computed var) — sync accessor: bundled snapshot →
    `fallbackCatalog`. (In `swift test`, where `Bundle.main` is the test
    runner — no bundled resource — returns `fallbackCatalog` so the existing
    `catalogHasExpandedEntries` / `defaultCatalogIsNonEmptyAndClaudeAcpPresent`
    assertions still hold. In the .app, returns the official 38-agent
    snapshot.)
  - `loadAgents()` (NEW async) — fresh cache → fetch → stale cache →
    bundled snapshot → `fallbackCatalog`. Delegates to
    `ACPRegistryClient.loadAgents()`.
- `Sources/WikiFS/Settings/AddProviderSheet.swift` — the sheet's model now
  owns `catalogAgents: [KnownACPAgent]` (initialized to the bundled snapshot
  via `ACPProviderCatalog.agents`, refreshed from the live registry by the
  sheet's `.task`). The footer count reads `catalogAgents.count`; on a
  successful refresh the sheet reflows from 12 → 38 rows without further
  code changes. First paint is the bundled snapshot (no network fetch on
  the critical path of UI rendering).
- `build.sh` — copies `Resources/acp-registry.json` to
  `Contents/Resources/acp-registry.json` (a plain JSON resource; sealed by
  the outer .app codesign — no separate signing step, matches `merval.js`).
- `.github/workflows/ci.yml` + `Makefile` `FAST_TEST_SKIP` — appended
  `ACPRegistryTests/loadAgentsReturnsNonEmpty` to the fast-tier skip regex
  (it's tagged `.integration` AND has a 2-min time limit because it can hit
  the network — the rest of `ACPRegistryTest` is pure + bundled-snapshot,
  fast).
- `Tests/WikiFSTests/ACPRegistryTests.swift` — NEW (~230 lines, 17 tests).
  Pins:
  - Codable round-trip for each distribution variant (npx / binary / uvx /
    nil).
  - Mapping invariants per distribution (command / detect / convention).
  - Bundled snapshot decodes and maps to ≥30 agents (the floor — the
    live count is 38 at the time of #665).
  - Skip rules: nil distribution + binary with no darwin platform → entry
    absent from the mapped catalog.
  - `ACPProviderCatalog.agents` returns `fallbackCatalog` in `swift test`
    (no bundled resource in the test runner).
  - `ACPProviderCatalog.loadAgents()` (integration-tagged) → non-empty +
    contains `claude-acp` + invariant preserved across the whole cache →
    fetch → fallback chain.

**Behavior change for users.** `claude-acp` in the *Add Provider* catalog
moves from `bunx @agentclientprotocol/claude-agent-acp` (the old hardcoded
entry, still in `fallbackCatalog`) to `npx @agentclientprotocol/claude-agent-acp`
(per the official registry's `npx` distribution). The default provider
seeded on first run is unaffected — it's still the hardcoded
`AgentProvider.claudeAcpDefault` (which uses `bun`), so existing installs
see no regression; only catalog-driven adds from the refreshed UI use the
npx form. Other 26 new agents appear in *Add Provider* automatically
(amp-acp, codex-acp, cline, devin, factory-droid, qwen-code, …).

**Testing gates.**
- `swift build` — ✓ (34.88s).
- `swift test --filter 'ACPRegistryTests'` — 17/17 passed (loadAgents round
  trip 0.224s; the rest are pure decode/map).
- `swift test --filter 'ACPProviderDiscoveryTests|AddProviderSheetTests|AgentProviderCatalogTests'`
  — 19/19 passed (the existing catalog/discovery tests, no regressions).
- `swift test` (full, no skip) — 3042/3042 in 33s. ✓

**Closes #665**. NOT merged — branch `feature/acp-registry` left open for
review; tagged `Closes #665` in the PR body so a merge closes the issue.

---

## 2026-07-19 — Issue #663: Generic Custom ACP provider + UI redesign (branch `feature/generic-custom-acp`)

**Problem.** Settings → Agents vended provider creation via three hardcoded
seed buttons (`Add Claude` / `Add Hermes` / `Add OpenCode`) plus a `Custom…`
path that pre-persisted a blank row BEFORE the editor opened (Cancel left
junk in `agent-providers.json`). The runtime layer
(`AgentBackendFactory.makeBackend`) was already fully generic — the only
provider-specific code was in the seeds, the Add buttons, and the
default-fallback logic. So the change was smaller than it appeared.

**Scope (per `tmp/sdw-plans/663-combined-plan.md` + plan-reviewer
corrections):**

### Part 1 — Code removal (statics gone)

- `Sources/WikiFSCore/Core/AgentProvider.swift` — DELETED
  `.hermesDefault` and `.opencodeDefault` statics (~30 lines). KEPT
  `.claudeAcpDefault` as the `selectedProvider()` last-resort fallback
  (defensive safety net for a hand-edited/corrupt config). The
  `acp(from:)` factory is unchanged (the catalog-driven `AddProviderSheet`
  uses it).
- `Sources/WikiFSCore/Core/AgentProvidersConfig.swift`:
  - `seed(discovered:)` now returns `[.claudeAcpDefault]` only (was three
    providers). The `"claude-acp": "sonnet"` `selectedModelId` seed stays —
    `SpawnModelGuard` still needs it for day-one spawnability.
  - `normalized([])` re-seeds `[.claudeAcpDefault]` only. The single-default
    invariant and first-enabled-promotion logic are unchanged.
  - The `loadOrSeed` `claude-acp`-default `"sonnet"` backfill is unchanged
    (upgrade-safety for existing installs).

### Part 2 — UI redesign (AddProviderSheet)

New file: `Sources/WikiFS/Settings/AddProviderSheet.swift` (~370 lines):

- `AddProviderSheet` — the non-destructive Add Provider sheet. Replaces the
  hardcoded seed menu with a two-tier picker sourced from
  `ACPProviderCatalog.agents` (11 entries — Claude, Gemini, Hermes,
  Copilot, Kimi, Cursor, Kiro, Goose, Grok, CodeWhale, Kilo) + a live
  `ACPProviderDiscovery.discover()` PATH scan that runs OFF-main on
  `.task`. Nothing persists until an Add button is pressed (AC.2). Custom
  commands route through an inline `DisclosureGroup` at the bottom.
- `AddProviderModel` (`@MainActor @Observable`) — owns the live scan, the
  search filter (case-insensitive over `label`/`summary`), and the
  `needsEditor(for:)` heuristic. The heuristic (correction §4) drops the
  non-existent `catalogEntryRequiresKey` reference: returns `true` when the
  provider's command is empty (custom add) OR the agent wasn't detected
  on PATH (catalog add for a missing binary — the user may want to tweak
  the command/env/key). A cleanly-detected catalog agent skips the editor
  (fast path: 2 clicks total).
- `ProvidersEmptyState` — native macOS 15 `ContentUnavailableView` shown
  when `config.providers.isEmpty` (defensive — `loadOrSeed` guarantees ≥1).
- `ProviderStatusBadges` — small View for the "Default" capsule badge.
- `ModelStatus` enum + `AgentsSettingsView.modelStatus(for:in:)` — the
  structured `selected`/`noSelectionPickable`/`noneCaptured`/`disabled`
  classifier that the restructured `providerRow` reads. Sibling to the
  existing `modelWarning(for:in:)` (correction §6 — both coexist; the
  `AgentsSettingsViewWarningTests` string-format tests stay load-bearing).

### `AgentsSettingsView` wiring

- Deleted the three seed Menu buttons + the `addSeed(_:)` helper + the
  pre-persist tail of `addCustom()`. Replaced with a single
  `Button("Add Provider") { showAddSheet = true }` and a new
  `appendProvider(_:)` that only writes at confirm time.
- Sequential sheet dismiss→present handoff (correction §5): the
  `onAddNeedsEditor` callback sets `showAddSheet = false` then
  `DispatchQueue.main.async { editingProvider = provider }` so the first
  sheet finishes dismissing before the editor presents — works around the
  SwiftUI hazard where the second `.sheet` silently fails when the first
  is mid-dismissal.
- `providerRow` restructured per §3.2: leading `Toggle` (`.switch` +
  `.controlSize(.mini)` + `labelsHidden()`) + `VStack(label, command,
  ModelStatus line)`. Disabled rows `.opacity(0.55)`; switch stays full
  opacity. Middle-truncates the command line so both executable + tail
  flag stay visible.

### `ProviderEditorView` refactor

- Reordered sections: **Command → Model → Advanced (Environment +
  Authentication)**. The old order had Environment between Command and
  Authentication, cluttering the common case.
- `DisclosureGroup("Advanced")` wraps Environment + Authentication.
  Auto-expands on `.onAppear` when the provider already has env vars OR a
  stored API key (so existing config is never hidden). Documented the
  one-frame collapsed→expanded flash as accepted (correction §7 — Low).
- Cancel button gets `.keyboardShortcut(.cancelAction)` (was missing).
- `.ready` model refresh state now shows a compact `Label("N models",
  systemImage: "circle.fill")` caption (was `EmptyView` — the picker's
  count was the only signal, which disappeared when collapsed).

### Tests (5 existing + 2 new suites)

- `AgentLauncherSpawnRefusalTests` — replaced `.opencodeDefault` references
  with inline `AgentProvider(...)` literals (lines 41, 98).
- `AgentProviderModelTests` — updated seed-order assertions from
  `["claude-acp","hermes","opencode"]` to `["claude-acp"]` (5 sites).
  Replaced the `.opencodeDefault` reference at line 234 with an inline
  literal. Renamed `normalizedReseedsAllThreeWhenEmpty` →
  `normalizedReseedsClaudeAcpOnlyWhenEmpty`,
  `emptyProvidersListReseedsAllThreeDefaults` →
  `emptyProvidersListReseedsClaudeAcpOnly`. New
  `hermesOpencodeIDsRoundTripAfterStaticRemoval` pins **AC.3** (existing
  `agent-providers.json` with hermes/opencode IDs decodes + re-encodes).
- `AgentProvidersConfigSeedBackfillTests` — replaced `.opencodeDefault`
  with inline literal at line 79.
- `AgentsSettingsViewWarningTests` — replaced `.opencodeDefault` (×3) and
  `.hermesDefault` (×1) with inline literals.
- `ChatViewPreflightBannerTests` — replaced `.opencodeDefault` at line 212.
- `SpawnModelGuardTests` — updated the inline-fixture comment to reflect
  that only `claudeAcpDefault` is a static seed now.
- NEW `AddProviderSheetTests` (8 tests) — pins AC.2 (cancel = no change at
  the onAdd seam), AC.6 (`seed()`/`normalized([])` → `[claudeAcpDefault]`),
  the `needsEditor` heuristic (custom-empty, detected, non-detected
  branches), `freshCustomID` collision loop, the dedup contract
  (`otherAgents` excludes both `existingIDs` AND `detected`), and the
  query filter.
- NEW `AgentsSettingsViewModelStatusTests` (7 tests) — pins all 4
  `ModelStatus` branches (`disabled`, `selected(name)` with friendly name
  + raw-id fallback, `noneCaptured`, `noSelectionPickable`), the
  empty-string-selection parity with `modelWarning`, and stability across
  providers with the same state.

### Migration / breaking changes

- **No migration needed for existing configs.** `agent-providers.json`
  rows whose `id` happens to be `"hermes"` or `"opencode"` are just
  `AgentProvider` rows — they decode + re-encode losslessly (AC.3).
  Removing the `.hermesDefault`/`.opencodeDefault` statics does NOT remove
  the user's saved rows.
- The `loadOrSeed` `claude-acp`-default `"sonnet"` backfill is unchanged.

**Build/Tests:** `make version prompts` ✓; `swift build` clean ✓; fast tier
**2772 tests / 236 suites pass** (+15 new across `AddProviderSheetTests` +
`AgentsSettingsViewModelStatusTests` + the `hermesOpencodeIDsRoundTripAfterStaticRemoval`
AC.3 test).

**Status:** PR open (feature/generic-custom-acp), not merged. Closes #663.

## 2026-07-18 — Issue #616: drag sidebar items into editor to auto-insert wikilinks (branch `feature/drag-wikilinks`, PR #623)

**Problem:** When editing a page or source in markdown edit mode, the user wanted
to drag a sidebar row (Page/Source/Chat/Bookmark folder) into the editor and
have a canonical wikilink inserted at the drop point — instead of typing
`[[page:Some Title]]` by hand. The sidebar drag-vending side was already
complete (every sidebar list vends a `wikiSidebarItem` pasteboard item); the
editor side needed wiring.

**Solution (v1, in-app sidebar→editor drag only; per `plans/drag-wikilinks.md`):**

- `Sources/WikiFSLinks/DroppedLinkFormatter.swift` — pure, Foundation-only
  mapper (`link(for:id:displayName:)`, `markdownList(for: [Item])`) that
  emits the canonical ULID-pinned `[[kind:<ULID>|<alias>]]` form. The alias
  is cosmetic (Phase 5 display-at-render resolves the ULID regardless of
  alias text), and falls back to the raw ULID when the target is stale
  (`displayName == nil` OR empty). Lives in `WikiFSLinks` (depends only on
  `WikiFSTypes`) so unit tests can hit it without AppKit. Takes
  `ParsedLink.LinkType` (not `SidebarDragPayload.Kind` — that lives in
  `WikiFSCore`) to keep the formatter module-graph-clean; the kind→LinkType
  mapping is a 1:1 switch on the @MainActor builder.
- `Sources/WikiFS/Editor/DropLinkTextView.swift` — `NSTextView` subclass that
  accepts `wikiSidebarItem` drops and inserts the builder's text at the
  visual drop point (`characterIndexForInsertion`). **Load-bearing
  divergence from `WikiReaderView`:** the override registers the sidebar
  type ALONGSIDE the inherited text types (`string`/`RTF`/`filenames`),
  NOT instead of them (the #133/#385 competing-subview concern doesn't
  apply — the editor is a terminal NSTextView with no WKWebView child
  below it). Forcing sidebar-only would have silently broken
  drag-selected-text-to-move within the editor. Falls through to `super`
  for non-sidebar drags so NSTextView's default text-drop behavior is
  preserved.
- `Sources/WikiFS/Editor/SidebarDropBuilder.swift` — `@MainActor` factory
  that closes the loop: resolves display names via
  `WikiStoreModel.resolveAttachmentName`, routes single-vs-multiline, and
  guards on `store.agentRunCount > 0` (Step 4 protection — never silently
  insert into a buffer an agent is about to overwrite).
- `Sources/WikiFS/Editor/ScrollableTextEditor.swift` — new `sidebarDropBuilder`
  field on the `NSViewRepresentable`; `makeConfiguredTextView` now returns a
  `DropLinkTextView` (subclassed); `updateNSView` re-wires the builder on
  every SwiftUI evaluation.
- `Sources/WikiFS/Pages/PageDetailView.swift`,
  `Sources/WikiFS/Sources/SourceDetailView.swift` — pass `sidebarDropBuilder`
  closure to `ScrollableTextEditor` in both edit-mode surfaces.
- `Sources/WikiFSTypes/DebugLog.swift` — new `editor` os_log channel
  (subsystem `com.selfdrivingwiki.debug`) for drop/agent-guard events.

**v1 scope tradeoff:** ships Option B (flat depth-0 list for bookmark folders)
rather than nested indentation (Option A — depth-aware drag payloads). The
`DroppedLinkFormatter.markdownList(for:)` signature already accepts
`(depth, kind, id, displayName)` tuples so the data shape is forward-compatible
with the follow-up PR; v1 passes `depth: 0` for every leaf (the bookmark drag
source's `leafPayloads(under:)` already flattens a folder into a leaf list, so
the drop builder can't recover original tree depth without depth-aware payloads
or a bookmark-tree re-walk — both documented as follow-ups in the plan).

**Tests:** `DroppedLinkFormatterTests` (16 tests — pure-function correctness
for all 4 kinds + nil/empty displayName fallback + multi-depth list formatting
+ empty list + ULID canonicity + tuple-overload parity);
`DroppedLinkRoundTripTests` (11 tests — `WikiLinkParser.parse(_:)` accepts
every formatter output AND `WikiLinkRewriter.canonicalize(...)` is a **no-op**
on every formatter output, proving the drop-inserted link is already canonical
and save won't rewrite it — the idempotency fast-path that makes inserting the
canonical form strictly better than inserting `[[source:Name]]`);
`DropLinkTextViewDropTests` (5 tests — wiring: `makeConfiguredTextView`
returns `DropLinkTextView`; `sidebarDropBuilder` storage + invocation;
`registerForDraggedTypes` registers sidebar ALONGSIDE `.string` — the
divergence regression guard; `linkType(for:)` is the 1:1 inverse of
`BookmarksOutlineView.dragKind`);
`SidebarDropBuilderIntegrationTests` (5 tests, tagged `.integration` — store-side
builder against a real `GRDBWikiStore`: page drop resolves title; multi-payload
produces a flat depth-0 list; stale target falls back to raw ULID alias; empty
payload list rejected). The fast-tier `--skip` regex in
`.github/workflows/ci.yml` was extended to include the integration suite name
(per AGENTS.md convention).

**Status:** PR open (#623), not merged.

## 2026-07-18 — Require explicit model selection before agent spawn (branch `fix/require-explicit-model`)

**Problem:** The 2026-07-18 "Working Hypnotically with Children" ingestion stall
(`tmp/ingestion-stall-diagnosis.md`) had multiple causes; this fix targets one of
them — the OpenCode provider was `isDefault: true` with no entry in
`selectedModelIds`, so the launcher passed `nil` to `providerHints`, and the ACP
subprocess silently fell through to its first-listed upstream —
`opencode/big-pickle`, a free model nobody chose (diagnosis root cause #6, an
amplifier of the stall). The dominant cause — `alwaysAsk` permission prompts
with no timeout — is out of scope here (see Scope Boundaries in
`plan-001.md`) and tracked as a separate follow-up.

**Fix:** Added a pure `SpawnModelGuard.validate(provider:modelId:)` helper
(`Sources/WikiFSEngine/SpawnModelGuard.swift`) that returns an actionable
preflight error when the resolved provider has no `selectedModelId`. Wired into
both spawn paths:
- `AgentLauncher.resolveStageRouting` — covers all three ingest stages
  (planner / executor / finalizer) through one choke-point. Placed AFTER the
  PATH-preflight so the more-fundamental "executable missing" error wins when
  both are wrong.
- `AgentLauncher.startInteractiveQuery` — interactive chat. Placed BEFORE the
  PATH-preflight (missing model is a configuration issue we surface first).

The error message includes the provider's label (actionable) and
"Settings → Agents" (discoverable).

Also added a yellow warning caption to the provider row in `AgentsSettingsView`
(`Sources/WikiFS/Settings/AgentsSettingsView.swift`) when no model is selected,
gated by a pure static `modelWarning(for:in:)` helper. Non-blocking — models are
discovered live on first spawn, so blocking save would break new-provider
onboarding. Disabled providers show no caption (they can't spawn anyway).

**Fresh-install safety:** the shipped `AgentProvidersConfig.seed` now pairs the
`claude-acp` default with `selectedModelIds["claude-acp"] = "sonnet"` so a fresh
install can spawn chat/ingest on day one — without this the guard would create a
hard circularity (you must spawn to discover models, but the guard refuses to
spawn until a model is picked). The `loadOrSeed` backfill mirrors this for
existing `claude-acp`-default installs whose `selectedModelIds` was empty —
upgrade-safety only, does NOT touch non-default providers or an existing
non-empty `claude-acp` entry.

**Behavior change:** All providers now require an explicit model selection
before they will spawn, including `claude-acp` (which historically accepted nil
and defaulted to its first-listed model — effectively Sonnet, now the seeded
default). Existing configs with no `selectedModelIds["<id>"]` entry for the
resolved provider must set one via Agents settings before chat or ingest will
run; the preflight error points the user there.

**Accepted UX wrinkle (tracked for follow-up):** a freshly-added provider (not
the shipped seed) has no cached models until its first successful spawn — but
the guard refuses that first spawn. The yellow caption ("No model captured yet
— chat with this provider once to discover models") is the guidance for this
state; a future dry-run `session/new` on Save would close the loop.

**Tests:** `SpawnModelGuardTests` (pure helper), `AgentsSettingsViewWarningTests`
(pure `modelWarning` helper), `AgentProvidersConfigSeedBackfillTests` (seed +
backfill preserve/non-default), a new `AgentLauncherSpawnRefusalTests`
(chat-path refusal with injected config), and an extension to
`AgentProviderModelTests` (the bug-precondition: nil modelId when no selection).

## 2026-07-18 — Issue #583: per-model usage breakdown in menu bar + Activity window (branch `feature/usage-breakdown-by-model`)

**Problem:** The menu bar's "Today: 76K tokens · $1.23" is a single aggregate. Token pricing/kind varies wildly per model, so the aggregate hides the real signal — a "76K" day could be one Opus run or thirty Sonnet runs.

**Fix:** Track usage per model id + input/output/thought, surface it in two places:
1. **Menu bar** — one disabled, indented, secondary-gray item per model below the summary line, heaviest first, unknown-model bucket last. `runCount > 1` appends " · N runs" so many-small-runs days read clearly.
2. **Activity window per-item detail** — a per-model sub-view (caption, tertiary) when a single run used more than one model. Today most runs have one entry (the launcher merges phases into one `runTotalUsage`), but the structure is ready for phase-level usage events.

**Data flow unchanged:** `ACPBackend.sessionUsage(for:)` → `AgentLauncher.capturePhaseUsage` → `runTotalUsage` → `.usage` queue event → `QueueActivityTracker.handle(.usage)`. The only new bits are an `itemUsageByModel` dict (in-memory, per-item) and a `todayUsageByModel: DailyUsageByModel` (persisted to `UserDefaults` with a daily-reset key, mirroring `DailyUsage`).

**SessionUsage grew a `modelName: String?` field.** Resolved at the `ACPBackend` seam by matching `currentModelId` against `ModelsInfo.availableModels.first(where: modelId match)?.name`. Falls back to `nil` when no list advertised, no entry matches, or the name is empty. Point-in-time (latest non-nil wins on merge), like `modelId`. `UsageFormatter.fullSummary` and the new `itemModelBreakdownLine` prefer `modelName` over `modelId` for display.
## 2026-07-18 — Mermaid diagram tabs: Reader / Rendered / Split (branch `mermaid-source-detail-tabs`)

**Problem:** Mermaid diagram sources (`.mmd` files or markdown containing
```mermaid fenced blocks) rendered like ordinary markdown — a single Reader tab.
A diagram source had no dedicated "rendered SVG" view or side-by-side
source/rendered split, unlike PDFs (Reader/PDF/Split) and media
(Reader/Media/Split, from #586/#590).

**What changed (4 files), rebased onto the post-#590 `main`:**

1. **`MimeType`** (`Sources/WikiFSTypes/MimeType.swift`) — added `text/mermaid` +
   `text/x-mermaid` constants, a `mermaidVariants` set, and `isMermaid(_:)`
   (case-insensitive predicate, `nil` → false). Mirrors the markdown predicates.

2. **`MermaidSourceDetector`** (`Sources/WikiFSCore/Sources/MermaidSourceDetector.swift`,
   new) — pure, unit-tested gate. `isMermaidSource(mimeType:filename:content:)`
   is true when the MIME is a mermaid variant, the filename ends in `.mmd`, or
   the content contains a fenced ```mermaid block (reuses
   `MermaidValidator.mermaidBlocks`, the pure line scanner — no JS).
   `renderableMarkdown(from:)` wraps a standalone `.mmd` source in a ```mermaid
   fence so the reader's render pipeline picks it up, and passes embedded-mermaid
   markdown through unchanged (so headings/outline stay intact).

3. **`SourceDetailView`** (`Sources/WikiFS/Sources/SourceDetailView.swift`),
   adapted to #590's `availableTabs` / `tabLabel` system:
   - Added `.rendered` to `FileContentTab` (rawValue "Rendered"). The existing
     `tabLabel` returns its `rawValue` for non-media tabs, so no label helper
     change was needed.
   - `availableTabs` gains a mermaid branch → `[.reader, .rendered, .split]`,
     placed after the PDF branch so a PDF whose extracted text mentions mermaid
     stays a PDF.
   - `tabbedContent` handles `.rendered`; `splitContent`'s right pane branches
     to `renderedMermaidContent` for mermaid (vs the player/PDF).
   - `renderedMermaidContent` draws the diagram by wrapping the source and
     handing it to the existing `WikiReaderView` (Mermaid 10.9.6 in WKWebView) —
     no separate web view or JS wiring.
   - `markdownContent` now renders a native source's raw bytes via the reader
     when there's no processed-markdown head, so a `.mmd` Reader tab shows its
     source instead of "No Processed Markdown".
   - Edit button sources its buffer from `currentMarkdownContent` (so a native
     `.mmd` edits its raw source) and switches off the `.rendered` tab when
     editing (mirrors the PDF/Media guard).

**Rendering note:** no new WKWebView or Mermaid JS plumbing. The reader already
inlines the vendored Mermaid lib + bootstrap when a page contains a
`language-mermaid` code block; the Rendered tab just feeds it a fenced source.

**Build/Tests:** `make version prompts` ✓; `swift build` clean ✓;
fast tier **2603 tests / 221 suites passed** (+13 new in
`MermaidSourceDetectorTests`).

## 2026-07-18 — Persist queue activity (usage, log/debug paths, progress) across app restart (branch `fix/queue-activity-persistence`)

**Problem:** In the Activity window (Queue / agent view), per-item info about
**ingestion + lint** runs — the usage summary line ("2:32 PM · 1m 3s · Claude ·
797 tokens in · …"), the "Reveal Log"/"Reveal Debug Folder" buttons, and the
extraction progress text — was shown while the app ran but **lost on restart**.
Quit + relaunch and all that activity info vanished.

**Root cause confirmed:** `QueueActivityTracker` (a `@MainActor @Observable`
class) holds ALL per-item activity in in-memory dictionaries
(`itemUsage`, `itemLogURLs`, `itemDebugURLs`, `progressLogs`, `transcripts`)
that are cleared on `stop()` and never rehydrated on launch. The transcripts
were the **partial exception**: write-through already existed
(`QueueEngine.makeEmitTranscript` → `QueueStore.appendItemEvent`) and the
detail view already lazy-loaded them via `engine.loadTranscript(for:)` on
open. But **usage, log/debug URLs, and progress logs were neither written to
the DB nor rehydrated** — so they evaporated with the process. (`todayUsage`
already persisted via UserDefaults; the transient running-state sets
`extractingSourceIDs`/`ingestingSourceIDs`/`lintingItemIDs`/… are correctly
not persisted — they rebuild from live `.started` events after
`resetRunningToQueued()`.)

**Fix:** made the engine write those three streams through to `QueueStore`
as they arrive, and rehydrate them into the tracker at launch.

- **v4 GRDB migration (`v4_add_item_activity`)** — new `queue_item_activity`
  table keyed by `item_id` (FK → `queue_items(id) ON DELETE CASCADE`, so rows
  vanish with their item on `pruneHistory` — mirrors `queue_item_events`):
  `usage_json TEXT`, `log_url TEXT`, `debug_url TEXT`, `progress_log TEXT`,
  `updated_at INTEGER`.
- **Module boundary:** `SessionUsage` lives in `WikiFSEngine`; `QueueStore`
  lives in `WikiFSCore` (which `WikiFSEngine` depends on, not vice-versa). So
  the store stores `usage_json` as an opaque `String` (a new
  `QueueStore.QueueItemActivity` DTO of raw `String?`s); the engine
  encodes/decodes `SessionUsage` ↔ JSON (`SessionUsage` gained `Codable`).
- **Write-through seams (engine emit closures):**
  - `makeEmitUsage` → `upsertItemActivity(usageJSON:)` (final cumulative usage).
  - `makeEmitLogPaths` → `upsertItemActivity(logURL:debugURL:)` (absoluteString).
  - `makeEmitProgress` → `appendItemProgress(line:)` (newline-appended, mirrors
    the tracker's in-memory accumulation).
  - The upsert is COALESCE-partial — each field is set by a different event
    (usage fires once on `.usage`, paths once on `.runPaths`), so updating one
    never clobbers the others.
- **Rehydrate seam:** `QueueActivityTracker.rehydrate(from:)` (called at launch
  in `WikiFSApp` right after `attach`, in a `Task`) calls
  `QueueEngine.loadAllActivitySnapshots()` (which reads
  `store.loadAllActivity()` and decodes usage JSON / reconstructs URLs) and
  repopulates `itemUsage`/`itemLogURLs`/`itemDebugURLs`/`progressLogs`. The
  tracker stays the single owner of observable UI state. Typed **transcripts**
  are deliberately NOT bulk-loaded — the detail view already lazy-loads each
  item's transcript via `engine.loadTranscript(for:)`, avoiding pulling
  `recentLimit × maxTranscriptEvents` events into memory at launch.

**Concurrency:** `rehydrate` is `@MainActor async` — it awaits the engine actor
for the read (returns a `[ID: ActivitySnapshot]` of `Sendable` values), then
mutates MainActor dicts. The emit closures capture `store` (`@unchecked
Sendable`, GRDB-serialized) and write from worker Tasks — the same pattern
`makeEmitTranscript` already used. Errors are `do/catch` → `DebugLog.store`
(no bare `try?`).

**Known limitation (pre-existing, not introduced):** on `retryItem`, old
activity (and old transcript events) are not cleared, so a retried run's
summary/progress can show stale-then-new data. Matches the existing transcript
behavior; clearing on retry is a separate follow-up.

**Tests added:**
- `QueueStoreTests` (+5): activity survives close+reopen; COALESCE preserves
  existing fields; progress appends with newline; activity cascades on prune
  (`maxPerQueue: 0`); `loadAllActivity` returns all rows.
- `QueueActivityTrackerRehydrateTests` (+2): a fresh engine+tracker over the
  SAME `queue.sqlite` rehydrates usage (JSON→`SessionUsage` round-trip),
  log/debug URLs (`absoluteString`→`URL`), and progress; empty DB leaves the
  tracker empty.

**Build/Tests:** `make version prompts` ✓; `swift build` clean (181s); targeted
QueueStore/tracker suites 31/31 pass; fast tier **2603 tests / 222 suites**
pass; full `swift test` **2789 tests / 235 suites pass** (incl. the 13
integration suites — 0 failures).

## 2026-07-18 — Add "Reveal Debug Folder" + "Reveal Log" UI to the Activity window (branch `feature/reveal-debug-folder-ui`)

**Problem:** PR #580 added `DebugRunLogger` (a verbose ACP wire-trace under
`<scratch>/debug/`), and `ChatView` already had "Reveal Log" / "Reveal Debug
Folder" buttons in its activity menu. But the standalone **Activity window**
(`ActivityWindowView`) — where users view ingestion/lint transcripts across all
wikis — had no way to reveal either the lightweight `run.jsonl` log or the
verbose `debug/` folder. The launcher's `logFileURL` / `debugFolderURL` existed
(`public private(set)`) but were only reachable from the chat view's direct
launcher reference; the Activity window works with `QueueItem` objects and the
`QueueActivityTracker`, with no per-item log-path state.

**Fix:** Threaded the run's `logFileURL` + `debugFolderURL` through the queue
event system — mirroring the existing `.usage` / `.liveUsage` event plumbing —
so the tracker stores per-item paths that the Activity window can reveal.

**Data flow:** `AppQueueIngestionProvider` → `onLogPaths` callback →
`QueueIngestionWorker` → `emitLogPaths` (via `LogPathsEmitBox`) →
`QueueEngine.makeEmitLogPaths()` → `.runPaths(QueueItem.ID, logURL:, debugURL:)`
event → `QueueActivityTracker` → `ActivityWindowView`.

**New `QueueEvent.runPaths`** case (Sendable, NOT logged to JSONL — URLs are
runtime-only, not Codable audit data). Added `runPaths` to `QueueEventType`,
`QueueLogRecord.init` (all nil fields), and the `write()` skip list — same
treatment as `.usage`.

**`QueueActivityTracker`** gained `itemLogURLs` / `itemDebugURLs` dictionaries
+ `logURL(for:)` / `debugURL(for:)` accessors. Paths persist after terminal
state (same as transcripts) so users can reveal them for recently-completed
items; cleared on prune / stop.

**`ActivityWindowView`** gained two affordances:
1. A compact `ellipsis.circle` menu (`revealMenu`) in the detail header —
   "Reveal Log" (`doc.text.magnifyingglass`) + "Reveal Debug Folder"
   (`folder.badge.gearshape`). Only shown when at least one path exists.
2. The same two items in the row context menu (after "Copy Transcript",
   behind a divider).

Both use `NSWorkspace.shared.activateFileViewerSelecting([url])` — matching
`ChatView`'s existing behavior exactly.

**Tests:** 4 new `QueueActivityTrackerRunPathsTests` (stored per-item, survive
terminal state, cleared on prune, nil paths produce nil accessors). Updated all
8 `QueueIngestionWorkerFactory` / `QueueIngestionWorker` constructor call sites
+ the `FakeIngestionProvider` mock in `QueueIngestionTests.swift`.

**Build/Tests:** `make version prompts` ✓; `swift build` clean (16s);
fast test tier **2581 tests / 219 suites pass** (4 new).


## 2026-07-18 — Unify audio podcast source detail with the video Reader/Media/Split tab pattern (branch `feature/audio-podcast-detail-tabs`)

**Problem.** PR #586 (open, `unify-video-pdf-source-tabs`) unified *video*
sources (YouTube/Vimeo) into the same Reader / Video / Split tab layout that
PDFs use — but audio podcast sources (Apple Podcasts), which route through the
exact same `ExternalEmbed` byteless-embed path, would have surfaced under a
"Video" tab label. The tab system was video-specific in name; audio needed the
same Reader/Media/Split treatment with an "Audio" label.

**Fix.** Generalized the video tab into a media tab that classifies audio vs
video and labels the picker accordingly. Two files changed (one new pure
helper + view wiring, one test suite). Built on top of the merged #586 pattern
(video tab renamed → media tab).

Changes:
- `Sources/WikiFSEngine/ACPBackend.swift` — `SessionUsage.modelName` field + init param + merge propagation; `sessionUsage(for:)` resolves the friendly name from `ModelsInfo.availableModels`.
- `Sources/WikiFSEngine/AgentLauncher.swift` — `capturePhaseUsage` passes `modelName: usage.modelName` through the providerLabel enrichment init.
- `Sources/WikiFS/Queue/QueueActivityTracker.swift` — `ModelUsageBreakdown` struct, `DailyUsageByModel` persisted struct (load/save/sortedForDisplay), `itemUsageByModel` + `todayUsageByModel` state, `.usage` handler accumulation, `usageBreakdown(for:)` accessor, `UsageFormatter.modelBreakdownLine` + `itemModelBreakdownLine`.
- `Sources/WikiFS/Window/MenuBarItemController.swift` — `buildMenu` appends per-model items below the summary line.
- `Sources/WikiFS/Queue/ActivityWindowView.swift` — `detailHeader` per-model sub-view; `byModelSorted` helper.
- `Tests/WikiFSTests/UsageFormatterTests.swift` — 12 new tests (modelName preference, modelBreakdownLine variants, breakdown accumulation, DailyUsageByModel accumulation + sort, itemModelBreakdownLine).
- `plans/usage-breakdown-by-model.md` — design doc + future work (phase-level usage events, friendly-name lookup at the menu bar, interactive chat usage #546/#576).

**Build/Tests:** `make version prompts && swift build` clean; full fast test tier **2573 tests / 218 suites pass**; `swift test --filter UsageFormatterTests` 40/40 pass.

## 2026-07-18 — Wire interactive chat usage into the daily token tracking + menu bar display (branch `feature/chat-usage-tracking`)

**Problem:** The "Today: X tokens" menu bar item only counted usage from queue-based runs (ingest/lint). Interactive chat sessions (Ask/Edit tabs) go through `AgentLauncher.startInteractiveQuery` + `sendInteractiveMessage`, which did NOT emit usage via the `onUsage` callback — a long chat burning 50K tokens didn't show up in the daily total. The `ACPBackend` already captures `SessionUsage` for ALL sessions via `SessionUsageState`; the gap was that `AgentLauncher` only called `capturePhaseUsage` + emitted `onUsage` from the queue-based `run()` path, not from the interactive `sendInteractiveMessage` path.

**Key correctness challenge — no double-counting across turns.** The backend's `sessionUsage(for:)` returns **cumulative** per-session totals (tokens across all turns of one session), and `DailyUsage.add` is **additive**. The queue path reads each phase session's usage **once** (no double-count, since each phase is a separate session). Interactive chat reuses ONE session across many turns, so naively emitting the cumulative snapshot after each turn and adding it would re-add the full total on every turn. The fix emits the **per-turn delta** (`current cumulative − last-emitted baseline`) so the daily total only gains the marginal tokens for that turn.

**Approach — Option A (callback).** Matches the existing `onAgentEvent` callback on `AgentLauncher` and the closure-injection threading (`WikiFSApp` → `SessionManager.init` → `WikiSession.init`). Keeps capture in the `@MainActor` `sendInteractiveMessage` turn-end branch (naturally main-actor safe). Avoids adding a new `AgentEvent` case (which would complicate the transcript drain + persistence + the `StoreEmissionExhaustivenessTests` partition).

Changes:

- **`Sources/WikiFSEngine/ACPBackend.swift`** — added `SessionUsage.delta(from:to:)` static helper next to `merging`. Computes the incremental usage between two cumulative snapshots of the same session: token counts are subtracted (`to − from`, clamped to ≥0); cost is a delta (`to.cost − from.cost`, clamped ≥0); context window is point-in-time (takes `to`); provider label/model id/thinking level are latest-non-nil-wins (matching `merging`). `from == nil` returns `to` directly (first turn's delta == full snapshot).
- **`Sources/WikiFSEngine/AgentLauncher.swift`**:
  - New `@ObservationIgnored public var onInteractiveUsage: (@MainActor (SessionUsage) -> Void)?` callback (installed by the app layer; `nil` = no-op so headless/daemon callers are unaffected).
  - New `@ObservationIgnored private var lastInteractiveUsageSnapshot: SessionUsage?` per-session baseline.
  - New `captureInteractiveUsage()` async method: reads `backend.sessionUsage(for: sessionHandle)` (while the session is still alive, before `cancel`/`closeSession`), attaches the configured `runProviderLabel`, computes `delta(from: lastInteractiveUsageSnapshot, to:)`, updates the baseline, and forwards the delta via `onInteractiveUsage`. Silent no-op for non-ACP backends or when the callback is nil. Only forwards when `totalTokens > 0 || cost != nil`.
  - Call site: `sendInteractiveMessage`'s turn-end (`endsGeneration`) branch now calls `await self.captureInteractiveUsage()` after `flushTranscript()`/`generateChatSummary()`.
  - Reset: `lastInteractiveUsageSnapshot = nil` in `resetRunArtifacts()` (per-run fresh start) and `onInteractiveUsage = nil` + `lastInteractiveUsageSnapshot = nil` in `finish()` (session teardown).
- **`Sources/WikiFS/Queue/QueueActivityTracker.swift`** — added `recordInteractiveUsage(_ usage: SessionUsage)` that accumulates the delta into `todayUsage` and persists. Deliberately does NOT create an `itemUsage` entry (interactive chat has no queue item); only the daily total — which the menu bar reads — is updated. The existing `.usage` queue event handler is unchanged.
- **`Sources/WikiFSEngine/WikiSession.swift`** — new `interactiveUsageRecorder: @MainActor (SessionUsage) -> Void` init parameter (default no-op); installed onto BOTH `agentLauncher` and `chatLauncher` so interactive queries AND chats report usage.
- **`Sources/WikiFSEngine/SessionManager.swift`** — new `interactiveUsageRecorder` init param threaded through to `WikiSession`.
- **`Sources/WikiFS/Window/WikiFSApp.swift`** — passes `interactiveUsageRecorder: { [weak activityTracker] usage in activityTracker?.recordInteractiveUsage(usage) }` at `SessionManager` construction (the tracker is created just before the manager).

**No double-count with queued runs.** A single `AgentLauncher` runs EITHER a queue `run()` OR an interactive `startInteractiveQuery` (never both); `resetRunArtifacts()` is called at the start of each and clears `lastInteractiveUsageSnapshot`. The queue path never calls `captureInteractiveUsage` (only `sendInteractiveMessage` does), and the interactive path never emits a queue `.usage` event. So a session that is both queued AND interactive (theoretically possible via takeover) counts once per path.

**Tests:** Added 4 `SessionUsage.delta` tests (`deltaWithNilBaselineReturnsFullSnapshot`, `deltaSubtractsBaselineTokens`, `deltaCarriesMetadataFromBaselineWhenMissing`, `deltaClampsToZero`) in `ACPBackendTests.swift`, and 1 `QueueActivityTracker.recordInteractiveUsage` accumulation test in `QueueIngestionTests.swift`. The tracker test captures + restores the persisted `DailyUsage` so it doesn't pollute the real menu bar count.

**Build/Tests:** `make version prompts && swift build` clean; fast test tier **2578 tests / 219 suites pass**.

## 2026-07-18 — Fix missing activity ingestion details: thinking-level dropped in enrichment (branch `fix/missing-activity-details`)

**Problem:** The Activity window lost the thinking-effort level segment ("high"/"medium"/"low") for completed ingestion/lint runs. The user reported that rich run metadata (model name, token counts, cost, timing) had partially regressed — the thinking-effort segment introduced in #566 was always blank.

**Root cause:** PR #569 (`Surface thinking effort level in UI`) added `thinkingLevel: String?` to `SessionUsage` and wired it through `ACPBackend.sessionUsage(for:)` and `UsageFormatter.fullSummary`, but the enrichment hop in `AgentLauncher.capturePhaseUsage` (which reattaches the configured `providerLabel`) reconstructed `SessionUsage` with an explicit memberwise init that omitted the `thinkingLevel` parameter — defaulting it to `nil` on every call. Since every `capturePhaseUsage` call site passes a non-nil `providerLabel`, the `if let providerLabel` branch always ran, and `thinkingLevel` was always lost. `SessionUsage.merging` then propagated `nil` through `runTotalUsage` → `onUsage` → the `.usage` queue event → `QueueActivityTracker.itemUsage`, so the Activity window's `fullSummary` rendered without the thinking-effort segment.

**Investigation (pipeline trace):** Verified the full usage pipeline is structurally intact — `ACPBackend.sessionUsage` → `capturePhaseUsage` → `runTotalUsage` → `AppQueueIngestionProvider.onUsage?(launcher.runTotalUsage)` × 3 sites → `emitUsage` → `QueueEngine.makeEmitUsage` broadcaster → `QueueActivityTracker.handle(.usage)` → `itemUsage` → `ActivityWindowView.fullSummary`. The display code (row + header) is present and correct. The #565/#571/#572/#573 merges did not break the wiring in `WikiFSApp.swift` (the `UsageEmitBox` seam). The only dropped field was `thinkingLevel` in `capturePhaseUsage`.

**Fix:** One-line addition — pass `thinkingLevel: usage.thinkingLevel` through the enrichment `SessionUsage` init in `capturePhaseUsage`. The `else` branch (no `providerLabel`) already passed `usage` directly. Added 3 regression tests covering `SessionUsage.merging` thinking-level latest-wins + existing-preserved, and `UsageFormatter.fullSummary` thinking-level inclusion between model and tokens.

Changes:
- `Sources/WikiFSEngine/AgentLauncher.swift` (`capturePhaseUsage`) — pass `thinkingLevel: usage.thinkingLevel` in the providerLabel enrichment init.
- `Tests/WikiFSTests/ACPBackendTests.swift` — added `thinkingLevel: "high"` assertion to `sessionUsageStructCarriesAllFields`; 2 new tests (`mergingCarriesLatestThinkingLevel`, `mergingPreservesExistingThinkingLevelWhenNewIsNil`).
- `Tests/WikiFSTests/UsageFormatterTests.swift` — 2 new tests (`fullSummaryIncludesThinkingLevelBetweenModelAndTokens`, `fullSummaryOmitsThinkingLevelWhenNil`).

**Build/Tests:** `make version prompts && swift build` clean; `swift test --filter UsageFormatterTests|ACPBackendTests` 67/67 pass; full fast test tier **2552 tests / 216 suites pass**.

## 2026-07-18 — Issue #192: "Go to Original" bookmark context-menu action (branch `bookmark-go-to-original`)

**Problem:** Right-clicking a bookmark offered only Open / Open in Background /
Open With / Edit / Delete. To reach the page/source itself the user had to
double-click → open the bookmark detail → click "Show in List" — two clicks plus
a view switch.

**Fix:** Added a single-selection "Go to Original" item at the top of the
bookmarks context menu. It reveals the bookmark's target in its sidebar section
(Pages / Sources / Chats) without opening a reader tab, reusing the existing
"Show in List" reveal mechanism (`WikiStoreModel.requestSidebarReveal(_:)`)
that `PageDetailView` / `SourceDetailView` / `ChatView` already use — it
switches the sidebar tab, clears any search hiding the target, and scrolls to +
selects the row.

Wiring: an `onGoToOriginal: (WikiSelection) -> Void` callback was threaded
through `BookmarksCallbacks` and `BookmarksOutlineView` (both `.init` sites in
the representable) and connected in `BookmarksContainerView` to
`store.requestSidebarReveal(selection)`. The VC's `goToOriginalAction` resolves
the clicked node's target to a `WikiSelection` via a shared
`revealSelection(for:)` helper (also used to DRY up `openableSelections`).
Gated single-selection + openable leaf only (pageRef / sourceRef / chatRef);
hidden for folders and multi-selection batches.

Changes:
- `Sources/WikiFS/Bookmarks/BookmarksOutlineView.swift` — new menu item + action,
  `revealSelection(for:)` helper; `BookmarksCallbacks` and `BookmarksOutlineView`
  gain `onGoToOriginal`; `openableSelections` refactored to reuse
  `revealSelection`.
- `Sources/WikiFS/Bookmarks/BookmarksContainerView.swift` — wire
  `onGoToOriginal` → `store.requestSidebarReveal(selection)`.
- `Tests/WikiFSTests/BookmarksMultiSelectMenuTests.swift` — updated the 3
  `BookmarksCallbacks(...)` call sites for the new field; added 5 tests
  (visibility for leaf/folder/batch + page/chat target reveal mapping).

**Build/Tests:** `make version prompts && swift build` clean; fast test tier
2,503 tests in 213 suites pass.

## 2026-07-17 — Fli## 2026-07-18 — Tantivy Phase 0 build spike (branch `spike/tantivy-build-verification`)

**What changed:** Added `botisan-ai/tantivy.swift` (`from: "0.3.4"`) as an SPM
dependency on `WikiFSSearch` + `WikiFSTests`. Verified the pre-built
`libtantivy-rs.xcframework` resolves under bare `swift build` (no Xcode, no
xcodebuild) and the UniFFI FFI bridge works end-to-end. Findings doc:
`plans/tantivy-build-spike-results.md`.

**Result: ✅ Phase 0 PASSED — Phase 1 (shadow index) unblocked.**

- `swift build` succeeds in 68 s (exit 0). Zero warnings in the build log.
- XCFramework macOS slice is a **universal binary** (`arm64` + `x86_64`,
  confirmed via `lipo -archs`) — contradicts the design doc's §1.2 "Intel
  likely unsupported." Intel Macs ARE supported.
- `@TantivyDocument` macro expands cleanly under `-warnings-as-errors` (the
  expanded Codable/CodingKeys is type-checked in `WikiFSTests`, which has
  strict settings). No Swift 6 concurrency warnings.
- Binary delta: +12 MB (debug executable 98 MB → 110 MB). Within the <20 MB
  threshold.
- Smoke test (`TantivySmokeTests.swift`): create index → `@TantivyDocument` with
  `@IDField`/`@TextField` → index one doc → search → verify hit + score.
  Passes in 0.11 s. Fast, untagged (runs in the fast CI tier).
- No symbol conflicts with `CSqliteVec` — disjoint namespaces.

**API confirmed:** `TantivySwiftIndex<T>(path:)` generic actor,
`index(doc:)` auto-commits, `TantivySwiftSearchQuery<T>(queryStr:defaultFields:)`
with macro-synthesized `CodingKeys`. No `SnippetGenerator` exposed (confirms
design doc §4.3 fallback: client-side highlighting for Phase 1).

**Not done here:** Tantivy is NOT wired into the search pipeline. No production
code in `Sources/WikiFSCore/` imports it yet — only the smoke test does.
Phase 1 implements `TantivySearchService` + `TantivyIndexer` +
`WikiSearchDocument` + event bus subscription.

## 2026-07-17 — Flip StoreBackend default to GRDB (branch `feature/grdb-default-backend`)

**What changed:** The GRDB migration is complete — all 88 methods implemented
(#545/#550), 37-version migration ladder (#557), and 2,480 parity tests pass
(#561). `StoreBackend.current` now defaults to `.grdb` instead of `.sqlite`.
Setting `WIKIFS_STORE_BACKEND=sqlite` opts back in to the legacy
`SQLiteWikiStore` as an escape hatch.

**Deprecation:** Added prominent `⚠️ DEPRECATED` doc comment headers to
`SQLiteWikiStore`, `SQLiteStatement`, and `WikiReadPool`, noting that
`GRDBWikiStore` is the default and these types will be removed in a future
version. No `@available(*, deprecated)` markers were added — with
`-warnings-as-errors` active and live production usage of `WikiReadPool`
outside `SQLiteWikiStore`, compiler-enforced deprecation would break the build.
Compiler-enforced deprecation will come in a follow-up PR when the files are
actually deleted.

**Tests:** Fast test tier (2,487 tests) passes against GRDB by default
(`WIKIFS_STORE_BACKEND` unset). `SQLiteWikiStoreTests` (48 tests) still pass
— they construct the store directly, not through the factory, confirming the
deprecated code remains functional.

## 2026-07-17 — Enrich ingestion completion summary line (branch `scared-gopher`)

**Problem:** When an ingestion finished, the Activity window showed "797 in · 203 out" — no unit, no model, no harness, no thinking signal, no start time, no duration. The user couldn't tell what the numbers meant or what ran.

**Fix:** Threaded run metadata (provider label + model id) from the launcher into `SessionUsage` and enriched `UsageFormatter` to produce a full summary line.

Changes across 4 source files + 1 test file:

- **`Sources/WikiFSEngine/ACPBackend.swift`** — `SessionUsage` gained `providerLabel: String?` and `modelId: String?` (point-in-time, latest non-nil wins on merge, like cost/currency). `sessionUsage(for:)` now enriches the snapshot with `session.modelsInfo?.currentModelId` (the actual model the session used).
- **`Sources/WikiFSEngine/AgentLauncher.swift`** — `capturePhaseUsage` gained a `providerLabel` parameter; every call site (7 total — planner, executor ×3, finalizer, single-session, runPhase) passes `routing.provider.label`. The provider label is attached before merging into `runTotalUsage`.
- **`Sources/WikiFS/Queue/QueueActivityTracker.swift`** — `UsageFormatter` gained `tokenSummary(usage:)` (token segment with explicit "tokens" unit + thought tokens), `duration(ms:)`, `startTime(ms:)`, and `fullSummary(usage:startedAt:finishedAt:)` which composes the full line.
- **`Sources/WikiFS/Queue/ActivityWindowView.swift`** — both display sites (list row + detail header) call `fullSummary` with `item.startedAt`/`item.finishedAt` (already on `QueueItem`).

The completion line now renders like:
```
2:32 PM · 1m 3s · Claude · sonnet-4 · 797 tokens in · 203 tokens out · 412 thought · $0.34
```
Each segment is omitted when its data is unavailable. There is no "thinking effort" level setting; thought tokens (the cumulative reasoning-token count) surface as "412 thought" when present.

**Tests:** `Tests/WikiFSTests/UsageFormatterTests.swift` (27 tests covering `tokens`, `cost`, `duration`, `startTime`, `tokenSummary`, `summary`, `fullSummary` edge cases). Extended `ACPBackendTests.swift` with 3 `SessionUsage.merging` tests for the new fields.

**Build/Tests:** `swift build` clean; `swift test --filter UsageFormatterTests` 27/27 pass; full fast test tier 2462 tests pass.


## 2026-07-17 — Issue #525: Design — ACP session efficiency (branch `design/acp-session-efficiency`)

**Design doc written.** Produced `plans/acp-session-efficiency.md` covering the
full ACP session-lifecycle optimization for the multi-phase ingest pipeline.

The problem: `runACPIngestPlannerExecutors` spawns a new subprocess per phase
(planner, each executor, finalizer) — 7 complete lifecycles for a 5-source
ingest, each with ~2–4s of launch/initialize/authenticate/newSession/setModel
overhead = 12–24s wasted on process plumbing.

The design documents four incremental phases:
1. **Warm subprocess** — one `launch`+`initialize` at ingest start, per-phase
   `session/new`+`session/close` (without `terminate`), one `terminate` at the
   end. New `ACPBackend.closeSession()` method. Uses only existing SDK methods.
2. **`session/resume` crash recovery** — detect subprocess death, spawn a new
   one, `resumeSession` to restore context without history replay. Falls back
   to `session/load` (O(history)) or fresh `session/new`. Requires persisting
   the ACP `sessionId` in the QueueItem payload.
3. **`session/fork` for executors** — fork the planner session so executors
   inherit source-layout understanding without reasoning noise. Falls back to
   fresh sessions if fork unsupported.
4. **Parallel executors** — `withTaskGroup` for concurrent sessions on one
   subprocess (or a pool fallback), plus context monitoring via `usage_update`
   notifications (proactive artifact write at ~64%, close+fresh at ~80%).

Includes a context-benefit matrix (warm subprocess always; warm sessions only
within context-beneficial boundaries like a single source extraction), budget/
cost tracking integration (`UsageUpdate.cost` and `SessionPromptResponse.usage`
— currently discarded, ties to #528), interaction analysis with the generation
gate, `stopAgent`, and the watchdog, and a risk table with mitigations.

Verified against the swift-acp SDK (`wsargent/swift-acp` v0.2.0+) source:
confirmed `closeSession`, `resumeSession`, `forkSession`, `listSessions`,
`loadSession`, `terminate`, `processIdentifier`, `stderrLines` method
signatures; confirmed `SessionCapabilities` sub-capabilities
(`close`/`resume`/`fork`/`list`/`delete`); confirmed `UsageUpdate` carries
`used`/`size`/`cost: Cost(amount:currency:)`; confirmed `SessionPromptResponse`
carries `usage: Usage?` with `inputTokens`/`outputTokens`/`totalTokens`.

Key files read: `Sources/WikiFSEngine/AgentLauncher.swift` (the
`runACPIngestPlannerExecutors`, `runPhase`, `startInteractiveQuery`,
`stopAgent`, `finish`, `startCompletionWatchdog` methods),
`Sources/WikiFSEngine/ACPBackend.swift` (the `ACPSession` struct, `start`,
`send`, `cancel`, `resume`, `resolveSpawnConfig`),
`Sources/WikiFSEngine/AgentBackend.swift` (the protocol, `SessionHandle`,
`BackendProfile`), `Sources/WikiFSEngine/ACPPermissions.swift` (the
`ACPEventTranslator` — discards `.usageUpdate`),
`Sources/WikiFSEngine/GenerationGate.swift`, `Sources/WikiFSEngine/QueueIngestionProvider.swift`.

## 2026-07-17 — Issue #532: Module restructuring Phase 2+3 — extract WikiFSMarkdown + WikiFSSearch (branch `refactor/extract-markdown-search`)

**Shipped.** Extracted two new SPM targets following the Phase 1 pattern
(WikiFSLinks + WikiFSTypes, PR #535):

- **`WikiFSMarkdown`** (16 files) — linter, extractors, diffs, HTML↔markdown
  converters, slug utils, mermaid validator. Depends on `WikiFSTypes` +
  `WikiFSLinks` (`WikiLinkFixer`, `WikiLinkSpan`). Links `JavaScriptCore`
  (MarkdownLinter + MermaidValidator run vendored JS in a JSContext).
- **`WikiFSSearch`** (6 files) — `Embedder` protocol, `NLEmbedder`,
  `EmbeddingService`, `TextChunker`, `RankFusion`, `WikiIndex`. Depends on
  `WikiFSTypes` only. Links `NaturalLanguage` (NLEmbedder).

Both re-exported by `WikiFSCore` via `@_exported import` in `ModuleExports.swift`
so consumers don't need per-file imports.

**Key decisions:**
- **Moved `DebugLog` to `WikiFSTypes`** — the pure leaf logging type (Foundation
  + `os` only) was used by both `MarkdownLinter` and `EmbeddingService`. Moving
  it to the leaf module + re-export solved both dependencies cleanly.
- **Inlined 3 `GeneratedPrompts` references** to break circular dependencies
  (`WikiFSMarkdown`/`WikiFSSearch` → `WikiFSCore` → back): `wikiIndexDefault`
  (4-line fallback string in `WikiIndex`), `extractionSystem` +
  `extractionInstruction` (extraction prompts in `ExtractionPrompts`). Each has
  a comment pointing to its `prompts/*.md` source file.
- **Kept `PageMarkdownFormat.swift` in WikiFSCore** — it references `WikiPage`
  and `SourceMarkdownVersion` (domain model types with deep WikiFSCore coupling)
  and has ~23 call sites. Too coupled to extract without a protocol-injection
  refactor; left in `Sources/WikiFSCore/Markdown/` per the task's "keep if too
  coupled" guidance.
- **Widened 5 access levels to `public`** (was `internal`, accessed cross-module
  after extraction): `SlugUtils.slugBase`, `RankFusion.rrf`, plus
  `HTMLToMarkdown.Token`/`scopedTokens`/`markdown(fromScopedTokens:)`/`titleOnly`
  and `WikiFootnoteMarkdown.Footnote.init` (Swift 6 implicit memberwise init is
  internal — added explicit public init).
- **Removed `linkerSettings` from WikiFSCore** — `JavaScriptCore` and
  `NaturalLanguage` are now linked by their respective extracted targets and
  transitively available through the dependency chain.

**Dependency graph** (DAG, no cycles):
```
WikiFSTypes (leaf)
├─ DebugLog, PageID, ULID, ResourceKind, EmbedTarget, ParsedLink, MimeType
├─ WikiFSLinks → WikiFSTypes
├─ WikiFSMarkdown → WikiFSTypes + WikiFSLinks
├─ WikiFSSearch → WikiFSTypes
└─ WikiFSCore → all four (+ CSqliteVec)
```

**Gates:** `make version prompts` ✓; `swift build` clean ✓;
fast tier **2456 tests / 211 suites passed** ✓.

## 2026-07-17 — Issue #532: Module restructuring design research (branch `design/module-restructure`)

**Design doc only — `plans/module-restructure.md`. No code changes.** Researched
whether to split `WikiFSCore` (131 files, ~30k lines, organized into 7 subdirs
by #531) into domain-specific SPM targets. Key findings:

- **The 7 subdirectories from #531** are: Core (51 files/6,967 lines), Store
  (9/13,408), Integrations (25/3,660), Markdown (15/2,929), Links (11/1,822),
  Sources/glue (14/1,935), Search (6/413).
- **The Links cluster is pure logic** — zero actual `store.` method calls; the
  only `WikiStore` references in Links files are doc comments. Same for Search's
  link-fetch types.
- **No real circular dependency exists.** The dependency is a DAG. The one
  protocol-level type cycle — `WikiStore.replaceLinks` takes
  `[WikiLinkParser.ParsedLink]` — is breakable by moving the tiny `ParsedLink`
  struct (~15 lines) into WikiFSCore.
- **SQLiteWikiStore is a fan-in hub**, not a leaf. It references 54+ cross-domain
  type calls: 27 `WikiNameRules`, 6 `WikiLinkParser`, 6 `EmbeddingService`, 5
  `WikiIndex`, 3 `DisplayNameResolver`, etc. Extracting it as `WikiFSStorage`
  makes a hub that depends on all domain targets, not a clean leaf.
- **WikiStoreModel is the composition root by design** — 3,096 lines, 75+
  distinct `store.<method>` calls across every domain, plus direct calls to
  WikiLinkParser, MarkdownLinter, EmbeddingService, SourceRefreshService,
  LinkReconciler, DisplayNameResolver, WikiRenderContext, WikiStateSnapshot.
  Cannot be decomposed into per-domain models without refactoring 68 app views.
- **Build time:** 25s cached, 64s incremental (1 file changed). The ~39s delta
  is recompiling all 131 WikiFSCore files + dependents.
- **Access-control audit:** ~22 types can become `internal` after extraction
  (HTMLTokenizer, Embedder, NLEmbedder, RankFusion, etc.). Key cross-target types
  (DebugLog×245, PageID×160, WikiStoreModel×89, WikiLinkParser×6, EmbeddingService×5)
  must stay `public`.
- **Recommendation: Option D (phased), scoped to Phases 1–3.** Extract
  WikiFSLinks + WikiFSMarkdown + WikiFSSearch (low risk, ~4,420 lines, modest
  build win, ~22 types → internal). Defer WikiFSStorage extraction + WikiStoreModel
  decomposition (HIGH risk, uncertain payoff — the storage impl is a fan-in hub
  that would need 54 protocol-injection refactor sites to become a clean leaf).

PR: branch `design/module-restructure` → `main` (NOT merged).

## 2026-07-17 — Issue #502: Cross-module dedup — keychain boilerplate, HTML escape, slug algorithm (branch `cross-module-dedup`, PR #504)

**Shipped (PR #504, open — NOT merged).** Three cross-module dedup fixes; net
**−122 lines** of duplicated boilerplate (8 files modified, 2 new shared modules).

**L1 — Keychain `SecItem` boilerplate (3 stores → 1).** New
`Sources/WikiFSCore/KeychainSecretStore.swift` centralizes the generic-password
query/add/update/delete mechanics (`read(service:account:)`,
`write(service:account:value:error:)`). `KeychainZoteroCredentialStore`,
`KeychainACPCredentialStore`, `KeychainExtractionCredentialStore` now delegate;
each keeps only its `service`/`account` mapping and its own typed error. ACP's
pre-existing local `read`/`write` helpers removed. `write` takes an
`error: (String, OSStatus) -> Error` factory so each store throws its own
`*KeychainError` with the exact `operation`/`status` formatting it always had —
behavior preserved.

**L2 — byte-identical HTML escape.** Added `HTMLEntities.escapeHTML(_:)` (enum
made `public` so the `WikiFS` target can reach it; `decode` stays module-
internal). `ChatWebView.escape` and `MarkdownHTMLRenderer.escape` now delegate;
the `escapeAttribute`/`escapePreservingBreaks`/`htmlAttributeEscape` wrappers
are unchanged. `HTMLMarkdownRenderer.escapeInline` (markdown `[`/`]`) is
different logic — left alone.

**L3 — duplicated slug algorithm.** New `Sources/WikiFSCore/SlugUtils.swift`
holds the shared `slugBase(_:)` normalization (lowercase → whitespace→`-` →
keep letters/numbers/`-` → collapse). `AnchorBlock.makeSlug` and
`SQLiteWikiStore.slugify` delegate, keeping their own fallback
(`"heading"`/`"untitled"`) and suffix logic. `slugBase` matches `makeSlug`'s
Unicode-permissive behavior, so the heading-anchor/`resolveAnchor` path is
byte-identical; `slugify` now also keeps non-ASCII letters/whitespace (existing
DB slugs read verbatim; only new/renamed titles change). `PodcastEpisodeURL.slug`
is path-based — deliberately separate. Note: the issue assumed the two slugs
were "the same algorithm" — they differed subtly (ASCII-only vs Unicode).

**Build/tests:** `swift build` clean; fast tier **2444 tests/210 suites passed**;
targeted `slugifyStripsPunctuationAndCollapsesDashes` (in the skipped
`SQLiteWikiStoreTests`) passes with the changed `slugify`.

## 2026-07-17 — Issue #488: Delete dead content-sniff forwarder shims (branch `cleanup/dead-sniff-forwarders`)

**Shipped.** Removed 81 lines of dead forwarder shims left over from the
`ContentSniff` extraction. All real callers use `ContentSniff.mimeType(of:)`
(or `FormatMaterializer.dispatch`, which now calls it directly).

**Deleted from `URLFetchService.swift`** (zero production callers — only
tests/forwarders referenced them):
- `shouldSniff`, `sniffContentType` — 1-line forwarders to FormatMaterializer.
- `stemFromURL` — dead; comment admitted "backward compat"; `nameHint(for:)`
  is the production path.
- `sanitizeStem`, `ensureExtension`, `textExtension` — dead forwarders (only
  test callers or zero callers); canonical copies live on `FormatMaterializer`.

**Kept** (real production callers): `URLFetchService.normalizedMIME`
(WebsiteSnapshotExtractor), `decodeText` (SourceMaterializer),
`binaryExtension` (WebsiteSnapshotExtractor).

**`FormatMaterializer.swift`:** inlined the `sniffContentType` forwarder —
`dispatch` now calls `ContentSniff.mimeType(of:)` directly. Kept `shouldSniff`
(real switch logic, not a forwarder; used internally by `dispatch`). Note:
the issue's premise that the FormatMaterializer methods were "only called by
the dead shim" was incorrect — they have an internal caller (`dispatch`);
only the `URLFetchService` versions were truly dead.

**Tests:** deleted duplicate `URLFetchServiceTests` copies (canonical versions
already exist in `FormatMaterializerTests`). Migrated
`stemFromURLPrefersPathThenHost` → `nameHintPrefersPathThenHost` (tests the
production replacement). Migrated `FormatMaterializerTests.sniffContentType`
to call `ContentSniff.mimeType(of:)` directly. Removed `URLFetchService` from
the `ExtensionCheckGuardTests` allowlist (no longer contains extension checks).

## 2026-07-17 — Issue #484: Structured ChangeToken type (branch `hardcore-bulldog`)

**Shipped.** Replaced the positional colon-joined `changeToken()` string
literals with a structured `ChangeToken` type — named fields per fold
(`pages`, `sourceTable`, `systemPrompt`, `log`, `wikiIndex`,
`sourceMarkdownVersions`, `sourceGraph`, `bookmarks`, `chat`) so adding a new
`ResourceKind` fold no longer breaks ~20 tests that each need a `:0` appended.

**New types** (`Sources/WikiFSCore/Resource.swift`):
- `ChangeToken` — `Sendable, Equatable` struct with named properties; nested
  structs (`Pages`, `SourceTable`, `SourceGraph`, `Chat`) for the multi-field
  folds. A `rawString` property reproduces the colon-joined form for the File
  Provider sync anchor.
- `ChangeTokenFold` — enum cases carrying named values; one case per contributor
  fold.
- `ChangeTokenContributor` protocol: `fragment(in:) -> String` →
  `fold(in:) -> ChangeTokenFold`.

**Changed** (`Sources/WikiFSCore/SQLiteWikiStore.swift`):
- `changeToken()` return type `String` → `ChangeToken`; assembles via
  `var token = ChangeToken(); for c in contributors { token.apply(try c.fold(in: self)) }`.
- 9 contributor structs updated from `fragment` → `fold`.

**Non-test callers** updated to use `.rawString`:
- `Sources/wikid/WikiDaemon.swift` — 2 sites: `(try? store.changeToken())?.rawString ?? ""`.
- `Sources/WikiFSFileProvider/Projection.swift` — 1 site: `token.rawString`.
  `Projection.changeToken()` still returns `String` (the FP opaque anchor).

**Tests migrated** (~22 literal assertions → named-field assertions):
- `SQLiteWikiStoreTests.swift` — 10 literal assertions + 2 preDelete string
  comparisons across 3 tests (`changeTokenAdvancesOnEveryMutation`,
  `changeTokenAdvancesOnIngestAndDelete`, `changeTokenAdvancesOnAppendProcessedMarkdown`).
- `LogIndexTests.swift` — 5 literal assertions across 2 tests.
- `SystemPromptTests.swift` — 2 literal assertions.
- `Phase5StoreCanonicalizationTests.swift` — `token: String` → `token: ChangeToken`
  in helper return type.
- `ChangeTokenContributorTests.swift` — added `rawStringMatchesHistoricalLayout`
  test (single assertion guarding `rawString` reproduces the historical token).

**No changes needed** (Equatable struct worked for `before != after`-style
comparisons): `BytelessEmbedIntegrationTests`, `ProcessedMarkdownTests`,
`EnumeratorDeletionTests` (uses `Projection.changeToken()` which still returns
`String`), `StoreEmissionExhaustivenessTests` (comment-only reference).

**Evidence.**
- `swift build` ✓ (159s, clean).
- `swift test --filter 'SQLiteWikiStoreTests'` ✓ (48 tests passed).
- Targeted change-token tests ✓ (all passed:
  `ChangeTokenContributorTests`, `LogIndexTests`, `SystemPromptTests`,
  `changeTokenAdvances*`, `renameSource*`, `changeTokenChangesOnVersionAppend`).
- `StoreEmissionTests` ✓ (12 tests passed — `changeToken()` signature change
  didn't break the exhaustiveness parse).
- Fast-tier `swift test --skip` ✓ (2438 tests passed).
- `rg 'changeToken\(\)\s*==\s*"' Tests/` — no remaining string-literal comparisons.
- `rg 'fragment\(in' Sources/ Tests/` — no remaining `fragment(in:)` calls.

See [`plans/issue-484-change-token-struct.md`](plans/issue-484-change-token-struct.md).

## 2026-07-16 — User guide documentation (branch `spiteful-starfish`)

**Created.** A user-facing documentation wiki under `docs/user-guide/` —
focused on what the user sees, does, and experiences, **not** on architecture
or internal design decisions. Seven topic pages plus an index:

- `docs/user-guide/README.md` — landing page: core concepts (wikis, pages,
  sources, agent, links, bookmarks), the fundamental workflow diagram, TOC,
  and design philosophy.
- `docs/user-guide/getting-started.md` — first-time setup: create a wiki,
  configure agents, add sources, run first ingest, ask first question.
- `docs/user-guide/interface.md` — window layout tour: sidebar sections,
  tab bar, toolbar omnibox, wiki switcher, change log, detail pane, menu bar.
- `docs/user-guide/pages-and-links.md` — reading/editing pages, full wiki-link
  syntax reference (pages, sources, sections, quotes, version pins, embeds),
  ghost links, link context menus, zoom, find-on-page.
- `docs/user-guide/sources-and-ingestion.md` — adding sources (drag-drop, URL,
  Zotero, folder import), PDF extraction backends, source detail view,
  extraction versioning, the ingest operation, the persistent queue.
- `docs/user-guide/chat.md` — starting chats, the composer, adding context/
  attachments, permission approvals, reading the transcript (tool calls,
  thinking blocks, durations), the chat outline, managing chat history.
- `docs/user-guide/organizing-and-managing.md` — bookmarks, search (semantic
  + FTS5), navigation, multiple wikis & windows, all settings tabs, the
  activity queue, notifications, change log, system prompt.
- `docs/user-guide/keyboard-shortcuts.md` — complete shortcut quick-reference.

**Research method:** dispatched three parallel `researcher` subagents to
investigate the chat experience, the page/source experience, and the wiki
management/settings experience respectively, each reading the relevant Swift
view files and design plans. Their summaries were synthesized into the
user-guide pages.

**PLAN.md** documentation index updated with the user-guide entry.

## 2026-07-16 — Fix #477: wiki open blocking on large wikis (branch `fix/477-wiki-open-blocking`)

**Implemented.** Eliminated the frozen "Opening wiki…" spinner when opening
wikis with 300+ pages. Three changes address the synchronous main-thread
blocking at different layers of the session-resolution path:

1. **Persist link-reconcile flag in SQLite metadata (v37 migration)** —
   highest impact. Added a `wiki_metadata` key-value table (schema v37
   migration). `WikiStoreModel.upgradeSearchIndex` now checks a persisted
   `link_reconcile_version` key instead of an in-memory `didReconcileLinks`
   boolean that reset every model recreation. Previously,
   `LinkReconciler.reconcileAll` ran on every wiki open — 600+ synchronous
   SQLite read+write ops per page for 300 pages. Now it runs once per
   resolver version (currently `"1"`) and the flag persists across launches.
   `getMetadata`/`setMetadata` added to `WikiStore` protocol + `SQLiteWikiStore`
   (NO_EMIT, routes through `mutate(event: { _ in nil })`).

2. **Skip 10K-row log scan when all sources are marked** (issue #477 §2).
   `reloadSources()` now short-circuits `recentLogEntries(limit: 10_000)`
   when there are no un-marked sources (the common case — every source has
   `ingested_at` stamped). Avoids materializing 10K `LogEntry` structs just
   to filter them for the legacy ingest-status fallback.

3. **Task-wrap session resolution so spinner animates** (issue #477 §3).
   `RootScene.resolveSession(for:)` now runs in a `Task` with an initial
   `Task.yield()`, so the `ProgressView("Opening wiki…")` spinner paints and
   animates before the synchronous store init + model reloads execute. With
   fixes 1+2, the remaining init is ~4 lightweight SELECTs + one system-prompt
   read — single-digit ms even for 300+ pages.

**Files (6 changed):**
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — v37 migration (`wiki_metadata`
  table), `getMetadata`/`setMetadata` methods, `createWikiMetadataTable`/
  `migrateV36ToV37` (fresh schema + stepwise ladder)
- `Sources/WikiFSCore/WikiStore.swift` — `getMetadata`/`setMetadata` on the
  protocol
- `Sources/WikiFSCore/WikiStoreModel.swift` — replaced `didReconcileLinks`
  with persisted metadata check; `reloadSources` 10K-scan guard
- `Sources/WikiFS/RootScene.swift` — `resolveSession(for:)` Task-wrapped
- `Tests/WikiFSTests/StoreEmissionExhaustivenessTests.swift` — `setMetadata`
  classified NO_EMIT
- `Tests/WikiFSTests/WikiMetadataTests.swift` (new, 7 tests)

**Gates:** `swift build` clean; fast tier 2415 tests pass; `StoreEmissionTests`
partition check passes; `FreshSchemaParityTests` v37 schema matches; 7 new
`WikiMetadataTests` pass. PR #478.

## 2026-07-16 — ACP extraction backend (#453)

**Implemented (branch `bouncy-manatee`).** Added an `.acp` extraction
backend that delegates PDF→Markdown to a user-configured ACP provider
(Claude, Gemini, Hermes, Copilot, …) instead of the hardcoded
`AnthropicExtractionClient` / `GeminiExtractionClient` HTTP clients.

- **New `ACPExtractionClient`** (`Sources/WikiFSEngine/ACPExtractionClient.swift`)
  — a `MarkdownExtractor` conformer that writes the PDF to a temp file,
  spawns an ACP session via `ACPBackend` (reusing the provider's
  `AgentProvidersConfig` + `ACPCredentialStore` Keychain key), sends the
  extraction prompt referencing the file path, and collects the markdown
  from the `AgentEvent` stream. Works with ANY ACP provider — no vendor-
  specific HTTP code, no second Keychain entry.
- **`ExtractionBackend.acp` case** — added to the enum with
  `displayName`, `helpText`, and `agentName` ("acp-extraction" for PROV).
  The old `.anthropic` / `.gemini` cases are retained for backward compat
  (existing `extraction-config.json` files decode fine).
- **`ExtractionConfig.acpProviderId`** — new optional field: the provider id
  to use for extraction. nil = use the app's default provider. Forward-
  compatible (decodes as nil from old config files).
- **`ExtractionCoordinator`** — new `acpCredentialStore` property (defaults
  to `KeychainACPCredentialStore`). The `.acp` case in `current()` resolves
  the provider via `ACPExtractionClient.resolveProvider`, falling back to
  the local extractor if no provider resolves.
- **`ExtractionSettingsView`** — new "ACP Provider" section with a provider
  picker (populated from `AgentProvidersConfig.enabledProviders`). No
  credentials to enter — the API key comes from Settings → Agents.
- **`SourceDetailView` / `QueueExtractionWorker`** — wired the `.acp`
  case into `extractorFor`, `modelVersionFor`, and the queue capacity map.
- **Tests** — 5 new tests in `ExtractionConfigTests` (round-trip, forward-
  compat decode, agent name) and 1 in `ExtractionCoordinatorTests` (falls
  back to local when no provider resolves).

## 2026-07-16 — "Worked for Xs" footer with hover-swap (branch `social-dugong`)

**Implemented.** Added a "Worked for Xs" duration footer under assistant
responses that swaps to the completion timestamp on hover — matching
Paseo's `AssistantTurnFooter` pattern.

- **Why:** Paseo renders a metadata line after each assistant turn showing
  how long the agent took ("Worked for 4s"); hovering swaps it to the
  completion time ("2:34 PM"). WikiFS had no such metadata.
- **Challenge:** `AgentEvent` has no timestamp fields — events are pure
  data (`.assistantText(String)`, etc.). The timing was tracked only at the
  launcher level (`runStartedAt`) for the whole session, not per-event.
- **What changed:**
  1. **`AgentEvent`** — moved `isInternalTranscriptEvent` from `WikiFS` to `WikiFSCore`; added `isVisibleInTranscript(in:)` + `hasAssistantText` helper.
  2. **`AgentLauncher`** — added `eventTimestamps: [Date]` parallel to `events`, tracked in lockstep across all append/replace/reset paths.
  3. **`[AgentEvent]` extension** — refactored `transcriptVisible` to use `transcriptVisibleIndices` for parallel-array filtering.
  4. **`ChatView`** — computes `displayTimestamps` from launcher (live) or `ChatMessage.createdAt` (persisted).
  5. **`ChatTranscriptView`** — `timestamps` param, `hideToolCalls` mirror filter.
  6. **`ChatWebView`** — threads timestamps through rendering; `formatDuration`/`formatTimestamp`/`workDuration`; footer HTML + CSS hover-swap.

- **Build:** `swift build` clean. **Tests:** all 2385 pass (fast tier).

## 2026-07-16 — Copy icon on assistant responses (branch `social-dugong`)

**Implemented.** Replaced the text "Copy" button on assistant chat bubbles
with a lucide `Copy` SVG icon, matching Paseo's `TurnCopyButton` pattern.

- Lucide `Copy` SVG icon (15×15, `currentColor` stroke) replaces text label.
- On click, swaps to green `Check` icon for 1.5s (Paseo parity).
- CSS: transparent bg, `--code-bg` on hover, `currentColor` tint.
- JS handler swaps `innerHTML` between copy/check SVGs.

## 2026-07-16 — macOS notifications for queue operation completion

**Implemented (branch `wizardly-horse`).** When a lint, extraction, or
ingestion operation reaches a terminal state, the app now posts a macOS local
notification (`UNUserNotificationCenter`) summarizing the outcome.

- **New `OperationNotifier`** (`Sources/WikiFS/OperationNotifier.swift`) — a
  `@MainActor` class that subscribes to `QueueEngine.events` (the same
  multicast stream that `QueueActivityTracker` and `MenuBarItemController`
  consume). On `.completed` / `.failed` events it posts a
  `UNNotificationRequest` with a computed title + body. Cancelled items are
  skipped (user-initiated, not actionable).
- **Authorization.** Calls `requestAuthorization(options: [.alert, .sound])`
  at `start()`. When the app is frontmost, notifications land silently in
  Notification Center; when backgrounded they appear as banners (the useful
  case for long-running ingest/extraction).
- **Summary logic** is extracted as `nonisolated static` pure functions:
  `operationKind(for:)` classifies extraction vs. ingestion vs. lint (with
  source/page counts, including whole-wiki lint), and `summary(for:outcome:)`
  produces the title + body. Error messages are truncated to 180 chars.
  Pluralization handled ("1 file" vs. "3 files").
- **Wiring.** Created in `WikiFSApp.startStatusItem()` alongside
  `MenuBarItemController`, held strongly on `AppDelegate.operationNotifier`
  (same retention pattern as the menu-bar controller).

**Drives off the queue engine — no new event sources.** The Queue Engine
already emits `.completed(item)` and `.failed(item, error:)` for every
extraction, ingestion, and lint item. The notifier is a passive third consumer
of the existing `QueueEventBroadcaster` multicast.

**Tests** (`Tests/WikiFSTests/OperationNotifierSummaryTests.swift`, 23 tests):
operation-kind classification, completed/failed/cancelled summaries for all
three operation types, pluralization edge cases, empty-error fallback,
long-error truncation, whole-wiki vs. specific-page lint, outcome identifiers.

**Gates:** `make build` clean; 23 new tests + 2385 existing fast-tier tests all
pass (2408 total).

## 2026-07-16 — Timestamped untitled pages + rename collision guard

**Implemented (branch `torpid-penguin`).** Two related changes to page-title
behavior:

1. **Timestamped default title.** Creating a new page with no explicit title
   (`model.newPage()` / `model.newPageInNewTab()`) now produces
   `"Untitled 2026-07-16 14:30:45"` instead of bare `"Untitled"`. This makes
   multiple new pages instantly distinguishable in the sidebar and avoids
   title collisions (which would otherwise silently duplicate-title, with
   wiki-links resolving to whichever page has the lowest ULID).
   - `WikiStoreModel.defaultUntitledTitle()` — a `public static` that formats
     `Date()` via a private `DateFormatter` (`"yyyy-MM-dd HH:mm:ss"`).
   - Default parameters on `newPage` and `newPageInNewTab` use it (can't use
     `Self.` — Swift forbids covariant `Self` in default args; explicit
     `WikiStoreModel.defaultUntitledTitle()` works).
   - Callers that pass explicit titles (Home page seeding, `wikictl`, tests)
     are unaffected.

2. **Rename collision guard.** `WikiStoreModel.rename(_:to:)` now checks
   whether another page already has the target title (case-insensitive,
   matching `resolveTitleToID` / wiki-link resolution) BEFORE writing. If a
   collision exists, the rename is blocked — the title stays unchanged, and
   `renameConflictingTitle` is set so views can show an alert.
   - `renameConflictingTitle: String?` — observable on the model; UI shows
     "Title Already Exists" alert in `PageDetailView` and `PagesContainerView`.
   - `clearRenameConflict()` — dismisses the alert state.
   - The check skips the page being renamed itself (`existingID != id`), so
     re-saving the same title is a no-op (not a false collision).
   - `WikiNameRules.sanitized` is applied before the collision check and before
     the write, so e.g. `A|B` is stored as `A-B` and compared consistently.

**Tests** (`Tests/WikiFSTests/PageTitleCollisionTests.swift`, 9 tests):
- `defaultUntitledTitleIncludesTimestamp` / `ChangesOverTime` — the formatter
  produces a parseable timestamp that differs across seconds.
- `newPageWithoutExplicitTitleGetsTimestamp` / `InNewTab` — end-to-end store
  round-trip gets a timestamped title.
- `renameToExistingTitleIsBlocked` / `CaseInsensitiveIsBlocked` — the rename
  doesn't change the title and surfaces the conflict.
- `renameToOwnTitleIsAllowed` — no false positive when renaming to the same
  title.
- `renameToUniqueTitleSucceeds` — normal renames still work.
- `clearRenameConflictResets` — the alert state is dismissible.

**Gates:** `swift build` clean; 9 new tests + 69 existing
(Navigation/EditableTitle/WikiNameRules/EditorTab) all pass.
## 2026-07-14 — Stop committing generated codegen files

`GeneratedVersion.swift` (git SHA → Swift) and `GeneratedPrompts.swift` (prompt
markdown → Swift) are now gitignored — regenerated at build time by `make
version` / `make prompts`. Previously they were checked in, causing constant
diff noise: the version file embedded the git SHA, so it drifted on every commit
(the committed snapshot always pointed at the *previous* SHA). CI now runs
`make version prompts` before `swift build` instead of gating on drift.

## 2026-07-13 — wikictl author provenance (issue #397)

**Implemented.** `wikictl page upsert` now records agent/chat provenance on
every write — `created_by`/`last_edited_by` are no longer `nil` for
agent-written pages.

- **`--author <who>` flag** on `wikictl page upsert`, threaded through
  `PageCommand.Action.upsert` → `PageUpsert.upsert(author:)` →
  `createPage(createdBy:)` / `updatePage(lastEditedBy:)`.
- **`WIKI_AUTHOR` env var** auto-applies when `--author` isn't passed (mirrors
  the existing `WIKI_WORKSPACE` injection). The launcher sets it "for free" so
  agents never have to remember: chat-driven writes get `chat:<chatID>`,
  one-shot runs get `agent:<kind>` (ingest/lint/query). Explicit `--author`
  always wins. Moved `applyEnv` from `wikictl/main.swift` into
  `ArgumentParser.applyEnv` (now `public`, testable).
- **`AgentLauncher`** injects `env.WIKI_AUTHOR` into `providerHints` at both
  spawn paths (`run` one-shot, `startInteractiveQuery` chat).

**Tests added** (105 in WikiCtlCommandTests + AgentCASTests all green):
`--author` parsing; `WIKI_AUTHOR` env routing (stamps when absent, explicit
flag wins, ignored when env empty); end-to-end provenance on create + update
(create sets both, update sets only `last_edited_by`).

**Scope notes.** Workspace writes (`--workspace`) stage to `page_versions`
without `last_edited_by` (provenance flows to `pages` on merge — deferred).
Source-ingestion provenance is out of scope (#397's "consider" item). The 9
`user_version == 36` failures in the fast tier pre-exist (schema was bumped to
36 by the chat-summary #411 commit; those test expectations weren't updated) —
unrelated to this change.

See [`plans/wikictl-author-provenance.md`](plans/wikictl-author-provenance.md).

A persistent, app-wide extraction and ingestion work queue backed by a new
`queue.sqlite` in the App Group container. Items survive relaunch, schedule
across wikis with per-provider concurrency limits, and keep running when no
window is open.
Design plan: `plans/queue-engine.md`.

**What's done:** Durable queue store with crash recovery (running items reset to
queued on launch), event-driven dispatch with per-provider concurrency limits and
per-wiki ingestion invariant (one ingest per wiki at a time), pause/resume/halt/
cancel/retry controls, a JSONL audit trail (daily-rotated, 30-day retention), and
all PDF extraction now routed through the engine. The `QueueActivityTracker`
replaces the launcher's extraction slot machinery — extraction status and control
live in the UI via the tracker, not internal launcher state.

**Phase 2 — QueueEngine actor (`WikiFSEngine`):** event-driven dispatch,
per-provider concurrency limits, per-wiki ingestion invariant, local/remote
extraction limits, pause/resume/halt/cancel/retry, write-through to `QueueStore`,
`AsyncStream<QueueEvent>`, launch rehydration. 16 tests.

**Phase 3 — QueueEventLog (`WikiFSEngine`):** JSONL audit trail. Daily-rotated
`queue-YYYY-MM-DD.jsonl` under `Logs/queue/`, 30-day bounded retention, appends
across relaunches. 16 tests.

**Phase 4 — Extraction through the queue (`WikiFSEngine`):** `QueueExtractionProvider`
protocol bridges `@MainActor ExtractionCoordinator` into the headless engine.
`QueueExtractionWorker` calls `resolveExtraction` → `readiness()` → `convert()` →
`persistExtraction`. `QueueIngestSignaling` protocol for `isIngestInProgress` timing
(issue #235). `waitForCompletion(of:)` on the engine for inline-caller awaits.
`.progress` event for live extraction log. 13 tests.

**Files (1 new + 1 test):**
- `Sources/WikiFSEngine/QueueEventLog.swift` (new)
- `Tests/WikiFSTests/QueueEventLogTests.swift` (new, 16 tests)

## 2026-07-13 — Queue Engine Phase 2: QueueEngine actor

**Phase 2 is implemented.** The design plan lives at
`docs/design-plans/2026-07-13-queue-engine.md`. This phase adds the
`QueueEngine` actor — the scheduling engine with write-through persistence,
event-driven dispatch, per-provider concurrency limits, per-wiki ingestion
invariant, pause/resume/halt/cancel/retry, and an `AsyncStream<QueueEvent>`
for UI observation. Still no app-layer wiring (that's Phase 4+); the engine
is fully testable with fake workers.

**New types (all in `Sources/WikiFSEngine/`):**
- **`QueueEngine`** (`QueueEngine.swift`) — an `actor` that owns all scheduling.
  Every state change writes through to `QueueStore` before emitting a
  `QueueEvent`. Event-driven dispatch (no polling): `enqueue`, item finish,
  `resume`, `retryItem` all trigger `dispatchScan()`. Worker `Task`s are
  spawned detached so the engine never blocks on a worker.
- **`QueueWorker.swift`** — supporting types:
  - `QueueWorker` protocol — `execute(_:)` runs one item.
  - `QueueWorkerFactory` protocol — resolves a provider ID (capacity check) and
    produces a worker (execution). Split so the engine checks capacity without
    committing a worker.
  - `QueueEvent` enum — `.enqueued`/`.started`/`.completed`/`.failed`/
    `.cancelled`/`.runStateChanged`. `Sendable` for crossing actor boundaries.
  - `QueueSnapshot` struct — point-in-time state for UI bootstrap (active
    items, recent items, run states, provider counts, active ingestion wikis).
  - `QueueEngineConfig` struct — capacity limits: per-provider ingestion limits,
    local extraction limit (default 1), remote extraction limit (default 2).

**Modified (in `Sources/WikiFSCore/`):**
- **`AgentProvidersConfig`** — added `maxConcurrent: [String: Int]` field for
  per-provider ingestion limits. Forward-compatible (old files decode to `[:]`);
  all internal constructor calls carry it over.

**Tests** (`Tests/WikiFSTests/QueueEngineTests.swift`): 16 tests with fake
workers, all pass in 0.77s. Covers:
- Dispatch order (ordering-key / FIFO)
- Per-provider concurrency limit (at max, blocks)
- Different providers run concurrently
- Per-wiki ingestion invariant (at most 1 per wiki)
- Local extraction serialized (limit 1)
- Pause stops new dispatch; resume restarts
- Pause state persists across reopen
- Halt cancels in-flight items (requeue preserves ordering key)
- Failed item records error, frees slot, doesn't block later items
- Retry re-enqueues with attempt + 1
- Enqueue returns immediately (UI never awaits slots)
- Items from multiple wikis in one shared queue
- Crash recovery / rehydration (running → queued on launch)
- Event stream emits enqueued/started/completed
- Snapshot reflects engine state
- Cancel queued item

Also updated `QueueStoreTests.testNoExternalReferencesToQueueStore` to only
scan `Sources/WikiFS/` (the app layer) — `WikiFSEngine` now legitimately
references queue types (Phase 2). The guard now also checks for `QueueEngine`,
`QueueEvent`, `QueueSnapshot`.

**Acceptance criteria covered:**
- AC2.1 (multi-wiki items in one queue) ✓
- AC2.2 (dispatch in ordering-key order) ✓
- AC2.5 (crash recovery rehydration) ✓ (from Phase 1, re-verified for engine)
- AC3.1 (different providers run concurrently) ✓
- AC3.2 (provider at max blocks) ✓
- AC3.3 (at most one ingestion per wiki) ✓
- AC3.4 (local pdf2md serialized) ✓
- AC3.5 (pause/resume persists) ✓
- AC3.6 (halt cancels in-flight) ✓
- AC3.7 (failed item records error, frees slot, retry) ✓
- AC4.1 (enqueue returns immediately) ✓

**Files (2 new + 1 modified + 1 test + 1 test modified):**
- `Sources/WikiFSEngine/QueueEngine.swift` (new)
- `Sources/WikiFSEngine/QueueWorker.swift` (new)
- `Sources/WikiFSCore/AgentProvidersConfig.swift` (modified — `maxConcurrent`)
- `Tests/WikiFSTests/QueueEngineTests.swift` (new, 16 tests)
- `Tests/WikiFSTests/QueueStoreTests.swift` (modified — source-scan scope)

## 2026-07-13 — Queue Engine Phase 1: Queue data model and store

**Phase 1 is implemented.** The design plan lives at
`docs/design-plans/2026-07-13-queue-engine.md`. This phase adds the persistent
`QueueStore` and its value types to `WikiFSCore` with **no behavior change** —
nothing in `WikiFSEngine` or `WikiFS` references it yet. It is the dependency-
free foundation for the `QueueEngine` actor (Phase 2).

**New types (all in `Sources/WikiFSCore/`):**
- **`QueueStore`** (`QueueStore.swift`) — persistent, durable store for the
  extraction/ingestion work queue. Owns one serial SQLite connection
  (`queue.sqlite`) with the same concurrency discipline as `SQLiteWikiStore`:
  method-atomic `NSRecursiveLock`, statement cache, WAL + busy_timeout, versioned
  idempotent migrations (`PRAGMA user_version`), `withTransaction` savepoint
  nesting (never raw `BEGIN`), `#if DEBUG assertNoBusyStatements()` guard, and
  checkpoint-and-close deinit. No `ResourceChangeEvent` emission (not a
  `WikiStore`).
- **`QueueTypes.swift`** — `QueueKind` (extraction/ingestion), `QueueItemState`
  (queued/running/completed/failed/cancelled), `QueueRunState` (running/paused),
  `QueueItemPayload` (JSON-encoded `sourceIDs` + `stageRouting` + `chainedItemID`),
  `QueueItem` (the durable row, `Codable + Sendable + Identifiable`),
  `QueueItemRequest` (caller-facing enqueue request).
- **`QueueStoreError`** — dedicated error enum (`.open`, `.sqlite(code:message:)`,
  `.notFound(QueueItem.ID)`, `.invalidStateTransition(from:to:)`). Does NOT reuse
  `WikiStoreError` (different `notFound` semantics). `WikiStoreError.sqlite`
  from `SQLiteStatement` is caught and rewrapped via a private `rewrap` helper.

**API surface:**
- `enqueue(_:)` → `QueueItem` (ULID ID, next ordering key = max + 1000)
- `getItem(_:)` → `QueueItem?`
- State transitions: `markRunning`, `markCompleted`, `markFailed`,
  `markCancelled`, `requeue`, `retryItem` (each guarded by a state-transition
  table; invalid transitions throw)
- Queries: `loadActive(for:)` (non-terminal, by ordering_key), `loadRecent(limit:)`
  (terminal, newest-first)
- Crash recovery: `resetRunningToQueued()` → `Int` (resets `.running` → `.queued`,
  attempt preserved)
- Queue run state: `queueRunState(for:)`, `setQueueRunState(_:_:)` (persisted)
- Maintenance: `pruneHistory(maxPerQueue:)` (keeps newest 200 terminal per queue)

**One method added to `DatabaseLocation`:**
- `queueDatabaseURL()` — returns `…/<appGroup>/queue.sqlite`

**Tests** (`Tests/WikiFSTests/QueueStoreTests.swift`): 20 tests, all pass in
0.14s. Covers durability (enqueue/state/run-state across reopen), crash recovery
(running→queued, attempt intact), pruning (250 completed → ≤200, queued
untouched), headless source-scan (no AppKit/SwiftUI imports), no-external-
references source-scan (WikiFSEngine/WikiFS don't reference queue types), ordering
key assignment, all state transitions + invalid-transition throws, retry (new
ordering key), requeue (preserves ordering key), loadActive/loadRecent filtering,
and resetRunningToQueued count. Not tagged `.integration` — fast enough for the
CI fast tier.

**Acceptance criteria met:**
- AC.1 (durability) ✓ — 3 reopen tests
- AC.2 (crash recovery) ✓ — `testRunningItemsResetToQueuedOnLaunch`
- AC.3 (pruning) ✓ — `testHistoryPruningBeyondBound`
- AC.4 (no behavior change) ✓ — `testNoExternalReferencesToQueueStore` + clean build
- AC.5 (headless isolation) ✓ — `testQueueStoreFilesAreHeadless` (source-scan)

**Implementation review:** Dispatched a `general-purpose` subagent to review
against sqlite-concurrency discipline, SQLiteWikiStore pattern fidelity, headless
imports, Swift Testing conventions, and Sendable correctness. No CRITICAL issues.
Two MEDIUM findings fixed:
1. `WikiStoreError` was leaking through `SQLiteStatement` calls — fixed via a
   `rewrap` helper that catches and rewraps to `QueueStoreError.sqlite`.
2. `markRunning`/`retryItem` left stale `finished_at` on non-terminal items —
   fixed by clearing `finished_at = NULL` (and `error = NULL` for `markRunning`)
   in both transitions. Also added `migrate(from:)` stub (LOW-1) for future-
   proofing the migration ladder.

**Files (4 new + 1 modified + 1 test):**
- `Sources/WikiFSCore/QueueTypes.swift` (new)
- `Sources/WikiFSCore/QueueStore.swift` (new)
- `Sources/WikiFSCore/DatabaseLocation.swift` (modified — added `queueDatabaseURL()`)
- `Tests/WikiFSTests/QueueStoreTests.swift` (new)
- `PLAN.md` (doc index updated)
**Phase 7 — sidebar removal:** Deleted `AgentActivitySidebar`, `AgentRunBanner`,
and `PdfExtractionView` — their duties are now served by the menu-bar popover
(queue state + controls), the `QueueActivityTracker` (source row status), and
`ChatView`'s inline stop control. `LintView` now shows the agent transcript
inline instead of in a sidebar. The transcript toggle toolbar button and
`isTranscriptExpanded` state are removed from `ContentView`.

## 2026-07-13 — Chat Summary (issue #411)

**Implemented.** The sidebar's `RecentChatRow` now shows a one-line summary of
the model's first response under the chat title. The summary is generated once
on chat completion (`AgentLauncher.finish()`) and persisted to SQLite
(`chats.summary` + `chats.summary_at`, schema v36), so it's available
immediately when the history list loads — no recomputation on app launch.

**v0 strategy: deterministic first-sentence extract** (no LLM call). The
schema and rendering are designed so an LLM-based summarizer can be layered on
later without further migrations.

**What changed:**
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — schema migration v35→v36
  (`migrateV35ToV36`), `createChatTablesV23` columns, `createFreshSchemaV20`
  version stamp, `listChats` / `listAllChatsOrderedByID` SELECT update (NULL-
  safe reads), new `updateChatSummary` mutator (routes through `mutate()`).
- `Sources/WikiFSCore/WikiStore.swift` — `updateChatSummary` on the protocol.
- `Sources/WikiFSCore/ChatModels.swift` — `summary`/`summaryAt` fields on
  `ChatSummary`, `summaryExtract(from:maxLength:)` pure function.
- `Sources/WikiFSCore/WikiStoreModel.swift` — `updateChatSummary` wrapper.
- `Sources/WikiFSEngine/AgentLauncher.swift` — `summarySink` property,
  `onSummary` parameter on `startInteractiveQuery`, `firstSummaryText(from:)`
  static function, `generateChatSummary()` method called in `finish()`.
- `Sources/WikiFSEngine/AgentOperationRunner.swift` — wired `onSummary` at both
  `startInteractiveQuery` call sites.
- `Sources/WikiFS/AgentToolsView.swift` — `RecentChatRow` shows summary caption
  when `!isLive`.
- Tests: `ChatSummaryTests.swift` (13 tests: pure extract, static event
  selection, store round-trip, NULL handling, updatedAt bump).

## 2026-07-13 — Multi-window UI — per-wiki windows (Phase 2b of #358)

**Multi-window is implemented.** The plan lives at
`plans/multi-window-ui.md`. Users can now open multiple wiki windows
simultaneously, each with its own `WikiSession` — a long ingest in wiki A's
window does not block a query in wiki B's window. Two windows over the SAME
wiki share one session (one store, one bus, one gate).

**New types:**
- **`SessionManager`** (`Sources/WikiFSEngine/SessionManager.swift`) —
  `@MainActor @Observable`. Owns the `[wikiID: WikiSession]` cache.
  `session(for:descriptor:)` is create-or-get (same wiki ID returns the
  existing session). `releaseSession(for:)` flushes + removes.
  `flushAllSessions()` flushes all active. `frontmostWikiID` /
  `frontmostSession` for `VacuumCommands` resolution.
- **`RootScene`** (`Sources/WikiFS/RootScene.swift`) — per-window entry
  point. Receives `wikiID: String?`, resolves the session via
  `sessionManager`, owns per-window `scenePhase` (flush-on-background +
  search-index backfill), vacuum alert, and `.onDisappear` session release.

**What changed:**
- `@State session` + `SessionRef` → `@State sessionManager: SessionManager`
- `WindowGroup { RootView(session:) }` → two WindowGroups: single-identity
  main (launch + MRU wiki) + `WindowGroup(for: String.self)` (additional
  wiki windows). Both use `RootScene`.
- `.onChange(of: registry.activeWikiID)` session creation → moved into
  `RootScene` (per-window via `resolveSession(for:)`).
- `.onChange(of: scenePhase)` + vacuum `.alert` → moved into `RootScene`.
- `WikiChangeBridge`: `weak var session` → `var sessionLookup` closure.
  `flush(wikiID:)` pokes all matching sessions' buses.
- `FileProviderSpike`: `subscribeActiveStoreBus` (single) →
  `subscribeBus(for:bus:)` + `unsubscribeBus(for:)` (multi-dict).
- `WikiSwitcher`: `registry.select(id)` → `openWindow(value: id)` default,
  `registry.select(id)` Option+click (in-window switch).
- `VacuumCommands`: `session: WikiSession?` → `sessionManager` (resolves
  `frontmostSession`).
- `ExtractionCompareContext` gained `wikiID` field (so the compare window
  resolves the correct session). `ExtractionCompareWindow` takes
  `sessionManager` instead of `session`.
- `WikiRegistryClient.flushActiveStore` signature: `(() -> Void)?` →
  `((String) -> Void)?` (passes the wiki ID being exported/deleted).
- `RootView.session`: `WikiSession?` → `WikiSession` (non-optional;

**Files changed (13 total):**
- 3 new: `SessionManager.swift`, `RootScene.swift`, `SessionManagerTests.swift`
- 10 modified: `WikiFSApp`, `RootView`, `WikiSwitcher`, `WikiChangeBridge`,
  `ExtractionCompareSheet`, `FileProviderSpike`, `VacuumCommands`,
  `SourceDetailView`, `WikiRegistryClient`, `FPIfSubscriberDebounceTests`
- Tests: `SessionManagerTests` (9 tests) + updated `WikiChangeBridgeTests`
  (4 tests). All pass. `swift build` clean, fast-tier (2305 tests) green.

**What does NOT change:** the daemon, the File Provider extension, `wikictl`
store writes, Darwin notification routing, SQLite concurrency invariants,
agent config, `ExtractionCoordinator`, `settingsLauncher`, `WikiSession`
itself, `WikiRegistryClient` (except the `flushActiveStore` signature).

## 2026-07-13 — Dissolve `WikiManager` into `WikiRegistryClient` + `WikiSession` (Phase 2a of #358)

**The type split is implemented.** The plan lives at
`plans/dissolve-wikimanager.md`. `WikiManager` (app-scoped monolith bundling
registry + active store + side effects) is dissolved into two focused types:

- **`WikiRegistryClient`** (`Sources/WikiFSCore/WikiRegistryClient.swift`) —
  app-scoped, `@MainActor @Observable`. Owns the wiki list (`wikis`), the
  active wiki id (`activeWikiID`), and the create/select/delete/rename/
  export/import operations. Never opens a store itself (no `activeStore`,
  no `openActive`). FP domain closures (`registerDomain`/`removeDomain`/
  `renameDomain`) + a `flushActiveStore` closure are injected from the app
  layer. `WikiManagerError` → `WikiRegistryError` (moved into the same file).
- **`WikiSession`** (`Sources/WikiFSEngine/WikiSession.swift`) — per-active-wiki,
  `@MainActor @Observable`. Holds the store (`WikiStoreModel`), per-session
  `AgentLauncher` pair, per-session `GenerationGate`, shared
  `ExtractionCoordinator` ref, and the vacuum/GC + search-upgrade state.
  `init` does what `WikiManager.openActive` did (open store, attach bus,
  create model, create read pool, create launchers, seed Home page). Each
  session has its own gate → structural per-wiki isolation (a long ingest in
  one wiki cannot block a query in another).

**What moved where:**
- `wikis`/`activeWikiID` → `WikiRegistryClient`
- `activeStore` → `WikiSession.store`
- `pendingBlobVacuum`/`pendingVacuumAll` → `WikiSession`
- `upgradeActiveStoreSearchIndex` → `WikiSession.upgradeSearchIndex()`
- `openActive` → `WikiSession.init` (called from the app's `.onChange(of:
  registry.activeWikiID)`)
- v0 migration, FP domain closures, `registerAllDomains` → `WikiRegistryClient`
- `WikiManagerError` → `WikiRegistryError`

**Files changed (21 total):**
- 2 new: `WikiRegistryClient.swift`, `WikiSession.swift`
- 2 deleted: `WikiManager.swift`, `WikiManagerError.swift`
- 17 modified: `WikiFSApp`, `RootView`, `ContentView`, `SidebarView`,
  `WikiSwitcher`, `WikiDetailView`, `PageDetailView`, `ChatView`, `LintView`,
  `SourcesContainerView`, `SourcesListView`, `PagesContainerView`,
  `PagesListView`, `ExtractionCompareSheet`, `VacuumCommands`,
  `WikiChangeBridge`, `WikiStoreModel`
- Tests: `WikiManagerTests` → `WikiRegistryClientTests` (17 tests) +
  `WikiSessionTests` (7 tests) + `WikiChangeBridgeTests` (2 tests). All 26 pass.

**What does NOT change:** the daemon (`wikid`), the File Provider extension,
`wikictl` store writes, Darwin notification routing, the SQLite concurrency
invariants, agent config, the single `WindowGroup` (multi-window is Phase 2b).

## 2026-07-12 — wikid XPC daemon + WikiFSEngine extraction (Phase 1 of #358)

**All three phases of the multi-wiki daemon plan are implemented.** The design
doc lives at `plans/multi-wiki-daemon.md`; the architecture-roadmap §4 fork is
resolved (daemon-first path chosen).

**Phase 1A: WikiFSEngine extraction (PR #369, merged).** Extracted the agent
execution engine out of the app target into a new `WikiFSEngine` library. Both
the app and the future daemon link it. 14 files moved
(`Sources/WikiFS/` → `Sources/WikiFSEngine/`): `AgentLauncher`, `ACPBackend`,
`ClaudeCLIBackend`, `AgentOperationRunner`, `GenerationGate`,
`ExtractionCoordinator`, `AgentBackend`/`Factory`, `OperationRequest`,
`ACPPermissions`, `PermissionResolving`, `NotificationFanout`,
`TurnLivenessPolicy`, `ACPAuthResolver`. Protocol seams introduced
(`EngineProtocols.swift`): `ChangeSignaler` (abstracts `FileProviderSpike`),
`UnavailablePdf2MarkdownExtractor` (placeholder for the
`localExtractorFactory` injection). `AgentOperationRunner` signatures changed:
`manager: WikiManager` → `wikiID: String`, `fileProvider: FileProviderSpike` →
`changeSignaler: any ChangeSignaler`, `HelpersLocation.wikictlDirectory` →
`wikictlDirectory: String` (injected). `ExtractionCoordinator`+`AgentLauncher`
gained factory closures for `PdfExtractionService`/`LocalPdf2MarkdownExtractor`
(which stay in the app target — AppKit-coupled). `FileProviderSpike` conforms to
`ChangeSignaler`. All 8 app call sites updated. Fast tier: 2354 tests pass.

**Phase 1B: wikid XPC daemon (PR #370, merged).** New `wikid` executable target
linking `WikiFSCore`. `WikiDaemonProtocol` (`@objc`, JSON-in-`Data` transport)
in `WikiFSCore` — shared by daemon + clients. `WikiDaemon` holds live
`WikiRegistry` in-memory (not load-mutate-save per op), holds open
`SQLiteWikiStore` instances (Sendable, method-atomic), serializes mutations on a
`DispatchQueue`, seeds a Home page on `createWiki`. `main.swift`:
`NSXPCListener(machServiceName:)` + `RunLoop.current.run()`. launchd plist
(`signing/com.selfdrivingwiki.wikid.plist`) with `MachServices`, `RunAtLoad`,
`KeepAlive`, `IdleTimeout=300s`. Makefile targets: `install-daemon` /
`uninstall-daemon` / `daemon-status`.

**Phase 1C: wikictl as first XPC client (PR #370, merged).**
`WikiDaemonConnection` (in `WikiCtlCore`) — thin async XPC client,
JSON encode/decode of `WikiDescriptor` over `Data`. `wikictl main.swift`:
`run()` is now async; wiki resolution tries the daemon first, falls back to
direct `WikiResolver` if the daemon isn't running (graceful degradation). Four
new `wikictl wiki` subcommands: `list` / `create --name` / `delete --id` /
`rename --id --name`, all routed through the daemon via XPC. Store writes still
direct (`SQLiteWikiStore`) — "sole writer" deferred to Phase 2+ (decision D4).

**What does NOT change:** the app stays in-process (`WikiManager` untouched);
the File Provider extension reads SQLite directly; store writes from `wikictl`
open their own `SQLiteWikiStore` (WAL + method-atomic store handles
multi-writer); Darwin notification routing unchanged; all SQLite concurrency
invariants preserved (`mutate()` write-seam, `StoreEmissionExhaustivenessTests`,
`WikiReadPool` read-only connections).
## 2026-07-12 — ACP Multi-Provider: Phase 4 (legacy deletion)

**What shipped.** Phase 4 of `plans/acp-multi-provider.md` — the app is now
ACP-only. All legacy Claude-CLI code paths, config types, and settings UI were
deleted. This completes the 4-phase plan (Phases 1–3 shipped in commit
`50d1c0f`).

**Deleted (12 files, ~3585 lines of source + tests):**
- `Sources/WikiFSEngine/ClaudeCLIBackend.swift` — the `claude -p` stream-json
  backend. `AgentBackendFactory.makeBackend` now always returns `ACPBackend`.
- `Sources/WikiFSCore/AgentCommandConfig.swift` — `agent-command-config.json`
  (executable, prefix-args, model override, extra env). The tokenizer + tilde-
  expansion helpers were extracted to `ShellArgv.swift` (both call sites in
  `AgentBackendFactory.providerHints` and `AgentLauncher` still need them).
- `Sources/WikiFSCore/ACPAgentConfig.swift` — `acp-agent-config.json`
  (dead wiring kept for old tests; the real path was always
  `AgentProvidersConfig`).
- `Sources/WikiFSCore/OperationCommand.swift` — the pure-argv assembly type
  (`OperationCommand.build`). With the CLI backend gone, spawn argv is built
  directly in `AgentLauncher` from `AgentSpawnConfig`.
- `Sources/WikiFSCore/ClaudePromptHelp.swift` + `ClaudePromptHelpDocument.swift`
  + 3 view files (`ClaudePromptHelpView`, `ClaudePromptHelpCommands`,
  `PromptHelpSectionView`) — the in-app Claude prompt debugger/help feature.
- `Sources/WikiFS/AgentCommandSettingsView.swift` +
  `AgentProvidersSettingsView.swift` — the old Agent + Providers settings tabs
  (replaced by the unified `AgentsSettingsView` in Phase 3).
- Tests: `ACPConfigTests`, `AgentCommandConfigTests`, `ClaudePromptHelpTests`,
  `OperationCommandTests`, `SandboxedOperationCommandTests`.

**New file:**
- `Sources/WikiFSCore/ShellArgv.swift` — `tokenize(_:)` (shell-style argv
  splitting, no shell invoked) + `expandTilde(_:)`. Extracted from
  `AgentCommandConfig` since `AgentBackendFactory.providerHints` and
  `AgentLauncher`'s ACP spawn resolution still need both transforms,
  independent of the deleted CLI config type.

**Key model changes:**
- `AgentProvider.backend` field (`.claudeCLI` / `.acp`) removed — all providers
  are ACP. The old `claudeDefault` (id `"claude"`, CLI, no command) was replaced
  by `claudeAcpDefault` (`bun x @agentclientprotocol/claude-agent-acp`).
- `AgentProvidersConfig` no longer injects `claudeCachedModels` (`["opus",
  "sonnet", "haiku"]`) — model lists always come from ACP discovery.
- `IngestPlan` stripped of opus/sonnet tiering (`topLevelModelAlias`,
  `agentsJSON`, `digesterPrompt`) — it is now a pure source-size predicate.
  Which provider/model runs each stage is resolved separately via
  `AgentProvidersConfig.resolvedProvider(for:)`.
- `AgentBackendFactory.makeBackend(useACPBackend:policy:)` →
  `makeBackend(policy:)` — no more `useACPBackend` UserDefaults toggle.
- `AgentBackendFactory.providerHints` removed the `.claudeCLI` branch.

**Gates:** `swift build` clean; fast tier **2268 tests in 190 suites pass**.
All remaining references to deleted types are in doc comments documenting the
old architecture — no functional code references remain.

## 2026-07-12 — Git SHA versioning scheme

Replaced the `0.0.0-dev` placeholder versioning with a git-derived scheme so
every build is uniquely identifiable. The old scheme resolved `VERSION` from a
tag or `VERSION` file, fell back to `0.0.0-dev`, and wrote the same value into
both `CFBundleShortVersionString` and `CFBundleVersion` — no SHA, no commit
count, every dev build indistinguishable.

**Version scheme:** `CFBundleShortVersionString` = SemVer (tag/`VERSION`
file/`0.0.0`), `CFBundleVersion` = `<commit-count>-<short-sha>` (e.g.
`487-d440699`). Monotone integer for Apple's build-number expectations, SHA
baked in for traceability.

**Two codegen paths:**
1. `tools/versiongen/main.swift` → `Sources/WikiFSCore/GeneratedVersion.swift`
   (checked-in Swift constants: `appVersion`, `gitSHA`, `gitCommitCount`,
   `buildVersion`, `fullVersionString`). Mirrors the `promptgen` pattern:
   `make version` regenerates; `make check-version-gen` is the CI drift gate;
   the generator only writes when content changes (no spurious recompiles).
2. `build.sh` resolves `VERSION` + `BUILD_VERSION` + `GIT_SHA` +
   `GIT_COMMIT_COUNT` and writes them into both Info.plists (app + appex),
   including custom `WIKIGitSHA` / `WIKIGitCommitCount` / `WIKIBuildVersion`
   keys for runtime query.

**Makefile:** `version` and `check-version-gen` targets added; `build`,
`check`, `test`, `release` now depend on `version`. `print-version` enhanced
to show SHA + commit count + build version.

**wikictl:** `version` / `--version` / `-v` subcommand prints build info (plain
text or `--json`). Intercepted before wiki selector requirement — no `--wiki`
needed. Added `.version(json:)` to `ArgumentParser.Command`.

**App:** `ACPBackend` now sends `GeneratedVersion.appVersion` as the ACP client
version (was hardcoded `"1.0.0"`). New `AboutView` added as the first Settings
tab showing app icon, name, version, build, git SHA, and commit count.

**Files changed:**
- `tools/versiongen/main.swift` (new — 120 lines)
- `Sources/WikiFSCore/GeneratedVersion.swift` (new — generated)
- `Sources/WikiCtlCore/ArgumentParser.swift` (`.version` case, parse intercept, usage text)
- `Sources/wikictl/main.swift` (version print + exhaustive switch case)
- `Sources/WikiFS/ACPBackend.swift` (hardcoded `"1.0.0"` → `GeneratedVersion.appVersion`)
- `Sources/WikiFS/AboutView.swift` (new)
- `Sources/WikiFS/WikiFSApp.swift` (About tab in Settings TabView)
- `Makefile` (versiongen variables, targets, prerequisites, help, print-version)
- `build.sh` (BUILD_VERSION, GIT_SHA, GIT_COMMIT_COUNT, Info.plist keys)
- `PLAN.md` (Versioning section)

**Gates:** 2354 tests pass (fast tier). `make check-version-gen` passes. `make
version` + `make print-version` work. `wikictl version` / `--version` / `-v` /
`version --json` all produce correct output. `swift build` clean.

## 2026-07-12 — Hardening Feedback Fixes (Fable Review)

Addressed 3 failing tests + 2 latent Phase-7 defects from the Fable review of
the multi-writer hardening commit (`de539d7`).

**3 failing tests (all CI-skipped `SQLiteWikiStoreTests`):**
1. `changeTokenAdvancesOnEveryMutation` — test expected `refsGenSum` unchanged
   after `deletePage`, but the hardening commit correctly cascades the page's
   `page-content` ref on delete. Fixed the test literal + comment.
2. `migrateV28ToV29RewritesAskChatsToEdit` — v29→v30 refs rebuild queried a
   `refs` table absent from the chats-only fixture. Added table-existence guard
   (create fresh if missing), matching the v30 `hasPages` convention.
3. `migrateV19ToV20_hashesContentIntoBlobsAndDropsContentColumn` — v32→v33's
   `tableColumnInfo("pages")` and v33→v34's backfill against a sources-only
   fixture. Added `sqlite_master` existence guards on both steps.

**Latent defect 1 (Phase 7): `workspaceWritePage` status guard.** Writes to a
`merged`/`conflicted`/`abandoned` workspace succeeded silently. Added a
`status == 'open'` guard (one query) at the top of the transaction. Two tests
added to `WorkspaceStagingTests`.

**Latent defect 2 (Phase 7): `WIKI_WORKSPACE` global `setenv`.** The env var
was process-global, leaking to chat-edit agents spawned mid-ingest via the
interactive lane. Replaced `setenv`/`unsetenv` in `AgentOperationRunner` with
per-spawn environment injection: `workspaceID` threaded through
`AgentLauncher.run()` → `providerHints["env.WIKI_WORKSPACE"]` →
`ACPBackend.start` (already handled `env.*` prefix) +
`ClaudeCLIBackend.start` (added `env.*` expansion). `OperationCommand.environment`
changed `let` → `var` to enable post-construction injection. This also fixes
the cancelled-while-queued stale-env-var case (no global state to leave stale).

All 55 `SQLiteWikiStoreTests` + `WorkspaceStagingTests` pass. Full fast-tier
CI (2349 tests) passes.

## 2026-07-12 — Multi-Writer Hardening: All 7 Phases Complete

**All 7 phases of the multi-writer hardening plan are implemented.** The
design doc lives at `docs/design-plans/2026-07-12-multi-writer-hardening.md`;
the implementation plan is at `plans/multi-writer-hardening.md`.

**Phase 0 (hotfix):** Fixed `vacuum-blobs --apply` data-loss bug —
`orphanBlobPredicate` was missing `page_versions.blob_hash`, deleting live
page-history blobs.

**Phase 1: Agent CAS writes.** `page get --json` outputs
`head_version_id`; `page upsert --expect-head <ver>` CAS-protects writes
(exit code 3 on conflict). Agent prompts updated with read→expect→retry-once
discipline. Blind upsert behavior preserved.

**Phase 2: Lane-aware generation gate.** `GenerationGate` split into
`.ingest` (limit 1) and `.interactive` (limit 3) lanes — a long ingest no
longer blocks chat. Cancellation safety preserved per-lane.

**Phase 3: Head-ref invariant (v34).** Every page now has an explicit
`page-content` ref from birth (`createPage` seeds root version + ref).
v34 migration backfills refs for existing pages, seeding root versions
where needed. MAX(id) fallback demoted to logged assertion.

**Phase 4: Autosave amend + version GC.** Same-actor saves within 5s
coalesce via amend (no new version row). `vacuumPageVersions` deletes
unreachable versions. Also fixed `orphanActivityPredicate` (missing
`page_versions.activity_id` edge).

**Phase 5: Workspace created-page staging (v35).** `workspace_refs`
rebuilt with nullable `version_id` + `blob_hash` + `title`. Created pages
stage as blob+title (no phantom `pages` row, no changeToken movement,
no abandon residue). Merge mints the `pages` row + root version.

**Phase 6: Merge completeness.** `workspaceMerge` returns merged page IDs
for post-merge re-embedding. Wiki-index line-set three-way merge using
`Diff3`. Ingest-completion log entry appended after successful merge.

**Phase 7: Ingest isolation behind flag.** `--workspace W` on `page
upsert`/`page get`/`index set`; `WIKI_WORKSPACE` env var for the agent
subprocess. `workspacesEnabled` flag (default off).
`reapStaleWorkspaces` on app launch (24h TTL).

## 2026-07-11 — W4: Concurrency at scale (PR #312)

**What shipped.** Phase W4 (final) of the multi-writer concurrency plan:
configurable N-throttle + workspace reaper.

**Configurable N-throttle** (`GenerationGate`):
- `maxConcurrent` parameter (default 1, backward-compatible). When N > 1,
  up to N generations run simultaneously. This is a resource-management
  concern, not a correctness concern (workspaces handle correctness).
- Replaced the single-slot `held` bool with `activeCount` + `maxConcurrent`.
  `acquire()` checks `activeCount < maxConcurrent`; `release()` decrements
  `activeCount` on no-waiter path, hands off (keeps count) on waiter path.

**Workspace reaper** (`SQLiteWikiStore` + `WikiStore` protocol):
- `reapStaleWorkspaces(ttl:)` — mark any workspace with status `open`
  whose `updated_at` is older than the TTL as `abandoned` (crashed/abandoned
  runs). Deletes workspace_refs + workspace_conflicts for each reaped ws.
  Returns the count reaped.
- `wikictl workspace reap [--ttl <seconds>]` (default 3600s).

**Tests:** 3 `GenerationGateThrottleTests` (single-slot blocks, two-slot
allows concurrent, release frees for waiter) + 2 new `WorkspaceTests`
(reap abandons stale, reap doesn't touch active). Fast tier: 2189 tests.

**What's deferred (stretch goals):** Read-set PROV recording + "cites
since-changed content" lint, merge-queue fairness (rebase-don't-abort),
SwiftUI conflict-review panel, edit lock retirement behind capability flag
in `AgentOperationRunner`, `wiki_index` line-set merge (D12),
slug-collision unification (D13). The core multi-writer concurrency arc
(W0–W4) is complete.

## 2026-07-11 — W3: Conflict resolution & review (PR #312)

**What shipped.** Phase W3 of the multi-writer concurrency plan: parked
conflicts are now persisted, queryable, and resolvable.

**Schema v32:**
- `workspace_conflicts` table (workspace_id, page_id, base_version_id,
  main_version_id, ws_version_id, created_at). When `workspaceMerge` or
  `workspaceRefresh` parks as `conflicted`, the per-page conflict details
  are persisted so they can be queried and resolved.

**Store layer** (`SQLiteWikiStore` + `WikiStore` protocol):
- `workspaceConflicts(workspaceID:)` — query persisted conflict details.
- `workspaceResolveConflict(workspaceID:pageID:body:)` — write a resolved
  body as a new workspace version + update the workspace_ref's
  `base_version_id` to current main head (so retry merge sees no
  divergence) + delete the conflict row.
- `workspaceRetryMerge(workspaceID:)` — set status back to `open`,
  then call `workspaceMerge` again. If all conflicts were resolved,
  the merge succeeds; if some remain, it parks again.

New type: `WorkspaceConflict`.

**wikictl:**
- `workspace conflicts --id W` — list per-page conflict details.
- `workspace resolve --id W --page P --body-file <path|->` — resolve.
- `workspace retry --id W` — re-open + re-merge.

**Tests:** 17 `WorkspaceTests` (3 new: conflicts persisted/queryable,
resolve+retry succeeds, second workspace merges while first parked).
Fast tier: 2184 tests pass.

**What's deferred:** Edit lock retirement behind capability flag,
`wiki_index` line-set merge (D12), slug-collision unification (D13),
workspace TTL/reaper (W4), SwiftUI conflict-review panel.

## 2026-07-11 — W2: Real merge (diff3) (PR #312)

**What shipped.** Phase W2 of the multi-writer concurrency plan: real diff3
three-way merge. When `main_head != base`, `workspaceMerge` now does a diff3
merge instead of parking (W1's behavior). Plus a refresh/rebase verb.

**Diff3 engine** (`Diff3.swift`):
- Line-based three-way merge. Input: base, ours (main), theirs (workspace).
- Output: `.clean(merged)` or `.conflict`.
- Finds common lines across all three sequences as split points, then
  classifies the gaps between them. When both sides changed a gap
  differently, uses `interleavedMerge` — recursively splits using common
  lines (including base↔ours and base↔theirs anchors) to interleave
  non-overlapping changes to adjacent lines.
- Pure, Sendable, unit-testable. 9 `Diff3Tests`.

**Store layer** (`SQLiteWikiStore`):
- `workspaceMerge` — when `main_head != base`, calls `diff3MergePage`:
  fetch three blobs, run `Diff3.merge`. Clean → merge version
  (`parent_id = main_head`, `merge_parent_id = workspace version`) with
  PROV activity (`kind='merge'`), updates pages mirror + main ref,
  regenerates wiki links (`replaceLinks`). FTS triggers fire from the
  pages UPDATE. Conflict → park (same as W1).
- `workspaceRefresh` — re-base the workspace against current main:
  diff3 per workspace_ref, write the merged version as the workspace's
  NEW version (NOT to main — main is untouched), update `base_version_id`
  to current main_head. Conflict → park.
- New protocol member: `workspaceRefresh`.

**wikictl:**
- `workspace refresh --id W` — re-base workspace against current main.

**Tests:** 9 `Diff3Tests` + 14 `WorkspaceTests` (4 new: clean diff3,
conflict on same line, two-parent lineage, two overlapping ingestions
both merge, refresh re-bases). `StoreEmissionExhaustivenessTests` —
`workspaceRefresh` in NO-EMIT. Fast tier: 2181 tests pass.

**What's deferred:** Conflict resolution UI (W3), edit lock retirement
behind capability flag, `wiki_index` line-set merge (D12),
slug-collision unification (D13), workspace TTL/reaper (W4).

## 2026-07-11 — W1: Workspaces, overlay, fast-forward merge (PR #312)

**What shipped.** Phase W1 of the multi-writer concurrency plan: durable
workspaces for speculative ingestion branches + fast-forward-only merge.

**Schema v31:**
- `workspaces` table (id, name, status, activity_id, index_body,
  index_base_version, timestamps). Status: open → merging → merged |
  conflicted | abandoned.
- `workspace_refs` table (workspace_id, kind, owner_id, base_version_id,
  version_id, updated_at). Per-page overlay: the workspace's current head
  + the base version observed at first write (the three-way-merge base).
  `base_version_id = NULL` means the page was created in the workspace.

**Store layer** (`SQLiteWikiStore` + `WikiStore` protocol):
- `createWorkspace` — creates a durable, named workspace (status=open).
- `workspaceSummary` — read status + metadata.
- `workspaceRefs` — list all page-overlay refs.
- `workspaceWritePage` — append version + UPSERT workspace_refs. Does NOT
  touch `pages.body_markdown` or main `refs` — main is untouched until
  merge. Creates a placeholder `pages` row (empty body) for FK safety on
  workspace-created pages.
- `workspacePageVersion` — overlay read (the workspace's head for a page).
- `workspaceMerge` — fast-forward-only: for each workspace_ref, if
  `main_head == base_version_id` → fast-forward (repoint main ref + update
  mirror). If divergence → roll back the partial fast-forwards, park as
  `conflicted` in a follow-up transaction. Page-created-in-workspace
  (base=nil, no main ref) → fast-forward (update mirror + create ref).
- `abandonWorkspace` — set status=abandoned + delete workspace_refs.

New types: `WorkspaceStatus`, `WorkspaceSummary`, `WorkspaceRef`.

**wikictl:**
- `workspace create [--name N]` — creates a workspace, prints its ID.
- `workspace status --id W` — shows status + touched pages.
- `workspace abandon --id W` — abandons (GCs refs).
- `workspace merge --id W` — attempts fast-forward merge.

**Tests:** 9 `WorkspaceTests` (create, write-doesn't-touch-main, overlay
read, fast-forward merge, conflict park, abandon, page-created-in-workspace,
multi-page merge). `FreshSchemaParityTests` — fresh path matches ladder.
`StoreEmissionExhaustivenessTests` — workspace mutators in NO-EMIT
partition (invisible to FP token). Fast tier: 2167 tests pass.

**What's deferred:** diff3 merge (W2), conflict resolution UI (W3),
edit lock retirement behind capability flag (the `workspacesEnabled`
plumbing is designed but not yet wired into `AgentOperationRunner`),
`wiki_index` line-set merge (W2), workspace TTL/reaper (W4).

## 2026-07-11 — W0: Page versions & CAS (PR #312, issue #258)

**What shipped.** Phase W0 of the multi-writer concurrency plan:
`page_versions` (append-only, blob-backed page body chain) + CAS
conflict detection. Two writers racing one page → loser gets a
`PageConflictError`, no silent clobber.

**Schema v30:**
- `page_versions` table (mirrors `source_versions`: id, page_id,
  parent_id, merge_parent_id, blob_hash, title, activity_id, saved_at).
- `refs` rebuilt: dropped `owner_id REFERENCES sources(id)` FK, added
  `CHECK (kind IN ('source-content','source-derived','page-content'))`.
  The graph-model plan §4.3 flagged this as the trigger condition for a
  third ref kind.
- Migration seeds one root version per existing page (blob of
  body_markdown, legacy-import activity, no ref row — default-active =
  MAX(id), like sources at v20).

**Store layer** (`SQLiteWikiStore` + `WikiStore` protocol):
- `appendPageVersion` — CAS save: resolve head (ref → version_id, or
  MAX(id)), guard expected == head, insert blob + activity + version,
  update `pages.body_markdown` mirror (keeps FTS triggers working),
  UPSERT `page-content` ref.
- `pageHeadVersionID` — resolve active version (ref or MAX(id)).
- `pageVersionHistory` — full version chain, ULID-ordered.
- `revertPage` — repoint ref + update body mirror from version's blob.
- `PageConflictError` — carries expected + actual version id.
- All routed through `mutate()` (StoreEmissionExhaustivenessTests pass).

**CAS threading:**
- `PageUpsert.upsert` gains `expectedHeadVersionID` (default nil =
  blind write, backward-compatible). `writePage` routes through
  `appendPageVersion` when CAS is active, `updatePage` otherwise.
- `WikiStoreModel.save()` captures `loadedPageHeadVersionID` on page
  load, passes it as the CAS expectation. On `PageConflictError`,
  surfaces "Page Was Updated" alert. `wikictl` passes nil (blind write).

**wikictl:**
- `page history (--title X | --id Y)` — version chain (seq, id, date,
  title, blob hash, parent).
- `page revert (--title X | --id Y) --version V` — repoint ref + body.

**Tests:** 9 `PageVersionTests` (CAS conflict, CAS passes, blind write,
history ordering, parent linkage, revert body, revert head,
default-active, body mirror). `FreshSchemaParityTests` — fresh path
matches ladder (byte-identical). `StoreEmissionExhaustivenessTests` —
new mutators in EMIT partition. Fast tier: 2158 tests pass.

**What's deferred:** workspaces, overlay resolution, merge (W1/W2),
conflict UI (full editor affordance — W0 just shows a StoreError
alert), agent edit lock retirement (W1), `vacuum-pages` GC.

## 2026-07-11 — ACP stall recovery: watchdog kill escalation (#334 Phase 3)

**Problem:** Phases 1 + 2 fixed the stall detection, recovery, and root causes.
But if the ACPBackend watchdog's `cancelSession` fails to unblock `sendPrompt`,
and the SDK's `terminate()` also fails (the process is truly wedged), the agent
process stays alive with no way to kill it. The launcher watchdog was log-only.

**Phase 3 fix:**

- **Stall escalation in `startCompletionWatchdog`:** when `isRunning` and idle
  exceeds `watchdogStallThreshold` (180s — more generous than ACPBackend's
  per-turn 120s, this is the backstop), the watchdog calls `stopAgent()` (cancel
  + finish) and spawns a separate kill-escalation task. A `watchdogHasEscalated`
  flag prevents double-escalation. Reset in `resetRunArtifacts()` + `finish()`.
- **Kill escalation (`startKillEscalation`):** runs as a separate Task because
  `stopAgent()` sets `isRunning = false` (which exits the heartbeat loop). Checks
  `kill(pid, 0)` directly — not `isRunning` — to detect whether the process is
  actually dead. Escalation sequence: wait 10s for cancel → `kill(-pid, SIGTERM)`
  (process group) → wait 5s → `kill(-pid, SIGKILL)`. The `terminationHandler`
  fires after the kill → `onExit` → `finish()`.
- **Pure decision helper:** `shouldEscalateWatchdog(isRunning:idleSeconds:
  stallThreshold:alreadyEscalated:)` — extracted as a `nonisolated static` so
  it's unit-testable without driving launcher state. `watchdogStallThreshold`
  is also `nonisolated static`.
- **Debug cleanup:** stripped the two noisy TEMP DEBUG lines that dumped raw
  `session/update` JSON (800-char prefix) and per-event descriptions — too
  verbose for production. Kept the lifecycle markers (start/send/cancel/
  heartbeat) which were essential for diagnosing the original incident.

**Tests (7 new):** `WatchdogEscalationTests` — escalate at/above threshold,
don't escalate when not running / below threshold / already escalated / no
activity record.

**Gate:** `swift build` clean; fast tier **2147 tests in 181 suites pass**.

**Files changed:**
- `Sources/WikiFS/AgentLauncher.swift` — stall escalation + kill sequence +
  `watchdogHasEscalated` flag + pure decision helper.
- `Sources/WikiFS/ACPBackend.swift` — stripped 2 noisy TEMP DEBUG lines.
- `Tests/WikiFSTests/WatchdogEscalationTests.swift` (new) — 7 tests.

## 2026-07-11 — ACP stall recovery: SDK fork + root-cause fixes (#334 Phase 2)

**Problem:** Phase 1 (#335) fixed the *symptom* (permanent stall → failed turn
with retry). Phase 2 fixes the four *root causes* inside the swift-acp SDK.

**SDK fork:** Forked `wiedymi/swift-acp` v0.1.0 → `wsargent/swift-acp` v0.2.0.
Upstream confirmed dead since v0.1.0 (no fixes available). `Package.swift`
swapped to the fork pinned to `v0.2.0`. Upstream PRs offered when the upstream
resumes.

**Four root-cause fixes (all in the fork):**

1. **Ordered transport reads** (the likely loss in the observed incident).
   `ACPProcessManager.startReading()` and `StdioTransport.startReading()` spawned
   an unstructured `Task { processIncomingData }` per pipe chunk — tasks raced
   across actor hops and could swap chunk order, corrupting JSON-RPC framing and
   silently dropping messages. Replaced with an ordered `AsyncStream<Data>` pipe:
   the readabilityHandler yields into the stream; ONE long-lived consumer calls
   `processIncomingData` in arrival order. Same fix in both transports.

2. **Non-blocking incoming requests.** `Client.handleMessage` dispatched
   `.request` handling inline — `handleIncomingRequest` awaited
   `requestRouter.routeRequest` on the actor. Under `.alwaysAsk`, a
   `session/request_permission` that suspends on a user decision froze the whole
   actor (no responses, no notifications). Now wrapped in `Task { }` — responses
   and notification yields stay inline (they're fast).

3. **Stderr forwarding.** `startReadingStderr` discarded stderr entirely.
   Now yields lines to a new `stderrLines()` stream on `Client`. Default consumer
   is none (preserving behavior). The app wires it to `DebugLog.agent`.

4. **PID exposure.** `ProcessRegistry` recorded pid/pgid but had no read API.
   `Client` gains `processIdentifier()` and `processGroupIdentifier()` methods.
   The app threads the PID to `AgentLauncher.currentProcessID` via
   `ACPBackend.processIdentifier(for:)` → `captureProcessID(session:)`.

**App-side wiring:**
- `ACPBackend.start`: starts a stderr drain task → `DebugLog.agent`.
- `ACPBackend.processIdentifier(for:)`: delegates to `session.client.processIdentifier()`.
- `AgentLauncher.captureProcessID(session:)`: called alongside
  `captureAndCacheModels` at all 4 spawn sites → assigns `currentProcessID`.

**Gate:** `swift build` clean (fork + app); fast tier **2140 tests in 180 suites
pass**. No new tests (SDK changes are in the fork; the app-side wiring is thin
delegation). Phase 2 ship gate: live-agent smoke (multi-turn session incl.
always-ask permission mid-turn) — needs manual verification with credentials.

**Files changed (selfdrivingwiki):**
- `Package.swift` — swapped to `wsargent/swift-acp` from `0.2.0`.
- `Package.resolved` — resolved fork.
- `Sources/WikiFS/ACPBackend.swift` — `processIdentifier(for:)` + stderr drain.
- `Sources/WikiFS/AgentLauncher.swift` — `captureProcessID(session:)` + 4 call sites.

**Files changed (fork: wsargent/swift-acp):**
- `Sources/ACP/Internal/ProcessManager.swift` — ordered reads + stderr + PID.
- `Sources/ACP/Transport/StdioTransport.swift` — ordered reads.
- `Sources/ACP/Client.swift` — non-blocking requests + PID/stderr accessors.

## 2026-07-11 — ACP stall recovery: app-side hang prevention (#334 Phase 1)

**Problem:** An ACP turn could stall permanently — `client.sendPrompt()` never
returns, the generation gate never releases, `isRunning` stays true, and the UI
shows no failure. Observed: the agent finished the work (page written) but the
`session/prompt` completion response never reached the app. Recovery required a
manual Stop.

**Root causes (6, all verified against code + SDK source):**
1. SDK: unordered chunk processing (`Task { processIncomingData }` per pipe
   chunk — ordering not guaranteed across actor hops).
2. SDK: `Client` actor head-of-line blocking on `request_permission`.
3. SDK: stderr discarded.
4. SDK: PID never exposed (`ProcessRegistry` is write-only).
5. App: no timeout/recovery (`sendPrompt` with `timeout: nil`; watchdog log-only).
6. App: per-turn `client.notifications` re-acquisition (AsyncStream is
   single-consumer — two concurrent iterators split elements).

**Phase 1 fixes (app-side, no SDK change — shippable alone):**

- **1a. Turn inactivity watchdog** (`TurnLivenessPolicy.swift`, new): a PURE
  decision helper — `(now, promptDone, turnStartedAt, lastActivityAt, limits) →
  .healthy | .stalled | .ceilingExceeded`. NOT a flat timeout (turns legitimately
  run 6+ min); the signal is *inactivity* (idle 120s default, ceiling 30 min).
  A sibling watchdog `Task` in `ACPBackend.send` polls every 15s; on stall it
  calls `cancelSession` + yields `turnEndEvents(error: .turnStalled(...))` +
  finishes the continuation. A shared `TurnCompletionFlag` prevents the prompt
  task and watchdog from double-firing.

- **1b. Session-lifetime notification drain** (`NotificationFanout.swift`, new):
  `client.notifications` is acquired ONCE in `ACPBackend.start` and fanned into a
  per-session `NotificationFanout`. Each turn subscribes to the fanout instead of
  re-acquiring the SDK stream (eliminates cause 6 — the single-consumer race).
  The fanout also timestamps every notification, giving 1a its liveness signal
  for free. Torn down in `cancel` (drainTask.cancel + fanout.finish).

- **1c. Stop-path audit + error synthesis:** `ACPBackendError` gains
  `.turnStalled(idleSeconds:)` and `.turnCeilingExceeded(totalSeconds:)`. The
  recovery reuses the existing `turnEndEvents(error:)` synthesis (`.raw` +
  `.messageStop`), so the consumer's `for await` exits, the generation gate
  releases, and the user sees an error line + can retry. `FakeAgentBackend`
  gains `neverFinish` to simulate a stalled `sendPrompt`.

**Concurrency design note:** `NotificationFanout.subscribe()` deliberately does
NOT set `onTermination` — the old subscriber's termination fires asynchronously
and can race with a new `subscribe()`, clearing the NEW subscriber's
continuation (which hangs the new turn's drain). The subscriber is overwritten
by the next `subscribe()` or cleared by `finish()` at teardown. Between turns
there are no notifications (the agent is idle), so a stale continuation is
harmless.

**Tests (24 new, all green):**
- `TurnLivenessPolicyTests` (11): healthy/stalled/ceiling/boundary/precedence.
- `NotificationFanoutTests` (7): subscribe/yield/finish/liveness/resubscribe.
- `ACPStallRecoveryTests` (6): neverFinish behavior, error messages,
  turnEndEvents synthesis for both stall + ceiling.

**Gate:** `swift build` clean; fast tier **2140 tests in 180 suites pass**.
Existing ACP tests (69 across 6 suites) unchanged. `ACPBackend.send` path not
unit-tested (requires a real `Client` actor from the SDK) — Phase 2's ship gate
(live-agent smoke) covers the full fire-and-recover path.

**Files changed:**
- `Sources/WikiFS/TurnLivenessPolicy.swift` (new) — pure decision helper.
- `Sources/WikiFS/NotificationFanout.swift` (new) — session-lifetime drain fanout.
- `Sources/WikiFS/ACPBackend.swift` — watchdog + fanout + stall errors + teardown.
- `Tests/WikiFSTests/TurnLivenessPolicyTests.swift` (new) — 11 tests.
- `Tests/WikiFSTests/NotificationFanoutTests.swift` (new) — 7 tests.
- `Tests/WikiFSTests/ACPStallRecoveryTests.swift` (new) — 6 tests.
- `Tests/WikiFSTests/FakeAgentBackend.swift` — `neverFinish` behavior.
- `plans/acp-stall-recovery.md` (new) — design doc of record.
- `PLAN.md` — doc index entry.

**Deferred (Phase 2):** Fork `wiedymi/swift-acp` for ordered transport reads,
non-blocking incoming requests, stderr forwarding, PID exposure. SDK upstream
confirmed dead since v0.1.0 (no fixes available). Phase 3: watchdog kill
escalation + UI surfacing.

## 2026-07-11 — Fix: SQLite statement reset leak pinning stale WAL snapshots (#332)

**Problem:** Cached SELECT statements across 18 functions (26 leaking statements)
in `SQLiteWikiStore.swift` used a "reset-before-use" idiom (`stmt.reset()` before
`bind`/`step`) that cleared the *previous* call's leftover but left the
*current* call's statement stepped-to-`SQLITE_ROW` (busy) when the function
returned. A busy statement holds an implicit read transaction open, pinning the
connection's WAL read snapshot. After an external writer (`wikictl`, another
store instance) commits, the pinned snapshot is stale — subsequent reads return
old data and `BEGIN IMMEDIATE` fails with `SQLITE_BUSY_SNAPSHOT`.

**Fix (Phase 1):** At every affected site, replaced the leading `stmt.reset()`
with `defer { stmt.reset() }` immediately after `try statement(...)`. This bounds
the statement's read transaction to the call, covering success, early-return, and
throw paths uniformly. Also converted the migration-loop statements
(`resolveVersion`/`resolveVersionMax`) and fixed `revertProcessedMarkdown`, which
stepped a `target` statement to ROW before entering `withTransaction` — added an
explicit `target.reset()` after extracting values so the read snapshot is released
before `BEGIN IMMEDIATE`.

**Guard (Phase 2):** Added `SQLiteStatement.isBusy` (wraps `sqlite3_stmt_busy`),
an internal `assertNoBusyStatements()` method (iterates the statement cache,
throws if any is busy), and a `_testProbeBusyStatement()` test seam. The guard
fires at the top of `withTransaction` at depth 0 (`#if DEBUG` only) — before
`BEGIN IMMEDIATE`.

**Tests (Phase 3):** New `SQLiteStatementLifecycleTests` suite (not
`.integration`-tagged → runs in CI): `noBusyStatementsAfterReads` (Test 1,
deterministic — exercises every fixed site via public callers, asserts no busy
statement), `detectsBusyStatement` (AC.2 — verifies the guard throws). Integration
suite `SQLiteStatementLifecycleIntegrationTests` (`.integration`-tagged):
multi-connection WAL write-lock and read-only stale-snapshot tests.

**Documentation (Phase 4):** Updated `docs/skills/sqlite-concurrency/SKILL.md`
(new §7 on statement lifetime discipline), `AGENTS.md` (rule addition to the
SQLite concurrency bullet), CI skip regex in `.github/workflows/ci.yml`.

**Files changed:**
- `Sources/WikiFSCore/SQLiteStatement.swift` — added `isBusy`
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — 18 functions + migration + `revertProcessedMarkdown` fixed; `assertNoBusyStatements()` + `_testProbeBusyStatement()` added; guard in `withTransaction`
- `Tests/WikiFSTests/SQLiteStatementLifecycleTests.swift` — new test file
- `docs/skills/sqlite-concurrency/SKILL.md`, `AGENTS.md`, `.github/workflows/ci.yml` — documentation + CI

## 2026-07-10 — Multi-phase ACP ingestion (planner → executors → finalizer)

**Problem:** Large-source ACP ingestion relied on Claude's in-process sub-agents
(the Sonnet `source-reader` digester spawned via `--agents`). Sub-agents don't
work over ACP — the protocol has no custom agent types and background agents
can't complete within a single turn. So a large ingest over ACP silently stalled.

**Fix:** Replaced the one-shot spawn with a multi-process architecture for ACP
large ingests (> 4 KB):

1. **Planner** (Opus, 1 session): reads staged sources, decides the page set,
   writes a `plan.json` to the scratch directory. Does NOT write wiki pages.
2. **Executors** (Sonnet, N sessions — one per source file): each reads its
   assigned pages from `plan.json` + the source section, writes pages via
   `$WIKICTL page upsert`. Sequential (parallel is a future optimization).
3. **Finalizer** (Opus, 1 session): reads `$WIKICTL page list`, writes
   `index.md` via `$WIKICTL index set`, records log entries via
   `$WIKICTL log append --kind ingest --source <id>`.

Each phase is a clean, independent single-turn ACP session — no sub-agents, no
background dispatch, no sleep. Tiny sources (< 4 KB) and all CLI runs use the
existing single-session path unchanged.

**Lifecycle design:** `runACPIngestPlannerExecutors()` is a structural
replacement for `run()`'s spawn-commit block. It is dispatched AFTER `run()` has
acquired the generation gate, fired `onLock`, opened log files, and set
`isRunning`/`ingestingSourceIDs`. It owns per-phase: `BackendProfile` (model
override), `sessionHandle`, `currentRunToken`. The per-phase `onExit` closure
does NOT call `finish()` (phase-tracking only); `finish()` is called exactly once
at the end. If the user hits Stop, `stopAgent()` cancels the live phase's session,
remaining phases are skipped, and `finish()` runs once via the cancellation path.

**Fallback:** If the planner fails or produces no valid `plan.json`, the
orchestration falls back to single-session ACP ingest (the original one-shot
prompt with the "no sub-agents" instruction).

**Model override for executors:** The alias "sonnet" doesn't match
`ACPModelSelectionResolver` (exact-id matching). Instead, after the planner
session starts, the advertised models are read via `ACPBackend.availableModels`
and the first model whose id/name contains "sonnet" is selected. Falls back to
the provider's default if no match.

**Files changed:**
- `Sources/WikiFSCore/ACPIngestPlan.swift` (**new**): `Codable` plan schema
  (`ACPIngestPageAssignment`, `ACPIngestPlan`), tolerant JSON extraction
  (`extract(from:)` — strips fences, substrings `{`→`}`), pure prompt builders
  (`ACPIngestPrompts.plannerPrompt`/`executorPrompt`/`finalizerPrompt`).
- `Sources/WikiFS/AgentLauncher.swift`: `runACPIngestPlannerExecutors()` method
  + `runPhase()` helper + `runACPIngestFallback()` + `findSonnetModelId()`.
  Dispatch point inserted after `onLock` in `run()` for `useACP && .opusCurator`.
- `prompts/ingest-planner.md`, `prompts/ingest-executor.md`,
  `prompts/ingest-finalizer.md` (**new**): codegen'd into `GeneratedPrompts.swift`.
- `Tests/WikiFSTests/FakeAgentBackend.swift` (**new**): test double conforming to
  `AgentBackend`.
- `Tests/WikiFSTests/ACPIngestPlanTests.swift` (**new**): 23 tests — plan
  encode/decode round-trip, `assignments(forSource:)`, `distinctSourceFiles`,
  tolerant JSON extraction (clean/fenced/prose-wrapped/invalid), prompt builders,
  `findSonnetModelId` (match/name/no-match/empty/case-insensitive),
  FakeAgentBackend recording (start/send/cancel sequence, failure, model hints).
- `Sources/WikiFSCore/WikiOperation.swift`: `sourceID(fromPath:)` → `public`.
- `tools/promptgen/main.swift`: registered 3 new prompt entries.

**Not verified:** The full orchestration needs a live ACP agent for end-to-end
verification (integration-level). The FakeAgentBackend infrastructure is provided
for future integration tests that drive the launcher end-to-end.

## 2026-07-11 — Provider selector under the chat composer (#325)

**Change:** added a compact **provider selector** under the chat composer
(`ChatView`), modeled on paseo's `combined-model-selector` trigger and
translated to native macOS. v1 is **provider-only** (no model drill-down —
selfdrivingwiki doesn't yet collect per-agent models). Picking a provider
sets the persisted default, so the next chat session uses it via the
launcher's existing `resolveSelectedProvider` (no launcher spawn change).

- **Model** (`AgentProvidersConfig.swift`): added `settingDefault(id:)` — a
  PURE mutator that marks one provider default + demotes the rest (enforces
  the single-default invariant via `normalized`), and `enabledProviders` — the
  enabled-only view the selector binds (matches the launcher's
  `selectedProvider()` fallback). The Settings view's inline `setDefault` now
  delegates to the shared mutator (DRY).
- **Launcher** (`AgentLauncher.swift`): added `resolveProvidersContainerDirectory`
  (same container resolution as `resolveSelectedProvider`), a read accessor
  `providersConfig()`, and a `setDefaultProvider(id:)` that sets + persists +
  returns the new config. The composer selector reads + mutates through these.
- **UI** (`Sources/WikiFS/ProviderSelector.swift`, new): a `Menu` trigger —
  glyph + current label + a chevron (`menuIndicator(.hidden)`; we draw our own)
  — opening the enabled providers, with a gear → `@Environment(\.openSettings)`.
  Leading-aligned, `.caption`/secondary, sits below the text field as a
  composer VStack sibling (`providerSelectorBar` in both `emptyState` and
  `chatComposer`). Hidden when no wiki is active.
- **Tests** (`Tests/WikiFSTests/ProviderSelectorTests.swift`, new): the
  `settingDefault` invariant (demotes others, reversible, unknown-id-safe,
  pure), `enabledProviders`, the persist→reload round-trip, and the launcher
  wiring (`setDefaultProvider` → `resolveSelectedProvider` reads it; default =
  Claude when unpicked). 88 ACP/provider tests + the fast tier (2049 tests)
  green.
- **Not verified:** the rendered selector needs a live-UI check (couldn't run
  the GUI here) — compile + unit-test only.

## 2026-07-11 — Agent providers model + Settings UI (#324)

**Change:** replaced the slice-3 `useACPBackend` bool + single `ACPAgentConfig`
with a **provider list** (`agent-providers.json`) the user configures in a new
Settings → **Providers** tab. Modeled on paseo's `providers-section.tsx` +
`provider-catalog-list.tsx` + `provider-diagnostic-sheet.tsx`, translated to
native macOS SwiftUI.

- **Model** (`Sources/WikiFSCore/AgentProvider.swift` +
  `AgentProvidersConfig.swift`): `AgentProvider { id, label, backend, command,
  env, enabled, isDefault }` where `enum AgentBackendKind { claudeCLI, acp }`.
  `AgentProvidersConfig` persists to `agent-providers.json` (App Group
  container). `loadOrSeed` seeds **Claude (default, enabled)** + ACP agents
  discovered on PATH. Pure `seed(discovered:)` for tests. Single-default
  invariant enforced by `normalized`.
- **Catalog** (`ACPProviderCatalog.swift`): expanded from 2 → **12 confirmed
  ACP agents** ported from paseo's `acp-provider-catalog.ts` — gemini, hermes,
  copilot, kimi, cursor, kiro, goose, grok, codewhale, kilo, plus the npx
  wrappers `claude-agent-acp` + `codex-acp`. Claude stays OUT (the `.claudeCLI`
  default).
- **Settings UI** (`Sources/WikiFS/AgentProvidersSettingsView.swift`): providers
  list (icon/name + status badge + enable toggle + details), a radio-group
  default selector, an **Add Provider** catalog sheet (searchable, hides
  already-added), and a per-provider detail editor (command, `SecureField` API
  key via Keychain, enable). Native `Form`/`.formStyle(.grouped)`. Used the
  `swiftui-pro` + `macos-design` skills.
- **Launcher wiring** (`AgentLauncher.swift`): new `resolveSelectedProvider`
  seam; both `run()` + `startInteractiveQuery()` now pick the provider from
  config and construct the backend via `AgentBackendFactory.makeBackend(
  provider:policy:)`. `.acp` resolves the provider's PATH command + per-provider
  Keychain key into `providerHints`. **Default = Claude → zero behavior
  change.**
- **Credential store** (`ACPCredentialStore.swift`): added per-provider Keychain
  keying (`apiKey(forProvider:)` / `setAPIKey(_:forProvider:)`), namespaced by
  account `acp-provider:<id>`. The legacy single-key API is preserved.
- `AgentBackendFactory.makeBackend(useACPBackend:policy:)` + the slice-3
  `acpProviderHints(...)` retained (existing tests + `ACPSmokeTests` unchanged).

**Tests:** new `AgentProviderModelTests` (5 suites, 30+ tests) — seed/normalize/
persist/round-trip, catalog expansion + Claude-absent + command[0]==detect,
selection→backend mapping, per-provider Keychain isolation. All existing ACP
suites green. Fast tier: **2041 tests in 170 suites pass.**

**Couldn't verify:** live non-Claude E2E (no creds) — the model/selection/
catalog are unit-tested; `ACPSmokeTests` covers the Claude path. Flagged for
manual E2E when credentials are available.

## 2026-07-10 — Remove read-only Ask/Plan chat mode

**Change:** the dual Ask (read-only) / Edit (write-capable) chat product
surface collapsed to a single always-write-capable chat. The read-only "Ask"
seatbelt is no longer wired to the chat path.

- `ChatKind.ask` removed — only `.edit` remains (vestigial enum + `chats.kind`
  column retained for a future always-ask/yolo distinction).
- v28→v29 data-only migration: `UPDATE chats SET kind = 'edit' WHERE kind =
  'ask'`. Fresh DBs are unaffected (no chat rows). `user_version` head is now 29.
- `WikiSelection.ask` / `.edit` → single `.newChat` draft case.
- Dual launchers (`askLauncher` / `editLauncher`) collapsed to one
  `chatLauncher` across `WikiFSApp`, `RootView`, `ContentView`,
  `WikiDetailView`, `SidebarView`, `AgentToolsView`.
- `QueryMode` enum deleted; `ChatView` takes `chatID: PageID?` only.
- `AgentLauncher.startInteractiveQuery` no longer takes `allowWikiEdits` —
  always uses the write sandbox (`resolveSandboxInvocation`), `isReadOnly:
  false`.
- `selectQuerySandbox` + the `allowWikiEdits == false` read-only branch in
  `queryChatPrompt` removed from the call path (the prompt always includes
  `IngestWriteRule.writes`).
- `AgentOperationRunner.startChat` / `continueChat` always create `.edit`
  chats and always take the edit lock; `shouldBlockEditStart` no longer takes
  `allowWikiEdits`.
- `SandboxProfile.generateReadOnly` / `readOnlyInvocation` retained in-tree
  deliberately (unwired, not deprecated) — the read-only seatbelt code stays
  for reference.
- `WikiOperation.queryChat` keeps `allowWikiEdits: Bool = true` for signature
  stability; the chat path always constructs it with `true`.

**Tests:** `QuerySandboxSelectionTests` + `QueryModeTests` deleted (functions
gone). `OperationCommandTests`, `Issue235IngestExtractionLockTests`,
`EditorTabTests`, `ChatViewD2Tests`, `ChatTranscriptRendererTests`, and
schema-version assertions across ~12 suites updated. New
`migrateV28ToV29RewritesAskChatsToEdit` test added.

## 2026-07-09 — #279: Signal the bookmarks container on store events

**Problem:** `FileProviderSpike.signalChange(forWikiID:)` had a hardcoded list
of containers to proactively refresh on every store event. The top-level
`bookmarks/` folder was missing — only pages/root/indexes/sources/chats views
plus `.workingSet` were signaled. So a Finder/Terminal user browsing
`bookmarks/` directly wouldn't see bookmark create/move/delete changes until a
working-set sweep re-enumerated. (The working set still caught deletions
authoritatively; the per-container signal is an optimization for proactive
refresh.)

**Fix:** added `NSFileProviderItemIdentifier(WikiFSContainerID.bookmarks)` to
the `containers` array in `signalChange(forWikiID:)`. Bookmarks use
`NestedResourceProjection` (arbitrary-depth folders), so only the top-level
container needs signaling — nested folder enumerators refresh via the parent's
`didUpdate` re-enumeration.

**Tests:** no new tests — the signal path is best-effort against
`NSFileProviderManager` and not unit-testable. `swift build` clean.

## 2026-07-09 — #277: File Provider deletion signaling — self-heal on extension restart

**Problem:** #111/#276 fixed deleted sources/pages lingering in the File
Provider by diffing the last-reported item set (`knownItems`) against the
current one in `WikiFSEnumerator.enumerateChanges` and calling
`didDeleteItems`. But `knownItems` is process-static (in-memory only), while
the sync anchor is persisted by the File Provider framework across extension
process restarts. On a routine extension relaunch the framework can call
`enumerateChanges(from: validAnchor)` with no prior `enumerateItems` in the new
process → `knownItems` is nil → the deletion diff is skipped → deletions that
landed while the process was dead are silently dropped (the original #111
symptom reintroduced). The docstring also wrongly claimed the anchor "expires"
on restart (it doesn't — only unparseable/legacy anchors expire).

**Fix:** in `enumerateChanges`, when the baseline is absent, return
`syncAnchorExpired` instead of diffing against an empty set. The framework then
discards its cache and does a clean full `enumerateItems`, which re-seeds the
baseline. Cost is one full re-enumeration per container after a restart; the
restart path now emits only the expiry (no wasteful `didUpdate`). Corrected the
misleading `KnownItemSet` docstring. Findings #2 (kinds) / #3 (nested) / #4
(concurrency) from the issue review were closed by tests, not code: the diff is
generic over `projection.children(of:)`, the `NSLock` guards only the dict
get/set (DB read + diff run unlocked), and the `wikiID/container` cache key
can't collide.

**Tests:** 4 new cases in `EnumeratorDeletionTests` — bookmark-ref deletion,
chat deletion, nested folder deletion, and the restart baseline-loss case
(asserts anchor expiry, not a silent drop). Full suite 7/7 pass
(`swift test --filter EnumeratorDeletionTests`).

## 2026-07-09 — #235: Prevent silent hang when starting Edit/Ask during ingest extraction

**Problem:** Starting an Edit (or Ask) session immediately after kicking off an
ingest could silently hang — the edit lock (`isAgentRunning`) only fires at
spawn commit (via `onLock`/`beginAgentRun`), which is AFTER the multi-second
pdf2md extraction phase. During extraction, the Edit preflight guard didn't see
the ingest, so Edit started — then silently queued on the generation gate with
no visible feedback (the "Waiting…" text was only a hidden `.help()` tooltip).

**Fix (two parts):**

1. **`isIngestInProgress` flag** (`WikiStoreModel`): set at the top of
   `runMultiIngest` via `beginIngest()` (BEFORE extraction), cleared on early
   exit (via `defer { if !launcher.isRunning { store.endIngest() } }`) or on
   process termination (via the ingest run's `onUnlock` callback). The Edit
   preflight (`shouldBlockEditStart`) now checks `isAgentRunning ||
   isIngestInProgress`. Ask mode is never blocked (read-only, lock-exempt).
   A separate flag avoids the self-deadlock that reusing `isAgentRunning` would
   cause (the ingest's own `run()` preflight checks `isAgentRunning`).

2. **Visible waiting caption** (`ChatView`): replaced the hidden
   `.help(sendButtonTitle)` tooltip with visible `composerCaption` text below
   the composer. When `isAwaitingGenerationSlot` is true, the user now sees
   "Waiting for the other session to finish before sending…" directly in the
   UI. Applied to both `chatSurface` and `emptyState` (draft) composer areas.

Both predicates (`shouldBlockEditStart`, `composerCaptionText`) are extracted as
static functions for unit testability. New test suite
`Issue235IngestExtractionLockTests` (11 tests) covers the full state matrix.
See [`plans/issue-235-ingest-extraction-lock.md`](plans/issue-235-ingest-extraction-lock.md).

**Tests:** `swift test --filter 'Issue235'` — 11/11 pass. Full fast-tier run:
1972/1973 pass (1 pre-existing flaky `PdfExtractionServiceTests` pipe-draining
test, unrelated, passes in isolation).

## 2026-07-09 — #278: Reorganize welcome "Get Started" into Add Page / Add Source / Add Chat

The welcome screen's "Get Started" row (`WikiDetailView.swift`, `case .none`)
was a flat `FlowLayout` of up to four ingestion-shaped buttons (Add from URL,
Add File, Add Folder, Add from Zotero-when-configured) — conflating several
actions under one heading and offering no path to the two other primary object
types the intro cards above it advertise (Pages, Chats). Reorganized it into
**three primary buttons** that map 1:1 to the Pages / Sources / Chats intro
rows:

- **Add Page** — `store.newPageInNewTab()` (untitled → editor in a new tab),
  mirroring the Pages sidebar `+` and the window toolbar's New Page.
- **Add Source** — a native SwiftUI `Menu` (`.menuStyle(.button)` +
  `.bordered`/`.large`, matching the codebase's `WikiSwitcher` convention) that
  consolidates the four existing ingestion handlers: URL (`addURLHandler?("")`),
  File (`WikiFilePanels.chooseFile` + `store.addFiles`), Folder
  (`showingImportMarkdown = true`), and Zotero (`showingAddFromZotero = true`,
  item appears only when `isZoteroConfigured`).
- **Add Chat** — `store.openTab(.edit)`, mirroring the Chats sidebar `+` New
  Chat (there is only Edit mode now; Ask was removed).

Resolved the issue's open questions: Add Source → native pull-down Menu (vs
popover/sheet); Add Page → untitled straight into edit mode (no title prompt,
matching the rest of the app); Add Chat → Edit (only mode). Per swiftui-pro,
button actions were extracted into `addPage`/`addChat`/`addFile` methods and the
`Button(_:systemImage:action:)` initializer form is used where possible (text +
icon labels for VoiceOver). Gave File vs Folder distinct menu icons
(`doc` / `folder`) — the originals both used `doc.badge.plus`.

**Files:** `Sources/WikiFS/WikiDetailView.swift` (view only — no store/schema
change). **Gate:** `swift build` clean; fast-tier `swift test` — **1963 tests in
162 suites** pass.

## 2026-07-09 — #303: Chat-created pages push to UI via event bus

`WikiChangeBridge.flush` was an either/or: for the active wiki it emitted a
coarse bus event (model reloaded, but the File Provider was only refreshed
transitively via the bus subscriber with an extra ~250 ms debounce); for a
non-active wiki it signaled the File Provider directly and never poked the bus.
The either/or meant that if `activeWikiID` changed during the coalesce window
(user switched wikis mid-burst), the model reload was skipped entirely.

**Fix:** `flush` now **always** signals the File Provider directly for the
changed wiki, **and** emits the coarse bus event when the wiki is the active
one. Both paths fire unconditionally for their respective targets — no more
either/or. The redundant FP signal for the active wiki (direct + bus subscriber)
is harmless: `NSFileProviderManager.signalEnumerator` is idempotent and the FP's
own coalescer collapses the duplicate.

- `Sources/WikiFS/WikiChangeBridge.swift` — `flush` restructured + doc comment
  updated.
- `plans/event-bus.md` — emitter description updated to reflect the new
  always-signal + conditional-bus-emit behavior.
- `Tests/WikiFSTests/WikiChangeBridgeBusTests.swift` — two new tests:
  `crossProcessWriteSurfacedByCoarseEvent` (wikictl write through a separate
  store with no bus → model picks it up purely from the coarse event) and
  `burstOfWritesOneCoarseEventSurfacesAll` (a burst of writes collapsed into one
  coarse event surfaces all pages).

## 2026-07-09 — #281: Chat quote anchors (`[[chat:Title#"quote"]]`)

`[[chat:Title#"quote"]]` now deep-links to a specific message in a chat
transcript — navigating to the chat, scrolling the matched message into view,
and highlighting the passage — exactly as `[[source:Name#"quote"]]` does for
sources. This closes the explicit non-goal carried over from
`chat-projection.md` (where `chat_messages.text` was "the future FTS substrate,
but quote-anchor matching is not built"). Design of record:
`plans/chat-quote-anchors.md`.

**What shipped (no parser/URL change — that already worked):** The parser
(`WikiLinkParser.splitFragment`) and URL builder (`WikiLinkMarkdown.markdownLink`)
already carried a `#"quote"` fragment through the emitted `wiki://chat?…#"quote"`
URL for chat links generically. The gap was resolution + rendering, not syntax.

- **`ChatQuoteResolver`** (new, pure, `Sources/WikiFSCore/ChatQuoteResolver.swift`)
  — `quoteText(_:)` strips the surrounding `"` the parser keeps verbatim;
  `searchableText(_:)` exposes the prose each `.chat-row` renders; `messageIndex(
  of:in:)` is a whitespace-normalized, case-insensitive **first-match** substring
  scan over the transcript-visible events (mirrors the source quote anchor's
  `wikiNormalized` matching + `ChatWebView`'s `window.find` first-match).
- **Route + navigation** — `WikiLinkRoute.chat` gains `fragment:` (was
  `chat(title:id:)`); `linkRoute(for:)` and both `route(_:)` switch sites +
  `onWikiLinkHandler` thread it through; `selectChat(byID:anchor:)` /
  `selectChat(byTitle:anchor:)` gain an `anchor:` param (default `nil`, so
  sidebar/other callers are unchanged) and set `pendingScrollAnchor` tagged
  `.chat(id)` + bump `pendingScrollAnchorVersion` — the same seam
  `selectPage`/`selectSource` use.
- **Rendering** — `ChatWebView` gains `ChatHighlightRequest{version,quote}` +
  a `quoteAnchor` field; the coordinator stashes the quote and applies it via
  `highlightAndScrollJS(quote:)` — `window.find` + `<mark class="sdwhl">` +
  `scrollIntoView`, the exact mechanism `WikiReaderView.applyFind` uses (the
  transcript is one document, so `window.find` lands on the first match = the
  resolver's message). Applied in `didFinish` (fresh load, after rows render)
  and `updateNSView` (re-click on an already-loaded view); the stash survives a
  request that lands before load (guarded on `isLoaded`). `mark.sdwhl` CSS added
  to the chat shell HTML. Forwarded through `ChatTranscriptView`.
- **`ChatView`** consumes the anchor via a `.task(id:)` keyed on
  `(chatID, anchorVersion, messageCount)` — the messageCount dimension re-fires
  once a persisted chat's messages load, so the set-once anchor is consumed only
  when the transcript is ready (it survives the 0→N load); resolves via
  `ChatQuoteResolver`, then drives `ChatHighlightRequest`.
- **Agent surface** — `prompts/system-prompt-default.md` documents
  `[[chat:Title#"distinctive passage"]]` (regenerated via `make prompts`).

**Tests:** `ChatQuoteResolverTests` (16 — quote stripping, exact/whitespace/
case-tolerant first-match, partial-substring, nil-when-absent, prose-kind
coverage, non-searchable-skip) + `ChatQuoteAnchorModelTests` (5 —
producer/consumer/tagging/mismatch/nil-anchor). `ChatWebView` highlight is
WKWebView (manual verification only). Gate: `swift build` clean; full `swift
test` — **2079 tests in 167 suites** pass; `make check-prompts` green.

## 2026-07-09 — #283/#284: rename conversation→chat, unify the chat render path

The chat surface's naming now matches the canonical "chat" term from the data
model (`chats` table, `ChatSummary`, `[[chat:…]]`, `chats/` projection). Three
commits on `refactor/283-conversation-to-chat`; no feature removal, no
schema/data migration.

**#284 — single prompt body for Ask + Edit.** Deleted
`prompts/query-conversation-readonly.md` (and its promptgen entry); both the
read-only (Ask) and read-write (Edit) chat variants now source `chat.md`
(`GeneratedPrompts.chat`), differing only by the operational write-rule block
(`IngestWriteRule.writes`), which the read-only arm omits. The seatbelt sandbox
+ `--allowed-tools` remain the authoritative write gate. New
`chatBothModesShareChatBodyReadOnlyOmitsWriteRule` test pins it; `make
check-prompts` green.

**#283 — rename sweep.** Whole-identifier, case-sensitive rename across
Sources/Tests/tools: `ConversationView`→`ChatView`,
`QueryTranscriptView`→`ChatTranscriptView`,
`AgentTranscriptSidebar`→`AgentActivitySidebar`, `queryConversation`→`queryChat`
(enum case + `queryChatPrompt`/`queryChatAllowsEdits`; the read-write helper
folded into one body), `startNewConversation`→`startNewChat`, etc. Four files
git-mv'd to match. UI strings updated (Conversation→Chat). Scoped comment cleanup
on chat-surface files only — "conversational" in `SQLiteWikiStore` and the
podcast-transcript plumbing (`TTMLTranscript`, `PodcastTranscript*`,
`AgentLauncher` persistence internals) are untouched.

**@AppStorage key migration.** `conversation.zoom`→`chat.zoom` via a pure,
injectable `AppStorageMigration.migrateZoomKey(from:to:in:)` in WikiFSCore
(`public`, idempotent: copies only when the new key is unset and the old key is
set — no-op for fresh installs), called from `WikiFSApp.init()` with `.standard`.
Covered by `AppStorageMigrationTests`.

**Render-path unification.** `ChatTranscriptView` generalized to take
`events:[AgentEvent]` + parameterized `emptyStateMessage`/`isRunning` (no longer
binds a launcher). `ChatView` now renders one `ChatTranscriptView(events:
displayMessages, …)` from a single call site, where `displayMessages` is a pure
static selector `(isLiveChat ? launcher.events : persistedEvents).transcriptVisible`.
One composer is placed once as a VStack sibling (the live placement), replacing
the persisted-only `.safeAreaInset` footer; the "another chat is responding"
caption is retained. Removed the dead `liveChat`/`persistedChat`/
`persistedTranscript`/`persistedComposerFooter`/`liveComposer`/`hasVisibleChat`.
New `ChatDisplayMessagesTests` cover source selection + the transcriptVisible filter.

**Deferred** to the #286/#287 mode-rework PR (operator-confirmed): removing
`.ask`/`.edit` (read-only Ask mode) — it's persisted (`WikiSelection.ask`,
`EditorTab`, `ChatKind` decoded from the DB `kind` column) and threaded through
~15 files; its removal is a kind/tab migration, not cleanup.

Gate evidence: `swift build` clean; full `swift test` green locally (2057 tests /
165 suites); `make check-prompts` green.

## 2026-07-09 — #285: Copy button on agent chat responses

Each assistant/response bubble in the chat transcript (Ask/Edit + Query) now has
a hover-revealed **Copy** button that writes the raw markdown text (not the
rendered HTML) to the system pasteboard — no more drag-selecting to copy an
answer.

The transcript is a single `WKWebView` (`ChatWebView`), so the button is an
HTML/CSS `:hover` affordance inside the rendered bubble markup, not a SwiftUI
modifier. Each `.chat-assistant` bubble emits a `<button class="copy-btn"
data-copy="<escaped raw text>">`. A delegated `document`-level click listener
posts the `data-copy` payload to a new `copyText` `WKScriptMessageHandler` on the
`WKUserContentController`; the coordinator writes it via the standard
`NSPasteboard.general` idiom. The button shows brief "Copied" feedback.

Scoped to `.chat` style only (the user-facing transcript). The internals/activity
feed (`feedRowHTML`) is unchanged (non-goal per the issue). 6 new tests in
`ChatWebViewLinkifyTests` cover: assistant + result rows carry `data-copy`,
user/tool rows don't, HTML-special-char escaping, and the empty-result guard.

## 2026-07-09 — #245: Semantic + FTS search over chats

Past Ask/Edit conversations are now searchable by meaning + keywords, mirroring
the existing pages/sources pipeline. Design of record:
`plans/chat-semantic-search.md`.

**Schema v28** (purely additive, `createChatSearchTables()` shared by the
fresh-schema fast path + the v27→28 ladder step; `freshFastPathMatchesStepwiseLadder`
holds): `chat_chunks` (per-chunk cosine embeddings, mirrors `page_chunks`/
`source_chunks`, FK `ON DELETE CASCADE` to `chats`), `chat_search` (one-row FTS
sidecar — title + concatenated message text, mirrors `source_search`), and
`chats_fts` (FTS5 external-content over `chat_search` with AFTER INSERT/UPDATE/
DELETE triggers). `deleteChat` cascades to all three — no extra code.

**Incremental write-time embedding (the key decision).** Chats are append-only
and grow over a session, so unlike pages/sources (re-chunk the whole document on
content change), a chat append embeds **only the new user/assistant messages**
and appends their chunks — never re-embedding prior turns. `reembedChatMessages`
runs outside the insert transaction (inference must not happen in a tx) inside
`mutate()`; `appendChatChunks` finds `MAX(chunk_idx)` and inserts after it
without deleting. Tool/system chatter is excluded from the semantic index (noise
for "what was discussed") but stays in the FTS body. `upsertChatSearch` rebuilds
the FTS sidecar inside the append tx + on rename. Best-effort (no-op when vec/
model unavailable).

**Self-heal + bulk backfill.** `ensureSearchIndexesPopulated` gains a
`chat_search` backfill step + a `chats_fts` `_idx` health-check; the debug log
line now reports `chats_fts`/`chatChunks` counts. `ensureEmbedderConsistency`
wipes `chat_chunks` on an embedder-model mismatch. `missingChatEmbeddingWork`
feeds a third `upgradeSearchIndex` phase (`SearchUpgradeState.Phase.chats`;
sheet reads "Embedding chats…"); `storeChatChunks` (replace-all) is the bulk path.

**Search.** `searchSimilarChats` → `hybridSearch` (the single RRF fusion flow),
FTS5 (`searchChatsFTS`) + vec0 cosine (`searchChatsSemantic`, best-matching chunk
per chat), `[ChatSummary]`, FTS-only fallback. Added to the `WikiStore` protocol
+ `WikiStoreModel` wrapper.

**Surfaces.** Chats sidebar search bar (`AgentToolsView`, debounced, off-main
reader-pool path, empty-state "No matching conversations"). `wikictl chat search
--query X [--limit N]` (TSV output) + system-prompt doc.

**Files:** `SQLiteWikiStore.swift`, `WikiStore.swift`, `WikiStoreModel.swift`,
`AgentToolsView.swift`, `SearchUpgradeView.swift`, `ChatCommand.swift`,
`ArgumentParser.swift`; new `ChatSearchTests.swift` (FTS backbone + chunk
mechanics + CLI). Schema-version assertions bumped 27→28 across the suite;
`storeChatChunks` added to `StoreEmissionExhaustivenessTests` noEmit; new chat
search tables added to `FreshSchemaParityTests` expected set.

## 2026-07-09 — Fix #291: ReadScope collapses N+1 store opens in Projection

`children(of: .workingSet)` opened ~35 independent SQLite connections per
enumeration pass (one per leaf, index, singleton doc, and `changeToken()` call).
Each `SQLiteWikiStore(readOnlyURL:)` runs pragma setup + `registerVec` + a WAL
checkpoint on close, making the working-set tests take 165 s+ each.

**Fix:** added a `ReadScope` reference type (`Projection.ReadScope`) that lazily
opens ONE store and caches ONE change token. The three public entry points
(`children(of:)` / `node(for:)` / `contents(for:)`) now create a scoped copy of
`self` carrying a `ReadScope`, so every internal `openReadStore()` /
`changeToken()` call within that operation reuses the same connection. The
private `*Resolved` methods hold the original bodies.

**Result:** `ProjectionTreeTests` (37 tests) went from 165 s+ per working-set
test to ~32 s for the entire suite (~10x). All 1908 fast-tier tests + the
EnumeratorDeletionTests still pass.

**Bonus:** caching `changeToken()` within one pass also makes node versioning
more consistent (previously each call queried independently, risking slight
drift mid-pass). This also speeds up the real File Provider extension.

## 2026-07-09 — Chat File Provider projection + `[[chat:…]]` wikilinks

Chats (store v25 `chats` + `chat_messages`, shipped #119) now project to the
File Provider mount and are linkable from page/source bodies. Design of record:
`plans/chat-projection.md`.

**What shipped:**

### Part 1 — Core foundation (WikiFSCore)
- **`ResourceKind.chat`** added to the `ResourceKind` enum — the single
  declaration point the bus, the `changeToken` contributor registry, and the
  projection descriptor registry all reference.
- **`WikiFSContainerID`** — chat container IDs: `chats`, `chatsByID`,
  `chatsByName`, `indexChatsJSONL`, `chatByIDPrefix`, `chatByNamePrefix`.
- **`ChatTokenContributor`** — appends `chatCount:chatMessageCount` as the
  13th token fold (after bookmarks). A chat create/delete bumps the count;
  a message append bumps the message count. Both advance the token so the FP
  re-enumerates `chats/`.
- **Store emission routing** — all four chat mutators (`createChat`,
  `appendChatMessages`, `renameChat`, `deleteChat`) now route through
  `mutate()` and emit `ResourceChangeEvent(kind: .chat, …)`. Previously they
  used `lock.lock(); defer { lock.unlock() }` directly and emitted nothing —
  the File Provider signaler never heard about chat changes.
  `StoreEmissionExhaustivenessTests` updated (chat mutators in `emit` set).
- **Read methods** — `listAllChatsOrderedByID()` (ULID/creation order, for
  the projection) and `resolveChatByTitle(_:)` (case-insensitive, lowest
  ULID wins — for wikilink resolution).
- **`ChatTranscriptRenderer`** (new, pure) — renders `ChatSummary` +
  `[ChatMessage]` as a readable markdown transcript (title H1, metadata
  blockquote, `## Role` sections per event using `AgentEvent` case dispatch).

### Part 2 — File Provider projection (WikiFSFileProvider)
- **`chatsProjection`** `FlatResourceProjection` — mirrors `pagesProjection`/
  `sourcesProjection`. `by-id` + `by-name` views, each chat as one `.md` file.
  `chatFileNode` sizes from rendered transcript bytes; versioned by
  `updated_at` so any message append re-fetches.
- **Dispatch wiring** — `chatsProjection` added to `flatProjections`; the
  structural folder switch in `node(for:)` handles `chats`/`chatsByID`/
  `chatsByName`. Root enumeration, by-container children, working set, and
  content dispatch are all registry-driven (no per-kind switch arms).
- **`chats.jsonl`** index — `IndexGenerators.chatsJSONL(chats:)` + a
  `chatsJSONLIndex` `GeneratedIndex` descriptor under `indexes/`.
- **Manifest** — extended with `chat_count` + `chats_by_id`/`chat_index` paths.
- **`WIKI-STRUCTURE.md`** — `WikiTreeRenderer.render` now takes `chatCount`;
  the prompt template (`prompts/wiki-tree-render.md`) lists `chats/` in the
  layout. `make prompts` regenerated `GeneratedPrompts.swift`.
- **README bytes** — `chats/by-id/`, `chats/by-name/`, `indexes/chats.jsonl`
  added to the useful-paths list.
- **Token literal assertions** — all 22 hardcoded `changeToken()` assertions
  across `SQLiteWikiStoreTests`/`LogIndexTests`/`SystemPromptTests` updated
  (appended `:0:0` for the chat fold).

### Part 3 — Wikilinks (WikiFSCore + WikiFS)
- **`WikiLinkParser`** — `.chat` added to `LinkType`; `classify` peels `chat:`
  (after `source:`); `isEmptyPrefix` checks `chat:`; embed-skip extended
  (`![[chat:…]]` is invalid — embeds are source-only).
- **`WikiLinkMarkdown`** — `chatHost = "chat"` constant; `target`/`id`/
  `fragment`/`resolvedKind` accept the chat host; `markdownLink` routes
  `.chat` → `wiki://chat?title=…`.
- **`WikiLinkRoute`** — `.chat(title:id:)` case; `linkRoute(for:)` routes;
  `onWikiLinkHandler` navigates to the chat via `selectChat(byID/byTitle)`.
- **`WikiStoreModel`** — `selectChat(byID:)` / `selectChat(byTitle:)` /
  `chatID(forTitle:)`.
- **`WikiRenderContext`** — `chatTitles` set + `chatIDToName` map for
  ghost-link resolution and canonical-ULID display-name self-healing.
- **`WikiLinkRewriter`** — `canonicalize` handles `.chat` (promotes
  `[[chat:Title]]` → `[[chat:<ULID>|alias]]` at the `PageUpsert` seam).
- **`MarkdownHTMLRenderer`** — `visitLink` tooltip for `chat:` prefix.
- **Downstream switches** — `WikiLinkMenuNSItems`, `WikiLinkMenuBuilder`,
  `BookmarksOutlineView`, `SQLiteWikiStore.replaceLinks`/
  `resolveCanonicalLink` updated for `.chat` exhaustiveness.

**Gate:** `swift build` clean; `swift test` — 2030 tests in 162 suites pass.
`make check-prompts` green.

### Part 4 — Agent surface (wikictl + system prompt)
- **`wikictl chat list`** — lists all chats as TSV (`id`, title, kind,
  message_count) or `--json` (same `chats.jsonl` format as the mount index).
- **`wikictl chat get (--id X | --title T)`** — prints a chat's transcript as
  rendered markdown (via `ChatTranscriptRenderer` — the same bytes the File
  Provider projects at `chats/by-id/<ULID>.md`).
- **System prompt** — `prompts/system-prompt-default.md` documents
  `[[chat:Title]]` wikilink syntax: how to link, how to find titles
  (`wikictl chat list`), how to read transcripts (`wikictl chat get`), the
  canonical ULID form, and the no-embed constraint. Regenerated via
  `make prompts`.
- **FP signal list** — `chats`, `chatsByID`, `chatsByName` added to
  `FileProviderSpike.signalChange(forWikiID:)` so the #111 deletion-diff path
  proactively refreshes chat containers (not just the working set).

## 2026-07-08 — #111: File Provider reports deletions via didDeleteItems

Issue #111: deleted sources (and pages) lingered in the File Provider
projection forever. Root cause — `WikiFSEnumerator.enumerateChanges` only ever
called `observer.didUpdate(_:)` with the surviving items; it never called
`didDeleteItems(_:)`, so the daemon had no signal to evict removed rows from
its materialized cache. The code even carried a comment flagging this as a
"known v0 gap."

**Fix (`Sources/WikiFSFileProvider/WikiFSEnumerator.swift`):**
- Added a process-wide, lock-guarded `KnownItemSet` cache keyed by
  `(wikiID, container)` that records the item identifiers the enumerator last
  handed the daemon.
- `enumerateItems` seeds the baseline (the full child set — correct on every
  page, not just the last, since pagination only slices for serving).
- `enumerateChanges` diffs the last-reported set against the current one and
  calls `observer.didDeleteItems(withIdentifiers:)` for identifiers that
  dropped out, then refreshes the cache.
- Survives enumerator recreation within one extension process; a process
  restart falls back to a full re-enumeration (anchor expires), which re-seeds
  the set.

**Tests (`Tests/WikiFSTests/EnumeratorDeletionTests.swift`, 3 new):**
- Deleting a source → the dropped id is reported via `didDeleteItems`; survivors
  come through `didUpdate`.
- No deletion → `didDeleteItems` is never called.
- Deleting a page → same behavior under `pages/by-id`.

**Build/tests:** `swift build` clean; `EnumeratorDeletionTests` (3) and
`ProjectionTreeTests` (29) all pass.

## 2026-07-08 — #275: Conversation view layout parity with PageDetailView

PR #275 (`conversation-zoom-header-fix`) brings the conversation surface's
header, outline, and content layout in line with `PageDetailView` so the two
detail surfaces read as siblings.

**What shipped (7 commits on top of the branch):**
- **Zoom fix** — `ConversationView`'s zoom consumer wiring was dropped in an
  earlier change; re-added `@AppStorage("conversation.zoom")` +
  `.zoomShortcuts`/`.zoomScroll`, `zoom:` flows to both transcript web views,
  and the composer font scales too.
- **Title + date header for live chats** — live conversations had no header
  (only persisted chats did). Added the shared `header(for:)` + divider to the
  live view. Title restyled to `.largeTitle` to match page/source detail.
- **Left margin** — left-aligned transcript + composer at
  `PageEditorMetrics.contentInset` (12pt) instead of a centered 900pt column.
  Removed dead `conversationHorizontalInset`.
- **Header restructured to VStack** — the outline toggle was floating at the
  top-right corner (`HStack(.top)` + `Spacer`). Restructured to a `VStack`
  matching `PageDetailView`: title → metadata row → button row.
- **Show in List button** — added `sidebar.left` button calling
  `store.requestSidebarReveal(.chat(chatID))`; shown only for persisted/live
  chats (hidden in the draft `.ask`/`.edit` state).
- **Draggable outline** — `ChatOutlineView` now mirrors `PageOutlineView`:
  draggable divider with resize cursor, dynamic width via
  `@AppStorage("chatOutlineWidth")`, `.windowBackgroundColor`.
  `withChatOutline` stretches content to `.infinity` so the outline sits flush
  against the right window edge.
- **Full-width content** — removed the 900pt `chatColumnWidth` cap (live +
  persisted transcript, composer, editing banner). All now fill available
  width like `PageDetailView`.
- **Transcript CSS cleanup** — `body { padding: 10px }` → `padding: 10px 0`
  (vertical only) to stop double-stacking horizontal padding with the SwiftUI
  `.padding(.horizontal, 12pt)`.
- **Full-width agent bubbles** — changed `.chat-row .bubble` max-width
  selector to `.chat-user .bubble` so only user messages are capped at
  `min(760px, 86%)`. Agent responses fill the width, eliminating the
  perceived right-margin gap when reading agent text.

**Files touched:** `Sources/WikiFS/ConversationView.swift`,
`Sources/WikiFS/AgentTranscriptWebView.swift`.

## 2026-07-08 — #242: Bookmark created/updated timestamps

Bookmarks now carry `createdAt`/`updatedAt` so the UI can show "date added"/"date
updated" (the companion sort/filter is #241). New **schema v27** migration adds
`created_at`/`updated_at REAL NOT NULL DEFAULT 0` to `bookmark_nodes`, backfilling
every legacy row to the migration time (legacy nodes have no recorded creation time).

**Reorder semantics (the issue's open question):** a **cross-folder move** bumps
`updatedAt`; a **pure same-parent reorder does NOT** (organizing siblings shouldn't
reshuffle a "date updated" view). Label rename also bumps. `moveBookmarkNode`
already computes `sameParent`, so the bump is conditional on `!sameParent`.

**What shipped:**
- **`BookmarkNode`** — `createdAt`/`updatedAt` fields (epoch defaults so existing
  in-memory test fixtures keep compiling; the store always stamps real values).
- **`SQLiteWikiStore`** — fresh schema + v26→v27 ladder step (ALTER + backfill,
  `pragma_table_info`-guarded; also tolerates a missing `bookmark_nodes` table so
  a hand-crafted minimal fixture can't crash mid-migration). `createBookmarkNode`
  stamps both on insert; `updateBookmarkNode` and cross-folder `moveBookmarkNode`
  bump `updatedAt`; `listBookmarkNodes` selects/decodes them.
- **`EditBookmarkSheet`** — read-only "Added …"/"Updated …" relative dates
  (absolute date as tooltip), mirroring `RecentChatRow`'s `chat.updatedAt`.
  "Updated" only appears when the node has actually changed.
- **Schema-version assertions** across the test suite bumped 26→27 (ULID
  `.count == 26` and the FileProvider UserDefaults version left untouched).
- **Tests (6 new):** create stamps both; rename bumps `updatedAt` not `createdAt`;
  cross-folder move bumps; same-parent reorder doesn't; the v26→v27 migration adds
  the columns + backfills a legacy row to ~now (parity-checked NOT NULL DEFAULT 0).
  1979 tests green.

## 2026-07-08 — #253: Blob GC — sweep orphaned blobs

**Shipped (on `feature/253-blob-gc`; 1972 tests green).** Lazy reclamation of
orphaned `blobs` rows — blobs no version references. Deleting a source cascades
its `source_versions`/`source_markdown_versions` rows but leaves the blobs they
pointed at behind; `wikictl admin vacuum-blobs` now sweeps them.

**Open question resolved (§13 Q1):** **lazy-only.** No opportunistic sweep in
`deleteSource` (matches the plan's "nothing depends on eager GC"). The CLI
default is a safe **dry run**; `--apply` deletes. Nothing depends on eager GC.

**What shipped:**
- **`SQLiteWikiStore.vacuumBlobs(dryRun:)`** (+ `BlobVacuumReport`) — one
  reachability predicate (a blob is orphaned when no
  `source_versions.blob_hash` / `source_versions.thumbnail_hash` /
  `source_markdown_versions.blob_hash` cites it; each subquery filters NULLs so
  SQLite's three-valued `NOT IN` never suppresses a live orphan). Count SELECT +
  DELETE share the predicate in ONE `withTransaction`, so the report always
  matches what's reclaimed. **NO_EMIT** (added to `StoreEmissionExhaustivenessTests`'
  `noEmit`: vacuuming orphans changes no projected `ResourceKind` — blobs fold
  into the changeToken only via their version rows).
- **`AdminCommand.swift`** (new, `WikiCtlCore`) — the `admin …` family. First
  subcommand `vacuum-blobs`; `didCommit` true only when `--apply` actually
  deleted (a dry run never wakes the change bridge). Text + JSON output.
- **`ArgumentParser.swift`** — `Command.admin` case + `parseAdminCommand`;
  `Options` generalized from a hardcoded `--json` valueless flag to a
  `booleanFlags` set so `--apply` works; `usageText` gains the `admin` line.
- **`main.swift`** — `execute()` dispatches `.admin`.
- **Tests (13 new):** parser (default dry-run, `--apply`, `--json`,
  missing/unknown subcommand); store GC via the realistic add→delete→vacuum flow
  (orphan reported, dry-run no-op, `--apply` reclaims the orphan while preserving
  a referenced blob, idempotent re-run, no-op when everything referenced);
  `AdminCommand.run` dispatch (dry-run doesn't commit, apply commits, JSON parses
  + matches the report); `WikiManager` preview/apply state flow (2 in
  `WikiManagerTests`).

**Also surfaced in the app UI** (Help menu → "Vacuum Orphaned Storage…"): a
read-only dry-run preview drives a confirm `.alert` (Cancel + destructive
Vacuum; `ByteCountFormatter` for the byte count; "no orphans" empty state).
`BlobVacuumReport` + `vacuumBlobs(dryRun:)` were promoted to the `WikiStore`
protocol (the `@MainActor` model only ever calls protocol methods — no downcast);
`WikiStoreModel.performBlobVacuum` + `WikiManager.previewBlobVacuum`/
`applyBlobVacuum` wire the menu to the active wiki's store.

**Gate:** `swift test` exit 0 — 1974 tests in 160 suites. Resolves §13 Q1;
`plans/graph-model-and-versioning.md` §4.1/§13 marked shipped.

## 2026-07-08 — #263: Separate source origin from materialized format

**Shipped (code-only refactor; 1974 tests green).** Extracted the format-dispatch
logic from `URLFetchService.plan(for:)` into a standalone, URL-independent
`FormatMaterializer.dispatch(data:contentType:stem:extensionHint:)`. Every
byte-producing origin now routes through it.

**What shipped:**
- **`FormatMaterializer.swift`** (new) — `SourceFormat` enum, `FormatPlan`
  struct, `FormatMaterializer.dispatch(...)`. The pure format dispatcher: sniffs
  ambiguous types, converts HTML→Markdown, stores PDF/text/binary verbatim,
  derives filename from `stem` + `extensionHint`. No URL/store/network
  dependency (AC.7: source-grep test enforces this).
- **`URLFetchService.swift`** — `plan(for:)` is now a thin wrapper:
  `nameHint(for:)` extracts `(stem, extHint)` from `response.finalURL` →
  `FormatMaterializer.dispatch` → `mapFormat` to `FetchOutcome.Kind`. Thin
  forwarders for all moved helpers (`normalizedMIME`, `decodeText`, `shouldSniff`,
  `sniffContentType`, `sanitizeStem`, `ensureExtension`, `textExtension`,
  `binaryExtension`) so existing consumers + tests compile unchanged.
- **`SourceMaterializer.swift`** — `WebsiteMaterializer.materializeWithPlan()`
  returns `FormatPlan` (calls `FormatMaterializer.dispatch` directly).
  `WebsiteSnapshot.plan` type → `FormatPlan`. `LocalFileMaterializer` migrated
  to call `FormatMaterializer.dispatch` directly (no synthetic `FetchResponse`).
  **`ZoteroMaterializer` now routes through `FormatMaterializer.dispatch`** —
  fixing the bypass (HTML attachments convert to Markdown; PDFs get extension
  inference + sniffing).
- **`WebsiteSnapshotExtractor.swift`** — takes `FormatPlan`, checks
  `plan.format == .htmlConverted`.
- **`WikiStoreModel.swift`** — `addURLViaWebsite` reads `snapshot.plan.format`,
  maps to `FetchOutcome.Kind`.
- **Tests:** `FormatMaterializerTests` (20 new pure dispatch tests — AC.1/AC.7);
  `SourceMaterializerTests.zoteroProviderSetsItemKeyProvenance` strengthened
  (asserts filename + bytes — AC.4); new `zoteroHtmlAttachmentConvertsToMarkdown`
  (AC.3); `WikiStoreModelZoteroIngestTests` `attachment(key:filename:)` helper
  gains `contentType:` parameter; `WebsiteSnapshotExtractorTests` updated to
  `FormatPlan`.

**Behavior change:** Zotero HTML attachments now convert to Markdown (bugfix).
Existing Zotero sources are unaffected (only new ingests change).

**Gate:** `swift test` exit 0 — 1954 tests in 159 suites.

## 2026-07-08 — #129 Phase E: model subscribes to ALL events; `origin` removed

**Shipped (on `feature/129-phase-e-reload-on-self-write`; tests green).** The
core Phase E change: the model is now a **pure reload subscriber** on the bus —
it reloads on **every** event (both in-app writes and cross-process `wikictl`
writes), not just `.external` ones. The transitional `origin` field
(`.local`/`.external`) is fully removed from `ResourceChangeEvent`, `EventOrigin`,
the store's `localEvent`, the bridge's emit, and all tests. The event shape now
matches §3 decision 2's `(wiki, seq, kind, id, change)` exactly.

**What shipped:**
- **`EventOrigin` + `origin` field deleted** from `WikiEventBus.swift`. The
  `ResourceChangeEvent` is now `(wikiID, kind, id, change, seq)` — no origin
  distinction. Updated `emit` to stop threading `origin` through.
- **`SQLiteWikiStore.localEvent`** — `origin: .local` removed.
- **`WikiChangeBridge.flush`** — `origin: .external` removed; the bridge now
  emits a plain coarse event (the model reloads on it like any other).
- **`WikiStoreModel.subscribeToChanges`** (renamed from
  `subscribeToExternalChanges`) — the `.external` guard is gone; the model
  reloads on ALL events via `reloadFromStore()`.
- **Tests updated** — `WikiEventBusTests` (11 event constructions), 
  `WikiChangeBridgeBusTests` (3 event constructions + 2 test rewrites:
  `localEventReloadsModel` replaces `localEventDoesNotReloadModel`;
  `coarseBusEventReloadsModel` replaces `externalEventReloadsModel`),
  `StoreEmissionTests` (1 `.origin` property assertion removed).

**Deferred (follow-up):** the ~28 per-call `reload*()` sites in the model's
write methods (e.g., `reloadSummaries()` after `save()`, `reloadSources()`
after `addSource`). They are now **redundant** — the bus-triggered
`reloadFromStore()` handles every write — but removing them is a code-cleanup
PR (not an architectural change): each removal risks tests that synchronously
check model list state after a write. The reload methods only touch list
projections (sidebar, sources, chats, bookmarks) — never the editor draft or
selection — so there is **no editor focus/flicker risk** either way.

**Gate:** `origin` fully removed ✅; model subscribes to all events ✅ (proven
by `localEventReloadsModel`); no editor focus/flicker regression ✅ (reload
only refreshes list projections). **1914 tests green** (156 suites).

## 2026-07-08 — #129 slice 2b, Phase D: bookmarks File Provider projection (#125)

**Shipped (on `feature/129-2b-phase-d-bookmarks-projection`; tests green).**
Phase D: the capstone of the Resource abstraction. Bookmarks — which existed
in the store (`bookmark_nodes`, schema v16/v17) and UI (sidebar tree) since
early on but projected **nothing** to the File Provider mount — now appear as a
nested `bookmarks/` tree. Folders are directories; page/source refs are leaf
files serving the target's content. Stale refs (target deleted) render as a
small placeholder so the tree shape is preserved. This is the **nested-shape
proof** the descriptor model needed — it validates `NestedResourceProjection`
against arbitrary-depth folders + leaf refs, which the flat (Phase B) and
singleton-doc (Phase C) retrofits couldn't exercise.

**What shipped:**
- **`NestedResourceProjection` descriptor.** A value type holding `topLevel`,
  `owns`/`nodeFor`/`childrenOf`/`contentFor`/`allNodes` closures — mirrors
  `FlatResourceProjection` but handles arbitrary-depth nesting. One instance:
  `bookmarksProjection`. A `nestedProjections` registry drives every dispatch
  site (`node`/`children`/`contents`/working set), so a future nested kind is
  "add a descriptor".
- **Bookmark node builders.** `bookmarkNodeItem(for:in:)` resolves a
  `BookmarkNode` to a `ProjectedNode` — folders → directories; page refs →
  `<title>.md` serving `PageMarkdownFormat.fileContent`; source refs →
  `<filename>` serving `sourceContent`; stale refs → `Stale Reference.md/.txt`
  placeholder. All versioned by the change token so any mutation re-fetches.
  Identifier scheme: `bookmark-folder:<ULID>` / `bookmark-page-ref:<ULID>` /
  `bookmark-source-ref:<ULID>` (the bookmark-node ULID, not the target's).
- **changeToken `BookmarkTokenContributor`.** Appends a `bookmark_nodes` count
  fold to the token (now 12 fields). Every existing token literal assertion
  updated (`:0` appended). `ChangeTokenContributorTests` updated: `.bookmark`
  removed from `notYetFolded` (all kinds now contribute); order assertion
  extended.
- **Dispatch wiring.** Root children includes the `bookmarks` folder (after
  `sources`, before `indexes`). `children(of:)` default case dispatches to the
  nested projection for the topLevel or any owned folder. `node(for:)` /
  `contents(for:)` dispatch after flat projections. Working set emits all
  bookmark nodes at every depth.
- **8 new characterization tests** in `ProjectionTreeTests` (root children
  enumerate with position order, nested folder children, folder node resolves,
  page-ref serves target content, source-ref serves target content, stale-ref
  placeholder, working set includes all bookmark nodes, empty bookmarks folder
  still listed at root).
- **README bytes** updated to include `bookmarks/` in the useful-paths list.

**Gate:** full suite green — **1914 tests** (156 suites); all Phase B/C
`ProjectionTreeTests` pass (byte-identical for the existing kinds). Schema
unchanged (v26); `changeToken` format-extended (12th field).

**Slice 2b is now COMPLETE** (Phases A–D). The access layer is ready for MCP
(#124) and the daemon (#187) to build on. Phase E (model reload-on-self-write,
drops `origin`) remains deferred to its own slice.

## 2026-07-08 — #129 slice 2b, Phase C: singleton-doc + generated-index descriptors

**Shipped (on `feature/129-2b-phase-c-singleton-index-descriptors`; tests green).**
Phase C: the last non-flat projection kinds collapse to descriptor-driven code.
The bespoke singleton-doc builders (`README.md`, `CLAUDE.md`/`AGENTS.md`,
`index.md`, `log.md`, `WIKI-STRUCTURE.md`/`TREE.md`) and the generated-index
files (`manifest.json`, the three `*.jsonl` under `indexes/`) — each previously
a hand-coded switch arm + builder in `node(for:)` / `children(of:)` /
`contents(for:)` — now route through two registries (`singletonDocs` +
`generatedIndexes`) of value-typed descriptors, exactly as Phase B did for
flat resources. **Behavior byte-identical.**

**What shipped:**
- **`SingletonDoc` + `SingletonDocEntry` descriptors.** A value type holding
  one-or-more root-level filename entries (`entries`), a `nodeFor` closure, a
  `contentFor` closure, and a `participatesInWorkingSet` flag (static docs like
  README never change → excluded from the working set). Five instances:
  `readmeDoc`, `systemPromptDoc` (dual-alias: CLAUDE.md + AGENTS.md),
  `wikiIndexDoc`, `logDoc`, `wikiStructureDoc` (dual-alias:
  WIKI-STRUCTURE.md + TREE.md). The private helper methods
  (`systemPromptNode`, `wikiIndexNode`, `logNode`, `treeNode`, etc.) are
  unchanged — the closures call them.
- **`GeneratedIndex` descriptor.** Collects the per-index variation (identifier,
  filename, parent, generator closure) that was previously inlined in the
  `generateIndexData(for:)` switch. Four instances: `manifestIndex` (root-level),
  `pagesJSONLIndex` / `linksJSONLIndex` / `sourcesJSONLIndex` (under `indexes/`).
  The `parent` field drives root-vs-indexes children enumeration. `generateIndexData`
  is deleted; `indexData(for:)` now looks up the descriptor by id and calls its
  generator. `indexFileNode` takes a descriptor instead of `(id, name, parent)`.
- **Dispatch sites all registry-driven.** `node(for:)` iterates `singletonDocs`
  then `generatedIndexes` before the structural-folder switch; `children(of:)`
  root iterates singleton-doc entries + root-level indexes + flat folders + the
  indexes folder, and the `indexes/` case filters `generatedIndexes` by parent;
  `contents(for:)` dispatches through both registries; the working set emits all
  generated indexes + participating singleton docs.
- **12 new characterization tests** in `ProjectionTreeTests` (singleton-doc node
  resolution + content serving for every alias pair, root-children order, `indexes/`
  children order, manifest size==content, jsonl row counts, working-set
  exclusion of README + inclusion of all non-static docs + indexes).

**Gate:** full suite green — **1906 tests** (156 suites); the 10 Phase B
`ProjectionTreeTests` + 12 pure `ProjectionTests` pass unchanged
(byte-identical). No schema change; no `user_version` bump.

**Next:** Phase D — bookmarks projection (#125) via `NestedResourceProjection`,
the nested-shape capstone.

## 2026-07-08 — PDF source add by URL can fail "database is locked" (#229)

PDFKit's whole-file parse for extracting a PDF display name was running inside
the store's lock, delaying the write transaction long enough for concurrent
writers to exceed the busy timeout. Fix: resolve the display name before
acquiring the lock, and for PDFs run that resolution off the main actor.

## 2026-07-04 — Multi-select pages/sources → bookmark them all into a chosen folder (#151)

Bookmarking was folder-first: the only entry point was from inside the Bookmarks
section (`BookmarksContainerView.onAddPage`/`onAddSource` → `ItemPickerSheet`),
where the folder is known and you pick items. There was no path from the
Pages/Sources lists — you couldn't bookmark a multi-row selection in one gesture.
Implements [#151](https://github.com/tqbf/selfdrivingwiki/issues/151).

- **`onAddToBookmarks` callback + "Add to Bookmarks…" menu item** — both
  `PagesListCallbacks` and `SourcesListCallbacks` gain an `onAddToBookmarks`
  closure; both lists add an **Add to Bookmarks…** context-menu item after the
  Open group, batch-count-aware ("Add 3 Pages to Bookmarks…"). Reuses the
  existing effective-selection logic (selected ∪ clicked) and `@objc` action
  pattern — multi-select was already wired in the `NSTableView`s.
- **`BookmarkTargetPickerSheet`** (`WikiFS/BookmarkTargetPickerSheet.swift`,
  new) — the inverse of `ItemPickerSheet`: the item selection is fixed and the
  user picks-or-creates the destination folder. Single-select (radio-style)
  over existing folders; an inline "New folder name" + Create button calls
  `store.createFolder(parentID: nil, name:)`, after which the new folder
  appears immediately (live `@Observable` refresh of `bookmarkNodes`) and
  auto-selects. Header/footer are noun+count-aware. Confirming calls
  `onConfirm(parentID)`; the container loops the fixed ids through
  `store.addPageRef` / `store.addSourceRef`. Mirrors `ItemPickerSheet`'s chrome
  (420×480, same search-bar style) for visual consistency.
- **`BookmarkNode.displayPath(id:in:)`** (`WikiFSCore/BookmarkNode.swift`) — a
  pure helper walking the `parentID` chain to render `"Research / Papers"` so
  same-named folders disambiguate in the picker. Capped at 64 hops so a
  corrupted parent cycle can't hang the UI.
- **Sheet hosts** — `PagesContainerView` and `SourcesContainerView` each own a
  `@State addToBookmarksContext: BookmarkTargetPickerContext?` and present the
  sheet via `.sheet(item:)`.
- **Tests** — `BookmarkNodeDisplayPathTests` (5 cases: root label, nested join,
  unknown id, nil-label skip, parent-cycle cap). Full suite green: 1398 tests.
- **Docs** — added `plans/multi-select-bookmark.md`; indexed it in `PLAN.md`;
  corrected the stale `BookmarkDestinationSheet` aspirational name in the
  bookmarks-tree row to the real `BookmarkTargetPickerSheet`.
- **Not yet verified live** — the interactive flow (multi-select → context menu
  → sheet → inline Create → Add → refs appear in the Bookmarks tree) compiles
  and passes tests but needs a human to click through it in the running app;
  no schema change so no migration risk.

## 2026-07-04 — Drag sidebar rows onto the welcome screen or any detail tab to open it (#133)

Sidebar rows (pages, sources, bookmarks) weren't draggable. Now any of them can
be dragged onto the welcome screen **or onto any open detail tab** (including
the rendered markdown body) to open its target as a new focused tab.
Implements [#133](https://github.com/tqbf/selfdrivingwiki/issues/133).

- **`SidebarDragPayload`** (`WikiFSCore`, new) — a `Codable` value carrying a
  `kind` (page/source) + id, with a computed `selection: WikiSelection`. Kept in
  the model layer (no `Transferable`) so it's unit-testable; the app layer adds
  `Transferable` + a `UTType.wikiSidebarItem` declared in the app's Info.plist
  (`UTExportedTypeDeclarations`, conforms to `public.item`). The Info.plist
  declaration is mandatory — without it, AppKit can't match the drag to the drop
  target and the gesture silently no-ops.
- **Drag sources** — `PagesListView`/`SourcesListView` gain
  `pasteboardWriterForRow` (a custom `NSPasteboardWriting` carrying the payload
  JSON) + `.copy` local drag-source mask. `BookmarksOutlineView` dual-registers
  the `.string` node id (intra-tree **reorder** still works) AND the
  resolved-target payload (`pageRef`→page, `sourceRef`→source); folders carry
  the node id only. Bookmarks resolve at drag-start, so the drop target is
  bookmark-agnostic.
- **Drop target — SwiftUI chrome** — `WikiDetailView` wraps its whole
  `detailContent` in `.dropDestination(for: SidebarDragPayload.self)` →
  `store.openTab(payload.selection)`. Covers the welcome screen, header, and
  banners. Innermost target, so URL/file drops still fall through to the
  window-level ingest destination.
- **Drop target — WKWebView body** — the rendered markdown is a `WKWebView`, and
  SwiftUI's `.dropDestination` does NOT receive drags over an embedded
  `NSViewRepresentable`'s NSView (AppKit delivers them into the web view's own
  subtree). So `WikiReaderWebView` is itself the `NSDraggingDestination` for its
  body: it overrides `registerForDraggedTypes` to register ONLY the sidebar-item
  type, plus `draggingEntered`/`draggingUpdated`/`performDragOperation` to decode
  the payload and call `store.openTab`. WebKit's internal subviews still register
  their own broad types for web-content drag/drop, but a sidebar payload doesn't
  conform to those, so AppKit walks up to the WKWebView subclass. This is the
  fix that made drops work on the markdown body, not just the top portion.
- **Tests** — `SidebarDragPayloadTests` (Codable round-trip + selection mapping)
  and `SidebarDragPasteboardBridgeTests` (pasteboard-level bridge: writer →
  `NSPasteboard` → decodable JSON, including the bookmark dual-representation and
  folder node-id-only cases). Full 1378-test suite green. Live DnD verified via
  `os_log` traces: drops land on the welcome screen, the SwiftUI chrome, and the
  WKWebView markdown body.

## 2026-07-04 — Sources default-open opens an in-app tab; "Open With" submenu for external editors (#139)

The default-open gestures on **sources** (double-click + the "Open" / "Open N
Sources" context-menu item) launched the file in its default external app
(Preview for a PDF), inconsistent with pages/bookmarks which open an in-app tab
on the same gestures. The external launch is a legitimate workflow but belongs
behind an explicit action. Fixes [#139](https://github.com/tqbf/selfdrivingwiki/issues/139).

- **Sources default-open → in-app tab.** `SourcesContainerView.onOpen` now calls
  `store.openTab(.source(id))` (matching `onOpenBackground` and the pages/bookmark
  path) instead of `fileProvider.openSource(id:)`. The old external behavior
  moves to a new `onOpenExternal` callback. The `SourcesListView` docstring
  (which documented the external double-click as intentional) is corrected.
- **Finder-style "Open With" submenu** on sources, pages, and bookmarks, listing
  the registered editors for the content type (default marked "(Default)",
  separator, then the rest, then "Other…"). `OpenWithMenu` (new) builds the
  submenu from `NSWorkspace.urlsForApplications(toOpen: UTType)` — discovery is
  **content-type based**, not URL based, so the menu builds synchronously from
  the source's MIME/extension (pages are always Markdown); the mount URL is only
  resolved at click time. "Other…" presents an `NSOpenPanel` app picker
  (`AppPicker`). Gated on the File Provider mount being up (same as "Reveal in
  Finder"). Single + batch on sources/pages.
- **`FileProviderSpike.openSource(id:with:)` / `openPage(id:with:)`** gain an
  optional `appURL: URL?`. With nil, the default handler launches (sync
  `NSWorkspace.open`); with an app URL, `open(_:withApplicationAt:configuration:)`
  launches that editor. Both share a private `launch(url:with:)` helper. `openPage`
  resolves via the existing `resolvePageByTitleURL` (same `page-by-title`
  identifier share/reveal use, so no drift) — mirroring `openSource`.
- **Bookmarks.** `FileProviderSpike` is threaded through `BookmarksContainerView`
  → `BookmarksOutlineView` → controller (which had no file-provider access
  before). The pageRef/sourceRef context menu gains the "Open With" submenu;
  `openWithAppAction` routes pageRef→`openPage`, sourceRef→`openSource`. Content
  type for a source bookmark is looked up from the store by id.
- **Drive-by:** dropped an unused `let callbacks` binding in
  `BookmarksOutlineView.acceptDrop` that SourceKit surfaced during the edit.

Not in scope for this cut: the "App Store…" item (Finder's deep-link format is
undocumented) and "Change All" (system default-app binding). Easy to add later.

Gates: `swift build` clean; `swift test` — 1365 tests in 104 suites pass (one
flaky timing test in `PipeDrainingTests.streamProcessCapturesStderrLines` fails
under full-suite load but passes 3/3 in isolation; pre-existing, unrelated).

## 2026-07-04 — Robust `[[wiki-link]]` name handling: lookup-driven resolution, name rules, startup self-heal (v18)

A source/page NAME containing `#` (e.g. "Agentic Static Analysis for C#
Security Auditing") broke every citation to it — the parser split targets on
the FIRST `#`, truncating labels and orphaning links. Fixed structurally, plus
the adjacent robustness gaps:

- **`WikiLinkResolver`** (new, pure): a raw target like `C# Guide#Methods` is
  ambiguous syntactically but not against the real namespace — resolution now
  tries every `(name, fragment)` reading, longest name first (exact full-target
  match wins), taking the first that names an existing page/source. Wired into
  `SQLiteWikiStore.replaceLinks` (link graph), `WikiLinkMarkdown.linkified`
  (reader links + ghost styling), and `WikiStoreModel.preflightLint`.
  `WikiLinkParser.splitFragment` prefers the `#"` quote-anchor delimiter for
  unresolved (ghost) display; `parse` de-dupes by RAW target so two `#`-titles
  sharing a mis-split base both survive.
- **`WikiLinkRewriter`**: rename rewriting matches the old name by direct
  string comparison after `source:` (candidate slices, longest first) instead
  of delimiter guessing; an `isNameKnown` closure from `renameSource` keeps
  longest-name-wins (renaming source "C" can't corrupt a citation of
  "C# Notes").
- **`WikiNameRules`** (new): names that can NEVER be linked are sanitized at
  every write boundary (`|` → `-`, `[`/`]` → `(`/`)`, leading `#` dropped) —
  `createPage`, `updatePage`, `renameSource`, `addSource` (unlinkable FILENAME
  falls back into `display_name`; the filename stays verbatim), and
  `PageUpsert` (before the title→id resolve, so repeated upserts of a dirty
  title can't duplicate pages). `#` inside a name stays legal.
- **Migration v17→18** (`sanitizeStoredNames`): one-time, data-only sweep of
  existing titles/display names that violate the rules (slug recomputed,
  version bumped). Fresh-schema fast path stamps 18.
- **Lenient source resolution** (`resolveSourceByName` pass 3): unique-only
  match on `WikiNameRules.looseMatchKey` (one trailing extension + one trailing
  "(…)" suffix stripped), so a citation of `Some Paper (2026)` finds
  "Some Paper.pdf"; two candidates → no guess. Mirrored in the reader's
  ghost-styling sets.
- **`LinkReconciler`** (new, pure orchestration like `PageUpsert`): re-parses
  every page and rewrites link rows under current rules; run once per model
  lifetime from the top of `upgradeSearchIndex()` (scenePhase-`.active` hook,
  before the MiniLM gates). Heals rows written before a resolution improvement
  or before their target was ingested — page bodies untouched.
- Tests: new resolver/name-rules/sanitization suites (incl. a raw-SQL v17
  tamper/reopen migration test); residual edges (reserved characters inside
  quoted passages; inherent `#` ambiguity when both readings exist) documented
  in `ISSUES.md`.

## 2026-07-03 — Graph-model design: adversarial review hardening (doc-only)

Second-pass adversarial review of [`plans/graph-model-and-versioning.md`](plans/graph-model-and-versioning.md),
prompted by the "should sources and pages be one data model?" question. No code
or schema change — five amendments hardening the design of record:

- **New §4.6 — why `pages` and `sources` stay distinct.** Records the verdict
  that the convergence the unification challenge senses is real but belongs at
  the addressing/link layer (§6, already done via ULID-canonical links), *not*
  the node-storage layer. The three rebuttals: opposite mutability models
  (page bodies through `blobs` would destroy dedup), table-per-class
  unification is worse than two tables (a JOIN on every read for four shared
  columns), and page versioning is a forward-compatibility hook (§14) not a
  commitment. Edge tables stay separate too — FK integrity beats DRY.
- **§4.3 — `refs.version_id` polymorphism trigger condition.** The un-FK'd
  polymorphic column is justified only by the single-writer invariant; Phase 6's
  `page-content` ref makes it triply polymorphic. Added an explicit trigger:
  re-evaluate (split per-kind, or add a discriminator + CHECK) when a third kind
  lands or any non-repoint path writes `refs`. Don't let it decay silently.
- **§9 — migration simplified for pre-launch.** The app has no live users, so
  the soak/dual-write/read-fallback machinery that existed for binary skew
  across stale binaries is unnecessary. v18 is now a clean one-shot migration:
  create tables → hash `content` into blobs + v1 versions + refs → **drop
  `sources.content` in the same step**. Byteless sources are legal from v18 with
  no gating (the byteless sequencing caveat added earlier is superseded). The
  developer's own DB migrates once in place; restorable from VCS.
- **§10 — changeToken is monotone non-decreasing by design.** All three new
  folds grow monotonically (`generation` only increments), so a rollback moves
  the token *forward*, never back. Recorded as an explicit constraint: any
  future "changed since snapshot X" feature that needs rollback-to-prior to
  *decrease* the token is foreclosed and would need a different mechanism.
- **§12 Phase 3 — `original_path` disambiguation is a Phase-3 deliverable.**
  §7's sibling-resolution collision rule (suffixing on `original_path`) was
  forward-referencing the unimplemented website provider. Added it to Phase 3's
  contents (the website provider writes disambiguated `original_path`); Phase 4's
  rendering consumes it.
- **§11/§12 — Apple Podcasts added as a tracked provider (PR #106).** Podcast
  transcript ingest already exists as a URL-path special case (`PodcastEpisodeURL`
  → `ApplePodcastTranscriptService`) against the flat source model. Added to the
  provider list (§11) with a note on how it re-models when Phase 1–3 land
  (byteless source, transcript as derived alternative, recognizer+service become
  a `SourceProvider`), and to Phase 7's leaf providers. Ships independently.
- **§4.7 + A5 — W3C PROV-DM provenance vocabulary (Full alignment).** Adopted
  the PROV-DM core types/relations as schema: new **`agents`** table (PROV
  Agent; normalizes the `provider_kind`/`extraction_technique` strings into
  first-class agents) and **`activities`** table (PROV Activity; generalizes
  `provider_runs`, broadens `kind` to `fetch|extract|edit|import` so extraction
  becomes a real Activity). Relations mapped: `wasGeneratedBy`
  (`activity_id` on both version tables), `wasDerivedFrom` (`parent_id` /
  `source_version_id`), `wasAssociatedWith` (`activities.agent_id`), `used`
  (derivable from derivation+generation, §4.7). Closes the run-level provenance
  gap (an extraction's run is now recoverable, not just implied). Token fold
  renamed `runCount`→`actCount`; §5 graph, §9 migration, §11/§12 phases, and
  all `provider_run`/`extraction_technique` references updated to match.
- **§4.8 — PROV–Dublin Core boundary (context note, no schema).** Recorded the
  [PROV-DC](https://www.w3.org/TR/prov-dc/) mapping as orientation for Phase 3
  provider design: DC responsibility terms (creator/publisher/contributor/
  rightsHolder) → `wasAttributedTo` (already the `agents` table); derivation
  terms → `wasDerivedFrom` (already `parent_id`/`source_version_id`); date terms
  → distinct Create/Publish activities. The "not mapped" descriptive residue
  (title/type/identifier/isPartOf/language/…) is what a provider must capture as
  plain attributes — the high-value ones for determining sources are canonical
  identifiers, type/subtype, isPartOf, title, language. Non-normative context
  for `SourceProvider.materialize`'s return shape.

## 2026-07-03 — Graph-model Phase 0: method-atomic store, savepoint transactions, `WikiReadPool`

Concurrency substrate for [`plans/graph-model-and-versioning.md`](plans/graph-model-and-versioning.md)
(the design of record superseding the `source-versioning-and-providers.md`
draft; also records the "no CozoDB" decision). The "one connection,
main-thread-only" store convention is replaced by structural safety — no
schema change, no `WikiStore` protocol change, zero call-site churn.

- **`SQLiteWikiStore` is method-atomic.** New internal `NSRecursiveLock`;
  all 50 public/internal entry points acquire it for their whole body
  (`lock.lock(); defer { lock.unlock() }`). This closes the two app-level races
  `FULLMUTEX` never covered: byte-identical SQL sharing one cached
  `sqlite3_stmt*` (the historical `String(cString:)` `EXC_BREAKPOINT`), and the
  unguarded `statements` dictionary.
- **`withTransaction` (savepoint nesting).** Outermost = `BEGIN IMMEDIATE`,
  nested = `SAVEPOINT`s; the six raw transaction sites (deletePage,
  replaceLinks, createBookmarkNode, deleteBookmarkNode, moveBookmarkNode,
  replaceChunks) converted. Transaction-owning methods now compose.
- **`renameSource` is atomic** — source row + every page rewrite in one
  transaction (retires phase-d's "eventually consistent" caveat). Embedding +
  FTS side effects run after commit so MLX inference never holds the write
  lock against `wikictl`.
- **New `WikiReadPool`** (`Sources/WikiFSCore/WikiReadPool.swift`): lazily
  opened, reusable read-only snapshot connections (`init(readOnlyURL:)`,
  `query_only=ON`, own statement cache each). `WikiManager.openActive` injects
  one per file-backed wiki; `WikiStoreModel`'s debounced page/source searches
  now run **off-main** through it (main-store fallback kept for in-memory/tests).
- **Docs/invariant updated**: `docs/skills/sqlite-concurrency/SKILL.md`
  rewritten for the new discipline; AGENTS.md invariant bullet replaced.
- Gate: full suite green — **1269 tests / 99 suites** (10 new in
  `StoreConcurrencyTests`: concurrent reader/writer hammer, savepoint
  commit/rollback semantics, nested transaction-owning methods, atomic rename,
  pool visibility/read-only/reuse/async/concurrency).
- **Adversarial review pass** (5 lenses × skeptic verification; 12 confirmed
  of 17 raised): two code fixes — `checkpointDatabase` now steps
  `wal_checkpoint(TRUNCATE)` as a query with a 5s busy wait and fails the
  export loudly when the `busy` column is set (a pooled reader could
  previously make an export silently stale), and `renameSource` reads the
  old name *inside* its transaction (cross-process TOCTOU vs `wikictl`
  rename) — plus ten design-doc amendments (pin-distinct `source_links`
  edges via a `COALESCE`'d unique index, `refs.owner_id` cascade +
  polymorphic-`version_id` integrity note, dual-write/read-fallback rules for
  binary skew during the `sources.content` soak, byteless zero-byte
  projection interim rule, `sources.role` added in v20, §3 sweep pinned to
  `92124bd`).

## 2026-07-02 — Remove configurable sandbox config (`sandbox-config.json`)

The sandbox is **not configurable**. Confinement is fixed by spawn type —
Ingest/Edit get the write whitelist, Ask gets the read-only profile, both always
on — so the persisted `SandboxConfig` (`enabled` toggle + `extraAllowedPaths`
escape hatch) was dead weight. `enabled` was already ignored (Ingest/Edit
sandbox by default; Ask forced read-only by `selectQuerySandbox`), and
`extraAllowedPaths` was a manual-edit-JSON-only widening hatch with no UI. See
[`plans/sandbox-always-on.md`](plans/sandbox-always-on.md) (supersedes the
opt-in "Config" section of `sandbox-agent.md`).

- **Deleted** `Sources/WikiFSCore/SandboxConfig.swift` (the `Codable` model,
  `load`/`save`, `parsedExtraAllowedPaths`) and `Tests/WikiFSTests/SandboxConfigTests.swift`.
- **`SandboxProfile.swift`** — dropped the `extraAllowedPaths` parameter from
  `generate(...)` and `invocation(...)`; removed the now-dead extra-paths splicing
  loop and the `isDirectory` / `escape` private helpers.
- **`AgentLauncher.resolveSandboxInvocation`** — no longer loads any config; builds
  the write-whitelist `SandboxInvocation` directly from scratch dir + DB path.
- **`ClaudePromptHelp.currentSandboxInvocation`** — returns the write-mode
  invocation unconditionally (always on for the Command Template preview); the
  `guard config.enabled` gate and App Group container read are gone.
- **`SandboxProfileTests`** — removed the 5 `extraAllowedPaths` tests; simplified
  the `profile()` helper.
- Gate: `swift build` clean; full suite 1259 tests + sandbox suite 30 tests green.
- Note: an existing `sandbox-config.json` on disk (App Group container) is now
  orphaned and harmless — the app never reads it; not regenerated.

## 2026-07-02 — Fix app launching in the background + "access data from other apps" prompt

Both symptoms were one bug. At cold launch the app appeared behind other windows
and popped a recurring **"Self Driving Wiki would like to access data from other
apps"** TCC prompt. Root cause: `FileProviderSpike.warmCaches(root:)` eagerly
listed the File Provider mount top-down via `FileManager.contentsOfDirectory`
during the launch `.task`. The File Provider runs in the sandboxed **extension**
(separate bundle id), so reading the domain's directory data tripped
`kTCCServiceSystemPolicyAppData` (the `FileProviderDomainID` indirect object) on
every cold launch. That pending prompt held the app in the background until
dismissed. See [`plans/fileprovider-schema-migration-and-cache-warming.md`](plans/fileprovider-schema-migration-and-cache-warming.md).

- **Removed `warmCaches`** entirely (`Sources/WikiFS/FileProviderSpike.swift`) and
  its two `Task.detached` call sites in `resolvePath`. All leaf-resolution methods
  (`openSource`, `resolveSourceByNameURL`, `resolvePageByTitleURL`) resolve by
  **identifier** via `getUserVisibleURL` through the daemon, so they never needed
  the parent pre-enumerated — verified: no prompt, app foregrounds,
  `FileProviderSpikeMountPathTests` pass. If a path-*traversal* access ever needs a
  warm cache, reintroduce warming lazily at that user-initiated call site only.
- **App Group entitlement** (`build.sh`) — added
  `com.apple.security.application-groups = [${APP_GROUP}]` to the **app** target's
  entitlements (previously only the extension had it). The app accesses the group
  container at launch; the entitlement makes that legitimate (the app's
  provisioning profile already authorizes the group) and avoids a slow TCC/sandbox
  evaluation at launch. Parameterized via `${APP_GROUP}` per-developer like the
  existing extension entitlement.

## 2026-07-01 — Bookmarks sidebar section (folders, refs, drag-drop)

A user-defined hierarchical tree of folders, page references, and source
references in a fourth sidebar tab, rendered via `NSOutlineView` for instant
selection performance. Designed and reviewed against native macOS patterns
(Apple HIG sidebar guidance); all reviewer findings (H1–H4, M1–M6, L1–L8)
addressed before merge. See [`plans/bookmarks-tree.md`](plans/bookmarks-tree.md).

- **Schema v16/v17** — `bookmark_nodes` table (self-referencing `parent_id`
  with `ON DELETE CASCADE`, `position` for ordering, `kind` for
  folder/page_ref/source_ref). Fresh-schema fast path creates at v17;
  migration ladder creates `view_nodes` (v16) then renames (v17).
- **Store CRUD** — `listBookmarkNodes`, `createBookmarkNode` (with sibling
  position shift + defense-in-depth renumber), `updateBookmarkNode`
  (label-only), `deleteBookmarkNode` (cascade + renumber), `moveBookmarkNode`
  (shift to avoid ties, renumber, **cycle prevention** via parent-chain walk).
  All renumber methods are `throws` (no `try?` swallowing).
- **Core types** — `BookmarkNode`, `BookmarkNodeKind` (`BookmarkNode.swift`);
  `BookmarkTreeBuilder.swift` with pure-logic `buildBookmarkTree()`;
  `BookmarkTreeItem` rendered-tree type.
- **Model** — `bookmarkNodes` array, `bookmarkTree` computed property; mutation
  methods (createFolder, addPageRef, addSourceRef, renameBookmarkNode,
  deleteBookmarkNode, moveBookmarkNode). `createFolder` returns the new node id.
- **UI** — `BookmarksContainerView` (header bar with compact trailing-edge
  action buttons per Apple HIG), `BookmarksOutlineView` (NSOutlineView wrapper
  with cached parent→children map, content-aware reload detection, expand-state
  preservation across reloads, native drag-and-drop with cycle-safe acceptDrop),
  `EditBookmarkSheet`, `ItemPickerSheet`, `BookmarkDestinationSheet`.
- **Tests** — `BookmarkNodeStoreTests` (schema, CRUD, cascade delete, position
  renumbering, move/reorder, stale refs, **cycle prevention** — 4 tests) +
  `BookmarkTreeBuilderTests` (tree assembly, empty folders, selection). 1248
  tests pass.

## 2026-06-30 — MiniLM (Metal) embeddings shipped; search index hardened

- **MiniLM/MLX embeddings now run in the bundled app.** It had been crashing
  immediately on launch (a silent `exit()`): MLX couldn't find its `metallib` (it
  searches next to the binary, not via the bundle) and its default error handler
  `exit()`s. Fixed the bundle layout so MLX finds it, and moved `MLXEmbedders`
  off `WikiFSCore` so the File Provider extension no longer transitively links
  Metal.
- **Search ranking fixed.** The launch self-heal never rebuilt the FTS5 index for
  wikis migrated through the schema ladder — a `count(*)`-based health check is
  always satisfied for external-content FTS5 tables — so search degraded to
  semantic-only and ranked poorly. The check now detects an unbuilt index and
  rebuilds.
- **Embedding is a one-time, blocking, single-threaded upgrade** — no background
  "backfill." All `SQLiteWikiStore` access is main-thread only (a blocking modal
  sheet makes the upgrade the sole owner of the store); only MLX inference runs
  off-main. New content embeds inline at write time, so the upgrade is usually an
  instant no-op.
- **`searchSimilar` / "Find Similar…" restored** (it had been a no-op since the
  NLEmbedding main-thread freeze); MiniLM is cheap enough to run on demand.

## 2026-06-29 — Embedding inference stopped blocking the main thread

Clicking a page (and app startup) had a ~0.4–2 s stall introduced by the
semantic-search work (PR #91). Root-caused via `ReaderTiming`/`DebugLog`
instrumentation (subsystem `com.selfdrivingwiki.debug`, category `render`):

- The **page-row context menu** in `SidebarView.pagesSectionRows` eagerly called
  `store.searchSimilar(query:)` for every page row in its `.contextMenu` builder.
  SwiftUI evaluates that builder on every sidebar layout pass, so a single page
  selection ran `searchSimilar` (→ `NLEmbedding.vector(for:)` on the **main
  thread**) for all ~232 rows — hundreds of inferences per render, freezing the
  UI. (Sources were fast only because their rows lack that menu.)
- Separately, at launch `backfill` called `EmbeddingService.isAvailable`, which
  **loads the `NLEmbedding` model** (~0.3 s on the main thread) even when there
  was zero missing work to embed.

**Fixes (this branch):**
- `WikiStoreModel.searchSimilar` / `searchSimilarSources` are **no-ops (`[]`)**
  until NLEmbedding inference is moved off the main actor; the "Find Similar…"
  context-menu item is removed.
- `backfill` now short-circuits on empty work **before** touching the embedding
  model, so a warm DB skips the model load at startup.
- `EmbeddingService` is instrumented end-to-end (`embed.model LOAD`, `embed.isAvailable`,
  `embed.chunked ENTER/EXIT`, `embed.call <ms> …`, `embed.STACK …`) so every hit
  is visible via `log show`. Kept as witness marks.
- Reader timing probes added: `click.to-startLoad`, `click.to-painted`,
  `webview.main-hop`, `webview.task-start`, `webview.html-load`.

**Follow-up (not done here):** move `NLEmbedding` inference off the main actor
(the comment claims BNNS crashes off-main, but that's most likely a shared-model
concurrency issue — serialize on a dedicated background thread) and restore
"Find Similar" with a lazy, off-main search.

## 2026-06-29 — File Provider extension no longer links AppKit/PDFKit (macOS 26 crash)

The `WikiFSFileProvider` extension crashed at launch on macOS 26 inside
`_EXRunningExtension._start` because its binary linked **AppKit** — forbidden
for a `com.apple.fileprovider-nonui` extension.

**Root cause.** `DisplayNameResolver` (in `WikiFSCore`) `import`s PDFKit, and
PDFKit transitively links AppKit. The extension links `WikiFSCore` as its sole
read-only dependency, so it inherited AppKit linkage even though it never runs
the PDF-title path.

**Fix (injectable seam).** PDF-title extraction is now injected:
`DisplayNameResolver.pdfTitleExtractor` defaults to a `nil`-returning closure,
keeping `WikiFSCore` — and therefore the extension — free of PDFKit/AppKit at
link time. The real PDFKit implementation lives in the **app** target
(`Sources/WikiFS/PDFTitleExtractor.swift`), which the extension does **not**
link, and is installed at launch via `DisplayNameResolver.installPDFTitleExtractor()`
(called from `WikiFSApp.init`). Non-app contexts (extension, `wikictl`, tests)
keep the default and fall through to the filename.

**MLX note.** This branch was originally built on top of a MiniLM/MLX embedding
feature series; that MLX work was **dropped** (it was a separate concern and
also pulled Metal/Accelerate/CoreML into the extension). The fix now stands on
`main` alone, where isolating PDFKit is *sufficient* to remove AppKit from the
extension. NL-based embeddings (PR #91) remain unaffected.

**Evidence.** `swift build` clean; 1211 tests pass; `otool -L` on the rebuilt
`WikiFSFileProvider` binary shows **no** AppKit/PDFKit/AVFoundation/Metal (only
FileProvider/Foundation/NaturalLanguage/JavaScriptCore/CFNetwork/Security). The
app binary still links PDFKit/AppKit, so PDF display-name resolution is
preserved. See PR #93.

## 2026-06-29 — Fresh-DB fast path (migration consolidation)

The stepwise ladder (v0→v14) is correct but does heavy create→mutate→drop churn
on a **fresh** DB: v7/v12 create single-row embeddings that v14 immediately
drops; v2 creates `ingested_files` that v10 renames to `sources`; v8 creates
`file_markdown_versions` that v10 renames; `source_links` is created (v10) then
rebuilt for cascade (v11). ~40 DDL statements for a fresh DB.

**Consolidation (safe):** added `createFreshSchemaV14()` — when `user_version ==
0`, build the complete current schema in ONE block and jump to v14, skipping all
the churn. The stepwise ladder is preserved verbatim as `migrate(from:)` for
EXISTING dbs (version >= 1), which MUST keep their irreversible data migrations
(renames, column adds, table rebuilds) — those cannot be collapsed without
risking existing data. Legacy index names (`ingested_files_created`,
`file_markdown_versions_file`) that survive the ladder's renames are reproduced
verbatim in the fast path.

**Parity guard:** `FreshSchemaParityTests` forces a fresh DB through the full
ladder (via a test-only `forceLadderMigration` init flag) and asserts the two
produce identical schemas (object inventory + per-table columns + FKs + version).
`swift build` clean; **1211 tests pass**.

## 2026-06-29 — v14 per-chunk RAG embeddings (fixed launch crash; async backfill)

**Crash:** the app aborted at launch with an uncatchable C++ `std::bad_alloc`.
Root cause (via `lldb` break on `__cxa_throw`): the open-time self-heal called
`NLEmbedding.vector(for:)` on whole source bodies; above ~250k chars NLEmbedding
throws `std::bad_alloc` (Swift can't catch C++ exceptions → terminate). It was
never seen before because the embedding recompute only ran via the never-pressed
"Reindex Search" button; the self-heal made it run at every launch. Measured:
NLEmbedding ≈ 5 s / 100k chars and crashes ≥ ~250k.

**Fix — per-chunk (RAG-style) embeddings, computed async:**
- **`TextChunker`** (`Sources/WikiFSCore/TextChunker.swift`): pure-Swift port of
  LangChain `RecursiveCharacterTextSplitter` / Chonkie `RecursiveChunker`
  (separator hierarchy `\n\n → \n → space → char`, ~4k-char chunks + 10% overlap).
  Research confirmed only Recursive/Sentence chunkers are portable to on-device
  Swift; Late/Semantic/Neural need a transformer's token embeddings (NLEmbedding
  is opaque). No mature Swift chunking library exists.
- **`EmbeddingService.chunkedEmbeddings(for:maxChunks:)`**: chunks the text, embeds
  each chunk (small → fast + crash-free), caps to 64 chunks (evenly sampled across
  the doc so a deep passage is still represented). `embeddingBlob(for:)` kept for
  short query strings.
- **v14 migration:** `page_chunks` + `source_chunks` (one BLOB per text chunk,
  FK ON DELETE CASCADE); drops the old one-row-per-doc `page_embeddings` /
  `source_embeddings`. Semantic search now ranks by each doc's BEST-matching chunk
  (`GROUP BY doc … MIN(vec_distance_cosine)`), so a query hits the specific passage.
- **Async, not at launch:** embedding is too slow to run synchronously (full corpus
  ≈ minutes). Removed from `init`; `WikiStoreModel.backfillMissingEmbeddings()`
  (kicked off on wiki open) computes vectors OFF the main actor while all DB
  reads/writes stay on main (single-connection store). Resumable/incremental — only
  docs still missing chunks are embedded, so a killed run continues next launch. FTS
  search works immediately; semantic search fills in as chunks land.
- Protocol: `storePageEmbedding`/`storeSourceEmbedding` → `storePageChunks`/
  `storeSourceChunks` (+ `missingPageEmbeddingWork`/`missingSourceEmbeddingWork`).
  `PageUpsert.upsert` (wikictl) chunk-embeds pages too.

**Verified:** `swift build` clean; **1209 tests pass** (incl. 7 new `TextChunkerTests`).
Rebuilt the `.app` via `./build.sh debug` and launched against the live DB: no crash,
v14 migration applied, background backfill streamed `backfill: page … ← N chunk(s)`.
(source_chunks fills after pages; was killed mid-run at 73 page-chunks.)

**Follow-up crash (SIGSEGV) + fix:** the first cut ran the backfill on a detached
background queue. That crashed with `EXC_BAD_ACCESS` inside `BNNSFilterApplyBatch` —
**NLEmbedding/CoreNLP inference is not safe off the main thread.** Moved the backfill
onto the main actor, embedding chunk-by-chunk with `Task.yield()` between chunks so
the UI stays responsive between the ~0.3 s NLEmbedding calls. Re-verified: app ran
60 s through active backfill with no crash (newest `.ips` unchanged). Known minor
warning (non-fatal): "reentrant operation in NSTableView delegate" during backfill
writes — to revisit. The per-chunk main-actor jank is itself the strongest argument
for the MLX MiniLM move (Metal inference is safe off-main).

**Deferred (recommended separately): MLX all-MiniLM-L6-v2.** NLEmbedding is the
bottleneck — ~5 s / 100k chars, so a full-corpus first backfill takes minutes.
Research says MLX MiniLM on Metal/GPU is low-single-digit ms/sentence
(100-1000× faster), better quality, no crash, predictable 512-token truncation —
using `mlx-community/all-MiniLM-L6-v2-bf16` + Apple's `MLXEmbedders` (model
downloaded on demand, gitignored, ~45 MB bundled into the .app; no conversion
pipeline). Design + phased plan are written
(`plans/mlx-minilm-design.md`). **Phase 0 done** — `tools/minilm-prepare/`
downloads the bf16 model on demand (gitignored, pinned HF revision `b6691709`,
SHA recorded for reproducible builds) and validates it. Gate reframed: MLX
embedding engines diverge from HF at ~0.99 cosine (a BERT-impl difference, not
bf16/precision), so the bar is **non-garbage** (min 0.9871 ≥ 0.95) +
**self-consistent** (paraphrase 0.636 ≫ unrelated 0.028), both PASS. The real
parity/quality bar is Swift `MLXEmbedders` (Phase 1) + AC.4 (search quality).
Phases 1–3 pending. (Pivoted from an earlier CoreML/ANE design that hit
conversion/quantization/ANE-compile problems.) When adopted, swap it in behind
`EmbeddingService` (chunk index + queries unchanged).

## 2026-06-29 — Unified, self-healing hybrid search (removed manual Reindex)

**Bug:** source search returned **no results** in the app. Root cause: the live
DB (`01KVHRPBPRY368HJTZNSB75D7R`, 71 sources) had `source_search=0` and
`source_embeddings=0` rows — both halves of the hybrid query came back empty.
The only thing that populated these was the manual **"Reindex Search"** sidebar
button (`rebuildFTS` + `recomputeMissing*`), which was never run against
pre-existing sources. Verified via `DebugLog` + direct sqlite counts.

**Fix — one search flow that self-heals on every writable open:**
- **Unified the duplicated page/source search flow** into one generic
  `hybridSearch(kind:query:limit:id:fts:semantic:)` (FTS5 bm25 always; +vec0
  cosine fused via `RankFusion.rrf` when vec+model available; FTS-only fallback).
  Both `searchSimilar` and `searchSimilarSources` route through it — the two can
  no longer drift.
- **Unified embedding store + maintenance:** `storePageEmbedding`/
  `storeSourceEmbedding` → one generic `upsertEmbedding(table:idColumn:…)`; the
  two `recomputeMissing*` → one shared `embedMissing(kind:rows:store:)`.
- **Self-heal `ensureSearchIndexesPopulated()`** runs in `init(databaseURL:)`
  (writable only; NOT the read-only File Provider). Idempotent, near-zero cost
  when healthy: (1) seed native-markdown sources lacking a processed-markdown
  version, (2) backfill `source_search`, (3) rebuild `pages_fts`/`sources_fts`
  only when lagging, (4) `recomputeMissingEmbeddings` + `recomputeMissingSourceEmbeddings`.
- **Removed the manual reindex:** the sidebar "Reindex Search" button, and
  `recomputeMissingEmbeddings`/`recomputeMissingSourceEmbeddings`/`rebuildFTS`
  from the `WikiStore` protocol + `WikiStoreModel`. (Kept on the concrete
  `SQLiteWikiStore` — used by self-heal + tests.)

**Verified:** `swift build` clean; **1202 tests pass**. Against a snapshot copy
of the real DB, applying the FTS self-heal steps took `source_search` 0→71 and
`sources_fts` 0→71, and the bm25 query returned relevant hits for "dissociation"
and "hypnosis". (The embedding half can't run under raw sqlite3 — it needs
`NLEmbedding` — but is the same path covered by unit tests; it populates on the
app's next open.)

**Known, out of scope:** `wikictl` resolves the app-group container to
`group.org.sockpuppet.wiki` (empty) while the live data is in
`group.com.willsargent.wiki`, so `wikictl source search` can't reach the live DB
(`no wiki matching`). This is a pre-existing wikictl container mismatch, not a
search bug.

## 2026-06-29 — `WikiIdentifiers` reads `signing/local.config` (debug wikictl just works)

The plain SwiftPM CLI (`.build/debug/wikictl`) resolved the **wrong** App Group
(`group.org.sockpuppet.wiki`, empty) while the live data lived in
`group.com.willsargent.wiki`: it has no Info.plist (so the `WIKIAppGroupID`
lookup missed) and no `wiki-identifiers.env` sidecar, so it fell through to the
compiled-in default. The GUI app was unaffected (it gets the value from its
Info.plist via `build.sh`).

**Fix:** added `signing/local.config` (the gitignored, per-developer file that
`build.sh` already reads) as a resolution step in `WikiIdentifiers.resolve`,
checked by walking UP from the executable until a repo root containing it is
found. `appGroupID` ← `APP_GROUP`, `fileProviderID` ← `EXT_BUNDLE_ID`. New order:
env → Info.plist → `wiki-identifiers.env` sidecar → `signing/local.config` →
default. Refactored the shared `KEY=VALUE` parsing into `parseKV`.

**Non-breaking:** no per-user value is committed. Fresh clones / CI without
`signing/local.config` fall through to the default unchanged. Verified: `.build/debug/wikictl --wiki "My Wiki" source search --query dissociation` now
returns real hits with NO env var; 1202 tests pass.

## 2026-06-28 — FTS5/BM25 keyword search (v13); vec layer found broken

Discovered the **semantic (vec) search never actually ran in the app**: macOS's
system SQLite is built with `SQLITE_OMIT_LOAD_EXTENSION`, so
`sqlite3_enable_load_extension`/`sqlite3_load_extension` don't exist as symbols
→ `dlsym` returns NULL → `vec0.dylib` never loads → `isVecAvailable()` is always
false → every search (pages AND sources) degraded to filename-only `LIKE`. The
body was never indexed or searched. Confirmed via `DebugLog` instrumentation and
`PRAGMA compile_options` (`OMIT_LOAD_EXTENSION`; `ENABLE_FTS5` present).
See [`plans/search-fts5-hybrid.md`](plans/search-fts5-hybrid.md) (3-phase plan).

**Phase 1 done — FTS5/BM25 backbone (always-on, fully unit-testable):**
- **v12 → v13 migration:** `pages_fts` = external-content FTS5 over `pages`
  (`title`, `body_markdown`) maintained by AFTER INSERT/UPDATE/DELETE triggers
  (zero page-write Swift changes); `sources_fts` = external-content FTS5 over a
  new `source_search(source_id PK → sources(id) ON DELETE CASCADE, title, body)`
  sidecar (body is the HEAD of the version chain, not inline). Porter tokenizer
  (stemming: `run`↔`running`, `car`↔`cars`). Existing content backfilled lazily
  via `rebuildFTS()` (Reindex).
- **Store methods:** `searchPagesFTS`/`searchSourcesFTS` (bm25, `ORDER BY rank`),
  `upsertSourceSearch(sourceID:body:)` (resolves `display_name ?? filename`),
  `rebuildFTS() -> (pages, sources)`. Added to the `WikiStore` protocol + model.
- **Write hooks:** `addSource` (name-only), `appendProcessedMarkdown`,
  `renameSource` now keep `source_search` fresh (triggers keep `*_fts` in sync).
- **Search switch:** the `LIKE` fallback in `searchSimilar`/`searchSimilarSources`
  is now **FTS5 bm25 over the full body** (kept as the path taken when vec is
  unavailable — i.e. today, and in tests/`wikictl`).
- **Tests:** new `FullTextSearchTests` (body search with zero filename overlap,
  porter stemming, name-only, bm25 ranking, delete cascade, rebuild). All pass.
  Existing source-search tests now exercise FTS and still pass.
- **Phase 2 done — vec fixed via static amalgamation:** the loadable-`dylib` path
  was impossible on macOS (`OMIT_LOAD_EXTENSION`). Vendored `sqlite-vec.c`
  v0.1.9 into a new `CSqliteVec` SwiftPM C target (`Sources/CSqliteVec/`, +MIT
  license + provenance README) compiled `-DSQLITE_CORE -DSQLITE_VEC_STATIC`,
  linked against the **system** libsqlite3 (no second SQLite, no
  `load_extension`). Registered per-connection via the sqlite-vec C/C++ guide's
  "direct call" pattern — `sqlite3_vec_init(db, NULL, NULL)` — exposed as
  `wikifs_vec_register` and called from both inits. Removed the dead
  `dlopen`/`dlsym`/`load_extension` loader, the `vec0.dylib` copy in `build.sh`,
  and `Resources/vec0.dylib` itself — `make`/`swift build` now Just Works for any
  contributor (no dylib, no env vars). Proven by
  `vecScalarIsRegisteredAfterStaticLink` (vec_distance_cosine registers under
  `swift test` now); full suite green (1197 tests).
- **Phase 3 done — RRF hybrid reranker:** `RankFusion.rrf` (pure Swift,
  `Sources/WikiFSCore/RankFusion.swift`) fuses the semantic + FTS result lists by
  Reciprocal Rank Fusion (`score = Σ 1/(60+rank)`). `searchSimilar` /
  `searchSimilarSources` now always compute FTS5 (the lexical floor), and when vec
  + the embedding model are available also run the cosine query and fuse — a doc
  matching BOTH lexical + semantic outranks one matching only one. Degrades to
  FTS-only when vec/the model is unavailable (tests, `wikictl`). Fully unit-tested
  (`RankFusionTests`); full suite green (1202 tests). **Search now works end-to-end.**

## 2026-06-28 — Semantic (vector) search for sources

Added meaning-based search over sources, mirroring the existing page-embedding
pipeline (sqlite-vec cosine + Apple `NLEmbedding`) verbatim on a new per-source
embeddings table. Surfaced in the Sources sidebar search box and via a new
`wikictl source search` command so the agent finds source material by meaning.
See [`plans/source-semantic-search.md`](plans/source-semantic-search.md).

**Phase 1 — storage & embeddings (`SQLiteWikiStore` / `WikiStore`):**
- **v11 → v12 migration:** new `source_embeddings(source_id PK → sources(id) ON
  DELETE CASCADE, embedding BLOB)` table, mirroring `page_embeddings` (v7).
- `storeSourceEmbedding(id:blob:)`, `searchSimilarSources(query:limit:)`
  (cosine ranking with a `LIKE` filename/display-name fallback), and
  `recomputeMissingSourceEmbeddings() -> Int` (backfills gaps; embeds on
  processed-markdown HEAD body + name, name-only when no markdown). All three
  added to the `WikiStore` protocol (only `SQLiteWikiStore` conforms).
- **Re-embed hooks** keep embeddings fresh: `reembedSource(sourceID:body:)` is
  called from `appendProcessedMarkdown` (covers extraction seeding, raw-text
  seeding, user edits, and revert) and `renameSource` (title changed).
  Best-effort (`try?`); falls back to reindex backfill when vec is unavailable.
- `searchSimilarSources` enumerates the 11 source columns explicitly — **never
  `SELECT s.*`** (the physical `sources` table has a `content` BLOB between
  `byte_size` and `created_at` that would shift `sourceSummary(from:)`'s indices).

**Phase 2 — model & UI:** `WikiStoreModel` gained `sourceSearchQuery` +
`sourceSearchResults` + a debounced (300 ms) `scheduleSourceSearch`. A Sources
search bar (mirroring the Pages `searchBar`) sits between the filter picker and
the rows, swapping to ranked results with a "No matching sources" empty state.
`recomputeMissingSourceEmbeddings()` on the model first seeds markdown-native
sources (so they get *content* embeddings) then calls the store recompute.
"Reindex Search" now also runs the source recompute.

**Phase 3 — agent CLI + system prompt:** `source search --query "…" [--limit N]`
prints ranked `id<TAB>name` lines (display name, filename fallback), read-only
(mirrors `PageCommand.search`). `--limit` validated 1–100 (default 10). Added to
`ArgumentParser.usageText` and the `SystemPrompt.swift` tooling list, with a note
that source *content* is searchable (complementing `sources.jsonl` metadata and
`source cat` raw bytes).

**Tests:** new `SourceEmbeddingSearchTests` (17 tests) covering the v12
migration, the LIKE fallback (find/limit/display-name/empty/no-`SELECT *`
regression), recompute/re-embed no-op behavior without vec, the `ON DELETE
CASCADE`, and the CLI TSV output + arg validation. The model-gated cosine path
cannot run under `swift test` (NLEmbedding is app-bundle-gated) — same limitation
as page search; AC.1/AC.3/AC.6 validated manually in the running app. Updated
schema-version assertions (11 → 12) across 6 existing tests. **1189 tests green.**

Branch `feature/source-semantic-search`.

## 2026-06-28 — Reveal in Finder for pages and sources

Added a "Reveal in Finder" action on every page and source surface so users can
locate the File Provider-mounted file in Finder (to drag to other apps, open in
Terminal, etc.).

**New methods on `FileProviderSpike`.**  `revealPageInFinder(id:)` and
`revealSourceInFinder(id:)` resolve the item's user-visible URL via the daemon
(reusing the existing `resolvePageByTitleURL` / `resolveSourceByNameURL` helpers)
then call `NSWorkspace.shared.activateFileViewerSelecting([url])` — the same
call used by `VerificationPopover` for the wiki root.

**Surfaces:**
- **Page sidebar context menu** — "Reveal in Finder" after Share, single-select
  only (multi-select would open N Finder windows).
- **Page detail view** — button in the view-mode header row, after Share.
- **Source sidebar context menu** — wired via a new `onRevealInFinder` closure on
  `SourceRow`; single-select only.
- **Source detail view** — button in the view-mode header row, after Share.

All surfaces are guarded by `fileProvider.path != nil` so the item is hidden
until the domain is mounted. Branch `feature/add-reveal-in-finder`, PR #90.

## 2026-06-28 — Dirty-editor protection and edit-mode persistence

Three editor-UX gaps closed. See [`plans/dirty-editor-protection.md`](plans/dirty-editor-protection.md) for the design.

**Outline button in edit mode.** Added the `sidebar.right` toggle to the
edit-mode toolbar in both `PageDetailView` and `SourceDetailView` (it existed
only in read mode before). State is shared via `@AppStorage("isOutlineExpanded")`
so the panel's visible/hidden position persists across mode switches.

**Per-tab edit-mode persistence.** `EditorTab` gained `isEditing: Bool`.
`WikiStoreModel.setTabEditing(tabID:isEditing:)` persists the flag from the
view. `PageDetailView` and `SourceDetailView` sync on every enter/exit-edit event
and restore the flag when `store.activeTabID` changes. A `lastKnownActiveTabID`
sentinel distinguishes tab switches (restore from tab flag) from in-tab
navigation (reset to false). `SourceDetailView` adds a `shouldRestoreEditing`
flag that defers the `editBuffer` repopulation until `headVersion` loads.

**Close-tab confirmation.** `WikiStoreModel.closeTab(id:)` now defers when
`tabs[index].isEditing && id == activeTabID`, setting `pendingCloseTabID`.
`confirmCloseTab()` / `cancelCloseTab()` apply or abandon the deferred close.
`ContentView` shows "Close Tab?" for page/other tabs (page drafts are saved
automatically by `flushPendingSave` inside `setActiveTab`). `SourceDetailView`
shows its own alert and calls `flushEditIfDirty()` before `confirmCloseTab()` so
the save runs while `file.id` still refers to the closing tab's source.

## 2026-06-28 — Page body contract: clean body in SQLite, decoration via file provider

`body_markdown` in SQLite now stores only the prose body — no H1, no YAML
frontmatter. The File Provider extension generates both on the fly when serving
`.md` files to Finder and external tools. This fixes the outline-panel flicker
and makes renames safe.

**Root cause of the flicker.** `PageDetailView` had a `readerMarkdown` computed
property that stripped the leading H1 from `draftBody` before passing it to
`PageOutlineView`. Because `draftTitle` and `draftBody` are set sequentially in
`loadDrafts`, there was a render window where the new title was live but the old
body was still in place. The guard inside `readerMarkdown` failed to match,
returning the full old body (H1 included), which briefly appeared in the outline.

**New contract.** A shared `PageMarkdownFormat` enum in `WikiFSCore` owns both
directions:
- `stripped(body:title:)` — removes leading YAML frontmatter block, matching H1,
  and the blank lines that separate them from the body. Used in `loadDrafts` and
  `rename(_:to:)` so the editor and SQLite always hold clean body.
- `fileContent(for:)` — generates `---\ntitle/date frontmatter---\n\n# Title\n\n
  body` for the file provider. Calls `stripped` internally, so pages whose
  `body_markdown` still has an embedded H1 (pre-migration) produce correct
  single-title output without a DB migration.

**`Projection` changes.** Both `pageFileNode` (reported `documentSize`) and
`contents(for:)` call `PageMarkdownFormat.fileContent(for:)`, so the file size
the daemon caches and the bytes it serves are always derived from the same
formula. Frontmatter schema: `title` (double-quoted, `"` escaped) and `date`
(local `YYYY-MM-DD` from `updatedAt`).

**Editor warning.** `saveWarningBanner` in `PageDetailView` now shows an orange
warning when `draftBody` starts with `---`, pointing the user to the title field
above.

**`readerMarkdown` deleted.** The three call sites in `PageDetailView` now
reference `store.draftBody` directly; no stripping is needed because the body is
always clean.

**Migration.** Automatic and zero-downtime: stripping in `loadDrafts` is
backwards-compatible; pages converge to the new format on first load + save.

**Tests.** 12 new `PageMarkdownFormatTests` covering `stripped` (H1 match/miss,
frontmatter only, frontmatter + H1, mismatch, empty) and `fileContent` (format,
no-double-H1, empty body, title escaping). 1170 tests total, all passing.

## 2026-06-28 — Clean up link context menus and sidebar context menus

Removed redundant actions and reorganized the right-click link context menu
and the sidebar context menus for pages and sources.

**Link context menu (both page and source detail views):**
- Removed "Copy File Path", "Download…", "Copy Link", and "Open in Browser"
- WebKit's native "Open Link" covers browser-open; Share covers file-copy/download
- "Open in Background Tab" inserted right after "Open Link" for wiki links
- Share icon added to the custom Share item; resolves the canonical URL from
  the daemon (`getUserVisibleURL`) for wiki links, passes the raw URL for
  external links
- Menu is now identical between Page and Source detail views

**Page sidebar context menu:**
- Added "Open" and "Open in Background" at the top
- Added "Find Similar…" submenu (semantic search, excludes the current page)
- Rename moved next to Delete at the bottom; Delete has a trash icon
- Lint Page has a dedicated separator section

**Source sidebar context menu:**
- Added "Open in Background" below "Open"
- Ingest Selected shows a confirmation dialog when re-ingesting
- Share and Ingest grouped together (no divider); Rename/Delete below a separator
- Rename and Delete match the page menu layout
**Verified.** `make check` passes, `make test` passes (**320/320**), and the
user-provided appshot shows the selected page in reader mode with the manual edit
button tucked into the toolbar.

## 2026-06-16 — Ingest division of labor: Opus curates/writes, Sonnet only digests — DONE ✅ (user-verified, merged to main)

CORRECTION to the model-tiering build below.
The prior build (commit `caebfd7`) tiered by model but with the WRONG division of
labor (tiny → Sonnet single pass; large → Opus *planner* that delegated **page
writing** to Sonnet `ingest-worker`s). The user's guiding principle: **Opus is
ALWAYS the curator — it decides what goes in the wiki and WRITES everything. Sonnet
exists ONLY to chew through large volumes of source content; Sonnet NEVER writes.**

**Corrected architecture.**
- **Tiny source** (`< 4 KB`, `IngestPlan.singleOpus`) → a single `--model opus` pass,
  no `--agents`. Opus reads the small staged source and writes the pages + index +
  log itself. (Opus must decide what belongs even for small sources.)
- **Large source** (`IngestPlan.opusCurator`) → `--model opus` curator + `--agents`
  `'{"source-reader":{"model":"sonnet","tools":["Bash","Read"],…}}'`. Opus INSPECTS
  the source's size/structure (`wc`/`head`/page count) WITHOUT reading the whole bulk,
  splits it into chunks, and forks **2–19** Sonnet `source-reader` DIGESTERS to READ
  the chunks in parallel and return STRUCTURED DIGESTS. Opus then synthesizes the
  digests, decides the page set, and WRITES every page + `index.md` + the log entry
  itself. Opus MAY fork more workers for follow-up QUESTIONS and MAY pull pages via
  `wikictl page get` to double-check — the `<20` cap is on TOTAL Sonnet invocations.
- The Sonnet worker has **read-only tools** (`["Read","Bash"]`, no wikictl), and its
  prompt (`IngestPlan.digesterPrompt`) carries NO write rule — it only reads + returns
  a digest. The write rule (`IngestWriteRule.writes`) now leads ONLY the Opus prompts
  (single + curator), since Opus is the writer (`OperationCommandTests` asserts both
  ways). Top-level `--model` is `opus` in BOTH Ingest modes; the tiering is purely in
  the fan-out. Query/Lint unchanged (single-Opus + write rule + WIKI_STATE +
  don't-rediscover).

**Verified (CLI 2.1.178, real `--agents` smoke test):** top level ran on
`claude-opus-4-8`; the `source-reader` subagent resolved to `claude-sonnet-4-6`
(`"resolvedModel":"claude-sonnet-4-6"`), READ the staged source via its `Read` tool,
and returned its digest to the Opus parent, which replied `DIGEST_RECEIVED: …`. No
wikictl anywhere in the worker. Delegation still surfaces as an `Agent` `tool_use` +
`system`/`task_started`/`task_notification` events; the `AgentEvent` parser maps those
to `.subagent` and the activity panel renders the fan-out as purple "reading" / green
"digested" rows (relabeled from "delegated"/"finished" + `doc.text.magnifyingglass`
icon, since the workers now READ, not write).

**Tests / build.** Reworked the two-mode argv + plan tests: tiny → `--model opus` no
`--agents`; large → `--model opus` + a read-only `source-reader` digester whose prompt
DIGESTS (not writes); the curator prompt carries the 2–19 guardrail + "fork more for
questions / pull pages to double-check" + "Opus writes every page"; the worker prompt
has no wiki-write instructions. `make test` → **320/320** green; `make` clean signed
bundle. Live gate (orchestrator `make install` + watch a large Ingest) pending: proof
is no mount-probing, Opus does the writing, a visible fan-out of 2–19 Sonnet *reader*
workers, and Opus optionally asking follow-ups / pulling pages.

### Superseded — 2026-06-16 — Ingest redesign: write-rule in the prompt, local staging, model tiering

Branch `feature/ingest-fewer-turns`. Fixes three problems a live Ingest run exposed.
(The model-tiering division of labor in item #3 below was corrected by the entry
above; items #1 and #2 — the write rule in the `-p` prompt, and local staging — still
stand.)

**1. Agent probed the read-only mount instead of writing.** Phase D moved the
`wikictl` write rule entirely into `--append-system-prompt`, which the agent
under-weights — in a real run it printed *"The mount is read-only. There must be a
dedicated tool for wiki mutations. Let me search."*, ran ToolSearch, then
`echo > pages/by-title/__wikitest__.md` to test the mount. Fix: the load-bearing
write rule + the exact `wikictl` write commands now lead EVERY `-p` prompt
(`IngestWriteRule.writes`), while the layout map / conventions stay in the schema
(DRY — asserted both ways in `OperationCommandTests`).

**2. Wasted orientation turns + laggy mount reads.** The app now STAGES into the
per-run scratch dir, reading from SQLite (not the ~5s-laggy mount): `WIKI_STATE.md`
(titles + index.md + log tail, via `WikiStateSnapshot.renderStateFile`) and, for
Ingest, the raw `source.<ext>` bytes (via `ingestedFileContent`). The prompt names
those absolute paths and forbids `wikictl page list` / re-reading index.md/log.md
(`IngestWriteRule.dontRediscover`). Staging is owned by `AgentLauncher` (it owns the
scratch dir); the per-op intent is the new app-side `OperationRequest`, whose pure
pieces (`AgentStaging` leaf-name math, the `WIKI_STATE.md` rendering, the plan
decision) are core-tested.

**3. Model tiering.** App picks the mode by source size (`IngestPlan.decide`,
threshold `tinySourceByteThreshold = 4096`). **Tiny** (`< 4 KB`) → single
`--model sonnet` pass, no `--agents`. **Non-tiny** → `--model opus` planner +
`--agents '{"ingest-worker":{"model":"sonnet",…,"tools":["Bash","Read"]}}'`: Opus
plans the page set, fans out to **2–19** Sonnet workers (prompt-level guardrail:
"use more than 1 and fewer than 20; size the fan-out to the material"), then Opus
synthesizes `index.md` + the log entry. Query/Lint stay single-agent Opus but ALSO
get the write rule + the staged state + the don't-rediscover directive. The worker
prompt is SELF-SUFFICIENT (a custom agent's `prompt` doesn't inherit
`--append-system-prompt`, so it embeds the full write rule).

**Verified mechanism (CLI 2.1.178, real `--agents` smoke test):** top level ran on
`claude-opus-4-8`, the `worker` subagent resolved to `claude-sonnet-4-6`
(`"resolvedModel":"claude-sonnet-4-6"`; `modelUsage` shows both). Aliases: `opus` →
`claude-opus-4-8`, `sonnet` → `claude-sonnet-4-6`. The `--agents` JSON shape is
`{"<name>":{"description","model","prompt","tools"}}`. Delegation surfaces in the
stream as an `Agent` `tool_use` plus `system`/`task_started` + `task_notification`
events — the `AgentEvent` parser now maps those to a `.subagent` event and the
activity panel renders the Opus→Sonnet fan-out as indented purple "delegated" /
green "finished" rows.

**Tests / build.** +20 tests (the two-mode argv builder, the 2..19 guardrail text,
the write-rule + staged paths + don't-rediscover assertions, the schema-not-
duplicated check, `IngestPlan` threshold, `AgentStaging` path math + WIKI_STATE.md
rendering, the `.subagent`/`Agent` parser cases). `make test` → **320/320** green;
`make` clean signed bundle. Live gate (orchestrator `make install` + watch an
Ingest) pending: proof is no mount-probing, few/no orientation turns, a visible
Opus→Sonnet fan-out.

## 2026-06-16 — URL ingest fix: share-link normalization + content sniffing

Branch `feature/url-ingest`. A real-world test exposed a gap: pasting a **Dropbox
share link** to a PDF stored the Dropbox HTML *preview page* (converted to junk
markdown) instead of the PDF. File-share hosts (Dropbox, Google Drive, OneDrive)
hand non-browser clients a JS interstitial unless you hit the direct-download host
— and Dropbox serves HTML for BOTH `dl=0` and `dl=1`. Two pure, tested fixes:

- **`ShareLinkNormalizer` (new, `WikiFSCore`)** — `normalize(_ url:) -> URL` with a
  list of provider `Rule`s. **Dropbox:** host `www.dropbox.com`/`dropbox.com` →
  `dl.dropboxusercontent.com`, preserving path + query (so the `.pdf` filename in
  the path and the `rlkey`/`e` auth params survive) — the verified rewrite that
  returns raw `%PDF` bytes. Conservative: an unrecognized URL passes through
  byte-for-byte. Google Drive / OneDrive shapes are stubbed in comments for trivial
  add-later. **Wired into `URLSessionFetcher.fetch`** (normalizes BEFORE the request),
  so every production fetch — `ingest` and `WikiStoreModel.ingestURL` — benefits.
- **Content sniffing in `URLIngestService.plan(for:)`** — `sniffContentType(_ data:)
  -> String?` reads leading magic numbers (`%PDF`→pdf, `\x89PNG`→png, `\xFF\xD8\xFF`
  →jpeg, `GIF8`→gif, `PK\x03\x04`→zip). When the declared type is ambiguous
  (`text/html`, missing, or `application/octet-stream` — see `shouldSniff`) but the
  bytes are clearly a known binary, store them VERBATIM as the sniffed type instead
  of running HTML→Markdown. A specific declared type (`application/pdf`, …) is
  trusted as-is. This is the backstop if an interstitial ever slips past the
  normalizer.

**Tests.** +5 `ShareLinkNormalizerTests` (www/bare-host rewrite preserves
path+query+filename; non-share URL unchanged; case-insensitive; no double-rewrite),
+6 in `URLIngestServiceTests` (html-labeled-%PDF→`.pdf` byte-identical;
octet-stream-PNG→`.png`; genuine HTML still→markdown; real PDF still→`.pdf`; the
`sniffContentType`/`shouldSniff` tables). `make test` → **300/300** green; `make`
clean signed bundle. The original failing URL
(`www.dropbox.com/scl/fi/…/CPP_behaviorgen.pdf?…&dl=0`) now normalizes to
`dl.dropboxusercontent.com`, fetches `%PDF` bytes, and stores `CPP_behaviorgen.pdf`.

## 2026-06-16 — Feature: ingest a resource by URL — DONE ✅ (live-verified, merged to main)

Fetch a URL and land it as an ingested
file in the ACTIVE wiki — exactly like a drag-dropped file, so the existing
"Ingest into wiki" `claude -p` operation can summarize it. HTML is converted to
clean Markdown; PDFs/text/binaries are stored verbatim. All deterministic logic is
pure + unit-tested with a FAKE fetcher (NO real network in tests); the UI is a small
native sheet. **221 → 289 tests; clean signed bundle (app + appex + `wikictl`).**

**Added (`WikiFSCore`, all pure + dependency-free)**
- **`HTMLToMarkdown`** — a hand-rolled, tolerant HTML→Markdown converter. We
  deliberately do NOT use `NSAttributedString(html:)` (WebKit-backed,
  main-thread-only, non-deterministic, untestable). A tokenizer
  (`HTMLTokenizer.swift`) + a streaming renderer (`HTMLMarkdownRenderer.swift`) +
  an entity decoder (`HTMLEntities.swift`). Strips `script`/`style`/`head`/`nav`/
  `footer`; prefers `<article>`/`<main>`/`<body>` content; maps `h1`–`h6`→`#`…,
  `p`→paragraphs, `br`→newline, `a`→`[t](u)`, `strong`/`b`→`**`, `em`/`i`→`*`,
  `code`→`` ` ``, `pre`→fenced block, `ul`/`ol`/`li`→lists (nesting-indented),
  `blockquote`→`>`, `img`→`![alt](src)`; decodes named + numeric (`&#NN;`/`&#xNN;`)
  entities; collapses whitespace; extracts `<title>` (for the filename). Every loop
  is input-length-bounded — never crashes/loops on malformed/unclosed tags
  (degrades to literal text). 45 tests.
- **`URLIngestService`** — the fetch→dispatch→store pipeline with an INJECTED
  `URLResourceFetcher` (so dispatch/filename/store is unit-tested with a fake
  fetcher). `Content-Type` dispatch: `text/html`/`application/xhtml+xml` →
  `HTMLToMarkdown` → store the **markdown** as `.md` (named from `<title>`);
  `application/pdf` → raw bytes as `.pdf`; other `text/*` → raw as-is; else → raw
  bytes with a MIME/URL-inferred extension. Filename rules: HTML uses the sanitized
  `<title>` (else the URL stem, else host), via `FilenameEscaping.escapeTitle` +
  an 80-char cap + an `ensureExtension` guard; derives from the FINAL (post-redirect)
  URL. `normalizeURL` trims whitespace + defaults a missing scheme to `https://` +
  rejects non-http(s). 20 tests.
- **`URLSessionFetcher`** — the production `URLResourceFetcher`: `URLSession`
  (ephemeral config) with a desktop Safari User-Agent (so sites don't 403), redirect
  following (reports the final URL), a bounded timeout, and non-2xx → `httpStatus` /
  transport error → `network` translation. The app is un-sandboxed, so this needs no
  entitlement and fires no macOS prompt.

**Added / changed (app — `WikiFS`)**
- **`WikiStoreModel.ingestURL(_:fetcher:)`** — the model seam: validate + fetch OFF
  the main actor (the GET shouldn't stall the UI), then store on the main actor via
  the SAME `store.ingestFile` path drag-ingest uses (so the file shows up under Files
  + `files/by-{id,name}` and is pickable in Operations → Ingest), `reloadIngestedFiles()`
  + `onPageDidChange?()`. Pure `URLIngestService.plan(for:)` decides filename+bytes
  so no `@Sendable` store closure crosses the actor boundary. 3 tests.
- **`AddFromURLSheet`** — a clean native sheet: a paste-friendly URL field
  (auto-focus, submit-on-Return), a prominent **Fetch** button, an inline progress
  spinner while fetching, and an inline red error row on failure. SWIFTUI-RULES:
  the status row is always-mounted + height-animated (§1.1, no insert/remove
  transition), the URL is read fresh at click time (§3.5), semantic Dynamic-Type
  fonts (§5.1), no formatters in `body`. On success it dismisses and the new file
  appears live.
- **Affordance** — "Add from URL…" lives in TWO native spots in `SidebarView`: the
  sidebar toolbar (next to New Page, always available) and an inline icon button in
  the "Files" section header (next to the content it produces). Also updated the
  Operations → Ingest empty-state hint to mention it.

**Skills (CLAUDE.md, before & after):** `swiftui-pro`, `macos-design`,
`typography-designer`, `airbnb-swift-style` — the sheet matches the app's existing
utility type scale (`.headline`/`.subheadline`/`.body`/`.callout`, same as
`OperationsView`) and animation/state rules; no findings to apply.

**Tests/build.** `make test` → **289/289** green (+45 `HTMLToMarkdownTests`, +20
`URLIngestServiceTests`, +3 `WikiStoreModelURLIngestTests`); `make` produces a clean
signed bundle.

**Live gate (orchestrator `make install` + user):** open a wiki → click "Add from
URL…" (sidebar toolbar) → paste an HTML page URL (e.g.
`https://en.wikipedia.org/wiki/Photosynthesis`) → Fetch → a `.md` file named from the
page title appears under Files; paste a PDF URL (e.g.
`https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf`) → a `.pdf`
appears (raw bytes). Then Maintain Wiki → Ingest → pick the fetched file → it
summarizes like any dropped file.

## 2026-06-16 — LLM Wiki Phase D: the schema — DONE ✅ (gate passed)

Branch `llmwiki/phase-d-schema` (stacked on `llmwiki/phase-c-claude-ops`).
Implements `plans/llm-wiki.md` Phase D: replaces the stub `SystemPrompt.defaultBody`
with the real wiki-maintainer schema, and slims the operation `-p` prompts now that
the schema is delivered every run via `--append-system-prompt`. **Cheap, mostly
prose — no new views, no migration changes.**

**Verified (live gate — user created the wiki; orchestrator verified via Bash; real `make clean && make install`, real-signed, fresh wiki `GateD`)**
- **Byte-identity ✅:** a freshly-created wiki's `CLAUDE.md` ≡ `AGENTS.md` ≡ the
  seeded `system_prompt` row body — all `sha256 f3174a5b…`, **5362 bytes**, the
  new "# Wiki Maintainer Instructions" schema (read raw via `writefile` to avoid
  the `sqlite3`-CLI trailing-newline artifact). The projection serves the same
  body under both names, as in the post-v0 system-prompt gate.
- **Agent reads it ✅:** a real `claude -p` launched with the new schema as
  `--append-system-prompt` named the FULL `wikictl` surface from its instructions
  alone — `page list/get/upsert/delete`, `index set`, `log append --kind …`.
- **Migration ✅:** the new wiki seeds the new schema; an EXISTING wiki
  (`GateCFresh`) is **unaffected** — still the old 762-byte stub (no `wikictl`),
  exactly as required (only `defaultBody`, the v2→3 seed + projection fallback,
  changed; no path rewrites an existing row).
- **Prompt de-duplication ✅:** the ~30-line `toolingPreamble` (layout +
  `wikictl` cheatsheet + read-after-write rule) is GONE from the `-p` prompts —
  each op now carries just the task + the resolved `WIKI_ROOT` (+ Ingest's source
  path / Query's question), relying on `CLAUDE.md` (via `--append-system-prompt`)
  for the schema. The exact seam the user flagged during Phase C.
- 211 → **221** tests (also fixed the last same-millisecond ULID flake), all green.

**What changed**
- **`SystemPrompt.defaultBody` is now the real maintainer schema** (`WikiFSCore/
  SystemPrompt.swift`) — addressed to the maintaining agent ("You maintain this
  wiki…"), tight and skimmable. Documents: the **layout** (`pages/by-{title,id}`,
  immutable `files/by-{name,id}`, `index.md`/`log.md`/`TREE.md`, `indexes/*.jsonl`,
  `manifest.json`, `CLAUDE.md`≡`AGENTS.md`); **conventions** (page titling,
  `[[wiki links]]`/`[[Target|alias]]`, summarize-don't-discard, entity vs concept
  page shapes, citing sources by their `files/…` path); **tooling** — the full
  `wikictl` command reference (`page list/get/upsert/delete`, `index set`,
  `log append`), **write via `wikictl` NEVER the filesystem** (mount is read-only),
  `wikictl` on PATH + targets the wiki via `WIKI_DB` (do NOT pass `--wiki`), and the
  **read-after-write rule** (read back via `wikictl page get` because the mount lags
  ~5s); **workflows** — the Ingest/Query/Lint playbooks in order; **sources** — raw
  `files/` may be PDFs/images, use the `Read` tool (PDF text first, images
  separately). This IS each wiki's per-wiki `CLAUDE.md`/`AGENTS.md`; the user
  co-evolves it in-app.
- **Slimmed the operation `-p` prompts** (`WikiOperation.swift`). The Phase-C
  `toolingPreamble` (layout map + `wikictl` cheatsheet + read-after-write rule) is
  REMOVED — that content now lives only in the system prompt, delivered every run via
  `--append-system-prompt`. Each prompt is now the per-op task + the per-run facts
  the schema can't contain: the resolved absolute `WIKI_ROOT` and (Ingest) the
  source's absolute path / (Query) the question. E.g. Ingest is now "Follow the
  Ingest workflow from your instructions… WIKI_ROOT: `<abs>` Source: `<abs>/…`". DRY
  against the schema — no second copy of the layout/cheatsheet to drift.
- **Migration UNCHANGED — verified, not disturbed.** The v2→3 seed and the
  projection fallback both reference the same `defaultBody` constant, so changing the
  constant seeds NEW wikis with the new schema while leaving EXISTING wikis untouched
  (the seed runs only inside `if version < 3` at table-creation; there is no code
  path that rewrites an existing `system_prompt` row to the default). A new test
  (`existingSystemPromptRowIsNotOverwrittenOnReopen`) pins this. `CLAUDE.md`≡
  `AGENTS.md`≡seeded body still holds structurally (both projection nodes serve
  `systemPromptDocument().body`, which returns the seeded `defaultBody`).

**Also in this phase — hardened File Provider domain registration (Phase D gate
finding).** During the Phase D gate a freshly-created wiki ("GateD") did NOT mount
until the app was relaunched, with NO error shown. The create→register→mount code
path was logically correct (`WikiManager.createWiki` → `registerDomain` →
`FileProviderSpike.registerDomain` → `NSFileProviderManager.add(domain)`, the same
call launch uses), but registration was **brittle and silent under a busy/churned
`fileproviderd`**: a single `add(domain)` that swallowed any error into an
unsurfaced `status` string and never verified/retried/nudged. Hardened
`FileProviderSpike.registerDomain(id:displayName:)` WITHOUT changing its injected
shape:
- **Surfaces failures** — a real `add` error is now `print`ed to the console AND
  kept in `status` (never buried); already-exists stays benign (the verify below
  confirms presence).
- **Verifies + bounded retry** — after each `add` it confirms the domain actually
  appears in `NSFileProviderManager.domains()`; if a busy daemon didn't take it, it
  backs off (~0.6 s async sleep — never blocks the main actor) and retries, up to 3
  attempts, then fails LOUDLY (console + `status`) and returns `false`.
- **Nudges initial enumeration** — on a verified add it signals the new domain's
  `.rootContainer` + `.workingSet` enumerator (the same `signalEnumerator` path
  `signalChange` uses, scoped to THIS domain) so the daemon materializes the root
  promptly instead of waiting for an external trigger — this is what makes the mount
  appear right after create.
The decision arithmetic (registered? / retry? / failed?) is extracted into a PURE,
unit-tested `WikiFSCore/DomainRegistrationPolicy` (mirroring `PathPreflight`) so the
FileProvider-importing `FileProviderSpike` stays thin side-effect glue. Idempotent +
safe to call repeatedly (launch calls it per wiki via `registerAllDomains`, create
once); the `WIKIFS_REENUMERATE` one-shot remove+re-add hatch is preserved.
`DomainRegistrationPolicyTests` (10) covers exact-match membership, the
retry-while-attempts-remain / fail-after-max decision table, and full-loop
simulations (registers on the final attempt; fails when the domain never appears).
**Guaranteed by the code:** on a healthy-but-momentarily-busy daemon, create→mount
is immediate (verify+retry+nudge) and any real failure is loud + self-healing rather
than silent. **Still daemon-dependent:** a fully *wedged* replica (the `ISSUES.md`
churned-domain case) is NOT rescued by retry — it needs a domain teardown — and the
exact end-to-end timing can't be proven without a clean (un-churned) `fileproviderd`.

**Tests/build.** Updated `OperationCommandTests` to the slimmed prompt shape: each
prompt now carries the resolved `WIKI_ROOT` and defers to "the … workflow from your
instructions", and the inline layout map / `wikictl` cheatsheet / read-after-write /
`--wiki` reminders are asserted GONE. New `SystemPromptTests` pin the schema content
(names every `wikictl` command, the layout, conventions, workflows, the PDF/Read
note) and the migration invariant (existing row not overwritten). **Also fixed the
last same-millisecond ULID flake** (`PageUpsertTests.upsertByTitleResolvesDuplicate
ToLowestULID` assumed creation order == ULID order; `ULID.generate()` is NOT
monotonic within a ms, so it now derives the expected lowest id from the actual ids
— matching the fix already applied to `WikiLinkNavigationTests`/`WikiLinkStoreTests`).
`make test` → **221/221 green** (211 schema-phase + 10 `DomainRegistrationPolicyTests`);
`make` produces a clean signed bundle (app + appex + `wikictl`, real identity).

**Notes / what the independent verifier should watch (the Phase-D gate)**
- The new default is **byte-identical** across a wiki's `CLAUDE.md` and `AGENTS.md`
  and matches the seeded DB body (use a freshly-created wiki; one-shot
  `WIKIFS_REENUMERATE=1` may be needed to surface the files on an already-materialized
  domain).
- A fresh `claude -p` launched against a NEW wiki reads the schema as its system
  prompt and **can name the `wikictl` commands** (`claude` on PATH; macOS-26 TCC
  prompt re-fires on a re-signed install).
- Migration seeds new wikis with the new schema; **existing wikis are unaffected**.

## 2026-06-16 — Preview polish: clickable `[[wiki-links]]` — DONE ✅ (live-checked)

Surfaced during the Phase C gate: the in-app Markdown preview rendered
`[[Photosynthesis]]` as literal dead text because `AttributedString(markdown:)`
is CommonMark and has no `[[…]]` concept. The link *graph* was already correct
(`page_links` / `links.jsonl`); this was purely a preview/navigation gap. The
on-disk / mounted body STAYS literal `[[…]]` — this is an in-app render concern
only, nothing is written back.

What landed:
- `WikiFSCore/WikiLinkMarkdown.swift` — pure, view-free transform
  `linkified(_:isResolved:)` that rewrites every `[[Title]]` / `[[Target|alias]]`
  span into a real Markdown link on a private `wiki://` scheme
  (`[[Photosynthesis]]` → `[Photosynthesis](wiki://page?title=Photosynthesis)`;
  alias displays the alias, links by the URL-encoded target). Reuses
  `WikiLinkParser`'s exact bracket grammar; rewrites EVERY occurrence (the parser
  de-dupes for the graph, the preview must not). Skips spans inside inline code
  (`` `…` ``) and fenced ``` blocks so code samples stay literal. Resolution is
  injected as a closure, so a resolved target gets host `page` (navigates) and a
  missing one host `missing` (rendered dimmed, inert).
- `WikiFS/MarkdownPreview.swift` — linkifies each block through the model's
  `pageExists`, dims unresolved (`wiki://missing`) link runs to `.secondary`, and
  installs an `OpenURLAction` that drives `store.selectPage(byTitle:)` for our
  scheme (`.handled`) while letting real external URLs fall through
  (`.systemAction`).
- `WikiFSCore/WikiStoreModel.swift` — `selectPage(byTitle:)` (resolve title→id,
  lowest-ULID on duplicates, navigate through the SAME `select(_:)` seam the
  sidebar uses so the outgoing page flushes first) + `pageExists(title:)`.
- Tests: `WikiLinkMarkdownTests` (transform: forms, encoding, code-span/fence
  protection, escaping, idempotence, URL round-trip) + `WikiLinkNavigationTests`
  (resolve-to-id, missing no-op, duplicate→lowest-ULID, flush-on-navigate). Suite
  green at 207. `make` builds + signs clean.

Still DRAFT until the live check: click a resolved `[[link]]` in the running app
and confirm it selects that page; confirm a missing link reads dimmed and inert.

## 2026-06-16 — Phase C gate fix: skip-permissions + layout-up-front + `TREE.md` — DONE ✅ (folded into the Phase C gate pass below)

The first live Phase-C gate FAILED with two real defects (still DRAFT — re-gate
pending). Fixing exactly these on `llmwiki/phase-c-claude-ops`:

1. **Every command the agent issued was rejected → ZERO output.** The
   `--allowedTools 'Bash(wikictl:*) Bash(cat:*) …'` allowlist can't statically
   verify a command containing a `$WIKI_ROOT`/`$WIKI_DB` shell expansion or a
   compound command, so the CLI demanded approval — and in `-p` (non-interactive)
   mode there is no approval prompt, so the run was dead on arrival (no page, no
   log, no index bump). The allowlist is fundamentally incompatible with the
   env-var paths the whole design depends on. **Fix:** dropped the `--allowedTools`
   pair, now pass **`--dangerously-skip-permissions`** — the "frictionless mode"
   fallback `plans/llm-wiki.md` sanctions (app is local, un-sandboxed,
   user-initiated; the agent only has `wikictl` + read-only shell intent). Verified
   accepted by the installed CLI (2.1.178 — a real `-p … --dangerously-skip-permissions`
   run reports `permissionMode":"bypassPermissions"`). Everything else on the argv
   is unchanged.
2. **The agent burned ~6 turns probing for basic structure** (`ls`, `env`,
   `mount`, `wikictl --help`) because it had no map. **Fix, two parts:**
   - **In-prompt layout (load-bearing).** `WikiOperation.prompt` is now
     `prompt(wikiRoot:)` and leads with a concrete map: the **resolved absolute
     `WIKI_ROOT`** (passed in — not `$WIKI_ROOT` for the agent to expand, which is
     exactly what the permission system choked on AND what made it hunt), the fixed
     `pages/by-{title,id}` + `files/by-{name,id}` + `index.md`/`log.md`/`TREE.md`/
     `manifest.json`/`indexes/*.jsonl` layout, the `wikictl` cheatsheet (incl. the
     exact `printf '%s' "<body>" | wikictl page upsert --title T --body-file -`
     form), and that `wikictl` is on PATH + already targets the wiki via `$WIKI_DB`
     (so do NOT pass `--wiki`). For Ingest, the **chosen source's resolved absolute
     path** is injected so the agent reads it immediately instead of hunting.
   - **`TREE.md` at the wiki root** — a new read-only projection (`WikiTreeRenderer`,
     pure) served exactly like `log.md`/`index.md` (new container id `tree-md`, root
     child, working-set re-emit, `contents`). It is the same orientation map,
     largely STATIC (the projection layout is fixed) plus two cheap live counts
     (pages, files). Versioned by `changeToken()` like `log.md` — NOT a separate
     token term: the only thing that moves is the two counts, and those move with
     the same page/file folds the token already tracks, so a token-versioned node
     re-fetches precisely when the counts can change. Prompts reference it ("full
     layout is in `TREE.md`").

**KEPT exactly as-is** (they work — they're how we SAW the failure): the streaming
activity panel, `AgentEvent`/`AgentEventParser`, the backend `run.jsonl`/
`run.stderr.log`, the per-wiki edit lock, the change-bridge live refresh, and the
`claude` PATH preflight.

**Tests/build.** `OperationCommandTests` updated: argv now asserts
`--dangerously-skip-permissions` (no `--allowedTools`); the prompt builder is
asserted to lead with the layout + resolved `WIKI_ROOT` + cheatsheet + (Ingest)
the resolved source path. New `WikiTreeRendererTests` covers the layout/cheatsheet
content, the live counts (incl. singular/plural), and determinism. `make test`
green at **184**; `make` produces a clean signed bundle.

(Original Phase-C build notes below — the parts about `--allowedTools` are
superseded by the skip-permissions switch above.)

## 2026-06-16 — LLM Wiki Phase C: `claude -p` operations (Ingest / Query / Lint) — DONE ✅ (gate passed)

Branch `llmwiki/phase-c-claude-ops` (stacked on `llmwiki/phase-b-index-log`).
Implements `plans/llm-wiki.md` Phase C: generalizes the v0 agent launcher into
three discrete `claude -p` operations scoped to the active wiki, the per-wiki
edit lock, and the live-sidebar refresh during a run. The deterministic seams
(prompt/command/env construction, PATH preflight, edit-lock state machine) are
unit-tested; the real agent run was verified live. This phase took **three
gate-driven course-corrections** (the two entries above + this one are the
sub-stories): (1) the streaming UI + backend logs were missing → built them
(without live visibility the agent "just sits there"); (2) the least-privilege
`--allowedTools` allowlist rejected EVERY command (it can't match a command
containing the `$WIKI_ROOT`/`$WIKI_DB` expansion, and `-p` has no approval
prompt) → switched to `--dangerously-skip-permissions` + inject the wiki layout
up front (`TREE.md` + in-prompt map) so the agent acts instead of probing; (3)
ingested `[[wiki-links]]` rendered as dead text in the preview → made them
clickable/navigable.

**Verified (live gate — user drove the app UI, orchestrator verified via Bash; real `make clean && make install`, real-signed, on a freshly-created wiki `GateCFresh`)**
- **Ingest (structural pass):** a real `claude -p` Ingest of `photosynthesis.txt`
  took the wiki from **1 page → 6** (Photosynthesis + Chloroplast, Chlorophyll,
  Light-Dependent Reactions, Calvin Cycle), appended an **`ingest` log row**,
  rewrote **`index.md` (v2→v3)**, and built a **9-edge `[[link]]` graph**
  (`page_links` + `indexes/links.jsonl`) — all written via `wikictl`, the
  read-only mount untouched. The gate is structural (the agent is
  non-deterministic), and all three required artifacts (≥1 page, ≥1 log entry,
  index changed) landed.
- **Query:** returns a cited answer in the panel + a `query` log row.
- **Live streaming + backend logs:** the activity panel showed real tool-call
  rows (`printf … | wikictl page upsert`, etc.), assistant text, and the green
  terminal result **as they streamed**; **4 `run.jsonl`** backend logs captured
  the full NDJSON event stream (system init → assistant → tool_use → tool_result
  → result) under `~/Library/Caches/WikiFS-agent/<uuid>/`, with `run.stderr.log`
  sibling and a "Reveal Log" button.
- **Edit lock:** the in-app editor was read-only with the "Agent is updating the
  wiki…" banner for the run's duration and re-enabled on completion (per-wiki).
- **Clickable wiki-links:** in the preview, `[[Photosynthesis]]` etc. render as
  accent links and navigate to the target page on click; unresolved links render
  dimmed + inert. (On-disk/mount bytes stay literal `[[…]]`.)
- **Tests 161 → 207** across the phase (operations seams, `AgentEvent` parser,
  `WikiTreeRenderer`, `WikiLinkMarkdown` linkifier + navigation), all green and
  deterministic — also fixed three pre-existing same-millisecond ULID-ordering
  flakes (log order; duplicate-title resolve; link order) surfaced along the way.

**Carry-forward to Phase D:** the operation `-p` prompts currently INLINE the
schema (layout + `wikictl` cheatsheet + read-after-write rule) as a stopgap,
because today's `system_prompt`/`CLAUDE.md` is still the Phase-D stub. Phase D
puts the real schema in `CLAUDE.md`; the `-p` prompts should then slim down to
just the per-op task (the inline preamble becomes the duplication to remove).

**Flag surface confirmed (claude-api skill + installed CLI `2.1.178`)**
- `claude --help` confirms `-p`/`--print`, `--append-system-prompt <prompt>`,
  `--allowedTools` ("Comma or space-separated list of tool names"), and
  `--output-format text|json|stream-json`.
- **Streaming is now load-bearing, not polish.** A plain `claude -p` emits almost
  nothing until the final result, so the operations panel sat blank for the whole
  run — "you just sit there waiting for claude to do nothing", undebuggable. We now
  always pass `--output-format stream-json --verbose --include-partial-messages`.
  `--help` (and a real captured run) confirm `--verbose` is REQUIRED with
  `stream-json` in print mode, and `--include-partial-messages` is accepted (it
  adds token-level `stream_event` deltas).
- **Real event shapes captured from the installed binary** (a live
  `claude -p 'say hi' --output-format stream-json --verbose --include-partial-messages`
  run, NDJSON, one per line): a `{"type":"system","subtype":"init",…,"model":…}`
  event; `{"type":"assistant","message":{"content":[{type:"text"|"tool_use",…}]}}`;
  `{"type":"user","message":{"content":[{type:"tool_result","is_error":…,"content":…}]}}`;
  and the terminal `{"type":"result","is_error":…,"result":…}`. The bookkeeping
  types we DON'T render — `system/status`, `rate_limit_event`, the
  `--include-partial-messages` `stream_event` deltas, `system/post_turn_summary` —
  were all observed and are intentionally skipped (the complete `assistant`/`user`
  events carry the same content cleanly).
- Validated the EXACT combination parses on the real binary (no unknown-flag
  error). The space-separated `Bash(<cmd>:*)` allowlist form is what the installed
  CLI accepts.

**Added (deterministic, unit-tested — `WikiFSCore`)**
- **`WikiOperation`** — a PURE enum (`ingest(sourcePath:)` / `query(question:)` /
  `lint`) that renders each operation's OWN self-sufficient `-p` prompt. Because
  the per-wiki `system_prompt` is still the Phase-D stub, each prompt spells out
  the `wikictl` workflow (write via `page upsert`, record via `log append`,
  rewrite via `index set`, **read-back via `page get`** since the mount lags ~5s)
  and reminds the agent the mount is read-only + `WIKI_DB` already selects the
  wiki (so it must NOT pass `--wiki`). Ingest names all four write steps (≥1
  summary page, entity/concept pages, rewrite `index.md`, append `log.md`); Query
  asks for a cited answer; Lint asks for the health report + a `log append`.
- **`OperationCommand`** — the PURE `claude -p` argv/env/cwd builder, the
  load-bearing testable seam. `build(...)` assembles:
  `claude -p <prompt> --output-format stream-json --verbose
  --include-partial-messages --append-system-prompt <wiki's system_prompt>
  --allowedTools '<allowlist>'` with **env** `WIKI_ROOT=<live mount>` +
  `WIKI_DB=<wiki ULID>` +
  `PATH=<Helpers dir>:<inherited PATH>` (so the agent's `wikictl` calls resolve),
  **cwd** = a per-run writable scratch dir (NOT the read-only mount, decision #4).
  `allowedTools` = `Bash(wikictl:*) Bash(find:*) Bash(cat:*) Bash(grep:*)
  Bash(printf:*) Read Grep Glob` (least privilege: wikictl writes + read-only
  shell + read tools; `printf` for the stdin-piped `--body-file -` writes).
- **`AgentEvent` + `AgentEventParser` + `ToolInputSummary`** (NEW, PURE,
  unit-tested) — the typed projection of the stream-json NDJSON. `parse(line:)`
  decodes ONE line → `.systemInit(model:)` / `.assistantText(String)` /
  `.toolUse(name:inputSummary:)` / `.toolResult(isError:summary:)` /
  `.result(isError:text:)`, and is deliberately TOLERANT: an empty line → `nil`;
  any line that fails to decode (garbage, a mid-object partial flush) →
  `.raw(line)` rather than throwing; unmodeled event types (`stream_event`
  deltas, `system/status`, `rate_limit_event`, `post_turn_summary`) and
  renderable-content-free `assistant` blocks (e.g. `thinking`-only) → `nil`. So a
  bad/unfamiliar line never crashes or drops the run. `ToolInputSummary` renders a
  concise one-liner per `tool_use` (Bash → its command, Read/Write/Edit → the
  path, Glob/Grep → the pattern, else a sorted `key=value` join), elided at 120
  chars — so the feed reads `Bash  wikictl page upsert --title "…"` not a JSON
  blob. Built against the REAL captured shapes, not a guess.
- **`PathPreflight`** — pure `resolve(executable:onPath:fileExists:)` first-hit
  PATH search + `resolveOnLoginShell()` (a real `zsh -lc 'echo $PATH'` hop, since
  the GUI app's process PATH lacks `/opt/homebrew/bin`). Surfaces a clear in-UI
  error if `claude` isn't resolvable instead of a cryptic spawn failure.
- **`EditLock`** — `@MainActor @Observable` per-wiki lock state machine (decision
  #6): `lock(wikiID:)` / `unlock(wikiID:)`, keyed by ULID, **re-entrant via a
  count** (two ops on one wiki don't unlock each other early), stray-unlock
  clamped at zero. (The app drives the lock through `WikiStoreModel` directly —
  `EditLock` is the tested standalone state machine for the per-wiki contract.)

**Added / changed (app — `WikiFS`)**
- **`AgentLauncher` generalized + made observable** from a free-form `zsh -lc
  <cmd>` to
  `run(operation:wikiID:wikiRoot:systemPrompt:wikictlDirectory:onLock:onUnlock:)`:
  runs the PATH preflight, builds the per-run scratch dir under Caches, assembles
  the command via `OperationCommand.build`, spawns `claude`. **The stdout
  `readabilityHandler` now does double duty**: it tees every raw byte to the
  per-run `run.jsonl` log AND feeds bytes through a line buffer (carrying over a
  partial trailing line until its newline arrives, so the parser only ever sees
  complete NDJSON) → `AgentEventParser` → a published
  `private(set) var events: [AgentEvent]` the UI renders live, all on the main
  actor. It also keeps a `rawTranscript` mirror and separate `stderr`. The
  no-`waitUntilExit` model is preserved — completion arrives via
  `terminationHandler`, which drains any trailing partial line, closes the log
  handles, releases the edit lock (`onUnlock`), and records the exit status, so a
  killed/crashed agent still re-enables editing. Exposes `preflightError`,
  `runningKind`, `exitStatus`, and `logFileURL` for the UI. `resolveClaude` is
  injectable for tests.
- **Backend logs (the user-required "fully reconstructable after the fact").**
  Each run's scratch dir holds `run.jsonl` (every raw stream-json byte, unparsed)
  and a sibling `run.stderr.log` (claude's diagnostics). The scratch dir is now
  PERSISTED (not deleted on termination) so a finished run can be replayed;
  `logFileURL` surfaces `run.jsonl` so the UI can reveal it in Finder.
- **`HelpersLocation`** — resolves the `wikictl` dir to prepend to the agent's
  PATH: the signed bundle's `Contents/Helpers` first, then `build/` and the
  running-exe dir for dev (`swift run`). Confirmed live: the embedded+signed
  `wikictl` resolves on PATH and honors `WIKI_DB`.
- **Edit lock wired into the model.** `WikiStoreModel.beginAgentRun()` flushes
  pending edits then sets `isAgentRunning` (editor → read-only, autosave PAUSED —
  both `scheduleAutosave` and `systemPromptChanged` early-return while running, so
  an in-app save can't clobber the agent's `wikictl` writes). `endAgentRun()`
  clears the flag, `reloadFromStore()`s the sidebar, and reloads the open
  document's draft from the (agent-rewritten) source. The live change-bridge
  `reloadFromStore` is UNAFFECTED by the lock, so the sidebar still fills in as the
  agent's writes land mid-run. `currentSystemPromptBody()` exposes the singleton
  for `--append-system-prompt`.
- **UI (macos-design + typography-designer + swiftui-pro).** `OperationsView`
  replaces the old "Run Agent" sheet: a segmented Ingest/Query/Lint picker, an
  Ingest source picker (over the wiki's ingested files → its `files/by-id/…`
  mount path via the shared `FilenameEscaping`), a Query text box, a Lint button,
  the live activity panel, and the PATH-preflight error.
- **`AgentActivityView` (NEW) — the live transcript.** Replaces the old "raw blob"
  console: an auto-scrolling `LazyVStack` over `launcher.events`, one row per typed
  event — a `tool_use` row is an SF Symbol (terminal/doc/pencil/magnifyingglass per
  tool) + monospaced name + concise input summary; assistant text is body prose;
  the terminal result is distinct (green `checkmark.seal` / red
  `exclamationmark.octagon` by `is_error`); a spinner + "Starting <kind>…"
  placeholder shows while a run has started but emitted nothing yet, so the panel
  is NEVER staring at nothing. Auto-scroll animates a scroll OFFSET to a
  zero-height bottom anchor (`onChange(of: events.count)`) — never inserts/removes a
  structural view (SWIFTUI-RULES §1.1); rows derive purely from their `AgentEvent`
  (§3.1); semantic Dynamic-Type fonts (§5.1); no cached formatters in `body`. A
  stderr "Diagnostics" sub-panel surfaces claude's stderr when non-empty, and the
  footer's **"Reveal Log"** button opens `run.jsonl` in Finder. The raw transcript
  stays available via `launcher.rawTranscript` for debugging.
- `AgentRunBanner` ("Agent is updating the wiki…") sits above both
  editors — **always-mounted, height-animated** per SWIFTUI-RULES §1.1 (no
  structural transition), Reduce-Motion-aware; both detail views `.disabled` while
  `store.isAgentRunning`. Semantic Dynamic-Type fonts throughout. Toolbar button
  renamed "Maintain Wiki" (`sparkles`). Obsolete `AgentLauncherView` removed.
- Tests: 135 → **180** (+45). `OperationCommandTests` (updated: argv now asserts
  `-p`, the `--output-format stream-json --verbose --include-partial-messages`
  streaming flags, `--append-system-prompt`, `--allowedTools` in exact order, plus
  a dedicated `streamJSONRequiresVerbose` check; allowlist scope,
  `WIKI_ROOT`/`WIKI_DB` env, Helpers-dir PATH prepend, scratch-cwd-not-mount,
  base-env inheritance, every-kind builds; the three prompts name their `wikictl`
  steps + read-after-write rule + `do NOT pass --wiki`; PATH preflight
  found/missing/order/absolute/empty). **`AgentEventParserTests` (NEW, ~19)** —
  each event type from REAL captured sample lines (system/init w/ + w/o model,
  assistant text, Bash/Read `tool_use` summaries, string + array `tool_result`,
  success + error `result`); tolerance (garbage → `.raw`, truncated mid-object →
  `.raw`, empty/whitespace → `nil`, unmodeled types → `nil`, renderable-free
  assistant → `nil`); `ToolInputSummary` (unknown-tool sorted `key=value`,
  long-command elision, empty input). `EditLockTests` (8, unchanged).
  `make test` → **180 green, all deterministic** (the prior log-ordering flake was
  fixed in `38aeb6f` — `ts+rowid` ordering); `make` clean signed bundle (app +
  appex + `wikictl`, real identity).
- **End-to-end live smoke (this session).** Drove the FULL pipeline against the
  installed `claude 2.1.178`: built the real `OperationCommand` argv, spawned
  `claude -p`, teed raw stdout to `run.jsonl`, line-buffered through the real
  `AgentEventParser`. Result: parsed `systemInit(model: "claude-opus-4-8[1m]")` →
  `assistantText("PONG")` → `result(isError:false, text:"PONG")`, and `run.jsonl`
  populated (7,917 bytes). The activity stream AND the backend log both populate
  on a real run. (Smoke harness was temporary; removed after the run.)

**The EXACT command each op builds** (env + cwd shown):
```
cd <Caches>/WikiFS-agent/<uuid>  \   # writable scratch (also holds run.jsonl +
                                     #   run.stderr.log); NOT the read-only mount
  env WIKI_ROOT=<live mount> WIKI_DB=<wiki ULID> \
      PATH=<WikiFS.app/Contents/Helpers>:<inherited PATH> \
  <resolved claude> -p "<operation prompt>" \
    --output-format stream-json --verbose --include-partial-messages \
    --append-system-prompt "<this wiki's system_prompt body>" \
    --allowedTools 'Bash(wikictl:*) Bash(find:*) Bash(cat:*) Bash(grep:*) Bash(printf:*) Read Grep Glob'
```

**Notes / carry-forward**
- **The prior log-ordering flake is FIXED** (`38aeb6f` — `log.md` now orders by
  `ts+rowid`, not the ULID `id`). The whole suite (180) is deterministic.
- **Gate is STRUCTURAL** (agent is non-deterministic): on a FRESHLY-CREATED wiki,
  drop a real source → Ingest → ≥1 new summary page + ≥1 `log.md` entry +
  `index.md` changed (all visible on the mount); a Query returns a cited answer; a
  Lint produces a report; the editor is read-only during a run and re-enabled
  after. `claude` must be on the login-shell PATH. macOS-26 TCC prompt re-fires on
  a re-signed install (Phase 0 carry-forward).
- **The verifier must ALSO confirm the streaming observability** (the whole point
  of this enhancement): during a run the operations panel shows live tool-call
  rows + assistant text streaming in (NOT a blank box until the end), and a
  backend `run.jsonl` log is written under the run's scratch dir
  (`<Caches>/WikiFS-agent/<uuid>/run.jsonl`, revealable via "Reveal Log"),
  containing the raw stream-json for after-the-fact replay.

## 2026-06-15 — LLM Wiki Phase B: `log.md` + `index.md` — DONE ✅ (gate passed)

Branch `llmwiki/phase-b-index-log` (stacked on `llmwiki/phase-a-write-path`).
Implements `plans/llm-wiki.md` Phase B: the append-only `log` table + the curated
`wiki_index` singleton, two `wikictl` subcommands to write them, and both
projected read-only at each wiki's root. All deterministic (no agent yet).
Independent live-mount gate (Bash, on a freshly-created wiki) PASSED.

**Added / changed**
- **Two stepwise migrations** slotted into the existing `bootstrapSchema()` ladder
  (`SQLiteWikiStore.swift`), continuing past the v2→3 `system_prompt` step:
  - **v3→4** — a `log` table (`id` ULID PK, `ts` REAL, `kind` TEXT, `title` TEXT,
    `note` TEXT nullable). Append-only chronological log; NOT a singleton — each
    `appendLog` INSERTs a fresh ULID-keyed row (`id` sorts == chronological).
  - **v4→5** — a `wiki_index` SINGLETON (`id INTEGER PRIMARY KEY CHECK(id=1)`,
    `body_markdown`, `updated_at`, `version`), modeled EXACTLY on `system_prompt`:
    seeded with `WikiIndex.defaultBody`, UPSERT on write, `version` bumped each
    write. Existing v1/v2/v3 DBs migrate forward with pages + files + system_prompt
    preserved (`LogIndexTests.migratesV3DatabaseToV5PreservingData` builds a v3 DB
    by hand and asserts all three ride through untouched + the index seeds).
- **Value types (`WikiFSCore`).** `LogEntry` (+ closed `LogEntry.Kind`
  `ingest|query|lint`) and `WikiIndex` (the `system_prompt`-shaped singleton +
  `defaultBody`). `LogRenderer` — pure, deterministic `log.md` rendering: one
  grep-able `## [YYYY-MM-DD] <kind> | <title>` heading per row (UTC date via a
  fixed `en_US_POSIX` formatter so `grep "^## \[" log.md | tail -5` works exactly
  as the doc shows), the optional note on the following line.
- **Store methods (`SQLiteWikiStore` + `WikiStore` protocol).** `appendLog(kind:
  title:note:)`, `getWikiIndex()`, `updateWikiIndex(body:)` on the protocol (so the
  CLI commands run against `WikiStore`, like the `page` commands);
  `listAllLogEntriesOrderedByID()` stays concrete (a read-projection helper, like
  `listAllPagesOrderedByID`).
- **⚠️ `changeToken()` extended** `…:spVersion` → `…:spVersion:logCount:idxVersion`
  (now `"pCount:pSum:fCount:fSum:spVersion:logCount:idxVersion"`). SAME reasoning
  as the `spVersion` fold: appending ONLY a log entry (logCount) or editing ONLY
  the index (idxVersion) must still advance the anchor or the projected
  `log.md`/`index.md` would never refresh. `log` uses COUNT (append-only — rows
  only grow), `wiki_index` uses the row `version` (UPSERTs). Both fall back to `0`
  on a pre-v4/v5 read connection (table absent), exactly like the `spVersion`
  helper. ALL `changeToken` test literals gained the trailing `:0:1` (fresh DB:
  no log rows, index seeded at v1).
- **`wikictl` subcommands (`WikiCtlCore` + `wikictl`).** `ArgumentParser` grew a
  top-level command switch (`page` / `log` / `index`) and two parsers; the new
  `LogIndexCommand` executes `logAppend` / `indexSet` against a `WikiStore`
  (mirrors `PageCommand`); `main.swift`'s dispatch (`execute`) routes to the right
  family and reads the deferred `--body-file` body (`-` = stdin):
  - `wikictl [--wiki <id>] log append --kind ingest|query|lint --title "…"
    [--note "…"]` — appends one dated row, echoes the new ULID. Rejects an invalid
    `--kind`.
  - `wikictl [--wiki <id>] index set --body-file <path|->` — UPSERTs the singleton
    body wholesale (version+1); `-` reads stdin.
  Both select the wiki via `--wiki`/`WIKI_DB` and post the SAME per-wiki
  `WikiChangeNotification` Darwin name as Phase A after committing (both return
  `didCommit: true`) — reusing the existing `WikiResolver` + `DarwinNotifier`
  plumbing unchanged, so the app's change bridge refreshes that wiki with no new
  wiring.
- **Projection (`Projection.swift` + `WikiFSContainerID`).** Two new root-level
  read-only files: `index.md` (the singleton body served verbatim, sized/versioned
  by the row `version` — exactly the `CLAUDE.md`/`AGENTS.md` path) and `log.md`
  (the rendered table, versioned by the change token since its bytes derive from
  many rows — like the generated index files). New `log-md`/`index-md` container
  ids; added to `node(for:)`, the root children, the working set, and
  `contents(for:)`. Both resilient to the v4/v5 tables being absent on a
  pre-migration read connection → empty/default, so the files always exist.
- **Signaling.** `log.md`/`index.md` are root children, so the app's existing
  `signalChange()` (`.rootContainer` + `.workingSet`) refreshes them — no new
  signal container needed (same as `manifest.json` / `CLAUDE.md`).
- Tests: 113 → **135** (+22). `LogIndexTests` (v3→5 migration preserving
  pages+files+system_prompt + seeding the index; `appendLog` field correctness +
  nil-note + chronological order; `LogRenderer` grep-able prefix + empty doc;
  `updateWikiIndex` UPSERT version-bump + persist-across-reopen +
  recreate-after-delete; **changeToken advances on a log-only AND an index-only
  write**). `WikiCtlLogIndexTests` (arg parsing/dispatch for both commands incl.
  bad-`--kind` + missing-required + unknown-subcommand; `LogIndexCommand`
  execution against a temp DB). Existing `changeToken`/migration literals updated.
  `make test` → **135/135**; `make` clean signed bundle (app + appex + `wikictl`).

**Smoke-tested (Bash, against the `GateAClean` wiki, non-destructive)**
- `log append --kind ingest --title … --note …` and `--kind query` (no note) both
  echoed new ULIDs and wrote correct `log` rows (kind/title/note); `index set`
  from stdin UPSERTed the `wiki_index` body to version 2. The hand-computed change
  token reflected the writes (`…:logCount=2:idxVersion=2`), proving both folds
  advance live. DB migrated to `user_version 5`.

**Verified (independent live gate, real `make clean && make install`, real-signed, Bash + minimal computer-use)**
On a **freshly-created wiki `GateBClean`** (`01KV7CWPJE…`, mount
`WikiFS-GateBClean`, made via the in-app switcher) — no `WIKIFS_REENUMERATE`
needed, the new root files materialized cleanly in seconds (confirming Phase A's
churned-domain finding). App pid **44966 unchanged through every step** (no
relaunch anywhere).
- **(1) `log append` → grep-able `log.md`:** appended `--kind ingest` (with
  `--note`) and `--kind query` (no note) → mount `log.md` refreshed in ~2 s to
  `## [2026-06-16] ingest | Article One` / `## [2026-06-16] query | How does X
  compare?`; `grep "^## \["` returned exactly the two headings; the note renders
  for the ingest entry and is absent for the no-note query entry. `--kind bogus`
  rejected (exit 2).
- **(2) `index set` → rewrites root `index.md`:** `printf … | wikictl index set
  --body-file -` bumped `wiki_index.version` 1→2; mount `index.md` refreshed in
  ~1 s and `diff` vs the set body was IDENTICAL (verbatim).
- **(3) log-only / index-only edit advances the anchor + refresh, no relaunch:**
  a fresh `log append --kind lint` advanced the token fold `logCount` 2→3
  (idxVersion held at 2) → `log.md` changed bytes in ~2 s; a fresh `index set`
  advanced `idxVersion` 2→3 (logCount held at 3) → `index.md` refreshed in ~3 s;
  pid 44966 unchanged both times. Both halves of the `…:logCount:idxVersion` fold
  drive the sync anchor independently.
- **SoT confirmed:** `PRAGMA user_version` migrated 3→5 **lazily on the first
  `wikictl` write** (a fresh wiki ships at 3); `wiki_index` at version 3, all 3
  `log` rows intact. 135/135 tests; real-signed app + appex + `wikictl`.

**Notes / carry-forward**
- A fresh wiki's DB ships at `user_version 3` and migrates to 5 **lazily on the
  first `wikictl` write** (the `bootstrapSchema()` ladder runs on store-open) —
  expected; the projected `log.md`/`index.md` exist (default/empty) before then.
- **~5 s mount-refresh window** still applies; `wikictl page get` is the instant
  SoT escape hatch.
- **macOS-26 TCC prompt** re-fires on a re-signed install and holds the app until
  "Allow" (Phase 0 carry-forward).
- Gate artifact wiki **`GateBClean`** left in place (deleting is destructive; the
  gate doesn't require teardown), as with `GateAClean`.

## 2026-06-15 — LLM Wiki Phase A: Write path + change bridge — DONE ✅ (gate passed)

Branch `llmwiki/phase-a-write-path` (stacked on `llmwiki/phase-0-many-wikis`).
Implements `plans/llm-wiki.md` Phase A: the `wikictl` write path, the shared
link-reparse refactor, and the Darwin-notification → debounced app refresh +
`signalChange()` change bridge. **All deterministic (no agent yet).** Independent
live-mount gate (Bash + one UI check) PASSED.

**Added / changed**
- **Shared upsert+reparse seam (`WikiFSCore/PageUpsert.swift`).** Lifted "create-
  or-update a page + reparse `[[links]]` + `replaceLinks`" out of
  `WikiStoreModel.save()` into `PageUpsert.upsert(in:id:title:body:)`. BOTH the
  app model (`save()` now calls it) AND `wikictl` call this one op, so the link
  graph stays consistent **identically** from both writers (the doc's "no second
  drifting implementation in the CLI"). Resolution order: explicit `--id` →
  title→id via `resolveTitleToID` → create. Returns the id + a `didCreate` flag.
  `newPage()` still uses `createPage` directly (it must always create, never
  resolve-to-existing). A unit test drives the SAME content through `PageUpsert`
  and through the model and asserts byte-identical `page_links`.
- **`wikictl` CLI — new SwiftPM targets.** Logic lives in a LIBRARY target
  `WikiCtlCore` (arg parsing, command dispatch, wiki resolution, the Darwin post)
  so it's unit-testable; the `wikictl` executable target is a thin process shell
  over it (the same library/executable split `WikiFSCore` uses). Command surface,
  each selecting the wiki via `--wiki <id-or-name>` or the `WIKI_DB` env var:
  - `page list [--json]` — id / title / mount-relative `pages/by-title/…` path per
    line, TSV or JSON (the path uses the SAME `FilenameEscaping` as the projection
    so the agent can `cat` it).
  - `page get (--title X | --id Y)` — prints the body. The **instant SoT read**
    that bypasses the ~5 s mount lag.
  - `page upsert --title X [--id Y] --body-file <path|->` — create-or-update via
    the shared `PageUpsert`; prints the resulting id. `-` reads stdin.
  - `page delete --id Y`.
  Opens the wiki's `<ulid>.sqlite` **read-write** via the literal App Group path
  the un-sandboxed app uses (`WikiResolver` → `DatabaseLocation.appGroupContainerDirectory`),
  resolved through the SAME `WikiRegistry` the app reads. WAL + `busy_timeout=5000`
  make the second writer safe. Exit codes: 0 ok / 2 usage / 1 runtime.
- **Darwin notification — wiki id in the NAME.** Darwin notifications carry no
  payload, so the wiki id can't be data. `WikiChangeNotification`
  (`WikiFSCore`, shared so the two sides can't drift) encodes it in the name:
  `org.sockpuppet.wiki.changed.<wikiID>`. `wikictl` posts THIS per-wiki name after
  every committing call (`upsert`/`delete`), never on a read, and **never signals
  the File Provider itself** — that stays the app's job (single owner of FP
  signaling). The app subscribes to exactly that name for each registered wiki, so
  the change bridge learns WHICH wiki changed with no demux table. (Rejected: one
  generic name + refresh-all-wikis — wasteful with N wikis and loses the "which
  wiki" the doc wants.)
- **Change bridge in the app (`WikiFS/WikiChangeBridge.swift`).** Observes the
  per-wiki Darwin notification for every registered wiki (re-subscribes on the
  wiki set changing via `.onChange(of: manager.wikis)`), and for the changed wiki,
  after a **per-wiki ~250 ms coalesce**, (a) rebuilds the active store's
  `summaries` if that wiki is on screen (`WikiStoreModel.reloadFromStore()`, a full
  source rebuild per §3.1) and (b) calls `FileProviderSpike.signalChange(forWikiID:)`
  so that wiki's mount refreshes (~5 s). The CF observer fires on a CFRunLoop
  callback and **hops to the main actor** before touching the coalescer / model /
  FP. The coalescing itself is the PURE `WikiFSCore/ChangeCoalescer` (injected
  scheduler + flush) so the debounce is unit-tested with a fake clock — one ingest
  burst of ~15 `wikictl` calls collapses to one rebuild + one FP signal per wiki.
- **`FileProviderSpike.signalChange(forWikiID:)`** — a per-wiki variant (the old
  `signalChange()` now delegates to it for the active wiki) so the bridge can
  refresh a wiki that is NOT the one on screen.
- **Packaging.** `Package.swift` gains `WikiCtlCore` + `wikictl`. `build.sh`
  builds `wikictl`, copies it to `build/wikictl` for the gate to invoke directly,
  AND embeds + codesigns it at `WikiFS.app/Contents/Helpers/wikictl` for Phase C's
  app-spawn. Read-only FP invariant intact — `wikictl` writes ONLY SQLite.
- Tests: 86 → **113** (+27). `PageUpsertTests` (create/update/explicit-id/
  duplicate-title resolution, link reparse, replace-not-append, CLI-vs-model link
  parity), `WikiCtlCommandTests` (arg parsing for every command incl. env-vs-flag
  precedence + usage errors; `PageCommand` dispatch against a temp DB; Darwin name
  carries the id), `ChangeCoalescerTests` (burst→one flush, per-wiki independence,
  re-arm after flush). `make test` → **113/113**; `make` clean signed bundle
  (app + appex + wikictl all real-signed).

**Smoke-tested (Bash, against the real registry's wiki, non-destructive)**
- `page list` (TSV + `--json`), `page get --title/--id`, `WIKI_DB` env and
  display-name selectors all resolve and return live SQLite bytes. An `upsert`
  with a `[[Home]]` body wrote a real `page_links` row (shared reparse seam works
  from the CLI), `page get` read it back instantly, and `delete` removed it (list
  returned to 2). Error paths return the right exit codes (unknown wiki → 1, bad
  args → 2).

**Verified (independent live gate, real `make clean && make install`, real-signed, Bash + one computer-use UI check)**
All five Phase A criteria passed; the decisive end-to-end run was on a
**freshly-created wiki `GateAClean`** (`01KV7BHTQM…`, mount `WikiFS-GateAClean`),
with items 1–2 also reconfirmed on the live `WikiFS` wiki.
- **(1) CLI write:** `printf 'Gate A body linking [[Home]]\n' | wikictl --wiki
  <id> page upsert --title "GateA-CLEAN9" --body-file -` → printed new id
  `01KV7BJWS8…`; SQLite row confirmed directly (title + body).
- **(2) Sidebar updates live (no relaunch):** the new page appeared in the running
  app's sidebar above Home, app pid unchanged — proving the per-wiki Darwin
  notification → debounced `WikiChangeBridge` → `reloadFromStore()` path
  (reconfirmed with two successive upserts on the WikiFS wiki).
- **(3) Mount reflects it (~1 s):** `pages/by-id/01KV7BJW….md` +
  `pages/by-title/GateA-CLEAN9--01KV7BJW.md` both served the exact body.
- **(4) Read-only intact:** overwrite/append of projected files AND of
  `indexes/links.jsonl` → "operation not permitted"; SQLite untouched.
- **(5) Link graph:** `page_links` row `01KV7BJW… → <Home>` and mount
  `indexes/links.jsonl` `{"from":"01KV7BJW…","to":"<Home>","link_text":"Home"}` —
  the CLI-written `[[Home]]` resolved through the shared `PageUpsert` seam end to
  end. Command surface (`get`/`list` TSV+JSON/`WIKI_DB` env/`delete`, exit codes
  1 unknown-wiki / 2 usage) all confirmed. 113/113 tests; real-signed app + appex
  + `wikictl`.

**Notes / carry-forward**
- **Heavily-churned domain replica can wedge (operational, NOT a code defect →
  use a fresh wiki for live gates).** The long-lived `WikiFS` domain's mount would
  not reflect CLI writes during the gate: `fileproviderctl dump` showed the
  daemon's replica holding a *phantom* page from an earlier session, `-1005`
  fetch errors, a missing `indexes/`, and "Stale NFS file handle" on
  previously-valid files — the extension wasn't even invoked. The DB itself is
  intact (a `wal_checkpoint(TRUNCATE)` confirmed all pages durable + readable by a
  fresh reader); this is a corrupted **daemon-side materialized replica**
  accumulated over many prior gate runs on that one domain. It did NOT recover via
  the app's `WIKIFS_REENUMERATE` remove+re-add, a `fileproviderd` bounce, or ~90 s
  of reconciliation — a true reset needs a domain teardown (only the signed app's
  lifecycle can do it; an ad-hoc CLI gets FP -2001/-2014). A **freshly-created**
  domain (`GateAClean`) materialized fully and correctly in ~1 s. **Phase B/C live
  gates should run against a freshly-created wiki, not the churned `WikiFS` one.**
  Logged to `ISSUES.md`.
- **~5 s mount-refresh window** (replicated-FP read-after-write) still applies; the
  CLI's `page get` is the instant-SoT escape hatch.
- **macOS-26 TCC prompt** ("access data from other apps") re-fires on a re-signed
  install and holds the app until "Allow" (Phase 0 carry-forward).
- A gate artifact wiki **`GateAClean`** was left in place (deleting is destructive;
  the gate doesn't require teardown); its only content is a seeded empty `Home`.

## 2026-06-15 — LLM Wiki Phase 0: Many wikis (foundation) — DONE ✅ (gate passed)

Branch `llmwiki/phase-0-many-wikis` (stacked on the post-v0 line). Implements
`plans/llm-wiki.md` Phase 0: one SQLite DB + one File Provider domain **per
wiki**, a registry, an in-app switcher, and migration of the single v0 wiki as
wiki #1. Independent live-mount gate (computer-use + Bash) PASSED after one
fix round (the migration duplication loop below).

**Added / changed**
- **Registry (`WikiFSCore`).** New `WikiDescriptor` (id ULID, displayName,
  createdAt, lastUsedAt) — `dbFileName` (`<ulid>.sqlite`) and `domainIdentifier`
  (the bare ULID) BOTH derive from the ULID, **never the display name**, so a
  rename can't orphan the DB or the mount (the doc's explicit open-risk). New
  `WikiRegistry` (Codable) persisted as `wikis.json` in the App Group container:
  MRU-ordered list, add/rename/touch/remove, atomic save, corrupt/missing →
  empty (no launch crash).
- **`DatabaseLocation` generalized.** Split into `appGroupContainerDirectory()`
  (literal home path, app) + `extensionContainerDirectory()` (security API,
  extension), each with a per-wiki `…URL(forWikiID:)` → `<ulid>.sqlite`. The
  literal-vs-`containerURL` app/extension split is preserved; the legacy
  `WikiFS.sqlite` constant + Application-Support migration are kept for the v0
  adoption.
- **Extension maps domain → DB (the crux).** `Projection` went from a static
  `enum` to a `struct Projection { let wikiID }`; `init(domain:)` builds
  `Projection(wikiID: domain.identifier.rawValue)` and threads it through
  `WikiFSEnumerator`. `openReadStore()` resolves
  `extensionContainerURL(forWikiID:)` — same projection logic, different DB per
  domain, **no registry read** in the extension. The token-keyed index cache is
  now keyed by `(wikiID, identifier)` so two domains in one process can't collide.
- **`WikiManager` (`WikiFSCore`, `@MainActor @Observable`).** Owns the registry,
  the active `WikiStoreModel`, and create/select/rename/delete. File-Provider
  side effects (`registerDomain`/`removeDomain`) + `onActiveStoreDidChange` are
  injected CLOSURES, so the whole switcher logic is unit-testable without
  importing `FileProvider` (same pattern as `onPageDidChange`). Resolves per-wiki
  DB paths under an injected `containerDirectory` (hermetic tests).
- **One domain per wiki.** `FileProviderSpike` rewritten from a single static
  domain to per-wiki `registerDomain`/`removeDomain`/`activate`/`signalChange`,
  each keyed by the wiki ULID; mounts at `~/Library/CloudStorage/WikiFS-<name>`.
  The v0 `WIKIFS_REENUMERATE` one-shot hatch is preserved, scoped per domain.
  Obsolete single-domain `WelcomeView` spike removed.
- **Switcher UI.** `WikiSwitcher` — a sidebar-header `Menu` (`.headline`, native
  "account header" idiom) listing wikis to select, with New Wiki…/Rename/Delete;
  a `NewWikiSheet` for naming; a destructive-confirm delete alert. `RootView`
  hosts the active wiki's `ContentView` keyed by `.id(activeWikiID)` so no
  draft/selection leaks across a switch. `WikiFSApp` builds the manager, wires
  the FP closures, bootstraps, and registers all domains on launch.
- **v0 migration.** On first launch `WikiManager.bootstrap()` renames the legacy
  `WikiFS.sqlite` (+ `-wal`/`-shm`) to `<ulid>.sqlite` and registers it as wiki
  #1 named "WikiFS" — all pages/files/system_prompt ride along untouched (same
  file). **Strictly one-time, idempotent across any number of launches:** the
  whole legacy-import chain is gated on an EMPTY registry. The first gate run
  found this was broken — two un-coordinated migration layers (`WikiManager`
  renames the container file away; `DatabaseLocation.migrateFromApplicationSupportIfNeeded`
  re-copies it from Application Support) formed a duplication loop, spawning a new
  "WikiFS" wiki on every launch. Fixed by gating BOTH layers on the registry
  being empty: `WikiFSApp.init` only runs the Application-Support copy when the
  registry is empty, and `bootstrap()` only calls `migrateLegacyWikiIfNeeded`
  when the registry is empty. Net invariant: a v0 user's first launch → exactly
  one wiki #1; every subsequent launch adds zero wikis and keeps it active; a
  non-empty registry + a stray legacy file never creates a new wiki.
- Tests: 69 → **86** (+17). New `WikiRegistryTests` (round-trip, MRU,
  rename-keeps-identity, ULID-derived paths) + `WikiManagerTests` (fresh-seed,
  per-wiki DB isolation, distinct files on disk, delete removes DB, MRU
  launch-pick, rename doesn't move the file, v0 migration preserves content +
  doesn't re-run, **legacy file reappearing after first launch doesn't
  duplicate**, **stray legacy file + non-empty registry creates no wiki**).
  `make test` → **86/86**; `make check` clean; real `make` app-bundle build +
  codesign (app + appex) clean.

**Verified (independent live gate, real `make clean && make install`, real-signed, computer-use + Bash)**
- **Create + isolation + independent DBs:** created a second wiki **"GateBeta"**
  in-app via the sidebar switcher → it mounted at its own
  `~/Library/CloudStorage/WikiFS-GateBeta` with its own `<ulid>.sqlite` (3
  distinct ULID DB files in the container at peak). Added a sentinel page
  `BetaSentinelZ9` in GateBeta → it appeared ONLY in GateBeta's DB (`count(*)=1`;
  `0` in both other DBs) and ONLY in GateBeta's mount; the v0 wiki's unique
  `Target` page never appeared in GateBeta's mount, and `BetaSentinelZ9` never
  appeared in the v0 wiki's mount (`WikiFS-WikiFS`). Isolation proven both ways.
- **Delete removes domain + DB:** deleted GateBeta via the switcher (destructive
  confirm dialog) → its registry entry, `<ulid>.sqlite` + `-wal`/`-shm` sidecars,
  Finder mount, AND File Provider domain (`fileproviderctl`) were all gone.
- **v0 preserved + migration idempotent (the fix):** from a v0 starting point
  (Application Support `WikiFS.sqlite` present, empty registry), the FIRST launch
  migrated to **exactly one** wiki #1 "WikiFS" carrying the full v0 content —
  original `Home` (`01KV6EAH…`) + `Target` (`01KV6KS0…`) + the ingested
  `[MS-NRPC] (1).pdf` — served read-only on the mount. Repeated relaunches **with
  the Application Support source still present** kept the registry at exactly one
  wiki (same id) and one ULID DB — zero duplicates (the pre-fix code spawned a new
  "WikiFS" every launch). Read-only still enforced (`echo >` rejected with
  "operation not permitted"; SQLite untouched).

**Notes / carry-forward**
- **macOS-26 TCC gate re-fires on a re-signed install:** "WikiFS would like to
  access data from other apps" appears (UserNotificationCenter) in `App.init()`
  and holds the app hostage until "Allow" — migration/bootstrap don't run until
  it's dismissed. Consent persists across launches within an install. Already
  documented in `PROGRESS.md`/`ISSUES.md`; surfaced again here driving the gate.
- **Mount labels:** each wiki mounts at `~/Library/CloudStorage/WikiFS-<display>`;
  two wikis with the same display name collide on the Finder label (not the DB —
  identity is the ULID). With the migration fixed there are no spurious
  same-named duplicates; deliberate same-name wikis remain out of scope to dedupe.
- **Stale domains** from prior manual file-archiving aren't reaped by the app
  (it registers add-if-absent; `NSFileProviderManager.removeAllDomains` needs the
  provider-app context, so an ad-hoc CLI can't reap them). Cosmetic only.

A user-editable singleton "system prompt" document — the instructions the
managing agent reads each run — projected **read-only at the wiki root under TWO
names with identical bytes: `CLAUDE.md` and `AGENTS.md`** (the filenames CLI
agents look for). Edited in-app like a page; read-only on the mount like
everything else. Branch work stacked on the v0 + Phase-5 line.

**User-chosen scope (locked):** in-app editing via a **pinned sidebar item**
(above Pages) that opens the document in the main editor pane — i.e. a
first-class document, not a sheet/settings window.

**Added / changed**
- **New singleton `system_prompt` table** (`id INTEGER PRIMARY KEY CHECK(id=1)`,
  `body_markdown`, `updated_at`, `version`). `bootstrapSchema()` gains a stepwise
  **v2→3 migration** that creates AND **seeds** the row with
  `SystemPrompt.defaultBody`; existing v1/v2 DBs migrate forward with pages +
  ingested files preserved (test-proven). `SystemPrompt` value type +
  `defaultBody` live in `WikiFSCore` (shared by the migration seed and the
  projection fallback).
- **Store API** (`SQLiteWikiStore` + `WikiStore` protocol): `getSystemPrompt()`
  (returns the seeded default if absent) and `updateSystemPrompt(body:)`
  (**UPSERT**, `version = version + 1`).
- **⚠️ `changeToken()` now folds in the system-prompt version** →
  `"pCount:pSum:fCount:fSum:spVersion"`. Editing ONLY the prompt (no page/file
  change) must still advance the sync anchor or the projected files would never
  refresh. Resilient to the table being absent on a pre-v3 read connection
  (→ `0`). All `changeToken` test literals gained the trailing `:1`.
- **Projection**: `CLAUDE.md` + `AGENTS.md` as root-level files (new
  `claude-md`/`agents-md` identities), both serving the SAME live body (read like
  a page in both `node` and `contents`); item version = the row `version`. Added
  to root children, the working set, and `contents(for:)`; README updated.
  `systemPromptDocument()` falls back to `SystemPrompt.defaultBody` so the two
  files ALWAYS exist even pre-migration. **No new signal container needed** — both
  are root children, so the existing `.rootContainer` + `.workingSet` signals
  refresh them (same path as `manifest.json`).
- **Model/UI**: sidebar selection generalized from `PageID?` to a new
  `WikiSelection` enum (`.page` / `.systemPrompt`); the autosave tests reference
  selection opaquely so the load-bearing §3.5 logic is untouched. New
  `draftSystemPrompt` track with its own debounce + `flushPendingSystemPromptSave`
  (combined `flushPendingSaves()` used on switch + backgrounding). `SidebarView`
  pins a **"System Prompt"** item above Pages; `ContentView` switches the detail
  pane; new `SystemPromptDetailView` (header explaining the projection + editor +
  live preview, semantic Dynamic-Type styles).
- Tests: 63 → **69** (new `SystemPromptTests`: seed default, update bumps
  version + persists across reopen, repeated edits, token advances on a
  prompt-only edit, UPSERT recreates a deleted row, v2→3 migration preserving
  pages + files). Updated `SQLiteWikiStoreTests` (user_version 3, `system_prompt`
  table, `:1` token suffix) and the `IngestedFilesTests` migration assertion (→3).

**Verified (live signed mount, real `make install`, computer-use + Bash)**
- **Byte-identity:** `CLAUDE.md` and `AGENTS.md` byte-identical to each other AND
  to the seeded DB body (`writefile` raw compare; sha `17e74587…`, 770 bytes —
  762 *chars*, the gap is UTF-8 em-dashes). 69/69 tests; real Apple Development
  signing chain.
- **Refresh on edit (no relaunch):** edited the prompt **in-app** (appended a
  sentinel to the heading via the pinned "System Prompt" item), switched pages to
  flush → `system_prompt.version` bumped (1→3 across autosave+flush), sentinel
  persisted to SQLite. Within ~6 s the mount's `CLAUDE.md` AND `AGENTS.md` showed
  the new bytes (sha `f7021881…`), **app pid unchanged** (no relaunch). Reverted
  the sentinel in-app → both files returned to the clean default (sha
  `17e74587…`). The change-token's `spVersion` fold drives this end to end.
- **Read-only enforced:** append/overwrite of both files rejected (`operation not
  permitted`); SQLite row untouched; projected bytes still matched the DB (no
  client-side staging leak).
- **One-shot re-enumerate needed** on the already-materialized (phase-5) domain to
  surface the two new root files — launched once with `WIKIFS_REENUMERATE=1`, as
  predicted; fresh installs wouldn't need it.

**Notes / known gaps**
- The ~5 s read-after-write window (replicated-File-Provider replica invalidation,
  NOT a stale SQLite read) is documented in `ISSUES.md` — two items signaled
  together (`CLAUDE.md` + `AGENTS.md`) can also refresh a few seconds apart.
- Same `files/`-style caveat: on an already-materialized (upgraded) domain the
  two new root files may need the one-shot `WIKIFS_REENUMERATE=1` launch to
  appear; fresh installs are fine.
- Pre-existing flaky test `resolvesDuplicateTitleToLowestULID` (same-millisecond
  ULID ordering) is unrelated to this change — flagged separately.

## 2026-06-15 — Post-v0 feature: File ingestion (drag-to-ingest) — DONE ✅

Dragging a file into the app **ingests** it: stores the **raw bytes + metadata**
in SQLite as a NEW object kind (NOT a wiki page) and surfaces it read-only under
a new `files/` File Provider tree, so Unix tools/agents can read the verbatim
file. A removable "Files" section lists ingested files. Branch
`phase-5-file-ingest` (stacked on `phase-4-agent-wiki`, unmerged).

**User-chosen scope (locked):** raw bytes only (NO text extraction/conversion —
a PDF stays a PDF); instant synchronous ingest with a managed removable list (NO
async pipeline / status states). Types: md/txt/PDF, but any file stored
generically.

**Added / changed**
- **New `ingested_files` table** (id ULID, filename, ext, mime_type, byte_size,
  content BLOB, timestamps, version) — separate from `pages` and from the
  page-tied `attachments`. `bootstrapSchema()` is now a **stepwise idempotent
  migration**: existing v1 DBs (with pages) get only the v1→2 step that adds the
  table — pages data preserved (test-proven). `SQLiteStatement` gained a BLOB
  binder/reader (`SQLITE_TRANSIENT`).
- **Store API** (`SQLiteWikiStore` + minimal `WikiStore` protocol additions):
  `ingestFile(filename:data:)` (ext via pathExtension, mime via UTType,
  **100 MB soft cap**, ULID id), `listIngestedFiles`, `getIngestedFile`,
  `ingestedFileContent` (BLOB read on demand only), `deleteIngestedFile`.
  Metadata queries never load the BLOB.
- **⚠️ `changeToken()` now folds in files** → `"pCount:pSum:fCount:fSum"`, so an
  ingest/remove advances the sync anchor and `files/` (and the indexes) refresh.
  Without this the mount would never reflect ingested files. Regression-tested.
- **`files/` projection**: `files/by-id/<ulid>.<ext>` + `files/by-name/
  <escaped-stem>--<shortid>.<ext>` (original extension preserved; identical raw
  bytes). New identities + `WikiFSContainerID` constants; wired into
  `node`/`children`/`contents`/`.workingSet`. Extension reads are **resilient to
  the table not existing yet** (pre-migration → empty, never error). A
  **dedicated ingested-file `contentType` branch** (UTType by ext, `.data`
  fallback) — the page/`.json`/`.jsonl` type logic is untouched (no regression).
- **Agent-facing index**: `manifest.json` gains `file_count` + `files_by_id` +
  `file_index`; new `indexes/files.jsonl` (`{id,name,path,size,mime}` per line),
  token-cached like the other indexes.
- **`signalChange()`** signals the `files` containers (plus root + `indexes`,
  already there) on ingest AND removal.
- **Model**: `ingestedFiles` list (rebuilt from source); `ingest(fileURLs:)`
  (off-main byte read, rejects directories, batches, single signal) + sync
  `ingestFile`/`deleteIngestedFile` seams — the drop UI is a thin shell over
  these, so ingestion is testable/Bash-verifiable without a drag gesture.
- **UI**: sectioned sidebar (`Pages` / `Files`, Files shown only when non-empty);
  `IngestedFileRow` (SF-symbol-by-ext + size, Remove via context menu + swipe,
  no `.tag` so it can't collide with page selection); whole-window
  `.dropDestination(for: URL.self)` with a Reduce-Motion-aware accent highlight.
- Tests: 47 → **63** (ingest round-trip + byte-identity, ext/mime derivation,
  delete, the v1→2 migration, `changeToken` advancing on ingest/delete,
  `filesJSONL`, manifest `file_count`, by-name escaping, duplicate drops).

**Verified — real Finder drag of an 8 MB PDF (`[MS-NRPC] (1).pdf`), then Bash**
- SQLite row: ext `pdf`, mime `application/pdf`, `byte_size == length(content)
  == 7,970,045`.
- Served at `files/by-id/01KV6PAD….pdf` and `files/by-name/[MS-NRPC] (1)--
  01KV6PAD.pdf`; **byte-identical** to the SQLite blob (sha256 `b1b07a28…`,
  all 7,970,045 bytes) — raw bytes stored + served verbatim.
- `indexes/files.jsonl` + `manifest.json` `file_count` reflect it (after the
  ~5 s eventual-consistency settle). Read-only enforced (write rejected; SQLite
  untouched). Pages / Phases 1–4 not regressed. 63/63 tests; real-signed.

**Notes / known gaps**
- Generated indexes (`files.jsonl`, `manifest`) trail the raw `files/`
  enumeration by the usual ~5 s eventual-consistency window after a change.
- `files/` is a new top-level folder; on an already-materialized (upgraded)
  domain it needs a one-shot `WIKIFS_REENUMERATE=1` launch to appear (same as
  `indexes/` in Phase 4); fresh installs are fine.
- The drag gesture + ingest were confirmed via a real user drag; the sidebar
  **Remove** affordance is unit-tested + harness-verified at the store layer but
  was not visually gate-confirmed (user opted to finalize).
- Out of scope: text extraction, async/status queue, OCR, thumbnails, file
  detail view, linking files to pages, dedup, recursive directory ingest.

## 2026-06-15 — 🎉 v0 DONE ✅ — all four phases gate-passed

WikiFS v0 is complete: a native macOS SwiftUI wiki, SQLite-backed, projected
read-only onto the filesystem via a File Provider extension, kept fresh on edit,
and traversable by an agent launched with `WIKI_ROOT`. Built across four stacked,
unmerged branches off a pristine `main` (review/merge locally):

- `phase-1-local-wiki` — **Phase 1 (M0+M1)**: SQLite wiki + editor. Gate: create
  Home, type Markdown, live preview, quit/relaunch persistence, matching SQLite
  row. (computer-use)
- `phase-2-file-provider` — **Phase 2 (M2+M3)**: read-only SQLite projection.
  Gate: `find .` shows the tree, `cat pages/by-title/Home--*.md` returns live
  SQLite bytes from both by-title and by-id, read-only enforced. (live mount)
- `phase-3-verify-fresh` — **Phase 3 (M4+M5)**: Copy Unix Path + change-signaling.
  Gate: copy path → cat → edit in app (token `1:5→1:6`) → re-cat shows new bytes,
  NO relaunch. Closes INITIAL §12. (computer-use)
- `phase-4-agent-wiki` — **Phase 4 (M6 + generated views)**: indexes, wiki-links,
  agent launcher. Gate below.

**Verification method note:** Phases 1–3 and most of Phase 4 were driven via
computer-use/Bash by dedicated verifier subagents. The Phase-4 index/link/
read-only/freshness checks were validated directly via Bash (no screen
disruption); the in-app agent-launcher output panel was confirmed by the user
(GUI automation was repeatedly stealing focus, so we stopped fighting it).

**What is stubbed / deferred (known v0 gaps):**
- `enumerateChanges` deletion semantics (`didDeleteItems`) not implemented.
- A brand-new top-level projection folder (e.g. `indexes/`) needs a one-shot
  domain re-enumeration on an already-materialized (upgraded) domain — handled
  by a gated `WIKIFS_REENUMERATE=1` launch hatch; fresh installs don't need it.
- Rename does not re-resolve the whole wiki-link graph (stale cross-page links
  self-heal on the linking page's next save).
- Read-after-write is eventually-consistent (~5 s) — a `cat` within ~1 s of a
  save can briefly show stale bytes before refreshing (no relaunch needed).
- macOS-26 TCC "access data from other apps" prompt fires in `App.init()` and
  re-prompts per re-signed install (cleanup idea: move the DB open off init).
- Optional post-v0 views skipped: by-created/updated-date, tags/backlinks/
  attachments JSONL.

## 2026-06-15 — Phase 4 (M6 + generated views): Agent-facing wiki — DONE ✅ (gate passed)

Branch `phase-4-agent-wiki` (stacked on `phase-3-verify-fresh`, unmerged).
Layers the agent surface on top of the v0 loop.

**Added / changed**
- **Wiki-links (INITIAL §4).** `WikiFSCore/WikiLinkParser.swift` (pure, tested):
  `[[Title]]` + `[[Target|alias]]`, whitespace-collapse, dedupe, skip empty.
  `SQLiteWikiStore` gains `resolveTitleToID` (lowest ULID on duplicate titles),
  `replaceLinks` (one txn: delete-then-`INSERT OR IGNORE` the resolved subset;
  **unresolved links omitted** — `page_links.to_page_id` is NOT NULL/FK; self-
  links allowed), `listAllLinks`. `WikiStoreModel.save()`/`newPage()` re-parse +
  rewrite that page's links. **`deletePage` now clears `page_links` rows
  referencing the page (source OR target) first** — required under
  `foreign_keys=ON` or deleting a linked page throws (orchestrator-caught;
  regression-tested).
- **Generated indexes (INITIAL §5).** `WikiFSCore/IndexGenerators.swift` (pure,
  deterministic, tested): `manifest.json` (`name/version/generated_at/
  page_count/paths`), `indexes/pages.jsonl` (one line/page, by id), `indexes/
  links.jsonl` (one line/link from `page_links`). `Projection` adds the four
  identities + a **token-keyed (`count:sum(version)`) byte cache** so a node's
  `documentSize` and its `contents` bytes always come from the same snapshot
  (a mismatch truncates `cat`). `signalChange()` now also signals `.rootContainer`
  + `indexes` so edits invalidate the generated files.
- **Agent launcher (INITIAL §8 / M6).** `WikiFS/AgentLauncher.swift`
  (`@MainActor @Observable`) spawns `/bin/zsh -lc <command>` with `WIKI_ROOT` =
  the live mount (resolved via `getUserVisibleURL` at click time, never
  hardcoded), streaming stdout+stderr into the UI via pipe `readabilityHandler`s
  (non-blocking; `terminationHandler` for exit status). `AgentLauncherView.swift`
  is the sheet (editable command, Run/Stop, scrolling output). Works because the
  app is **un-sandboxed** (the Phase-2 Option-B call) — a sandboxed app couldn't
  `Process`-spawn. Before spawning, `await signalChange()` so the agent sees
  current content (no fixed-sleep correctness dependency).
- Tests: 24 → **47** (WikiLinkParser, replaceLinks/resolve/listAllLinks,
  deletePage-with-links FK regression, index generators).

**Verified (Bash by the orchestrator + user-confirmed GUI)**
- `manifest.json` valid, `page_count: 2` == `select count(*) from pages`.
- `indexes/pages.jsonl`: 2 valid JSON lines == 2 pages. `indexes/links.jsonl`:
  the **cross-page link** `Home→Target` (`{"from","to","link_text":"Target"}`),
  valid, == the one `page_links` row — `[[Target]]` in Home's body parsed through
  to the index end to end.
- Read-only: `manifest.json` overwrite → "operation not permitted"; SQLite
  untouched. Phase-3 freshness intact (Home body served fresh, no relaunch).
- 47/47 tests; real-signed `make install`.
- **Agent launcher: user confirmed** the in-app output panel populated with the
  `find` tree + manifest + both JSONL files when clicking Run Agent (WIKI_ROOT =
  the live `~/Library/CloudStorage/WikiFS-WikiFS` mount).

## 2026-06-15 — Phase 3 (M4+M5): Verify & stay fresh — DONE ✅ (v0 ship-gate loop passed)

**This closes the v0 definition of done (INITIAL §12):** copy a Unix path → read
it in Terminal → edit in the app → re-read sees the update, no relaunch. Branch
`phase-3-verify-fresh` (stacked on `phase-2-file-provider`, unmerged). Phase 4
(agent-facing wiki) is the extension on top; the core v0 loop is now proven.

**Added / changed**
- **M4 — path button.** `Sources/WikiFS/VerificationPopover.swift` (NEW) +
  `ContentView.swift`: a `Copy Unix Path` toolbar button (⌘⇧U) opening a popover
  that resolves the mount URL **at click time** via
  `NSFileProviderManager.getUserVisibleURL(for: .rootContainer)` (NEVER
  hardcoded), copies `url.path` to the pasteboard, shows it (monospaced,
  selectable), and offers a copyable `cd … && find . && cat pages/by-title/Home--*.md`
  block + Reveal in Finder. (Open Terminal Here skipped — Process hop is Phase 4.)
- **M5 — change-signaling (defeats read-after-write staleness).**
  - `WikiFSCore/SQLiteWikiStore.swift` — `changeToken()` = `"count:sum(version)"`.
    **NOT `MAX(version)`:** `version` is per-page, so `MAX` wouldn't advance when
    a non-max page is edited (would stay stale); `count:sum` advances on every
    create/update/delete. Locked by `changeTokenAdvancesOnEveryMutation`.
  - `WikiFSFileProvider/WikiFSEnumerator.swift` — `currentSyncAnchor` returns the
    live token; `enumerateChanges` re-emits page items (carrying higher
    `contentVersion`) when the token advanced → daemon invalidates the
    materialized copy → next read re-fetches from SQLite. Legacy/unparseable
    anchors (the Phase-2 `"v2-sqlite"`) treated as expired → clean full
    re-enumerate.
  - `WikiFSCore/WikiStoreModel.swift` — `@ObservationIgnored onPageDidChange`
    hook fired on save/new/rename/delete success (NO FileProvider import in core).
  - `WikiFS/FileProviderSpike.swift` — `signalChange()` signals **three**
    containers: `pages-by-title`, `pages-by-id`, and `.workingSet` (signaling root
    alone wouldn't refresh the page lists). `registerIfNeeded()` rewritten
    **add-if-absent** — the Phase-2 `remove(.removeAll)` relaunch hack is GONE.
  - `WikiFSCore/WikiFSContainerID.swift` (NEW) — shared plain-`String` container-id
    constants used by BOTH the extension and the app, so the signaled ids can't
    drift from the projection's ids.
  - `WikiFSApp.swift` — wires `store.onPageDidChange = { fileProvider.signalChange() }`.
- Tests: 23 → **24** (+`changeTokenAdvancesOnEveryMutation`).

**Verified (independent computer-use gate, fresh `make clean && make install`, real-signed)**
- Copy Unix Path → clipboard held `/Users/tqbf/Library/CloudStorage/WikiFS-WikiFS`
  (overwrote a pre-seeded sentinel → the app wrote it); path matches the live
  mount `fileproviderctl dump` reports.
- `cat` original Home (`VERIFY-7Q4Z`) → edit through the app to `FRESH-D7F04E00`
  → change token advanced **`1:5 → 1:6`**, row now `version 6` (proves the edit
  went through the app's real save pipeline, not a DB poke) → re-`cat` the SAME
  files (by-title AND by-id) showed the NEW bytes, **app never relaunched** (pid
  stayed up). Read-only not regressed (writes rejected / staged-then-reverted;
  SQLite untouched). 24/24 tests; real Apple Development signing chain.

**Caveat (carry into Phase 4)**
- **Refresh is eventually-consistent (~5 s):** `signalEnumerator` →
  `enumerateChanges` → re-fetch is async, so a `cat` within ~1 s of saving can
  briefly show stale bytes before refreshing on its own (no relaunch needed). A
  tightly-polling agent (Phase 4) may want a short settle or an explicit sync
  step before reading just-written content.

## 2026-06-15 — Phase 2 (M2+M3): File Provider projection from SQLite — DONE ✅ (gate passed)

The File Provider extension now serves a **read-only filesystem projection of the
SQLite wiki**, shared with the app via the App Group container. Branch
`phase-2-file-provider` (stacked on `phase-1-local-wiki`, unmerged). A swap of
the spike's static `Catalog` for a live SQLite projection — the appex plumbing,
entry-point flag, inside-out signing, and domain registration all carried over.

**Added / changed**
- `Sources/WikiFSFileProvider/Projection.swift` (NEW; `Catalog.swift` deleted) —
  identity↔row mapping, static `README.md`, filename escaping, and
  `node(for:)`/`children(of:)`/`contents(for:)`, each opening a **short-lived
  read connection** to the App Group DB via `extensionContainerURL()`.
  Virtual ids carry the **full ULID, never the filename** (paths are
  presentation — INITIAL §6).
- `WikiFSCore/SQLiteWikiStore.swift` — `init(readOnlyURL:)` opens a read-WRITE
  handle then `PRAGMA query_only=ON` (NOT `SQLITE_OPEN_READONLY`): robustly
  attaches the WAL `-shm` even when no writer is running (matters for Phase-4
  agents reading with the app closed) while still rejecting writes.
- `WikiFSCore/DatabaseLocation.swift` — `appGroupContainerURL()` (literal path,
  used by the un-sandboxed app, no entitlement needed), `extensionContainerURL()`
  (`containerURL(forSecurityApplicationGroupIdentifier:)`, sandboxed extension;
  same inode), `migrateFromApplicationSupportIfNeeded()` (checkpoint-TRUNCATE +
  copy the single `.sqlite`).
- `WikiFSFileProvider/WikiFSItem.swift` — real `documentSize` (=`utf8.count`,
  never nil → no truncated `cat`), `contentType`, creation/mod dates, and
  content/metadata `itemVersion` from the row. Read-only capabilities.
- `WikiFSFileProvider/WikiFSEnumerator.swift` — queries `Projection`,
  offset-paginated (256/page), sync anchor bumped to `"v2-sqlite"` so any cached
  spike enumeration expires.
- `WikiFS/WikiFSApp.swift` + `FileProviderSpike.swift` — open the App Group DB
  (after migration); `registerIfNeeded()` does `remove(_, mode: .removeAll)` then
  `add` on launch so the daemon re-enumerates from the SQLite extension.
- `Package.swift` — extension target depends on `WikiFSCore`; `-e
  _NSExtensionMain` flag + `FileProvider` framework preserved. `build.sh`
  unchanged.
- Tests: +13 (FilenameEscaping, ReadOnlyStore) → **23 total, all pass**.

**Decision — Option B: app stays UN-sandboxed**
Both processes share the literal `~/Library/Group Containers/group.org.sockpuppet.wiki/WikiFS.sqlite`
(app writes the literal path; sandboxed extension resolves the same inode via
`containerURL`). Rejected sandboxing the app (Option A) because it would (1)
redirect `Application Support` and orphan the Phase-1 DB, and (2) front-load the
Phase-4 `Process`/agent-spawn restriction (`signing.md`) for zero Phase-2
benefit. The container dir is user-owned and writable by a non-sandboxed
process. Phase-1's `Home` row **migrated** intact (same ULID
`01KV6EAH410NWC9K9ZM44DNMXT`).

**Verified (independent gate, fresh `make clean && make install`, real-signed)**
- `find .` → `README.md` + `pages/by-id/<ULID>.md` + `pages/by-title/Home--<id8>.md`
  (the SQLite ULID, not the static spike tree).
- `cat` of by-title AND by-id → byte-identical Home body (`VERIFY-7Q4Z` sentinel,
  62 bytes, `shasum b6ef887f…`), exactly matching the SQLite row.
- Read-only: `createItem` → FP -2010; shell writes stage client-side then revert;
  SQLite source of truth never altered. Extension `+`-enabled, fresh appex
  (Timestamp 20:44:24) serving.

**Notes / caveats (carry into Phase 3)**
- **macOS 26 TCC gate:** first App Group access raises *"WikiFS would like to
  access data from other apps"* (Allow/Don't-Allow, NOT Touch ID). It fires
  synchronously in SwiftUI `App.init()`, so the window is hostage to it, and a
  re-signed `make install` re-prompts. Consent persisted across the gate launch.
  *Cleanup idea:* move the DB open off `App.init()` so the window renders while
  the prompt is pending.
- **Read-after-write staleness on EDITS is still present — that's Phase 3's job.**
  The blunt `remove(.removeAll)` refresh on launch is replaced in Phase 3 by
  per-item version bumps + `signalEnumerator`.
- Read-only root: a shell `echo > f` stages then reverts (File Provider client
  framework behavior); never reaches SQLite. Optional polish: disallow
  adding-sub-items on the root capabilities for up-front shell rejection.
- All 5 File Provider gotchas intact (entry-point flag, entitlements⊆profile,
  user-enabled, /Applications via `make install`, real codesign).
- **Operational:** the Mac went to the **lock screen** during the Phase-2 run;
  the gate's load-bearing evidence was read directly from the live mount
  (identical regardless of GUI lock), but the GUI-driven Phase-3 gate (edit in
  app → re-read in Terminal) needs the screen unlocked + kept awake.

## 2026-06-15 — Phase 1 (M0+M1): Local SQLite wiki — DONE ✅ (gate passed)

A usable standalone Markdown wiki, persisted in SQLite, verified on the running
app (not just a green build). Branch `phase-1-local-wiki` (stacked off `main`,
unmerged — review locally; the pipeline keeps `main` pristine and stacks each
phase branch on the prior).

**Added**
- `Sources/WikiFSCore/` — new **library** target (so the store is unit-testable
  now and the read surface is reusable by the Phase-2 extension):
  - `SQLiteWikiStore.swift` — hand-wrapped system `SQLite3` (no third-party
    dep). `READWRITE|CREATE|FULLMUTEX`; pragmas `journal_mode=WAL` (return row
    asserted == `wal`) / `foreign_keys=ON` / `busy_timeout=5000`;
    `user_version`-guarded idempotent bootstrap of `pages`+`attachments`+
    `page_links` + unique slug index; statement cache; **`SQLITE_TRANSIENT`**
    text binding (not STATIC); slug collision suffix `-<first6 of ULID>`.
  - `ULID.swift` (48-bit ms ‖ 80 random bits, Crockford base32 — lexical sort
    == creation order, for cheap Phase-4 by-date views), `PageID`, `WikiPage`,
    `WikiPageSummary`, `WikiStore`(+`WikiStoreError`), `DatabaseLocation`,
    `WikiStoreModel`.
  - `WikiStoreModel.swift` — `@MainActor @Observable`. `summaries` always
    rebuilt from `store.listPages()` (never patched — SWIFTUI-RULES §3.1); live
    `draftTitle`/`draftBody` buffers (drafts live in the model so flush can read
    them — §3.5); 500 ms debounced autosave; `save()` reads live values at fire
    time and writes to the *loaded* page (correct even after selection advances);
    `flushPendingSave()` on page-switch and on app backgrounding.
- `Sources/WikiFS/` UI: `SidebarView` (List, +New, rename, delete via
  contextMenu **and** swipeActions), `PageDetailView` (title + `TextEditor` +
  live preview), `MarkdownPreview` (`AttributedString(markdown:)`, inline-only
  per INITIAL §4), `PageEditorMetrics`; `ContentView` rewired to
  `NavigationSplitView` + `ContentUnavailableView` empty state; `WikiFSApp`
  flushes autosave on `scenePhase != .active`. Spike files kept (Phase-2 ref),
  unhosted.
- `Tests/WikiFSTests/` — 10 tests incl. the §3.5/§9.4 stale-snapshot autosave
  regression and persistence-across-reopen.

**Decisions**
- **DB at `~/Library/Application Support/WikiFS/WikiFS.sqlite` for Phase 1**
  (option c), path injected via `DatabaseLocation`. The App Group container API
  (`containerURL(forSecurityApplicationGroupIdentifier:)`) returns `nil`
  without the sandbox + app-groups entitlement, and enabling the sandbox now
  would front-load the Phase-4 `Process`/agent-spawn restriction for zero
  Phase-1 benefit. **Phase 2 must repoint to the App Group container + run a
  one-time `migrate(from:to:)`** (hook noted in `DatabaseLocation.swift`). No
  entitlement/sandbox change this phase.
- Split `WikiFSCore` library (vs. `@testable import` of an executable) — clean
  testability + a shared store surface for the Phase-2 reader.
- Hand-wrapped SQLite3, no GRDB (dependency-free default honored).

**Verified (independent computer-use gate, fresh `make clean && make`)**
- Live preview: unique sentinel `VERIFY-7Q4Z` typed → preview rendered bold/
  italic live (screenshot read back, not just asserted).
- Persistence: clean-DB start → create `Home` → quit → relaunch → `Home` + body
  reload from disk. Running binary confirmed to be the fresh `build/` copy
  (`lsof`), alive 4 s past launch (no constraint crash).
- Data layer: `sqlite3 … "select … from pages"` → exactly one `Home` row with
  the exact sentinel body; DB at the literal Application Support path (no
  sandbox redirect). `make test` → 10/10 pass.

**Notes / caveats**
- Synthetic keystrokes don't reach SwiftUI `TextEditor`; the gate drove text via
  the AX `value` API (fires `.onChange` → autosave). Real user typing is
  unaffected. A bug found *by* the live gate — sidebar `List(selection:)` wrote
  the property directly, bypassing the load path — was fixed (`.onChange(of:
  selection)` → `handleSelectionChange`) with a regression test.
- Context-menu Rename / swipe-Delete are implemented + unit-tested but not
  visually gate-confirmed (outside the acceptance bar).
- DB state for Phase 2: fresh DB holds one clean `Home`; the pre-gate DB is
  preserved as `WikiFS.sqlite.verifier-bak` in the same dir.

## 2026-06-15 — File Provider spike PROVEN end to end ✅

De-risked the riskiest part of the project before Phase 1. A real
`NSFileProviderReplicatedExtension` (SwiftPM, no Xcode project), serving a
static tree, is mounted and readable from Terminal:
`cd ~/Library/CloudStorage/WikiFS-WikiFS && find . && cat README.md && grep -R …`
all work. Full writeup + the five gotchas: `plans/file-provider.md`.

**Added (spike code — kept as the Phase 2 reference, serves static content):**
- `Sources/WikiFSFileProvider/` — extension (`FileProviderExtension`,
  `WikiFSEnumerator`, `WikiFSItem`, `Catalog`, `main.swift`).
- `Sources/WikiFS/FileProviderSpike.swift` + `WelcomeView.swift` — register the
  domain, resolve the user-visible path, reveal/copy it.
- `WikiFS/WikiFSFileProvider.entitlements`; second SwiftPM target in
  `Package.swift`; `build.sh` now assembles + inside-out-signs the `.appex`.

**Five gotchas solved (each cost time — see plans/file-provider.md):**
1. Entitlements must be ⊆ the profile — claiming `get-task-allow` (which these
   profiles lack) → AMFI SIGKILL at exec, no crash log.
2. Mach-O entry must be `_NSExtensionMain` via `-e` linker flag; a Swift
   `main()` calling `NSExtensionMain()` recurses → SIGSEGV.
3. Third-party File Provider must be user-enabled in System Settings (consent
   gate); `EnabledByDefault` doesn't bypass it.
4. App must be in `/Applications` + launched once for `pluginkit` discovery →
   dev loop is `make install`.
5. First codesign with a fresh cert needs a one-time keychain approval
   (errSecInternalComponent until then).

**Verified strings/tools:** mount at `~/Library/CloudStorage/WikiFS-WikiFS`;
`fileproviderctl dump` + `pluginkit -m` + `.ips` backtraces were the usable
diagnostics (sandboxed shell can't read the unified log).

## 2026-06-15 — Apple provisioning done up front (pre-Phase 2)

Per the user's call, knocked out the File Provider / App Group portal setup
*before* starting feature work, to de-risk Phase 2. Full detail + verified
strings in `plans/signing.md`.

- Apple Development cert installed: `Apple Development: Thomas Ptacek
  (7F2QE7P59D)` — already matches `DEV_IDENTITY` in the `Makefile`.
- This Mac registered as a dev device (`00006050-00190839016B401C`).
- App IDs created: `org.sockpuppet.WikiFS`, `org.sockpuppet.WikiFS.FileProvider`
  (both with App Groups capability).
- **App Group is `group.org.sockpuppet.wiki`** — NOT `…wikifs`. The `…wikifs`
  group got fouled up in the portal; adopted the working `…wiki` name rather
  than redo + regenerate profiles. Docs updated to match. DB will live at
  `~/Library/Group Containers/group.org.sockpuppet.wiki/WikiFS.sqlite`.
- Two macOS App Development profiles downloaded to `signing/` (gitignored),
  decoded + verified: team `KK7E9G89GW`, this device included, expire
  2027-06-15, authorize the exact entitlements recorded in `plans/signing.md`.
- Remaining signing work (embed profiles, inside-out codesign, `make install`
  loop) is wired in Phase 2.

## 2026-06-15 — Milestone 0: app skeleton on its legs

Bootstrapped the SwiftPM build environment from `Makefile.example` and got a
hello-world WikiFS SwiftUI app building, signing, and launching.

**Added**

- `Package.swift` — executable target `WikiFS`, macOS 14+, Swift tools 6.0.
- `Sources/WikiFS/WikiFSApp.swift` — `@main` App + `WindowGroup`.
- `Sources/WikiFS/ContentView.swift` — `NavigationSplitView` shell (foreshadows
  the sidebar/editor split).
- `Sources/WikiFS/WelcomeView.swift` — hello-world detail pane.
- `WikiFS/WikiFS.entitlements` — minimal (no sandbox yet).
- `scripts/make-icon.swift` — generates the app icon (white `books.vertical.fill`
  on a blue→indigo squircle) at all macOS sizes.
- `build.sh` — `swift build` → assemble `.app` → write `Info.plist` → codesign.
- `Makefile` — adapted from `Makefile.example` (Moves → WikiFS): app name,
  entitlements path, icon comment, notary profile `wikifs-notary`.
- `.gitignore` — `build/ .build/ dist/`.
- Docs: `PLAN.md` (index), `plans/build-environment.md` (build deep-dive).

**Verified**

- `make` builds `build/WikiFS.app` (debug, v0.0.0-dev). Dev cert not in this
  keychain → ad-hoc signature (expected; `make run` still works).
- `make check` compiles clean.
- Live gate (`SWIFTUI-RULES` §9.1): `make run` launches, window renders the
  native two-column layout with the books hero, process stays alive past the
  first display cycle. Screenshot confirmed the UI.

**Notes / decisions**

- Bundle id `org.sockpuppet.WikiFS`; min macOS 14 (matches `Makefile.example`).
- Ran the `swiftui-pro` skill on the sources (CLAUDE.md requirement). Only
  finding: one-type-per-file — extracted `WelcomeView` out of `ContentView.swift`.
- Toolchain present: Apple Swift 6.3.2, macOS 26.5 host.

**Next (Milestone 1 / setup)**

- Add a `WikiFSTests` target so `make test` does something.
- Begin SQLite store + page model (Milestone 0 deliverables in `plans/INITIAL.md`
  also include persistence; the build skeleton is done, the data layer is not).

## #163 — Drop routing for .webloc / remote URLs (2026-07-05)

**Problem:** dragging a `.webloc` file or an `http(s)` URL from a browser onto
the window hit the generic file-drop path (`addFiles`), ingesting the
`.webloc` plist's raw bytes instead of fetching the linked page.

**Fix**
- `WikiStoreModel.addDroppedURLs(_:fetcher:)` — partitions dropped URLs:
  `http(s)` URLs and `.webloc` shortcuts (resolved to their target) route through
  `addURL` (the "Add from URL" fetch + HTML→Markdown path); other `file://`
  URLs still ingest as raw bytes via `addFiles`. Supports multi-URL drops;
  an unresolvable `.webloc` is skipped (its bytes aren't a useful source).
  Named `add*` (not `ingest*`) since it only adds a source — agent ingestion
  (read source → generate pages) is a separate `AgentLauncher` phase.
- `WikiStoreModel.resolveWeblocURL(_:)` — reads the plist (XML or binary) off the
  main actor via `PropertyListSerialization`.
- `ContentView` `.dropDestination` now calls `store.addDroppedURLs(_:)`.

**Tests:** `WikiStoreModelDropRoutingTests` (5) — webloc→md, http url→md, local
txt→verbatim, mixed batch, unresolvable webloc skipped. All pass; existing
`WikiStoreModelAddURLTests` still green.

## #183 — "Show In List" sidebar reveal for pages & sources

A "Show in List" button (next to "Reveal in Finder") in `PageDetailView` and
`SourceDetailView` that surfaces the current page/source in the sidebar: opens
the sidebar if collapsed, switches to the right section, clears a search that
would hide the row, then scrolls to + selects it.

**Mechanism** — mirrors the existing `pendingScrollAnchor` "set once, consume
once" cross-view signal (issue #183 design):

- `WikiStoreModel` — `pendingSidebarReveal: WikiSelection?` +
  `pendingSidebarRevealVersion: Int` (monotonic, observed via `.onChange` so a
  repeat request re-fires even when the value is unchanged), with
  `requestSidebarReveal(_:)` (producer) and `consumePendingSidebarReveal()`
  (consumer, called by the list view after scroll+select).
- `ContentView` — `.onChange(of: pendingSidebarRevealVersion)` un-collapses the
  sidebar (`columnVisibility = .all`) when it's `.detailOnly`, so the target
  section's list is actually mounted.
- `SidebarView` — `.onChange(of: pendingSidebarRevealVersion)` sets
  `selectedSection` to `.pages`/`.sources` from the `WikiSelection` case and
  clears the section's search query (`searchQuery`/`sourceSearchQuery`) only
  when the target isn't in the filtered results (clearing resets
  `searchResults`/`sourceSearchResults` synchronously, so the full list is
  visible for row lookup).
- `PagesListViewController` / `SourcesListViewController` — new
  `revealAndSelect(id:)`: looks up the row, selects it (bypassing the
  `reconcileHighlight` multi-select guard — an explicit user action wins over a
  Cmd/Shift selection), and `scrollRowToVisible(_:)`. Driven from
  `updateNSViewController`, which reads `pendingSidebarReveal` (also registers
  the observation so the method re-runs on change), then consumes.
- `PageDetailView` / `SourceDetailView` — `Button("Show in List",
  systemImage: "sidebar.left")` calling `requestSidebarReveal(.page(id))` /
  `.source(id)`. Works without a mounted File Provider (unlike Reveal in Finder).

**Build/tests:** `swift build` clean; `swift test` — 1466 tests pass.

---

### Issue #229 — PDF source add by URL can fail "database is locked" (PR #247)

**Problem.** `DisplayNameResolver.resolve()` — which invokes PDFKit's
whole-file parse for PDFs — ran **inside** `SQLiteWikiStore.addSource`'s
`mutate()` closure, under the recursive lock and before the write transaction
opened. For a large PDF this parse can take seconds, delaying the `BEGIN` long
enough for another writer (File Provider, daemon, concurrent write) to hold the
DB write lock past the 5 s `busy_timeout`, surfacing as "database is locked".

**Fix.** Two-part:
1. **Out of the locked path:** `addSource` (and `addSnapshotImage`) now compute
   `ext` / `mime` / `displayName` **before** `mutate()` acquires the recursive
   lock. The locked body keeps only the dup-check SELECT + INSERT transaction.
   Added a `resolvedDisplayName: String??` parameter to `addSource` (and a
   `WikiStore` protocol-extension convenience overload since protocol methods
   can't have default args) so callers can skip the in-method parse entirely.
2. **Off the main actor:** `WikiStoreModel.preResolveDisplayName()` runs
   `DisplayNameResolver.resolve()` on a `Task.detached` for **PDFs only**
   (non-PDFs return `nil` → resolve inline). Wired into `addURLViaWebsite`,
   `addFiles`, and `ingestFromZotero`.

**Key files:** `SQLiteWikiStore.swift` (`addSource` / `addSnapshotImage`),
`WikiStore.swift` (protocol + extension), `WikiStoreModel.swift`
(`preResolveDisplayName`, `storeMaterialized`, three ingest paths).

**Build/tests:** `swift build` clean; `swift test` — 1930 tests pass
(1927 existing + 3 new for the `resolvedDisplayName` tri-state bypass).

## Remove edit locks — CAS replaces the mutex (2026-07-11)

**Problem:** Starting a second chat while Chat 1 was running silently failed —
the second chat didn't even display the user's question. The root cause was
`store.isAgentRunning`, a process-wide mutex that blocked `startChat`/
`continueChat` at the preflight guard (`shouldBlockEditStart`), failing before
the chat row was created or the message was shown.

**Why the mutex existed:** Pre-CAS, it prevented last-writer-wins data races —
the in-app autosave could clobber the agent's `wikictl` writes. It paused
autosave, disabled editing UI, and blocked new chat starts.

**Why it's safe to remove now:** W0 (PR #342) introduced page versions + CAS
save (`PageUpsert.upsert` with `expectedHeadVersionID`). `WikiStoreModel.save()`
catches `PageConflictError` and surfaces a "Page Was Updated" dialog. Concurrent
writes are safe — the store detects the version mismatch.

**Changes:**
- **WikiStoreModel:** Replaced `isAgentRunning: Bool` with `agentRunCount: Int`
  (ref-counted). `agentRunStarted()` increments + flushes drafts; `agentRunEnded()`
  decrements + reloads from store when count hits 0. Removed autosave pause guards
  in `scheduleAutosave()` and `systemPromptChanged()` — CAS handles it.
- **AgentOperationRunner:** `shouldBlockEditStart` now only checks
  `isIngestInProgress` (extraction is resource-intensive, not a data-race concern).
  Removed `takeEditLock` parameter entirely. Callbacks now
  `agentRunStarted()`/`agentRunEnded()` (session lifecycle, not mutex).
- **AgentLauncher:** Removed `onTurnBoundary` parameter and handler (was the
  per-turn edit lock toggle). Renamed `releaseEditLock()` → `releaseRunLifecycle()`.
  Kept `isGenerating` (independent — drives ChatView banner + send guard) and
  the generation gate (FIFO, N=1 by default).
- **UI views:** Removed all `.disabled(store.isAgentRunning)`, `.onChange(of:
  store.isAgentRunning)`, and "Agent updating wiki…" labels from PageDetailView,
  SourceDetailView, SystemPromptDetailView, PagesListView, WikiDetailView.
- **Tests:** Updated `Issue235IngestExtractionLockTests` (predicate now 1-arg)
  and `AgentGenerationSlotTests` (ref-count assertions).

**Build/tests:** `swift build` clean; fast tier — 2187 tests pass.

---

## Queue Engine — Phase 3: QueueEventLog JSONL Audit Trail (2026-07-14)

**Status:** Complete. All 16 tests pass (0.35s), 52 total across all 3 phases.

**What:** `QueueEventLog` actor writes every `QueueEvent` as a JSONL line to
daily-rotated `queue-YYYY-MM-DD.jsonl` files under `Logs/queue/` in the App
Group container, with bounded retention (30-day default). Daily rotation is
date-driven (no timer); prune-on-rotate. Progress events are high-volume and
skipped from the audit trail (consumed live by the UI via the event stream).

**Files:** `Sources/WikiFSEngine/QueueEventLog.swift` (QueueLogRecord +
QueueEventLog actor), `Tests/WikiFSTests/QueueEventLogTests.swift`.

**Build/tests:** `swift build` clean; 52 queue tests pass across 4 suites.

---

## Queue Engine — Phase 4: Extraction Through the Queue (2026-07-14)

**Status:** Complete. All 78 queue tests pass across 4 suites. Build clean.

**What:** All PDF extraction flows through the central extraction queue.
The `QueueExtractionWorkerFactory` + `QueueExtractionWorker` resolve the
extractor + PDF bytes via the `QueueExtractionProvider` protocol, check
`readiness()`, call `convert()` with progress reporting, and persist the
result. `waitForCompletion(of:)` lets callers (AgentOperationRunner,
SourceDetailView) await extraction results synchronously.

**QueueActivityTracker:** `@Observable @MainActor` class that observes
`QueueEngine.events` and replaces the launcher's extraction slot machinery
(`isExtracting`, `extractionLog`, `extractionPID`, `extractingSourceIDs`,
`extractTask`, `stopExtraction`). Injected via `.environment()`.

**Retired from AgentLauncher:** `awaitExtractionSlot`,
`releaseExtractionSlot`, `isExtractionSlotBusy`, `extractionWaiters`,
`ExtractionWaiter`, `extractPDF`, `stopExtraction`, `extractionLog`,
`isExtracting`, `extractionPID`, `extractingSourceIDs`, `extractTask`.
Local-pdf2md limit-1 is now enforced by the engine's capacity config, not
the slot.

**Files:** `Sources/WikiFSEngine/QueueExtractionProvider.swift`,
`Sources/WikiFSEngine/QueueExtractionWorker.swift`,
`Sources/WikiFS/QueueActivityTracker.swift`,
`Sources/WikiFS/WikiFSApp.swift` (wiring), view migrations across
SourceDetailView, SourcesContainerView, ContentView, WikiDetailView,
PdfExtractionView, ExtractionSettingsView, AgentActivitySidebar, SidebarView.

**Build/tests:** `swift build` clean; 78 queue tests pass across 4 suites.


---

## 2026-07-15 — Fix #439: flaky SIGTRAP (signal 5) in fast-tier CI

**Problem:** The fast-tier `swift` CI job intermittently crashed with
`Exited with unexpected signal code 5` (SIGTRAP) on `macos-latest`, killing
the parallel test process. Root cause: two suites instantiate
`WKWebView`/`NSWindow` off a host app — `SplitDiffSnapshotTests` (renders
`WKWebView`/`NSHostingController` to PNG snapshots) and
`QuoteHighlightWebViewTests` (bare `WKWebView` + JS eval). Headless macOS GH
Actions runners SIGTRAP on AppKit/WebKit under `swift test`'s concurrent
execution. A secondary `ChatStoreTests.chatMessagesSkipsRowWithCorruptEventJSON`
WAL-lock failure was a telemetry side-effect of the crash teardown, not a bug.

**Fix:** Moved both suites to the `swift-integration` (full-suite) job only —
they still gate merges there, but no longer run in the per-commit fast tier.
- Tagged both suite types with `@Suite(.tags(.integration))` (matches the
  established pattern in `TestTags.swift`; documents intent + enables IDE/
  xcodebuild filtering; future-proofs for SwiftPM `--skip` tag support).
- Appended `SplitDiffSnapshotTests|QuoteHighlightWebViewTests` to the
  fast-tier `SKIP` env regex in `.github/workflows/ci.yml` (the actual skip
  mechanism — SwiftPM `--skip` is name-regex, not tag-based).

**Scope note:** Three other suites (`SidebarSelectAllShortcutTests`,
`ComposerTextViewTests`, `AddressBarLayoutHostedTests`) instantiate `NSWindow`
only (no `WKWebView`) for layout/shortcut testing — lighter, not observed to
crash, left in the fast tier per issue #439's stated scope.

**Build:** `make build` clean; the two suites now skip in the fast tier and run
in `swift-integration`.

---

## 2026-07-17 — Reorganize WikiFSCore + WikiFS into subdirectories (#531)

**Problem:** `Sources/WikiFSCore/` (131 flat `.swift` files) and
`Sources/WikiFS/` (92 flat `.swift` files) were monolithic flat directories,
making navigation and understanding ownership difficult.

**Fix:** Pure `git mv` reorganization into logical subdirectories — zero new
SPM targets, zero import changes, zero access-control changes. SwiftPM
recursively includes all `.swift` under each target's `path:`, so subdirectories
are transparent to the build.

- **WikiFSCore** (131 files → 7 dirs): `Store/` (9), `Links/` (11), `Markdown/`
  (15), `Sources/` (14), `Integrations/` (25), `Search/` (6), `Core/` (51).
- **WikiFS** (92 files → 10 dirs): `Pages/` (4), `Sources/` (14), `Chats/` (4),
  `Bookmarks/` (5), `Settings/` (9), `Queue/` (11), `Window/` (18), `Reader/` (8),
  `Editor/` (17), `System/` (2).

**Test follow-up:** 4 source-scan tests had hardcoded `Sources/WikiFSCore/<File>.swift`
path strings to read source files (not compile symbols). Updated 7 path strings
across 4 test files to follow the moved files to their new subdirectories:
`FormatMaterializerTests`, `QueueStoreTests`, `StoreEmissionExhaustivenessTests`,
`SourceMaterializerTests`. No logic changed — only path strings.

**Build/Tests:** `swift build` clean (107s); fast test tier 2456 tests passed
(21s). PR #531.


---

## 2026-07-17/18 — Codebase hygiene sweep + module restructuring + ACP session efficiency + GRDB adoption

A comprehensive multi-day session touching 40+ PRs across five major efforts.

### Codebase hygiene sweep (15 PRs, #487–#511)

**Correctness fixes:**
- #487/#495: WikiDaemon `changeToken` bare `try?` → sentinel + `DebugLog` (stale FP projections)
- #492/#494: 11 silent-swallow `try?` on mutating/persistence writes → `do/catch + DebugLog` (#475 pattern)
- #493/#499: `-warnings-as-errors` on all 9 Swift targets (37 existing warnings fixed)

**Type safety:**
- #489/#498: Link-kind prefixes (`"page:"`/`"source:"`/`"chat:"`) → `ResourceKind.linkPrefix` typed accessor (7+ sites)
- #501/#505: Typed enum sweep — `SourceMarkdownOrigin` (5 cases), `WorkspaceStatus` rawValue decode, `LinkRole` enum
- #508/#513: Queue-layer typing — namespace shared `"running"` rawValue, typed `QueueLogRecord` fields
- #509/#515: Agent config typing — `HintKey`/`StageRoutingKey` enums, `legacyAgentName` constant
- #510/#521: MIME type namespace — `MimeType` with typed predicates replacing 13+ inline comparisons

**Dead code + dedup:**
- #488/#497: Deleted dead content-sniff forwarder shims (−81 lines)
- #502/#504: Cross-module dedup — `KeychainSecretStore`, `HTMLEntities.escapeHTML`, `SlugUtils.slugBase` (−122 lines)
- #507/#512: Naming cleanup — deleted dead `Resource` protocol, renamed `WikiLinkValidator.swift` → `WikiLinkFixer.swift`, `FileProviderSpike` → `FileProviderFacade`

**Performance:**
- #490/#496: Cache `makeLinkMaps()` per `ReadScope` + `getChat(id:)` direct lookup (N+1 → O(1))
- #491/#500: Remove ~28 redundant per-mutator `reload*()` calls (Phase E follow-up — 8 table scans → 4 per save)
- #503/#514: Perf wins batch — cache chat transcript render, hoist O(n²) array copy, batched markdown head query
- #511/#516: Shared `WikiLinkIndex` builder (unify link-map computation between WikiRenderContext and Projection)

**Build infrastructure:**
- #518/#529: `JSONSidecarConfig` protocol (collapse config load/save boilerplate)
- #519/#523: SQLite PRAGMA tuning — `synchronous=NORMAL`, `mmap_size`, `cache_size`, `temp_store=MEMORY`
- #520/#522: Release-mode Makefile targets (`make check-release`, `make test-fast-release`)
- #531/#533: Directory reorganization — 223 files into 17 subdirectories (zero build impact)

### Module restructuring (5 PRs, #532–#536)

- #534: Design doc — `plans/module-restructure.md`. Key finding: `SQLiteWikiStore` is a fan-in hub (not a leaf); `WikiStoreModel` is the composition root by design (3,096 lines, 75+ store calls, 68 views observe it). No circular deps exist.
- #535: Phase 1 — extract `WikiFSLinks` (11 files) + `WikiFSTypes` leaf (PageID, ULID, ResourceKind, EmbedTarget, ParsedLink, DebugLog). `@_exported import` re-export pattern. Discovered the bidirectional dependency (WikiFSCore ↔ WikiFSLinks) and solved it with the leaf split.
- #536: Phases 2+3 — extract `WikiFSMarkdown` (16 files, links JavaScriptCore) + `WikiFSSearch` (7 files, links NaturalLanguage). Moved `DebugLog` to `WikiFSTypes`.

Module graph after restructuring:
```
WikiFSTypes (leaf, Foundation only) ← WikiFSLinks ← WikiFSMarkdown
WikiFSTypes ← WikiFSSearch
WikiFSCore depends on all four, @_exported import re-exports them
```

### ACP session efficiency (6 PRs, #525/#537–#549)

Design doc `plans/acp-session-efficiency.md` (PR #537). Four implementation phases:

- #539 Phase 1: Warm subprocess across ingest phases — `startProcess()`/`createSession()`/`closeSession()` split. Eliminates 6 subprocess lifecycles per 5-source ingest (12–24s saved).
- #540 Phase 2: `session/resume` crash recovery — capability detection (`canResume`/`canLoadSession`), `resume()` implementation (`resumeSession` → `loadSession` → `nil` fallback chain), subprocess death detection via `kill(pid, 0)`.
- #542 Phase 3: `session/fork` for executors — `forkSession(from:cwd:)`, planner session kept alive through executor loop, graceful fallback to fresh `createSession()`.
- #544/#549 Phase 4: Usage/cost capture (`SessionUsage` struct, `translateNotification` returns usage), context monitoring (64%/80% thresholds), `parallelExecutors` via `withTaskGroup` with per-session event batching.
- #546: Usage UI spike — surface token counts + cost in Activity window (per-item) and menu bar (daily cumulative).
- #547: Named constants for ACPBackend + AgentLauncher (timeouts, env keys, filenames, delimiters)
- #548: Strip 77 `TEMP DEBUG` comments + fix `QueueStore.loadItemEvents` bare `try?`
- #551: Remove idle stall detection, shift watchdog to observability-only

### GRDB adoption (4 PRs, #530/#538/#543/#545/#550/#557)

Design doc `plans/grdb-adoption.md` (PR #538). Key findings: `mutate()` seam is portable (15-line wrapper), `ValueObservation` complements (not replaces) `WikiEventBus`, `QueueStore` is the ideal pilot.

- #543: QueueStore pilot — full GRDB rewrite (replaces raw `sqlite3_*` with `DatabaseQueue` + `DatabaseMigrator` + `FetchableRecord`). Proves GRDB works in the project.
- #545: GRDBWikiStore skeleton — 1,662 lines, ~50 of 88 methods, `mutate()` seam, `DatabaseQueue` with PRAGMAs, sqlite-vec registration.
- #550: All 50 remaining stubs implemented — 3,024 lines added. All 88 `WikiStore` protocol methods now have GRDB implementations. Zero stubs.
- #557: 37-version migration ladder — `PRAGMA user_version` + same switch ladder translated to GRDB. Fresh DB → `createFreshSchema` + stamp to v37. Existing DB → run unapplied migrations. `writeWithoutTransaction` for independent commit per step. FTS5 corruption heal-and-retry.

**Path to removing SQLiteWikiStore:**
1. ✅ All 88 methods implemented
2. ✅ 37-version migration ladder
3. ⏳ Parity tests (swap at injection point, run 2,400+ tests against GRDBWikiStore)
4. ⏳ Swap injection point, deprecate SQLiteWikiStore
5. ⏳ Delete SQLiteWikiStore + SQLiteStatement + WikiReadPool

### Design research docs (3 PRs)

- #526/#541: Tantivy search sidecar — `plans/tantivy-search-sidecar.md`. 4-phase adoption: build spike → shadow index → cutover → retire FTS5+sqlite-vec. One unified index with facets. Embeddings stay in SQLite.
- #530/#538: GRDB adoption — `plans/grdb-adoption.md`. Feature mapping, `mutate()` seam design, observation migration, custom extension registration, migration framework evaluation.
- #532/#534: Module restructuring — `plans/module-restructure.md`. Phased extraction plan, circular dependency analysis, `WikiStoreModel` decomposition assessment.

### Other improvements

- #527: Filed — off-peak ingest scheduling (item-level `scheduledFor` + queue-level time windows)
- #528: Filed — budget/quota-aware ingestion (data seam ready from ACP Phase 4 + #546)
- #524: Filed — zstd BLOB compression via C extension (mirror CSqliteVec pattern)
- #552: Wire Settings window via OpenWindowBridge
- #555: Enrich activity window with run metadata and timing
- #556: Format broken links with namespace prefixes in agent lint prompt

## Tantivy Phase 2 — Cutover (feature/tantivy-search-cutover)

**Date:** 2026-07-18

Phase 2 makes Tantivy the **primary BM25 leg** of the hybrid search (BM25 +
sqlite-vec cosine + `RankFusion.rrf`), with FTS5 kept as fallback. Phase 1's
shadow index (#574) is already merged; this wires it into the real search path.

**Design: Option B — `bm25Leg` injection seam.** Rather than expose the store's
private FTS/Semantic leg methods and move RRF into the model (6 new protocol
methods + duplicate fusion logic), the proven in-store RRF path is kept
unchanged. The 3 `WikiStore.searchSimilar*` methods gain an optional
`bm25Leg:[Summary]?` parameter. When non-nil/non-empty, the store uses it
INSTEAD of running FTS5, then fuses with the semantic cosine leg via RRF
exactly as today. When nil/empty, it runs FTS5 (legacy path).

**Changes:**
- `TantivyShadowSearchResult.ulid` — computed property deriving the raw ULID
  from the composite `"<kind>:<ULID>"` documentID, enabling catalog resolution.
- `WikiStore` protocol: `searchSimilar`/`searchSimilarSources`/
  `searchSimilarChats` gain `bm25Leg` (no default — protocol requirements can't
  carry defaults); a `public` extension provides the 2-arg legacy entry points
  (zero caller breakage for wikictl, tests, and the model's sync wrappers).
- `GRDBWikiStore` + `SQLiteWikiStore`: when `bm25Leg` is supplied, use it as
  the FTS rows; otherwise run FTS5. Semantic leg + `RankFusion.rrf` unchanged.
- `WikiStoreModel`: `tantivySearch` property (injected post-init by
  `WikiSession`, same lifecycle as `readPool`). The 3 debounced search methods
  (pages/sources/chats) call `resolveTantivyLeg(query:kind:limit:catalog:)`,
  which queries the Tantivy actor, maps hits → full typed summaries via the
  cached catalog ([summaries]/[sources]/[chats]), and preserves Tantivy's
  best-first rank. `logShadowComparison` logs BM25/fused overlap + latency.
- `WikiSession.searchTantivy(query:kinds:limit:)` — public accessor for raw
  Tantivy hits (returns nil when the index is unavailable, not an empty list,
  so callers can distinguish "fall back to FTS5" from "no matches").

**FTS5 is fully intact** — Phase 3 (retire FTS5 + sqlite-vec) is the next step.

**Tests:** `TantivyBM25LegCutoverTests` (6 tests, fast tier) — verifies the leg
is used when supplied (membership + rank order preserved), nil/empty fall back
to FTS5, and the default-arg (2-arg) path is the legacy behavior. Full fast
tier (2558 tests) passes.

**Build:** `make version prompts` + `swift build` clean (no warnings under
`-warnings-as-errors`).

## wikictl CLI — `page` subcommand namespace (feature/wikictl-page-cmd)

**Date:** 2026-07-19

The `wikictl` CLI historically had a mix of flat page commands (`.list`,
`.get`, `.upsert`, `.delete`, `.search`, `.pageHistory`, `.pageRevert`,
`.sourceEditMarkdown`, `.sourceRename`, `.sourceSetActive`,
`.sourceRefresh`) on `ArgumentParser.Command` alongside already-namespaced
cases (`.source(SourceCommand.Action)`, `.chat(...)`, `.bookmark(...)`,
`.workspace(...)`, `.admin(...)`). This refactor moves every page/source
flat case under its existing namespacing enum, mirroring the
`SourceCommand.Action` pattern.

**Changes:**

- **`PageCommand.Action`** (the executable form):
  - Renamed `upsert` → `add`. The body is now `BodySource` (`.inline(String)`
    or `.file(path)`), so the action carries the same I/O-deferral info the
    parser used to. `PageCommand.run(.add(...))` resolves the body source
    just before the write.
  - `history`, `revert` already used the renamed cases (no change there).
- **`SourceCommand.Action.editMarkdown`** — `content: String` →
  `content: BodySource`, mirroring `PageCommand.Action.add`. Resolution
  happens inside `SourceCommand.run`.
- **`ArgumentParser.Command`** — removed the 11 flat page/source cases.
  Added `case page(PageCommand.Action)` (the single wrapping form). The
  parser routes `wikictl page …` and `wikictl source …` two-level via
  `parsePageCommand` / `parseSourceCommand`, both of which now produce the
  wrapping `.page(...)` / `.source(...)` form directly. Removed
  `parseSearchCommand` and `parseSourceEditMarkdown` helpers (their
  logic is inlined into the parent parser). Updated `applyEnv` so
  `WIKI_WORKSPACE` / `WIKI_AUTHOR` inject via pattern-matching
  `.page(.get(...))` / `.page(.add(...))`.
- **CLI grammar change** — `wikictl search` (top-level) is now
  `wikictl page search` (it was an implicit page command, now explicitly
  namespaced). `wikictl page upsert` → `wikictl page add` (the rename).
  All other page subcommands unchanged at the CLI grammar level
  (`page list/get/delete/history/revert`).
- **`main.swift`** — `execute()` is now 11 cases (down from 22). The flat
  `.list/.get/.delete/.upsert/.search/.pageHistory/.pageRevert` and
  `.sourceEditMarkdown/.sourceRename/.sourceSetActive/.sourceRefresh`
  dispatches collapse into `case .page(let action)` and `case .source(...)`.
  Async refresh still routed via the `RefreshResultBox` semaphore bridge,
  now triggered by `if case .refresh(let selector) = action` inside the
  `.source` branch.
- **`BodySource`** (`Sources/WikiCtlCore/BodySource.swift`) — new
  `public enum BodySource: Equatable, Sendable` with `.inline(String)`
  and `.file(String)` (path or `-` stdin). `resolveBodySource(...)` and
  `readBodyFile(...)` are public so `wikictl/main.swift` reuses the same
  stdin/file resolution for `indexSet` (the one flat case that stays —
  `logAppend`/`indexSet` are already two-level via `log append` /
  `index set` subcommands and were left as-is).
- **Docs/prompts** — `page upsert` → `page add` and `wikictl search` →
  `wikictl page search` across `prompts/*.md` (regenerated
  `GeneratedPrompts.swift` via `make prompts`), in-source doc comments,
  and test assertions that pin prompt text. Historical bash traces in
  `PROGRESS.md` left intact (they describe what was run at the time).

**Test updates:** `WikiCtlCommandTests`, `AgentCASTests`,
`IngestIsolationTests`, `MermaidValidatorTests` updated for the
`.page(.add(...))` / `BodySource.inline(...)` shapes; parser tests for
search now invoke `page search` instead of top-level `search`. All other
test assertions are prompt-text replacements only.

**Result:** 258 suites / 3031 tests pass. `swift build` clean.

**Build:** `make version prompts && swift build && swift test`.

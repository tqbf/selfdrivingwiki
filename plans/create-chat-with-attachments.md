# Create chat with attachments

## 1. Goal

The Pages and Sources sidebar lists get one new context-menu item. It creates
a new durable chat, attaches the selected pages (or sources) as composer
attachment chips, and opens that chat as the active tab with keyboard focus
in the composer. The user can type at once.

Out of scope: no menu change on the Chats or Bookmarks lists. No new
persistence. No daemon or schema changes.

## 2. Implementation Summary

### 2.1 Menu items

| List | Single selection | Batch selection |
| --- | --- | --- |
| Pages | `New Chat with Page` | `New Chat with \(count) Pages` |
| Sources | `New Chat with Source` | `New Chat with \(count) Sources` |

- Style: Title Case, no articles, count-prefixed batch form. This matches
  the existing items ("Open", "Open 3 Pages", "Lint Page",
  "Add 2 Pages to Bookmarks…") at `PagesListView.swift:321-390` and
  `SourcesListView.swift:426-525`.
- Icon: `plus.bubble` (the welcome screen's "Add Chat" glyph,
  `WikiDetailView.swift:166`). Every item on these menus carries a system
  image (`PagesListView.swift:402-409`).
- No ellipsis. The item acts at once, unlike "Add to Bookmarks…", which
  opens a picker.
- No keyboard shortcut, same as every other item on these menus.
- Placement: immediately before "Add to Bookmarks…" in both menus
  (`PagesListView.swift:345-347`, `SourcesListView.swift:452-454`). The
  item joins the open-and-act-on-this-selection cluster.

### 2.2 Typed attachment targets (new model type)

`SidebarDragPayload` is pasteboard transport. It stays untouched; its
`Codable` JSON is a compatibility contract
(`Sources/WikiFSCore/Core/SidebarDragPayload.swift:15-41`). Model state does
not carry it.

New enum in WikiFSCore
(`Sources/WikiFSCore/Core/ChatAttachmentTarget.swift`, new file):

```swift
public enum ChatAttachmentTarget: Hashable, Sendable {
    case page(PageID)
    case source(SourceID)
}
```

The case tag keeps the `PageID` and `SourceID` namespaces apart, per the
repo modeling rule that mixed targets use tagged enums. `PageID`
(`Sources/WikiFSTypes/PageID.swift:4`), `SourceID`
(`Sources/WikiFSTypes/SourceID.swift:7`), and `ChatID`
(`Sources/WikiFSTypes/ChatID.swift:7`) are existing `RawRepresentable`
wrappers. Small factory helpers `ChatAttachmentTarget.pages(_:)` and
`.sources(_:)` map ordered id arrays once, at this type.

### 2.3 One chat-scoped pending request (new model state)

The old sketch (a bare pending `[SidebarDragPayload]` array) had no
destination, so consumption could not prove it applied to the right chat.
Replacement, in `Sources/WikiFSCore/Store/WikiStoreModel.swift`:

```swift
public struct PendingChatAttachmentRequest: Equatable, Sendable {
    public let chatID: ChatID
    public let targets: [ChatAttachmentTarget]
}

public private(set) var pendingChatAttachmentRequest: PendingChatAttachmentRequest?
```

Lifecycle rules:

- Install: `beginNewChat(prefill: String? = nil, attachments:
  [ChatAttachmentTarget] = [])` writes the chat row first, then installs
  `PendingChatAttachmentRequest(chatID: chat.id, targets: attachments)`.
  The install happens only after the store write succeeds, next to the
  `prefill` install (`WikiStoreModel.swift:334-357`, rule documented at
  `:320-322`). A failed creation installs nothing.
- Replace: every successful `beginNewChat` unconditionally overwrites the
  request, including a second creation with empty attachments. An
  outstanding request for a prior chat never survives a newer creation, and
  an empty-targets request cannot strand an older one.
- Consume: `consumePendingChatAttachmentRequest(for chatID: ChatID?) ->
  [ChatAttachmentTarget]` returns the targets and clears the request in one
  step, only when `chatID` is non-nil and equals `request.chatID`. Any nil
  or wrong id gets `[]` and leaves the request alone. The function is
  independent of `pendingComposerFocusChatID`
  (`WikiStoreModel.swift:279-287,365-368`), which the composer clears on
  its own schedule.

### 2.4 App-target adapter (the one String boundary)

`ChatAttachment` (`Sources/WikiFS/Chats/ChatDetailView.swift:1052-1098`) is
internal to the WikiFS app module. It gains one typed initializer in the
same file:

```swift
@MainActor
init(target: ChatAttachmentTarget, store: WikiStoreModel)
```

The initializer switches on the target, builds a `SidebarDragPayload` for
the name lookup, and reuses `resolveAttachmentName(for:)`
(`WikiStoreModel.swift:948-958`). The `PageID`/`SourceID` to raw-String
conversion happens exactly here, once. Pasteboard JSON is untouched.

Target placement consequences for tests: the enum-level distinctness test
runs in `WikiFSTests`, which depends only on WikiFSCore
(`Package.swift:592-596`). The chip-level adapter test needs `@testable
import WikiFS`, so it runs in `WikiFSAppTests`, which depends on the WikiFS
target (`Package.swift:640-655`) under the opt-in env var (section 5).

### 2.5 Consumption path (no hydration dependency)

`ChatDetailView` consumes in `.onAppear`, synchronously on the main actor.
It does NOT consume inside the hydration task, whose
`await coordinator.rehydrate` (`ChatDetailView.swift:237`, task body
`:227-248`) can be cancelled by navigation away or superseded by a repeat
task. `.onAppear` runs at mount, before any await can matter, and cannot be
cancelled mid-flight. The consume is atomic in the model, so a re-appear
after a tab switch is a no-op.

Guard rule: any future path that applies targets from a Task must check
`Task.isCancelled` before it touches the model state or view state. The
planned design has no such path.

Scope note: composer chips are view state. A chip added by drop today does
not survive a tab switch (`ChatDetailView.swift:27`, cleared on send at
`:796` and `:820`). Pre-attached chips behave the same. The request itself
can never be stranded or misapplied, because the own chat's first mount
consumes it exactly once, synchronously.

### 2.6 Testable composer attachment seam

SwiftUI chip text is not reliably inspectable through the AppKit tree in the
CLI host. The seam has three parts.

**The model** — new `@Observable` type
(`Sources/WikiFS/Chats/ChatComposerAttachmentModel.swift`, new file):

- `private(set) var attachments: [ChatAttachment]`
- `add(_:)` dedupes by chip id and keeps order (the rule of the current
  `addAttachment`, `ChatDetailView.swift:755-758`)
- `replace(with:)` swaps the whole array in place. The queued recall and
  edit restores (`ChatDetailView.swift:833`, `:846`) replace the array
  today; append is not equivalent, so the restores route through this
  method.
- `remove(_:)`, `clear()`
- `applyTargets(_:store:)` maps `[ChatAttachmentTarget]` through the
  typed initializer and adds each result

The outgoing payload build and the composer snapshot reads keep reading the
model's array; the send (`ChatDetailView.swift:790-794`), queue
(`:812-818`), and `currentComposerSnapshot()` paths do not change shape.

**The props spy** — `ChatDetailView` gains an internal, default-nil
closure:

```swift
var onComposerPanePropsBuilt: ((ChatComposerPaneProps) -> Void)?
```

`makeComposerPaneProps()` (`ChatDetailView.swift:522-559`) invokes it once
per build with the props it is about to hand `ChatComposerPaneView`. This
captures the attachments at the real rendering seam — the exact value the
pane receives — not a parallel projection of the model. The internal
initializer (which also injects the model) sets it from tests.

**The props type stays unchanged.** `ChatComposerPaneProps.attachments`
(`ChatComposerPaneView.swift:7,16`) keeps its type; `makeComposerPaneProps`
reads `attachmentModel.attachments` inside body, so observation still
drives rebuilds. `ChatComposerPaneView` renders the same props field it
already renders (`:58-60`).

### 2.7 Chat creation and window semantics (recorded decision)

The action reuses the durable creation path
(`WikiStoreModel.beginNewChat`, `WikiStoreModel.swift:334-357`; omnibox
"Ask" precedent at `AddressBarView.swift:250-263`). It opens the new chat
as the active tab of the current wiki window. It does not open a separate
window.

Rationale and mechanics: the app has no separate composer windows. The chat
composer lives in the main window's detail area, and the Add Chat workflow
(`WikiDetailView.swift:334-336`) uses the same path. The context menu fires
inside the main wiki window, so that window is already key.
`openTab(.chat(chat.id))` (`WikiStoreModel.swift:1257-1270`) calls
`setActiveTab` (`:1193-1198`), which sets `activeTabID` and mirrors
`selection`. The tab bar and the detail routing observe these `@Observable`
properties, and the SwiftUI update makes the new tab visually active. When
invoked from a non-key window, the tab still becomes active in that
window's model; the window is not raised by this action. The legacy
`.newChat` draft surface stays untouched
(`ChatSessionKey.swift:17-23`, `WikiDetailView.swift:181-190`).

### 2.8 Current-state references (verified)

- Pages list: `PagesContainerView`
  (`Sources/WikiFS/Pages/PagesContainerView.swift:10`) hosts
  `PagesListView` (`:84-86`) and owns the callbacks (`:232-301`).
  `PagesListCallbacks` at `PagesListView.swift:65-86`; menu payload type at
  `:90-93`; multi-select on at `:127`; `menuForRow` at `:304-394`;
  effective-selection rule at `:310-314`; action-handler pattern at
  `:411-413`; table menu hook at `:463-468`.
- Sources list: `SourcesContainerView`
  (`Sources/WikiFS/Sources/SourcesContainerView.swift:11`) shows primary
  sources only (`:108-113`), hosts `SourcesListView` (`:120-126`), owns the
  callbacks (`:291-364`). `SourcesListCallbacks` at
  `SourcesListView.swift:71-103`; payload type at `:105-108`; multi-select
  on at `:272`; `menuForRow` at `:411-528`; effective-selection rule at
  `:416-421`; item helper at `:568-575`; delete-handler pattern at
  `:640-642`; table menu hook at `:653-658`.
- Enablement inputs: the menu only builds on a right-clicked row
  (`PagesListView.swift:304-305`), so the effective selection is never
  empty. Pages and sources are separate lists, so a selection is never
  mixed. `AddContextPicker` attaches every page, primary source, and chat
  with no eligibility gate
  (`Sources/WikiFS/Editor/AddContextPicker.swift:84-96`), so every visible
  row is attachable. The item is always enabled when the menu is open.
- Send path: chips become `[[page:Name]]` / `[[source:Name]]` reference
  text inlined into the wire message (`ChatDetailView.swift:871-872`). The
  composer also accepts chips by drop
  (`ChatComposerPaneView.swift:99-105`) and by the toolbar picker
  (`:111-113`).

## 3. Implementation Plan

Ordered. Each step compiles except where a step depends on an earlier one
(marked).

1. `Sources/WikiFSCore/Core/ChatAttachmentTarget.swift` (new file): add the
   `ChatAttachmentTarget` enum and the `pages(_:)` / `sources(_:)` helpers.
2. `Sources/WikiFSCore/Store/WikiStoreModel.swift`: add
   `PendingChatAttachmentRequest` and `pendingChatAttachmentRequest`;
   extend `beginNewChat` to
   `beginNewChat(prefill: String? = nil, attachments: [ChatAttachmentTarget] = [])`
   with the install-after-persist and replace-always rules (2.3); add
   `consumePendingChatAttachmentRequest(for:)`.
3. `Sources/WikiFS/Chats/ChatComposerAttachmentModel.swift` (new file): add
   the `@Observable` attachment model with `add`, `replace(with:)`,
   `remove`, `clear`, and `applyTargets` (2.6).
4. `Sources/WikiFS/Chats/ChatDetailView.swift`: add the typed
   `ChatAttachment.init(target:store:)` adapter (2.4). Replace the
   `@State attachments` array (`:27`) with the injected
   `ChatComposerAttachmentModel`; route `addAttachment` /
   `removeAttachment` (`:755-763`) through `add`/`remove`, the queued
   recall and edit restores (`:833`, `:846`) through `replace(with:)`, the
   send and queue clears (`:796`, `:820`) through `clear()`, and the props
   build (`:544`) through the model. Add the internal
   `onComposerPanePropsBuilt` spy, invoked at the end of
   `makeComposerPaneProps()` (2.6). Consume the request in `.onAppear`
   with `applyTargets` (2.5).
5. `Tests/WikiFSAppTests/AutocompleteHostedTestGate.swift`: replace the
   acquire/waiter lifecycle with a bounded, cancellation-aware one (step 6
   depends on this for the new hosted suites; see 3.1).
6. `Sources/WikiFS/Pages/PagesListView.swift`: add
   `var onNewChat: ([PageID]) -> Void` to `PagesListCallbacks`; add the
   menu item in `menuForRow` before "Add to Bookmarks…" (`:345`), title
   per 2.1, icon `plus.bubble`; add the `@objc` handler forwarding
   `p.effectiveIDs` in row order (pattern: `lintAction`). Set
   `item.accessibilityIdentifier = systemImage` in the shared
   `menuItem` helper (`:402-409`) so tests can assert the icon.
7. `Sources/WikiFS/Pages/PagesContainerView.swift`: wire the callback
   (`:232-301`): `store.beginNewChat(attachments:
   ChatAttachmentTarget.pages(ids))`.
8. `Sources/WikiFS/Sources/SourcesListView.swift`: the same three edits
   (`SourcesListCallbacks`, menu item before `:452`, `@objc` handler
   forwarding `p.effective.map(\.id)` in row order, icon identifier in the
   helper at `:568-575`).
9. `Sources/WikiFS/Sources/SourcesContainerView.swift`: wire the callback
   (`:291-364`) with `ChatAttachmentTarget.sources(ids)`.
10. Tests, per section 5.

### 3.1 Hosted-test gate infrastructure

`HostedAppKitTestGate` (typealias `AutocompleteHostedTestGate`,
`Tests/WikiFSAppTests/AutocompleteHostedTestGate.swift:12-65`) parks
contended acquirers on a bare `withCheckedContinuation` (`:18-28`). A suite
`.timeLimit` cancels the test task but cannot resume that continuation. The
waiter then leaks, and the gate can wedge.

This step is a deliberate replacement of the acquire/waiter lifecycle, not
a compatibility wrapper over the old unbounded wait: `acquire` becomes
`func acquire(timeout: Duration = .seconds(30)) async throws -> Lease`,
and EVERY existing call site migrates to the throwing bounded API in the
same change (mechanical: `try await` plus the suites already throw). No
deprecated unbounded entry point remains.

- Grant path unchanged when uncontended.
- A contended waiter carries an id and registers
  `withTaskCancellationHandler`; on task cancellation the actor removes
  that waiter from the queue and resumes it by throwing
  `CancellationError`. No abandoned continuation stays queued, and no
  resumed-but-dead task takes the lease slot.
- A deadline (raced against `Task.sleep(for:)` in a task group, or an
  actor-scheduled timeout resume) makes the wait throw a typed
  `GateTimeoutError`.

The opt-in mechanism this relies on is upstream repo policy, not a choice
this feature makes: `WikiFSAppTests` is excluded from the default test
graph because its suites can wedge SwiftPM's shared test helper when run
alongside daemon tests (`Package.swift:636-639,708`; flag read at `:17-18`;
#754, #949). `make test` (`Makefile:288,304-306`) never sets the flag, so
the mandatory opt-in commands in section 5 are the only way these suites
compile and run.

DurableNewChatHostedTests shows the hosting pattern this builds on
(fixture at `:57`, `mount` at `:78`, bounded `waitUntil` at `:88`,
acquire at `:116`, suite traits at `:15`).
`SidebarSelectAllShortcutTests.swift:36-45` and
`PageContextMenuHostedTests.swift:24,34,56` show the window-hosting and
store-fixture patterns for menu tests.

## 4. Acceptance Criteria

- **AC.1 — Menu items.** Both lists show the item with the exact titles of
  2.1 (single and batch forms), the `plus.bubble` icon, an enabled state,
  and placement immediately before "Add to Bookmarks…" in menu order.
- **AC.2 — Effective selection.** Right-click inside the selection acts on
  the whole selection; right-click outside acts on the clicked row only.
  The forwarded ids are typed (`[PageID]` / `[SourceID]`) and in row order.
- **AC.3 — Persist-first.** A successful creation persists one chat row,
  opens the `.chat(id)` tab, and installs the request for that chat. A
  failed creation shows the store error, opens no tab, creates no row, and
  installs no request.
- **AC.4 — Scoped attachment application.** The request applies only to its
  own chat. Consumption is atomic and one-shot: a nil or wrong chat id
  gets nothing and strands nothing. Consumption works after the composer
  focus marker has been cleared. A second creation replaces the request,
  including with empty attachments. Duplicate targets produce one chip.
  A page and a source with identical raw id text stay distinct targets
  (enum level) and distinct chips (adapter level). Queued recall and edit
  restore by replacement, not append.
- **AC.5 — Immediate typing focus.** After the action, the new chat's
  composer holds keyboard focus with no user click (the existing one-shot
  focus chain, `ChatDetailView.swift:536-543`).
- **AC.6 — Tab, not a separate window.** The new chat opens as the active
  tab of the current wiki window: the host window identity is unchanged,
  the window's model has the new chat as its active tab, and no additional
  product window exists after the action. Per the recorded decision in
  2.7.

## 5. Test Strategy

Swift Testing. Two tiers, and BOTH are mandatory gates:

- The default graph (`make build`, `make test`) covers the headless
  suites. It does NOT compile or run `WikiFSAppTests`
  (`Package.swift:17-18,708`; `Makefile:288,304-306`).
- The opt-in macOS commands below compile and run the app-target suites.
  `WikiFSAppTests` is upstream-excluded from the default graph because its
  suites can wedge SwiftPM's shared test helper when run alongside daemon
  tests (`Package.swift:636-639`, #754, #949). The constraint is upstream,
  not optional, so the executor must run the opt-in commands explicitly.

Command list (all from the repo root):

```
# Default gates. WikiFSAppTests is NOT in this graph.
make build
make test

# MANDATORY macOS opt-in runs for this feature's new suites.
# Each --filter MUST report a nonzero executed test count.
WIKIFS_APP_TESTS=1 swift test --filter HostedAppKitTestGateTests
WIKIFS_APP_TESTS=1 swift test --filter SidebarNewChatMenuHostedTests
WIKIFS_APP_TESTS=1 swift test --filter ChatAttachmentHostedScenarioTests
WIKIFS_APP_TESTS=1 swift test --filter ChatComposerAttachmentModelTests

# Opt-in app-test regression for the migrated gate callers (run before any PR).
WIKIFS_APP_TESTS=1 make test
```

Why `WIKIFS_APP_TESTS=1 make test` works: make exports its environment,
including the command-line prefix, to the recipe shell. The `test` recipe
(`Makefile:304-306`) runs `swift test --parallel …` in that shell, and
`Package.swift:18` reads `ProcessInfo.processInfo.environment`. The same
prefix also works on the other make test targets (`test-fast`,
`test-watchdog`). Prescribe exactly the commands above; do not invent an
`make test-app` target — none exists (`Makefile:313-324` shows the actual
test targets).

Evidence rule: the `progress/` entry must record the command, exit status,
and result for each gate. For `make build`, record the build result; a
test count is not applicable. For every test command — `make test`, each
opt-in filter, and `WIKIFS_APP_TESTS=1 make test` — record the executed
test count and pass/fail from the `swift test` output (the "Test run with
N tests passed" summary). A filter that matches zero tests is a failure —
a typo'd suite name must not count as a green gate.

**Test infrastructure first (opt-in tier):**

- `HostedAppKitTestGateTests` (new, `Tests/WikiFSAppTests/`): grant when
  uncontended; queued grant after a release; a contended acquire throws
  `GateTimeoutError` at the deadline and the gate stays usable; a cancelled
  waiter is removed safely, throws `CancellationError`, and the gate stays
  usable with no lost slot. Covers the 3.1 step.

**AC.1 and AC.2 — menu behavior (mandatory, opt-in tier):**

- `SidebarNewChatMenuHostedTests` (new, `Tests/WikiFSAppTests/`). One
  struct per list. Fixture: a real `GRDBWikiStore` on a temp file
  (`PageContextMenuHostedTests.swift:34` pattern), three rows, the view
  controller hosted in an `NSWindow` under the gate, `reloadData(from:)`,
  `selectRowIndexes`. Suite traits `@Suite(.serialized,
  .timeLimit(.minutes(2)))` (the durable-fixture pattern,
  `DurableNewChatHostedTests.swift:15`).
- `pagesMenuOffersSingularItem` / `sourcesMenuOffersSingularItem`: one row
  selected. Exact title, `accessibilityIdentifier == "plus.bubble"`,
  `isEnabled == true`, and the item's index is directly before the
  "Add to Bookmarks…" item's index.
- `pagesMenuOffersBatchTitle` / `sourcesMenuOffersBatchTitle`: two rows
  selected inside the selection. Exact batch title with the count.
- `pagesMenuActsOnWholeSelectionWhenClickedInside` /
  `sourcesMenu...`: rows 0 and 1 selected, right-click row 0. Invoking the
  item (`item.target?.perform(item.action, with: item)`) forwards
  `[id0, id1]` in row order to the creation callback.
- `pagesMenuActsOnClickedRowOnlyWhenClickedOutside` / `sourcesMenu...`:
  rows 0 and 1 selected, right-click row 2. Forwards `[id2]` only.
- The invoke tests wire the callbacks to the real `WikiStoreModel` with the
  same closures the containers install (steps 7 and 9), then assert the
  store projection: one new chat tab, active selection `.chat(id)`, and
  `pendingChatAttachmentRequest` carrying the typed targets in order. This
  is the operator-visible creation outcome.

**AC.3 — persist-first (mandatory, default tier):**

- Extend `Tests/WikiFSTests/NewChatSidebarProjectionTests.swift` (headless
  fixtures at `:22-39`; runs in the default `make test` graph):
  - `beginNewChatWithAttachmentsPersistsRowAndInstallsRequest`: one row,
    the tab, and the request with the input targets in order (mirrors
    `:103-112`).
  - `failedBeginNewChatWithAttachmentsLeavesNoRequestAndOpensNoTab`: via
    the read-only store fixture (`:33-39`, mirrors `:72-101`): store error
    shown, no tab, no row, `pendingChatAttachmentRequest == nil`.

**AC.4 — scoped consumption (mandatory, default tier):**

- Same headless suite, mirroring `:130-149` and `:151-162`:
  - `attachmentRequestConsumedByItsOwnChatOnly`: nil chat id returns `[]`
    and keeps the request; a wrong id returns `[]` and keeps it; the
    matching id returns the targets once; a second consume returns `[]`.
  - `attachmentConsumeWorksAfterComposerFocusCleared`: call
    `consumeComposerFocusRequest(for: chatID)` first (the composer cleared
    the marker), then the attachment consume still returns the targets for
    that chat. The two hand-offs do not proxy each other.
  - `secondBeginNewChatReplacesAttachmentRequest`: creation with targets,
    then a second creation with different targets. The request carries the
    second chat and targets only.
  - `secondBeginNewChatWithEmptyAttachmentsReplacesRequest`: the empty
    creation replaces a still-outstanding request. Consuming for the first
    chat returns `[]`; nothing strands and nothing inherits.
- `ChatAttachmentTargetTests` (new, `Tests/WikiFSTests/`, default tier):
  - `pageAndSourceWithIdenticalRawTextStayDistinct`: `.page(PageID("x"))`
    differs from `.source(SourceID("x"))` at the enum level. WikiFSTests
    has no WikiFS dependency (`Package.swift:592-596`), so this test stops
    at the enum; the chip level runs in the app target below.

**AC.4 — adapter, model, replacement (mandatory, opt-in tier):**

- `ChatComposerAttachmentModelTests` (new, `Tests/WikiFSAppTests/`,
  `@testable import WikiFS`):
  - `identicalRawTextPageAndSourceProduceDistinctChips`: the two
    `ChatAttachment` values built through the typed initializer from
    `.page(PageID("x"))` and `.source(SourceID("x"))` differ as chips
    (`kind:itemID` ids differ).
  - `replaceReplacesRatherThanAppends`: seed two chips, `replace(with:)`
    one chip. The model holds exactly the one chip (count and content),
    not three.
  - `applyTargetsAddsInOrderAndDedupes`: ordered targets land in order; a
    repeated target adds nothing.
- The queued-restore migration is covered at the unit level by
  `replaceReplacesRatherThanAppends` plus the existing queued-message
  behavior tests; the restore call sites (`ChatDetailView.swift:833`,
  `:846`) route through `replace(with:)` per step 4.

**AC.4, AC.5, and the composer seam — view-level scenarios (mandatory,
opt-in tier):**

- `ChatAttachmentHostedScenarioTests` (new, `Tests/WikiFSAppTests/`).
  Mounts the real chat routing surface with the
  `DurableNewChatHostedTests` pattern (`:57` fixture, `:78` mount, `:88`
  bounded `waitUntil`), injecting a test-owned
  `ChatComposerAttachmentModel` and an `onComposerPanePropsBuilt` capture
  list. Suite traits `@Suite(.serialized, .timeLimit(.minutes(2)))`.
  - `composerPaneReceivesChipsInOrder`: after mount, the captured
    `ChatComposerPaneProps.attachments` carry the targets in order with
    the resolved display names and kinds. This asserts what
    `ChatComposerPaneView` actually receives, through the real
    `makeComposerPaneProps()` path — not a parallel projection. Then add
    one more target through the model and wait for the next props
    capture: the new value forwards, which also proves the model change
    triggers a rebuild.
  - `chipsLandBeforeHydrationCompletes`: create with targets, mount, and
    assert the captured props while the daemon call is still suspended
    (below). Consumption does not wait for hydration.
  - `nothingAttachesToTheWrongChat`: with hydration still suspended,
    navigate `store.selection` to another chat tab and mount it. Its
    captured props carry no attachments, and the request is already nil.
  - `remountAddsNoDuplicateChips`: switch away and back to the new chat
    while hydration is in flight, then let hydration finish. The captured
    props show no duplicate chips after the repeat mount and the re-run of
    the hydration task.
  - `duplicateTargetProducesOneChip`: apply the same target twice through
    the model. The captured props show one chip.
  - `newChatComposerTakesFocus`: `makeKeyAndOrderFront` the host window,
    create with targets, mount, bounded wait. Assert
    `window.firstResponder` is an `NSTextView` descendant of the composer.
    If the CLI host cannot make the window key, fall back to asserting the
    focus-request consumption chain (`store.pendingComposerFocusChatID`
    drains after mount) and note the limitation in the progress entry.
  - `newChatStaysInHostWindow` (pages variant) and the same sources
    variant live in `SidebarNewChatMenuHostedTests`: snapshot
    `NSApplication.shared.windows` (count plus object identity) before
    invoking the menu item, then after the invoke and a bounded wait
    assert all three: the host window identity is unchanged, the window's
    model `activeTab?.selection` is `.chat(newID)`, and the post snapshot
    contains no additional product window. Covers AC.6 for both list
    actions.
- The hydration latch (the test-local stub suspending the rehydrate-path
  daemon call) is itself bounded: exactly-once resume per waiter, a
  `tearDown()` that releases every outstanding call, and deadline-bounded
  acquisition in the test. A named fixture test,
  `hydrationLatchReleasesOnCancelOrDeadlineWithoutLeakingWaiter`, cancels
  the awaiting task and separately forces the deadline, and asserts in
  both cases that the suspended call completes and no waiter stays
  outstanding. A failed assertion or cancelled hydration task can
  therefore not leave a suspended continuation behind — the same hang
  class the gate work fixes.
- The daemon stub base is `StubChatDaemonCommands`
  (`Tests/WikiFSAppTests/ChatDaemonCoordinatorTests.swift:897`, protocol
  at `ChatDaemonCoordinator.swift:12`).

**Optional:**

- Outgoing reference text: after a send through the injected daemon command
  surface, assert the wire message carries the ordered
  `[[page:Name]]` / `[[source:Name]]` refs. The send-path inlining is
  existing behavior (`ChatDetailView.swift:871-872`); this test is a bonus,
  not an AC gate.

## 6. Review Strategy

1. Plan reviews: round-1 and round-2 reviews are done, and every finding
   from both rounds is resolved in this revision. Final approval waits on
   the concluding review round. The orchestrating agent adjudicated all
   findings on the operator's behalf.
2. After implementation: an independent code review by a separate agent
   with fresh context. The reviewer checks the diff against this plan,
   the modeling rules, and the concurrency rules.
3. Fix and re-review loop: every finding gets a fix and a re-review until
   the reviewer reports no blocking findings.
4. Only then prepare the PR on a feature branch. The operator owns the
   merge decision.

## 7. Documentation Strategy

- `PLAN.md` index row: done. The summary line names the typed request.
- `progress/` entry when the feature lands: one entry with the gate
  evidence — `make build` with its build result (test count not
  applicable), and every test command from section 5 (`make test` and each
  opt-in run) with its executed test count and result — plus the
  gate-migration note from 3.1.
- No other docs. The user-visible behavior needs no manual update beyond
  the menu item itself.

## 8. Risks, Blockers, and Required Decisions

**Risks:**

- The `@Observable` attachment model must be read inside body for SwiftUI
  updates to fire. The props-capture test proves both halves of the seam:
  the initial capture shows what `ChatComposerPaneView` receives at build
  time, and the post-change capture shows a model edit produces a new
  build with the forwarded value. What the capture cannot prove is
  per-frame rendering; if that ever matters, an AppKit-tree check stays
  available as a follow-up, but the current assertions cover the seam this
  feature touches.
- The gate change touches shared test infrastructure. Every call site
  migrates in the same change (3.1), and the new gate tests plus the
  opt-in regression run (`WIKIFS_APP_TESTS=1 make test`) cover it.
- The opt-in tier adds a step an executor could skip. The evidence rule in
  section 5 (recorded nonzero counts per filter) makes a skipped tier
  visible instead of silently green.
- Chips do not survive a tab switch. This matches drop-added chips today
  (2.5). The plan treats it as existing behavior, not a regression, and the
  hosted tests pin the consume-once semantics instead.

**Blockers:** none.

**Required Decisions:** none open. The previously open points are closed:

- Window semantics (decision recorded in 2.7): active tab of the current
  window, matching the Add Chat workflow; no separate composer window.
- Chip persistence (recorded in 2.5): view-state lifetime, matching
  drop-added chips; no draft persistence for attachments in this feature.
- Scope (recorded in section 1): Pages and Sources lists only. A Chats-list
  variant would be a separate, later change.

# Chat attachment persistence

## 1. Goal

Composer attachment chips become durable per-chat state in SQLite. Chips
written in one session restore when the chat tab reopens and after an app
restart, with one lifetime rule for every chip source: menu-attached
("New Chat with Page/Source"), drag-in from any sidebar list (including the
Chats list), and Add-Context-Picker picks — pages, sources, AND chats. This
replaces the one-shot `PendingChatAttachmentRequest` hand-off shipped in
d1871db7, whose chips die at tab close or app restart
(`ChatDetailView.swift:780-784`, `WikiStoreModel.swift:303,374,411`).

Out of scope: no change to the attachment UI, to the reference-text inlining
at send, to the composer focus flow, or to the transcript tables.

## 2. Implementation Summary

### 2.1 Storage: a `chat_attachments` table, one row per target

New table (DDL in the v58 step and in the fresh schema):

```sql
CREATE TABLE IF NOT EXISTS chat_attachments (
    chat_id   TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    kind      TEXT NOT NULL,   -- 'page' | 'source' | 'chat'
    raw_id    TEXT NOT NULL,   -- PageID/SourceID/ChatID rawValue (raw ULID text)
    position  INTEGER NOT NULL,
    PRIMARY KEY (chat_id, position)
);
CREATE INDEX IF NOT EXISTS chat_attachments_by_chat ON chat_attachments(chat_id);
```

The `IF NOT EXISTS` style matches the existing chat-table helpers
(`createChatTablesV23`, `GRDBWikiStore.swift:2199-2242`).

Decisions, with alternatives:

- **Table, not a JSON column on `chats`.** The row-per-target shape matches
  the chat persistence family (`chat_transcript_items`/`chat_messages`,
  :2199-2242), gives FK cascade and typed columns, and keeps the `chats` row
  free of a blob that three other writers (daemon titles, config writes,
  ordering) would race. A JSON column is opaque, has no per-row integrity,
  and turns every add/remove into read-modify-write of the whole chat row.
  Rejected.
- **All three target kinds from day one, including `.chat`.** Chats are
  attachable TODAY: `AddContextPicker` lists pages, sources, and chats with
  no filter (`AddContextPicker.swift:84-95`, chats at :92-94), the Chats
  sidebar emits `.chat` drag payloads (`ChatsListView.swift:271`), and the
  composer accepts every payload kind unfiltered
  (`ChatComposerPaneView.swift:99-113`). A design that dropped chat targets
  would delete shipped behavior. `ChatAttachmentTarget` therefore gains
  `case chat(ChatID)`, the table's `kind` column stores a checked `'chat'`
  tag from day one, and the chip mapping
  (`ChatAttachment.init(target:store:)`, `ChatDetailView.swift:1095-1104`)
  gains the `.chat` case — its display name resolves through
  `resolveAttachmentName`'s existing `.chat` branch
  (`WikiStoreModel.swift:999-1009`, chats at :1006). The decode of `kind`
  is checked: an unknown tag throws rather than silently producing no chip.
- **Store the TARGET (kind + raw id), never the display name.** Names are
  resolved fresh at restore through `resolveAttachmentName(for:)`
  (`WikiStoreModel.swift:999-1009`), so a rename is reflected on the next
  restore. Raw ULID strings are the persistence-boundary contract (AGENTS.md
  modeling rules); typed `ChatAttachmentTarget` conversion happens exactly
  there. The case tag keeps the namespaces apart: a page and a chat with
  identical raw text decode to different targets (pinned by test, AC.4).
- **Replace-all per mutation.** Every write deletes the chat's rows and
  re-inserts the model's current array in one savepoint. The model array is
  the single source of truth for order and dedupe, so replace-all makes each
  mutation one atomic, order-correct write. Per-row upserts were rejected:
  they spread order/dedupe logic across two code paths and invite drift.

### 2.2 Schema ladder: v57 → v58 (baseline verified)

`GRDBWikiStore.currentSchemaVersion` is **57** — verified from source
(`GRDBWikiStore.swift:161`; `schemaVersion` at :165). This is a closed,
verified fact, not an operator decision. The plan targets **v58**.

- Ladder step: `if version < 58 { try db.inTransaction(.immediate) { try
  Self.createChatAttachmentsTableV58(in: db); try db.execute(sql: "PRAGMA
  user_version = 58;"); return .commit }; version = 58 }` — exactly the
  v56/v57 step shape (`GRDBWikiStore.swift:1666-1690`), with the DDL in a
  static `createChatAttachmentsTableV58(in:)` mirroring
  `createChatTablesV23` (:2199).
- Fresh-schema path (REQUIRED): `createFreshSchema(on:)` (:3435) creates the
  chat tables INLINE in its consolidated block (the `chats`/`chat_messages`
  DDL at :3686-3699) — the `:1129` helper call is the LADDER's v24→v25 step,
  not the fresh path. The v58 implementation MUST add
  `createChatAttachmentsTableV58(in:)` to `createFreshSchema` itself; a
  fresh DB is born with the table at `user_version = 58`.
- Existing chats migrate to **empty attachment sets** — there is nothing to
  backfill; the table simply starts empty.
- **Schema-test audit step (named, mandatory).** Thirteen pin sites across
  five test files assert `57` and break `make test` when the version bumps:
  `ChangeRevisionTests.swift:138`; `ChatStoreTests.swift:442`;
  `FetcherStoreMigrationTests.swift:53-54,85,100`;
  `SchemaMigrationLadderTests.swift:29,44,71,137,212`;
  `WikiStrategyStoreTests.swift:85,100`. The implementation step replaces
  `57` with `GRDBWikiStore.schemaVersion` wherever the test means "latest",
  and keeps a literal number ONLY where a test intentionally pins a historical
  fixture (the rewind tests' `user_version = 56` stamps stay literal — they
  are the point of the test). The audit greps `== 57` / `= 57` across
  `Tests/WikiFSTests/` and accounts for every hit.

### 2.3 Emission discipline: one top-level mutate, behavioral event tests

New public `GRDBWikiStore` mutators, both routed through `mutate(event:_:)`
(`GRDBWikiStore.swift:501-534`):

- `createChat(kind:title:attachments:)` — a composed overload of the
  existing `createChat` (:10179/:10186). Its `mutate` body inserts the
  `chats` row AND the attachment rows inside ONE reentrant savepoint, so the
  persist-first contract is atomic by construction. Event:
  `localEvent(.chat, id: chat.id.rawValue, change: .created)`.
- `setChatAttachments(chatID:targets:)` — existence-checked (throws
  `WikiStoreError.chatNotFound`), replace-all write of the ordered targets.
  Event: `localEvent(.chat, id: chatID.rawValue, change: .updated)`.

**Composition guard (explicit, per the store's own nesting note at
`GRDBWikiStore.swift:484-496`):** the composed create MUST be ONE top-level
`mutate(event:)` body performing the two inserts directly (or through
non-emitting, `Database`-taking `*Locked` helpers — the pattern the note
prescribes). It must NEVER call the public `createChat` or
`setChatAttachments` from inside the body: a nested `mutate` emits its event
as soon as ITS savepoint returns, so an outer rollback cannot suppress it
and the run produces duplicate/escaped events. The new read,
`chatAttachments(chatID:) throws -> [ChatAttachmentTarget]`, is a plain
query (READ partition, `ORDER BY position`).

The event kind is the existing `.chat` channel: attachment rows are part of
the chat's composer state, and `ResourceKind` has no attachment case to
reuse. A new event kind was rejected — no subscriber needs to distinguish
attachment writes from other chat writes today.

**Emission proof is behavioral, not textual.** Beyond the source-text
classification in `StoreEmissionExhaustivenessTests` (kept, extended with
the two new signatures), named event-bus tests assert the observable
contract: subscribing a test bus, the composed create emits EXACTLY ONE
post-commit `.chat`/`.created` event; `setChatAttachments` emits EXACTLY ONE
`.chat`/`.updated`; and when the write fails (injected failure, 2.3.1), ZERO
events are emitted — proving post-commit emission and rollback suppression.

#### 2.3.1 Failure injection after the chat row inserts

A read-only store fails the FIRST insert and cannot distinguish an atomic
compose from a naive create-then-insert (the chat would already be
committed when attachments fail). Named store integration tests inject the
failure at the ATTACHMENT insert instead:

- A test trigger raising ABORT on `chat_attachments` inserts
  (`CREATE TRIGGER ... BEFORE INSERT ON chat_attachments BEGIN SELECT
  RAISE(ABORT, 'injected'); END;`) is installed AFTER seeding an existing
  chat; the composed create then runs against it. Assert: no NEW chat row
  (rolled back), no attachment rows, and ZERO events on the test bus.
- The same trigger pattern exercises `setChatAttachments` rollback: seed an
  existing chat with two targets, install the trigger, attempt a
  replacement, assert the OLD two rows are intact and zero events fired.

### 2.4 Write-through seams: one binding operation

`ChatComposerAttachmentModel` gains the persistence wiring as ONE coherent
binding lifecycle — no scattered hooks:

- `weak var store: WikiStoreModel?`, `private(set) var chatID: ChatID?`,
  and a `bound` flag, set by a single `bind(store:chatID:)` call when the
  chat surface mounts. `chatID == nil` (the legacy draft surface) binds to
  nothing: local draft chips are preserved and no read or write happens.
- **Every mount enters the unbound/restoring state first.** The mount
  sequence is: (1) the model is unbound (persistence disarmed), (2) the
  persisted targets are read and applied as ONE deduped batch via
  `applyTargets` — which performs ONE `replace(with:)`-equivalent set of
  chips, not a loop of `add`s (the current loop at
  `ChatComposerAttachmentModel.swift:49-51` would fire the persistence hook
  once per row if hooks lived on `add`), (3) persistence is armed. Repeat
  mounts and re-renders therefore write NOTHING.
- After arming, every user-driven mutation — `add`, `remove`,
  `replace(with:)`, `clear()`, and `applyTargets` (one deduped batch, ONE
  persistence call) — ends with a single `persistCurrentState()` that maps
  the chips to `[ChatAttachmentTarget]` and calls the model-level write
  (below). The dedupe rule in `add` is unchanged.
- `applyTargets` is reworked from its loop-of-adds shape (:47-52) into one
  deduped batch assignment; its doc comment (:46-47) is updated with it.

**Model-level write + error reporting.** `WikiStoreModel` gains
`setChatAttachments(chatID:targets:)` (the step the earlier draft omitted):
it wraps the store mutator in do/catch; on failure it logs through
`DebugLog.store` and surfaces a non-fatal `storeError`-style report — the
in-memory chips stay authoritative and the next mutation retries the write.
A chip persistence failure must never take the composer down, but it must
never be silent either (no bare `try?`). `beginNewChat(attachments:)`
routes through the composed store overload; its existing failure path
(store error, no tab) is unchanged.

All writes stay on the main actor (model is `@MainActor`, calls the
`@MainActor` `WikiStoreModel`, which calls the store synchronously); no
statement handle leaves `GRDBWikiStore`.

### 2.5 Fate of the one-shot seam: removed, with a zero-reference audit

`beginNewChat(attachments:)` (`WikiStoreModel.swift:357-388`) switches to
the composed store overload. The one-shot machinery is REMOVED:

- `PendingChatAttachmentRequest` — declared in
  `Sources/WikiFSCore/Core/ChatAttachmentTarget.swift:35` (NOT in
  WikiStoreModel.swift); its removal also updates the enum's doc comment
  that references it (:9-13).
- `pendingChatAttachmentRequest` + `consumePendingChatAttachmentRequest`
  (`WikiStoreModel.swift:303,398-417`) and their doc comments.
- `applyPendingChatAttachments` (`ChatDetailView.swift:780-784`) — replaced
  by bind + restore (2.4).
- Stale doc comments referencing the request:
  `ChatDetailView.swift:1095-1100` (the typed adapter's doc comment) and
  `ChatComposerAttachmentModel.swift:46-47` (`applyTargets`' doc comment).

The removal step ends with a zero-reference audit:
`rg -n 'PendingChatAttachmentRequest|pendingChatAttachmentRequest|consumePendingChatAttachmentRequest|applyPendingChatAttachments' Sources/ Tests/`
must return zero hits before the commit lands.

Restore semantics (replacing consume): the mount path is ONE binding
operation (2.4) — restore is keyed by the mounted chat's own persisted rows,
so it is idempotent and wrong-chat-proof by construction, with no
consumable state to race.

Test fallout, rewritten rather than deleted:

- `NewChatSidebarProjectionTests`: the six pending-request tests (installed
  at :411-509 of the merged file) become persistence pins — the composed
  create persists chat + rows together, a failed creation leaves nothing
  (2.3.1 injection, not read-only store), `setChatAttachments` pins, and a
  chat created WITHOUT attachments has an empty set.
- `ChatAttachmentHostedScenarioTests`: "chips land before hydration
  completes" keeps its shape (the restore read is store-backed, so chips
  still land before the daemon answers); "nothing attaches to the wrong
  chat" becomes "the wrong chat restores empty"; the consume-once assertions
  disappear; the remount test now proves restore idempotence; the
  send/queue/failed-send scenarios (2.7) are added here.
- `SidebarNewChatMenuHostedTests`: the invoke tests assert persisted rows
  (`store.chatAttachments(chatID:)`) instead of the pending request, and the
  restart tests assert restore through a fresh model over the same DB.
- `ChatAttachmentTargetTests`: gains the `.chat` case pins, including the
  namespace-separation triple (page vs source vs chat with identical raw
  text are three distinct targets).

### 2.6 Restore read path and rename coverage

The restore is a synchronous main-actor read: `WikiStoreModel` gains
`chatAttachments(chatID:) -> [ChatAttachmentTarget]` wrapping the store
read, called from the `.onAppear` mount slot. An async `WikiReadService`
read was rejected: the chips must exist at first render, the query is a
single indexed scan of one chat's rows, and a second off-main invalidation
channel for a synchronous `@State` seed would add machinery the read does
not need. This is the same mount slot and synchrony the one-shot consume
used (`ChatDetailView.swift:271-276`), so the no-state-writes-in-view-update
rules are unchanged — `.onAppear` is a lifecycle moment, not the update
pass.

**Rename coverage (all three kinds).** `resolveAttachmentName` reads the
MODEL's caches (`summaries`, `sources`, `chats`,
`WikiStoreModel.swift:999-1009`), so restore tests must move names through
the model — a raw store write plus a fresh model would sidestep the cache
and prove nothing. Named tests rename a page, a source, and a chat through
the model's mutation paths (which refresh their caches) and then restore,
asserting the new display names on the restored chips while the persisted
rows still carry the raw ids.

### 2.7 Send/queue semantics: sending consumes, failure restores

Sending or queueing consumes the chips: the existing `clear()` paths
(`ChatDetailView.swift:817,841`) persist the empty set through the bound
model. The reference text lives on inline in the transcript (existing
inlining at :888-889), so nothing is lost. Failed-send restore, queued
recall, and queued edit re-persist via `replace(with:)`. This matches
today's chip behavior exactly; the only change is that the state survives a
restart. The hosted scenarios drive the REAL `sendMessage`/`queueMessage`/
`recallQueuedMessage`/`editQueuedMessage` callbacks — not synthetic model
calls — and a stubbed failed submit exercises the restore path, asserting
the SQLite target set at each transition (2.7 tests in section 5).

### 2.8 Restart proof

"Survives app restart" is tested literally: build model A over a DB file,
attach chips, discard A; open a FRESH `GRDBWikiStore` + `WikiStoreModel`
over the same file; assert the restore. The hosted tier mounts the REAL
`ChatDetailView` through the existing props-capture host
(`ChatAttachmentHostedScenarioTests.swift:179-205` route view, :217-267
fixture/mount) over the reopened store and asserts the restored chips
through `onComposerPanePropsBuilt` — not a headless read in an app-test
target.

### 2.9 Current-state references (verified on main @ d1871db7)

- Schema: `GRDBWikiStore.swift:161` (`currentSchemaVersion = 57` — closed,
  verified), :165 (`public static var schemaVersion`), :638
  (`migrate(from:in:)`), :1666-1690 (v56/v57 steps — the template for v58),
  :2199-2242 (`createChatTablesV23` DDL — `chats.id` is `TEXT PRIMARY KEY`),
  :3435 (`createFreshSchema`), :3686-3699 (the fresh path's INLINE chats
  DDL — where the v58 table must also be created), :1127-1131 (the LADDER's
  v24→v25 step that calls the V23 helper — not the fresh path).
- Mutator pattern: :501-534 (`mutate(event:_:)` — reentrant savepoint, event
  computed in-transaction, emitted post-commit), :484-496 (composition
  guard: one top-level `mutate`, non-emitting `*Locked` helpers, never
  nested public mutators), :536-557 (`mutateBatch`), :562-566
  (`localEvent`), :10186 (`createChat` with
  `localEvent(.chat, change: .created)`).
- Protocol home: `WikiStore.swift:1129-1154` (`createChat` overloads,
  `listChats`) — the new mutator and read join the protocol here.
- Shipped feature under this plan: `ChatAttachmentTarget.swift` (enum :14,
  request struct :35, stale docs :9-13), `ChatComposerAttachmentModel.swift`
  (:32 @State home in ChatDetailView; applyTargets :47-52, stale docs :46-47),
  `ChatDetailView.swift:24,32,271-276,553,569,767-783,817,841,888-889,
  1095-1104`, `WikiStoreModel.swift:303,342-388,398-417,999-1009`.
- Tests: `StoreEmissionExhaustivenessTests.swift:13-24` (page mutator
  classification), :138-143 (chat mutator classification),
  `ChangeRevisionTests.swift:109-138` (migration test shape: fresh DB
  stamps `schemaVersion` at :109; rewind drops the table + triggers then
  stamps 56 at :125-134), the five schema-pinning files listed in 2.2,
  `StoreConcurrencyTests.swift:10` (regression suite).

## 3. Implementation Plan

Ordered; each step compiles except where a step depends on an earlier one
(marked).

1. `Sources/WikiFSCore/Core/ChatAttachmentTarget.swift` — add
   `case chat(ChatID)` to the enum and refresh the doc comment (:9-13).
2. `Sources/WikiFSCore/Store/GRDBWikiStore.swift` — bump
   `currentSchemaVersion` to 58; add the `if version < 58` ladder step and
   the static `createChatAttachmentsTableV58(in:)` (IF NOT EXISTS DDL);
   add the same table creation to `createFreshSchema`'s inline block
   (REQUIRED — :3686-3699 region); add `chatAttachments(chatID:)` (read),
   `setChatAttachments(chatID:targets:)` (mutator), and the composed
   `createChat(kind:title:attachments:)` overload — one top-level `mutate`
   each, direct inserts or `*Locked` helpers, per the :484-496 guard;
   declare all three in the `WikiStore` protocol
   (`WikiStore.swift:1129` region).
3. `Tests/WikiFSTests/StoreEmissionExhaustivenessTests.swift` — classify the
   two new mutator signatures (source-text layer, kept alongside the
   behavioral tests).
4. Schema-test audit (naming all five files): replace "latest" pins with
   `GRDBWikiStore.schemaVersion` in `ChangeRevisionTests.swift:138`,
   `ChatStoreTests.swift:442`, `FetcherStoreMigrationTests.swift:53-54,85,100`,
   `SchemaMigrationLadderTests.swift:29,44,71,137,212` (:29 is a hard-coded
   `#expect(store.pragmaValue("user_version") == "57")`, not a `schemaVersion`
   use), `WikiStrategyStoreTests.swift:85,100`; keep
   literal numbers only for intentional historical fixtures (the rewind
   stamps). Account for every `== 57` / `= 57` hit in `Tests/WikiFSTests/`.
5. `Tests/WikiFSTests/ChatAttachmentsMigrationTests.swift` (new) — migration
   + fresh-schema pins (AC.6/AC.7), modeled on `ChangeRevisionTests`
   (:125-134 rewind pattern), non-self-satisfying per AC.6.
6. `Tests/WikiFSTests/ChatAttachmentPersistenceTests.swift` (new, depends on
   1-2) — the persistence contract, failure injection (2.3.1), event-bus
   tests, restart, rename coverage (AC.1-AC.5, AC.8, AC.10).
7. `Sources/WikiFS/Chats/ChatComposerAttachmentModel.swift` — `bind`, the
   one-binding-operation lifecycle, the batched `applyTargets`, the boundary
   conversion, `persistCurrentState()`, and the per-mutation persistence
   hooks (depends on 6); update the :46-47 doc comment.
8. `Sources/WikiFSCore/Store/WikiStoreModel.swift` — model-level
   `setChatAttachments(chatID:targets:)` with the do/catch error-reporting
   semantics of 2.4 (DebugLog + non-fatal surface, in-memory state stays
   authoritative); model `chatAttachments(chatID:)` read; switch
   `beginNewChat` to the composed overload; delete the one-shot state,
   consume, and `PendingChatAttachmentRequest` (depends on 2).
9. `Sources/WikiFS/Chats/ChatDetailView.swift` — replace
   `applyPendingChatAttachments` with bind + restore at the same `.onAppear`
   slot; update the typed adapter's doc comment (:1095-1100) and add the
   `.chat` mapping case (depends on 7-8).
10. `Tests/WikiFSTests/NewChatSidebarProjectionTests.swift` — rewrite the
    pending-request tests as persistence pins (depends on 8).
11. `Tests/WikiFSAppTests/SidebarNewChatMenuHostedTests.swift` — swap
    pending-request assertions for persisted-row assertions + fresh-model
    restart checks; add chat-target menu scenarios are NOT needed (the menus
    attach pages/sources only), but the restart proof covers the persisted
    rows they create (depends on 8).
12. `Tests/WikiFSAppTests/ChatAttachmentHostedScenarioTests.swift` — rewrite
    for restore semantics; add the real-callback send/queue/failed-send and
    rename scenarios; add the chat-target scenario
    `chatPayloadAttachmentSurvivesReopenAndRestart` (AC.5): drive the REAL
    `onAddAttachment` callback used by `ChatComposerPaneView`'s picker/drop
    with a `.chat` `SidebarDragPayload` through
    `ChatAttachment(payload:store:)`, assert SQLite carries the chat-tagged
    target row, remount the same chat and assert the restored props, then
    open a fresh store/model over the same file, mount the real
    `ChatDetailView` through the `CaptureRouteView` host (:179-205,
    fixture/mount :217-267) and assert the restored props again. Picker and
    drop share this one callback, so the shared wiring is verified by one
    scenario. Keep the latch scenarios (depends on 9).
13. `Tests/WikiFSAppTests/ChatComposerAttachmentModelTests.swift` — bind +
    write-through + repeated-bind zero-write unit tests; extend
    `identicalRawTextPageAndSourceProduceDistinctChips` (:24-37) to the
    page/source/chat triple via `ChatAttachment.init(target:store:)` with
    pairwise-distinct chips and the `page:`/`source:`/`chat:` identity
    prefixes (depends on 7).
14. Removal audit: the zero-reference `rg` from 2.5 must be empty.

## 4. Acceptance Criteria

- **AC.1 — Persist on every mutation.** Add, remove, `replace(with:)`,
  `clear()`, and `applyTargets` on a bound model produce exactly the
  corresponding `chat_attachments` rows (kind, raw_id, order), in one write
  per mutation; repeated binds and re-renders write nothing.
- **AC.2 — Restore on reopen.** A chat surface mounted again over the same
  model restores its persisted chips at first render, names resolved fresh,
  order preserved — for page, source, AND chat targets.
- **AC.3 — Restore after restart.** A fresh `GRDBWikiStore` +
  `WikiStoreModel` over the same DB file yields the same restore, through a
  really mounted `ChatDetailView` in the hosted tier.
- **AC.4 — Atomic creation and typed distinctness.** The composed create
  persists the chat row and the attachment rows in one transaction; an
  attachment-insert failure AFTER the chat insert rolls back to: no new chat
  row, no attachment rows, zero events. A page, a source, and a chat with
  identical raw text are three distinct targets and three distinct chips.
- **AC.5 — Menu and picker flows end-to-end after restart.** The menu action
  creates a chat whose page/source chips restore after a fresh model over
  the same DB (both lists); a picker- or drop-attached chat target survives
  reopen and restart the same way.
- **AC.6 — Migration, non-self-satisfying.** A v57-era DB with the v58
  table and index dropped, and an existing chat preserved, migrates to v58:
  the table is recreated, `user_version` stamps 58, and the chat survives.
- **AC.7 — Fresh schema.** A fresh DB is created at v58 with the table
  present (the `createFreshSchema` inclusion is REQUIRED, verified by
  test).
- **AC.8 — Emission, behavioral.** The composed create emits exactly one
  post-commit `.chat`/`.created` event; `setChatAttachments` emits exactly
  one `.chat`/`.updated`; a failed write emits zero events; both mutators
  are classified in `StoreEmissionExhaustivenessTests`.
- **AC.9 — No duplicate chips on repeated mounts.** Remounting the same chat
  (and re-running hydration) leaves exactly one chip per persisted target,
  with zero writes from the remount itself.
- **AC.10 — Names resolve fresh, through the model caches.** After a page,
  source, or chat rename moved through the model's mutation paths, the next
  restore shows the new display name while the persisted rows still carry
  the raw ids.
- **AC.11 — Send/queue semantics, real callbacks.** The real
  send/queue callbacks persist the empty set; a stubbed failed submit and
  the queued recall/edit paths re-persist the restored chips.
- **AC.12 — Concurrency discipline, exercised.** New named
  `StoreConcurrencyTests` cases drive concurrent attachment reads and
  replacements and the transaction nesting/rollback of the new methods,
  using the suite's existing nonblocking patterns; the pre-existing cases
  stay green as the regression gate.

## 5. Test Strategy

Swift Testing. Gates: `make build`, `make test`, the opt-in
`WIKIFS_APP_TESTS=1` tier, `swift test --filter
StoreEmissionExhaustivenessTests`, `swift test --filter
StoreConcurrencyTests` — all before any PR. Opt-in evidence rule: record
executed counts per filter; a zero-count filter is a failure (the filter
must match the SUITE name — e.g. filtering the FILE name
`SidebarNewChatMenuHostedTests` matches zero suites; the runnable suites are
`PagesNewChatMenuHostedTests` and `SourcesNewChatMenuHostedTests`). New
hosted suites keep `.serialized` + `.timeLimit` traits and bounded
`waitUntil` polling; no bare unbounded continuations anywhere.

Runnable opt-in command list (verbatim):

```
# Default gates. WikiFSAppTests is NOT in this graph.
make build
make test

# MANDATORY macOS opt-in runs (each MUST report a nonzero executed test count).
WIKIFS_APP_TESTS=1 swift test --filter HostedAppKitTestGateTests
WIKIFS_APP_TESTS=1 swift test --filter PagesNewChatMenuHostedTests
WIKIFS_APP_TESTS=1 swift test --filter SourcesNewChatMenuHostedTests
WIKIFS_APP_TESTS=1 swift test --filter ChatAttachmentHostedScenarioTests
WIKIFS_APP_TESTS=1 swift test --filter ChatComposerAttachmentModelTests

# Opt-in app-test regression for the whole hosted tier (run before any PR).
WIKIFS_APP_TESTS=1 make test
```

- **AC.1/AC.2/AC.3/AC.5/AC.10 → `ChatAttachmentPersistenceTests`** (new,
  `Tests/WikiFSTests/`, headless; temp-file `GRDBWikiStore` + model fixture
  as in `NewChatSidebarProjectionTests:22-39`): `setChatAttachments` writes
  rows in order and replaces wholesale; `chatAttachments` reads back targets
  with fresh names after model-level renames (page via `renamePage` +
  reload, source and chat via their model mutators); **restart**: model A
  attaches, model B over the same file restores — including a `.chat`
  target; composed create via `beginNewChat(attachments:)` leaves exactly
  one chat row plus ordered attachment rows; the empty-set call clears.
- **AC.4 → `ChatAttachmentPersistenceTests`** (failure-injection block):
  the ABORT trigger tests of 2.3.1 — composed create rolls back to no chat,
  no rows, zero events; `setChatAttachments` rollback preserves the old
  rows, zero events. Plus `ChatAttachmentTargetTests`: the page/source/chat
  identical-raw-text distinctness triple (now three cases).
- **AC.4 (chip level) → `ChatComposerAttachmentModelTests`**: extend
  `identicalRawTextPageAndSourceProduceDistinctChips`
  (`ChatComposerAttachmentModelTests.swift:24-37`) to the page/source/chat
  triple through `ChatAttachment.init(target:store:)`, asserting pairwise
  distinct chips and the `page:` / `source:` / `chat:` identity prefixes.
- **AC.6/AC.7 → `ChatAttachmentsMigrationTests`** (new, modeled on
  `ChangeRevisionTests:125-134`): build a v57-era DB, DROP
  `chat_attachments` and its index, keep an existing chat row, stamp
  `user_version = 57`, reopen → assert 58, table recreated, chat alive;
  fresh DB → assert `schemaVersion == 58` + table present.
- **AC.8 → `StoreEmissionExhaustivenessTests`** (extended classification)
  **+ `ChatAttachmentPersistenceTests`** (behavioral event-bus block): the
  test bus asserts the exactly-one/zero-event contract of 2.3.
- **AC.9 → `ChatAttachmentHostedScenarioTests`** (rewritten): remount +
  re-hydration leaves one chip per target with zero writes from the
  remount; chips land before the latched hydration completes (restore is
  store-backed); the wrong chat restores empty; the latch keeps its
  cancellation/deadline leak test unchanged.
- **AC.5 (hosted half) → `PagesNewChatMenuHostedTests` /
  `SourcesNewChatMenuHostedTests`** (updated): invoking the items asserts
  persisted rows through `chatAttachments`, then a fresh model over the
  same DB restores them.
- **AC.5 (chat targets) → `ChatAttachmentHostedScenarioTests`**:
  `chatPayloadAttachmentSurvivesReopenAndRestart` drives a `.chat` payload
  through the REAL `onAddAttachment` callback shared by the composer's
  picker and drop, asserts the chat-tagged row in SQLite, remounts the chat
  and asserts the restored props, then reopens a fresh store/model over the
  same file, mounts the real `ChatDetailView`, and asserts the restored
  props again.
- **AC.11 → `ChatAttachmentHostedScenarioTests`** (new scenarios): drive the
  real composer callbacks — send and queue clear the persisted set; a
  stubbed failed submit restores it; queued recall and edit re-persist —
  asserting `chatAttachments` rows at each transition.
- **AC.10 (hosted rename half) → `ChatAttachmentHostedScenarioTests`**:
  rename a page, a source, and a chat through the model, remount, assert
  restored chip names.
- **AC.1/AC.11 (model half) → `ChatComposerAttachmentModelTests`**
  (extended): bind + write-through for every mutation; repeated-bind
  zero-write; unbound (draft) writes do not persist; one event per
  mutation observable via a test bus.
- **AC.12 → `StoreConcurrencyTests`** (new named cases): concurrent
  attachment reads vs replacements on the same chat; transaction nesting and
  rollback through the new mutators (injected-failure variant), following
  the suite's existing nonblocking patterns.
- **Schema-test audit → covered by `make test`** (the five audited files run
  in the default graph; the audit accounts for every `57` pin).

## 6. Review Strategy

1. Plan reviews: this design goes through the same review rounds as its
   predecessor; the orchestrating agent adjudicates on the operator's
   behalf, and implementation waits for the concluding approval round.
2. The independent implementation review starts only after ALL section-5
   gates pass with recorded, nonzero executed counts. An implementation
   whose gates are not run and counted is not reviewable.
3. That review has fresh context and checks the diff against this plan, the
   modeling rules, the SQLite discipline (savepoints, no statement handles
   across boundaries), the composition guard (:484-496), and the event-bus
   contract.
4. After review fixes: the AFFECTED gates rerun — and the required final
   full gates (`make test` and `WIKIFS_APP_TESTS=1 make test`) rerun —
   before the fix is re-reviewed or the branch is PR-ready.
5. Fix and re-review loop until no blocking findings. PR prep on a feature
   branch follows; the operator owns the merge.

## 7. Documentation Strategy

- `PLAN.md` index row: added with this plan (see below).
- The predecessor record is superseded: `plans/create-chat-with-attachments.md`
  sections 2.5 and 8 and its `PLAN.md` row note that the one-shot lifetime
  decision is replaced by this plan's persisted per-chat attachments (done
  with this revision).
- AGENTS.md's stale schema line ("currently at v53") is refreshed to the new
  version (58) as part of the implementation branch.
- `progress/` entry when the feature lands: gate evidence with executed
  counts per filter (including the opt-in tier rule), the migration note
  (v57→v58), and any deviation from this plan flagged prominently.
- `plans/chat-and-persistence.md` gains a pointer to the new table when the
  feature lands (it is the chat-persistence reference doc).

## 8. Risks, Blockers, and Required Decisions

**Risks:**

- **Write amplification on every chip op** (delete-all + re-insert). The
  row count is one chat's targets (single digits), inside one savepoint on
  an already-serialized write path; negligible. Per-row upserts were
  rejected for correctness, not speed.
- **Restore must not write.** The one-binding-operation lifecycle (2.4)
  makes the mount a read followed by an in-memory apply, with persistence
  armed only after the restore. The repeated-bind zero-write test pins it;
  if the arm ordering is wrong, every mount writes N rows.
- **Event fan-out for composer-only state.** `.chat`/`.updated` fires on
  chip adds; today's subscribers treat it as a cheap refresh (titles,
  ordering already ride it). Accepted; noted for reviewers.
- **Schema-test drift.** Thirteen pin sites in five files break `make test`
  at the bump; the named audit step (2.2) accounts for every hit, and the
  "latest" pins migrate to `GRDBWikiStore.schemaVersion` so the next bump
  is quieter.
- **The `.chat` target widens the failure surface of restore** (a chat can
  now be attached to itself). The existence-checked restore returns whatever
  the resolver yields; a self-attached chat's name resolves like any other
  chat. No special casing; noted for reviewers.

**Blockers:** none.

**Required Decisions:** none. The schema baseline is CLOSED — verified from
source at `GRDBWikiStore.swift:161`: the ladder is at 57 and this plan
targets v57→v58. All other previously open points are closed with recorded
decisions: storage shape (table, replace-all, all three kinds), event kind
(`.chat` reused), restore path (main-actor model read at mount, one binding
operation), send/queue semantics (consume + inline text), seam fate (one-shot
machinery removed with a zero-reference audit), and restart proof (fresh
model over the same DB, headless + hosted with the real mounted view).

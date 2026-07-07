# Ask/Edit conversation UI (issue #119, phase 2)

Phase 1 (`persisted-chat-history.md`) shipped the storage substrate: every
Ask/Edit session persists to `chats` + `chat_messages` (v23), history rows
appear in the Agent sidebar, and a persisted chat opens as a **read-only**
`ChatHistoryDetailView`. The live surfaces are still the two one-per-kind
singletons (`.ask`/`.edit` → `QueryConversationView` bound to
`askLauncher`/`editLauncher`).

This phase makes conversations the first-class unit of the Agent UI. Three
pillars, in dependency order:

1. **References to source content keep working in transcripts** — wikilinks,
   `#"quote"` anchors, `@vN` pins, `![[source:…]]` embeds, and blob images
   render in chat transcripts (live *and* persisted) exactly as they do in
   the reader, and heal/resolve the same way over time.
2. **One conversation surface with streaming** — live session and persisted
   history render through a single `ConversationView`; streaming deltas keep
   working; when a session ends the view degrades seamlessly to the
   persisted transcript.
3. **History you can continue** — reopen a persisted conversation and keep
   talking (`--resume` when possible, seeded-fresh-session fallback), rename
   it, and see at a glance which conversation is live.
4. **Per-mode models and providers** — Ask and Edit can run different
   models *and* different agent backends (e.g. Ask on a cheap/fast model,
   Edit on a stronger one; or one mode on `claude`, the other on a
   provider-independent CLI like letta-code), via named agent profiles.

## Current state (verified, post-#212 merge)

- Three launchers in `WikiFSApp`: `agentLauncher` (ingest/lint/background),
  `askLauncher`, `editLauncher`. One live interactive session per kind.
- `AgentTranscriptWebView.renderedMarkdown` renders assistant/result rows via
  `MarkdownHTMLRenderer.render(ReaderMarkdown.prepared(text) { _, _ in true })`
  — constant-`true` resolution, **no** `displayName`, **no** `embedInfo`,
  **no** `pinnedExtractionID`, **no** `imageResolver`, and the transcript
  `WKWebView` does **not** register `BlobSchemeHandler`. Clicks already route
  correctly (`wiki://` → `WikiReaderView.onWikiLinkHandler(for: store)`);
  it's the *rendering* that is store-blind. Consequences today: canonical
  `[[source:ULID|alias]]` shows the stale alias forever (no display-at-render
  healing), every link styles as resolved even when its target is gone,
  `![[source:…]]` embeds don't render, blob images 404.
- `WikiReaderView.startLoad` (~line 840) builds the full render precompute:
  existence sets (`pageTitles`/`sourceNames`/`uniqueLooseKeys` +
  ULID-keyed `pageIDToName`/`sourceIDToName`), `embedMap` (incl. Phase 4b
  external `EmbedTarget`s from `store.embedDescriptors()`),
  `sourceDerivedChain` (Phase 6 `@vN`), `siblingImageResolvers()` (Phase 4),
  all captured as pure data by a detached render task.
- Streaming: `assistantTextDelta`s are merged into the trailing
  `.assistantText` by the launcher; the web view patches via
  `replaceLastRow` (same-count branch of `apply`). Persisted flushes happen
  only at turn boundaries, so deltas never hit SQLite.
- `AgentEventParser` decodes `system`/`init` into `.systemInit(model:)` and
  **drops `session_id`** — nothing stores the Claude CLI session identity,
  so `--resume` has nothing to hang off yet.
- `WikiStore.renameChat(id:to:)` exists and is tested; **no UI calls it**.
- `WikiEventBus` (#212, just merged) provides store-change subscription —
  the invalidation mechanism for any cached render context.
- Agent invocation is configured by a **single app-wide**
  `AgentCommandConfig` (executable / prefix args / `modelOverride` / extra
  env), JSON in the App Group container, loaded fresh at every spawn.
  `OperationCommand` resolves the model as
  `modelOverride.isEmpty ? operation.topLevelModelAlias : modelOverride` —
  there is no per-mode axis anywhere; Ask, Edit, ingest, and lint all run
  the same command identity. `AgentCommandSettingsView` (Settings → Agent)
  edits the four flat fields.
- Schema: v23 is current (Phase 5 + chats share it). Next bump: **v24**.

## Design

### D1. Shared render context (pillar 1)

Extract the reader's precompute into one value type in `WikiFSCore`:

```swift
/// Pure-data snapshot of everything a markdown render needs from the store.
/// Built on the main actor, safe to hand to a detached render task.
public struct WikiRenderContext: Sendable {
    // existence / display-at-render / loose-match sets (reader lines ~820–846)
    // embedMap: lowercased name & id → SourceEmbedInfo (incl. external targets)
    // sourceDerivedChain: sourceID → ULID-asc [smvID]  (@vN)
    // siblingMaps: sourceID → [original_path → sibling sourceID]
    public static func build(from store: WikiStoreModel) -> WikiRenderContext
    // The four closures ReaderMarkdown.prepared takes, derived from the data:
    public var isResolved: (String, WikiLinkParser.LinkType) -> Bool { get }
    public var embedInfo: (String) -> WikiLinkMarkdown.SourceEmbedInfo? { get }
    public var displayName: (PageID, WikiLinkParser.LinkType) -> String? { get }
    public var pinnedExtractionID: (PageID, Int) -> PageID? { get }
}
```

- `WikiReaderView.startLoad` is refactored to call `WikiRenderContext.build`
  and pass its closures — behavior-preserving, the existing reader tests are
  the gate. This kills the copy-paste risk before the transcript grows a
  second precompute.
- `AgentTranscriptWebView` gains an optional `renderContext:
  (() -> WikiRenderContext?)?` parameter (a provider closure, not a value —
  rows render incrementally over the life of the view, and the context must
  be *current*, not load-time). `renderedMarkdown(_:context:)` threads it
  into `ReaderMarkdown.prepared`; nil context keeps today's constant-`true`
  behavior (used by `AgentActivityView` internals feed, where ghost styling
  is noise).
- **Caching + invalidation:** the context is rebuilt lazily and memoized on
  `WikiStoreModel` (`store.renderContext()`), invalidated by subscribing to
  `WikiEventBus` (any page/source mutation bumps a generation counter; next
  `renderContext()` call rebuilds). Per-delta renders therefore never touch
  SQLite — they reuse the memoized snapshot. This is the same
  compute-once/capture-pure-data discipline the reader already follows, just
  lifted to a shareable seam.
- **Blob serving:** register `BlobSchemeHandler` on the transcript
  `WKWebView`'s configuration (same `BlobSchemeHandler(store:)` wiring as
  `WikiReaderView`, ~line 326–348) so `wiki-blob://source/<id>` images and
  media resolve inside chat transcripts.
- **Two-tier streaming render:** while a row is still streaming (grown by
  deltas, patched via `replaceLastRow`), render **links only** — skip
  `embedInfo` (pass nil) so a half-typed `![[source:…` never instantiates a
  broken iframe/player that churns per token. When the row finalizes (next
  event lands / `messageStop` boundary), it re-renders once with the full
  context, embeds included. Concretely: `rowHTML` gains an `isFinal: Bool`;
  the coordinator already knows (a row is non-final only when it is the last
  row of a live-streaming launcher).
- User rows stay linkify-exempt (a user typing `[[Foo]]` is not a link) —
  unchanged.

Persisted transcripts get all of this for free because history renders
through the same web view. This is the payoff of phase 1's `event_json`
verbatim-storage decision: old chats *upgrade* — a chat recorded before this
phase gains display-name healing, embeds, and pins the next time it renders.

### D2. One conversation surface (pillar 2)

`ConversationView(chatID:)` replaces the live/history split:

- **Source of truth rule:** if `chatID` is the launcher's active chat
  (`launcher.activeChatID == chatID`, a new launcher property set by the
  runner when it installs the sink), render `launcher.events` (streaming,
  in-memory, exactly today's live path). Otherwise render
  `store.chatMessages(chatID:).map(\.event)`. The turn-boundary flush
  guarantees the two agree whenever a session ends — the view flips source
  without a visible change.
- The existing `QueryConversationView` chrome moves over largely intact:
  composer, editing-enabled banner, internals toggle, stop button, New
  Conversation button. `ChatHistoryDetailView` is absorbed (its header —
  title/kind/count/date — becomes the idle-state header) and deleted.
- `.chat(id)` in `WikiDetailView` routes to `ConversationView`. The
  `transcriptVisible` filter stays shared.

Tabs and selection:

- `.ask` / `.edit` selections survive as **draft states**: selecting Ask
  shows the empty-composer state (today's `emptyState`). On first send, the
  runner creates the chat row (already does) and the tab **retargets in
  place** to `.chat(id)` via a new
  `WikiStoreModel.retargetTab(id: UUID, to: WikiSelection)` (keeps the tab's
  UUID → tab order and per-tab history survive; closing + reopening would
  lose both). From then on the conversation *is* its tab — reopenable,
  drag/droppable, restorable like any page.
- Live continuation: `AgentLauncher.startNewConversation()` semantics are
  unchanged (detach sink, clear transcript, fresh chat row on next send) but
  it now also clears `activeChatID` and retargets the tab back to the draft
  state (`.ask`/`.edit` per mode).

### D3. Continue a persisted conversation (pillar 3)

Session identity (schema v24 + parser):

- `AgentEventParser`: `system`/`init` → `.systemInit(model:sessionID:)`.
  `sessionID` is optional; Codable decode of phase-1 rows (no key) yields
  nil — add a round-trip test against an old-format JSON fixture.
- `chats` gains two nullable TEXT columns (v24, fresh + ladder,
  `FreshSchemaParityTests` extended): `claude_session_id` and
  `agent_executable` (the resolved executable that produced the session —
  the session id is only meaningful to the backend that minted it). The
  transcript sink already sees every persistable event; when a
  `.systemInit` with a session id flows through, the store records both on
  the chat row (`setChatSessionID`, last-writer-wins — a resumed session
  gets a fresh id and overwrites).

Continuing:

- Composer on a non-live persisted chat sends via a new
  `AgentOperationRunner.continueConversation(chatID:message:…)`:
  - Acquires the kind's launcher. If that launcher is **idle**, take over.
    If it is running a *different* conversation but **between turns**
    (`!isGenerating`), end it first (final flush persists its tail — nothing
    is lost; that's the phase-1 guarantee) and take over. If it is
    **mid-generation**, the composer is disabled with the existing
    slot-style hint ("Another Edit conversation is responding — wait or stop
    it."). One live session per kind remains the invariant; the launcher
    pool is deferred.
  - If `claude_session_id` is present **and** the chat's recorded
    `agent_executable` matches the profile the mode resolves to today (D5;
    a `--resume` id from one backend is garbage to another):
    `startInteractiveQuery` gains a
    `resumeSessionID:` parameter → appends `--resume <id>` to the CLI
    arguments (`OperationCommand` interactive variants). Verify against the
    installed CLI that `--resume` composes with `--input-format stream-json`
    (same capture discipline `AgentEventParser` was built with); if the CLI
    session store has GC'd the id, the CLI errors — detect and fall through
    to the seeded path rather than surfacing a raw failure.
  - **Fallback (no session id / resume refused):** start a fresh session
    whose first prompt embeds a condensed transcript — the last N
    `chat_messages.text` rows (user/assistant roles only, byte-capped),
    wrapped in a "continuing an earlier conversation" preamble. The phase-1
    `text` projection exists precisely so this never parses `event_json`.
  - Either way the sink appends to the **same** chat row — `seq` continues,
    title is preserved, `updatedAt` bumps it to the top of Recent.
- The runner installs the sink with the same weak-store discipline as
  phase 1 (wiki switch mid-session degrades to no-op).

### D5. Per-mode models & providers (agent profiles)

`AgentCommandConfig` grows from one flat command into **named profiles**
with per-role assignment — same file, same load-fresh-at-spawn discipline:

```swift
public struct AgentProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String            // "Claude (default)", "Local letta", …
    public var executable: String      // the current four fields, verbatim
    public var prefixArguments: String
    public var modelOverride: String
    public var extraEnvironment: String
}
public struct AgentCommandConfig {    // v2 shape
    public var profiles: [AgentProfile]        // never empty; [0] exists
    public var defaultProfileID: UUID          // ingest / lint / everything else
    public var askProfileID: UUID?             // nil → default
    public var editProfileID: UUID?            // nil → default
    public func profile(for role: AgentRole) -> AgentProfile  // ask|edit|default
}
```

- **Migration:** the v1 JSON (four flat keys) decodes via a custom
  `init(from:)` into a single "Default" profile with `defaultProfileID`
  pointing at it — the same degrade-gracefully load contract as today
  (missing/corrupt → `.default`). Round-trip fixture test against a real
  v1 file.
- **Spawn sites:** `startQueryConversation` / `continueConversation`
  resolve `config.profile(for: mode == .edit ? .edit : .ask)`;
  ingest/lint/background keep `.default`. `OperationCommand` takes the
  profile's fields exactly where it takes the config's fields today — the
  `modelOverride.isEmpty ? topLevelModelAlias : modelOverride` rule is
  unchanged, just per-profile. "Provider" needs no new concept: a profile's
  executable + env *is* the provider (a letta-code profile is just
  `executable: "letta"` + its env), which is what makes the swap drop-in.
- **Settings UI:** the Agent tab becomes an Accounts-style master-detail
  (profile list left — add/duplicate/delete, `[0]`-cannot-delete — and the
  existing four-field form as the detail pane; mirrors `ZoteroSettingsView`
  conventions like the current view does), plus two pickers above the list:
  "Ask uses:" / "Edit uses:" (each: Default ∣ named profile).
- **Conversation surface:** the idle header (D2) shows what produced the
  transcript — kind · model (already persisted in the chat's `.systemInit`
  row; no new storage) · profile name when not default. The draft
  empty-state shows the mode's resolved profile/model as a caption under
  the composer ("Ask · haiku via Claude") so the per-mode split is visible
  *before* the first send, not a surprise after.
- **Continue interplay (D3):** continuing always uses the mode's *current*
  profile. Same executable → `--resume` (model may differ; the CLI accepts
  a model switch on resume). Different executable → recorded
  `agent_executable` mismatch → seeded fallback, automatically. No
  per-conversation profile pinning in this phase — the chat row records
  what happened (`agent_executable` + per-session `.systemInit` rows), it
  doesn't constrain what happens next.

### D4. Sidebar & affordances

- **Recent Conversations** section header gains a `+` (New Conversation →
  opens the draft state for a mode via a small Ask/Edit menu; default Ask).
- Rows: live indicator (small `circle.fill` tint / "responding…" caption
  driven by `activeChatID` + `isGenerating` on the matching launcher) so the
  one-per-kind constraint is *visible* instead of surprising.
- Context menu: **Rename Conversation…** (inline alert/text field →
  `store.renameChat`, which exists and is tested but has no UI today) next
  to the existing Delete.
- Ask/Edit mode rows stay at the top as the entry points to draft states —
  their subtitle changes to "New read-only conversation" / "New editing
  conversation" to match the retarget behavior.
- List stays most-recently-updated-first; no search/FTS in this phase (the
  `text` column is ready for it — deferred with the `[[chat:…]]` family).

## What stays deferred (unchanged from phase 1)

`[[chat:…]]` wikilinks, quote anchors *into* chats, `chats.jsonl`, the File
Provider `chats/` tree, and **multiple concurrent live sessions per kind**
(needs a per-conversation launcher pool; D3's takeover semantics are
designed so the pool slots in without changing the conversation surface).

## Phases

Each phase is independently shippable and gated on green tests.

### Phase A — shared render context (no UI change)
1. `WikiRenderContext` in `WikiFSCore` + `WikiStoreModel.renderContext()`
   memo + `WikiEventBus`-driven invalidation.
2. Refactor `WikiReaderView.startLoad` onto it (behavior-preserving).
3. Thread `renderContext` into `AgentTranscriptWebView` (+ `isFinal`
   two-tier render), register `BlobSchemeHandler`, pass the provider from
   `QueryConversationView`/`ChatHistoryDetailView`.
   Gate: a persisted chat containing `[[source:ULID|old name]]`, a
   `#"quote"` link with `@vN`, an `![[source:…]]` image embed, and a broken
   link renders: healed display name, `&pin=` URL, inline image via
   `wiki-blob://`, ghost styling. Reader renders byte-identical to before.

### Phase B — session identity (schema v24)
1. Parser + `AgentEvent.systemInit` gains `sessionID` (Codable
   back-compat fixture test).
2. v24 ladder + fresh path: `chats.claude_session_id`; `setChatSessionID`
   store API; sink records it.
   Gate: new sessions persist a session id; phase-1 rows decode; parity
   test green.

### Phase C — ConversationView + continue
1. `ConversationView` (source-of-truth rule, composer, absorbed header);
   `WikiDetailView.chat` routes to it; delete `ChatHistoryDetailView`.
2. `launcher.activeChatID`; `retargetTab`; draft-state morph on first send;
   `startNewConversation` retarget-back.
3. `continueConversation` runner path: takeover rules, `--resume` plumbing
   through `OperationCommand`, seeded fallback, same-row sink.
   Gate: send in a reopened chat → response streams into the same tab;
   restart the app → reopen → continue again ( `--resume` path); delete the
   CLI session dir → continue still works (seeded path, visibly fine);
   mid-generation takeover correctly refused.

### Phase D — sidebar affordances
Rename UI, live indicator, `+` new-conversation, mode-row subtitle copy.
Gate: rename round-trips; the live row badges while generating and unbadges
at `messageStop`.

## Files touched

| Area | File | Change |
| --- | --- | --- |
| Core | `WikiRenderContext.swift` (new) | precompute extraction (D1) |
| Core | `WikiStoreModel.swift` | `renderContext()` memo + bus invalidation; `retargetTab` |
| Core | `AgentEvent.swift` | `systemInit(model:sessionID:)`, parser, Codable compat |
| Core | `SQLiteWikiStore.swift` / `WikiStore.swift` | v24 `claude_session_id`, `setChatSessionID` |
| Core | `OperationCommand.swift` | `--resume` on interactive variants |
| App | `WikiReaderView.swift` | refactor onto `WikiRenderContext` |
| App | `AgentTranscriptWebView.swift` | context param, `isFinal` tiering, `BlobSchemeHandler` |
| App | `ConversationView.swift` (new) | unified surface (absorbs `QueryConversationView` conversation body + `ChatHistoryDetailView`) |
| App | `AgentLauncher.swift` | `activeChatID`, resume plumbing |
| App | `AgentOperationRunner.swift` | `continueConversation`, sink/session-id recording |
| App | `AgentToolsView.swift` | rename, live badge, `+` |
| App | `WikiDetailView.swift` | `.chat` → `ConversationView` |
| Tests | render-context parity, codable fixtures, v24 ladder/parity, takeover matrix, retarget, seeded-fallback prompt builder |

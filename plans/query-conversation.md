# Query Conversation Page

## Direction

Query is now a dedicated wiki-level workspace instead of a page-bottom composer.
The user can ask questions, ask follow-ups, inspect the transcript, and decide
whether Claude should update the wiki. The default behavior is conversational:
Claude answers in chat. It writes through `wikictl` only when the user explicitly
asks to save, update, add, rewrite, log, or otherwise persist something.

## App Shape

- `WikiSelection.query` is a singleton sidebar destination beside System Prompt
  and Change Log.
- `QueryConversationView` owns the visible query workspace: output-first chat
  transcript, Start/Send composer, Stop, and Activity log access. The File
  Provider mount remains a run precondition, but its path is not shown as primary
  chrome.
- Page readers no longer embed query controls. Reading a page stays focused on
  page content; questions happen in the Query workspace.
- The global transcript inspector is suppressed while `WikiSelection.query` is
  selected, because Query's primary content is already the transcript.
- Query uses `QueryTranscriptView` for the default chat surface. It shows user
  turns as right-aligned pills and Claude prose/results as unboxed readable text,
  suppressing tool calls and duplicate terminal result events.
- The shared `AgentActivityView` remains the inspector/log renderer for
  operations and debugging. Transcript surfaces default to output-only; the
  "Show internals" checkbox reveals tool calls, live status, raw events,
  diagnostics, and stderr when debugging a run.
- The sidebar separates app-level destinations into Tools (Query) and System
  (Activity, Instructions), with Pages and Files left as content lists.

### Layout parity with PageDetailView (#275)

The conversation surface (`ConversationView`) mirrors `PageDetailView`'s
header + content + outline layout so the two detail surfaces read as siblings:

- **Header** — `VStack`: title (`.largeTitle`) → metadata row (message count ·
  date) → button row. The button row holds a "Show in List" button
  (`sidebar.left` → `requestSidebarReveal(.chat(id))`, hidden in draft state)
  and the outline toggle (`sidebar.right`). Both live and persisted chats use
  the same `header(for:)` + divider.
- **Content width** — transcript, composer, and editing banner fill the full
  available width (`maxWidth: .infinity`) with `contentInset` (12pt) padding.
  No `chatColumnWidth` cap (the old 900pt limit was removed).
- **Outline** — `ChatOutlineView` mirrors `PageOutlineView`: draggable divider
  with resize cursor, dynamic width via `@AppStorage("chatOutlineWidth")`
  (default 240, range 60–600), `.windowBackgroundColor`. The outline sits flush
  against the right window edge (`withChatOutline` stretches content to
  `.infinity`). Lists user turns in order; clicking scrolls the transcript via
  a versioned `ChatScrollRequest`.
- **Chat bubble CSS** — agent responses fill the available width (no
  `max-width` cap); only user messages are capped at `min(760px, 86%)` and
  right-aligned. Transcript `body` padding is vertical-only (`10px 0`); the
  SwiftUI layer handles horizontal insets.

## Agent Session

Interactive Query uses Claude Code's print-mode streaming input:

```text
claude -p --input-format stream-json --output-format stream-json --verbose ...
```

`AgentLauncher.startInteractiveQuery(...)` stages `WIKI_STATE.md`, starts Claude
with stdin/stdout/stderr pipes, and sends the first user turn as stream-json.
Follow-up turns call `sendInteractiveMessage(_:)`, which appends the user message
to the transcript and writes the same text as a JSON line to stdin. The process
remains open until the user stops it or Claude exits.

The command still exports `WIKI_ROOT`, `WIKI_DB`, and a PATH prefixed with the
embedded `wikictl` directory. The appended prompt includes the normal maintainer
schema plus an interactive Query overlay:

- answer in chat by default;
- inspect the wiki/source material silently, without narrating setup steps;
- use `wikictl page get` and raw-source footnote chasing when needed;
- only mutate the wiki on explicit user request;
- when mutating, write via `wikictl`, update `index.md` if appropriate, and
  append a `query` log entry.

## Security: read-only vs edit-mode trust surface

Query has two distinct trust tiers, enforced by **different mechanisms**:

- **Read-only (default, "Allow wiki edits" OFF).** The agent runs under a
  **hard seatbelt-sandbox boundary** (`SandboxProfile.readOnlyInvocation`) that
  DENIES writes to the wiki database at the OS level. `wikictl page upsert` /
  `index set` / `log append` physically fail regardless of what the prompt says.
  This is enforced by `AgentLauncher.selectQuerySandbox(allowWikiEdits:false, …)`,
  which returns the read-only sandbox EVEN WHEN a non-nil edit sandbox is
  configured — global sandbox settings can never override the forced read-only
  boundary. The editor lock is never taken, so ingestion stays unblocked.

- **Edit-mode ("Allow wiki edits" ON).** A higher-trust surface. The agent runs
  `claude --dangerously-skip-permissions` with only the opt-in seatbelt sandbox
  (which may be `nil` / fail-open) plus prompt-level instructions. The per-turn
  edit lock (`store.isAgentRunning`, driven by `onTurnBoundary`) is taken while
  the agent is responding and RELEASED between turns so ingestion can run when the
  agent is idle. Because edit mode skips the permission prompts, **ingested and
  source content can influence agent writes** — a malicious source document could
  attempt prompt injection. Read-only mode is the safe default for untrusted
  material; edit mode should be reserved for material the user intends to act on.

The lock is owned by `AgentLauncher.setGenerating(_:)` (single mutation point),
fired via the `onTurnBoundary` callback the runner installs — NOT by any View —
so it releases between turns even when the Query view is unmounted.

## UI Notes

The page uses two explicit states. Empty Query is a centered greeting plus a
floating pill composer. Once the first user turn exists, the transcript fills the
page and the same composer docks at the bottom. This avoids permanent header
chrome and keeps attention on either starting or reading the conversation.

Conversation content is constrained to a centered chat column. User turns align
right within that column, Claude prose aligns left, and the composer uses the
same width. Debug controls live in a compact Activity menu, with Stop exposed
only while the agent is running.

The page uses the app's existing semantic macOS type scale: `.largeTitle` for the
empty-state greeting, `.body` for composed text, `.callout` for message text, and
`.caption` for debug/status controls. Controls use SF Symbols and standard
SwiftUI buttons.

The composer is intentionally plain: users type the question or instruction they
want, including requests to update the wiki. There is no separate Answer/Update
mode control.

Debug affordances are progressive: "Show internals" and Activity log access
appear once a run exists or is running, instead of occupying the empty Query
state.

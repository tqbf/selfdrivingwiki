# ACP backend + always-ask/yolo permissions

**Status:** Design + spike (in progress). Delivers #286/#287 (always-ask/yolo) and
the first concrete slice of #217 (generalized providers). Replaces the deleted
`edit-permission-modes.md` direction: rather than a prompt-only always-ask, the
approval gate is **structural**, mediated by the Agent Client Protocol.

**References:** `~/work/paseo` (`packages/server/src/server/agent/providers/acp-agent.ts`)
is a production ACP client (TS) implementing exactly this — `ACPAgentSession`'s
`requestPermission` is the pattern we mirror. Swift SDK candidate:
[`wiedymi/swift-acp`](https://github.com/wiedymi/swift-acp) (native macOS, has a
`ClientDelegate.handlePermissionRequest`).

## Why ACP (not prompt-based, not MCP)

ACP defines **`session/request_permission`**: when the agent wants to do
something needing approval, it sends this request to the *client* (the app) and
**blocks until the client responds**. The tool call itself is the pause point.

- This is the **structural** enforcement #287 demands — a write physically cannot
  land until the app approves. No cooperative "please ask first" prompt; no MCP.
- It also gives **provider independence** (#217): the same client talks to any of
  30+ ACP agents (Claude via the `@agentclientprotocol/claude-agent-acp` wrapper,
  Codex, Gemini, Copilot, Goose, …).

## The always-ask/yolo lever

The app is the ACP **client**; its permission delegate is the policy:

- **yolo** → `handlePermissionRequest` auto-resolves with the request's `allow`
  option immediately (today's "writes apply with no review" behavior).
- **always-ask** → surface the `RequestPermissionRequest` (the tool call + its
  options) to the chat UI as an **Approve/Reject** affordance, and **block**
  (return later) until the user decides — exactly paseo's pending-permission +
  `permission_requested` event pattern. On Reject, return `deny`; the agent
  adapts (it already does for denied tools).

Secondary lever (not required for v1): the client advertises `fs.writeTextFile`
and `terminal` capabilities, so file writes / terminal commands are performed by
the *app*, which can refuse them — a second structural gate.

## Architecture

A new `ACPBackend: AgentBackend` conformer (the port in
`Sources/WikiFS/AgentBackend.swift` explicitly anticipates "a future backend
(ACP, Polytoken)"). The launcher already consumes only `AgentEvent` — it never
touches a wire format — so ACP is a new conformer, not a rewrite.

- **Lifecycle:** `Client.launch(agentPath:)` → `initialize(capabilities:)` →
  `newSession(cwd:)` → per-turn `sendPrompt`; `session/update` notifications map
  to `AgentEvent`.
- **Event mapping:** `agentMessageChunk` → agent text; `toolCall` → tool event;
  prompt `stopReason == .endTurn` → **`.messageStop`** (the backend MUST synthesize
  this — the port's turn-boundary contract; the launcher releases the generation
  gate / edit lock / transcript flush off it).
- **Permissions:** `ClientDelegate.handlePermissionRequest` implements the
  always-ask/yolo policy above.
- **Agent selection:** the agent subprocess is **pluggable via the existing
  agent-command config** (`AgentCommandConfig` executable + args = the ACP agent
  spawn, e.g. `npx @agentclientprotocol/claude-agent-acp`, or any ACP agent
  binary). NOT locked to the Zed adapter — the user can point at any ACP agent.

## Modes (future hook)

ACP agents expose modes (`…/session-modes#agent`, `#plan`, `#autopilot`, …) via
`setMode`. A later slice can map always-ask → a plan-style mode and yolo → an
agent/autopilot mode, combining agent-side + client-side gating. Out of scope for
the first slice.

## Caveat

Always-ask enforcement **depends on the agent emitting `request_permission` for
writes.** Most do (Claude via the wrapper, Copilot, …), but paseo's smoke test
explicitly asserts "wrapper emitted no requestPermission" as a failure — so it's
agent-dependent, and yolo is the safe default.

## Slices

1. **Spike (now):** add `swift-acp`; implement `ACPBackend` (lifecycle + event
   mapping + `handlePermissionRequest` with a yolo/auto-allow vs
   always-ask/pending policy); unit-test the event mapping and the permission
   policy (no live agent). Best-effort: boot the configured ACP agent if one is
   available.
2. **Wire-in + UI:** select ACP vs CLI backend; a per-chat always-ask/yolo
   toggle (default yolo); the Approve/Reject affordance fed by the pending
   permission.
3. **Provider generalization (#217):** a provider/agent picker + auth UI.

## Risks

- `swift-acp` is community/early (24 commits). Validate it compiles under
  Swift 6.0 / macOS 15 and that its API matches the README. **Fallback:** hand-roll
  the JSON-RPC/stdio client (paseo + the official TS/Rust SDKs are the protocol
  reference) — more work, but no external dependency risk.
- Live end-to-end testing needs a working ACP agent + credentials; the spike can
  only fully validate behavior where one is installed.

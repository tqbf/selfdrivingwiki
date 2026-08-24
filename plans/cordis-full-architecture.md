# Cordis Full Architecture — Design Record

Status: complete through the composition authority cleanup. The app, daemon,
and CLI boot from profiles. Child profiles supply stable per-wiki capabilities.
Opaque lifetime owners keep Cordis contexts out of normal application code.
`scripts/check-cordis-boundaries` rejects context leaks, untyped services, and
hidden production store factories. Current boundary details are in
`plans/cordis-composition-authority-cleanup.md`.

## Goal

Cordis composes stable headless capabilities with typed contracts, declared
dependencies, and profile lifetimes. It does not own all application objects.

UI models and controllers remain outside Cordis. Active operation state,
framework connections, and pre-profile bootstrap also remain outside Cordis.
Application code receives typed facades and opaque shutdown handles. It does
not receive a `CordisContext`.

## Kernel layers

### 1. Typed events (`Sources/Cordis/EventKey.swift`, `Events.swift`)

- `EventKey<Payload, Mode>` — like `ServiceKey`, identity + label; the payload
  type and dispatch mode are compile-time generics.
- Dispatch modes are marker types, not runtime options:
  - `EmitMode` — sequential, best-effort; listener errors ignored by contract.
  - `SerialMode` — sequential; first listener error propagates.
  - `ParallelMode` — concurrent; all listeners finish; first error propagates.
  - `BailMode` — concurrent; first settled listener decides; rest cancelled.
  - `WaterfallMode` — pass-through chain; a listener calls `next()` to continue
    and may transform the value it received; omitting `next()` short-circuits
    everything downstream and the listener owns the result.
- Registration surfaces:
  - `ActivationContext.on(key, listener)` — staged with the activation
    attempt, committed on success, removed when the component unloads (LIFO).
  - `ComponentHandle.on(key, listener)` — mid-flight, for active components.
  - `CordisContext.on(key, listener)` — ambient, owned by the context.
  - `ListenerHandle.dispose()` removes one listener reversibly.
- Dispatch surfaces: `ctx.emit(key, payload)` (overloads per mode),
  `ctx.waterfall(key, payload) -> Payload`.
- Listener visibility follows the context chain: a child context sees parent
  listeners; a parent does not see child listeners.
- Mid-flight effects: `ComponentHandle.effect(dispose)` registers a committed
  cleanup effect on an active component; disposal stays LIFO.

Events are main-actor-safe by convention: payloads are `Sendable`; UI-facing
re-projection happens in the UI plugin, not the kernel.

### 2. Config schemas + plugin catalog (`Sources/Cordis/PluginDefinition.swift`)

- `PluginConfig` — a `Sendable & Decodable` value type plus a static
  `validate` returning structured `ConfigIssue`s (`ConfigValidation` is the
  declarative builder). Validation runs at mount; boot fails naming the entry
  id and field. Never silently default on failure.
- `PluginDefinition` — plugin id, label, dependencies/provisions, optional
  typed config schema, factory `(validated config) -> ComponentDefinition`.
- `PluginCatalog` — link-time `PluginID → PluginDefinition` registry. No
  dynamic loading in v1; out-of-tree plugins are out of scope.
- Identity split: `PluginID` (catalog/patch identity), `EntryID` (loader row
  identity — two entries of one plugin are independently addressable),
  `ComponentID` (runtime instance identity). Only `PluginID` and `EntryID`
  serialize to YAML.

### 3. Loader (`Sources/CordisLoader/`)

- `Entry { id, plugin, config?, disabled? }`, `PatchFile { entries, remove }`.
- `PatchFileCodec` — natural-shape YAML (Yams) with round-trip tests.
- `PatchResolver.resolve(layers:)` — ordered layers applied to an empty list:
  each bundle in profile order → profile `cordis.patch.yml` → home patch →
  `--patch` overlay. A row replaced by id takes the replacement's whole
  config; `remove` deletes by id.
- `EntryTree` (actor) — mounts/updates/removes entries on a live context;
  diffing is by `EntryID`; a changed row is disposed and re-registered
  (hot-swap foundation). Mount validates config, registers, and requires the
  component to settle `.active`.
- `CordisBoot.boot(.init(catalog:layers:configure:))` — root context, ambient
  facts via `configure`, resolved tree, `BootedProfile.dumpConfig()` is the
  `--dump-config` contract.

## Service key catalog (Phase 4 target)

| Key | Domain | Status |
|---|---|---|
| `ctx.store` | method-atomic `any WikiStore` exception (GRDB backend) | done (`wiki.store`) |
| `ctx.readService` | narrow asynchronous reads through private pooled connections | done (`wiki.read-service`) |
| `ctx.events` | store change signal as Cordis `EmitMode` event | done |
| `ctx.chats` | session log persistence | done (`wiki.sessions` + `wiki.chats-persistence`) |
| `ctx.llm` | model adapter runtime | done (`wiki.llm-runtime` + `wiki.llm-acp-adapter`) |
| `ctx.tools` | tool registry + execution waterfalls | done (`wiki.tools`) |
| `ctx.systemPrompt` | prompt assembly | done (`wiki.system-prompt`) |
| `ctx.agentLoop` / `ctx.agents` | queue worker, chat turn flow | done (`wiki.agent-loop`; QueueEngine/ChatAgentRuntime lifetimes now owned by process-profile leases) |
| `ctx.launcherFactory` | per-wiki launcher pair creation | done (`wiki.launcher-factory`) |
| `ctx.search` | Tantivy + embeddings providers | done (`wiki.search` + adapters) |
| `ctx.renderers` | renderer packages | done (`wiki.renderers` + adapter) |
| `ctx.transport` | daemon XPC/RPC | done (`wiki.transport` + adapter) |
| integrations | Zotero and URL fetch | done (`wiki.integrations` + typed credential and fetch capabilities) |

## Bundles and profiles (Phase 5 target)

- `wikifs-base` bundle: store, sessions, llm, tools, prompt, loop, search,
  extraction, renderer, transport.
- `wikifs-app` profile: adds the SwiftUI shell, File Provider projection,
  settings UI.
- `wikid` profile: headless daemon (no UI plugin).
- `wikictl` profile: CLI + `--dump-config`.
- Bundles ship as `bundles/<name>/cordis.patch.yml` in the repo; user
  profiles live in the App Group container with a `cordis.patch.yml`
  override.

## References

- Kernel lifecycle semantics: `plans/cordis-swift-components.md`.
- Per-domain migration details: `plans/cordis-{daemon-transport,agent-provider,search,renderer,extraction}-services.md`.
- Event listener/disposal test contract: `Tests/CordisTests/CordisEventsTests.swift`.
- Loader/patch contract: `Tests/CordisLoaderTests/CordisLoaderTests.swift`.

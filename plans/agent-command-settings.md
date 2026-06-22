# Configurable Agent Command (Settings → Agent tab)

**Status:** Implemented on `feature/agent-command-settings`. 770 tests pass.

## The problem

The app spawns its maintainer agent via a hardcoded `claude -p` invocation, in
two places:

- The executable name `"claude"` is baked into `AgentLauncher.resolveClaude`
  (`Sources/WikiFS/AgentLauncher.swift:95`), which calls
  `PathPreflight.resolveOnLoginShell(executable: "claude")`.
- The entire argument vector is assembled, fixed, in `OperationCommand.build`
  (`Sources/WikiFSCore/OperationCommand.swift:63-104`) and
  `buildInteractiveQuery` (`:126-158`).

There is no way to point at a different binary, add flags, set environment
variables, or override the model. Concrete needs this blocks:

- running the agent in a **sandbox** (e.g. `sandbox-exec -f profile.sb claude`)
  or via a **wrapper script**;
- setting **extra environment variables** on the spawned process;
- overriding the **model** (e.g. `haiku` instead of the per-op `opus`).

## What the app keeps owning

Not everything is up for grabs. Three parts of the invocation are load-bearing
and stay app-controlled:

- **`-p <prompt>`** — the per-operation prompt is the operation's payload; the
  app must own it.
- **`--output-format stream-json --verbose --include-partial-messages`** — the
  live activity feed (`AgentEventParser`) parses this specific NDJSON schema. Drop
  it and Ingest/Query/Lint still *run*, but the live feed goes silent.
- **`--append-system-prompt <body>`** — the wiki's system-prompt singleton. This
  is *not* redundant with the mount's projected `CLAUDE.md`: the agent's working
  directory is the **per-run scratch dir**, not the mount root, so claude does
  not auto-discover the projected `CLAUDE.md`. The flag is how the maintainer
  schema reaches the agent.
- **`--dangerously-skip-permissions`** and **`--agents <json>`** — structural.

The user controls everything *around* these: the executable, a prefix of
arguments, the model, and extra env. Default config reproduces today's `claude -p
…` run **exactly**, so behavior is unchanged until configured.

## The design: structured fields, not a free-form string

A single editable "command line string" was considered and rejected. The three
needs (env vars, model override, sandbox wrapper) don't fit one argv string
cleanly: env vars are a different channel from argv, and a wrapper is naturally
"executable + a prefix of args." A free-form string would also reintroduce shell
parsing into a code path that is today a clean `[String]` argv with no quoting
bugs. So the Settings → Agent tab exposes **distinct fields**:

- **Executable** — binary or wrapper script (default `claude`). Resolved on the
  login-shell PATH, or used directly if absolute/`./`/`../`; `~` is expanded.
- **Prefix arguments** — tokenized args inserted *before* the standard flags.
  Covers `sandbox-exec -f profile.sb claude` without needing a wrapper script.
- **Model override** — e.g. `haiku`; blank means use the per-op alias.
- **Extra environment variables** — `KEY=VALUE`, one per line.

App-wide (one config for all wikis), not per-wiki — a property of the user's
environment, exactly like `ZoteroConfig`.

### Why app-wide, mirroring `ZoteroConfig`

`ZoteroConfig` (`Sources/WikiFSCore/ZoteroConfig.swift`) is the established
pattern for app-wide, non-secret, JSON-in-the-App-Group-container settings:
pure `Codable` value type, `load(from:)` / `save(to:)`, corrupt-or-missing →
default, atomic pretty-printed write. `AgentCommandConfig` copies that pattern
verbatim (`agent-command-config.json` next to `zotero-config.json`).

## The assembled invocation

```
executable = expandTilde(config.executable)            // "" → "claude"
argv = tokenize(config.prefixArguments)
     + ["-p", prompt,
        "--model", config.modelOverride ?? operation.topLevelModelAlias,
        "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        "--append-system-prompt", systemPrompt,
        "--dangerously-skip-permissions"]
     + (agentsJSON != nil ? ["--agents", agentsJSON] : [])
```

(Interactive Query keeps its distinct `--input-format stream-json` + combined
`--append-system-prompt`; only executable/prefix/model/env change there too.)

Env assembly order matters — app-owned keys must not be clobbered, and a user
`PATH` extension must be preserved while `wikictl` still resolves:

```
env = baseEnv
env.merge(config.extraEnvironment)            // user KEY=VALUE, incl. possibly PATH
env["WIKI_ROOT"] = wikiRoot                    // app-owned, authoritative
env["WIKI_DB"]   = wikiID                      // app-owned, authoritative
let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
env["PATH"] = wikictlDirectory + ":" + path    // wikictl always resolves; user PATH kept
```

With `.default` (executable `claude`, empty prefix/override/env) this is
byte-identical to today's argv + env, so existing `OperationCommandTests`
assertions (`arguments[0] == "-p"`, env keys) keep passing.

## Scope of changes

- **New `Sources/WikiFSCore/AgentCommandConfig.swift`** — the config type
  (`executable` / `prefixArguments` / `modelOverride` / `extraEnvironment`),
  `load`/`save` mirroring `ZoteroConfig`, and a pure `tokenize(_:)` helper
  (whitespace split respecting single/double quotes and `\` escapes) plus
  `~` expansion.
- **`OperationCommand.swift`** — replace the `claudeExecutable: String = "claude"`
  param on `build` and `buildInteractiveQuery` with `command: AgentCommandConfig
  = .default`; implement the argv + env assembly above.
- **`AgentLauncher.swift`** — `init(containerDirectory: URL? = nil)` (optional,
  defaults to `DatabaseLocation.appGroupContainerDirectory()`, so the three
  existing `AgentLauncher()` call sites are unchanged); `resolveClaude` loads the
  config and resolves `expandTilde(config.executable)`; the two build call sites
  (`:424`, `:593`) pass `command:`. Load the config **fresh at spawn time** (not
  cached at init) so Settings changes apply on the next run without a restart.
- **`WikiFSApp.swift`** — the `Settings` scene becomes a `TabView` (Zotero +
  Agent tabs); pass the already-resolved `containerDirectory` to the launcher.
- **New `Sources/WikiFS/AgentCommandSettingsView.swift`** — mirrors
  `ZoteroSettingsView` (`Form` + `.formStyle(.grouped)`, fixed width, explicit
  **Save button that closes the window** — the Zotero rationale: implicit
  on-blur save silently drops edits when the window closes via `⌘W`). Fields:
  Executable, Prefix arguments, Model override, Extra environment variables
  (`TextEditor`), a read-only **resolved preview** (sample command built with
  `ClaudePromptHelp` placeholders + the live config, shell-quoted), and
  **Reset to default**.
- **`ClaudePromptHelp.swift`** — build the Command Template with the *configured*
  executable (currently hardcodes `claudeExecutable: "claude"`), so Help →
  Command Template reflects reality. Promote the private `shellQuoted` /
  `renderCommand` (`:100-111`) to a shared `public` helper so both the Help menu
  and the Settings preview use one quoter.

### Tokenization safety

`tokenize` is a single small pure helper. **No shell is invoked anywhere** — the
argv stays a `[String]`. There is no quoting-injection surface beyond the user's
own machine, and `--dangerously-skip-permissions` is already the trust model.

## Tests

- **New `Tests/WikiFSTests/AgentCommandConfigTests.swift`** — load/save
  round-trip, missing → default, corrupt → default; `tokenize` (quotes, escapes,
  double-space, empty); `~` expansion.
- **`OperationCommandTests.swift`** — update the four `claudeExecutable:` sites to
  `command:`; add cases for custom executable flowing to `.executable`, prefix
  args tokenized and placed before `-p`, `modelOverride` replacing the `--model`
  value, extra env merged, user `PATH` preserved with `wikictl` still prepended,
  `WIKI_ROOT`/`WIKI_DB` authoritative over extra env, and `.default` reproducing
  today's argv exactly.
- `AgentSpawnSlotTests` / `AgentExtractionLockTests` — confirm the optional
  `containerDirectory` init param doesn't break existing construction.

## Non-goals

- **Model override is top-level only.** The large-source `--agents`
  `source-reader` subagent bakes its own `claude-sonnet-4-6` into the JSON
  (`IngestPlan.swift:101`), independent of `--model`. Setting `haiku` makes the
  curator/query/lint top level run on Haiku; the digesters stay Sonnet.
  Acceptable for the stated need; flagged.
- **Not per-wiki.** App-wide config, like Zotero. Easy to move per-wiki later if
  needed.
- **No comment/doc sweep.** `claude -p` appears in many historical comments;
  updates are limited to the modified files. `PROGRESS.md` / `PLAN.md` prose is a
  historical record and is left as-is.

## Verification

1. `swift build`.
2. `swift test --filter OperationCommandTests` — existing argv/env assertions
   pass with `.default`; new config cases pass.
3. `swift test --filter AgentCommandConfigTests`.
4. `swift test --filter AgentSpawnSlotTests AgentExtractionLockTests`.
5. `swift test` — full suite green.
6. **Manual (`make run`):** Settings → Agent → set executable `sandbox-exec`,
   prefix `-f /Users/me/sdw/sandbox.sb /opt/homebrew/bin/claude`, model `haiku`,
   one env var → Save → confirm the resolved preview, then run a Query and verify
   the spawned argv (per-run `run.jsonl` / Help → Command Template) reflects the
   config. Reset to default → confirm a normal Query still runs as before.

## Skills

Per project `CLAUDE.md`, apply `swiftui-pro`, `typography-designer`, and
`macos-design` when authoring `AgentCommandSettingsView` and the `TabView`
Settings scene — consistent type scale/hierarchy, modern macOS Settings idioms,
kept simple.

* For all coding tasks use your judgement to decide an appropriate lower
  power model and run that in a subagent.

* Keep a master PLAN.md as an index to the documentation you make for this codebase.

* Store specific in-depth documentation in plans/whatever.md.

* Record progress in PROGRESS.md. I should be able to tell a future agent "read PLAN.md and
PROGRESS.md" and trust it's up to speed with this codebase.

* Before and after deciding on code, use the swiftui-pro skill to ensure we're following
  modern best practices.

* When setting type, use the typography-designer skill to make sure we're using consistent
  type scales with a sensible visual hierarchy. Pay attention to type weight and emphasis.

* Use the macos-design skill to make sure the UI we come up with makes sense as a modern
  macOS app, with modern professional macOS idioms. Keep things simple.

## Design skills — sources

The three design skills above are vendored in this repo at
`docs/skills/` (central skills directory, symlinked as `.polytoken/skills/`
and `.claude/skills/`). They originate from
these public Agent Skills repos; the `npx` / `/plugin` commands are for Claude
Code and other agents — NOT Polytoken — included for provenance:

- **swiftui-pro** — https://github.com/twostraws/swiftui-agent-skill
  (`npx skills add https://github.com/twostraws/swiftui-agent-skill --skill swiftui-pro`)
- **macos-design** — https://github.com/ceorkm/macos-design-skill
- **typography-designer** (upstream name `typography`) —
  https://github.com/petekp/claude-code-setup (`skills/typography/`)

> Caveat: swiftui-pro targets iOS 26 / Swift 6.2; this app is macOS 15 /
> Swift 6.0 — filter version-gated guidance. macos-design & typography
> express values in CSS/web terms — translate to SwiftUI
> (`.regularMaterial`, points, `Font`, system faces).

## Engineering skills — sources

The following engineering skills are also vendored under `docs/skills/`. Same
provenance convention as above (the `npx` / `/plugin` commands are for other
agents, NOT Polytoken):

- **swift-concurrency-pro** —
  https://github.com/twostraws/Swift-Concurrency-Agent-Skill
- **swift-testing-pro** —
  https://github.com/twostraws/Swift-Testing-Agent-Skill
- **swiftui-ui-patterns** — https://github.com/Dimillian/Skills
- **swiftui-performance-audit** — https://github.com/Dimillian/Skills
- **macos-spm-app-packaging** — https://github.com/Dimillian/Skills

> Same caveat: these target recent iOS/macOS toolchains. Filter
> version-gated guidance to macOS 15 / Swift 6.0. The `macos-spm-app-packaging`
> **release/notarize** references and `assets/templates/` are for a future
> shipping path — this project is local-only / dev signing today, so only its
> **scaffold** reference is immediately actionable.

* When touching anything that crosses the main actor — background tasks,
  `Sendable` boundaries, `AsyncStream`, or any off-main compute (e.g. MLX
  embeddings) — consult
  [`docs/skills/swift-concurrency-pro/SKILL.md`](docs/skills/swift-concurrency-pro/SKILL.md)
  (see its `actors`, `structured`/`unstructured`, `cancellation`, and
  `bug-patterns` references). This is the skill behind the SQLite
  single-threaded invariant below.

* When writing or reviewing tests, follow
  [`docs/skills/swift-testing-pro/SKILL.md`](docs/skills/swift-testing-pro/SKILL.md)
  (core-rules, async-tests, migrating-from-xctest). Prefer Swift Testing over
  XCTest for new tests.

* When a SwiftUI view is slow, janky, or you suspect unnecessary diffing /
  re-rendering, run the audit in
  [`docs/skills/swiftui-performance-audit/SKILL.md`](docs/skills/swiftui-performance-audit/SKILL.md)
  (code-smells, profiling-intake, Instruments, hangs) **before** guessing.
  For the concrete view/containers involved (NavigationStack, sheets, forms,
  split views, async-state), cross-reference
  [`docs/skills/swiftui-ui-patterns/SKILL.md`](docs/skills/swiftui-ui-patterns/SKILL.md).

* When a feature passes tests but fails in the running app (and you can't see the
  screen), follow [`docs/skills/reproducing-live-ui-bugs/SKILL.md`](docs/skills/reproducing-live-ui-bugs/SKILL.md):
  read the real data, host the real view in an `NSWindow` test, instrument every
  seam via `os_log`, and read the trace back with `log show`.

* When the app quits with **no crash report** (no new `.ips`, just an exit
  code — e.g. a silent `exit()`/`abort()` from a C/C++ dependency, or a failure
  that reproduces only via `open`/LaunchServices), `os_log` is structurally
  blind to it. Follow
  [`docs/skills/debugging-with-lldb/SKILL.md`](docs/skills/debugging-with-lldb/SKILL.md):
  attach to the `open`-launched process with `process attach -n <NAME> -w`,
  break on `exit`/`abort`/`__assert_rtn` (scoped to `libsystem_c.dylib`), and
  read the stack at the moment of death. Reach for this *before* rebuild-and-
  guess when there's no `.ips`.

* **SQLite concurrency (graph-model Phase 0): the store is method-atomic —
  every `SQLiteWikiStore` entry point holds an internal recursive lock; writes
  still flow through the `@MainActor` model; off-main reads go through
  `WikiReadPool`.** Multi-step writes compose via `withTransaction` (savepoint
  nesting — never raw `BEGIN`), and no statement handle or column pointer may
  cross a method boundary. Every stepped `SQLiteStatement` must be covered by
  `defer { stmt.reset() }` — a statement left at `SQLITE_ROW` pins the
  connection's WAL read snapshot, causing stale reads and `BEGIN IMMEDIATE`
  failures after external writes (#332). Never run inference/network inside a
  transaction, and never pool `init(databaseURL:)` connections (that init
  writes; read-only pools use `init(readOnlyURL:)`). Follow
  [`docs/skills/sqlite-concurrency/SKILL.md`](docs/skills/sqlite-concurrency/SKILL.md)
  and `plans/graph-model-and-versioning.md` §8; regression suite:
  `swift test --filter StoreConcurrencyTests`.

* **Change signaling (#129 slice 2a): the store emits at the write seam; the
  File Provider + the model subscribe — there is no hand-fired `onPageDidChange`
  anymore.** Every public mutating method on `SQLiteWikiStore` routes its body
  through `mutate(event:_:)`, which emits one `ResourceChangeEvent` onto the
  per-wiki `WikiEventBus` strictly AFTER the recursive lock is released at its
  own depth-0 (compute-while-locked, flush-after-unlock). **Load-bearing
  invariant: every NEW public mutating method MUST route through `mutate()` and
  emit a `ResourceChangeEvent`, or be explicitly annotated no-emit with a reason
  (derived embeddings, search index, migrations)** — otherwise the File Provider
  silently goes stale (and a future kind-specific subscriber misses the change).
  `StoreEmissionExhaustivenessTests` enforces this (parses every `public func`,
  asserts the EMIT/READ/NO-EMIT partition is complete and every EMIT member calls
  `mutate(`). Adding a new public mutator? Route it through `mutate()` or the
  guard fails. See `plans/event-bus.md`.

* Never use `print` for diagnostics — route all logging through `DebugLog`
  (`os_log` → Console.app, subsystem `com.selfdrivingwiki.debug`) so it's visible
  no matter how the app launched. The only exception is real CLI stdout (e.g.
  `wikictl`'s command output).

* Never commit or push directly to `main`. Always work on a feature branch, push
  the branch, and open a PR. You may push PR branches but MUST NOT merge them to
  main yourself.

* Never pipe literal markdown or multi-line content into `gh pr edit --body` —
  the shell mangles the formatting. Use plain text for the inline body, or write
  the body to a file first and use `gh pr edit --body-file <file>`.

## Agent prompts

Agent-facing prompts (the system prompt, write rules, extraction prompts, the
tree-render map, etc.) are authored as real markdown in `prompts/*.md` and
codegen'd into the checked-in `Sources/WikiFSCore/GeneratedPrompts.swift` by
`tools/promptgen`. After editing any `.md`, run `make prompts` and commit both
the `.md` and the regenerated `.swift`. CI runs `make check-prompts` and fails
on drift, so a stale generated file blocks the build.

## Local data — finding the SQLite wiki databases

**The SQLite DB is the source of truth.** Every wiki is one `<ulid>.sqlite` file in
the **App Group container** (`~/Library/Group Containers/<appGroupID>/`). The
`pages/`, `sources/`, `indexes/` folders you may see elsewhere (e.g. an iCloud
Drive folder) are the **File Provider's read-only filesystem projection** — a
mirror of the DB, not the data store. Don't dig through those for chat/page data;
read the DB.

**The container path is per-developer.** `appGroupID` resolves at runtime
(`Sources/WikiFSCore/WikiIdentifiers.swift`), first hit wins:

1. env `WIKI_APP_GROUP_ID`
2. Info.plist key `WIKIAppGroupID` (injected by `build.sh`)
3. sidecar `wiki-identifiers.env` beside the executable
4. `signing/local.config` key `APP_GROUP` (gitignored, per-developer)
5. compiled default `group.org.sockpuppet.wiki`

So the literal path is `~/Library/Group Containers/<that id>/<ulid>.sqlite`.
`wikis.json` in the same container is the registry: it maps display name → ULID
(see `Sources/WikiFSCore/WikiRegistry.swift`). The legacy single-wiki DB is
`WikiFS.sqlite`. The DB runs in WAL mode, so expect `<ulid>.sqlite`,
`-wal`, and `-shm` sidecars.

**⚠️ TCC gotcha — the container is protected.** A plain shell gets
`Operation not permitted` / `authorization denied` on `ls`, `cat`, and even
`sqlite3` against files in the container. To read the DB you must either give the
terminal/daemon process **Full Disk Access** (System Settings → Privacy &
Security), or read it through the app / bundled `wikictl` (which has access).

**Quick locator that works regardless of developer** (needs FDA on the shell):

```bash
# Resolve THIS machine's app-group id from the built app (or signing/local.config).
defaults read "$(mdfind -name WikiFS.app | head -1)/Contents/Info" WIKIAppGroupID \
  2>/dev/null || grep '^APP_GROUP=' signing/local.config | cut -d= -f2 | tr -d '"'
# Then list the wikis and open one.
C="$HOME/Library/Group Containers/$(…resolved id…)"
cat "$C/wikis.json"                      # registry: name → ULID
sqlite3 "$C/<ulid>.sqlite" ".tables"     # pages, chats, chat_messages, …
```

Schema lives in `Sources/WikiFSCore/SQLiteWikiStore.swift`
(`createFreshSchemaV20` / `createChatTablesV23` / the `migrate(from:)` ladder).
Persistent chats are two tables: `chats` (one row per conversation) and
`chat_messages` (one row per persistable `AgentEvent`) — see
`plans/chat-and-persistence.md`.

## Testing

**Swift** (from repo root):
```
swift build          # compile
swift test           # full suite (run locally before merge)
# fast tier — what the CI `swift` job runs; skips the slow SQLite integration suites:
swift test --skip 'EnumeratorDeletionTests|SQLiteWikiStoreTests|StoreEmissionTests|FreshSchemaParityTests|SQLiteStatementLifecycleIntegrationTests|BlobVacuumTests|AgentCASTests|GenerationGateLaneTests|WorkspaceStagingTests|WorkspaceMergeCompletenessTests|IngestIsolationTests'
swift test --filter PdfExtractionServiceTests  # pdf extraction only
```

CI runs **two Swift jobs** (issue #364):
- **`swift`** (fast tier, issue #292) — skips the slow SQLite integration
  suites for quick PR feedback. These suites open real databases and dominate
  runtime (notably `ProjectionTreeTests` working-set tests at 165s+ each, #291).
  They are tagged `.integration` (`Tests/WikiFSTests/TestTags.swift`); `swift
  test` does not yet filter by tag, so the fast tier skips them by name.
- **`swift-integration`** — runs the full `swift test` (no skip), so the
  integration suites (and any AC tests in them) gate merges. **Promote this
  job to a required status check in branch protection** so a failing AC test
  blocks merge. Still run `swift test` locally before merging for fast iteration.

To mark a new slow suite, add `.tags(.integration)` AND append its name to the
fast-tier `--skip` regex in `.github/workflows/ci.yml` (it will still run in
the `swift-integration` job).

**Python / pdf2md** (from `tools/pdf2md`):
```
uv run pytest tests/                                     # unit + fast integration (60, never hangs)
uv run pytest tests/test_vlm.py -v                       # VLM pipeline (slow, needs real PDF + ~2 GB model)
uv run ruff check pdf2md tests/                          # lint
uv run pyright pdf2md tests/                             # type check
```

Python tests are NOT in CI — run them manually when changing pdf2md or PdfExtractionService.
- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

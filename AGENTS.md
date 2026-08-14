Last verified: 2026-08-13

* Running `/graphify` is always permitted, including from read-only branches or other read-only repository states, when `tmp/graphify-out` is specified as the output directory.

* **All Swift code must compile via SwiftPM from the command line — prefer
  `make build` / `make test` as the default entrypoints, and ensure bare
  `swift build` / `swift test` also work when used directly. Never rely on
  Xcode-only tooling or APIs.**
  In practice this means: no macros or APIs that require an Xcode project
  file, an Xcode-managed scheme, or Xcode's build system to resolve (e.g.
  avoid `@Entry` for `EnvironmentValues`/`FocusedValues` — use the manual
  `EnvironmentKey`/`FocusedValueKey` pattern instead). If a feature only
  builds inside Xcode, it doesn't belong in this codebase.

* For all coding tasks use your judgement to decide an appropriate lower
  power model and run that in a subagent.

* Keep a master PLAN.md as an index to the documentation you make for this codebase.

* Store specific in-depth documentation in plans/whatever.md.

* **Supported platform and required gates:** Self Driving Wiki supports macOS
  only. Required SwiftPM build/test gates and the required `swift` workflow job
  run on macOS; Linux portability is an optional Apple Container/Docker
  diagnostic and is not a product gate.

* Record progress in `progress/`. I should be able to tell a future agent
  "read PLAN.md and progress/" and trust it is up to speed with this codebase.

* `PLAN.md` and `PROGRESS.md` document features and design-relevant refactorings only.
  Do not add bug-fix entries to either file.

* When writing prose, use the ste-writing skill to ensure clarity.  This applies to pull requests, 
  github issues, plans in the plans folder, and progress in PROGRESS.md.

* Before and after deciding on code, use the swiftui-pro skill to ensure we're following
  modern best practices.

* When setting type, use the typography-designer skill to make sure we're using consistent
  type scales with a sensible visual hierarchy. Pay attention to type weight and emphasis.

* Use the macos-design skill to make sure the UI we come up with makes sense as a modern
  macOS app, with modern professional macOS idioms. Keep things simple.

## Modeling rules

* **Page and source IDs are separate namespaces.** Use `PageID` for rows in
  `pages` and `SourceID` for rows in `sources`; construct either from raw text
  only at persistence or external-format boundaries. Source content-version
  IDs, source Markdown-version IDs, and chat IDs remain `PageID` until their
  own namespace migrations. Mixed targets use tagged enums such as
  `BookmarkNode.Content`. The raw ULID strings and existing JSON, SQLite,
  wiki-link, File Provider, CLI, and staging formats are compatibility
  contracts; see `plans/page-source-id-separation.md`.

* **Avoid stringly-typed variables.** A bare `String` (or `String?`) that
  actually means "a chat id" / "a queue item id" / "a provider name" makes two
  different id spaces compare equal, lets a typo pass the type checker, and
  gives the reader no idea what values are legal. Wrap it: a `RawRepresentable`
  struct (`PageID`) when it's one id space, an `enum` when it's a closed set of
  cases, and a **namespaced enum** when one field must carry ids from several
  spaces (`TranscriptID.chat(PageID)` / `.queueItem(QueueItem.ID)` — the case
  tag is what makes a chat ULID unable to collide with a queue ULID). Same for
  file paths (`URL`), durations (`Duration`), and raw enum-backed strings —
  convert at the boundary, not at every use site.

  **A sentinel string is the same smell.** `ChatSessionKey.draft` /
  `.chat(PageID)` replaced a `String` key whose draft was spelled
  `"__wiki_draft_chat__"`: that sentinel shared a namespace with real chat
  ULIDs, so "is this the draft?" was a comparison against a magic constant that
  every call site had to remember. Give the special case its own case, and the
  compiler asks the question for you — `.draft` carries no `PageID`, so a draft
  cannot satisfy an id comparison even by accident.

* **Prefer enums (or named constants) over magic numbers.** A bare literal at a
  use site — `if attempt > 3`, `rowHeight = 36`, `case 2: …` — hides both its
  meaning and the fact that the same number is load-bearing somewhere else. If
  it names one of a closed set of choices, make it an `enum`; if it's a tuning
  value, hoist it to a named `static let` in the type or metrics enum that owns
  it (`ChatMetrics`, `PageEditorMetrics`) so the name carries the rationale and
  there is exactly one place to change it. The same goes for raw values
  crossing a boundary: decode into an `enum` at the edge rather than comparing
  integers or strings downstream.

* **Prefer a finite state machine over a cluster of flags.** Several
  `Bool`/optional properties that are really one lifecycle are a denormalized
  enum: they can encode impossible combinations, and every write site has to
  remember to update all of them coherently (see `ChatRunState`, which replaced
  `isRunning`/`isGenerating`/`isAwaitingGenerationSlot`/`isInteractiveSession`/
  `activeChatID` after a missed write in one of them shipped a bug). Model the
  states as an `enum`, make it the single stored source of truth, and derive
  the flags as computed properties — impossible states stop being
  representable, and a missed write site becomes a compile error rather than an
  incoherent runtime state.

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
- **conventional-commits** — https://www.conventionalcommits.org/en/v1.0.0/
- **conventional-branch** — https://github.com/github/awesome-copilot/blob/main/skills/conventional-branch/SKILL.md

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

* When creating or reviewing Git commits, follow
  [`docs/skills/conventional-commits/SKILL.md`](docs/skills/conventional-commits/SKILL.md)
  for the commit type, scope, description, body, footer, and breaking-change
  format.

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

* **Swift async bridging of nullable Objective-C object returns can trap
  (`EXC_BREAKPOINT`/`SIGTRAP`) instead of throwing (#756).** When an Obj-C
  method's completion handler is `(NSURL?, NSError?)` (or any nullable object
  pointer: `URL?`, `Array?`, `Dictionary?`), Swift's `async` bridge imports it
  as a **non-optional** `async throws -> URL` and routes nil through
  `<Type>._unconditionallyBridgeFromObjectiveC(_:)`, which **traps before the
  `throws`/`try` machinery can intervene** — an uncatchable runtime death, not
  a catchable error. `try await`, `CheckedContinuation` wrappers, and timeouts
  give **no protection**; the trap is before they run.
  - **The rule:** before `await`ing an Apple `async` API whose bridged return is
    a non-optional `URL`/`NSURL` (or non-optional `Array`/`Dictionary` where the
    underlying completion is nullable), check Apple's docs for nil as a
    documented return. If nil is possible, **use the completion-handler overload
    directly** and branch on the `URL?`:
    ```swift
    // BAD — traps on nil:
    let url = try await manager.getUserVisibleURL(for: id)
    // GOOD — nil becomes a recoverable error:
    manager.getUserVisibleURL(for: id) { url, error in
        if let url { resume(.success(url)) }
        else { resume(.failure(error ?? MyError.urlNil)) }
    }
    ```
  - **Known-affected families to watch for:** `NSFileProviderManager.getUserVisibleURL(for:)`
    (fixed at `FileProviderFacade.userVisibleURL`), `FileManager.url(for:in:appropriateFor:create:)`,
    `NSItemProvider.loadObject(ofClass:)`/`loadItem(forTypeIdentifier:)`, and any
    future `NSFileProviderManager`/`NSFileCoordinator` API returning a nullable URL.
    `Void`-returning bridges (`add(domain)`, `remove(domain)`) are safe; `[NSFileProviderDomain]`
    array bridges fail-soft to `[]` in this codebase (already wrapped in `try?` + `?? []`).
    `FileProviderExtension` overrides are server-side callbacks *we implement* with the
    completion-handler signature — no async bridge, no trap surface.
  - Audit recipe if a new unexplained `EXC_BREAKPOINT`/`SIGTRAP` appears: `rg -n 'try await .*(getUserVisibleURL|urlForItem|url\(for:|loadObject|loadItem)' Sources/`
    and look for any non-optional `URL` await where the Obj-C completion is `(NSURL?, …)`.
    See `plans/fileprovider-crash-fix.md` for the full root-cause writeup.

* **Never block the cooperative thread pool in tests — `Process.waitUntilExit()`,
  `Thread.sleep`, `DispatchSemaphore.wait` on a `Task.detached` body, and bare
  `withCheckedContinuation` with no timeout can all hang `swift test` under
  `--parallel` (#664, #732, #926, #1051).** The cooperative thread pool is
  finite (as few as 3 on CI). A synchronous blocking call parks the pool thread
  it runs on; enough concurrent blockers exhaust the pool, and other suites'
  `withCheckedContinuation` completions can't be delivered — the whole `swift
  test` process hangs with no diagnostic. `.timeLimit` can't rescue this: it
  cancels the test's `Task`, but cancelling a Task does NOT resume an abandoned
  continuation.
  - **The rule:** every test that waits on a subprocess or a continuation must
    (a) use the non-blocking `terminationHandler` + `withCheckedContinuation`
    pattern instead of `Process.waitUntilExit()`, (b) race the continuation
    against a timeout so a starved pool produces a fast, diagnosed failure
    instead of an infinite hang, and (c) annotate the suite with
    `@Suite(.serialized, .timeLimit(.minutes(N)))`.
  ```swift
  // BAD — parks a cooperative thread; starves the pool under --parallel:
  process.waitUntilExit()

  // BAD — hangs forever if the completion is starved off the pool:
  await withCheckedContinuation { cont in process.terminationHandler = { _ in cont.resume() } }

  // GOOD — non-blocking, and a timeout turns starvation into a fast failure:
  try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
              if !process.isRunning { cont.resume(); return }
              process.terminationHandler = { _ in cont.resume() }
          }
      }
      group.addTask { try await Task.sleep(for: .seconds(30)) }
      _ = try await group.next()
      group.cancelAll()
  }
  ```
  - **Audit recipe:** `rg -n 'waitUntilExit|Thread\.sleep|DispatchSemaphore.*wait|withCheckedContinuation' Tests/`
    and confirm every hit is either non-blocking, timeout-bounded, or in a
    `.serialized` + `.timeLimit` suite. See #1051 for the full root-cause
    writeup; regression watchdog: `scripts/test-with-watchdog.sh`.

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

* **Never write SwiftUI state synchronously from an `NSViewRepresentable`'s
  `makeNSView`/`updateNSView`, or from anything reachable from them.** Both run
  inside SwiftUI's update pass, so a `@State`/`@Binding` write there is
  "Modifying state during view update, this will cause undefined behavior."
  `WikiReaderView.Coordinator.startLoad` wrote `isLoading.wrappedValue = true`
  from `makeNSView` and warned on *every* reader mount.
  - **The trap is indirection.** AppKit setters post delegate notifications
    **synchronously**, so the write is often several frames deep and not visible
    at the call site: `textView.string = …` → `textViewDidChangeSelection` →
    `onCaretChange` → `@State`. Assigning `.string`, `setSelectedRange`,
    `selectRowIndexes`, and friends all do this. Wiring `delegate` *before*
    seeding content in `makeNSView` is the classic way to trip it.
  - **The rule:** in a Coordinator, either **defer** the write
    (`Task { @MainActor in … }` — see `ComposerTextView.Coordinator.recomputeHeight`)
    or **suppress** it while you are the one mutating the view (an
    `isApplyingProgrammaticChange` flag bracketing the mutation, with the
    write-back path gated on it — see `ScrollableTextEditor`). Programmatic
    mutation is not user input; don't report it back into SwiftUI.
  - **These are runtime issues, not compile warnings.** They appear in no build
    log, and `swift test` does not display them, so a clean build and a green
    CLI test run are *not* evidence they're absent. Capture and bisect procedure:
    [`docs/skills/reproducing-live-ui-bugs/SKILL.md`](docs/skills/reproducing-live-ui-bugs/SKILL.md)
    §"SwiftUI runtime issues".

* Never use `print` for diagnostics — route all logging through `DebugLog`
  (`os_log` → Console.app, subsystem `com.selfdrivingwiki.debug`) so it's visible
  no matter how the app launched. The only exception is real CLI stdout (e.g.
  `wikictl`'s command output).

* Never use bare `try?` to swallow errors silently — it hides failures and has
  already caused lost transcripts (`QueueStore.swift:156-160`) and misattributed
  queue items (#475). Use `do { try … } catch { DebugLog.store(…) }` (or the
  appropriate `DebugLog` channel) so the failure is at least visible in
  Console.app. If ignoring the error is genuinely correct, add a comment saying
  why.

* Never commit or push directly to `main`. Always work on a feature branch, push
  the branch, and open a PR. Agents may prepare, push, open, review, and report
  PR readiness. The operator owns the merge decision. Only the operator may
  enqueue the exact approved PR head in the GitHub merge queue. Agents MUST NOT
  enqueue a PR, enable auto-merge, merge directly, or change issue state. GitHub
  may merge only after the operator enqueues the approved PR head.

* When creating or naming a branch, follow
  [`docs/skills/conventional-branch/SKILL.md`](docs/skills/conventional-branch/SKILL.md).
  Use `feature/` (or `feat/`), `bugfix/` (or `fix/`), `hotfix/`, `release/`, or
  `chore/`, followed by a lowercase kebab-case description. The installed
  `pre-push` hook enforces the machine-checkable naming rules for pushed refs.

* Never pipe literal markdown or multi-line content into `gh pr edit --body` —
  the shell mangles the formatting. Use plain text for the inline body, or write
  the body to a file first and use `gh pr edit --body-file <file>`.

* **Scratch files go in `tmp/` (project-relative, gitignored), NOT `/tmp`
  (system temp).** Writing to `/tmp` may require auto-approve permission in
  sandboxed agent runtimes; `tmp/` is inside the project and always writable
  without approval. Use `tmp/` for plan docs, PR drafts, issue bodies, debug
  output, and any other throwaway artifacts. The directory is gitignored
  (`.gitignore` line 24) so nothing lands in the tree.

## Agent prompts

Agent-facing prompts (the system prompt, write rules, extraction prompts, the
tree-render map, etc.) are authored as real markdown in `prompts/*.md` and
synced to `Sources/WikiFSCore/Resources/Prompts/` by `make prompts`. They are
declared as SwiftPM resources (`.copy(["Resources/Prompts"])` in Package.swift)
and loaded at runtime via `Bundle.module` (see `PromptLoader.swift`). After
editing any `.md` in `prompts/`, run `make prompts` to sync the copy in
Resources; both the source and the resource copy are committed.
`make build`/`check`/`test` sync automatically as a prerequisite; bare
`swift build` does NOT — run `make prompts` first (CI runs `make version
prompts` before `swift build`). The same applies to `GeneratedVersion.swift`
(git state, regenerated by `make version`; never committed, so it can't drift).

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
5. compiled default `group.org.sockpuppet.wiki` — **reaching this leg is a
   hard error, not a fallback.** Legs 1–4 are each somebody stating an id; leg
   5 is nobody having stated one, and the constant is the upstream author's
   real registered App Group. `DatabaseLocation.appGroupContainerDirectory()`
   throws `WikiIdentifiersError.unconfiguredAppGroupID` rather than creating a
   container under it. It used to create one silently, which read an empty
   registry and wrote config to the wrong place — see
   `progress/2026-08-14T010000Z-app-group-fail-fast.md`.
   `wikictl version` prints the resolved id and which leg produced it.

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
make build           # preferred compile path; runs repo prerequisites first
make test            # preferred full suite — ~1.5 min via in-memory SQLite fixtures (#658)
swift test --filter PdfExtractionServiceTests  # targeted SwiftPM test run when needed
```

Prefer `make build` / `make test` over raw `swift build` / `swift test` for
normal local work, because the Make targets run the repo's prerequisite sync
steps automatically. `make test` runs the full suite in ~1.5 minutes
(in-memory fixtures since #658). Run it before every PR. CI has a single
`swift` job that runs the full suite — there is no tier split and no skip list
anymore (the slow disk-I/O they worked around is gone).

**Mutation testing** (`swift-mutation-testing`, schematized — builds once,
test-runs every mutant via a runtime switch):
```
make mutate                                       # full run (all sources)
make mutate-scope SOURCES_PATH=Sources/WikiFSTypes   # scoped to a directory
```
Config lives in `.swift-mutation-testing.yml`. Install the tool once:
`brew install ericodx/homebrew-tools/swift-mutation-testing`. Reports
(`mutation-report.json` etc.) and the cache are gitignored. Not in CI — run
manually when changing hot logic (relational / boolean / arithmetic mutators).

Budget ~10 min of cold sandbox build before the first mutant runs (the tool
copies the repo without `.build`), then ~9s per mutant. A `Sources/WikiFSTypes`
scope is ~30 min for 72 mutants (87.1%, stock 1.3.0).

`Sources/WikiFSTypes/MutationTestingSupport.swift` is **load-bearing and must
not be deleted**. The tool rewrites mutated function bodies into
`switch __swiftMutationTestingID { case "<id>": … default: … }` and references
that symbol unqualified, so it has to be in scope in every mutated module. The
tool injects its own copy into the alphabetically-first `Sources/` directory —
here `CSQLite`, a `.systemLibrary` target SPM compiles no sources for — so
without our own declaration every mutant fails to compile and reports
`Unviable` (#823, #860). `make mutate` guards this, and also rejects a
locally-patched `0.0.0-dev` tool build, which declares a *second* copy in
`WikiFSTypes` and re-breaks the run via duplicate declaration.

Read survivors with the noise in mind: `RemoveSideEffects` on `os_log` wrappers
and on lock acquire/release is unkillable by construction, not a test gap
(that's why `DebugLog.swift` is excluded). Real signal looks like the
`ULID.swift` survivors — `*1000` → `/1000` and `ms == lastTimestamp` → `!=`
both surviving means nothing pins timestamp encoding or same-millisecond
monotonicity.

**Python / pdf2md** (from `tools/pdf2md`):
```
uv run pytest tests/                                     # unit + fast integration (60, never hangs)
uv run pytest tests/test_vlm.py -v                       # VLM pipeline (slow, needs real PDF + ~2 GB model)
uv run ruff check pdf2md tests/                          # lint
uv run pyright pdf2md tests/                             # type check
```

Python tests are NOT in CI — run them manually when changing pdf2md or PdfExtractionService.
- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

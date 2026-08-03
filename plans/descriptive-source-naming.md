# Ingestion Run Transcript Artifacts — `plan.json` & `source-<N>.<ext>` Naming

Investigation of the agent/ingestion **run transcript** the SelfDrivingWiki app
materializes on disk. Two questions: (Q1) is `plan.json` still needed? (Q2) why
are sources named `source-<N>.<ext>` and how to improve it?

**Status: investigation + recommended plan only. No repo file modified, no commit.**
All scratch output lives under `tmp/` (gitignored, `.gitignore:24`).

Evidence base: a concrete run transcript at
`~/Library/Caches/Self Driving Wiki-agent/01KXYPNX5TRVDEXVT3YFGA3Z3S/runs/2026-07-20T02:46:29.547Z/`
plus repo source/tests (macOS 15 / Swift 6.0, ACP-only agent backend).

---

## Architecture refresher — what the run transcript IS

Large-source ingest is a **three-phase multi-process ACP pipeline**
(`runACPIngestPlannerExecutors`, `AgentLauncher.swift:1357`):

1. **Planner** (Opus) — reads staged sources + `WIKI_STATE.md`, decides the page
   set, and writes `plan.json` into the scratch dir. Writes **no** wiki pages.
2. **Executors** (Sonnet) — one executor per distinct `sourceFile`. Each reads
   `plan.json`'s subset for its source, reads that source's byte range, and
   writes pages via `wikictl page add`.
3. **Finalizer** (Opus) — writes `index.md` + appends `wikictl log` entries.

The run dir is the shared scratch these phases read/write. `plan.json` is the
**handoff artifact** between phase 1 and phase 2. Source files are staged into
the same dir before phase 1 starts.

`run()` decides single-phase vs multi-phase at `AgentLauncher.swift:1196`:
`.ingest(... plan.isLargeSource)` → planner/executors; otherwise the one-shot
`ingest-single-task` prompt in a single session (no `plan.json`).

---

## Q1 — Is `plan.json` still needed?

### Verdict: **CONSUMED and load-bearing — NOT obsolete.**

`plan.json` is NOT a vestigial pre-written artifact. It is the **output of the
planner phase** and the **input to the executor dispatch**. Removing it would
break large-source ingest.

### The actual `plan.json` shape (from the real run)

```json
{
  "pages": [
    {
      "title": "Neuralwatt Flex Tier",
      "sourceFile": "source-1.html",          // references a staged source leaf
      "sourceRanges": "lines 925-1164 (…)",
      "outline": "Summary page for the Flex Tier feature: …"
    },
    { "title": "Neuralwatt MCR Context Drop Protocol", "sourceFile": "source-2.txt", … },
    { "title": "Neuralwatt Cloud", "sourceFile": "source-1.html", … }
  ],
  "sourceIDs": ["01KXYMP7J6HZ3E34ZZX02HKS1F", "01KXYMKF1EF820Y5KZ6FTBAQRS"]
}
```

Schema: `ACPIngestPlan` / `ACPIngestPageAssignment`
(`Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:19-53`).

### Writers (it is written BY THE AGENT, not by the app)

The app does **not** pre-write `plan.json`. The **planner LLM** writes it, per
the planner prompt (`prompts/ingest-planner.md:26`):

> 5. Write your plan to `plan.json` in your current working directory using this
> EXACT JSON schema … Write ONLY `plan.json` and stop.

- Prompt builder: `ACPIngestPrompts.plannerPrompt(...)`
  (`ACPIngestPlan.swift:141-160`) — fills `GeneratedPrompts.ingestPlanner`.
- In tests, a fake planner writes it: `FakeAgentBackend.swift:103-105`
  (`behavior.planJSON` → `scratch/plan.json`).

So there is **no app-side "plan writer" to remove**. The operator's hypothesis
("the app pre-writes a plan.json") is factually wrong — the *agent* writes it.

### Readers (the app reads it back to dispatch executors)

- `ACPIngestPlan.load(from:)` — `ACPIngestPlan.swift:123-129`
  (`directory.appendingPathComponent("plan.json")`).
- Consumed at `AgentLauncher.swift:1503`:
  `guard let plan = ACPIngestPlan.load(from: scratch) else { … fallback … }`.
  If absent/invalid → falls back to single-session `runACPIngestFallback`
  (`:1506`). So a missing plan is gracefully handled, but a *valid* plan drives
  the whole executor fan-out.
- The plan's `distinctSourceFiles` (`ACPIngestPlan.swift:63-71`) is the **executor
  fan-out key**: serial loop `for sourceFile in plan.distinctSourceFiles`
  (`AgentLauncher.swift:1546`) or parallel via `runParallelExecutors`
  (`:1527-1543`); each executor gets `plan.assignments(forSource:)`
  (`ACPIngestPlan.swift:57-59`, used at `AgentLauncher.swift:1548`).
- `plan.allPageTitles` feeds the executor cross-link section
  (`AgentLauncher.swift:1558`).

### Is it redundant with "what the harness generates itself"?

**No.** The app deliberately does NOT use Claude's in-process sub-agents — they
"don't work over ACP" (`AgentLauncher.swift:1328-1334`). The planner→executor
split is a **multi-process** substitute for sub-agent dispatch. The planner
cannot "spawn its own executors" over ACP; the *app* does the spawning, and it
needs a serialized handoff (`plan.json`) to do so. The prompt even forbids
sub-agents (`prompts/ingest-planner.md:53`, `ingest-executor.md`, and the
fallback's "no sub-agents" instruction at `AgentLauncher.swift:1924`).

### Recommended action for Q1: **KEEP.** (Optionally: record the nuance.)

No code change is warranted for Q1. `plan.json` is actively consumed and is the
linchpin of multi-phase ingest. The only "dead" aspect is that the on-disk file
lingers after the run (it is not cleaned up), which is **fine** — it's a useful
audit/debug artifact in the run transcript.

> Optional housekeeping (low priority, not required): if transcript clutter is a
> concern, the run-dir cleanup path (`run()`'s `catch` removes `scratch` on spawn
> failure at `AgentLauncher.swift:1310`; success leaves it for inspection) could
> be documented. But **do not** stop writing `plan.json` or stop reading it.

---

## Q2 — Why are sources named `source-<N>.<ext>`?

> **Revision note.** The Q2 plan below supersedes the earlier draft. A
> plan-reviewer found six issues (one HIGH: the executor prompt injects the leaf
> BARE into `sed`/`cat` so a space/shell-meta leaf breaks it; two MEDIUM: the
> 8-char short-id does NOT guarantee uniqueness, and no AC/test pinned
> shell-safety; three LOW: stale `source-1.md` literals, a dead single-source
> API, and wrong module paths). All six are addressed below. Q1 is unchanged.

### Root cause: `AgentStaging.sourceFileName(ext:index:)` deliberately strips provenance.

The naming lives in `Sources/WikiFSCore/Sources/AgentStaging.swift:35-39`:

```swift
public static func sourceFileName(ext: String, index: Int) -> String {
    let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
    let stem = "source-\(index)"
    return trimmed.isEmpty ? stem : "\(stem).\(trimmed)"
}
```

Called by `AgentStaging.stageSources(...)` (`Sources/WikiFSCore/Sources/AgentStaging.swift:72-84`),
which loops `sourceFileName(ext: source.ext, index: index + 1)`. That in turn is
called from `OperationRequest.stage(into:)`
(`Sources/WikiFSEngine/OperationRequest.swift:61-62`). The single-source variant
`sourceFileName(ext:)` (`AgentStaging.swift:27-30`) produces `source.<ext>`; the
multi-source variant produces `source-1.<ext>`, `source-2.<ext>`, …

### Why it's generic (the design comment says it outright)

`Sources/WikiFSCore/Sources/AgentStaging.swift:24-26`:
> the same escaping the rest of the app uses isn't needed here because the leaf
> is app-chosen, not derived from the (untrusted) original filename.

So the rationale was **escaping simplicity**: pick a fixed, safe leaf that can
never contain `/`, `:`, spaces, or weird chars. Collision avoidance across
multiple sources is handled by the 1-based `index` suffix (collision-free by
construction). It is *not* a correctness requirement — it was a "don't think
about escaping" shortcut.

### Provenance IS available at the naming site — abundantly.

`OperationRequest.stage(into:)` (`Sources/WikiFSEngine/OperationRequest.swift:57-69`)
receives `[StagedSource]` (`Sources/WikiFSEngine/OperationRequest.swift:14-26`),
each carrying `bytes`, `ext`, and `displayPath`. The caller
(`Sources/WikiFS/Queue/AppQueueIngestionProvider.swift:167-171`) builds each
`StagedSource` from a `SourceSummary`
(`Sources/WikiFSCore/Sources/SourceSummary.swift:26-96`) which has:

- `id: PageID` — the source ULID (sortable, stable, globally unique).
- `filename: String` — original dropped filename.
- `ext: String`, `mimeType: String?`, `byteSize: Int`.
- `displayName: String?` — user-editable display name.
- `effectiveName: String` (`Sources/WikiFSCore/Sources/SourceSummary.swift:65-68`)
  — `displayName ?? filename` (best label).
- `zoteroItemTitle: String?` — for Zotero imports.

So at the moment sources are staged, the app **knows** each source's stable id,
original filename, display name, and (for Zotero) a curated title. The generic
`source-<N>` naming throws all of that away.

### Impact on the agent (the real problem)

The planner prompt lists sources as bare leaves
(`Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:146-153` →
`prompts/ingest-planner.md:8-10`):

```
- source-1.html  (absolute: …/source-1.html)
- source-2.txt   (absolute: …/source-2.txt)
```

The agent then has to **open each file to learn what it is** — there's zero
provenance in the name. For the example run, `source-1.html` is the Neuralwatt
Cloud platform docs and `source-2.txt` is the MCR protocol spec, but the agent
can't tell without reading them. A name like
`Neuralwatt-Cloud-Platform--01KXYMP7J6HZ3E34ZZX02HKS1F.html` would convey
identity at a glance.

### Proposed naming scheme — STAGING-specific shell-safe escaper (review fix #1)

> **Key decision (fixes review #1, HIGH).** Do NOT reuse the File Provider's
> `FilenameEscaping.byNameSourceFilename` / `escapeTitle` verbatim. That escaper
> **collapses** whitespace runs to a single space but does **not** replace spaces
> with dashes or strip shell metacharacters
> (`Sources/WikiFSCore/Core/FilenameEscaping.swift:17-45`). The executor prompt
> injects `{{PRIMARY_SOURCE_FILE}}` **BARE (unquoted)** into
> `sed -n 'START,ENDp' {{PRIMARY_SOURCE_FILE}}` and `cat {{PRIMARY_SOURCE_FILE}}`
> (`prompts/ingest-executor.md:27`). A space-containing leaf
> (`Neuralwatt Cloud--….html`) splits the `sed`/`cat` arg; a shell-metachar leaf
> (`Cost & Revenue`) is worse (`&` backgrounds, `()` opens a subshell).
>
> **Chosen approach: (a) — a STAGING-specific shell-safe escaper.** Replace every
> space and shell metacharacter in the stem with `-` so the whole leaf matches
> `^[A-Za-z0-9._-]+$`. This **intentionally diverges** from the File Provider's
> `sources/by-name/` naming (which keeps spaces) — different consumers with
> different constraints (the mount is never passed bare to a shell; the staged
> leaf is). Because the leaf is shell-safe by construction, the executor template
> needs **no quoting** to be safe. (The alternative, (b) quoting
> `'{{PRIMARY_SOURCE_FILE}}'` in the template, is *not* taken — (a) is safer and
> self-documenting.)

**New leaf:** `<shellSafeStem(effectiveName)>--<full-ULID>.<ext>`
(e.g. `Neuralwatt-Cloud-Platform--01KXYMP7J6HZ3E34ZZX02HKS1F.html`)

- **`shellSafeStem`** — a new `AgentStaging` helper: run `escapeTitle` first
  (strips control chars, replaces `/` & `:` with `-`, handles leading `.`/empty
  → `untitled`), then replace every char outside `[A-Za-z0-9._-]` (notably
  **spaces** and the shell metacharacters `; & $ \` ( ) | < > \ " ' ! * ? [ ] { }`)
  with `-`, and collapse runs of `-` / trim ends. Pure and unit-tested.
- **`full-ULID`** (review fix #2) — the **full 26-char** source ULID, NOT
  `FilenameEscaping.shortID` (`Sources/WikiFSCore/Core/FilenameEscaping.swift:49-51`).
  `shortID` takes the first 8 ULID chars, which lie **entirely within the 48-bit
  millisecond timestamp**; two sources assigned ULIDs in the same millisecond
  (the normal case in a multi-file drag-drop where IDs are allocated in a tight
  loop) share those 8 chars. If they also share `effectiveName`, the leaves are
  identical and `stageSources`' `.atomic` write has **no collision check**
  (`Sources/WikiFSCore/Sources/AgentStaging.swift:72-84`) → silent overwrite →
  one executor's input is lost. The index-based scheme being replaced was
  collision-free; the **full ULID restores that guarantee by construction**
  (ULIDs are globally unique). This matches the File Provider's `sources/by-id/`
  naming philosophy (`FilenameEscaping.byIDSourceFilename`,
  `Sources/WikiFSCore/Core/FilenameEscaping.swift:69-71`).
- **`<ext>`** preserved, also passed through the same `[A-Za-z0-9._-]` filter so
  the whole leaf is shell-safe.

#### BEFORE / AFTER — `Sources/WikiFSCore/Sources/AgentStaging.swift`

```swift
// BEFORE — AgentStaging.swift:72-84  (loses provenance; leaf has no provenance)
public static func stageSources(
    _ sources: [(bytes: Data, ext: String)],
    in scratchDirectory: URL
) throws -> [String] {
    var paths: [String] = []
    for (index, source) in sources.enumerated() {
        let leaf = sourceFileName(ext: source.ext, index: index + 1)  // "source-2.html"
        let url = scratchDirectory.appendingPathComponent(leaf, isDirectory: false)
        try source.bytes.write(to: url, options: .atomic)
        paths.append(url.path)
    }
    return paths
}

// AFTER — carry provenance through the tuple; shell-safe, collision-free leaf
public static func stageSources(
    _ sources: [(bytes: Data, ext: String, name: String, sourceID: String)],
    in scratchDirectory: URL
) throws -> [String] {
    var paths: [String] = []
    for source in sources {
        let leaf = shellSafeLeaf(name: source.name,
                                 sourceID: source.sourceID,
                                 ext: source.ext)
        // → "Neuralwatt-Cloud-Platform--01KXYMP7J6HZ3E34ZZX02HKS1F.html"
        let url = scratchDirectory.appendingPathComponent(leaf, isDirectory: false)
        try source.bytes.write(to: url, options: .atomic)
        paths.append(url.path)
    }
    return paths
}

/// STAGING-specific shell-safe leaf (review fix #1). Intentionally diverges from
/// the File Provider's `sources/by-name/` naming (which keeps spaces): the
/// executor prompt injects this leaf BARE into `sed`/`cat`
/// (`prompts/ingest-executor.md:27`), so it must contain no spaces or shell
/// metacharacters. The whole leaf matches `^[A-Za-z0-9._-]+$`.
///
/// `sourceID` is the FULL ULID (review fix #2): `shortID` (first 8 chars) lives
/// in the ms-timestamp prefix and collides for same-millisecond ULIDs (a normal
/// case in multi-file drag-drop), which would silently overwrite a staged file.
public static func shellSafeLeaf(name: String, sourceID: String, ext: String) -> String {
    // (1) escapeTitle: strip control chars, replace `/` & `:` with `-`, handle
    //     leading `.` and empty → "untitled" (FilenameEscaping.swift:17-45).
    var stem = FilenameEscaping.escapeTitle(name)
    // (2) Replace every char outside [A-Za-z0-9._-] with '-'. This covers spaces
    //     AND shell metacharacters ; & $ ` ( ) | < > \ " ' ! * ? [ ] { }.
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    stem = String(stem.unicodeScalars.map {
        allowed.contains($0) ? Character($0) : "-"
    })
    // (3) Collapse runs of '-' and trim leading/trailing '-' (tidy, deterministic).
    while stem.contains("--") { stem = stem.replacingOccurrences(of: "--", with: "-") }
    stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if stem.isEmpty { stem = "untitled" }
    // (4) Sanitize the extension the same way; ext is already lowercased upstream.
    let safeExt = ext.lowercased().unicodeScalars
        .filter { allowed.contains($0) }.map { Character($0) }
    let base = "\(stem)--\(sourceID)"   // full 26-char ULID (fix #2)
    return safeExt.isEmpty ? base : "\(base).\(String(safeExt))"
}
```

#### Plumbing: `StagedSource` gains `name` + `sourceID`

The caller `OperationRequest.stage(into:)`
(`Sources/WikiFSEngine/OperationRequest.swift:57-69`) must thread `name` +
`sourceID` into the tuple:

```swift
// AFTER — Sources/WikiFSEngine/OperationRequest.swift:59-62
case .ingest(let sources, let stateMarkdown):
    let stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
    let stagedSourcePaths = try AgentStaging.stageSources(
        sources.map { ($0.bytes, $0.ext, $0.name, $0.sourceID) }, in: scratch)
```

`StagedSource` (`Sources/WikiFSEngine/OperationRequest.swift:16-26`) gains two
fields, populated at `Sources/WikiFS/Queue/AppQueueIngestionProvider.swift:167-171`
from `source.effectiveName` and `source.id.rawValue`:

```swift
// AFTER — Sources/WikiFSEngine/OperationRequest.swift:16-26
public struct StagedSource: Equatable, Sendable {
    public let bytes: Data
    public let ext: String          // lowercased, e.g. "md", "pdf"
    public let displayPath: String  // mount-relative, e.g. "sources/by-id/<ulid>.md"
    public let name: String         // source.effectiveName — drives the staged leaf stem
    public let sourceID: String     // source.id.rawValue (full ULID) — disambiguator
    // …init updated to set both…
}

// AFTER — Sources/WikiFS/Queue/AppQueueIngestionProvider.swift:167-171
sources.append(OperationRequest.StagedSource(
    bytes: sourceBytes,
    ext: sourceExt,
    displayPath: ingestSourcePath(for: source),
    name: source.effectiveName,
    sourceID: source.id.rawValue))
```

### Dead single-source API — recommend DELETE (review fix #5)

`OperationRequest.stage` **always** calls `stageSources(...)`
(`Sources/WikiFSEngine/OperationRequest.swift:61`), even for one source, so the
**single-source** API is test-only:

- `AgentStaging.stageSource(_:ext:in:)` (`Sources/WikiFSCore/Sources/AgentStaging.swift:57-66`)
  — its only non-test caller would be gone; it is referenced only by
  `Tests/WikiFSTests/AgentStagingTests.swift:38`.
- `AgentStaging.sourceFileName(ext:)` (`Sources/WikiFSCore/Sources/AgentStaging.swift:27-30`)
  — single-source leaf math; only caller is `stageSource` (`:63`) and tests.
- `AgentStaging.sourceFileName(ext:index:)` (`Sources/WikiFSCore/Sources/AgentStaging.swift:35-39`)
  — multi-source leaf math; superseded by the new `shellSafeLeaf`, only caller
  was `stageSources` (`:78`).

`source.<ext>` is **not a live contract** — nothing in production reads or globs
it. **Recommendation: DELETE all three** (`stageSource`, `sourceFileName(ext:)`,
`sourceFileName(ext:index:)`) and their tests (below), rather than preserve dead
surface area. `stageStateFile` + the new `stageSources` become the only staging
entry points. If a single-source convenience is ever wanted, call
`stageSources([one], in:)`.

### Consumers that depend on `source-<N>` — and how each is updated

**Verification (sound, kept intact): the `source-<N>` string is not globbed or
parsed anywhere in app code.** The flow is fully indirected by absolute path +
exact string match:

1. **`OperationRequest.stage`** returns `stagedSourcePaths: [String]` (absolute),
   carried verbatim in `WikiOperation.ingest`
   (`Sources/WikiFSCore/Core/WikiOperation.swift:30-40`). The leaf name is never
   re-derived downstream — the absolute path is the contract.
2. **Planner prompt** (`Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:146-153`)
   renders each staged path as `- <leaf>  (absolute: <path>)`. With the new names
   this becomes
   `- Neuralwatt-Cloud-Platform--01KXYMP7J….html  (absolute: …)` — **strictly
   better**; no logic change, the path content is all that differs.
3. **`plan.json` `sourceFile` field** — written by the *planner agent* using
   whatever leaf it sees in the prompt. It will naturally contain the new
   descriptive leaf. The schema (`ACPIngestPageAssignment.sourceFile`) is a
   free-form `String` (`Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:23-24`),
   so **no schema change**.
4. **Executor dispatch** keys on `plan.distinctSourceFiles`
   (`Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:63-71`) and
   `plan.assignments(forSource:)` (`:57-59`), used at
   `Sources/WikiFSEngine/AgentLauncher.swift:1546-1548` (serial) and
   `:1527-1543` (parallel `runParallelExecutors`). These do **exact string
   match** on whatever `sourceFile` the planner wrote — so they work with **any**
   leaf name. No change.
5. **Executor prompt** (`Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:179`)
   defaults `primarySourceFile = assignments.first?.sourceFile ?? "source-1.md"`.
   The fallback literal is only reached when `assignments` is empty (an executor
   always has ≥1 page in practice), but it is stale — **change it to a neutral
   default** (e.g. the first staged source path, or `"source.md"` as an obviously
   placeholder leaf). Better: pass the executor its single staged path explicitly
   so there is no fallback literal at all.

**Net: no consumer globs `source-*` or hard-parses the `source-<N>` pattern in
production code.** Dispatch is by absolute path + exact string match throughout.

### Tests that must change

- `Tests/WikiFSTests/AgentStagingTests.swift` — currently asserts the old leaves:
  `source.pdf` (`:14-17`), `source` (`:21-22`), `source-1.md`/`source-2.pdf`
  (`:49-52`), and round-trips `stageSource`/`stageSources` (`:38, :65, :68-69, :80`).
  Per fix #5, **delete** the single-source tests
  (`sourceFileNameAppendsLowercasedExtension`, `sourceFileNameHandlesMissingExtension`,
  `stagesStateAndSourceIntoScratchAndReturnsAbsolutePaths`'s `stageSource` half,
  and `sourceFileNameWithIndex`). **Rewrite** the multi-source test to assert the
  new `<shellSafeStem>--<full-ULID>.<ext>` leaves, and **add** the shell-safety
  test (fix #3, below).
- `Tests/WikiFSTests/ACPIngestPlanTests.swift:176-205` —
  `testPlannerPromptFillsPlaceholders` / `testExecutorPromptFillsPlaceholders`
  assert `prompt.contains("source-1.md")`. Update the fixtures to use descriptive
  leaves (the assertions check the path round-trips into the prompt, which still
  holds — just a different leaf string).
- `Tests/WikiFSTests/ACPIngestPlanTests.swift` group/dedup tests
  (`distinctSourceFiles`, `assignments(forSource:)`, lines 52-73) use
  `source-1.md`/`source-2.md` literals as `sourceFile` values. These still pass
  (they test string-equality grouping, not the literal) but should be refreshed
  for realism.
- `Tests/WikiFSTests/FakeAgentBackend.swift:103-105` — writes `plan.json` to
  simulate the planner; unaffected (it doesn't care about source leaf names).

### New shell-safety AC + mapped unit test (review fix #3)

**Acceptance criterion (new):** *Every staged source leaf matches
`^[A-Za-z0-9._-]+$` (shell-safe) regardless of `effectiveName` content.*

Mapped unit test to add to `Tests/WikiFSTests/AgentStagingTests.swift`:

```swift
@Test func stagedSourceLeavesAreShellSafe() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    // Adversarial effectiveNames: spaces, shell metacharacters, path separators.
    let ulid = "01KXYMP7J6HZ3E34ZZX02HKS1F"
    let cases: [(name: String, ext: String)] = [
        ("Cost & Revenue (Q3)", "md"),
        ("a/b:c", "txt"),
        ("name with $vars", "pdf"),
        ("Neuralwatt Cloud Platform", "html"),
        ("", "md"),                         // empty → untitled stem
    ]
    let sources = cases.map { (Data("x".utf8), $0.ext, $0.name, ulid) }
    let paths = try AgentStaging.stageSources(sources, in: scratch)

    let shellSafe = try #require(
        NSRegularExpression(pattern: "^[A-Za-z0-9._-]+$"))
    for (i, leaf) in paths.map { ($0 as NSString).lastPathComponent }.enumerated() {
        #expect(shellSafe.firstMatch(in: leaf, range: NSRange(location: 0, length: leaf.count)) != nil,
                "leaf \(leaf) (from \(cases[i].name)) is not shell-safe")
        // The full ULID disambiguator survives intact (fix #2).
        #expect(leaf.contains(ulid))
    }
}
// Expect e.g. "Cost-Revenue-Q3--01KXYMP7J6HZ3E34ZZX02HKS1F.md",
//              "a-b-c--01KXYMP7J6HZ3E34ZZX02HKS1F.txt",
//              "name-with-vars--01KXYMP7J6HZ3E34ZZX02HKS1F.pdf".
```

### Refreshed prompt literals + `make prompts` (review fix #4)

Stale `source-1.md` literals to refresh (the planner copies these verbatim):

- `prompts/ingest-planner.md:33` — the example JSON `"sourceFile": "source-1.md"`
  → a descriptive leaf, e.g. `"sourceFile": "Neuralwatt-Cloud-Platform--01KXYMP7J6HZ3E34ZZX02HKS1F.html"`.
- `prompts/ingest-planner.md:45` — the field rule
  `- \`sourceFile\`: the actual filename in your working directory (e.g. "source-1.md").`
  → `(e.g. the descriptive \`--<ulid>.<ext>\` leaf shown above).`
- `Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:23` — the doc comment
  `/// The staged source filename in the scratch directory (e.g. \`"source-1.md"\`).`
  → `(e.g. \`"Neuralwatt-Cloud-Platform--<ulid>.html"\`)`.
- `Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:179` — the executor
  fallback `?? "source-1.md"` → a neutral default (see consumers #5 above).

After editing `prompts/ingest-planner.md`, run `make prompts` to regenerate
`Sources/WikiFSCore/GeneratedPrompts.swift` (gitignored derived artifact; the
`prompts/*.md` are the source of truth).

---

## Risks

- **Planner emits a `sourceFile` that doesn't match any staged file.** This risk
  exists *today* (the planner is an LLM copying a leaf name). The executor's
  `assignments(forSource:)` would return empty and that executor is skipped
  (`Sources/WikiFSEngine/AgentLauncher.swift:1549`). The new leaves are *more*
  distinctive, so a typo is more likely to be a clean miss (skipped executor,
  visible in logs) than a silent collision — net positive. Mitigation: the
  planner prompt already says "the actual filename in your working directory"
  (`prompts/ingest-planner.md:45`); keep instructing it to copy verbatim.
- **Shell-safety (review fix #1).** Resolved by construction: `shellSafeLeaf`
  guarantees every leaf matches `^[A-Za-z0-9._-]+$`, so the executor template's
  BARE `{{PRIMARY_SOURCE_FILE}}` (`prompts/ingest-executor.md:27`) is safe with
  **no template quoting required**. (If the escaper were ever bypassed, the new
  shell-safety unit test fails.) *Note: the previous draft's claim that
  shell-safety was "mitigated by `escapeTitle`" was wrong — `escapeTitle` keeps
  spaces (`Sources/WikiFSCore/Core/FilenameEscaping.swift:17-45`); the new
  `shellSafeLeaf` is what actually removes them.*
- **Uniqueness (review fix #2).** Resolved by construction: the full 26-char ULID
  is globally unique, so no two staged leaves collide even for same-ms,
  same-name sources. *Note: the previous draft's claim that the 8-char `shortID`
  "guarantees uniqueness" was wrong — those 8 chars are the ms-timestamp prefix.*
- **`displayPath` vs staged-leaf divergence.** `StagedSource.displayPath`
  (`Sources/WikiFSEngine/OperationRequest.swift:19`) stays
  `sources/by-id/<ulid>.<ext>` (the canonical mount citation path) while the
  staged leaf becomes descriptive + shell-safe. That's fine — they are different
  things (mount citation path vs scratch leaf) and both are passed through.
- **Regression in parallel-executor fan-out.** `runParallelExecutors`
  (`Sources/WikiFSEngine/AgentLauncher.swift:1535`) also keys on
  `distinctSourceFiles`; same exact-string-match logic, so it's unaffected by
  leaf content.

## Acceptance criteria

1. A multi-source ingest run produces scratch leaves like
   `<shellSafeStem>--<full-ULID>.<ext>` instead of `source-<N>.<ext>`.
2. **Uniqueness (fix #2):** two sources — even same-millisecond ULIDs with the
   same `effectiveName` — produce **distinct** leaves (full-ULID disambiguator);
   `stageSources` never silently overwrites a staged file.
3. **Shell-safety (fix #3):** every staged source leaf matches
   `^[A-Za-z0-9._-]+$`, verified by a unit test feeding adversarial
   `effectiveName`s (`Cost & Revenue (Q3)`, `a/b:c`, `name with $vars`).
4. A source with no display name falls back to `filename` via `effectiveName`,
   and an empty/weird name becomes `untitled--<full-ULID>.<ext>`.
5. The planner prompt lists the descriptive leaves; the planner's emitted
   `sourceFile` values match staged files; executors dispatch correctly
   (exact-string-match fan-out unchanged).
6. Stale `source-1.md` literals refreshed in the planner example JSON
   (`prompts/ingest-planner.md:33,45`), the `sourceFile` doc comment
   (`Sources/WikiFSCore/Integrations/ACPIngestPlan.swift:23`), and the executor
   fallback (`:179`); `make prompts` re-run.
7. Dead single-source API (`stageSource`, `sourceFileName(ext:)`,
   `sourceFileName(ext:index:)`) and its tests deleted.
8. `AgentStagingTests` and `ACPIngestPlanTests` updated and green.
9. `swift build` and `swift test` pass. (pdf2md python tests are unaffected —
   this change does not touch `tools/pdf2md`.)

## Build / test commands

```bash
make prompts                    # regenerate GeneratedPrompts.swift after editing prompts/*.md (fix #4)
swift build                     # compile
swift test                      # full suite (~1.5 min, in-memory SQLite fixtures)
swift test --filter AgentStagingTests            # the new leaf math + shell-safety test
swift test --filter ACPIngestPlanTests           # planner/executor prompt + plan schema
```

`make prompts` is required because the planner template's example JSON is edited
(fix #4). `make build`/`check`/`test` regenerate `GeneratedPrompts.swift`
automatically as a prerequisite, but a bare `swift build` does **not** — run
`make prompts` first (CI runs `make version prompts` before `swift build`).

---

## Summary

- **Q1 (unchanged): `plan.json` is actively consumed and load-bearing** — it is
  the planner→executor handoff for large-source ingest. The *agent* writes it
  (per the planner prompt), and the app reads it (`ACPIngestPlan.load`) to fan
  out executors. **Keep it.** The operator's "app pre-writes plan.json"
  hypothesis is incorrect; there is no app-side writer to remove.
- **Q2 (revised): `source-<N>.<ext>` is an escaping shortcut** in
  `AgentStaging.sourceFileName(ext:index:)` that discards available provenance.
  Full provenance (id, filename, displayName, effectiveName) is available at the
  staging site. Replace it with a **STAGING-specific shell-safe escaper**
  (`AgentStaging.shellSafeLeaf`) emitting
  `<shellSafeStem>--<full-ULID>.<ext>`: spaces and shell metacharacters become
  `-` (leaf matches `^[A-Za-z0-9._-]+$`, so the executor's bare
  `{{PRIMARY_SOURCE_FILE}}` is safe), and the **full** ULID (not the 8-char
  short-id) restores collision-freedom for same-ms sources. No consumer globs or
  parses `source-<N>`; all dispatch is by absolute path / exact string match.
  The dead single-source API is deleted; stale `source-1.md` literals are
  refreshed + `make prompts`; module-path citations corrected to
  `Sources/WikiFSEngine/`.

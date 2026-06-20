# Design: `wikictl file` — replace Query-time raw-file reads off the mount

**Status:** Implemented 2026-06-20.
Part of the File-Provider decouple effort (see
`plans/inline-file-view-and-provider-decouple.md`). This is the **first**
concrete step: remove the agent's dependency on the File Provider mount for
reading raw ingested files during a Query run.

All file/line references verified against `main` @ `1d9b6a4`.

## Why

The agent (`claude -p`) currently reads raw ingested source files through the
read-only File Provider mount. In the **Query** workflow prompt
(`Sources/WikiFSCore/WikiOperation.swift:289-293`) it is told:

> "…resolve the source filename/path using `$WIKI_ROOT/files/by-name/`,
> `$WIKI_ROOT/files/by-id/`, or `$WIKI_ROOT/indexes/files.jsonl`, then read the
> raw file from the mount (use the `Read` tool or shell commands such as `cat`,
> `python`, `pdftotext`, or `strings`…)"

This is one of only two remaining *hard* dependencies on the mount (the other is
human/external-tool browsing). Everything else the agent reads is already routed
around the mount:

- **Pages** → `wikictl page get` (instant SoT read; bypasses the ~5 s mount lag).
- **Wiki structure** → a `WIKI_STATE.md` snapshot staged into the scratch cwd.
- **Ingest sources** → already copied into the scratch dir by `AgentStaging.stageSources`.

Replacing Query-time raw-file reads with a `wikictl` read command makes the agent
fully self-sufficient from SQLite — a prerequisite for making the File Provider
extension optional (no `/Applications`, no Apple Developer Account).

## What exists today (the seams to reuse)

**Store reads (already present, no new store code for the happy path):**
- `WikiStore.listIngestedFiles() -> [IngestedFileSummary]` (`SQLiteWikiStore.swift:737`)
- `WikiStore.getIngestedFile(id:) -> IngestedFileSummary` (`SQLiteWikiStore.swift:751`)
- `WikiStore.ingestedFileContent(id:) -> Data` (`SQLiteWikiStore.swift:764`) — the verbatim BLOB
- `SQLiteWikiStore.listAllIngestedFilesOrderedByID() -> [IndexGenerators.FileRow]` (`SQLiteWikiStore.swift:804`) — ingest-ordered, blob-free

**The JSONL shape to mirror** (so the agent sees the same data it sees in the
mount's `indexes/files.jsonl`) — `IndexGenerators.filesJSONL` (`IndexGenerators.swift:139`):
```
{"id":<ulid>,"name":<filename>,"path":<files/by-id/<id>.<ext>>,"size":<int>,"mime":<string|null>}
```
One object per line, fixed key order, ordered by id (ingest order).

**`wikictl` plumbing to extend:**
- `ArgumentParser` (`Sources/WikiCtlCore/ArgumentParser.swift`) — grammar, the
  `Command` enum, the per-family `parseXCommand` helpers, the `Options` bag, and
  `usageText`. `page`/`log`/`index`/`search` are the existing families.
- `PageCommand` (`Sources/WikiCtlCore/PageCommand.swift`) — the execution +
  `Result { output, didCommit }` pattern. Reads set `didCommit: false`.
- `main.swift` `execute(_:in:)` (`Sources/wikictl/main.swift:62`) — dispatch; the
  `--wiki` / `WIKI_DB` selection and the post-commit Darwin notify are already
  handled around it. A read command needs **no** Darwin post.

**Agent already has `wikictl` wired:**
- `OperationCommand.build` (`OperationCommand.swift`) sets `WIKI_DB = wikiID` and
  prepends `wikictlDirectory` to `PATH`, so `wikictl file …` resolves and
  auto-selects the wiki with **no `--wiki` needed**.
- The agent's Bash allowlist entry is `Bash(wikictl:*)` — a new `file`
  subcommand is already covered. **Verify** this allowlist string in the run
  setup before assuming it (grep `wikictl:` / `allowedTools`).

## Proposed CLI surface: the `wikictl file` family

Three subcommands. `cat` handles the text path; `export` handles binaries
(PDFs) that need a real filesystem path for `pdftotext` / the `Read` tool;
`list` replaces `indexes/files.jsonl`.

```
wikictl [--wiki <id>] file list [--json]
        list ingested files. TSV: id <tab> name <tab> size <tab> mime
        (or --json: one object per line, IDENTICAL bytes to indexes/files.jsonl)

wikictl [--wiki <id>] file cat (--id X | --name N)
        write the file's raw bytes to stdout (for text; pipeable, e.g. | head)

wikictl [--wiki <id>] file export (--id X | --name N) [--out <path>]
        materialize the file to a real path and PRINT that path on stdout.
        Without --out, write to "<cwd>/file-<id>.<ext>" (the scratch dir).
        This is the replacement for "$WIKI_ROOT/files/by-id/<id>.<ext>" —
        the agent then runs pdftotext / Read / strings on the printed path.
```

**Selector resolution.** `--id` is canonical (ULID, unambiguous). `--name`
resolves a filename → id by matching `filename` in `listIngestedFiles()`. On
**ambiguity** (multiple files share a name) `--name` must FAIL with a message
listing the matching ids, telling the agent to re-issue with `--id`. This mirrors
how the mount's `files/by-name` is inherently 1:1 per disambiguated name; do not
silently pick one.

**Binary stdout.** `file cat` must write raw `Data` via
`FileHandle.standardOutput.write(_:)`, NOT `print` (which mangles non-UTF-8).
This means `cat`'s output cannot ride the existing `Result.output: String`
field — see "Implementation shape" below.

## Implementation shape

The existing `Result.output` is a `String` printed by `main` via `print`. Raw
bytes don't fit that. Two clean options — **pick option A**:

- **Option A (recommended): a dedicated `FileCommand` with a byte-aware Result.**
  Add `Sources/WikiCtlCore/FileCommand.swift` mirroring `PageCommand`, but its
  `Result` carries an enum payload: `.text(String)` (for `list`, `export`'s
  printed path) or `.bytes(Data)` (for `cat`). `main.execute` writes `.text` via
  `print` and `.bytes` via `FileHandle.standardOutput.write`. Keeps `PageCommand`
  untouched and keeps binary I/O out of the string path.

- Option B: shoehorn bytes into `PageCommand.Result` by adding an optional
  `Data` field. Rejected — pollutes the page command surface.

### Files to change

1. **`Sources/WikiCtlCore/FileCommand.swift`** (new). `enum FileCommand` with:
   - `Action`: `.list(json: Bool)`, `.cat(Selector)`, `.export(Selector, out: String?)`
   - `Selector`: `.id(PageID)` | `.name(String)` (its own, or reuse a shared one)
   - `Result`: `{ payload: Payload, didCommit: false }`, `Payload = .text(String) | .bytes(Data)`
   - `run(_:in:cwd:)` — `cwd` injected for `export`'s default path (testability;
     don't read `FileManager.default.currentDirectoryPath` inside the pure core).
   - `list` builds TSV from `listIngestedFiles()`; `--json` reuses
     `IndexGenerators.filesJSONL(files: store.listAllIngestedFilesOrderedByID())`
     verbatim so the bytes match the mount index exactly.
   - `cat` → `.bytes(ingestedFileContent(id:))`.
   - `export` → write bytes to `out ?? "\(cwd)/file-\(id).\(ext)"`
     (extension-less when `ext` empty, matching `filesJSONL` path logic), return
     `.text(absolutePath)`.
   - Name resolution + ambiguity error as specified above.

2. **`Sources/WikiCtlCore/ArgumentParser.swift`**:
   - Add `case file(FileCommand.Action)` (or flattened cases) to `Command`.
   - Add `case "file": command = try parseFileCommand(...)` in `parse`.
   - Add `parseFileCommand` mirroring `parsePageCommand`. Note: `--name` and
     `--out` are `--key value` (already handled by `Options`); `--json` is the
     existing valueless flag. The `Options` initializer special-cases `--json` as
     the *only* valueless flag — `--out`/`--name` need no change.
   - Extend `usageText` with the three `file` lines.
   - Add a `requireFileSelector()` to `Options` (exactly one of `--id`/`--name`),
     mirroring `requireSelector()`.

3. **`Sources/wikictl/main.swift`** `execute(_:in:)`:
   - Add the `file` dispatch. For `export`, pass
     `cwd: FileManager.default.currentDirectoryPath`.
   - In `run()`, after execute, handle the byte payload: if `.bytes`, write to
     `FileHandle.standardOutput`; if `.text` and non-empty, `print`. Reads never
     `didCommit`, so the Darwin-notify branch is untouched.

4. **`Sources/WikiFSCore/WikiOperation.swift`** — rewrite the Query prompt's
   raw-file paragraph (`queryPrompt`, ~lines 282-299). Replace the
   `$WIKI_ROOT/files/...` instructions with:
   > "If a page footnote cites a raw source, resolve it with `wikictl file list`
   > (or `--json`), then read it: for text use `wikictl file cat --id <id>`; for
   > a PDF or other binary run `wikictl file export --id <id>` and run
   > `pdftotext` / `Read` / `strings` on the path it prints."
   Drop the `WIKI_ROOT (… reference only)` trailer's relevance for files (leave
   the line if still used for orientation, but it is no longer load-bearing for
   raw-file reads). Keep `wikictl page get` for pages unchanged.

5. **Tests** — `Tests/WikiFSTests/WikiCtlCommandTests.swift` is the model
   (builds a temp `SQLiteWikiStore`, runs commands, asserts `Result`). Add:
   - **Parser tests** (pure, no I/O): `file list`/`file list --json`,
     `file cat --id`, `file cat --name`, `file export --id`,
     `file export --id --out P`, and the failure cases (`file` with no
     subcommand, neither/both selectors, `--out` without value).
   - **Execution tests** (temp DB seeded with `ingestedFiles`): `list` TSV +
     `--json` bytes **equal `IndexGenerators.filesJSONL`**; `cat` returns the
     exact stored BLOB (use a binary fixture, e.g. bytes `0x00 0xFF`, to prove
     the byte path); `export` writes the file under the injected `cwd` and
     returns its path with correct contents; `--name` ambiguity fails listing
     the ids; unknown id/name fails cleanly.

## Edge cases & decisions

- **Binary correctness is the whole point** — test `cat`/`export` with
  non-UTF-8 bytes, not just text, or a regression that re-routes through a
  `String` will pass tests and corrupt PDFs in the field.
- **`export` default path collisions across files** — keying the default name on
  the ULID (`file-<id>.<ext>`) makes it unique and idempotent per run.
- **No Darwin notification, no mount signal** — these are pure reads.
- **`WIKI_DB` auto-selection** means the agent never passes `--wiki`; tests
  should still cover explicit `--wiki` since the grammar allows it.

## Out of scope (call out, don't do here)

- The **human/external-tool browsing** dependency on the mount (Preview, Terminal
  `grep`) — that is the *other* hard dependency and is what makes the extension
  ultimately optional; tracked in `plans/inline-file-view-and-provider-decouple.md`.
- Making the extension actually optional in the build/run path, and the `PLAN.md`
  non-negotiable amendment — separate PR, needs user sign-off.
- The **system prompt / `WIKI-STRUCTURE.md`** wording (`SystemPrompt.swift:55`
  mentions `files.jsonl`) still points the agent at the mount index. Updating it
  to mention `wikictl file list` is a nice follow-up but not required for Query to
  stop touching the mount — the Query prompt change (item 4) is what removes the
  dependency. Note it as a follow-up so the docs don't drift.
- Ingest already stages sources to scratch, so it needs no change.

## Definition of done

- `wikictl file list [--json]`, `file cat`, `file export` implemented, with
  `--json` bytes byte-identical to `indexes/files.jsonl`.
- The Query prompt no longer references `$WIKI_ROOT/files/...`; it uses
  `wikictl file …`.
- New parser + execution tests green; full `swift test` green.
- A live Query run answers a footnote-backed question (text source AND a PDF
  source) **without** the File Provider mount mounted/enabled. This is the gate
  that proves the dependency is gone.
- Update `PROGRESS.md` (newest-first entry) and link this doc from `PLAN.md`'s
  documentation index.

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

* **SQLite is single-threaded in this app: all `SQLiteWikiStore` access happens
  on the main actor — never on a background task/queue.** The store keeps one
  connection with a statement cache keyed by SQL; two threads running the same
  query share one `sqlite3_stmt*` and race (`EXC_BREAKPOINT` in `String(cString:)`).
  `SQLITE_OPEN_FULLMUTEX` does NOT save you — it serializes C calls, not app-level
  statement reuse. Follow
  [`docs/skills/sqlite-concurrency/SKILL.md`](docs/skills/sqlite-concurrency/SKILL.md):
  bulk store work is a blocking modal upgrade (sole owner while it runs), new
  content embeds inline at write time, and off-main work is pure compute (MLX)
  only — no `store.*` calls. There is no background "backfill."

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

## Testing

**Swift** (from repo root):
```
swift build          # compile
swift test           # full suite
swift test --filter PdfExtractionServiceTests  # pdf extraction only
```

**Python / pdf2md** (from `tools/pdf2md`):
```
uv run pytest tests/                                     # unit + fast integration (60, never hangs)
uv run pytest tests/test_vlm.py -v                       # VLM pipeline (slow, needs real PDF + ~2 GB model)
uv run ruff check pdf2md tests/                          # lint
uv run pyright pdf2md tests/                             # type check
```

Python tests are NOT in CI — run them manually when changing pdf2md or PdfExtractionService.

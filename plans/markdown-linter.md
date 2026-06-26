# Markdown linter for wiki pages

Design of record for the save-time markdown auto-fix feature. See
`PROGRESS.md` for the build evidence.

## Goal

Run a deterministic markdown linter over every wiki page at save time,
**auto-fixing cosmetic issues** when the agent writes via `wikictl`, and
**warning** (non-blocking) when a human edits in-app. Mirrors the existing
`merval` (Mermaid) save-time validation pattern exactly, generalized to general
markdown.

## Engine

**Vendor `markdownlint` 0.41.0 (npm core JS lib) + `markdownlint-rule-helpers`
0.31.0**, bundled to a single IIFE and run in a `JavaScriptCore` `JSContext` —
no Node/fs/DOM at runtime. This is the proven `merval` approach (bundled JS →
JSContext → `shared` singleton) applied to markdown.

### Bundling

markdownlint 0.41 is ESM and pulls in a deep dependency tree (micromark + GFM
extensions + katex). Two build tricks were required:

1. **Targeted `#node-imports` swap** — markdownlint imports Node builtins
   (`node:fs`, `node:os`, `node:path`) via a `#node-imports` subpath condition.
   It ships a browser shim (`node-imports-browser.mjs`) that throws when those
   APIs are called. An esbuild plugin (`build.mjs`) intercepts ONLY the
   `#node-imports` import and points it at the browser shim, leaving every other
   package on default conditions. (Naively passing `--conditions=browser` would
   also force `decode-named-character-reference` onto its DOM version, which
   calls `document.createElement("i")` at load time — JSC has no DOM.)

2. **`URL` polyfill** — markdownlint builds rule-info links with `new URL(...)`
   at module-load time. JSC has no `URL` global. `MarkdownLinter.init` installs a
   minimal stub (`var URL = function(u){...}`) before evaluating the bundle. Safe
   because none of the enabled cosmetic rules depend on URL validation.

**`applyFixes` location change:** in markdownlint 0.41, `applyFixes` moved from
`markdownlint-rule-helpers` into the main `markdownlint` package
(`export { applyFix, applyFixes, getVersion } from "./markdownlint.mjs"`). The
helpers package (0.31) no longer exports it.

### Reproduction recipe

```sh
cd tools/markdownlint-vendor
npm ci                    # reproduce from pinned package-lock.json
node build.mjs            # esbuild → ../../Resources/markdownlint.bundle.js
node verify.mjs           # 10 checks (cosmetic config, mermaid safety, wiki-links)
```

The pinned `package-lock.json` is the reproduction recipe. The recorded SHA256
(`e022302172162c294bcec1a0d3ee44938c765d15afb5b3e230fc48425d499f0e`) is a
best-effort drift indicator — esbuild output is not byte-deterministic across
runs (module ID assignment varies), but the functional output is identical.

## Rule set: cosmetic normalization only

`default: false` (turn OFF all rules), then explicitly enable only safe,
auto-fixable normalizers:

| Rule | Description |
|------|-------------|
| MD009 | Trailing spaces |
| MD010 | Hard tabs |
| MD012 | Multiple consecutive blank lines |
| MD018–021 | Space after heading marker (atx/close/space/atx-closed) |
| MD022 | Blanks around headings |
| MD023 | Headings must start at the left margin |
| MD027 | Multiple spaces after blockquote symbol |
| MD030 | Spaces after list markers |
| MD031 | Blanks around fences |
| MD032 | Blanks around lists |
| MD037 | Spaces inside emphasis markers |
| MD038 | Spaces inside code span elements |
| MD039 | Spaces inside link text |
| MD047 | File should end with a single newline |
| MD058 | Blanks around tables |

**Excluded (opinionated/structural):** MD013 (line-length), MD040
(fenced-language), MD041 (first-line-H1), MD001/024/025/033. Every enabled rule
is auto-fixable, so the agent path's "block on non-fixable" guard is inert in
practice but kept wired for a future structural-rules opt-in.

## Two write surfaces (both mirror merval)

### Agent path — `wikictl page upsert` (`PageCommand`)

`fix()` is applied to the body BEFORE the write. Order becomes:
markdown-fix → mermaid-validate (block) → `PageUpsert`.

```
autoFixMarkdown(body, linter:)     → fixed text (or throw on unfixable)
abortOnInvalidMermaid(fixed, validator:)  → throw on broken diagram
PageUpsert.upsert(... body: fixed) → commit
```

Frictionless under the cosmetic-only config (no round-trips — every rule
auto-fixes). When `linter` is nil (unbundled / dev / `swift test`), the body
passes through unchanged (AC.4 graceful degradation).

### In-app path — `WikiStoreModel.save`

`lint()` computes findings on a background `Task` (the JSContext call is
thread-safe via the linter's `NSLock`) and sets a non-blocking
`markdownSaveWarning` via a `@MainActor` hop. The **original** text is saved (no
auto-fix — editor is the human escape hatch). Combined banner with the mermaid
warning in `PageDetailView`.

## API contract

```swift
// MarkdownLinter (Sources/WikiFSCore/MarkdownLinter.swift)
init?(jsSource: String)                    // load IIFE into JSContext
func lint(markdown: String) -> [LintResult]
func fix(markdown: String) -> FixOutcome   // { fixed: String, unfixable: [LintResult] }
static func describe(_ findings: [LintResult]) -> String
static func loadDefault() -> MarkdownLinter?
static let shared: MarkdownLinter?         // process-wide, built once
static var defaultConfig: [String: Any]    // the cosmetic-only config
```

## What it catches vs. misses

**Catches:** trailing whitespace, hard tabs, multiple consecutive blank lines,
missing space after `#`/`>`/list markers, missing blank lines around
headings/fences/lists/tables, spaces inside emphasis/code/links, missing single
trailing newline.

**Does NOT catch:** heading hierarchy (MD001), line length (MD013), fenced-code
language tags (MD040), first-line-must-be-H1 (MD041), duplicate headings
(MD024/025), or any structural/semantic rule. Fenced code blocks (including
```` ```mermaid ````) are never modified inside the fence. `[[wiki-links]]` are
inert text — no false positives.

## Naming

The class is `MarkdownLinter` / warning is `markdownSaveWarning`, to disambiguate
from the existing AI-driven agent **"Lint"** operation (a claude review pass) —
these are unrelated.

## Scope

Wiki pages only (the agent's primary output + in-app editor). Source markdown
(PDF-extracted) is **out of scope** for v1 — machine-extracted, lower value, and
linting it could fight the extraction.

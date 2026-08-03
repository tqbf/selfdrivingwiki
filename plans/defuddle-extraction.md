# Defuddle HTML Extraction — Implementation Plan (v2, simplified)

> **Issue #761** — Use defuddle for HTML source content extraction, replacing
> the current tag-based `HTMLToMarkdown.scopeToMainContent`. Supersedes #209.
>
> **Design (confirmed by operator):** defuddle is a `#!/usr/bin/env node` script.
> The app **already bundles bun** (a Node-compatible runtime) in `Contents/Helpers/`.
> So the integration is: **bundle the defuddle script** (like pdf2md) and **run it
> with the bundled bun** — fully self-contained, no external runtime dependency.
> This is a near-clone of the `PdfExtractionService` pattern, but STRICTLY SIMPLER:
> no uv/Python/venv, stdin input, sub-second runtime.

---

## 0. Key Empirical Findings (verified this session)

1. **What defuddle is:** `~/.local/bin/defuddle` is a `#!/usr/bin/env node` script,
   7416 bytes — the published `dist/cli.js` CommonJS entry point (it starts with
   `"use strict"; Object.defineProperty(exports, "__esModule", …)`). It is **NOT**
   self-contained: it `require`s `commander`, `./node`, `fs/promises`, `path`,
   `./utils/linkedom-compat`, `./utils`, `./frontmatter`, `./fetch`. bun runs
   the npm-installed script fine because it resolves those `require`s relative
   to the real path (`~/.local/lib/node_modules/defuddle/dist/cli.js`), where
   the sibling `.js` files + `node_modules/` exist:

   ```sh
   $ echo '<html>…<article><p>Hi <strong>there</strong>.</p></article>…' \
       | bun ~/.local/bin/defuddle parse -j -
   { "contentMarkdown": "Hi **there**.", "title": "T", "author": "", … }
   ```

   **⚠️ The `cp` trap (the bug behind the original DefuddleExtractionServiceTests
   failures):** a verbatim `cp` of `dist/cli.js` into `tools/defuddle/defuddle`
   does NOT work — bun then resolves `./node` relative to `tools/defuddle/` (no
   siblings, no `node_modules/`) and dies with `Cannot find module './node'`,
   making `extract()` return nil. The fix: `tools/defuddle/defuddle` is a
   **`bun build` bundle** of `dist/cli.js` (~2.45 MB, 351 modules inlined,
   INCLUDING commander/linkedom/all extractors) — genuinely self-contained, runs
   standalone under bun, no `node_modules`. See `tools/defuddle/README.md`'s
   update procedure. A future agent changing this back to a plain `cp` will
   re-introduce the silent fallback-to-tag-based regression (the broken bundle
   still ships in `Contents/Helpers/defuddle` and the test still "resolves" —
   it just returns nil at runtime).

2. **JSON field behavior — CRITICAL GOTCHA (verified):**

   | Invocation | `content` field | `contentMarkdown` field |
   |------------|-----------------|-------------------------|
   | `parse -j -` (no `-m`) | **cleaned HTML** (`<article><p>Hi</p></article>`) | **markdown** (`Hi **there**.`) |
   | `parse -m -j -` | **markdown** (`Hi **there**.`) | **ABSENT** |

   With `-m -j`, defuddle **overloads `content` with markdown and drops
   `contentMarkdown`**. The skill doc + issue prompt assume `-m -j` yields
   `contentMarkdown` — it does not. **Use `parse -j -` (no `-m`) and read
   `contentMarkdown`** — that's the field literally named for markdown, and
   `content` still gives the cleaned HTML (useful if ever needed). Make the
   decoder robust to both (prefer `contentMarkdown`, fall back to `content`).

3. **SPA / empty content:** a page with no article body (e.g. `<div id="app">`)
   makes defuddle **exit 1 with empty stdout**. This is the fallback trigger.

4. **bun is already bundled + signed:** `build.sh` copies `~/.bun/bin/bun`
   into `Contents/Helpers/bun` and signs it. It is REQUIRED by the build (ACP
   providers need it). So **bun is always present in the bundle** — defuddle
   needs no separate runtime, no PATH search, no uv-style graceful degradation.
   This makes defuddle **strictly better than pdf2md** (which needs the
   un-bundled uv+Python and falls back to the agent when absent).

---

## 1. Current State — the seam being replaced

### 1.1 `HTMLToMarkdown.scopeToMainContent` (the current extractor)

Pure tag-based heuristic: strip `script/style/head/nav/footer`, then prefer
`<article>` → `<main>` → `<body>` (first match wins). No readability scoring, no
site-specific knowledge. Works for clean articles; noisy for heavy-chrome pages.

### 1.2 The HTML ingestion path (trace — where defuddle slots in)

```
WebsiteMaterializer.materializeWithPlan()        SourceMaterializer.swift
  ├─ URLFetchService.fetch(url)                  → raw HTML bytes
  ├─ FormatMaterializer.dispatch(...)            (PURE, SYNC — unchanged)
  │    └─ if mime == html/xhtml:
  │         HTMLToMarkdown.convert(html)         ← THE SEAM (tag-based markdown + <title>)
  │         → FormatPlan(data: HTML, .html, extractedMarkdown: tagMD)
  ├─ [NEW] await DefuddleExtractionService.extract(html)   ← defuddle replaces the markdown
  │    └─ if non-empty: overwrite extractedMarkdown; else keep tag-based fallback
  └─ MaterializedSource(..., extractedMarkdown: <defuddle OR tag-based>)
```

Store-write (unchanged): `WikiStoreModel.storeMaterialized` →
`appendExtractedMarkdown` →
`store.appendProcessedMarkdown(origin: .extraction, technique: …)`.

**Issue #599 two-layer model is intact:** original HTML bytes are the source blob
(`.html` format); extracted markdown is a derived `source_markdown_versions` row.
Defuddle only changes *what produces the markdown*, not the storage model.

### 1.3 Where defuddle does NOT run (out of scope)

- **`WebsiteSnapshotExtractor`** — uses
  `HTMLToMarkdown.scopedTokens(for:)` for token-level `<img src>` rewriting.
  Defuddle returns cleaned markdown, not tokens. **Keep HTMLToMarkdown here.**
- **Re-extraction UI** — the PDF re-extract button. HTML re-extract via defuddle
  is a natural follow-on, not in the initial PR. **The ingestion path is the target.**

---

## 2. The Integration — simplest possible, mirroring pdf2md

### 2.1 build.sh: bundle the defuddle script (4 edits, all mirroring pdf2md)

| # | build.sh location | pdf2md pattern to mirror | defuddle addition |
|---|-------------------|--------------------------|-------------------|
| 1 | variable defs | `PDF2MD_NAME`/`PDF2MD_SRC` | `DEFUDDLE_NAME="defuddle"` / `DEFUDDLE_SRC="tools/defuddle/defuddle"` |
| 2 | cp into bundle | `cp "${PDF2MD_SRC}" "${HELPERS_DIR}/…"` + build/ copy | same for defuddle |
| 3 | real-identity codesign | `codesign … --sign "${IDENTITY}" "${HELPERS_DIR}/${PDF2MD_NAME}"` | same for defuddle |
| 4 | ad-hoc codesign | `codesign --force --sign - "${HELPERS_DIR}/${PDF2MD_NAME}"` | same for defuddle |

**Why sign a plain script?** Same reason as pdf2md: a plain script bundled in
`Helpers/` must be signed or the outer app's seal fails ("code object is not
signed at all"). bun reads the file; signing is for the seal.

**Repo vendoring:** the ~2.45 MB self-contained `bun build` bundle lives at
`tools/defuddle/defuddle` (parallel to `tools/pdf2md/pdf2md`). Single bundle — no
`node_modules`, no install step. `tools/defuddle/README.md` notes the source
version (0.19.1) and the `bun build` update procedure.

### 2.2 New file: `Sources/WikiFS/Sources/DefuddleExtractionService.swift`

A `@MainActor enum` (namespace of statics), a **near-clone of
`PdfExtractionService`** but simpler. Lives in the `WikiFS` target alongside
`PdfExtractionService.swift`.

**Resolved binary pair:** unlike pdf2md (one script), defuddle needs **two
artifacts**: the bun runtime + the defuddle script. `resolve()` returns
`(bun: URL, script: URL)?`.

```swift
import Foundation
import WikiFSCore

/// Extracts article markdown + metadata from HTML via the bundled `defuddle`
/// Node script run with the bundled `bun` runtime. A near-clone of
/// PdfExtractionService's Process pattern, but simpler: no uv/Python/venv (bun
/// is always bundled), HTML on stdin, sub-second runtime, JSON on stdout.
///
/// Fallback contract: extract() returns nil on ANY failure (binary missing,
/// non-zero exit, empty content for SPA/JS-rendered pages, bad JSON). The
/// caller then uses the tag-based HTMLToMarkdown path — zero regression.
@MainActor
enum DefuddleExtractionService {

    /// Markdown body + parsed metadata.
    struct ExtractionResult: Sendable {
        let markdown: String        // contentMarkdown (preferred) or content
        let title: String?
        let author: String?
        let description: String?
        let published: String?      // ISO 8601 string
        let wordCount: Int?
    }

    /// Resolve (bundled bun, defuddle script). Returns nil only if EITHER is
    /// unresolvable.
    static func resolve() -> (bun: URL, script: URL)? { … }

    /// Extract markdown + metadata from HTML bytes via `bun defuddle parse -j -`.
    /// Best-effort: returns nil on any failure. Never throws.
    static func extract(html: String, timeout: Duration = .seconds(30)) async -> ExtractionResult? { … }

    // MARK: - JSON parse (robust to both -j and -m -j field shapes)
    private static func parseDefuddleJSON(_ data: Data) -> ExtractionResult? { … }
}
```

### 2.3 The subprocess invocation — concrete shape

Mirror `PdfExtractionService.run()`, adapted for stdin + bun:

```swift
let process = Process()
process.executableURL = bun                           // Helpers/bun
process.arguments = [script.path, "parse", "-j", "-"] // [defuddle, "parse","-j","-"]
// NO env PATH augmentation needed — bun is the absolute executableURL.

let stdinPipe = Pipe();  process.standardInput = stdinPipe
let stdoutPipe = Pipe(); process.standardOutput = stdoutPipe
let stderrPipe = Pipe(); process.standardError = stderrPipe

// Continuous stdout/stderr drain (OutputBuffer + readabilityHandler) —
// SAME pipe-deadlock avoidance as PdfExtractionService.
let stdoutBuffer = OutputBuffer()
stdoutPipe.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData; guard !d.isEmpty else { return }; stdoutBuffer.append(d)
}
let stderrBuffer = OutputBuffer()
stderrPipe.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData; guard !d.isEmpty else { return }; stderrBuffer.append(d)
}

try process.run()
// Feed HTML to stdin, then CLOSE (EOF signals defuddle to parse):
stdinPipe.fileHandleForWriting.write(Data(html.utf8))
try? stdinPipe.fileHandleForWriting.close()
```

**Three things that differ from PdfExtractionService.run():**
1. **stdin input** (HTML bytes via pipe + `closeFile`) instead of a temp file path arg.
2. **bun as executableURL** instead of the script itself (the script is `arguments[0]`).
3. **A timeout** (`withTaskGroup` race vs `Task.sleep(30s)` — pdf2md has none because
   a cold run is legitimately minutes; defuddle is sub-second so 30s is a safety net).

### 2.4 Wire into the ingestion path (the materializers)

`FormatMaterializer.dispatch` stays **pure + synchronous** (it's called from tests
and the pure-dispatch contract is valuable). Defuddle is async, so the call lives
in the **materializers** (already `async throws`). Add one shared helper + call it
from each HTML-producing materializer.

**New helper** (add to `FormatMaterializer`):

```swift
/// If the plan is HTML, try defuddle; fall back to the tag-based markdown already
/// on the plan. Async — called by materializers after dispatch. Returns the
/// (possibly rewritten) plan + the technique tag to stamp on the stored version.
static func enrichWithDefuddle(_ plan: FormatPlan) async -> (plan: FormatPlan, technique: String) {
    guard plan.format == .html else { return (plan, "html-to-markdown") }
    let html = decodeText(plan.data)
    if let r = await DefuddleExtractionService.extract(html: html) {
        // Defuddle title may be better than the tag-based <title>.
        return (FormatPlan(filename: …, data: plan.data, format: .html,
                           extractedMarkdown: r.markdown), "defuddle")
    }
    return (plan, "html-to-markdown")  // fallback: keep tag-based extractedMarkdown
}
```

**Call sites** (3 materializers, each ~2 lines added after the `dispatch` call):
`WebsiteMaterializer`, `LocalFileMaterializer`, `ZoteroMaterializer`.

### 2.5 Thread the technique tag to the store (lightweight)

The current path hardcodes `"html-to-markdown"`. To surface which extractor
produced each version, add one optional field:

**`MaterializedSource`** gains:
```swift
public let extractionTechnique: String?  // "defuddle" | "html-to-markdown" | nil
```

**`WikiStoreModel.appendExtractedMarkdown`** reads it:
```swift
let technique = m.extractionTechnique ?? Self.htmlToMarkdownTechnique
try store.appendProcessedMarkdown(sourceID: summary.id, content: markdown,
    origin: .extraction, note: nil, technique: technique)
```

(Metadata enrichment — author/description/published → provenance — is
explicitly **out of scope**. `ExtractionResult` captures them, but the
`MaterializedSource`/`SourceProvenance` types don't yet carry author/published.
That's a follow-on task, not a blocker.)

---

## 3. The Fallback Chain (zero-regression guarantee)

```
materialize() [async]
  └─ FormatMaterializer.dispatch()  →  FormatPlan(.html, extractedMarkdown: TAG-BASED)
  └─ FormatMaterializer.enrichWithDefuddle(plan)
       └─ DefuddleExtractionService.extract(html)  [async subprocess]
            ├─ bun + script resolvable?
            │    NO → return nil
            ├─ exit 0 + non-empty contentMarkdown?
            │    YES → return ExtractionResult  →  use defuddle markdown, technique="defuddle"
            │    NO (exit 1 / empty / SPA / bad JSON) → return nil
            └─ nil → KEEP plan.extractedMarkdown (tag-based), technique="html-to-markdown"
```

**The fallback guarantees it is impossible to do worse than today.** Defuddle
either improves extraction (site-specific parsers: GitHub, Wikipedia, Substack,
YouTube transcripts, …) or transparently degrades to the current tag-based path.

---

## 4. Files to Modify

| File | Change |
|------|--------|
| `tools/defuddle/defuddle` | **NEW** — vendor the 7416-byte script |
| `tools/defuddle/README.md` | **NEW** — version (0.19.1), source, update procedure |
| `build.sh` | 4 edits: var defs, cp+sign (real + ad-hoc) — mirror pdf2md |
| `Sources/WikiFS/Sources/DefuddleExtractionService.swift` | **NEW** — ~120-line Process wrapper |
| `Sources/WikiFSCore/Sources/FormatMaterializer.swift` | Add `enrichWithDefuddle(_:)` async helper |
| `Sources/WikiFSCore/Sources/SourceMaterializer.swift` | Add `extractionTechnique` to `MaterializedSource`; call `enrichWithDefuddle` in 3 materializers |
| `Sources/WikiFSCore/Store/WikiStoreModel.swift` | `appendExtractedMarkdown` reads `m.extractionTechnique` |
| `Tests/WikiFSTests/DefuddleExtractionServiceTests.swift` | **NEW** — extraction + JSON parse + fallback tests |
| `Tests/WikiFSTests/FormatMaterializerTests.swift` | Add async `enrichWithDefuddle` tests |

---

## 5. Testing Plan (Swift Testing)

### 5.1 `DefuddleExtractionServiceTests` (new)

Mirror `PdfExtractionServiceTests` structure. Tests run the **real** bundled
bun + defuddle script. **Skip gracefully if `resolve()` returns nil** (CI / clean
dev) via an early `return` + comment (defuddle is opt-in until vendored).

- `extractsMarkdownAndMetadata` — article with nav/footer stripped, title/author/published parsed.
- `returnsNilForSPAEmptyBody` — `<div id="app">` → nil (fallback trigger).
- `returnsNilForEmptyInput` — `""` → nil.
- `parseJSONHandlesMissingContentMarkdown` — content present (HTML), contentMarkdown absent → nil.
- `parseJSONPrefersContentMarkdownOverContent` — both present → contentMarkdown wins.
- `resolvesBunAndScript` — resolve() != nil when bundled.

### 5.2 Fallback integration test

`enrichWithDefuddleFallsBackToTagBased` — SPA HTML → tag-based markdown kept,
technique == "html-to-markdown".

### 5.3 Regression

- `FormatMaterializerTests` — `dispatch` is unchanged (still pure/sync); pass as-is.
- `HTMLToMarkdownTests` — unchanged (still the fallback).
- `SourceMaterializerTests` — materializers are already `async`; add `await`.

---

## 6. Acceptance Criteria

1. **AC1 — Defuddle extraction:** ingesting a `text/html` URL yields markdown via
   defuddle with site-specific extraction (no nav/footer boilerplate).
2. **AC2 — Fallback on SPA:** a JS-rendered page (empty body) falls back to
   tag-based `HTMLToMarkdown` — no crash, no empty result.
3. **AC3 — Original HTML preserved:** the source blob is still the original HTML
   bytes (issue #599 two-layer model intact). The HTML tab in `SourceDetailView`
   still shows raw HTML.
4. **AC4 — Technique tag:** the `source_markdown_versions.technique` column is
   `"defuddle"` on success, `"html-to-markdown"` on fallback.
5. **AC5 — Self-contained:** runs via the **bundled bun** (no system Node/bun
   needed, no external runtime dependency). No uv-style degradation path.
6. **AC6 — No `print` / no bare `try?`:** all diagnostics via `DebugLog.extraction`;
   swallowed errors are logged, not hidden.
7. **AC7 — No regression:** all existing tests pass.
8. **AC8 — Unbundled is safe:** if `resolve()` returns nil, `extract()` returns
   nil, the fallback runs, a `DebugLog` note fires. No crash.

---

## 7. Gotchas

1. **`-j` vs `-m -j` field names (verified):** use `parse -j -` and read
   `contentMarkdown`. With `-m -j`, defuddle overloads `content` with markdown
   and **drops `contentMarkdown`**. Invoke `-j`; make the decoder robust
   (prefer `contentMarkdown`, fall back to `content`).
2. **stdin must be closed (EOF):** after `write`, call
   `stdinPipe.fileHandleForWriting.close()`. Without EOF, defuddle blocks
   waiting for more input → deadlock.
3. **stdout must drain continuously** (`readabilityHandler` + `OutputBuffer`),
   not only in `terminationHandler` — same 64 KB pipe-buffer deadlock as pdf2md.
4. **Sign the defuddle script** in `build.sh` — a plain script in `Helpers/`
   breaks the app seal if unsigned. Mirror the pdf2md codesign in BOTH the
   real-identity and ad-hoc branches.
5. **macOS 15 / Swift 6.0:** no `@Entry` (manual `EnvironmentKey`); strict
   concurrency — `OutputBuffer` must be `@unchecked Sendable` with a lock (pipe
   callbacks fire off-actor). `@MainActor enum` for the service, `nonisolated`
   for the registry/PATH helpers.
6. **bun is `executableURL`, script is `arguments[0]`:**
   `process.executableURL = bun`; `arguments = [script.path, "parse", "-j", "-"]`.
   NOT `executableURL = script` (the shebang would search PATH for node, which a
   Finder-launched app doesn't have).
7. **`resolveDefuddle` uses `fileExists`, not `isExecutableFile`:** bun *reads*
   the script (doesn't exec it), so the executable bit is irrelevant; readability
   is what matters.
8. **No PATH augmentation needed:** bun is resolved as an absolute
   `executableURL` (Helpers/bun), unlike pdf2md whose shebang needs `uv` on PATH.
   This is the key simplification — no `uvSearchPATH` equivalent.
9. **Empty-string metadata → nil:** defuddle emits `""` (not null) for absent
   `author`/`published`/`description`. Map with a `nonEmpty()` helper.
10. **Timeout (30s):** defuddle is sub-second, but a hung process (e.g. stdin not
    closed) is possible. Race the `terminationHandler` continuation against
    `Task.sleep(30s)` via `withTaskGroup`; on timeout, `process.terminate()`.
11. **`WebsiteSnapshotExtractor` is NOT touched** — it needs token-level access
    for `<img src>` rewriting. Document as a known follow-on.

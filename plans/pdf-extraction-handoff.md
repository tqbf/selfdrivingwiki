# PDF Extraction — Handoff Document

**Date:** 2026-06-18
**Branch:** `feature/pdf2md-docling-pipeline` (PR #11)
**Tests:** 422 passing (was 410; +12 PdfExtractionService tests)

## What was built

### `tools/pdf2md/` — standalone PDF-to-Markdown CLI

A PEP 723 inline script that wraps docling + granite-docling VLM pipeline for
local PDF-to-Markdown conversion. Requires `uv` (auto-downloads if missing).

| File | Purpose |
|---|---|
| `tools/pdf2md/pdf2md` | PEP 723 script. `./pdf2md input.pdf` → markdown to stdout |
| `tools/pdf2md/pyproject.toml` | Deps + tool config (ruff, pyright, pytest, beartype) |
| `tools/pdf2md/tests/test_pdf2md.py` | 48 unit tests (regex, cleanup, spaCy, CLI parsing) |
| `tools/pdf2md/tests/test_integration.py` | 10 integration tests (full pipeline, needs real PDF) |
| `tools/pdf2md/test-pipeline` | Shell script: end-to-end smoke test, ~100s for 1.6MB PDF |
| `tools/pdf2md/AGENTS.md` | Agent instructions: format with ruff, run quality checks |
| `tools/pdf2md/README.md` | Human instructions |

Run from `tools/pdf2md/`:
```bash
./pdf2md input.pdf                    # convert
uv run pytest tests/test_pdf2md.py -v # unit tests
uv run ruff check pdf2md tests/       # lint
./test-pipeline                       # smoke test
```

### Swift integration

| File | Change |
|---|---|
| `Sources/WikiFS/PdfExtractionService.swift` | Spawns `pdf2md` subprocess. `checkReady()`, `convert()`, `preDownload()`. ProcessRegistry kills children on app terminate. |
| `Sources/WikiFS/IngestSheetView.swift` | New — ingest-only sheet (no Query/Lint). Shows filename, extraction status, Run button. |
| `Sources/WikiFS/OperationsView.swift` | Simplified — Query + Lint only. Ingest removed. |
| `Sources/WikiFS/AgentOperationRunner.swift` | `runIngest` intercepts PDFs: converts to markdown via PdfExtractionService before agent sees bytes. Animated dots during conversion. Falls back to raw PDF on failure. |
| `Sources/WikiFS/AgentLauncher.swift` | Added `extractionLog` property for status text in activity view. |
| `Sources/WikiFS/AgentActivityView.swift` | Shows extraction log text during conversion (replaces "No output yet" placeholder). |
| `Sources/WikiFS/ContentView.swift` | Two separate sheets: `IngestSheetView` (file button) and `OperationsView` (toolbar). |
| `build.sh` | Copies `pdf2md` into `Contents/Helpers/`, codesigns it. |
| `Package.swift` | Added `WikiFS` as test dependency. |
| `Tests/WikiFSTests/PdfExtractionServiceTests.swift` | 12 tests: ProcessRegistry lifecycle, ExtractionError messages. |

### Design docs

| File | Purpose |
|---|---|
| `plans/pdf-extraction.md` | Full architecture: pdf2md tool, sibling ingested file storage, conversion flow, prompt changes, error handling |

## Architecture

### The conversion flow

```
User clicks "Ingest Into Wiki" on a PDF file
  → IngestSheetView opens (filename shown as text, no dropdown)
  → User clicks "Run Ingest"
  → AgentOperationRunner.runIngest():
      1. Sets launcher.extractionLog = "Converting PDF" (animated dots in UI)
      2. Calls PdfExtractionService.checkReady() (probes pdf2md --help)
      3. If ready: PdfExtractionService.convert() spawns pdf2md subprocess
         - Writes PDF bytes to temp file
         - Runs: pdf2md <temp.pdf>  (captures stdout = markdown)
         - 180s timeout via TaskGroup, defer block kills process
      4. On success: agent gets source.md instead of source.pdf
      5. On failure: prints message, agent gets raw PDF (Read tool fallback)
      6. ProcessRegistry tracks all running processes; kills on NSApplication.willTerminate
```

### The two dialogs

```
Toolbar "Maintain Wiki" (sparkle icon)
  → OperationsView
  → Segmented picker: [Query | Lint]  (no Ingest)
  → Query: text input, Run button
  → Lint: description, Run button

File "Ingest Into Wiki" button
  → IngestSheetView
  → Shows: source filename, extraction status dot (green/red), Run button
  → No operation picker, no Query, no Lint
```

### pdf2md resolution order

`PdfExtractionService.resolveScript()` checks:
1. `Contents/Helpers/pdf2md` (bundled in .app)
2. `build/pdf2md` (dev build)
3. Next to running executable
4. `tools/pdf2md/pdf2md` (repo, via project root calculation)

PATH: `~/.local/bin` prepended so `uv` in shebang resolves when app launched from Finder.

## How to pick up

### If deps aren't downloaded yet

The extraction status shows a red dot: "PDF extraction needs ~2 GB download".
The user must run the pre-download once. Currently this is wired in
`PdfExtractionService.preDownload()` but there's no UI button — it was
removed when the separate log viewer was taken out. The download happens
implicitly on first `convert()` call (slow — up to 180s).

**To do:** add a "Download Dependencies" button. The `PdfExtractionService.preDownload(onProgress:)`
method already exists — it just needs a UI affordance. The simplest place
is `IngestSheetView` next to the extraction status line.

### If the first conversion is slow

The Granite-Docling VLM model does full vision-language inference per page.
A 20-page academic PDF takes ~100s on MLX (Apple Silicon). The timeout is
180s. The UI shows animated dots during conversion.

### If pdf2md isn't found

Check the resolution order above. `build.sh` copies it to `Contents/Helpers/`
during `make`. If running via `swift run`, the script is found at
`tools/pdf2md/pdf2md` via the project root calculation.

### Running tests

```bash
# All Swift tests
swift test

# Just extraction tests
swift test --filter PdfExtractionServiceTests

# pdf2md Python tests
cd tools/pdf2md && uv run pytest tests/ -v

# Pipeline smoke test
tools/pdf2md/test-pipeline ~/path/to/test.pdf
```

### Key constants

| Constant | Location | Value |
|---|---|---|
| Conversion timeout | PdfExtractionService.run() | 180s |
| ingestByteCap | SQLiteWikiStore | 100 MB |
| `~/.local/bin` PATH prefix | PdfExtractionService | always prepended |
| Dependency download size | messages | ~2 GB |

## Remaining work

1. **Pre-download button** — `PdfExtractionService.preDownload()` has no UI trigger.
2. **Progress granularity** — docling has no per-page progress callback (the
   system is service-only). Sticking with animated dots is the pragmatic choice.
3. **uv environment cache sharing** — the bundled script (at `/Applications/.../
   Contents/Helpers/pdf2md`) gets a different uv cache key than the dev copy
   (at `tools/pdf2md/pdf2md`). Dependencies download twice: once for dev, once
   for prod. Consider copying the cached venv or symlinking.
4. **Sibling markdown storage** — the design plan calls for storing converted
   markdown as a sibling `ingested_files` row so conversion happens once at
   ingest time rather than on every agent run. Not yet implemented; currently
   conversion happens each time "Run Ingest" is clicked.

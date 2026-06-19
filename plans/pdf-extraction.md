# PDF Extraction — Local Docling Pipeline

**Status:** Design validated, not yet implemented.

## Goal

Replace Claude's built-in `Read`-tool PDF extraction with a local,
deterministic pipeline. When a PDF enters the wiki (URL or drag-drop),
convert it to markdown using **docling + granite-docling** (IBM's VLM
pipeline running on Apple Silicon via MLX) before the LLM agent ever
sees it. The agent reads pre-extracted markdown instead of raw PDF
bytes.

**Why:**
- Token cost: markdown is 2-5× smaller than raw PDF text extraction
  through the API
- Quality: docling is purpose-built for document structure (tables,
  headings, reading order, formulas)
- Privacy: PDF content stays local — only clean markdown goes to the
  LLM
- Caching: extract once, reuse across multiple ingest/query runs

**Non-goal:** This is strictly additive. If extraction fails or is
unavailable, the agent falls back to the existing `Read`-tool path.
Existing PDFs without extractions continue to work exactly as before.

---

## Architecture

### The `pdf2md` Tool

A minimal Python CLI wrapping docling. Lives at `tools/pdf2md/` in
this repo.

```
pdf2md <input.pdf> [--output <output.md>] [--pipeline vlm|standard] [--json]
```

| Flag | Default | Purpose |
|---|---|---|
| `--output` | stdout | Write markdown to a file |
| `--pipeline` | `vlm` | `vlm` = `VlmPipeline` + `GRANITEDOCLING_MLX` (best quality, Apple Silicon). `standard` = multi-stage pipeline (faster, text-heavy digital PDFs) |
| `--json` | off | Output structured JSON with page count, detected language, extraction metadata |

Exit 0 on success, non-zero on failure with error message to stderr.

**Core conversion:**

```python
from docling.document_converter import DocumentConverter, PdfFormatOption
from docling.datamodel.base_models import InputFormat
from docling.pipeline.vlm_pipeline import VlmPipeline

converter = DocumentConverter(
    format_options={
        InputFormat.PDF: PdfFormatOption(pipeline_cls=VlmPipeline)
    }
)
result = converter.convert(pdf_path)
markdown = result.document.export_to_markdown()
```

**Post-processing:**
1. Strip margin line-number blocks (common in preprint templates)
2. Collapse multi-space artifacts per-line
3. Remove soft hyphens (U+00AD)
4. spaCy sentence-aware page break fixing — join paragraphs split
   across PDF page boundaries, verifying with `en_core_web_sm` that a
   sentence boundary exists at the junction

**Packaging:** `pyproject.toml` with a `[project.scripts]` entry point.
Installed via `uv tool install` into the user's PATH. The Swift app
discovers `pdf2md` via `which pdf2md` or a configurable path.

**Error handling:**

| Condition | Exit code | Message |
|---|---|---|
| Corrupted PDF | 1 | `Error: Unable to parse PDF: <details>` |
| Empty PDF | 2 | `Error: PDF contains no extractable text` |
| docling not installed | 3 | `Error: docling is not available. Install with: pip install 'docling[vlm]'` |
| Timeout (5 min) | 124 | SIGTERM |

All errors to stderr. With `--json`, also emit a JSON error object.

---

## Storage: Sibling Ingested File

**No new tables or columns for markdown content.** The extracted
markdown becomes another row in the existing `ingested_files` table,
linked to its source PDF.

### Schema addition

```sql
ALTER TABLE ingested_files ADD COLUMN source_file_id TEXT;
```

- `NULL` — user-ingested file (the normal case)
- Non-NULL — auto-generated extraction; points to the source PDF's
  `id`

### How it works

1. User drops `paper.pdf` → stored as `ingested_files` row with
   `id = <pdf-ulid>`, `source_file_id = NULL`
2. `pdf2md` converts → markdown bytes stored as a second
   `ingested_files` row with `id = <md-ulid>`,
   `source_file_id = <pdf-ulid>`
3. Mount shows both:
   - `files/by-id/<pdf-ulid>.pdf`
   - `files/by-id/<md-ulid>.md`

The UI hides `source_file_id IS NOT NULL` rows from the file list
(they're implementation artifacts, not user-facing). They remain
visible on the mount for the agent.

**Benefits of this approach:**
- Zero content-schema migration
- Reuses existing file storage, mount projection, and list views
- Markdown gets the same 100 MB cap, MIME type, and version tracking
  for free
- Agent sees it as just another file — no special casing in prompts
  beyond "prefer `.md` when available"

---

## Conversion Flow

### At ingest time (URL or drag-drop)

```
PDF bytes arrive
  → store verbatim in SQLite (unchanged, fast)
  → UI shows PDF immediately
  → spawn pdf2md as subprocess (async, off main actor)
  → on success: store markdown bytes as sibling ingested_file
  → on failure: log warning, PDF still usable via Read fallback
```

### Subprocess pattern

Matches the existing `claude` and `wikictl` subprocess pattern:

```swift
// PdfExtractionService.swift (new, WikiFSCore)
func extractMarkdown(from pdfPath: String) throws -> String {
    let process = Process()
    process.executableURL = resolvePDF2MD()  // PATH lookup or config
    process.arguments = [pdfPath]
    // standard output capture, 5-min timeout, stderr → log
}
```

Discovered via `which pdf2md`, with an optional config override
in the wiki's settings or `.env` equivalent.

### UI during extraction

- PDF row appears immediately in the Files list
- A small spinner or badge indicator while extraction is in progress
- No blocking — user can navigate away, start other operations
- If extraction fails, the badge disappears silently (PDF remains
  usable)

---

## Prompt Changes

### `SystemPrompt.swift` — PDF handling guidance

**Before:**
> Raw files under `files/` may be PDFs or images, not just text. Use
> the `Read` tool on them directly — it handles text, images, and
> PDFs. For a PDF, read the text first; if it references figures you
> need, view those images separately.

**After:**
> Files under `files/` include both original uploads and
> auto-extracted markdown siblings (`.md` next to `.pdf`). Prefer the
> `.md` version for text content. Use the original only when you need
> non-text content (images, figures, tables that didn't survive
> extraction).

### `WikiOperation.swift` — Ingest prompt

**Before (line 193):**
> INSPECT the staged source's size and structure WITHOUT reading the
> whole bulk — e.g. `wc -l`/`head` for text, or count pages for a
> PDF — then split it into chunks (byte/line ranges, sections, or
> page ranges).

**After:**
> INSPECT the staged source's size and structure WITHOUT reading the
> whole bulk — e.g. `wc -l`/`head` for text. If a `.md` extraction
> exists alongside a source file, prefer it. Split into chunks
> (byte/line ranges or sections) as appropriate.

### `WikiOperation.swift` — Query prompt (line 253-255)

Remove `pdftotext` from the tool suggestion list. The agent uses
`cat` or `Read` on the `.md` file.

### `IngestPlan.swift` — Digester prompt

No change needed. The digester prompt says "READ ONLY that assigned
chunk" — the chunk is now markdown instead of PDF bytes. The
instruction is format-agnostic.

---

## Error Handling & Degradation

**The PDF is always usable.** Docling extraction is an optimization,
not a dependency. The agent falls back to the current `Read`-tool
behavior whenever the `.md` sibling is absent or suspect.

| Failure | Behavior |
|---|---|
| `pdf2md` not found in PATH | Log warning, skip extraction, PDF ingested normally. Agent sees only `.pdf` — unchanged from today. |
| `pdf2md` exits non-zero | Log stderr, PDF ingested normally. No `.md` sibling. |
| `pdf2md` times out (5 min) | SIGTERM, log warning, PDF ingested normally. |
| PDF has no extractable text (image-only scan) | `pdf2md` may produce empty/near-empty markdown. Store it; agent inspects both and can fall back to vision on the original. |
| Markdown is garbage (hallucinated VLM content) | The LLM agent is the last line of defense. It reads the markdown, cross-references the original if suspicious, can flag or re-extract. |
| PDF > 100 MB | Rejected by existing `ingestByteCap`. |
| Conversion crashes mid-flight | Temp files cleaned up by `defer`. PDF stored, `.md` absent — fallback. |

**The `.md` sibling is a hint, not a contract.** The agent prompt says
"prefer the `.md`" — if it's missing or looks wrong, the agent has
full access to the original and can use `Read` on it exactly as it
does today.

---

## File Provider Projection

`Projection.swift` already iterates `ingested_files` to build
`files/by-id` and `files/by-name`. Extraction siblings
(`source_file_id IS NOT NULL`) are included in the projection so the
agent sees them, but excluded from `indexes/files.jsonl` so they don't
appear in the user-facing file index.

---

## Files Touched

| File | Change |
|---|---|
| `tools/pdf2md/pdf2md` | New — PEP 723 inline script, self-bootstrapping |
| `tools/pdf2md/tests/test_pdf2md.py` | New — unit tests for cleanup functions |
| `tools/pdf2md/tests/test_integration.py` | New — integration tests |
| `Sources/WikiFSCore/SQLiteWikiStore.swift` | `source_file_id` column, `ingestExtraction()` method |
| `Sources/WikiFSCore/PdfExtractionService.swift` | New — `Process` spawn for `pdf2md` |
| `Sources/WikiFSCore/URLIngestService.swift` | Call `PdfExtractionService` after PDF ingest |
| `Sources/WikiFS/WikiStoreModel.swift` | Wire extraction into drag-drop ingest path |
| `Sources/WikiFSCore/SystemPrompt.swift` | Update PDF handling guidance |
| `Sources/WikiFSCore/WikiOperation.swift` | Update ingest + query prompts |
| `Sources/WikiFSFileProvider/Projection.swift` | Include extraction siblings in `files/by-id` + `files/by-name`, exclude from `files.jsonl` |
| `Tests/WikiFSTests/` | New tests: `PdfExtractionServiceTests`, plus updates to `URLIngestServiceTests`, `SystemPromptTests`, `OperationCommandTests`, `IndexGeneratorTests` |

---

## Implementation Order

1. **`pdf2md` CLI** — build and install the Python tool, verify it
   works on real PDFs, establish the subprocess contract
2. **Schema + store** — add `source_file_id` column, `ingestExtraction()`
3. **`PdfExtractionService`** — subprocess spawn, PATH discovery,
   timeout, error handling
4. **Wire into ingest** — URL ingest + drag-drop paths call extraction
5. **Update prompts** — `SystemPrompt`, `WikiOperation`, verify agent
   behavior
6. **Update projection** — include extraction siblings on mount
7. **Tests** — new + updated tests for each layer

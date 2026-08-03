# PDF→Markdown extraction backends (model + remote)

Pluggable PDF→Markdown extraction behind a single protocol, so a user can convert
PDFs with **local pdf2md** (the bundled docling + granite VLM subprocess, the
default), **Claude** (Anthropic Messages API), **Gemini** (Google AI
`generateContent`), or a self-hosted **Docling Serve** instance — all landing as
the same `source_markdown_versions` row.

This doc is the source of truth for the backend abstraction. For the original
local pipeline, see [`pdf-extraction.md`](pdf-extraction.md); for the lock model
around extraction, see [`extraction-vs-ingestion-lock.md`](extraction-vs-ingestion-lock.md).

## Why

Extraction was hardwired to one engine (`PdfExtractionService` spawns the bundled
`pdf2md`). More options share the exact same contract:

1. **Model backends** — send the PDF to Claude (Anthropic) or Gemini (Google AI)
   and get clean markdown back.
2. A **remote backend** — offload to a self-hosted **Docling Serve** HTTP service.

(Mathpix and the Apify Docling actor are deferred — see Out of scope.)

The key insight that made this small: **extraction is a single chokepoint**.
`PdfExtractionService.convert(...)` was called from exactly two places, both with
an identical preamble, and **storage is backend-agnostic** — every backend's
markdown lands as a `source_markdown_versions` row with origin `"extraction"`.
**No schema change.** So the work is: one abstraction, two backends, mirror the
app's existing config / Keychain / Settings / HTTP patterns (all established by
Zotero), and dispatch through the abstraction at the two call sites.

### Locked decisions

- **Backends**: Local pdf2md (default), Claude (Anthropic API), Gemini (Google
  AI), Docling Serve.
- **Model mechanisms**: Anthropic Messages API (PDF `document` block) and Gemini
  `generateContent` (PDF `inline_data` part); API keys in Keychain. Raw HTTP, no
  SDK, no `claude`/`claude -p` CLI.
- **Default models**: extraction is transcription, not reasoning — `claude-sonnet-4-6`
  and `gemini-3.5-flash` (good fidelity/cost balance), both user-overridable to
  cheaper (Haiku / Gemini Flash-Lite) or more-capable (Opus / Gemini Pro) tiers.
- **Output**: native markdown per backend — each emits its own markdown, stored
  verbatim. No shared normalization pass.

## Architecture

### The abstraction (`WikiFSCore`)

`Sources/WikiFSCore/MarkdownExtractor.swift`:

```swift
public protocol MarkdownExtractor: Sendable {
    var displayName: String { get }                          // "Local pdf2md" / "Claude (Opus 4.8)" / "Docling Serve (localhost)"
    func readiness() async -> ExtractionReadiness            // cheap probe before convert
    func convert(pdfData: Data, filename: String,
                 onProgress: (@Sendable (String) -> Void)?) async throws -> String
}

public enum ExtractionReadiness: Sendable, Equatable {
    case ready
    case needsSetup(String)    // remote/model: no API key / endpoint → points at Settings
    case notInstalled(String)  // local only: deps missing → downloadable
}

public enum ExtractionBackend: String, Sendable, CaseIterable, Codable {
    case localPdf2md, anthropic, gemini, doclingServe
    var displayName: String { … }
    var helpText: String { … }
}
```

The protocol is deliberately **PID-free**: only the subprocess backend has a PID,
and it reports it via the `onProgress` stream (`"Started pdf2md (pid 12345).\n"`).
Remote/model backends have nothing analogous, and the live UI already nil-handles
the PID (it shows "Converting…" when there is none).

### The backends

| Backend | File | `readiness()` | Mechanism |
| --- | --- | --- | --- |
| Local pdf2md | `WikiFS/LocalPdf2MarkdownExtractor.swift` | `.ready` / `.notInstalled` | Thin non-isolated struct delegating to `PdfExtractionService` statics (the service is a caseless `@MainActor enum` namespace, so it can't be the instance conformer). |
| Claude | `WikiFSCore/AnthropicExtractionClient.swift` | key set ? `.ready` : `.needsSetup` | Raw HTTP `POST /v1/messages` with a base64 PDF `document` block + a faithful-transcription system prompt. Concatenates `content[]` text blocks; errors on `stop_reason:"refusal"` or empty. |
| Gemini | `WikiFSCore/GeminiExtractionClient.swift` | key set ? `.ready` : `.needsSetup` | Raw HTTP `POST …/v1beta/models/<model>:generateContent` with a base64 PDF `inline_data` part + the shared transcription prompt. Concatenates `candidates[0].content.parts[].text`; errors on `promptFeedback.blockReason` / a blocking `finishReason` / empty. |
| Docling Serve | `WikiFSCore/DoclingServeClient.swift` | endpoint set ? `.ready` : `.needsSetup` | Multipart `POST <endpoint>/v1/convert/file` (`files` part + `to_formats=md`); pulls `document.md_content` from the JSON response. |

Both model clients + Docling mirror `ZoteroClient`: a fetcher-injected value type
with pure static helpers (`buildRequest`, `checkStatus`, `decode`) that are the
unit-test targets, plus a typed nested `Error` (`unauthorized` / `httpStatus` /
`decoding` / `network` / `emptyOutput`, plus Anthropic `tooLarge`/`refused`/
`missingAPIKey`/`truncated`, Gemini `tooLarge`/`blocked`/`missingAPIKey`, and
Docling `serverErrors`/`endpointInvalid`). The two model clients share one
transcription prompt via `ExtractionPrompts` (`MarkdownExtractor.swift`) so their
output is consistent regardless of provider.

### The shared HTTP seam

`Sources/WikiFSCore/ExtractionHTTP.swift` defines `HTTPRequestFetcher`
(`URLRequest → (data, statusCode)`) with a production
`URLSessionRequestFetcher` (10-minute timeout — a large PDF can take minutes)
and an `actor FakeHTTPFetcher` (FIFO response queue) so the clients share one
trivially-fakeable network seam and the tests need no real network.

### Config + secrets (mirror Zotero exactly)

- `Sources/WikiFSCore/ExtractionConfig.swift` — `Codable, Equatable, Sendable`,
  `fileName = "extraction-config.json"`, app-wide (App Group container, sibling
  of `zotero-config.json`), same load(degrade-to-empty)/save(atomic, sorted)
  and resilient `init(from:)` (each field `decodeIfPresent` + default; unknown
  backend raw value degrades to `.localPdf2md`). **Single source of truth for
  all non-secret prefs**, including `backend`. Fields: `backend`,
  `anthropicModel` (default `claude-sonnet-4-6`), `anthropicBaseURLOverride`,
  `geminiModel` (default `gemini-3.5-flash`), `geminiBaseURLOverride`,
  `doclingServeEndpoint`.
- `Sources/WikiFSCore/ExtractionCredentialStore.swift` — protocol +
  `KeychainExtractionCredentialStore` (service `org.sockpuppet.WikiFS.extraction`,
  accounts `anthropic-api-key` / `gemini-api-key` / `docling-serve-token`) +
  `InMemoryExtractionCredentialStore` for tests. Secrets never touch JSON. The
  app is un-sandboxed, so Keychain needs no entitlement.

### The coordinator

`Sources/WikiFS/ExtractionCoordinator.swift` — `@MainActor @Observable`, one
instance `@State` in `WikiFSApp`, threaded like `AgentLauncher`
(`RootView` → `ContentView` → `WikiDetailView` → `SourceDetailView`).
`current()` re-reads `ExtractionConfig` off disk each call and returns the right
backend wired with its config + secrets:

```swift
func current() -> any MarkdownExtractor {
    let cfg = config                      // ExtractionConfig.load(from: containerDirectory)
    switch cfg.backend {
    case .localPdf2md: return LocalPdf2MarkdownExtractor()
    case .anthropic:  return AnthropicExtractionClient(model: cfg.anthropicModel, apiKey: secret(.anthropicAPIKey) ?? "", …)
    case .gemini:     return GeminiExtractionClient(model: cfg.geminiModel, apiKey: secret(.geminiAPIKey) ?? "", …)
    case .doclingServe: return DoclingServeClient(endpoint: cfg.doclingServeEndpoint ?? "", apiToken: secret(.doclingServeToken), …)
    }
}
```

Because `current()` reads disk fresh, a Settings Save is picked up immediately by
the next extract.

### The two dispatch edits (the whole point)

Both call sites resolve the extractor once, then switch on readiness — replacing
the old `if await PdfExtractionService.checkReady() { PdfExtractionService.convert(…) }`:

```swift
let extractor = extractionCoordinator.current()
switch await extractor.readiness() {
case .ready:
    let markdown = try await extractor.convert(pdfData: bytes, filename: …, onProgress: { … append to launcher.extractionLog })
    store.seedPdfMarkdown(for: source.id, content: markdown)   // backend-agnostic storage, unchanged
case .needsSetup(let message), .notInstalled(let message):
    launcher.extractionLog = message          // show reason; raw PDF is sent to the agent as-is
}
```

- `Sources/WikiFS/AgentOperationRunner.swift` `runMultiIngest` — the ingest-path
  extract (the `onStart(pid:)` wiring is gone; the local backend funnels its PID
  through `onProgress`).
- `Sources/WikiFS/SourceDetailView.swift` `runExtraction` — the standalone
  "Extract Markdown" button.

### Settings UI

`Sources/WikiFS/ExtractionSettingsView.swift` — mirrors `ZoteroSettingsView`
for structure (secrets in Keychain, non-secret prefs in `ExtractionConfig`) but
**auto-saves on change** instead of an explicit Save button: drafts are seeded in
`init` and each field's `.onChange` writes config + Keychain immediately, so
closing the window can never drop a just-typed value. A backend `Picker` swaps in
**only the selected backend's section** (Local note / Claude / Gemini / Docling),
each with its fields and a **Test Connection** (a phase machine + `.alert`) — so
the form stays uncluttered and Test Connection always targets the visible
section. Wired into `WikiFSApp`'s `Settings` scene as a `TabView` alongside
`ZoteroSettingsView`. The panel **locks itself while a PDF extraction is running**
(`launcher.extractingSourceIDs` non-empty) — a banner explains why and all
controls are disabled, so a mid-conversion backend/key change can't derail the
running extraction.

## API facts

### Anthropic Messages

- PDF input is a base64 `document` block
  `{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":<b64, no newlines>}}`
  before the text instruction. No beta header.
- `POST https://api.anthropic.com/v1/messages`; headers `x-api-key` +
  `anthropic-version: 2023-06-01`. Concatenate the `content[]` text blocks.
- Check `stop_reason`: `"refusal"` → extraction error; `"max_tokens"` → warn
  (possible truncation).
- 32 MB request cap → guard raw bytes at 24 MB (`maxPDFBytes`) and reject with
  `.tooLarge` (base64 inflates ~1.33×) rather than letting the API 413.
- Default model `claude-sonnet-4-6` (extraction is transcription, not reasoning —
  Sonnet's fidelity/cost balance beats Opus); user-overridable to Haiku 4.5
  (cheapest) or Opus (hardest layouts). Non-streaming with the long `URLSession`
  timeout.
- Test Connection = a 1-token `ping` message (`verifyConnection`); 401 → key invalid.

### Gemini (Google AI `generateContent`)

- PDF input is a base64 `inline_data` part
  `{"inline_data":{"mime_type":"application/pdf","data":<b64>}}` alongside the
  text instruction, under `contents[0].parts`; system prompt under
  `systemInstruction.parts[0].text`.
- `POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`;
  header `x-goog-api-key`. Concatenate the `candidates[0].content.parts[].text`
  blocks.
- Uses the classic `generateContent` endpoint, **not** the newer Interactions API
  (which is in beta with breaking changes and returns an agentic `steps` timeline
  that's overkill for a one-shot extract; `generateContent`'s flat `candidates`
  response is trivial to parse). Google explicitly recommends `generateContent`
  for stable deployments.
- Check `finishReason`: a blocking value (`SAFETY`/`RECITATION`/`OTHER`/…) with no
  text, or a `promptFeedback.blockReason` → `.blocked`; `MAX_TOKENS` → warn.
- 50 MB PDF cap → guard raw bytes at 48 MB (`maxPDFBytes`) and reject with
  `.tooLarge` rather than letting the API error.
- Auth is a single Google AI Studio API key (aistudio.google.com) which works on
  the **free tier** (rate-limited). Default model `gemini-3.5-flash` (good
  fidelity/cost); user-overridable to `gemini-3.1-flash-lite` (cheapest, most
  generous free limits, weaker on complex layouts) or a Pro model. Gemini 3
  doesn't charge for native embedded PDF text.
- Test Connection = a 1-token `ping` (`verifyConnection`); 401/403 → key invalid
  (a bad key actually returns 400 "API key not valid", surfaced via the carried
  `.httpStatus` detail).

### Docling Serve v1

- `POST <endpoint>/v1/convert/file` multipart: a `files` part
  (`application/pdf`) plus `to_formats=md` (and `from_formats=pdf`). Fresh
  boundary per request; CRLF line endings.
- Single-file JSON response: `{"document":{"md_content":"…"}, "errors":[]}`. We
  return `document.md_content`; with `abort_on_error=false` (the default) the
  server may still return partial output alongside `errors`, so non-empty
  markdown wins and we only surface `errors` when there's no usable markdown.
- Optional auth: when the server is started with `DOCLING_SERVE_API_KEY`, every
  request carries `X-Api-Key`. 401/403 → `.unauthorized`.
- Test Connection = `GET <endpoint>/openapi.json` (FastAPI's standard schema
  endpoint — confirms the service is up at that base URL); 401/403 → token wrong.

## The live extraction surface

The conversion log is shown in the **transcript sidebar's "PDF Conversion" box**
(`AgentTranscriptSidebar`), which keys off `launcher.extractionLog` /
`launcher.isExtracting`. Every backend writes its progress lines there, so it
works for all four with **no change**; a remote/model extract just shows
"Converting…" (no PID) instead of "Converting… (pid N)".

`Sources/WikiFS/PdfExtractionView.swift` is **orphaned** — it predates the
sidebar-box UI and is no longer instantiated anywhere. It still compiles (it
calls `PdfExtractionService` statics directly) but is dead code; the download
flow it owned (`PdfExtractionService.preDownload`) is likewise not reachable from
the current UI. Leaving it in place for now; wire it up or delete it as a
follow-up.

## File map

**New (`WikiFSCore`, pure/testable):** `MarkdownExtractor.swift`,
`ExtractionConfig.swift`, `ExtractionCredentialStore.swift`,
`ExtractionHTTP.swift`, `AnthropicExtractionClient.swift`,
`GeminiExtractionClient.swift`, `DoclingServeClient.swift`.

**New (`WikiFS`):** `LocalPdf2MarkdownExtractor.swift`,
`ExtractionCoordinator.swift`, `ExtractionSettingsView.swift`.

**Modified:** `AgentOperationRunner.swift` (`runIngest`/`runMultiIngest`
dispatch), `SourceDetailView.swift` (`runExtraction` dispatch),
`ContentView.swift` / `RootView.swift` / `WikiDetailView.swift` (thread the
coordinator), `WikiFSApp.swift` (coordinator `@State` + Settings `TabView`).

**Tests:** `ExtractionConfigTests`, `ExtractionCredentialStoreTests`,
`AnthropicExtractionClientTests`, `GeminiExtractionClientTests`,
`DoclingServeClientTests`, `ExtractionCoordinatorTests`.

## Verification

- `swift build`; `swift test` (892 tests; the new ones cover config
  round-trip/resilient decode, the credential store, all three clients'
  request-build + decode + status mapping + end-to-end convert +
  `verifyConnection`, and the coordinator's backend resolution + readiness mapping).
- **Manual smoke tests** (one per backend, like Zotero's live gate), ingesting a
  real PDF and confirming markdown lands as a `source_markdown_versions` row
  with origin `"extraction"`:
  1. Settings → Extraction → backend = Claude, paste API key, Test Connection;
     Ingest/Extract a PDF → markdown appears.
  2. Backend = Gemini, paste a Google AI Studio key, Test Connection; repeat.
  3. Backend = Docling Serve (run `docling-serve run` locally), Test Connection;
     repeat.
  4. Backend = Local pdf2md → unchanged from today (`cd tools/pdf2md && ./test-pipeline <pdf>`).

## Out of scope / follow-ups

- **Batch API (Anthropic / Gemini)** — 50% off but a 24-hour completion SLA and
  a poll-for-results model. Rejected for the synchronous ingest→agent flow
  (extraction blocks until the markdown is staged for the agent run). A separate
  **bulk background extract** mode (submit a folder of PDFs as one batch, poll,
  mark markdown ready later, outside the live ingest) is the only shape where it
  fits — a follow-up feature, not a swap for the synchronous path.
- **Gemini Interactions API** — Google's newer surface (`/v1beta/interactions`)
  is in beta with breaking changes and built for agentic `steps` timelines; we
  use the stable `generateContent` endpoint. Migrate if/when Google sunsets
  `generateContent`.
- **Default model tuning** — Claude Sonnet / Gemini Flash are the fidelity/cost
  defaults; Flash-Lite / Haiku are the cheapest options. Revisit if extraction
  quality or cost needs shift.
- **Mathpix** and **Apify Docling actor** backends — async submit+poll HTTP;
  straightforward to add behind the same protocol.
- **Stream the model response** for live per-token progress (v1 is non-streaming
  with a generous timeout; remote/model show "Converting…" + a final char count).
- **Per-extraction backend override** on the Extract button (v1: Settings default
  only).
- **Shared normalization** across backends (decided against for v1).
- **Oversized-PDF fallback** — surface a clear `tooLarge` error (done); an
  auto-fall-back-to-local heuristic is a follow-up.
- **`PdfExtractionView`** — wire up or delete the orphaned readiness view.

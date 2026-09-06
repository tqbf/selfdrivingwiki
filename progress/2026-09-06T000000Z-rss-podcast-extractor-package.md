---
timestamp: 2026-09-06T000000Z
title: RSS podcast transcripts as a reviewed extractor package
branch: feature/rss-podcast-extractor-package
status: complete
---

# RSS podcast transcripts as a reviewed extractor package

## Progress

RSS podcast transcript extraction moved into a reviewed extractor package.
The pipeline now runs through the same registry, queue, and provenance
machinery as the other package-backed routes, in both the app and the
daemon.

### Package contract (protocol revision 3)

- `ExtractorKind` gained `podcast-transcript`; `ExtractorInputTransport`
  gained `remote-url`.
- `ExtractorProtocolRevision` accepts revision 3. The request models the
  input as a tagged value: `inputPath` is mandatory only for
  `operation-file`, and `remoteURL` (new type `ExtractorRemoteSourceURL`)
  is mandatory only for `remote-url`. URL validation rejects non-HTTP(S)
  schemes, embedded credentials, fragments, missing hosts, NUL, and
  over-limit strings before launch; the stored URL is normalized.
- Revisions 1 and 2 keep their exact wire shape (golden tests assert the key
  set and values) and reject the revision-3 key set; mixed shapes are
  rejected in every revision.
- The revision-gate sweep: selection resolver, generated-plugin factory,
  credential resolution, and operation configuration all accept revision 3.
  The package catalog record persists `manifestRevision` explicitly and
  derives it for legacy records, so a manifest-1/protocol-3 package no
  longer poisons the catalog.
- `docs/architecture/extractor-script-protocol.md` and
  `docs/architecture/extractor-package-manifest.md` now describe revisions
  1–3, the URL rules, and the manifest-revision/protocol-revision split.

### The reviewed package

- `tools/podcast-transcript/podcast-transcript` gained
  `run_extractor_protocol`: one revision-3 `remote-url` request in, JSON
  Lines frames out, Markdown only at the output path, exactly one terminal
  frame, bounded URL-free diagnostics. The CLI stays for development.
- `scripts/sync-extractor-packages.sh` generates
  `ExtractorPackages/PodcastTranscript` (`uv run --script` launch,
  `network` capability only, no Whisper fallback in the registration), and
  `--check` byte-compares it. `sources.lock.json` records the source
  digest.
- `ReviewedExtractorPackages.podcastTranscript` pins the exact digest; the
  golden test re-validates the committed bytes.
- `protocol-smoke` fixtures cover success, missing transcript, and network
  failure frame sequences, plus revision/transport mismatch refusals.
- Python tests cover request parsing, transport rules, failure mapping,
  bounded diagnostics, and output byte accounting (ruff + pyright clean).

### Registration, selection, execution

- `ProcessExtractorProvider.preparePodcastTranscript` prepares the
  process-backed adapter; `execute(remoteURL:...)` runs the operation with
  no staged input file. Admission, snapshots, runtime resolution, deadline,
  cancellation, redaction, and output validation reuse the shared path.
- The generated-plugin factory registers `podcast-transcript` through the
  atomic batch. The never-registered built-in `RSSPodcastTranscriptPlugin`
  and its fetcher adapter case were removed; the new
  `.podcastTranscript(ProcessPackagePodcastTranscript)` adapter case
  carries exact package provenance.
- `ExtractionServices.preparePodcastTranscript` resolves the route through
  the configuration with the documented state machine: stored installed
  reference → active registration; explicit `.none` disables (no
  reviewed-default revival, unlike DOCX); host strays fail closed; the
  bundled default route supplies the reviewed lineage when nothing is
  configured.
- `default-routes.json` ships the podcast route default.
- The route table gains the canonical podcast descriptor and a
  package-only choice set; `installedPackageRows()` derives from
  registration snapshots instead of a hard-coded kind list.

### Tagged resolution and persistence

- `ExtractionResolution` is a tagged enum. The `.bytes(...)` case handles
  file-backed conversion. The `.transcript(...)` case handles URL-backed
  work. Its result mode is `.builtInTool(tool)` or
  `.installedPackage(producer)`. The installed-package case requires the
  initial source-version link. The payload does not store a second policy
  flag. The worker switches exhaustively.
- `QueueExtractionProvider` now has typed per-case writes
  (`persistBytesExtraction`, `persistTranscriptExtraction`); the
  `InstalledPackageExtractionPersisting` side protocol is deleted.
- `appendInstalledPackageMarkdown` accepts the derived origin and refuses a
  package transcript without `sourceVersionID`
  (`AppendDerivedMarkdownError.missingInitialSourceVersion`).
- Both hosts resolve `SourceOrigin.plan` into a validated URL, resolve the
  initial content version before writing, and persist `.transcript`-origin
  rows with exact revision/registration/protocol/metadata provenance.
- Re-transcription appends alternatives; failures write nothing (atomic
  store mutation through the existing `mutate()` seam).

### Queue-routed `.podcast` path

- `WikiStoreModel.transcribe`'s `.podcast` arm and the RSS-feed
  materialization in `SourceRefreshService` are removed.
  `transcribe` on a `.podcast` source throws the typed
  `RefreshError.podcastQueueRequired` whose message names the app's
  extraction queue; the app's refresh action handles that case by
  enqueuing the durable extraction job. `isSourceRefreshable` and
  `supportsRefresh` stay `true` for `.podcast` with updated docs.
- `ExtractionCompositionBoundaryTests.noProductionRSSPodcastSubprocessPath`
  scans production sources and rejects any
  `RSSPodcastTranscriptService(` construction outside the three
  allow-listed `.applePodcast` fallback sites, including a moved
  construction.
- The Settings route table shows the RSS podcast transcript route as a
  standard row; the old "not package-backed" statement is gone. The Apple
  TTML backend control remains a separate row (Apple follow-up boundary).

### Deliberately unchanged

- Apple TTML behavior, `podcast-token-helper`, `#if PODCAST_TRANSCRIPTS`,
  and the Apple queue path's nil source-version link (carry-over for the
  Apple follow-up).
- YouTube captions as a built-in transcript adapter.
- Byteless `.podcast` ingest: no transcript is fetched until the user starts
  transcription.

## Verification

- `tools/podcast-transcript`: pytest (76 tests), ruff check, ruff format,
  pyright — all clean.
- `swift run extractor-package-tool validate ExtractorPackages/PodcastTranscript`
  — clean; digest pinned in `ReviewedExtractorPackages`.
- `scripts/sync-extractor-packages.sh --check` — current.
- `make test` — full Swift suite green (one pre-existing failure,
  `RendererModelTests.reviewedRevision6PackageHashesRemainStable`, verified
  failing at HEAD without these changes).
- `WIKIFS_APP_STORE=1 swift build` — clean; the RSS package route stays
  compiled while Apple TTML is excluded.
